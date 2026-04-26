-- bin/cr-platform.lua — delegates to lib/platform/cli.lua
local M = {}
function M.main(argv) return require("lib.platform.cli").main(argv) end
return M
