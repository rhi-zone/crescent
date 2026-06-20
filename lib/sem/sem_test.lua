-- lib/sem/sem_test.lua
-- Unit tests for the S1 primitive-decomposed semantics: value algebra, partial
-- primitives (faults-as-stuck), and end-to-end lower→run observations. The
-- differential Loop-α harness lives in lib/sem/diff/alpha_test.lua.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local value   = require("lib.sem.value")
local config  = require("lib.sem.config")
local prim    = require("lib.sem.prim")
local lower   = require("lib.sem.lang.lua.lower")
local run     = require("lib.sem.run")
local profile = require("lib.sem.profile")
local observe = require("lib.sem.diff.observe")

--:: require "lib.sem.value"
--:: require "lib.sem.config"
--:: require "lib.sem.lang.lua.lower"
--:: require "lib.sem.diff.observe"
--:: require "lib.sem.run"

local va = value.luajit51

-- helper: run a surface program and observe it.
--: (SS[]) -> Observation
local function obs_of(prog)
	local control = lower.lower_program(va, prog) --: Stmt[]
	local res = run.run(profile.luajit51, control, 100000) --: RunResult
	return observe.observe_spec(va, res)
end

T.describe("sem value algebra", function()
	T.it("kind_of distinguishes the six value kinds", function()
		T.eq(va.kind_of(va.nil_v), "nil")
		T.eq(va.kind_of(va.bool(true)), "boolean")
		T.eq(va.kind_of(va.number(1)), "number")
		T.eq(va.kind_of(va.string("x")), "string")
		T.eq(va.kind_of(va.table_ref(1)), "table")
		T.eq(va.kind_of(va.closure(1)), "closure")
	end)

	T.it("truthiness: only nil and false are falsy", function()
		T.eq(va.truthy(va.nil_v), false)
		T.eq(va.truthy(va.bool(false)), false)
		T.eq(va.truthy(va.bool(true)), true)
		T.eq(va.truthy(va.number(0)), true)   -- 0 is truthy in Lua
		T.eq(va.truthy(va.string("")), true)
	end)

	T.it("equality: scalars by value, references by address", function()
		T.ok(va.equal(va.number(3), va.number(3)))
		T.fail(va.equal(va.number(3), va.number(4)))
		T.ok(va.equal(va.string("a"), va.string("a")))
		T.ok(va.equal(va.table_ref(7), va.table_ref(7)))
		T.fail(va.equal(va.table_ref(7), va.table_ref(8)))
		T.fail(va.equal(va.number(1), va.string("1")))
	end)
end)

T.describe("sem primitives (partiality = faults-as-stuck)", function()
	--: () -> PrimEnv
	local function fresh_env()
		return { va = va, store = config.new_store(), arith_ops = profile.luajit51.arith_ops }
	end

	T.it("arithmetic on non-numbers faults", function()
		local env = fresh_env()
		local r, f = prim.prim_arith(env, "add", va.number(1), va.string("x"))
		T.eq(r, nil)
		T.ok(f ~= nil and f.class == config.FAULT_ARITH)
	end)

	T.it("arithmetic on numbers succeeds", function()
		local env = fresh_env()
		local r, f = prim.prim_arith(env, "mul", va.number(6), va.number(7))
		T.eq(f, nil)
		T.ok(r ~= nil and va.kind_of(r) == "number" and va.number_value(r) == 42)
	end)

	T.it("indexing a non-table faults", function()
		local env = fresh_env()
		local r, f = prim.raw_get(env, va.number(1), va.number(1))
		T.eq(r, nil)
		T.ok(f ~= nil and f.class == config.FAULT_INDEX_NIL)
	end)

	T.it("raw_get of an absent key returns the nil-VALUE (not a fault)", function()
		local env = fresh_env()
		local t = prim.alloc_table(env)
		local r, f = prim.raw_get(env, t, va.string("missing"))
		T.eq(f, nil)
		T.ok(r ~= nil and va.kind_of(r) == "nil")
	end)

	T.it("raw_set then raw_get round-trips", function()
		local env = fresh_env()
		local t = prim.alloc_table(env)
		local _ok, sf = prim.raw_set(env, t, va.string("k"), va.number(99))
		T.eq(sf, nil)
		local r = prim.raw_get(env, t, va.string("k"))
		T.ok(r ~= nil and va.kind_of(r) == "number" and va.number_value(r) == 99)
	end)

	T.it("table index nil on WRITE faults; on READ reads nil", function()
		local env = fresh_env()
		local t = prim.alloc_table(env)
		local _ok, wf = prim.raw_set(env, t, va.nil_v, va.number(1))
		T.eq(_ok, nil)
		T.ok(wf ~= nil and wf.class == config.FAULT_KEY_NIL)
		local r = prim.raw_get(env, t, va.nil_v)
		T.ok(r ~= nil and va.kind_of(r) == "nil")
	end)

	T.it("comparison <: numbers and strings ok, mixed faults", function()
		local env = fresh_env()
		local r1 = prim.prim_compare(env, "lt", va.number(1), va.number(2))
		T.ok(r1 ~= nil and va.bool_value(r1) == true)
		local _r2, f = prim.prim_compare(env, "lt", va.number(1), va.string("a"))
		T.ok(f ~= nil and f.class == config.FAULT_COMPARE)
	end)

	T.it("concat: string/number ok, other kinds fault", function()
		local env = fresh_env()
		local r = prim.prim_concat(env, va.string("a"), va.number(2))
		T.ok(r ~= nil and va.kind_of(r) == "string" and va.string_value(r) == "a2")
		local _r2, f = prim.prim_concat(env, va.string("a"), va.bool(true))
		T.ok(f ~= nil and f.class == config.FAULT_CONCAT)
	end)
end)

T.describe("sem end-to-end (lower -> run -> observe)", function()
	-- num literal helper for surface ASTs.
	--: (number) -> SX
	local function n(x)
		local e = { x = "num", n = x } --[[: SX]]
		return e
	end

	T.it("arithmetic program returns the value tuple", function()
		-- local a = 2 + 3; return a, a * a
		local prog = {
			{ s = "local", names = { "a" }, exprs = {
				{ x = "binop", op = "add", a = n(2), b = n(3) } } },
			{ s = "return", exprs = {
				{ x = "name", name = "a" },
				{ x = "binop", op = "mul", a = { x = "name", name = "a" }, b = { x = "name", name = "a" } } } },
		} --[[: SS[] ]]
		local o = obs_of(prog)
		T.eq(o.tag, "value")
		T.eq(o.shape, "n:5,n:25")
	end)

	T.it("a runtime fault is observed as a fault", function()
		-- return 1 + "x"  (arith on non-number)
		local prog = {
			{ s = "return", exprs = {
				{ x = "binop", op = "add", a = n(1), b = { x = "str", s = "x" } } } },
		} --[[: SS[] ]]
		local o = obs_of(prog)
		T.eq(o.tag, "fault")
	end)

	T.it("closure with multi-return + vararg", function()
		-- return (function(x, ...) return x, ... end)(10, 20, 30)
		local prog = {
			{ s = "return", exprs = {
				{ x = "call",
					fn = { x = "func", params = { "x" }, vararg = true, body = {
						{ s = "return", exprs = { { x = "name", name = "x" }, { x = "vararg" } } } } },
					args = { n(10), n(20), n(30) } } } },
		} --[[: SS[] ]]
		local o = obs_of(prog)
		T.eq(o.tag, "value")
		T.eq(o.shape, "n:10,n:20,n:30")
	end)

	T.it("while loop accumulates", function()
		-- local i=0; local s=0; while i < 5 do s = s + i; i = i + 1 end; return s
		local prog = {
			{ s = "local", names = { "i" }, exprs = { n(0) } },
			{ s = "local", names = { "s" }, exprs = { n(0) } },
			{ s = "while",
				cond = { x = "binop", op = "lt", a = { x = "name", name = "i" }, b = n(5) },
				body = {
					{ s = "assign", name = "s", expr = { x = "binop", op = "add", a = { x = "name", name = "s" }, b = { x = "name", name = "i" } } },
					{ s = "assign", name = "i", expr = { x = "binop", op = "add", a = { x = "name", name = "i" }, b = n(1) } },
				} },
			{ s = "return", exprs = { { x = "name", name = "s" } } },
		} --[[: SS[] ]]
		local o = obs_of(prog)
		T.eq(o.tag, "value")
		T.eq(o.shape, "n:10")   -- 0+1+2+3+4
	end)

	T.it("table construct + index", function()
		-- local t = {7, 8, 9}; return t[2]
		local prog = {
			{ s = "local", names = { "t" }, exprs = {
				{ x = "table", items = { n(7), n(8), n(9) } } } },
			{ s = "return", exprs = {
				{ x = "index", obj = { x = "name", name = "t" }, key = n(2) } } },
		} --[[: SS[] ]]
		local o = obs_of(prog)
		T.eq(o.tag, "value")
		T.eq(o.shape, "n:8")
	end)
end)
