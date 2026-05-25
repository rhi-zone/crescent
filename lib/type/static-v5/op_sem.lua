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
M.prov        = constraint_mod.prov
M.variance    = variance_mod

-- ────────────────────────────────────────────────────────────────────────────
-- State
-- ────────────────────────────────────────────────────────────────────────────

--:: OpSemError = { rule: string, msg: string }
--:: OpSemTrace = { rule: string, msg: string }
--:: OpSemState = { subst: Subst, worklist: OpSemConstraint[], head: integer, tail: integer, inert: { [integer]: OpSemConstraint }, errors: OpSemError[], trace: OpSemTrace[], reactivations: integer, steps: integer }

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

--: (OpSemState, string, string) -> nil
local function err(st, rule, msg)
	st.errors[#st.errors + 1] = { rule = rule, msg = msg }
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
	local b = blockers_of(c, st.subst)
	for tv in pairs(b) do subst_mod.watch(st.subst, tv, c.id) end
end

-- ────────────────────────────────────────────────────────────────────────────
-- T-CEq family
-- ────────────────────────────────────────────────────────────────────────────

-- T-CEq-UU: both sides UVar.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_UU(st, a, b, prov)
	if a.tag ~= "uvar" then err(st, "T-CEq-UU", "precondition a must be uvar"); return "error" end
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
	if a.tag ~= "uvar" then err(st, "T-CEq-Bind-L", "precondition a must be uvar"); return "error" end
	if b.tag == "uvar" then err(st, "T-CEq-Bind-L", "precondition b must be concrete"); return "error" end
	local seen = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(b, seen)
	local root = subst_mod.find(st.subst, a.id)
	if seen[root] == true then
		err(st, "T-CEq-Occurs", "occurs check failed")
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
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CEq-Const", "precondition: both const"); return "error"
	end
	if a.name ~= b.name then
		err(st, "T-CEq-Const", "const mismatch: " .. a.name .. " vs " .. b.name)
		return "error"
	end
	trace(st, "T-CEq-Const", a.name)
	return "done"
end

-- T-CEq-Arrow.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Arrow(st, a, b, prov)
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CEq-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CEq-Arrow", "arity mismatch"); return "error"
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
			err(st, "T-CEq-Record", "positional arity mismatch: " .. na .. " vs " .. nb)
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
			err(st, "T-CEq-Record", "missing field " .. k)
		elseif va ~= nil then
			M.emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
	for k, _ in pairs(b.fields) do
		if a.fields[k] == nil then err(st, "T-CEq-Record", "extra field " .. k) end
	end
	trace(st, "T-CEq-Record", "")
	return "done"
end

-- T-CEq-App.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_App(st, a, b, prov)
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
	err(st, "T-CEq-Mismatch", "kind mismatch: " .. a.tag .. " vs " .. b.tag)
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
	if not types_mod.equal(a, b) then
		err(st, "T-CSub-Refl", "precondition: types equal"); return "error"
	end
	trace(st, "T-CSub-Refl", "")
	return "done"
end

-- T-CSub-TVar.  Either side is an unbound UVar — route to CEq.  v5.0
-- discipline (no per-tvar bounds); v5.x will extend.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_TVar(st, a, b, prov)
	M.emit(st, constraint_mod.eq(a, b, prov))
	trace(st, "T-CSub-TVar", "routed to CEq")
	return "done"
end

-- T-CSub-Arrow.  Contra in args, co in rets.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Arrow(st, a, b, prov)
	if a.tag ~= "arrow" or b.tag ~= "arrow" then
		err(st, "T-CSub-Arrow", "precondition: both arrow"); return "error"
	end
	if #a.args ~= #b.args then
		err(st, "T-CSub-Arrow", "arity mismatch"); return "error"
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
	if a.tag ~= "const" or b.tag ~= "const" then
		err(st, "T-CSub-Const-Var", "precondition: both const"); return "error"
	end
	if a.name ~= b.name then
		err(st, "T-CSub-Const-Var",
			"const name mismatch: " .. a.name .. " vs " .. b.name)
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
			"head mismatch: " .. ha .. " vs " .. hb)
		return "error"
	end
	if #aa ~= #ab then
		err(st, "T-CSub-App-Var",
			"arity mismatch for " .. ha)
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
			err(st, "T-CSub-Record-Width", "missing field " .. k)
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
	err(st, "T-CSub-Union-R", "no branch matches LHS exactly (v5.0 limitation)")
	return "error"
end

-- T-CSub-Mismatch.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_Mismatch(st, a, b, prov)
	err(st, "T-CSub-Mismatch", "sub kind mismatch: " .. a.tag .. " vs " .. b.tag)
	return "error"
end

-- CSub dispatcher.  Order matters: Refl first (cheap fast path), then TVar
-- (must precede shape dispatch — uvars masquerade as no tag here), then
-- by tag.
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
	-- Union dispatch (L takes priority over R; both can apply if both sides
	-- are unions — emit per-branch sub from L, the recursive call will see
	-- RHS-only-union on each branch).
	if ra.tag == "union" then
		return M.rule_T_CSub_Union_L(st, ra, rb, prov)
	end
	if rb.tag == "union" then
		return M.rule_T_CSub_Union_R(st, ra, rb, prov)
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
	if b == nil then
		err(st, "T-CTSet-Open-Extend", "precondition: tv bound"); return "error"
	end
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
	if b == nil then err(st, "T-CTSet-Open-Equate", "precondition: tv bound"); return "error" end
	if b.tag ~= "record" then err(st, "T-CTSet-Open-Equate", "precondition: record"); return "error" end
	local existing = b.fields[key]
	if existing == nil then err(st, "T-CTSet-Open-Equate", "precondition: field present"); return "error" end
	M.emit(st, constraint_mod.eq(existing, ty, prov))
	trace(st, "T-CTSet-Open-Equate", key)
	return "done"
end

-- T-CTSet-Sealed-Reject.
--: (OpSemState, integer, string, V5Type, Provenance) -> string
function M.rule_T_CTSet_Sealed_Reject(st, tv, key, ty, prov)
	err(st, "T-CTSet-Sealed-Reject", "set " .. key .. " on sealed table (tv=" .. tostring(tv) .. ")")
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
	if b == nil then err(st, "T-CMCall-Sealed-Field", "precondition: bound"); return "error" end
	if b.tag ~= "record" then err(st, "T-CMCall-Sealed-Field", "precondition: record"); return "error" end
	local mraw = b.fields[key]
	if mraw == nil then err(st, "T-CMCall-Sealed-Field", "precondition: field present"); return "error" end
	local m = mraw --[[: V5Type ]]
	if m.tag ~= "arrow" then err(st, "T-CMCall-Sealed-Field", "field is not callable"); return "error" end
	local r1raw = m.ret.fields["1"]
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
	err(st, "T-CMCall-Sealed-Missing", "no method " .. key)
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
	if b == nil then err(st, "T-CMCall", "sealed tv unbound"); return "error" end
	if b.tag ~= "record" then err(st, "T-CMCall", "sealed tv not a record"); return "error" end
	if b.fields[c.key] == nil then
		return M.rule_T_CMCall_Sealed_Missing(st, c.tv, c.key, c.ret, c.prov)
	end
	return M.rule_T_CMCall_Sealed_Field(st, c.tv, c.key, c.ret, c.prov)
end

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
	if df.tag ~= "lambda" then
		err(st, "T-CHKT-Reduce", "precondition: f deref to lambda")
		return "error"
	end
	local body = df --[[: V5Type ]]
	for i = 1, #args do
		if body.tag ~= "lambda" then
			err(st, "T-CHKT-Reduce", "arity mismatch: not enough lambda binders for " .. tostring(#args) .. " args")
			return "error"
		end
		local a = args[i]
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
	err(st, "T-CHKT-Rigid-Mismatch", "HKT application on non-constructor: tag=" .. df.tag)
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
		"ambiguous constructor variable: head shape never rigidified")
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
	-- constructor variable); others get the generic S-Quiesce error.
	for _cid, c in pairs(st.inert) do
		if c.tag == "hounify" then
			M.rule_T_HOUnify_Stuck(st, c)
		else
			err(st, "S-Quiesce", "stuck constraint (tag=" .. c.tag .. ")")
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
