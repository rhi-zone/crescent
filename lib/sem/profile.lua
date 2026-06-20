-- lib/sem/profile.lua
-- The Profile record. A Profile is (desugar, value-algebra, enabled-rule-set,
-- typing-delta) per docs/typechecker-formal-semantics.md §3 — version AND
-- language are the SAME parameter type. A version delta is DATA (a different
-- number model, a different enabled-op set), NEVER a branch in the trusted
-- reducer (step.lua / prim.lua mention no version).
--
-- S2 ships five profiles spanning two number models:
--   * single-double model: luajit51, lua51, lua52
--   * dual integer/float model: lua53, lua54
-- The proving case is the 5.3/5.4 int/float split: it is expressed PURELY as a
-- different value-algebra `va` plus the `idiv` op enabled in `arith_ops`. No
-- step/prim code knows which model it is running.
--
-- ENABLED-RULE-SET: `arith_ops` is the set of arithmetic ops the profile's
-- language accepts. `//` (idiv) is a SYNTAX in LuaJIT and 5.3/5.4 but a syntax
-- error in PUC 5.1/5.2 — so those profiles omit it from `arith_ops`, and prim
-- treats an `idiv` term as stuck (no rule) under them, with no version branch.
--
-- The desugar/typing-delta fields are forward slots (S4 language profiles, S3
-- typing deltas); S2 leaves them implicit (the lowering is shared).

local value = require("lib.sem.value")

--:: require "lib.sem.value"

local M = {}

--:: Profile = { name: string, version: string, va: ValueAlgebra, arith_ops: { [string]: boolean } }

-- Build an arithmetic op-set from a list of enabled op names. Each profile picks
-- the names its language accepts; `//` ("idiv") is only listed for profiles whose
-- language accepts it. The result is an index-signature set, consumed generically
-- by prim (no op name is special-cased in the reducer).
--: (string[]) -> { [string]: boolean }
local function ops(names)
	local o = {} --[[: { [string]: boolean }]]
	for i = 1, #names do
		local nm = names[i]
		if nm ~= nil then o[nm] = true end
	end
	return o
end

local BASE = { "add", "sub", "mul", "div", "mod", "pow" } --[[: string[] ]]
local WITH_IDIV = { "add", "sub", "mul", "div", "mod", "pow", "idiv" } --[[: string[] ]]

-- ── single-double profiles ───────────────────────────────────────────────────
-- LuaJIT 5.1: one number kind (IEEE double). LuaJIT is a 5.1 language and does
-- NOT implement `//` (it is a 5.3 operator; the vendored LuaJIT parser rejects
-- it as a syntax error), so idiv is OMITTED — same op-set as PUC 5.1. (This is a
-- real cross-version fact, verified against the vendored bin/luajit.)
M.luajit51 = {
	name = "luajit51", version = "luajit-5.1",
	va = value.single_double, arith_ops = ops(BASE),
} --[[: Profile]]

-- PUC 5.1: one number kind; NO `//` operator (syntax error) → idiv omitted.
M.lua51 = {
	name = "lua51", version = "5.1",
	va = value.single_double, arith_ops = ops(BASE),
} --[[: Profile]]

-- PUC 5.2: one number kind; NO `//` operator → idiv omitted.
M.lua52 = {
	name = "lua52", version = "5.2",
	va = value.single_double, arith_ops = ops(BASE),
} --[[: Profile]]

-- ── dual integer/float profiles ──────────────────────────────────────────────
-- PUC 5.3: integer/float split (the proving delta); `//` floor-division enabled.
M.lua53 = {
	name = "lua53", version = "5.3",
	va = value.dual_intfloat, arith_ops = ops(WITH_IDIV),
} --[[: Profile]]

-- PUC 5.4: integer/float split (same model as 5.3 for the S2 fragment).
M.lua54 = {
	name = "lua54", version = "5.4",
	va = value.dual_intfloat, arith_ops = ops(WITH_IDIV),
} --[[: Profile]]

-- the full ordered list, for harnesses that iterate every profile.
M.all = { M.luajit51, M.lua51, M.lua52, M.lua53, M.lua54 } --[[: Profile[] ]]

return M
