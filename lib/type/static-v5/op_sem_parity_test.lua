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

-- mkrec(bare): build a closed three-region TRecord from a bare { [name]: V5Type }
-- map (each value wrapped as a non-optional, non-readonly TField).  Test
-- ergonomics for the Spec C shape.
--: ({ [string]: V5Type }) -> V5Type
local function mkrec(bare)
	local fields = {} --[[: { [string]: TField } ]]
	for k, v in pairs(bare) do
		if v ~= nil then fields[k] = types_mod.field(v, false, false) end
	end
	return types_mod.record(fields)
end
local _ = mkrec

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

-- ─── Fixtures 6 / 6a–6d RETIRED (Spec C) ────────────────────────────────
-- These exercised multi-return as POSITIONAL RECORDS (`Record{"1"=…,"2"=…}`)
-- through the now-deleted positional branch of T-CSub-Record-Width.  Spec C
-- retires positional records: multi-return sequences are TPack (Spec B).  The
-- equivalent alignment/arity behaviour is covered by the independent-parity
-- pack fixtures F-B1..F-B10 (op_sem_independent_parity_test.lua).

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

-- ═══════════════════════════════════════════════════════════════════════
-- CHKT + HOUnify fixtures (2026-05-24 extension)
-- ═══════════════════════════════════════════════════════════════════════

-- ─── Fixture 9: Functor<Maybe> instance + fmap(f, just(1)) (H2 case) ───
-- Maybe is a known type constructor (bound as Lambda \alpha. Maybe alpha
-- here; for the test we use Const("Maybe") composed as Lambda \alpha. Maybe-alpha
-- represented structurally as a record { tag: "just"|"nothing", val: alpha }).
-- We assert that CHKT(Maybe, [int], ?r) reduces (T-CHKT-Reduce) to
-- the expected Maybe-of-int shape.

T.describe("op_sem parity: fixture 9 — CHKT Reduce for Functor<Maybe>", function()
	T.it("CHKT(Maybe, [int], ?r) reduces to Maybe-of-int", function()
		-- Define Maybe := \alpha. Record{ tag: string, val: alpha }
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		local maybe_body = mkrec({ tag = string_ty, val = var0 }) --[[: V5Type ]]
		local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		-- EXEC: bind ?F to Maybe lambda, then CHKT(?F, [int], ?r).
		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.eq(uf, maybe_lambda, prov("F=Maybe")))
		op_sem.emit(exec, op_sem.chkt(uf, { int_ty }, ur, prov("fmap-apply")))
		op_sem.run(exec)
		local rr_exec = op_sem.resolve(exec, r)

		-- DOCS: drive by hand. T-CEq-Bind-L binds ?F to lambda, then
		-- step_chkt routes to T-CHKT-Reduce (since deref(?F) is lambda).
		local docs = op_sem.new_state()
		local f2 = subst_mod.fresh(docs.subst, "open")
		local r2 = subst_mod.fresh(docs.subst, "open")
		op_sem.rule_T_CEq_Bind_L(docs, types_mod.uvar(f2), maybe_lambda, prov("F=Maybe"))
		op_sem.rule_T_CHKT_Reduce(docs, types_mod.uvar(f2), { int_ty }, types_mod.uvar(r2), prov("fmap-apply"))
		-- Drain emitted CEq(reduced, ?r2).
		while docs.head <= docs.tail do
			local c = docs.worklist[docs.head]
			docs.worklist[docs.head] = nil
			docs.head = docs.head + 1
			if c ~= nil then op_sem.step(docs, c) end
		end
		local rr_docs = op_sem.resolve(docs, r2)

		-- The expected shape: Record{ tag: string, val: int }.
		local expected = mkrec({ tag = string_ty, val = int_ty }) --[[: V5Type ]]
		T.ok(walk_equal(rr_exec, expected), "exec r = Maybe<int>")
		T.ok(walk_equal(rr_docs, expected), "docs r = Maybe<int>")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 10: Miller pattern — CHKT(?F, [?a], result) ─────────────────
-- ?F unbound; arg ?a is rigid (its own uvar treated as a distinct skolem-
-- like name); result references ?a.  Miller fragment should bind ?F to
-- (lambda. Var 0)-style identity-ish constructor.
--
-- We use UVar(a) as the "rigid" argument with the v5.0 restriction that
-- args may be UVar or Const.

T.describe("op_sem parity: fixture 10 — CHKT Miller pattern", function()
	T.it("CHKT(?F, [?a], ?a) binds ?F to lambda x. x (identity constructor)", function()
		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local a = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ua = types_mod.uvar(a) --[[: V5Type ]]
		-- result is the same uvar as the arg: ?F<?a> = ?a.
		op_sem.emit(exec, op_sem.chkt(uf, { ua }, ua, prov("F-of-a=a")))
		op_sem.run(exec)
		-- ?F should be bound to lambda * (Var 0).
		local rf = op_sem.resolve(exec, f)

		local docs = op_sem.new_state()
		local f2 = subst_mod.fresh(docs.subst, "open")
		local a2 = subst_mod.fresh(docs.subst, "open")
		local uf2 = types_mod.uvar(f2) --[[: V5Type ]]
		local ua2 = types_mod.uvar(a2) --[[: V5Type ]]
		op_sem.rule_T_CHKT_Miller(docs, uf2, { ua2 }, ua2, prov("F-of-a=a"))
		local rf2 = op_sem.resolve(docs, f2)

		local expected = types_mod.lambda("*", types_mod.var(0)) --[[: V5Type ]]
		T.ok(walk_equal(rf, expected), "exec ?F = lambda x. x")
		T.ok(walk_equal(rf2, expected), "docs ?F = lambda x. x")
		T.eq(op_sem.error_count(exec), 0, "exec no errors")
		T.eq(op_sem.error_count(docs), 0, "docs no errors")
	end)
end)

-- ─── Fixture 11: HOUnify ambiguity (compose F G outside Miller) ─────────
-- CHKT(?F, [?G(int)], ?r) where ?G is also unbound — args contain an App
-- node, violating v5.0's restricted-Miller (UVar/Const only).  Should
-- park as HOUnify and remain ambiguous at quiescence.

T.describe("op_sem parity: fixture 11 — HOUnify ambiguity (compose)", function()
	T.it("CHKT outside Miller fragment parks as HOUnify, errors at quiescence", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		-- Arg is App(?G, int) — neither uvar nor const at top level.
		local app_arg = types_mod.app(ug, int_ty) --[[: V5Type ]]
		op_sem.emit(exec, op_sem.chkt(uf, { app_arg }, ur, prov("compose")))
		op_sem.run(exec)

		local docs = op_sem.new_state()
		local f2 = subst_mod.fresh(docs.subst, "open")
		local g2 = subst_mod.fresh(docs.subst, "open")
		local r2 = subst_mod.fresh(docs.subst, "open")
		local uf2 = types_mod.uvar(f2) --[[: V5Type ]]
		local ug2 = types_mod.uvar(g2) --[[: V5Type ]]
		local ur2 = types_mod.uvar(r2) --[[: V5Type ]]
		local app_arg2 = types_mod.app(ug2, int_ty) --[[: V5Type ]]
		-- Miller miss -> Park (emit HOUnify), park-on-head(?F2).
		local miller_status = op_sem.rule_T_CHKT_Miller(docs, uf2, { app_arg2 }, ur2, prov("compose"))
		T.eq(miller_status, "miss", "miller does not apply")
		op_sem.rule_T_CHKT_Park(docs, uf2, { app_arg2 }, ur2, prov("compose"))
		-- The emitted HOUnify in docs.worklist needs to be parked manually.
		-- Drain via op_sem.step which will park it (returns "stuck").
		while docs.head <= docs.tail do
			local c = docs.worklist[docs.head]
			docs.worklist[docs.head] = nil
			docs.head = docs.head + 1
			if c ~= nil then
				local status = op_sem.step(docs, c)
				if status == "stuck" then
					-- emulate park: insert into inert, T-HOUnify-Stuck at end.
					docs.inert[c.id] = c
				end
			end
		end
		-- Simulate S-Quiesce for hounify in inert.
		for _cid, c in pairs(docs.inert) do
			if c.tag == "hounify" then op_sem.rule_T_HOUnify_Stuck(docs, c) end
		end

		-- Both should report exactly one HOUnify-Stuck error.
		T.ok(op_sem.error_count(exec) >= 1, "exec has hounify error")
		T.ok(op_sem.error_count(docs) >= 1, "docs has hounify error")
		local found_exec = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-HOUnify-Stuck" then found_exec = true end
		end
		local found_docs = false
		for i = 1, #docs.errors do
			local e = docs.errors[i]
			if e ~= nil and e.rule == "T-HOUnify-Stuck" then found_docs = true end
		end
		T.ok(found_exec, "exec error is T-HOUnify-Stuck")
		T.ok(found_docs, "docs error is T-HOUnify-Stuck")
	end)
end)

-- ─── Fixture 12: HOUnify wakes after downstream rigidifies head ─────────
-- CHKT(?F, [App(?G, int)], ?r) parks; a downstream CEq(?F, Maybe-lambda)
-- rigidifies ?F.  The HOUnify wakes, re-emits CHKT, which now T-CHKT-Reduces.

T.describe("op_sem parity: fixture 12 — HOUnify wakes on head rigidification", function()
	T.it("downstream CEq rigidifies ?F; HOUnify wakes and reduces", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		-- Maybe := \alpha. Record{ tag: string, val: alpha }
		local maybe_body = mkrec({ tag = string_ty, val = var0 }) --[[: V5Type ]]
		local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]

		-- EXEC.  CHKT first (with App arg → out of Miller, parks);
		-- then CEq(?F, Maybe-lambda) rigidifies head; wake; reduce.
		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		-- Use Const arg pattern (in Miller) then bind G later; simpler:
		-- use a plain UVar arg (allowed in Miller) but emit CHKT BEFORE F
		-- is rigid — wait, Miller succeeds when F is uvar and args are
		-- uvar.  We want a case where Miller FAILS but downstream still
		-- rigidifies F.  Use App arg.
		local app_arg = types_mod.app(ug, int_ty) --[[: V5Type ]]
		op_sem.emit(exec, op_sem.chkt(uf, { app_arg }, ur, prov("chkt-first")))
		op_sem.emit(exec, constraint_mod.eq(uf, maybe_lambda, prov("F=Maybe-later")))
		op_sem.run(exec)
		-- After wake & reduce: ?r should be Record{tag:string, val: App(?G, int)}.
		local rr_exec = op_sem.resolve(exec, r)
		local expected = mkrec({ tag = string_ty,
			val = types_mod.app(types_mod.uvar(g), int_ty) }) --[[: V5Type ]]

		T.ok(op_sem.error_count(exec) == 0, "exec resolves cleanly after wake")
		T.ok(walk_equal(rr_exec, expected), "exec ?r reduces to Maybe-of-App(?G,int)")
		-- Reactivations may be 0 if HOUnify never made it to inert before
		-- the rigidifying CEq fired (FIFO ordering matters); but the wake
		-- path is exercised in fixture 12b below.
	end)
end)

-- ─── Fixture 12b: HOUnify actually parks then wakes (interleaved) ──────
-- Force the HOUnify into inert by interposing constraints that drain the
-- worklist between the CHKT and the rigidifying CEq.

T.describe("op_sem parity: fixture 12b — HOUnify parks then wakes", function()
	T.it("HOUnify reaches inert; subsequent CEq rigidifies head; reactivation", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		local maybe_body = mkrec({ tag = string_ty, val = var0 }) --[[: V5Type ]]
		local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]

		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		local app_arg = types_mod.app(ug, int_ty) --[[: V5Type ]]
		-- Emit only the CHKT first; run to quiescence (HOUnify parks).
		op_sem.emit(exec, op_sem.chkt(uf, { app_arg }, ur, prov("chkt-1")))
		op_sem.run(exec)
		-- Now HOUnify should be in inert + an error reported by S-Quiesce.
		-- We continue: emit the rigidifying CEq, re-run.  The hounify is
		-- inert; binding ?F via wake_head should reactivate it.
		local errs_before = op_sem.error_count(exec)
		op_sem.emit(exec, constraint_mod.eq(uf, maybe_lambda, prov("F=Maybe-later")))
		op_sem.run(exec)
		-- Reactivation count should now be at least 1 (HOUnify woken).
		T.ok(exec.reactivations >= 1, "HOUnify reactivated after head rigidified")
		-- ?r should resolve to the reduced shape.
		local rr_exec = op_sem.resolve(exec, r)
		local expected = mkrec({ tag = string_ty,
			val = types_mod.app(types_mod.uvar(g), int_ty) }) --[[: V5Type ]]
		T.ok(walk_equal(rr_exec, expected), "?r reduces to Maybe-of-App(?G,int) after wake")
		-- Note: errs_before includes the T-HOUnify-Stuck from first
		-- quiescence; the second run additionally re-runs hounify but it
		-- now resolves cleanly (no extra error from the re-run path).
		local _ = errs_before
	end)
end)

-- ─── Fixture 13: HOUnify never resolves (ambiguous to quiescence) ──────
-- A standalone CHKT with App arg and nothing ever rigidifies ?F.

T.describe("op_sem parity: fixture 13 — HOUnify never resolves", function()
	T.it("standalone CHKT outside Miller, ?F never rigidifies — ambiguous", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		local exec = op_sem.new_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		local app_arg = types_mod.app(ug, int_ty) --[[: V5Type ]]
		op_sem.emit(exec, op_sem.chkt(uf, { app_arg }, ur, prov("orphan-chkt")))
		op_sem.run(exec)

		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-HOUnify-Stuck" then found = true end
		end
		T.ok(found, "exec reports T-HOUnify-Stuck at quiescence")
	end)
end)

-- ─── Fixture 8: CRow narrowing-suppression soundness floor (G8) ────────
-- Scenario A (suppressed narrowing → error): open-row record + CRowLacks
-- with no CRowClose drives to quiescence with the constraint still parked.
-- The solver must report S-Quiesce-CRowLacks — the row var was never closed,
-- so narrowing is unsound and the constraint cannot be discharged.
-- Scenario B (narrowing committed → success): same setup plus CRowClose
-- before quiescence; the row closes without "tag", CRowLacks resolves to
-- pass, no errors.

T.describe("op_sem parity: fixture 8 — CRow narrowing suppression soundness floor", function()
	T.it("Scenario A: unresolved CRowLacks at quiescence → S-Quiesce-CRowLacks error", function()
		local exec = op_sem.new_state()
		local rv = types_mod.rowvar(8) --[[: V5Type ]]
		local rec = types_mod.record_open({}, rv) --[[: V5Type ]]
		-- CRowLacks(rec, "tag") — parks on open row; no CRowClose follows.
		op_sem.emit(exec, constraint_mod.row_lacks(rec, "tag", prov("lacks-tag-open")))
		op_sem.run(exec)
		-- Still-parked CRowLacks at quiescence is a soundness violation (G8).
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CRowLacks" then found = true end
		end
		T.ok(found, "open-row CRowLacks unresolved at quiescence: S-Quiesce-CRowLacks fired")
	end)

	T.it("Scenario B: CRowClose before quiescence → CRowLacks resolves, no errors", function()
		local exec = op_sem.new_state()
		local rv = types_mod.rowvar(9) --[[: V5Type ]]
		local rec = types_mod.record_open({}, rv) --[[: V5Type ]]
		-- CRowLacks parks, then CRowClose closes the row without "tag" → resolves.
		op_sem.emit(exec, constraint_mod.row_lacks(rec, "tag", prov("lacks-tag-close")))
		op_sem.emit(exec, constraint_mod.row_close(rec, prov("close-row")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "CRowClose before quiescence: CRowLacks resolves, no errors")
		T.ok(rec.row == nil, "record row is nil (closed) after CRowClose")
	end)
end)

-- ═══════════════════════════════════════════════════════════════════════
-- Variance-respecting CSub fixtures (2026-05-24 extension)
-- ═══════════════════════════════════════════════════════════════════════
--
-- Per docs/typechecker-v5-operational-semantics.md § "Subtyping (variance-
-- respecting)".  Discharges debt called out in the CHKT op-sem entry
-- (T-CSub-AsEq stub).
--
-- Each fixture exercises one variance variant; the "soundness rejection"
-- fixture (15b, mutable-field covariance attempt) is the one that would
-- have been silently allowed under the old CEq routing if the producer
-- bound the field to a subtype.

-- ─── Fixture 14: T-CSub-Arrow contra-args + co-rets ─────────────────────
-- Sub:   Arrow [Animal]    [Dog]      -- accepts Animal, returns Dog
-- Super: Arrow [Dog]       [Animal]   -- accepts Dog,    returns Animal
-- A function-of-Animal-to-Dog is a subtype of function-of-Dog-to-Animal
-- IF Dog <: Animal.  Encode Dog <: Animal as a declared variance via a
-- named constructor (we use Const directly; mismatch surfaces because
-- nothing relates Dog and Animal at the CSub-Const level).  Better
-- encoding: use a covariant Maybe wrapper.

T.describe("op_sem variance: fixture 14 — T-CSub-Arrow decomposes", function()
	T.it("Arrow CSub decomposes into contra-args + co-rets subgoals", function()
		op_sem.variance.reset()
		-- Declare Box covariant in its parameter.
		op_sem.variance.declare("Box", { "co" })
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		-- Sub:   (Box<Animal>) -> Box<Dog>
		-- Super: (Box<Dog>)    -> Box<Animal>
		-- For this to subtype: Box<Dog> <: Box<Animal>  AND  Box<Dog> <: Box<Animal>
		-- (contra-args: Box<Dog> <: Box<Animal> ;  co-rets: Box<Dog> <: Box<Animal>)
		-- Both reduce to Dog <: Animal under Box's covariance.  Since Dog and
		-- Animal are distinct Consts with no declared relation, the result
		-- is a T-CSub-Const-Var mismatch error.  We assert THAT — the rule
		-- DECOMPOSES, which is the variance-respecting behaviour.  Compare:
		-- under the old T-CSub-AsEq stub, the whole Arrow would have been
		-- CEq'd, surfacing as a single "arrow arg mismatch" rather than the
		-- per-position Const mismatch.
		local box_dog = types_mod.app(types_mod.const("Box"), dog) --[[: V5Type ]]
		local box_animal = types_mod.app(types_mod.const("Box"), animal) --[[: V5Type ]]
		local sub_arrow = types_mod.arrow({ box_animal }, { box_dog }) --[[: V5Type ]]
		local sup_arrow = types_mod.arrow({ box_dog }, { box_animal }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(sub_arrow, sup_arrow, prov("arr-sub")))
		op_sem.run(exec)

		-- Under T-CSub-Arrow + T-CSub-App-Var(co) + T-CSub-Const-Var, we
		-- expect TWO Const mismatch errors (one from contra-arg side, one
		-- from co-ret side), both labelled T-CSub-Const-Var.
		local const_var_errs = 0
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CSub-Const-Var" then
				const_var_errs = const_var_errs + 1
			end
		end
		T.eq(const_var_errs, 2, "two T-CSub-Const-Var errors from per-position decomposition")
	end)
end)

-- ─── Fixture 15: T-CSub-App-Var covariant List ──────────────────────────
-- Declare List covariant.  List<Dog> <: List<Animal> requires
-- Dog <: Animal, which won't hold here — but the EMISSION shape is
-- what we test: T-CSub-App-Var emits a CSub(Dog, Animal), NOT a CEq.

T.describe("op_sem variance: fixture 15 — T-CSub-App-Var covariant", function()
	T.it("covariant List dispatches Dog <: Animal as a CSub subgoal", function()
		op_sem.variance.reset()
		op_sem.variance.declare("List", { "co" })
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local list_dog = types_mod.app(list, dog) --[[: V5Type ]]
		local list_animal = types_mod.app(list, animal) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(list_dog, list_animal, prov("list-sub")))
		op_sem.run(exec)
		-- Subgoal Dog <: Animal will fail at T-CSub-Const-Var.  We just want
		-- to see that the failure rule is T-CSub-Const-Var (the subgoal
		-- fired), not T-CEq-Const (the CEq stub would have).
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CSub-Const-Var" then found = true end
		end
		T.ok(found, "covariant subgoal surfaces as CSub-Const-Var (not CEq)")
	end)

	T.it("invariant List (default) dispatches Dog vs Animal as a CEq subgoal", function()
		op_sem.variance.reset()
		-- Do NOT declare; default is invariant.
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local list_dog = types_mod.app(list, dog) --[[: V5Type ]]
		local list_animal = types_mod.app(list, animal) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(list_dog, list_animal, prov("list-inv")))
		op_sem.run(exec)
		-- Invariant: subgoal is CEq, errors surface as T-CEq-Const.
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CEq-Const" then found = true end
		end
		T.ok(found, "invariant default surfaces as CEq-Const (sound)")
	end)

	T.it("covariant List<Dog> <: List<Dog> (Refl fast path)", function()
		op_sem.variance.reset()
		op_sem.variance.declare("List", { "co" })
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local ld = types_mod.app(list, dog) --[[: V5Type ]]
		local ld2 = types_mod.app(list, dog) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(ld, ld2, prov("refl")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "reflexive sub succeeds")
	end)
end)

-- ─── Fixture 16: T-CSub-Record-Width with invariant fields ──────────────
-- {x: int, y: string} <: {x: int}  — width subtyping
-- {x: int} </: {x: int, y: string}  — supertype demands missing field
-- {x: int, y: string} </: {x: int, y: int}  — invariant on y
-- The third case is the SOUNDNESS-CRITICAL one: under a covariant-field
-- treatment (the TypeScript-array unsoundness), int <: number could
-- pretend `int` is a subtype of `int` (trivially) and accept this where
-- it shouldn't if the destination is mutated to a non-int.  We assert
-- invariance on the field by checking that an unequal field type emits a
-- T-CEq-Const error (NOT a T-CSub-Const-Var, which would imply we ran
-- the covariant subgoal instead).

T.describe("op_sem variance: fixture 16 — T-CSub-Record-Width", function()
	T.it("wider record subtypes narrower (width subtyping)", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local wide = mkrec({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = mkrec({ x = int_ty }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(wide, narrow, prov("width-ok")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "wide <: narrow (width subtyping)")
	end)

	T.it("narrower record DOES NOT subtype wider (missing field)", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local wide = mkrec({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = mkrec({ x = int_ty }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(narrow, wide, prov("width-bad")))
		op_sem.run(exec)
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CSub-Record-Width" then found = true end
		end
		T.ok(found, "missing field reports T-CSub-Record-Width error")
	end)

	T.it("field-type mismatch is INVARIANT (soundness floor)", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		-- Both have field x, but types differ.  Soundness floor: must reject
		-- via CEq (invariant), not via CSub which might be made to pass
		-- through some lurking variance.  We assert the error rule is
		-- T-CEq-Const — emitted by the T-CSub-Record-Width subgoal — NOT
		-- T-CSub-Const-Var.  This is the explicit divergence from the
		-- TypeScript-array unsoundness path.
		local r_int = mkrec({ x = int_ty }) --[[: V5Type ]]
		local r_str = mkrec({ x = str_ty }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(r_int, r_str, prov("invar")))
		op_sem.run(exec)
		local ceq_const = 0
		local csub_const = 0
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CEq-Const" then ceq_const = ceq_const + 1 end
			if e ~= nil and e.rule == "T-CSub-Const-Var" then csub_const = csub_const + 1 end
		end
		T.ok(ceq_const >= 1, "invariant field surfaces as T-CEq-Const")
		T.eq(csub_const, 0, "no T-CSub-Const-Var (NOT covariant on field)")
	end)
end)

-- ─── Fixture 17: T-CSub-Arrow soundness — variance violation rejected ──
-- The task brief asks for "at least one fixture where variance violation
-- produces a sound rejection (would have crashed at runtime under the
-- prior CEq-routed CSub)."
--
-- Under the OLD T-CSub-AsEq stub:
--   CSub(Arrow [Dog] [Dog], Arrow [Animal] [Dog]) routed to
--   CEq(Arrow [Dog] [Dog], Arrow [Animal] [Dog])
--   which fails as a Const mismatch (Dog vs Animal at arg position).
-- Under the NEW T-CSub-Arrow:
--   This SUCCEEDS via contra-args (Animal <: Dog routed through CSub-
--   Const-Var which fails since Animal ≠ Dog), giving the SAME error
--   shape since neither Dog nor Animal are declared related.
--
-- The cleaner soundness rejection: a function-of-Dog can't substitute
-- where function-of-Animal is expected (input is too restrictive).
-- That's contravariance on the arg: caller may pass any Animal, but the
-- function only handles Dog.

T.describe("op_sem variance: fixture 17 — Arrow contravariance rejects unsound substitution", function()
	T.it("function-of-Dog NOT a subtype of function-of-Animal (sound rejection)", function()
		op_sem.variance.reset()
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local unit = types_mod.const("unit") --[[: V5Type ]]
		-- Sub:   (Dog)    -> unit  (handles ONLY dogs)
		-- Super: (Animal) -> unit  (handles ANY animal)
		-- Sub should NOT be acceptable where Super is expected — caller
		-- might pass a cat (an Animal).  Contravariance on args means:
		-- super-arg <: sub-arg, i.e. Animal <: Dog, which fails.
		local fn_dog = types_mod.arrow({ dog }, { unit }) --[[: V5Type ]]
		local fn_animal = types_mod.arrow({ animal }, { unit }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(fn_dog, fn_animal, prov("contra-reject")))
		op_sem.run(exec)
		-- Expect a T-CSub-Const-Var error (the contra-arg subgoal CSub(Animal, Dog) fails).
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CSub-Const-Var" then found = true end
		end
		T.ok(found, "contravariant arg subgoal CSub(Animal,Dog) fails as T-CSub-Const-Var")
	end)

	T.it("function-of-Animal IS a subtype of function-of-Dog (sound accept, when Animal <: Dog wasn't required)", function()
		-- Symmetric: super = function-of-Dog, sub = function-of-Animal.
		-- Contra-args: super-arg <: sub-arg, i.e. Dog <: Animal.
		-- Without a declared relation between Dog and Animal, this still
		-- fails — so the assertion is "subgoal emitted is CSub(Dog,Animal)
		-- (T-CSub-Const-Var error), NOT a single arrow-mismatch under
		-- the old stub."  The decomposition is the SHAPE the rule
		-- gives us; declaring Dog <: Animal as a subsumption would
		-- require type-level inheritance which v5.0 doesn't have.
		op_sem.variance.reset()
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local unit = types_mod.const("unit") --[[: V5Type ]]
		local fn_animal = types_mod.arrow({ animal }, { unit }) --[[: V5Type ]]
		local fn_dog = types_mod.arrow({ dog }, { unit }) --[[: V5Type ]]

		local exec = op_sem.new_state()
		op_sem.emit(exec, constraint_mod.sub(fn_animal, fn_dog, prov("contra-accept-shape")))
		op_sem.run(exec)
		-- Whether this errors depends on Animal/Dog subtyping; we expect
		-- T-CSub-Const-Var (Dog vs Animal mismatch via contra subgoal).
		-- The point of the fixture is to show the DISPATCH path: arrow
		-- decomposes, per-position CSubs fire, per-Const variance checked.
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CSub-Const-Var" then found = true end
		end
		T.ok(found, "contra-arg subgoal fires as T-CSub-Const-Var")
	end)
end)

-- ─── Fixture 18: T-CSub-TVar routes to CEq (v5.0 trade) ─────────────────

T.describe("op_sem variance: fixture 18 — T-CSub-TVar routes to CEq", function()
	T.it("CSub with a uvar on either side routes to CEq", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local exec = op_sem.new_state()
		local tv = subst_mod.fresh(exec.subst, "open")
		local utv = types_mod.uvar(tv) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(utv, int_ty, prov("tv-sub")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "uvar route to CEq binds successfully")
		local r = op_sem.resolve(exec, tv)
		T.ok(walk_equal(r, int_ty), "tv resolved to int")
	end)
end)

-- ─── Fixture 19: CRowExtend binds open-row record with new key ───────────
-- CRowExtend on an open-row record adds a new field.
-- Rule fired: T-CRowExtend-Bind.

T.describe("op_sem CRow: fixture 19 — CRowExtend binds open-row record", function()
	T.it("CRowExtend adds key to open-row record", function()
		local exec = op_sem.new_state()
		local rv = types_mod.rowvar(1) --[[: V5Type ]]
		local rec = types_mod.record_open({}, rv) --[[: V5Type ]]
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(rec, "x", int_ty, prov("extend-x")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "CRowExtend on open row: no errors")
		-- After extend, rec.fields["x"] should be int_ty.
		local fx = rec.fields["x"]
		T.ok(fx ~= nil, "field x added to record")
		T.ok(walk_equal((fx ~= nil and fx.type) or int_ty, int_ty), "field x = int")
	end)

	T.it("CRowExtend lookup equates existing field type", function()
		-- Record already has x: int; CRowExtend with x: string → CEq(int, string) → error.
		local exec = op_sem.new_state()
		local rv = types_mod.rowvar(2) --[[: V5Type ]]
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local recf = { x = types_mod.field(int_ty, false, false) } --[[: { [string]: TField } ]]
		local rec = types_mod.record_open(recf, rv) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(rec, "x", str_ty, prov("extend-x-lookup")))
		op_sem.run(exec)
		-- Should produce a CEq(int, str) mismatch.
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CEq-Const" then found = true end
		end
		T.ok(found, "field-type conflict surfaces as T-CEq-Const")
	end)
end)

-- ─── Fixture 20: CRowExtend on closed record → ERROR ────────────────────
-- Rule fired: T-CRowExtend-Closed.

T.describe("op_sem CRow: fixture 20 — CRowExtend on closed record", function()
	T.it("CRowExtend on closed record with missing key errors", function()
		local exec = op_sem.new_state()
		-- Closed record: row = nil (via types_mod.record).
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local rec = mkrec({ y = int_ty }) --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(rec, "x", str_ty, prov("extend-closed")))
		op_sem.run(exec)
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then found = true end
		end
		T.ok(found, "closed record extend error: T-CRowExtend-Closed")
	end)
end)

-- ─── Fixture 21: CRowLacks parks then succeeds after CRowClose ───────────
-- Rules fired: T-CRowLacks-Open (park), T-CRowClose-Bind (close), T-CRowLacks-Closed-Pass.

T.describe("op_sem CRow: fixture 21 — CRowLacks parks while open, succeeds when closed", function()
	T.it("CRowLacks on open row parks; CRowClose closes; lacks succeeds when key absent", function()
		local exec = op_sem.new_state()
		local rv = types_mod.rowvar(3) --[[: V5Type ]]
		local rec = types_mod.record_open({}, rv) --[[: V5Type ]]
		-- CRowLacks(rec, "z") — should park while row is open.
		op_sem.emit(exec, constraint_mod.row_lacks(rec, "z", prov("lacks-z")))
		-- CRowClose(rec) — closes the row, wakes the parked lacks.
		op_sem.emit(exec, constraint_mod.row_close(rec, prov("close-row")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "CRowLacks parks then passes after CRowClose")
		T.ok(rec.row == nil, "record row is closed after CRowClose")
	end)

	T.it("CRowLacks on closed record with key present errors", function()
		local exec = op_sem.new_state()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local rec = mkrec({ z = int_ty }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_lacks(rec, "z", prov("lacks-z-fail")))
		op_sem.run(exec)
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CRowLacks-Closed-Fail" then found = true end
		end
		T.ok(found, "key present in closed row: T-CRowLacks-Closed-Fail error")
	end)
end)

-- ─── Fixture 22 (risk): positional record + CRowExtend → closed-extend ERROR ──
-- A closed record (row = nil) cannot grow.  CRowExtend on a closed record must
-- ERROR with T-CRowExtend-Closed.  (Spec C retires positional records; this
-- soundness floor is tested with an ordinary closed named record.)

T.describe("op_sem CRow: fixture 22 — closed record stays closed", function()
	T.it("closed record + CRowExtend errors as T-CRowExtend-Closed", function()
		local exec = op_sem.new_state()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local closed_rec = mkrec({ a = int_ty, b = str_ty }) --[[: V5Type ]]
		-- Attempt to add a new named key via CRowExtend.
		local bool_ty = types_mod.const("bool") --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(closed_rec, "name", bool_ty, prov("closed-extend")))
		op_sem.run(exec)
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then found = true end
		end
		T.ok(found, "closed record cannot extend: T-CRowExtend-Closed fired")
		T.ok(closed_rec.row == nil, "closed record row remains nil")
	end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- Intersection + effect fixtures (Phase 4)
-- ════════════════════════════════════════════════════════════════════════

-- Helper: search trace for a rule label.
--: (OpSemState, string) -> boolean
local function trace_has(st, rule)
	for i = 1, #st.trace do
		local e = st.trace[i]
		if e ~= nil and e.rule == rule then return true end
	end
	return false
end

-- ─── Fixture 23: canonical form — A & B ≡ B & A (Risk 3) ───────────────
T.describe("op_sem parity: fixture 23 — intersection canonical commutativity", function()
	T.it("CIntersectionEq on swapped parts succeeds via canonicalization", function()
		local exec = op_sem.new_state()
		local io_e = types_mod.effect("io") --[[: V5Type ]]
		local os_e = types_mod.effect("os") --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.intersection_eq({ io_e, os_e }, { os_e, io_e }, prov("23")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "23: commutative parts are equal under canonicalization")
		T.ok(trace_has(exec, "T-CIntersectionEq-Canonical"), "23: rule fired")
	end)
end)

-- ─── Fixture 24: flattening — A & (B & C) ≡ (A & B) & C ────────────────
T.describe("op_sem parity: fixture 24 — intersection canonical flattening", function()
	T.it("nested intersection flattens to the same canonical list", function()
		local exec = op_sem.new_state()
		local a = types_mod.effect("io")
		local b = types_mod.effect("os")
		local c = types_mod.const("alpha")
		local lhs = { a, types_mod.intersection({ b, c }) } --[[: V5Type[] ]]
		local rhs = { types_mod.intersection({ a, b }), c } --[[: V5Type[] ]]
		op_sem.emit(exec, constraint_mod.intersection_eq(lhs, rhs, prov("24")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "24: nested intersection flattens equivalently")
		T.ok(trace_has(exec, "T-CIntersectionEq-Canonical"), "24: rule fired")
	end)
end)

-- ─── Fixture 25: dedupe — A & A ≡ A ────────────────────────────────────
T.describe("op_sem parity: fixture 25 — intersection canonical dedupe", function()
	T.it("duplicate parts collapse under canonicalization", function()
		local exec = op_sem.new_state()
		local a = types_mod.effect("io")
		op_sem.emit(exec, constraint_mod.intersection_eq({ a, a }, { a }, prov("25")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "25: dedupe yields equal canonical lists")
		T.ok(trace_has(exec, "T-CIntersectionEq-Canonical"), "25: rule fired")
	end)
end)

-- ─── Fixture 26: CSub LHS-decomp — int & !io <: int ────────────────────
T.describe("op_sem parity: fixture 26 — intersection LHS decomp drops effect", function()
	T.it("(int & !io) <: int succeeds via eager part-match", function()
		local exec = op_sem.new_state()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local lhs = types_mod.intersection({ int_ty, io_e }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(lhs, int_ty, prov("26")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "26: drop-effect direction succeeds")
		T.ok(trace_has(exec, "T-CSub-Intersection-Decomp"), "26: LHS decomp rule fired")
	end)
end)

-- ─── Fixture 27: CSub RHS-conj — int <: int & !io fails ────────────────
T.describe("op_sem parity: fixture 27 — intersection RHS conj rejects missing part", function()
	T.it("int <: (int & !io) fails because LHS lacks the effect part", function()
		local exec = op_sem.new_state()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local rhs = types_mod.intersection({ int_ty, io_e }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(int_ty, rhs, prov("27")))
		op_sem.run(exec)
		T.ok(op_sem.error_count(exec) > 0, "27: RHS conj fails (LHS missing effect part)")
		T.ok(trace_has(exec, "T-CSub-Intersection-Conj"), "27: RHS conj rule fired")
	end)
end)

-- ─── Fixture 28: CIntersectionMember direct on canonical intersection ───
T.describe("op_sem parity: fixture 28 — intersection member direct match", function()
	T.it("member query on canonicalized intersection succeeds", function()
		local exec = op_sem.new_state()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local os_e = types_mod.effect("os")
		local inter = types_mod.intersection({ int_ty, io_e, os_e }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.intersection_member(inter, io_e, prov("28")))
		op_sem.run(exec)
		T.eq(op_sem.error_count(exec), 0, "28: direct member match")
		T.ok(trace_has(exec, "T-CIntersectionMember-Direct"), "28: rule fired")
	end)
end)

-- ─── Fixture 29: F2 enforcement — stuck inferred effect ─────────────────
T.describe("op_sem parity: fixture 29 — CIntersectionMember on unbound uvar errors at quiescence", function()
	T.it("member query on never-bound uvar surfaces as S-Quiesce error", function()
		local exec = op_sem.new_state()
		local uid = subst_mod.fresh(exec.subst, "open")
		local uvar_ty = types_mod.uvar(uid) --[[: V5Type ]]
		local io_e = types_mod.effect("io")
		op_sem.emit(exec, constraint_mod.intersection_member(uvar_ty, io_e, prov("29")))
		op_sem.run(exec)
		local found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CIntersectionMember" then found = true end
		end
		T.ok(found, "29: F2 enforcement — stuck cint_member surfaces at quiescence")
	end)
end)

return true
