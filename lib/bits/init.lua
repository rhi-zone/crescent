if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Bitset and Bloom filter implementations.
-- Fixed-size bitsets with set operations, plus a probabilistic Bloom filter.

local floor = math.floor
local ceil = math.ceil
local log = math.log
local abs = math.abs

local M = {}

-- Try to use LuaJIT bit library for performance; fall back to arithmetic.
local has_bit, bit = pcall(require, "bit")
--: string
M._tier = has_bit and "ffi" or "pure"

local band, bor, bxor, bnot, lshift, rshift
if has_bit then
  band = bit.band
  bor = bit.bor
  bxor = bit.bxor
  bnot = bit.bnot
  lshift = bit.lshift
  rshift = bit.rshift
else
  -- Pure Lua fallback (32-bit unsigned arithmetic)
  band = function(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local a_bit = a % 2
      local b_bit = b % 2
      if a_bit == 1 and b_bit == 1 then r = r + p end
      a = floor(a / 2)
      b = floor(b / 2)
      p = p * 2
    end
    return r
  end
  bor = function(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local a_bit = a % 2
      local b_bit = b % 2
      if a_bit == 1 or b_bit == 1 then r = r + p end
      a = floor(a / 2)
      b = floor(b / 2)
      p = p * 2
    end
    return r
  end
  bxor = function(a, b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local a_bit = a % 2
      local b_bit = b % 2
      if a_bit ~= b_bit then r = r + p end
      a = floor(a / 2)
      b = floor(b / 2)
      p = p * 2
    end
    return r
  end
  bnot = function(a)
    return 4294967295 - (a % 4294967296)
  end
  lshift = function(a, n)
    return (a * (2 ^ n)) % 4294967296
  end
  rshift = function(a, n)
    return floor(a / (2 ^ n)) % 4294967296
  end
end

-- ── Popcount ────────────────────────────────────────────────────────────────

-- Hamming weight for a 32-bit integer.
local function popcount32(x)
  -- Ensure unsigned 32-bit
  if x < 0 then x = x + 4294967296 end
  x = x - band(rshift(x, 1), 0x55555555)
  x = band(x, 0x33333333) + band(rshift(x, 2), 0x33333333)
  x = band(x + rshift(x, 4), 0x0F0F0F0F)
  -- Multiply by 0x01010101 and shift right 24
  -- Use addition to avoid overflow issues on pure Lua
  x = x + lshift(x, 8)
  x = x + lshift(x, 16)
  return band(rshift(x, 24), 0x3F)
end

-- ── Bitset ──────────────────────────────────────────────────────────────────

local Bitset = {}
Bitset.__index = Bitset

local BITS_PER_WORD = 32

--- Create a new fixed-size bitset.
--: (n: number) -> Bitset
function M.bitset(n)
  if type(n) ~= "number" or n < 0 then
    return nil, "bitset: size must be a non-negative number"
  end
  n = floor(n)
  local nwords = ceil(n / BITS_PER_WORD)
  if nwords == 0 then nwords = 1 end
  local words = {}
  for i = 1, nwords do words[i] = 0 end
  local self = setmetatable({
    _words = words,
    _size = n,
    _nwords = nwords,
  }, Bitset)
  return self
end

--- Set bit at index i (0-based).
--: (i: number) -> nil
function Bitset:set(i)
  if i < 0 or i >= self._size then return end
  local word_idx = floor(i / BITS_PER_WORD) + 1
  local bit_idx = i % BITS_PER_WORD
  self._words[word_idx] = bor(self._words[word_idx], lshift(1, bit_idx))
end

--- Clear bit at index i (0-based).
--: (i: number) -> nil
function Bitset:clear(i)
  if i < 0 or i >= self._size then return end
  local word_idx = floor(i / BITS_PER_WORD) + 1
  local bit_idx = i % BITS_PER_WORD
  self._words[word_idx] = band(self._words[word_idx], bnot(lshift(1, bit_idx)))
end

--- Toggle bit at index i (0-based).
--: (i: number) -> nil
function Bitset:toggle(i)
  if i < 0 or i >= self._size then return end
  local word_idx = floor(i / BITS_PER_WORD) + 1
  local bit_idx = i % BITS_PER_WORD
  self._words[word_idx] = bxor(self._words[word_idx], lshift(1, bit_idx))
end

--- Get bit at index i (0-based). Returns boolean.
--: (i: number) -> boolean
function Bitset:get(i)
  if i < 0 or i >= self._size then return false end
  local word_idx = floor(i / BITS_PER_WORD) + 1
  local bit_idx = i % BITS_PER_WORD
  return band(self._words[word_idx], lshift(1, bit_idx)) ~= 0
end

--- Return the number of set bits (popcount).
--: () -> number
function Bitset:count()
  local c = 0
  for i = 1, self._nwords do
    c = c + popcount32(self._words[i])
  end
  return c
end

--- Return the total capacity.
--: () -> number
function Bitset:size()
  return self._size
end

--- Return true if any bit is set.
--: () -> boolean
function Bitset:any()
  for i = 1, self._nwords do
    if self._words[i] ~= 0 then return true end
  end
  return false
end

--- Return true if no bits are set.
--: () -> boolean
function Bitset:none()
  return not self:any()
end

--- Return true if all bits are set.
--: () -> boolean
function Bitset:all()
  -- Check all full words
  local full_words = floor(self._size / BITS_PER_WORD)
  for i = 1, full_words do
    -- A full word of all 1s is 0xFFFFFFFF = 4294967295 (or -1 with bit ops)
    local w = self._words[i]
    if w < 0 then w = w + 4294967296 end
    if w ~= 4294967295 then return false end
  end
  -- Check remaining bits in the last word
  local remaining = self._size % BITS_PER_WORD
  if remaining > 0 then
    local mask = lshift(1, remaining) - 1
    if mask < 0 then mask = mask + 4294967296 end
    local w = self._words[self._nwords]
    if w < 0 then w = w + 4294967296 end
    if band(w, mask) ~= mask then return false end
  end
  return true
end

-- Helper: create a bitset from raw words (same size).
local function bitset_from_words(words, nwords, size)
  local new_words = {}
  for i = 1, nwords do new_words[i] = words[i] end
  return setmetatable({
    _words = new_words,
    _size = size,
    _nwords = nwords,
  }, Bitset)
end

--- Bitwise AND with another bitset. Returns a new bitset.
--: (other: Bitset) -> Bitset | (nil, string)
function Bitset:and_(other)
  if self._size ~= other._size then
    return nil, "bitset:and_: size mismatch"
  end
  local words = {}
  for i = 1, self._nwords do
    words[i] = band(self._words[i], other._words[i])
  end
  return bitset_from_words(words, self._nwords, self._size)
end

--- Bitwise OR with another bitset. Returns a new bitset.
--: (other: Bitset) -> Bitset | (nil, string)
function Bitset:or_(other)
  if self._size ~= other._size then
    return nil, "bitset:or_: size mismatch"
  end
  local words = {}
  for i = 1, self._nwords do
    words[i] = bor(self._words[i], other._words[i])
  end
  return bitset_from_words(words, self._nwords, self._size)
end

--- Bitwise XOR with another bitset. Returns a new bitset.
--: (other: Bitset) -> Bitset | (nil, string)
function Bitset:xor_(other)
  if self._size ~= other._size then
    return nil, "bitset:xor_: size mismatch"
  end
  local words = {}
  for i = 1, self._nwords do
    words[i] = bxor(self._words[i], other._words[i])
  end
  return bitset_from_words(words, self._nwords, self._size)
end

--- Bitwise NOT. Returns a new bitset (only flips bits within size).
--: () -> Bitset
function Bitset:not_()
  local words = {}
  for i = 1, self._nwords do
    words[i] = bnot(self._words[i])
  end
  -- Mask the last word to stay within size
  local remaining = self._size % BITS_PER_WORD
  if remaining > 0 then
    local mask = lshift(1, remaining) - 1
    words[self._nwords] = band(words[self._nwords], mask)
  end
  return bitset_from_words(words, self._nwords, self._size)
end

--- Return an array of 0-based indices of all set bits.
--: () -> { [number]: number }
function Bitset:to_array()
  local result = {}
  local n = 0
  for i = 0, self._size - 1 do
    if self:get(i) then
      n = n + 1
      result[n] = i
    end
  end
  return result
end

--- Set bits from an array of 0-based indices. Returns self for chaining.
--: (indices: { [number]: number }) -> Bitset
function Bitset:from_array(indices)
  for _, i in ipairs(indices) do
    self:set(i)
  end
  return self
end

--- String representation: "10110100..." (bit 0 is leftmost).
function Bitset:__tostring()
  local chars = {}
  for i = 0, self._size - 1 do
    chars[i + 1] = self:get(i) and "1" or "0"
  end
  return table.concat(chars)
end

-- ── Bloom Filter ────────────────────────────────────────────────────────────

local Bloom = {}
Bloom.__index = Bloom

-- Murmur3-inspired hash mix for 32-bit. Better avalanche than FNV for double hashing.
local function hash_mix(h)
  h = bxor(h, rshift(h, 16))
  h = (h * 2246822507) % 4294967296
  h = bxor(h, rshift(h, 13))
  h = (h * 3266489909) % 4294967296
  h = bxor(h, rshift(h, 16))
  return h
end

-- Hash a string to two independent 32-bit values using FNV-1a + mixing.
local FNV_OFFSET = 2166136261
local FNV_PRIME = 16777619

local function hash_pair(data)
  local h1 = FNV_OFFSET
  local h2 = 2246822519  -- different seed
  for i = 1, #data do
    local b = data:byte(i)
    h1 = bxor(h1, b)
    h1 = (h1 * FNV_PRIME) % 4294967296
    h2 = bxor(h2, b)
    h2 = (h2 * 2654435769) % 4294967296  -- different prime
  end
  -- Final avalanche mix for better bit distribution
  h1 = hash_mix(h1)
  h2 = hash_mix(h2)
  -- Ensure h2 is odd so it's coprime with any even m
  h2 = bor(h2, 1)
  return h1, h2
end

--- Create a new Bloom filter.
--: (expected_items: number, fp_rate: number) -> Bloom | (nil, string)
function M.bloom(expected_items, fp_rate)
  if type(expected_items) ~= "number" or expected_items <= 0 then
    return nil, "bloom: expected_items must be a positive number"
  end
  if type(fp_rate) ~= "number" or fp_rate <= 0 or fp_rate >= 1 then
    return nil, "bloom: false_positive_rate must be between 0 and 1"
  end
  -- Optimal number of bits: m = -n * ln(p) / (ln(2))^2
  local ln2 = log(2)
  local m = ceil(-expected_items * log(fp_rate) / (ln2 * ln2))
  if m < 1 then m = 1 end
  -- Optimal number of hash functions: k = (m/n) * ln(2)
  local k = ceil((m / expected_items) * ln2)
  if k < 1 then k = 1 end

  local bs = M.bitset(m)
  if not bs then return nil, "bloom: failed to create internal bitset" end

  return setmetatable({
    _bits = bs,
    _m = m,
    _k = k,
    _n = expected_items,
    _count = 0,
  }, Bloom)
end

--- Add an item (string or number) to the filter.
--: (item: string | number) -> nil
function Bloom:add(item)
  local s = tostring(item)
  local h1, h2 = hash_pair(s)
  local m = self._m
  local already_present = true
  for i = 0, self._k - 1 do
    local idx = (h1 + i * h2) % m
    if not self._bits:get(idx) then
      already_present = false
    end
    self._bits:set(idx)
  end
  if not already_present then
    self._count = self._count + 1
  end
end

--- Test if an item might be in the filter. Returns boolean.
-- May return false positives but never false negatives.
--: (item: string | number) -> boolean
function Bloom:test(item)
  local s = tostring(item)
  local h1, h2 = hash_pair(s)
  local m = self._m
  for i = 0, self._k - 1 do
    local idx = (h1 + i * h2) % m
    if not self._bits:get(idx) then
      return false
    end
  end
  return true
end

--- Approximate count of items added.
--: () -> number
function Bloom:count()
  return self._count
end

--- Merge another Bloom filter into this one (union). Same parameters required.
--: (other: Bloom) -> true | (nil, string)
function Bloom:union(other)
  if self._m ~= other._m or self._k ~= other._k then
    return nil, "bloom:union: filters must have same parameters"
  end
  local merged = self._bits:or_(other._bits)
  if not merged then
    return nil, "bloom:union: bitset or_ failed"
  end
  self._bits = merged
  -- Estimate count from fill ratio: n_est = -(m/k) * ln(1 - X/m)
  local set_bits = self._bits:count()
  if set_bits >= self._m then
    self._count = self._n  -- saturated
  else
    self._count = floor(abs(-(self._m / self._k) * log(1 - set_bits / self._m)))
  end
  return true
end

--- Clear all bits and reset count.
--: () -> nil
function Bloom:clear()
  for i = 1, self._bits._nwords do
    self._bits._words[i] = 0
  end
  self._count = 0
end

--- Estimated false positive rate based on current fill ratio.
--: () -> number
function Bloom:false_positive_rate()
  local set_bits = self._bits:count()
  local fill = set_bits / self._m
  return (fill) ^ self._k
end

M.Bitset = Bitset
M.Bloom = Bloom

return M
