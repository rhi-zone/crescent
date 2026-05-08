-- lib/base64/init.lua
-- Base64 encoding and decoding (RFC 4648).
-- Standard alphabet (section 4) and URL-safe alphabet (section 5).
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, concat = string.byte, string.char, table.concat
local floor = math.floor

-- Standard alphabet (RFC 4648 section 4): A-Z a-z 0-9 + /
local STD_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- URL-safe alphabet (RFC 4648 section 5): A-Z a-z 0-9 - _
local URL_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function make_enc(alpha)
    local t = {}
    for i = 1, 64 do t[i - 1] = byte(alpha, i) end
    return t
end

local function make_dec(alpha)
    local t = {}
    for i = 1, 64 do t[byte(alpha, i)] = i - 1 end
    return t
end

local std_enc = make_enc(STD_ALPHA)
local url_enc = make_enc(URL_ALPHA)
local std_dec = make_dec(STD_ALPHA)
local url_dec = make_dec(URL_ALPHA)
local PAD = byte("=")

--- Encode a binary string to base64.
--: (string, { url: boolean | nil, pad: boolean | nil } | nil) -> string
function M.encode(s, opts)
    local enc = (opts and opts.url) and url_enc or std_enc
    local pad = not (opts and opts.pad == false)
    local n = #s
    local tail = n % 3
    local t = {}
    local k = 1
    for i = 1, n - tail, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = (a or 0) --[[:! integer]] * 0x10000 + (b or 0) --[[:! integer]] * 0x100 + (c or 0) --[[:! integer]]
        t[k] = char(
            enc[floor(v / 0x40000) % 64],
            enc[floor(v / 0x1000) % 64],
            enc[floor(v / 0x40) % 64],
            enc[v % 64]
        )
        k = k + 1
    end
    if tail == 2 then
        local a, b = byte(s, n - 1, n)
        local v = (a or 0) --[[:! integer]] * 0x10000 + (b or 0) --[[:! integer]] * 0x100
        if pad then
            t[k] = char(
                enc[floor(v / 0x40000) % 64],
                enc[floor(v / 0x1000) % 64],
                enc[floor(v / 0x40) % 64],
                PAD
            )
        else
            t[k] = char(
                enc[floor(v / 0x40000) % 64],
                enc[floor(v / 0x1000) % 64],
                enc[floor(v / 0x40) % 64]
            )
        end
    elseif tail == 1 then
        local a3 = byte(s, n)
        local v = (a3 or 0) --[[:! integer]] * 0x10000
        if pad then
            t[k] = char(
                enc[floor(v / 0x40000) % 64],
                enc[floor(v / 0x1000) % 64],
                PAD, PAD
            )
        else
            t[k] = char(
                enc[floor(v / 0x40000) % 64],
                enc[floor(v / 0x1000) % 64]
            )
        end
    end
    return concat(t)
end

--- Decode a base64 string to binary.
--- Whitespace (space, tab, CR, LF) is skipped. Returns (nil, errmsg) on invalid input.
--: (string, { url: boolean | nil } | nil) -> (string | nil, string | nil)
function M.decode(s, opts)
    local dec = (opts and opts.url) and url_dec or std_dec
    local n = #s
    if n == 0 then return "" end

    -- Strip whitespace and padding, collect data bytes
    local bytes = {}
    local nb = 0 --: integer
    local saw_pad = false
    for i = 1, n do
        local b = byte(s, i)
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
            -- skip whitespace
        elseif b == PAD then
            saw_pad = true
        elseif saw_pad then
            return nil, "invalid base64: data after padding"
        else
            nb = nb + 1
            bytes[nb] = b
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
    for i = 1, nb - rem, 4 do
        local da = dec[bytes[i]]
        local db = dec[bytes[i + 1]]
        local dc = dec[bytes[i + 2]]
        local dd = dec[bytes[i + 3]]
        if not da or not db or not dc or not dd then
            return nil, "invalid base64: bad character"
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40 + dd
        t[k] = char(
            floor(v / 0x10000) % 256,
            floor(v / 0x100) % 256,
            v % 256
        )
        k = k + 1
    end
    -- Final partial group
    if rem == 3 then
        local da = dec[bytes[nb - 2]]
        local db = dec[bytes[nb - 1]]
        local dc = dec[bytes[nb]]
        if not da or not db or not dc then
            return nil, "invalid base64: bad character"
        end
        local v = da * 0x40000 + db * 0x1000 + dc * 0x40
        t[k] = char(floor(v / 0x10000) % 256, floor(v / 0x100) % 256)
    elseif rem == 2 then
        local da = dec[bytes[nb - 1]]
        local db = dec[bytes[nb]]
        if not da or not db then
            return nil, "invalid base64: bad character"
        end
        local v = da * 0x40000 + db * 0x1000
        t[k] = char(floor(v / 0x10000) % 256)
    end
    return concat(t)
end

--- Encode with URL-safe alphabet and no padding (RFC 4648 section 5).
--: (string) -> string
function M.encode_url(s)
    return M.encode(s, { url = true, pad = false })
end

--- Decode URL-safe base64 (with or without padding).
--: (string) -> (string | nil, string | nil)
function M.decode_url(s)
    return M.decode(s, { url = true })
end

-- Codec aliases per conventions
M.string_to_base64 = M.encode
M.base64_to_string = M.decode

return M
