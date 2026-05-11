if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Time series data store and analysis library.
-- Pure Lua, no dependencies.
--
-- A series stores {t, v} pairs sorted by t (monotonically increasing).
-- All statistical and transform operations return new series objects.

local M = {}
M._tier = "pure"

local sqrt = math.sqrt
local huge = math.huge

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Binary search: returns index of largest i such that ts[i] <= t, or 0.
-- Binary search: returns index of largest i such that ts[i] <= t, or 0.
local function bisect_le(times --[[ : { [integer]: number } ]], t --[[ : number ]])
  local lo, hi = 1, #times
  if hi == 0 or times[1] > t then return 0 end
  while lo < hi do
    local fl = math.floor((hi - lo + 1) / 2) --[[:! integer]]
    local mid = lo + fl
    if times[mid] <= t then lo = mid else hi = mid - 1 end
  end
  return lo
end

-- Returns index of first i such that ts[i] >= t, or #times+1.
local function bisect_ge(times --[[ : { [integer]: number } ]], t --[[ : number ]])
  local lo, hi = 1, #times
  if hi == 0 or times[hi] < t then return hi + 1 end
  while lo < hi do
    local fl = math.floor((hi - lo) / 2) --[[:! integer]]
    local mid = lo + fl
    if times[mid] >= t then hi = mid else lo = mid + 1 end
  end
  return lo
end

-- Aggregate a slice of values (array) by method string.
local function aggregate(vals, agg)
  local n = #vals
  if n == 0 then return nil end
  if agg == "count" then return n end
  if agg == "last" then return vals[n] end
  if agg == "first" then return vals[1] end
  local s = 0
  local mn, mx = huge, -huge
  for i = 1, n do
    local v = vals[i]
    s = s + v
    if v < mn then mn = v end
    if v > mx then mx = v end
  end
  if agg == "sum"  then return s end
  if agg == "min"  then return mn end
  if agg == "max"  then return mx end
  -- default: "mean"
  return s / n
end

-- ── series metatable ─────────────────────────────────────────────────────────

local Series = {}
Series.__index = Series

-- Create a new empty series (internal).
local function new_series()
  return setmetatable({ _t = {}, _v = {} }, Series)
end

-- Create a series pre-loaded with parallel time/value arrays (internal, no copy).
local function series_from(ts_arr --[[ : { [integer]: number } ]], vs_arr --[[ : { [integer]: number } ]])
  return setmetatable({ _t = ts_arr, _v = vs_arr }, Series)
end

-- append a (t, v) point; t must be >= last t.
function Series:push(t, v)
  local n = #self._t
  if n > 0 and t < self._t[n] then
    return nil, "time series: push out of order: t=" .. tostring(t) ..
      " < last t=" .. tostring(self._t[n])
  end
  n = n + 1
  self._t[n] = t
  self._v[n] = v
  return true
end

function Series:len()
  return #self._t
end

-- Exact or interpolated lookup.
-- interp = nil → exact (returns nil if not found)
-- interp = "linear" → linearly interpolate between neighbours
function Series:at(t, interp)
  local times = self._t
  local vals  = self._v
  local i = bisect_le(times, t)
  -- exact hit
  if i > 0 and times[i] == t then return vals[i] end
  if not interp then return nil end
  -- linear interpolation
  if i == 0 or i >= #times then return nil end
  local t0, t1 = times[i], times[i + 1]
  local v0, v1 = vals[i],  vals[i + 1]
  local frac = (t - t0) / (t1 - t0)
  return v0 + frac * (v1 - v0)
end

-- Returns array of {t, v} pairs where t0 <= t <= t1.
function Series:range(t0, t1)
  local times = self._t
  local vals  = self._v
  local lo = bisect_ge(times, t0)
  local hi = bisect_le(times, t1)
  local out = {}
  for i = lo, hi do
    out[#out + 1] = { times[i], vals[i] }
  end
  return out
end

-- Statistics over an optional time window [t0, t1].
-- Returns {min, max, mean, sum, count, stddev, first, last}
function Series:stats(t0, t1)
  local times = self._t
  local vals  = self._v
  local lo = 1
  local hi = #times
  if t0 ~= nil then
    lo = bisect_ge(times, t0)
    hi = bisect_le(times, t1)
  end
  local lo_ = lo --[[:! integer]]
  local hi_ = hi --[[:! integer]]
  local n = hi_ - lo_ + 1
  if n <= 0 then
    return { min=nil, max=nil, mean=nil, sum=nil, count=0,
             stddev=nil, first=nil, last=nil }
  end
  local s  = 0
  local mn = huge
  local mx = -huge
  for i = lo_, hi_ do
    local v = vals[i]
    s = s + v
    if v < mn then mn = v end
    if v > mx then mx = v end
  end
  local mean = s / n
  -- two-pass stddev
  local sq = 0
  for i = lo_, hi_ do
    local d = vals[i] - mean
    sq = sq + d * d
  end
  local stddev = (n > 1) and sqrt(sq / (n - 1)) or 0
  return {
    min    = mn,
    max    = mx,
    mean   = mean,
    sum    = s,
    count  = n,
    stddev = stddev,
    first  = vals[lo_],
    last   = vals[hi_],
  }
end

-- Resample into fixed-width buckets of width `interval`.
-- agg = "mean"|"sum"|"min"|"max"|"last"|"first"|"count"
function Series:resample(interval, agg)
  agg = agg or "mean"
  local times = self._t
  local vals  = self._v
  local n = #times
  if n == 0 then return new_series() end
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  local bucket_t = nil
  local bucket_v = {} --: { [integer]: number }
  for i = 1, n do
    local t = times[i]
    local b = math.floor(t / interval) * interval
    if b ~= bucket_t then
      if bucket_t ~= nil then
        local av = aggregate(bucket_v, agg)
        if av ~= nil then
          ot[#ot + 1] = bucket_t
          ov[#ov + 1] = av
        end
      end
      bucket_t = b
      bucket_v = { vals[i] }
    else
      bucket_v[#bucket_v + 1] = vals[i]
    end
  end
  -- flush last bucket
  if bucket_t ~= nil and #bucket_v > 0 then
    local av = aggregate(bucket_v, agg)
    if av ~= nil then
      ot[#ot + 1] = bucket_t
      ov[#ov + 1] = av
    end
  end
  return series_from(ot, ov)
end

-- Rolling window of n points, aggregated by agg.
function Series:rolling(n, agg)
  agg = agg or "mean"
  local times = self._t
  local vals  = self._v
  local len = #times
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  for i = n, len do
    local window = {}
    for j = i - n + 1, i do
      window[#window + 1] = vals[j]
    end
    local av = aggregate(window, agg)
    if av ~= nil then
      ot[#ot + 1] = times[i]
      ov[#ov + 1] = av
    end
  end
  return series_from(ot, ov)
end

-- LTTB (Largest-Triangle-Three-Buckets) downsampling.
-- Returns a new series with at most max_points points.
function Series:downsample(max_points)
  local times = self._t
  local vals  = self._v
  local n = #times
  if n <= max_points then
    -- return a shallow copy
    local ot = {} --: { [integer]: number }
    local ov = {} --: { [integer]: number }
    for i = 1, n do ot[i] = times[i]; ov[i] = vals[i] end
    return series_from(ot, ov)
  end
  if max_points < 3 then
    -- just return first and last
    return series_from({ times[1], times[n] }, { vals[1], vals[n] })
  end
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  -- always keep first point
  ot[1] = times[1]; ov[1] = vals[1]
  -- bucket the middle points
  local bucket_size = (n - 2) / (max_points - 2)
  local a = 1  -- index of last selected point
  for i = 1, max_points - 2 do
    -- next bucket range
    local b_start = math.floor((i - 1) * bucket_size) + 2
    local b_end   = math.floor(i       * bucket_size) + 1
    if b_end > n - 1 then b_end = n - 1 end
    -- average of look-ahead bucket (for triangle area)
    local c_start = math.floor(i * bucket_size) + 2
    local c_end   = math.floor((i + 1) * bucket_size) + 1
    if c_end > n - 1 then c_end = n - 1 end
    if c_start > n - 1 then c_start = n - 1 end
    local avg_t = 0 --: number
    local avg_v = 0 --: number
    local cnt = 0
    for j = c_start, c_end do
      avg_t = avg_t + times[j]
      avg_v = avg_v + vals[j]
      cnt   = cnt + 1
    end
    if cnt > 0 then avg_t = avg_t / cnt; avg_v = avg_v / cnt end
    -- find point in bucket that forms largest triangle with a and avg
    local best_area = -1
    local best_idx  = b_start
    local ax, ay = times[a], vals[a]
    for j = b_start, b_end do
      -- triangle area × 2
      local area = math.abs(
        (ax - avg_t) * (vals[j] - ay) -
        (ax - times[j]) * (avg_v - ay)
      )
      if area > best_area then
        best_area = area
        best_idx  = j
      end
    end
    ot[#ot + 1] = times[best_idx]
    ov[#ov + 1] = vals[best_idx]
    a = best_idx
  end
  -- always keep last point
  ot[#ot + 1] = times[n]; ov[#ov + 1] = vals[n]
  return series_from(ot, ov)
end

-- Min-max normalise values to [0, 1].
function Series:normalize()
  local times = self._t
  local vals  = self._v
  local n = #times
  if n == 0 then return new_series() end
  local mn, mx = huge, -huge
  for i = 1, n do
    if vals[i] < mn then mn = vals[i] end
    if vals[i] > mx then mx = vals[i] end
  end
  local range = mx - mn
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  for i = 1, n do
    ot[i] = times[i]
    ov[i] = (range == 0) and 0 or (vals[i] - mn) / range
  end
  return series_from(ot, ov)
end

-- First differences: v[i] - v[i-1]. Returns series of length n-1.
function Series:diff()
  local times = self._t
  local vals  = self._v
  local n = #times
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  for i = 2, n do
    ot[#ot + 1] = times[i]
    ov[#ov + 1] = vals[i] - vals[i - 1]
  end
  return series_from(ot, ov)
end

-- Cumulative sum.
function Series:cumsum()
  local times = self._t
  local vals  = self._v
  local n = #times
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  local s = 0
  for i = 1, n do
    s = s + vals[i]
    ot[i] = times[i]
    ov[i] = s
  end
  return series_from(ot, ov)
end

-- Apply fn to every value, return new series.
function Series:apply(fn)
  local times = self._t
  local vals  = self._v
  local n = #times
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  for i = 1, n do
    ot[i] = times[i]
    ov[i] = fn(vals[i])
  end
  return series_from(ot, ov)
end

-- Outlier detection.
-- opts.method = "zscore" (default) | "iqr"
-- opts.threshold = number (default 3 for zscore, 1.5 for iqr)
-- Returns array of {t, v, score}.
function Series:outliers(opts)
  opts = opts or {}
  local method = opts.method or "zscore"
  local times = self._t
  local vals  = self._v
  local n = #times
  local result = {}
  if n == 0 then return result end

  if method == "zscore" then
    local threshold = opts.threshold or 3
    -- compute mean and stddev
    local s = 0
    for i = 1, n do s = s + vals[i] end
    local mean = s / n
    local sq = 0
    for i = 1, n do local d = vals[i] - mean; sq = sq + d * d end
    local sd = (n > 1) and sqrt(sq / (n - 1)) or 0
    if sd == 0 then return result end
    for i = 1, n do
      local z = math.abs(vals[i] - mean) / sd
      if z >= threshold then
        result[#result + 1] = { times[i], vals[i], z,
          t = times[i], v = vals[i], z_score = z, score = z }
      end
    end

  elseif method == "iqr" then
    local threshold_raw = opts.threshold or 1.5
    local threshold = threshold_raw --[[:! number]]
    -- sort values to find quartiles
    local sorted = {} --: { [integer]: number }
    for i = 1, n do sorted[i] = vals[i] end
    table.sort(sorted)
    local q1 = sorted[math.floor(n * 0.25) + 1 --[[:! integer]]] or sorted[1]
    local q3 = sorted[math.floor(n * 0.75) + 1 --[[:! integer]]] or sorted[n]
    local iqr = q3 - q1
    local lo_fence = q1 - threshold * iqr
    local hi_fence = q3 + threshold * iqr
    for i = 1, n do
      local v = vals[i]
      if v < lo_fence or v > hi_fence then
        local score = (v > hi_fence) and (v - hi_fence) / iqr
                                      or  (lo_fence - v) / iqr
        result[#result + 1] = { times[i], v, score,
          t = times[i], v = v, score = score, z_score = score }
      end
    end
  else
    return nil, "time series: unknown outlier method: " .. tostring(method)
  end
  return result
end

-- ── module-level functions ────────────────────────────────────────────────────

-- Create a new empty series.
function M.series()
  return new_series()
end

-- Merge two series by applying fn(v1, v2) at each timestamp present in both.
-- Only timestamps present in BOTH series are included.
function M.merge(s1, s2, fn)
  local t1, v1 = s1._t, s1._v
  local t2, v2 = s2._t, s2._v
  local ot = {} --: { [integer]: number }
  local ov = {} --: { [integer]: number }
  local i, j = 1, 1
  local n1, n2 = #t1, #t2
  while i <= n1 and j <= n2 do
    if t1[i] == t2[j] then
      ot[#ot + 1] = t1[i]
      ov[#ov + 1] = fn(v1[i], v2[j])
      i = i + 1; j = j + 1
    elseif t1[i] < t2[j] then
      i = i + 1
    else
      j = j + 1
    end
  end
  return series_from(ot, ov)
end

-- Align two series to a common set of timestamps.
-- opts.method = "linear" (default) | "exact"
-- Uses the union of timestamps from both series.
-- Returns {s1_aligned, s2_aligned}.
function M.align(s1 --[[ : { at: (number, unknown) -> number | nil, _t: { [integer]: number }, _v: { [integer]: number }, ... } ]], s2 --[[ : { at: (number, unknown) -> number | nil, _t: { [integer]: number }, _v: { [integer]: number }, ... } ]], opts)
  opts = opts or {}
  local interp = (opts.method == nil or opts.method == "linear") and "linear" or nil
  -- collect union of timestamps
  local t1, t2 = s1._t, s2._t
  local n1, n2 = #t1, #t2
  local seen = {}
  local all_t = {}
  for i = 1, n1 do
    if not seen[t1[i]] then
      seen[t1[i]] = true
      all_t[#all_t + 1] = t1[i]
    end
  end
  for i = 1, n2 do
    if not seen[t2[i]] then
      seen[t2[i]] = true
      all_t[#all_t + 1] = t2[i]
    end
  end
  table.sort(all_t)
  local m = #all_t
  local a1t = {} --: { [integer]: number }
  local a1v = {} --: { [integer]: number }
  local a2t = {} --: { [integer]: number }
  local a2v = {} --: { [integer]: number }
  for i = 1, m do
    local t = all_t[i]
    local s1_any = s1 --[[: unknown]]
    local s2_any = s2 --[[: unknown]]
    local v1 = s1_any:at(t, interp)
    local v2 = s2_any:at(t, interp)
    if v1 ~= nil and v2 ~= nil then
      a1t[#a1t + 1] = t; a1v[#a1v + 1] = v1
      a2t[#a2t + 1] = t; a2v[#a2v + 1] = v2
    end
  end
  return { series_from(a1t, a1v), series_from(a2t, a2v) }
end

return M
