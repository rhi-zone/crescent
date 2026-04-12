-- lib/bloom_count/init.lua
-- Counting Bloom filter, Cuckoo filter, and Scalable Bloom filter.
-- Pure Lua — no dependencies beyond LuaJIT bit library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = bit  -- LuaJIT global
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local floor, ceil, log, exp = math.floor, math.ceil, math.log, math.exp
local LN2 = log(2)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- FNV-1a 32-bit hash
local function fnv1a(s, seed)
  seed = seed or 0
  local h = band(2166136261 + seed * 16777619, 0xFFFFFFFF)
  for i = 1, #s do
    h = band(bxor(h, string.byte(s, i)) * 16777619, 0xFFFFFFFF)
  end
  return h
end

-- Two independent hashes for Kirsch-Mitzenmacher double hashing
local function hash_pair(s)
  local h1 = fnv1a(s, 0)
  local h2 = 0
  for i = 1, #s do
    h2 = band(h2 * 31 + string.byte(s, i), 0xFFFFFFFF)
  end
  -- h2 must be odd to ensure all m slots are reachable
  h2 = bor(h2, 1)
  return h1, h2
end

-- Optimal bit count: m = -n * ln(p) / (ln 2)^2
local function optimal_m(n, p)
  return ceil(-n * log(p) / (LN2 * LN2))
end

-- Optimal hash count: k = (m/n) * ln(2)
local function optimal_k(m, n)
  return math.max(1, ceil((m / n) * LN2))
end

-- ---------------------------------------------------------------------------
-- Counting Bloom Filter
-- ---------------------------------------------------------------------------
-- Uses an array of counters (plain Lua integers). counter_bits controls the
-- logical max per counter (4=max 15, 8=max 255) — we saturate at max.

local CBF = {}
CBF.__index = CBF

local function cbf_probe(self, s, fn)
  local m, k = self._m, self._k
  local h1, h2 = hash_pair(s)
  for i = 0, k - 1 do
    fn((h1 + i * h2) % m)
  end
end

function CBF:add(item)
  local s = tostring(item)
  local counters = self._counters
  local max = self._max
  cbf_probe(self, s, function(pos)
    local c = counters[pos]
    if c < max then counters[pos] = c + 1 end
  end)
  self._size = self._size + 1
end

function CBF:remove(item)
  local s = tostring(item)
  local counters = self._counters
  -- Only decrement if ALL positions are > 0 (item was added)
  local all_positive = true
  cbf_probe(self, s, function(pos)
    if counters[pos] == 0 then all_positive = false end
  end)
  if not all_positive then return end
  cbf_probe(self, s, function(pos)
    counters[pos] = counters[pos] - 1
  end)
end

function CBF:contains(item)
  local s = tostring(item)
  local counters = self._counters
  local found = true
  cbf_probe(self, s, function(pos)
    if counters[pos] == 0 then found = false end
  end)
  return found
end

-- Returns minimum counter value across all hash positions (lower bound on net insertions)
function CBF:count(item)
  local s = tostring(item)
  local counters = self._counters
  local mn = math.huge
  cbf_probe(self, s, function(pos)
    local c = counters[pos]
    if c < mn then mn = c end
  end)
  if mn == math.huge then return 0 end
  return mn
end

function CBF:clear()
  local counters = self._counters
  for i = 0, self._m - 1 do counters[i] = 0 end
  self._size = 0
end

function CBF:size()
  return self._size
end

function CBF:false_positive_rate()
  local n = self._size
  local m, k = self._m, self._k
  if n == 0 then return 0 end
  return (1 - exp(-k * n / m)) ^ k
end

-- Construct counting Bloom filter from options table
-- opts.capacity, opts.error_rate (default 0.01), opts.counter_bits (default 4)
function M.counting(opts)
  opts = opts or {}
  local n = opts.capacity or 1000
  local p = opts.error_rate or 0.01
  if n < 1 or p <= 0 or p >= 1 then
    return nil, "bloom_count.counting: capacity must be >= 1 and 0 < error_rate < 1"
  end
  local m = optimal_m(n, p)
  local k = opts.hash_count or optimal_k(m, n)
  local bits = opts.counter_bits or 4
  local max = (bits >= 32) and 0x7FFFFFFF or (lshift(1, bits) - 1)
  local counters = {}
  for i = 0, m - 1 do counters[i] = 0 end
  return setmetatable({
    _m        = m,
    _k        = k,
    _max      = max,
    _counters = counters,
    _size     = 0,
  }, CBF)
end

-- ---------------------------------------------------------------------------
-- Cuckoo Filter
-- ---------------------------------------------------------------------------
-- 2 candidate buckets per item; fingerprint-based; supports O(1) deletion.

local CF = {}
CF.__index = CF

-- Compute fingerprint (never 0)
local function fingerprint(h, bits)
  local mask = lshift(1, bits) - 1
  local fp = band(h, mask)
  if fp == 0 then fp = 1 end
  return fp
end

-- Compute the two candidate bucket indices and fingerprint for an item.
-- Use a second independent hash for b1 to avoid the correlation between fp and b1
-- that occurs when both use the same low bits of the same hash value.
local function cf_positions(self, item)
  local h1 = fnv1a(item, 0)
  local h2 = fnv1a(item, 1337)  -- independent hash for bucket index
  local fp = fingerprint(h1, self._fp_bits)
  local nb = self._num_buckets
  local b1 = h2 % nb
  -- b2 = b1 XOR hash(fingerprint) — ensures b1 can be recovered from b2+fp
  local b2 = bxor(b1, fnv1a(tostring(fp), 0) % nb)
  return b1, b2, fp
end

function CF:add(item)
  local s = tostring(item)
  local b1, b2, fp = cf_positions(self, s)
  local buckets = self._buckets
  local bsz = self._bucket_size

  -- Try bucket 1
  local bucket = buckets[b1]
  for i = 1, bsz do
    if bucket[i] == 0 then
      bucket[i] = fp
      self._count = self._count + 1
      return true
    end
  end

  -- Try bucket 2
  bucket = buckets[b2]
  for i = 1, bsz do
    if bucket[i] == 0 then
      bucket[i] = fp
      self._count = self._count + 1
      return true
    end
  end

  -- Cuckoo eviction: randomly evict from one of the two buckets
  local cur_b = (math.random(2) == 1) and b1 or b2
  local cur_fp = fp
  local max_kicks = self._max_kicks
  for _ = 1, max_kicks do
    -- Pick a random entry in cur_b to evict
    local slot = math.random(bsz)
    local evicted = buckets[cur_b][slot]
    buckets[cur_b][slot] = cur_fp
    cur_fp = evicted
    -- Find the alternate bucket for the evicted fingerprint
    local alt_b = bxor(cur_b, fnv1a(tostring(cur_fp), 0) % self._num_buckets)
    bucket = buckets[alt_b]
    for i = 1, bsz do
      if bucket[i] == 0 then
        bucket[i] = cur_fp
        self._count = self._count + 1
        return true
      end
    end
    cur_b = alt_b
  end

  -- Filter is full
  return false
end

function CF:remove(item)
  local s = tostring(item)
  local b1, b2, fp = cf_positions(self, s)
  local buckets = self._buckets
  local bsz = self._bucket_size

  local bucket = buckets[b1]
  for i = 1, bsz do
    if bucket[i] == fp then
      bucket[i] = 0
      self._count = self._count - 1
      return true
    end
  end

  bucket = buckets[b2]
  for i = 1, bsz do
    if bucket[i] == fp then
      bucket[i] = 0
      self._count = self._count - 1
      return true
    end
  end

  return false
end

function CF:contains(item)
  local s = tostring(item)
  local b1, b2, fp = cf_positions(self, s)
  local buckets = self._buckets
  local bsz = self._bucket_size

  local bucket = buckets[b1]
  for i = 1, bsz do
    if bucket[i] == fp then return true end
  end

  bucket = buckets[b2]
  for i = 1, bsz do
    if bucket[i] == fp then return true end
  end

  return false
end

function CF:load_factor()
  return self._count / (self._num_buckets * self._bucket_size)
end

function CF:clear()
  local bsz = self._bucket_size
  local nb = self._num_buckets
  local buckets = self._buckets
  for i = 0, nb - 1 do
    local bucket = buckets[i]
    for j = 1, bsz do bucket[j] = 0 end
  end
  self._count = 0
end

-- Construct cuckoo filter from options table
-- opts.capacity, opts.fingerprint_bits (default 8), opts.bucket_size (default 4), opts.max_kicks (default 500)
function M.cuckoo(opts)
  opts = opts or {}
  local capacity = opts.capacity or 1000
  local fp_bits = opts.fingerprint_bits or 8
  local bsz = opts.bucket_size or 4
  local max_kicks = opts.max_kicks or 500
  -- Number of buckets: next power of 2 >= capacity / bucket_size
  local num_buckets = 1
  local target = ceil(capacity / bsz)
  while num_buckets < target do num_buckets = num_buckets * 2 end
  -- Build bucket array (1-indexed)
  local buckets = {}
  for i = 0, num_buckets - 1 do
    local b = {}
    for j = 1, bsz do b[j] = 0 end
    buckets[i] = b
  end
  return setmetatable({
    _num_buckets = num_buckets,
    _bucket_size = bsz,
    _fp_bits     = fp_bits,
    _max_kicks   = max_kicks,
    _buckets     = buckets,
    _count       = 0,
  }, CF)
end

-- ---------------------------------------------------------------------------
-- Simple (non-counting) Bloom filter — used internally by Scalable Bloom filter
-- ---------------------------------------------------------------------------

local SBF_inner = {}
SBF_inner.__index = SBF_inner

local function sbloom_bit_get(bits, pos)
  local word = floor(pos / 32) + 1
  return band(rshift(bits[word] or 0, pos % 32), 1) == 1
end

local function sbloom_bit_set(bits, pos)
  local word = floor(pos / 32) + 1
  bits[word] = bor(bits[word] or 0, lshift(1, pos % 32))
end

local function sbloom_probe(self, s, fn)
  local m, k = self._m, self._k
  local h1, h2 = hash_pair(s)
  for i = 0, k - 1 do
    fn((h1 + i * h2) % m)
  end
end

function SBF_inner:add(s)
  sbloom_probe(self, s, function(pos) sbloom_bit_set(self._bits, pos) end)
  self._count = self._count + 1
end

function SBF_inner:contains(s)
  local found = true
  sbloom_probe(self, s, function(pos)
    if not sbloom_bit_get(self._bits, pos) then found = false end
  end)
  return found
end

function SBF_inner:at_capacity()
  -- Consider "full" when 90% of capacity has been used
  return self._count >= self._capacity * 0.9
end

local function make_inner_bloom(n, p)
  local m = optimal_m(n, p)
  local k = optimal_k(m, n)
  local nwords = ceil(m / 32)
  local bits = {}
  for i = 1, nwords do bits[i] = 0 end
  return setmetatable({
    _m        = m,
    _k        = k,
    _bits     = bits,
    _count    = 0,
    _capacity = n,
  }, SBF_inner)
end

-- ---------------------------------------------------------------------------
-- Scalable Bloom Filter
-- ---------------------------------------------------------------------------

local ScalableBloom = {}
ScalableBloom.__index = ScalableBloom

function ScalableBloom:add(item)
  local s = tostring(item)
  -- Check if current filter needs expanding
  local current = self._filters[#self._filters]
  if current:at_capacity() then
    local new_cap = current._capacity * self._growth_factor
    -- Tighten error rate by factor of 0.85 per level to bound total FP rate
    local new_p = self._base_error_rate * (0.85 ^ #self._filters)
    if new_p < 1e-10 then new_p = 1e-10 end
    current = make_inner_bloom(new_cap, new_p)
    self._filters[#self._filters + 1] = current
  end
  current:add(s)
end

function ScalableBloom:contains(item)
  local s = tostring(item)
  for i = 1, #self._filters do
    if self._filters[i]:contains(s) then return true end
  end
  return false
end

function ScalableBloom:filter_count()
  return #self._filters
end

function ScalableBloom:total_capacity()
  local total = 0
  for i = 1, #self._filters do
    total = total + self._filters[i]._capacity
  end
  return total
end

-- Construct scalable Bloom filter from options table
-- opts.initial_capacity (default 100), opts.error_rate (default 0.01), opts.growth_factor (default 2)
function M.scalable(opts)
  opts = opts or {}
  local initial_capacity = opts.initial_capacity or 100
  local error_rate = opts.error_rate or 0.01
  local growth_factor = opts.growth_factor or 2
  local first = make_inner_bloom(initial_capacity, error_rate)
  return setmetatable({
    _filters          = { first },
    _base_error_rate  = error_rate,
    _growth_factor    = growth_factor,
  }, ScalableBloom)
end

return M
