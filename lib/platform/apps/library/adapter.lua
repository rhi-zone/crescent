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

return M
