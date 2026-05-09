-- bin/cr-lint.lua — delegates to lib/stdlib/lint_cli.lua
local M = {}
function M.main(argv) return require("lib.stdlib.lint_cli").main(argv) end
return M
