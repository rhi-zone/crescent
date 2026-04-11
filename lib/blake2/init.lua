if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- BLAKE2b and BLAKE2s cryptographic hash functions.
-- Reference: RFC 7693 (https://www.rfc-editor.org/rfc/rfc7693)
--
-- BLAKE2b: 64-bit words, 12 rounds, 128-byte blocks, 1-64 byte output
-- BLAKE2s: 32-bit words, 10 rounds, 64-byte blocks,  1-32 byte output
--
-- API:
--   M.b(input, opts)         → hex string | (nil, errmsg)   BLAKE2b
--   M.b_binary(input, opts)  → raw bytes string | (nil, errmsg)
--   M.s(input, opts)         → hex string | (nil, errmsg)   BLAKE2s
--   M.s_binary(input, opts)  → raw bytes string | (nil, errmsg)
--   opts: { key = nil, hash_len = 64 } for b; { key = nil, hash_len = 32 } for s
--   M._tier = "pure"

local ffi = require("ffi")
local bit = require("bit")

local M = {}
M._tier = "pure"

local U64 = ffi.typeof("uint64_t")

-- ---------------------------------------------------------------------------
-- Shared sigma permutation (12 rows × 16 entries, 0-based indices)
-- ---------------------------------------------------------------------------

local SIGMA = {
  {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
  { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
  { 11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4 },
  {  7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8 },
  {  9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13 },
  {  2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9 },
  { 12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11 },
  { 13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10 },
  {  6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5 },
  { 10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0 },
  {  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15 },
  { 14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3 },
}

-- ---------------------------------------------------------------------------
-- BLAKE2b — 64-bit word implementation via FFI uint64_t
-- ---------------------------------------------------------------------------

-- BLAKE2b initialization vectors (square roots of first 8 primes, fractional parts)
local B_IV = {
  U64(0x6a09e667) * U64(0x100000000) + U64(0xf3bcc908),  -- 0x6a09e667f3bcc908
  U64(0xbb67ae85) * U64(0x100000000) + U64(0x84caa73b),  -- 0xbb67ae8584caa73b
  U64(0x3c6ef372) * U64(0x100000000) + U64(0xfe94f82b),  -- 0x3c6ef372fe94f82b
  U64(0xa54ff53a) * U64(0x100000000) + U64(0x5f1d36f1),  -- 0xa54ff53a5f1d36f1
  U64(0x510e527f) * U64(0x100000000) + U64(0xade682d1),  -- 0x510e527fade682d1
  U64(0x9b05688c) * U64(0x100000000) + U64(0x2b3e6c1f),  -- 0x9b05688c2b3e6c1f
  U64(0x1f83d9ab) * U64(0x100000000) + U64(0xfb41bd6b),  -- 0x1f83d9abfb41bd6b
  U64(0x5be0cd19) * U64(0x100000000) + U64(0x137e2179),  -- 0x5be0cd19137e2179
}

-- Rotate uint64_t right by n bits.
--: (uint64_t, number) -> uint64_t
local function rotr64(v, n)
  return bit.bor(bit.rshift(v, n), bit.lshift(v, 64 - n))
end

-- Read 8 bytes from string s at byte offset (0-based), little-endian → uint64_t.
--: (string, number) -> uint64_t
local function read_u64_le(s, off)
  local b0, b1, b2, b3, b4, b5, b6, b7 = string.byte(s, off + 1, off + 8)
  b0 = b0 or 0; b1 = b1 or 0; b2 = b2 or 0; b3 = b3 or 0
  b4 = b4 or 0; b5 = b5 or 0; b6 = b6 or 0; b7 = b7 or 0
  local lo = U64(b0) + U64(b1) * U64(256) + U64(b2) * U64(65536) + U64(b3) * U64(16777216)
  local hi = U64(b4) + U64(b5) * U64(256) + U64(b6) * U64(65536) + U64(b7) * U64(16777216)
  return lo + hi * U64(0x100000000)
end

-- BLAKE2b compression: mutates h[1..8] in place.
-- block: 128-byte string (already zero-padded)
-- t_lo, t_hi: counter (low and high 64-bit words)
-- last: boolean (true for final block)
local function b_compress(h, block, t_lo, t_hi, last)
  -- Load message words m[0..15] (0-based in sigma, 1-based in table)
  local m = {}
  for i = 0, 15 do
    m[i] = read_u64_le(block, i * 8)
  end

  -- Initialize working variables
  local v = {
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8],
    B_IV[1], B_IV[2], B_IV[3], B_IV[4],
    bit.bxor(t_lo, B_IV[5]),
    bit.bxor(t_hi, B_IV[6]),
    B_IV[7],
    B_IV[8],
  }
  -- v is 1-based; sigma uses 0-based, so v[a+1], v[b+1], etc.

  if last then
    v[15] = bit.bxor(v[15], -U64(1))
  end

  -- 12 rounds
  for r = 1, 12 do
    local s = SIGMA[r]
    -- Column step: (0,4,8,12), (1,5,9,13), (2,6,10,14), (3,7,11,15)
    -- Diagonal step: (0,5,10,15), (1,6,11,12), (2,7,8,13), (3,4,9,14)
    -- G(r, i, a, b, c, d) operates on v[a+1], v[b+1], v[c+1], v[d+1]
    -- with message words m[s[2*i+1]] and m[s[2*i+2]]
    -- (s is 0-based lua table, indices 1..16 map to sigma[r][1..16])

    -- Inline G for all 8 calls per round
    -- G(a, b, c, d, x, y):
    --   v[a] = v[a] + v[b] + x
    --   v[d] = rotr64(v[d] ^ v[a], 32)
    --   v[c] = v[c] + v[d]
    --   v[b] = rotr64(v[b] ^ v[c], 24)
    --   v[a] = v[a] + v[b] + y
    --   v[d] = rotr64(v[d] ^ v[a], 16)
    --   v[c] = v[c] + v[d]
    --   v[b] = rotr64(v[b] ^ v[c], 63)

    -- Column 0: a=1, b=5, c=9,  d=13, x=m[s[1]], y=m[s[2]]
    local a,b,c,d,x,y
    a=1; b=5; c=9;  d=13; x=m[s[1]];  y=m[s[2]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Column 1: a=2, b=6, c=10, d=14, x=m[s[3]], y=m[s[4]]
    a=2; b=6; c=10; d=14; x=m[s[3]];  y=m[s[4]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Column 2: a=3, b=7, c=11, d=15, x=m[s[5]], y=m[s[6]]
    a=3; b=7; c=11; d=15; x=m[s[5]];  y=m[s[6]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Column 3: a=4, b=8, c=12, d=16, x=m[s[7]], y=m[s[8]]
    a=4; b=8; c=12; d=16; x=m[s[7]];  y=m[s[8]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Diagonal 0: a=1, b=6, c=11, d=16, x=m[s[9]], y=m[s[10]]
    a=1; b=6; c=11; d=16; x=m[s[9]];  y=m[s[10]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Diagonal 1: a=2, b=7, c=12, d=13, x=m[s[11]], y=m[s[12]]
    a=2; b=7; c=12; d=13; x=m[s[11]]; y=m[s[12]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Diagonal 2: a=3, b=8, c=9,  d=14, x=m[s[13]], y=m[s[14]]
    a=3; b=8; c=9;  d=14; x=m[s[13]]; y=m[s[14]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)

    -- Diagonal 3: a=4, b=5, c=10, d=15, x=m[s[15]], y=m[s[16]]
    a=4; b=5; c=10; d=15; x=m[s[15]]; y=m[s[16]]
    v[a]=v[a]+v[b]+x;  v[d]=rotr64(bit.bxor(v[d],v[a]),32)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),24)
    v[a]=v[a]+v[b]+y;  v[d]=rotr64(bit.bxor(v[d],v[a]),16)
    v[c]=v[c]+v[d];    v[b]=rotr64(bit.bxor(v[b],v[c]),63)
  end

  -- Update state
  for i = 1, 8 do
    h[i] = bit.bxor(bit.bxor(h[i], v[i]), v[i + 8])
  end
end

-- Serialize uint64_t to 8 bytes, little-endian, appended to table t.
local function u64_to_bytes_le(v, t)
  local tmp = v
  for _ = 1, 8 do
    t[#t + 1] = string.char(tonumber(bit.band(tmp, U64(0xff))))
    tmp = bit.rshift(tmp, 8)
  end
end

-- Core BLAKE2b hash function.
-- Returns raw binary string on success, or nil + errmsg on error.
--: (string, number, string) -> string | nil, string
local function blake2b_raw(input, hash_len, key)
  key = key or ""
  hash_len = hash_len or 64
  if type(input) ~= "string" then
    return nil, "blake2b: input must be a string"
  end
  if hash_len < 1 or hash_len > 64 then
    return nil, "blake2b: hash_len must be 1-64"
  end
  if #key > 64 then
    return nil, "blake2b: key must be 0-64 bytes"
  end

  local key_len = #key

  -- Initialize state h[1..8] = IV
  local h = {}
  for i = 1, 8 do h[i] = B_IV[i] end

  -- Parameter block: h[1] ^= 0x01010000 ^ (key_len << 8) ^ hash_len
  -- Construct as uint64_t (only low 32 bits are non-zero for basic params)
  local param = U64(0x01010000) + U64(key_len * 256) + U64(hash_len)
  h[1] = bit.bxor(h[1], param)

  -- Prepare input: if keyed, prepend key block (key padded to 128 bytes)
  local data
  if key_len > 0 then
    data = key .. string.rep("\0", 128 - key_len) .. input
  else
    data = input
  end

  local data_len = #data
  -- Edge case: empty data (no key, empty input) — must still process one block
  if data_len == 0 then
    -- Process a single empty block (all zeros, final=true, counter=0)
    b_compress(h, string.rep("\0", 128), U64(0), U64(0), true)
  else
    local num_full = math.floor(data_len / 128)
    local rem = data_len % 128
    -- If data divides evenly into 128-byte blocks, the last full block is "final"
    -- and we do NOT add an extra empty block.
    local last_full_is_final = (rem == 0)
    local blocks_to_process = num_full
    if not last_full_is_final then
      blocks_to_process = num_full  -- partial block handled separately
    end

    -- Process full blocks (excluding the last block if it's the final one)
    local full_blocks_non_final = last_full_is_final and (num_full - 1) or num_full
    for i = 0, full_blocks_non_final - 1 do
      local off = i * 128
      local block = string.sub(data, off + 1, off + 128)
      local t_lo = U64((i + 1) * 128)
      b_compress(h, block, t_lo, U64(0), false)
    end

    if last_full_is_final then
      -- Last block is a full 128-byte block, it's the final one
      local off = (num_full - 1) * 128
      local block = string.sub(data, off + 1, off + 128)
      b_compress(h, block, U64(data_len), U64(0), true)
    else
      -- Process the partial (last) block padded to 128 bytes
      local off = num_full * 128
      local partial = string.sub(data, off + 1)
      local block = partial .. string.rep("\0", 128 - #partial)
      b_compress(h, block, U64(data_len), U64(0), true)
    end
  end

  -- Serialize h[1..hash_len bytes] as little-endian
  local out = {}
  local bytes_left = hash_len
  for i = 1, 8 do
    if bytes_left <= 0 then break end
    local tmp = h[i]
    for _ = 1, math.min(8, bytes_left) do
      out[#out + 1] = string.char(tonumber(bit.band(tmp, U64(0xff))))
      tmp = bit.rshift(tmp, 8)
    end
    bytes_left = bytes_left - 8
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- BLAKE2s — 32-bit word implementation using bit.*
-- ---------------------------------------------------------------------------

-- BLAKE2s initialization vectors (32-bit, same primes)
local S_IV = {
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
}

-- Rotate uint32 right by n bits (bit.* treats values as signed 32-bit).
--: (number, number) -> number
local function rotr32(v, n)
  return bit.bor(bit.rshift(v, n), bit.lshift(v, 32 - n))
end

-- Read 4 bytes from string s at byte offset (0-based), little-endian → uint32.
--: (string, number) -> number
local function read_u32_le(s, off)
  local b0, b1, b2, b3 = string.byte(s, off + 1, off + 4)
  b0 = b0 or 0; b1 = b1 or 0; b2 = b2 or 0; b3 = b3 or 0
  return bit.bor(b0, bit.lshift(b1, 8), bit.lshift(b2, 16), bit.lshift(b3, 24))
end

-- BLAKE2s compression: mutates h[1..8] in place.
-- block: 64-byte string (already zero-padded)
-- t_lo, t_hi: counter (low and high 32-bit words)
-- last: boolean
local function s_compress(h, block, t_lo, t_hi, last)
  local m = {}
  for i = 0, 15 do
    m[i] = read_u32_le(block, i * 4)
  end

  local v = {
    h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8],
    S_IV[1], S_IV[2], S_IV[3], S_IV[4],
    bit.bxor(t_lo, S_IV[5]),
    bit.bxor(t_hi, S_IV[6]),
    S_IV[7],
    S_IV[8],
  }

  if last then
    v[15] = bit.bxor(v[15], 0xffffffff)
  end

  -- G function for BLAKE2s: rotations are 16, 12, 8, 7
  -- Inline all 8 G calls for each of the 10 rounds

  for r = 1, 10 do
    local s = SIGMA[r]
    local a, b, c, d, x, y

    -- Column 0: a=1, b=5, c=9,  d=13
    a=1; b=5; c=9;  d=13; x=m[s[1]];  y=m[s[2]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Column 1: a=2, b=6, c=10, d=14
    a=2; b=6; c=10; d=14; x=m[s[3]];  y=m[s[4]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Column 2: a=3, b=7, c=11, d=15
    a=3; b=7; c=11; d=15; x=m[s[5]];  y=m[s[6]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Column 3: a=4, b=8, c=12, d=16
    a=4; b=8; c=12; d=16; x=m[s[7]];  y=m[s[8]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Diagonal 0: a=1, b=6, c=11, d=16
    a=1; b=6; c=11; d=16; x=m[s[9]];  y=m[s[10]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Diagonal 1: a=2, b=7, c=12, d=13
    a=2; b=7; c=12; d=13; x=m[s[11]]; y=m[s[12]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Diagonal 2: a=3, b=8, c=9,  d=14
    a=3; b=8; c=9;  d=14; x=m[s[13]]; y=m[s[14]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)

    -- Diagonal 3: a=4, b=5, c=10, d=15
    a=4; b=5; c=10; d=15; x=m[s[15]]; y=m[s[16]]
    v[a]=bit.tobit(v[a]+v[b]+x); v[d]=rotr32(bit.bxor(v[d],v[a]),16)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),12)
    v[a]=bit.tobit(v[a]+v[b]+y); v[d]=rotr32(bit.bxor(v[d],v[a]),8)
    v[c]=bit.tobit(v[c]+v[d]);   v[b]=rotr32(bit.bxor(v[b],v[c]),7)
  end

  for i = 1, 8 do
    h[i] = bit.bxor(bit.bxor(h[i], v[i]), v[i + 8])
  end
end

-- Core BLAKE2s hash function.
--: (string, number, string) -> string | nil, string
local function blake2s_raw(input, hash_len, key)
  key = key or ""
  hash_len = hash_len or 32
  if type(input) ~= "string" then
    return nil, "blake2s: input must be a string"
  end
  if hash_len < 1 or hash_len > 32 then
    return nil, "blake2s: hash_len must be 1-32"
  end
  if #key > 32 then
    return nil, "blake2s: key must be 0-32 bytes"
  end

  local key_len = #key

  local h = {}
  for i = 1, 8 do h[i] = S_IV[i] end

  -- Parameter block: h[1] ^= 0x01010000 ^ (key_len << 8) ^ hash_len
  h[1] = bit.bxor(h[1], bit.bor(0x01010000, bit.lshift(key_len, 8), hash_len))

  local data
  if key_len > 0 then
    data = key .. string.rep("\0", 64 - key_len) .. input
  else
    data = input
  end

  local data_len = #data
  if data_len == 0 then
    s_compress(h, string.rep("\0", 64), 0, 0, true)
  else
    local num_full = math.floor(data_len / 64)
    local rem = data_len % 64
    local last_full_is_final = (rem == 0)

    local full_blocks_non_final = last_full_is_final and (num_full - 1) or num_full
    for i = 0, full_blocks_non_final - 1 do
      local off = i * 64
      local block = string.sub(data, off + 1, off + 64)
      -- counter is cumulative bytes consumed (fits in 32 bits for reasonable inputs)
      local t_lo = bit.tobit((i + 1) * 64)
      s_compress(h, block, t_lo, 0, false)
    end

    if last_full_is_final then
      local off = (num_full - 1) * 64
      local block = string.sub(data, off + 1, off + 64)
      s_compress(h, block, bit.tobit(data_len), 0, true)
    else
      local off = num_full * 64
      local partial = string.sub(data, off + 1)
      local block = partial .. string.rep("\0", 64 - #partial)
      s_compress(h, block, bit.tobit(data_len), 0, true)
    end
  end

  -- Serialize h[1..hash_len bytes] as little-endian 32-bit words
  local out = {}
  local bytes_left = hash_len
  for i = 1, 8 do
    if bytes_left <= 0 then break end
    local w = h[i]
    local take = math.min(4, bytes_left)
    for _ = 1, take do
      out[#out + 1] = string.char(bit.band(w, 0xff))
      w = bit.rshift(w, 8)
    end
    bytes_left = bytes_left - 4
  end
  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Hex encoding helper
-- ---------------------------------------------------------------------------

--: (string) -> string
local function to_hex(s)
  local t = {}
  for i = 1, #s do
    t[i] = string.format("%02x", string.byte(s, i))
  end
  return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--: (string, table | nil) -> string | nil, string
function M.b_binary(input, opts)
  opts = opts or {}
  return blake2b_raw(input, opts.hash_len or 64, opts.key or "")
end

--: (string, table | nil) -> string | nil, string
function M.b(input, opts)
  local raw, err = M.b_binary(input, opts)
  if not raw then return nil, err end
  return to_hex(raw)
end

--: (string, table | nil) -> string | nil, string
function M.s_binary(input, opts)
  opts = opts or {}
  return blake2s_raw(input, opts.hash_len or 32, opts.key or "")
end

--: (string, table | nil) -> string | nil, string
function M.s(input, opts)
  local raw, err = M.s_binary(input, opts)
  if not raw then return nil, err end
  return to_hex(raw)
end

return M
