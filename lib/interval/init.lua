-- lib/interval/init.lua
-- Interval arithmetic: closed, open, and half-open numeric intervals.
-- Supports containment, set operations, clamping, iteration, and interval sets.
-- Also provides merge/gaps/span utilities and a sorted-array interval tree.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor = math.floor

-- ---------------------------------------------------------------------------
-- Interval object
-- ---------------------------------------------------------------------------

local Interval = {}
Interval.__index = Interval

-- Create a new interval.
-- lo_closed: whether the low end is closed (default true)
-- hi_closed: whether the high end is closed (default true)
function M.new(lo, hi, lo_closed, hi_closed)
  if lo_closed == nil then lo_closed = true end
  if hi_closed == nil then hi_closed = true end
  return setmetatable({
    lo = lo, hi = hi,
    lo_closed = lo_closed, hi_closed = hi_closed,
  }, Interval)
end

-- Low bound.
function Interval:low() return self.lo end
-- Alias used by legacy code.
function Interval:get_lo() return self.lo end

-- High bound.
function Interval:high() return self.hi end
-- Alias used by legacy code.
function Interval:get_hi() return self.hi end

-- Size / width: high - low (ignoring openness).
function Interval:size() return self.hi - self.lo end

-- Alias: length (clamps to 0 for inverted intervals).
function Interval:length()
  local len = self.hi - self.lo
  return len < 0 and 0 or len
end

-- Midpoint.
function Interval:midpoint() return (self.lo + self.hi) / 2 end

-- True if both ends are closed.
function Interval:is_closed() return self.lo_closed and self.hi_closed end

-- True if both ends are open.
function Interval:is_open() return not self.lo_closed and not self.hi_closed end

-- True if the interval is empty.
-- lo > hi is always empty. lo == hi is empty unless both ends are closed.
function Interval:is_empty()
  if self.lo > self.hi then return true end
  if self.lo == self.hi then return not (self.lo_closed and self.hi_closed) end
  return false
end

-- Alias for legacy code.
function Interval:empty() return self:is_empty() end

-- True if value v is contained in the interval.
function Interval:contains(v)
  if self:is_empty() then return false end
  local lo_ok = self.lo_closed and v >= self.lo or v > self.lo
  local hi_ok = self.hi_closed and v <= self.hi or v < self.hi
  return lo_ok and hi_ok
end

-- True if other interval is entirely within self.
function Interval:contains_interval(other)
  if self:is_empty() then return false end
  if other:is_empty() then return true end
  -- low bound
  local lo_ok
  if other.lo > self.lo then
    lo_ok = true
  elseif other.lo == self.lo then
    lo_ok = self.lo_closed or not other.lo_closed
  else
    lo_ok = false
  end
  if not lo_ok then return false end
  -- high bound
  local hi_ok
  if other.hi < self.hi then
    hi_ok = true
  elseif other.hi == self.hi then
    hi_ok = self.hi_closed or not other.hi_closed
  else
    hi_ok = false
  end
  return hi_ok
end

-- True if self and other share at least one point.
function Interval:overlaps(other)
  if self:is_empty() or other:is_empty() then return false end
  if self.hi < other.lo then return false end
  if other.hi < self.lo then return false end
  if self.hi == other.lo then return self.hi_closed and other.lo_closed end
  if other.hi == self.lo then return other.hi_closed and self.lo_closed end
  return true
end

-- Intersection of self and other. Returns an interval (possibly empty).
function Interval:intersection(other)
  local lo, lo_closed
  if self.lo > other.lo then
    lo, lo_closed = self.lo, self.lo_closed
  elseif other.lo > self.lo then
    lo, lo_closed = other.lo, other.lo_closed
  else
    lo, lo_closed = self.lo, self.lo_closed and other.lo_closed
  end
  local hi, hi_closed
  if self.hi < other.hi then
    hi, hi_closed = self.hi, self.hi_closed
  elseif other.hi < self.hi then
    hi, hi_closed = other.hi, other.hi_closed
  else
    hi, hi_closed = self.hi, self.hi_closed and other.hi_closed
  end
  return M.new(lo, hi, lo_closed, hi_closed)
end

-- Union of self and other.
-- If they overlap or touch (at a closed endpoint), returns a single Interval.
-- Otherwise returns an IntervalSet containing both.
function Interval:union(other)
  local touches = self:overlaps(other)
  if not touches then
    -- Adjacent: touching at one closed endpoint counts as touching.
    if self.hi == other.lo and (self.hi_closed or other.lo_closed) then
      touches = true
    elseif other.hi == self.lo and (other.hi_closed or self.lo_closed) then
      touches = true
    end
  end
  if self:is_empty() then return other end
  if other:is_empty() then return self end
  if touches then
    local lo, lo_closed
    if self.lo < other.lo then
      lo, lo_closed = self.lo, self.lo_closed
    elseif other.lo < self.lo then
      lo, lo_closed = other.lo, other.lo_closed
    else
      lo, lo_closed = self.lo, self.lo_closed or other.lo_closed
    end
    local hi, hi_closed
    if self.hi > other.hi then
      hi, hi_closed = self.hi, self.hi_closed
    elseif other.hi > self.hi then
      hi, hi_closed = other.hi, other.hi_closed
    else
      hi, hi_closed = self.hi, self.hi_closed or other.hi_closed
    end
    return M.new(lo, hi, lo_closed, hi_closed)
  end
  -- Non-overlapping: return a set.
  return M.set({ self, other })
end

-- Difference: points in self but not in other.
-- Returns an Interval or IntervalSet.
function Interval:difference(other)
  local inter = self:intersection(other)
  if inter:is_empty() then return self end
  local results = {}
  -- Left part: self.lo up to inter.lo
  if self.lo < inter.lo or (self.lo == inter.lo and self.lo_closed and not inter.lo_closed) then
    -- Right edge of left part is open if inter.lo_closed, closed if inter.lo_open.
    results[#results + 1] = M.new(self.lo, inter.lo, self.lo_closed, not inter.lo_closed)
  end
  -- Right part: from inter.hi to self.hi
  if self.hi > inter.hi or (self.hi == inter.hi and self.hi_closed and not inter.hi_closed) then
    results[#results + 1] = M.new(inter.hi, self.hi, not inter.hi_closed, self.hi_closed)
  end
  if #results == 0 then
    -- self was entirely consumed
    return M.new(self.lo, self.lo, false, false)
  elseif #results == 1 then
    return results[1]
  else
    return M.set(results)
  end
end

-- Shift interval by offset.
function Interval:shift(offset)
  return M.new(self.lo + offset, self.hi + offset, self.lo_closed, self.hi_closed)
end

-- Scale interval by factor around origin 0.
function Interval:scale(factor)
  if factor >= 0 then
    return M.new(self.lo * factor, self.hi * factor, self.lo_closed, self.hi_closed)
  else
    -- Negative factor reverses the interval.
    return M.new(self.hi * factor, self.lo * factor, self.hi_closed, self.lo_closed)
  end
end

-- Clamp value v into [lo, hi] (always treats bounds as closed for clamping).
function Interval:clamp(v)
  if v < self.lo then return self.lo end
  if v > self.hi then return self.hi end
  return v
end

-- True if self is entirely before other (no shared point).
function Interval:before(other)
  if self:is_empty() or other:is_empty() then return false end
  if self.hi < other.lo then return true end
  if self.hi == other.lo then return not (self.hi_closed and other.lo_closed) end
  return false
end

-- True if self is entirely after other (no shared point).
function Interval:after(other)
  return other:before(self)
end

-- Equality: two empty intervals are equal; otherwise all four fields must match.
function Interval:eq(other)
  if self:is_empty() and other:is_empty() then return true end
  return self.lo == other.lo and self.hi == other.hi
    and self.lo_closed == other.lo_closed and self.hi_closed == other.hi_closed
end

function Interval:__eq(other)
  return self:eq(other)
end

function Interval:__tostring()
  local l = self.lo_closed and "[" or "("
  local r = self.hi_closed and "]" or ")"
  return l .. tostring(self.lo) .. ", " .. tostring(self.hi) .. r
end

M.Interval = Interval

-- ---------------------------------------------------------------------------
-- Integer range (step iteration)
-- ---------------------------------------------------------------------------

local Range = {}
Range.__index = Range

-- Create an integer range from lo to hi with given step (default 1).
function M.range(lo, hi, step)
  step = step or 1
  return setmetatable({ lo = lo, hi = hi, step = step }, Range)
end

-- Stateless iterator over values lo, lo+step, ... while <= hi.
function Range:iter()
  local v = self.lo
  local hi = self.hi
  local step = self.step
  return function()
    if v <= hi then
      local cur = v
      v = v + step
      return cur
    end
  end
end

-- Collect all values into a table.
function Range:to_table()
  local t = {}
  for v in self:iter() do t[#t + 1] = v end
  return t
end

M.Range = Range

-- ---------------------------------------------------------------------------
-- Interval set
-- ---------------------------------------------------------------------------

local Set = {}
Set.__index = Set

-- Create an interval set from a list of intervals.
-- Call :normalize() to sort and merge overlapping intervals.
function M.set(intervals)
  local s = setmetatable({ intervals = {}, n = 0 }, Set)
  for i = 1, #intervals do
    s.intervals[i] = intervals[i]
    s.n = i
  end
  return s
end

-- Sort and merge overlapping or adjacent (touching at a closed endpoint) intervals.
function Set:normalize()
  local ivs = self.intervals
  local n = self.n
  if n == 0 then return self end
  table.sort(ivs, function(a, b)
    if a.lo ~= b.lo then return a.lo < b.lo end
    return a.lo_closed and not b.lo_closed
  end)
  local merged = { ivs[1] }
  for i = 2, n do
    local prev = merged[#merged]
    local cur = ivs[i]
    local touches = prev:overlaps(cur)
    if not touches then
      if prev.hi == cur.lo and (prev.hi_closed or cur.lo_closed) then
        touches = true
      end
    end
    if touches then
      local u = prev:union(cur)
      -- union of two overlapping Intervals returns an Interval, not a Set
      merged[#merged] = u
    else
      merged[#merged + 1] = cur
    end
  end
  return M.set(merged)
end

-- True if value v is in any interval of the set.
function Set:contains(v)
  for i = 1, self.n do
    if self.intervals[i]:contains(v) then return true end
  end
  return false
end

-- True if other interval is contained within any single interval of the set.
function Set:contains_interval(other)
  for i = 1, self.n do
    if self.intervals[i]:contains_interval(other) then return true end
  end
  return false
end

-- Union of two sets: combine all intervals, normalize.
function Set:union(other)
  local ivs = {}
  for i = 1, self.n do ivs[#ivs + 1] = self.intervals[i] end
  for i = 1, other.n do ivs[#ivs + 1] = other.intervals[i] end
  return M.set(ivs):normalize()
end

-- Intersection of two sets.
function Set:intersection(other)
  local ivs = {}
  for i = 1, self.n do
    for j = 1, other.n do
      local inter = self.intervals[i]:intersection(other.intervals[j])
      if not inter:is_empty() then ivs[#ivs + 1] = inter end
    end
  end
  return M.set(ivs):normalize()
end

function Set:__tostring()
  local parts = {}
  for i = 1, self.n do parts[i] = tostring(self.intervals[i]) end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

M.Set = Set

-- ---------------------------------------------------------------------------
-- Collection utilities (preserved from original implementation)
-- ---------------------------------------------------------------------------

-- Merge a list of intervals: sort, then coalesce touching/overlapping.
-- Returns a plain table of non-overlapping Intervals sorted by lo.
-- NOTE: uses simple closed-interval semantics (lo/hi comparison only),
-- matching the original implementation for backward compatibility.
function M.merge(intervals)
  local n = #intervals
  if n == 0 then return {} end
  local sorted = {}
  for i = 1, n do sorted[i] = intervals[i] end
  table.sort(sorted, function(a, b) return a.lo < b.lo end)
  local result = { M.new(sorted[1].lo, sorted[1].hi) }
  local ri = 1
  for i = 2, n do
    local cur = result[ri]
    local s = sorted[i]
    if s.lo <= cur.hi then
      if s.hi > cur.hi then cur.hi = s.hi end
    else
      ri = ri + 1
      result[ri] = M.new(s.lo, s.hi)
    end
  end
  return result
end

-- Find gaps in coverage of [lo, hi] not covered by any of the given intervals.
function M.gaps(intervals, lo, hi)
  local merged = M.merge(intervals)
  local result = {}
  local ri = 0
  local cursor = lo
  for i = 1, #merged do
    local iv = merged[i]
    if iv.hi < cursor then goto continue end
    local iv_lo = iv.lo > lo and iv.lo or lo
    local iv_hi = iv.hi < hi and iv.hi or hi
    if iv_lo > cursor then
      ri = ri + 1
      result[ri] = M.new(cursor, iv_lo)
    end
    if iv_hi > cursor then cursor = iv_hi end
    if cursor >= hi then break end
    ::continue::
  end
  if cursor < hi then
    ri = ri + 1
    result[ri] = M.new(cursor, hi)
  end
  return result
end

-- Bounding interval spanning all given intervals.
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

-- ---------------------------------------------------------------------------
-- Interval tree (sorted array with max-endpoint annotation)
-- ---------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

function M.tree()
  return setmetatable({ entries = {}, n = 0 }, Tree)
end

-- Binary search: first entry index with lo >= val.
local function lower_bound(entries, n, val)
  local lo, hi = 1, n
  local result = n + 1
  while lo <= hi do
    local mid = lo + floor((hi - lo) / 2)
    if entries[mid][1].lo >= val then
      result = mid
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return result
end

-- Recompute max_hi suffix from position `from` to end.
local function recompute_max(entries, n, from)
  if n == 0 then return end
  if from > n then from = n end
  entries[n][3] = entries[n][1].hi
  for i = n - 1, from, -1 do
    local h = entries[i][1].hi
    local nm = entries[i + 1][3]
    entries[i][3] = h > nm and h or nm
  end
end

function Tree:insert(iv, data)
  local entries = self.entries
  local n = self.n
  local pos = lower_bound(entries, n, iv.lo)
  for i = n, pos, -1 do entries[i + 1] = entries[i] end
  entries[pos] = { iv, data, iv.hi }
  self.n = n + 1
  recompute_max(entries, self.n, pos)
end

function Tree:remove(iv)
  local entries = self.entries
  local n = self.n
  for i = 1, n do
    local e = entries[i]
    if e[1].lo == iv.lo and e[1].hi == iv.hi then
      for j = i, n - 1 do entries[j] = entries[j + 1] end
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

function Tree:query_point(point)
  local entries = self.entries
  local n = self.n
  local result = {}
  local ri = 0
  for i = 1, n do
    local e = entries[i]
    if e[1].lo > point then break end
    if point <= e[1].hi then
      ri = ri + 1
      result[ri] = { e[1], e[2] }
    end
  end
  return result
end

function Tree:query_overlap(query)
  local entries = self.entries
  local n = self.n
  local result = {}
  local ri = 0
  for i = 1, n do
    local e = entries[i]
    if e[1].lo > query.hi then break end
    if e[1].hi >= query.lo then
      ri = ri + 1
      result[ri] = { e[1], e[2] }
    end
  end
  return result
end

function Tree:size() return self.n end

function Tree:all()
  local entries = self.entries
  local n = self.n
  local result = {}
  for i = 1, n do result[i] = { entries[i][1], entries[i][2] } end
  return result
end

M.Tree = Tree

return M
