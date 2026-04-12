if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band = bit.band
local bor = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

local M = {}
M._tier = "pure"

-- FNV-1a 32-bit hash
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = band(bit.bxor(h, s:byte(i)) * 16777619, 0xffffffff)
  end
  return h
end

-- Produce two independent base hashes from a string key
local function two_hashes(key)
  local h1 = fnv1a(key)
  -- Mix for second hash using a different seed
  local h2 = fnv1a(key .. "\x00")
  return h1, h2
end

-- Number of uint32 words needed to hold `size` bits
local function words_for(size)
  return math.floor((size + 31) / 32)
end

-- Set bit `idx` (0-based) in the filter array
local function set_bit(filter, idx)
  local word = math.floor(idx / 32) + 1
  local bit_pos = idx % 32
  filter[word] = bor(filter[word], lshift(1, bit_pos))
end

-- Test bit `idx` (0-based) in the filter array
local function test_bit(filter, idx)
  local word = math.floor(idx / 32) + 1
  local bit_pos = idx % 32
  return band(filter[word], lshift(1, bit_pos)) ~= 0
end

-- Add key to bloom filter using double-hashing
local function bloom_add(filter, size, hash_count, key)
  local h1, h2 = two_hashes(key)
  for i = 0, hash_count - 1 do
    -- double hashing: (h1 + i*h2) mod size
    -- Use unsigned arithmetic via band to stay positive
    local idx = band(h1 + i * h2, 0x7fffffff) % size
    set_bit(filter, idx)
  end
end

-- Check if all k bits for key are set in filter
local function bloom_contains(filter, size, hash_count, key)
  local h1, h2 = two_hashes(key)
  for i = 0, hash_count - 1 do
    local idx = band(h1 + i * h2, 0x7fffffff) % size
    if not test_bit(filter, idx) then
      return false
    end
  end
  return true
end

-- Allocate a zeroed filter (array of words)
local function new_filter(size)
  local n = words_for(size)
  local f = {}
  for i = 1, n do
    f[i] = 0
  end
  return f
end

-- OR two filters together (union), storing into dst
local function filter_or(dst, src, size)
  local n = words_for(size)
  for i = 1, n do
    dst[i] = bor(dst[i], src[i])
  end
end

-- Check if filter `a` is a subset of filter `b` (every 1-bit in a is also in b)
local function filter_subset(a, b, size)
  local n = words_for(size)
  for i = 1, n do
    -- if a has bits that b doesn't, not a subset
    if band(a[i], b[i]) ~= a[i] then
      return false
    end
  end
  return true
end

-- Clone a filter
local function filter_clone(f, size)
  local n = words_for(size)
  local c = {}
  for i = 1, n do
    c[i] = f[i]
  end
  return c
end

local Clock = {}
Clock.__index = Clock

function Clock:tick()
  self._time = self._time + 1
  local key = self._node_id .. ":" .. tostring(self._time)
  bloom_add(self._filter, self._size, self._hash_count, key)
end

function Clock:time()
  return self._time
end

function Clock:merge(other)
  filter_or(self._filter, other._filter, self._size)
  if other._time > self._time then
    self._time = other._time
  end
end

function Clock:serialize()
  local filter_copy = {}
  for i = 1, #self._filter do
    filter_copy[i] = self._filter[i]
  end
  return {
    node_id = self._node_id,
    time = self._time,
    size = self._size,
    hash_count = self._hash_count,
    filter = filter_copy,
  }
end

function Clock:clone()
  local c = {}
  c._node_id = self._node_id
  c._time = self._time
  c._size = self._size
  c._hash_count = self._hash_count
  c._filter = filter_clone(self._filter, self._size)
  return setmetatable(c, Clock)
end

function Clock:to_string()
  return "BloomClock(" .. self._node_id .. ", t=" .. tostring(self._time) .. ")"
end

Clock.__tostring = Clock.to_string

-- Create a new Bloom Clock
-- node_id: string identifier for this node
-- opts: {size=64, hash_count=3}
function M.new(node_id, opts)
  if type(node_id) ~= "string" then
    return nil, "node_id must be a string"
  end
  opts = opts or {}
  local size = opts.size or 64
  local hash_count = opts.hash_count or 3
  if size < 1 then
    return nil, "size must be >= 1"
  end
  if hash_count < 1 then
    return nil, "hash_count must be >= 1"
  end
  local clock = {
    _node_id = node_id,
    _time = 0,
    _size = size,
    _hash_count = hash_count,
    _filter = new_filter(size),
  }
  return setmetatable(clock, Clock)
end

-- happened_before(a, b): returns true if a causally precedes b
-- Condition: a's filter is a subset of b's filter AND a.time < b.time
function M.happened_before(a, b)
  if a._size ~= b._size then
    return false
  end
  return a._time < b._time and filter_subset(a._filter, b._filter, a._size)
end

-- concurrent(a, b): neither happened before the other
function M.concurrent(a, b)
  return not M.happened_before(a, b) and not M.happened_before(b, a)
end

-- Deserialize from a table produced by clock:serialize()
function M.deserialize(t)
  if type(t) ~= "table" then
    return nil, "expected table"
  end
  if type(t.node_id) ~= "string" then
    return nil, "node_id must be a string"
  end
  if type(t.time) ~= "number" then
    return nil, "time must be a number"
  end
  if type(t.size) ~= "number" then
    return nil, "size must be a number"
  end
  if type(t.hash_count) ~= "number" then
    return nil, "hash_count must be a number"
  end
  if type(t.filter) ~= "table" then
    return nil, "filter must be a table"
  end
  local filter_copy = {}
  local n = words_for(t.size)
  for i = 1, n do
    filter_copy[i] = t.filter[i] or 0
  end
  local clock = {
    _node_id = t.node_id,
    _time = t.time,
    _size = t.size,
    _hash_count = t.hash_count,
    _filter = filter_copy,
  }
  return setmetatable(clock, Clock)
end

return M
