-- lib/murmurhash/init.lua
-- MurmurHash3 non-cryptographic hash functions.
-- All three variants: x86_32, x86_128, x64_128.
-- Pure Lua — requires LuaJIT's bit library for 32-bit arithmetic.
-- Reference: https://github.com/aappleby/smhasher/blob/master/src/MurmurHash3.cpp

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bxor, bor   = bit.band, bit.bxor, bit.bor
local lshift, rshift    = bit.lshift, bit.rshift
local tobit             = bit.tobit
local byte              = string.byte
local format            = string.format

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Multiply two 32-bit integers mod 2^32.
-- Lua numbers are doubles; direct multiplication can lose bits above 2^53.
-- Splitting b into 16-bit halves keeps each partial product under 2^48.
--: (integer, integer) -> integer
local function mul32(a, b)
  local blo = band(b, 0xffff)
  local bhi = rshift(b, 16)
  return tobit(a * blo + lshift(a * bhi, 16))
end

-- Rotate left 32-bit.
--: (integer, integer) -> integer
local function rotl32(x, r)
  return bor(lshift(x, r), rshift(x, 32 - r))
end

local FMIX32_C1 = math.floor(0x85ebca6b) --: integer
local FMIX32_C2 = math.floor(0xc2b2ae35) --: integer

-- Final mix of a 32-bit hash block — force all bits to avalanche.
--: (integer) -> integer
local function fmix32(h)
  h = bxor(h, rshift(h, 16))
  h = mul32(h, FMIX32_C1)
  h = bxor(h, rshift(h, 13))
  h = mul32(h, FMIX32_C2)
  h = bxor(h, rshift(h, 16))
  return h
end

-- Read 4 bytes from string s at byte offset pos (1-indexed) as uint32 LE.
--: (string, integer) -> integer
local function read_u32_le(s, pos)
  local a, b, c, d = byte(s, pos, pos + 3)
  return bor(a or 0, lshift(b or 0, 8), lshift(c or 0, 16), lshift(d or 0, 24))
end

-- Format a 32-bit integer as 8 lower-case hex digits.
-- tobit() returns a signed Lua number; add 2^32 when negative so %x sees the
-- correct unsigned bit pattern (doubles have enough precision for uint32_t).
--: (integer) -> string
local function hex32(v)
  if v < 0 then v = (v + 4294967296) --[[:! integer]] end
  return format("%08x", v)
end

-- ---------------------------------------------------------------------------
-- MurmurHash3_x86_32
-- ---------------------------------------------------------------------------

local C1_32 = math.floor(0xcc9e2d51) --: integer
local C2_32 = math.floor(0x1b873593) --: integer
local C3_32 = math.floor(0xe6546b64) --: integer

--: (string, integer | nil) -> (integer | nil, string | nil)
function M.x86_32(key, seed)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  seed = seed or 0

  local len  = #key
  local h1   = tobit(seed)
  local nblocks = rshift(len, 2)  -- floor(len/4)

  -- Body: process 4-byte blocks
  for i = 0, nblocks - 1 do
    local k1 = read_u32_le(key, i * 4 + 1)
    k1 = mul32(k1, C1_32)
    k1 = rotl32(k1, 15)
    k1 = mul32(k1, C2_32)
    h1 = bxor(h1, k1)
    h1 = rotl32(h1, 13)
    h1 = tobit(mul32(h1, 5) + tobit(C3_32))
  end

  -- Tail: remaining bytes
  local tail_start = nblocks * 4 + 1
  local rem = band(len, 3)  -- len % 4
  if rem > 0 then
    local k1 = 0
    if rem >= 3 then k1 = bxor(k1, lshift(byte(key, tail_start + 2) or 0, 16)) end
    if rem >= 2 then k1 = bxor(k1, lshift(byte(key, tail_start + 1) or 0,  8)) end
    k1 = bxor(k1, byte(key, tail_start) or 0)
    k1 = mul32(k1, C1_32)
    k1 = rotl32(k1, 15)
    k1 = mul32(k1, C2_32)
    h1 = bxor(h1, k1)
  end

  -- Finalization
  h1 = bxor(h1, len)
  h1 = fmix32(h1)
  return h1
end

--: (string, integer | nil) -> (string | nil, string | nil)
function M.x86_32_hex(key, seed)
  local h, err = M.x86_32(key, seed)
  if not h then return nil, err end
  return hex32(h)
end

-- ---------------------------------------------------------------------------
-- MurmurHash3_x86_128
-- ---------------------------------------------------------------------------

local C1_128x86 = math.floor(0x239b961b) --: integer
local C2_128x86 = math.floor(0xab0e9789) --: integer
local C3_128x86 = math.floor(0x38b34ae5) --: integer
local C4_128x86 = math.floor(0xa1e38b93) --: integer
local C5_128x86 = math.floor(0x561ccd1b) --: integer
local C6_128x86 = math.floor(0x0bcaa747) --: integer
local C7_128x86 = math.floor(0x96cd1c35) --: integer
local C8_128x86 = math.floor(0x32ac3b17) --: integer

-- Returns h1, h2, h3, h4 as four 32-bit integers.
--: (string, integer | nil) -> (integer | nil, integer | string | nil, integer | nil, integer | nil)
function M.x86_128(key, seed)
  if type(key) ~= "string" then
    return nil, "key must be a string", nil, nil
  end
  seed = seed or 0

  local len    = #key
  local h1     = tobit(seed)
  local h2     = tobit(seed)
  local h3     = tobit(seed)
  local h4     = tobit(seed)
  local nblocks = rshift(len, 4)  -- floor(len/16)

  -- Body: process 16-byte blocks
  for i = 0, nblocks - 1 do
    local base = i * 16 + 1
    local k1 = read_u32_le(key, base)
    local k2 = read_u32_le(key, base + 4)
    local k3 = read_u32_le(key, base + 8)
    local k4 = read_u32_le(key, base + 12)

    k1 = mul32(k1, C1_128x86); k1 = rotl32(k1, 15); k1 = mul32(k1, C2_128x86); h1 = bxor(h1, k1)
    h1 = rotl32(h1, 19); h1 = tobit(mul32(tobit(h1 + h2), 5) + tobit(C5_128x86))

    k2 = mul32(k2, C2_128x86); k2 = rotl32(k2, 16); k2 = mul32(k2, C3_128x86); h2 = bxor(h2, k2)
    h2 = rotl32(h2, 17); h2 = tobit(mul32(tobit(h2 + h3), 5) + tobit(C6_128x86))

    k3 = mul32(k3, C3_128x86); k3 = rotl32(k3, 17); k3 = mul32(k3, C4_128x86); h3 = bxor(h3, k3)
    h3 = rotl32(h3, 15); h3 = tobit(mul32(tobit(h3 + h4), 5) + tobit(C7_128x86))

    k4 = mul32(k4, C4_128x86); k4 = rotl32(k4, 18); k4 = mul32(k4, C1_128x86); h4 = bxor(h4, k4)
    h4 = rotl32(h4, 13); h4 = tobit(mul32(tobit(h4 + h1), 5) + tobit(C8_128x86))
  end

  -- Tail
  local tail_start = nblocks * 16 + 1
  local rem = band(len, 15)
  local k1, k2, k3, k4 = 0, 0, 0, 0

  if rem >= 15 then k4 = bxor(k4, lshift(byte(key, tail_start + 14) or 0, 16)) end
  if rem >= 14 then k4 = bxor(k4, lshift(byte(key, tail_start + 13) or 0,  8)) end
  if rem >= 13 then k4 = bxor(k4, byte(key, tail_start + 12) or 0) end
  if rem >= 13 then
    k4 = mul32(k4, C4_128x86); k4 = rotl32(k4, 18); k4 = mul32(k4, C1_128x86); h4 = bxor(h4, k4)
  end

  if rem >= 12 then k3 = bxor(k3, lshift(byte(key, tail_start + 11) or 0, 24)) end
  if rem >= 11 then k3 = bxor(k3, lshift(byte(key, tail_start + 10) or 0, 16)) end
  if rem >= 10 then k3 = bxor(k3, lshift(byte(key, tail_start +  9) or 0,  8)) end
  if rem >=  9 then k3 = bxor(k3, byte(key, tail_start + 8) or 0) end
  if rem >=  9 then
    k3 = mul32(k3, C3_128x86); k3 = rotl32(k3, 17); k3 = mul32(k3, C4_128x86); h3 = bxor(h3, k3)
  end

  if rem >=  8 then k2 = bxor(k2, lshift(byte(key, tail_start +  7) or 0, 24)) end
  if rem >=  7 then k2 = bxor(k2, lshift(byte(key, tail_start +  6) or 0, 16)) end
  if rem >=  6 then k2 = bxor(k2, lshift(byte(key, tail_start +  5) or 0,  8)) end
  if rem >=  5 then k2 = bxor(k2, byte(key, tail_start + 4) or 0) end
  if rem >=  5 then
    k2 = mul32(k2, C2_128x86); k2 = rotl32(k2, 16); k2 = mul32(k2, C3_128x86); h2 = bxor(h2, k2)
  end

  if rem >=  4 then k1 = bxor(k1, lshift(byte(key, tail_start +  3) or 0, 24)) end
  if rem >=  3 then k1 = bxor(k1, lshift(byte(key, tail_start +  2) or 0, 16)) end
  if rem >=  2 then k1 = bxor(k1, lshift(byte(key, tail_start +  1) or 0,  8)) end
  if rem >=  1 then k1 = bxor(k1, byte(key, tail_start) or 0) end
  if rem >=  1 then
    k1 = mul32(k1, C1_128x86); k1 = rotl32(k1, 15); k1 = mul32(k1, C2_128x86); h1 = bxor(h1, k1)
  end

  -- Finalization
  h1 = bxor(h1, len); h2 = bxor(h2, len); h3 = bxor(h3, len); h4 = bxor(h4, len)

  h1 = tobit(h1 + h2); h1 = tobit(h1 + h3); h1 = tobit(h1 + h4)
  h2 = tobit(h2 + h1); h3 = tobit(h3 + h1); h4 = tobit(h4 + h1)

  h1 = fmix32(h1); h2 = fmix32(h2)
  h3 = fmix32(h3); h4 = fmix32(h4)

  h1 = tobit(h1 + h2); h1 = tobit(h1 + h3); h1 = tobit(h1 + h4)
  h2 = tobit(h2 + h1); h3 = tobit(h3 + h1); h4 = tobit(h4 + h1)

  return h1, h2, h3, h4
end

--: (string, integer | nil) -> (string | nil, string | nil)
function M.x86_128_hex(key, seed)
  local h1, h2, h3, h4 = M.x86_128(key, seed)
  if not h1 then return nil, h2 --[[:! string | nil]] end
  return hex32(h1) .. hex32(h2 --[[:! integer]]) .. hex32(h3 --[[:! integer]]) .. hex32(h4 --[[:! integer]])
end

-- ---------------------------------------------------------------------------
-- MurmurHash3_x64_128
-- ---------------------------------------------------------------------------
-- Uses LuaJIT's FFI uint64_t for true 64-bit arithmetic.

local ffi = require("ffi")
local u64  = ffi.typeof("uint64_t") --[[: any]]

-- Rotate left 64-bit.
local function rotl64(x, r)
  return bor(lshift(x, r), rshift(x, 64 - r))
end

-- Read 8 bytes from string s at byte position pos (1-indexed) as uint64 LE.
local function read_u64_le(s, pos)
  local a, b, c, d, e, f, g, h = byte(s, pos, pos + 7)
  return u64(a)
    + lshift(u64(b),  8)
    + lshift(u64(c), 16)
    + lshift(u64(d), 24)
    + lshift(u64(e), 32)
    + lshift(u64(f), 40)
    + lshift(u64(g), 48)
    + lshift(u64(h), 56)
end

-- Final mix of a 64-bit hash block.
-- Constants use ULL suffix (LuaJIT extension) to avoid double precision loss
-- for values > 2^53.
local FMIX64_C1 = 0xff51afd7ed558ccdULL
local FMIX64_C2 = 0xc4ceb9fe1a85ec53ULL
--: (cdata) -> cdata
local function fmix64(k)
  k = bxor(k --[[:! integer]], rshift(k --[[:! integer]], 33)) --[[: any]]
  k = k * FMIX64_C1 --[[: any]]
  k = bxor(k --[[:! integer]], rshift(k --[[:! integer]], 33)) --[[: any]]
  k = k * FMIX64_C2 --[[: any]]
  k = bxor(k --[[:! integer]], rshift(k --[[:! integer]], 33)) --[[: any]]
  return k
end

-- ULL literals preserve all 64 bits (Lua doubles only have 53 bits of mantissa).
local C1_x64 = 0x87c37b91114253d5ULL
local C2_x64 = 0x4cf5ad432745937fULL

-- Returns h1, h2 as two uint64_t cdata values (128-bit total).
function M.x64_128(key, seed)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  seed = seed or 0

  local len     = #key
  local h1      = u64(seed)
  local h2      = u64(seed)
  local nblocks = rshift(len, 4)  -- floor(len/16)

  -- Body: process 16-byte blocks
  for i = 0, nblocks - 1 do
    local base = i * 16 + 1
    local k1 = read_u64_le(key, base)
    local k2 = read_u64_le(key, base + 8)

    k1 = k1 * C1_x64; k1 = rotl64(k1, 31); k1 = k1 * C2_x64; h1 = bxor(h1, k1)
    h1 = rotl64(h1, 27); h1 = h1 + h2; h1 = h1 * u64(5) + u64(0x52dce729)

    k2 = k2 * C2_x64; k2 = rotl64(k2, 33); k2 = k2 * C1_x64; h2 = bxor(h2, k2)
    h2 = rotl64(h2, 31); h2 = h2 + h1; h2 = h2 * u64(5) + u64(0x38495ab5)
  end

  -- Tail
  local tail_start = nblocks * 16 + 1
  local rem = band(len, 15)
  local k1, k2 = u64(0), u64(0)

  if rem >= 15 then k2 = bxor(k2, lshift(u64(byte(key, tail_start + 14)), 48)) end
  if rem >= 14 then k2 = bxor(k2, lshift(u64(byte(key, tail_start + 13)), 40)) end
  if rem >= 13 then k2 = bxor(k2, lshift(u64(byte(key, tail_start + 12)), 32)) end
  if rem >= 12 then k2 = bxor(k2, lshift(u64(byte(key, tail_start + 11)), 24)) end
  if rem >= 11 then k2 = bxor(k2, lshift(u64(byte(key, tail_start + 10)), 16)) end
  if rem >= 10 then k2 = bxor(k2, lshift(u64(byte(key, tail_start +  9)),  8)) end
  if rem >=  9 then k2 = bxor(k2, u64(byte(key, tail_start + 8))) end
  if rem >=  9 then
    k2 = k2 * C2_x64; k2 = rotl64(k2, 33); k2 = k2 * C1_x64; h2 = bxor(h2, k2)
  end

  if rem >=  8 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  7)), 56)) end
  if rem >=  7 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  6)), 48)) end
  if rem >=  6 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  5)), 40)) end
  if rem >=  5 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  4)), 32)) end
  if rem >=  4 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  3)), 24)) end
  if rem >=  3 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  2)), 16)) end
  if rem >=  2 then k1 = bxor(k1, lshift(u64(byte(key, tail_start +  1)),  8)) end
  if rem >=  1 then k1 = bxor(k1, u64(byte(key, tail_start))) end
  if rem >=  1 then
    k1 = k1 * C1_x64; k1 = rotl64(k1, 31); k1 = k1 * C2_x64; h1 = bxor(h1, k1)
  end

  -- Finalization
  h1 = bxor(h1, u64(len))
  h2 = bxor(h2, u64(len))

  h1 = h1 + h2
  h2 = h2 + h1

  h1 = fmix64((h1 --[[:! cdata]])) --[[: any]]
  h2 = fmix64((h2 --[[:! cdata]])) --[[: any]]

  h1 = h1 + h2
  h2 = h2 + h1

  return h1, h2
end

-- Format a uint64_t cdata as 16 lower-case hex digits.
-- Prints high 32 bits first (standard numeric/big-endian hex representation),
-- which matches what you get reading the reference C output buffer on a LE machine
-- when the caller displays h1 then h2 as 64-bit integers.
local function hex64(v)
  local hi = tonumber(rshift(v --[[:! integer]], 32)) or 0
  local lo = tonumber(band(v --[[:! integer]], u64(0xffffffff) --[[:! integer]])) or 0
  return hex32(hi --[[:! integer]]) .. hex32(lo --[[:! integer]])
end

--: (string, integer | nil) -> (string | nil, string | nil)
function M.x64_128_hex(key, seed)
  local h1, h2 = M.x64_128(key, seed)
  if not h1 then return nil, h2 --[[:! string | nil]] end
  return hex64(h1) .. hex64(h2 --[[: any]])
end

-- ---------------------------------------------------------------------------
-- Convenience aliases
-- ---------------------------------------------------------------------------

M.hash32  = M.x86_32
M.hash128 = M.x64_128

return M
