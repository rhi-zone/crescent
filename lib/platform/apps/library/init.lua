-- lib/platform/apps/library/init.lua
-- Library app — a general-purpose collection browser with an adapter interface.
--
-- Re-exports the adapter and DOM modules.

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.adapter = require("lib.platform.apps.library.adapter")
M.dom = require("lib.platform.apps.library.dom")

return M
