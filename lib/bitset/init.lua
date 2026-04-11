-- lib/bitset/init.lua — dense fixed and dynamic bitset backed by 32-bit integer words
-- Uses LuaJIT bit library for all bitwise operations.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift
local tohex, tobit = bit.tohex, bit.tobit

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Number of 32-bit words needed to hold n bits
local function words_for(n)
  return math.ceil(n / 32)
end

-- Mask for the last word when n is not a multiple of 32.
-- Returns 0xFFFFFFFF when n is an exact multiple (all bits used).
local function last_word_mask(n)
  local rem = n % 32
  if rem == 0 then return 0xFFFFFFFF end
  -- bits 0..(rem-1) set  → (1 << rem) - 1
  -- but bit.lshift operates on signed 32-bit; use unsigned arithmetic:
  return lshift(1, rem) - 1
end

-- Kernighan popcount for one 32-bit word
local function popcount32(w)
  -- treat as unsigned
  w = band(w, 0xFFFFFFFF)
  local count = 0
  while w ~= 0 do
    w = band(w, w - 1)
    count = count + 1
  end
  return count
end

-- ---------------------------------------------------------------------------
-- Fixed bitset
-- ---------------------------------------------------------------------------

local BS = {}
BS.__index = BS

--- Create a new fixed-size bitset with `n` bits, all zero.
function M.new(n)
  if type(n) ~= "number" or n < 1 or math.floor(n) ~= n then
    return nil, "size must be a positive integer"
  end
  local nw = words_for(n)
  local words = {}
  for i = 1, nw do words[i] = 0 end
  return setmetatable({ _n = n, _nw = nw, _words = words }, BS)
end

-- Validate bit position for fixed bitset; returns word index and bit mask
local function check_pos(self, pos)
  if pos < 1 or pos > self._n then
    return nil, nil, "out of range"
  end
  local wi = math.ceil(pos / 32)
  local bi = (pos - 1) % 32
  return wi, lshift(1, bi), nil
end

--- Set bit at position `pos` (1-based). Returns nil, errmsg on out-of-range.
function BS:set(pos)
  local wi, mask, err = check_pos(self, pos)
  if err then return nil, err end
  self._words[wi] = bor(self._words[wi], mask)
  return true
end

--- Clear bit at position `pos`. Returns nil, errmsg on out-of-range.
function BS:clear(pos)
  local wi, mask, err = check_pos(self, pos)
  if err then return nil, err end
  self._words[wi] = band(self._words[wi], bnot(mask))
  return true
end

--- Toggle bit at position `pos`. Returns nil, errmsg on out-of-range.
function BS:flip(pos)
  local wi, mask, err = check_pos(self, pos)
  if err then return nil, err end
  self._words[wi] = bxor(self._words[wi], mask)
  return true
end

--- Get bit at position `pos`. Returns true/false, or nil, errmsg on out-of-range.
function BS:get(pos)
  local wi, mask, err = check_pos(self, pos)
  if err then return nil, err end
  return band(self._words[wi], mask) ~= 0
end

--- Return the number of set bits (popcount).
function BS:count()
  local total = 0
  for i = 1, self._nw do
    total = total + popcount32(self._words[i])
  end
  return total
end

--- Return the capacity (bit count) of this bitset.
function BS:size()
  return self._n
end

--- Return true if any bit is set.
function BS:any()
  for i = 1, self._nw do
    if self._words[i] ~= 0 then return true end
  end
  return false
end

--- Return true if no bit is set.
function BS:none()
  return not self:any()
end

--- Return true if all bits are set.
function BS:all()
  local nw = self._nw
  -- Check full words first
  for i = 1, nw - 1 do
    if self._words[i] ~= -1 then return false end  -- -1 = 0xFFFFFFFF in LuaJIT signed
  end
  -- Check last word with mask
  local mask = last_word_mask(self._n)
  return band(self._words[nw], mask) == band(mask, 0xFFFFFFFF)
end

-- Validate that two bitsets have the same size for set operations
local function check_same_size(a, b)
  if a._n ~= b._n then
    return "size mismatch: " .. a._n .. " vs " .. b._n
  end
end

--- Return a new bitset that is the bitwise AND of self and other.
function BS:band(other)
  local err = check_same_size(self, other)
  if err then return nil, err end
  local result = M.new(self._n)
  for i = 1, self._nw do
    result._words[i] = band(self._words[i], other._words[i])
  end
  return result
end

--- Return a new bitset that is the bitwise OR of self and other.
function BS:bor(other)
  local err = check_same_size(self, other)
  if err then return nil, err end
  local result = M.new(self._n)
  for i = 1, self._nw do
    result._words[i] = bor(self._words[i], other._words[i])
  end
  return result
end

--- Return a new bitset that is the bitwise XOR of self and other.
function BS:bxor(other)
  local err = check_same_size(self, other)
  if err then return nil, err end
  local result = M.new(self._n)
  for i = 1, self._nw do
    result._words[i] = bxor(self._words[i], other._words[i])
  end
  return result
end

--- Return a new bitset with all bits flipped (within size).
function BS:bnot()
  local result = M.new(self._n)
  for i = 1, self._nw do
    result._words[i] = bnot(self._words[i])
  end
  -- Mask the last word to clear bits beyond _n
  local mask = last_word_mask(self._n)
  result._words[self._nw] = band(result._words[self._nw], mask)
  return result
end

--- Return a new bitset containing bits in self but not in other (self AND NOT other).
function BS:difference(other)
  local err = check_same_size(self, other)
  if err then return nil, err end
  local result = M.new(self._n)
  for i = 1, self._nw do
    result._words[i] = band(self._words[i], bnot(other._words[i]))
  end
  return result
end

--- Iterator over set bit positions in ascending order.
function BS:iter()
  local words = self._words
  local nw = self._nw
  local n = self._n
  local wi = 1
  local w = words[1]
  local base = 0  -- bit position base for current word: (wi-1)*32

  return function()
    while true do
      if w ~= 0 then
        -- Find lowest set bit in w
        -- isolate lowest set bit
        local lb = band(w, -w)  -- lowest set bit (two's complement trick)
        -- clear it in w
        w = band(w, w - 1)
        -- compute bit position from lb
        -- lb is a power of 2; find its log2
        -- use rshift: keep shifting right until 0, counting shifts
        local bit_idx = 0
        local tmp = lb
        -- fast log2 via successive shifts
        if band(tmp, 0xFFFF0000) ~= 0 then bit_idx = bit_idx + 16; tmp = rshift(tmp, 16) end
        if band(tmp, 0x0000FF00) ~= 0 then bit_idx = bit_idx + 8;  tmp = rshift(tmp, 8)  end
        if band(tmp, 0x000000F0) ~= 0 then bit_idx = bit_idx + 4;  tmp = rshift(tmp, 4)  end
        if band(tmp, 0x0000000C) ~= 0 then bit_idx = bit_idx + 2;  tmp = rshift(tmp, 2)  end
        if band(tmp, 0x00000002) ~= 0 then bit_idx = bit_idx + 1             end
        local pos = base + bit_idx + 1  -- 1-based
        if pos <= n then return pos end
      else
        wi = wi + 1
        if wi > nw then return nil end
        w = words[wi]
        base = (wi - 1) * 32
      end
    end
  end
end

--- Return an array of set bit positions in ascending order.
function BS:to_array()
  local arr = {}
  for pos in self:iter() do
    arr[#arr + 1] = pos
  end
  return arr
end

--- Return a binary string of length n, left=bit1, right=bitn. '1' means set.
function BS:to_string()
  local chars = {}
  for i = 1, self._n do
    local wi = math.ceil(i / 32)
    local bi = (i - 1) % 32
    chars[i] = band(rshift(self._words[wi], bi), 1) == 1 and "1" or "0"
  end
  return table.concat(chars)
end

--- Serialize as a hex string (each 32-bit word in hex, big-endian word order).
-- Words are printed as 8-digit hex; last partial word is still 8 digits.
function BS:to_hex()
  local parts = {}
  for i = 1, self._nw do
    parts[i] = tohex(self._words[i])
  end
  return table.concat(parts)
end

--- Restore a bitset from a hex string produced by to_hex(). n = bit count.
function M.from_hex(s, n)
  local nw = words_for(n)
  if #s ~= nw * 8 then
    return nil, "hex string length mismatch: expected " .. nw * 8 .. ", got " .. #s
  end
  local bs = M.new(n)
  for i = 1, nw do
    local chunk = s:sub((i - 1) * 8 + 1, i * 8)
    local v = tonumber(chunk, 16)
    if not v then return nil, "invalid hex at word " .. i end
    -- bit.tobit converts the unsigned value to signed 32-bit as LuaJIT bit ops expect
    bs._words[i] = tobit(v)
  end
  return bs
end

-- ---------------------------------------------------------------------------
-- Dynamic bitset (auto-grows)
-- ---------------------------------------------------------------------------

local DBS = {}
DBS.__index = DBS

--- Create a new dynamic bitset (grows on demand).
function M.dynamic_new()
  return setmetatable({ _words = {}, _nw = 0, _max_bit = 0 }, DBS)
end

local function dbs_ensure(self, pos)
  local wi = math.ceil(pos / 32)
  if wi > self._nw then
    for i = self._nw + 1, wi do self._words[i] = 0 end
    self._nw = wi
  end
  if pos > self._max_bit then self._max_bit = pos end
end

function DBS:set(pos)
  if type(pos) ~= "number" or pos < 1 or math.floor(pos) ~= pos then
    return nil, "position must be a positive integer"
  end
  dbs_ensure(self, pos)
  local wi = math.ceil(pos / 32)
  local bi = (pos - 1) % 32
  self._words[wi] = bor(self._words[wi], lshift(1, bi))
  return true
end

function DBS:clear(pos)
  if type(pos) ~= "number" or pos < 1 or math.floor(pos) ~= pos then
    return nil, "position must be a positive integer"
  end
  local wi = math.ceil(pos / 32)
  if wi > self._nw then return true end  -- already zero
  local bi = (pos - 1) % 32
  self._words[wi] = band(self._words[wi], bnot(lshift(1, bi)))
  return true
end

function DBS:flip(pos)
  if type(pos) ~= "number" or pos < 1 or math.floor(pos) ~= pos then
    return nil, "position must be a positive integer"
  end
  dbs_ensure(self, pos)
  local wi = math.ceil(pos / 32)
  local bi = (pos - 1) % 32
  self._words[wi] = bxor(self._words[wi], lshift(1, bi))
  return true
end

function DBS:get(pos)
  if type(pos) ~= "number" or pos < 1 or math.floor(pos) ~= pos then
    return nil, "position must be a positive integer"
  end
  local wi = math.ceil(pos / 32)
  if wi > self._nw then return false end
  local bi = (pos - 1) % 32
  return band(self._words[wi], lshift(1, bi)) ~= 0
end

function DBS:count()
  local total = 0
  for i = 1, self._nw do
    total = total + popcount32(self._words[i])
  end
  return total
end

function DBS:any()
  for i = 1, self._nw do
    if self._words[i] ~= 0 then return true end
  end
  return false
end

function DBS:none()
  return not self:any()
end

function DBS:size()
  return self._max_bit
end

function DBS:iter()
  local words = self._words
  local nw = self._nw
  local wi = 1
  local w = nw >= 1 and words[1] or 0
  local base = 0

  return function()
    while true do
      if w ~= 0 then
        local lb = band(w, -w)
        w = band(w, w - 1)
        local bit_idx = 0
        local tmp = lb
        if band(tmp, 0xFFFF0000) ~= 0 then bit_idx = bit_idx + 16; tmp = rshift(tmp, 16) end
        if band(tmp, 0x0000FF00) ~= 0 then bit_idx = bit_idx + 8;  tmp = rshift(tmp, 8)  end
        if band(tmp, 0x000000F0) ~= 0 then bit_idx = bit_idx + 4;  tmp = rshift(tmp, 4)  end
        if band(tmp, 0x0000000C) ~= 0 then bit_idx = bit_idx + 2;  tmp = rshift(tmp, 2)  end
        if band(tmp, 0x00000002) ~= 0 then bit_idx = bit_idx + 1             end
        return base + bit_idx + 1
      else
        wi = wi + 1
        if wi > nw then return nil end
        w = words[wi]
        base = (wi - 1) * 32
      end
    end
  end
end

function DBS:to_array()
  local arr = {}
  for pos in self:iter() do arr[#arr + 1] = pos end
  return arr
end

return M
