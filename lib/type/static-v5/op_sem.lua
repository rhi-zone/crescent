-- lib/type/static-v5/op_sem.lua
-- v5.0 typechecker operational semantics — EXECUTABLE FORM.
--
-- Companion to `docs/typechecker-v5-operational-semantics.md`.  Per H7
-- (parallel impl + docs with parity tests) and F2 (op-sem is a runnable
-- test, not prose).
--
-- Each labelled rule in the doc has a `rule_<label>` function here.
-- `run()` is the solver loop implementing S-Step / S-Park / S-Wake /
-- S-Quiesce.
--
-- This module REUSES the perf-prototype substrate at
-- `lib/type/experiments/v5_perf/` — types.lua (AST), subst.lua (union-find
-- substitution with phase), constraint.lua (constraint ADT).  CInst is
-- added locally here as a "cinst"-tagged shape.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local variance_mod   = require("lib.type.experiments.v5_perf.variance")

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Scheme + CInst extension
-- ────────────────────────────────────────────────────────────────────────────

--:: V5Scheme       = { binders: integer, body: V5Type }
--:: ConstraintInst = { id: integer, tag: "cinst", scheme: V5Scheme, target: V5Type, prov: Provenance }
--:: ConstraintHKT  = { id: integer, tag: "chkt", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: ConstraintHO   = { id: integer, tag: "hounify", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: OpSemConstraint = V5Constraint | ConstraintInst | ConstraintHKT | ConstraintHO

-- Narrow an unknown value to V5Type (requires non-nil table with string .tag).
-- Used when reading V5Type fields off unknown-typed constraint field accesses.
--: (unknown) -> V5Type | nil
local function as_v5type(v)
	if type(v) ~= "table" then return nil end
	--: { tag: unknown, ... }
	local t = v
	local tg = t.tag
	if type(tg) ~= "string" then return nil end
	--: V5Type
	local ty = v
	return ty
end

local _next_id = 100000

--: () -> integer
local function fresh_id()
	local i = _next_id
	_next_id = i + 1
	return i
end

--: (integer, V5Type) -> V5Scheme
function M.scheme(binders, body)
	return { binders = binders, body = body }
end

--: (V5Scheme, V5Type, Provenance) -> ConstraintInst
function M.inst(sch, target, prov)
	return { id = fresh_id(), tag = "cinst", scheme = sch, target = target, prov = prov }
end

--: (V5Type, V5Type[], V5Type, Provenance) -> ConstraintHKT
function M.chkt(f, args, result, prov)
	return { id = fresh_id(), tag = "chkt", f = f, args = args, result = result, prov = prov }
end

--: (V5Type, V5Type[], V5Type, Provenance) -> ConstraintHO
function M.hounify(f, args, result, prov)
	return { id = fresh_id(), tag = "hounify", f = f, args = args, result = result, prov = prov }
end

-- Re-export constructor pass-throughs.
M.eq          = constraint_mod.eq
M.sub         = constraint_mod.sub
M.table_open  = constraint_mod.table_open
M.table_set   = constraint_mod.table_set
M.table_seal  = constraint_mod.table_seal
M.method_call = constraint_mod.method_call
M.row_extend  = constraint_mod.row_extend
M.row_lacks   = constraint_mod.row_lacks
M.row_close   = constraint_mod.row_close
M.prov        = constraint_mod.prov
M.variance    = variance_mod

-- ────────────────────────────────────────────────────────────────────────────
-- State
-- ────────────────────────────────────────────────────────────────────────────

--:: ErrorDetails = { tag: "const_mismatch", a_name: string, b_name: string } | { tag: "missing_field", field: string } | { tag: "extra_field", field: string } | { tag: "effect_not_permitted", effect: V5Type, container: V5Type | nil } | { tag: "kind_mismatch", a_tag: string, b_tag: string } | { tag: "no_matching_branch", value_ty: V5Type, union_ty: V5Type } | { tag: "arrow_arity_mismatch", expected: integer, got: integer } | { tag: "record_arity_mismatch", expected: integer, got: integer } | { tag: "head_mismatch", a_name: string, b_name: string } | { tag: "closed_extend", field: string } | { tag: "row_already_contains", field: string } | { tag: "occurs_check", a_name: string } | { tag: "intersection_arity_mismatch", expected: integer, got: integer } | { tag: "all_parts_unresolved" } | { tag: "sealed_field_set", field: string } | { tag: "missing_method", method: string } | { tag: "not_a_record", found_tag: string } | { tag: "ambiguous_constructor" } | { tag: "hkt_arity_mismatch", expected: integer, got: integer }
--:: OpSemError = { rule: string, msg: string, prov: Provenance | nil, details: ErrorDetails | nil }
--:: OpSemTrace = { rule: string, msg: string }
--:: OpSemState = { subst: Subst, worklist: OpSemConstraint[], head: integer, tail: integer, inert: { [integer]: OpSemConstraint }, errors: OpSemError[], trace: OpSemTrace[], reactivations: integer, steps: integer, row_watchers: { [integer]: { [integer]: boolean } }, upper_bounds: { [integer]: V5Type[] }, lower_bounds: { [integer]: V5Type[] } }

--: () -> OpSemState
function M.new_state()
	return {
		subst         = subst_mod.new(),
		worklist      = {} --[[: OpSemConstraint[] ]],
		head          = 1,
		tail          = 0,
		inert         = {} --[[: { [integer]: OpSemConstraint } ]],
		errors        = {} --[[: OpSemError[] ]],
		trace         = {} --[[: OpSemTrace[] ]],
		reactivations = 0,
		steps         = 0,
		row_watchers  = {} --[[: { [integer]: { [integer]: boolean } } ]],
		upper_bounds  = {} --[[: { [integer]: V5Type[] } ]],
		lower_bounds  = {} --[[: { [integer]: V5Type[] } ]],
	}
end

--: (OpSemState, OpSemConstraint) -> nil
function M.emit(st, c)
	local n = st.tail + 1
	st.worklist[n] = c
	st.tail = n
end

--: (OpSemState, string, string) -> nil
local function trace(st, rule, msg)
	st.trace[#st.trace + 1] = { rule = rule, msg = msg }
end

--: (OpSemState, string, string, Provenance | nil, ErrorDetails | nil) -> nil
local function err(st, rule, msg, prov, details)
	st.errors[#st.errors + 1] = { rule = rule, msg = msg, prov = prov, details = details }
	trace(st, rule, msg)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Wake + park
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, integer) -> nil
local function wake(st, tvar_id)
	local watchers = subst_mod.drain_watchers(st.subst, tvar_id)
	if watchers == nil then return end
	for cid in pairs(watchers) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- S-Wake-Head.  Drain head-watchers when the tvar's binding's head becomes
-- rigid.  Called after any binding event where head_is_rigid holds.
--: (OpSemState, integer) -> nil
local function wake_head(st, tvar_id)
	if not subst_mod.head_is_rigid(st.subst, tvar_id) then return end
	local hw = subst_mod.drain_head_watchers(st.subst, tvar_id)
	if hw == nil then return end
	for cid in pairs(hw) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Row-var watcher helpers (needed by park, which is defined next).
-- watch_rowvar/wake_rowvar are also referenced from the CRow rules below;
-- declaring them here ensures they are in scope for both park and the rules.

--: (OpSemState, integer, integer) -> nil
local function watch_rowvar(st, rv_id, cid)
	local w = st.row_watchers[rv_id]
	if w == nil then w = {} --[[: { [integer]: boolean } ]]; st.row_watchers[rv_id] = w end
	w[cid] = true
end

--: (OpSemState, integer) -> nil
local function wake_rowvar(st, rv_id)
	local w = st.row_watchers[rv_id]
	if w == nil then return end
	st.row_watchers[rv_id] = nil
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			local n = st.tail + 1
			st.worklist[n] = c
			st.tail = n
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Bound-tracking helpers.  Bounds live in side tables on OpSemState keyed
-- by the uvar's union-find root id (so unioned uvars share bounds).
-- Dedupe is by types_mod.equal — concrete bounds usually appear in fixed
-- shapes from a single annotation, so the O(n) scan is acceptable.
--: (V5Type[], V5Type) -> boolean
local function bounds_contains(xs, t)
	for i = 1, #xs do
		local v = xs[i]
		if v ~= nil and types_mod.equal(v, t) then return true end
	end
	return false
end

--: (OpSemState, integer, V5Type) -> nil
local function add_upper_bound(st, tv_id, ty)
	local root = subst_mod.find(st.subst, tv_id)
	local list = st.upper_bounds[root]
	if list == nil then list = {} --[[: V5Type[] ]]; st.upper_bounds[root] = list end
	if not bounds_contains(list, ty) then list[#list + 1] = ty end
end

--: (OpSemState, integer, V5Type) -> nil
local function add_lower_bound(st, tv_id, ty)
	local root = subst_mod.find(st.subst, tv_id)
	local list = st.lower_bounds[root]
	if list == nil then list = {} --[[: V5Type[] ]]; st.lower_bounds[root] = list end
	if not bounds_contains(list, ty) then list[#list + 1] = ty end
end

--: (OpSemConstraint, Subst) -> { [integer]: boolean }
local function blockers_of(c, s)
	local acc = {} --[[: { [integer]: boolean } ]]
	if c.tag == "ceq" then
		local a = subst_mod.deref(s, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(s, c.b) --[[: V5Type ]]
		if a.tag == "uvar" then acc[a.id] = true end
		if b.tag == "uvar" then acc[b.id] = true end
	elseif c.tag == "csub" then
		local a = subst_mod.deref(s, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(s, c.b) --[[: V5Type ]]
		if a.tag == "uvar" then acc[a.id] = true end
		if b.tag == "uvar" then acc[b.id] = true end
	elseif c.tag == "topen" then acc[c.tv] = true
	elseif c.tag == "tset"  then acc[c.tv] = true
	elseif c.tag == "tseal" then acc[c.tv] = true
	elseif c.tag == "mcall" then acc[c.tv] = true
	elseif c.tag == "crow_extend" then
		local cr = c --[[: ConstraintRowExtend ]]
		local rt = subst_mod.deref(s, cr.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "crow_lacks" then
		local cl = c --[[: ConstraintRowLacks ]]
		local rt = subst_mod.deref(s, cl.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "crow_close" then
		local cc2 = c --[[: ConstraintRowClose ]]
		local rt = subst_mod.deref(s, cc2.record_ty)
		if rt.tag == "uvar" then acc[rt.id] = true end
	elseif c.tag == "cint_member" then
		local cm = c --[[: ConstraintIntMember ]]
		local ty = subst_mod.deref(s, cm.ty)
		if ty.tag == "uvar" then acc[ty.id] = true end
	end
	return acc
end

--: (OpSemState, OpSemConstraint) -> nil
local function park(st, c)
	st.inert[c.id] = c
	if c.tag == "hounify" then
		-- HOUnify parks on head rigidity of f's underlying uvar.
		local f = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
		if f.tag == "uvar" then
			subst_mod.watch_head(st.subst, f.id, c.id)
		end
		return
	end
	if c.tag == "chkt" then
		-- CHKT parks on head rigidity of f's uvar (same wake condition as HOUnify).
		local f = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
		if f.tag == "uvar" then
			subst_mod.watch_head(st.subst, f.id, c.id)
		end
		return
	end
	if c.tag == "crow_lacks" then
		-- CRowLacks parks on either the record_ty UVar (if not yet concrete) or
		-- on the open row-var id (if record is already concrete with open row).
		local cl = c --[[: ConstraintRowLacks ]]
		local rt = subst_mod.deref(st.subst, cl.record_ty)
		if rt.tag == "uvar" then
			subst_mod.watch(st.subst, rt.id, c.id)
		elseif rt.tag == "record" then
			local rrow = rt.row --[[: TRowVar | nil ]]
			if rrow ~= nil then
				watch_rowvar(st, rrow.id, c.id)
			end
		end
		return
	end
	local b = blockers_of(c, st.subst)
	for tv in pairs(b) do subst_mod.watch(st.subst, tv, c.id) end
end

-- ────────────────────────────────────────────────────────────────────────────
-- T-CEq family
-- ────────────────────────────────────────────────────────────────────────────

-- T-CEq-UU: both sides UVar.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_UU(st, a, b, prov)
	-- internal: dispatcher guarantees both are uvar; fires only on solver bug
	if a.tag ~= "uvar" then err(st, "T-CEq-UU", "precondition a must be uvar"); return "error" end
	-- internal: dispatcher guarantees both are uvar; fires only on solver bug
	if b.tag ~= "uvar" then err(st, "T-CEq-UU", "precondition b must be uvar"); return "error" end
	if a.id == b.id then trace(st, "T-CEq-UU", "refl"); return "done" end
	local _w, loser = subst_mod.union(st.subst, a.id, b.id)
	if loser ~= nil then wake(st, loser) end
	trace(st, "T-CEq-UU", "union")
	return "done"
end

-- T-CEq-Bind-L.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Bind_L(st, a, b, prov)
	-- internal: dispatcher routes here only when a=uvar; fires only on solver bug
	if a.tag ~= "uvar" then err(st, "T-CEq-Bind-L", "precondition a must be uvar"); return "error" end
	-- internal: dispatcher routes here only when b is concrete; fires only on solver bug
	if b.tag == "uvar" then err(st, "T-CEq-Bind-L", "precondition b must be concrete"); return "error" end
	local seen = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(b, seen)
	local root = subst_mod.find(st.subst, a.id)
	if seen[root] == true then
		err(st, "T-CEq-Occurs", "occurs check failed",
			prov, { tag = "occurs_check", a_name = tostring(a.id) })
		return "error"
	end
	if subst_mod.bind(st.subst, a.id, b) then
		wake(st, a.id)
		wake_head(st, a.id)
	end
	trace(st, "T-CEq-Bind-L", "bound")
	return "done"
end

-- T-CEq-Bind-R.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Bind_R(st, a, b, prov)
	return M.rule_T_CEq_Bind_L(st, b, a, prov)
end

-- T-CEq-Const.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Const(st, a, b, prov)
	-- internal: dispatcher routes here only when both are const; fires only on solver bug
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CEq-Const", "precondition: both const"); return "error"
	end
	if a.name ~= b.name then
		err(st, "T-CEq-Const", "const mismatch: " .. a.name .. " vs " .. b.name,
			prov, { tag = "const_mismatch", a_name = a.name, b_name = b.name })
		return "error"
	end
	trace(st, "T-CEq-Const", a.name)
	return "done"
end

-- T-CEq-Arrow.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Arrow(st, a, b, prov)
	-- internal: dispatcher routes here only when both are arrow; fires only on solver bug
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CEq-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CEq-Arrow", "arity mismatch", prov,
			{ tag = "arrow_arity_mismatch", expected = #b.args, got = #a.args })
		return "error"
	end
	for i = 1, #a.args do
		local av, bv = a.args[i], b.args[i]
		if av ~= nil and bv ~= nil then M.emit(st, constraint_mod.eq(av, bv, prov)) end
	end
	M.emit(st, constraint_mod.eq(a.ret, b.ret, prov))
	trace(st, "T-CEq-Arrow", "")
	return "done"
end

-- is_positional: true iff record fields are exactly the string keys "1".."n"
-- for some n >= 0, with no gaps and no non-numeric keys.
-- Keys are stored as strings (tostring(i)) per the substrate in types.lua.
--: (V5Type) -> boolean
local function is_positional(r)
	if r.tag ~= "record" then return false end
	local n = 0
	for _ in pairs(r.fields) do n = n + 1 end
	for i = 1, n do
		if r.fields[tostring(i)] == nil then return false end
	end
	return true
end

-- T-CEq-Record.
-- Dispatch: both positional -> arity-check then per-field eq.
--           named/mixed    -> existing invariant domain-equality check.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Record(st, a, b, prov)
	-- internal: dispatcher routes here only when both are record; fires only on solver bug
	if a.tag ~= "record" or b.tag ~= "record" then
		err(st, "T-CEq-Record", "precondition: both record"); return "error"
	end
	local a_pos = is_positional(a)
	local b_pos = is_positional(b)
	if a_pos and b_pos then
		-- Positional branch: eq is strict on arity (no nil-pad for eq).
		local na, nb = 0, 0
		for _ in pairs(a.fields) do na = na + 1 end
		for _ in pairs(b.fields) do nb = nb + 1 end
		if na ~= nb then
			err(st, "T-CEq-Record", "positional arity mismatch: " .. na .. " vs " .. nb,
				prov, { tag = "record_arity_mismatch", expected = nb, got = na })
			return "error"
		end
		for i = 1, na do
			local va = a.fields[tostring(i)]
			local vb = b.fields[tostring(i)]
			if va ~= nil and vb ~= nil then
				M.emit(st, constraint_mod.eq(va, vb, prov))
			end
		end
		trace(st, "T-CEq-Record", "positional n=" .. na)
		return "done"
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- Conservative choice: treat as named-key domain mismatch if keys differ.
	for k, va in pairs(a.fields) do
		local vb = b.fields[k]
		if vb == nil then
			err(st, "T-CEq-Record", "missing field " .. k, prov,
				{ tag = "missing_field", field = k })
		elseif va ~= nil then
			M.emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
	for k, _ in pairs(b.fields) do
		if a.fields[k] == nil then
			err(st, "T-CEq-Record", "extra field " .. k, prov,
				{ tag = "extra_field", field = k })
		end
	end
	trace(st, "T-CEq-Record", "")
	return "done"
end

-- T-CEq-App.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_App(st, a, b, prov)
	-- internal: dispatcher routes here only when both are app; fires only on solver bug
	if a.tag ~= "app" then err(st, "T-CEq-App", "precondition: a app"); return "error" end
	if b.tag ~= "app" then err(st, "T-CEq-App", "precondition: b app"); return "error" end
	local af = a.f --[[: V5Type ]]
	local bf = b.f --[[: V5Type ]]
	local aa = a.a --[[: V5Type ]]
	local ba = b.a --[[: V5Type ]]
	M.emit(st, constraint_mod.eq(af, bf, prov))
	M.emit(st, constraint_mod.eq(aa, ba, prov))
	trace(st, "T-CEq-App", "")
	return "done"
end

-- T-CEq-Mismatch.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Mismatch(st, a, b, prov)
	err(st, "T-CEq-Mismatch", "kind mismatch: " .. a.tag .. " vs " .. b.tag,
		prov, { tag = "kind_mismatch", a_tag = a.tag, b_tag = b.tag })
	return "error"
end

-- Dispatcher.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
local function step_ceq(st, ra, rb, prov)
	if ra.tag == "uvar" and rb.tag == "uvar" then return M.rule_T_CEq_UU(st, ra, rb, prov) end
	if ra.tag == "uvar" then return M.rule_T_CEq_Bind_L(st, ra, rb, prov) end
	if rb.tag == "uvar" then return M.rule_T_CEq_Bind_R(st, ra, rb, prov) end
	if ra.tag ~= rb.tag then return M.rule_T_CEq_Mismatch(st, ra, rb, prov) end
	if ra.tag == "const" then return M.rule_T_CEq_Const(st, ra, rb, prov) end
	if ra.tag == "arrow" then return M.rule_T_CEq_Arrow(st, ra, rb, prov) end
	if ra.tag == "record" then return M.rule_T_CEq_Record(st, ra, rb, prov) end
	if ra.tag == "app" then return M.rule_T_CEq_App(st, ra, rb, prov) end
	return M.rule_T_CEq_Mismatch(st, ra, rb, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- T-CSub family (variance-respecting)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Per `docs/typechecker-v5-operational-semantics.md` § "Subtyping (variance-
-- respecting)".  Declaration-site variance via `variance.lookup(name)`;
-- default = invariant.  Soundness floor: record fields are invariant in
-- v5.0 (CTableSet model — mutable fields can't be covariant).

-- T-CSub-Refl.  Same type both sides under deref.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Refl(st, a, b, prov)
	-- internal: dispatcher calls this only after equal() returns true; fires only on solver bug
	if not types_mod.equal(a, b) then
		err(st, "T-CSub-Refl", "precondition: types equal"); return "error"
	end
	trace(st, "T-CSub-Refl", "")
	return "done"
end

-- T-CSub-TVar.  Either side is an unbound UVar.
--
-- v5.0 discipline:
--   (a) ra=uvar, rb=concrete → PARK watching ra.  When ra is later bound
--       (e.g. by a CRowExtend-Lookup CEq), the sub is retried with the
--       concrete type.  At S-Quiesce, any still-parked csub with unbound
--       ra gets ra bound to rb (upper-bound assignment).
--   (b) ra=concrete, rb=uvar → emit CEq to bind rb := ra (lower bound).
--   (c) Both uvars           → emit CEq (symmetric).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_TVar(st, a, b, prov)
	if a.tag == "uvar" and b.tag ~= "uvar" then
		-- Park: wait for a to be bound, then retry sub(a_bound, b).
		-- Record `b` as an upper bound of a; at S-Quiesce the uvar binds to
		-- the meet (intersection) of accumulated upper bounds.
		add_upper_bound(st, a.id, b)
		trace(st, "T-CSub-TVar", "ra=uvar → park watching ra=" .. tostring(a.id))
		return "stuck"
	end
	if b.tag == "uvar" and a.tag ~= "uvar" then
		-- Record `a` as a lower bound of b for later verification, then
		-- fall through to the CEq route (preserves existing behavior).
		add_lower_bound(st, b.id, a)
	end
	-- rb=uvar (and ra concrete), or both uvars: route to CEq.
	M.emit(st, constraint_mod.eq(a, b, prov))
	trace(st, "T-CSub-TVar", "routed to CEq")
	return "done"
end

-- T-CSub-Arrow.  Contra in args, co in rets.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Arrow(st, a, b, prov)
	-- internal: dispatcher routes here only when both are arrow; fires only on solver bug
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CSub-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CSub-Arrow", "arity mismatch", prov,
			{ tag = "arrow_arity_mismatch", expected = #b.args, got = #a.args })
		return "error"
	end
	for i = 1, #a.args do
		local av, bv = a.args[i], b.args[i]
		if av ~= nil and bv ~= nil then
			-- contravariant in args: B_i <: A_i.
			M.emit(st, constraint_mod.sub(bv, av, prov))
		end
	end
	-- covariant in ret: delegate to positional Record rules (Phase 3).
	M.emit(st, constraint_mod.sub(a.ret, b.ret, prov))
	trace(st, "T-CSub-Arrow", "")
	return "done"
end

-- T-CSub-Const-Var.  Two same-named Consts; degenerate (no params on AST).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Const_Var(st, a, b, prov)
	-- internal: dispatcher routes here only when both are const; fires only on solver bug
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CSub-Const-Var", "precondition: both const"); return "error"
	end
	if a.name ~= b.name then
		err(st, "T-CSub-Const-Var",
			"const name mismatch: " .. a.name .. " vs " .. b.name,
			prov, { tag = "const_mismatch", a_name = a.name, b_name = b.name })
		return "error"
	end
	trace(st, "T-CSub-Const-Var", a.name)
	return "done"
end

-- Walk a left-associated App chain to extract the head Const name and its
-- argument list (innermost-first reversal — args in source order).
-- Returns (head_name, args[]) where head_name is nil if the head is not
-- a Const.  Using head name (string) instead of returning the Const itself
-- sidesteps narrowing through the union return type.
--: (V5Type) -> (string | nil, V5Type[])
local function app_head_and_args(t)
	local args = {} --[[: V5Type[] ]]
	local cur = t
	while cur.tag == "app" do
		-- cur.f is the curried head; cur.a is the rightmost arg.
		args[#args + 1] = cur.a
		cur = cur.f
	end
	-- Reverse args so source-order matches (outermost App carries last arg).
	local n = #args
	local sorted = {} --[[: V5Type[] ]]
	for i = 1, n do sorted[i] = args[n - i + 1] end
	if cur.tag == "const" then return cur.name, sorted end
	return nil, sorted
end

-- T-CSub-App-Var.  Two applications with matching named head — per-position
-- variance dispatch.  Returns "miss" if heads aren't both Consts with the
-- same name (caller falls to T-CSub-App-Struct).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_App_Var(st, a, b, prov)
	local ha, aa = app_head_and_args(a)
	local hb, ab = app_head_and_args(b)
	if ha == nil or hb == nil then return "miss" end
	if ha ~= hb then
		err(st, "T-CSub-App-Var",
			"head mismatch: " .. ha .. " vs " .. hb,
			prov, { tag = "head_mismatch", a_name = ha, b_name = hb })
		return "error"
	end
	if #aa ~= #ab then
		err(st, "T-CSub-App-Var",
			"arity mismatch for " .. ha, prov,
			{ tag = "arrow_arity_mismatch", expected = #ab, got = #aa })
		return "error"
	end
	for i = 1, #aa do
		local xi, yi = aa[i], ab[i]
		if xi ~= nil and yi ~= nil then
			local v = variance_mod.at(ha, i)
			if v == "co" then
				M.emit(st, constraint_mod.sub(xi, yi, prov))
			elseif v == "contra" then
				M.emit(st, constraint_mod.sub(yi, xi, prov))
			else
				M.emit(st, constraint_mod.eq(xi, yi, prov))
			end
		end
	end
	trace(st, "T-CSub-App-Var", ha)
	return "done"
end

-- T-CSub-App-Struct.  Non-Const head fallback: decompose under invariance.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_App_Struct(st, a, b, prov)
	-- internal: dispatcher routes here only when both are app; fires only on solver bug
	if a.tag ~= "app" or b.tag ~= "app" then
		err(st, "T-CSub-App-Struct", "precondition: both app"); return "error"
	end
	M.emit(st, constraint_mod.eq(a.f, b.f, prov))
	M.emit(st, constraint_mod.eq(a.a, b.a, prov))
	trace(st, "T-CSub-App-Struct", "")
	return "done"
end

-- T-CSub-Record-Width.  Width subtyping with invariant fields.  Supertype
-- (b) has fewer fields; each common field is required equal.
-- Dispatch: both positional -> covariant per-field sub with nil-pad width
--           policy; named/mixed -> existing invariant domain check.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Record_Width(st, a, b, prov)
	-- internal: dispatcher routes here only when both are record; fires only on solver bug
	if a.tag ~= "record" or b.tag ~= "record" then
		err(st, "T-CSub-Record-Width", "precondition: both record"); return "error"
	end
	local a_pos = is_positional(a)
	local b_pos = is_positional(b)
	if a_pos and b_pos then
		-- Positional covariant branch (Arrow returns).
		-- Nil-pad policy: the shorter side gets Const("nil") for missing
		-- positions so sub(va, vb) is always well-formed regardless of which
		-- side is wider.
		local na, nb = 0, 0
		for _ in pairs(a.fields) do na = na + 1 end
		for _ in pairs(b.fields) do nb = nb + 1 end
		local n = na > nb and na or nb
		local nil_type = types_mod.const("nil")
		for i = 1, n do
			local va = a.fields[tostring(i)] or nil_type
			local vb = b.fields[tostring(i)] or nil_type
			M.emit(st, constraint_mod.sub(va, vb, prov))
		end
		trace(st, "T-CSub-Record-Width", "positional covariant na=" .. na .. " nb=" .. nb)
		return "done"
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- Conservative choice: treat as named-key subtyping; key-shape mismatch
	-- surfaces as a missing-field error when the positional string keys ("1",
	-- "2", ...) don't appear in the named record.
	for k, vb in pairs(b.fields) do
		local va = a.fields[k]
		if va == nil then
			err(st, "T-CSub-Record-Width", "missing field " .. k, prov,
				{ tag = "missing_field", field = k })
		elseif vb ~= nil then
			-- Invariant: fields are mutable in v5.0 (per CTableSet model).
			M.emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
	trace(st, "T-CSub-Record-Width", "")
	return "done"
end

-- T-CSub-Union-L.  LHS is union: each branch subtypes RHS.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Union_L(st, a, b, prov)
	-- internal: dispatcher routes here only when a=union; fires only on solver bug
	if a.tag ~= "union" then
		err(st, "T-CSub-Union-L", "precondition: a union"); return "error"
	end
	for i = 1, #a.xs do
		local ai = a.xs[i]
		if ai ~= nil then M.emit(st, constraint_mod.sub(ai, b, prov)) end
	end
	trace(st, "T-CSub-Union-L", "")
	return "done"
end

-- T-CSub-Union-R.  RHS is union: LHS must exactly equal some branch.
-- v5.0 simplification (no backtracking search).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Union_R(st, a, b, prov)
	-- internal: dispatcher routes here only when b=union; fires only on solver bug
	if b.tag ~= "union" then
		err(st, "T-CSub-Union-R", "precondition: b union"); return "error"
	end
	for j = 1, #b.xs do
		local bj = b.xs[j]
		if bj ~= nil and types_mod.equal(a, bj) then
			trace(st, "T-CSub-Union-R", "matched branch " .. tostring(j))
			return "done"
		end
	end
	err(st, "T-CSub-Union-R", "no branch matches LHS exactly (v5.0 limitation)",
		prov, { tag = "no_matching_branch", value_ty = a, union_ty = b })
	return "error"
end

-- T-CSub-Mismatch.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Mismatch(st, a, b, prov)
	err(st, "T-CSub-Mismatch", "sub kind mismatch: " .. a.tag .. " vs " .. b.tag,
		prov, { tag = "kind_mismatch", a_tag = a.tag, b_tag = b.tag })
	return "error"
end

-- T-CSub-Top.  `unknown` is the top type: anything subtypes it.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Top(st, ra, rb, prov)
	-- Precondition (caller checks): rb is const("unknown").
	local _ = ra; local _ = prov  -- suppress unused warnings
	trace(st, "T-CSub-Top", "sub const=unknown (top type)")
	return "done"
end

-- T-CSub-Never.  `never` is the bottom type: it subtypes anything.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Never(st, ra, rb, prov)
	-- Precondition (caller checks): ra is const("never").
	local _ = rb; local _ = prov  -- suppress unused warnings
	trace(st, "T-CSub-Never", "sub const=never (bottom type)")
	return "done"
end

-- CSub dispatcher.  Order matters: Refl first (cheap fast path), then TVar
-- (must precede shape dispatch — uvars masquerade as no tag here), then
-- top/bottom, then by tag.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
local function step_csub(st, ra, rb, prov)
	-- Refl fast path.
	if types_mod.equal(ra, rb) then
		return M.rule_T_CSub_Refl(st, ra, rb, prov)
	end
	-- TVar route.
	if ra.tag == "uvar" or rb.tag == "uvar" then
		return M.rule_T_CSub_TVar(st, ra, rb, prov)
	end
	-- Top type: unknown is a supertype of everything.
	if rb.tag == "const" and rb.name == "unknown" then
		return M.rule_T_CSub_Top(st, ra, rb, prov)
	end
	-- Bottom type: never is a subtype of everything.
	if ra.tag == "const" and ra.name == "never" then
		return M.rule_T_CSub_Never(st, ra, rb, prov)
	end
	-- Literal widening: $Lit<S> <: string, $LitInt<N> <: integer | number,
	-- $LitNum<N> <: number.  These rules let annotated function parameters
	-- of type `string`/`number`/`integer` accept literal-typed call-site args.
	if ra.tag == "app" and rb.tag == "const" then
		local ra_f = ra.f
		if ra_f ~= nil and ra_f.tag == "const" then
			local fname = ra_f.name
			if fname == "$Lit" and rb.name == "string" then
				trace(st, "T-CSub-LitWiden", "$Lit<S> <: string")
				return "done"
			end
			if fname == "$LitInt" and (rb.name == "integer" or rb.name == "number") then
				trace(st, "T-CSub-LitWiden", "$LitInt<N> <: " .. rb.name)
				return "done"
			end
			if fname == "$LitNum" and rb.name == "number" then
				trace(st, "T-CSub-LitWiden", "$LitNum<N> <: number")
				return "done"
			end
			-- true / false literals subtype boolean.
			if (ra_f.name == "true" or ra_f.name == "false") and rb.name == "boolean" then
				trace(st, "T-CSub-LitWiden", "bool literal <: boolean")
				return "done"
			end
		end
		-- const("true") / const("false") <: boolean handled below in same-const branch,
		-- but for safety also handle TApp where head is "true"/"false" here.
	end
	-- Boolean literal constants: const("true") <: boolean, const("false") <: boolean.
	if ra.tag == "const" and rb.tag == "const" then
		if (ra.name == "true" or ra.name == "false") and rb.name == "boolean" then
			trace(st, "T-CSub-LitWiden", "bool const <: boolean")
			return "done"
		end
	end
	-- Union dispatch (L takes priority over R; both can apply if both sides
	-- are unions — emit per-branch sub from L, the recursive call will see
	-- RHS-only-union on each branch).
	if ra.tag == "union" then
		return M.rule_T_CSub_Union_L(st, ra, rb, prov)
	end
	if rb.tag == "union" then
		return M.rule_T_CSub_Union_R(st, ra, rb, prov)
	end
	-- Intersection dispatch (LHS decomp first; if both sides are
	-- intersections, the recursive call lands on RHS-only intersection).
	if ra.tag == "intersection" then
		return M.rule_T_CSub_Intersection_Decomp(st, ra.parts, rb, prov)
	end
	if rb.tag == "intersection" then
		return M.rule_T_CSub_Intersection_Conj(st, ra, rb.parts, prov)
	end
	-- Same-tag dispatch.
	if ra.tag == rb.tag then
		if ra.tag == "const" then
			return M.rule_T_CSub_Const_Var(st, ra, rb, prov)
		end
		if ra.tag == "arrow" then
			return M.rule_T_CSub_Arrow(st, ra, rb, prov)
		end
		if ra.tag == "record" then
			return M.rule_T_CSub_Record_Width(st, ra, rb, prov)
		end
		if ra.tag == "app" then
			local status = M.rule_T_CSub_App_Var(st, ra, rb, prov)
			if status == "miss" then
				return M.rule_T_CSub_App_Struct(st, ra, rb, prov)
			end
			return status
		end
		-- Var / lambda / etc.: fall back to equality.
		M.emit(st, constraint_mod.eq(ra, rb, prov))
		trace(st, "T-CSub-Struct", "fallback CEq for tag=" .. ra.tag)
		return "done"
	end
	return M.rule_T_CSub_Mismatch(st, ra, rb, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Intersection rules (Phase 4)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Effects ARE types — `!io`, `!throw<E>`, `!yield<Y,R>` are TConst (with a
-- "!" prefix) and TApp chains over them, handled uniformly with all other
-- types under intersection.  Canonical form (flatten/sort/dedupe) lives in
-- constraint_mod so both interpreters share a single source of truth.

-- T-CIntersectionEq-Canonical.  Canonicalize both sides; if lengths differ
-- after canonicalization → error.  Else emit pair-wise CEq.
--: (OpSemState, V5Type[], V5Type[], Provenance) -> string
function M.rule_T_CIntersectionEq_Canonical(st, parts_a, parts_b, prov)
	local ca = constraint_mod.flatten_parts(parts_a)
	local cb = constraint_mod.flatten_parts(parts_b)
	if #ca ~= #cb then
		err(st, "T-CIntersectionEq-Canonical",
			"intersection arity mismatch after canonicalization: " ..
			tostring(#ca) .. " vs " .. tostring(#cb),
			prov, { tag = "intersection_arity_mismatch", expected = #cb, got = #ca })
		return "error"
	end
	for i = 1, #ca do
		local av, bv = ca[i], cb[i]
		if av ~= nil and bv ~= nil then
			M.emit(st, constraint_mod.eq(av, bv, prov))
		end
	end
	trace(st, "T-CIntersectionEq-Canonical", "n=" .. tostring(#ca))
	return "done"
end

-- T-CSub-Intersection-Decomp.  LHS intersection: (A & B) <: C if some part
-- already proves it under types_mod.equal.  Eager fast path; v5.0 has no
-- disjunctive constraint scheduler, so all parts being unresolved tvars
-- yields a stuck error rather than a disjunction.
--: (OpSemState, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CSub_Intersection_Decomp(st, parts_lhs, rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_lhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and types_mod.equal(p, rhs) then
			trace(st, "T-CSub-Intersection-Decomp",
				"eager part-match at " .. tostring(i))
			return "done"
		end
	end
	-- No eager match — try emitting CSub on the first non-uvar part as the
	-- best-effort progress.  If every part is a uvar, error (no disjunction).
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil and p.tag ~= "uvar" then
			M.emit(st, constraint_mod.sub(p, rhs, prov))
			trace(st, "T-CSub-Intersection-Decomp", "delegated part " .. tostring(i))
			return "done"
		end
	end
	err(st, "T-CSub-Intersection-Decomp",
		"all LHS intersection parts are uvars; no disjunctive scheduler in v5.0",
		prov, { tag = "all_parts_unresolved" })
	return "error"
end

-- T-CSub-Intersection-Conj.  RHS intersection: A <: (B & C) iff A <: B AND
-- A <: C.  Emit a CSub per canonicalized RHS part.
--: (OpSemState, V5Type, V5Type[], Provenance) -> string
function M.rule_T_CSub_Intersection_Conj(st, lhs, parts_rhs, prov)
	local canon = constraint_mod.flatten_parts(parts_rhs)
	for i = 1, #canon do
		local p = canon[i]
		if p ~= nil then M.emit(st, constraint_mod.sub(lhs, p, prov)) end
	end
	trace(st, "T-CSub-Intersection-Conj", "n=" .. tostring(#canon))
	return "done"
end

-- T-CIntersectionMember-Direct.  If `ty` (post-deref) is an intersection
-- canonically containing `part`, succeed.  If unresolved uvars remain in
-- ty, park (F2 enforcement at quiescence will surface the unresolved case).
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CIntersectionMember_Direct(st, ty, part, prov)
	local dty = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if dty.tag == "uvar" then
		-- Park: when ty's uvar is bound we may decide.
		return "stuck"
	end
	if dty.tag == "intersection" then
		local canon = constraint_mod.flatten_parts(dty.parts)
		for i = 1, #canon do
			local p = canon[i]
			if p ~= nil and types_mod.equal(p, part) then
				trace(st, "T-CIntersectionMember-Direct",
					"member match at " .. tostring(i))
				return "done"
			end
		end
		err(st, "T-CIntersectionMember-Direct",
			"part not in intersection",
			prov, { tag = "effect_not_permitted", effect = part, container = dty })
		return "error"
	end
	-- Singleton case: ty IS the part itself.
	if types_mod.equal(dty, part) then
		trace(st, "T-CIntersectionMember-Direct", "singleton match")
		return "done"
	end
	err(st, "T-CIntersectionMember-Direct",
		"ty is neither intersection nor equal to part (tag=" .. dty.tag .. ")",
		prov, { tag = "effect_not_permitted", effect = part, container = dty })
	return "error"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Construction-phase rules
-- ────────────────────────────────────────────────────────────────────────────

-- T-CTOpen.
--: (OpSemState, integer, Provenance) -> string
function M.rule_T_CTOpen(st, tv, prov)
	local r = subst_mod.find(st.subst, tv)
	if subst_mod.binding(st.subst, r) ~= nil then
		trace(st, "T-CTOpen", "idempotent")
		return "done"
	end
	local rec = types_mod.record({}) --[[: V5Type ]]
	if subst_mod.bind(st.subst, r, rec) then wake(st, r); wake_head(st, r) end
	trace(st, "T-CTOpen", "bound empty")
	return "done"
end

-- T-CTSet-Open-Fresh.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local fields = {} --[[: { [string]: V5Type } ]]
	fields[key] = ty
	local rec = types_mod.record(fields) --[[: V5Type ]]
	if subst_mod.bind(st.subst, r, rec) then wake(st, r); wake_head(st, r) end
	trace(st, "T-CTSet-Open-Fresh", key)
	return "done"
end

-- T-CTSet-Open-Extend.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: dispatcher routes here after confirming binding present; fires only on solver bug
	if b == nil then
		err(st, "T-CTSet-Open-Extend", "precondition: tv bound"); return "error"
	end
	-- internal: dispatcher routes here after confirming record type; fires only on solver bug
	if b.tag ~= "record" then
		err(st, "T-CTSet-Open-Extend", "precondition: tv bound to record"); return "error"
	end
	b.fields[key] = ty
	wake(st, r)
	trace(st, "T-CTSet-Open-Extend", key)
	return "done"
end

-- T-CTSet-Open-Equate.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: dispatcher routes here after confirming binding present; fires only on solver bug
	if b == nil then err(st, "T-CTSet-Open-Equate", "precondition: tv bound"); return "error" end
	-- internal: dispatcher routes here after confirming record type; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CTSet-Open-Equate", "precondition: record"); return "error" end
	local existing = b.fields[key]
	-- internal: dispatcher routes here after confirming field present; fires only on solver bug
	if existing == nil then err(st, "T-CTSet-Open-Equate", "precondition: field present"); return "error" end
	M.emit(st, constraint_mod.eq(existing, ty, prov))
	trace(st, "T-CTSet-Open-Equate", key)
	return "done"
end

-- T-CTSet-Sealed-Reject.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Sealed_Reject(st, tv, key, ty, prov)
	err(st, "T-CTSet-Sealed-Reject", "set " .. key .. " on sealed table (tv=" .. tostring(tv) .. ")",
		prov, { tag = "sealed_field_set", field = key })
	return "error"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_tset(st, c)
	if c.tag ~= "tset" then return "done" end
	local r = subst_mod.find(st.subst, c.tv)
	local phase = subst_mod.phase(st.subst, r)
	if phase == "sealed" then
		return M.rule_T_CTSet_Sealed_Reject(st, c.tv, c.key, c.ty, c.prov)
	end
	local b = subst_mod.binding(st.subst, r)
	if b == nil then
		return M.rule_T_CTSet_Open_Fresh(st, c.tv, c.key, c.ty, c.prov)
	end
	-- internal: binding is present but not a record; indicates a solver invariant violation
	if b.tag ~= "record" then
		err(st, "T-CTSet", "tv bound to non-record"); return "error"
	end
	if b.fields[c.key] == nil then
		return M.rule_T_CTSet_Open_Extend(st, c.tv, c.key, c.ty, c.prov)
	end
	return M.rule_T_CTSet_Open_Equate(st, c.tv, c.key, c.ty, c.prov)
end

-- T-CTSeal.
--: (OpSemState, integer, integer | nil, Provenance) -> string
function M.rule_T_CTSeal(st, tv, mu, prov)
	subst_mod.seal(st.subst, tv)
	wake(st, tv)
	trace(st, "T-CTSeal", "")
	return "done"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Method-call rules
-- ────────────────────────────────────────────────────────────────────────────

-- T-CMCall-Open-Stuck.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	trace(st, "T-CMCall-Open-Stuck", key)
	return "stuck"
end

-- T-CMCall-Sealed-Field.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
	local r = subst_mod.find(st.subst, tv)
	local b = subst_mod.binding(st.subst, r)
	-- internal: step_mcall routes here after confirming sealed+bound; fires only on solver bug
	if b == nil then err(st, "T-CMCall-Sealed-Field", "precondition: bound"); return "error" end
	-- internal: step_mcall routes here after confirming record; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CMCall-Sealed-Field", "precondition: record"); return "error" end
	local mraw = b.fields[key]
	-- internal: step_mcall routes here after confirming field exists; fires only on solver bug
	if mraw == nil then err(st, "T-CMCall-Sealed-Field", "precondition: field present"); return "error" end
	local m = mraw --[[: V5Type ]]
	-- internal: field found but is not callable (type inconsistency); fires only on solver bug
	if m.tag ~= "arrow" then err(st, "T-CMCall-Sealed-Field", "field is not callable"); return "error" end
	local r1raw = m.ret.fields["1"]
	-- internal: arrow has no return slots; fires only on solver bug
	if r1raw == nil then err(st, "T-CMCall-Sealed-Field", "arrow with zero rets"); return "error" end
	local r1 = r1raw --[[: V5Type ]]
	local lhs = types_mod.uvar(ret) --[[: V5Type ]]
	M.emit(st, constraint_mod.eq(lhs, r1, prov))
	trace(st, "T-CMCall-Sealed-Field", key)
	return "done"
end

-- T-CMCall-Sealed-Missing.
--: (OpSemState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Sealed_Missing(st, tv, key, ret, prov)
	err(st, "T-CMCall-Sealed-Missing", "no method " .. key,
		prov, { tag = "missing_method", method = key })
	return "error"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_mcall(st, c)
	if c.tag ~= "mcall" then return "done" end
	local r = subst_mod.find(st.subst, c.tv)
	local phase = subst_mod.phase(st.subst, r)
	if phase == "open" then
		return M.rule_T_CMCall_Open_Stuck(st, c.tv, c.key, c.ret, c.prov)
	end
	local b = subst_mod.binding(st.subst, r)
	-- internal: phase=sealed but tv has no binding; fires only on solver bug
	if b == nil then err(st, "T-CMCall", "sealed tv unbound"); return "error" end
	-- internal: binding is not a record; fires only on solver bug
	if b.tag ~= "record" then err(st, "T-CMCall", "sealed tv not a record"); return "error" end
	if b.fields[c.key] == nil then
		return M.rule_T_CMCall_Sealed_Missing(st, c.tv, c.key, c.ret, c.prov)
	end
	return M.rule_T_CMCall_Sealed_Field(st, c.tv, c.key, c.ret, c.prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- CRow rules (row-polymorphic records)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Row variables live on TRecord.row (a TRowVar node or nil).
-- nil means closed (no further extension allowed).
-- A TRowVar with id means open (may grow).
--
-- CRow constraints operate on an entire TRecord type (not a tvar id) so the
-- solver must first deref the record_ty argument to find the concrete record.
-- If record_ty is still a UVar, the rule parks on that UVar.
--
-- Row-var ids are separate from UVar ids.  They are tracked in a simple
-- counter; no union-find (row vars are either open or closed, never merged
-- with other row vars directly — field CEqs handle structural sharing).

-- Row-var ids are created by callers (e.g. tests) using types_mod.rowvar(id)
-- and types_mod.record_open(fields, row).  The solver does not allocate new
-- row vars in Phase 2; it only reads and closes them.

-- Deref the record_ty through UVars; return the record or nil if still stuck.
--: (OpSemState, V5Type) -> (V5Type | nil, boolean)
-- Returns (record_type, is_stuck).  is_stuck=true means park on the uvar.
local function deref_to_record(st, ty)
	local t = subst_mod.deref(st.subst, ty) --[[: V5Type ]]
	if t.tag == "uvar" then return nil, true end
	if t.tag == "record" then return t, false end
	return nil, false -- concrete non-record: error at caller
end

-- T-CRowExtend-Bind: record has an open row var → add key to fields and keep row open.
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Bind(st, _rec_ty, rec, key, field_ty, _prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Bind", "precondition: record"); return "error" end
	-- internal: dispatcher routes here only for open-row case; fires only on solver bug
	if rec.row == nil then err(st, "T-CRowExtend-Bind", "precondition: open row"); return "error" end
	-- Mutate field into the record (monotone extension — no overwrite).
	rec.fields[key] = field_ty
	trace(st, "T-CRowExtend-Bind", "bound " .. key)
	return "done"
end

-- T-CRowExtend-Lookup: record already has the key → emit CEq(existing, field_ty).
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Lookup(st, _rec_ty, rec, key, field_ty, prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Lookup", "precondition: record"); return "error" end
	local existing = rec.fields[key]
	-- internal: dispatcher routes here only when key already present; fires only on solver bug
	if existing == nil then err(st, "T-CRowExtend-Lookup", "precondition: key present"); return "error" end
	M.emit(st, constraint_mod.eq(existing, field_ty, prov))
	trace(st, "T-CRowExtend-Lookup", "equated " .. key)
	return "done"
end

-- T-CRowExtend-Closed: closed record missing key → ERROR.
--: (OpSemState, V5Type, V5Type, string, V5Type, Provenance) -> string
function M.rule_T_CRowExtend_Closed(st, _rec_ty, rec, key, _field_ty, prov)
	-- internal: caller deref_to_record already confirmed record; fires only on solver bug
	if rec.tag ~= "record" then err(st, "T-CRowExtend-Closed", "precondition: record"); return "error" end
	err(st, "T-CRowExtend-Closed", "closed record cannot extend: key=" .. key,
		prov, { tag = "closed_extend", field = key })
	return "error"
end

--: (OpSemState, V5Type, string, V5Type, Provenance) -> string
local function step_crow_extend(st, record_ty, key, field_ty, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then
		-- record_ty is still a UVar; park (blockers_of picks up the watcher).
		return "stuck"
	end
	if rec == nil then
		local tag = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowExtend", "record_ty is not a record: tag=" .. tag,
			prov, { tag = "not_a_record", found_tag = tag })
		return "error"
	end
	-- Dispatch on row state.
	if rec.row ~= nil then
		-- Open row.
		if rec.fields[key] ~= nil then
			return M.rule_T_CRowExtend_Lookup(st, record_ty, rec, key, field_ty, prov)
		end
		return M.rule_T_CRowExtend_Bind(st, record_ty, rec, key, field_ty, prov)
	end
	-- Closed row (row == nil).
	if rec.fields[key] ~= nil then
		return M.rule_T_CRowExtend_Lookup(st, record_ty, rec, key, field_ty, prov)
	end
	return M.rule_T_CRowExtend_Closed(st, record_ty, rec, key, field_ty, prov)
end

-- T-CRowLacks-Open: row is open → park watching the row-var id.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Open(st, _rec_ty, rec, key, _prov)
	local rrow = rec.row
	-- internal: dispatcher routes here only when row is open; fires only on solver bug
	if rrow == nil then err(st, "T-CRowLacks-Open", "precondition: open row"); return "error" end
	trace(st, "T-CRowLacks-Open", "park on rowvar " .. rrow.id .. " key=" .. key)
	return "stuck"
end

-- T-CRowLacks-Closed-Pass: closed and key absent → succeed.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Closed_Pass(st, _rec_ty, _rec, key, _prov)
	trace(st, "T-CRowLacks-Closed-Pass", "key absent: " .. key)
	return "done"
end

-- T-CRowLacks-Closed-Fail: closed and key present → ERROR.
--: (OpSemState, V5Type, V5Type, string, Provenance) -> string
function M.rule_T_CRowLacks_Closed_Fail(st, _rec_ty, _rec, key, prov)
	err(st, "T-CRowLacks-Closed-Fail", "row already contains key: " .. key,
		prov, { tag = "row_already_contains", field = key })
	return "error"
end

--: (OpSemState, V5Type, string, Provenance) -> string
local function step_crow_lacks(st, record_ty, key, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		local tag2 = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowLacks", "record_ty is not a record",
			prov, { tag = "not_a_record", found_tag = tag2 })
		return "error"
	end
	if rec.row ~= nil then
		-- Open row: park watching the row-var id so CRowClose can wake us.
		return M.rule_T_CRowLacks_Open(st, record_ty, rec, key, prov)
	end
	-- Closed.
	if rec.fields[key] ~= nil then
		return M.rule_T_CRowLacks_Closed_Fail(st, record_ty, rec, key, prov)
	end
	return M.rule_T_CRowLacks_Closed_Pass(st, record_ty, rec, key, prov)
end

-- T-CRowClose-Bind: close the row var of a record (set row = nil).
-- If already closed, no-op.
--: (OpSemState, V5Type, Provenance) -> string
function M.rule_T_CRowClose_Bind(st, record_ty, prov)
	local rec, stuck = deref_to_record(st, record_ty)
	if stuck then return "stuck" end
	if rec == nil then
		local tag3 = subst_mod.deref(st.subst, record_ty).tag
		err(st, "T-CRowClose-Bind", "record_ty is not a record",
			prov, { tag = "not_a_record", found_tag = tag3 })
		return "error"
	end
	-- Capture row-var id before closing (needed to wake watchers).
	local rrow = rec.row
	if rrow == nil then
		-- Already closed (positional record or previously closed).
		trace(st, "T-CRowClose-Bind", "already closed")
		return "done"
	end
	local rv_id = rrow.id
	-- Close: set row to nil.
	rec.row = nil
	trace(st, "T-CRowClose-Bind", "closed row rv=" .. rv_id)
	-- Wake any CRowLacks constraints that were parked on this row-var.
	wake_rowvar(st, rv_id)
	return "done"
end

-- blockers_of extension: CRow constraints park on the record_ty's uvar.
-- We override the park logic in M.step via a dedicated branch.

-- ────────────────────────────────────────────────────────────────────────────
-- Instantiation
-- ────────────────────────────────────────────────────────────────────────────

-- T-CInst-Mono.
--: (OpSemState, V5Scheme, V5Type, Provenance) -> string
function M.rule_T_CInst_Mono(st, sch, target, prov)
	M.emit(st, constraint_mod.eq(sch.body, target, prov))
	trace(st, "T-CInst-Mono", "")
	return "done"
end

-- T-CInst.  Allocate `binders` fresh tvars; β-substitute into body.
-- Substitute repeatedly at depth 0: after each step the next outer Var
-- becomes Var(0).
--: (OpSemState, V5Scheme, V5Type, Provenance) -> string
function M.rule_T_CInst(st, sch, target, prov)
	if sch.binders == 0 then return M.rule_T_CInst_Mono(st, sch, target, prov) end
	local body = sch.body
	for _i = 1, sch.binders do
		local fresh = subst_mod.fresh(st.subst, "open")
		local arg = types_mod.uvar(fresh) --[[: V5Type ]]
		body = types_mod.instantiate(body, arg, 0)
	end
	M.emit(st, constraint_mod.eq(body, target, prov))
	trace(st, "T-CInst", "binders=" .. tostring(sch.binders))
	return "done"
end

--: (OpSemState, OpSemConstraint) -> string
local function step_cinst(st, c)
	if c.tag ~= "cinst" then return "done" end
	return M.rule_T_CInst(st, c.scheme, c.target, c.prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- CHKT / HOUnify (higher-kinded type application + HO unification residue)
-- ────────────────────────────────────────────────────────────────────────────

-- Collect free UVar ids in a type.
--: (V5Type, { [integer]: boolean }) -> nil
local function collect_free_uvars(t, acc)
	types_mod.collect_uvars(t, acc)
end

-- v5.0 restricted Miller pattern fragment check.  Each arg must be a UVar
-- or Const (deref'd); UVars must be pairwise distinct; T's free UVars must
-- be a subset of the arg-UVars.  Returns the allowed-uvar set if in fragment,
-- nil otherwise.
--: (Subst, V5Type[], V5Type) -> { [integer]: boolean } | nil
local function miller_check(s, args, result_walked)
	local allowed = {} --[[: { [integer]: boolean } ]]
	local seen_uvars = {} --[[: { [integer]: boolean } ]]
	local seen_consts = {} --[[: { [string]: boolean } ]]
	for i = 1, #args do
		local a = args[i]
		if a == nil then return nil end
		local da = subst_mod.deref(s, a) --[[: V5Type ]]
		if da.tag == "uvar" then
			if seen_uvars[da.id] == true then return nil end
			seen_uvars[da.id] = true
			allowed[da.id] = true
		elseif da.tag == "const" then
			if seen_consts[da.name] == true then return nil end
			seen_consts[da.name] = true
			-- Const has no UVars; nothing to allow.
		else
			-- v5.0 restriction: only UVar or Const args admitted.
			return nil
		end
	end
	local fv = {} --[[: { [integer]: boolean } ]]
	collect_free_uvars(result_walked, fv)
	for id, _ in pairs(fv) do
		if allowed[id] ~= true then return nil end
	end
	return allowed
end

-- Walker for abstract_body: replaces UVar(id) with Var(map[id]).
-- Recursive; does NOT cross nested Lambdas (returns unchanged, since
-- caller guards via contains_lambda).
--: ({ [integer]: integer }, V5Type) -> V5Type
local function abstract_sub(map, t)
	if t.tag == "uvar" then
		local idx = map[t.id]
		if idx ~= nil then return types_mod.var(idx) end
		return t
	elseif t.tag == "const" or t.tag == "var" or t.tag == "lambda" then
		return t
	elseif t.tag == "app" then
		local sf = abstract_sub(map, t.f) --[[: V5Type ]]
		local sa = abstract_sub(map, t.a) --[[: V5Type ]]
		return types_mod.app(sf, sa)
	elseif t.tag == "record" then
		local out = {} --[[: { [string]: V5Type } ]]
		for fk, fv in pairs(t.fields) do
			if fv ~= nil then local s2 = abstract_sub(map, fv) --[[: V5Type ]]; out[fk] = s2 end
		end
		return types_mod.record(out)
	elseif t.tag == "arrow" then
		local aargs = {} --[[: V5Type[] ]]
		for i = 1, #t.args do
			local v = t.args[i]
			if v ~= nil then local s2 = abstract_sub(map, v) --[[: V5Type ]]; aargs[i] = s2 end
		end
		local aret = abstract_sub(map, t.ret) --[[: V5Type ]]
		return { tag = "arrow", args = aargs, ret = aret }
	elseif t.tag == "union" then
		local xs = {} --[[: V5Type[] ]]
		for i = 1, #t.xs do
			local v = t.xs[i]
			if v ~= nil then local s2 = abstract_sub(map, v) --[[: V5Type ]]; xs[i] = s2 end
		end
		return types_mod.union(xs)
	end
	return t
end

-- Abstract a body over a list of UVar-args, producing a nested Lambda chain.
-- For args = [u1, u2, ..., un], produces  Lambda(_, Lambda(_, ... Lambda(_, body')))
-- where body' has UVar(ui.id) replaced by Var(n - i)  (so u1 -> Var(n-1),
-- u_n -> Var(0)).  v5.0 restriction: assumes body has no inner Lambdas
-- (capture-avoiding shift over nested lambdas is a spec gap; caller must
-- guard via contains_lambda).
--: (V5Type, V5Type[]) -> V5Type
local function abstract_body(body, args)
	local n = #args
	local map = {} --[[: { [integer]: integer } ]]
	for i = 1, n do
		local a = args[i]
		if a ~= nil and a.tag == "uvar" then
			map[a.id] = n - i  -- innermost binder = Var(0) = last arg.
		end
	end
	local body2 = abstract_sub(map, body) --[[: V5Type ]]
	local result = body2
	for _i = 1, n do
		result = types_mod.lambda("*", result) --[[: V5Type ]]
	end
	return result
end

-- Returns true if t contains a Lambda anywhere (used to guard the v5.0
-- restricted abstract).
--: (V5Type) -> boolean
local function contains_lambda(t)
	if t.tag == "lambda" then return true end
	if t.tag == "app" then return contains_lambda(t.f) or contains_lambda(t.a) end
	if t.tag == "record" then
		for _, fv in pairs(t.fields) do if contains_lambda(fv) then return true end end
		return false
	end
	if t.tag == "arrow" then
		for i = 1, #t.args do if contains_lambda(t.args[i]) then return true end end
		return contains_lambda(t.ret)
	end
	if t.tag == "union" then
		for i = 1, #t.xs do if contains_lambda(t.xs[i]) then return true end end
		return false
	end
	return false
end

-- T-CHKT-Miller.  Returns "done" if Miller bound, "miss" if not in fragment.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Miller(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return "miss" end
	local rw = subst_mod.walk(st.subst, result) --[[: V5Type ]]
	local allowed = miller_check(st.subst, args, rw)
	if allowed == nil then return "miss" end
	-- Occurs check: ?F itself must not appear in result.
	if allowed[df.id] == true then
		-- ?F appears among its own args' allowed set vacuously?  No;
		-- allowed comes from args, and ?F binding is what we're computing.
	end
	-- Free-vars check already done in miller_check.
	-- Spec-gap guard: refuse if body contains existing Lambda (v5.0
	-- doesn't shift across nested binders).
	if contains_lambda(rw) then return "miss" end
	local body = abstract_body(rw, args)
	if subst_mod.bind(st.subst, df.id, body) then
		wake(st, df.id)
		wake_head(st, df.id)
	end
	trace(st, "T-CHKT-Miller", "bound ?F id=" .. tostring(df.id))
	return "done"
end

-- T-CHKT-Reduce.  ?F is bound to a (chain of) Lambda(s).  β-reduce and
-- emit CEq(reduced, result).
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Reduce(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	-- internal: dispatcher routes here only when f deref to lambda; fires only on solver bug
	if df.tag ~= "lambda" then
		err(st, "T-CHKT-Reduce", "precondition: f deref to lambda")
		return "error"
	end
	local body = df --[[: V5Type ]]
	for i = 1, #args do
		-- internal: lambda binder count must match arg count; fires only on solver bug
		if body.tag ~= "lambda" then
			err(st, "T-CHKT-Reduce", "arity mismatch: not enough lambda binders for " .. tostring(#args) .. " args")
			return "error"
		end
		local a = args[i]
		-- internal: args array contains nil; fires only on solver bug
		if a == nil then
			err(st, "T-CHKT-Reduce", "nil arg at " .. tostring(i))
			return "error"
		end
		local lb = body.b --[[: V5Type ]]
		body = types_mod.instantiate(lb, a, 0) --[[: V5Type ]]
	end
	M.emit(st, constraint_mod.eq(body, result, prov))
	trace(st, "T-CHKT-Reduce", "reduced #args=" .. tostring(#args))
	return "done"
end

-- T-CHKT-Rigid-Mismatch.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Rigid_Mismatch(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	err(st, "T-CHKT-Rigid-Mismatch", "HKT application on non-constructor: tag=" .. df.tag,
		prov, { tag = "not_a_record", found_tag = df.tag })
	return "error"
end

-- T-CHKT-Park.  ?F unbound, Miller fragment doesn't apply: emit HOUnify
-- (which will park on head_watchers in the next dispatch loop iteration).
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Park(st, f, args, result, prov)
	M.emit(st, M.hounify(f, args, result, prov))
	trace(st, "T-CHKT-Park", "emit HOUnify")
	return "done"
end

-- T-HOUnify-Wake.  f is now rigid (head-watch fired); retry as CHKT.
--: (OpSemState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_HOUnify_Wake(st, f, args, result, prov)
	M.emit(st, M.chkt(f, args, result, prov))
	trace(st, "T-HOUnify-Wake", "re-emit CHKT")
	return "done"
end

-- T-HOUnify-Stuck.  Reported at quiescence; helper used by the run loop.
-- Takes OpSemConstraint to avoid narrowing-through-Map issues at call site.
--: (OpSemState, OpSemConstraint) -> nil
function M.rule_T_HOUnify_Stuck(st, c)
	err(st, "T-HOUnify-Stuck",
		"ambiguous constructor variable: head shape never rigidified",
		c.prov, { tag = "ambiguous_constructor" })
end

-- CHKT dispatch.  Decides which CHKT rule applies.
--: (OpSemState, ConstraintHKT) -> string
local function step_chkt(st, c)
	local df = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
	if df.tag == "lambda" then
		return M.rule_T_CHKT_Reduce(st, c.f, c.args, c.result, c.prov)
	end
	if df.tag ~= "uvar" then
		return M.rule_T_CHKT_Rigid_Mismatch(st, c.f, c.args, c.result, c.prov)
	end
	-- ?F is uvar: try Miller, else park.
	local status = M.rule_T_CHKT_Miller(st, c.f, c.args, c.result, c.prov)
	if status == "miss" then
		return M.rule_T_CHKT_Park(st, c.f, c.args, c.result, c.prov)
	end
	return status
end

-- HOUnify dispatch.  If f is now rigid, retry; else stuck (park).
--: (OpSemState, ConstraintHO) -> string
local function step_hounify(st, c)
	local df = subst_mod.deref(st.subst, c.f) --[[: V5Type ]]
	if df.tag ~= "uvar" then
		return M.rule_T_HOUnify_Wake(st, c.f, c.args, c.result, c.prov)
	end
	trace(st, "T-HOUnify-Park", "stuck on head(?F)")
	return "stuck"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Top-level dispatch + run
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, OpSemConstraint) -> string
function M.step(st, c)
	st.steps = st.steps + 1
	if c.tag == "ceq" then
		local a = subst_mod.deref(st.subst, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(st.subst, c.b) --[[: V5Type ]]
		return step_ceq(st, a, b, c.prov)
	end
	if c.tag == "csub" then
		local a = subst_mod.deref(st.subst, c.a) --[[: V5Type ]]
		local b = subst_mod.deref(st.subst, c.b) --[[: V5Type ]]
		return step_csub(st, a, b, c.prov)
	end
	if c.tag == "topen" then return M.rule_T_CTOpen(st, c.tv, c.prov) end
	if c.tag == "tset"  then return step_tset(st, c) end
	if c.tag == "tseal" then return M.rule_T_CTSeal(st, c.tv, c.mu, c.prov) end
	if c.tag == "mcall" then return step_mcall(st, c) end
	if c.tag == "cinst"   then return step_cinst(st, c) end
	if c.tag == "chkt"    then return step_chkt(st, c) end
	if c.tag == "hounify" then return step_hounify(st, c) end
	if c.tag == "crow_extend" then
		return step_crow_extend(st, c.record_ty, c.key, c.field_ty, c.prov)
	end
	if c.tag == "crow_lacks" then
		return step_crow_lacks(st, c.record_ty, c.key, c.prov)
	end
	if c.tag == "crow_close" then
		return M.rule_T_CRowClose_Bind(st, c.record_ty, c.prov)
	end
	if c.tag == "cint_eq" then
		return M.rule_T_CIntersectionEq_Canonical(st, c.parts_a, c.parts_b, c.prov)
	end
	if c.tag == "cint_sub" then
		-- Set-direction subtyping reduces to RHS-conj (every super-part
		-- must be matched by some sub-part), each emitted as a member query.
		local canon_super = constraint_mod.flatten_parts(c.parts_super)
		local lhs_ty = types_mod.intersection(constraint_mod.flatten_parts(c.parts_sub)) --[[: V5Type ]]
		for i = 1, #canon_super do
			local p = canon_super[i]
			if p ~= nil then
				M.emit(st, constraint_mod.intersection_member(lhs_ty, p, c.prov))
			end
		end
		trace(st, "T-CIntersectionSub", "n=" .. tostring(#canon_super))
		return "done"
	end
	if c.tag == "cint_member" then
		return M.rule_T_CIntersectionMember_Direct(st, c.ty, c.part, c.prov)
	end
	-- internal: constraint tag not recognized by dispatcher; fires only on solver bug
	err(st, "step", "unknown constraint tag " .. tostring(c.tag))
	return "error"
end

-- S-Step / S-Park / S-Wake / S-Quiesce.
--: (OpSemState) -> nil
function M.run(st)
	while true do
		local h = st.head
		if h > st.tail then
			st.head = 1; st.tail = 0
			break
		end
		local c = st.worklist[h]
		st.worklist[h] = nil
		st.head = h + 1
		if c ~= nil then
			local status = M.step(st, c)
			if status == "stuck" then park(st, c) end
		end
	end
	-- S-Quiesce: report inert constraints as stuck errors.
	-- HOUnify gets the dedicated T-HOUnify-Stuck rule (ambiguous
	-- constructor variable); CRowLacks still parked means the row var was
	-- never closed — soundness floor violation; others get generic error.
	-- CSub with ra=uvar still parked: no competing binding appeared; apply
	-- upper-bound assignment (bind ra := rb) per the v5.0 defaulting rule,
	-- matching the intent of the original T-CSub-TVar CEq route.
	for _cid, c in pairs(st.inert) do
		if c.tag == "hounify" then
			M.rule_T_HOUnify_Stuck(st, c)
		elseif c.tag == "crow_lacks" then
			local ckey = c.key or "?"
			err(st, "S-Quiesce-CRowLacks",
				"CRowLacks still unresolved at quiescence (row never closed): key=" .. ckey,
				c.prov, { tag = "missing_field", field = ckey })
		elseif c.tag == "cint_member" then
			-- F2 enforcement: stuck inferred effect — a CIntersectionMember
			-- on a uvar that never got bound must error at quiescence.
			--: V5Type | nil
			local container_nil = nil
			local eff_ty = as_v5type(c.part)
			if eff_ty ~= nil then
				--: ErrorDetails
				local det = { tag = "effect_not_permitted", effect = eff_ty, container = container_nil }
				err(st, "S-Quiesce-CIntersectionMember",
					"CIntersectionMember stuck on unbound uvar (effect never inferred)",
					c.prov, det)
			else
				err(st, "S-Quiesce-CIntersectionMember",
					"CIntersectionMember stuck on unbound uvar (effect never inferred)",
					c.prov, nil)
			end
		elseif c.tag == "csub" then
			-- Parked csub: ra=uvar was never bound by a competing constraint.
			-- Materialize as the meet (intersection) of accumulated upper
			-- bounds — preserves principal-type semantics when multiple
			-- CSub demands accumulated on the same uvar.  A single bound is
			-- equivalent to the prior CEq(ra, rb) behavior.  Conflicting
			-- bounds (e.g. integer & string) surface as real errors via
			-- existing intersection-reduction rules.  Lower bounds are
			-- verified against the resolved type after binding.
			local cc_a_raw = c.a  -- .a is V5Type on ConstraintSub
			local cc_b_raw = c.b  -- .b is V5Type on ConstraintSub
			local cc_p_raw = c.prov
			--: V5Type | nil
			local cc_a = as_v5type(cc_a_raw)
			--: V5Type | nil
			local cc_b = as_v5type(cc_b_raw)
			if cc_a == nil or cc_b == nil or cc_p_raw == nil then
				-- internal: csub constraint missing required fields; fires only on solver bug
				err(st, "S-Quiesce", "csub missing fields (tag=csub)")
			else
				local ra2 = subst_mod.deref(st.subst, cc_a) --[[: V5Type ]]
				local rb2 = subst_mod.deref(st.subst, cc_b) --[[: V5Type ]]
				--: Provenance
				local prov2 = cc_p_raw
				if ra2.tag == "uvar" then
					-- Still unbound: bind to meet of upper bounds.
					local root = subst_mod.find(st.subst, ra2.id)
					local uppers = st.upper_bounds[root]
					if uppers == nil then
						-- Bounds already drained by a prior parked-csub on the
						-- same uvar; the meet has been emitted, nothing to do.
						trace(st, "S-Quiesce-CSub-TVar", "bounds already drained for uvar=" .. tostring(root))
					elseif #uppers == 0 then
						-- Shouldn't happen (park populated bounds).
						M.emit(st, constraint_mod.eq(ra2, rb2, prov2))
						trace(st, "S-Quiesce-CSub-TVar", "defaulting uvar to upper bound (no bounds tracked)")
						st.upper_bounds[root] = nil
					elseif #uppers == 1 then
						local u1 = uppers[1]
						if u1 ~= nil then
							M.emit(st, constraint_mod.eq(ra2, u1, prov2))
							trace(st, "S-Quiesce-CSub-TVar", "single upper bound")
						end
						st.upper_bounds[root] = nil
					else
						-- Multiple upper bounds → meet via TIntersection.
						local meet = types_mod.intersection(uppers) --[[: V5Type ]]
						M.emit(st, constraint_mod.eq(ra2, meet, prov2))
						trace(st, "S-Quiesce-CSub-TVar",
							"meet of " .. tostring(#uppers) .. " upper bounds")
						st.upper_bounds[root] = nil
					end
					-- Verify lower bounds against the (about-to-be) resolved type.
					local lowers = st.lower_bounds[root]
					if lowers ~= nil then
						for i = 1, #lowers do
							local lb = lowers[i]
							if lb ~= nil then
								M.emit(st, constraint_mod.sub(lb, ra2, prov2))
							end
						end
						st.lower_bounds[root] = nil
					end
				else
					-- ra was bound between park and quiescence (possible if multiple
					-- passes are needed); retry the sub constraint.
					local status = step_csub(st, ra2, rb2, prov2)
					if status == "stuck" then
						-- internal: constraint still stuck after retry; fires only on solver bug
					err(st, "S-Quiesce", "stuck constraint (tag=csub) after quiescence retry")
					end
				end
			end
		else
			-- internal: unknown constraint tag still stuck at quiescence; fires only on solver bug
			err(st, "S-Quiesce", "stuck constraint (tag=" .. c.tag .. ")")
		end
	end
	-- Drain any CEq constraints emitted by S-Quiesce defaulting above.
	while st.head <= st.tail do
		local h = st.head
		local c2 = st.worklist[h]
		st.worklist[h] = nil
		st.head = h + 1
		if c2 ~= nil then
			local status = M.step(st, c2)
			if status == "stuck" then
				-- internal: constraint emitted by S-Quiesce defaulting is still stuck; fires only on solver bug
				err(st, "S-Quiesce-Drain", "constraint still stuck after quiescence drain (tag=" .. c2.tag .. ")")
			end
		end
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Inspection helpers
-- ────────────────────────────────────────────────────────────────────────────

--: (OpSemState, integer) -> V5Type
function M.resolve(st, tv)
	local t = types_mod.uvar(tv) --[[: V5Type ]]
	return subst_mod.walk(st.subst, t)
end

--: (OpSemState) -> integer
function M.error_count(st) return #st.errors end

return M
