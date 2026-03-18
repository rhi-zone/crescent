-- lib/fp/fn/fn_test.lua
-- Tests for Fn wrapper: constructor, __call transparency, and typeclass instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Chainable  = require("lib.fp.chainable")
local Fn         = require("lib.fp.fn")

-- ── Constructor and __call ─────────────────────────────────────────────────────

T.describe("Fn constructor", function()
	T.it("Fn wraps a function", function()
		local f = function(x) return x + 1 end
		local wrapped = Fn(f)
		T.ok(type(wrapped) == "table")
		T.ok(wrapped._fn == f)
	end)

	T.it("Fn(f) sugar calls Fn.new(f)", function()
		local f = function(x) return x * 2 end
		local a = Fn(f)
		local b = Fn.new(f)
		T.ok(a._fn == b._fn)
	end)

	T.it("__call makes Fn transparent — single arg", function()
		local wrapped = Fn(function(x) return x + 10 end)
		T.eq(wrapped(5), 15)
	end)

	T.it("__call makes Fn transparent — multiple args", function()
		local wrapped = Fn(function(x, y) return x + y end)
		T.eq(wrapped(3, 4), 7)
	end)

	T.it("__call makes Fn transparent — no args", function()
		local wrapped = Fn(function() return 42 end)
		T.eq(wrapped(), 42)
	end)

	T.it("tostring includes Fn prefix", function()
		local wrapped = Fn(function() end)
		T.ok(tostring(wrapped):find("Fn(", 1, true) ~= nil)
	end)
end)

-- ── Mappable — function composition ───────────────────────────────────────────

T.describe("Fn Mappable", function()
	T.it("map composes functions: map(h, Fn(g))(x) == h(g(x))", function()
		local g = Fn(function(x) return x * 3 end)
		local h = function(x) return x + 1 end
		local composed = Mappable.map(h, g)
		T.eq(composed(4), 13)   -- h(g(4)) = h(12) = 13
	end)

	T.it("map returns a Fn wrapper", function()
		local g = Fn(function(x) return x end)
		local r = Mappable.map(function(x) return x end, g)
		T.ok(type(r) == "table" and r._fn ~= nil)
	end)

	T.it("identity law: map(id, Fn(g))(x) == g(x)", function()
		local g = Fn(function(x) return x * 5 end)
		local id = function(x) return x end
		local r = Mappable.map(id, g)
		T.eq(r(7), g(7))
	end)

	T.it("composition law: map(h, map(f, Fn(g)))(x) == map(h.f, Fn(g))(x)", function()
		local g = Fn(function(x) return x + 2 end)
		local f = function(x) return x * 4 end
		local h = function(x) return x - 1 end
		local lhs = Mappable.map(h, Mappable.map(f, g))
		local rhs = Mappable.map(function(x) return h(f(x)) end, g)
		T.eq(lhs(10), rhs(10))   -- g(10)=12, f(12)=48, h(48)=47
	end)
end)

-- ── Applicable — S combinator and pure ────────────────────────────────────────

T.describe("Fn Applicable: pure", function()
	T.it("pure creates a constant function", function()
		local const = Applicable.pure(Fn(function() end), 99)
		T.eq(const(1), 99)
		T.eq(const("anything"), 99)
		T.eq(const(), 99)
	end)

	T.it("pure ignores all arguments", function()
		local const = Applicable.pure(Fn(function() end), "hello")
		T.eq(const(1, 2, 3), "hello")
	end)
end)

T.describe("Fn Applicable: ap (S combinator)", function()
	-- ap(Fn(f), Fn(a))(x) = f(x)(a(x))
	T.it("ap applies S combinator: Fn(f) ap Fn(a)", function()
		-- f(x) returns a function that adds x to its argument
		-- a(x) returns x * 2
		-- so ap(Fn(f), Fn(a))(x) = f(x)(a(x)) = (y -> y + x)(x * 2) = x*2 + x = 3x
		local ff = Fn(function(x) return function(y) return y + x end end)
		local fa = Fn(function(x) return x * 2 end)
		local r  = Applicable.ap(ff, fa)
		T.eq(r(5), 15)   -- 5*2 + 5 = 15
		T.eq(r(3), 9)    -- 3*2 + 3 = 9
	end)

	T.it("ap returns a Fn wrapper", function()
		local ff = Fn(function(_x) return function(y) return y end end)
		local fa = Fn(function(x) return x end)
		local r  = Applicable.ap(ff, fa)
		T.ok(type(r) == "table" and r._fn ~= nil)
	end)
end)

-- ── Chainable — reader monad / function monad ─────────────────────────────────

T.describe("Fn Chainable: bind (reader monad)", function()
	-- bind(Fn(f), k)(x) = k(f(x))(x)
	-- k receives the output of f(x), returns a Fn; that Fn is called with x
	T.it("bind threads x to both f and the continuation result", function()
		-- f(x) = x + 1
		-- k(a) = Fn(x -> a * x)  (uses a from f's result, and x from env)
		-- bind(Fn(f), k)(x) = k(f(x))(x) = k(x+1)(x) = (x+1)*x
		local f = Fn(function(x) return x + 1 end)
		local k = function(a) return Fn(function(x) return a * x end) end
		local r = Chainable.bind(f, k)
		T.eq(r(4), 20)   -- (4+1)*4 = 20
		T.eq(r(3), 12)   -- (3+1)*3 = 12
	end)

	T.it("bind returns a Fn wrapper", function()
		local f = Fn(function(x) return x end)
		local k = function(a) return Fn(function(_) return a end) end
		local r = Chainable.bind(f, k)
		T.ok(type(r) == "table" and r._fn ~= nil)
	end)

	T.it("bind with const k behaves like map", function()
		-- When k ignores x: bind(Fn(f), λa. Fn(λ_. g(a)))(x) = g(f(x))
		-- This is essentially map(g, Fn(f))
		local f = Fn(function(x) return x * 2 end)
		local g = function(a) return a + 10 end
		local via_bind = Chainable.bind(f, function(a) return Fn(function(_) return g(a) end) end)
		local via_map  = Mappable.map(g, f)
		T.eq(via_bind(7), via_map(7))   -- g(f(7)) = g(14) = 24
	end)
end)

-- ── Monad laws for Fn ─────────────────────────────────────────────────────────
--
-- For the function monad, pure(a) = Fn(λ_. a)  (constant function ignoring input)
-- All three laws hold pointwise: lhs(x) == rhs(x) for all x.
--
-- Left identity:   bind(pure(a), k)(x)     == k(a)(x)
-- Right identity:  bind(Fn(f), pure . f)(x) == Fn(f)(x)
-- Associativity:   bind(bind(Fn(f), k), h)(x) == bind(Fn(f), λa. bind(k(a), h))(x)

local int_arb = arb.int(-100, 100)

T.describe("Fn monad: left identity", function()
	-- bind(pure(a), k)(x) == k(a)(x)
	-- pure(a) ignores its argument, always returns a.
	-- bind passes a to k, then calls k(a) with x.
	-- k(a)(x) is the direct call.
	arb.it("bind(pure(a), k)(x) == k(a)(x) for int x", int_arb, function(x)
		local a   = 7   -- a fixed value lifted into pure
		local k   = function(v) return Fn(function(env) return v + env end) end
		local lhs = Chainable.bind(Applicable.pure(Fn(function() end), a), k)
		local rhs = k(a)
		return lhs(x) == rhs(x)   -- (a + x) == (a + x)
	end)
end)

T.describe("Fn monad: right identity", function()
	-- bind(Fn(f), λa. pure(a))(x) == Fn(f)(x)
	-- Lifting the result back into pure should be a no-op.
	arb.it("bind(Fn(f), pure)(x) == f(x) for int x", int_arb, function(x)
		local f   = Fn(function(v) return v * 3 end)
		-- pure lifted: takes a, returns Fn(λ_. a)
		local lhs = Chainable.bind(f, function(a)
			return Applicable.pure(Fn(function() end), a)
		end)
		return lhs(x) == f(x)
	end)
end)

T.describe("Fn monad: associativity", function()
	-- bind(bind(Fn(f), k), h)(x) == bind(Fn(f), λa. bind(k(a), h))(x)
	arb.it("bind associativity for int x", int_arb, function(x)
		local f   = Fn(function(v) return v + 1 end)
		local k   = function(a) return Fn(function(env) return a * env end) end
		local h   = function(b) return Fn(function(env) return b - env end) end
		local lhs = Chainable.bind(Chainable.bind(f, k), h)
		local rhs = Chainable.bind(f, function(a)
			return Chainable.bind(k(a), h)
		end)
		return lhs(x) == rhs(x)
	end)
end)
