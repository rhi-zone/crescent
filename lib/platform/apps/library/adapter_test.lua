-- lib/platform/apps/library/adapter_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local adapter = require("lib.platform.apps.library.adapter")

-- ── Test data ────────────────────────────────────────────────────────────────

local function make_items()
	return {
		{
			id = "app-1",
			metadata = { name = "Calculator", category = "utility" },
			open = function() end,
		},
		{
			id = "app-2",
			metadata = { name = "Notes", category = "productivity" },
			open = function() end,
		},
		{
			id = "app-3",
			metadata = { name = "Music Player", category = "media" },
			open = function() end,
		},
	}
end

-- ── Static adapter ───────────────────────────────────────────────────────────

T.describe("adapter.static", function()
	T.it("list returns all items", function()
		local src = adapter.static(make_items())
		local result = src.list()
		T.eq(#result, 3)
		T.eq(result[1].id, "app-1")
		T.eq(result[2].id, "app-2")
		T.eq(result[3].id, "app-3")
	end)

	T.it("list returns empty for empty input", function()
		local src = adapter.static({})
		T.eq(#src.list(), 0)
	end)

	T.it("search matches metadata name (case-insensitive)", function()
		local src = adapter.static(make_items())
		local result = src.search("calc")
		T.eq(#result, 1)
		T.eq(result[1].id, "app-1")
	end)

	T.it("search matches metadata category", function()
		local src = adapter.static(make_items())
		local result = src.search("media")
		T.eq(#result, 1)
		T.eq(result[1].id, "app-3")
	end)

	T.it("search is case-insensitive", function()
		local src = adapter.static(make_items())
		local result = src.search("NOTES")
		T.eq(#result, 1)
		T.eq(result[1].id, "app-2")
	end)

	T.it("search returns empty when nothing matches", function()
		local src = adapter.static(make_items())
		local result = src.search("zzzzz")
		T.eq(#result, 0)
	end)

	T.it("search matches multiple items", function()
		local src = adapter.static(make_items())
		-- "ity" matches "utility" and "productivity"
		local result = src.search("ity")
		T.eq(#result, 2)
	end)

	T.it("search does not match non-string metadata values", function()
		local items = {
			{
				id = "x",
				metadata = { name = "Test", count = 42 },
				open = function() end,
			},
		}
		local src = adapter.static(items)
		local result = src.search("42")
		T.eq(#result, 0)
	end)

	T.it("search does not duplicate items with multiple matching fields", function()
		local items = {
			{
				id = "x",
				metadata = { name = "Music Notes", category = "music" },
				open = function() end,
			},
		}
		local src = adapter.static(items)
		-- "music" matches both name and category
		local result = src.search("music")
		T.eq(#result, 1)
	end)
end)

-- ── Composite adapter ────────────────────────────────────────────────────────

T.describe("adapter.composite", function()
	T.it("list merges all sources", function()
		local src1 = adapter.static({
			{ id = "a", metadata = { name = "A" }, open = function() end },
		})
		local src2 = adapter.static({
			{ id = "b", metadata = { name = "B" }, open = function() end },
			{ id = "c", metadata = { name = "C" }, open = function() end },
		})
		local comp = adapter.composite({ src1, src2 })
		local result = comp.list()
		T.eq(#result, 3)
		T.eq(result[1].id, "a")
		T.eq(result[2].id, "b")
		T.eq(result[3].id, "c")
	end)

	T.it("list with empty sources", function()
		local comp = adapter.composite({})
		T.eq(#comp.list(), 0)
	end)

	T.it("search across multiple sources", function()
		local src1 = adapter.static({
			{ id = "a", metadata = { name = "Alpha" }, open = function() end },
		})
		local src2 = adapter.static({
			{ id = "b", metadata = { name = "Beta" }, open = function() end },
			{ id = "c", metadata = { name = "Alphabet" }, open = function() end },
		})
		local comp = adapter.composite({ src1, src2 })
		local result = comp.search("alph")
		T.eq(#result, 2)
		T.eq(result[1].id, "a")
		T.eq(result[2].id, "c")
	end)

	T.it("search returns empty when no matches across sources", function()
		local src1 = adapter.static({
			{ id = "a", metadata = { name = "Alpha" }, open = function() end },
		})
		local src2 = adapter.static({
			{ id = "b", metadata = { name = "Beta" }, open = function() end },
		})
		local comp = adapter.composite({ src1, src2 })
		T.eq(#comp.search("zzz"), 0)
	end)
end)
