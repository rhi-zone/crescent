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

-- ── Index adapter ───────────────────────────────────────────────────────────

-- Fake index that mimics the interface of lib/platform/index.lua.
local function mock_index(rows)
	return {
		list = function(_, filter)
			if filter and filter.tag then
				local out = {}
				for _, r in ipairs(rows) do
					for _, t in ipairs(r.tags or {}) do
						if t == filter.tag then
							out[#out + 1] = r
							break
						end
					end
				end
				return out
			end
			return rows
		end,
		search = function(_, query)
			local q = query:lower()
			local out = {}
			for _, r in ipairs(rows) do
				if r.name and r.name:lower():find(q, 1, true) then
					out[#out + 1] = r
				end
			end
			return out
		end,
	}
end

local SAMPLE_ROWS = {
	{
		id = 1, name = "Alice", path = "/apps/alice.png",
		manifest = { meta = { description = "A helpful assistant" } },
		tags = { "ai", "chat" }, installed_at = 1000,
	},
	{
		id = 2, name = "Calculator", path = "/apps/calc.png",
		manifest = { meta = { description = "Math tool" } },
		tags = { "utility", "math" }, installed_at = 2000,
	},
	{
		id = 3, name = "Dungeon Master", path = "/apps/dm.png",
		manifest = { meta = { description = "RPG adventure" } },
		tags = { "ai", "roleplay" }, installed_at = 3000,
	},
}

T.describe("adapter.index", function()
	T.it("list returns all apps as items", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx)
		local items = src.list()
		T.eq(#items, 3)
		T.eq(items[1].id, "1")
		T.eq(items[1].metadata.name, "Alice")
		T.eq(items[2].metadata.name, "Calculator")
	end)

	T.it("list with tag filter", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx, { tag = "ai" })
		local items = src.list()
		T.eq(#items, 2)
		T.eq(items[1].metadata.name, "Alice")
		T.eq(items[2].metadata.name, "Dungeon Master")
	end)

	T.it("search delegates to index search", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx)
		local items = src.search("calc")
		T.eq(#items, 1)
		T.eq(items[1].metadata.name, "Calculator")
	end)

	T.it("search returns empty for no match", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx)
		T.eq(#src.search("zzz"), 0)
	end)

	T.it("items have metadata fields", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx)
		local items = src.list()
		T.eq(items[1].metadata.description, "A helpful assistant")
		T.eq(items[1].metadata.tags, "ai, chat")
		T.eq(items[1].metadata.path, "/apps/alice.png")
	end)

	T.it("on_open callback is called when item.open is invoked", function()
		local opened = {}
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx, {
			on_open = function(row) opened[#opened + 1] = row.name end,
		})
		local items = src.list()
		T.ok(items[1].open)
		items[1].open()
		T.eq(#opened, 1)
		T.eq(opened[1], "Alice")
	end)

	T.it("items have no open when on_open not provided", function()
		local idx = mock_index(SAMPLE_ROWS)
		local src = adapter.index(idx)
		local items = src.list()
		T.eq(items[1].open, nil)
	end)

	T.it("handles rows with minimal data", function()
		local rows = {
			{ id = 99, name = nil, path = "", manifest = nil, tags = nil, installed_at = 0 },
		}
		local idx = mock_index(rows)
		local src = adapter.index(idx)
		local items = src.list()
		T.eq(#items, 1)
		T.eq(items[1].metadata.name, "Unknown")
		T.eq(items[1].metadata.description, "")
		T.eq(items[1].metadata.tags, "")
	end)

	T.it("composable with other adapters", function()
		local idx = mock_index(SAMPLE_ROWS)
		local idx_src = adapter.index(idx)
		local static_src = adapter.static({
			{ id = "manual", metadata = { name = "Manual Entry" }, open = function() end },
		})
		local comp = adapter.composite({ idx_src, static_src })
		local items = comp.list()
		T.eq(#items, 4)
		T.eq(items[4].metadata.name, "Manual Entry")
	end)
end)
