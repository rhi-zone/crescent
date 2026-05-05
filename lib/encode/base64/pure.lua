-- lib/encode/base64/pure.lua
-- Tier 1: Pure Lua base64 (RFC 4648 §4 standard, §5 URL-safe).
-- Works on PUC-Rio Lua 5.2+ and LuaJIT.

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

local function make_enc(chars)
    local enc = {}
    for i = 1, 64 do
        enc[i - 1] = chars:byte(i)
    end
    return enc
end

local function make_dec(chars)
    local dec = {}
    for i = 1, 64 do
        dec[chars:byte(i)] = i - 1
    end
    return dec
end

local std_enc = make_enc(STD)
local url_enc = make_enc(URL)
local std_dec = make_dec(STD)
local url_dec = make_dec(URL)
local PAD = string.byte("=")

-- Encode binary string to base64.
-- opts.url = true  → URL-safe alphabet (- _ instead of + /)
-- opts.pad = false → omit = padding (default: include padding)
--: (string, { url: boolean | nil, pad: boolean | nil } | nil) -> string
M.encode = function(str, opts)
    local enc = (opts and opts.url) and url_enc or std_enc
    local pad = not (opts and opts.pad == false)
    local n = #str
    local lastn = n % 3
    local t = {}
    local k = 1
    for i = 1, n - lastn, 3 do
        local a, b, c = str:byte(i, i + 2)
        local v = (a or 0) * 0x10000 + (b or 0) * 0x100 + (c or 0)
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
        local v = (a or 0) * 0x10000 + (b or 0) * 0x100
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
-- Whitespace (space, tab, CR, LF) is skipped inline. Returns nil, err on invalid input.
--: (string, { url: boolean | nil } | nil) -> string
M.decode = function(b64, opts)
    local dec = (opts and opts.url) and url_dec or std_dec
    local n = #b64
    if n == 0 then return "" end

    -- Collect non-whitespace bytes inline, stripping padding as we go.
    -- We need to know the effective length first to detect bad-length errors.
    local bytes = {}
    local nb = 0
    local padding = 0
    local saw_pad = false
    for i = 1, n do
        local byte = b64:byte(i)
        -- Skip whitespace: space(0x20), tab(0x09), LF(0x0A), CR(0x0D)
        if byte == 0x20 or byte == 0x09 or byte == 0x0A or byte == 0x0D then
            -- skip
        elseif byte == PAD then
            if not saw_pad then
                saw_pad = true
                padding = 1
            else
                padding = 2
            end
        elseif not saw_pad then
            nb = nb + 1
            bytes[nb] = byte
        else
            -- data after padding is invalid
            return nil, "invalid base64: data after padding"
        end
    end

    if nb == 0 then return "" end

    -- After stripping padding, remainder mod 4 must not be 1
    local rem = nb % 4
    if rem == 1 then
        return nil, "invalid base64: bad length"
    end

    local t = {}
    local k = 1
    -- Full 4-byte groups
    for i = 1, nb - rem, 4 do
        local a, b, c, d = bytes[i], bytes[i+1], bytes[i+2], bytes[i+3]
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
        local a, b, c = bytes[nb-2], bytes[nb-1], bytes[nb]
        local da, db, dc = dec[a], dec[b], dec[c]
        if not da or not db or not dc then
            return nil, "invalid base64: bad character in final group"
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40
        t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff))
    elseif rem == 2 then
        local a, b = bytes[nb-1], bytes[nb]
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
