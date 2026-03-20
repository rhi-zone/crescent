-- lib/fp/optics/traversal/traversal_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local Maybe     = require("lib.fp.maybe")
local Lens      = require("lib.fp.optics.lens")
local Prism     = require("lib.fp.optics.prism")
local Traversal = require("lib.fp.optics.traversal")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- A lens focusing on the first element of a two-element table {a, b}.
local fst_lens = Lens.new(
	function(s) return s[1] end,
	function(s, a) return { a, s[2] } end
)

-- A lens focusing on the second element.
local snd_lens = Lens.new(
	function(s) return s[2] end,
	function(s, a) return { s[1], a } end
)

-- A prism that focuses on Just values inside a Maybe.
-- preview: Maybe a -> Maybe a   (Just x -> Just x, Nothing -> Nothing)
-- review:  a -> Maybe a         (wrap in Just)
local just_prism = Prism.new(
	function(s)
		if Maybe.is_nothing(s) then
			return Maybe.nothing
		end
		return Maybe.just(s.value)
	end,
	function(a)
		return Maybe.just(a)
	end
)

-- A prism that focuses on even numbers.
-- preview: number -> Maybe number   (Just n if n is even, Nothing otherwise)
-- review:  number -> number         (identity)
local even_prism = Prism.new(
	function(n)
		if n % 2 == 0 then
			return Maybe.just(n)
		end
		return Maybe.nothing
	end,
	function(n) return n end
)

-- ── from_lens ─────────────────────────────────────────────────────────────────

T.describe("Traversal.from_lens", function()

	T.it("traverseOf with Maybe applicative threads the focus through f", function()
		-- Traversal over the first element; f wraps it in Just.
		local t = Traversal.from_lens(fst_lens)
		local s = { 10, 20 }
		local result = Traversal.traverseOf(t, Maybe.nothing, function(a)
			return Maybe.just(a * 2)
		end, s)
		-- Result should be Just({20, 20})
		T.ok(Maybe.is_just(result))
		T.eq(result.value[1], 20)
		T.eq(result.value[2], 20)
	end)

	T.it("traverseOf propagates Nothing when f returns Nothing", function()
		local t = Traversal.from_lens(fst_lens)
		local s = { 10, 20 }
		local result = Traversal.traverseOf(t, Maybe.nothing, function(_a)
			return Maybe.nothing
		end, s)
		T.ok(Maybe.is_nothing(result))
	end)

	T.it("over modifies the single focus", function()
		local t = Traversal.from_lens(fst_lens)
		local s = { 10, 20 }
		local result = Traversal.over(t, s, function(x) return x + 5 end)
		T.eq(result[1], 15)
		T.eq(result[2], 20)
	end)

	T.it("over on snd_lens modifies second element", function()
		local t = Traversal.from_lens(snd_lens)
		local s = { 10, 20 }
		local result = Traversal.over(t, s, function(x) return x * 3 end)
		T.eq(result[1], 10)
		T.eq(result[2], 60)
	end)

	T.it("toList collects the single focus into a one-element list", function()
		local t = Traversal.from_lens(fst_lens)
		local s = { 10, 20 }
		local list = Traversal.toList(t, s)
		T.eq(#list, 1)
		T.eq(list[1], 10)
	end)

	T.it("set replaces the focus", function()
		local t = Traversal.from_lens(fst_lens)
		local s = { 10, 20 }
		local result = Traversal.set(t, s, 99)
		T.eq(result[1], 99)
		T.eq(result[2], 20)
	end)

end)

-- ── from_prism ────────────────────────────────────────────────────────────────

T.describe("Traversal.from_prism", function()

	T.it("traverseOf (hit) applies f to the focus", function()
		local t = Traversal.from_prism(just_prism)
		local s = Maybe.just(42)
		local result = Traversal.traverseOf(t, Maybe.nothing, function(a)
			return Maybe.just(a + 1)
		end, s)
		-- f(42) = Just(43); map (Prism.review) = Just(Just(43))
		T.ok(Maybe.is_just(result))
		T.ok(Maybe.is_just(result.value))
		T.eq(result.value.value, 43)
	end)

	T.it("traverseOf (miss) returns pure s", function()
		local t = Traversal.from_prism(just_prism)
		local s = Maybe.nothing
		local result = Traversal.traverseOf(t, Maybe.nothing, function(a)
			return Maybe.just(a + 1)
		end, s)
		-- No focus: result is Just(Nothing)
		T.ok(Maybe.is_just(result))
		T.ok(Maybe.is_nothing(result.value))
	end)

	T.it("traverseOf (hit) propagates Nothing from f", function()
		local t = Traversal.from_prism(even_prism)
		-- 4 is even, so prism hits
		local result = Traversal.traverseOf(t, Maybe.nothing, function(_a)
			return Maybe.nothing
		end, 4)
		T.ok(Maybe.is_nothing(result))
	end)

	T.it("over (hit) modifies the focus", function()
		local t = Traversal.from_prism(even_prism)
		local result = Traversal.over(t, 4, function(n) return n * 10 end)
		T.eq(result, 40)
	end)

	T.it("over (miss) returns s unchanged", function()
		local t = Traversal.from_prism(even_prism)
		local result = Traversal.over(t, 3, function(n) return n * 10 end)
		T.eq(result, 3)
	end)

	T.it("toList (hit) collects the focus", function()
		local t = Traversal.from_prism(even_prism)
		local list = Traversal.toList(t, 6)
		T.eq(#list, 1)
		T.eq(list[1], 6)
	end)

	T.it("toList (miss) returns empty list", function()
		local t = Traversal.from_prism(even_prism)
		local list = Traversal.toList(t, 3)
		T.eq(#list, 0)
	end)

	T.it("set (hit) replaces the focus", function()
		local t = Traversal.from_prism(even_prism)
		local result = Traversal.set(t, 4, 100)
		-- review(100) = 100  (even_prism.review is identity)
		T.eq(result, 100)
	end)

	T.it("set (miss) returns s unchanged", function()
		local t = Traversal.from_prism(even_prism)
		local result = Traversal.set(t, 3, 100)
		T.eq(result, 3)
	end)

end)

-- ── compose ───────────────────────────────────────────────────────────────────

T.describe("Traversal.compose", function()

	-- Structure: { { 2, 3 }, { 4, 5 } }
	-- t_outer: traverses first element of the outer pair -> { 2, 3 }
	-- t_inner: traverses first element of an inner pair -> 2
	-- composed: focuses on the first element of the first inner pair -> 2
	T.it("composes two lens-traversals — visits the nested focus", function()
		local t_outer = Traversal.from_lens(fst_lens)
		local t_inner = Traversal.from_lens(fst_lens)
		local composed = Traversal.compose(t_outer, t_inner)

		local s = { { 2, 3 }, { 4, 5 } }
		local list = Traversal.toList(composed, s)
		T.eq(#list, 1)
		T.eq(list[1], 2)
	end)

	T.it("compose over modifies only the composed focus", function()
		local t_outer = Traversal.from_lens(fst_lens)
		local t_inner = Traversal.from_lens(snd_lens)
		local composed = Traversal.compose(t_outer, t_inner)

		-- s = { { 10, 20 }, { 30, 40 } }
		-- composed focuses on s[1][2] = 20
		local s = { { 10, 20 }, { 30, 40 } }
		local result = Traversal.over(composed, s, function(x) return x + 1 end)
		T.eq(result[1][1], 10)
		T.eq(result[1][2], 21)
		T.eq(result[2][1], 30)
		T.eq(result[2][2], 40)
	end)

	T.it("compose with prism-traversal: hit/hit visits focus", function()
		-- t1: traversal from just_prism (focuses inside Just)
		-- t2: traversal from even_prism (focuses on even numbers)
		-- composed: focuses on even numbers inside a Just
		local t1 = Traversal.from_prism(just_prism)
		local t2 = Traversal.from_prism(even_prism)
		local composed = Traversal.compose(t1, t2)

		local list = Traversal.toList(composed, Maybe.just(8))
		T.eq(#list, 1)
		T.eq(list[1], 8)
	end)

	T.it("compose with prism-traversal: hit/miss gives empty list", function()
		local t1 = Traversal.from_prism(just_prism)
		local t2 = Traversal.from_prism(even_prism)
		local composed = Traversal.compose(t1, t2)

		local list = Traversal.toList(composed, Maybe.just(7))
		T.eq(#list, 0)
	end)

	T.it("compose with prism-traversal: miss gives empty list", function()
		local t1 = Traversal.from_prism(just_prism)
		local t2 = Traversal.from_prism(even_prism)
		local composed = Traversal.compose(t1, t2)

		local list = Traversal.toList(composed, Maybe.nothing)
		T.eq(#list, 0)
	end)

end)

-- ── Traversal law ─────────────────────────────────────────────────────────────

T.describe("Traversal law: set then toList", function()

	T.it("from_lens: toList after set gives [b, b] for both foci", function()
		-- Build a traversal over BOTH elements using compose of fst and snd lens traversals.
		-- Actually build it manually: a traversal that visits both elements.
		-- We'll use a hand-written traverseOf for a pair.
		local Applicable = require("lib.fp.applicable")
		local Mappable   = require("lib.fp.mappable")

		-- Traversal over both elements of a two-element table.
		-- traverseOf(ctor, f, {a, b}) = ap(map(\a' -> \b' -> {a',b'}, f(a)), f(b))
		local both = Traversal.new(function(ctor, f, s)
			local fa = f(s[1])
			local fb = f(s[2])
			local fcons = Mappable.map(function(a)
				return function(b) return { a, b } end
			end, fa)
			return Applicable.ap(fcons, fb)
		end)

		local s = { 10, 20 }

		-- toList gives [10, 20]
		local list_before = Traversal.toList(both, s)
		T.eq(#list_before, 2)
		T.eq(list_before[1], 10)
		T.eq(list_before[2], 20)

		-- set all foci to 99
		local s2 = Traversal.set(both, s, 99)

		-- toList now gives [99, 99]
		local list_after = Traversal.toList(both, s2)
		T.eq(#list_after, 2)
		T.eq(list_after[1], 99)
		T.eq(list_after[2], 99)
	end)

	T.it("from_prism: toList after set gives [b] on hit", function()
		local t = Traversal.from_prism(even_prism)

		local list_before = Traversal.toList(t, 4)
		T.eq(#list_before, 1)
		T.eq(list_before[1], 4)

		local s2 = Traversal.set(t, 4, 100)
		local list_after = Traversal.toList(t, s2)
		T.eq(#list_after, 1)
		T.eq(list_after[1], 100)
	end)

end)
