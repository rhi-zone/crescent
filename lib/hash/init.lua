--- Hash algorithms.
-- require("lib.hash.sha256") for SHA-256
-- require("lib.hash.sha1") for SHA-1
local M = {}
M.sha256 = require("lib.hash.sha256")
M.sha1   = require("lib.hash.sha1")
return M
