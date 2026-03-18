-- lib/fp/monoid/monoid_test.lua
-- Tests for the Monoid typeclass and its instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local arb       = require("lib.test.arb")
local Semigroup = require("lib.fp.semigroup")
local Monoid    = require("lib.fp.monoid")
local Sum       = require("lib.fp.sum")
local Product   = require("lib.fp.product")
local Min       = require("lib.fp.min")
local Max       = require("lib.fp.max")

-- ── empty dispatch ────────────────────────────────────────────────────────────

T.describe("Monoid.empty dispatch", function()
	T.it("Sum empty is Sum(0)", function()
		local e = Monoid.empty(Sum(1))
		T.eq(e.value, 0)
	end)

	T.it("Product empty is Product(1)", function()
		local e = Monoid.empty(Product(1))
		T.eq(e.value, 1)
	end)

	T.it("Min empty is Min(math.huge)", function()
		local e = Monoid.empty(Min(1))
		T.eq(e.value, math.huge)
	end)

	T.it("Max empty is Max(-math.huge)", function()
		local e = Monoid.empty(Max(1))
		T.eq(e.value, -math.huge)
	end)
end)

-- ── identity laws ─────────────────────────────────────────────────────────────

T.describe("Sum identity laws", function()
	T.it("left identity: empty <> x == x", function()
		local r = Semigroup.append(Monoid.empty(Sum(1)), Sum(5))
		T.eq(r.value, 5)
	end)

	T.it("right identity: x <> empty == x", function()
		local r = Semigroup.append(Sum(5), Monoid.empty(Sum(1)))
		T.eq(r.value, 5)
	end)
end)

T.describe("Product identity laws", function()
	T.it("left identity: empty <> x == x", function()
		local r = Semigroup.append(Monoid.empty(Product(1)), Product(7))
		T.eq(r.value, 7)
	end)

	T.it("right identity: x <> empty == x", function()
		local r = Semigroup.append(Product(7), Monoid.empty(Product(1)))
		T.eq(r.value, 7)
	end)
end)

T.describe("Min identity laws", function()
	T.it("left identity: empty <> x == x", function()
		local r = Semigroup.append(Monoid.empty(Min(1)), Min(42))
		T.eq(r.value, 42)
	end)

	T.it("right identity: x <> empty == x", function()
		local r = Semigroup.append(Min(42), Monoid.empty(Min(1)))
		T.eq(r.value, 42)
	end)
end)

T.describe("Max identity laws", function()
	T.it("left identity: empty <> x == x", function()
		local r = Semigroup.append(Monoid.empty(Max(1)), Max(42))
		T.eq(r.value, 42)
	end)

	T.it("right identity: x <> empty == x", function()
		local r = Semigroup.append(Max(42), Monoid.empty(Max(1)))
		T.eq(r.value, 42)
	end)
end)

-- ── Monoid.fold ───────────────────────────────────────────────────────────────

T.describe("Monoid.fold", function()
	T.it("Sum: fold {1,2,3} == 6", function()
		local r = Monoid.fold({ Sum(1), Sum(2), Sum(3) })
		T.eq(r.value, 6)
	end)

	T.it("Product: fold {2,3,4} == 24", function()
		local r = Monoid.fold({ Product(2), Product(3), Product(4) })
		T.eq(r.value, 24)
	end)

	T.it("Min: fold {5,3,8,1} == 1", function()
		local r = Monoid.fold({ Min(5), Min(3), Min(8), Min(1) })
		T.eq(r.value, 1)
	end)

	T.it("Max: fold {5,3,8,1} == 8", function()
		local r = Monoid.fold({ Max(5), Max(3), Max(8), Max(1) })
		T.eq(r.value, 8)
	end)

	T.it("fold of singleton equals the element", function()
		T.eq(Monoid.fold({ Sum(42) }).value, 42)
	end)

	T.it("errors on empty list", function()
		T.throws(function() Monoid.fold({}) end)
	end)
end)

-- ── Property: fold equals manual left-fold from empty ─────────────────────────

local int_arb  = arb.int(-100, 100)
local list_arb = arb.array(int_arb, { min = 1, max = 8 })  -- non-empty lists

T.describe("Monoid.fold property", function()
	arb.it("Sum: fold(list) == manual left-fold from empty", list_arb, function(ns)
		local wrapped = {}
		for i, n in ipairs(ns) do wrapped[i] = Sum(n) end

		local folded = Monoid.fold(wrapped)

		local acc = Monoid.empty(Sum(0))
		for _, v in ipairs(wrapped) do
			acc = Semigroup.append(acc, v)
		end

		return folded.value == acc.value
	end)

	arb.it("Product: fold(list) == manual left-fold from empty", list_arb, function(ns)
		local wrapped = {}
		for i, n in ipairs(ns) do wrapped[i] = Product(n) end

		local folded = Monoid.fold(wrapped)

		local acc = Monoid.empty(Product(1))
		for _, v in ipairs(wrapped) do
			acc = Semigroup.append(acc, v)
		end

		return folded.value == acc.value
	end)
end)
