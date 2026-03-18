-- lib/fp/maybe/maybe_test.lua
-- Tests for Maybe: constructors, Mappable, Semigroup, Monoid instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local arb       = require("lib.test.arb")
local Mappable  = require("lib.fp.mappable")
local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")
local Maybe     = require("lib.fp.maybe")
local Sum       = require("lib.fp.sum")

local function id(x) return x end

-- ── Constructors and predicates ───────────────────────────────────────────────

T.describe("Maybe constructors", function()
	T.it("just wraps a value", function()
		local m = Maybe.just(42)
		T.eq(m.value, 42)
	end)

	T.it("nothing is a singleton", function()
		T.eq(Maybe.nothing, Maybe.nothing)
	end)

	T.it("is_just returns true for Just", function()
		T.ok(Maybe.is_just(Maybe.just(1)))
	end)

	T.it("is_just returns false for Nothing", function()
		T.ok(not Maybe.is_just(Maybe.nothing))
	end)

	T.it("is_nothing returns true for Nothing", function()
		T.ok(Maybe.is_nothing(Maybe.nothing))
	end)

	T.it("is_nothing returns false for Just", function()
		T.ok(not Maybe.is_nothing(Maybe.just(1)))
	end)
end)

-- ── Eliminators ───────────────────────────────────────────────────────────────

T.describe("Maybe.from_maybe", function()
	T.it("returns value for Just", function()
		T.eq(Maybe.from_maybe(0, Maybe.just(5)), 5)
	end)

	T.it("returns default for Nothing", function()
		T.eq(Maybe.from_maybe(0, Maybe.nothing), 0)
	end)
end)

T.describe("Maybe.from_just", function()
	T.it("returns value for Just", function()
		T.eq(Maybe.from_just(Maybe.just(7)), 7)
	end)

	T.it("errors on Nothing", function()
		T.throws(function() Maybe.from_just(Maybe.nothing) end)
	end)
end)

-- ── tostring ──────────────────────────────────────────────────────────────────

T.describe("Maybe tostring", function()
	T.it("Just tostring", function()
		T.eq(tostring(Maybe.just(3)), "Just(3)")
	end)

	T.it("Nothing tostring", function()
		T.eq(tostring(Maybe.nothing), "Nothing")
	end)
end)

-- ── Mappable ──────────────────────────────────────────────────────────────────

T.describe("Maybe Mappable", function()
	T.it("map over Just applies f", function()
		local r = Mappable.map(function(x) return x * 2 end, Maybe.just(5))
		T.eq(r.value, 10)
	end)

	T.it("map over Nothing returns Nothing singleton", function()
		local r = Mappable.map(function(x) return x * 2 end, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)

	T.it("identity law: map(id, Just(x)) == Just(x)", function()
		local m = Maybe.just(99)
		T.eq(Mappable.map(id, m).value, m.value)
	end)

	T.it("identity law: map(id, Nothing) == Nothing", function()
		T.eq(Mappable.map(id, Maybe.nothing), Maybe.nothing)
	end)

	T.it("composition law (Just)", function()
		local f = function(x) return x + 1 end
		local g = function(x) return x * 3 end
		local m = Maybe.just(4)
		local lhs = Mappable.map(function(x) return f(g(x)) end, m)
		local rhs = Mappable.map(f, Mappable.map(g, m))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("composition law (Nothing)", function()
		local f = function(x) return x + 1 end
		local g = function(x) return x * 3 end
		local lhs = Mappable.map(function(x) return f(g(x)) end, Maybe.nothing)
		local rhs = Mappable.map(f, Mappable.map(g, Maybe.nothing))
		T.eq(lhs, rhs)
	end)
end)

-- ── Semigroup ─────────────────────────────────────────────────────────────────

T.describe("Maybe Semigroup", function()
	T.it("Nothing <> Just(x) == Just(x)", function()
		local r = Semigroup.append(Maybe.nothing, Maybe.just(Sum(5)))
		T.eq(r.value.value, 5)
	end)

	T.it("Just(x) <> Nothing == Just(x)", function()
		local r = Semigroup.append(Maybe.just(Sum(5)), Maybe.nothing)
		T.eq(r.value.value, 5)
	end)

	T.it("Just(a) <> Just(b) == Just(a <> b)", function()
		local r = Semigroup.append(Maybe.just(Sum(3)), Maybe.just(Sum(4)))
		T.eq(r.value.value, 7)
	end)

	T.it("Nothing <> Nothing == Nothing", function()
		local r = Semigroup.append(Maybe.nothing, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Monoid ────────────────────────────────────────────────────────────────────

T.describe("Maybe Monoid", function()
	T.it("empty is Nothing (via Just)", function()
		local e = Monoid.empty(Maybe.just(Sum(1)))
		T.eq(e, Maybe.nothing)
	end)

	T.it("empty is Nothing (via Nothing)", function()
		local e = Monoid.empty(Maybe.nothing)
		T.eq(e, Maybe.nothing)
	end)

	T.it("left identity: Nothing <> Just(x) == Just(x)", function()
		local r = Semigroup.append(Monoid.empty(Maybe.just(Sum(1))), Maybe.just(Sum(9)))
		T.eq(r.value.value, 9)
	end)

	T.it("right identity: Just(x) <> Nothing == Just(x)", function()
		local r = Semigroup.append(Maybe.just(Sum(9)), Monoid.empty(Maybe.just(Sum(1))))
		T.eq(r.value.value, 9)
	end)
end)

-- ── Property tests ────────────────────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

T.describe("Maybe Mappable property: identity law", function()
	arb.it("map(id, Just(x)).value == x", int_arb, function(n)
		local fa = Maybe.just(n)
		local r  = Mappable.map(id, fa)
		return r.value == n
	end)
end)

T.describe("Maybe Mappable property: composition law", function()
	arb.it("map(f∘g, Just(x)) == map(f, map(g, Just(x)))", int_arb, function(n)
		local fa = Maybe.just(n)
		local f  = function(x) return x + 7 end
		local g  = function(x) return x * 2 end
		local lhs = Mappable.map(function(x) return f(g(x)) end, fa)
		local rhs = Mappable.map(f, Mappable.map(g, fa))
		return lhs.value == rhs.value
	end)
end)
