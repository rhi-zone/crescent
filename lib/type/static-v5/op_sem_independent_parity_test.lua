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

-- mkrec(bare): build a closed three-region TRecord (Spec C) from a bare
-- { [name]: V5Type } map (each value wrapped as a non-optional, non-readonly
-- TField).  ro(bare): same but every field readonly.  idxrec(key, value, ro):
-- a record carrying a single index signature.
--: ({ [string]: V5Type }) -> V5Type
local function mkrec(bare)
	local fields = {} --[[: { [string]: TField } ]]
	for k, v in pairs(bare) do
		if v ~= nil then fields[k] = types_mod.field(v, false, false) end
	end
	return types_mod.record(fields)
end
--: ({ [string]: V5Type }) -> V5Type
local function ro(bare)
	local fields = {} --[[: { [string]: TField } ]]
	for k, v in pairs(bare) do
		if v ~= nil then fields[k] = types_mod.field(v, false, true) end
	end
	return types_mod.record(fields)
end
--: (V5Type, V5Type, boolean) -> V5Type
local function idxrec(key, value, readonly)
	local idxs = {} --[[: TIndex[] ]]
	idxs[1] = types_mod.index(key, value, readonly)
	local empty_fields = {} --[[: { [string]: TField } ]]
	return types_mod.record_full(empty_fields, idxs, nil)
end
local _ = mkrec
local _ = ro
local _ = idxrec

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

-- Fixtures 6 / 6a–6d RETIRED (Spec C): multi-return positional records are
-- retired in favour of TPack (Spec B); the alignment/arity behaviour is covered
-- by the pack fixtures F-B1..F-B10 below.

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
-- Fixture 8: CRow narrowing-suppression soundness floor (G8)
-- Scenario A: open-row + CRowLacks, no close → S-Quiesce-CRowLacks in both.
-- Scenario B: open-row + CRowLacks + CRowClose → resolves cleanly in both.
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 8 — CRow narrowing suppression soundness floor", function()
	T.it("Scenario A: unresolved CRowLacks at quiescence errors in both interpreters", function()
		local rv1 = types_mod.rowvar(80) --[[: V5Type ]]
		local rec1 = types_mod.record_open({}, rv1) --[[: V5Type ]]
		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.row_lacks(rec1, "tag", prov("lacks-tag-open")))
		op_sem.run(exec)

		local rv2 = types_mod.rowvar(81) --[[: V5Type ]]
		local rec2 = types_mod.record_open({}, rv2) --[[: V5Type ]]
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.row_lacks(rec2, "tag", prov("lacks-tag-open")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture8-A", exec, alt)
		local exec_found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CRowLacks" then exec_found = true end
		end
		local alt_found = false
		for i = 1, #alt.errors do
			local e = alt.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CRowLacks" then alt_found = true end
		end
		T.ok(exec_found, "exec: S-Quiesce-CRowLacks fired (open-row unresolved at quiescence)")
		T.ok(alt_found, "alt: S-Quiesce-CRowLacks fired (open-row unresolved at quiescence)")
	end)

	T.it("Scenario B: CRowClose before quiescence — no errors in both interpreters", function()
		local rv1 = types_mod.rowvar(82) --[[: V5Type ]]
		local rec1 = types_mod.record_open({}, rv1) --[[: V5Type ]]
		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.row_lacks(rec1, "tag", prov("lacks-tag-close")))
		op_sem.emit(exec, constraint_mod.row_close(rec1, prov("close-row")))
		op_sem.run(exec)

		local rv2 = types_mod.rowvar(83) --[[: V5Type ]]
		local rec2 = types_mod.record_open({}, rv2) --[[: V5Type ]]
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.row_lacks(rec2, "tag", prov("lacks-tag-close")))
		op_sem.emit(alt, constraint_mod.row_close(rec2, prov("close-row")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture8-B", exec, alt)
		T.eq(op_sem.error_count(exec), 0, "exec: CRowClose before quiescence — no errors")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: CRowClose before quiescence — no errors")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 9: CHKT Reduce for Functor<Maybe>
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 9 — CHKT Reduce", function()
	T.it("Maybe lambda + CHKT(?F, [int], ?r) reduces identically", function()
		local string_ty = types_mod.const("string") --[[: V5Type ]]
		local var0 = types_mod.var(0) --[[: V5Type ]]
		local maybe_body = mkrec({ tag = string_ty, val = var0 }) --[[: V5Type ]]
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
		local maybe_body = mkrec({ tag = string_ty, val = var0 }) --[[: V5Type ]]
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
		local wide = mkrec({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = mkrec({ x = int_ty }) --[[: V5Type ]]

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
		local wide = mkrec({ x = int_ty, y = str_ty }) --[[: V5Type ]]
		local narrow = mkrec({ x = int_ty }) --[[: V5Type ]]

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
		local r_int = mkrec({ x = int_ty }) --[[: V5Type ]]
		local r_str = mkrec({ x = str_ty }) --[[: V5Type ]]

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

-- ════════════════════════════════════════════════════════════════════
-- Fixture 19: CRowExtend binds open-row record with new key
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 19 — CRowExtend binds open row", function()
	T.it("both interpreters add key to open-row record with no errors", function()
		local int_ty = types_mod.const("int") --[[: V5Type ]]

		local exec = fresh_state()
		local rv1 = types_mod.rowvar(10) --[[: V5Type ]]
		local rec1 = types_mod.record_open({}, rv1) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(rec1, "x", int_ty, prov("extend-x")))
		op_sem.run(exec)

		local alt = fresh_state()
		local rv2 = types_mod.rowvar(11) --[[: V5Type ]]
		local rec2 = types_mod.record_open({}, rv2) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.row_extend(rec2, "x", int_ty, prov("extend-x")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture19", exec, alt)
		T.eq(op_sem.error_count(exec), 0, "exec: no errors on open-row extend")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: no errors on open-row extend")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 20: CRowExtend on closed record → ERROR
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 20 — CRowExtend on closed record", function()
	T.it("both interpreters error with T-CRowExtend-Closed", function()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]

		local exec = fresh_state()
		local rec1 = mkrec({ y = int_ty }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(rec1, "x", str_ty, prov("extend-closed")))
		op_sem.run(exec)

		local alt = fresh_state()
		local rec2 = mkrec({ y = int_ty }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.row_extend(rec2, "x", str_ty, prov("extend-closed")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture20", exec, alt)
		local exec_found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then exec_found = true end
		end
		local alt_found = false
		for i = 1, #alt.errors do
			local e = alt.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then alt_found = true end
		end
		T.ok(exec_found, "exec: T-CRowExtend-Closed fired")
		T.ok(alt_found, "alt: T-CRowExtend-Closed fired")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 21: CRowLacks parks while open, succeeds when closed via CRowClose
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 21 — CRowLacks + CRowClose interaction", function()
	T.it("CRowLacks parks on open row; CRowClose wakes it; succeeds with key absent", function()
		local exec = fresh_state()
		local rv1 = types_mod.rowvar(20) --[[: V5Type ]]
		local rec1 = types_mod.record_open({}, rv1) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_lacks(rec1, "z", prov("lacks-z")))
		op_sem.emit(exec, constraint_mod.row_close(rec1, prov("close")))
		op_sem.run(exec)

		local alt = fresh_state()
		local rv2 = types_mod.rowvar(21) --[[: V5Type ]]
		local rec2 = types_mod.record_open({}, rv2) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.row_lacks(rec2, "z", prov("lacks-z")))
		op_sem.emit(alt, constraint_mod.row_close(rec2, prov("close")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture21", exec, alt)
		T.eq(op_sem.error_count(exec), 0, "exec: no errors — lacks succeeded after close")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: no errors — lacks succeeded after close")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Fixture 22 (risk): positional record + CRowExtend → closed-extend ERROR
-- A closed record (row = nil) must never grow a row tail (Spec C retires
-- positional records; the soundness floor is tested with a closed named record).
-- ════════════════════════════════════════════════════════════════════
T.describe("indep parity: fixture 22 — closed record stays closed", function()
	T.it("CRowExtend on closed record errors in both interpreters", function()
		local int_ty = types_mod.const("int") --[[: V5Type ]]
		local str_ty = types_mod.const("str") --[[: V5Type ]]
		local bool_ty = types_mod.const("bool") --[[: V5Type ]]

		local exec = fresh_state()
		local pos1 = mkrec({ a = int_ty, b = str_ty }) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.row_extend(pos1, "name", bool_ty, prov("closed-extend")))
		op_sem.run(exec)

		local alt = fresh_state()
		local pos2 = mkrec({ a = int_ty, b = str_ty }) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.row_extend(pos2, "name", bool_ty, prov("closed-extend")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture22", exec, alt)
		local exec_found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then exec_found = true end
		end
		local alt_found = false
		for i = 1, #alt.errors do
			local e = alt.errors[i]
			if e ~= nil and e.rule == "T-CRowExtend-Closed" then alt_found = true end
		end
		T.ok(exec_found, "exec: closed record rejected CRowExtend (T-CRowExtend-Closed)")
		T.ok(alt_found, "alt: positional record rejected CRowExtend (T-CRowExtend-Closed)")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Intersection + effect cross-interpreter fixtures (Phase 4)
-- ════════════════════════════════════════════════════════════════════

--: (string, V5Type[], V5Type[]) -> nil
local function run_pair_eq(label, a_parts, b_parts)
	local exec = fresh_state()
	op_sem.emit(exec, constraint_mod.intersection_eq(a_parts, b_parts, prov(label)))
	op_sem.run(exec)
	local alt = fresh_state()
	op_sem.emit(alt, constraint_mod.intersection_eq(a_parts, b_parts, prov(label)))
	op_sem_alt.run(alt)
	assert_state_parity(label, exec, alt)
end

-- Fixture 23: A & B ≡ B & A
T.describe("indep parity: fixture 23 — intersection commutativity", function()
	T.it("op_sem and op_sem_alt agree on canonical commutativity", function()
		local io_e = types_mod.effect("io")
		local os_e = types_mod.effect("os")
		run_pair_eq("fixture23", { io_e, os_e }, { os_e, io_e })
	end)
end)

-- Fixture 24: flatten A & (B & C) ≡ (A & B) & C
T.describe("indep parity: fixture 24 — intersection flattening", function()
	T.it("op_sem and op_sem_alt agree on nested flattening", function()
		local a = types_mod.effect("io")
		local b = types_mod.effect("os")
		local c = types_mod.const("alpha")
		run_pair_eq("fixture24",
			{ a, types_mod.intersection({ b, c }) },
			{ types_mod.intersection({ a, b }), c })
	end)
end)

-- Fixture 25: dedupe A & A ≡ A
T.describe("indep parity: fixture 25 — intersection dedupe", function()
	T.it("op_sem and op_sem_alt agree on canonical dedupe", function()
		local a = types_mod.effect("io")
		run_pair_eq("fixture25", { a, a }, { a })
	end)
end)

-- Fixture 26: int & !io <: int
T.describe("indep parity: fixture 26 — intersection LHS decomp", function()
	T.it("op_sem and op_sem_alt agree drop-effect direction succeeds", function()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local lhs = types_mod.intersection({ int_ty, io_e })

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(lhs, int_ty, prov("26")))
		op_sem.run(exec)
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(lhs, int_ty, prov("26")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture26", exec, alt)
		T.eq(op_sem.error_count(exec), 0, "fixture26: exec no errors")
		T.eq(op_sem_alt.error_count(alt), 0, "fixture26: alt no errors")
	end)
end)

-- Fixture 27: int <: int & !io fails
T.describe("indep parity: fixture 27 — intersection RHS conj fails", function()
	T.it("op_sem and op_sem_alt both reject LHS missing effect", function()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local rhs = types_mod.intersection({ int_ty, io_e })

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.sub(int_ty, rhs, prov("27")))
		op_sem.run(exec)
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.sub(int_ty, rhs, prov("27")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture27", exec, alt)
		T.ok(op_sem.error_count(exec) > 0, "fixture27: exec rejected")
		T.ok(op_sem_alt.error_count(alt) > 0, "fixture27: alt rejected")
	end)
end)

-- Fixture 28: direct member match on canonical intersection
T.describe("indep parity: fixture 28 — intersection member direct", function()
	T.it("op_sem and op_sem_alt agree direct member succeeds", function()
		local int_ty = types_mod.const("int")
		local io_e = types_mod.effect("io")
		local os_e = types_mod.effect("os")
		local inter = types_mod.intersection({ int_ty, io_e, os_e })

		local exec = fresh_state()
		op_sem.emit(exec, constraint_mod.intersection_member(inter, io_e, prov("28")))
		op_sem.run(exec)
		local alt = fresh_state()
		op_sem.emit(alt, constraint_mod.intersection_member(inter, io_e, prov("28")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture28", exec, alt)
	end)
end)

-- Fixture 29: F2 enforcement — stuck member on uvar errors at quiescence
T.describe("indep parity: fixture 29 — F2 enforcement on stuck member", function()
	T.it("op_sem and op_sem_alt both surface S-Quiesce error", function()
		local io_e = types_mod.effect("io")

		local exec = fresh_state()
		local u1 = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.intersection_member(types_mod.uvar(u1), io_e, prov("29")))
		op_sem.run(exec)

		local alt = fresh_state()
		local u2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.intersection_member(types_mod.uvar(u2), io_e, prov("29")))
		op_sem_alt.run(alt)

		assert_state_parity("fixture29", exec, alt)
		local exec_found = false
		for i = 1, #exec.errors do
			local e = exec.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CIntersectionMember" then exec_found = true end
		end
		local alt_found = false
		for i = 1, #alt.errors do
			local e = alt.errors[i]
			if e ~= nil and e.rule == "S-Quiesce-CIntersectionMember" then alt_found = true end
		end
		T.ok(exec_found, "fixture29: exec F2 enforcement fires")
		T.ok(alt_found, "fixture29: alt F2 enforcement fires")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Spec A — simple-sub bounds fixtures (P2.1).  Exercise the bound graph
-- B = {lower, upper, edge_up, edge_down} + the termination cache C across
-- BOTH independently-encoded interpreters.  The prior ~80 fixtures never
-- hit these paths (CSub-TVar previously routed to CEq).
-- ════════════════════════════════════════════════════════════════════

-- Count entries in the termination cache C of a state.
--: ({ [string]: boolean }) -> integer
local function cache_size(c)
	local n = 0
	for _k in pairs(c) do n = n + 1 end
	return n
end

-- ─── Fixture 30: multi-bound — one uvar with several upper bounds ────────
-- CSub(?u, number) + CSub(?u, unknown).  number <: unknown so ⋂ uppers
-- reduces to number; both interpreters coalesce identically.
T.describe("indep parity: fixture 30 — multi-bound (meet of uppers)", function()
	T.it("CSub(?u, number) + CSub(?u, unknown) coalesce identically", function()
		local number = types_mod.const("number") --[[: V5Type ]]
		local unknown = types_mod.const("unknown") --[[: V5Type ]]
		local exec = fresh_state()
		local u = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(u), number, prov("u<:num")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(u), unknown, prov("u<:unk")))
		op_sem.run(exec)
		local alt = fresh_state()
		local u2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(u2), number, prov("u<:num")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(u2), unknown, prov("u<:unk")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture30", exec, alt)
		local ru = op_sem.resolve(exec, u) --[[: V5Type ]]
		local ra = op_sem_alt.resolve(alt, u2) --[[: V5Type ]]
		assert_resolve_eq("fixture30.u", ru, ra)
		T.ok(types_mod.equal(ru, number), "exec ?u coalesces to number (unknown dropped)")
	end)
end)

-- ─── Fixture 31: transitive — integer <: ?a <: ?b <: number ──────────────
-- The flow edges carry integer up to number; the lattice accepts it.
T.describe("indep parity: fixture 31 — transitive bound chain", function()
	T.it("integer <: ?a <: ?b <: number resolves with no errors in both", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local number = types_mod.const("number") --[[: V5Type ]]
		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(integer, types_mod.uvar(a), prov("int<:a")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(a), types_mod.uvar(b), prov("a<:b")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(b), number, prov("b<:num")))
		op_sem.run(exec)
		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(integer, types_mod.uvar(a2), prov("int<:a")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(a2), types_mod.uvar(b2), prov("a<:b")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(b2), number, prov("b<:num")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture31", exec, alt)
		T.eq(op_sem.error_count(exec), 0, "exec: transitive chain clean")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: transitive chain clean")
	end)
end)

-- ─── Fixture 32: polar — same uvar at a lower AND an upper ───────────────
-- integer <: ?u <: number.  Eager cross-emission discharges
-- CSub(integer, number) (lattice ok); the coalesced face must agree.
T.describe("indep parity: fixture 32 — polar (lower + upper on one var)", function()
	T.it("integer <: ?u <: number coalesces identically in both", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local number = types_mod.const("number") --[[: V5Type ]]
		local exec = fresh_state()
		local u = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(integer, types_mod.uvar(u), prov("int<:u")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(u), number, prov("u<:num")))
		op_sem.run(exec)
		local alt = fresh_state()
		local u2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(integer, types_mod.uvar(u2), prov("int<:u")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(u2), number, prov("u<:num")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture32", exec, alt)
		local ru = op_sem.resolve(exec, u) --[[: V5Type ]]
		local ra = op_sem_alt.resolve(alt, u2) --[[: V5Type ]]
		assert_resolve_eq("fixture32.u", ru, ra)
		T.eq(op_sem.error_count(exec), 0, "exec: compatible polar bounds clean")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: compatible polar bounds clean")
	end)
end)

-- ─── Fixture 32b: polar conflict — integer <: ?u <: string errors ────────
T.describe("indep parity: fixture 32b — polar conflict surfaces", function()
	T.it("integer <: ?u <: string errors in both interpreters", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local strty = types_mod.const("string") --[[: V5Type ]]
		local exec = fresh_state()
		local u = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(integer, types_mod.uvar(u), prov("int<:u")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(u), strty, prov("u<:str")))
		op_sem.run(exec)
		local alt = fresh_state()
		local u2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(integer, types_mod.uvar(u2), prov("int<:u")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(u2), strty, prov("u<:str")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture32b", exec, alt)
		T.ok(op_sem.error_count(exec) > 0, "exec: conflict surfaces")
		T.ok(op_sem_alt.error_count(alt) > 0, "alt: conflict surfaces")
	end)
end)

-- ─── Fixture 33: var-flow — CSub(?a,?b) edge, then bind propagates ───────
-- integer flows through a→b's edge and b's concrete upper, exercising the
-- forward lower-propagation that closes the transitive obligation.
T.describe("indep parity: fixture 33 — var-flow then bind propagates", function()
	T.it("CSub(?a,?b) edge + concrete bounds resolve identically", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(a), types_mod.uvar(b), prov("a<:b")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(b), integer, prov("b<:int")))
		op_sem.emit(exec, constraint_mod.sub(integer, types_mod.uvar(a), prov("int<:a")))
		op_sem.run(exec)
		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(a2), types_mod.uvar(b2), prov("a<:b")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(b2), integer, prov("b<:int")))
		op_sem.emit(alt, constraint_mod.sub(integer, types_mod.uvar(a2), prov("int<:a")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture33", exec, alt)
		local rae = op_sem.resolve(exec, a) --[[: V5Type ]]
		local raa = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture33.a", rae, raa)
		T.eq(op_sem.error_count(exec), 0, "exec: var-flow clean")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: var-flow clean")
	end)
end)

-- ─── Fixture 34: cyclic-bound — ?a <: ?b and ?b <: ?a (no CEq merge) ─────
-- The bound graph has a 2-cycle of edges; the cache C cuts the otherwise
-- infinite re-emission.  Assert bounded steps + state parity.
T.describe("indep parity: fixture 34 — cyclic bound graph terminates", function()
	T.it("?a <: ?b and ?b <: ?a terminate via cache C in both", function()
		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(a), types_mod.uvar(b), prov("a<:b")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(b), types_mod.uvar(a), prov("b<:a")))
		op_sem.run(exec)
		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(a2), types_mod.uvar(b2), prov("a<:b")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(b2), types_mod.uvar(a2), prov("b<:a")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture34", exec, alt)
		T.ok(exec.steps < 100, "exec terminated in bounded steps (" .. exec.steps .. ")")
		T.ok(alt.steps < 100, "alt terminated in bounded steps (" .. alt.steps .. ")")
		T.eq(op_sem.error_count(exec), 0, "exec: cyclic edges clean")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: cyclic edges clean")
	end)
end)

-- ─── Fixture 35: adversarial mutually-recursive concrete bounds ──────────
-- A web of edges (a→b→c→a) plus concrete bounds drives transitive
-- re-emission.  Without the cache this diverges; with it both terminate
-- and the cache demonstrably short-circuits (one re-emission per key).
T.describe("indep parity: fixture 35 — adversarial mutually-recursive bounds", function()
	T.it("mutually-recursive bound graph terminates + cache short-circuits", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local number = types_mod.const("number") --[[: V5Type ]]
		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		local c = subst_mod.fresh(exec.subst, "open")
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(a), types_mod.uvar(b), prov("a<:b")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(b), types_mod.uvar(c), prov("b<:c")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(c), types_mod.uvar(a), prov("c<:a")))
		op_sem.emit(exec, constraint_mod.sub(integer, types_mod.uvar(a), prov("int<:a")))
		op_sem.emit(exec, constraint_mod.sub(types_mod.uvar(c), number, prov("c<:num")))
		op_sem.run(exec)
		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		local c2 = subst_mod.fresh(alt.subst, "open")
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(a2), types_mod.uvar(b2), prov("a<:b")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(b2), types_mod.uvar(c2), prov("b<:c")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(c2), types_mod.uvar(a2), prov("c<:a")))
		op_sem.emit(alt, constraint_mod.sub(integer, types_mod.uvar(a2), prov("int<:a")))
		op_sem.emit(alt, constraint_mod.sub(types_mod.uvar(c2), number, prov("c<:num")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture35", exec, alt)
		T.ok(exec.steps < 200, "exec terminated in bounded steps (" .. exec.steps .. ")")
		T.ok(alt.steps < 200, "alt terminated in bounded steps (" .. alt.steps .. ")")
		T.ok(exec.sub_emits < 100, "exec sub re-emissions bounded (" .. exec.sub_emits .. ")")
		T.ok(alt.sub_emits < 100, "alt sub re-emissions bounded (" .. alt.sub_emits .. ")")
		local ec = cache_size(exec.subcache)
		local ac = cache_size(alt.subcache)
		T.ok(ec > 0, "exec cache C populated (short-circuit active)")
		T.ok(ac > 0, "alt cache C populated (short-circuit active)")
		-- Each re-emitted obligation recorded exactly one key before enqueue,
		-- so the cache bounds re-emission: sub_emits == cache size.
		T.eq(exec.sub_emits, ec, "exec: one re-emission per cache key")
		T.eq(alt.sub_emits, ac, "alt: one re-emission per cache key")
	end)
end)

-- ─── Fixture 36: cyclic bound resolved by CEq merge (T-CEq-UU-Bounds) ────
-- ?a<:?b, ?b<:?a, then CEq(?a,?b) merges roots; the merge reconciliation
-- folds both bound sets + edges and re-establishes closure, cache-guarded.
T.describe("indep parity: fixture 36 — cyclic bound then CEq merge", function()
	T.it("?a<:?b, ?b<:?a, CEq(?a,?b) merge reconciles in both", function()
		local integer = types_mod.const("integer") --[[: V5Type ]]
		local exec = fresh_state()
		local a = subst_mod.fresh(exec.subst, "open")
		local b = subst_mod.fresh(exec.subst, "open")
		local ua = types_mod.uvar(a) --[[: V5Type ]]
		local ub = types_mod.uvar(b) --[[: V5Type ]]
		op_sem.emit(exec, constraint_mod.sub(ua, ub, prov("a<:b")))
		op_sem.emit(exec, constraint_mod.sub(ub, ua, prov("b<:a")))
		op_sem.emit(exec, constraint_mod.sub(integer, ua, prov("int<:a")))
		op_sem.emit(exec, constraint_mod.eq(ua, ub, prov("a=b")))
		op_sem.run(exec)
		local alt = fresh_state()
		local a2 = subst_mod.fresh(alt.subst, "open")
		local b2 = subst_mod.fresh(alt.subst, "open")
		local ua2 = types_mod.uvar(a2) --[[: V5Type ]]
		local ub2 = types_mod.uvar(b2) --[[: V5Type ]]
		op_sem.emit(alt, constraint_mod.sub(ua2, ub2, prov("a<:b")))
		op_sem.emit(alt, constraint_mod.sub(ub2, ua2, prov("b<:a")))
		op_sem.emit(alt, constraint_mod.sub(integer, ua2, prov("int<:a")))
		op_sem.emit(alt, constraint_mod.eq(ua2, ub2, prov("a=b")))
		op_sem_alt.run(alt)
		assert_state_parity("fixture36", exec, alt)
		T.ok(exec.steps < 100, "exec terminated bounded (" .. exec.steps .. ")")
		T.ok(alt.steps < 100, "alt terminated bounded (" .. alt.steps .. ")")
		local rae = op_sem.resolve(exec, a) --[[: V5Type ]]
		local raa = op_sem_alt.resolve(alt, a2) --[[: V5Type ]]
		assert_resolve_eq("fixture36.a", rae, raa)
		T.eq(op_sem.error_count(exec), 0, "exec: merge clean")
		T.eq(op_sem_alt.error_count(alt), 0, "alt: merge clean")
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Spec B — TPack parity fixtures (Phase 2.2)
-- ════════════════════════════════════════════════════════════════════
--
-- These exercise the TPack CEq/CSub rules across both interpreters: closed
-- equal-arity, OpenL/OpenR tail-binding, OpenBoth prefix-align, splice
-- (R↦pack / R↦never), arrow CSub contra-args / co-ret through packs, pack-arity
-- rejection, deeply-nested pack-in-pack-in-arrow (op-sem doc gap #2), and an
-- open-pack alignment FUZZ (op-sem doc gap #3) across the two encoders.

local C = constraint_mod
local function k(s) return types_mod.const(s) end

-- Run identical emissions (built by `build(st)` returning a list of tvar ids to
-- compare) on both interpreters; assert state + resolution parity.
--: (string, (AltState) -> integer[]) -> nil
local function run_both(label, build)
	local exec = fresh_state()
	local ids_e = build(exec)
	op_sem.run(exec)
	local alt = fresh_state()
	local ids_a = build(alt)
	op_sem_alt.run(alt)
	assert_state_parity(label, exec, alt)
	T.eq(#ids_e, #ids_a, label .. ": tracked-id count diverges")
	for i = 1, #ids_e do
		local ie = ids_e[i]
		local ia = ids_a[i]
		if ie ~= nil and ia ~= nil then
			local re = op_sem.resolve(exec, ie) --[[: V5Type ]]
			local ra = op_sem_alt.resolve(alt, ia) --[[: V5Type ]]
			assert_resolve_eq(label .. ".id" .. i, re, ra)
		end
	end
end

T.describe("indep parity: pack F-B1 — closed equal-arity arrow CEq", function()
	T.it("(?x, num) -> str  ≡  (int, num) -> ?y  binds ?x=int, ?y=str", function()
		run_both("packB1", function(st)
			local x = subst_mod.fresh(st.subst, "open")
			local y = subst_mod.fresh(st.subst, "open")
			local ar1 = types_mod.arrow({ types_mod.uvar(x), k("number") }, { k("string") }) --[[: V5Type ]]
			local ar2 = types_mod.arrow({ k("integer"), k("number") }, { types_mod.uvar(y) }) --[[: V5Type ]]
			op_sem.emit(st, C.eq(ar1, ar2, prov("arr-ceq")))
			return { x, y }
		end)
	end)
end)

T.describe("indep parity: pack F-B2 — OpenL tail-binding via CEq", function()
	T.it("pack([?a], R) ≡ pack([int, str, bool]) binds ?a=int, R↦[str,bool]", function()
		run_both("packB2", function(st)
			local a = subst_mod.fresh(st.subst, "open")
			local pl = types_mod.pack({ types_mod.uvar(a) }, types_mod.packvar(9001)) --[[: V5Type ]]
			local pr = types_mod.pack({ k("integer"), k("string"), k("true") }, nil) --[[: V5Type ]]
			op_sem.emit(st, C.eq(pl, pr, prov("openL")))
			return { a }
		end)
	end)
end)

T.describe("indep parity: pack F-B3 — OpenR tail-binding via CEq", function()
	T.it("pack([int, str, bool]) ≡ pack([?b], R)", function()
		run_both("packB3", function(st)
			local b = subst_mod.fresh(st.subst, "open")
			local pl = types_mod.pack({ k("integer"), k("string"), k("true") }, nil) --[[: V5Type ]]
			local pr = types_mod.pack({ types_mod.uvar(b) }, types_mod.packvar(9002)) --[[: V5Type ]]
			op_sem.emit(st, C.eq(pl, pr, prov("openR")))
			return { b }
		end)
	end)
end)

T.describe("indep parity: pack F-B4 — OpenBoth prefix-align surplus → shorter rest", function()
	T.it("pack([?a, ?b], R1) ≡ pack([int], R2) prefix-aligns by min", function()
		run_both("packB4", function(st)
			local a = subst_mod.fresh(st.subst, "open")
			local bb = subst_mod.fresh(st.subst, "open")
			local pl = types_mod.pack({ types_mod.uvar(a), types_mod.uvar(bb) }, types_mod.packvar(9003)) --[[: V5Type ]]
			local pr = types_mod.pack({ k("integer") }, types_mod.packvar(9004)) --[[: V5Type ]]
			op_sem.emit(st, C.eq(pl, pr, prov("openBoth")))
			return { a }
		end)
	end)
end)

T.describe("indep parity: pack F-B5 — splice R↦pack then equate", function()
	T.it("(true, ...R) with R↦[int, str] splices into closed [true,int,str]", function()
		run_both("packB5", function(st)
			-- Pre-bind R (id 9005) to [int, str] in pack_bindings, then CEq an
			-- open pack (true, ...R) against a fresh uvar tuple to observe splice.
			st.subst.pack_bindings[9005] = types_mod.pack({ k("integer"), k("string") }, nil)
			local u1 = subst_mod.fresh(st.subst, "open")
			local u2 = subst_mod.fresh(st.subst, "open")
			local u3 = subst_mod.fresh(st.subst, "open")
			local open = types_mod.pack({ k("true") }, types_mod.packvar(9005)) --[[: V5Type ]]
			local target = types_mod.pack({ types_mod.uvar(u1), types_mod.uvar(u2), types_mod.uvar(u3) }, nil) --[[: V5Type ]]
			op_sem.emit(st, C.eq(open, target, prov("splice")))
			return { u1, u2, u3 }
		end)
	end)
end)

T.describe("indep parity: pack F-B6 — splice R↦never (empty pack)", function()
	T.it("(true, ...R) with R↦[] collapses to closed [true]", function()
		run_both("packB6", function(st)
			st.subst.pack_bindings[9006] = types_mod.pack({}, nil)
			local u1 = subst_mod.fresh(st.subst, "open")
			local open = types_mod.pack({ k("true") }, types_mod.packvar(9006)) --[[: V5Type ]]
			local target = types_mod.pack({ types_mod.uvar(u1) }, nil) --[[: V5Type ]]
			op_sem.emit(st, C.eq(open, target, prov("splice-never")))
			return { u1 }
		end)
	end)
end)

T.describe("indep parity: pack F-B7 — arrow CSub contra-args / co-ret", function()
	T.it("(num)->?r <: (int)->str  emits int<:num (contra) and ?r adjust to str", function()
		run_both("packB7", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local sub_arr = types_mod.arrow({ k("number") }, { types_mod.uvar(r) }) --[[: V5Type ]]
			local sup_arr = types_mod.arrow({ k("integer") }, { k("string") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(sub_arr, sup_arr, prov("arr-csub")))
			return { r }
		end)
	end)
end)

T.describe("indep parity: pack F-B8 — pack-arity rejection (contra args)", function()
	T.it("(int, int)->num <: (int)->num rejects on arg arity", function()
		run_both("packB8", function(st)
			local sub_arr = types_mod.arrow({ k("integer"), k("integer") }, { k("number") }) --[[: V5Type ]]
			local sup_arr = types_mod.arrow({ k("integer") }, { k("number") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(sub_arr, sup_arr, prov("arity-reject")))
			return {}
		end)
	end)
end)

T.describe("indep parity: pack F-B9 — deeply-nested pack-in-pack-in-arrow (doc gap #2)", function()
	T.it("arrow whose arg is an arrow whose ret is a tuple decomposes identically", function()
		run_both("packB9", function(st)
			local x = subst_mod.fresh(st.subst, "open")
			-- inner arrow: (?x) -> (int, str)  [ret is a 2-tuple pack]
			local inner_sub = types_mod.arrow({ types_mod.uvar(x) }, { k("integer"), k("string") }) --[[: V5Type ]]
			local inner_sup = types_mod.arrow({ k("number") }, { k("integer"), k("string") }) --[[: V5Type ]]
			-- outer arrow: (inner) -> num.  CSub contra on the arg (inner arrows),
			-- which re-derives variance into the nested packs.
			local outer_sub = types_mod.arrow({ inner_sub }, { k("number") }) --[[: V5Type ]]
			local outer_sup = types_mod.arrow({ inner_sup }, { k("number") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(outer_sub, outer_sup, prov("nested")))
			return { x }
		end)
	end)
end)

T.describe("indep parity: pack F-B10 — open-pack alignment FUZZ (doc gap #3)", function()
	T.it("randomized open/closed pack CEq pairs agree across both encoders", function()
		-- Deterministic seed so failures replay.  Both interpreters see the SAME
		-- emissions per trial (build closures construct fresh nodes each call).
		local seed = tonumber(os.getenv("FUZZ_SEED") or "") or 0xB12A2
		math.randomseed(seed)
		local atoms = { "integer", "string", "true", "false", "number", "nil" }
		for trial = 1, 60 do
			--: () -> integer
			local function rint(n) return math.floor(math.random() * n) end
			local na = rint(4)          -- 0..3 fixed LHS items
			local nb = rint(4)          -- 0..3 fixed RHS items
			local la_open = math.random() < 0.5
			local lb_open = math.random() < 0.5
			-- Snapshot the choices so both interpreters build identical packs.
			local la_atoms = {} --[[: string[] ]]
			for i = 1, na do la_atoms[i] = atoms[1 + rint(#atoms)] end
			local lb_atoms = {} --[[: string[] ]]
			for i = 1, nb do lb_atoms[i] = atoms[1 + rint(#atoms)] end
			--: (AltState) -> integer[]
			local function build(st)
				local _ = st
				local items_a = {} --[[: V5Type[] ]]
				for i = 1, na do local nm = la_atoms[i]; if nm ~= nil then items_a[i] = k(nm) end end
				local items_b = {} --[[: V5Type[] ]]
				for i = 1, nb do local nm = lb_atoms[i]; if nm ~= nil then items_b[i] = k(nm) end end
				--: { id: integer, tag: "packvar" } | nil
				local ra = nil
				if la_open then ra = types_mod.packvar(90100 + trial) end
				--: { id: integer, tag: "packvar" } | nil
				local rb = nil
				if lb_open then rb = types_mod.packvar(90200 + trial) end
				local pa = types_mod.pack(items_a, ra) --[[: V5Type ]]
				local pb = types_mod.pack(items_b, rb) --[[: V5Type ]]
				op_sem.emit(st, C.eq(pa, pb, prov("fuzz" .. trial)))
				return {}
			end
			run_both("packB10.trial" .. trial, build)
		end
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Spec C — TLiteral + TRecord three-region + unit (Phase 2.3)
-- ════════════════════════════════════════════════════════════════════

-- lit(base, value): a TLiteral helper.  Returns V5Type.
--: (string, integer | number | string | boolean) -> V5Type
local function lit(base, value) return types_mod.literal(base, value) end

-- ─── F-C1: literal <: literal (same singleton) ───────────────────────────
T.describe("indep parity: F-C1 — literal <: literal", function()
	T.it("42 <: 42 holds; 42 <: 43 rejects (both interpreters)", function()
		run_both("FC1.ok", function(st)
			op_sem.emit(st, C.sub(lit("integer", 42), lit("integer", 42), prov("lit-refl")))
			return {}
		end)
		run_both("FC1.bad", function(st)
			op_sem.emit(st, C.sub(lit("integer", 42), lit("integer", 43), prov("lit-distinct")))
			return {}
		end)
	end)
end)

-- ─── F-C2: literal <: const via base_widens (incl. 42 <: number) ─────────
T.describe("indep parity: F-C2 — literal widening", function()
	T.it("42<:integer, 42<:number, \"GET\"<:string, true<:boolean", function()
		run_both("FC2.int", function(st)
			op_sem.emit(st, C.sub(lit("integer", 42), k("integer"), prov("w1")))
			return {}
		end)
		run_both("FC2.num", function(st)
			op_sem.emit(st, C.sub(lit("integer", 42), k("number"), prov("w2")))
			return {}
		end)
		run_both("FC2.str", function(st)
			op_sem.emit(st, C.sub(lit("string", "GET"), k("string"), prov("w3")))
			return {}
		end)
		run_both("FC2.bool", function(st)
			op_sem.emit(st, C.sub(lit("boolean", true), k("boolean"), prov("w4")))
			return {}
		end)
		run_both("FC2.numlit", function(st)
			op_sem.emit(st, C.sub(lit("number", 1.5), k("number"), prov("w5")))
			return {}
		end)
	end)
end)

-- ─── F-C3: const <: literal NEVER ────────────────────────────────────────
T.describe("indep parity: F-C3 — const </: literal", function()
	T.it("integer </: 42; string </: \"GET\" (both reject)", function()
		run_both("FC3.int", function(st)
			op_sem.emit(st, C.sub(k("integer"), lit("integer", 42), prov("nw1")))
			return {}
		end)
		run_both("FC3.str", function(st)
			op_sem.emit(st, C.sub(k("string"), lit("string", "GET"), prov("nw2")))
			return {}
		end)
	end)
end)

-- ─── F-C4: T-CEq-Literal match / mismatch ────────────────────────────────
T.describe("indep parity: F-C4 — T-CEq-Literal", function()
	T.it("CEq(42,42) clean; CEq(42,43) and CEq(1:int, 1.0:num) mismatch", function()
		run_both("FC4.ok", function(st)
			local a = lit("integer", 42) --[[: V5Type ]]
			local b = lit("integer", 42) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, b, prov("eq-ok")))
			return {}
		end)
		run_both("FC4.valbad", function(st)
			local a = lit("integer", 42) --[[: V5Type ]]
			local b = lit("integer", 43) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, b, prov("eq-val")))
			return {}
		end)
		-- base distinguishes 1 (integer) from 1.0 (number) though Lua 1 == 1.0.
		run_both("FC4.basebad", function(st)
			local a = lit("integer", 1) --[[: V5Type ]]
			local b = lit("number", 1.0) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, b, prov("eq-base")))
			return {}
		end)
		-- literal vs its base atom under CEq is a MISMATCH (literal ≠ const).
		run_both("FC4.litvsconst", function(st)
			local a = lit("integer", 42) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, k("integer"), prov("eq-litconst")))
			return {}
		end)
	end)
end)

-- ─── F-C5: readonly-covariant vs mutable-invariant record subtyping ──────
T.describe("indep parity: F-C5 — record field variance", function()
	T.it("readonly field covariant; mutable field invariant", function()
		-- readonly x: integer  <:  readonly x: number   (covariant) — OK
		run_both("FC5.ro-cov-ok", function(st)
			local a = ro({ x = k("integer") }) --[[: V5Type ]]
			local b = ro({ x = k("number") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(a, b, prov("ro-cov")))
			return {}
		end)
		-- mutable x: integer  <:  mutable x: number   (invariant) — REJECT
		run_both("FC5.mut-inv-bad", function(st)
			local a = mkrec({ x = k("integer") }) --[[: V5Type ]]
			local b = mkrec({ x = k("number") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(a, b, prov("mut-inv")))
			return {}
		end)
		-- mutable x: integer  <:  mutable x: integer  (invariant, equal) — OK
		run_both("FC5.mut-eq-ok", function(st)
			local a = mkrec({ x = k("integer") }) --[[: V5Type ]]
			local b = mkrec({ x = k("integer") }) --[[: V5Type ]]
			op_sem.emit(st, C.sub(a, b, prov("mut-eq")))
			return {}
		end)
	end)
end)

-- ─── F-C6: index-signature equality + variance ───────────────────────────
T.describe("indep parity: F-C6 — index signatures", function()
	T.it("{[string]:integer} = {[string]:integer}; mutable index invariant; readonly covariant", function()
		-- CEq of identical index records.
		run_both("FC6.eq", function(st)
			local a = idxrec(k("string"), k("integer"), false) --[[: V5Type ]]
			local b = idxrec(k("string"), k("integer"), false) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, b, prov("idx-eq")))
			return {}
		end)
		-- mutable {[string]:integer} </: {[string]:number} (invariant index value).
		run_both("FC6.mut-bad", function(st)
			local a = idxrec(k("string"), k("integer"), false) --[[: V5Type ]]
			local b = idxrec(k("string"), k("number"), false) --[[: V5Type ]]
			op_sem.emit(st, C.sub(a, b, prov("idx-mut")))
			return {}
		end)
		-- readonly {[string]:integer} <: {[string]:number} (covariant index value).
		run_both("FC6.ro-ok", function(st)
			local a = idxrec(k("string"), k("integer"), true) --[[: V5Type ]]
			local b = idxrec(k("string"), k("number"), true) --[[: V5Type ]]
			op_sem.emit(st, C.sub(a, b, prov("idx-ro")))
			return {}
		end)
	end)
end)

-- ─── F-C7: optional-field domain agreement under CEq ─────────────────────
T.describe("indep parity: F-C7 — optional attribute identity", function()
	T.it("CEq distinguishes optional from required field", function()
		local opt = types_mod.record({ x = types_mod.field(k("integer"), true, false) }) --[[: V5Type ]]
		local req = types_mod.record({ x = types_mod.field(k("integer"), false, false) }) --[[: V5Type ]]
		-- Same attributes → clean.
		run_both("FC7.same", function(st)
			local a = types_mod.record({ x = types_mod.field(k("integer"), true, false) }) --[[: V5Type ]]
			local b = types_mod.record({ x = types_mod.field(k("integer"), true, false) }) --[[: V5Type ]]
			op_sem.emit(st, C.eq(a, b, prov("opt-same")))
			return {}
		end)
		-- Differing optional attribute → mismatch in both interpreters.
		run_both("FC7.diff", function(st)
			op_sem.emit(st, C.eq(opt, req, prov("opt-diff")))
			return {}
		end)
	end)
end)

-- ─── F-C8: unit primitive ────────────────────────────────────────────────
T.describe("indep parity: F-C8 — unit primitive", function()
	T.it("unit <: unit; never <: unit; unit <: unknown; unit </: nil", function()
		run_both("FC8.refl", function(st)
			op_sem.emit(st, C.sub(k("unit"), k("unit"), prov("u1")))
			return {}
		end)
		run_both("FC8.bottom", function(st)
			op_sem.emit(st, C.sub(k("never"), k("unit"), prov("u2")))
			return {}
		end)
		run_both("FC8.top", function(st)
			op_sem.emit(st, C.sub(k("unit"), k("unknown"), prov("u3")))
			return {}
		end)
		-- unit is unrelated to nil (it is the absence of a value, not nil).
		run_both("FC8.notnil", function(st)
			op_sem.emit(st, C.sub(k("unit"), k("nil"), prov("u4")))
			return {}
		end)
	end)
end)

-- ─── F-C9: ZERO `$`-string-matches in the interpretation path ────────────
-- The Spec C success criterion: no literal/record/unit `$`-encoding name is
-- matched in the interpretation path (op_sem.lua, op_sem_alt.lua, the types.lua
-- walkers).  We scan the source of those modules for `"$X"` comparisons /
-- prefix tests against the retired encodings.  Permanent type-level intrinsics
-- ($Require/$Opaque/$FfiC/$GlobalScope/$Throw/$Catch/$EachField/$PatternReturn/
-- $FindReturn) and the tuple-spread marker $Spread are NOT part of the
-- literal/record interpretation path and are not searched for here — the test
-- targets ONLY the retired literal/record/unit names.
T.describe("indep parity: F-C9 — no `$`-string-matches in interpretation path", function()
	T.it("op_sem.lua / op_sem_alt.lua / types.lua walkers contain zero retired `$`-encoding matches", function()
		local retired = {
			"$Lit", "$LitInt", "$LitNum", "$LitBool", "$LitStr",
			"$idx", "$opt_", "$ro_", "$opaque", "$computed", "$pos_", "$spread_",
			"$Unit", "$Idx",
		} --[[: string[] ]]
		local files = {
			"lib/type/static-v5/op_sem.lua",
			"lib/type/static-v5/op_sem_alt.lua",
			"lib/type/experiments/v5_perf/types.lua",
		} --[[: string[] ]]
		for fi = 1, #files do
			local path = files[fi]
			if path ~= nil then
				local fh = io.open(path, "r")
				T.ok(fh ~= nil, "open " .. path)
				if fh ~= nil then
					local src_opt = fh:read("*a")
					fh:close()
					local src = src_opt or "" --[[: string ]]
					for ri = 1, #retired do
						local name = retired[ri]
						if name ~= nil then
							-- Match a quoted occurrence ("$X") — the only way a name
							-- enters a comparison or prefix test in Lua source.
							local needle = "\"" .. name --[[: string ]]
							local found = src:find(needle, 1, true)
							T.ok(found == nil,
								path .. " must not match retired encoding " .. name)
						end
					end
				end
			end
		end
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Spec B (part 2) — TMatch + CMatchEval + match_pattern parity (Phase 2.4)
-- ════════════════════════════════════════════════════════════════════
--
-- Each match_pattern case across both independently-encoded interpreters:
-- wildcard, capture, bare-named CSub, primitive, literal-equality, table/
-- record, all-fields distribution, arrow/pack (() -> %R, (...%P)), union
-- distribution, intersection elimination, named/match scrutinee, plus
-- park-then-wake on a uvar param, eager-vs-parked equality, the MANDATORY
-- coinductive recursive match, stuck-at-quiescence, and effect App-spine.

--:: TMatchArm = { pattern: V5Type, result: V5Type }

local function lit(base, v) return types_mod.literal(base, v) end
local function cap(i) return types_mod.capture(i) end
local function fld(t) return types_mod.field(t, false, false) end

-- emit_match1 / emit_match2: seed a CMatchEval over a fresh result tvar with
-- one or two `Pattern => Result` arms.  The arm list is built internally (a
-- typed `TMatchArm[]` local) so the giant-union firewall stays contained.
--: (AltState, V5Type, V5Type, V5Type, integer) -> nil
local function emit_match1(st, scrut, pat, res, rtv)
	local arms = {} --[[: TMatchArm[] ]]
	arms[1] = { pattern = pat, result = res }
	op_sem.emit(st, C.match_eval(scrut, arms, types_mod.uvar(rtv), prov("cmatch")))
end
--: (AltState, V5Type, V5Type, V5Type, V5Type, V5Type, integer) -> nil
local function emit_match2(st, scrut, p1, r1, p2, r2, rtv)
	local arms = {} --[[: TMatchArm[] ]]
	arms[1] = { pattern = p1, result = r1 }
	arms[2] = { pattern = p2, result = r2 }
	op_sem.emit(st, C.match_eval(scrut, arms, types_mod.uvar(rtv), prov("cmatch")))
end

-- F-B2.1: wildcard arm fires, binds nothing.
T.describe("indep parity: match — wildcard arm", function()
	T.it("match string { _ => integer } reduces to integer", function()
		run_both("match_wildcard", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, k("string"), cap(-1), k("integer"), r)
			return { r }
		end)
	end)
end)

-- F-B2.2: capture arm binds the scrutinee.
T.describe("indep parity: match — bare capture", function()
	T.it("match number { %X => X } binds X = number", function()
		run_both("match_capture", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, k("number"), cap(0), cap(0), r)
			return { r }
		end)
	end)
end)

-- F-B2.3: bare-named pattern resolves via CSub (atomic widening).
T.describe("indep parity: match — bare-named CSub (widening)", function()
	T.it("match integer { number => true } fires (integer <: number)", function()
		run_both("match_named_csub", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, k("integer"), k("number"), lit("boolean", true), r)
			return { r }
		end)
	end)
end)

-- F-B2.4: primitive exact match.
T.describe("indep parity: match — primitive exact", function()
	T.it("match string { string => integer } fires", function()
		run_both("match_prim", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, k("string"), k("string"), k("integer"), r)
			return { r }
		end)
	end)
end)

-- F-B2.5: literal-equality leaf against the real TLiteral ("GET" / 42).
T.describe("indep parity: match — literal-equality leaf", function()
	T.it('match "GET" { "GET" => integer, "POST" => string } picks integer', function()
		run_both("match_lit_str", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match2(st, lit("string", "GET"),
				lit("string", "GET"), k("integer"),
				lit("string", "POST"), k("string"), r)
			return { r }
		end)
	end)
	T.it("match 42 { 42 => true, 0 => false } picks true", function()
		run_both("match_lit_int", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match2(st, lit("integer", 42),
				lit("integer", 42), lit("boolean", true),
				lit("integer", 0), lit("boolean", false), r)
			return { r }
		end)
	end)
	T.it("literal widens to base atom: match 42 { integer => string }", function()
		run_both("match_lit_widen", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, lit("integer", 42), k("integer"), k("string"), r)
			return { r }
		end)
	end)
end)

-- F-B2.6: table / record pattern with a field capture.
T.describe("indep parity: match — record field capture", function()
	T.it("match { a: number, b: string } { { a: %X } => X } binds X = number", function()
		run_both("match_record", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.record({ a = fld(k("number")), b = fld(k("string")) })
			local pat = types_mod.record({ a = fld(cap(0)) })
			emit_match1(st, scrut, pat, cap(0), r)
			return { r }
		end)
	end)
end)

-- F-B2.7: rest-field capture { f: T, ...%Rest }.
T.describe("indep parity: match — record rest capture", function()
	T.it("match { a: number, b: string } { { a: %X, ...%Rest } => Rest }", function()
		run_both("match_rest", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.record({ a = fld(k("number")), b = fld(k("string")) })
			local rest_fields = {} --[[: { [string]: TField } ]]
			local restk = "..." --[[: string ]]
			local ak = "a" --[[: string ]]
			rest_fields[restk] = fld(cap(1))
			rest_fields[ak] = fld(cap(0))
			local pat = types_mod.record(rest_fields)
			emit_match1(st, scrut, pat, cap(1), r)
			return { r }
		end)
	end)
end)

-- F-B2.8: all-fields distribution { ...[%K]: %V } — Values<T>.
T.describe("indep parity: match — all-fields distribution", function()
	T.it("Values: match { a: number, b: string } { ...[%K]: %V => V }", function()
		run_both("match_allfields", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.record({ a = fld(k("number")), b = fld(k("string")) })
			emit_match1(st, scrut, types_mod.patallfields(0, 1), cap(1), r)
			return { r }
		end)
	end)
end)

-- F-B2.9: arrow / pack — () -> %R binds the ret (single type).
T.describe("indep parity: match — arrow () -> %R", function()
	T.it("match (integer) -> number { () -> %R => R } binds R = number", function()
		run_both("match_arrow_R", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.arrow({ k("integer") }, { k("number") })
			local pat = types_mod.arrow({}, { cap(0) })
			emit_match1(st, scrut, pat, cap(0), r)
			return { r }
		end)
	end)
	T.it("multi-ret () -> %R binds R = pack[number, string]", function()
		run_both("match_arrow_R_multi", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.arrow({ k("integer") }, { k("number"), k("string") })
			local pat = types_mod.arrow({}, { cap(0) })
			emit_match1(st, scrut, pat, cap(0), r)
			return { r }
		end)
	end)
	T.it("(...%P) -> R binds P = pack of params, spliced via (...P)", function()
		run_both("match_arrow_P", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.arrow({ k("integer"), k("string") }, { k("number") })
			local pat = types_mod.arrow({ cap(0) }, { k("number") })
			-- result (...P) -> number: splice P into the args pack.
			local res = types_mod.arrow({}, { k("number") })
			res = { tag = "arrow", args = types_mod.pack({ cap(0) }, nil), ret = res.ret }
			emit_match1(st, scrut, pat, res, r)
			return { r }
		end)
	end)
end)

-- F-B2.10: union distribution.
T.describe("indep parity: match — union distribution", function()
	T.it("match (integer | string) { integer => true, string => false }", function()
		run_both("match_union", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.union({ k("integer"), k("string") })
			emit_match2(st, scrut,
				k("integer"), lit("boolean", true),
				k("string"), lit("boolean", false), r)
			return { r }
		end)
	end)
end)

-- F-B2.11: intersection elimination.
T.describe("indep parity: match — intersection elimination", function()
	T.it("match (integer & string) { integer => true }", function()
		run_both("match_int_elim", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local scrut = types_mod.intersection({ k("integer"), k("string") })
			emit_match1(st, scrut, k("integer"), lit("boolean", true), r)
			return { r }
		end)
	end)
end)

-- F-B2.12: named / match scrutinee — a nested TMatch as the scrutinee.
T.describe("indep parity: match — nested match scrutinee", function()
	T.it("match (match integer { integer => string }) { string => true }", function()
		run_both("match_nested", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local inner_arms = {} --[[: TMatchArm[] ]]
			inner_arms[1] = { pattern = k("integer"), result = k("string") }
			local inner = types_mod.match(k("integer"), inner_arms)
			emit_match1(st, inner, k("string"), lit("boolean", true), r)
			return { r }
		end)
	end)
end)

-- F-B2.13: Park-then-Wake on a uvar param.
T.describe("indep parity: match — park-then-wake on uvar param", function()
	T.it("match ?p { integer => string } parks; ?p = integer wakes → string", function()
		run_both("match_park_wake", function(st)
			local p = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			local up = types_mod.uvar(p) --[[: V5Type ]]
			local tint = types_mod.const("integer") --[[: V5Type ]]
			emit_match1(st, up, tint, k("string"), r)
			op_sem.emit(st, constraint_mod.eq(up, tint, prov("bind-p")))
			return { r }
		end)
	end)
end)

-- F-B2.14: eager-vs-parked observable equality (rigid scrutinee = same result).
T.describe("indep parity: match — eager vs parked equality", function()
	T.it("rigid-at-emit and bound-after-emit give the same result", function()
		local tint = types_mod.const("integer") --[[: V5Type ]]
		local tstr = types_mod.const("string") --[[: V5Type ]]
		-- Eager: scrutinee already rigid when CMatchEval is emitted.
		local eager = fresh_state()
		local re = subst_mod.fresh(eager.subst, "open")
		emit_match1(eager, tint, tint, tstr, re)
		op_sem.run(eager)
		-- Parked: scrutinee bound after the CMatchEval.
		local parked = fresh_state()
		local pp = subst_mod.fresh(parked.subst, "open")
		local rp = subst_mod.fresh(parked.subst, "open")
		local upp = types_mod.uvar(pp) --[[: V5Type ]]
		emit_match1(parked, upp, tint, tstr, rp)
		op_sem.emit(parked, constraint_mod.eq(upp, tint, prov("late-bind")))
		op_sem.run(parked)
		local res_eager = op_sem.resolve(eager, re) --[[: V5Type ]]
		local res_parked = op_sem.resolve(parked, rp) --[[: V5Type ]]
		assert_resolve_eq("eager-vs-parked", res_eager, res_parked)
	end)
end)

-- F-B2.15: MANDATORY coinductive recursive match.  A self-referential record
-- scrutinee (a uvar bound to a record that contains itself) is matched by a
-- field-capturing record pattern; the seen-set cycle guard bounds the descent.
-- This is the highest-value check: v4's cycle-guard / conflicting-capture
-- semantics diverge only on recursive scrutinees.
T.describe("indep parity: match — coinductive recursive scrutinee", function()
	T.it("match (μ R. { next: R, val: integer }) { { val: %V } => V } binds integer", function()
		run_both("match_recursive", function(st)
			local p = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			-- Bind ?p to a record that references itself in `next` (a regular μ-type).
			local rec = types_mod.record({ next = fld(types_mod.uvar(p)), val = fld(k("integer")) })
			subst_mod.bind(st.subst, p, rec)
			local pat = types_mod.record({ val = fld(cap(0)) })
			emit_match1(st, types_mod.uvar(p), pat, cap(0), r)
			return { r }
		end)
	end)
	T.it("recursive scrutinee with a recursive field PATTERN hits the cycle guard", function()
		run_both("match_recursive_pat", function(st)
			local p = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			local rec = types_mod.record({ next = fld(types_mod.uvar(p)), val = fld(k("integer")) })
			subst_mod.bind(st.subst, p, rec)
			-- Pattern { next: { next: ... }, val: %V } — a self-recursive pattern via
			-- a uvar bound to itself; the coinductive (ty,pat) key bounds descent.
			local pp = subst_mod.fresh(st.subst, "open")
			local recpat = types_mod.record({ next = fld(types_mod.uvar(pp)), val = fld(cap(0)) })
			subst_mod.bind(st.subst, pp, recpat)
			emit_match1(st, types_mod.uvar(p), types_mod.uvar(pp), cap(0), r)
			return { r }
		end)
	end)
end)

-- F-B2.16: Stuck-at-quiescence (T-CMatchEval-Stuck).
T.describe("indep parity: match — stuck at quiescence", function()
	T.it("match ?p { integer => string } with ?p never bound errors identically", function()
		run_both("match_stuck", function(st)
			local p = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, types_mod.uvar(p), k("integer"), k("string"), r)
			return {}
		end)
	end)
end)

-- F-B2.17: effect App-spine pattern !yield<%Y, %R>.
T.describe("indep parity: match — effect App-spine !yield<%Y,%R>", function()
	T.it("match (nil & !yield<number, string>) { !yield<%Y, %R> => Y } binds Y = number", function()
		run_both("match_effect_yield", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local yeff = types_mod.effect_apply(types_mod.effect("yield"), { k("number"), k("string") })
			local scrut = types_mod.intersection({ k("nil"), yeff })
			local pat = types_mod.effect_apply(types_mod.effect("yield"), { cap(0), cap(1) })
			emit_match1(st, scrut, pat, cap(0), r)
			return { r }
		end)
	end)
	T.it("!yield<%Y,%R> binds R = string from the second arg", function()
		run_both("match_effect_yield_R", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			local yeff = types_mod.effect_apply(types_mod.effect("yield"), { k("number"), k("string") })
			local scrut = types_mod.intersection({ k("nil"), yeff })
			local pat = types_mod.effect_apply(types_mod.effect("yield"), { cap(0), cap(1) })
			emit_match1(st, scrut, pat, cap(1), r)
			return { r }
		end)
	end)
end)

-- F-B2.18: fallthrough → never.
T.describe("indep parity: match — fallthrough to never", function()
	T.it("match boolean { integer => string } (no arm fires) → never", function()
		run_both("match_fallthrough", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, k("boolean"), k("integer"), k("string"), r)
			return { r }
		end)
	end)
end)

-- ════════════════════════════════════════════════════════════════════
-- Phase 2.4.5 — call-site declared-return instantiation parity
-- ════════════════════════════════════════════════════════════════════
--
-- The 2.4.5 substrate is gen-pass-side: subst_params substitutes actual arg
-- types into a declared return's TParam binders, then lower_matches emits a
-- CMatchEval over the (now-concrete) scrutinee.  No NEW interpreter reduction
-- rule is introduced — the per-call-site match is reduced by the existing
-- CMatchEval machinery.  These fixtures verify that the SHAPE subst_params
-- produces (a TMatch whose scrutinee is a substituted concrete arg) reduces
-- IDENTICALLY in both independently-encoded interpreters.  subst_params itself
-- (a pure types-module walk) is exercised in the fixture body so the substrate
-- composition — substitute then reduce — is checked across both.

-- emit_disc(st, arg, rtv): the canonical 2.4.5 discriminated-return reduction.
-- Build a TMatch over a TParam(1) ref — the way a stdlib
-- `disc : (%1) -> match %1 { true => string, false => integer }` declares it —
-- substitute `arg` into the param via subst_params (the gen-pass-side step),
-- then emit the resulting CMatchEval (the lower_matches step).  The CMatchEval
-- carries the now-concrete substituted scrutinee.
--: (AltState, V5Type, integer) -> nil
local function emit_disc(st, arg, rtv)
	local arms = {} --[[: TMatchArm[] ]]
	arms[1] = { pattern = lit("boolean", true),  result = k("string") }
	arms[2] = { pattern = lit("boolean", false), result = k("integer") }
	local scrut = types_mod.subst_params(types_mod.param(1), { arg }) --[[: V5Type ]]
	op_sem.emit(st, C.match_eval(scrut, arms, types_mod.uvar(rtv), prov("inst-disc")))
end

T.describe("indep parity: 2.4.5 — disc(true) arm-1 reduction", function()
	T.it("subst_params(true) then CMatchEval reduces to string in both", function()
		run_both("inst_disc_true", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_disc(st, lit("boolean", true), r)
			return { r }
		end)
	end)
end)

T.describe("indep parity: 2.4.5 — disc(false) arm-2 reduction", function()
	T.it("subst_params(false) then CMatchEval reduces to integer in both", function()
		run_both("inst_disc_false", function(st)
			local r = subst_mod.fresh(st.subst, "open")
			emit_disc(st, lit("boolean", false), r)
			return { r }
		end)
	end)
end)

-- An UN-substituted param leaf, if it ever reached a CMatchEval, would have an
-- un-rigid head and STICK.  This fixture confirms both interpreters agree that a
-- match parked on a still-uvar scrutinee errors identically — the safety floor
-- behind the "subst_params must eliminate every TParam before emission" rule
-- (here the scrutinee is a bare unbound uvar standing in for an unsubstituted
-- position).
T.describe("indep parity: 2.4.5 — unrigid scrutinee sticks identically", function()
	T.it("CMatchEval over an unbound uvar scrutinee is stuck in both", function()
		run_both("inst_unrigid_stuck", function(st)
			local s = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			emit_match1(st, types_mod.uvar(s), lit("boolean", true), k("string"), r)
			return { r }
		end)
	end)
end)

-- Parked-then-woken: the scrutinee uvar is later bound to a rigid literal via a
-- CEq, which rigidifies the head and wakes the parked CMatchEval (T-CMatchEval-
-- Wake) — modelling a call site whose argument type is solved AFTER the match is
-- lowered.  Both interpreters must reduce to the same arm result.
T.describe("indep parity: 2.4.5 — park-then-wake on solved arg", function()
	T.it("scrutinee uvar bound to `true` later → reduces to string in both", function()
		run_both("inst_park_wake", function(st)
			local s = subst_mod.fresh(st.subst, "open")
			local r = subst_mod.fresh(st.subst, "open")
			local us = types_mod.uvar(s) --[[: V5Type ]]
			local tru = lit("boolean", true) --[[: V5Type ]]
			emit_match1(st, us, tru, k("string"), r)
			-- Solve the scrutinee AFTER emitting the match (order-independent).
			op_sem.emit(st, C.eq(us, tru, prov("solve-arg")))
			return { r, s }
		end)
	end)
end)

return true
