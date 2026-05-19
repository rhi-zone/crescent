-- Walker sub-phase E — local/assign statements and match expressions.
--
-- Per docs/typechecker-ast-walker-design.md §3.11 (local/assign) and §7
-- (match expressions). This module registers SYNTHESIZE handlers for:
--
--   NODE_LOCAL_STMT       — `local x = e` and multi-binding forms.
--   NODE_ASSIGN_STMT      — `x = e` and multi-assign forms.
--   NODE_MATCH_EXPR       — value-level match-on-type (walker-internal node).
--
-- Decoded node shapes
-- ───────────────────
--
--   NODE_LOCAL_STMT
--     { tag, line, col,
--       names: { { name: string, ann: V4Type | nil } },
--       exprs: Node[] | nil }
--
--   NODE_ASSIGN_STMT
--     { tag, line, col,
--       targets: Node[],   -- each is NODE_IDENTIFIER for sub-phase E;
--                          -- NODE_FIELD_EXPR / NODE_INDEX_EXPR rejected.
--       exprs:   Node[] }
--
--   NODE_MATCH_EXPR
--     { tag, line, col,
--       subject: Node,
--       arms: { { pattern: V4Type, result: V4Type, captures: V4Type[] } },
--       wildcard_result: V4Type | nil }
--
-- The arms field is a list of v4 match-arm records (the same shape V.arm
-- produces). Pattern and result are V4Types whose capture vars (V.var()s
-- shared between pattern and result) are listed in `captures`. The walker
-- does NOT manufacture capture vars from a `%X` surface sigil — that
-- happens at the lowering / annotation-parser site that builds the node
-- (sub-phase J wires the parser; tests construct nodes directly). The
-- walker's contribution is:
--   (1) synthesizing the subject (forward) or computing the subject's
--       expected type via V.match_backward (backward),
--   (2) calling V.match (forward) or threading the backward constraint,
--   (3) surfacing v4 errors (disjointness, suspension, non-exhaustive)
--       verbatim as walker diagnostics.
--
-- Multi-return / multi-assign semantics (§3.11 + §8.3 + legacy fixes
-- D1/D2/D3/D4):
--   * The last RHS expression in `local`/assign **spreads** when it
--     synthesises to a multi-return tuple (V.rec with string-keyed slots
--     "1","2",...).
--   * Non-last RHS expressions **truncate** to slot 1 if multi-return —
--     Lua's "list-trim" rule.
--   * LHS slots beyond the RHS count are filled with `nil` (Lua's missing-
--     RHS-yields-nil rule), unless the last RHS spread covers them.
--
-- Annotated local bindings (§3.11):
--   * If the LHS slot carries an annotation `ann`, the corresponding RHS
--     is CHECKed against `ann` and the binding's type is `ann` itself.
--   * If only an annotation is present (no init), the binding is `ann`.
--   * If only an init is present, the binding is `synth(init)` (no
--     widening — sub-phase E does not yet implement <const> attribute).
--   * Neither: a fresh V.var().
--
-- Module-pattern accumulation (§3.11 + §13.5):
--   Field-write assignment (`M.foo = ...`) requires indexed access, which
--   is sub-phase F. Per the prompt's hard rule (no temp-measures), any
--   field/index target on the LHS is rejected loudly here with a
--   sub-phase-F message. The module accumulator slot in env.lua already
--   exists; threading writes into it lands when NODE_FIELD_EXPR /
--   NODE_INDEX_EXPR handlers arrive.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Intentionally annotation-free; same rationale as functions.lua and
-- control_flow.lua (cross-module --:: alias resolution limitation
-- documented in walker/README.md).

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local D       = require("lib.type.static-v4.walker.diag")
local defs    = require("lib.type.static.defs")
local subtype = require("lib.type.static-v4.subtype")

local _types  = require("lib.type.static-v4.types")
local _ = _types

local M = {}

local function walker_mod()
	return require("lib.type.static-v4.walker.walker")
end

-- ── helpers ───────────────────────────────────────────────────────────────

-- Lua multi-return is V.rec({ ["1"]=T1, ["2"]=T2, ... }, false). Detect
-- that shape and extract a positional slot list. Returns nil if `ty` is
-- not a multi-return tuple (in which case the caller treats it as a
-- scalar).
local function as_tuple(ty)
	if ty == nil then return nil end
	if type(ty) ~= "table" then return nil end
	if ty.tag ~= "rec" then return nil end
	local fields = ty.fields
	if type(fields) ~= "table" then return nil end
	if fields["1"] == nil then return nil end
	local slots = {}
	local count = 0
	local i = 1
	while true do
		local v = fields[tostring(i)]
		if v == nil then break end
		slots[i] = v
		count = count + 1
		i = i + 1
	end
	-- Require at least 2 slots to call it a tuple; a one-slot rec with
	-- only "1" is functionally a scalar wrapper, but Lua semantics don't
	-- spread a single-position return any differently from a scalar.
	if count < 2 then return nil end
	return slots
end

-- Build the per-LHS-slot type list from the RHS expression types, applying
-- Lua's last-spreads / non-last-truncates rules. Inputs:
--   rhs_types : list of synthesised RHS types in left-to-right order.
--   lhs_count : number of LHS slots to fill.
-- Output: list of types of length lhs_count. Slots without coverage map
-- to V.nil_.
local function distribute_rhs(rhs_types, lhs_count)
	local out = {}
	-- Collect RHS types into a sequentially-indexed list with a known count.
	-- Avoid `#rhs_types` (typechecker rejects `__len` on the locally-inferred
	-- table type) by counting via ipairs.
	local seq = {}
	local n_rhs = 0
	for k, v in ipairs(rhs_types) do
		seq[k] = v
		n_rhs = n_rhs + 1
	end
	if n_rhs <= 0 then
		for i = 1, lhs_count do out[i] = V.nil_ end
		return out
	end
	-- Non-last RHS slots: truncate to scalar (slot "1" if tuple).
	local last_idx = n_rhs
	for i = 1, last_idx do
		if i < last_idx and i <= lhs_count then
			local t = seq[i]
			local tup = as_tuple(t)
			if tup ~= nil then
				out[i] = tup[1]
			else
				out[i] = t
			end
		end
	end
	-- Last RHS slot: may spread.
	local last = seq[last_idx]
	local last_tup = as_tuple(last)
	if last_tup ~= nil then
		-- Spread across remaining LHS positions starting at last_idx.
		local j = 1
		for i = last_idx, lhs_count do
			out[i] = last_tup[j] or V.nil_
			j = j + 1
		end
	else
		if last_idx <= lhs_count then
			out[last_idx] = last
		end
	end
	-- Fill any remaining uncovered LHS slots with nil.
	for i = 1, lhs_count do
		if out[i] == nil then out[i] = V.nil_ end
	end
	return out
end

-- ── NODE_LOCAL_STMT ──────────────────────────────────────────────────────
--
-- Per §3.11. Per-slot rules:
--   (ann, init)  → CHECK init against ann; bind ann.
--   (ann, _)     → bind ann.
--   (_,   init)  → bind synth(init).
--   (_,   _)     → bind fresh V.var().
--
-- The "init" for slot i is determined by distribute_rhs, which applies
-- multi-return spread / truncation across the RHS expression list. If
-- ann is present on slot i AND that slot's RHS is the spread tail of a
-- multi-return tuple, we still CHECK the distributed slot type against
-- ann — that's what the user expects from `local a, b --: T = f()`.
--
-- Refinement on CHECK with annotation: when the RHS is a *single*
-- expression and the LHS has an annotation, we walk the RHS in CHECK
-- mode (bidirectional inference). For multi-expression RHS, each RHS is
-- synthesised first and then individual distributed slot types are
-- subtyped against per-slot annotations. Single-expr-CHECK is the
-- common case (`local x --: T = expr`) and bidirectional pays off there.

local function synth_local(node, env, solver)
	local W = walker_mod()
	local names = node.names
	local exprs = node.exprs
	local lhs_count = 0
	if names ~= nil then
		for _ in ipairs(names) do lhs_count = lhs_count + 1 end
	end
	local rhs_count = 0
	if exprs ~= nil then
		for _ in ipairs(exprs) do rhs_count = rhs_count + 1 end
	end

	-- Empty `local` is legal Lua syntax (`local` with no name binds nothing)
	-- but `lhs_count == 0` here means an empty list, which the parser would
	-- not emit. Defend regardless: nothing to bind, env unchanged.
	if lhs_count == 0 then return nil, env, nil end

	-- Single-expression + single-annotated-name path uses CHECK mode for
	-- the bidirectional payoff.
	if lhs_count == 1 and rhs_count == 1 and names[1].ann ~= nil
		and exprs ~= nil then
		local ann = names[1].ann
		local env2, err = W.walk_check(exprs[1], env, solver, ann)
		if err ~= nil then return nil, env2, err end
		env2 = E.bind(env2, names[1].name, ann)
		return nil, env2, nil
	end

	-- Synthesise each RHS in left-to-right order.
	local rhs_types = ({})
	if exprs ~= nil then
		for i, e in ipairs(exprs) do
			local ty, env2, err = W.walk_synth(e, env, solver)
			env = env2
			if err ~= nil then return nil, env, err end
			if ty == nil then
				return nil, env,
					"local: RHS expression " .. tostring(i) ..
					" has no synthesised type"
			end
			rhs_types[i] = ty
		end
	end

	-- Distribute according to Lua's last-spreads / non-last-truncates rule.
	local distributed = distribute_rhs(rhs_types, lhs_count)

	-- Bind each LHS slot.
	for i, nm in ipairs(names) do
		local ann = nm.ann
		local init_ty = distributed[i]
		local bind_ty
		if ann ~= nil then
			-- Annotated slot: distributed init must subtype ann; binding is ann.
			if rhs_count > 0 and init_ty ~= nil then
				subtype.constrain(solver, init_ty, ann)
				if solver.error ~= nil then
					return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
						"local: initializer for '" .. nm.name ..
						"' does not satisfy annotation",
						solver, init_ty, ann)
				end
			end
			bind_ty = ann
		else
			if rhs_count > 0 and init_ty ~= nil then
				bind_ty = init_ty
			else
				bind_ty = V.var(nm.name)
			end
		end
		env = E.bind(env, nm.name, bind_ty)
	end
	return nil, env, nil
end

-- ── NODE_ASSIGN_STMT ─────────────────────────────────────────────────────
--
-- Per §3.11. For each LHS/RHS pair: synth RHS, CHECK against typeof(LHS).
-- LHS is an existing local-var binding (NODE_IDENTIFIER). Field/index
-- writes are sub-phase F territory and rejected loudly here.
--
-- Multi-assign Lua semantics: same last-spreads / non-last-truncates
-- distribution as local. The distributed type for slot i is constrained
-- against `E.lookup(targets[i].name)`. Re-assignment does NOT change the
-- binding's declared type (Lua does not have flow-typed bindings at the
-- declaration level; narrowing is the only mechanism that refines a
-- name's view, and assignment widens back to the binding).

local FORBIDDEN_LHS_TAGS = {
	[defs.NODE_FIELD_EXPR] = "NODE_FIELD_EXPR",
	[defs.NODE_INDEX_EXPR] = "NODE_INDEX_EXPR",
}

local function synth_assign(node, env, solver)
	local W = walker_mod()
	local targets = node.targets
	local exprs = node.exprs
	local lhs_count = 0
	if targets ~= nil then
		for _ in ipairs(targets) do lhs_count = lhs_count + 1 end
	end
	if lhs_count == 0 then return nil, env, nil end

	-- Validate every LHS first (cheap, no side-effects on env / solver).
	for i, t in ipairs(targets) do
		local forbidden = FORBIDDEN_LHS_TAGS[t.tag]
		if forbidden ~= nil then
			return nil, env, D.emit(env, D.E_UNSUPPORTED_NODE,
				"assign: indexed LHS (" .. forbidden ..
				") not in sub-phase E scope — lands in sub-phase F " ..
				"(target #" .. tostring(i) .. ")")
		end
		if t.tag ~= defs.NODE_IDENTIFIER then
			return nil, env, D.emit(env, D.E_UNSUPPORTED_NODE,
				"assign: unsupported LHS shape on target #" .. tostring(i))
		end
		if not E.has(env, t.name) then
			return nil, env, D.emit(env, D.E_UNDEFINED_NAME,
				"assign: undefined name '" .. t.name .. "' on target #" ..
				tostring(i))
		end
	end

	-- Synthesise each RHS.
	local rhs_types = ({})
	if exprs ~= nil then
		for i, e in ipairs(exprs) do
			local ty, env2, err = W.walk_synth(e, env, solver)
			env = env2
			if err ~= nil then return nil, env, err end
			if ty == nil then
				return nil, env, D.emit(env, D.E_INTERNAL,
					"assign: RHS expression " .. tostring(i) ..
					" has no synthesised type")
			end
			rhs_types[i] = ty
		end
	end

	local distributed = distribute_rhs(rhs_types, lhs_count)

	-- Constrain each distributed RHS slot <: the existing LHS binding type.
	-- We look up via E.bindings directly (not E.lookup): narrowing is a
	-- read-side overlay, but ASSIGNMENT writes through to the underlying
	-- binding and must satisfy the declared/inferred type, not the
	-- currently-narrowed view.
	for i, t in ipairs(targets) do
		local lhs_ty = env.bindings[t.name]
		if lhs_ty == nil then
			return nil, env, D.emit(env, D.E_INTERNAL,
				"assign: internal — binding '" .. t.name ..
				"' disappeared between validation and constraint")
		end
		local rhs_slot = distributed[i]
		if rhs_slot ~= nil then
			subtype.constrain(solver, rhs_slot, lhs_ty)
			if solver.error ~= nil then
				return nil, env, D.from_solver(env, D.E_TYPE_MISMATCH,
					"assign: RHS for '" .. t.name .. "' does not satisfy LHS type",
					solver, rhs_slot, lhs_ty)
			end
		end
	end
	return nil, env, nil
end

-- ── NODE_MATCH_EXPR ───────────────────────────────────────────────────────
--
-- §7. SYNTHESIZE: synth the subject, dispatch to v4.match (forward). The
-- returned type is the firing arm's result with captures bound (or the
-- wildcard's result when no non-wildcard arm fires). Disjointness, non-
-- exhaustiveness, and suspension are reported as v4 errors and surfaced
-- verbatim.
--
-- CHECK: v4.match_backward produces a constraint on the subject from the
-- expected result. We then CHECK the subject against that constraint.
-- Returning the expected type to the walker shell is the caller's
-- contract — the walker harness routes through walk_check and supplies it.

local function build_arms(raw_arms)
	-- raw_arms is the list provided by the node. Each entry is already a
	-- v4 arm record (pattern, result, captures). We pass-through; the
	-- arm-constructor sugar V.arm(...) is a one-liner the caller may have
	-- used or may have produced the record literal directly.
	local arms = {}
	for i, a in ipairs(raw_arms) do
		arms[i] = a
	end
	return arms
end

local function synth_match(node, env, solver)
	local W = walker_mod()
	local subject_ty, env2, err =
		W.walk_synth(node.subject, env, solver)
	if err ~= nil then return nil, env2, err end
	if subject_ty == nil then
		return nil, env2, D.emit(env2, D.E_INTERNAL,
			"match: subject has no synthesised type")
	end
	local arms = build_arms(node.arms or ({}))
	local result, merr = V.match(subject_ty, arms, node.wildcard_result)
	if merr ~= nil then
		return nil, env2, D.emit(env2, D.E_MATCH, "match: " .. merr)
	end
	return result, env2, nil
end

local function check_match(node, env, solver, expected)
	local W = walker_mod()
	local arms = build_arms(node.arms or ({}))
	local subj_constraint, berr =
		V.match_backward(arms, node.wildcard_result, expected)
	if berr ~= nil then
		return env, D.emit(env, D.E_MATCH, "match (backward): " .. berr)
	end
	-- CHECK the subject against the backward-derived constraint.
	local env2, serr = W.walk_check(node.subject, env, solver, subj_constraint)
	if serr ~= nil then return env2, serr end
	return env2, nil
end

-- ── registration ─────────────────────────────────────────────────────────

function M.register(W)
	W.register_synth(defs.NODE_LOCAL_STMT,  synth_local)
	W.register_synth(defs.NODE_ASSIGN_STMT, synth_assign)
	W.register_synth(defs.NODE_MATCH_EXPR,  synth_match)
	W.register_check(defs.NODE_MATCH_EXPR,  check_match)
end

-- Exported for sub-phase F's overrides. F's NODE_LOCAL_STMT /
-- NODE_ASSIGN_STMT wrappers dispatch to these for the non-module-pattern,
-- non-indexed-LHS paths. Names carry the sub-phase explicitly to discourage
-- generic re-export ("see, this is a fallback hook, not a public API").
M.synth_local_for_subphase_f  = synth_local
M.synth_assign_for_subphase_f = synth_assign

return M
