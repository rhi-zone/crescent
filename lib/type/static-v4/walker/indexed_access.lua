-- Walker sub-phase F — indexed access expressions, module-pattern
-- accumulation, indexed callees, varargs polish, table literals.
--
-- Per docs/typechecker-ast-walker-design.md §3.6, §3.7 (indexed callees),
-- §3.10 (table literals — only the empty case is required by F; the rich
-- table-literal CHECK/SYNTHESIZE pair lands when subphase G needs it),
-- §3.11 + §13.5 (module pattern Option D), §8.1 (indexed access), §8.2
-- (varargs polish).
--
-- This module owns:
--
--   NODE_FIELD_EXPR     `obj.k`              — synthesize obj, V.index(obj, lit(k))
--   NODE_INDEX_EXPR     `obj[k]`             — synthesize obj AND key, V.index(obj, k)
--   NODE_TABLE_EXPR     `{}`-and-friends     — empty + non-empty literals.
--                                              §3.10 SYNTHESIZE assembles a
--                                              closed V.rec from positional /
--                                              named / computed fields;
--                                              non-literal computed keys fold
--                                              into an indexer. CHECK against a
--                                              closed expected rec checks each
--                                              value against the corresponding
--                                              field type directly.
--
-- It also re-registers, OVERRIDING sub-phase C's stubs:
--
--   NODE_CALL_EXPR      indexed-callee resolution (was rejected in C).
--   NODE_ASSIGN_STMT    indexed-LHS resolution + module-pattern accumulation
--                       (was rejected in E).
--   NODE_LOCAL_STMT     module-pattern trigger: `local M = {}` (empty table
--                       literal, no annotation) binds α_M = V.var, with the
--                       empty closed rec as a baseline lower bound.
--
-- The module-pattern contract is Option D from design §13.5.3, NOT a
-- syntactic carve-out. The rule is uniform across all bindings:
--
--   * `local M = {}` (no annotation): bind α_M = V.var; constrain
--     V.rec({}, false) <: α_M as the baseline. Field-writes accumulate.
--   * `local M --: T = {}` (annotated): bind M to T. Field-writes are
--     checked against T (closed-record write-of-absent-field surfaces).
--   * Any other init (`local M = 7`, `local M = f()`): the existing
--     sub-phase E rules apply unchanged. No expando carve-out.
--
-- Indexed callee rework (was sub-phase C's loud rejection):
--
--   Sub-phase C rejected NODE_FIELD_EXPR / NODE_INDEX_EXPR callees with
--   "lands in sub-phase F." F now synthesizes the callee through the
--   normal indexed-access path and continues with the function-call
--   logic. NODE_METHOD_CALL was already wired in C and continues to use
--   its own dedicated path (the method name is on the node, not a child
--   expression).
--
-- Indexed LHS rework (was sub-phase E's loud rejection):
--
--   Sub-phase E rejected indexed assignment targets. F implements two
--   regimes per Option D:
--   (a) target.tag == NODE_FIELD_EXPR (or NODE_INDEX_EXPR with a literal
--       key) AND target.target is NODE_IDENTIFIER bound to a V.var ⇒
--       module-pattern accumulation: V.rec({k = synth(rhs)}, /*open=*/true)
--       <: α. The `open=true` is load-bearing — it makes the singleton-
--       field record a subtype of any record that contains `k` (a
--       valid lower-bound contribution).
--   (b) Same target shape, but the binding is a non-variable type:
--       v4's index reducer is queried at write-of-field. constrain
--       (synth(rhs), V.index(T, k)) — surfaces write-of-absent-field-
--       on-closed-record cleanly.
--   (c) Otherwise (chained field paths, indexed-LHS on a non-identifier
--       target): reject loudly with a clear message; this is a real
--       limitation, not a sub-phase punt — chained-path module-pattern
--       accumulation requires tracking field-path-roots through the AST,
--       which is mechanical but additive. The design doc does not call
--       for it; if a real codebase needs it, it lands as a separate
--       contribution rather than a quiet expansion of F.
--
-- Varargs polish (§8.2):
--
--   NODE_VARARG_EXPR was implemented in B as "synthesize env.vararg".
--   Sub-phase F revisits the spread/non-spread discipline. The vararg
--   node itself always synthesizes to the spread-element type (or the
--   tuple shape depending on the annotation). The enclosing-node
--   contexts that should spread it are:
--     * last-position argument of a call (`f(..., x, ...)`).
--     * last-position return expression (`return ..., x, ...`).
--     * last-position element of a table constructor (table literals
--       are not in F's scope beyond the empty case).
--   Non-last positions collapse to a scalar (slot 1 of the spread, or
--   the spread-element type for unannotated vararg).
--
--   NODE_CALL_EXPR's argument handling and NODE_RETURN_STMT's return
--   handling absorb this. NODE_VARARG_EXPR itself remains scalar by
--   default; the *caller* (the enclosing context) decides whether to
--   spread by special-casing a vararg expression in last position.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua and
-- statements.lua (cross-module --:: alias resolution limitation
-- documented in walker/README.md).

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local D       = require("lib.type.static-v4.walker.diag")
local defs    = require("lib.type.static.defs")
local subtype = require("lib.type.static-v4.subtype")
local index_mod = require("lib.type.static-v4.index")

local _types  = require("lib.type.static-v4.types")
local _ = _types

-- Pre-interned `nil` singleton with a runtime-guarded local so the
-- typechecker sees it as non-nil at use sites. (NIL_TYPE /  V.prim("nil")
-- carry `V4Type | nil` return types due to the prim cache lookup branch.)
local NIL_TYPE = V.prim("nil")
if NIL_TYPE == nil then error("v4 nil prim unexpectedly nil") end

local M = {}

local function walker_mod()
	return require("lib.type.static-v4.walker.walker")
end

-- ── helpers ───────────────────────────────────────────────────────────────

-- Lua multi-return shape detector, shared with statements.lua's tuple
-- distribution. Returns the positional-slot list or nil.
local function as_tuple(ty)
	if ty == nil or type(ty) ~= "table" then return nil end
	if ty.tag ~= "rec" then return nil end
	local fields = ty.fields
	if type(fields) ~= "table" then return nil end
	if fields["1"] == nil then return nil end
	local slots = {}
	local i = 1
	while true do
		local v = fields[tostring(i)]
		if v == nil then break end
		slots[i] = v
		i = i + 1
	end
	if (i - 1) < 2 then return nil end
	return slots
end

-- ── NODE_FIELD_EXPR ───────────────────────────────────────────────────────
--
-- §3.6: synthesize the target, then V.index(target, V.literal("string", k)).
-- The key is a bare Lua string on the decoded node (matches the parser's
-- NAME-after-DOT shape). Failures from V.index become diagnostics.

local function synth_field(node, env, solver)
	local W = walker_mod()
	local target_ty, env2, err = W.walk_synth(node.target, env, solver)
	if err ~= nil then return nil, env2, err end
	if target_ty == nil then
		return nil, env2, D.emit(env2, D.E_INTERNAL,
			"field: target has no synthesized type")
	end
	local key = node.key
	if type(key) ~= "string" then
		return nil, env2, D.emit(env2, D.E_INTERNAL,
			"field: key must be a string (got " .. type(key) .. ")")
	end
	local result, ierr = index_mod.index(target_ty, V.literal("string", key))
	if ierr ~= nil then
		return nil, env2, D.emit(env2, D.E_FIELD_MISSING,
			"field: " .. ierr, { origin_type = target_ty })
	end
	return result, env2, nil
end

-- ── NODE_INDEX_EXPR ───────────────────────────────────────────────────────
--
-- §3.6: synthesize target AND key, then V.index(target, key_ty). The key
-- expression is a full Node (not a bare string). v4's index handles the
-- key-type cases (literal string, primitive string, union of literals,
-- and rejects unbound type-variable keys per its own contract).

local function synth_index(node, env, solver)
	local W = walker_mod()
	local target_ty, env2, err = W.walk_synth(node.target, env, solver)
	if err ~= nil then return nil, env2, err end
	if target_ty == nil then
		return nil, env2, D.emit(env2, D.E_INTERNAL,
			"index: target has no synthesized type")
	end
	local key_ty, env3, kerr = W.walk_synth(node.key, env2, solver)
	if kerr ~= nil then return nil, env3, kerr end
	if key_ty == nil then
		return nil, env3, D.emit(env3, D.E_INTERNAL,
			"index: key has no synthesized type")
	end
	local result, ierr = index_mod.index(target_ty, key_ty)
	if ierr ~= nil then
		return nil, env3, D.emit(env3, D.E_FIELD_MISSING,
			"index: " .. ierr, { origin_type = target_ty })
	end
	return result, env3, nil
end

-- ── NODE_TABLE_EXPR ───────────────────────────────────────────────────────
--
-- §3.10: build a `V.rec` from the literal's fields.
--
-- Field-kind cases (decoder emits one of three `field_kind` values):
--
--   * `"positional"` — `{1, 2, 3}` — each value goes into a string-keyed
--     positional slot `"1"`, `"2"`, ... (matches v4's tuple convention used
--     throughout the walker — see functions.lua's multi-return packing).
--   * `"named"` — `{a = 1}` — bare-string `key`; closed-record named field.
--   * `"computed"` — `{[expr] = v}` — `key` is itself a node. If the key
--     synthesizes to a string-literal or integer-literal type, it folds
--     into a named (string) or positional-by-key (integer) field. Otherwise
--     all such fields are joined into an `indexer(K, V)` on the record.
--
-- Mixed shapes are supported: positional + named + computed in any order.
-- Per Lua semantics, positional indices are derived from textual order of
-- positional fields, NOT from the field's overall position in the literal
-- (i.e. `{a = "x", 1, 2}` assigns 1 → "1" and 2 → "2").
--
-- Duplicate keys: take the last. Lua's runtime semantics: `{a = 1, a = 2}`
-- yields `{a = 2}`. The walker mirrors this (deterministic, matches user
-- intuition). Erroring would be a stricter discipline than Lua itself and
-- the inputs are unambiguous, so the last-wins rule is principled.
--
-- Nil-key check: a computed key whose type is `nil` (or a literal nil) is
-- a Lua runtime error. The walker rejects at typecheck time when the key
-- is a literal nil / primitive nil. Unions that *include* nil are also
-- rejected — Lua would only fail at runtime for the nil-valued branch but
-- v4 is "safer than Lua at runtime"; surfacing the unsoundness at the
-- literal site is the principled choice.
--
-- Multi-return spread: the trailing positional value, if it synthesizes
-- to a tuple-shaped `V.rec` (positional slots `"1"`, `"2"`, ...), spreads
-- its slots into successive positional indices. This mirrors call-arg
-- spread (synth_call above) and Lua's last-position rule.
--
-- CHECK mode: if `expected` is a closed `V.rec` (no indexer), each named/
-- computed-literal-string field CHECKs against the expected field's type;
-- positional slots CHECK against the expected positional slot's type; extra
-- fields error via closed-rec discipline. If `expected` has an indexer or
-- is open, CHECK falls back to SYNTHESIZE-then-constrain (the walker.lua
-- default rule already does this; the CHECK handler simply forwards in
-- that case by returning nil so the walker dispatches synth+constrain).

-- Computed-key classification result. Returned as a single record (rather
-- than five positional values) so the typechecker can carry per-kind
-- presence guarantees through the `kind` discriminant — when `kind` is
-- "string_literal" the caller knows `string_key` is present, etc. Each
-- field is independently typed; callers branch on `kind` and dispatch.
--
-- Shape:
--   { kind: "string_literal" | "integer_literal" | "indexer" | "error",
--     string_key: string | nil,    -- present iff kind == "string_literal"
--     integer_key: number | nil,   -- present iff kind == "integer_literal"
--     key_ty: V4Type,              -- the synthesized key type
--     env: WalkerEnv,              -- post-walk env
--     err: Diagnostic | nil }      -- non-nil iff kind == "error"

local function classify_computed_key(key_node, env, solver)
	local W = walker_mod()
	local kty, env2, kerr = W.walk_synth(key_node, env, solver)
	local nil_kty = V.prim("nil")
	if nil_kty == nil then nil_kty = NIL_TYPE end
	if kerr ~= nil then
		return { kind = "error", key_ty = nil_kty, env = env2, err = kerr }
	end
	if kty == nil then
		return { kind = "error", key_ty = nil_kty, env = env2,
			err = D.emit(env2, D.E_INTERNAL,
				"table: computed key has no synthesized type") }
	end
	-- Nil-key check.
	if kty.tag == "prim" and kty.name == "nil" then
		return { kind = "error", key_ty = kty, env = env2,
			err = D.emit(env2, D.E_TYPE_MISMATCH,
				"table: computed key has type nil (Lua runtime error)",
				{ origin_type = kty }) }
	end
	if kty.tag == "literal" and kty.base == "nil" then
		return { kind = "error", key_ty = kty, env = env2,
			err = D.emit(env2, D.E_TYPE_MISMATCH,
				"table: computed key is literal nil (Lua runtime error)",
				{ origin_type = kty }) }
	end
	if kty.tag == "union" then
		for _, m in ipairs(kty.members) do
			if (m.tag == "prim" and m.name == "nil")
				or (m.tag == "literal" and m.base == "nil") then
				return { kind = "error", key_ty = kty, env = env2,
					err = D.emit(env2, D.E_TYPE_MISMATCH,
						"table: computed key type includes nil",
						{ origin_type = kty }) }
			end
		end
	end
	if kty.tag == "literal" and kty.base == "string"
		and type(kty.value) == "string" then
		return { kind = "string_literal", string_key = kty.value,
			key_ty = kty, env = env2 }
	end
	if kty.tag == "literal" and kty.base == "integer"
		and type(kty.value) == "number" then
		return { kind = "integer_literal", integer_key = kty.value,
			key_ty = kty, env = env2 }
	end
	return { kind = "indexer", key_ty = kty, env = env2 }
end

-- Build a union type, collapsing trivial cases. Single-member unions
-- collapse to the bare type (v4 builds 1-element unions deliberately;
-- a record's indexer should carry the underlying type, not a union
-- wrapper, where possible — keeps downstream `V.index` predictable).
local function join_types(types)
	if #types == 0 then return nil end
	if #types == 1 then return types[1] end
	-- De-duplicate by table identity (literals are interned, prims are interned).
	local seen, dedup = {}, {}
	for _, t in ipairs(types) do
		if not seen[t] then
			seen[t] = true
			dedup[#dedup + 1] = t
		end
	end
	if #dedup == 1 then return dedup[1] end
	return V.union(dedup)
end

-- Core SYNTHESIZE: walk fields, assemble (named_map, indexer_or_nil).
-- Returns (rec_ty, env, err). `env` is the post-walk env (each value is
-- synthesized, which may extend bindings via side-effects on the solver,
-- though typical literal expressions do not modify the env).
local function synth_table_impl(node, env, solver)
	local W = walker_mod()
	local fields = node.fields
	if fields == nil or #fields == 0 then
		return V.rec({}, false, nil), env, nil
	end

	-- Named slots accumulate by key (last-wins on duplicate).
	local named = {} --[[: { [string]: V4Type } ]]
	-- Positional slots accumulate by integer index, then projected to
	-- string keys at the end (v4's tuple-rec convention).
	local positional = {} --[[: { [integer]: V4Type } ]]
	-- Computed-with-non-literal-key contributions accumulate as
	-- (key_types, value_types) lists that fold into one indexer at the
	-- end.
	local ix_keys, ix_vals = {}, {}

	local pos_index = 0
	local n_fields = #fields
	for i, f in ipairs(fields) do
		local is_last = (i == n_fields)
		local fk = f.field_kind
		if fk == "positional" then
			local vty, env2, verr = W.walk_synth(f.value, env, solver)
			env = env2
			if verr ~= nil then return nil, env, verr end
			if vty == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"table: positional value has no synthesized type")
			end
			-- Last-position multi-return spread.
			if is_last then
				local tup = as_tuple(vty)
				if tup ~= nil then
					for _, slot in ipairs(tup) do
						pos_index = pos_index + 1
						positional[pos_index] = slot
					end
				else
					pos_index = pos_index + 1
					positional[pos_index] = vty
				end
			else
				-- Non-last collapses multi-return to slot 1.
				local tup = as_tuple(vty)
				if tup ~= nil then
					pos_index = pos_index + 1
					positional[pos_index] = tup[1]
				else
					pos_index = pos_index + 1
					positional[pos_index] = vty
				end
			end
		elseif fk == "named" then
			local key = f.key
			if type(key) ~= "string" then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"table: named field key must be a string (got " .. type(key) .. ")")
			end
			local vty, env2, verr = W.walk_synth(f.value, env, solver)
			env = env2
			if verr ~= nil then return nil, env, verr end
			if vty == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"table: named value has no synthesized type")
			end
			-- Last-wins on duplicate (documented above).
			named[key] = vty
		elseif fk == "computed" then
			local cls = classify_computed_key(f.key, env, solver)
			env = cls.env
			if cls.err ~= nil then return nil, env, cls.err end
			local vty, env2, verr = W.walk_synth(f.value, env, solver)
			env = env2
			if verr ~= nil then return nil, env, verr end
			if vty == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"table: computed value has no synthesized type")
			end
			local sk = cls.string_key
			local ik = cls.integer_key
			if cls.kind == "string_literal" and type(sk) == "string" then
				named[sk] = vty
			elseif cls.kind == "integer_literal" and type(ik) == "number" then
				local idx = math.floor(ik)
				if idx >= 1 then
					positional[idx] = vty
					if idx > pos_index then pos_index = idx end
				else
					-- Non-positive integer key — fold into the indexer.
					ix_keys[#ix_keys + 1] = cls.key_ty
					ix_vals[#ix_vals + 1] = vty
				end
			else
				ix_keys[#ix_keys + 1] = cls.key_ty
				ix_vals[#ix_vals + 1] = vty
			end
		else
			return nil, env, D.emit(env, D.E_INTERNAL,
				"table: unknown field_kind '" .. tostring(fk) .. "'")
		end
	end

	-- Project positional indices into string-keyed slots, last-wins
	-- against a same-key named entry. (E.g. `{[1]="a", "b"}` — the
	-- positional "b" textually came second so it wins.)
	for idx, vty in pairs(positional) do
		named[tostring(idx)] = vty
	end

	local indexer = nil
	if #ix_keys > 0 then
		local k_union = join_types(ix_keys)
		local v_union = join_types(ix_vals)
		if k_union == nil or v_union == nil then
			return nil, env, D.emit(env, D.E_INTERNAL,
				"table: indexer accumulation produced empty type lists")
		end
		indexer = V.indexer(k_union, v_union)
	end
	-- A record carrying an indexer is structurally not "closed" in the
	-- row-extension sense: any key matching the indexer is permitted.
	-- The `open` flag stays false (closed for excess fields outside the
	-- indexer's key type) — matches the type-system reference's
	-- `{[K]: V}` shape, which has no extra-field row variable.
	return V.rec(named, false, indexer), env, nil
end

local function synth_table(node, env, solver)
	return synth_table_impl(node, env, solver)
end

-- ── NODE_TABLE_EXPR CHECK ─────────────────────────────────────────────────
--
-- §3.10 CHECK: if expected is a closed `V.rec` with no indexer, check each
-- field's value against the expected field type directly (better
-- diagnostics than synth-then-constrain, no row variable invented). Any
-- field present in the literal but absent in expected fails via closed-rec
-- discipline (a missing-field error pointing at the literal's field).
-- Extra-strict cases (expected open, expected has an indexer, expected
-- carries a non-rec shape such as a union or var) fall back to synth +
-- constrain so the standard subtype machinery handles them.

local function expected_is_simple_closed_rec(expected)
	return expected ~= nil
		and expected.tag == "rec"
		and expected.open == false
		and expected.indexer == nil
end

local function check_table(node, env, solver, expected)
	local W = walker_mod()
	if not expected_is_simple_closed_rec(expected) then
		-- Default rule: synth then constrain. Replicated here rather than
		-- delegated so the CHECK handler returns the right shape (env, err)
		-- without re-entering walk_check (which would recurse into this
		-- same handler).
		local ty, env2, err = synth_table_impl(node, env, solver)
		if err ~= nil then return env2, err end
		if ty == nil then
			return env2, D.emit(env2, D.E_INTERNAL,
				"table: CHECK fallback got nil synthesized type")
		end
		subtype.constrain(solver, ty, expected)
		if solver.error ~= nil then
			return env2, D.from_solver(env2, D.E_TYPE_MISMATCH,
				"table: literal does not satisfy expected record",
				solver, ty, expected)
		end
		return env2, nil
	end

	-- Closed expected record. CHECK each field's value against the
	-- corresponding expected field type. Extra fields in the literal that
	-- are absent in expected are rejected. Missing required fields are
	-- detected after walking.
	local fields = node.fields or ({})
	local exp_fields = expected.fields or ({})
	local saw = {} --[[: { [string]: boolean } ]]

	local pos_index = 0
	local n_fields = #fields
	for i, f in ipairs(fields) do
		local fk = f.field_kind
		local is_last = (i == n_fields)
		-- Determine target key (string) or fall through to per-field synth
		-- and constrain if the key doesn't fold to a known slot.
		local target_keys --[[: string[] | nil ]] = nil

		if fk == "positional" then
			-- Spread on last: the value's tuple slots populate successive
			-- positional indices. We handle the spread by re-synthesizing
			-- the value then per-slot CHECKing — but the cleaner shape is
			-- a single CHECK against the expected positional slot if the
			-- value is non-tuple. For tuple-multi-return on the last
			-- field, fall back to synth+constrain (the structural form is
			-- already correct; constraining the full rec preserves the
			-- spread semantics).
			local vty, env2, verr = W.walk_synth(f.value, env, solver)
			env = env2
			if verr ~= nil then return env, verr end
			if vty == nil then
				return env, D.emit(env, D.E_INTERNAL,
					"table CHECK: positional value has no synthesized type")
			end
			local tup = (is_last) and as_tuple(vty) or nil
			if tup ~= nil then
				for _, slot in ipairs(tup) do
					pos_index = pos_index + 1
					local k = tostring(pos_index)
					local exp_ty = exp_fields[k]
					if exp_ty == nil then
						return env, D.emit(env, D.E_FIELD_MISSING,
							"table CHECK: extra positional field '" .. k ..
							"' not present in expected record",
							{ origin_type = expected })
					end
					subtype.constrain(solver, slot, exp_ty)
					if solver.error ~= nil then
						return env, D.from_solver(env, D.E_TYPE_MISMATCH,
							"table CHECK: positional field '" .. k .. "' type mismatch",
							solver, slot, exp_ty)
					end
					saw[k] = true
				end
			else
				-- Non-last tuple collapses to slot 1.
				local slot_ty = vty
				if not is_last then
					local nlt = as_tuple(vty)
					if nlt ~= nil then slot_ty = nlt[1] end
				end
				pos_index = pos_index + 1
				local k = tostring(pos_index)
				local exp_ty = exp_fields[k]
				if exp_ty == nil then
					return env, D.emit(env, D.E_FIELD_MISSING,
						"table CHECK: extra positional field '" .. k ..
						"' not present in expected record",
						{ origin_type = expected })
				end
				subtype.constrain(solver, slot_ty, exp_ty)
				if solver.error ~= nil then
					return env, D.from_solver(env, D.E_TYPE_MISMATCH,
						"table CHECK: positional field '" .. k .. "' type mismatch",
						solver, slot_ty, exp_ty)
				end
				saw[k] = true
			end
			target_keys = nil -- already handled
		elseif fk == "named" then
			local key = f.key
			if type(key) ~= "string" then
				return env, D.emit(env, D.E_INTERNAL,
					"table CHECK: named field key must be a string")
			end
			target_keys = { key }
		elseif fk == "computed" then
			local cls = classify_computed_key(f.key, env, solver)
			env = cls.env
			if cls.err ~= nil then return env, cls.err end
			local sk = cls.string_key
			local ik = cls.integer_key
			if cls.kind == "string_literal" and type(sk) == "string" then
				target_keys = { sk }
			elseif cls.kind == "integer_literal" and type(ik) == "number" then
				target_keys = { tostring(ik) }
			else
				-- Non-literal computed key against a closed-rec expected
				-- with no indexer: cannot statically discharge. Fall back
				-- to synth+constrain for the rest of the literal.
				local ty, env2, err = synth_table_impl(node, env, solver)
				if err ~= nil then return env2, err end
				if ty == nil then
					return env2, D.emit(env2, D.E_INTERNAL,
						"table CHECK: fallback got nil ty")
				end
				subtype.constrain(solver, ty, expected)
				if solver.error ~= nil then
					return env2, D.from_solver(env2, D.E_TYPE_MISMATCH,
						"table CHECK: literal does not satisfy expected record",
						solver, ty, expected)
				end
				return env2, nil
			end
		else
			return env, D.emit(env, D.E_INTERNAL,
				"table CHECK: unknown field_kind '" .. tostring(fk) .. "'")
		end

		if target_keys ~= nil then
			for _, k in ipairs(target_keys) do
				local exp_ty = exp_fields[k]
				if exp_ty == nil then
					return env, D.emit(env, D.E_FIELD_MISSING,
						"table CHECK: field '" .. k ..
						"' not present in expected record",
						{ origin_type = expected })
				end
				-- CHECK the value directly against the expected field type.
				local env2, err = W.walk_check(f.value, env, solver, exp_ty)
				env = env2
				if err ~= nil then return env, err end
				saw[k] = true
			end
		end
	end

	-- Missing-required-field check: every key in expected must have been
	-- written. (Per design §3.10 closed-record CHECK semantics: the
	-- literal must satisfy the closed shape exactly.)
	for k in pairs(exp_fields) do
		if not saw[k] then
			return env, D.emit(env, D.E_FIELD_MISSING,
				"table CHECK: missing required field '" .. k ..
				"' for expected record",
				{ origin_type = expected })
		end
	end
	return env, nil
end

-- ── shared call-application logic ─────────────────────────────────────────
--
-- Copied from sub-phase C (functions.lua) intentionally rather than
-- factored out — `apply_arrow` is local to functions.lua and the
-- design's no-coupling rule means we keep two callers each direct. The
-- shape is small (≤30 lines); duplication is cheaper than the export.

local function maybe_instantiate(t)
	if t.tag ~= "forall" then return t end
	return require("lib.type.static-v4.forall").instantiate(t)
end

local function add_effects(env, effects)
	if effects == nil or next(effects) == nil then return env end
	for name in pairs(effects) do
		env = E.add_effect(env, name)
	end
	return env
end

local function apply_arrow(callee_ty, arg_types, arg_count, env, solver)
	local arrow = maybe_instantiate(callee_ty)
	if arrow.tag ~= "fn" then
		return nil, env, D.emit(env, D.E_CALL_NON_FN,
			"call: callee has non-function type " .. V.show(callee_ty),
			{ origin_type = callee_ty })
	end
	local params = arrow.params
	local param_count = 0
	for _ in pairs(params) do param_count = param_count + 1 end
	if param_count ~= arg_count then
		return nil, env, D.emit(env, D.E_CALL_ARITY,
			"call: arity mismatch — expected " .. tostring(param_count) ..
			" argument(s), got " .. tostring(arg_count))
	end
	for i = 1, param_count do
		subtype.constrain(solver, arg_types[i], params[i])
		if solver.error ~= nil then
			return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
				"call: argument " .. tostring(i) .. " type mismatch",
				solver, arg_types[i], params[i])
		end
	end
	env = add_effects(env, arrow.effects)
	return arrow.ret, env, nil
end

-- ── NODE_CALL_EXPR (overrides C) ──────────────────────────────────────────
--
-- F resolves indexed callees that C rejected. The callee may be any
-- expression that synthesizes to a function type (forall or fn). Indexed
-- access on the callee path is the common case (`obj.method(...)`,
-- `tbl[k](...)`); both go through the standard SYNTHESIZE recursion.
--
-- Argument vararg spread (§8.2): if the LAST argument is NODE_VARARG_EXPR,
-- and env.vararg is a tuple-shaped V.rec, spread its slots into the arg
-- list. Otherwise the vararg contributes a single scalar argument.
-- A vararg in NON-last position collapses to its scalar form
-- (matches Lua's "..." semantics — non-last `...` yields its first
-- value).

local function synth_call(node, env, solver)
	local W = walker_mod()
	local callee_ty, env2, err = W.walk_synth(node.callee, env, solver)
	if err ~= nil then return nil, env2, err end
	if callee_ty == nil then
		return nil, env2, D.emit(env2, D.E_INTERNAL,
			"call: callee has no synthesized type")
	end
	local args = node.args or ({})
	local n_args = #args
	local arg_types = {}
	local arg_count = 0
	for i = 1, n_args do
		local arg = args[i]
		local is_last = (i == n_args)
		local is_vararg = (arg.tag == defs.NODE_VARARG_EXPR)
		local ty, env3, aerr = W.walk_synth(arg, env2, solver)
		env2 = env3
		if aerr ~= nil then return nil, env2, aerr end
		if ty == nil then
			return nil, env2, D.emit(env2, D.E_INTERNAL,
				"call: argument " .. tostring(i) .. " has no synthesized type")
		end
		if is_vararg and is_last then
			-- Spread: if env.vararg is a tuple-shaped rec, spread its
			-- positional slots. Otherwise contribute a single arg.
			local tup = as_tuple(ty)
			if tup ~= nil then
				for _, slot in ipairs(tup) do
					arg_count = arg_count + 1
					arg_types[arg_count] = slot
				end
			else
				arg_count = arg_count + 1
				arg_types[arg_count] = ty
			end
		elseif is_vararg then
			-- Non-last vararg collapses to its first slot or scalar.
			local tup = as_tuple(ty)
			if tup ~= nil then
				arg_count = arg_count + 1
				arg_types[arg_count] = tup[1]
			else
				arg_count = arg_count + 1
				arg_types[arg_count] = ty
			end
		else
			arg_count = arg_count + 1
			arg_types[arg_count] = ty
		end
	end
	return apply_arrow(callee_ty, arg_types, arg_count, env2, solver)
end

-- ── NODE_LOCAL_STMT (overrides E: module-pattern trigger) ────────────────
--
-- §13.5.3 contract: `local M = {}` (no annotation, init is an empty table
-- literal) binds α_M = V.var; constrain V.rec({}, false) <: α_M as the
-- baseline lower bound; bind M to α_M.
--
-- All OTHER LOCAL_STMT shapes defer to E's existing handler. We re-register
-- a thin wrapper that detects the module-pattern shape and dispatches.
--
-- The detection is restricted to the form `local M = {}`:
--   * exactly one name with no annotation,
--   * exactly one initialiser expression,
--   * the initialiser is a NODE_TABLE_EXPR with no fields.
-- Anything else falls through to the existing local handler.
--
-- This is NOT a syntactic carve-out: per §13.5.4, it follows directly
-- from Option D's principled formulation. The trigger is "empty table
-- on initialisation" — not "name starts with capital M", not "top-level
-- only", and not "function/namespace pattern detected." Any binding to
-- an empty table follows the same rule.

local existing_local_handler -- captured at register-time

-- Detect the syntactic shape `local M [--: T] = {}` (single binding, init
-- is an empty NODE_TABLE_EXPR). Returns `(name, ann_or_nil)` if matched,
-- or `nil`.
local function detect_empty_table_init(node)
	local names = node.names
	local exprs = node.exprs
	if names == nil or exprs == nil then return nil end
	if #names ~= 1 or #exprs ~= 1 then return nil end
	local init = exprs[1]
	if init.tag ~= defs.NODE_TABLE_EXPR then return nil end
	if init.fields ~= nil and #init.fields > 0 then return nil end
	return names[1].name, names[1].ann
end

local function synth_local_with_module(node, env, solver)
	local name, ann = detect_empty_table_init(node)
	if name == nil then
		return existing_local_handler(node, env, solver)
	end
	if ann ~= nil then
		-- Annotated case (design §13.5.3): bind M to T directly. The
		-- empty-table init is treated as "M starts as the declared T"
		-- — subsequent field-writes are checked against T (via the
		-- non-variable branch of emit_indexed_write). Per the design,
		-- the init expression's type is NOT checked against the
		-- annotation here: the annotation describes the *final* shape
		-- the user is building up, not the initialiser. `{}` is the
		-- canonical "I will fill this in" idiom.
		local env2 = E.bind(env, name, ann)
		return nil, env2, nil
	end
	-- Unannotated case: allocate accumulator var.
	local alpha = V.var(name)
	-- Baseline lower bound: an empty closed record. This ensures reads
	-- against α see at least an empty record's worth of shape.
	subtype.constrain(solver, V.rec({}, false, nil), alpha)
	if solver.error ~= nil then
		return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
			"local (module pattern): baseline constraint failed",
			solver, V.rec({}, false, nil), alpha)
	end
	local env2 = E.bind(env, name, alpha)
	return nil, env2, nil
end

-- ── NODE_ASSIGN_STMT (overrides E: indexed-LHS + module accumulation) ────
--
-- E rejected NODE_FIELD_EXPR / NODE_INDEX_EXPR targets loudly. F implements
-- them per the Option D contract above. Non-indexed targets fall through to
-- E's existing handler.
--
-- The two regimes (variable-bound LHS-base vs concrete-typed LHS-base) are
-- selected by examining the binding's tag. A V.var (.tag == "var") triggers
-- accumulation; anything else triggers v4's index-reducer check.

local existing_assign_handler -- captured at register-time

local function synth_assign_with_field(node, env, solver)
	local W = walker_mod()
	local targets = node.targets or ({})
	local exprs = node.exprs or ({})
	-- If no indexed targets, defer to E's handler unchanged.
	local has_indexed = false
	for _, t in ipairs(targets) do
		if t.tag == defs.NODE_FIELD_EXPR or t.tag == defs.NODE_INDEX_EXPR then
			has_indexed = true
			break
		end
	end
	if not has_indexed then
		return existing_assign_handler(node, env, solver)
	end
	-- For sub-phase F we support either ALL indexed targets or the mixed
	-- case via per-target dispatch. Multi-assign with mixed shapes is
	-- legal Lua but unusual; per-target dispatch keeps the implementation
	-- straightforward.
	--
	-- Synthesize RHS in order, applying multi-return spread/truncate as
	-- in E's distribute_rhs. We replicate that here rather than importing
	-- the helper to keep modules decoupled.
	local rhs_types = {}
	for i, e in ipairs(exprs) do
		local ty, env2, err = W.walk_synth(e, env, solver)
		env = env2
		if err ~= nil then return nil, env, err end
		if ty == nil then
			return nil, env, D.emit(env, D.E_INTERNAL,
				"assign: RHS expression " .. tostring(i) .. " has no synthesized type")
		end
		rhs_types[i] = ty
	end
	local lhs_count = #targets
	local n_rhs = #rhs_types
	local distributed = {}
	if n_rhs == 0 then
		for i = 1, lhs_count do distributed[i] = NIL_TYPE end
	else
		for i = 1, n_rhs - 1 do
			if i <= lhs_count then
				local t = rhs_types[i]
				local tup = as_tuple(t)
				distributed[i] = (tup ~= nil) and tup[1] or t
			end
		end
		local last = rhs_types[n_rhs]
		local last_tup = as_tuple(last)
		if last_tup ~= nil then
			local j = 1
			for i = n_rhs, lhs_count do
				distributed[i] = last_tup[j] or NIL_TYPE
				j = j + 1
			end
		else
			if n_rhs <= lhs_count then
				distributed[n_rhs] = last
			end
		end
		for i = 1, lhs_count do
			if distributed[i] == nil then distributed[i] = NIL_TYPE end
		end
	end
	for i, t in ipairs(targets) do
		local rhs_slot = NIL_TYPE
		local rhs_slot_raw = distributed[i]
		if rhs_slot_raw ~= nil and type(rhs_slot_raw) == "table" and rhs_slot_raw.tag ~= nil then
			rhs_slot = rhs_slot_raw
		end
		if t.tag == defs.NODE_FIELD_EXPR or t.tag == defs.NODE_INDEX_EXPR then
			-- Inline indexed-LHS handling. The two regimes (var-bound base
			-- → module accumulation; concrete-typed base → v4 index reducer
			-- check) are selected by the binding's tag.
			local base = t.target
			if base == nil or base.tag ~= defs.NODE_IDENTIFIER then
				return nil, env, D.emit(env, D.E_UNSUPPORTED_NODE,
					"assign: indexed LHS root must be a simple identifier " ..
					"(chained or computed paths land as a separate contribution if needed)")
			end
			local lhs_name = base.name
			if not E.has(env, lhs_name) then
				return nil, env, D.emit(env, D.E_UNDEFINED_NAME,
					"assign: undefined name '" .. lhs_name .. "'")
			end
			-- Compute the key type. For NODE_FIELD_EXPR the key is a bare
			-- string; for NODE_INDEX_EXPR we synthesize the key expression.
			-- Initialise key_ty to a sentinel so the typechecker sees a
			-- non-nil flow into the use sites below.
			local key_ty = NIL_TYPE
			if t.tag == defs.NODE_FIELD_EXPR then
				local key = t.key
				if type(key) ~= "string" then
					return nil, env, D.emit(env, D.E_INTERNAL,
						"assign: field LHS key must be a string (got " .. type(key) .. ")")
				end
				local lit = V.literal("string", key)
				if lit == nil then
					return nil, env, D.emit(env, D.E_INTERNAL,
						"assign: V.literal returned nil")
				end
				key_ty = lit
			else
				local kty, env_k, kerr = W.walk_synth(t.key, env, solver)
				env = env_k
				if kerr ~= nil then return nil, env, kerr end
				if kty == nil then
					return nil, env, D.emit(env, D.E_INTERNAL,
						"assign: index LHS key has no synthesized type")
				end
				key_ty = kty
			end
			-- Apply the per-regime constraint.
			local binding = env.bindings[lhs_name]
			if binding == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"assign: internal — binding '" .. lhs_name .. "' disappeared")
			end
			if binding.tag == "var" then
				-- Module-pattern accumulation: build a singleton-field open
				-- record and constrain it as a lower bound. `open=true` is
				-- load-bearing — the singleton must subtype any record
				-- containing the field.
				local contribution
				if key_ty.tag == "literal" and key_ty.base == "string" then
					local kv = key_ty.value
					if type(kv) ~= "string" then
						return nil, env, D.emit(env, D.E_INTERNAL,
							"assign: module-pattern key literal is malformed")
					end
					contribution = V.rec({ [kv] = rhs_slot }, true, nil)
				else
					-- Non-literal key on a var-bound target falls back to
					-- indexer accumulation.
					contribution = V.rec({}, true, V.indexer(key_ty, rhs_slot))
				end
				subtype.constrain(solver, contribution, binding)
				if solver.error ~= nil then
					return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
						"assign (module pattern)", solver, contribution, binding)
				end
			else
				-- Concrete-typed LHS: query v4's index reducer. For closed
				-- records lacking the field, V.index errors directly —
				-- that surfaces write-of-absent-field cleanly.
				local field_ty, ierr = index_mod.index(binding, key_ty)
				if ierr ~= nil then
					return nil, env, D.emit(env, D.E_FIELD_MISSING,
						"assign: " .. ierr, { origin_type = binding })
				end
				if field_ty == nil then
					return nil, env, D.emit(env, D.E_INTERNAL,
						"assign: V.index returned nil field type")
				end
				subtype.constrain(solver, rhs_slot, field_ty)
				if solver.error ~= nil then
					return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
						"assign: RHS does not satisfy field type",
						solver, rhs_slot, field_ty)
				end
			end
		elseif t.tag == defs.NODE_IDENTIFIER then
			-- Plain identifier target — fall back to E's logic by inlining
			-- the constraint. (Re-dispatching to the E handler would re-
			-- synthesize RHS expressions; we already have rhs_types.)
			if not E.has(env, t.name) then
				return nil, env, D.emit(env, D.E_UNDEFINED_NAME,
					"assign: undefined name '" .. t.name .. "'")
			end
			local lhs_ty = env.bindings[t.name]
			if lhs_ty == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"assign: internal — binding '" .. t.name .. "' disappeared")
			end
			subtype.constrain(solver, rhs_slot, lhs_ty)
			if solver.error ~= nil then
				return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
					"assign: RHS for '" .. t.name .. "' does not satisfy LHS type",
					solver, rhs_slot, lhs_ty)
			end
		else
			return nil, env, D.emit(env, D.E_UNSUPPORTED_NODE,
				"assign: unsupported LHS shape on target #" .. tostring(i))
		end
	end
	return nil, env, nil
end

-- ── registration ─────────────────────────────────────────────────────────

-- Exposed for sub-phase G (ffi_cdef.lua) to wrap as a fallback. The
-- override pattern relies on capturing the prior handler at register-time;
-- sub-phase G layers on top of F's CALL_EXPR handler the same way F layered
-- on C's. Naming convention mirrors statements.lua's
-- `synth_local_for_subphase_f` / `synth_assign_for_subphase_f`.
M.synth_call_for_subphase_g = synth_call

function M.register(W)
	-- New handlers introduced by F.
	W.register_synth(defs.NODE_FIELD_EXPR, synth_field)
	W.register_synth(defs.NODE_INDEX_EXPR, synth_index)
	W.register_synth(defs.NODE_TABLE_EXPR, synth_table)
	W.register_check(defs.NODE_TABLE_EXPR, check_table)

	-- Override sub-phase C's NODE_CALL_EXPR — F handles indexed callees
	-- via the standard synth path.
	W.register_synth(defs.NODE_CALL_EXPR, synth_call)

	-- Override sub-phase E's NODE_LOCAL_STMT / NODE_ASSIGN_STMT with the
	-- module-pattern + indexed-LHS variants. Existing handlers are
	-- captured so the non-pattern paths defer to them unchanged.
	local statements = require("lib.type.static-v4.walker.statements")
	existing_local_handler = statements.synth_local_for_subphase_f
	existing_assign_handler = statements.synth_assign_for_subphase_f
	W.register_synth(defs.NODE_LOCAL_STMT, synth_local_with_module)
	W.register_synth(defs.NODE_ASSIGN_STMT, synth_assign_with_field)
end

return M
