-- lib/bloom/init.lua
-- Bloom filter probabilistic set membership.
-- Supports standard (space-efficient) and counting (supports remove) variants.
-- Pure Lua — no dependencies beyond LuaJIT bit library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = bit  -- LuaJIT global
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local floor, ceil, log, exp = math.floor, math.ceil, math.log, math.exp
local LN2 = log(2)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- FNV-1a 32-bit hash of a string, seeded by an integer offset (for double hashing)
local function fnv1a(s, seed)
  local h = band(2166136261 + seed * 16777619, 0xFFFFFFFF)
  local str = s --[[:! string]]
  for i = 1, #str do
    local b = string.byte(str, i) or 0
    h = band(h, 0xFFFFFFFF)
    h = band(bit.bxor(h, b) * 16777619, 0xFFFFFFFF)
  end
  return h
end

-- Compute h1 and h2 for Kirsch-Mitzenmacher double hashing
local function hash_pair(s)
  local h1 = fnv1a(s, 0)
  -- Simple polynomial second hash — different enough from FNV-1a
  local h2 = 0
  local str = s --[[:! string]]
  for i = 1, #str do
    h2 = band(h2 * 31 + (string.byte(str, i) or 0), 0xFFFFFFFF)
  end
  -- h2 must be odd to avoid degeneracy in double hashing (ensures all m slots reachable)
  h2 = bor(h2, 1)
  return h1, h2
end

-- Get and set individual bits in a packed integer table
-- bits[i] where i is 1-based 32-bit word index; bit position within word is 0-based
local function bit_get(bits, pos)
  local word = floor(pos / 32) + 1
  local off  = pos % 32
  return band(rshift(bits[word] or 0, off), 1) == 1
end

local function bit_set(bits, pos)
  local word = floor(pos / 32) + 1
  local off  = pos % 32
  bits[word] = bor(bits[word] or 0, lshift(1, off))
end

-- Count set bits in all words
local function popcount_all(bits, nwords)
  local n = 0
  for i = 1, nwords do
    local w = bits[i] or 0
    -- Brian Kernighan popcount
    while w ~= 0 do
      w = band(w, w - 1)
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Optimal parameter calculation
-- ---------------------------------------------------------------------------

-- Optimal bit-array size for n items and false-positive rate p
-- m = -n * ln(p) / (ln 2)^2
local function optimal_m(n, p)
  return ceil(-n * log(p) / (LN2 * LN2))
end

-- Optimal number of hash functions for given m and n
-- k = (m/n) * ln(2)
local function optimal_k(m, n)
  return math.max(1, ceil((m / n) * LN2))
end

-- ---------------------------------------------------------------------------
-- Standard Bloom filter
-- ---------------------------------------------------------------------------

local Bloom = {}
Bloom.__index = Bloom

-- Coerce key to string (numbers are common)
local function to_key(v)
  if type(v) == "string" then return v end
  return tostring(v)
end

-- Internal: probe k bit positions for key s, calling fn(pos) for each
local function probe(b, s, fn)
  local m, k = b._m, b._k
  local h1, h2 = hash_pair(s)
  for i = 0, k - 1 do
    -- Kirsch-Mitzenmacher: position = (h1 + i*h2) mod m
    local pos = (h1 + i * h2) % m
    fn(pos)
  end
end

function Bloom:add(v)
  local s = to_key(v)
  probe(self, s, function(pos) bit_set(self._bits, pos) end)
end

function Bloom:has(v)
  local s = to_key(v)
  local all = true
  probe(self, s, function(pos)
    if not bit_get(self._bits, pos) then all = false end
  end)
  return all
end

function Bloom:clear()
  local nwords = self._nwords
  for i = 1, nwords do self._bits[i] = 0 end
end

function Bloom:capacity()
  return self._m
end

function Bloom:num_hashes()
  return self._k
end

-- Estimated number of items added: n* = -m/k * ln(1 - X/m)  where X = set bits
function Bloom:count()
  local x = popcount_all(self._bits, self._nwords)
  local m, k = self._m, self._k
  if x >= m then return math.huge end
  if x == 0 then return 0 end
  return floor(-m / k * log(1 - x / m) + 0.5)
end

-- Estimated FP rate: (1 - e^(-k*n/m))^k  using estimated n
function Bloom:false_positive_rate()
  local n = self:count()
  local m, k = self._m, self._k
  if n == math.huge then return 1 end
  return (1 - exp(-k * n / m)) ^ k
end

-- Serialize as: 4-byte big-endian m, 4-byte big-endian k, then nwords * 4 bytes.
-- k is embedded so bloom.deserialize() needs no extra parameter.
function Bloom:to_string()
  local nwords = self._nwords
  local m = self._m
  local k = self._k
  local t = {}
  -- Header: m then k as big-endian uint32
  t[#t + 1] = string.char(
    band(rshift(m, 24), 0xFF),
    band(rshift(m, 16), 0xFF),
    band(rshift(m,  8), 0xFF),
    band(m, 0xFF)
  )
  t[#t + 1] = string.char(
    band(rshift(k, 24), 0xFF),
    band(rshift(k, 16), 0xFF),
    band(rshift(k,  8), 0xFF),
    band(k, 0xFF)
  )
  for i = 1, nwords do
    local w = self._bits[i] or 0
    t[#t + 1] = string.char(
      band(rshift(w, 24), 0xFF),
      band(rshift(w, 16), 0xFF),
      band(rshift(w,  8), 0xFF),
      band(w, 0xFF)
    )
  end
  return table.concat(t)
end

-- serialize is an alias for to_string
Bloom.serialize = Bloom.to_string

-- Union: OR of bit arrays. Returns new Bloom filter. Same m and k required.
function Bloom:union(other)
  if self._m ~= other._m or self._k ~= other._k then
    return nil, "bloom:union: incompatible filters (m or k mismatch)"
  end
  local nb = M.new_raw(self._m, self._k)
  for i = 1, self._nwords do
    nb._bits[i] = bor(self._bits[i] or 0, other._bits[i] or 0)
  end
  return nb
end

-- merge: in-place union — OR other's bits into self. Same m and k required.
function Bloom:merge(other)
  if self._m ~= other._m or self._k ~= other._k then
    return nil, "bloom:merge: incompatible filters (m or k mismatch)"
  end
  for i = 1, self._nwords do
    self._bits[i] = bor(self._bits[i] or 0, other._bits[i] or 0)
  end
  return self
end

-- Intersection: AND of bit arrays. Returns new Bloom filter. Same m and k required.
function Bloom:intersection(other)
  if self._m ~= other._m or self._k ~= other._k then
    return nil, "bloom:intersection: incompatible filters (m or k mismatch)"
  end
  local nb = M.new_raw(self._m, self._k)
  for i = 1, self._nwords do
    nb._bits[i] = band(self._bits[i] or 0, other._bits[i] or 0)
  end
  return nb
end

-- intersect: in-place intersection — AND self's bits with other's. Same m and k required.
function Bloom:intersect(other)
  if self._m ~= other._m or self._k ~= other._k then
    return nil, "bloom:intersect: incompatible filters (m or k mismatch)"
  end
  for i = 1, self._nwords do
    self._bits[i] = band(self._bits[i] or 0, other._bits[i] or 0)
  end
  return self
end

-- bit_count: total number of bits in the filter
function Bloom:bit_count()
  return self._m
end

-- hash_count: number of hash functions
function Bloom:hash_count()
  return self._k
end

-- ---------------------------------------------------------------------------
-- Bloom filter constructors
-- ---------------------------------------------------------------------------

-- Create from explicit bit count and hash count
function M.new_raw(m, k)
  local nwords = ceil(m / 32)
  local bits = {}
  for i = 1, nwords do bits[i] = 0 end
  return setmetatable({
    _m      = m,
    _k      = k,
    _nwords = nwords,
    _bits   = bits,
  }, Bloom)
end

-- Create from expected capacity n and false-positive rate p (0 < p < 1)
function M.new(n, p)
  if not n or not p or n < 1 or p <= 0 or p >= 1 then
    return nil, "bloom.new: n must be >= 1 and 0 < p < 1"
  end
  local m = optimal_m(n, p)
  local k = optimal_k(m, n)
  return M.new_raw(m, k)
end

-- Reconstruct from serialized string produced by to_string/serialize.
-- Format (8-byte header): 4-byte big-endian m, 4-byte big-endian k, then nwords*4 bytes.
-- The optional second argument k is ignored when using the new format (k is in header).
function M.from_string(s, _k_ignored)
  local str = s --[[:! string]]
  local nbytes = #str
  -- Minimum: 8-byte header + 0 data words
  if nbytes < 8 or (nbytes - 8) % 4 ~= 0 then
    return nil, "bloom.from_string: invalid serialized string (bad length)"
  end
  local mh1, mh2, mh3, mh4 = string.byte(str, 1, 4)
  local m = bor(lshift(mh1, 24), lshift(mh2, 16), lshift(mh3, 8), mh4)
  local kh1, kh2, kh3, kh4 = string.byte(str, 5, 8)
  local k = bor(lshift(kh1, 24), lshift(kh2, 16), lshift(kh3, 8), kh4)
  if k == 0 then
    return nil, "bloom.from_string: invalid serialized string (k=0)"
  end
  local nwords = (nbytes - 8) / 4
  local bits = {}
  for i = 1, nwords do
    local off = 8 + (i - 1) * 4 + 1
    local b1, b2, b3, b4 = string.byte(str, off, off + 3)
    bits[i] = bor(
      lshift(b1, 24),
      lshift(b2, 16),
      lshift(b3,  8),
      b4
    )
  end
  return setmetatable({
    _m      = m,
    _k      = k,
    _nwords = nwords,
    _bits   = bits,
  }, Bloom)
end

-- deserialize: reconstruct from a string produced by serialize() (new format only).
-- k is embedded in the header — no second argument needed.
function M.deserialize(s)
  return M.from_string(s)
end

-- ---------------------------------------------------------------------------
-- Counting Bloom filter
-- ---------------------------------------------------------------------------
-- Each slot is a non-negative integer (unbounded in Lua; 4-bit semantics by
-- convention but we store plain ints for simplicity and correctness).
-- A bit-packed 4-bit-counter version is a future performance optimisation.

local CountingBloom = {}
CountingBloom.__index = CountingBloom

local function cprobe(cb, s, fn)
  local m, k = cb._m, cb._k
  local h1, h2 = hash_pair(s)
  for i = 0, k - 1 do
    local pos = (h1 + i * h2) % m
    fn(pos)
  end
end

function CountingBloom:add(v)
  local s = to_key(v)
  local counters = self._counters
  cprobe(self, s, function(pos)
    counters[pos] = (counters[pos] or 0) + 1
  end)
end

function CountingBloom:remove(v)
  local s = to_key(v)
  local counters = self._counters
  cprobe(self, s, function(pos)
    local c = counters[pos] or 0
    if c > 0 then counters[pos] = c - 1 end
  end)
end

function CountingBloom:has(v)
  local s = to_key(v)
  local counters = self._counters
  local all = true
  cprobe(self, s, function(pos)
    if (counters[pos] or 0) == 0 then all = false end
  end)
  return all
end

-- Minimum counter value across all k slots (lower bound on net add-minus-remove)
function CountingBloom:count_of(v)
  local s = to_key(v)
  local counters = self._counters
  local mn = math.huge
  cprobe(self, s, function(pos)
    local c = counters[pos] or 0
    if c < mn then mn = c end
  end)
  if mn == math.huge then return 0 end
  return mn
end

function CountingBloom:clear()
  local m = self._m
  local counters = self._counters
  for i = 0, m - 1 do counters[i] = 0 end
end

function CountingBloom:capacity()
  return self._m
end

function CountingBloom:num_hashes()
  return self._k
end

-- Estimated count uses number of non-zero slots as a proxy for set bits
function CountingBloom:count()
  local m, k = self._m, self._k
  local x = 0
  for i = 0, m - 1 do
    if (self._counters[i] or 0) > 0 then x = x + 1 end
  end
  if x >= m then return math.huge end
  if x == 0 then return 0 end
  return floor(-m / k * log(1 - x / m) + 0.5)
end

function CountingBloom:false_positive_rate()
  local n = self:count()
  local m, k = self._m, self._k
  if n == math.huge then return 1 end
  return (1 - exp(-k * n / m)) ^ k
end

-- ---------------------------------------------------------------------------
-- Counting Bloom filter constructors
-- ---------------------------------------------------------------------------

function M.counting_new_raw(m, k)
  local counters = {}
  for i = 0, m - 1 do counters[i] = 0 end
  return setmetatable({
    _m        = m,
    _k        = k,
    _counters = counters,
  }, CountingBloom)
end

function M.counting_new(n, p)
  if not n or not p or n < 1 or p <= 0 or p >= 1 then
    return nil, "bloom.counting_new: n must be >= 1 and 0 < p < 1"
  end
  local m = optimal_m(n, p)
  local k = optimal_k(m, n)
  return M.counting_new_raw(m, k)
end

-- counting: alias for counting_new
M.counting = M.counting_new

-- optimal_params: return {bits=m, hashes=k} for given capacity and FP rate
function M.optimal_params(n, p)
  if not n or not p or n < 1 or p <= 0 or p >= 1 then
    return nil, "bloom.optimal_params: n must be >= 1 and 0 < p < 1"
  end
  local m = optimal_m(n, p)
  local k = optimal_k(m, n)
  return { bits = m, hashes = k }
end

return M
