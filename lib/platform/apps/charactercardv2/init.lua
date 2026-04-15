-- lib/platform/apps/charactercardv2/init.lua
-- Card app -- re-exports server and llm modules.

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.server = require("lib.platform.apps.charactercardv2.server")
M.llm    = require("lib.platform.apps.charactercardv2.llm")

return M
