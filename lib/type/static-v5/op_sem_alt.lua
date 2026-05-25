-- lib/type/static-v5/op_sem_alt.lua
-- v5.0 typechecker operational semantics — ALTERNATE INTERPRETER.
--
-- This module is an independently-written transcription of the inference
-- rules in `docs/typechecker-v5-operational-semantics.md`.  It exists to
-- give the parity test TWO independently-encoded interpreters: the existing
-- `op_sem.lua` and this one.  If they agree on every fixture, the rule
-- encoding is corroborated.  If they disagree, the divergence is logged
-- (see `docs/typechecker-v5-log.md`) and an orchestrator decides which
-- reading is correct.
--
-- Methodology constraint (per the task brief): this file was written
-- WITHOUT reading `op_sem.lua`.  It uses only the substrate modules
-- (`types.lua`, `subst.lua`, `constraint.lua`, `variance.lua`), the
-- inference rules in the spec doc, and the public state-shape /
-- constraint-tag set advertised by `op_sem.lua`'s headers (so the parity
-- test can compare apples to apples).
--
-- Same `M.run(state)` entry point as op_sem; the parity harness can call
-- either interchangeably.

local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local variance_mod   = require("lib.type.experiments.v5_perf.variance")

local _ = constraint_mod -- silence unused-import; aliases come via op_sem in caller

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- State shape (mirrors op_sem.lua so the parity test can use either)
-- ────────────────────────────────────────────────────────────────────────────
--
-- We don't define new_state/emit/scheme/etc. here — the parity test
-- constructs state via op_sem.new_state() and emits via op_sem.emit(), and
-- our M.run consumes the same state.  This keeps the comparison surface
-- identical: only the SOLVER LOOP and RULE LOGIC differ.

--:: OpSemError    = { rule: string, msg: string }
--:: OpSemTrace    = { rule: string, msg: string }
--:: AltScheme     = { binders: integer, body: V5Type }
--:: AltCInst      = { id: integer, tag: "cinst", scheme: AltScheme, target: V5Type, prov: Provenance }
--:: AltCHKT       = { id: integer, tag: "chkt", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: AltHOUnify    = { id: integer, tag: "hounify", f: V5Type, args: V5Type[], result: V5Type, prov: Provenance }
--:: AltConstraint = V5Constraint | AltCInst | AltCHKT | AltHOUnify
--:: AltState      = { subst: Subst, worklist: AltConstraint[], head: integer, tail: integer, inert: { [integer]: AltConstraint }, errors: OpSemError[], trace: OpSemTrace[], reactivations: integer, steps: integer }

-- ────────────────────────────────────────────────────────────────────────────
-- Small helpers
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, string, string) -> nil
local function record_error(st, rule, msg)
	st.errors[#st.errors + 1] = { rule = rule, msg = msg }
end

--: (AltState, AltConstraint) -> nil
local function emit(st, c)
	local n = st.tail + 1
	st.worklist[n] = c
	st.tail = n
end

-- Drain ordinary watchers for tv (called after a bind/seal/union).
--: (AltState, integer) -> nil
local function wake(st, tv)
	local w = subst_mod.drain_watchers(st.subst, tv)
	if w == nil then return end
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			emit(st, c)
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Drain head-watchers ONLY if the new binding contributes a rigid head.
--: (AltState, integer) -> nil
local function wake_head(st, tv)
	if not subst_mod.head_is_rigid(st.subst, tv) then return end
	local w = subst_mod.drain_head_watchers(st.subst, tv)
	if w == nil then return end
	for cid in pairs(w) do
		local c = st.inert[cid]
		if c ~= nil then
			st.inert[cid] = nil
			emit(st, c)
			st.reactivations = st.reactivations + 1
		end
	end
end

-- Compose: bind a uvar, then run BOTH wakes.
--: (AltState, integer, V5Type) -> nil
local function bind_and_wake(st, id, ty)
	subst_mod.bind(st.subst, id, ty)
	wake(st, id)
	wake_head(st, id)
end

-- Free-uvar membership check for occurs.
--: (V5Type, integer) -> boolean
local function occurs(ty, id)
	local acc = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(ty, acc)
	return acc[id] == true
end

-- Park a constraint in the inert set, watching ?t on `watch_kind`.
--: (AltState, AltConstraint, integer, string) -> nil
local function park(st, c, tv, watch_kind)
	st.inert[c.id] = c
	if watch_kind == "head" then
		subst_mod.watch_head(st.subst, tv, c.id)
	else
		subst_mod.watch(st.subst, tv, c.id)
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Equality / unification rules
-- ────────────────────────────────────────────────────────────────────────────
--
-- Dispatch order per the doc:
--   1.  If both sides deref to UVar  -> T-CEq-UU (T-CEq-Refl is degenerate
--       and subsumed).
--   2.  If LHS UVar, RHS concrete    -> T-CEq-Bind-L (with occurs check
--       falling over to T-CEq-Occurs).
--   3.  Mirror of 2 with RHS UVar    -> T-CEq-Bind-R.
--   4.  Otherwise dispatch by matching tags.

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_UU(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	-- Per spec: "If a = b: discharged with no change."
	if da.tag == "uvar" and db.tag == "uvar" then
		subst_mod.union(st.subst, da.id, db.id)
		-- The union may have transferred a binding onto the winner; wake.
		local ra = subst_mod.find(st.subst, da.id)
		wake(st, ra); wake_head(st, ra)
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Bind_L(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "uvar" then return end
	if db.tag == "uvar" then return end
	if occurs(db, da.id) then
		record_error(st, "T-CEq-Occurs", "occurs check failed")
		return
	end
	bind_and_wake(st, da.id, db)
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Bind_R(st, a, b, prov)
	M.rule_T_CEq_Bind_L(st, b, a, prov)
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Const(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "const" or db.tag ~= "const" then return end
	if da.name ~= db.name then
		record_error(st, "T-CEq-Const", "const mismatch " .. da.name .. " vs " .. db.name)
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Arrow(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "arrow" or db.tag ~= "arrow" then return end
	if #da.args ~= #db.args then
		record_error(st, "T-CEq-Arrow", "arrow arity mismatch")
		return
	end
	for i = 1, #da.args do
		local xa = da.args[i]; local xb = db.args[i]
		if xa ~= nil and xb ~= nil then emit(st, constraint_mod.eq(xa, xb, prov)) end
	end
	emit(st, constraint_mod.eq(da.ret, db.ret, prov))
end

-- is_positional: true iff record fields are exactly the string keys "1".."n"
-- for some n >= 0, contiguous with no gaps and no non-numeric keys.
-- Independent encoding from op_sem.lua per the alternate-interpreter mandate.
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

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Record(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "record" or db.tag ~= "record" then return end
	local a_pos = is_positional(da)
	local b_pos = is_positional(db)
	if a_pos and b_pos then
		-- Positional branch: eq is strict on arity (no nil-pad for eq).
		local na, nb = 0, 0
		for _ in pairs(da.fields) do na = na + 1 end
		for _ in pairs(db.fields) do nb = nb + 1 end
		if na ~= nb then
			record_error(st, "T-CEq-Record", "positional arity mismatch: " .. na .. " vs " .. nb)
			return
		end
		for i = 1, na do
			local va = da.fields[tostring(i)]
			local vb = db.fields[tostring(i)]
			if va ~= nil and vb ~= nil then
				emit(st, constraint_mod.eq(va, vb, prov))
			end
		end
		return
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- Domain check.
	for k, _v in pairs(da.fields) do
		if db.fields[k] == nil then
			record_error(st, "T-CEq-Record", "missing field " .. k)
			return
		end
	end
	for k, _v in pairs(db.fields) do
		if da.fields[k] == nil then
			record_error(st, "T-CEq-Record", "extra field " .. k)
			return
		end
	end
	for k, va in pairs(da.fields) do
		local vb = db.fields[k]
		if va ~= nil and vb ~= nil then
			emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_App(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "app" or db.tag ~= "app" then return end
	emit(st, constraint_mod.eq(da.f, db.f, prov))
	emit(st, constraint_mod.eq(da.a, db.a, prov))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CEq_Mismatch(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then return end
	if da.tag == db.tag then return end
	record_error(st, "T-CEq-Mismatch", "kind mismatch " .. da.tag .. " vs " .. db.tag)
end

-- Top-level dispatch for CEq.  Encodes the rule-priority described in the
-- spec's prose.
--: (AltState, V5Type, V5Type, Provenance) -> nil
local function step_ceq(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" and db.tag == "uvar" then
		-- T-CEq-UU (covers Refl when a==b).
		M.rule_T_CEq_UU(st, da, db, prov)
		return
	end
	if da.tag == "uvar" then
		M.rule_T_CEq_Bind_L(st, da, db, prov); return
	end
	if db.tag == "uvar" then
		M.rule_T_CEq_Bind_R(st, da, db, prov); return
	end
	-- Both concrete; dispatch on tag pair.
	if da.tag ~= db.tag then
		M.rule_T_CEq_Mismatch(st, da, db, prov); return
	end
	if da.tag == "const" then M.rule_T_CEq_Const(st, da, db, prov); return end
	if da.tag == "arrow" then M.rule_T_CEq_Arrow(st, da, db, prov); return end
	if da.tag == "record" then M.rule_T_CEq_Record(st, da, db, prov); return end
	if da.tag == "app" then M.rule_T_CEq_App(st, da, db, prov); return end
	if da.tag == "lambda" then
		-- Spec doesn't explicitly list T-CEq-Lambda; structural equal-or-mismatch.
		if types_mod.equal(da, db) then return end
		record_error(st, "T-CEq-Mismatch", "lambda mismatch")
		return
	end
	if da.tag == "union" then
		if types_mod.equal(da, db) then return end
		record_error(st, "T-CEq-Mismatch", "union mismatch")
		return
	end
	if da.tag == "var" then
		if da.i == db.i then return end
		record_error(st, "T-CEq-Mismatch", "var mismatch")
		return
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Subtyping (variance-respecting) rules
-- ────────────────────────────────────────────────────────────────────────────

-- Walk a (possibly curried) application down to its head + ordered args.
-- Returns (head_after_deref, args_list).  For non-app input returns (t, {}).
--: (AltState, V5Type) -> (V5Type, V5Type[])
local function split_app(st, t)
	local args = {} --[[: V5Type[] ]]
	local cur = subst_mod.deref(st.subst, t) --[[: V5Type ]]
	while cur.tag == "app" do
		args[#args + 1] = cur.a
		cur = subst_mod.deref(st.subst, cur.f) --[[: V5Type ]]
	end
	-- args were collected outermost-first (a_n, a_{n-1}, …, a_1).  Reverse.
	local n = #args
	local out = {} --[[: V5Type[] ]]
	for i = 1, n do
		local v = args[n - i + 1]
		if v ~= nil then out[i] = v end
	end
	return cur, out
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Refl(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if types_mod.equal(da, db) then
		-- discharged
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_TVar(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then
		emit(st, constraint_mod.eq(da, db, prov))
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Arrow(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "arrow" or db.tag ~= "arrow" then return end
	if #da.args ~= #db.args then
		record_error(st, "T-CSub-Arrow", "arrow arity mismatch")
		return
	end
	-- Contra args: A_i is supertype of B_i  ->  CSub(B_i, A_i).
	for i = 1, #da.args do
		local xa = da.args[i]; local xb = db.args[i]
		if xa ~= nil and xb ~= nil then emit(st, constraint_mod.sub(xb, xa, prov)) end
	end
	-- Co ret: delegate to positional Record rules (Phase 3).
	emit(st, constraint_mod.sub(da.ret, db.ret, prov))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Const_Var(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "const" or db.tag ~= "const" then return end
	if da.name == db.name then return end
	record_error(st, "T-CSub-Const-Var", "const sub mismatch " .. da.name .. " vs " .. db.name)
end

--: (AltState, V5Type, V5Type[], V5Type, V5Type[], string, Provenance) -> nil
local function emit_app_var_subgoals(st, _head_a, args_a, _head_b, args_b, name, prov)
	for i = 1, #args_a do
		local v = variance_mod.at(name, i)
		local xi = args_a[i]
		local yi = args_b[i]
		if v == "co" then
			emit(st, constraint_mod.sub(xi, yi, prov))
		elseif v == "contra" then
			emit(st, constraint_mod.sub(yi, xi, prov))
		else
			emit(st, constraint_mod.eq(xi, yi, prov))
		end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_App_Var(st, a, b, prov)
	local ha, aa = split_app(st, a)
	local hb, bb = split_app(st, b)
	if ha.tag ~= "const" or hb.tag ~= "const" then return end
	if ha.name ~= hb.name then
		record_error(st, "T-CSub-Const-Var", "const head mismatch " .. ha.name .. " vs " .. hb.name)
		return
	end
	if #aa ~= #bb then
		record_error(st, "T-CSub-App-Var", "arity mismatch on " .. ha.name)
		return
	end
	emit_app_var_subgoals(st, ha, aa, hb, bb, ha.name, prov)
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_App_Struct(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "app" or db.tag ~= "app" then return end
	emit(st, constraint_mod.eq(da.f, db.f, prov))
	emit(st, constraint_mod.eq(da.a, db.a, prov))
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Record_Width(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag ~= "record" or db.tag ~= "record" then return end
	local a_pos = is_positional(da)
	local b_pos = is_positional(db)
	if a_pos and b_pos then
		-- Positional covariant branch (Arrow returns).
		-- Nil-pad policy: shorter side padded with Const("nil") so sub is
		-- always valid regardless of which side is wider.
		local na, nb = 0, 0
		for _ in pairs(da.fields) do na = na + 1 end
		for _ in pairs(db.fields) do nb = nb + 1 end
		local n = na > nb and na or nb
		local nil_type = types_mod.const("nil")
		for i = 1, n do
			local va = da.fields[tostring(i)] or nil_type
			local vb = db.fields[tostring(i)] or nil_type
			emit(st, constraint_mod.sub(va, vb, prov))
		end
		return
	end
	-- Mixed shapes (one positional, one named): fall through to named-key rule.
	-- dom(G) ⊆ dom(F)  where da=F (sub), db=G (sup).
	for k, _v in pairs(db.fields) do
		if da.fields[k] == nil then
			record_error(st, "T-CSub-Record-Width", "supertype demands missing field " .. k)
			return
		end
	end
	for k, vb in pairs(db.fields) do
		local va = da.fields[k]
		if va ~= nil and vb ~= nil then
			emit(st, constraint_mod.eq(va, vb, prov))
		end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Union_L(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a)
	if da.tag ~= "union" then return end
	for i = 1, #da.xs do
		local x = da.xs[i]
		if x ~= nil then emit(st, constraint_mod.sub(x, b, prov)) end
	end
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Union_R(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if db.tag ~= "union" then return end
	local wa = subst_mod.walk(st.subst, da) --[[: V5Type ]]
	for i = 1, #db.xs do
		local bi = db.xs[i]
		if bi ~= nil and types_mod.equal(wa, bi) then return end
	end
	record_error(st, "T-CSub-Union-R", "no exact union branch matches")
end

--: (AltState, V5Type, V5Type, Provenance) -> nil
function M.rule_T_CSub_Mismatch(st, a, b, prov)
	local _ = prov
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then return end
	if da.tag == db.tag then return end
	record_error(st, "T-CSub-Mismatch", "sub kind mismatch " .. da.tag .. " vs " .. db.tag)
end

-- Top-level dispatch for CSub.  Priority per the doc:
--   1.  Either side uvar  -> T-CSub-TVar (route to CEq).
--   2.  Structurally equal -> T-CSub-Refl.
--   3.  Both arrow         -> T-CSub-Arrow.
--   4.  Both record        -> T-CSub-Record-Width.
--   5.  Union LHS          -> T-CSub-Union-L.
--   6.  Union RHS          -> T-CSub-Union-R.
--   7.  Both apps (or one) with named-Const head -> T-CSub-App-Var.
--   8.  Both apps, non-Const head -> T-CSub-App-Struct.
--   9.  Both const         -> T-CSub-Const-Var.
--   10. Otherwise (tag mismatch) -> T-CSub-Mismatch.
--: (AltState, V5Type, V5Type, Provenance) -> nil
local function step_csub(st, a, b, prov)
	local da = subst_mod.deref(st.subst, a) --[[: V5Type ]]
	local db = subst_mod.deref(st.subst, b) --[[: V5Type ]]
	if da.tag == "uvar" or db.tag == "uvar" then
		M.rule_T_CSub_TVar(st, da, db, prov); return
	end
	if types_mod.equal(da, db) then
		M.rule_T_CSub_Refl(st, da, db, prov); return
	end
	-- Union dispatch before arrow/record because a union side dominates.
	if da.tag == "union" then M.rule_T_CSub_Union_L(st, da, db, prov); return end
	if db.tag == "union" then M.rule_T_CSub_Union_R(st, da, db, prov); return end
	if da.tag == "arrow" and db.tag == "arrow" then
		M.rule_T_CSub_Arrow(st, da, db, prov); return
	end
	if da.tag == "record" and db.tag == "record" then
		M.rule_T_CSub_Record_Width(st, da, db, prov); return
	end
	if da.tag == "app" and db.tag == "app" then
		local ha, _aa = split_app(st, da)
		local hb, _bb = split_app(st, db)
		if ha.tag == "const" and hb.tag == "const" then
			M.rule_T_CSub_App_Var(st, da, db, prov); return
		end
		M.rule_T_CSub_App_Struct(st, da, db, prov); return
	end
	if da.tag == "const" and db.tag == "const" then
		M.rule_T_CSub_Const_Var(st, da, db, prov); return
	end
	M.rule_T_CSub_Mismatch(st, da, db, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Construction phase rules
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, integer, Provenance) -> nil
function M.rule_T_CTOpen(st, tv, prov)
	local _ = prov
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil then return end -- idempotent
	-- Phase preserved (already Open by default).
	bind_and_wake(st, tv, types_mod.record({} --[[: { [string]: V5Type } ]]))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov)
	local _ = prov
	if subst_mod.binding(st.subst, tv) ~= nil then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	local fields = {} --[[: { [string]: V5Type } ]]
	fields[key] = ty
	bind_and_wake(st, tv, types_mod.record(fields))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov)
	local _ = prov
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	if cur.fields[key] ~= nil then return end
	-- The binding is monotone (no overwrite); to extend we mutate the
	-- field table in place.  This matches the substrate's "single source
	-- of truth" guarantee — the bound record IS the row.
	cur.fields[key] = ty
	-- Field extension is an observable change to ?t; wake watchers.
	local r = subst_mod.find(st.subst, tv)
	wake(st, r)
	-- head_watchers don't fire here: the head tag is already "record".
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov)
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	if subst_mod.phase(st.subst, tv) ~= "open" then return end
	local existing = cur.fields[key]
	if existing == nil then return end
	emit(st, constraint_mod.eq(existing, ty, prov))
end

--: (AltState, integer, string, V5Type, Provenance) -> nil
function M.rule_T_CTSet_Sealed_Reject(st, tv, key, _ty, _prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	record_error(st, "T-CTSet-Sealed-Reject", "set on sealed table key=" .. key)
end

-- Top-level dispatch for CTableSet — picks one of the four T-CTSet-* rules.
--: (AltState, integer, string, V5Type, Provenance) -> nil
local function step_tset(st, tv, key, ty, prov)
	if subst_mod.phase(st.subst, tv) == "sealed" then
		M.rule_T_CTSet_Sealed_Reject(st, tv, key, ty, prov); return
	end
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil then
		M.rule_T_CTSet_Open_Fresh(st, tv, key, ty, prov); return
	end
	if cur.tag == "record" then
		if cur.fields[key] == nil then
			M.rule_T_CTSet_Open_Extend(st, tv, key, ty, prov); return
		end
		M.rule_T_CTSet_Open_Equate(st, tv, key, ty, prov); return
	end
	-- ?t bound to a non-record under Open: degenerate; defer to a CEq.
	if cur == nil then return end
	local cur_nn = cur --[[: V5Type ]]
	local fields = {} --[[: { [string]: V5Type } ]]
	fields[key] = ty
	local rec = types_mod.record(fields) --[[: V5Type ]]
	emit(st, constraint_mod.eq(cur_nn, rec, prov))
end

--: (AltState, integer, integer | nil, Provenance) -> nil
function M.rule_T_CTSeal(st, tv, _mu, _prov)
	if subst_mod.phase(st.subst, tv) == "sealed" then return end
	subst_mod.seal(st.subst, tv)
	-- Phase flip is an observable change; wake.  head_watchers don't
	-- consult phase, only rigid binding head.
	local r = subst_mod.find(st.subst, tv)
	wake(st, r)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Method dispatch
-- ────────────────────────────────────────────────────────────────────────────

-- These return a "status" string so the parity test's explicit calls (e.g.
-- T.eq(stuck_status, "stuck", ...)) can introspect.
--: (AltState, integer, string, integer, Provenance) -> string
function M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	-- Park the constraint.  Use a constraint object for parking.
	if subst_mod.phase(st.subst, tv) ~= "open" then return "noop" end
	local c = constraint_mod.method_call(tv, key, ret, prov) --[[: AltConstraint ]]
	park(st, c, tv, "normal")
	return "stuck"
end

--: (AltState, integer, string, integer, Provenance) -> nil
function M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	local cur = subst_mod.binding(st.subst, tv)
	if cur == nil or cur.tag ~= "record" then return end
	local f_opt = cur.fields[key]
	if f_opt == nil then return end
	local f = f_opt --[[: V5Type ]]
	if f.tag ~= "arrow" then
		-- Per spec: "F[k] = Arrow(_, [τ_ret, ...])".  Non-arrow field is
		-- not addressed by an explicit rule; treat as missing for v5.0.
		record_error(st, "T-CMCall-Sealed-Field", "field is not arrow: " .. key)
		return
	end
	local first_ret = f.ret.fields["1"]
	if first_ret == nil then
		record_error(st, "T-CMCall-Sealed-Field", "arrow has no returns: " .. key)
		return
	end
	local fr = first_ret --[[: V5Type ]]
	local ur = types_mod.uvar(ret) --[[: V5Type ]]
	emit(st, constraint_mod.eq(ur, fr, prov))
end

--: (AltState, integer, string, integer, Provenance) -> nil
function M.rule_T_CMCall_Sealed_Missing(st, tv, key, _ret, _prov)
	if subst_mod.phase(st.subst, tv) ~= "sealed" then return end
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil and cur.tag == "record" and cur.fields[key] ~= nil then return end
	record_error(st, "T-CMCall-Sealed-Missing", "no method " .. key)
end

-- Top-level dispatch for CMethodCall.
--: (AltState, integer, string, integer, Provenance) -> string
local function step_mcall(st, tv, key, ret, prov)
	if subst_mod.phase(st.subst, tv) == "open" then
		return M.rule_T_CMCall_Open_Stuck(st, tv, key, ret, prov)
	end
	local cur = subst_mod.binding(st.subst, tv)
	if cur ~= nil and cur.tag == "record" and cur.fields[key] ~= nil then
		M.rule_T_CMCall_Sealed_Field(st, tv, key, ret, prov)
		return "done"
	end
	M.rule_T_CMCall_Sealed_Missing(st, tv, key, ret, prov)
	return "done"
end

-- ────────────────────────────────────────────────────────────────────────────
-- Instantiation (CInst)
-- ────────────────────────────────────────────────────────────────────────────

-- Iterated substitution of fresh uvars for De Bruijn vars Var(0..n-1).  The
-- substrate's `instantiate(body, arg, depth)` decrements outer indices by 1
-- on each call; per the spec doc § "β-reduction (auxiliary)" we iterate
-- `instantiate(body, fresh_i, 0)` with depth 0 every time.
--: (V5Type, V5Type[]) -> V5Type
local function iter_instantiate(body, args)
	local cur = body --[[: V5Type ]]
	for i = 1, #args do
		local a = args[i]
		if a ~= nil then
			local nxt = types_mod.instantiate(cur, a, 0) --[[: V5Type ]]
			cur = nxt
		end
	end
	return cur
end

--: (AltState, AltScheme, V5Type, Provenance) -> nil
function M.rule_T_CInst_Mono(st, sch, target, prov)
	if sch.binders ~= 0 then return end
	emit(st, constraint_mod.eq(sch.body, target, prov))
end

--: (AltState, AltScheme, V5Type, Provenance) -> nil
function M.rule_T_CInst(st, sch, target, prov)
	local args = {} --[[: V5Type[] ]]
	for i = 1, sch.binders do
		local id = subst_mod.fresh(st.subst, "open")
		local u = types_mod.uvar(id) --[[: V5Type ]]
		args[i] = u
	end
	local body = iter_instantiate(sch.body, args) --[[: V5Type ]]
	emit(st, constraint_mod.eq(body, target, prov))
end

-- ────────────────────────────────────────────────────────────────────────────
-- CHKT (HKT application) + HOUnify
-- ────────────────────────────────────────────────────────────────────────────

-- Miller pattern check (v5.0 restricted): each arg after deref is UVar or
-- Const; args pairwise distinct under types.equal; free uvars of T are a
-- subset of the uvar-arg ids; ?F not free in T.
--: (AltState, V5Type, V5Type[], V5Type) -> (boolean, V5Type[] | nil)
local function miller_check(st, f_deref, args, result)
	if f_deref.tag ~= "uvar" then return false, nil end
	local fid = f_deref.id
	local derefs = {} --[[: V5Type[] ]]
	for i = 1, #args do
		local ai = args[i]
		if ai == nil then return false, nil end
		local d = subst_mod.deref(st.subst, ai) --[[: V5Type ]]
		if d.tag ~= "uvar" and d.tag ~= "const" then return false, nil end
		derefs[i] = d
	end
	-- pairwise distinct
	for i = 1, #derefs do
		for j = i + 1, #derefs do
			local di = derefs[i]; local dj = derefs[j]
			if di ~= nil and dj ~= nil and types_mod.equal(di, dj) then return false, nil end
		end
	end
	-- Build allowed uvar-id set from uvar args.
	local allowed = {} --[[: { [integer]: boolean } ]]
	for i = 1, #derefs do
		local d = derefs[i]
		if d ~= nil and d.tag == "uvar" then allowed[d.id] = true end
	end
	-- T's free uvars (after walking) must be ⊆ allowed (and != ?F).
	local rw = subst_mod.walk(st.subst, result) --[[: V5Type ]]
	local fv = {} --[[: { [integer]: boolean } ]]
	types_mod.collect_uvars(rw, fv)
	if fv[fid] then return false, nil end
	for id, _v in pairs(fv) do
		if not allowed[id] then return false, nil end
	end
	return true, derefs
end

-- Build λ…λ. body' by abstracting UVar(aᵢ.id) -> Var(n - i) for uvar args.
-- For Const args, the pattern requires uniqueness, but Const args don't
-- abstract (they're rigid) — the spec restricts args to UVar/Const, and
-- only UVar args correspond to abstracted positions.  Const args at
-- pattern positions act like rigid type constants and the resulting
-- lambda still binds n positions; the body just doesn't reference them.
-- (This is the v5.0 simplification per the spec.)
--: (AltState, V5Type, V5Type[]) -> V5Type
local function abstract_body(st, t, derefs_args)
	local n = #derefs_args
	-- Walk t once with σ to make all uvar references current.
	local walked = subst_mod.walk(st.subst, t) --[[: V5Type ]]
	-- For each uvar arg at position i (1-indexed), substitute UVar(arg.id)
	-- with Var(n - i).  We do this by recursive structural rewrite.
	-- Build replacement map id -> Var(n - i).
	local repl = {} --[[: { [integer]: V5Type } ]]
	for i = 1, n do
		local d = derefs_args[i]
		if d ~= nil and d.tag == "uvar" then
			local v = types_mod.var(n - i) --[[: V5Type ]]
			repl[d.id] = v
		end
	end
	--: (V5Type) -> V5Type
	local function rewrite(x)
		if x.tag == "uvar" then
			local r = repl[x.id]
			if r ~= nil then return r end
			return x
		elseif x.tag == "var" or x.tag == "const" then
			return x
		elseif x.tag == "app" then
			local rf = rewrite(x.f) --[[: V5Type ]]
			local ra = rewrite(x.a) --[[: V5Type ]]
			return types_mod.app(rf, ra)
		elseif x.tag == "lambda" then
			-- v5.0 spec gap: nested lambdas need shift-aware rewrite.
			-- For v5.0 minimal-core we leave the inner lambda body
			-- as-is (the body's De Bruijn vars refer to its own
			-- binder; rewriting our outer-level uvars inside it is
			-- still safe because uvars and De Bruijn vars don't mix).
			local rb = rewrite(x.b) --[[: V5Type ]]
			return types_mod.lambda(x.k, rb)
		elseif x.tag == "record" then
			local out = {} --[[: { [string]: V5Type } ]]
			for k, v in pairs(x.fields) do
				if v ~= nil then
					local rv = rewrite(v) --[[: V5Type ]]
					out[k] = rv
				end
			end
			return types_mod.record(out)
		elseif x.tag == "arrow" then
			local a = {} --[[: V5Type[] ]]
			for i = 1, #x.args do
				local v = x.args[i]
				if v ~= nil then
					local rv = rewrite(v) --[[: V5Type ]]
					a[i] = rv
				end
			end
			local rret = rewrite(x.ret) --[[: V5Type ]]
			return { tag = "arrow", args = a, ret = rret }
		elseif x.tag == "union" then
			local xs = {} --[[: V5Type[] ]]
			for i = 1, #x.xs do
				local v = x.xs[i]
				if v ~= nil then
					local rv = rewrite(v) --[[: V5Type ]]
					xs[i] = rv
				end
			end
			return types_mod.union(xs)
		end
		return x
	end
	local body = rewrite(walked) --[[: V5Type ]]
	-- Wrap in n lambdas.
	for _i = 1, n do
		local nb = types_mod.lambda("*", body) --[[: V5Type ]]
		body = nb
	end
	return body
end

-- Returns "ok" (bound) or "miss" (Miller doesn't apply).
--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> string
function M.rule_T_CHKT_Miller(st, f, args, result, _prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return "miss" end
	local ok, derefs = miller_check(st, df, args, result)
	if not ok or derefs == nil then return "miss" end
	local lam = abstract_body(st, result, derefs) --[[: V5Type ]]
	bind_and_wake(st, df.id, lam)
	return "ok"
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Reduce(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "lambda" then return end
	-- Walk down through up to length(args) lambdas, peeling one per arg.
	local cur = df --[[: V5Type ]]
	local i = 1
	while i <= #args and cur.tag == "lambda" do
		local ai = args[i]
		if ai == nil then break end
		local nxt = types_mod.instantiate(cur.b, ai, 0) --[[: V5Type ]]
		cur = nxt
		i = i + 1
	end
	-- If we exited because we ran out of args while cur is still lambda,
	-- emit a CEq directly — this surfaces as a shape mismatch per the
	-- spec gap on kind inference.
	emit(st, constraint_mod.eq(cur, result, prov))
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Rigid_Mismatch(st, f, args, _result, _prov)
	local _ = args
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag == "uvar" or df.tag == "lambda" then return end
	record_error(st, "T-CHKT-Rigid-Mismatch", "HKT app on non-constructor: " .. df.tag)
end

--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
function M.rule_T_CHKT_Park(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f) --[[: V5Type ]]
	if df.tag ~= "uvar" then return end
	-- Emit a HOUnify residue and park on head-rigidity of ?F.
	local id = (function()
		_G._op_sem_alt_hounify_next = (_G._op_sem_alt_hounify_next or 200000) + 1
		return _G._op_sem_alt_hounify_next
	end)()
	local c = { id = id, tag = "hounify", f = df, args = args, result = result, prov = prov }
	st.inert[c.id] = c
	subst_mod.watch_head(st.subst, df.id, c.id)
end

--: (AltState, AltConstraint) -> nil
function M.rule_T_HOUnify_Wake(st, c)
	-- Re-emit as CHKT.
	if c.tag ~= "hounify" then return end
	local ck = { id = c.id, tag = "chkt", f = c.f, args = c.args, result = c.result, prov = c.prov } --[[: AltConstraint ]]
	emit(st, ck)
end

--: (AltState, AltConstraint) -> nil
function M.rule_T_HOUnify_Stuck(st, c)
	local _ = c
	record_error(st, "T-HOUnify-Stuck",
		"ambiguous constructor variable: head shape never rigidified")
end

-- Top-level dispatch for CHKT.
--: (AltState, V5Type, V5Type[], V5Type, Provenance) -> nil
local function step_chkt(st, f, args, result, prov)
	local df = subst_mod.deref(st.subst, f)
	if df.tag == "lambda" then
		M.rule_T_CHKT_Reduce(st, f, args, result, prov); return
	end
	if df.tag ~= "uvar" then
		M.rule_T_CHKT_Rigid_Mismatch(st, f, args, result, prov); return
	end
	-- ?F is unbound uvar.  Try Miller first.
	local status = M.rule_T_CHKT_Miller(st, f, args, result, prov)
	if status == "ok" then return end
	M.rule_T_CHKT_Park(st, f, args, result, prov)
end

-- ────────────────────────────────────────────────────────────────────────────
-- Solver step (S-Step dispatcher)
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState, AltConstraint) -> nil
function M.step(st, c)
	st.steps = st.steps + 1
	if c.tag == "ceq" then
		step_ceq(st, c.a, c.b, c.prov)
	elseif c.tag == "csub" then
		step_csub(st, c.a, c.b, c.prov)
	elseif c.tag == "topen" then
		M.rule_T_CTOpen(st, c.tv, c.prov)
	elseif c.tag == "tset" then
		step_tset(st, c.tv, c.key, c.ty, c.prov)
	elseif c.tag == "tseal" then
		M.rule_T_CTSeal(st, c.tv, c.mu, c.prov)
	elseif c.tag == "mcall" then
		step_mcall(st, c.tv, c.key, c.ret, c.prov)
	elseif c.tag == "cinst" then
		if c.scheme.binders == 0 then
			M.rule_T_CInst_Mono(st, c.scheme, c.target, c.prov)
		else
			M.rule_T_CInst(st, c.scheme, c.target, c.prov)
		end
	elseif c.tag == "chkt" then
		step_chkt(st, c.f, c.args, c.result, c.prov)
	elseif c.tag == "hounify" then
		-- Already in inert by spec; if seen on the worklist via wake,
		-- retry by treating as CHKT.
		M.rule_T_HOUnify_Wake(st, c)
	end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Solver loop (S-Step / S-Park / S-Wake / S-Quiesce)
-- ────────────────────────────────────────────────────────────────────────────

--: (AltState) -> nil
function M.run(st)
	while st.head <= st.tail do
		local c = st.worklist[st.head]
		st.worklist[st.head] = nil
		st.head = st.head + 1
		if c ~= nil then M.step(st, c) end
	end
	-- S-Quiesce: report any inert HOUnify as ambiguous.
	for _cid, c in pairs(st.inert) do
		if c.tag == "hounify" then
			M.rule_T_HOUnify_Stuck(st, c)
		end
	end
end

--: (AltState, integer) -> V5Type
function M.resolve(st, tv)
	local u = types_mod.uvar(tv) --[[: V5Type ]]
	return subst_mod.walk(st.subst, u)
end

--: (AltState) -> integer
function M.error_count(st) return #st.errors end

M.variance = variance_mod

return M
