if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Byte-level encodings and transforms.
-- require("lib.encode.base64") for Base64
-- require("lib.encode.urlencode") for URL encoding
-- require("lib.encode.utf8") for UTF-8 utilities
local M = {}
M.base64   = require("lib.encode.base64")
M.urlencode = require("lib.encode.urlencode")
M.utf8     = require("lib.encode.utf8")
return M
