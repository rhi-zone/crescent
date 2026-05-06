-- lib/cuckoo/init.lua
-- Cuckoo filter: probabilistic set membership with insert, lookup, and DELETE.
-- Unlike Bloom filters, supports deletion via partial-key cuckoo hashing.
-- Based on Fan et al., 2014: "Cuckoo Filter: Practically Better Than Bloom".
-- Pure Lua — no dependencies beyond LuaJIT bit library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = require("bit")
local band, bor, bxor, lshift, rshift, tobit =
  bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift, bit.tobit
local floor, ceil, log = math.floor, math.ceil, math.log
local byte, char = string.byte, string.char

-- ---------------------------------------------------------------------------
-- Hash helpers
-- ---------------------------------------------------------------------------

-- FNV-1a 32-bit hash with safe 16-bit multiply to avoid double precision loss.
-- FNV prime = 16777619 (25 bits). Max product: 65535 * 16777619 < 2^41 < 2^53 — safe.
local function fnv1a32(s, seed)
  local h = tobit(seed or 2166136261)
  for i = 1, #s do
    h = bxor(h, (byte(s, i) or 0))
    -- Multiply by FNV prime 16777619 using 16-bit splits to stay within 53-bit mantissa.
    local a = band(h, 0xffff)            -- lower 16 bits
    local b = band(rshift(h, 16), 0xffff) -- upper 16 bits (logical via mask)
    local prime = 16777619
    local alo = a * prime               -- <= 65535 * 16777619 < 2^41, exact in double
    local blo = b * prime               -- same
    -- recombine: lower 16 of alo | (lower 16 of (blo + upper 16 of alo)) << 16
    local result = band(alo, 0xffff) +
                   lshift(band(blo + rshift(alo, 16), 0xffff), 16)
    h = tobit(result)
  end
  return h
end

-- Hash the fingerprint (an integer) for alternate-bucket computation.
-- Treats fp as a 4-character "string" of bytes for mixing.
local function hash_fp(fp)
  -- Simple multiplicative mix — fast for small integers.
  local h = tobit(fp * 0x9e3779b9)
  h = bxor(h, rshift(h, 16))
  h = tobit(h * 0x85ebca6b)
  h = bxor(h, rshift(h, 13))
  return h
end

-- ---------------------------------------------------------------------------
-- Internal bucket operations
-- ---------------------------------------------------------------------------

-- Flat storage: self._data[bucket_index * bucket_size + slot + 1], 1-based.
-- Value 0 = empty slot. Fingerprints are always >= 1.

--: ({ [integer]: integer }, integer, integer, integer) -> integer | nil
local function bucket_find(data, base, bucket_size, fp)
  for s = 0, bucket_size - 1 do
    if data[base + s] == fp then return s end
  end
  return nil
end

--: ({ [integer]: integer }, integer, integer, integer) -> boolean
local function bucket_insert(data, base, bucket_size, fp)
  for s = 0, bucket_size - 1 do
    if data[base + s] == 0 then
      data[base + s] = fp
      return true
    end
  end
  return false
end

--: ({ [integer]: integer }, integer, integer, integer) -> boolean
local function bucket_delete(data, base, bucket_size, fp)
  for s = 0, bucket_size - 1 do
    if data[base + s] == fp then
      data[base + s] = 0
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Filter object
-- ---------------------------------------------------------------------------

--:: CuckooFilter = { _data: { [integer]: integer }, _num_buckets: integer, _bucket_size: integer, _fp_bits: integer, _fp_mask: integer, _max_kicks: integer, _count: integer, _capacity: integer }

local Filter = {}
Filter.__index = Filter

-- Coerce element to string key (numbers are common).
local function to_key(v)
  if type(v) == "string" then return v end
  return tostring(v)
end

-- Compute fingerprint and two bucket indices for element s.
--: (CuckooFilter, string) -> (integer, integer, integer)
local function fingerprints(self, s)
  local self_ = self --[[:! CuckooFilter]]
  local fp_mask = self_._fp_mask
  local num_buckets = self_._num_buckets
  local fp = band(fnv1a32(s, 0xdeadbeef), fp_mask)
  if fp == 0 then fp = 1 end  -- 0 is reserved for empty slots

  local i1 = band(fnv1a32(s, 0x811c9dc5), num_buckets - 1)
  -- Partial-key cuckoo: i2 = i1 XOR hash(fp)  — derivable from either bucket + fp
  local i2 = band(bxor(i1, band(hash_fp(fp), num_buckets - 1)), num_buckets - 1)
  return fp, i1, i2
end

-- Alternate bucket given current bucket index and fingerprint.
--: (CuckooFilter, integer, integer) -> integer
local function alt_index(self, i, fp)
  local self_ = self --[[:! CuckooFilter]]
  return band(bxor(i, band(hash_fp(fp), self_._num_buckets - 1)), self_._num_buckets - 1)
end

function Filter:insert(element)
  local self_ = self --[[:! CuckooFilter]]
  local s = to_key(element)
  local fp, i1, i2 = fingerprints(self_, s)
  local data = self_._data
  local bs = self_._bucket_size

  -- Try direct insert into i1 or i2.
  if bucket_insert(data, i1 * bs, bs, fp) then
    self_._count = self_._count + 1
    return true
  end
  if bucket_insert(data, i2 * bs, bs, fp) then
    self_._count = self_._count + 1
    return true
  end

  -- Both full — cuckoo eviction loop.
  -- Randomly pick starting bucket (deterministic: use i1 ^ fp for spread).
  local i = (band(i1 + fp, 1) == 0) and i1 or i2
  local max_kicks = self_._max_kicks
  for _ = 1, max_kicks do
    -- Evict a random (deterministic) entry from bucket i.
    -- Pick slot via a simple rotation based on current fp.
    local slot = band(fp, bs - 1)  -- slot in [0, bs-1]
    local base = i * bs
    local evicted = data[base + slot]
    data[base + slot] = fp
    fp = evicted
    -- Move evicted fingerprint to its alternate bucket.
    i = alt_index(self_, i, fp)
    if bucket_insert(data, i * bs, bs, fp) then
      self_._count = self_._count + 1
      return true
    end
  end

  -- Filter is full.
  return nil, "full"
end

function Filter:contains(element)
  local self_ = self --[[:! CuckooFilter]]
  local s = to_key(element)
  local fp, i1, i2 = fingerprints(self_, s)
  local data = self_._data
  local bs = self_._bucket_size
  return bucket_find(data, i1 * bs, bs, fp) ~= nil
      or bucket_find(data, i2 * bs, bs, fp) ~= nil
end

function Filter:delete(element)
  local self_ = self --[[:! CuckooFilter]]
  local s = to_key(element)
  local fp, i1, i2 = fingerprints(self_, s)
  local data = self_._data
  local bs = self_._bucket_size
  if bucket_delete(data, i1 * bs, bs, fp) then
    self_._count = self_._count - 1
    return true
  end
  if bucket_delete(data, i2 * bs, bs, fp) then
    self_._count = self_._count - 1
    return true
  end
  return false
end

function Filter:count()
  local self_ = self --[[:! CuckooFilter]]
  return self_._count
end

function Filter:capacity()
  local self_ = self --[[:! CuckooFilter]]
  return self_._capacity
end

function Filter:false_positive_rate()
  -- Theoretical FPR: (1 - (1 - 1/2^f)^(2*b))
  -- where f = fingerprint bits, b = bucket size.
  -- Approximation: 2b / 2^f
  local self_ = self --[[:! CuckooFilter]]
  local f = self_._fp_bits
  local b = self_._bucket_size
  return (2 * b) / (2 ^ f)
end

function Filter:load_factor()
  local self_ = self --[[:! CuckooFilter]]
  local total = self_._num_buckets * self_._bucket_size
  if total == 0 then return 0 end
  -- Count actual filled slots by scanning (data is 0-indexed).
  local filled = 0
  local data = self_._data
  for i = 0, total - 1 do
    if data[i] ~= 0 then filled = filled + 1 end
  end
  return filled / total
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------
-- Header (12 bytes): num_buckets (4), bucket_size (1), fp_bits (1), max_kicks (2),
--                    count (4).
-- Body: packed fingerprint array. Each fingerprint is stored in ceil(fp_bits/8) bytes
-- for byte-aligned simplicity (simplifies round-trip). Total = num_buckets*bucket_size
-- entries * bytes_per_fp bytes.

function Filter:serialize()
  local self_ = self --[[:! CuckooFilter]]
  local nb = self_._num_buckets
  local bs = self_._bucket_size
  local fp_bits = self_._fp_bits
  local max_kicks = self_._max_kicks
  local count = self_._count
  local data = self_._data
  local total = nb * bs

  -- Bytes per fingerprint: 1 for 4/8 bits, 2 for 16 bits.
  local bpf = (fp_bits <= 8) and 1 or 2

  local t = {}
  -- Header
  t[#t+1] = char(band(rshift(nb, 24), 0xff), band(rshift(nb, 16), 0xff),
                 band(rshift(nb,  8), 0xff), band(nb, 0xff))
  t[#t+1] = char(bs, fp_bits,
                 band(rshift(max_kicks, 8), 0xff), band(max_kicks, 0xff))
  t[#t+1] = char(band(rshift(count, 24), 0xff), band(rshift(count, 16), 0xff),
                 band(rshift(count,  8), 0xff), band(count, 0xff))
  -- Body (data is 0-indexed)
  if bpf == 1 then
    for i = 0, total - 1 do
      t[#t+1] = char(band(data[i], 0xff))
    end
  else
    for i = 0, total - 1 do
      local v = data[i]
      t[#t+1] = char(band(rshift(v, 8), 0xff), band(v, 0xff))
    end
  end
  return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

-- Next power of 2 >= n.
local function next_pow2(n)
  local p = 1
  while p < n do p = p * 2 end
  return p
end

-- Create a new cuckoo filter.
-- capacity: approximate max number of items.
-- opts.fingerprint_bits: 4, 8, or 16 (default 8).
-- opts.bucket_size: 2 or 4 (default 4).
-- opts.max_kicks: max eviction attempts (default 500).
--: (integer, { fingerprint_bits?: integer, bucket_size?: integer, max_kicks?: integer } | nil) -> (CuckooFilter | nil, string | nil)
function M.new(capacity, opts)
  if not capacity or capacity < 1 then
    return nil, "cuckoo.new: capacity must be >= 1"
  end
  local opts_ = opts or {} --[[:! { fingerprint_bits?: integer, bucket_size?: integer, max_kicks?: integer }]]
  local fp_bits    = opts_.fingerprint_bits or 8
  local bucket_size = opts_.bucket_size or 4
  local max_kicks  = opts_.max_kicks or 500

  if fp_bits ~= 4 and fp_bits ~= 8 and fp_bits ~= 16 then
    return nil, "cuckoo.new: fingerprint_bits must be 4, 8, or 16"
  end
  if bucket_size ~= 2 and bucket_size ~= 4 then
    return nil, "cuckoo.new: bucket_size must be 2 or 4"
  end

  -- Number of buckets = next power of 2 so that XOR-based alternate index works.
  -- Each bucket holds bucket_size items; load factor ~= 0.955 * bucket_size/bucket_size.
  -- To achieve requested capacity, need at least capacity/bucket_size buckets.
  local num_buckets = next_pow2(ceil(capacity / bucket_size))
  if num_buckets < 1 then num_buckets = 1 end

  local fp_mask = lshift(1, fp_bits) - 1
  local total = num_buckets * bucket_size

  -- Initialize flat data array (all 0 = empty). 0-indexed: data[0] to data[total-1].
  local data = {} --: { [integer]: integer }
  for i = 0, total - 1 do data[i] = 0 end

  return setmetatable({
    _data        = data,
    _num_buckets = num_buckets,
    _bucket_size = bucket_size,
    _fp_bits     = fp_bits,
    _fp_mask     = fp_mask,
    _max_kicks   = max_kicks,
    _count       = 0,
    _capacity    = num_buckets * bucket_size,  -- true max slots (theoretical ~95% usable)
  }, Filter)
end

-- Deserialize a filter produced by filter:serialize().
function M.deserialize(s)
  if type(s) ~= "string" or #s < 12 then
    return nil, "cuckoo.deserialize: invalid data (too short)"
  end
  local b1_,b2_,b3_,b4_ = byte(s, 1, 4)
  local b1 = (b1_ or 0)
  local b2 = (b2_ or 0)
  local b3 = (b3_ or 0)
  local b4 = (b4_ or 0)
  local nb = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
  local bs_byte_, fp_bits_, mk_hi_, mk_lo_ = byte(s, 5, 8)
  local bucket_size = (bs_byte_ or 0)
  local fp_bits_val = (fp_bits_ or 0)
  local max_kicks = bor(lshift((mk_hi_ or 0), 8), (mk_lo_ or 0))
  local c1_,c2_,c3_,c4_ = byte(s, 9, 12)
  local c1 = (c1_ or 0)
  local c2 = (c2_ or 0)
  local c3 = (c3_ or 0)
  local c4 = (c4_ or 0)
  local count = bor(lshift(c1, 24), lshift(c2, 16), lshift(c3, 8), c4)

  if nb < 1 or bucket_size < 1 or fp_bits_val < 1 then
    return nil, "cuckoo.deserialize: corrupt header"
  end

  local bpf = (fp_bits_val <= 8) and 1 or 2
  local total = nb * bucket_size
  local expected_len = 12 + total * bpf
  if #s ~= expected_len then
    return nil, "cuckoo.deserialize: data length mismatch (got " .. #s .. ", expected " .. expected_len .. ")"
  end

  local data = {} --: { [integer]: integer }
  local offset = 13
  if bpf == 1 then
    for i = 0, total - 1 do
      data[i] = (byte(s, offset) or 0)
      offset = offset + 1
    end
  else
    for i = 0, total - 1 do
      local hi_, lo_ = byte(s, offset, offset + 1)
      local hi = (hi_ or 0)
      local lo = (lo_ or 0)
      data[i] = bor(lshift(hi, 8), lo)
      offset = offset + 2
    end
  end

  local fp_mask = lshift(1, fp_bits_val) - 1
  return setmetatable({
    _data        = data,
    _num_buckets = nb,
    _bucket_size = bucket_size,
    _fp_bits     = fp_bits_val,
    _fp_mask     = fp_mask,
    _max_kicks   = max_kicks,
    _count       = count,
    _capacity    = total,
  }, Filter)
end

return M
