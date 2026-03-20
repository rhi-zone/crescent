-- lib/fp/bifunctor/bifunctor_test.lua
-- Tests for the Bifunctor typeclass: dispatch, Either instances, and laws.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Bifunctor  = require("lib.fp.bifunctor")
local Either     = require("lib.fp.either")

local int_arb = arb.int(-1000, 1000)

local function add1(x) return x + 1 end
local function mul2(x) return x * 2 end
local function id(x)   return x     end

-- ── bimap dispatch ─────────────────────────────────────────────────────────────

T.describe("Bifunctor.bimap Either", function()
	T.it("bimap(f, g, Left(e)) = Left(f(e))", function()
		local r = Bifunctor.bimap(add1, mul2, Either.left(5))
		T.ok(Either.is_left(r))
		T.eq(r.value, 6)   -- add1(5) = 6
	end)

	T.it("bimap(f, g, Right(a)) = Right(g(a))", function()
		local r = Bifunctor.bimap(add1, mul2, Either.right(5))
		T.ok(Either.is_right(r))
		T.eq(r.value, 10)  -- mul2(5) = 10
	end)

	T.it("bimap does not apply g to Left", function()
		local called = false
		Bifunctor.bimap(id, function(x) called = true return x end, Either.left(1))
		T.ok(not called)
	end)

	T.it("bimap does not apply f to Right", function()
		local called = false
		Bifunctor.bimap(function(x) called = true return x end, id, Either.right(1))
		T.ok(not called)
	end)
end)

-- ── lmap / rmap derived operations ────────────────────────────────────────────

T.describe("Bifunctor.lmap Either", function()
	T.it("lmap(f, Left(e)) = Left(f(e))", function()
		local r = Bifunctor.lmap(add1, Either.left(9))
		T.ok(Either.is_left(r))
		T.eq(r.value, 10)
	end)

	T.it("lmap(f, Right(a)) = Right(a) unchanged", function()
		local r = Bifunctor.lmap(add1, Either.right(9))
		T.ok(Either.is_right(r))
		T.eq(r.value, 9)
	end)
end)

T.describe("Bifunctor.rmap Either", function()
	T.it("rmap(g, Right(a)) = Right(g(a))", function()
		local r = Bifunctor.rmap(mul2, Either.right(4))
		T.ok(Either.is_right(r))
		T.eq(r.value, 8)
	end)

	T.it("rmap(g, Left(e)) = Left(e) unchanged", function()
		local r = Bifunctor.rmap(mul2, Either.left(4))
		T.ok(Either.is_left(r))
		T.eq(r.value, 4)
	end)
end)

-- ── Bifunctor laws ─────────────────────────────────────────────────────────────
--
-- Identity:    bimap(id, id, fab) == fab
-- Composition: bimap(f∘g, h∘k, fab) == bimap(f, h, bimap(g, k, fab))

T.describe("Bifunctor identity law: bimap(id, id, fab) == fab", function()
	arb.it("Left: bimap(id, id, Left(n)).value == n", int_arb, function(n)
		local fab = Either.left(n)
		local r   = Bifunctor.bimap(id, id, fab)
		return Either.is_left(r) and r.value == fab.value
	end)

	arb.it("Right: bimap(id, id, Right(n)).value == n", int_arb, function(n)
		local fab = Either.right(n)
		local r   = Bifunctor.bimap(id, id, fab)
		return Either.is_right(r) and r.value == fab.value
	end)
end)

T.describe("Bifunctor composition law", function()
	-- bimap(f∘g, h∘k, fab) == bimap(f, h, bimap(g, k, fab))
	local f = function(x) return x + 3 end
	local g = function(x) return x * 2 end
	local h = function(x) return x - 1 end
	local k = function(x) return x + 10 end

	arb.it("Left: composition holds for first parameter", int_arb, function(n)
		local fab = Either.left(n)
		local lhs = Bifunctor.bimap(function(x) return f(g(x)) end, function(x) return h(k(x)) end, fab)
		local rhs = Bifunctor.bimap(f, h, Bifunctor.bimap(g, k, fab))
		return Either.is_left(lhs) and Either.is_left(rhs) and lhs.value == rhs.value
	end)

	arb.it("Right: composition holds for second parameter", int_arb, function(n)
		local fab = Either.right(n)
		local lhs = Bifunctor.bimap(function(x) return f(g(x)) end, function(x) return h(k(x)) end, fab)
		local rhs = Bifunctor.bimap(f, h, Bifunctor.bimap(g, k, fab))
		return Either.is_right(lhs) and Either.is_right(rhs) and lhs.value == rhs.value
	end)
end)

T.describe("Bifunctor lmap/rmap consistency with bimap", function()
	arb.it("lmap(f, Left(n)) == bimap(f, id, Left(n))", int_arb, function(n)
		local fab = Either.left(n)
		local via_lmap  = Bifunctor.lmap(add1, fab)
		local via_bimap = Bifunctor.bimap(add1, id, fab)
		return Either.is_left(via_lmap) and via_lmap.value == via_bimap.value
	end)

	arb.it("rmap(g, Right(n)) == bimap(id, g, Right(n))", int_arb, function(n)
		local fab = Either.right(n)
		local via_rmap  = Bifunctor.rmap(mul2, fab)
		local via_bimap = Bifunctor.bimap(id, mul2, fab)
		return Either.is_right(via_rmap) and via_rmap.value == via_bimap.value
	end)
end)
