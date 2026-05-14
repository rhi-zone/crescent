-- bin/cr-uninstall.lua — delegates to lib/cr/uninstall.lua
local M = {}
function M.main(argv) return require("lib.cr.uninstall").main(argv) end
return M
