-- lib/fp/applicative/applicative_test.lua
-- Tests for the Applicative typeclass dispatch via Maybe instances.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local arb         = require("lib.test.arb")
local Apply       = require("lib.fp.apply")
local Applicative = require("lib.fp.applicative")
local Maybe       = require("lib.fp.maybe")

local function id(x) return x end

-- ── pure ──────────────────────────────────────────────────────────────────────

T.describe("Applicative.pure", function()
	T.it("pure(Nothing, 42) returns Just(42)", function()
		local r = Applicative.pure(Maybe.nothing, 42)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 42)
	end)

	T.it("pure(Just(x), 42) returns Just(42)", function()
		local r = Applicative.pure(Maybe.just(0), 42)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 42)
	end)
end)

-- ── Applicative identity law ──────────────────────────────────────────────────
-- ap(pure(id), fa) == fa

local int_arb = arb.int(-1000, 1000)

T.describe("Applicative identity law (Just)", function()
	arb.it("ap(pure(id), Just(x)) == Just(x)", int_arb, function(n)
		local fa  = Maybe.just(n)
		local pid = Applicative.pure(Maybe.nothing, id)
		local r   = Apply.ap(pid, fa)
		return r.value == fa.value
	end)
end)

T.describe("Applicative identity law (Nothing)", function()
	T.it("ap(pure(id), Nothing) == Nothing", function()
		local pid = Applicative.pure(Maybe.nothing, id)
		local r   = Apply.ap(pid, Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Applicative homomorphism law ──────────────────────────────────────────────
-- ap(pure(f), pure(x)) == pure(f(x))

T.describe("Applicative homomorphism law", function()
	arb.it("ap(pure(f), pure(x)) == pure(f(x))", int_arb, function(n)
		local f   = function(x) return x * 3 end
		local pf  = Applicative.pure(Maybe.nothing, f)
		local px  = Applicative.pure(Maybe.nothing, n)
		local lhs = Apply.ap(pf, px)
		local rhs = Applicative.pure(Maybe.nothing, f(n))
		return lhs.value == rhs.value
	end)
end)

-- ── Applicative interchange law ───────────────────────────────────────────────
-- ap(u, pure(x)) == ap(pure(function(f) return f(x) end), u)

T.describe("Applicative interchange law", function()
	arb.it("ap(u, pure(x)) == ap(pure(f->f(x)), u)", int_arb, function(n)
		local u   = Maybe.just(function(x) return x + 5 end)
		local px  = Applicative.pure(Maybe.nothing, n)
		local lhs = Apply.ap(u, px)
		local apply_to = Applicative.pure(Maybe.nothing, function(f) return f(n) end)
		local rhs = Apply.ap(apply_to, u)
		return lhs.value == rhs.value
	end)
end)
