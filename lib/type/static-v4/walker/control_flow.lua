-- Walker sub-phase D — control flow + flow-sensitive narrowing.
--
-- Per docs/typechecker-ast-walker-design.md §3.12 and §5. This module
-- registers SYNTHESIZE handlers for the seven control-flow statements
-- and centralises guard-pattern analysis (the §5 narrowing rules).
--
-- Decoded node shapes (consumed by handlers)
-- ──────────────────────────────────────────
--
--   NODE_IF_STMT
--     { tag, line, col,
--       clauses:   { { cond: Node, body: Node[] } },  -- if + elseif chain
--       else_body: Node[] | nil }                      -- optional else
--
--   NODE_WHILE_STMT  { tag, line, col, cond: Node, body: Node[] }
--   NODE_REPEAT_STMT { tag, line, col, body: Node[], cond: Node }
--     (Lua semantics: body runs once unconditionally, then cond is tested
--     after the body in a scope that sees body-locals — the cond's
--     positive narrowing flows past the loop into the *outer* scope.)
--
--   NODE_FOR_NUM     { tag, line, col, name: string,
--                      init: Node, stop: Node, step: Node | nil,
--                      body: Node[] }
--     (loop-var is `integer` iff init/stop/step all synthesize to
--     integer-typed values, otherwise `number`.)
--
--   NODE_FOR_IN      { tag, line, col, names: string[],
--                      exprs: Node[], body: Node[] }
--     (the first expr is the iterator; iterator-returned tuple positions
--     bind to the loop names left-to-right. Per §3.12 the iterator's
--     return shape determines the per-name types.)
--
--   NODE_DO_STMT     { tag, line, col, body: Node[] }
--   NODE_BREAK_STMT  { tag, line, col }
--
-- Narrowing model
-- ───────────────
-- A guard expression is decomposed into a *positive narrowing map* and a
-- *negative narrowing map*:
--
--   atoms_pos : { [string]: V4Type }   -- name → atom applied in truthy branch
--   atoms_neg : { [string]: V4Type }   -- name → atom applied in falsy branch
--
-- The truthy branch overlays E.narrow(name, V.inter({E.lookup(name), atom_pos}))
-- per design §5. The falsy branch overlays the same shape with atom_neg.
--
-- Convention: BOTH atoms_pos and atoms_neg are *directly-applied* atoms.
-- The truthy-branch overlay is inter(name, atoms_pos[name]); the
-- falsy-branch overlay is inter(name, atoms_neg[name]). The framework
-- does NOT implicitly V.neg the falsy atom — the recogniser carries the
-- complement explicitly when needed. This symmetric shape is essential
-- for `not p` to be a simple pos/neg swap (and for `and`/`or` to compose
-- cleanly via per-side map ops).
--
-- Recognised guards (mirroring docs/typechecker-reference.md §narrowing
-- and the design doc §5 table):
--
--   `if x then`                       — pos: ~(nil|false_lit), neg: nil|false_lit
--   `if x == nil` / `if x ~= nil`     — pos/neg: V.prim("nil") / V.neg(nil)
--   `if x == "GET"` (and other lits)  — pos: V.literal(kind,val), neg: V.neg(...)
--   `if type(x) == "string"`/...      — pos: V.prim(name), neg: V.neg(V.prim(name))
--   `if x.tag == "leaf"`              — pos: V.rec({tag=lit}, true), neg: V.neg(...)
--
-- Composite (per §5):
--   `if a and b`   pos = pos(a) ⊓ pos(b);  neg = ∅                 (deliberately weak)
--   `if a or b`    pos = pos(a) ⊔ pos(b);  neg = neg(a) ⊓ neg(b)
--   `if not p`     pos := neg(p);  neg := pos(p)
--
-- "⊓" combines two maps element-wise: for a name appearing in both, the
-- atoms intersect via V.inter; for a name in only one, that map's entry
-- carries through. "⊔" combines element-wise: for a name in both, atoms
-- union via V.union; a name in only one is dropped (because the other
-- branch contributes no information about it). The `and`-false and
-- `or`-true semantics follow directly: a false `a and b` could be either
-- side false, so no per-var narrowing is safe; a true `a or b` requires
-- a per-var atom valid in BOTH branches (hence drop singletons).
--
-- Note that "atoms_neg" is a *map* (per name) rather than a single atom:
-- composite guards such as `a or b` can carry different negative atoms
-- for different names. The branch-overlay logic applies one per-name.
--
-- Join at branch end (§5.2)
-- ─────────────────────────
-- Two reconverging branches' narrowing overlays merge into a single
-- post-branch view. For each variable `x`:
--   * if both branches narrowed x → post = V.union({ then_x, else_x })
--   * if only one narrowed x → post = unchanged binding (the other
--     branch's view was the pre-branch view)
--   * if a branch terminated (return / break) → it contributes nothing
--     to the join; the surviving branch's view propagates verbatim.
-- Bindings *introduced* inside a branch do not escape (block-scoped).
--
-- The join produces a narrowed-overlay update on the pre-branch env.
-- The underlying `bindings` map is the pre-branch one.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua
-- (cross-module --:: alias resolution limitation documented in
-- walker/README.md).

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local D       = require("lib.type.static-v4.walker.diag")
local defs    = require("lib.type.static.defs")

local _types  = require("lib.type.static-v4.types")
local _ = _types

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────

local function walker_mod()
	return require("lib.type.static-v4.walker.walker")
end

-- "Truthy" atom for plain `if x then` — everything except nil and false.
-- Built as V.inter({~nil, ~false_lit}) — equivalent to ~(nil | false_lit).
-- We pre-intern at module load to keep allocation off the hot path.
local FALSE_LIT = V.literal("boolean", false)
local TRUTHY_ATOM = V.inter({ V.neg(V.nil_), V.neg(FALSE_LIT) })
local FALSY_ATOM  = V.union({ V.nil_, FALSE_LIT })

-- Map a Lua `type(x)` return-string literal to a v4 atom suitable for
-- intersect-narrowing the variable x. Lua's `type()` returns exactly eight
-- strings; we map each:
--
--   "nil"      → V.prim("nil")
--   "boolean"  → V.prim("boolean")
--   "number"   → V.prim("number")
--   "string"   → V.prim("string")
--   "cdata"    → V.prim("cdata")
--   "table"    → V.rec({}, true, nil)  (the universal open empty record —
--               structurally accepts any table)
--   "function" → V.fn({}, V.top(), nil) (a function type with no specified
--               params and a top return; in the v4 lattice this acts as the
--               canonical "any function" tag for intersect-narrowing — the
--               exact arity/variance shape doesn't matter for narrowing
--               purposes because the intersection with x's current binding
--               picks whichever concrete function type x already had)
--   "thread", "userdata" → nil  (the v4 type system lacks atomic
--               representations for these Lua type-returns. Returning nil
--               signals "no atom available"; the caller treats the guard
--               as recognised-but-non-narrowing rather than crashing.)
--: (string) -> V4Type | nil
local function atom_for_type_string(s)
	-- "table" / "function" need structural representations because v4
	-- has no `prim("table")` / `prim("function")` atoms (the type system
	-- represents tables as records and functions as `fn` constructors).
	if s == "table" then
		return V.rec({}, true, nil)
	end
	if s == "function" then
		return V.fn({}, V.top(), nil)
	end
	-- "thread" / "userdata" — no v4 representation at all. Returning nil
	-- signals the caller to recognise the guard but apply no narrowing.
	if s == "thread" or s == "userdata" then
		return nil
	end
	-- Everything else (the standard primitives nil/boolean/number/string/
	-- cdata, plus the synthetic "integer" the test corpus exercises) maps
	-- directly to a primitive. V.prim errors loudly on unknown names, so
	-- a typo in the source surfaces as a diagnostic rather than silently
	-- accepted.
	return V.prim(s)
end

-- Intersect two narrowing maps element-wise (the `and`-pos and `or`-neg
-- combiner). Returns a fresh map; inputs untouched.
local function map_inter(m1, m2)
	local r = {}
	for k, v in pairs(m1) do r[k] = v end
	for k, v in pairs(m2) do
		local prev = r[k]
		if prev == nil then
			r[k] = v
		else
			r[k] = V.inter({ prev, v })
		end
	end
	return r
end

-- Union two narrowing maps. Only names present in BOTH maps survive —
-- a name in only one carries no actionable information for the union
-- branch (the other side could be anything).
local function map_union(m1, m2)
	local r = {}
	for k, v in pairs(m1) do
		local other = m2[k]
		if other ~= nil then
			r[k] = V.union({ v, other })
		end
	end
	return r
end

-- ── guard analysis ────────────────────────────────────────────────────────
--
-- analyze_guard(node, env, solver) returns
--   (atoms_pos, atoms_neg, env_after, err)
--
-- atoms_pos / atoms_neg are name → V4Type maps. env_after is the env
-- after walking the guard's operands (for synth side-effects like
-- arity-checks on `type(x)`). On err, the caller propagates without
-- applying narrowing.
--
-- The analyzer pattern-matches recognised guard shapes BEFORE attempting
-- a generic synth of the whole node. Generic synth is used only as a
-- last resort (the "unrecognised guard" fallthrough → no narrowing).
-- Per the prompt: no TODO for "we'll handle this guard later" — the
-- semantics for an unrecognised guard is well-defined as "no narrowing
-- applies", not as a deferred case.

-- Try to interpret a node as an identifier. Returns the name or nil.
local function ident_name(node)
	if node.tag == defs.NODE_IDENTIFIER then return node.name end
	return nil
end

-- Try to interpret a node as a literal. Returns (kind_str, value) or nil.
-- kind_str is one of "string","integer","number","boolean","nil".
local function lit_payload(node)
	if node.tag ~= defs.NODE_LITERAL then return nil end
	local k = node.lit_kind
	if k == defs.LIT_STRING then return "string", node.value end
	if k == defs.LIT_INTEGER then return "integer", node.value end
	if k == defs.LIT_NUMBER then return "number", node.value end
	if k == defs.LIT_BOOLEAN then return "boolean", node.value end
	if k == defs.LIT_NIL then return "nil", nil end
	return nil
end

-- Try to interpret a node as `type(x)` for some identifier x. Returns x's
-- name, or nil. We accept only the exact shape: a NODE_CALL_EXPR whose
-- callee is the identifier `type` and whose single argument is an
-- identifier.
local function type_of_ident(node)
	if node.tag ~= defs.NODE_CALL_EXPR then return nil end
	if ident_name(node.callee) ~= "type" then return nil end
	local args = node.args
	if args == nil or #args ~= 1 then return nil end
	return ident_name(args[1])
end

-- Try to interpret a node as `x.k` for some identifier x and string key k.
-- Returns (x_name, key) or nil. NODE_FIELD_EXPR is sub-phase F territory,
-- but pattern-matching it here for the field-discriminant narrowing case
-- is *not* a synth (we do not call the field handler) — we read the
-- decoded node shape directly. The narrowing emits an open-record atom
-- per the §5 table; no field-lookup is performed.
local function field_of_ident(node)
	if node.tag ~= defs.NODE_FIELD_EXPR then return nil end
	local x = ident_name(node.target)
	if x == nil then return nil end
	if type(node.key) ~= "string" then return nil end
	return x, node.key
end

-- Forward declaration so unary `not` can recurse.
local analyze_guard

-- Walk a node in SYNTHESIZE mode, discarding its type. Used to thread
-- synth side-effects (identifier lookup, etc.) through the env without
-- treating the result as a narrowing input.
local function side_effect_walk(node, env, solver)
	local _ty, env2, err = walker_mod().walk_synth(node, env, solver)
	return env2, err
end

-- ── recogniser primitives ─────────────────────────────────────────────────

-- Handle `x` as a bare-identifier guard. Truthy narrowing: x ≠ nil and
-- x ≠ false. Negative narrowing: x is nil or false (atom = ~truthy,
-- which the caller flips via V.neg).
local function recognise_identifier_guard(node, env, solver)
	if node.tag ~= defs.NODE_IDENTIFIER then return nil end
	local name = node.name
	if type(name) ~= "string" then return nil end
	local env2, err = side_effect_walk(node, env, solver)
	if err ~= nil then return nil, nil, env2, err end
	return { [name] = TRUTHY_ATOM }, { [name] = FALSY_ATOM }, env2, nil
end

-- Handle `type(x) == "string"` / `type(x) ~= "string"`. The == branch
-- narrows x to V.prim(<lit>); the ~= branch's positive narrowing is the
-- negation, which the framework applies via V.neg around the atom.
-- Returns (atoms_pos, atoms_neg, env_after, err) or nil if not the shape.
local function recognise_type_eq(node, env, solver, inverted)
	local lhs, rhs = node.lhs, node.rhs
	local x = type_of_ident(lhs)
	local kind, val
	if x ~= nil then
		kind, val = lit_payload(rhs)
	else
		x = type_of_ident(rhs)
		if x == nil then return nil end
		kind, val = lit_payload(lhs)
	end
	if kind ~= "string" then return nil end
	-- Walk the `type(x)` subexpression for side-effects — but `type` is
	-- not necessarily bound (it's an ambient global; crescent forbids
	-- ambient globals, so the recogniser deliberately does NOT walk it
	-- as a call). Instead we walk only the identifier `x` to verify it
	-- exists, and leave `type` unchecked. This is the same trade-off
	-- the design doc makes: `type(...)` is a *syntactic* guard form.
	local x_node = { tag = defs.NODE_IDENTIFIER, name = x, line = node.line, col = node.col }
	local env2, err = side_effect_walk(x_node, env, solver)
	if err ~= nil then return nil, nil, env2, err end
	local atom = atom_for_type_string(val)
	if atom == nil then
		-- Recognised guard shape but no v4 atom available for this Lua
		-- type-return string ("thread"/"userdata"). Walk x for the
		-- in-scope check (done above) and apply no narrowing. This is
		-- conservative and sound: the truthy/falsy branches both see x
		-- with its original type. Reporting it as recognised (returning
		-- non-nil maps) prevents the caller from falling through to
		-- side-effect-walking the whole `type(x) == "..."` expression,
		-- which would attempt to walk `type` as a global and produce an
		-- unrelated diagnostic.
		return {}, {}, env2, nil
	end
	if inverted then
		-- `~=`: truthy means NOT-atom; falsy means IS-atom.
		return { [x] = V.neg(atom) }, { [x] = atom }, env2, nil
	end
	return { [x] = atom }, { [x] = V.neg(atom) }, env2, nil
end

-- Handle `x == lit` / `x ~= lit` where lit is a literal scalar (or nil).
-- For x == nil: pos = V.prim("nil"), neg = V.prim("nil")
-- For x == "GET": pos = V.literal("string","GET"), neg = same
-- For x ~= lit: pos and neg become V.neg(atom) (framework applies a
-- second V.neg on the falsy branch, restoring the literal in falsy).
local function recognise_literal_eq(node, env, solver, inverted)
	local lhs, rhs = node.lhs, node.rhs
	local x = ident_name(lhs)
	local kind, val
	if x ~= nil then
		kind, val = lit_payload(rhs)
	else
		x = ident_name(rhs)
		if x == nil then return nil end
		kind, val = lit_payload(lhs)
	end
	if kind == nil then return nil end
	-- Walk x for the lookup side-effect (this verifies x is in scope and
	-- threads any synth error through to the caller).
	local x_node = { tag = defs.NODE_IDENTIFIER, name = x, line = node.line, col = node.col }
	local env2, err = side_effect_walk(x_node, env, solver)
	if err ~= nil then return nil, nil, env2, err end
	local atom
	if kind == "nil" then
		atom = V.nil_
	else
		atom = V.literal(kind, val)
	end
	if inverted then
		return { [x] = V.neg(atom) }, { [x] = atom }, env2, nil
	end
	return { [x] = atom }, { [x] = V.neg(atom) }, env2, nil
end

-- Handle `x.k == lit`. Atom = V.rec({k=V.literal(...)}, true) — an open
-- record discriminant. The truthy branch narrows x to "is at least this
-- shape"; the framework's V.inter does the rest.
local function recognise_field_eq(node, env, solver, inverted)
	local lhs, rhs = node.lhs, node.rhs
	local x, k = field_of_ident(lhs)
	local kind, val
	if x ~= nil then
		kind, val = lit_payload(rhs)
	else
		x, k = field_of_ident(rhs)
		if x == nil then return nil end
		kind, val = lit_payload(lhs)
	end
	if kind == nil then return nil end
	-- Walk x for the binding-existence side-effect; do NOT walk the
	-- NODE_FIELD_EXPR (field synth is sub-phase F).
	local x_node = { tag = defs.NODE_IDENTIFIER, name = x, line = node.line, col = node.col }
	local env2, err = side_effect_walk(x_node, env, solver)
	if err ~= nil then return nil, nil, env2, err end
	local field_atom
	if kind == "nil" then
		field_atom = V.nil_
	else
		field_atom = V.literal(kind, val)
	end
	local atom = V.rec({ [k] = field_atom }, true, nil)
	if inverted then
		return { [x] = V.neg(atom) }, { [x] = atom }, env2, nil
	end
	return { [x] = atom }, { [x] = V.neg(atom) }, env2, nil
end

-- Try every recogniser for an equality form (`==` or `~=`) in order.
local function recognise_equality(node, env, solver, inverted)
	local p, n, env2, err = recognise_type_eq(node, env, solver, inverted)
	if p ~= nil or err ~= nil then return p, n, env2, err end
	p, n, env2, err = recognise_field_eq(node, env, solver, inverted)
	if p ~= nil or err ~= nil then return p, n, env2, err end
	return recognise_literal_eq(node, env, solver, inverted)
end

-- ── main analyzer ─────────────────────────────────────────────────────────

-- Binary op string → narrowing handler. The parser is expected to carry
-- the operator as a string field `op` on NODE_BINARY_EXPR. Walker tests
-- use this convention directly; the FFI bridge in sub-phase J translates
-- the parser's int-encoded operator to the same string.
analyze_guard = function(node, env, solver)
	if node.tag == defs.NODE_IDENTIFIER then
		local p, n, env2, err = recognise_identifier_guard(node, env, solver)
		if p ~= nil then return p, n, env2, err end
		if err ~= nil then return nil, nil, env2, err end
		-- Should be unreachable for NODE_IDENTIFIER, but treat as no-narrow.
		return {}, {}, env, nil
	end
	if node.tag == defs.NODE_UNARY_EXPR and node.op == "not" then
		local p, n, env2, err = analyze_guard(node.operand, env, solver)
		if err ~= nil then return nil, nil, env2, err end
		-- `not` swaps polarity.
		return n, p, env2, nil
	end
	if node.tag == defs.NODE_BINARY_EXPR then
		local op = node.op
		if op == "==" then
			local p, n, env2, err = recognise_equality(node, env, solver, false)
			if p ~= nil then return p, n, env2, err end
			if err ~= nil then return nil, nil, env2, err end
			return {}, {}, env, nil
		elseif op == "~=" then
			local p, n, env2, err = recognise_equality(node, env, solver, true)
			if p ~= nil then return p, n, env2, err end
			if err ~= nil then return nil, nil, env2, err end
			return {}, {}, env, nil
		elseif op == "and" then
			local p1, n1, env2, err1 = analyze_guard(node.lhs, env, solver)
			if err1 ~= nil then return nil, nil, env2, err1 end
			local p2, n2, env3, err2 = analyze_guard(node.rhs, env2, solver)
			if err2 ~= nil then return nil, nil, env3, err2 end
			-- Truthy: both lhs and rhs truthy → intersect positives.
			-- Falsy: either could be false; the per-var info is the
			-- UNION of falsy narrowings only when both branches agree
			-- (per `or`-true logic on the negated form via De Morgan).
			-- Practically: drop falsy narrowing for `and`. The design
			-- doc §5 names truthy explicitly and leaves `and`-false
			-- weak — this is the principled position.
			local _ = n1; local __ = n2
			return map_inter(p1, p2), {}, env3, nil
		elseif op == "or" then
			local p1, n1, env2, err1 = analyze_guard(node.lhs, env, solver)
			if err1 ~= nil then return nil, nil, env2, err1 end
			local p2, n2, env3, err2 = analyze_guard(node.rhs, env2, solver)
			if err2 ~= nil then return nil, nil, env3, err2 end
			-- Truthy: union the per-var atoms; only names known in both
			-- can be narrowed (otherwise one side gives no info).
			-- Falsy: both are false → intersect per-var negatives.
			return map_union(p1, p2), map_inter(n1, n2), env3, nil
		end
	end
	-- Unrecognised guard form: walk it for side-effects (so undefined
	-- names / arity errors surface), apply no narrowing.
	local env2, err = side_effect_walk(node, env, solver)
	if err ~= nil then return nil, nil, env2, err end
	return {}, {}, env2, nil
end

M._analyze_guard = analyze_guard -- exposed for tests

-- ── env-overlay helpers ───────────────────────────────────────────────────
--
-- Given a narrowing map and a polarity, overlay it onto env. For each
-- name, narrow to inter(current_view, atom) in the positive case or
-- inter(current_view, neg(atom)) in the negative case.

local function apply_narrowing(env, atoms)
	for name, atom in pairs(atoms) do
		local cur = E.lookup(env, name)
		if cur ~= nil then
			env = E.narrow(env, name, V.inter({ cur, atom }))
		end
	end
	return env
end

-- ── statement-flow control: termination tracking ────────────────────────
--
-- A statement walk returns (env_after, err, terminated). `terminated` is
-- true if the statement unconditionally exits the surrounding block
-- (return / break). The branch-join code uses it to drop a terminated
-- branch from the join.

local function walk_statements(stmts, env, solver)
	for _, s in ipairs(stmts) do
		if s.tag == defs.NODE_BREAK_STMT then
			-- The break itself terminates the block; subsequent
			-- statements in this block are unreachable for narrowing
			-- purposes (we still walked the block up to here).
			return env, nil, true
		end
		if s.tag == defs.NODE_RETURN_STMT then
			local _ty, env2, err = walker_mod().walk_synth(s, env, solver)
			if err ~= nil then return env2, err, false end
			return env2, nil, true
		end
		local _ty, env2, err = walker_mod().walk_synth(s, env, solver)
		env = env2
		if err ~= nil then return env, err, false end
	end
	return env, nil, false
end

-- Block-scope discipline: bindings introduced inside `body` do not
-- escape. We capture the pre-block `bindings` and restore them post-walk,
-- but propagate narrowing changes on names that existed before the block.
local function walk_block(stmts, env, solver)
	local pre_bindings = env.bindings
	local env2, err, terminated = walk_statements(stmts, env, solver)
	if err ~= nil then return env2, err, terminated end
	-- Restore bindings (drop block-locals). Narrowing on pre-existing
	-- names is preserved; narrowing on a block-local is meaningless once
	-- the binding is dropped, so we strip those entries.
	local out_narrowed = {}
	for k, v in pairs(env2.narrowed) do
		if pre_bindings[k] ~= nil then out_narrowed[k] = v end
	end
	-- Compose a new env: pre bindings, kept narrowing. env.lua exposes no
	-- "set bindings wholesale" primitive (its API is single-name), so we
	-- replicate its private clone semantics here — a shallow shape-clone
	-- with bindings/narrowed overridden.
	local out = {
		bindings      = pre_bindings,
		narrowed      = out_narrowed,
		return_ty     = env2.return_ty,
		vararg        = env2.vararg,
		effects       = env2.effects,
		module        = env2.module,
		expected      = env2.expected,
		source        = env2.source,
		-- Sub-phase I fields: must be carried through. Dropping them
		-- leaves a partially-shaped env, and downstream code (e.g.
		-- E.lookup_require) indexes `require_chain` unconditionally —
		-- a nil here surfaces as a driver crash inside any `require()`
		-- walked through a block-scoped statement.
		aliases       = env2.aliases,
		io_caps       = env2.io_caps,
		cache_dir     = env2.cache_dir,
		require_chain = env2.require_chain,
	}
	return out, nil, terminated
end

-- ── NODE_IF_STMT ──────────────────────────────────────────────────────────

local function synth_if(node, env, solver)
	local clauses = node.clauses
	local else_body = node.else_body
	-- The if/elseif chain is folded right-associatively into a series of
	-- nested two-branch joins so the narrowing semantics stay simple:
	--   if c1 then b1 elseif c2 then b2 ... else be end
	--   ≡ if c1 then b1 else (if c2 then b2 else (... else be ...))

	local function walk_chain(i, current_env)
		if i > #clauses then
			-- Past the chain: either else_body or empty.
			if else_body ~= nil then
				return walk_block(else_body, current_env, solver)
			end
			return current_env, nil, false
		end
		local clause = clauses[i]
		local atoms_pos, atoms_neg, env_after_guard, gerr =
			analyze_guard(clause.cond, current_env, solver)
		if gerr ~= nil then return env_after_guard, gerr, false end
		if env_after_guard == nil then
			-- Defensive: analyze_guard always supplies an env on the
			-- non-error path; this branch is a typechecker-narrowing
			-- aid (the multi-return tuple can't be correlated with gerr
			-- by the inferrer alone).
			return current_env, D.emit(current_env, D.E_INTERNAL,
				"control_flow: analyze_guard returned nil env on no-error path"), false
		end
		-- THEN branch: apply positive narrowing.
		local then_env = apply_narrowing(env_after_guard, atoms_pos)
		local then_out, terr, then_term =
			walk_block(clause.body, then_env, solver)
		if terr ~= nil then return then_out, terr, false end
		-- ELSE branch: apply negative narrowing, then recurse on the
		-- rest of the chain.
		local else_env = apply_narrowing(env_after_guard, atoms_neg)
		local else_out, eerr, else_term = walk_chain(i + 1, else_env)
		if eerr ~= nil then return else_out, eerr, false end
		-- Join. The join produces a new narrowed map; bindings are
		-- the pre-clause (current_env) bindings — walk_block already
		-- restored them.
		local joined_narrowed = {}
		if not then_term and not else_term then
			-- Names narrowed in both branches → union of views.
			-- Names narrowed in only one → revert to pre-branch view.
			local all = {}
			for k in pairs(then_out.narrowed) do all[k] = true end
			for k in pairs(else_out.narrowed) do all[k] = true end
			for k in pairs(all) do
				local t = then_out.narrowed[k]
				local e_ = else_out.narrowed[k]
				if t ~= nil and e_ ~= nil then
					joined_narrowed[k] = V.union({ t, e_ })
				else
					-- Drop: revert to pre-branch (i.e. current_env.narrowed[k]
					-- if any; absence means no narrowing on this name).
					local pre = current_env.narrowed[k]
					if pre ~= nil then joined_narrowed[k] = pre end
				end
			end
			-- Also retain pre-branch narrowings on names not touched in
			-- either branch.
			for k, v in pairs(current_env.narrowed) do
				if joined_narrowed[k] == nil and
					then_out.narrowed[k] == nil and
					else_out.narrowed[k] == nil then
					joined_narrowed[k] = v
				end
			end
		elseif then_term and not else_term then
			-- only else flows through
			for k, v in pairs(else_out.narrowed) do joined_narrowed[k] = v end
		elseif not then_term and else_term then
			for k, v in pairs(then_out.narrowed) do joined_narrowed[k] = v end
		else
			-- Both terminated: outer block also terminates; narrowings
			-- carry the pre-branch view (nothing flows past anyway).
			for k, v in pairs(current_env.narrowed) do joined_narrowed[k] = v end
		end
		local out = {
			bindings      = current_env.bindings,
			narrowed      = joined_narrowed,
			return_ty     = current_env.return_ty,
			vararg        = current_env.vararg,
			effects       = then_out.effects, -- effects accumulate monotonically;
			-- (in practice both branches share the same effect set since
			-- effects only grow per the function-body frame's monotonic
			-- discipline)
			module        = current_env.module,
			expected      = current_env.expected,
			source        = current_env.source,
			-- Sub-phase I fields: see walk_block for the rationale.
			aliases       = current_env.aliases,
			io_caps       = current_env.io_caps,
			cache_dir     = current_env.cache_dir,
			require_chain = current_env.require_chain,
		}
		-- Merge any effects from the else branch too (a branch that
		-- terminated still ran whatever effects it accumulated).
		for k, v in pairs(else_out.effects) do out.effects[k] = v end
		return out, nil, (then_term and else_term)
	end

	local out, err, _term = walk_chain(1, env)
	if err ~= nil then return nil, out, err end
	return nil, out, nil
end

-- ── NODE_WHILE_STMT ──────────────────────────────────────────────────────

local function synth_while(node, env, solver)
	local atoms_pos, atoms_neg, env_after_guard, gerr =
		analyze_guard(node.cond, env, solver)
	if gerr ~= nil then return nil, env_after_guard, gerr end
	if env_after_guard == nil then
		return nil, env, D.emit(env, D.E_INTERNAL,
			"control_flow: analyze_guard returned nil env on no-error path")
	end
	-- Body sees positive narrowing.
	local body_env = apply_narrowing(env_after_guard, atoms_pos)
	local body_out, berr, _term = walk_block(node.body, body_env, solver)
	if berr ~= nil then return nil, body_out, berr end
	-- After the loop: negative narrowing applies (the loop exited
	-- because the guard became false).
	local after_env = apply_narrowing(env_after_guard, atoms_neg)
	-- Restore bindings to pre-loop (the loop body's locals don't escape;
	-- block-scope was already enforced by walk_block on body_out).
	return nil, after_env, nil
end

-- ── NODE_REPEAT_STMT ────────────────────────────────────────────────────
--
-- Lua: `repeat body until cond` — body runs unconditionally; `cond` is
-- tested at the end. The cond's scope INCLUDES body-locals (a Lua quirk),
-- so the analyzer runs inside the body's env. For narrowing purposes,
-- once the loop exits, cond was true → positive narrowing applies after
-- the loop, on names that existed before the loop.

local function synth_repeat(node, env, solver)
	-- Body executes once with no incoming narrowing.
	local body_out, berr, _term = walk_block(node.body, env, solver)
	if berr ~= nil then return nil, body_out, berr end
	-- Cond is analyzed in body's env (with body locals visible — but
	-- walk_block already dropped them when restoring bindings; the doc
	-- §3.12 calls out cond-at-end semantics. For narrowing of outer
	-- names, we want to use the env where outer names are in scope, so
	-- the post-restore body_out env is correct.)
	local atoms_pos, _atoms_neg, env_after_guard, gerr =
		analyze_guard(node.cond, body_out, solver)
	if gerr ~= nil then return nil, env_after_guard, gerr end
	-- Loop exits when cond becomes true → positive narrowing flows
	-- past the loop.
	local after_env = apply_narrowing(env_after_guard, atoms_pos)
	return nil, after_env, nil
end

-- ── NODE_FOR_NUM ─────────────────────────────────────────────────────────
--
-- Loop var typed as integer if init/stop/step all synthesize to a type
-- subtype-of integer; otherwise number. The body sees the loop-var as a
-- block-local binding; it does not escape.

local function is_integer_typed(ty)
	if ty == nil then return false end
	if ty.tag == "prim" and ty.name == "integer" then return true end
	if ty.tag == "literal" and ty.base == "integer" then return true end
	return false
end

local function synth_for_num(node, env, solver)
	local W = walker_mod()
	local init_ty, env1, err = W.walk_synth(node.init, env, solver)
	if err ~= nil then return nil, env1, err end
	local stop_ty, env2, err2 = W.walk_synth(node.stop, env1, solver)
	if err2 ~= nil then return nil, env2, err2 end
	local step_ty = nil
	local env3 = env2
	if node.step ~= nil then
		local sty, env_s, err_s = W.walk_synth(node.step, env2, solver)
		if err_s ~= nil then return nil, env_s, err_s end
		step_ty = sty
		env3 = env_s
	end
	local loop_var_ty
	if is_integer_typed(init_ty) and is_integer_typed(stop_ty) and
		(step_ty == nil or is_integer_typed(step_ty)) then
		loop_var_ty = V.integer
	else
		loop_var_ty = V.number
	end
	-- Bind in the body env only; restore on exit.
	local body_env = E.bind(env3, node.name, loop_var_ty)
	local body_out, berr, _term = walk_block(node.body, body_env, solver)
	if berr ~= nil then return nil, body_out, berr end
	-- Post-loop env has the loop-var dropped (walk_block did this) and
	-- pre-loop bindings/narrowing intact.
	return nil, env3, nil
end

-- ── NODE_FOR_IN ──────────────────────────────────────────────────────────
--
-- `for n1, n2, ... in iter, state, ctrl do body end`. The iterator
-- expression(s) are synthesized; the iterator's return-tuple positions
-- bind to the names. Per design §3.12, this uses the standard iterator
-- shape `(state, ctrl) -> (K?, V?)` produced by pairs/ipairs/custom
-- iterators. We synthesise the first expr (the iterator), expect it to
-- be a callable, and extract the result tuple shape to bind the names.

local function synth_for_in(node, env, solver)
	local W = walker_mod()
	local iter_ty, env1, err = W.walk_synth(node.exprs[1], env, solver)
	if err ~= nil then return nil, env1, err end
	if iter_ty == nil then
		return nil, env1, D.emit(env1, D.E_INTERNAL,
			"for-in: iterator has no synthesized type")
	end
	-- Walk any remaining exprs for side-effects (state, ctrl).
	for i = 2, #node.exprs do
		local _ty, env_n, err_n = W.walk_synth(node.exprs[i], env1, solver)
		env1 = env_n
		if err_n ~= nil then return nil, env1, err_n end
	end
	-- Instantiate if forall.
	local arrow = iter_ty
	if arrow.tag == "forall" then
		arrow = V.instantiate(arrow)
	end
	if arrow.tag ~= "fn" then
		return nil, env1,
			"for-in: iterator is not a function type (" .. V.show(iter_ty) .. ")"
	end
	-- The arrow's return: either a scalar (single-name binding) or a
	-- record-tuple { ["1"]=T1, ["2"]=T2, ... }.
	local ret = arrow.ret
	local body_env = env1
	if #node.names == 1 then
		local t = ret
		if ret.tag == "rec" and ret.fields["1"] ~= nil then
			t = ret.fields["1"]
		end
		body_env = E.bind(body_env, node.names[1], t)
	else
		for i, name in ipairs(node.names) do
			local t = V.nil_
			if ret.tag == "rec" then
				t = ret.fields[tostring(i)] or V.nil_
			elseif i == 1 then
				t = ret
			end
			body_env = E.bind(body_env, name, t)
		end
	end
	local body_out, berr, _term = walk_block(node.body, body_env, solver)
	if berr ~= nil then return nil, body_out, berr end
	return nil, env1, nil
end

-- ── NODE_DO_STMT ─────────────────────────────────────────────────────────

local function synth_do(node, env, solver)
	local out, err, _term = walk_block(node.body, env, solver)
	if err ~= nil then return nil, out, err end
	return nil, out, nil
end

-- ── NODE_BREAK_STMT ──────────────────────────────────────────────────────
--
-- A break statement reached at the top level of a walk just returns
-- cleanly with no effect on env. Inside walk_statements (above), a break
-- short-circuits the remaining statements. Code after a break in the
-- same block is unreachable for narrowing purposes — walk_statements
-- handles that by returning `terminated = true` from the encounter.

local function synth_break(_node, env, _solver)
	return nil, env, nil
end

-- ── registration ─────────────────────────────────────────────────────────

function M.register(W)
	W.register_synth(defs.NODE_IF_STMT,     synth_if)
	W.register_synth(defs.NODE_WHILE_STMT,  synth_while)
	W.register_synth(defs.NODE_REPEAT_STMT, synth_repeat)
	W.register_synth(defs.NODE_FOR_NUM,     synth_for_num)
	W.register_synth(defs.NODE_FOR_IN,      synth_for_in)
	W.register_synth(defs.NODE_DO_STMT,     synth_do)
	W.register_synth(defs.NODE_BREAK_STMT,  synth_break)
end

return M
