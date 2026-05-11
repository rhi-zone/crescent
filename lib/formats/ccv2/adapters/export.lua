-- lib/formats/ccv2/adapters/export.lua
-- Converts crescent internal representation back to CCv2 card PNG or JSON.
--
-- API:
--   export.to_png(card, lorebook?, png_bytes?) -> bytes | nil, err
--   export.to_json(card, lorebook?)            -> str | nil, err

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local card_mod = require("lib.formats.ccv2.card")
local lorebook = require("lib.formats.ccv2.lorebook")

local M = {}

-- Shallow-copy card data and attach/remove character_book.
local function with_lorebook(data, entries)
	local out = {}
	for k, v in pairs(data) do out[k] = v end
	if entries then
		local entries_ = entries --[[:! { [integer]: any }]]
		if #entries_ > 0 then
			local lorebook_any = lorebook --[[: unknown]]
			out.character_book = lorebook_any.to_ccv2(entries_)
		else
			out.character_book = nil
		end
	else
		out.character_book = nil
	end
	return out
end

--: (unknown, (unknown | nil), (string | nil)) -> (string | nil, string)
function M.to_png(data, entries, png_bytes)
	local out = with_lorebook(data, entries)
	return card_mod.to_png(out, png_bytes)
end

--: (unknown, (unknown | nil)) -> (string | nil, string)
function M.to_json(data, entries)
	local out = with_lorebook(data, entries)
	return card_mod.to_json(out)
end

return M
