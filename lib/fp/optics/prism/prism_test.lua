-- lib/fp/optics/prism/prism_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local Maybe  = require("lib.fp.maybe")
local Either = require("lib.fp.either")
local Prism  = require("lib.fp.optics.prism")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- A prism that focuses on Just values inside a Maybe.
-- preview: Maybe a -> Maybe a   (Just x -> Just x, Nothing -> Nothing)
-- review:  a -> Maybe a         (wrap in Just)
local just_prism = Prism.new(
	function(s)
		-- s is a Maybe a; we return Maybe a directly
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
-- preview: number -> Maybe number  (Just n if even, Nothing if odd)
-- review:  number -> number        (identity; the review just returns the number)
local even_prism = Prism.new(
	function(n)
		if n % 2 == 0 then
			return Maybe.just(n)
		end
		return Maybe.nothing
	end,
	function(n) return n end
)

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("Prism", function()

	T.it("preview hit: returns Just a", function()
		local result = Prism.preview(even_prism, 4)
		T.ok(Maybe.is_just(result))
		T.eq(result.value, 4)
	end)

	T.it("preview miss: returns Nothing", function()
		local result = Prism.preview(even_prism, 3)
		T.ok(Maybe.is_nothing(result))
	end)

	T.it("review constructs the value", function()
		T.eq(Prism.review(even_prism, 6), 6)
	end)

	-- review then preview roundtrip: preview(review(a)) == Just a
	T.it("review then preview roundtrip", function()
		local a = 8
		local result = Prism.preview(even_prism, Prism.review(even_prism, a))
		T.ok(Maybe.is_just(result))
		T.eq(result.value, a)
	end)

	T.it("matching: Right on hit", function()
		local result = Prism.matching(even_prism, 4)
		T.ok(Either.is_right(result))
		T.eq(result.value, 4)
	end)

	T.it("matching: Left on miss", function()
		local result = Prism.matching(even_prism, 3)
		T.ok(Either.is_left(result))
		T.eq(result.value, 3)
	end)

	T.it("over: modifies focus on hit", function()
		local result = Prism.over(even_prism, 4, function(n) return n * 10 end)
		T.eq(result, 40)
	end)

	T.it("over: identity on miss", function()
		local result = Prism.over(even_prism, 3, function(n) return n * 10 end)
		T.eq(result, 3)
	end)

	T.it("compose: p1 then p2 — hit/hit", function()
		-- p1: focuses on Just values inside a Maybe (preview: Maybe->Maybe a)
		-- p2: focuses on even numbers
		-- composed: focuses on even numbers inside a Just(Maybe a)

		-- A prism that extracts even numbers from inside a Just.
		local composed = Prism.compose(just_prism, even_prism)

		-- Just(4): just_prism hits (gives 4), even_prism hits (4 is even)
		local result = Prism.preview(composed, Maybe.just(4))
		T.ok(Maybe.is_just(result))
		T.eq(result.value, 4)
	end)

	T.it("compose: p1 then p2 — hit/miss", function()
		local composed = Prism.compose(just_prism, even_prism)

		-- Just(3): just_prism hits (gives 3), even_prism misses (3 is odd)
		local result = Prism.preview(composed, Maybe.just(3))
		T.ok(Maybe.is_nothing(result))
	end)

	T.it("compose: p1 then p2 — miss", function()
		local composed = Prism.compose(just_prism, even_prism)

		-- Nothing: just_prism misses immediately
		local result = Prism.preview(composed, Maybe.nothing)
		T.ok(Maybe.is_nothing(result))
	end)

	T.it("compose: review goes through both prisms", function()
		local composed = Prism.compose(just_prism, even_prism)
		-- review(6) via composed: even_prism.review(6) = 6, then just_prism.review(6) = Just(6)
		local result = Prism.review(composed, 6)
		T.ok(Maybe.is_just(result))
		T.eq(result.value, 6)
	end)

end)
