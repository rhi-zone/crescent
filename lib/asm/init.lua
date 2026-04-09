-- lib/asm/init.lua
-- Assembly/SIMD support: CPU feature detection and kernel compilation.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}
M.cpu = require("lib.asm.cpu")
return M
