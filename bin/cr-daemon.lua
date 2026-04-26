-- bin/cr-daemon.lua — delegates to lib/platform/daemon/cli.lua
local M = {}
function M.main(argv) return require("lib.platform.daemon.cli").main(argv) end
return M
