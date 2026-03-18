-- lib/fp/apply/apply_test.lua
-- Tests for the Apply typeclass dispatch via Maybe instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local arb     = require("lib.test.arb")
local Functor = require("lib.fp.functor")
local Apply   = require("lib.fp.apply")
local Maybe   = require("lib.fp.maybe")

local function compose(f)
	return function(g)
		return function(x)
			return f(g(x))
		end
	end
end

-- ── Dispatch ──────────────────────────────────────────────────────────────────

T.describe("Apply.ap dispatch", function()
	T.it("Just(f) <*> Just(x) applies f to x", function()
		local ff = Maybe.just(function(x) return x + 10 end)
		local fa = Maybe.just(5)
		local r  = Apply.ap(ff, fa)
		T.eq(r.value, 15)
	end)

	T.it("Nothing <*> Just(x) returns Nothing", function()
		local fa = Maybe.just(5)
		local r  = Apply.ap(Maybe.nothing, fa)
		T.eq(r, Maybe.nothing)
	end)

	T.it("Just(f) <*> Nothing returns Nothing", function()
		local ff = Maybe.just(function(x) return x + 10 end)
		local r  = Apply.ap(ff, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)

	T.it("Nothing <*> Nothing returns Nothing", function()
		local r = Apply.ap(Maybe.nothing, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Apply composition law ─────────────────────────────────────────────────────
-- ap(ap(map(compose, u), v), w) == ap(u, ap(v, w))

local int_arb = arb.int(-1000, 1000)

T.describe("Apply composition law (Just)", function()
	arb.it("ap(ap(map(compose, u), v), w) == ap(u, ap(v, w))", int_arb, function(n)
		local u = Maybe.just(function(x) return x * 2 end)
		local v = Maybe.just(function(x) return x + 3 end)
		local w = Maybe.just(n)
		local lhs = Apply.ap(Apply.ap(Functor.map(compose, u), v), w)
		local rhs = Apply.ap(u, Apply.ap(v, w))
		return lhs.value == rhs.value
	end)
end)

T.describe("Apply composition law (Nothing u)", function()
	T.it("ap(ap(map(compose, Nothing), v), w) == ap(Nothing, ap(v, w))", function()
		local v = Maybe.just(function(x) return x + 3 end)
		local w = Maybe.just(42)
		local lhs = Apply.ap(Apply.ap(Functor.map(compose, Maybe.nothing), v), w)
		local rhs = Apply.ap(Maybe.nothing, Apply.ap(v, w))
		T.eq(lhs, rhs)
	end)
end)
