-- bin/cr-info.lua — delegates to lib/pkg/cli.lua
local M = {}
function M.main(argv)
  local args = { [1] = "info" }
  for i = 1, #argv do args[i + 1] = argv[i] end
  return require("lib.pkg.cli").main(args)
end
return M
