if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Data serialization formats.
-- require("lib.format.json") for JSON
-- require("lib.format.cbor") for CBOR
local M = {}
M.json = require("lib.format.json")
M.cbor = require("lib.format.cbor")
M.toml = require("lib.format.toml")
M.msgpack = require("lib.format.msgpack")
return M
