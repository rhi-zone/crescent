-- lib/platform/apps/card/init.lua
-- Card app -- re-exports server and llm modules.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.server = require("lib.platform.apps.card.server")
M.llm    = require("lib.platform.apps.card.llm")

return M
