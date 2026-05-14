-- bin/cr-open.lua — delegates to lib/cr/open.lua
local M = {}
function M.main(argv) return require("lib.cr.open").main(argv) end
return M
