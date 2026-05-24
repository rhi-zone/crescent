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

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Scheme + CInst extension
-- ────────────────────────────────────────────────────────────────────────────

--:: V5Scheme       = { binders: integer, body: V5Type }
--:: ConstraintInst = { id: integer, tag: "cinst", scheme: V5Scheme, target: V5Type, prov: Provenance }
--:: OpSemConstraint = V5Constraint | ConstraintInst

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

-- Re-export constructor pass-throughs.
M.eq          = constraint_mod.eq
M.sub         = constraint_mod.sub
M.table_open  = constraint_mod.table_open
M.table_set   = constraint_mod.table_set
M.table_seal  = constraint_mod.table_seal
M.method_call = constraint_mod.method_call
M.prov        = constraint_mod.prov

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
	if subst_mod.bind(st.subst, a.id, b) then wake(st, a.id) end
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
	if #a.args ~= #b.args or #a.rets ~= #b.rets then
		err(st, "T-CEq-Arrow", "arity mismatch"); return "error"
	end
	for i = 1, #a.args do
		local av, bv = a.args[i], b.args[i]
		if av ~= nil and bv ~= nil then M.emit(st, constraint_mod.eq(av, bv, prov)) end
	end
	for i = 1, #a.rets do
		local av, bv = a.rets[i], b.rets[i]
		if av ~= nil and bv ~= nil then M.emit(st, constraint_mod.eq(av, bv, prov)) end
	end
	trace(st, "T-CEq-Arrow", "")
	return "done"
end

-- T-CEq-Record.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CEq_Record(st, a, b, prov)
	if a.tag ~= "record" or b.tag ~= "record" then
		err(st, "T-CEq-Record", "precondition: both record"); return "error"
	end
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

-- T-CSub-AsEq.
--: (OpSemState, V5Type, V5Type, Provenance) -> string
function M.rule_T_CSub_AsEq(st, a, b, prov)
	M.emit(st, constraint_mod.eq(a, b, prov))
	trace(st, "T-CSub-AsEq", "")
	return "done"
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
	if subst_mod.bind(st.subst, r, rec) then wake(st, r) end
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
	if subst_mod.bind(st.subst, r, rec) then wake(st, r) end
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
	if #m.rets == 0 then err(st, "T-CMCall-Sealed-Field", "arrow with zero rets"); return "error" end
	local r1raw = m.rets[1]
	if r1raw == nil then err(st, "T-CMCall-Sealed-Field", "ret[1] missing"); return "error" end
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
		return M.rule_T_CSub_AsEq(st, c.a, c.b, c.prov)
	end
	if c.tag == "topen" then return M.rule_T_CTOpen(st, c.tv, c.prov) end
	if c.tag == "tset"  then return step_tset(st, c) end
	if c.tag == "tseal" then return M.rule_T_CTSeal(st, c.tv, c.mu, c.prov) end
	if c.tag == "mcall" then return step_mcall(st, c) end
	if c.tag == "cinst" then return step_cinst(st, c) end
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
	for _cid, c in pairs(st.inert) do
		err(st, "S-Quiesce", "stuck constraint (tag=" .. c.tag .. ")")
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
