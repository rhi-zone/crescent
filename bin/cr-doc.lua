-- bin/cr-doc.lua — delegates to lib/doc/cli.lua
local M = {}
function M.main(argv) return require("lib.doc.cli").main(argv) end
return M
