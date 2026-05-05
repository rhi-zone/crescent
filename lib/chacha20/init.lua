-- lib/chacha20/init.lua
-- ChaCha20 stream cipher (RFC 7539) and ChaCha20-Poly1305 AEAD.
--
-- Public API:
--   M.encrypt(key, nonce, plaintext, counter)            -> ciphertext | nil, errmsg
--   M.decrypt(key, nonce, ciphertext, counter)           -> plaintext  | nil, errmsg
--   M.keystream(key, nonce, n, counter)                  -> keystream  | nil, errmsg
--   M.aead_encrypt(key, nonce, plaintext, aad)           -> ciphertext..tag | nil, errmsg
--   M.aead_decrypt(key, nonce, ciphertext_with_tag, aad) -> plaintext | nil, errmsg
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local ffi = require("ffi")

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Bit op aliases
-- ---------------------------------------------------------------------------

local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local rol    = bit.rol
local tobit  = bit.tobit
local sbyte  = string.byte
local schar  = string.char
local concat = table.concat

-- ---------------------------------------------------------------------------
-- ChaCha20 helpers
-- ---------------------------------------------------------------------------

-- Read 4 bytes from string s at 1-based position i as a little-endian uint32.
-- tobit converts to signed 32-bit so bit ops work correctly.
--: (string, number) -> number
local function read_u32_le(s, i)
  local b0, b1, b2, b3 = sbyte(s, i, i + 3)
  return tobit(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216)
end

-- Write a 32-bit value as 4 little-endian bytes.
--: (number) -> string
local function write_u32_le(v)
  local b0 = band(v,           0xff)
  local b1 = band(rshift(v,  8), 0xff)
  local b2 = band(rshift(v, 16), 0xff)
  local b3 = band(rshift(v, 24), 0xff)
  return schar(b0, b1, b2, b3)
end

-- ChaCha20 initial state constants ("expand 32-byte k" LE words).
local SIGMA = {
  tobit(0x61707865),  -- "expa"
  tobit(0x3320646e),  -- "nd 3"
  tobit(0x79622d32),  -- "2-by"
  tobit(0x6b206574),  -- "te k"
}

-- Quarter round applied in-place to state table s at 1-based indices.
--: (table, number, number, number, number) -> nil
local function quarter_round(s, ai, bi, ci, di)
  local a, b, c, d = s[ai], s[bi], s[ci], s[di]
  a = tobit(a + b); d = rol(bxor(d, a), 16)
  c = tobit(c + d); b = rol(bxor(b, c), 12)
  a = tobit(a + b); d = rol(bxor(d, a),  8)
  c = tobit(c + d); b = rol(bxor(b, c),  7)
  s[ai], s[bi], s[ci], s[di] = a, b, c, d
end

-- Produce one 64-byte ChaCha20 keystream block.
--: (string, number, string) -> string
local function chacha20_block(key, counter, nonce)
  local s = {
    SIGMA[1], SIGMA[2], SIGMA[3], SIGMA[4],
    read_u32_le(key,  1), read_u32_le(key,  5),
    read_u32_le(key,  9), read_u32_le(key, 13),
    read_u32_le(key, 17), read_u32_le(key, 21),
    read_u32_le(key, 25), read_u32_le(key, 29),
    tobit(counter),
    read_u32_le(nonce, 1), read_u32_le(nonce, 5), read_u32_le(nonce, 9),
  }
  -- Save initial state for final addition.
  local t = {}
  for i = 1, 16 do t[i] = s[i] end

  -- 10 double-rounds (20 rounds total).
  for _ = 1, 10 do
    quarter_round(s,  1,  5,  9, 13)
    quarter_round(s,  2,  6, 10, 14)
    quarter_round(s,  3,  7, 11, 15)
    quarter_round(s,  4,  8, 12, 16)
    quarter_round(s,  1,  6, 11, 16)
    quarter_round(s,  2,  7, 12, 13)
    quarter_round(s,  3,  8,  9, 14)
    quarter_round(s,  4,  5, 10, 15)
  end

  -- Add initial state back.
  local out = {}
  for i = 1, 16 do
    out[i] = write_u32_le(tobit(s[i] + t[i]))
  end
  return concat(out)
end

-- XOR msg with ChaCha20 keystream starting at block counter.
--: (string, string, string, number) -> string
local function chacha20_xor(key, nonce, msg, counter)
  local len = #msg
  if len == 0 then return "" end
  local out = {}
  local pos = 1
  local blk = 0
  while pos <= len do
    local ks = chacha20_block(key, counter + blk, nonce)
    local chunk_end = math.min(pos + 63, len)
    local t = {}
    for i = 1, chunk_end - pos + 1 do
      t[i] = schar(bxor(sbyte(msg, pos + i - 1), sbyte(ks, i)))
    end
    out[blk + 1] = concat(t)
    pos = pos + 64
    blk = blk + 1
  end
  return concat(out)
end

-- ---------------------------------------------------------------------------
-- Poly1305 MAC (RFC 7539 §2.5)
--
-- Uses a 5-limb 26-bit representation for the 130-bit accumulator.
-- Each product a_i * r_j <= (2^26-1)^2 < 2^52, and each d_i sums 5 such
-- products, so d_i < 5 * 2^52 < 2^55 — safely within FFI uint64_t (63-bit).
-- ---------------------------------------------------------------------------

local U64    = ffi.typeof("uint64_t")
local U0     = U64(0)
local U5     = U64(5)
local U256   = U64(256)
local MASK26  = U64(0x3ffffff)
local SHIFT26 = U64(67108864)   -- 2^26

-- Clamp Poly1305 r value per RFC 7539 §2.5.
--: (string) -> string
local function clamp_r(r)
  local t = { sbyte(r, 1, 16) }
  t[4]  = band(t[4],  15)
  t[8]  = band(t[8],  15)
  t[12] = band(t[12], 15)
  t[16] = band(t[16], 15)
  t[5]  = band(t[5],  252)
  t[9]  = band(t[9],  252)
  t[13] = band(t[13], 252)
  return schar(unpack(t))
end

-- Decode a 16-byte LE byte array (1-indexed Lua table) into 5x26-bit limbs.
-- The 26-bit limb boundaries fall at bits 0,26,52,78,104, which straddle byte
-- boundaries — each limb overlaps two bytes at its edges.
-- b[1..16]: the 16 message/key bytes; any high bit is added by the caller.
local function decode_26(b)
  -- n0: bits  0..25 — all of b[1..3], bottom 2 bits of b[4].
  local n0 = U64(b[1])
    + U64(b[2]) * U64(256)
    + U64(b[3]) * U64(65536)
    + U64(band(b[4], 3)) * U64(16777216)       -- 2^24
  -- n1: bits 26..51 — top 6 bits of b[4], all of b[5,6], bottom 4 bits of b[7].
  local n1 = U64(rshift(b[4], 2))              -- b[4]>>2, at position 0 of n1
    + U64(b[5]) * U64(64)                       -- 2^6
    + U64(b[6]) * U64(16384)                    -- 2^14
    + U64(band(b[7], 15)) * U64(4194304)        -- 2^22 (4 bits, not 2)
  -- n2: bits 52..77 — top 4 bits of b[7], all of b[8,9], bottom 6 bits of b[10].
  local n2 = U64(rshift(b[7], 4))              -- b[7]>>4, at position 0 of n2
    + U64(b[8]) * U64(16)                       -- 2^4
    + U64(b[9]) * U64(4096)                     -- 2^12
    + U64(band(b[10], 63)) * U64(1048576)       -- 2^20 (6 bits, not 2)
  -- n3: bits 78..103 — top 2 bits of b[10], all of b[11,12,13].
  local n3 = U64(rshift(b[10], 6))             -- b[10]>>6, at position 0 of n3
    + U64(b[11]) * U64(4)                       -- 2^2
    + U64(b[12]) * U64(1024)                    -- 2^10
    + U64(b[13]) * U64(262144)                  -- 2^18
  -- n4: bits 104..127 — all of b[14,15,16] (and any high bit added by caller).
  local n4 = U64(b[14])
    + U64(b[15]) * U64(256)                     -- 2^8
    + U64(b[16]) * U64(65536)                   -- 2^16
  return n0, n1, n2, n3, n4
end

-- Poly1305 MAC.  key32: 32-byte one-time key.  Returns 16-byte binary tag.
--: (string, string) -> string
local function poly1305_mac(key32, msg)
  local r_str = clamp_r(key32:sub(1, 16))
  local s_str = key32:sub(17, 32)

  local rb = { sbyte(r_str, 1, 16) }
  local r0, r1, r2, r3, r4 = decode_26(rb)
  local r1_5 = r1 * U5
  local r2_5 = r2 * U5
  local r3_5 = r3 * U5
  local r4_5 = r4 * U5

  local h0, h1, h2, h3, h4 = U0, U0, U0, U0, U0

  local msglen = #msg
  local pos = 1

  while pos <= msglen do
    local remaining = msglen - pos + 1
    local blocklen = remaining >= 16 and 16 or remaining

    -- Read block into byte table (zero-padded to 16).
    local n = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for i = 1, blocklen do
      n[i] = sbyte(msg, pos + i - 1)
    end
    local n0, n1, n2, n3, n4 = decode_26(n)
    -- Add 2^(8*blocklen): the "1" bit that turns the block into a field element.
    -- 2^128 = 2^(26*4 + 24), so it lands in limb 4 at bit 24 = 2^24 = 16777216.
    -- For a full 16-byte block: blocklen=16, the 1 goes at byte position 17
    -- which is bit 128 = 2^(26*4)*2^(128-104) = limb4 * 2^24.
    -- For partial blocks: 2^(8*blocklen). blocklen < 16 so 8*blocklen < 128.
    -- The bit lands in one of the lower limbs — add 2^(8*blocklen) directly.
    -- Simpler: build a byte array with the high-bit byte and decode.
    -- byte position = blocklen+1, value = 1 (i.e. 2^(8*blocklen)).
    -- Reconstruct: the extra byte 1 at position (blocklen+1) contributes:
    --   1 * 2^(8*blocklen) to the 130-bit number.
    -- Add it to the appropriate limb.
    -- Bit position in 130-bit number: 8*blocklen.
    -- Limb index: bit_pos / 26 (floor), bit within limb: bit_pos mod 26.
    local bit_pos = 8 * blocklen
    local limb_idx = math.floor(bit_pos / 26)
    local bit_in_limb = bit_pos % 26
    local add_val = U64(lshift(1, bit_in_limb))
    if limb_idx == 0 then n0 = n0 + add_val
    elseif limb_idx == 1 then n1 = n1 + add_val
    elseif limb_idx == 2 then n2 = n2 + add_val
    elseif limb_idx == 3 then n3 = n3 + add_val
    else n4 = n4 + add_val
    end

    -- h += n
    h0 = h0 + n0; h1 = h1 + n1; h2 = h2 + n2
    h3 = h3 + n3; h4 = h4 + n4

    -- h = h * r  mod (2^130 - 5)
    -- d[i] = sum over j of h[j] * r[(i-j) mod 5], with wrap-around scaled by 5
    -- (because 2^130 ≡ 5 mod (2^130-5), so a term shifted 5 limbs = *5 at limb 0).
    local d0 = h0*r0 + h1*r4_5 + h2*r3_5 + h3*r2_5 + h4*r1_5
    local d1 = h0*r1 + h1*r0   + h2*r4_5 + h3*r3_5 + h4*r2_5
    local d2 = h0*r2 + h1*r1   + h2*r0   + h3*r4_5 + h4*r3_5
    local d3 = h0*r3 + h1*r2   + h2*r1   + h3*r0   + h4*r4_5
    local d4 = h0*r4 + h1*r3   + h2*r2   + h3*r1   + h4*r0

    -- Carry-propagate to reduce limbs back to 26 bits.
    local c
    c = d0 / SHIFT26; h0 = band(d0, MASK26); d1 = d1 + c
    c = d1 / SHIFT26; h1 = band(d1, MASK26); d2 = d2 + c
    c = d2 / SHIFT26; h2 = band(d2, MASK26); d3 = d3 + c
    c = d3 / SHIFT26; h3 = band(d3, MASK26); d4 = d4 + c
    c = d4 / SHIFT26; h4 = band(d4, MASK26); h0 = h0 + c * U5
    c = h0 / SHIFT26; h0 = band(h0, MASK26); h1 = h1 + c

    pos = pos + blocklen
  end

  -- Final reduction: subtract (2^130-5) if h >= (2^130-5).
  -- Test by computing g = h + 5; if g >= 2^130 (i.e. carry out of limb 4), use g.
  local g0 = h0 + U5
  local c = g0 / SHIFT26
  local g1 = h1 + c; c = g1 / SHIFT26
  local g2 = h2 + c; c = g2 / SHIFT26
  local g3 = h3 + c; c = g3 / SHIFT26
  local g4 = h4 + c
  -- If g4 >= 2^26 the carry propagated all the way through, meaning h >= 2^130-5.
  local use_g = tonumber(g4 / SHIFT26)  -- 1 if h >= p, else 0
  local keep_h = 1 - use_g
  h0 = h0 * U64(keep_h) + band(g0, MASK26) * U64(use_g)
  h1 = h1 * U64(keep_h) + band(g1, MASK26) * U64(use_g)
  h2 = h2 * U64(keep_h) + band(g2, MASK26) * U64(use_g)
  h3 = h3 * U64(keep_h) + band(g3, MASK26) * U64(use_g)
  h4 = h4 * U64(keep_h) + band(g4, MASK26) * U64(use_g)

  -- Serialize h as 16 LE bytes, then add s (mod 2^128).
  -- h = h0 + h1*2^26 + h2*2^52 + h3*2^78 + h4*2^104.
  -- Decompose into bytes using two 64-bit halves.
  -- lo64: bits 0..63:  h0 + h1*2^26 + (h2 mod 2^12)*2^52
  -- hi64: bits 0..65:  (h2 >> 12) + h3*2^14 + h4*2^40
  local h2_lo = band(h2, U64(0xfff))   -- bits 0..11 of h2
  local h2_hi = h2 / U64(0x1000)       -- bits 12..25 of h2 (14 bits, h2<2^26)
  local lo64 = h0 + h1 * SHIFT26 + h2_lo * U64(0x10000000000000ULL)
  local hi64 = h2_hi + h3 * U64(0x4000) + h4 * U64(0x10000000000ULL)
  -- h3 * 2^(78-64) = h3 * 2^14 = h3 * 16384
  -- h4 * 2^(104-64) = h4 * 2^40 = h4 * 0x10000000000

  -- Extract bytes from lo64 (8 bytes) and hi64 (8 bytes).
  local out = {}
  local v = lo64
  for i = 1, 8 do
    out[i] = tonumber(band(v, U64(0xff)))
    v = v / U256
  end
  v = hi64
  for i = 9, 16 do
    out[i] = tonumber(band(v, U64(0xff)))
    v = v / U256
  end

  -- Add s mod 2^128.
  local sb = { sbyte(s_str, 1, 16) }
  local carry = 0
  for i = 1, 16 do
    local sum = out[i] + sb[i] + carry
    out[i] = sum % 256
    carry = math.floor(sum / 256)
  end

  return schar(unpack(out))
end

-- ---------------------------------------------------------------------------
-- Input validation
-- ---------------------------------------------------------------------------

--: (string, string, string | nil, number | nil) -> (boolean | nil, string | nil)
local function validate(key, nonce, msg, counter)
  if type(key) ~= "string" or #key ~= 32 then
    return nil, "key must be a 32-byte string"
  end
  if type(nonce) ~= "string" or #nonce ~= 12 then
    return nil, "nonce must be a 12-byte string"
  end
  if msg ~= nil and type(msg) ~= "string" then
    return nil, "message must be a string"
  end
  if counter ~= nil and type(counter) ~= "number" then
    return nil, "counter must be a number"
  end
  return true, nil
end

-- ---------------------------------------------------------------------------
-- Padding and length encoding helpers
-- ---------------------------------------------------------------------------

--: (string) -> string
local function pad16(s)
  local rem = #s % 16
  if rem == 0 then return s end
  return s .. ("\0"):rep(16 - rem)
end

--: (number) -> string
local function len64_le(n)
  local lo = n % 0x100000000
  local hi = math.floor(n / 0x100000000)
  return write_u32_le(tobit(lo)) .. write_u32_le(tobit(hi))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- ChaCha20 encrypt (counter defaults to 1 per RFC 7539 §2.4).
--: (string, string, string, number | nil) -> (string | nil, string | nil)
function M.encrypt(key, nonce, plaintext, counter)
  local ok, err = validate(key, nonce, plaintext, counter)
  if not ok then return nil, err end
  return chacha20_xor(key, nonce, plaintext, counter or 1), nil
end

-- ChaCha20 decrypt (identical to encrypt — XOR is its own inverse).
--: (string, string, string, number | nil) -> (string | nil, string | nil)
function M.decrypt(key, nonce, ciphertext, counter)
  local ok, err = validate(key, nonce, ciphertext, counter)
  if not ok then return nil, err end
  return chacha20_xor(key, nonce, ciphertext, counter or 1), nil
end

-- Generate n bytes of raw keystream (counter defaults to 0).
--: (string, string, number, number | nil) -> (string | nil, string | nil)
function M.keystream(key, nonce, n, counter)
  local ok, err = validate(key, nonce, nil, counter)
  if not ok then return nil, err end
  if type(n) ~= "number" or n < 0 or math.floor(n) ~= n then
    return nil, "n must be a non-negative integer"
  end
  if n == 0 then return "", nil end
  return chacha20_xor(key, nonce, ("\0"):rep(n), counter or 0), nil
end

-- ChaCha20-Poly1305 AEAD encrypt (RFC 7539 §2.6).
--: (string, string, string, string | nil) -> (string | nil, string | nil)
function M.aead_encrypt(key, nonce, plaintext, aad)
  local ok, err = validate(key, nonce, plaintext, nil)
  if not ok then return nil, err end
  aad = aad or ""
  if type(aad) ~= "string" then return nil, "aad must be a string" end

  local poly_key = chacha20_block(key, 0, nonce):sub(1, 32)
  local ciphertext = chacha20_xor(key, nonce, plaintext, 1)
  local mac_data = pad16(aad) .. pad16(ciphertext) .. len64_le(#aad) .. len64_le(#ciphertext)
  local tag = poly1305_mac(poly_key, mac_data)

  return ciphertext .. tag, nil
end

-- ChaCha20-Poly1305 AEAD decrypt and verify (RFC 7539 §2.6).
--: (string, string, string, string | nil) -> (string | nil, string | nil)
function M.aead_decrypt(key, nonce, ciphertext_with_tag, aad)
  local ok, err = validate(key, nonce, ciphertext_with_tag, nil)
  if not ok then return nil, err end
  aad = aad or ""
  if type(aad) ~= "string" then return nil, "aad must be a string" end
  if #ciphertext_with_tag < 16 then
    return nil, "ciphertext_with_tag too short"
  end

  local ctlen = #ciphertext_with_tag - 16
  local ciphertext   = ciphertext_with_tag:sub(1, ctlen)
  local received_tag = ciphertext_with_tag:sub(ctlen + 1)

  local poly_key = chacha20_block(key, 0, nonce):sub(1, 32)
  local mac_data = pad16(aad) .. pad16(ciphertext) .. len64_le(#aad) .. len64_le(#ciphertext)
  local expected_tag = poly1305_mac(poly_key, mac_data)

  -- Constant-time comparison.
  local diff = 0
  for i = 1, 16 do
    diff = bor(diff, bxor(sbyte(received_tag, i), sbyte(expected_tag, i)))
  end
  if diff ~= 0 then
    return nil, "authentication failed"
  end

  return chacha20_xor(key, nonce, ciphertext, 1), nil
end

-- Expose internals for testing.
M._quarter_round  = quarter_round
M._chacha20_block = chacha20_block
M._poly1305_mac   = poly1305_mac

return M
