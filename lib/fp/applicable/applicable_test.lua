-- lib/fp/applicable/applicable_test.lua
-- Tests for the Applicable typeclass dispatch via Maybe instances.
-- Covers both ap (formerly Apply) and pure (formerly Applicative).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Mappable   = require("lib.fp.mappable")
local Applicable = require("lib.fp.applicable")
local Maybe      = require("lib.fp.maybe")

local function id(x) return x end

local function compose(f)
	return function(g)
		return function(x)
			return f(g(x))
		end
	end
end

-- ── ap dispatch ───────────────────────────────────────────────────────────────

T.describe("Applicable.ap dispatch", function()
	T.it("Just(f) <*> Just(x) applies f to x", function()
		local ff = Maybe.just(function(x) return x + 10 end)
		local fa = Maybe.just(5)
		local r  = Applicable.ap(ff, fa)
		T.eq(r.value, 15)
	end)

	T.it("Nothing <*> Just(x) returns Nothing", function()
		local fa = Maybe.just(5)
		local r  = Applicable.ap(Maybe.nothing, fa)
		T.eq(r, Maybe.nothing)
	end)

	T.it("Just(f) <*> Nothing returns Nothing", function()
		local ff = Maybe.just(function(x) return x + 10 end)
		local r  = Applicable.ap(ff, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)

	T.it("Nothing <*> Nothing returns Nothing", function()
		local r = Applicable.ap(Maybe.nothing, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── pure ──────────────────────────────────────────────────────────────────────

T.describe("Applicable.pure", function()
	T.it("pure(Nothing, 42) returns Just(42)", function()
		local r = Applicable.pure(Maybe.nothing, 42)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 42)
	end)

	T.it("pure(Just(x), 42) returns Just(42)", function()
		local r = Applicable.pure(Maybe.just(0), 42)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 42)
	end)
end)

-- ── Apply composition law ─────────────────────────────────────────────────────
-- ap(ap(map(compose, u), v), w) == ap(u, ap(v, w))

local int_arb = arb.int(-1000, 1000)

T.describe("Applicable composition law (Just)", function()
	arb.it("ap(ap(map(compose, u), v), w) == ap(u, ap(v, w))", int_arb, function(n)
		local u = Maybe.just(function(x) return x * 2 end)
		local v = Maybe.just(function(x) return x + 3 end)
		local w = Maybe.just(n)
		local lhs = Applicable.ap(Applicable.ap(Mappable.map(compose, u), v), w)
		local rhs = Applicable.ap(u, Applicable.ap(v, w))
		return lhs.value == rhs.value
	end)
end)

T.describe("Applicable composition law (Nothing u)", function()
	T.it("ap(ap(map(compose, Nothing), v), w) == ap(Nothing, ap(v, w))", function()
		local v = Maybe.just(function(x) return x + 3 end)
		local w = Maybe.just(42)
		local lhs = Applicable.ap(Applicable.ap(Mappable.map(compose, Maybe.nothing), v), w)
		local rhs = Applicable.ap(Maybe.nothing, Applicable.ap(v, w))
		T.eq(lhs, rhs)
	end)
end)

-- ── Applicative identity law ──────────────────────────────────────────────────
-- ap(pure(id), fa) == fa

T.describe("Applicable identity law (Just)", function()
	arb.it("ap(pure(id), Just(x)) == Just(x)", int_arb, function(n)
		local fa  = Maybe.just(n)
		local pid = Applicable.pure(Maybe.nothing, id)
		local r   = Applicable.ap(pid, fa)
		return r.value == fa.value
	end)
end)

T.describe("Applicable identity law (Nothing)", function()
	T.it("ap(pure(id), Nothing) == Nothing", function()
		local pid = Applicable.pure(Maybe.nothing, id)
		local r   = Applicable.ap(pid, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Applicative homomorphism law ──────────────────────────────────────────────
-- ap(pure(f), pure(x)) == pure(f(x))

T.describe("Applicable homomorphism law", function()
	arb.it("ap(pure(f), pure(x)) == pure(f(x))", int_arb, function(n)
		local f   = function(x) return x * 3 end
		local pf  = Applicable.pure(Maybe.nothing, f)
		local px  = Applicable.pure(Maybe.nothing, n)
		local lhs = Applicable.ap(pf, px)
		local rhs = Applicable.pure(Maybe.nothing, f(n))
		return lhs.value == rhs.value
	end)
end)

-- ── Applicative interchange law ───────────────────────────────────────────────
-- ap(u, pure(x)) == ap(pure(function(f) return f(x) end), u)

T.describe("Applicable interchange law", function()
	arb.it("ap(u, pure(x)) == ap(pure(f->f(x)), u)", int_arb, function(n)
		local u   = Maybe.just(function(x) return x + 5 end)
		local px  = Applicable.pure(Maybe.nothing, n)
		local lhs = Applicable.ap(u, px)
		local apply_to = Applicable.pure(Maybe.nothing, function(f) return f(n) end)
		local rhs = Applicable.ap(apply_to, u)
		return lhs.value == rhs.value
	end)
end)
