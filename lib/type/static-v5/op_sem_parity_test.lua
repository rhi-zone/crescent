-- lib/type/static-v5/op_sem_parity_test.lua
-- Parity tests between the docs-form inference rules
-- (docs/typechecker-v5-operational-semantics.md) and the executable spec
-- (lib/type/static-v5/op_sem.lua).
--
-- Methodology.  For each fixture:
--   1. EXEC: feed the gen-pass constraint list to a fresh op_sem state,
--      run M.run (the S-Step/S-Park/S-Wake/S-Quiesce loop), record the
--      final substitution + errors + traces.
--   2. DOCS: encode the rule application sequence manually — a list of
--      (rule_label, hypotheses) tuples — and invoke the corresponding
--      M.rule_<label> function in order, threading the same state shape.
--      The docs trace must NOT use M.run; it must drive the rules by
--      hand, exactly as the doc form describes.
--   3. ASSERT: walk the resulting substitution at the binding tvars and
--      check both forms produce equal types; check error sets match.
--
-- If the test fails, EITHER the doc rule encoding is wrong OR the
-- executable spec is wrong — both must be reconciled (per the task
-- brief).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T            = require("lib.test.assert")
local types_mod    = require("lib.type.experiments.v5_perf.types")
local subst_mod    = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local op_sem       = require("lib.type.static-v5.op_sem")

local _ = subst_mod -- alias reachable for sigs

--: (string) -> Provenance
local function prov(name) return op_sem.prov("fixture", 1, name) end

-- Walk-equals on two V5Types under their respective substitutions.
--: (V5Type, V5Type) -> boolean
local function walk_equal(a, b) return types_mod.equal(a, b) end

-- Run the executable form on a list of initial constraints.  Returns
-- the final state.
--: (OpSemConstraint[]) -> OpSemState
local function run_exec(initial)
	local st = op_sem.new_state()
	for i = 1, #initial do
		local c = initial[i]
		if c ~= nil then op_sem.emit(st, c) end
	end
	op_sem.run(st)
	return st
end

-- ─── Fixture 1: CEq basic ───────────────────────────────────────────────
-- Source:  local x : ?x = 1; local y : ?y = x
-- Gen emits:  CEq(?x, Const("number")) ; CEq(?y, ?x)
-- Expected:  resolve(?x) = Const("number"), resolve(?y) = Const("number"),
--            no errors.
describe = T.describe or function(_n, f) f() end
local it = T.it or function(_n, f) f() end

T.describe("op_sem parity: fixture 1 — CEq basic", function()
	T.it("exec form vs docs form produce equal substitution", function()
		-- EXEC ─────────────────────────────────────────────────────────
		local exec = op_sem.new_state()
		local x = subst_mod.fresh(exec.subst, "open")
		local y = subst_mod.fresh(exec.subst, "open")
		local number = types_mod.const("number") --[[: V5Type ]]
		local ux = types_mod.uvar(x) --[[: V5Type ]]
		local uy = types_mod.uvar(y) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.eq(ux, number, prov("x=1")))
		op_sem.emit(exec, constraint_mod.eq(uy, ux, prov("y=x")))
		op_sem.run(exec)
		local rx_exec = op_sem.resolve(exec, x)
		local ry_exec = op_sem.resolve(exec, y)

		-- DOCS ─────────────────────────────────────────────────────────
		-- Rule trace: (T-CEq-Bind-L x ↦ number) ; (T-CEq-Bind-R y ↦ x)
		local docs = op_sem.new_state()
		local x2 = subst_mod.fresh(docs.subst, "open")
		local y2 = subst_mod.fresh(docs.subst, "open")
		op_sem.rule_T_CEq_Bind_L(docs, types_mod.uvar(x2), number, prov("x=1"))
		-- y = x: both uvars → T-CEq-UU
		op_sem.rule_T_CEq_UU(docs, types_mod.uvar(y2), types_mod.uvar(x2), prov("y=x"))
		local rx_docs = op_sem.resolve(docs, x2)
		local ry_docs = op_sem.resolve(docs, y2)

		T.ok(walk_equal(rx_exec, number), "exec resolves x to number")
		T.ok(walk_equal(ry_exec, number), "exec resolves y to number")
		T.ok(walk_equal(rx_docs, number), "docs resolves x to number")
		T.ok(walk_equal(ry_docs, number), "docs resolves y to number")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 2: construction phase end-to-end ───────────────────────────
-- Source:  local t = {}; t.x = 1; t.y = "hi"; setmetatable(t, mt); return t
-- Gen emits: CTableOpen(?t)
--            CTableSet(?t, "x", Const("number"))
--            CTableSet(?t, "y", Const("string"))
--            CTableSeal(?t, ?mu)
-- Expected:  resolve(?t) = Record{x=number, y=string} @ Sealed, no errors.

T.describe("op_sem parity: fixture 2 — construction phase", function()
	T.it("exec form vs docs form produce equal sealed record", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local strty  = types_mod.const("string") --[[: V5Type ]]

		-- EXEC
		local exec = op_sem.new_state()
		local t = subst_mod.fresh(exec.subst, "open")
		local mu = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.table_open(t, prov("t={}")))
		op_sem.emit(exec, constraint_mod.table_set(t, "x", number, prov("t.x=1")))
		op_sem.emit(exec, constraint_mod.table_set(t, "y", strty, prov("t.y=hi")))
		op_sem.emit(exec, constraint_mod.table_seal(t, mu, prov("setmt")))
		op_sem.run(exec)
		local rt_exec = op_sem.resolve(exec, t)
		local ph_exec = subst_mod.phase(exec.subst, t)

		-- DOCS — drive the rules by hand in source order.
		local docs = op_sem.new_state()
		local t2 = subst_mod.fresh(docs.subst, "open")
		local mu2 = subst_mod.fresh(docs.subst, "open")
		op_sem.rule_T_CTOpen(docs, t2, prov("t={}"))
		-- After CTOpen, ?t bound to empty record.  Next set goes via
		-- T-CTSet-Open-Extend (field new, record present).
		op_sem.rule_T_CTSet_Open_Extend(docs, t2, "x", number, prov("t.x=1"))
		op_sem.rule_T_CTSet_Open_Extend(docs, t2, "y", strty, prov("t.y=hi"))
		op_sem.rule_T_CTSeal(docs, t2, mu2, prov("setmt"))
		local rt_docs = op_sem.resolve(docs, t2)
		local ph_docs = subst_mod.phase(docs.subst, t2)

		T.ok(walk_equal(rt_exec, rt_docs), "exec and docs records equal")
		T.eq(ph_exec, ph_docs, "phase matches")
		T.eq(ph_exec, "sealed", "ended sealed")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 3: CMethodCall on sealed table ─────────────────────────────
-- Source (after fixture 2's t with a method instead of a value):
--          local t = {}; t.foo = function(self) return 42 end
--          setmetatable(t, mt); local r = t:foo()
-- Gen emits: CTableOpen(?t)
--            CTableSet(?t, "foo", Arrow([?self], [Const("number")]))
--            CTableSeal(?t, ?mu)
--            CMethodCall(?t, "foo", ?r)
-- Expected:  resolve(?r) = Const("number"), no errors.
-- Note: CMethodCall arrives BEFORE seal in some interleavings; exec
-- form must park, then unstick when seal fires.

T.describe("op_sem parity: fixture 3 — CMethodCall after seal", function()
	T.it("CMethodCall resolves through sealed table field", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local self_ty = types_mod.const("any-table") --[[: V5Type ]]
		local foo_arrow = types_mod.arrow({ self_ty }, { number }) --[[: V5Type ]]

		-- EXEC: emit CMethodCall BEFORE seal to exercise stuck/wake.
		local exec = op_sem.new_state()
		local t = subst_mod.fresh(exec.subst, "open")
		local mu = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.table_open(t, prov("t={}")))
		op_sem.emit(exec, constraint_mod.table_set(t, "foo", foo_arrow, prov("t.foo=fn")))
		op_sem.emit(exec, constraint_mod.method_call(t, "foo", r, prov("t:foo()")))
		op_sem.emit(exec, constraint_mod.table_seal(t, mu, prov("setmt")))
		op_sem.run(exec)
		local rr_exec = op_sem.resolve(exec, r)

		-- DOCS: drive rules in source order; CMethodCall hit while
		-- still Open → T-CMCall-Open-Stuck.  After CTSeal, re-apply
		-- T-CMCall-Sealed-Field manually (the docs form's "wake +
		-- re-step" cycle).
		local docs = op_sem.new_state()
		local t2 = subst_mod.fresh(docs.subst, "open")
		local mu2 = subst_mod.fresh(docs.subst, "open")
		local r2 = subst_mod.fresh(docs.subst, "open")
		op_sem.rule_T_CTOpen(docs, t2, prov("t={}"))
		op_sem.rule_T_CTSet_Open_Extend(docs, t2, "foo", foo_arrow, prov("t.foo=fn"))
		local stuck_status = op_sem.rule_T_CMCall_Open_Stuck(docs, t2, "foo", r2, prov("t:foo()"))
		T.eq(stuck_status, "stuck", "open mcall is stuck")
		op_sem.rule_T_CTSeal(docs, t2, mu2, prov("setmt"))
		op_sem.rule_T_CMCall_Sealed_Field(docs, t2, "foo", r2, prov("t:foo()-wake"))
		-- The emitted CEq(?r2, number) needs to be processed by hand
		-- in the docs form; we know there's exactly one.  Apply
		-- T-CEq-Bind-L (r2 is uvar, number is concrete).
		op_sem.rule_T_CEq_Bind_L(docs, types_mod.uvar(r2), number, prov("cmcall-result"))
		local rr_docs = op_sem.resolve(docs, r2)

		T.ok(walk_equal(rr_exec, number), "exec resolves r to number")
		T.ok(walk_equal(rr_docs, number), "docs resolves r to number")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 4: setmetatable(t, nil) rejection (item 5 closure) ─────────
-- Per the spec, this is rejected at the stdlib-types boundary: nil
-- doesn't match the parameter type of setmetatable.  Surfaces as a
-- T-CEq-Mismatch.  Encoded directly here as a CEq between nil-const and
-- a table tvar.

T.describe("op_sem parity: fixture 4 — setmetatable(t, nil) reject", function()
	T.it("nil for metatable parameter is a kind/const mismatch", function()
		local nil_ty = types_mod.const("nil") --[[: V5Type ]]
		local tbl_ty = types_mod.const("table") --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.eq(nil_ty, tbl_ty, prov("setmt-nil")))
		op_sem.run(exec)

		local docs = op_sem.new_state()
		op_sem.rule_T_CEq_Const(docs, nil_ty, tbl_ty, prov("setmt-nil"))

		T.eq(op_sem.error_count(exec), 1, "exec one error")
		T.eq(op_sem.error_count(docs), 1, "docs one error")
		T.eq(exec.errors[1].rule, "T-CEq-Const", "exec error rule")
		T.eq(docs.errors[1].rule, "T-CEq-Const", "docs error rule")
	end)
end)

-- ─── Fixture 5: let-poly via CInst ──────────────────────────────────────
-- Source:  local id = function(x) return x end
--          id(1); id("hi")
-- Gen emits a scheme  ∀α. α → α  and two CInst constraints,
-- targeted at fresh ?call_n tvars equated to the call's expected arrow.

T.describe("op_sem parity: fixture 5 — let-poly CInst", function()
	T.it("two instantiations of identity scheme produce two fresh tvars", function()
		-- Scheme: \alpha. (Arrow [Var 0] [Var 0])
		local body = types_mod.arrow({ types_mod.var(0) }, { types_mod.var(0) }) --[[: V5Type ]]
		local sch = op_sem.scheme(1, body)

		-- Target arrow for call site 1: (number) -> ?r1
		-- Target arrow for call site 2: (string) -> ?r2
		local number = types_mod.const("number") --[[: V5Type ]]
		local strty  = types_mod.const("string") --[[: V5Type ]]

		-- EXEC
		local exec = op_sem.new_state()
		local r1 = subst_mod.fresh(exec.subst, "open")
		local r2 = subst_mod.fresh(exec.subst, "open")
		local target1 = types_mod.arrow({ number }, { types_mod.uvar(r1) }) --[[: V5Type ]]
		local target2 = types_mod.arrow({ strty },  { types_mod.uvar(r2) }) --[[: V5Type ]]
		op_sem.emit(exec, op_sem.inst(sch, target1, prov("id(1)")))
		op_sem.emit(exec, op_sem.inst(sch, target2, prov("id(hi)")))
		op_sem.run(exec)
		local rr1_exec = op_sem.resolve(exec, r1)
		local rr2_exec = op_sem.resolve(exec, r2)

		-- DOCS
		local docs = op_sem.new_state()
		local r1d = subst_mod.fresh(docs.subst, "open")
		local r2d = subst_mod.fresh(docs.subst, "open")
		local target1d = types_mod.arrow({ number }, { types_mod.uvar(r1d) }) --[[: V5Type ]]
		local target2d = types_mod.arrow({ strty },  { types_mod.uvar(r2d) }) --[[: V5Type ]]
		op_sem.rule_T_CInst(docs, sch, target1d, prov("id(1)"))
		op_sem.rule_T_CInst(docs, sch, target2d, prov("id(hi)"))
		-- Drain emitted CEqs by feeding them through M.step manually.
		while docs.head <= docs.tail do
			local c = docs.worklist[docs.head]
			docs.worklist[docs.head] = nil
			docs.head = docs.head + 1
			if c ~= nil then op_sem.step(docs, c) end
		end
		local rr1_docs = op_sem.resolve(docs, r1d)
		local rr2_docs = op_sem.resolve(docs, r2d)

		T.ok(walk_equal(rr1_exec, number), "exec r1 = number (id(1))")
		T.ok(walk_equal(rr2_exec, strty),  "exec r2 = string (id(\"hi\"))")
		T.ok(walk_equal(rr1_docs, number), "docs r1 = number")
		T.ok(walk_equal(rr2_docs, strty),  "docs r2 = string")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 6: multi-return into row (SPEC GAP, encoded as stand-in) ──
-- Per task brief: cover `t.x, t.y = f()` where f's return arity unions
-- to (int, int|nil).  CMultiReturn is OUT OF v5.0 scope per the log's
-- re-gate schedule and explicitly listed in the spec doc's "What this
-- does NOT cover" section.
--
-- Encoded here as a stand-in: simulate the gen pass having already
-- resolved the multi-return into two scalar CEqs (?ret1 = number,
-- ?ret2 = number|nil), and feed CTableSet for t.x and t.y.  The
-- ASSERTION is on what the v5.0 minimal core CAN handle — the
-- nil-padding union semantics live in the not-yet-implemented
-- CMultiReturn extension.

T.describe("op_sem parity: fixture 6 — multi-return scalar stand-in (SPEC GAP)", function()
	T.it("two field assignments from pre-resolved return tvars", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		-- Stand-in for `int | nil`: just `nil` here; the union form
		-- isn't in the minimal core.  See spec gap note in the doc.
		local nilty = types_mod.const("nil") --[[: V5Type ]]

		local exec = op_sem.new_state()
		local t = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.table_open(t, prov("t={}")))
		op_sem.emit(exec, constraint_mod.table_set(t, "x", number, prov("t.x")))
		op_sem.emit(exec, constraint_mod.table_set(t, "y", nilty, prov("t.y")))
		op_sem.run(exec)
		local rt_exec = op_sem.resolve(exec, t)

		local docs = op_sem.new_state()
		local t2 = subst_mod.fresh(docs.subst, "open")
		op_sem.rule_T_CTOpen(docs, t2, prov("t={}"))
		op_sem.rule_T_CTSet_Open_Extend(docs, t2, "x", number, prov("t.x"))
		op_sem.rule_T_CTSet_Open_Extend(docs, t2, "y", nilty, prov("t.y"))
		local rt_docs = op_sem.resolve(docs, t2)

		T.ok(walk_equal(rt_exec, rt_docs), "exec and docs match on scalar stand-in")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
		-- SPEC GAP: real CMultiReturn would unify `?ret2 = number | nil`
		-- and narrowing would then strip nil in flow-positive positions.
		-- That mechanism is owed in the CMultiReturn op-sem extension.
	end)
end)

-- ─── Fixture 7: circular require (DRIVER-LEVEL, not constraint-level) ──
-- Per the spec doc + log items 3,4,8: circular require is rejected at
-- module-ordering time, not by op_sem.  This fixture exists to assert
-- that op_sem.run on an empty constraint list (the "we never made it
-- to typechecking" state) is consistent across forms.  Driver-level
-- behaviour is not in op_sem's surface.

T.describe("op_sem parity: fixture 7 — circular require (driver level)", function()
	T.it("op_sem on no constraints is consistent (driver rejects upstream)", function()
		local exec = op_sem.new_state()
		op_sem.run(exec)
		local docs = op_sem.new_state()
		-- DOCS: empty rule trace.
		T.eq(op_sem.error_count(exec), 0, "exec empty: no errors")
		T.eq(op_sem.error_count(docs), 0, "docs empty: no errors")
		-- SPEC GAP / DESIGN: the actual circular-require rejection
		-- lives in the (not-yet-implemented) module driver, with a
		-- "restructure your modules" diagnostic.  Encoded in the
		-- spec doc but not in op_sem itself.
	end)
end)

-- ─── Fixture 8 (optional): row variable narrowing suppression ──────────
-- Per the task brief and log item 7's soundness floor: narrowing on a
-- discriminant suppressed when a row variable affects the path.  Row
-- machinery (CRow) is OUT OF v5.0 minimal scope per the doc.  Fixture
-- intentionally omitted; reinstate when the CRow op-sem extension lands.

return true
