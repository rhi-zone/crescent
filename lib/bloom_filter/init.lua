if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift

local M = {}
M._tier = "pure"

-- FNV-1a hash (32-bit)
local function fnv1a(s)
  local h = math.floor(2166136261) --[[:! integer]]
  for i = 1, #s do
    h = bxor(h, s:byte(i))
    -- FNV prime = 16777619; multiply via shifts to avoid overflow issues
    -- h * 16777619 = h * (2^24 + 2^8 + 2^7 + 2^4 + 2^1 + 2^0)
    h = band(h * 16777619, 0xFFFFFFFF)
  end
  return h
end

-- djb2 hash (32-bit)
local function djb2(s)
  local h = 5381
  for i = 1, #s do
    -- h = h * 33 + c
    h = band(h * 33 + s:byte(i), 0xFFFFFFFF)
  end
  return h
end

-- Double hashing: h_i(x) = (h1(x) + i * h2(x)) mod m
-- i is 0-based
--: (h1: integer, h2: integer, i: integer, m: integer) -> integer
local function hash_i(h1, h2, i, m)
  -- ensure positive result with modulo
  return (h1 + i * h2) % m
end

-- Bit array operations (1-indexed bit positions, 0-indexed internally)
--: (m: integer) -> { [integer]: integer }
local function bitarray_new(m)
  local words = math.ceil(m / 32)
  local arr = {}
  for i = 1, words do arr[i] = 0 end
  return arr
end

local function bitarray_set(arr, pos)
  local word = math.floor(pos / 32) + 1
  local bit_pos = pos % 32
  arr[word] = bor(arr[word], lshift(1, bit_pos))
end

local function bitarray_get(arr, pos)
  local word = math.floor(pos / 32) + 1
  local bit_pos = pos % 32
  return band(rshift(arr[word], bit_pos), 1) == 1
end

local function bitarray_clear(arr)
  for i = 1, #arr do arr[i] = 0 end
end

-- Compute optimal m (bit count) from capacity and error_rate
-- m = -n * ln(p) / (ln(2)^2)
--: (n: number, p: number) -> integer
local function optimal_m(n, p)
  return math.ceil(-n * math.log(p) / (math.log(2) * math.log(2)))
end

-- Compute optimal k (hash count) from m and n
-- k = (m/n) * ln(2)
--: (m: number, n: number) -> integer
local function optimal_k(m, n)
  return math.max(1, math.floor((m / n) * math.log(2) + 0.5)) --[[:! integer]]
end

-- Validate opts, return (m, k, err)
--: (opts: { capacity: unknown, error_rate: unknown, ... } | nil) -> (integer | nil, integer | nil, string | nil)
local function parse_opts(opts)
  local capacity = opts and opts.capacity
  local error_rate = opts and opts.error_rate
  if not capacity or type(capacity) ~= "number" or (capacity --[[:! number]]) < 1 then
    return nil, nil, "opts.capacity must be a positive number"
  end
  if not error_rate or type(error_rate) ~= "number" or (error_rate --[[:! number]]) <= 0 or (error_rate --[[:! number]]) >= 1 then
    return nil, nil, "opts.error_rate must be a number in (0, 1)"
  end
  local m = optimal_m(capacity --[[:! number]], error_rate --[[:! number]])
  local k = optimal_k(m, capacity --[[:! number]])
  return m, k, nil
end

--:: BloomFilter = { _bits: { [integer]: integer }, _k: integer, _m: integer, _count_approx: number, _capacity: number | nil, _error_rate: number | nil, ... }

-- Standard Bloom filter
local bloom_mt = {}
bloom_mt.__index = bloom_mt

function bloom_mt:add(item)
  local self_ = self --[[:! BloomFilter]]
  local h1 = fnv1a(item)
  local h2 = djb2(item)
  for i = 0, self_._k - 1 do
    bitarray_set(self_._bits, hash_i(h1, h2, i, self_._m))
  end
  self_._count_approx = self_._count_approx + 1
end

function bloom_mt:contains(item)
  local self_ = self --[[:! BloomFilter]]
  local h1 = fnv1a(item)
  local h2 = djb2(item)
  for i = 0, self_._k - 1 do
    if not bitarray_get(self_._bits, hash_i(h1, h2, i, self_._m)) then
      return false
    end
  end
  return true
end

-- Estimated current FPR based on number of inserted elements
-- fpr = (1 - e^(-k*n/m))^k
function bloom_mt:false_positive_rate()
  local self_ = self --[[:! BloomFilter]]
  local n = self_._count_approx
  local k = self_._k
  local m = self_._m
  return math.pow(1 - math.exp(-k * n / m), k)
end

-- Estimated element count via formula: n = -m/k * ln(1 - X/m)
-- where X = number of set bits
function bloom_mt:count()
  local self_ = self --[[:! BloomFilter]]
  local set_bits = 0 --: integer
  local words = math.ceil(self_._m / 32)
  for w = 1, words do
    local v = self_._bits[w]
    -- popcount via Brian Kernighan
    while v ~= 0 do
      v = band(v, v - 1)
      set_bits = set_bits + 1
    end
  end
  if set_bits == 0 then return 0 end
  if set_bits >= self_._m then return math.huge end
  return -self_._m / self_._k * math.log(1 - set_bits / self_._m)
end

function bloom_mt:clear()
  local self_ = self --[[:! BloomFilter]]
  bitarray_clear(self_._bits)
  self_._count_approx = 0
end

-- M.new(opts) -> filter or (nil, errmsg)
function M.new(opts)
  local m, k, err = parse_opts(opts)
  if err then return nil, err end
  local m_ = m --[[:! integer]]
  local k_ = k --[[:! integer]]
  return setmetatable({
    _bits = bitarray_new(m_),
    _k = k_,
    _m = m_,
    _count_approx = 0,
  }, bloom_mt)
end

--:: CountingFilter = { _counters: { [integer]: integer }, _k: integer, _m: integer, ... }

-- Counting Bloom filter (4-bit counters, supports removal)
-- Stored as a table of integers, 8 counters per 32-bit word (4 bits each)
local counting_mt = {}
counting_mt.__index = counting_mt

--: (m: integer) -> { [integer]: integer }
local function counter_new(m)
  local words = math.ceil(m / 8)
  local arr = {}
  for i = 1, words do arr[i] = 0 end
  return arr
end

local function counter_get(arr, pos)
  local word = math.floor(pos / 8) + 1
  local shift = (pos % 8) * 4
  return band(rshift(arr[word], shift), 0xF)
end

local function counter_inc(arr, pos)
  local word = math.floor(pos / 8) + 1
  local shift = (pos % 8) * 4
  local val = band(rshift(arr[word], shift), 0xF)
  if val < 15 then
    -- clear the nibble and set new value
    arr[word] = bor(band(arr[word], bxor(lshift(0xF, shift), 0xFFFFFFFF)), lshift(val + 1, shift))
  end
  -- silently saturate at 15 (counter overflow)
end

local function counter_dec(arr, pos)
  local word = math.floor(pos / 8) + 1
  local shift = (pos % 8) * 4
  local val = band(rshift(arr[word], shift), 0xF)
  if val == 0 then return false end
  arr[word] = bor(band(arr[word], bxor(lshift(0xF, shift), 0xFFFFFFFF)), lshift(val - 1, shift))
  return true
end

function counting_mt:add(item)
  local self_ = self --[[:! CountingFilter]]
  local h1 = fnv1a(item)
  local h2 = djb2(item)
  for i = 0, self_._k - 1 do
    counter_inc(self_._counters, hash_i(h1, h2, i, self_._m))
  end
end

function counting_mt:remove(item)
  local self_ = self --[[:! CountingFilter]]
  local h1 = fnv1a(item)
  local h2 = djb2(item)
  -- Check all counters are > 0 before decrementing
  for i = 0, self_._k - 1 do
    if counter_get(self_._counters, hash_i(h1, h2, i, self_._m)) == 0 then
      return false
    end
  end
  for i = 0, self_._k - 1 do
    counter_dec(self_._counters, hash_i(h1, h2, i, self_._m))
  end
  return true
end

function counting_mt:contains(item)
  local self_ = self --[[:! CountingFilter]]
  local h1 = fnv1a(item)
  local h2 = djb2(item)
  for i = 0, self_._k - 1 do
    if counter_get(self_._counters, hash_i(h1, h2, i, self_._m)) == 0 then
      return false
    end
  end
  return true
end

-- M.counting(opts) -> filter or (nil, errmsg)
function M.counting(opts)
  local m, k, err = parse_opts(opts)
  if err then return nil, err end
  local m_ = m --[[:! integer]]
  local k_ = k --[[:! integer]]
  return setmetatable({
    _counters = counter_new(m_),
    _k = k_,
    _m = m_,
  }, counting_mt)
end

--:: ScalableBloom = { _layers: { [integer]: BloomFilter }, _growth_factor: number, _tightening_ratio: number, ... }

-- Scalable Bloom filter (grows by adding filter layers)
-- Each layer has tighter error_rate = error_rate * tightening_ratio^layer_index
local scalable_mt = {}
scalable_mt.__index = scalable_mt

function scalable_mt:add(item)
  local self_ = self --[[:! ScalableBloom]]
  -- Check if current layer is full
  local layer = self_._layers[#self_._layers]
  if layer._count_approx >= (layer._capacity or 0) then
    -- Add a new layer with larger capacity and tighter error rate
    local new_capacity = (layer._capacity or 0) * self_._growth_factor
    local new_error_rate = (layer._error_rate or 0.01) * self_._tightening_ratio
    local new_m = optimal_m(new_capacity, new_error_rate)
    local new_k = optimal_k(new_m, new_capacity)
    layer = setmetatable({
      _bits = bitarray_new(new_m),
      _k = new_k,
      _m = new_m,
      _count_approx = 0,
      _capacity = new_capacity,
      _error_rate = new_error_rate,
    }, bloom_mt)
    self_._layers[#self_._layers + 1] = layer
  end
  layer:add(item)
end

function scalable_mt:contains(item)
  local self_ = self --[[:! ScalableBloom]]
  for i = #self_._layers, 1, -1 do
    if self_._layers[i]:contains(item) then
      return true
    end
  end
  return false
end

function scalable_mt:layers()
  local self_ = self --[[:! ScalableBloom]]
  return #self_._layers
end

-- M.scalable(opts) -> filter or (nil, errmsg)
-- opts: { initial_capacity=100, error_rate=0.01, growth_factor=2, tightening_ratio=0.85 }
function M.scalable(opts)
  local capacity_ = opts and opts.initial_capacity or 100
  local error_rate_ = opts and opts.error_rate or 0.01
  local growth_factor_ = opts and opts.growth_factor or 2
  local tightening_ratio_ = opts and opts.tightening_ratio or 0.85

  if type(capacity_) ~= "number" or (capacity_ --[[:! number]]) < 1 then
    return nil, "opts.initial_capacity must be a positive number"
  end
  if type(error_rate_) ~= "number" or (error_rate_ --[[:! number]]) <= 0 or (error_rate_ --[[:! number]]) >= 1 then
    return nil, "opts.error_rate must be a number in (0, 1)"
  end
  if type(growth_factor_) ~= "number" or (growth_factor_ --[[:! number]]) <= 1 then
    return nil, "opts.growth_factor must be a number > 1"
  end
  if type(tightening_ratio_) ~= "number" or (tightening_ratio_ --[[:! number]]) <= 0 or (tightening_ratio_ --[[:! number]]) >= 1 then
    return nil, "opts.tightening_ratio must be a number in (0, 1)"
  end

  local capacity = capacity_ --[[:! number]]
  local error_rate = error_rate_ --[[:! number]]
  local growth_factor = growth_factor_ --[[:! number]]
  local tightening_ratio = tightening_ratio_ --[[:! number]]

  local m = optimal_m(capacity, error_rate)
  local k = optimal_k(m, capacity)
  local first_layer = setmetatable({
    _bits = bitarray_new(m),
    _k = k,
    _m = m,
    _count_approx = 0,
    _capacity = capacity,
    _error_rate = error_rate,
  }, bloom_mt)

  return setmetatable({
    _layers = { first_layer },
    _growth_factor = growth_factor,
    _tightening_ratio = tightening_ratio,
  }, scalable_mt)
end

return M
