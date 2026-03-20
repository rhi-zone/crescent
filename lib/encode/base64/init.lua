-- lib/encode/base64/init.lua
-- Base64 encoding and decoding (RFC 4648 §4 standard, §5 URL-safe).

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, rshift = bit.band, bit.rshift

local M = {}

-- Standard alphabet (RFC 4648 §4): A-Z a-z 0-9 + /
local STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- URL-safe alphabet (RFC 4648 §5): A-Z a-z 0-9 - _
local URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function make_tables(chars)
    local enc = {}
    local dec = {}
    for i = 1, 64 do
        local c = chars:byte(i)
        enc[i - 1] = c
        dec[c] = i - 1
    end
    return enc, dec
end

local std_enc, std_dec = make_tables(STD)
local url_enc, url_dec = make_tables(URL)
local PAD = string.byte("=")

-- Encode binary string to base64.
-- opts.url = true  → URL-safe alphabet (- _ instead of + /)
-- opts.pad = false → omit = padding (default: include padding)
--: (string, { url: boolean?, pad: boolean? }?) -> string
M.encode = function(str, opts)
    local enc = (opts and opts.url) and url_enc or std_enc
    local pad = not (opts and opts.pad == false)
    local n = #str
    local lastn = n % 3
    local t = {}
    local k = 1
    for i = 1, n - lastn, 3 do
        local a, b, c = str:byte(i, i + 2)
        local v = a * 0x10000 + b * 0x100 + c
        t[k] = string.char(
            enc[band(rshift(v, 18), 0x3f)],
            enc[band(rshift(v, 12), 0x3f)],
            enc[band(rshift(v,  6), 0x3f)],
            enc[band(v,            0x3f)]
        )
        k = k + 1
    end
    if lastn == 2 then
        local a, b = str:byte(n - 1, n)
        local v = a * 0x10000 + b * 0x100
        if pad then
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], enc[band(rshift(v,6),0x3f)], PAD)
        else
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], enc[band(rshift(v,6),0x3f)])
        end
    elseif lastn == 1 then
        local v = str:byte(n) * 0x10000
        if pad then
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], PAD, PAD)
        else
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)])
        end
    end
    return table.concat(t)
end

-- Decode base64 string to binary.
-- opts.url = true → URL-safe alphabet (- _ instead of + /)
-- Whitespace is ignored. Returns nil, err on invalid input.
--: (string, { url: boolean? }?) -> string
M.decode = function(b64, opts)
    local dec = (opts and opts.url) and url_dec or std_dec
    b64 = b64:gsub("%s", "")
    local n = #b64
    if n == 0 then return "" end
    -- Strip trailing = padding
    local padding = 0
    if b64:sub(-2) == "==" then
        padding = 2
        b64 = b64:sub(1, n - 2)
        n = n - 2
    elseif b64:sub(-1) == "=" then
        padding = 1
        b64 = b64:sub(1, n - 1)
        n = n - 1
    end
    -- After stripping padding, remainder mod 4 must not be 1
    local rem = n % 4
    if rem == 1 then
        return nil, "invalid base64: bad length"
    end
    local t = {}
    local k = 1
    -- Full 4-character groups
    for i = 1, n - rem, 4 do
        local a, b, c, d = b64:byte(i, i + 3)
        local da, db, dc, dd = dec[a], dec[b], dec[c], dec[d]
        if not da or not db or not dc or not dd then
            return nil, "invalid base64: bad character at byte " .. i
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40 + dd
        t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff), band(v,0xff))
        k = k + 1
    end
    -- Partial final group (2 or 3 chars after padding was stripped)
    if rem == 3 then
        local a, b, c = b64:byte(n - 2, n)
        local da, db, dc = dec[a], dec[b], dec[c]
        if not da or not db or not dc then
            return nil, "invalid base64: bad character in final group"
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40
        t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff))
    elseif rem == 2 then
        local a, b = b64:byte(n - 1, n)
        local da, db = dec[a], dec[b]
        if not da or not db then
            return nil, "invalid base64: bad character in final group"
        end
        local v = da * 0x40000 + db * 0x1000
        t[k] = string.char(band(rshift(v,16),0xff))
    end
    return table.concat(t)
end

return M
