-- lib/fp/chainable/chainable_test.lua
-- Tests for the Chainable typeclass dispatch via Maybe instances.
-- Covers bind, then_, join, and the three monad laws.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Applicable = require("lib.fp.applicable")
local Chainable  = require("lib.fp.chainable")
local Maybe      = require("lib.fp.maybe")

-- ── bind dispatch ─────────────────────────────────────────────────────────────

T.describe("Chainable.bind dispatch", function()
	T.it("bind(Just(5), f) applies f to inner value", function()
		local r = Chainable.bind(Maybe.just(5), function(x) return Maybe.just(x + 1) end)
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 6)
	end)

	T.it("bind(Nothing, f) returns Nothing", function()
		local r = Chainable.bind(Maybe.nothing, function(x) return Maybe.just(x + 1) end)
		T.eq(r, Maybe.nothing)
	end)

	T.it("bind(Just(5), f returning Nothing) returns Nothing", function()
		local r = Chainable.bind(Maybe.just(5), function(_) return Maybe.nothing end)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── then_ ─────────────────────────────────────────────────────────────────────

T.describe("Chainable.then_", function()
	T.it("then_(Just(1), Just(2)) returns Just(2)", function()
		local r = Chainable.then_(Maybe.just(1), Maybe.just(2))
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 2)
	end)

	T.it("then_(Nothing, Just(2)) returns Nothing", function()
		local r = Chainable.then_(Maybe.nothing, Maybe.just(2))
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── join ──────────────────────────────────────────────────────────────────────

T.describe("Chainable.join", function()
	T.it("join(Just(Just(5))) returns Just(5)", function()
		local r = Chainable.join(Maybe.just(Maybe.just(5)))
		T.ok(Maybe.is_just(r))
		T.eq(r.value, 5)
	end)

	T.it("join(Just(Nothing)) returns Nothing", function()
		local r = Chainable.join(Maybe.just(Maybe.nothing))
		T.eq(r, Maybe.nothing)
	end)

	T.it("join(Nothing) returns Nothing", function()
		local r = Chainable.join(Maybe.nothing)
		T.eq(r, Maybe.nothing)
	end)
end)

-- ── Monad laws ────────────────────────────────────────────────────────────────

local int_arb = arb.int(-1000, 1000)

-- Left identity: bind(pure(a), f) == f(a)
T.describe("Monad left identity law", function()
	arb.it("bind(pure(a), f) == f(a)", int_arb, function(n)
		local f   = function(x) return Maybe.just(x * 2) end
		local lhs = Chainable.bind(Applicable.pure(Maybe.nothing, n), f)
		local rhs = f(n)
		return lhs.value == rhs.value
	end)
end)

-- Right identity: bind(ma, pure) == ma
T.describe("Monad right identity law", function()
	arb.it("bind(Just(n), pure) == Just(n)", int_arb, function(n)
		local ma  = Maybe.just(n)
		local lhs = Chainable.bind(ma, function(x) return Applicable.pure(Maybe.nothing, x) end)
		return lhs.value == ma.value
	end)

	T.it("bind(Nothing, pure) == Nothing", function()
		local lhs = Chainable.bind(Maybe.nothing, function(x) return Applicable.pure(Maybe.nothing, x) end)
		T.eq(lhs, Maybe.nothing)
	end)
end)

-- Associativity: bind(bind(ma, f), g) == bind(ma, function(x) return bind(f(x), g) end)
T.describe("Monad associativity law", function()
	arb.it("bind(bind(Just(n), f), g) == bind(Just(n), x->bind(f(x),g))", int_arb, function(n)
		local f   = function(x) return Maybe.just(x + 3) end
		local g   = function(x) return Maybe.just(x * 2) end
		local ma  = Maybe.just(n)
		local lhs = Chainable.bind(Chainable.bind(ma, f), g)
		local rhs = Chainable.bind(ma, function(x) return Chainable.bind(f(x), g) end)
		return lhs.value == rhs.value
	end)

	T.it("associativity holds when ma is Nothing", function()
		local f   = function(x) return Maybe.just(x + 3) end
		local g   = function(x) return Maybe.just(x * 2) end
		local lhs = Chainable.bind(Chainable.bind(Maybe.nothing, f), g)
		local rhs = Chainable.bind(Maybe.nothing, function(x) return Chainable.bind(f(x), g) end)
		T.eq(lhs, rhs)
		T.eq(lhs, Maybe.nothing)
	end)
end)
