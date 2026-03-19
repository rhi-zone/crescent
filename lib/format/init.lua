--- Data serialization formats.
-- require("lib.format.json") for JSON
-- require("lib.format.cbor") for CBOR
local M = {}
M.json = require("lib.format.json")
M.cbor = require("lib.format.cbor")
M.toml = require("lib.format.toml")
return M
