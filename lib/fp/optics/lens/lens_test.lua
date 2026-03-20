-- lib/fp/optics/lens/lens_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local Lens = require("lib.fp.optics.lens")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- A simple lens that focuses on the first element of a two-element table.
local fst_lens = Lens.new(
	function(s) return s[1] end,
	function(s, a)
		return { a, s[2] }
	end
)

-- A lens that focuses on the second element.
local snd_lens = Lens.new(
	function(s) return s[2] end,
	function(s, a)
		return { s[1], a }
	end
)

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("Lens", function()

	-- GetSet law: get(set(s, a)) == a
	T.it("get/set roundtrip: get(set(s, a)) == a", function()
		local s = { 10, 20 }
		T.eq(Lens.get(fst_lens, Lens.set(fst_lens, s, 99)), 99)
	end)

	-- SetGet law: set(s, get(s)) == s
	T.it("set/get law: set(s, get(s)) == s", function()
		local s = { 10, 20 }
		local result = Lens.set(fst_lens, s, Lens.get(fst_lens, s))
		T.eq(result[1], s[1])
		T.eq(result[2], s[2])
	end)

	-- SetSet law: set(set(s, a), b) == set(s, b)
	T.it("set/set law: set(set(s, a), b) == set(s, b)", function()
		local s = { 10, 20 }
		local result1 = Lens.set(fst_lens, Lens.set(fst_lens, s, 42), 99)
		local result2 = Lens.set(fst_lens, s, 99)
		T.eq(result1[1], result2[1])
		T.eq(result1[2], result2[2])
	end)

	T.it("over applies a function to the focus", function()
		local s = { 10, 20 }
		local result = Lens.over(fst_lens, s, function(x) return x + 1 end)
		T.eq(result[1], 11)
		T.eq(result[2], 20)
	end)

	T.it("compose: lens1 then lens2 — focuses on inner element", function()
		-- Nest: { outer, { inner1, inner2 } }
		-- lens for second element of outer, then first element of that
		local outer_snd = Lens.new(
			function(s) return s[2] end,
			function(s, a) return { s[1], a } end
		)
		local inner_fst = Lens.new(
			function(s) return s[1] end,
			function(s, a) return { a, s[2] } end
		)
		local composed = Lens.compose(outer_snd, inner_fst)
		local s = { "a", { 10, 20 } }

		T.eq(Lens.get(composed, s), 10)

		local result = Lens.set(composed, s, 99)
		T.eq(result[1], "a")
		T.eq(result[2][1], 99)
		T.eq(result[2][2], 20)
	end)

	T.it("Lens.field: gets named field", function()
		local name_lens = Lens.field("name")
		local s = { name = "alice", age = 30 }
		T.eq(Lens.get(name_lens, s), "alice")
	end)

	T.it("Lens.field: sets named field via shallow copy", function()
		local name_lens = Lens.field("name")
		local s = { name = "alice", age = 30 }
		local result = Lens.set(name_lens, s, "bob")
		T.eq(result.name, "bob")
		T.eq(result.age, 30)
		-- original is not mutated
		T.eq(s.name, "alice")
	end)

	T.it("Lens.field: over modifies named field", function()
		local age_lens = Lens.field("age")
		local s = { name = "alice", age = 30 }
		local result = Lens.over(age_lens, s, function(n) return n + 1 end)
		T.eq(result.age, 31)
		T.eq(result.name, "alice")
	end)

	T.it("from_iso: promotes an Iso to a Lens", function()
		local Iso = require("lib.fp.optics.iso")
		local negate_iso = Iso.new(
			function(n) return -n end,
			function(n) return -n end
		)
		local lens = Lens.from_iso(negate_iso)
		T.eq(Lens.get(lens, 5), -5)
		-- set ignores original s, reconstructs via review
		T.eq(Lens.set(lens, 0, -7), 7)
	end)

end)
