-- lib/platform/apps/charactercardv2/init.lua
-- Card app -- re-exports the server module. LLM access goes through caps.llm
-- (backed by lib/ai/) — apps do not implement their own LLM client.

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.server = require("lib.platform.apps.charactercardv2.server")

return M
