-- lib/type/static-v5/op_sem_independent_parity_test.lua
-- Cross-interpreter parity tests: op_sem (existing) vs op_sem_alt
-- (independently transcribed from the spec doc).
--
-- For each fixture, build IDENTICAL initial constraint sets against
-- fresh op_sem states (one per interpreter), run both interpreters to
-- quiescence, and assert that:
--   (a) every tracked tvar resolves to types.equal types in both
--   (b) error counts match
--   (c) error rule labels (multiset) match
--   (d) inert-set sizes match
--
-- Divergences must be specific: "fixture N diverges at assertion M;
-- op_sem says X, op_sem_alt says Y" — so when the suite fails, the
-- orchestrator can read which rule disagreed without re-running.
--
-- See docs/typechecker-v5-operational-semantics.md for the rules; see
-- lib/type/static-v5/op_sem.lua and op_sem_alt.lua for the two
-- interpreters.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T              = require("lib.test.assert")
local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local op_sem         = require("lib.type.static-v5.op_sem")
local op_sem_alt     = require("lib.type.static-v5.op_sem_alt")

--: (string) -> Provenance
local function prov(name) return op_sem.prov("fixture", 1, name) end

-- Sort a list of error rule labels (so multiset compare is order-stable).
--: (OpSemError[]) -> string[]
local function error_rules(errs)
	local out = {} --[[: string[] ]]
	for i = 1, #errs do
		local e = errs[i]
		if e ~= nil then out[#out + 1] = e.rule end
	end
	-- Simple insertion sort to avoid table.sort signature mismatches.
	for i = 2, #out do
		local key = out[i]
		local j = i - 1
		while j >= 1 and key ~= nil and out[j] ~= nil and out[j] > key do
			out[j + 1] = out[j]
			j = j - 1
		end
		if key ~= nil then out[j + 1] = key end
	end
	return out
end

-- Count inert constraints in a state.
--: ({ [integer]: OpSemConstraint }) -> integer
local function inert_count(inert)
	local n = 0
	for _k, _v in pairs(inert) do n = n + 1 end
	return n
end

-- Assert two resolve-results are equal at a given tvar, with a label
-- identifying the divergence.
--: (string, V5Type, V5Type) -> nil
local function assert_resolve_eq(label, a, b)
	T.ok(types_mod.equal(a, b),
		"divergence at " .. label ..
		"; op_sem: " .. tostring(a.tag) ..
		"; op_sem_alt: " .. tostring(b.tag))
end

--: (string, AltState, AltState) -> nil
local function assert_state_parity(label, exec, alt)
	-- Error count parity.
	T.eq(#exec.errors, #alt.errors,
		label .. ": error count diverges; op_sem=" .. #exec.errors ..
		" vs op_sem_alt=" .. #alt.errors)
	-- Error rule labels (multiset) parity.
	local er = error_rules(exec.errors)
	local ar = error_rules(alt.errors)
	T.eq(#er, #ar, label .. ": error-rule list length diverges")
	for i = 1, #er do
		T.eq(er[i], ar[i],
			label .. ": error rule " .. i .. " diverges: op_sem=" ..
			(er[i] or "nil") .. " vs op_sem_alt=" .. (ar[i] or "nil"))
	end
	-- Inert count parity (after S-Quiesce both should have emptied
	-- HOUnify into errors; non-HOUnify inert may remain).
	T.eq(inert_count(exec.inert), inert_count(alt.inert),
		label .. ": inert count diverges; op_sem=" ..
		inert_count(exec.inert) .. " vs op_sem_alt=" .. inert_count(alt.inert))
end

-- Build a fresh state and seed via op_sem.emit (which is just `n+=1,
-- worklist[n]=c` — works for both interpreters because the state
-- shape is shared).
--: () -> AltState
local function fresh_state() return op_sem.new_state() end

-- ════════════════════════════════════════════════════════════════════
-- Fixture 1: CEq basic — local x:?x = 1; local y:?y = x
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 1 — CEq basic", function()
	T.it("op_sem and op_sem_alt agree", function()
		local number = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local x = subst_mod.fresh(exec.subst, "open")
		local y = subst_mod.fresh(exec.subst, "open")
		local ux = types_mod.uvar(x) --[[: V5Type ]]
		local uy = types_mod.uvar(y) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.eq(ux, number, prov("x=1")))
		op_sem.emit(exec, constraint_mod.eq(uy, ux, prov("y=x")))
		op_sem.run(exec)

		local alt = fresh_state()
		local x2 = subst_mod.fresh(alt.subst, "open")
		local y2 = subst_mod.fresh(alt.subst, "open")
		local ux2 = types_mod.uvar(x2) --[[: V5Type ]]
		local uy2 = types_mod.uvar(y2) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.eq(ux2, number, prov("x=1")))
		op_sem.emit(alt, constraint_mod.eq(uy2, ux2, prov("y=x")))
		op_sem_alt.run(alt)

		local rex_fixture1_x = op_sem.resolve(exec, x) --[[: V5Type ]]
		local ralt_fixture1_x = op_sem_alt.resolve(alt, x2) --[[: V5Type ]]
		assert_resolve_eq("fixture1.x", rex_fixture1_x, ralt_fixture1_x)
		local rex_fixture1_y = op_sem.resolve(exec, y) --[[: V5Type ]]
		local ralt_fixture1_y = op_sem_alt.resolve(alt, y2) --[[: V5Type ]]
		assert_resolve_eq("fixture1.y", rex_fixture1_y, ralt_fixture1_y)
		assert_state_parity("fixture1", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 2: Construction phase end-to-end
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 2 — construction phase", function()
	T.it("CTOpen + 2x CTSet + CTSeal agree", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local strty  = types_mod.const("string") --[[: V5Type ]]

		local exec = fresh_state()
		local t = subst_mod.fresh(exec.subst, "open")
		local mu = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.table_open(t, prov("t={}")))
		op_sem.emit(exec, constraint_mod.table_set(t, "x", number, prov("t.x=1")))
		op_sem.emit(exec, constraint_mod.table_set(t, "y", strty, prov("t.y=hi")))
		op_sem.emit(exec, constraint_mod.table_seal(t, mu, prov("setmt")))
		op_sem.run(exec)

		local alt = fresh_state()
		local t2 = subst_mod.fresh(alt.subst, "open")
		local mu2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.table_open(t2, prov("t={}")))
		op_sem.emit(alt, constraint_mod.table_set(t2, "x", number, prov("t.x=1")))
		op_sem.emit(alt, constraint_mod.table_set(t2, "y", strty, prov("t.y=hi")))
		op_sem.emit(alt, constraint_mod.table_seal(t2, mu2, prov("setmt")))
		op_sem_alt.run(alt)

		local rex_fixture2_t = op_sem.resolve(exec, t) --[[: V5Type ]]
		local ralt_fixture2_t = op_sem_alt.resolve(alt, t2) --[[: V5Type ]]
		assert_resolve_eq("fixture2.t", rex_fixture2_t, ralt_fixture2_t)
		T.eq(subst_mod.phase(exec.subst, t), subst_mod.phase(alt.subst, t2),
			"fixture2: phase diverges")
		assert_state_parity("fixture2", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 3: CMethodCall — emit before seal, exercises stuck/wake
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 3 — CMethodCall after seal", function()
	T.it("park-then-wake produces identical resolution", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local self_ty = types_mod.const("any-table") --[[: V5Type ]]
		local foo_arrow = types_mod.arrow({ self_ty }, { number }) --[[: V5Type ]]

		local exec = fresh_state()
		local t = subst_mod.fresh(exec.subst, "open")
		local mu = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.table_open(t, prov("t={}")))
		op_sem.emit(exec, constraint_mod.table_set(t, "foo", foo_arrow, prov("t.foo=fn")))
		op_sem.emit(exec, constraint_mod.method_call(t, "foo", r, prov("t:foo()")))
		op_sem.emit(exec, constraint_mod.table_seal(t, mu, prov("setmt")))
		op_sem.run(exec)

		local alt = fresh_state()
		local t2 = subst_mod.fresh(alt.subst, "open")
		local mu2 = subst_mod.fresh(alt.subst, "open")
		local r2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.table_open(t2, prov("t={}")))
		op_sem.emit(alt, constraint_mod.table_set(t2, "foo", foo_arrow, prov("t.foo=fn")))
		op_sem.emit(alt, constraint_mod.method_call(t2, "foo", r2, prov("t:foo()")))
		op_sem.emit(alt, constraint_mod.table_seal(t2, mu2, prov("setmt")))
		op_sem_alt.run(alt)

		local rex_fixture3_r = op_sem.resolve(exec, r) --[[: V5Type ]]
		local ralt_fixture3_r = op_sem_alt.resolve(alt, r2) --[[: V5Type ]]
		assert_resolve_eq("fixture3.r", rex_fixture3_r, ralt_fixture3_r)
		assert_state_parity("fixture3", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 4: setmetatable(t, nil) — CEq mismatch
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 4 — setmetatable(t, nil) reject", function()
	T.it("both report one T-CEq-Const error", function()
		local nil_ty = types_mod.const("nil") --[[: V5Type ]]
		local tbl_ty = types_mod.const("table") --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.eq(nil_ty, tbl_ty, prov("setmt-nil")))
		op_sem.run(exec)

		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.eq(nil_ty, tbl_ty, prov("setmt-nil")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture4", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 5: let-poly via CInst (identity scheme, two instantiations)
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 5 — let-poly CInst", function()
	T.it("both instantiations agree", function()
		local body = types_mod.arrow({ types_mod.var(0) }, { types_mod.var(0) }) --[[: V5Type ]]
		local sch = op_sem.scheme(1, body)
		local number = types_mod.const("number") --[[: V5Type ]]
		local strty  = types_mod.const("string") --[[: V5Type ]]

		local exec = fresh_state()
		local r1 = subst_mod.fresh(exec.subst, "open")
		local r2 = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, op_sem.inst(sch,
			types_mod.arrow({ number }, { types_mod.uvar(r1) }), prov("id(1)")))
		op_sem.emit(exec, op_sem.inst(sch,
			types_mod.arrow({ strty }, { types_mod.uvar(r2) }), prov("id(hi)")))
		op_sem.run(exec)

		local alt = fresh_state()
		local r1a = subst_mod.fresh(alt.subst, "open")
		local r2a = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, op_sem.inst(sch,
			types_mod.arrow({ number }, { types_mod.uvar(r1a) }), prov("id(1)")))
		op_sem.emit(alt, op_sem.inst(sch,
			types_mod.arrow({ strty }, { types_mod.uvar(r2a) }), prov("id(hi)")))
		op_sem_alt.run(alt)

		local rex_fixture5_r1 = op_sem.resolve(exec, r1) --[[: V5Type ]]
		local ralt_fixture5_r1 = op_sem_alt.resolve(alt, r1a) --[[: V5Type ]]
		assert_resolve_eq("fixture5.r1", rex_fixture5_r1, ralt_fixture5_r1)
		local rex_fixture5_r2 = op_sem.resolve(exec, r2) --[[: V5Type ]]
		local ralt_fixture5_r2 = op_sem_alt.resolve(alt, r2a) --[[: V5Type ]]
		assert_resolve_eq("fixture5.r2", rex_fixture5_r2, ralt_fixture5_r2)
		assert_state_parity("fixture5", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 6: multi-return positional Record CSub
-- ════════════════════════════════════════════════════════════════════
-- `local a, b = f()` where f : () -> (number, number).
-- CSub(Record{1=number,2=number}, Record{1=?a,2=?b}) unifies a,b=number.
-- (Spec gap closed: positional Record dispatch from Phase 3 handles this.)
T.describe("indep parity: fixture 6 — multi-return positional Record CSub", function()
	T.it("CSub(Record{1=number,2=number}, Record{1=?a,2=?b}) — both agree", function()
		local number = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		local prod = types_mod.record({ ["1"] = number, ["2"] = number }) --[[: V5Type ]]
		local dest = types_mod.record({ ["1"] = types_mod.uvar(a), ["2"] = types_mod.uvar(b) }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(prod, dest, prov("6-call")))
		op_sem.run(exec)

		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		local prod2 = types_mod.record({ ["1"] = number, ["2"] = number }) --[[: V5Type ]]
		local dest2 = types_mod.record({ ["1"] = types_mod.uvar(a2), ["2"] = types_mod.uvar(b2) }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.sub(prod2, dest2, prov("6-call")))
		op_sem_alt.run(alt)

		local rex_fixture6_a = op_sem.resolve(exec, a) --[[: V5Type ]]
		local ralt_fixture6_a = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture6.a", rex_fixture6_a, ralt_fixture6_a)
		local rex_fixture6_b = op_sem.resolve(exec, b) --[[: V5Type ]]
		local ralt_fixture6_b = op_sem_alt.resolve(alt, b2) --[[: V5Type ]]
		assert_resolve_eq("fixture6.b", rex_fixture6_b, ralt_fixture6_b)
		assert_state_parity("fixture6", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 6a: nil-pad under-arity
-- ════════════════════════════════════════════════════════════════════
-- `local a, b, c = f()` where f returns 2 values.
-- CSub(Record{1=number,2=number}, Record{1=?a,2=?b,3=?c})
-- Position 3 on producer is absent → padded with Const("nil").
-- Expect: a=number, b=number, c=nil; no errors.
T.describe("indep parity: fixture 6a — nil-pad under-arity", function()
	T.it("CSub(2-ret, 3-dest) nil-pads position 3 — both agree", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local nilty  = types_mod.const("nil") --[[: V5Type ]]

		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		local c = subst_mod.fresh(exec.subst, "open")
		local prod2 = types_mod.record({ ["1"] = number, ["2"] = number }) --[[: V5Type ]]
		local dest3 = types_mod.record({ ["1"] = types_mod.uvar(a), ["2"] = types_mod.uvar(b), ["3"] = types_mod.uvar(c) }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(prod2, dest3, prov("6a-call")))
		op_sem.run(exec)

		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		local c2 = subst_mod.fresh(alt.subst, "open")
		local prod2a = types_mod.record({ ["1"] = number, ["2"] = number }) --[[: V5Type ]]
		local dest3a = types_mod.record({ ["1"] = types_mod.uvar(a2), ["2"] = types_mod.uvar(b2), ["3"] = types_mod.uvar(c2) }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.sub(prod2a, dest3a, prov("6a-call")))
		op_sem_alt.run(alt)

		local rex_6a_a = op_sem.resolve(exec, a) --[[: V5Type ]]
		local ralt_6a_a = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture6a.a", rex_6a_a, ralt_6a_a)
		local rex_6a_b = op_sem.resolve(exec, b) --[[: V5Type ]]
		local ralt_6a_b = op_sem_alt.resolve(alt, b2) --[[: V5Type ]]
		assert_resolve_eq("fixture6a.b", rex_6a_b, ralt_6a_b)
		local rex_6a_c = op_sem.resolve(exec, c) --[[: V5Type ]]
		local ralt_6a_c = op_sem_alt.resolve(alt, c2) --[[: V5Type ]]
		assert_resolve_eq("fixture6a.c", rex_6a_c, ralt_6a_c)
		T.ok(types_mod.equal(rex_6a_c, nilty), "exec c resolves to nil")
		T.ok(types_mod.equal(ralt_6a_c, nilty), "alt c resolves to nil")
		assert_state_parity("fixture6a", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 6b: over-arity (gen-truncated)
-- ════════════════════════════════════════════════════════════════════
-- `local a = f()` where f returns 2 values. Gen truncates ret to 1
-- before emitting CSub, so op_sem sees CSub(Record{1=number}, Record{1=?a}).
-- Expect: a=number; no errors.
T.describe("indep parity: fixture 6b — over-arity gen-truncated", function()
	T.it("CSub(1-ret, 1-dest) — both agree, no error", function()
		local number = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local prod1 = types_mod.record({ ["1"] = number }) --[[: V5Type ]]
		local dest1 = types_mod.record({ ["1"] = types_mod.uvar(a) }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(prod1, dest1, prov("6b-call")))
		op_sem.run(exec)

		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local prod1a = types_mod.record({ ["1"] = number }) --[[: V5Type ]]
		local dest1a = types_mod.record({ ["1"] = types_mod.uvar(a2) }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.sub(prod1a, dest1a, prov("6b-call")))
		op_sem_alt.run(alt)

		local rex_6b_a = op_sem.resolve(exec, a) --[[: V5Type ]]
		local ralt_6b_a = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture6b.a", rex_6b_a, ralt_6b_a)
		assert_state_parity("fixture6b", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 6c: empty record vacuous
-- ════════════════════════════════════════════════════════════════════
-- f : () -> () — both sides are Record{}.
-- CSub(Record{}, Record{}) must succeed with 0 sub constraints emitted.
T.describe("indep parity: fixture 6c — empty positional record", function()
	T.it("CSub(Record{}, Record{}) — vacuous, both agree", function()
		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(types_mod.record({}), types_mod.record({}), prov("6c")))
		op_sem.run(exec)

		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(types_mod.record({}), types_mod.record({}), prov("6c")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture6c", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 6d: single-return Record CSub
-- ════════════════════════════════════════════════════════════════════
-- `local a = f()` where f : () -> int (one return).
-- CSub(Record{1=number}, Record{1=?a}) → ?a = number.
T.describe("indep parity: fixture 6d — single-return Record CSub", function()
	T.it("CSub(Record{1=number}, Record{1=?a}) — both agree", function()
		local number = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local prod = types_mod.record({ ["1"] = number }) --[[: V5Type ]]
		local dest = types_mod.record({ ["1"] = types_mod.uvar(a) }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(prod, dest, prov("6d-call")))
		op_sem.run(exec)

		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local proda = types_mod.record({ ["1"] = number }) --[[: V5Type ]]
		local desta = types_mod.record({ ["1"] = types_mod.uvar(a2) }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.sub(proda, desta, prov("6d-call")))
		op_sem_alt.run(alt)

		local rex_6d_a = op_sem.resolve(exec, a) --[[: V5Type ]]
		local ralt_6d_a = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture6d.a", rex_6d_a, ralt_6d_a)
		assert_state_parity("fixture6d", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 7: empty constraint set
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 7 — empty constraint set", function()
	T.it("no constraints — both quiesce cleanly", function()
		local exec = fresh_state(); op_sem.run(exec)
		local alt = fresh_state(); op_sem_alt.run(alt)
		assert_state_parity("fixture7", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 9: CHKT Reduce for Functor<Maybe>
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 9 — CHKT Reduce", function()
	T.it("Maybe lambda + CHKT(?F, [int], ?r) reduces identically", function()
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		local maybe_body = types_mod.record({ tag = string_ty, val = var0 }) --[[: V5Type ]]
		local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.eq(types_mod.uvar(f), maybe_lambda, prov("F=Maybe")))
		op_sem.emit(exec, op_sem.chkt(types_mod.uvar(f), { int_ty }, types_mod.uvar(r),
			prov("fmap-apply")))
		op_sem.run(exec)

		local alt = fresh_state()
		local f2 = subst_mod.fresh(alt.subst, "open")
		local r2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.eq(types_mod.uvar(f2), maybe_lambda, prov("F=Maybe")))
		op_sem.emit(alt, op_sem.chkt(types_mod.uvar(f2), { int_ty }, types_mod.uvar(r2),
			prov("fmap-apply")))
		op_sem_alt.run(alt)

		local rex_fixture9_r = op_sem.resolve(exec, r) --[[: V5Type ]]
		local ralt_fixture9_r = op_sem_alt.resolve(alt, r2) --[[: V5Type ]]
		assert_resolve_eq("fixture9.r", rex_fixture9_r, ralt_fixture9_r)
		assert_state_parity("fixture9", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 10: CHKT Miller pattern (identity constructor)
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 10 — CHKT Miller", function()
	T.it("?F<?a> = ?a binds ?F to lambda x. x", function()
		local exec = fresh_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local a = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, op_sem.chkt(types_mod.uvar(f), { types_mod.uvar(a) },
			types_mod.uvar(a), prov("F-of-a=a")))
		op_sem.run(exec)

		local alt = fresh_state()
		local f2 = subst_mod.fresh(alt.subst, "open")
		local a2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, op_sem.chkt(types_mod.uvar(f2), { types_mod.uvar(a2) },
			types_mod.uvar(a2), prov("F-of-a=a")))
		op_sem_alt.run(alt)

		local rex_fixture10_F = op_sem.resolve(exec, f) --[[: V5Type ]]
		local ralt_fixture10_F = op_sem_alt.resolve(alt, f2) --[[: V5Type ]]
		assert_resolve_eq("fixture10.F", rex_fixture10_F, ralt_fixture10_F)
		assert_state_parity("fixture10", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 11: HOUnify ambiguity (compose F G outside Miller)
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 11 — HOUnify ambiguity", function()
	T.it("CHKT outside Miller parks then errors at quiescence", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, op_sem.chkt(types_mod.uvar(f),
			{ types_mod.app(types_mod.uvar(g), int_ty) }, types_mod.uvar(r), prov("compose")))
		op_sem.run(exec)

		local alt = fresh_state()
		local f2 = subst_mod.fresh(alt.subst, "open")
		local g2 = subst_mod.fresh(alt.subst, "open")
		local r2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, op_sem.chkt(types_mod.uvar(f2),
			{ types_mod.app(types_mod.uvar(g2), int_ty) }, types_mod.uvar(r2), prov("compose")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture11", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 12: HOUnify wakes on head rigidification
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 12 — HOUnify wakes on rigid head", function()
	T.it("CHKT then CEq rigidifies; both wake + reduce identically", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		local maybe_body = types_mod.record({ tag = string_ty, val = var0 }) --[[: V5Type ]]
		local maybe_lambda = types_mod.lambda("*", maybe_body) --[[: V5Type ]]

		local exec = fresh_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		local uf = types_mod.uvar(f) --[[: V5Type ]]
		local ug = types_mod.uvar(g) --[[: V5Type ]]
		local ur = types_mod.uvar(r) --[[: V5Type ]]
		op_sem.emit(exec, op_sem.chkt(uf,
			{ types_mod.app(ug, int_ty) }, ur, prov("chkt-first")))
		op_sem.emit(exec, constraint_mod.eq(uf, maybe_lambda, prov("F=Maybe-later")))
		op_sem.run(exec)

		local alt = fresh_state()
		local f2 = subst_mod.fresh(alt.subst, "open")
		local g2 = subst_mod.fresh(alt.subst, "open")
		local r2 = subst_mod.fresh(alt.subst, "open")
		local uf2 = types_mod.uvar(f2) --[[: V5Type ]]
		local ug2 = types_mod.uvar(g2) --[[: V5Type ]]
		local ur2 = types_mod.uvar(r2) --[[: V5Type ]]
		op_sem.emit(alt, op_sem.chkt(uf2,
			{ types_mod.app(ug2, int_ty) }, ur2, prov("chkt-first")))
		op_sem.emit(alt, constraint_mod.eq(uf2, maybe_lambda, prov("F=Maybe-later")))
		op_sem_alt.run(alt)

		local rex_fixture12_r = op_sem.resolve(exec, r) --[[: V5Type ]]
		local ralt_fixture12_r = op_sem_alt.resolve(alt, r2) --[[: V5Type ]]
		assert_resolve_eq("fixture12.r", rex_fixture12_r, ralt_fixture12_r)
		assert_state_parity("fixture12", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 13: HOUnify never resolves
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 13 — HOUnify never resolves", function()
	T.it("orphan CHKT outside Miller — both report T-HOUnify-Stuck", function()
		local int_ty = types_mod.const("number") --[[: V5Type ]]

		local exec = fresh_state()
		local f = subst_mod.fresh(exec.subst, "open")
		local g = subst_mod.fresh(exec.subst, "open")
		local r = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, op_sem.chkt(types_mod.uvar(f),
			{ types_mod.app(types_mod.uvar(g), int_ty) }, types_mod.uvar(r), prov("orphan")))
		op_sem.run(exec)

		local alt = fresh_state()
		local f2 = subst_mod.fresh(alt.subst, "open")
		local g2 = subst_mod.fresh(alt.subst, "open")
		local r2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, op_sem.chkt(types_mod.uvar(f2),
			{ types_mod.app(types_mod.uvar(g2), int_ty) }, types_mod.uvar(r2), prov("orphan")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture13", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 14: T-CSub-Arrow decomposes into contra-args + co-rets
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 14 — CSub-Arrow decomposition", function()
	T.it("Box-covariant arrow subtyping decomposes identically", function()
		op_sem.variance.reset(); op_sem.variance.declare("Box", { "co" })
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local box_dog = types_mod.app(types_mod.const("Box"), dog) --[[: V5Type ]]
		local box_animal = types_mod.app(types_mod.const("Box"), animal) --[[: V5Type ]]
		local sub_arr = types_mod.arrow({ box_animal }, { box_dog }) --[[: V5Type ]]
		local sup_arr = types_mod.arrow({ box_dog }, { box_animal }) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(sub_arr, sup_arr, prov("arr-sub")))
		op_sem.run(exec)

		op_sem.variance.reset(); op_sem.variance.declare("Box", { "co" })
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(sub_arr, sup_arr, prov("arr-sub")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture14", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 15: T-CSub-App-Var variance dispatch (co / inv / refl)
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 15a — covariant List dispatch", function()
	T.it("List<Dog> <: List<Animal> (co) — both emit CSub subgoal", function()
		op_sem.variance.reset(); op_sem.variance.declare("List", { "co" })
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local ld = types_mod.app(list, dog) --[[: V5Type ]]
		local la = types_mod.app(list, animal) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(ld, la, prov("list-sub"))); op_sem.run(exec)

		op_sem.variance.reset(); op_sem.variance.declare("List", { "co" })
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(ld, la, prov("list-sub"))); op_sem_alt.run(alt)

		assert_state_parity("fixture15a", exec, alt)
	end)
end)

T.describe("indep parity: fixture 15b — invariant default", function()
	T.it("List<Dog> <: List<Animal> (inv default) — both emit CEq subgoal", function()
		op_sem.variance.reset()
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local ld = types_mod.app(list, dog) --[[: V5Type ]]
		local la = types_mod.app(list, animal) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(ld, la, prov("list-inv"))); op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(ld, la, prov("list-inv"))); op_sem_alt.run(alt)

		assert_state_parity("fixture15b", exec, alt)
	end)
end)

T.describe("indep parity: fixture 15c — reflexive sub", function()
	T.it("List<Dog> <: List<Dog> — both refl, no errors", function()
		op_sem.variance.reset(); op_sem.variance.declare("List", { "co" })
		local list = types_mod.const("List") --[[: V5Type ]]
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local ld = types_mod.app(list, dog) --[[: V5Type ]]
		local ld2 = types_mod.app(list, dog) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(ld, ld2, prov("refl"))); op_sem.run(exec)

		op_sem.variance.reset(); op_sem.variance.declare("List", { "co" })
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(ld, ld2, prov("refl"))); op_sem_alt.run(alt)

		assert_state_parity("fixture15c", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 16: T-CSub-Record-Width width + missing + invariant field
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 16a — width subtyping ok", function()
	T.it("wide <: narrow — both clean", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local wide = types_mod.record({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = types_mod.record({ x = int_ty }) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(wide, narrow, prov("width-ok"))); op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(wide, narrow, prov("width-ok"))); op_sem_alt.run(alt)

		assert_state_parity("fixture16a", exec, alt)
	end)
end)

T.describe("indep parity: fixture 16b — narrow </: wide", function()
	T.it("narrow </: wide — both report missing field", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local wide = types_mod.record({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = types_mod.record({ x = int_ty }) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(narrow, wide, prov("width-bad"))); op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(narrow, wide, prov("width-bad"))); op_sem_alt.run(alt)

		assert_state_parity("fixture16b", exec, alt)
	end)
end)

T.describe("indep parity: fixture 16c — invariant field types", function()
	T.it("{x:int} <: {x:str} — both surface as CEq const mismatch", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local r_int = types_mod.record({ x = int_ty }) --[[: V5Type ]]
		local r_str = types_mod.record({ x = str_ty }) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(r_int, r_str, prov("invar"))); op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(r_int, r_str, prov("invar"))); op_sem_alt.run(alt)

		assert_state_parity("fixture16c", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 17: Arrow contravariance rejects unsound substitution
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 17 — Arrow contravariance reject", function()
	T.it("fn(Dog) </: fn(Animal) — both report CSub-Const-Var", function()
		op_sem.variance.reset()
		local dog = types_mod.const("Dog") --[[: V5Type ]]
		local animal = types_mod.const("Animal") --[[: V5Type ]]
		local unit = types_mod.const("unit") --[[: V5Type ]]
		local fn_dog = types_mod.arrow({ dog }, { unit }) --[[: V5Type ]]
		local fn_animal = types_mod.arrow({ animal }, { unit }) --[[: V5Type ]]

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(fn_dog, fn_animal, prov("contra-reject")))
		op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(fn_dog, fn_animal, prov("contra-reject")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture17", exec, alt)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 18: T-CSub-TVar routes to CEq
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 18 — CSub-TVar routes to CEq", function()
	T.it("CSub with uvar binds via CEq route", function()
		op_sem.variance.reset()
		local int_ty = types_mod.const("int") --[[: V5Type ]]

		local exec = fresh_state()
		local tv = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(tv), int_ty, prov("tv-sub")))
		op_sem.run(exec)

		op_sem.variance.reset()
		local alt = fresh_state()
		local tv2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(tv2), int_ty, prov("tv-sub")))
		op_sem_alt.run(alt)

		local rex_fixture18_tv = op_sem.resolve(exec, tv) --[[: V5Type ]]
		local ralt_fixture18_tv = op_sem_alt.resolve(alt, tv2) --[[: V5Type ]]
		assert_resolve_eq("fixture18.tv", rex_fixture18_tv, ralt_fixture18_tv)
		assert_state_parity("fixture18", exec, alt)
	end)
end)

return true
