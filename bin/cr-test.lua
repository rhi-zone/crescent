-- bin/cr-test.lua — delegates to lib/test/cli.lua
if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end
local M = {}
function M.main(argv) return require("lib.test.cli").main(argv) end
return M
