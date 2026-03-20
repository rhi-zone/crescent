-- lib/fp/alt/alt_test.lua
-- Tests for the Alt typeclass: dispatch, instances, and laws.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local arb    = require("lib.test.arb")
local Alt    = require("lib.fp.alt")
local Maybe  = require("lib.fp.maybe")
local Either = require("lib.fp.either")

local int_arb = arb.int(-1000, 1000)

-- ── Maybe instances ────────────────────────────────────────────────────────────

T.describe("Alt Maybe: Just is always chosen", function()
	T.it("alt(Just(a), Just(b)) = Just(a)", function()
		local r = Alt.alt(Maybe.just(1), Maybe.just(2))
		T.eq(r.value, 1)
	end)

	T.it("alt(Just(a), Nothing) = Just(a)", function()
		local r = Alt.alt(Maybe.just(42), Maybe.nothing)
		T.eq(r.value, 42)
	end)
end)

T.describe("Alt Maybe: Nothing falls back", function()
	T.it("alt(Nothing, Just(b)) = Just(b)", function()
		local r = Alt.alt(Maybe.nothing, Maybe.just(7))
		T.eq(r.value, 7)
	end)

	T.it("alt(Nothing, Nothing) = Nothing", function()
		local r = Alt.alt(Maybe.nothing, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Either instances ───────────────────────────────────────────────────────────

T.describe("Alt Either: Right is always chosen (right-biased)", function()
	T.it("alt(Right(a), Right(b)) = Right(a)", function()
		local r = Alt.alt(Either.right(10), Either.right(20))
		T.eq(r.value, 10)
	end)

	T.it("alt(Right(a), Left(e)) = Right(a)", function()
		local r = Alt.alt(Either.right(5), Either.left("error"))
		T.eq(r.value, 5)
		T.ok(Either.is_right(r))
	end)
end)

T.describe("Alt Either: Left falls back", function()
	T.it("alt(Left(e), Right(b)) = Right(b)", function()
		local r = Alt.alt(Either.left("err"), Either.right(99))
		T.eq(r.value, 99)
		T.ok(Either.is_right(r))
	end)

	T.it("alt(Left(e1), Left(e2)) = Left(e2)", function()
		local r = Alt.alt(Either.left("first"), Either.left("second"))
		T.eq(r.value, "second")
		T.ok(Either.is_left(r))
	end)
end)

-- ── Alt laws ──────────────────────────────────────────────────────────────────
--
-- Associativity: alt(alt(fa, fb), fc) == alt(fa, alt(fb, fc))
-- Distributivity (left): map(f, alt(fa, fb)) == alt(map(f, fa), map(f, fb))

local Mappable = require("lib.fp.mappable")

T.describe("Alt Maybe: associativity law", function()
	T.it("alt(alt(J,J),J): left nesting == right nesting, value matches leftmost", function()
		local fa = Maybe.just(1)
		local fb = Maybe.just(2)
		local fc = Maybe.just(3)
		local lhs = Alt.alt(Alt.alt(fa, fb), fc)
		local rhs = Alt.alt(fa, Alt.alt(fb, fc))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("alt(alt(N,J),J) == alt(N,alt(J,J))", function()
		local fb = Maybe.just(2)
		local fc = Maybe.just(3)
		local lhs = Alt.alt(Alt.alt(Maybe.nothing, fb), fc)
		local rhs = Alt.alt(Maybe.nothing, Alt.alt(fb, fc))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("alt(alt(N,N),J) == alt(N,alt(N,J))", function()
		local fc = Maybe.just(7)
		local lhs = Alt.alt(Alt.alt(Maybe.nothing, Maybe.nothing), fc)
		local rhs = Alt.alt(Maybe.nothing, Alt.alt(Maybe.nothing, fc))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("alt(alt(N,N),N) == Nothing", function()
		local lhs = Alt.alt(Alt.alt(Maybe.nothing, Maybe.nothing), Maybe.nothing)
		local rhs = Alt.alt(Maybe.nothing, Alt.alt(Maybe.nothing, Maybe.nothing))
		T.eq(lhs, Maybe.nothing)
		T.eq(rhs, Maybe.nothing)
	end)

	arb.it("alt(alt(Just(a), Just(b)), Just(c)).value == a (leftmost wins)", int_arb, function(n)
		local fa = Maybe.just(n)
		local fb = Maybe.just(n + 1)
		local fc = Maybe.just(n + 2)
		local lhs = Alt.alt(Alt.alt(fa, fb), fc)
		local rhs = Alt.alt(fa, Alt.alt(fb, fc))
		return lhs.value == rhs.value
	end)
end)

T.describe("Alt Maybe: distributivity — map(f, alt(fa, fb)) == alt(map(f,fa), map(f,fb))", function()
	local f = function(x) return x * 2 end

	T.it("Just/Just case", function()
		local fa = Maybe.just(3)
		local fb = Maybe.just(7)
		local lhs = Mappable.map(f, Alt.alt(fa, fb))
		local rhs = Alt.alt(Mappable.map(f, fa), Mappable.map(f, fb))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("Nothing/Just case", function()
		local fb = Maybe.just(5)
		local lhs = Mappable.map(f, Alt.alt(Maybe.nothing, fb))
		local rhs = Alt.alt(Mappable.map(f, Maybe.nothing), Mappable.map(f, fb))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("Nothing/Nothing case", function()
		local lhs = Mappable.map(f, Alt.alt(Maybe.nothing, Maybe.nothing))
		local rhs = Alt.alt(Mappable.map(f, Maybe.nothing), Mappable.map(f, Maybe.nothing))
		T.eq(lhs, Maybe.nothing)
		T.eq(rhs, Maybe.nothing)
	end)
end)

T.describe("Alt Either: associativity law", function()
	T.it("Right wins over Left regardless of nesting order", function()
		local r1 = Either.right(1)
		local r2 = Either.right(2)
		local r3 = Either.right(3)
		local lhs = Alt.alt(Alt.alt(r1, r2), r3)
		local rhs = Alt.alt(r1, Alt.alt(r2, r3))
		T.eq(lhs.value, rhs.value)
	end)

	T.it("alt(alt(L,R),R) == alt(L,alt(R,R)) — both pick first Right", function()
		local ra = Either.right(10)
		local rb = Either.right(20)
		local le = Either.left("e")
		local lhs = Alt.alt(Alt.alt(le, ra), rb)
		local rhs = Alt.alt(le, Alt.alt(ra, rb))
		T.eq(lhs.value, rhs.value)
	end)
end)
