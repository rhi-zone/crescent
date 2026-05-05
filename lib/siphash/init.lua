if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- SipHash-2-4 and SipHash-1-3: fast, secure PRF / MAC for hash tables and short messages.
-- Reference: https://131002.net/siphash/
-- Pure Lua implementation using LuaJIT FFI uint64_t arithmetic.
--
-- API:
--   M.hash(key, msg)       → uint64_t | (nil, errmsg)   SipHash-2-4
--   M.hash_hex(key, msg)   → string   | (nil, errmsg)   16 hex chars, little-endian bytes
--   M.hash_pair(key, msg)  → {lo,hi}  | (nil, errmsg)   two uint32 halves
--   M.hash13(key, msg)     → uint64_t | (nil, errmsg)   SipHash-1-3
--   M.hash13_hex(key, msg) → string   | (nil, errmsg)
--   M._tier = "pure"

local ffi = require("ffi")
local bit = require("bit")

local M = {}
M._tier = "pure"

--:: uint64_t = integer

local U64 = ffi.typeof("uint64_t") --[[: any]]

-- Bitmask for isolating lower 32 bits (used in hash_pair).
local MASK32 = U64(0xffffffff)

-- Build a uint64_t from two 32-bit halves.
-- Required for constants > 2^53 (Lua doubles lose precision for large integer literals).
--: (integer, integer) -> uint64_t
local function u64(hi32, lo32)
  return U64(hi32) * U64(0x100000000) + U64(lo32)
end

-- ---------------------------------------------------------------------------
-- Low-level 64-bit helpers
-- ---------------------------------------------------------------------------

-- Rotate uint64_t left by n bits.
--: (uint64_t, integer) -> uint64_t
local function rotl64(v, n)
  return bit.bor(bit.lshift(v, n), bit.rshift(v, 64 - n))
end

-- Read 8 bytes from string s starting at byte index i (1-based), little-endian.
-- Built from two 32-bit halves to avoid double-precision loss for the high word.
--: (string, integer) -> uint64_t
local function read_u64_le(s, i)
  local byte_ = string.byte --[[: any]]
  local b0, b1, b2, b3, b4, b5, b6, b7 = byte_(s, i, i + 7)
  local lo = U64(b0) + U64(b1) * U64(256) + U64(b2) * U64(65536) + U64(b3) * U64(16777216)
  local hi = U64(b4) + U64(b5) * U64(256) + U64(b6) * U64(65536) + U64(b7) * U64(16777216)
  return lo + hi * U64(0x100000000)
end

-- Read 16-byte key string into two uint64_t (k0, k1) little-endian.
--: (string) -> (uint64_t, uint64_t)
local function read_key(key)
  return read_u64_le(key, 1), read_u64_le(key, 9)
end

-- Format a uint64_t as 16 hex chars in little-endian byte order
-- (bytes from low to high, i.e. lo byte first).
--: (uint64_t) -> string
local function u64_to_hex_le(v)
  -- Extract 8 bytes in little-endian order.
  local bytes = {} --: { [integer]: string }
  local tmp = v
  local sfmt = string.format --[[: any]]
  for i = 1, 8 do
    bytes[i] = sfmt("%02x", tonumber(bit.band(tmp, U64(0xff))) or 0)
    tmp = bit.rshift(tmp, 8)
  end
  return table.concat(bytes)
end

-- ---------------------------------------------------------------------------
-- SipRound (shared by all variants)
-- ---------------------------------------------------------------------------

-- Four state words are passed by value (uint64_t); the updated four are returned.
-- LuaJIT FFI cdata returned from a function is cheap (8 bytes each).
--: (uint64_t, uint64_t, uint64_t, uint64_t) -> (uint64_t, uint64_t, uint64_t, uint64_t)
local function sip_round(v0, v1, v2, v3)
  v0 = v0 + v1
  v1 = rotl64(v1, 13)
  v1 = bit.bxor(v1, v0)
  v0 = rotl64(v0, 32)

  v2 = v2 + v3
  v3 = rotl64(v3, 16)
  v3 = bit.bxor(v3, v2)

  v0 = v0 + v3
  v3 = rotl64(v3, 21)
  v3 = bit.bxor(v3, v0)

  v2 = v2 + v1
  v1 = rotl64(v1, 17)
  v1 = bit.bxor(v1, v2)
  v2 = rotl64(v2, 32)

  return v0, v1, v2, v3
end

-- ---------------------------------------------------------------------------
-- Core SipHash engine
-- ---------------------------------------------------------------------------

-- Compute SipHash-c-d for the given key and message.
-- c: compression rounds, d: finalization rounds.
--: (string, string, number, number) -> (uint64_t | nil, string)
local function siphash(key, msg, c, d)
  if type(key) ~= "string" or #key ~= 16 then
    return nil, "siphash: key must be a 16-byte string"
  end
  if type(msg) ~= "string" then
    return nil, "siphash: message must be a string"
  end

  local k0, k1 = read_key(key)

  -- Initialization constants (split into hi/lo 32-bit pairs to avoid double precision loss).
  local v0 = bit.bxor(k0, u64(0x736f6d65, 0x70736575))
  local v1 = bit.bxor(k1, u64(0x646f7261, 0x6e646f6d))
  local v2 = bit.bxor(k0, u64(0x6c796765, 0x6e657261))
  local v3 = bit.bxor(k1, u64(0x74656462, 0x79746573))

  local len = #msg
  local blocks = math.floor(len / 8)

  -- Process full 8-byte blocks.
  for b = 0, blocks - 1 do
    local m = read_u64_le(msg, b * 8 + 1)
    v3 = bit.bxor(v3, m)
    for _ = 1, c do
      v0, v1, v2, v3 = sip_round(v0, v1, v2, v3)
    end
    v0 = bit.bxor(v0, m)
  end

  -- Build the last block: remaining bytes (little-endian) + message length mod 256 in byte 7 (high byte).
  -- The length byte occupies bit 56..63: use two multiplications to stay within 32-bit range.
  -- U64(len%256) * U64(0x01000000) * U64(0x100000000) = len_byte << 56
  local rem_start = blocks * 8  -- 0-based index of remaining bytes
  local rem = len - rem_start

  -- Build low 32 bits (bytes 0..3) and high 32 bits (bytes 4..7) separately.
  local lo32 = U64(0)
  local hi32 = U64(len % 256) * U64(0x01000000)  -- length byte into bits 24..31 of hi word = bit 56..63 overall
  if rem >= 1 then lo32 = bit.bor(lo32, U64(string.byte(msg, rem_start + 1))) end
  if rem >= 2 then lo32 = bit.bor(lo32, U64(string.byte(msg, rem_start + 2)) * U64(256)) end
  if rem >= 3 then lo32 = bit.bor(lo32, U64(string.byte(msg, rem_start + 3)) * U64(65536)) end
  if rem >= 4 then lo32 = bit.bor(lo32, U64(string.byte(msg, rem_start + 4)) * U64(16777216)) end
  if rem >= 5 then hi32 = bit.bor(hi32, U64(string.byte(msg, rem_start + 5))) end
  if rem >= 6 then hi32 = bit.bor(hi32, U64(string.byte(msg, rem_start + 6)) * U64(256)) end
  if rem >= 7 then hi32 = bit.bor(hi32, U64(string.byte(msg, rem_start + 7)) * U64(65536)) end
  local last = lo32 + hi32 * U64(0x100000000)

  -- Compress the last block.
  v3 = bit.bxor(v3, last)
  for _ = 1, c do
    v0, v1, v2, v3 = sip_round(v0, v1, v2, v3)
  end
  v0 = bit.bxor(v0, last)

  -- Finalization.
  v2 = bit.bxor(v2, U64(0xff))
  for _ = 1, d do
    v0, v1, v2, v3 = sip_round(v0, v1, v2, v3)
  end

  return bit.bxor(bit.bxor(v0, v1), bit.bxor(v2, v3))
end

-- ---------------------------------------------------------------------------
-- Public API — SipHash-2-4
-- ---------------------------------------------------------------------------

--: (string, string) -> (uint64_t | nil, string)
function M.hash(key, msg)
  return siphash(key, msg, 2, 4)
end

--: (string, string) -> (string | nil, string)
function M.hash_hex(key, msg)
  local h, err = siphash(key, msg, 2, 4)
  if not h then return nil, err end
  return u64_to_hex_le(h)
end

--: (string, string) -> ({ lo: number | nil, hi: number | nil } | nil, string | nil)
function M.hash_pair(key, msg)
  local h, err = siphash(key, msg, 2, 4)
  if not h then return nil, err end
  local lo = tonumber(bit.band(h, MASK32))
  local hi = tonumber(bit.band(bit.rshift(h, 32), MASK32))
  return { lo = lo, hi = hi }
end

-- ---------------------------------------------------------------------------
-- Public API — SipHash-1-3 (faster variant)
-- ---------------------------------------------------------------------------

--: (string, string) -> (uint64_t | nil, string)
function M.hash13(key, msg)
  return siphash(key, msg, 1, 3)
end

--: (string, string) -> (string | nil, string)
function M.hash13_hex(key, msg)
  local h, err = siphash(key, msg, 1, 3)
  if not h then return nil, err end
  return u64_to_hex_le(h)
end

return M
