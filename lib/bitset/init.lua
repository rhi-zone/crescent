-- lib/bitset/init.lua — dense bitset (bit array) backed by 32-bit integer words.
-- Auto-growing: M.new(n) takes an optional capacity hint; the bitset expands as needed.
-- All bit positions are 1-indexed.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor, bxor, bnot_fn = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}
M._tier = "pure"

local WORD_BITS = 32

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function word_index(i)
  return math.ceil(i / WORD_BITS)
end

local function bit_pos(i)
  return (i - 1) % WORD_BITS
end

-- Kernighan popcount for one 32-bit word
local function popcount32(w)
  w = band(w, 0xFFFFFFFF)
  local count = 0
  while w ~= 0 do
    w = band(w, w - 1)
    count = count + 1
  end
  return count
end

-- Fast log2 of a power-of-2 value (bit index within word)
local function log2_pow2(lb)
  local bit_idx = 0
  local tmp = lb
  if band(tmp, 0xFFFF0000) ~= 0 then bit_idx = bit_idx + 16; tmp = rshift(tmp, 16) end
  if band(tmp, 0x0000FF00) ~= 0 then bit_idx = bit_idx + 8;  tmp = rshift(tmp, 8)  end
  if band(tmp, 0x000000F0) ~= 0 then bit_idx = bit_idx + 4;  tmp = rshift(tmp, 4)  end
  if band(tmp, 0x0000000C) ~= 0 then bit_idx = bit_idx + 2;  tmp = rshift(tmp, 2)  end
  if band(tmp, 0x00000002) ~= 0 then bit_idx = bit_idx + 1 end
  return bit_idx
end

-- Ensure self.words has at least `wi` entries.
local function ensure_capacity(self, wi)
  local words = self.words
  for i = #words + 1, wi do
    words[i] = 0
  end
end

-- ---------------------------------------------------------------------------
-- Bitset metatable
-- ---------------------------------------------------------------------------

local BS = {}
BS.__index = BS

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

--:: Bitset = { words: { [integer]: integer }, ... }

--- Create a new bitset. `n` is an optional capacity hint (bits); the bitset
--- grows automatically on demand regardless.
--: (number | nil) -> Bitset
function M.new(n)
  local nw = 0
  local words = {}
  if n and n > 0 then
    nw = word_index(math.ceil(n))
    for i = 1, nw do words[i] = 0 end
  end
  return setmetatable({ words = words }, BS)
end

--- Create a bitset from an array of set bit positions (1-indexed).
function M.from_bits(positions)
  local bs = M.new()
  for _, pos in ipairs(positions) do
    BS.set(bs, pos)
  end
  return bs
end

-- ---------------------------------------------------------------------------
-- Individual bit operations
-- ---------------------------------------------------------------------------

function BS:set(i)
  local w = word_index(i)
  ensure_capacity(self, w)
  self.words[w] = bor(self.words[w], lshift(1, bit_pos(i)))
end

function BS:clear(i)
  local w = word_index(i)
  if w > #self.words then return end  -- already zero
  self.words[w] = band(self.words[w], bnot_fn(lshift(1, bit_pos(i))))
end

function BS:flip(i)
  local w = word_index(i)
  ensure_capacity(self, w)
  self.words[w] = bxor(self.words[w], lshift(1, bit_pos(i)))
end

--- Returns true/false — is bit i set?
function BS:test(i)
  local w = word_index(i)
  if w > #self.words then return false end
  return band(self.words[w], lshift(1, bit_pos(i))) ~= 0
end

--- Returns 0 or 1.
function BS:get(i)
  local w = word_index(i)
  if w > #self.words then return 0 end
  return band(self.words[w], lshift(1, bit_pos(i))) ~= 0 and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Range operations
-- ---------------------------------------------------------------------------

--- Set all bits from lo to hi (inclusive).
function BS:set_range(lo, hi)
  for i = lo, hi do
    self:set(i)
  end
end

--- Clear all bits from lo to hi (inclusive).
function BS:clear_range(lo, hi)
  for i = lo, hi do
    self:clear(i)
  end
end

--- Flip all bits from lo to hi (inclusive).
function BS:flip_range(lo, hi)
  for i = lo, hi do
    self:flip(i)
  end
end

-- ---------------------------------------------------------------------------
-- Set operations (return new bitsets)
-- ---------------------------------------------------------------------------

local function max_words(a, b)
  return math.max(#a.words, #b.words) --[[:! integer]]
end

--- Bitwise AND — returns new bitset. Words beyond either bitset are 0 AND x = 0.
function BS:band(other)
  local nw = math.min(#self.words, #other.words)
  local result = M.new()
  for i = 1, nw do
    result.words[i] = band(self.words[i], other.words[i])
  end
  -- Words only in self or other: AND with 0 = 0, so no need to add them.
  return result
end

--- Bitwise OR — returns new bitset.
function BS:bor(other)
  local nw = max_words(self, other)
  local result = M.new()
  ensure_capacity(result, nw)
  local sw, ow = self.words, other.words
  for i = 1, nw do
    result.words[i] = bor(sw[i] or 0, ow[i] or 0)
  end
  return result
end

--- Bitwise XOR — returns new bitset.
function BS:bxor(other)
  local nw = max_words(self, other)
  local result = M.new()
  ensure_capacity(result, nw)
  local sw, ow = self.words, other.words
  for i = 1, nw do
    result.words[i] = bxor(sw[i] or 0, ow[i] or 0)
  end
  return result
end

--- Bitwise complement up to the highest set bit.
function BS:bnot()
  local mb = self:max_bit()
  if mb == 0 then return M.new() end
  local nw = word_index(mb)
  local result = M.new()
  ensure_capacity(result, nw)
  for i = 1, nw do
    result.words[i] = bnot_fn(self.words[i] or 0)
  end
  -- Mask last word to clear bits above max_bit
  local rem = mb % WORD_BITS
  if rem ~= 0 then
    local mask = lshift(1, rem) - 1
    result.words[nw] = band(result.words[nw], mask)
  end
  return result
end

--- self AND NOT other — returns new bitset.
function BS:andnot(other)
  local nw = #self.words
  local result = M.new()
  ensure_capacity(result, nw)
  local ow = other.words
  for i = 1, nw do
    result.words[i] = band(self.words[i], bnot_fn(ow[i] or 0))
  end
  return result
end

-- ---------------------------------------------------------------------------
-- In-place set operations
-- ---------------------------------------------------------------------------

function BS:band_inplace(other)
  local nw = #self.words
  local ow = other.words
  for i = 1, nw do
    self.words[i] = band(self.words[i], ow[i] or 0)
  end
  -- Truncate words beyond other's length (they AND to 0)
  if #other.words < nw then
    for i = #other.words + 1, nw do
      self.words[i] = 0
    end
  end
end

function BS:bor_inplace(other)
  local ow = other.words
  local onw = #ow
  ensure_capacity(self, onw)
  for i = 1, onw do
    self.words[i] = bor(self.words[i], ow[i])
  end
end

function BS:bxor_inplace(other)
  local ow = other.words
  local onw = #ow
  ensure_capacity(self, onw)
  for i = 1, onw do
    self.words[i] = bxor(self.words[i], ow[i])
  end
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Number of set bits (popcount).
function BS:count()
  local total = 0
  for i = 1, #self.words do
    total = total + popcount32(self.words[i])
  end
  return total
end

function BS:is_empty()
  for i = 1, #self.words do
    if self.words[i] ~= 0 then return false end
  end
  return true
end

function BS:any()
  return not self:is_empty()
end

--- Returns true if all bits 1..n are set.
function BS:all(n)
  if n <= 0 then return true end
  local nw = word_index(n)
  -- Check full words
  for i = 1, nw - 1 do
    if (self.words[i] or 0) ~= -1 then return false end  -- -1 = 0xFFFFFFFF signed
  end
  -- Check last word
  local rem = n % WORD_BITS
  local mask
  if rem == 0 then
    mask = -1  -- all 32 bits
  else
    mask = lshift(1, rem) - 1
  end
  return band(self.words[nw] or 0, mask) == band(mask, 0xFFFFFFFF)
end

--- First set bit >= i (1-indexed), or nil.
function BS:next_set(i)
  i = i or 1
  local words = self.words
  local nw = #words
  local first_word = word_index(i)
  for wi = first_word, nw do
    local w = words[wi]
    if w ~= 0 then
      local start_bit = (wi == first_word) and bit_pos(i) or 0
      -- Mask off bits below start_bit
      local masked = band(w, bnot_fn(lshift(1, start_bit) - 1))
      if masked ~= 0 then
        local lb = band(masked, -masked)
        local bi = log2_pow2(lb)
        return (wi - 1) * WORD_BITS + bi + 1
      end
    end
  end
  return nil
end

--- First clear bit >= i (1-indexed), or nil.
function BS:next_clear(i)
  i = i or 1
  local words = self.words
  local nw = #words
  local first_word = word_index(i)
  for wi = first_word, nw do
    local w = words[wi] or 0
    -- Inverted: find lowest 0 in w = lowest 1 in ~w
    local inv = bnot_fn(w)
    if inv ~= 0 then
      local start_bit = (wi == first_word) and bit_pos(i) or 0
      local masked = band(inv, bnot_fn(lshift(1, start_bit) - 1))
      if masked ~= 0 then
        local lb = band(masked, -masked)
        local bi = log2_pow2(lb)
        return (wi - 1) * WORD_BITS + bi + 1
      end
    end
  end
  -- All words are fully set; first clear bit is beyond allocated storage
  local beyond = nw * WORD_BITS + 1
  local candidate = math.max(i, beyond)
  return candidate
end

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------

function BS:eq(other)
  local nw = math.max(#self.words, #other.words)
  local sw, ow = self.words, other.words
  for i = 1, nw do
    if (sw[i] or 0) ~= (ow[i] or 0) then return false end
  end
  return true
end

--- Returns true if self is a subset of other (every bit in self is also in other).
function BS:subset(other)
  local sw = self.words
  local ow = other.words
  for i = 1, #sw do
    local s = sw[i]
    if s ~= 0 then
      local o = ow[i] or 0
      -- self has bits not in other
      if band(s, bnot_fn(o)) ~= 0 then return false end
    end
  end
  return true
end

--- Returns true if self and other share at least one set bit.
function BS:intersects(other)
  local sw, ow = self.words, other.words
  local nw = math.min(#sw, #ow)
  for i = 1, nw do
    if band(sw[i], ow[i]) ~= 0 then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

--- Sorted list of set bit positions (1-indexed).
function BS:to_array()
  local arr = {}
  local words = self.words
  for wi = 1, #words do
    local w = words[wi]
    while w ~= 0 do
      local lb = band(w, -w)
      w = band(w, w - 1)
      local bi = log2_pow2(lb)
      arr[#arr + 1] = (wi - 1) * WORD_BITS + bi + 1
    end
  end
  return arr
end

--- Binary string, bit 1 first (LSB of first word = leftmost char).
function BS:to_string()
  local mb = self:max_bit()
  if mb == 0 then return "" end
  local chars = {}
  local words = self.words
  for i = 1, mb do
    local wi = word_index(i)
    local bp = bit_pos(i)
    chars[i] = band(rshift(words[wi] or 0, bp), 1) == 1 and "1" or "0"
  end
  return table.concat(chars)
end

--- Highest set bit position (1-indexed), or 0 if empty.
function BS:max_bit()
  local words = self.words
  for wi = #words, 1, -1 do
    local w = words[wi]
    if w ~= 0 then
      -- find highest set bit in w
      local bit_idx = 0
      local tmp = band(w, 0xFFFFFFFF)
      if band(tmp, 0xFFFF0000) ~= 0 then bit_idx = 16; tmp = rshift(tmp, 16) end
      if band(tmp, 0x0000FF00) ~= 0 then bit_idx = bit_idx + 8; tmp = rshift(tmp, 8) end
      if band(tmp, 0x000000F0) ~= 0 then bit_idx = bit_idx + 4; tmp = rshift(tmp, 4) end
      if band(tmp, 0x0000000C) ~= 0 then bit_idx = bit_idx + 2; tmp = rshift(tmp, 2) end
      if band(tmp, 0x00000002) ~= 0 then bit_idx = bit_idx + 1 end
      return (wi - 1) * WORD_BITS + bit_idx + 1
    end
  end
  return 0
end

--- Current capacity in bits (number of allocated words * 32).
function BS:capacity()
  return #self.words * WORD_BITS
end

function BS:clone()
  local c = M.new()
  local words = self.words
  local cw = {}
  for i = 1, #words do cw[i] = words[i] end
  c.words = cw
  return c
end

return M
