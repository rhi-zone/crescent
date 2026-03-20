-- lib/fp/optics/iso/iso_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local Iso = require("lib.fp.optics.iso")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Iso between a number and its negation.
local negate_iso = Iso.new(
	function(n) return -n end,
	function(n) return -n end
)

-- Iso between a string and its length (non-injective in general, but good enough
-- for roundtrip tests on a single value where we control both directions).
-- Use a simple wrap/unwrap pair for clean roundtrips.
local wrap_iso = Iso.new(
	function(s) return { wrapped = s } end,
	function(t) return t.wrapped end
)

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("Iso", function()

	T.it("get applies the forward direction", function()
		T.eq(Iso.get(negate_iso, 5), -5)
	end)

	T.it("review applies the backward direction", function()
		T.eq(Iso.review(negate_iso, -5), 5)
	end)

	-- Roundtrip law 1: get(review(a)) == a
	T.it("get(review(a)) == a", function()
		T.eq(Iso.get(negate_iso, Iso.review(negate_iso, 7)), 7)
		T.eq(Iso.get(wrap_iso, Iso.review(wrap_iso, { wrapped = "hi" })).wrapped, "hi")
	end)

	-- Roundtrip law 2: review(get(s)) == s
	T.it("review(get(s)) == s", function()
		T.eq(Iso.review(negate_iso, Iso.get(negate_iso, 3)), 3)
		T.eq(Iso.review(wrap_iso, Iso.get(wrap_iso, "hello")), "hello")
	end)

	T.it("flip swaps directions", function()
		local flipped = Iso.flip(negate_iso)
		-- flipped.get == original.review, flipped.review == original.get
		T.eq(Iso.get(flipped, -5), 5)
		T.eq(Iso.review(flipped, 5), -5)
	end)

	T.it("flip roundtrip: flip(flip(iso)) is equivalent to iso", function()
		local double_flip = Iso.flip(Iso.flip(negate_iso))
		T.eq(Iso.get(double_flip, 4), -4)
		T.eq(Iso.review(double_flip, -4), 4)
	end)

	T.it("compose: iso1 then iso2", function()
		-- iso1: number <-> negated number  (n <-> -n)
		-- iso2: number <-> doubled number  (n <-> 2*n)
		local double_iso = Iso.new(
			function(n) return n * 2 end,
			function(n) return n / 2 end
		)
		-- composed: n -> (-n) -> (-n)*2  i.e. n -> -2n
		local composed = Iso.compose(negate_iso, double_iso)
		T.eq(Iso.get(composed, 3), -6)
		T.eq(Iso.review(composed, -6), 3)
	end)

	T.it("to_lens: get matches iso.get", function()
		local lens = Iso.to_lens(wrap_iso)
		local result = lens.get("hello")
		T.eq(result.wrapped, "hello")
	end)

	T.it("to_lens: set reconstructs via review", function()
		local lens = Iso.to_lens(wrap_iso)
		-- set ignores s, reconstructs from a via review
		local result = lens.set("anything", { wrapped = "world" })
		T.eq(result, "world")
	end)

end)
