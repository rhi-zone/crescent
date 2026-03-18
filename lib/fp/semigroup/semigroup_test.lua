-- lib/fp/semigroup/semigroup_test.lua
-- Tests for the Semigroup typeclass and its instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local arb       = require("lib.test.arb")
local Semigroup = require("lib.fp.semigroup")
local First     = require("lib.fp.first")
local Last      = require("lib.fp.last")
local Sum       = require("lib.fp.sum")
local Product   = require("lib.fp.product")
local Min       = require("lib.fp.min")
local Max       = require("lib.fp.max")

-- ── Dispatch ──────────────────────────────────────────────────────────────────

T.describe("Semigroup dispatch", function()
	T.it("dispatches to First instance", function()
		local a = First(1)
		local b = First(2)
		local r = Semigroup.append(a, b)
		T.eq(r.value, 1)
	end)

	T.it("dispatches to Last instance", function()
		local a = Last(1)
		local b = Last(2)
		local r = Semigroup.append(a, b)
		T.eq(r.value, 2)
	end)

	T.it("dispatches to Sum instance", function()
		local r = Semigroup.append(Sum(3), Sum(4))
		T.eq(r.value, 7)
	end)

	T.it("dispatches to Product instance", function()
		local r = Semigroup.append(Product(3), Product(4))
		T.eq(r.value, 12)
	end)

	T.it("dispatches to Min instance", function()
		local r = Semigroup.append(Min(3), Min(5))
		T.eq(r.value, 3)
	end)

	T.it("dispatches to Max instance", function()
		local r = Semigroup.append(Max(3), Max(5))
		T.eq(r.value, 5)
	end)
end)

-- ── Unit tests ────────────────────────────────────────────────────────────────

T.describe("First", function()
	T.it("append returns left argument", function()
		local a = First(10)
		local b = First(20)
		local r = Semigroup.append(a, b)
		T.eq(r.value, a.value)
	end)

	T.it("tostring", function()
		T.eq(tostring(First(42)), "First(42)")
	end)
end)

T.describe("Last", function()
	T.it("append returns right argument", function()
		local a = Last(10)
		local b = Last(20)
		local r = Semigroup.append(a, b)
		T.eq(r.value, b.value)
	end)

	T.it("tostring", function()
		T.eq(tostring(Last(7)), "Last(7)")
	end)
end)

T.describe("Sum", function()
	T.it("append adds values", function()
		T.eq(Semigroup.append(Sum(1), Sum(2)).value, 3)
	end)

	T.it("tostring", function()
		T.eq(tostring(Sum(5)), "Sum(5)")
	end)
end)

T.describe("Product", function()
	T.it("append multiplies values", function()
		T.eq(Semigroup.append(Product(2), Product(3)).value, 6)
	end)

	T.it("tostring", function()
		T.eq(tostring(Product(4)), "Product(4)")
	end)
end)

T.describe("Min", function()
	T.it("append returns minimum", function()
		T.eq(Semigroup.append(Min(3), Min(5)).value, 3)
		T.eq(Semigroup.append(Min(5), Min(3)).value, 3)
	end)

	T.it("tostring", function()
		T.eq(tostring(Min(2)), "Min(2)")
	end)
end)

T.describe("Max", function()
	T.it("append returns maximum", function()
		T.eq(Semigroup.append(Max(3), Max(5)).value, 5)
		T.eq(Semigroup.append(Max(5), Max(3)).value, 5)
	end)

	T.it("tostring", function()
		T.eq(tostring(Max(9)), "Max(9)")
	end)
end)

-- ── Associativity property tests ──────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

T.describe("Semigroup associativity", function()
	arb.it("Sum: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = Sum(vals[1]), Sum(vals[2]), Sum(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)

	arb.it("Product: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = Product(vals[1]), Product(vals[2]), Product(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)

	arb.it("Min: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = Min(vals[1]), Min(vals[2]), Min(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)

	arb.it("Max: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = Max(vals[1]), Max(vals[2]), Max(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)

	arb.it("First: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = First(vals[1]), First(vals[2]), First(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)

	arb.it("Last: (a <> b) <> c == a <> (b <> c)", arb.tuple({int_arb, int_arb, int_arb}),
		function(vals)
			local a, b, c = Last(vals[1]), Last(vals[2]), Last(vals[3])
			local lhs = Semigroup.append(Semigroup.append(a, b), c)
			local rhs = Semigroup.append(a, Semigroup.append(b, c))
			return lhs.value == rhs.value
		end)
end)
