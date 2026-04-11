-- lib/base32/init.lua
-- Base32 encoding and decoding (RFC 4648 §6 standard, §7 hex, Crockford).
--
-- Public API:
--   M.encode(data)            → string  (standard base32, uppercase, padded)
--   M.decode(data)            → string | (nil, errmsg)
--   M.encode_hex(data)        → string  (base32hex, uppercase, padded)
--   M.decode_hex(data)        → string | (nil, errmsg)
--   M.encode_crockford(data)  → string  (Crockford, uppercase, no padding)
--   M.decode_crockford(data)  → string | (nil, errmsg)  (case-insensitive, i/l→1, o→0)
--   M.string_to_base32        = M.encode
--   M.base32_to_string        = M.decode
--   M._tier                   = "pure"

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Alphabets ──────────────────────────────────────────────────────────────────

local ALPHA_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local ALPHA_HEX = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
local ALPHA_CRO = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

-- Build decode lookup tables (char → 0-based value, or false for invalid).
local function make_decode_table(alpha)
    local t = {}
    for i = 1, 32 do
        local c = alpha:sub(i, i)
        t[c:byte()] = i - 1
        -- also accept lowercase
        local lc = c:lower()
        if lc ~= c then
            t[lc:byte()] = i - 1
        end
    end
    return t
end

local DEC_STD = make_decode_table(ALPHA_STD)
local DEC_HEX = make_decode_table(ALPHA_HEX)
local DEC_CRO = make_decode_table(ALPHA_CRO)

-- Crockford extras: i/I/l/L → 1, o/O → 0
do
    local function set(t, ch, val)
        t[ch:byte()] = val
        t[ch:upper():byte()] = val
    end
    set(DEC_CRO, "i", 1)
    set(DEC_CRO, "l", 1)
    set(DEC_CRO, "o", 0)
end

-- ── Generic encode ────────────────────────────────────────────────────────────

local function encode_generic(data, alpha, pad)
    local out = {}
    local n = #data
    local i = 1
    local oi = 0
    while i <= n do
        -- Gather up to 5 bytes
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local b4 = data:byte(i + 3) or 0
        local b5 = data:byte(i + 4) or 0
        local remaining = n - i + 1

        -- Encode 8 chars from 5 bytes (40 bits)
        local c1 = math.floor(b1 / 8)                               -- bits 7-3 of b1
        local c2 = (b1 % 8) * 4 + math.floor(b2 / 64)             -- bits 2-0 of b1, 7-6 of b2
        local c3 = math.floor(b2 / 2) % 32                          -- bits 5-1 of b2
        local c4 = (b2 % 2) * 16 + math.floor(b3 / 16)            -- bit 0 of b2, 7-4 of b3
        local c5 = (b3 % 16) * 2 + math.floor(b4 / 128)           -- bits 3-0 of b3, bit 7 of b4
        local c6 = math.floor(b4 / 4) % 32                          -- bits 6-2 of b4
        local c7 = (b4 % 4) * 8 + math.floor(b5 / 32)             -- bits 1-0 of b4, 7-5 of b5
        local c8 = b5 % 32                                           -- bits 4-0 of b5

        oi = oi + 1; out[oi] = alpha:sub(c1 + 1, c1 + 1)
        oi = oi + 1; out[oi] = alpha:sub(c2 + 1, c2 + 1)

        if remaining >= 2 then
            oi = oi + 1; out[oi] = alpha:sub(c3 + 1, c3 + 1)
            oi = oi + 1; out[oi] = alpha:sub(c4 + 1, c4 + 1)
        elseif pad then
            oi = oi + 1; out[oi] = "="
            oi = oi + 1; out[oi] = "="
        end

        if remaining >= 3 then
            oi = oi + 1; out[oi] = alpha:sub(c5 + 1, c5 + 1)
        elseif pad then
            oi = oi + 1; out[oi] = "="
        end

        if remaining >= 4 then
            oi = oi + 1; out[oi] = alpha:sub(c6 + 1, c6 + 1)
            oi = oi + 1; out[oi] = alpha:sub(c7 + 1, c7 + 1)
        elseif pad then
            oi = oi + 1; out[oi] = "="
            oi = oi + 1; out[oi] = "="
        end

        if remaining >= 5 then
            oi = oi + 1; out[oi] = alpha:sub(c8 + 1, c8 + 1)
        elseif pad then
            oi = oi + 1; out[oi] = "="
        end

        i = i + 5
    end
    return table.concat(out)
end

-- ── Generic decode ────────────────────────────────────────────────────────────

local function decode_generic(data, dec_table, name)
    -- Strip padding and whitespace
    local stripped = {}
    for i = 1, #data do
        local b = data:byte(i)
        local ch = string.char(b)
        if ch ~= "=" and ch ~= "\n" and ch ~= "\r" and ch ~= " " then
            local v = dec_table[b]
            if v == nil then
                return nil, name .. " decode: invalid character '" .. ch .. "' (0x" .. string.format("%02x", b) .. ")"
            end
            stripped[#stripped + 1] = v
        end
    end

    local chars = stripped
    local nc = #chars
    if nc == 0 then return "" end

    -- Validate length mod 8 — after stripping padding any remainder must be valid
    -- Valid lengths mod 8: 0, 2, 4, 5, 7
    local rem = nc % 8
    if rem == 1 or rem == 3 or rem == 6 then
        return nil, name .. " decode: invalid encoded length " .. nc .. " (mod 8 = " .. rem .. ")"
    end

    local out = {}
    local oi = 0
    local i = 1
    while i <= nc do
        local v1 = chars[i]     or 0
        local v2 = chars[i + 1] or 0
        local v3 = chars[i + 2]
        local v4 = chars[i + 3]
        local v5 = chars[i + 4]
        local v6 = chars[i + 5]
        local v7 = chars[i + 6]
        local v8 = chars[i + 7]

        local avail = nc - i + 1

        -- Always have at least 2 chars → 1 byte
        oi = oi + 1; out[oi] = string.char(v1 * 8 + math.floor(v2 / 4))

        if avail >= 4 then
            v3 = v3 or 0; v4 = v4 or 0
            oi = oi + 1; out[oi] = string.char((v2 % 4) * 64 + v3 * 2 + math.floor(v4 / 16))
        end

        if avail >= 5 then
            v5 = v5 or 0
            oi = oi + 1; out[oi] = string.char((v4 % 16) * 16 + math.floor(v5 / 2))
        end

        if avail >= 7 then
            v6 = v6 or 0; v7 = v7 or 0
            oi = oi + 1; out[oi] = string.char((v5 % 2) * 128 + v6 * 4 + math.floor(v7 / 8))
        end

        if avail >= 8 then
            v8 = v8 or 0
            oi = oi + 1; out[oi] = string.char((v7 % 8) * 32 + v8)
        end

        i = i + 8
    end
    return table.concat(out)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.encode(data)
    return encode_generic(data, ALPHA_STD, true)
end

function M.decode(data)
    return decode_generic(data, DEC_STD, "base32")
end

function M.encode_hex(data)
    return encode_generic(data, ALPHA_HEX, true)
end

function M.decode_hex(data)
    return decode_generic(data, DEC_HEX, "base32hex")
end

function M.encode_crockford(data)
    return encode_generic(data, ALPHA_CRO, false)
end

function M.decode_crockford(data)
    return decode_generic(data, DEC_CRO, "crockford")
end

-- Aliases
M.string_to_base32 = M.encode
M.base32_to_string = M.decode

return M
