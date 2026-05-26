-- lib/type/static-v5/op_sem_bounds_test.lua
-- Tests for Phase 5.F4 — uvar bounds tracking + meet-at-quiescence.
--
-- Prior to 5.F4, a stuck CSub(uvar, concrete) at quiescence silently
-- became CEq(uvar, concrete) — multiple incompatible upper bounds on the
-- same uvar collapsed to "whichever happened to be processed", hiding
-- bugs.  Now: bounds accumulate, and at quiescence the uvar binds to
-- the intersection of accumulated upper bounds (with lower bounds
-- re-verified via CSub).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T              = require("lib.test.assert")
local types_mod      = require("lib.type.experiments.v5_perf.types")
local subst_mod      = require("lib.type.experiments.v5_perf.subst")
local constraint_mod = require("lib.type.experiments.v5_perf.constraint")
local op_sem         = require("lib.type.static-v5.op_sem")

local _ = subst_mod

--: (string) -> Provenance
local function prov(name) return op_sem.prov("bounds_fixture", 1, name) end

T.describe("op_sem 5.F4: single upper bound — parity with prior behavior", function()
	T.it("CSub(?u, integer) at quiescence binds ?u := integer", function()
		local st = op_sem.new_state()
		local u = subst_mod.fresh(st.subst, "open")
		local int_ty = types_mod.const("integer") --[[: V5Type ]]
		local uu = types_mod.uvar(u) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(uu, int_ty, prov("u<:int")))
		op_sem.run(st)
		local resolved = op_sem.resolve(st, u)
		T.ok(types_mod.equal(resolved, int_ty), "resolved to integer")
		T.eq(op_sem.error_count(st), 0, "no errors")
	end)
end)

T.describe("op_sem 5.F4: two identical upper bounds — dedup", function()
	T.it("CSub(?u, integer) + CSub(?u, integer) binds ?u := integer", function()
		local st = op_sem.new_state()
		local u = subst_mod.fresh(st.subst, "open")
		local int_ty = types_mod.const("integer") --[[: V5Type ]]
		local uu1 = types_mod.uvar(u) --[[: V5Type ]]
		local uu2 = types_mod.uvar(u) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(uu1, int_ty, prov("u<:int#1")))
		op_sem.emit(st, constraint_mod.sub(uu2, int_ty, prov("u<:int#2")))
		op_sem.run(st)
		local resolved = op_sem.resolve(st, u)
		T.ok(types_mod.equal(resolved, int_ty), "resolved to integer (dedup)")
		T.eq(op_sem.error_count(st), 0, "no errors")
	end)
end)

T.describe("op_sem 5.F4: two distinct upper bounds — meet via intersection", function()
	T.it("CSub(?u, integer) + CSub(?u, string) binds ?u := integer ∩ string", function()
		local st = op_sem.new_state()
		local u = subst_mod.fresh(st.subst, "open")
		local int_ty = types_mod.const("integer") --[[: V5Type ]]
		local str_ty = types_mod.const("string") --[[: V5Type ]]
		local uu1 = types_mod.uvar(u) --[[: V5Type ]]
		local uu2 = types_mod.uvar(u) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(uu1, int_ty, prov("u<:int")))
		op_sem.emit(st, constraint_mod.sub(uu2, str_ty, prov("u<:string")))
		op_sem.run(st)
		local resolved = op_sem.resolve(st, u)
		-- Resolution is an intersection (set of two consts).  Either order
		-- is acceptable since intersections are commutative — accept any
		-- intersection containing both consts.
		T.eq(resolved.tag, "intersection", "resolved to intersection")
		if resolved.tag == "intersection" then
			local parts = resolved.parts
			T.eq(#parts, 2, "two parts after canonicalization")
			local saw_int, saw_str = false, false
			for i = 1, #parts do
				local p = parts[i]
				if p ~= nil and types_mod.equal(p, int_ty) then saw_int = true end
				if p ~= nil and types_mod.equal(p, str_ty) then saw_str = true end
			end
			T.ok(saw_int and saw_str, "intersection contains both integer and string")
		end
		T.eq(op_sem.error_count(st), 0, "binding itself produces no errors")
	end)
end)

T.describe("op_sem 5.F4: incompatible lower vs upper bound surfaces error", function()
	T.it("CSub(integer, ?u) + CSub(?u, string) errors at quiescence", function()
		local st = op_sem.new_state()
		local u = subst_mod.fresh(st.subst, "open")
		local int_ty = types_mod.const("integer") --[[: V5Type ]]
		local str_ty = types_mod.const("string") --[[: V5Type ]]
		local uu1 = types_mod.uvar(u) --[[: V5Type ]]
		local uu2 = types_mod.uvar(u) --[[: V5Type ]]
		-- Lower-bound direction (concrete <: uvar) routes through CEq today,
		-- binding ?u := integer; then the upper-bound CSub(integer, string)
		-- fails via T-CSub-Const-Var (kind mismatch).
		op_sem.emit(st, constraint_mod.sub(int_ty, uu1, prov("int<:u")))
		op_sem.emit(st, constraint_mod.sub(uu2, str_ty, prov("u<:string")))
		op_sem.run(st)
		T.ok(op_sem.error_count(st) > 0, "conflict surfaces as error")
	end)
end)

T.describe("op_sem 5.F4: compatible lower vs upper bound — no error", function()
	T.it("CSub(integer, ?u) + CSub(?u, integer) succeeds", function()
		local st = op_sem.new_state()
		local u = subst_mod.fresh(st.subst, "open")
		local int_ty = types_mod.const("integer") --[[: V5Type ]]
		local uu1 = types_mod.uvar(u) --[[: V5Type ]]
		local uu2 = types_mod.uvar(u) --[[: V5Type ]]
		op_sem.emit(st, constraint_mod.sub(int_ty, uu1, prov("int<:u")))
		op_sem.emit(st, constraint_mod.sub(uu2, int_ty, prov("u<:int")))
		op_sem.run(st)
		local resolved = op_sem.resolve(st, u)
		T.ok(types_mod.equal(resolved, int_ty), "resolved to integer")
		T.eq(op_sem.error_count(st), 0, "no errors")
	end)
end)
