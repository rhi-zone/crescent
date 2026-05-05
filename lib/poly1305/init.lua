-- lib/poly1305/init.lua
-- Poly1305 one-time MAC (RFC 8439 §2.5).
--
-- Public API:
--   M.auth(key, message)            -> tag (16-byte binary) | nil, errmsg
--   M.auth_hex(key, message)        -> tag (32-char hex)    | nil, errmsg
--   M.verify(key, message, tag)     -> true | false
--   M.new(key)                      -> ctx | nil, errmsg
--   ctx:update(chunk)               -> ctx | nil, errmsg
--   ctx:finish()                    -> tag (16-byte binary) | nil, errmsg
--   M._tier = "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local bit = require("bit")

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Aliases
-- ---------------------------------------------------------------------------

local band   = bit.band
local bxor   = bit.bxor
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift
local sbyte  = string.byte
local schar  = string.char
local concat = table.concat

-- ---------------------------------------------------------------------------
-- FFI uint64 helpers
-- ---------------------------------------------------------------------------

local U64    = ffi.typeof("uint64_t")
local U0     = U64(0)
local U5     = U64(5)
local U256   = U64(256)
local MASK26  = U64(0x3ffffff)
local SHIFT26 = U64(67108864)   -- 2^26

-- ---------------------------------------------------------------------------
-- Clamp r per RFC 8439 §2.5
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Decode 16 bytes (as a 1-indexed Lua table of byte values) into 5×26-bit
-- limbs stored as uint64_t.  Value = n0 + n1·2^26 + n2·2^52 + n3·2^78 + n4·2^104.
-- ---------------------------------------------------------------------------

local function decode_26(b)
  local n0 = U64(b[1])
    + U64(b[2]) * U64(256)
    + U64(b[3]) * U64(65536)
    + U64(band(b[4], 3)) * U64(16777216)
  local n1 = U64(rshift(b[4], 2))
    + U64(b[5]) * U64(64)
    + U64(b[6]) * U64(16384)
    + U64(band(b[7], 15)) * U64(4194304)
  local n2 = U64(rshift(b[7], 4))
    + U64(b[8]) * U64(16)
    + U64(b[9]) * U64(4096)
    + U64(band(b[10], 63)) * U64(1048576)
  local n3 = U64(rshift(b[10], 6))
    + U64(b[11]) * U64(4)
    + U64(b[12]) * U64(1024)
    + U64(b[13]) * U64(262144)
  local n4 = U64(b[14])
    + U64(b[15]) * U64(256)
    + U64(b[16]) * U64(65536)
  return n0, n1, n2, n3, n4
end

-- ---------------------------------------------------------------------------
-- Core MAC computation on a pre-parsed context.
--
-- Internal state carried in a context table:
--   .h0..h4   : accumulator limbs (uint64_t)
--   .r0..r4   : r limbs (uint64_t)
--   .r1_5..r4_5 : r limbs pre-multiplied by 5 (uint64_t)
--   .s_str    : 16-byte s value (string)
--   .buf      : buffered partial block (string, len < 16)
--
-- This design keeps finish() side-effect-free by never mutating the context
-- in place during finish — it reads from it then returns a fresh tag.
-- ---------------------------------------------------------------------------

-- Process a single 16-byte (or shorter final) block, updating h limbs.
--: (table, table, number) -> nil
local function process_block(ctx, n, blocklen)
  local n0, n1, n2, n3, n4 = decode_26(n)

  -- Add the 2^(8*blocklen) bit ("hibit") to the appropriate limb.
  local bit_pos    = 8 * blocklen
  local limb_idx   = math.floor(bit_pos / 26)
  local bit_in_limb = bit_pos % 26
  local add_val    = U64(lshift(1, bit_in_limb))
  if     limb_idx == 0 then n0 = n0 + add_val
  elseif limb_idx == 1 then n1 = n1 + add_val
  elseif limb_idx == 2 then n2 = n2 + add_val
  elseif limb_idx == 3 then n3 = n3 + add_val
  else                       n4 = n4 + add_val
  end

  -- h += n
  local h0 = ctx.h0 + n0
  local h1 = ctx.h1 + n1
  local h2 = ctx.h2 + n2
  local h3 = ctx.h3 + n3
  local h4 = ctx.h4 + n4

  -- h = h * r  mod (2^130 - 5)
  -- Schoolbook multiply of two 5-limb numbers with modular wrap:
  -- 2^130 ≡ 5 (mod 2^130-5), so limbs that overflow shift back scaled by 5.
  local r0   = ctx.r0;   local r1   = ctx.r1;   local r2   = ctx.r2
  local r3   = ctx.r3;   local r4   = ctx.r4
  local r1_5 = ctx.r1_5; local r2_5 = ctx.r2_5; local r3_5 = ctx.r3_5
  local r4_5 = ctx.r4_5

  local d0 = h0*r0   + h1*r4_5 + h2*r3_5 + h3*r2_5 + h4*r1_5
  local d1 = h0*r1   + h1*r0   + h2*r4_5 + h3*r3_5 + h4*r2_5
  local d2 = h0*r2   + h1*r1   + h2*r0   + h3*r4_5 + h4*r3_5
  local d3 = h0*r3   + h1*r2   + h2*r1   + h3*r0   + h4*r4_5
  local d4 = h0*r4   + h1*r3   + h2*r2   + h3*r1   + h4*r0

  -- Carry-propagate to reduce each limb back towards 26 bits.
  local c
  c = d0 / SHIFT26; h0 = band(d0, MASK26); d1 = d1 + c
  c = d1 / SHIFT26; h1 = band(d1, MASK26); d2 = d2 + c
  c = d2 / SHIFT26; h2 = band(d2, MASK26); d3 = d3 + c
  c = d3 / SHIFT26; h3 = band(d3, MASK26); d4 = d4 + c
  c = d4 / SHIFT26; h4 = band(d4, MASK26); h0 = h0 + c * U5
  c = h0 / SHIFT26; h0 = band(h0, MASK26); h1 = h1 + c

  ctx.h0 = h0; ctx.h1 = h1; ctx.h2 = h2; ctx.h3 = h3; ctx.h4 = h4
end

-- Finalise: apply full reduction mod (2^130-5) and add s, returning a 16-byte tag.
--: (table) -> string
local function finalise(ctx)
  local h0, h1, h2, h3, h4 = ctx.h0, ctx.h1, ctx.h2, ctx.h3, ctx.h4

  -- Full reduction: if h >= 2^130-5, subtract 2^130-5 (equivalently add 5 and
  -- check whether the carry propagates all the way to bit 130).
  local g0 = h0 + U5
  local c  = g0 / SHIFT26
  local g1 = h1 + c; c = g1 / SHIFT26
  local g2 = h2 + c; c = g2 / SHIFT26
  local g3 = h3 + c; c = g3 / SHIFT26
  local g4 = h4 + c
  -- use_g == 1 when h >= p (carry propagated through all limbs).
  local use_g  = tonumber(g4 / SHIFT26)
  local keep_h = 1 - use_g
  h0 = h0 * U64(keep_h) + band(g0, MASK26) * U64(use_g)
  h1 = h1 * U64(keep_h) + band(g1, MASK26) * U64(use_g)
  h2 = h2 * U64(keep_h) + band(g2, MASK26) * U64(use_g)
  h3 = h3 * U64(keep_h) + band(g3, MASK26) * U64(use_g)
  h4 = h4 * U64(keep_h) + band(g4, MASK26) * U64(use_g)

  -- Serialize h (5×26-bit limbs) into two 64-bit halves.
  -- lo64 covers bits 0..63, hi64 covers bits 64..127.
  local h2_lo = band(h2, U64(0xfff))        -- bits 0..11 of h2  (at bit 52)
  local h2_hi = h2 / U64(0x1000)            -- bits 12..25 of h2 (at bit 64)
  local lo64  = h0 + h1 * SHIFT26 + h2_lo * U64(0x10000000000000ULL)
  local hi64  = h2_hi + h3 * U64(0x4000) + h4 * U64(0x10000000000ULL)

  -- Extract bytes from lo64 then hi64.
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

  -- Add s mod 2^128 (little-endian byte addition with carry).
  local sb    = { sbyte(ctx.s_str, 1, 16) }
  local carry = 0
  for i = 1, 16 do
    local sum = out[i] + sb[i] + carry
    out[i] = sum % 256
    carry  = math.floor(sum / 256)
  end

  return schar(unpack(out))
end

-- ---------------------------------------------------------------------------
-- Create and initialise a context from a 32-byte key.
-- Returns a context table, or nil+errmsg on bad input.
-- ---------------------------------------------------------------------------

--: (string) -> (table | nil, string | nil)
local function new_ctx(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end
  if #key ~= 32 then
    return nil, "key must be exactly 32 bytes"
  end

  local r_str = clamp_r(key:sub(1, 16))
  local rb    = { sbyte(r_str, 1, 16) }
  local r0, r1, r2, r3, r4 = decode_26(rb)

  local ctx = {
    -- accumulator
    h0 = U0, h1 = U0, h2 = U0, h3 = U0, h4 = U0,
    -- r limbs
    r0 = r0, r1 = r1, r2 = r2, r3 = r3, r4 = r4,
    -- r limbs × 5 (used in modular multiply)
    r1_5 = r1 * U5, r2_5 = r2 * U5, r3_5 = r3 * U5, r4_5 = r4 * U5,
    -- s (last 16 bytes of key, used in finalise)
    s_str = key:sub(17, 32),
    -- partial-block buffer (string, always < 16 bytes)
    buf = "",
    -- whether finish() has been called
    done = false,
  }
  return ctx
end

-- ---------------------------------------------------------------------------
-- Streaming context methods
-- ---------------------------------------------------------------------------

local Ctx = {}
Ctx.__index = Ctx

--: (string) -> (table | nil, string | nil)
function Ctx:update(chunk)
  if self.done then
    return nil, "cannot update a finished context"
  end
  if type(chunk) ~= "string" then
    return nil, "chunk must be a string"
  end
  if chunk == "" then return self end

  local data = self.buf .. chunk
  self.buf = ""
  local pos = 1
  local len = #data

  while pos + 15 <= len do
    local n = { sbyte(data, pos, pos + 15) }
    process_block(self, n, 16)
    pos = pos + 16
  end

  -- Keep any leftover bytes < 16 in the buffer.
  if pos <= len then
    self.buf = data:sub(pos)
  end

  return self
end

--: () -> (string | nil, string | nil)
function Ctx:finish()
  if self.done then
    return nil, "context already finished"
  end
  self.done = true

  -- Process final partial block (may be empty if message is block-aligned).
  local buf = self.buf
  if #buf > 0 then
    local blocklen = #buf
    -- Zero-pad to 16 bytes.
    local n = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
    for i = 1, blocklen do
      n[i] = sbyte(buf, i)
    end
    process_block(self, n, blocklen)
  end

  return finalise(self)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Create a streaming Poly1305 context.
-- Returns ctx (with :update() / :finish() methods), or nil+errmsg.
--: (string) -> (table | nil, string | nil)
function M.new(key)
  local ctx, err = new_ctx(key)
  if not ctx then return nil, err end
  setmetatable(ctx, Ctx)
  return ctx
end

--- Compute Poly1305 MAC over message with key.
-- Returns 16-byte binary tag, or nil+errmsg.
--: (string, string) -> (string | nil, string | nil)
function M.auth(key, message)
  if type(message) ~= "string" then
    return nil, "message must be a string"
  end
  local ctx, err = M.new(key)
  if not ctx then return nil, err end
  local ok, uerr = ctx:update(message)
  if not ok then return nil, uerr end
  return ctx:finish()
end

--- Like auth() but returns a 32-character lowercase hex string.
--: (string, string) -> (string | nil, string | nil)
function M.auth_hex(key, message)
  local tag, err = M.auth(key, message)
  if not tag then return nil, err end
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format("%02x", sbyte(tag, i))
  end
  return concat(hex)
end

--- Timing-safe verify: returns true iff auth(key, message) == tag.
--: (string, string, string) -> boolean
function M.verify(key, message, tag)
  if type(tag) ~= "string" or #tag ~= 16 then return false end
  local expected, err = M.auth(key, message)
  if not expected then return false end
  -- Constant-time comparison: accumulate XOR differences.
  local diff = 0
  for i = 1, 16 do
    diff = bor(diff, bxor(sbyte(tag, i), sbyte(expected, i)))
  end
  return diff == 0
end

return M
