-- lib/fp/functor/functor_test.lua
-- Tests for the Functor typeclass dispatch via Maybe instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local arb     = require("lib.test.arb")
local Functor = require("lib.fp.functor")
local Maybe   = require("lib.fp.maybe")

local function id(x) return x end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

T.describe("Functor.map dispatch", function()
	T.it("maps Just via Functor", function()
		local r = Functor.map(function(x) return x + 1 end, Maybe.just(4))
		T.eq(r.value, 5)
	end)

	T.it("maps Nothing via Functor returns Nothing singleton", function()
		local r = Functor.map(function(x) return x + 1 end, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Functor laws ──────────────────────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

T.describe("Functor identity law (Just)", function()
	arb.it("map(id, Just(x)).value == x", int_arb, function(n)
		local fa = Maybe.just(n)
		local r  = Functor.map(id, fa)
		return r.value == fa.value
	end)
end)

T.describe("Functor identity law (Nothing)", function()
	T.it("map(id, Nothing) == Nothing", function()
		T.eq(Functor.map(id, Maybe.nothing), Maybe.nothing)
	end)
end)

T.describe("Functor composition law (Just)", function()
	arb.it("map(f∘g, Just(x)) == map(f, map(g, Just(x)))", int_arb, function(n)
		local fa = Maybe.just(n)
		local f  = function(x) return x * 2 end
		local g  = function(x) return x + 3 end
		local lhs = Functor.map(function(x) return f(g(x)) end, fa)
		local rhs = Functor.map(f, Functor.map(g, fa))
		return lhs.value == rhs.value
	end)
end)

T.describe("Functor composition law (Nothing)", function()
	T.it("map(f∘g, Nothing) == map(f, map(g, Nothing))", function()
		local f = function(x) return x * 2 end
		local g = function(x) return x + 3 end
		local lhs = Functor.map(function(x) return f(g(x)) end, Maybe.nothing)
		local rhs = Functor.map(f, Functor.map(g, Maybe.nothing))
		T.eq(lhs, rhs)
	end)
end)
