-- bin/cr-check.lua — delegates to lib/type/static/cli.lua
local M = {}
function M.main(argv) return require("lib.type.static.cli").main(argv) end
return M
