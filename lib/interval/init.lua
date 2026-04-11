if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Interval ────────────────────────────────────────────────────────────────

local Interval = {}
Interval.__index = Interval

--: (lo: number, hi: number) -> Interval
function M.new(lo, hi)
  return setmetatable({ lo = lo, hi = hi }, Interval)
end

--: () -> number
function Interval:get_lo() return self.lo end

--: () -> number
function Interval:get_hi() return self.hi end

--: () -> number
function Interval:length()
  local len = self.hi - self.lo
  if len < 0 then return 0 end
  return len
end

--: () -> boolean
function Interval:empty()
  return self.lo > self.hi
end

--: (other: Interval) -> boolean
function Interval:eq(other)
  return self.lo == other.lo and self.hi == other.hi
end

Interval.__eq = Interval.eq

--: (point: number) -> boolean
function Interval:contains(point)
  return point >= self.lo and point <= self.hi
end

--: (other: Interval) -> boolean
function Interval:contains_interval(other)
  return other.lo >= self.lo and other.hi <= self.hi
end

--: (other: Interval) -> boolean
function Interval:overlaps(other)
  return self.lo <= other.hi and other.lo <= self.hi
end

--: (other: Interval) -> Interval | nil, string
function Interval:union(other)
  if not self:overlaps(other) and not (self.hi == other.lo or other.hi == self.lo) then
    return nil, "intervals do not overlap or touch"
  end
  local lo = self.lo < other.lo and self.lo or other.lo
  local hi = self.hi > other.hi and self.hi or other.hi
  return M.new(lo, hi)
end

--: (other: Interval) -> Interval
function Interval:intersection(other)
  local lo = self.lo > other.lo and self.lo or other.lo
  local hi = self.hi < other.hi and self.hi or other.hi
  return M.new(lo, hi)
end

function Interval:__tostring()
  return "[" .. self.lo .. ", " .. self.hi .. "]"
end

-- ── Collection operations ───────────────────────────────────────────────────

--: (intervals: { Interval }) -> { Interval }
function M.merge(intervals)
  local n = #intervals
  if n == 0 then return {} end
  -- copy and sort by lo
  local sorted = {}
  for i = 1, n do sorted[i] = intervals[i] end
  table.sort(sorted, function(a, b) return a.lo < b.lo end)
  local result = { M.new(sorted[1].lo, sorted[1].hi) }
  local ri = 1
  for i = 2, n do
    local cur = result[ri]
    local s = sorted[i]
    if s.lo <= cur.hi then
      -- overlapping or touching — extend
      if s.hi > cur.hi then
        cur.hi = s.hi
      end
    else
      ri = ri + 1
      result[ri] = M.new(s.lo, s.hi)
    end
  end
  return result
end

--: (intervals: { Interval }, lo: number, hi: number) -> { Interval }
function M.gaps(intervals, lo, hi)
  local merged = M.merge(intervals)
  local result = {}
  local ri = 0
  local cursor = lo
  for i = 1, #merged do
    local iv = merged[i]
    -- skip intervals entirely before cursor
    if iv.hi < cursor then goto continue end
    -- clamp to range
    local iv_lo = iv.lo > lo and iv.lo or lo
    local iv_hi = iv.hi < hi and iv.hi or hi
    if iv_lo > cursor then
      ri = ri + 1
      result[ri] = M.new(cursor, iv_lo)
    end
    if iv_hi > cursor then
      cursor = iv_hi
    end
    if cursor >= hi then break end
    ::continue::
  end
  if cursor < hi then
    ri = ri + 1
    result[ri] = M.new(cursor, hi)
  end
  return result
end

--: (intervals: { Interval }) -> Interval | nil, string
function M.span(intervals)
  local n = #intervals
  if n == 0 then return nil, "empty interval list" end
  local lo = intervals[1].lo
  local hi = intervals[1].hi
  for i = 2, n do
    if intervals[i].lo < lo then lo = intervals[i].lo end
    if intervals[i].hi > hi then hi = intervals[i].hi end
  end
  return M.new(lo, hi)
end

-- ── Interval tree (sorted array with max-endpoint annotation) ───────────────

local Tree = {}
Tree.__index = Tree

--: () -> Tree
function M.tree()
  return setmetatable({
    entries = {},  -- sorted by lo; each entry: { iv, data, max_hi }
    n = 0,
  }, Tree)
end

-- binary search: find first entry with lo >= val
local function lower_bound(entries, n, val)
  local lo, hi = 1, n
  local result = n + 1
  while lo <= hi do
    local mid = lo + math.floor((hi - lo) / 2)
    if entries[mid][1].lo >= val then
      result = mid
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return result
end

-- recompute max_hi from position i to end
local function recompute_max(entries, n, from)
  if n == 0 then return end
  if from > n then from = n end
  -- max_hi[i] = max(entries[i].hi, max_hi[i+1])
  entries[n][3] = entries[n][1].hi
  for i = n - 1, from, -1 do
    local h = entries[i][1].hi
    local next_max = entries[i + 1][3]
    entries[i][3] = h > next_max and h or next_max
  end
end

--: (iv: Interval, data: unknown) -> nil
function Tree:insert(iv, data)
  local entries = self.entries
  local n = self.n
  local pos = lower_bound(entries, n, iv.lo)
  -- shift right
  for i = n, pos, -1 do
    entries[i + 1] = entries[i]
  end
  entries[pos] = { iv, data, iv.hi }
  self.n = n + 1
  recompute_max(entries, self.n, pos)
end

--: (iv: Interval) -> boolean
function Tree:remove(iv)
  local entries = self.entries
  local n = self.n
  for i = 1, n do
    local e = entries[i]
    if e[1].lo == iv.lo and e[1].hi == iv.hi then
      -- shift left
      for j = i, n - 1 do
        entries[j] = entries[j + 1]
      end
      entries[n] = nil
      self.n = n - 1
      if self.n > 0 then
        recompute_max(entries, self.n, i > self.n and self.n or i)
      end
      return true
    end
  end
  return false
end

--: (point: number) -> { { Interval, unknown } }
function Tree:query_point(point)
  local entries = self.entries
  local n = self.n
  local result = {}
  local ri = 0
  for i = 1, n do
    local e = entries[i]
    -- if max_hi < point, no interval from here onward can contain point
    -- (only valid if entries are sorted by lo and max is suffix-max)
    -- but since lo is sorted ascending, if lo > point we can stop
    if e[1].lo > point then break end
    if point <= e[1].hi then
      ri = ri + 1
      result[ri] = { e[1], e[2] }
    end
  end
  return result
end

--: (query: Interval) -> { { Interval, unknown } }
function Tree:query_overlap(query)
  local entries = self.entries
  local n = self.n
  local result = {}
  local ri = 0
  for i = 1, n do
    local e = entries[i]
    -- early termination: if lo > query.hi, no more overlaps possible
    if e[1].lo > query.hi then break end
    -- check overlap: e.lo <= query.hi (guaranteed by above) and e.hi >= query.lo
    if e[1].hi >= query.lo then
      ri = ri + 1
      result[ri] = { e[1], e[2] }
    end
  end
  return result
end

--: () -> number
function Tree:size()
  return self.n
end

--: () -> { { Interval, unknown } }
function Tree:all()
  local entries = self.entries
  local n = self.n
  local result = {}
  for i = 1, n do
    result[i] = { entries[i][1], entries[i][2] }
  end
  return result
end

return M
