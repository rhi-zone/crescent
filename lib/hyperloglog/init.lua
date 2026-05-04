-- lib/hyperloglog/init.lua
-- HyperLogLog++ probabilistic cardinality estimator.
-- Flajolet et al. (2007) + Heule et al. (2013) improvements.
-- Pure Lua — no dependencies beyond LuaJIT bit library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = bit  -- LuaJIT global
local band, bor, bxor, lshift, rshift =
  bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local floor, log = math.floor, math.log

-- ---------------------------------------------------------------------------
-- MurmurHash3 32-bit (Austin Appleby)
-- Produces well-distributed 32-bit hashes without precision loss.
-- ---------------------------------------------------------------------------

-- 32-bit multiply keeping only low 32 bits.
-- LuaJIT doubles have 53-bit mantissa; products of two 32-bit values can reach
-- 2^64, which overflows. Split into 16-bit halves to stay within 53 bits.
local function mul32(a, b)
  a = band(a, 0xFFFFFFFF)
  b = band(b, 0xFFFFFFFF)
  local alo = band(a, 0xFFFF)
  local ahi = rshift(a, 16)
  local blo = band(b, 0xFFFF)
  local bhi = rshift(b, 16)
  -- low32(a*b) = low32(ahi*blo*2^16 + alo*bhi*2^16 + alo*blo)
  local lo = alo * blo
  local mi = alo * bhi + ahi * blo
  return band(
    bor(band(lo, 0xFFFF), lshift(band(rshift(lo, 16) + band(mi, 0xFFFF), 0xFFFF), 16)),
    0xFFFFFFFF
  )
end

local function rotl32(x, r)
  return bor(lshift(x, r), rshift(x, 32 - r))
end

-- MurmurHash3 constants
local MM_C1 = 0xcc9e2d51
local MM_C2 = 0x1b873593

-- MurmurHash3 32-bit hash of string s with optional seed (default 0).
-- Returns a 32-bit value (may be negative as LuaJIT signed i32).
local function murmur3_32(s, seed)
  local h = seed or 0
  local len = #s
  local nblocks = floor(len / 4)
  -- Process 4-byte blocks
  for i = 0, nblocks - 1 do
    local off = i * 4 + 1
    local b1, b2, b3, b4 = string.byte(s, off, off + 3)
    local k = bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24))
    k = mul32(k, MM_C1)
    k = rotl32(k, 15)
    k = mul32(k, MM_C2)
    h = bxor(h, k)
    h = rotl32(h, 13)
    h = band(mul32(h, 5) + 0xe6546b64, 0xFFFFFFFF)
  end
  -- Tail (remaining 1-3 bytes)
  local tail = nblocks * 4
  local k = 0
  local rem = len % 4
  if rem >= 3 then k = bxor(k, lshift(string.byte(s, tail + 3), 16)) end
  if rem >= 2 then k = bxor(k, lshift(string.byte(s, tail + 2), 8)) end
  if rem >= 1 then
    k = bxor(k, string.byte(s, tail + 1))
    k = mul32(k, MM_C1)
    k = rotl32(k, 15)
    k = mul32(k, MM_C2)
    h = bxor(h, k)
  end
  -- Finalization mix
  h = bxor(h, len)
  h = bxor(h, rshift(h, 16))
  h = mul32(h, 0x85ebca6b)
  h = bxor(h, rshift(h, 13))
  h = mul32(h, 0xc2b2ae35)
  h = bxor(h, rshift(h, 16))
  return h
end

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Find position of first set bit in the `bits`-wide value w (MSB-first).
-- Returns 1 if the top bit is set, bits+1 if all zeros.
-- This is ρ(w) in the HyperLogLog paper.
local function rho(w, bits)
  local mask = lshift(1, bits - 1)
  for i = 1, bits do
    if band(w, mask) ~= 0 then return i end
    mask = rshift(mask, 1)
  end
  return bits + 1
end

-- Alpha_m bias correction constant.
local function alpha_m(m)
  if m == 16  then return 0.673 end
  if m == 32  then return 0.697 end
  if m == 64  then return 0.709 end
  return 0.7213 / (1 + 1.079 / m)  -- m >= 128
end

-- ---------------------------------------------------------------------------
-- HyperLogLog object
-- ---------------------------------------------------------------------------

local HLL = {}
HLL.__index = HLL

-- Add an element (string or number converted to string).
function HLL:add(element)
  local s = type(element) == "string" and element or tostring(element)
  local h = murmur3_32(s)
  local b = self._b
  -- Register index: top b bits as unsigned integer, 1-indexed.
  -- rshift on LuaJIT does logical (unsigned) shift even on negative i32 values.
  local j = rshift(h, 32 - b) + 1
  -- Remaining (32-b) lower bits for ρ computation.
  local w = band(h, lshift(1, 32 - b) - 1)
  local r = rho(w, 32 - b)
  if r > self._regs[j] then
    self._regs[j] = r
  end
end

-- Estimate the number of distinct elements.
function HLL:count()
  local m    = self._m --[[:! integer]]
  local regs = self._regs --[[:! { [integer]: number }]]
  -- Compute harmonic mean denominator Z and count empty registers V.
  local Z = 0 --: number
  local V = 0
  for i = 1, m do
    local r = regs[i]
    Z = Z + 2 ^ (-r)
    if r == 0 then V = V + 1 end
  end
  local E = self._alpha --[[:! number]] * m * m / Z
  -- Small-range correction: use linear counting when estimate is small and
  -- there are empty registers (Flajolet et al. §4).
  if E <= 2.5 * m and V > 0 then
    E = m * log(m / V)
  end
  E = E --[[:! number]]
  -- Large-range correction for 32-bit hash space saturation (§4).
  local two32 = 4294967296  -- 2^32
  if E > two32 / 30 then
    E = -two32 * log(1 - E / two32)
  end
  return floor(E + 0.5)
end

-- Merge another HLL (same precision) into this one in-place (union).
-- Returns self on success, nil+err if precisions differ.
function HLL:merge(other)
  if self._b ~= other._b then
    return nil, "hyperloglog:merge: precision mismatch (" ..
      self._b .. " vs " .. other._b .. ")"
  end
  local sr, or_ = self._regs, other._regs
  for i = 1, self._m do
    if or_[i] > sr[i] then sr[i] = or_[i] end
  end
  return self
end

-- Serialize to a compact binary string.
-- Format: 1 byte precision b, then m bytes (one byte per register).
-- Register values fit in one byte since max ρ ≤ 32-b+1 ≤ 29 for b≥4.
function HLL:serialize()
  local m    = self._m
  local regs = self._regs
  local t    = { string.char(self._b) }
  for i = 1, m do
    t[i + 1] = string.char(regs[i])
  end
  return table.concat(t)
end

-- Number of register index bits (the precision parameter).
function HLL:precision()
  return self._b
end

-- Number of registers (= 2^precision).
function HLL:registers()
  return self._m
end

-- Approximate memory usage in bytes (Lua table overhead not included).
function HLL:memory()
  -- One Lua number per register (8 bytes each) plus object overhead.
  return self._m * 8 + 64
end

-- ---------------------------------------------------------------------------
-- Module constructors
-- ---------------------------------------------------------------------------

-- Create a new HyperLogLog estimator.
-- precision: integer in 4..16 (default 12).
--   m = 2^precision registers, relative error ≈ 0.81/sqrt(m).
function M.new(precision)
  precision = precision or 12
  if type(precision) ~= "number" or precision < 4 or precision > 16 then
    return nil, "hyperloglog.new: precision must be 4..16, got " .. tostring(precision)
  end
  precision = floor(precision)
  local m    = lshift(1, precision)
  local regs = {}
  for i = 1, m do regs[i] = 0 end
  return setmetatable({
    _b     = precision,
    _m     = m,
    _alpha = alpha_m(m),
    _regs  = regs,
  }, HLL)
end

-- Deserialize a binary string produced by hll:serialize().
function M.deserialize(s)
  if type(s) ~= "string" or #s < 1 then
    return nil, "hyperloglog.deserialize: invalid input"
  end
  local b = string.byte(s, 1)
  if b < 4 or b > 16 then
    return nil, "hyperloglog.deserialize: invalid precision byte " .. tostring(b)
  end
  local m = lshift(1, b)
  if #s ~= m + 1 then
    return nil, "hyperloglog.deserialize: expected " .. (m + 1) ..
      " bytes, got " .. #s
  end
  local regs = {}
  for i = 1, m do
    regs[i] = string.byte(s, i + 1)
  end
  return setmetatable({
    _b     = b,
    _m     = m,
    _alpha = alpha_m(m),
    _regs  = regs,
  }, HLL)
end

return M
