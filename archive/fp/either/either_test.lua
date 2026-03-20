-- lib/fp/either/either_test.lua
-- Tests for Either: constructors, predicates, eliminators, Mappable,
-- Applicable, Foldable, Chainable, Semigroup instances, and laws.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Foldable   = require("lib.fp.foldable")
local Semigroup  = require("lib.fp.semigroup")
local Either     = require("lib.fp.either")
local Sum        = require("lib.fp.sum")

local Chainable
do
	local ok, mod = pcall(require, "lib.fp.chainable")
	if ok then Chainable = mod end
end

local function id(x) return x end

-- ── Constructors and predicates ───────────────────────────────────────────────

T.describe("Either constructors", function()
	T.it("left wraps a value", function()
		local e = Either.left("err")
		T.eq(e.value, "err")
	end)

	T.it("right wraps a value", function()
		local e = Either.right(42)
		T.eq(e.value, 42)
	end)

	T.it("is_left returns true for Left", function()
		T.ok(Either.is_left(Either.left("e")))
	end)

	T.it("is_left returns false for Right", function()
		T.ok(not Either.is_left(Either.right(1)))
	end)

	T.it("is_right returns true for Right", function()
		T.ok(Either.is_right(Either.right(1)))
	end)

	T.it("is_right returns false for Left", function()
		T.ok(not Either.is_right(Either.left("e")))
	end)
end)

-- ── Eliminators ───────────────────────────────────────────────────────────────

T.describe("Either.from_right", function()
	T.it("returns value for Right", function()
		T.eq(Either.from_right(Either.right(7)), 7)
	end)

	T.it("errors on Left", function()
		T.throws(function() Either.from_right(Either.left("e")) end)
	end)
end)

T.describe("Either.from_left", function()
	T.it("returns value for Left", function()
		T.eq(Either.from_left(Either.left("e")), "e")
	end)

	T.it("errors on Right", function()
		T.throws(function() Either.from_left(Either.right(1)) end)
	end)
end)

T.describe("Either.either", function()
	T.it("applies f to Left value", function()
		local r = Either.either(
			function(e) return "got error: " .. e end,
			function(a) return "got value: " .. tostring(a) end,
			Either.left("boom")
		)
		T.eq(r, "got error: boom")
	end)

	T.it("applies g to Right value", function()
		local r = Either.either(
			function(e) return "got error: " .. e end,
			function(a) return "got value: " .. tostring(a) end,
			Either.right(99)
		)
		T.eq(r, "got value: 99")
	end)
end)

-- ── tostring ──────────────────────────────────────────────────────────────────

T.describe("Either tostring", function()
	T.it("Left tostring", function()
		T.eq(tostring(Either.left("err")), "Left(err)")
	end)

	T.it("Right tostring", function()
		T.eq(tostring(Either.right(3)), "Right(3)")
	end)
end)

-- ── Mappable ──────────────────────────────────────────────────────────────────

T.describe("Either Mappable", function()
	T.it("map over Right applies f", function()
		local r = Mappable.map(function(x) return x * 2 end, Either.right(5))
		T.eq(r.value, 10)
		T.ok(Either.is_right(r))
	end)

	T.it("map over Left returns Left unchanged", function()
		local original = Either.left("err")
		local r = Mappable.map(function(x) return x * 2 end, original)
		T.eq(r, original)
		T.ok(Either.is_left(r))
	end)

	T.it("identity law: map(id, Right(x)) == Right(x)", function()
		local e = Either.right(99)
		T.eq(Mappable.map(id, e).value, e.value)
	end)

	T.it("identity law: map(id, Left(e)) == Left(e)", function()
		local e = Either.left("e")
		T.eq(Mappable.map(id, e), e)
	end)

	T.it("composition law (Right)", function()
		local f = function(x) return x + 1 end
		local g = function(x) return x * 3 end
		local e = Either.right(4)
		local lhs = Mappable.map(function(x) return f(g(x)) end, e)
		local rhs = Mappable.map(f, Mappable.map(g, e))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("composition law (Left)", function()
		local f = function(x) return x + 1 end
		local g = function(x) return x * 3 end
		local original = Either.left("e")
		local lhs = Mappable.map(function(x) return f(g(x)) end, original)
		local rhs = Mappable.map(f, Mappable.map(g, original))
		T.eq(lhs, rhs)
	end)
end)

-- ── Applicable ────────────────────────────────────────────────────────────────

T.describe("Either Applicable", function()
	T.it("ap(Left(e), _) = Left(e)", function()
		local lf = Either.left("no fn")
		local r  = Applicable.ap(lf, Either.right(1))
		T.eq(r, lf)
		T.ok(Either.is_left(r))
	end)

	T.it("ap(Right(f), Left(e)) = Left(e)", function()
		local lv = Either.left("no val")
		local r  = Applicable.ap(Either.right(function(x) return x end), lv)
		T.eq(r, lv)
		T.ok(Either.is_left(r))
	end)

	T.it("ap(Right(f), Right(a)) = Right(f(a))", function()
		local r = Applicable.ap(
			Either.right(function(x) return x + 10 end),
			Either.right(5)
		)
		T.eq(r.value, 15)
		T.ok(Either.is_right(r))
	end)

	T.it("pure lifts into Right", function()
		local r = Applicable.pure(Either.right(0), 42)
		T.eq(r.value, 42)
		T.ok(Either.is_right(r))
	end)

	T.it("pure via Left also lifts into Right", function()
		local r = Applicable.pure(Either.left("x"), 7)
		T.eq(r.value, 7)
		T.ok(Either.is_right(r))
	end)
end)

-- ── Foldable ──────────────────────────────────────────────────────────────────

T.describe("Either Foldable", function()
	T.it("foldr(f, z, Left) = z", function()
		local r = Foldable.foldr(function(a, b) return a + b end, 99, Either.left("e"))
		T.eq(r, 99)
	end)

	T.it("foldr(f, z, Right(a)) = f(a, z)", function()
		local r = Foldable.foldr(function(a, b) return a + b end, 10, Either.right(5))
		T.eq(r, 15)
	end)

	T.it("foldMap(f, Right(a)) = f(a)", function()
		local r = Foldable.foldMap(function(a) return Sum(a) end, Either.right(3))
		T.eq(r.value, 3)
	end)

	T.it("foldMap over Left errors", function()
		T.throws(function()
			Foldable.foldMap(function(a) return Sum(a) end, Either.left("e"))
		end)
	end)

	T.it("fold(Right(a)) = a", function()
		local inner = Sum(42)
		local r = Foldable.fold(Either.right(inner))
		T.eq(r.value, 42)
	end)

	T.it("fold over Left errors", function()
		T.throws(function()
			Foldable.fold(Either.left("e"))
		end)
	end)
end)

-- ── Chainable (bind / monad) ──────────────────────────────────────────────────

if Chainable then
	T.describe("Either Chainable", function()
		T.it("bind(Left(e), f) = Left(e)", function()
			local original = Either.left("err")
			local r = Chainable.bind(original, function(a)
				return Either.right(a + 1)
			end)
			T.eq(r, original)
			T.ok(Either.is_left(r))
		end)

		T.it("bind(Right(a), f) = f(a)", function()
			local r = Chainable.bind(Either.right(5), function(a)
				return Either.right(a * 2)
			end)
			T.eq(r.value, 10)
			T.ok(Either.is_right(r))
		end)

		T.it("bind(Right(a), f) propagates Left from f", function()
			local r = Chainable.bind(Either.right(5), function(_a)
				return Either.left("inner error")
			end)
			T.ok(Either.is_left(r))
			T.eq(r.value, "inner error")
		end)

		-- Monad left identity: bind(pure(a), f) == f(a)
		T.it("monad left identity", function()
			local f = function(a) return Either.right(a + 1) end
			local a = 10
			local lhs = Chainable.bind(Either.right(a), f)
			local rhs = f(a)
			T.eq(lhs.value, rhs.value)
		end)

		-- Monad right identity: bind(ma, pure) == ma
		T.it("monad right identity", function()
			local ma = Either.right(10)
			local r = Chainable.bind(ma, function(a) return Either.right(a) end)
			T.eq(r.value, ma.value)
		end)

		-- Monad associativity: bind(bind(ma,f),g) == bind(ma, function(a) return bind(f(a),g) end)
		T.it("monad associativity", function()
			local ma = Either.right(3)
			local f  = function(a) return Either.right(a + 1) end
			local g  = function(b) return Either.right(b * 2) end
			local lhs = Chainable.bind(Chainable.bind(ma, f), g)
			local rhs = Chainable.bind(ma, function(a) return Chainable.bind(f(a), g) end)
			T.eq(lhs.value, rhs.value)
		end)
	end)
end

-- ── Semigroup ─────────────────────────────────────────────────────────────────

T.describe("Either Semigroup", function()
	T.it("Left <> Left = right Left (second one)", function()
		local l1 = Either.left("first")
		local l2 = Either.left("second")
		local r  = Semigroup.append(l1, l2)
		T.eq(r, l2)
		T.ok(Either.is_left(r))
	end)

	T.it("Left <> Right = Right", function()
		local rv = Either.right(Sum(5))
		local r  = Semigroup.append(Either.left("e"), rv)
		T.eq(r, rv)
		T.ok(Either.is_right(r))
	end)

	T.it("Right <> Left = Right (self wins)", function()
		local rv = Either.right(Sum(5))
		local r  = Semigroup.append(rv, Either.left("e"))
		T.eq(r, rv)
		T.ok(Either.is_right(r))
	end)

	T.it("Right(a) <> Right(b) = Right(append(a, b))", function()
		local r = Semigroup.append(Either.right(Sum(3)), Either.right(Sum(4)))
		T.eq(r.value.value, 7)
		T.ok(Either.is_right(r))
	end)
end)

-- ── Property tests ────────────────────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

T.describe("Either Mappable property: identity law", function()
	arb.it("map(id, Right(x)).value == x", int_arb, function(n)
		local fa = Either.right(n)
		local r  = Mappable.map(id, fa)
		return r.value == n
	end)
end)

T.describe("Either Mappable property: composition law", function()
	arb.it("map(f∘g, Right(x)) == map(f, map(g, Right(x)))", int_arb, function(n)
		local fa = Either.right(n)
		local f  = function(x) return x + 7 end
		local g  = function(x) return x * 2 end
		local lhs = Mappable.map(function(x) return f(g(x)) end, fa)
		local rhs = Mappable.map(f, Mappable.map(g, fa))
		return lhs.value == rhs.value
	end)
end)

if Chainable then
	T.describe("Either monad property: left identity", function()
		arb.it("bind(pure(a), f) == f(a)", int_arb, function(n)
			local f   = function(a) return Either.right(a + 3) end
			local lhs = Chainable.bind(Either.right(n), f)
			local rhs = f(n)
			return lhs.value == rhs.value
		end)
	end)

	T.describe("Either monad property: associativity", function()
		arb.it("bind(bind(ma,f),g) == bind(ma, a->bind(f(a),g))", int_arb, function(n)
			local ma  = Either.right(n)
			local f   = function(a) return Either.right(a + 1) end
			local g   = function(b) return Either.right(b * 2) end
			local lhs = Chainable.bind(Chainable.bind(ma, f), g)
			local rhs = Chainable.bind(ma, function(a) return Chainable.bind(f(a), g) end)
			return lhs.value == rhs.value
		end)
	end)
end
