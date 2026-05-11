-- lib/encode/base64/base64url.lua
-- URL-safe base64 (RFC 4648 §5) — thin wrapper around init.lua with opts.url=true.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.encode.base64") --[[: unknown]]

local M = {}
local URL_OPTS = {url = true}

--: (string, { pad: boolean | nil, url: boolean | nil } | nil) -> string
M.encode = function(str, opts)
    if opts then
        opts.url = true
        return base64.encode(str, opts)
    end
    return base64.encode(str, URL_OPTS)
end

--: (string) -> string
M.decode = function(b64)
    return base64.decode(b64, URL_OPTS)
end

return M
