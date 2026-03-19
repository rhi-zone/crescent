if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Hash algorithms.
-- require("lib.hash.sha256") for SHA-256
-- require("lib.hash.sha1") for SHA-1
local M = {}
M.sha256 = require("lib.hash.sha256")
M.sha1   = require("lib.hash.sha1")
return M
