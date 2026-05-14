-- lib/encode/base64/base64url.lua
-- URL-safe base64 (RFC 4648 §5) — thin wrapper around init.lua with opts.url=true.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.encode.base64")

local M = {}
local URL_OPTS = { url = true, pad = nil } --: { pad: boolean | nil, url: boolean | nil }

--: (string, { pad: boolean | nil, url: boolean | nil } | nil) -> string
M.encode = function(str, opts)
    if opts then
        opts.url = true
        return base64.encode(str, opts)
    end
    return base64.encode(str, URL_OPTS)
end

--: (string, { url: boolean | nil } | nil) -> (string | nil, string | nil)
M.decode = function(b64, _opts)
    return base64.decode(b64, URL_OPTS)
end

return M
