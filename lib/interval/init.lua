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

--:: Interval = { lo: number, hi: number, lo_closed: boolean, hi_closed: boolean, is_empty: (self: Interval) -> boolean, overlaps: (self: Interval, Interval) -> boolean, intersection: (self: Interval, Interval) -> Interval, union: (self: Interval, Interval) -> Interval, contains: (self: Interval, number) -> boolean, before: (self: Interval, Interval) -> boolean, eq: (self: Interval, Interval) -> boolean, mul: (self: Interval, Interval) -> Interval, add: (self: Interval, Interval) -> Interval, sub: (self: Interval, Interval) -> Interval, div: (self: Interval, Interval) -> (Interval | nil, string | nil) }

local floor = math.floor
local huge = math.huge
--: (number, number, number, number) -> number
local min4 = function(a, b, c, d)
  local m = a
  if b < m then m = b end
  if c < m then m = c end
  if d < m then m = d end
  return m
end
--: (number, number, number, number) -> number
local max4 = function(a, b, c, d)
  local m = a
  if b > m then m = b end
  if c > m then m = c end
  if d > m then m = d end
  return m
end

-- ---------------------------------------------------------------------------
-- Interval object
-- ---------------------------------------------------------------------------

local Interval = {}
-- Use a function __index so that methods named 'lo', 'hi', etc. take priority
-- over the identically-named instance fields when called as methods.
Interval.__index = function(t, k)
  local m = rawget(Interval, k)
  if m ~= nil then return m end
  return rawget(t, k)
end

-- Create a new interval.
-- lo_closed: whether the low end is closed (default true)
-- hi_closed: whether the high end is closed (default true)
--: (number, number, boolean | nil, boolean | nil) -> Interval
function M.new(lo, hi, lo_closed, hi_closed)
  if lo_closed == nil then lo_closed = true end
  if hi_closed == nil then hi_closed = true end
  local raw = setmetatable({
    lo = lo, hi = hi,
    lo_closed = lo_closed, hi_closed = hi_closed,
  }, Interval) --[[: unknown]]
  return raw --[[:! Interval]]
end

-- Named constructors.
-- M.closed(a, b)   -> [a, b]
function M.closed(a, b)  return M.new(a, b, true,  true)  end
-- M.open(a, b)     -> (a, b)
function M.open(a, b)    return M.new(a, b, false, false) end
-- M.lopen(a, b)    -> (a, b]   left-open, right-closed
function M.lopen(a, b)   return M.new(a, b, false, true)  end
-- M.ropen(a, b)    -> [a, b)   left-closed, right-open
function M.ropen(a, b)   return M.new(a, b, true,  false) end
-- M.point(x)       -> [x, x]
function M.point(x)      return M.new(x, x, true,  true)  end
-- M.empty()        -> empty interval (lo > hi)
function M.empty()       return M.new(1, 0, true,  true)  end
-- M.infinite()     -> (-inf, +inf)
function M.infinite()    return M.new(-huge, huge, false, false) end

-- Low bound.
--: (Interval) -> number
function Interval:low() return self.lo end
-- Alias: lo() for API compatibility.
--: (Interval) -> number
function Interval:lo() return self.lo end
-- Alias used by legacy code.
--: (Interval) -> number
function Interval:get_lo() return self.lo end

-- High bound.
--: (Interval) -> number
function Interval:high() return self.hi end
-- Alias: hi() for API compatibility.
--: (Interval) -> number
function Interval:hi() return self.hi end
-- Alias used by legacy code.
--: (Interval) -> number
function Interval:get_hi() return self.hi end

-- True if the lower bound is open (not closed).
--: (Interval) -> boolean
function Interval:lo_open() return not self.lo_closed end
-- True if the upper bound is open (not closed).
--: (Interval) -> boolean
function Interval:hi_open() return not self.hi_closed end

-- Size / width: high - low (ignoring openness).
--: (Interval) -> number
function Interval:size() return self.hi - self.lo end

-- Alias: length (clamps to 0 for inverted intervals).
--: (Interval) -> number
function Interval:length()
  local len = self.hi - self.lo
  return len < 0 and 0 or len
end

-- Midpoint.
--: (Interval) -> number
function Interval:midpoint() return (self.lo + self.hi) / 2 end

-- True if both ends are closed.
--: (Interval) -> boolean
function Interval:is_closed() return (self.lo_closed and self.hi_closed) == true end

-- True if both ends are open.
--: (Interval) -> boolean
function Interval:is_open() return (not self.lo_closed and not self.hi_closed) == true end

-- True if the interval is empty.
-- lo > hi is always empty. lo == hi is empty unless both ends are closed.
--: (Interval) -> boolean
function Interval:is_empty()
  if self.lo > self.hi then return true end
  if self.lo == self.hi then return not (self.lo_closed and self.hi_closed) end
  return false
end

-- Alias for legacy code.
--: (Interval) -> boolean
function Interval:empty() return self:is_empty() end

-- True if value v is contained in the interval.
--: (Interval, number) -> boolean
function Interval:contains(v)
  if self:is_empty() then return false end
  local lo_ok = self.lo_closed and v >= self.lo or v > self.lo
  local hi_ok = self.hi_closed and v <= self.hi or v < self.hi
  return (lo_ok and hi_ok) == true
end

-- True if other interval is entirely within self.
--: (Interval, Interval) -> boolean
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
--: (Interval, Interval) -> boolean
function Interval:overlaps(other)
  if self:is_empty() or other:is_empty() then return false end
  if self.hi < other.lo then return false end
  if other.hi < self.lo then return false end
  if self.hi == other.lo then return (self.hi_closed and other.lo_closed) == true end
  if other.hi == self.lo then return (other.hi_closed and self.lo_closed) == true end
  return true
end

-- Intersection of self and other. Returns an interval (possibly empty).
--: (Interval, Interval) -> Interval
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
--: (Interval, Interval) -> Interval
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
--: (Interval, Interval) -> Interval
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

-- intersect: alias for intersection.
--: (Interval, Interval) -> Interval
function Interval:intersect(other)
  return self:intersection(other)
end

-- complement: returns a list of intervals covering (-inf,lo) and (hi,+inf).
-- Open/closed endpoints are inverted at the boundary.
-- Returns {} for an empty interval (complement is all of R, represented as one infinite interval).
--: (Interval) -> Interval[]
function Interval:complement()
  if self:is_empty() then
    return { M.new(-huge, huge, false, false) }
  end
  local result = {}
  if self.lo ~= -huge then
    result[#result + 1] = M.new(-huge, self.lo, false, not self.lo_closed)
  end
  if self.hi ~= huge then
    result[#result + 1] = M.new(self.hi, huge, not self.hi_closed, false)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Interval arithmetic
-- ---------------------------------------------------------------------------

-- [a,b] + [c,d] = [a+c, b+d]
-- Openness: open if either corresponding bound is open.
--: (Interval, Interval) -> Interval
function Interval:add(other)
  if self:is_empty() or other:is_empty() then return M.empty() end
  return M.new(
    self.lo + other.lo, self.hi + other.hi,
    self.lo_closed and other.lo_closed,
    self.hi_closed and other.hi_closed
  )
end

-- [a,b] - [c,d] = [a-d, b-c]
--: (Interval, Interval) -> Interval
function Interval:sub(other)
  if self:is_empty() or other:is_empty() then return M.empty() end
  return M.new(
    self.lo - other.hi, self.hi - other.lo,
    self.lo_closed and other.hi_closed,
    self.hi_closed and other.lo_closed
  )
end

-- [a,b] * [c,d] = [min(ac,ad,bc,bd), max(ac,ad,bc,bd)]
-- Openness: each endpoint is open if the contributing factor is open.
--: (Interval, Interval) -> Interval
function Interval:mul(other)
  if self:is_empty() or other:is_empty() then return M.empty() end
  local ac = self.lo * other.lo
  local ad = self.lo * other.hi
  local bc = self.hi * other.lo
  local bd = self.hi * other.hi
  local lo = min4(ac, ad, bc, bd)
  local hi = max4(ac, ad, bc, bd)
  -- Determine openness conservatively: open if any involved bound is open.
  -- We pick the pair of bounds that achieved lo/hi.
  local function bound_open(val, aval, bval, a_open, b_open)
    if val == aval then return a_open end
    if val == bval then return b_open end
    -- fallback: open
    return true
  end
  local ac_lo_open = not self.lo_closed or not other.lo_closed
  local ad_lo_open = not self.lo_closed or not other.hi_closed
  local bc_lo_open = not self.hi_closed or not other.lo_closed
  local bd_lo_open = not self.hi_closed or not other.hi_closed
  local lo_open
  if lo == ac then lo_open = ac_lo_open
  elseif lo == ad then lo_open = ad_lo_open
  elseif lo == bc then lo_open = bc_lo_open
  else lo_open = bd_lo_open end
  local hi_open
  if hi == bd then hi_open = bd_lo_open
  elseif hi == bc then hi_open = bc_lo_open
  elseif hi == ad then hi_open = ad_lo_open
  else hi_open = ac_lo_open end
  return M.new(lo, hi, not lo_open, not hi_open)
end

-- [a,b] / [c,d] = [a,b] * [1/d, 1/c]
-- Returns nil, errmsg if 0 is in [c,d].
--: (Interval, Interval) -> (Interval | nil, string | nil)
function Interval:div(other)
  if self:is_empty() or other:is_empty() then return M.empty() end
  -- Check if 0 is in other.
  if other:contains(0) then
    return nil, "division by interval containing zero"
  end
  local inv = M.new(1 / other.hi, 1 / other.lo, other.hi_closed, other.lo_closed)
  return self:mul(inv)
end

-- Metamethods for arithmetic.
--: (Interval, Interval) -> Interval
function Interval:__add(other) return self:add(other) end
--: (Interval, Interval) -> Interval
function Interval:__sub(other) return self:sub(other) end
--: (Interval, Interval) -> Interval
function Interval:__mul(other) return self:mul(other) end
--: (Interval, Interval) -> (Interval | nil, string | nil)
function Interval:__div(other) return self:div(other) end

-- Shift interval by offset.
--: (Interval, number) -> Interval
function Interval:shift(offset)
  return M.new(self.lo + offset, self.hi + offset, self.lo_closed, self.hi_closed)
end

-- Scale interval by factor around origin 0.
--: (Interval, number) -> Interval
function Interval:scale(factor)
  if factor >= 0 then
    return M.new(self.lo * factor, self.hi * factor, self.lo_closed, self.hi_closed)
  else
    -- Negative factor reverses the interval.
    return M.new(self.hi * factor, self.lo * factor, self.hi_closed, self.lo_closed)
  end
end

-- Clamp value v into [lo, hi] (always treats bounds as closed for clamping).
--: (Interval, number) -> number
function Interval:clamp(v)
  if v < self.lo then return self.lo end
  if v > self.hi then return self.hi end
  return v
end

-- True if self is entirely before other (no shared point).
--: (Interval, Interval) -> boolean
function Interval:before(other)
  if self:is_empty() or other:is_empty() then return false end
  if self.hi < other.lo then return true end
  if self.hi == other.lo then return not (self.hi_closed and other.lo_closed) end
  return false
end

-- True if self is entirely after other (no shared point).
--: (Interval, Interval) -> boolean
function Interval:after(other)
  return other:before(self)
end

-- Equality: two empty intervals are equal; otherwise all four fields must match.
--: (Interval, Interval) -> boolean
function Interval:eq(other)
  if self:is_empty() and other:is_empty() then return true end
  return (self.lo == other.lo and self.hi == other.hi
    and self.lo_closed == other.lo_closed and self.hi_closed == other.hi_closed) == true
end

--: (Interval, Interval) -> boolean
function Interval:__eq(other)
  return self:eq(other)
end

--: (Interval) -> string
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

--:: IntervalSet = { intervals: { [integer]: Interval }, n: integer, normalize: (self: IntervalSet) -> IntervalSet, ... }

local Set = {}
-- Method lookup takes priority over identically-named instance fields (e.g. 'intervals').
Set.__index = function(t, k)
  local m = rawget(Set, k)
  if m ~= nil then return m end
  return rawget(t, k)
end

-- Create an interval set from a list of intervals.
-- Call :normalize() to sort and merge overlapping intervals.
--: (Arr<Interval> | nil) -> IntervalSet
function M.set(intervals)
  local s = setmetatable({ intervals = {}, n = 0 }, Set) --[[:! IntervalSet]]
  local ivs = intervals or {}
  for i = 1, #ivs do
    s.intervals[i] = ivs[i] --[[:! Interval]]
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
    return (a.lo_closed and not b.lo_closed) == true
  end)
  local merged = { ivs[1] } --: { [integer]: Interval }
  for i = 2, n do
    local prev = merged[#merged] --[[:! Interval]]
    local cur = ivs[i] --[[:! Interval]]
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

-- Add an interval to the set, merging with any that overlap or touch.
--: (self: IntervalSet, Interval) -> IntervalSet
function Set:add(iv)
  if iv:is_empty() then return self end
  self.n = self.n + 1
  self.intervals[self.n] = iv
  -- Re-normalize in place.
  local normalized = M.set(self.intervals):normalize()
  self.intervals = normalized.intervals
  self.n = normalized.n
  return self
end

-- Return a copy of the intervals list (sorted, disjoint, non-empty).
-- Named get_intervals() to avoid shadowing the 'intervals' instance field.
function Set:get_intervals()
  local result = {}
  for i = 1, self.n do result[i] = self.intervals[i] end
  return result
end

-- True if the set has no intervals (or all are empty).
function Set:is_empty()
  for i = 1, self.n do
    if not self.intervals[i]:is_empty() then return false end
  end
  return true
end

-- intersect: alias for intersection (accepts Interval or Set).
function Set:intersect(other)
  -- wrap a plain interval in a set for uniform handling
  if getmetatable(other) ~= Set then
    other = M.set({ other })
  end
  return self:intersection(other)
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
--: (Interval[]) -> Interval[]
function M.merge(intervals)
  local n = #intervals
  if n == 0 then return {} end
  local sorted = {} --: { [integer]: Interval }
  for i = 1, n do sorted[i] = intervals[i] end
  table.sort(sorted, function(a, b) return a.lo < b.lo end)
  local iv1 = sorted[1] --[[:! Interval]]
  local result = { M.new(iv1.lo, iv1.hi) } --: { [integer]: Interval }
  local ri = 1
  for i = 2, n do
    local cur = result[ri] --[[:! Interval]]
    local s = sorted[i] --[[:! Interval]]
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
--: (Interval[], number, number) -> Interval[]
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
--: (Interval[]) -> (Interval | nil, string | nil)
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

--:: TreeEntry = { [integer]: unknown }
--:: IntervalTree = { entries: { [integer]: TreeEntry }, n: integer, ... }

local Tree = {}
Tree.__index = Tree

function M.tree()
  return setmetatable({ entries = {}, n = 0 }, Tree) --[[:! IntervalTree]]
end

-- Binary search: first entry index with lo >= val.
--: ({ [integer]: TreeEntry }, integer, number) -> integer
local function lower_bound(entries, n, val)
  local lo, hi = 1, n
  local result = n + 1
  while lo <= hi do
    local mid = lo + floor((hi - lo) / 2)
    if (entries[mid][1] --[[:! Interval]]).lo >= val then
      result = mid
      hi = mid - 1
    else
      lo = mid + 1
    end
  end
  return result
end

-- Recompute max_hi suffix from position `from` to end.
--: ({ [integer]: TreeEntry }, integer, integer) -> nil
local function recompute_max(entries, n, from)
  if n == 0 then return end
  if from > n then from = n end
  local en = entries[n]
  en[3] = (en[1] --[[:! Interval]]).hi
  for i = n - 1, from, -1 do
    local ei = entries[i]
    local h = (ei[1] --[[:! Interval]]).hi
    local nm = entries[i + 1][3] --[[:! number]]
    ei[3] = h > nm and h or nm
  end
end

--: (self: IntervalTree, Interval, unknown) -> nil
function Tree:insert(iv, data)
  local entries = self.entries
  local n = self.n
  local pos = lower_bound(entries, n, iv.lo)
  for i = n, pos, -1 do entries[i + 1] = entries[i] end
  entries[pos] = { iv, data, iv.hi }
  self.n = n + 1
  recompute_max(entries, self.n, pos)
end

--: (self: IntervalTree, Interval) -> boolean
function Tree:remove(iv)
  local entries = self.entries
  local n = self.n
  for i = 1, n do
    local e = entries[i]
    local ei = e[1] --[[:! Interval]]
    if ei.lo == iv.lo and ei.hi == iv.hi then
      for j = i, n - 1 do entries[j] = entries[j + 1] end
      entries[n] = nil --[[: any]]
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
