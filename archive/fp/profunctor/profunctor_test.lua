-- lib/fp/profunctor/profunctor_test.lua
-- Tests for the Profunctor typeclass: dispatch, Fn instances, and laws.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local arb        = require("lib.test.arb")
local Profunctor = require("lib.fp.profunctor")
local Fn         = require("lib.fp.fn")

local int_arb = arb.int(-1000, 1000)

local function add1(x) return x + 1 end
local function mul2(x) return x * 2 end
local function sub3(x) return x - 3 end
local function id(x)   return x     end

-- ── dimap dispatch ─────────────────────────────────────────────────────────────

T.describe("Profunctor.dimap Fn", function()
	T.it("dimap(f, g, Fn(h))(x) == g(h(f(x)))", function()
		-- f = add1, h = mul2, g = sub3
		-- dimap(add1, sub3, Fn(mul2))(10)
		--   = sub3(mul2(add1(10)))
		--   = sub3(mul2(11))
		--   = sub3(22)
		--   = 19
		local h = Fn(mul2)
		local r = Profunctor.dimap(add1, sub3, h)
		T.eq(r(10), 19)
	end)

	T.it("dimap returns a Fn wrapper", function()
		local h = Fn(id)
		local r = Profunctor.dimap(id, id, h)
		T.ok(type(r) == "table" and r._fn ~= nil)
	end)

	T.it("dimap with multiple arguments passes through", function()
		-- Pre-map picks first arg only (single-arg pre-map)
		-- h(x, y) — only x is pre-mapped by f
		local h = Fn(function(x) return x * 10 end)
		local r = Profunctor.dimap(add1, mul2, h)
		-- r(5) = mul2(h(add1(5))) = mul2(h(6)) = mul2(60) = 120
		T.eq(r(5), 120)
	end)
end)

-- ── lmap / rmap derived operations ────────────────────────────────────────────

T.describe("Profunctor.lmap Fn", function()
	T.it("lmap(f, Fn(h))(x) == h(f(x))", function()
		-- lmap(add1, Fn(mul2))(5) = mul2(add1(5)) = mul2(6) = 12
		local h = Fn(mul2)
		local r = Profunctor.lmap(add1, h)
		T.eq(r(5), 12)
	end)

	T.it("lmap does not affect output", function()
		-- Output should pass through identity (the rhs of dimap)
		local h = Fn(function(x) return x + 100 end)
		local r = Profunctor.lmap(mul2, h)
		-- r(3) = h(mul2(3)) = h(6) = 106
		T.eq(r(3), 106)
	end)
end)

T.describe("Profunctor.rmap Fn", function()
	T.it("rmap(g, Fn(h))(x) == g(h(x))", function()
		-- rmap(sub3, Fn(mul2))(7) = sub3(mul2(7)) = sub3(14) = 11
		local h = Fn(mul2)
		local r = Profunctor.rmap(sub3, h)
		T.eq(r(7), 11)
	end)

	T.it("rmap does not affect input", function()
		local h = Fn(function(x) return x * 3 end)
		local r = Profunctor.rmap(add1, h)
		-- r(4) = add1(h(4)) = add1(12) = 13
		T.eq(r(4), 13)
	end)
end)

-- ── Profunctor laws ────────────────────────────────────────────────────────────
--
-- Identity:    dimap(id, id, fbc) == fbc  (pointwise)
-- Composition: dimap(f∘g, h∘k, fbc)(x) == dimap(g, h, dimap(f, k, fbc))(x)
--   Note: pre-map composes in reverse (contravariant): dimap(f∘g,...) means
--   apply g first, then f to the input. In Haskell: dimap (g . f) (h . k).
--   In crescent arg order dimap(pre, post, f): pre is applied first to input,
--   so composition is: dimap(f, h, dimap(g, k, fbc)) where the outer dimap's
--   pre-map (f) is applied AFTER the inner dimap's pre-map (g).
--
-- In other words, for Profunctor composition:
--   dimap(f, h, dimap(g, k, fbc))(x)
--     = h(dimap(g, k, fbc)(f(x)))
--     = h(k(fbc(g(f(x)))))
--
--   dimap(f∘g, k∘h)(x) is ambiguous in arg order — we test the structural law:
--   dimap(f, g, dimap(h, k, fbc)) == dimap(h∘f, g∘k ... no.
--
-- The clearest form: dimap(f,g,fbc) is g . fbc . f  (pointwise)
-- Composition: (g2 . fbc . f2) composed with (g1 . ... . f1):
--   dimap(f1, g1, dimap(f2, g2, fbc))(x) = g1(g2(fbc(f2(f1(x)))))
--   dimap(f2 . f1, g1 . g2, fbc)(x)      = g1(g2(fbc(f2(f1(x)))))
-- Both are equal.

T.describe("Profunctor identity law: dimap(id, id, Fn(h))(x) == h(x)", function()
	arb.it("identity holds for int input", int_arb, function(n)
		local h = Fn(function(x) return x * 7 + 3 end)
		local r = Profunctor.dimap(id, id, h)
		return r(n) == h(n)
	end)
end)

T.describe("Profunctor composition law", function()
	-- dimap(f1, g1, dimap(f2, g2, Fn(h)))(x) == dimap(compose(f2,f1), compose(g1,g2), Fn(h))(x)
	-- where compose(f,g)(x) = f(g(x))  (standard math composition)
	-- lhs: g1(g2(h(f2(f1(x)))))
	-- rhs: g1(g2(h(f2(f1(x)))))  (same)

	local f1 = add1   -- outer pre-map (applied first to input)
	local f2 = mul2   -- inner pre-map (applied second)
	local g1 = sub3   -- outer post-map (applied last)
	local g2 = add1   -- inner post-map (applied first to output)

	arb.it("composition holds for int input", int_arb, function(n)
		local h = Fn(function(x) return x + 100 end)

		-- lhs: two nested dimaps
		local lhs = Profunctor.dimap(f1, g1, Profunctor.dimap(f2, g2, h))

		-- rhs: single dimap with composed maps
		-- pre: f2(f1(x))
		-- post: g1(g2(y))
		local rhs = Profunctor.dimap(
			function(x) return f2(f1(x)) end,
			function(y) return g1(g2(y)) end,
			h
		)

		return lhs(n) == rhs(n)
	end)
end)

T.describe("Profunctor lmap/rmap consistency with dimap", function()
	arb.it("lmap(f, fbc)(x) == dimap(f, id, fbc)(x)", int_arb, function(n)
		local h = Fn(function(x) return x * 5 end)
		local via_lmap  = Profunctor.lmap(add1, h)
		local via_dimap = Profunctor.dimap(add1, id, h)
		return via_lmap(n) == via_dimap(n)
	end)

	arb.it("rmap(g, fbc)(x) == dimap(id, g, fbc)(x)", int_arb, function(n)
		local h = Fn(function(x) return x + 50 end)
		local via_rmap  = Profunctor.rmap(mul2, h)
		local via_dimap = Profunctor.dimap(id, mul2, h)
		return via_rmap(n) == via_dimap(n)
	end)
end)
