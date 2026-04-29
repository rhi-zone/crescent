-- lib/formats/ccv2/adapters/import.lua
-- Converts CCv2 card PNG or JSON into crescent internal representation.
--
-- API:
--   import.from_png(bytes) -> { card, lorebook? } | nil, err
--   import.from_json(str)  -> { card, lorebook? } | nil, err

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local card_mod = require("lib.formats.ccv2.card")
local lorebook = require("lib.formats.ccv2.lorebook")

local M = {}

-- card.from_json/from_png return flat normalized data with character_book
-- as a direct field (not nested under .data).
local function extract_lorebook(data)
	if not data then return nil end
	local book = data.character_book
	if not book then return nil end
	return lorebook.from_ccv2(book)
end

--: (string) -> ({ card: table, lorebook: (table | nil) } | nil, string)
function M.from_png(bytes)
	local data, err = card_mod.from_png(bytes)
	if not data then return nil, err end
	local entries = extract_lorebook(data)
	return { card = data, lorebook = entries }
end

--: (string) -> ({ card: table, lorebook: (table | nil) } | nil, string)
function M.from_json(str)
	local data, err = card_mod.from_json(str)
	if not data then return nil, err end
	local entries = extract_lorebook(data)
	return { card = data, lorebook = entries }
end

return M
