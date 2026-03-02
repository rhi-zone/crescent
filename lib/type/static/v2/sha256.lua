-- lib/type/static/v2/sha256.lua
-- Pure LuaJIT SHA-256 implementation (FIPS 180-4).
-- Uses bit.* for 32-bit arithmetic; no external dependencies.
-- Input: Lua string. Output: 64-character lowercase hex string.

local ffi = require("ffi")
local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local tobit  = bit.tobit

local M = {}

-- SHA-256 round constants (first 32 bits of the fractional parts of the
-- cube roots of the first 64 primes).
local K = {
    tobit(0x428a2f98), tobit(0x71374491), tobit(0xb5c0fbcf), tobit(0xe9b5dba5),
    tobit(0x3956c25b), tobit(0x59f111f1), tobit(0x923f82a4), tobit(0xab1c5ed5),
    tobit(0xd807aa98), tobit(0x12835b01), tobit(0x243185be), tobit(0x550c7dc3),
    tobit(0x72be5d74), tobit(0x80deb1fe), tobit(0x9bdc06a7), tobit(0xc19bf174),
    tobit(0xe49b69c1), tobit(0xefbe4786), tobit(0x0fc19dc6), tobit(0x240ca1cc),
    tobit(0x2de92c6f), tobit(0x4a7484aa), tobit(0x5cb0a9dc), tobit(0x76f988da),
    tobit(0x983e5152), tobit(0xa831c66d), tobit(0xb00327c8), tobit(0xbf597fc7),
    tobit(0xc6e00bf3), tobit(0xd5a79147), tobit(0x06ca6351), tobit(0x14292967),
    tobit(0x27b70a85), tobit(0x2e1b2138), tobit(0x4d2c6dfc), tobit(0x53380d13),
    tobit(0x650a7354), tobit(0x766a0abb), tobit(0x81c2c92e), tobit(0x92722c85),
    tobit(0xa2bfe8a1), tobit(0xa81a664b), tobit(0xc24b8b70), tobit(0xc76c51a3),
    tobit(0xd192e819), tobit(0xd6990624), tobit(0xf40e3585), tobit(0x106aa070),
    tobit(0x19a4c116), tobit(0x1e376c08), tobit(0x2748774c), tobit(0x34b0bcb5),
    tobit(0x391c0cb3), tobit(0x4ed8aa4a), tobit(0x5b9cca4f), tobit(0x682e6ff3),
    tobit(0x748f82ee), tobit(0x78a5636f), tobit(0x84c87814), tobit(0x8cc70208),
    tobit(0x90befffa), tobit(0xa4506ceb), tobit(0xbef9a3f7), tobit(0xc67178f2),
}

local function ror32(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

-- Process one 64-byte block. W is a scratch array[0..63], h[0..7] are the
-- running state. Returns updated h values.
local function process_block(W, h0, h1, h2, h3, h4, h5, h6, h7)
    -- Extend the first 16 words into 64
    for i = 16, 63 do
        local s0 = bxor(ror32(W[i-15], 7), ror32(W[i-15], 18), rshift(W[i-15], 3))
        local s1 = bxor(ror32(W[i-2], 17), ror32(W[i-2], 19), rshift(W[i-2], 10))
        W[i] = tobit(W[i-16] + s0 + W[i-7] + s1)
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7

    for i = 0, 63 do
        local S1 = bxor(ror32(e, 6), ror32(e, 11), ror32(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local temp1 = tobit(h + S1 + ch + K[i+1] + W[i])
        local S0 = bxor(ror32(a, 2), ror32(a, 13), ror32(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local temp2 = tobit(S0 + maj)

        h = g; g = f; f = e
        e = tobit(d + temp1)
        d = c; c = b; b = a
        a = tobit(temp1 + temp2)
    end

    return tobit(h0+a), tobit(h1+b), tobit(h2+c), tobit(h3+d),
           tobit(h4+e), tobit(h5+f), tobit(h6+g), tobit(h7+h)
end

-- Compute SHA-256 of a Lua string. Returns 64-char hex string.
function M.hash(msg)
    local len = #msg
    local ptr = ffi.cast("const uint8_t*", msg)

    -- Initial hash values (first 32 bits of fractional parts of sqrt of first 8 primes)
    local h0 = tobit(0x6a09e667)
    local h1 = tobit(0xbb67ae85)
    local h2 = tobit(0x3c6ef372)
    local h3 = tobit(0xa54ff53a)
    local h4 = tobit(0x510e527f)
    local h5 = tobit(0x9b05688c)
    local h6 = tobit(0x1f83d9ab)
    local h7 = tobit(0x5be0cd19)

    local W = {}
    local pos = 0

    -- Process all complete 64-byte blocks from the source
    while pos + 64 <= len do
        for i = 0, 15 do
            local j = pos + i * 4
            W[i] = tobit(ptr[j]*16777216 + ptr[j+1]*65536 + ptr[j+2]*256 + ptr[j+3])
        end
        h0, h1, h2, h3, h4, h5, h6, h7 = process_block(W, h0, h1, h2, h3, h4, h5, h6, h7)
        pos = pos + 64
    end

    -- Padding: build the final 1 or 2 blocks
    -- Remaining bytes + 0x80 byte + zeros + 8-byte big-endian bit length
    local tail = {}
    local tail_len = len - pos
    for i = 0, tail_len - 1 do
        tail[i] = ptr[pos + i]
    end
    tail[tail_len] = 0x80
    for i = tail_len + 1, 63 do
        tail[i] = 0
    end

    -- Bit length as 64-bit big-endian (we only handle up to 2^32-1 byte messages)
    local bit_len = len * 8
    local bl_hi = math.floor(bit_len / 0x100000000)
    local bl_lo = bit_len % 0x100000000

    local function finish_block(blk)
        for i = 0, 15 do
            local j = i * 4
            W[i] = tobit(blk[j]*16777216 + blk[j+1]*65536 + blk[j+2]*256 + blk[j+3])
        end
        h0, h1, h2, h3, h4, h5, h6, h7 = process_block(W, h0, h1, h2, h3, h4, h5, h6, h7)
    end

    if tail_len < 56 then
        -- Fits in one block: write length at bytes 56-63
        local function wu32be(blk, offset, v)
            blk[offset]   = band(rshift(v, 24), 0xff)
            blk[offset+1] = band(rshift(v, 16), 0xff)
            blk[offset+2] = band(rshift(v, 8),  0xff)
            blk[offset+3] = band(v, 0xff)
        end
        wu32be(tail, 56, bl_hi)
        wu32be(tail, 60, bl_lo)
        finish_block(tail)
    else
        -- Need two blocks: flush current, then length block
        finish_block(tail)
        local final = {}
        for i = 0, 63 do final[i] = 0 end
        local function wu32be(blk, offset, v)
            blk[offset]   = band(rshift(v, 24), 0xff)
            blk[offset+1] = band(rshift(v, 16), 0xff)
            blk[offset+2] = band(rshift(v, 8),  0xff)
            blk[offset+3] = band(v, 0xff)
        end
        wu32be(final, 56, bl_hi)
        wu32be(final, 60, bl_lo)
        finish_block(final)
    end

    -- Encode as hex
    local hex_chars = "0123456789abcdef"
    local out = {}
    local function emit(v)
        v = band(v, 0xffffffff)  -- treat as unsigned
        -- 8 hex digits, high nibble first
        for i = 7, 0, -1 do
            local nibble = band(rshift(v, i * 4), 0xf)
            out[#out + 1] = hex_chars:sub(nibble + 1, nibble + 1)
        end
    end
    emit(h0); emit(h1); emit(h2); emit(h3)
    emit(h4); emit(h5); emit(h6); emit(h7)
    return table.concat(out)
end

return M
