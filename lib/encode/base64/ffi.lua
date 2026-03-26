-- lib/encode/base64/ffi.lua
-- Tier 2: LuaJIT FFI scalar base64 (RFC 4648 §4 standard, §5 URL-safe).
-- Uses ffi.cast("const uint8_t*", s) for zero-copy byte access.
-- Requires LuaJIT. Returns false if FFI is unavailable.

local ok, ffi = pcall(require, "ffi")
if not ok then return false end

local ok2, bit = pcall(require, "bit")
if not ok2 then return false end

local band, rshift = bit.band, bit.rshift

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Standard alphabet (RFC 4648 §4): A-Z a-z 0-9 + /
local STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- URL-safe alphabet (RFC 4648 §5): A-Z a-z 0-9 - _
local URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

-- Build 64-entry encode table (index 0..63 → byte value).
local function make_enc_ffi(chars)
    local enc = ffi.new("uint8_t[64]")
    for i = 1, 64 do
        enc[i - 1] = chars:byte(i)
    end
    return enc
end

-- Build 256-entry decode table (byte value 0..255 → 6-bit value or 0xFF for invalid).
-- Whitespace bytes (0x20, 0x09, 0x0A, 0x0D) map to 0xFE (skip sentinel).
local function make_dec_ffi(chars)
    local dec = ffi.new("uint8_t[256]")
    for i = 0, 255 do dec[i] = 0xFF end
    for i = 1, 64 do
        dec[chars:byte(i)] = i - 1
    end
    -- Whitespace → skip sentinel
    dec[0x20] = 0xFE
    dec[0x09] = 0xFE
    dec[0x0A] = 0xFE
    dec[0x0D] = 0xFE
    return dec
end

local std_enc = make_enc_ffi(STD)
local url_enc = make_enc_ffi(URL)
local std_dec = make_dec_ffi(STD)
local url_dec = make_dec_ffi(URL)
local PAD = string.byte("=")

-- Encode binary string to base64.
-- opts.url = true  → URL-safe alphabet
-- opts.pad = false → omit = padding (default: include padding)
--: (string, { url: boolean?, pad: boolean? }?) -> string
M.encode = function(str, opts)
    local enc = (opts and opts.url) and url_enc or std_enc
    local pad = not (opts and opts.pad == false)
    local n = #str
    if n == 0 then return "" end
    local lastn = n % 3
    local t = {}
    local k = 1
    local p = ffi.cast("const uint8_t*", str)
    -- Full 3-byte groups
    local full = n - lastn
    local i = 0
    while i < full do
        local a = p[i]; local b = p[i+1]; local c = p[i+2]
        local v = a * 0x10000 + b * 0x100 + c
        t[k] = string.char(
            enc[band(rshift(v, 18), 0x3f)],
            enc[band(rshift(v, 12), 0x3f)],
            enc[band(rshift(v,  6), 0x3f)],
            enc[band(v,            0x3f)]
        )
        k = k + 1
        i = i + 3
    end
    -- Remainder
    if lastn == 2 then
        local a = p[n-2]; local b = p[n-1]
        local v = a * 0x10000 + b * 0x100
        if pad then
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], enc[band(rshift(v,6),0x3f)], PAD)
        else
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], enc[band(rshift(v,6),0x3f)])
        end
    elseif lastn == 1 then
        local v = p[n-1] * 0x10000
        if pad then
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)], PAD, PAD)
        else
            t[k] = string.char(enc[band(rshift(v,18),0x3f)], enc[band(rshift(v,12),0x3f)])
        end
    end
    return table.concat(t)
end

-- Decode base64 string to binary.
-- opts.url = true → URL-safe alphabet
-- Whitespace is skipped inline. Returns nil, err on invalid input.
--: (string, { url: boolean? }?) -> string
M.decode = function(b64, opts)
    local dec = (opts and opts.url) and url_dec or std_dec
    local n = #b64
    if n == 0 then return "" end

    local p = ffi.cast("const uint8_t*", b64)

    -- First pass: collect non-whitespace, non-padding bytes and count padding.
    -- We build a Lua table of effective bytes to avoid a second FFI allocation.
    local bytes = {}
    local nb = 0
    local padding = 0
    local saw_pad = false
    for i = 0, n - 1 do
        local byte = p[i]
        local dv = dec[byte]
        if dv == 0xFE then
            -- whitespace: skip
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
            return nil, "invalid base64: data after padding"
        end
    end

    if nb == 0 then return "" end

    local rem = nb % 4
    if rem == 1 then
        return nil, "invalid base64: bad length"
    end

    local t = {}
    local k = 1
    -- Full 4-byte groups
    local full4 = nb - rem
    local i = 1
    while i <= full4 do
        local a, b, c, d = bytes[i], bytes[i+1], bytes[i+2], bytes[i+3]
        local da, db, dc, dd = dec[a], dec[b], dec[c], dec[d]
        if da == 0xFF or db == 0xFF or dc == 0xFF or dd == 0xFF then
            return nil, "invalid base64: bad character at byte " .. i
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40 + dd
        t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff), band(v,0xff))
        k = k + 1
        i = i + 4
    end
    -- Partial final group
    if rem == 3 then
        local a, b, c = bytes[nb-2], bytes[nb-1], bytes[nb]
        local da, db, dc = dec[a], dec[b], dec[c]
        if da == 0xFF or db == 0xFF or dc == 0xFF then
            return nil, "invalid base64: bad character in final group"
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40
        t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff))
    elseif rem == 2 then
        local a, b = bytes[nb-1], bytes[nb]
        local da, db = dec[a], dec[b]
        if da == 0xFF or db == 0xFF then
            return nil, "invalid base64: bad character in final group"
        end
        local v = da * 0x40000 + db * 0x1000
        t[k] = string.char(band(rshift(v,16),0xff))
    end
    return table.concat(t)
end

return M
