-- bin/cr-run.lua — delegates to lib/cr/run.lua
local M = {}
function M.main(argv) return require("lib.cr.run").main(argv) end
return M
