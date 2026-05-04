-- lib/platform/apps/library/adapter.lua
-- Adapter interface for the library browser.
--
-- An adapter is a table with:
--   list()         -> { { id = string, metadata = table, open = function }[] }
--   search(query)  -> same shape, filtered by query
--   write(id, metadata) -> true | nil, err  (optional, for writable sources)
--
-- This module provides adapter constructors: static() and composite().

local M = {}

-- static(items) -> adapter
-- Wraps a pre-loaded array of items. Useful for testing and for adapters
-- that load all data upfront.
function M.static(items)
	return {
		list = function() return items end,
		search = function(query)
			local q = query:lower()
			local results = {}
			for _, item in ipairs(items) do
				for _, v in pairs(item.metadata) do
					if type(v) == "string" and v:lower():find(q, 1, true) then
						results[#results + 1] = item
						break
					end
				end
			end
			return results
		end,
	}
end

-- composite(sources) -> adapter
-- Merges multiple adapters into one. list() and search() concatenate results
-- from all sources in order.
function M.composite(sources)
	return {
		list = function()
			local all = {}
			for _, src in ipairs(sources) do
				for _, item in ipairs(src.list()) do
					all[#all + 1] = item
				end
			end
			return all
		end,
		search = function(query)
			local all = {}
			for _, src in ipairs(sources) do
				for _, item in ipairs(src.search(query)) do
					all[#all + 1] = item
				end
			end
			return all
		end,
	}
end

-- index(idx, opts?) -> adapter
-- Wraps an app index (lib/platform/index.lua) as an adapter source.
-- opts.tag: optional tag filter for list()
-- opts.on_open: function(row) called when an item is opened
function M.index(idx, opts)
	local idx_ = idx --[[:! { list: unknown, search: unknown }]]
	opts = opts or {}
	local tag_filter = opts.tag
	local on_open = opts.on_open

	local function row_to_item(row)
		local meta = row.manifest and row.manifest.meta or {}
		return {
			id = tostring(row.id),
			metadata = {
				name = row.name or "Unknown",
				description = meta.description or "",
				tags = table.concat((row.tags or {}) --[[:! { [integer]: string | number }]], ", "),
				path = row.path or "",
			},
			open = on_open and function() local f_ = on_open --[[:! (unknown) -> nil]]; f_(row) end or nil,
		}
	end

	return {
		list = function()
			local filter = tag_filter and { tag = tag_filter } or nil
			local rows = (idx_ --[[: any]]):list(filter)
			local items = {}
			for i = 1, #rows do
				items[i] = row_to_item(rows[i])
			end
			return items
		end,
		search = function(query)
			local rows = (idx_ --[[: any]]):search(query)
			local items = {}
			for i = 1, #rows do
				items[i] = row_to_item(rows[i])
			end
			return items
		end,
	}
end

return M
