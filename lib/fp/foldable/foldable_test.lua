-- lib/fp/foldable/foldable_test.lua
-- Tests for the Foldable typeclass and Maybe Foldable instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local arb      = require("lib.test.arb")
local Foldable = require("lib.fp.foldable")
local Maybe    = require("lib.fp.maybe")
local Sum      = require("lib.fp.sum")

-- ── foldr on Just ─────────────────────────────────────────────────────────────

T.describe("Foldable.foldr on Just", function()
	T.it("applies f to inner value and accumulator", function()
		local r = Foldable.foldr(function(a, b) return a + b end, 10, Maybe.just(5))
		T.eq(r, 15)
	end)

	T.it("foldr with string concat", function()
		local r = Foldable.foldr(function(a, b) return a .. b end, "world", Maybe.just("hello "))
		T.eq(r, "hello world")
	end)
end)

-- ── foldr on Nothing ──────────────────────────────────────────────────────────

T.describe("Foldable.foldr on Nothing", function()
	T.it("returns z unchanged", function()
		local r = Foldable.foldr(function(a, b) return a + b end, 42, Maybe.nothing)
		T.eq(r, 42)
	end)

	T.it("returns z even when f would error if called", function()
		local r = Foldable.foldr(function(_a, _b) error("should not be called") end, 99, Maybe.nothing)
		T.eq(r, 99)
	end)
end)

-- ── foldMap on Just ───────────────────────────────────────────────────────────

T.describe("Foldable.foldMap on Just", function()
	T.it("applies f to the inner value", function()
		local r = Foldable.foldMap(function(x) return Sum(x.value * 2) end, Maybe.just(Sum(3)))
		T.eq(r.value, 6)
	end)

	T.it("foldMap returns f(a) directly", function()
		local r = Foldable.foldMap(function(x) return x end, Maybe.just(Sum(3)))
		T.eq(r.value, 3)
	end)
end)

-- ── foldMap on Nothing errors ─────────────────────────────────────────────────

T.describe("Foldable.foldMap on Nothing", function()
	T.it("errors with a clear message", function()
		T.throws(function()
			Foldable.foldMap(function(x) return x end, Maybe.nothing)
		end)
	end)
end)

-- ── fold on Just ──────────────────────────────────────────────────────────────

T.describe("Foldable.fold on Just", function()
	T.it("returns the inner Monoid value", function()
		local r = Foldable.fold(Maybe.just(Sum(5)))
		T.eq(r.value, 5)
	end)

	T.it("fold of Just(Nothing) returns Nothing", function()
		local r = Foldable.fold(Maybe.just(Maybe.nothing))
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── fold on Nothing errors ────────────────────────────────────────────────────

T.describe("Foldable.fold on Nothing", function()
	T.it("errors with a clear message", function()
		T.throws(function()
			Foldable.fold(Maybe.nothing)
		end)
	end)
end)

-- ── Property tests ────────────────────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

T.describe("Foldable.foldr on Just: property", function()
	arb.it("foldr(f, z, Just(a)) == f(a, z)", int_arb, function(n)
		local f = function(a, b) return a * 2 + b end
		local z = 7
		local lhs = Foldable.foldr(f, z, Maybe.just(n))
		local rhs = f(n, z)
		return lhs == rhs
	end)
end)

T.describe("Foldable.foldr on Nothing: property", function()
	arb.it("foldr(f, z, Nothing) == z", int_arb, function(n)
		local f = function(a, b) return a + b end
		local lhs = Foldable.foldr(f, n, Maybe.nothing)
		return lhs == n
	end)
end)
