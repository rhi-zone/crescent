-- lib/count_min/init.lua
-- Count-Min Sketch probabilistic frequency estimator.
-- Cormode & Muthukrishnan, 2005.
-- Pure Lua — no dependencies beyond LuaJIT bit library.
--
-- Guarantees: with probability >= 1-delta,
--   query(x) <= true_count(x) + epsilon * N
-- where N is the total number of updates.
--
-- Width  w = ceil(e / epsilon)   (e = 2.71828...)
-- Depth  d = ceil(ln(1/delta))
-- With epsilon=0.01, delta=0.01: w≈272, d≈5 → ~1360 counters

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local bit = require("bit")
local band, bxor, bor, lshift, rshift, tobit =
  bit.band, bit.bxor, bit.bor, bit.lshift, bit.rshift, bit.tobit
local floor, ceil, log, huge = math.floor, math.ceil, math.log, math.huge

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- FNV-1a 32-bit hash with seed mixing — safe 16-bit multiply to stay in range.
local function hash32(s, seed)
  local h = bxor(math.floor(2166136261), seed or 0)
  for i = 1, #s do
    h = bxor(h, string.byte(s, i))
    -- Multiply by FNV prime 16777619 using 16-bit halves to avoid float overflow.
    local lo = band(h, 0xffff)
    local hi = rshift(h, 16)  -- unsigned rshift
    local p  = 16777619
    local pl = lo * p
    local ph = hi * p
    h = tobit(bor(
      band(pl, 0xffff),
      lshift(band(bor(rshift(pl, 16), ph), 0xffff), 16)
    ))
  end
  return h
end

-- Generate d deterministic seeds (Knuth multiplicative + increment).
local function make_seeds(d)
  local seeds = {}
  for i = 1, d do
    seeds[i] = band(math.floor(i * 2654435761 + 1013904223), math.floor(0xffffffff))
  end
  return seeds
end

-- Pack a uint32 as 4 big-endian bytes into table t.
local function pack_u32(t, v)
  v = band(v, 0xffffffff)
  t[#t + 1] = string.char(
    band(rshift(v, 24), 0xff),
    band(rshift(v, 16), 0xff),
    band(rshift(v,  8), 0xff),
    band(v, 0xff)
  )
end

-- Unpack a big-endian uint32 from string s at byte offset (1-based).
--: (string, integer) -> integer
local function unpack_u32(s, off)
  local b1 = (string.byte(s, off, off) or 0) --[[:! integer]]
  local b2 = (string.byte(s, off + 1, off + 1) or 0) --[[:! integer]]
  local b3 = (string.byte(s, off + 2, off + 2) or 0) --[[:! integer]]
  local b4 = (string.byte(s, off + 3, off + 3) or 0) --[[:! integer]]
  return bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
end

-- ---------------------------------------------------------------------------
-- CMS metatable
-- ---------------------------------------------------------------------------

--:: CMS = { _w: integer, _d: integer, _seeds: { [integer]: integer }, _counters: { [integer]: number }, _total: number, _heavy: { [string]: number } | nil, update: (CMS, unknown, number | nil) -> nil, update_conservative: (CMS, unknown, number | nil) -> nil, query: (CMS, unknown) -> number, merge: (CMS, CMS) -> (CMS | nil, string | nil), reset: (CMS) -> nil, total: (CMS) -> number, width: (CMS) -> integer, depth: (CMS) -> integer, serialize: (CMS) -> string, heavy_hitters: (CMS, integer | nil) -> ({ [integer]: { [integer]: unknown } } | nil, string | nil) }
local CMS = {}
CMS.__index = CMS

-- update(element, amount): increment frequency of element by amount (default 1).
--: (CMS, unknown, number | nil) -> nil
function CMS:update(element, amount)
  amount = amount or 1
  local s     = type(element) == "string" and element or tostring(element)
  local w     = self._w
  local d     = self._d
  local seeds = self._seeds
  local cnt   = self._counters
  for i = 0, d - 1 do
    local j = band(hash32(s, seeds[i + 1]), 0x7fffffff) % w
    local idx = i * w + j + 1
    cnt[idx] = cnt[idx] + amount
  end
  self._total = self._total + amount
  -- Track heavy hitters if enabled.
  if self._heavy then
    local heavy_ = self._heavy --[[:! { [string]: number }]]
    local cur = heavy_[s] or 0
    heavy_[s] = cur + amount
  end
end

-- update_conservative(element, amount): conservative update variant.
-- For each row, only increment if current counter < current minimum (query value).
-- Reduces overcount at the cost of slightly more CPU.
--: (CMS, unknown, number | nil) -> nil
function CMS:update_conservative(element, amount)
  amount = amount or 1
  local s     = type(element) == "string" and element or tostring(element)
  local w     = self._w
  local d     = self._d
  local seeds = self._seeds
  local cnt   = self._counters
  -- First pass: compute current minimum (= query value).
  local min_val = huge
  local idxs    = {}
  for i = 0, d - 1 do
    local j   = band(hash32(s, seeds[i + 1]), 0x7fffffff) % w
    local idx  = i * w + j + 1
    idxs[i + 1] = idx
    if cnt[idx] < min_val then min_val = cnt[idx] end
  end
  -- Second pass: increment only cells at the minimum.
  local target = min_val + amount
  for i = 1, d do
    local idx = idxs[i]
    if cnt[idx] < target then
      cnt[idx] = target
    end
  end
  self._total = self._total + amount
  if self._heavy then
    local heavy_ = self._heavy --[[:! { [string]: number }]]
    local cur = heavy_[s] or 0
    heavy_[s] = cur + amount
  end
end

-- query(element): return minimum counter value — the frequency estimate.
--: (CMS, unknown) -> number
function CMS:query(element)
  local s     = type(element) == "string" and element or tostring(element)
  local w     = self._w
  local d     = self._d
  local seeds = self._seeds
  local cnt   = self._counters
  local min_val = huge
  for i = 0, d - 1 do
    local j = band(hash32(s, seeds[i + 1]), 0x7fffffff) % w
    local v = cnt[i * w + j + 1]
    if v < min_val then min_val = v end
  end
  return min_val == huge and 0 or min_val
end

-- merge(other): add other's counters into self in-place.
-- Both sketches must have identical width and depth.
-- Returns self, err.
--: (CMS, CMS) -> (CMS | nil, string | nil)
function CMS:merge(other)
  local other_ = other --[[:! CMS]]
  if self._w ~= other_._w or self._d ~= other_._d then
    return nil, "count_min:merge: incompatible dimensions (w or d mismatch)"
  end
  local cnt1 = self._counters
  local cnt2 = other_._counters
  local n    = self._w * self._d
  for i = 1, n do
    cnt1[i] = cnt1[i] + cnt2[i]
  end
  self._total = self._total + other_._total
  if self._heavy and other_._heavy then
    local h1_ = self._heavy --[[:! { [string]: number }]]
    local h2_ = other_._heavy --[[:! { [string]: number }]]
    for k, v in pairs(h2_) do
      h1_[k] = (h1_[k] or 0) + v
    end
  end
  return self --[[:! CMS]]
end

-- reset(): set all counters to zero, reset total.
--: (CMS) -> nil
function CMS:reset()
  local cnt = self._counters
  local n   = self._w * self._d
  for i = 1, n do cnt[i] = 0 end
  self._total = 0
  if self._heavy then
    local heavy_ = self._heavy --[[:! { [string]: number }]]
    for k in pairs(heavy_) do heavy_[k] = 0; heavy_[k] = nil --[[: unknown]] end
  end
end

-- total(): total number of updates (sum of all amounts).
--: (CMS) -> number
function CMS:total()
  return self._total
end

-- width(): counters per row.
--: (CMS) -> integer
function CMS:width()
  return self._w
end

-- depth(): number of rows (hash functions).
--: (CMS) -> integer
function CMS:depth()
  return self._d
end

-- serialize(): pack sketch into a binary string.
-- Header (16 bytes): d (4B), w (4B), total_lo (4B), total_hi (4B)
-- Body: d*w uint32 counters (4 bytes each, big-endian).
--: (CMS) -> string
function CMS:serialize()
  local t   = {}
  local d   = self._d
  local w   = self._w
  local tot = self._total
  -- Split total into two 32-bit halves (lo = lower 32 bits, hi = upper bits).
  -- LuaJIT numbers are doubles; support up to 2^53 safely.
  local lo  = tot % 0x100000000
  local hi  = floor(tot / 0x100000000)
  pack_u32(t, d --[[:! integer]])
  pack_u32(t, w --[[:! integer]])
  pack_u32(t, math.floor(lo))
  pack_u32(t, math.floor(hi))
  local cnt = self._counters
  for i = 1, d * w do
    pack_u32(t, math.floor(cnt[i]))
  end
  return table.concat(t)
end

-- heavy_hitters(k): return top-k elements by estimated count (descending).
-- Only available when sketch was created with track_heavy=true.
-- Returns {{element, count}, ...} or (nil, err).
--: (CMS, integer | nil) -> ({ [integer]: { [integer]: unknown } } | nil, string | nil)
function CMS:heavy_hitters(k)
  if not self._heavy then
    return nil, "count_min:heavy_hitters: sketch not created with track_heavy=true"
  end
  local heavy_ = self._heavy --[[:! { [string]: number }]]
  local list = {}
  for elem, cnt in pairs(heavy_) do
    list[#list + 1] = { elem, cnt }
  end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  if k then
    local out = {}
    for i = 1, math.min(k, #list) do out[i] = list[i] end
    return out
  end
  return list
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

-- Internal: build a CMS object from explicit w, d, optional opts.
local function make_cms(w, d, opts)
  local seeds = make_seeds(d)
  local cnt   = {}
  local n     = w * d
  for i = 1, n do cnt[i] = 0 end
  local heavy = nil
  if opts and opts.track_heavy then heavy = {} end
  return setmetatable({
    _w        = w,
    _d        = d,
    _seeds    = seeds,
    _counters = cnt,
    _total    = 0,
    _heavy    = heavy,
  }, CMS)
end

-- M.new(epsilon, delta[, opts]): create from error parameters.
-- epsilon: relative error tolerance (e.g. 0.01 = 1%)
-- delta:   failure probability (e.g. 0.01 = 1%)
-- opts:    optional table; opts.track_heavy=true enables heavy_hitters()
function M.new(epsilon, delta, opts)
  if not epsilon or epsilon <= 0 or epsilon >= 1 then
    return nil, "count_min.new: epsilon must be in (0, 1)"
  end
  if not delta or delta <= 0 or delta >= 1 then
    return nil, "count_min.new: delta must be in (0, 1)"
  end
  local w = ceil(math.exp(1) / epsilon)  -- ceil(e / epsilon)
  local d = ceil(log(1 / delta))         -- ceil(ln(1/delta))
  return make_cms(w, d, opts)
end

-- M.new_wh(width, depth[, opts]): create with explicit dimensions.
function M.new_wh(width, depth, opts)
  if not width or width < 1 then
    return nil, "count_min.new_wh: width must be >= 1"
  end
  if not depth or depth < 1 then
    return nil, "count_min.new_wh: depth must be >= 1"
  end
  return make_cms(width, depth, opts)
end

-- M.deserialize(s): reconstruct a CMS from a binary string produced by serialize().
function M.deserialize(s)
  -- Minimum: 16-byte header.
  if type(s) ~= "string" or #s < 16 then
    return nil, "count_min.deserialize: invalid data (too short)"
  end
  local d  = unpack_u32(s, 1)
  local w  = unpack_u32(s, 5)
  local lo = unpack_u32(s, 9)
  local hi = unpack_u32(s, 13)
  if d == 0 or w == 0 then
    return nil, "count_min.deserialize: invalid dimensions"
  end
  local body_len = d * w * 4
  if #s ~= 16 + body_len then
    return nil, "count_min.deserialize: data length mismatch"
  end
  local seeds = make_seeds(d)
  local cnt   = {}
  for i = 1, d * w do
    cnt[i] = unpack_u32(s, 16 + (i - 1) * 4 + 1)
  end
  -- Reconstruct total from lo/hi halves.
  -- unpack_u32 returns a signed Lua number via bor/lshift; coerce to unsigned.
  local lo_n = lo --: number
  local hi_n = hi --: number
  if lo_n < 0 then lo_n = lo_n + 0x100000000 end
  if hi_n < 0 then hi_n = hi_n + 0x100000000 end
  local total = hi_n * 0x100000000 + lo_n
  return setmetatable({
    _w        = w,
    _d        = d,
    _seeds    = seeds,
    _counters = cnt,
    _total    = total,
    _heavy    = nil,
  }, CMS)
end

return M
