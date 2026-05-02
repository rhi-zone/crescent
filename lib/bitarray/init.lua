-- lib/bitarray/init.lua — compact packed bit storage with multi-bit field support.
-- Bits are 0-indexed. Storage is in 32-bit words (LuaJIT `bit` library).
-- Use for packed boolean arrays, bitfields, and arbitrary-width integer packing.
-- Distinct from lib/bitset/ which is a set-membership structure (1-indexed, auto-growing).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local M = {}
M._tier = "pure"

local WORD_BITS = 32

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Word index (1-based) for 0-indexed bit position i.
local function wi(i)
  return math.floor(i / WORD_BITS) + 1
end

-- Bit position within word (0-31) for 0-indexed bit i.
local function bp(i)
  return i % WORD_BITS
end

-- Number of words needed to hold n bits.
local function words_for(n)
  return math.floor((n + WORD_BITS - 1) / WORD_BITS)
end

-- Parallel popcount for one 32-bit word (Hamming weight).
local function popcount32(w)
  w = band(w, 0xFFFFFFFF)
  -- Use Kernighan's method — good enough for 32-bit words in Lua.
  local c = 0
  while w ~= 0 do
    w = band(w, w - 1)
    c = c + 1
  end
  return c
end

-- Index of lowest set bit in word w (w must be nonzero). Returns 0-31.
local function lowest_bit(w)
  local lb = band(w, -w)
  local b = 0
  if band(lb, 0xFFFF0000) ~= 0 then b = b + 16; lb = rshift(lb, 16) end
  if band(lb, 0x0000FF00) ~= 0 then b = b + 8;  lb = rshift(lb, 8)  end
  if band(lb, 0x000000F0) ~= 0 then b = b + 4;  lb = rshift(lb, 4)  end
  if band(lb, 0x0000000C) ~= 0 then b = b + 2;  lb = rshift(lb, 2)  end
  if band(lb, 0x00000002) ~= 0 then b = b + 1 end
  return b
end

-- Mask of the low `n` bits (n in 1..32).
local function low_mask(n)
  if n == 32 then return -1 end  -- 0xFFFFFFFF as signed i32
  return lshift(1, n) - 1
end

-- ---------------------------------------------------------------------------
-- Bitarray metatable
-- ---------------------------------------------------------------------------

--:: BAType = { n: integer, words: { [integer]: integer }, get: (BAType, integer) -> integer, set: (BAType, integer, integer) -> nil, ... }

local BA = {}
BA.__index = BA

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

--- Create a new bitarray of exactly `n` bits, all zero. `n` must be >= 0.
--: (integer|nil) -> BAType
function M.new(n)
  n = n or 0
  local nw = words_for(n)
  local words = {} --: { [integer]: integer }
  for i = 1, nw do words[i] = 0 end
  local ret = setmetatable({ words = words, n = n }, BA) --[[: any]]
  return ret --[[:! BAType]]
end

-- ---------------------------------------------------------------------------
-- Core single-bit operations
-- ---------------------------------------------------------------------------

--- Return the value of bit i (0-indexed). Returns 0 or 1.
function BA:get(i)
  return band(rshift(self.words[wi(i)], bp(i)), 1)
end

--- Set bit i (0-indexed) to v (0 or 1).
function BA:set(i, v)
  local w = wi(i)
  local b = bp(i)
  if v == 0 then
    self.words[w] = band(self.words[w], bnot(lshift(1, b)))
  else
    self.words[w] = bor(self.words[w], lshift(1, b))
  end
end

--- Toggle bit i (0-indexed).
function BA:flip(i)
  local w = wi(i)
  self.words[w] = bxor(self.words[w], lshift(1, bp(i)))
end

--- Return the number of bits in the array.
function BA:len()
  return self.n
end

-- ---------------------------------------------------------------------------
-- Bulk operations
-- ---------------------------------------------------------------------------

--- Set all bits to v (0 or 1).
function BA:fill(v)
  local ba = self --[[:! BAType]]
  local words = ba.words
  local nw = #words
  if v == 0 then
    for i = 1, nw do words[i] = 0 end
  else
    for i = 1, nw do words[i] = -1 end
    -- Mask the last word to avoid spurious bits beyond ba.n.
    local tail = ba.n % WORD_BITS
    if tail ~= 0 then
      words[nw] = low_mask(tail)
    end
  end
end

--- Count set bits (popcount).
function BA:popcount()
  local total = 0
  local words = self.words
  for i = 1, #words do
    total = total + popcount32(words[i])
  end
  return total
end

--- Return the 0-indexed position of the first set bit, or nil.
function BA:first_set()
  local words = self.words
  for i = 1, #words do
    local w = words[i]
    if w ~= 0 then
      return (i - 1) * WORD_BITS + lowest_bit(w)
    end
  end
  return nil
end

--- Return the 0-indexed position of the first clear bit, or nil if all bits are set.
function BA:first_clear()
  local words = self.words
  local n = self.n
  for i = 1, #words do
    local w = words[i]
    -- Invert: find lowest 1 in ~w.
    local inv = bnot(w)
    if inv ~= 0 then
      local pos = (i - 1) * WORD_BITS + lowest_bit(inv)
      if pos < n then return pos end
      return nil
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Iteration
-- ---------------------------------------------------------------------------

--- Iterator over set bits. Yields (index, 1) for each set bit in order.
function BA:each()
  local words = self.words
  local nw = #words
  local wi_cur = 1
  local w = words[1] or 0
  local n = self.n
  return function()
    while true do
      if w ~= 0 then
        local b = lowest_bit(w)
        w = band(w, w - 1)  -- clear lowest bit
        local pos = (wi_cur - 1) * WORD_BITS + b
        if pos < n then
          return pos, 1
        end
        w = 0  -- skip remaining bits in this word (all out of range)
      else
        wi_cur = wi_cur + 1
        if wi_cur > nw then return nil end
        w = words[wi_cur]
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Set operations (return new bitarrays of same length as `a`)
-- ---------------------------------------------------------------------------

local function check_same_len(a, b, op)
  if a.n ~= b.n then
    error("bitarray." .. op .. ": length mismatch (" .. a.n .. " vs " .. b.n .. ")", 2)
  end
end

--: (BAType, BAType) -> BAType
function M.and_(a, b)
  check_same_len(a, b, "and_")
  local c = M.new(a.n) --[[:! BAType]]
  local aw, bw, cw = a.words, b.words, c.words
  for i = 1, #aw do cw[i] = band(aw[i], bw[i]) end
  return c
end

--: (BAType, BAType) -> BAType
function M.or_(a, b)
  check_same_len(a, b, "or_")
  local c = M.new(a.n) --[[:! BAType]]
  local aw, bw, cw = a.words, b.words, c.words
  for i = 1, #aw do cw[i] = bor(aw[i], bw[i]) end
  return c
end

--: (BAType, BAType) -> BAType
function M.xor_(a, b)
  check_same_len(a, b, "xor_")
  local c = M.new(a.n) --[[:! BAType]]
  local aw, bw, cw = a.words, b.words, c.words
  for i = 1, #aw do cw[i] = bxor(aw[i], bw[i]) end
  return c
end

--: (BAType) -> BAType
function M.not_(a)
  local c = M.new(a.n) --[[:! BAType]]
  local aw, cw = a.words, c.words
  local nw = #aw
  for i = 1, nw do cw[i] = bnot(aw[i]) end
  -- Mask tail word so bits beyond a.n are always 0.
  local tail = a.n % WORD_BITS
  if tail ~= 0 then
    cw[nw] = band(cw[nw], low_mask(tail))
  end
  return c
end

-- Convenience: module-level popcount and first_set/first_clear delegating to methods.
function M.popcount(a) return a:popcount() end
function M.first_set(a) return a:first_set() end
function M.first_clear(a) return a:first_clear() end

-- ---------------------------------------------------------------------------
-- Conversion
-- ---------------------------------------------------------------------------

--- Convert to "010011..." string (bit 0 is leftmost character).
function BA:to_string()
  local n = self.n
  local words = self.words
  local t = {}
  for i = 0, n - 1 do
    local w = wi(i)
    t[i + 1] = band(rshift(words[w], bp(i)), 1) == 1 and "1" or "0"
  end
  return table.concat(t)
end

--- Build a bitarray from a "010011..." string.
function M.from_string(s)
  local n = #s
  local ba = M.new(n)
  for i = 1, n do
    if s:sub(i, i) == "1" then
      ba:set(i - 1, 1)
    end
  end
  return ba
end

--- Convert to lowercase hex string, LSB of first word first, zero-padded to full words.
function BA:to_hex()
  local words = self.words
  local t = {}
  local TWO32 = 2^32
  for i = 1, #words do
    -- band gives a signed i32; use modulo to get the unsigned representation.
    t[i] = string.format("%08x", words[i] % TWO32)
  end
  return table.concat(t)
end

--- Build a bitarray from a hex string produced by to_hex().
--- The length (number of meaningful bits) must be supplied separately.
function M.from_hex(s, n)
  -- Each 8-char chunk is one 32-bit word.
  local nw = math.floor(#s / 8)
  local ba = M.new(n or nw * WORD_BITS)
  for i = 1, nw do
    local chunk = s:sub((i - 1) * 8 + 1, i * 8)
    ba.words[i] = tonumber(chunk, 16) or 0
  end
  return ba
end

-- ---------------------------------------------------------------------------
-- Slicing and concatenation
-- ---------------------------------------------------------------------------

--- Return a new bitarray containing bits [from, to) (0-indexed, exclusive end).
--: (self: BAType, integer, integer) -> BAType
function BA:slice(from, to)
  local len = to - from
  local c = M.new(len)
  for i = 0, len - 1 do
    c:set(i, self:get(from + i))
  end
  return c
end

--- Concatenate two bitarrays, returning a new one.
--: (BAType, BAType) -> BAType
function M.concat(a, b)
  local na, nb = a.n, b.n
  local c = M.new(na + nb) --[[:! BAType]]
  -- Copy a's words directly for the aligned portion.
  local aw = a.words
  for i = 1, #aw do c.words[i] = aw[i] end
  -- Append b bit by bit (handles arbitrary alignment).
  for i = 0, nb - 1 do
    c:set(na + i, b:get(i))
  end
  return c
end

-- ---------------------------------------------------------------------------
-- Fields object — arbitrary-width field access into a bitarray
-- ---------------------------------------------------------------------------

local FL = {}
FL.__index = FL

--- Create a fields object backed by `n_bits` of storage (all zero).
function M.fields(n_bits)
  return setmetatable({ _ba = M.new(n_bits) }, FL)
end

--- Write a `width`-bit unsigned integer `value` at bit `offset` (0-indexed).
--- Writes only the low `width` bits of `value`.
--: (self: { _ba: BAType }, integer, integer, integer) -> nil
function FL:write(offset, width, value)
  local fls = self --[[:! { _ba: BAType }]]
  local ba = fls._ba
  for i = 0, width - 1 do
    ba:set(offset + i, band(rshift(value, i), 1))
  end
end

--- Read a `width`-bit unsigned integer from bit `offset` (0-indexed).
--: (self: { _ba: BAType }, integer, integer) -> integer
function FL:read(offset, width)
  local fls = self --[[:! { _ba: BAType }]]
  local ba = fls._ba
  local v = 0
  for i = 0, width - 1 do
    v = bor(v, lshift(ba:get(offset + i), i))
  end
  -- band to ensure unsigned interpretation in LuaJIT (avoids negative results for 32-bit values)
  return band(v, low_mask(math.min(width, 32) --[[:! integer]]))
end

-- ---------------------------------------------------------------------------
-- Pack / unpack arrays of N-bit integers
-- ---------------------------------------------------------------------------

--- Pack a Lua array of integers into a bitarray, `width` bits per element.
--: ({ [integer]: integer }, integer) -> BAType
function M.pack_array(arr, width)
  local n = #arr
  local ba = M.new(n * width) --[[:! BAType]]
  for idx = 1, n do
    local v = arr[idx]
    local offset = (idx - 1) * width
    for b = 0, width - 1 do
      ba:set(offset + b, band(rshift(v, b), 1))
    end
  end
  return ba
end

--- Unpack `count` integers of `width` bits each from a bitarray.
--: (BAType, integer, integer) -> { [integer]: integer }
function M.unpack_array(ba, width, count)
  local arr = {}
  local mask = low_mask(math.min(width, 32) --[[:! integer]])
  for idx = 1, count do
    local offset = (idx - 1) * width
    local v = 0
    for b = 0, width - 1 do
      v = bor(v, lshift(ba:get(offset + b), b))
    end
    arr[idx] = band(v, mask)
  end
  return arr
end

return M
