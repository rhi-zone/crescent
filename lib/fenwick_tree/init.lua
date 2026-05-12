if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Fenwick tree (Binary Indexed Tree) library.
-- Supports 1D prefix-sum, 2D prefix-sum, custom operations,
-- range-update/point-query, and range-update/range-query variants.

local band = require("bit").band

local M = {}
M._tier = "pure"

--:: BIT = { n: integer, data: { [integer]: number }, _pts: ({ [integer]: number } | nil) }
--:: BITOP = { n: integer, data: { [integer]: unknown }, _pts: { [integer]: unknown }, _combine: ((unknown, unknown) -> unknown), _identity: unknown, _point_update: ((unknown, unknown) -> unknown) }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- LSB: lowest set bit of i (used for BIT traversal)
local function lsb(i) return band(i, -i) end

-- ---------------------------------------------------------------------------
-- 1D Fenwick tree (prefix sum, point update)
-- ---------------------------------------------------------------------------

local BIT = {}
BIT.__index = BIT

-- Create a new BIT of size n, all zeros.
function M.new(n)
  local t = { n = n, data = {} }
  for i = 1, n do t.data[i] = 0 end
  setmetatable(t, BIT)
  return t
end

-- Build a BIT from an array in O(n).
function M.from_array(arr)
  local n = #arr
  local data = {}
  for i = 1, n do data[i] = arr[i] end
  -- O(n) build: propagate each cell to its parent
  for i = 1, n do
    local j = i + lsb(i)
    if j <= n then data[j] = data[j] + data[i] end
  end
  local t = { n = n, data = data }
  -- Store point values for get/set
  local pts = {}
  for i = 1, n do pts[i] = arr[i] end
  t._pts = pts
  setmetatable(t, BIT)
  return t
end

--: (self: BIT, i: integer, delta: number) -> ()
function BIT:update(i, delta)
  if self._pts then self._pts[i] = self._pts[i] + delta end
  local data, n = self.data, self.n
  while i <= n do
    data[i] = data[i] + delta
    i = i + lsb(i)
  end
end

--: (self: BIT, i: integer, val: number) -> ()
function BIT:set(i, val)
  local cur = BIT.get(self, i)
  BIT.update(self, i, val - cur)
end

--: (self: BIT, i: integer) -> number
function BIT:get(i)
  if self._pts then return self._pts[i] end
  -- Fall back to prefix difference
  return BIT.prefix(self, i) - BIT.prefix(self, i - 1)
end

--: (self: BIT, i: integer) -> number
function BIT:prefix(i)
  local s, data = 0, self.data
  while i > 0 do
    s = s + data[i]
    i = i - lsb(i)
  end
  return s
end

--: (self: BIT, l: integer, r: integer) -> number
function BIT:query(l, r)
  return BIT.prefix(self, r) - BIT.prefix(self, l - 1)
end

-- Find smallest index where prefix_sum >= k (binary lifting), O(log n).
-- Returns nil if no such index exists (k > total sum).
function BIT:find_kth(k)
  local pos = 0
  local log = 1
  local n = self.n
  while log <= n do log = log * 2 end
  log = math.floor(log / 2)
  local data = self.data
  while log >= 1 do
    local next = pos + log
    if next <= n and data[next] < k then
      k = k - data[next]
      pos = next --[[:! integer]]
    end
    log = math.floor(log / 2)
  end
  local idx = pos + 1
  if idx > n then return nil end
  return idx
end

-- Return the number of elements.
function BIT:len()
  return self.n
end

--: (self: BIT) -> { [integer]: number }
function BIT:to_array()
  local arr = {}
  for i = 1, self.n do
    arr[i] = BIT.get(self, i)
  end
  return arr
end

-- ---------------------------------------------------------------------------
-- 2D Fenwick tree (prefix sum, point update)
-- ---------------------------------------------------------------------------

local BIT2D = {}
BIT2D.__index = BIT2D

function M.new_2d(rows, cols)
  local data = {}
  for i = 1, rows do
    data[i] = {}
    for j = 1, cols do data[i][j] = 0 end
  end
  local t = { rows = rows, cols = cols, data = data }
  setmetatable(t, BIT2D)
  return t
end

function BIT2D:update(r, c, v)
  local rows, cols, data = self.rows, self.cols, self.data
  local i = r
  while i <= rows do
    local j = c
    while j <= cols do
      data[i][j] = data[i][j] + v
      j = j + lsb(j)
    end
    i = i + lsb(i)
  end
end

function BIT2D:prefix(r, c)
  local s, data = 0, self.data
  local i = r
  while i > 0 do
    local j = c
    while j > 0 do
      s = s + data[i][j]
      j = j - lsb(j)
    end
    i = i - lsb(i)
  end
  return s
end

function BIT2D:query(r1, c1, r2, c2)
  return self:prefix(r2, c2)
       - self:prefix(r1 - 1, c2)
       - self:prefix(r2, c1 - 1)
       + self:prefix(r1 - 1, c1 - 1)
end

-- ---------------------------------------------------------------------------
-- BIT with custom operation (prefix queries only, no range queries)
-- ---------------------------------------------------------------------------

local BITOP = {}
BITOP.__index = BITOP

-- opts: { combine = fn, identity = val, point_update = fn }
-- point_update(old_val, new_val) -> stored_val (for update semantics)
function M.new_op(n, opts)
  local combine = opts.combine
  local identity = opts.identity
  local point_update = opts.point_update or function(_, v) return v end
  local data = {}
  for i = 1, n do data[i] = identity end
  local pts = {}
  for i = 1, n do pts[i] = identity end
  local t = {
    n = n,
    data = data,
    _pts = pts,
    _combine = combine,
    _identity = identity,
    _point_update = point_update,
  }
  setmetatable(t, BITOP)
  return t
end

--: (self: BITOP, i: integer, val: unknown) -> ()
function BITOP:update(i, val)
  local combine = self._combine
  local pt = self._point_update(self._pts[i], val)
  self._pts[i] = pt
  local data, n = self.data, self.n
  -- Re-build affected cells by recomputing from scratch via point values
  -- For non-invertible ops (max), we must recompute affected BIT cells.
  -- Strategy: for each ancestor cell, recompute from the point values it covers.
  local idx = i
  while idx <= n do
    -- Cell idx covers the range [idx - lsb(idx) + 1 .. idx]
    local lo = idx - lsb(idx) + 1
    local acc = self._identity
    for k = lo, idx do
      acc = combine(acc, self._pts[k])
    end
    data[idx] = acc
    idx = idx + lsb(idx)
  end
end

--: (self: BITOP, i: integer) -> unknown
function BITOP:prefix(i)
  local s, data, combine = self._identity, self.data, self._combine
  while i > 0 do
    s = combine(s, data[i])
    i = i - lsb(i)
  end
  return s
end

function BITOP:len()
  return self.n
end

-- ---------------------------------------------------------------------------
-- Range-update, point-query (dual BIT)
-- ---------------------------------------------------------------------------

local BITRP = {}
BITRP.__index = BITRP

function M.new_range(n)
  local data = {}
  for i = 1, n do data[i] = 0 end
  local t = { n = n, data = data }
  setmetatable(t, BITRP)
  return t
end

-- Add val to all indices in [l..r].
function BITRP:range_update(l, r, val)
  local data, n = self.data, self.n
  -- Difference array BIT: update(l, val) and update(r+1, -val)
  local i = l
  while i <= n do
    data[i] = data[i] + val
    i = i + lsb(i)
  end
  local j = r + 1
  while j <= n do
    data[j] = data[j] - val
    j = j + lsb(j)
  end
end

-- Point query: value at index i.
function BITRP:point_query(i)
  local s, data = 0, self.data
  while i > 0 do
    s = s + data[i]
    i = i - lsb(i)
  end
  return s
end

function BITRP:len()
  return self.n
end

-- ---------------------------------------------------------------------------
-- Range-update, range-query (two BITs)
-- ---------------------------------------------------------------------------

-- For a BIT supporting range-update/range-query, we maintain two BITs B1, B2
-- such that prefix_sum(i) = B1:prefix(i) * (i+1) - B2:prefix(i).
-- range_update(l,r,v): B1 += v at l, -v at r+1; B2 += v*(l-1) at l, -v*r at r+1.

local BITRR = {}
BITRR.__index = BITRR

function M.new_range_range(n)
  local b1, b2 = {}, {}
  for i = 1, n do b1[i] = 0; b2[i] = 0 end
  local t = { n = n, b1 = b1, b2 = b2 }
  setmetatable(t, BITRR)
  return t
end

local function _bit_add(data, n, i, v)
  while i <= n do
    data[i] = data[i] + v
    i = i + lsb(i)
  end
end

local function _bit_sum(data, i)
  local s = 0
  while i > 0 do
    s = s + data[i]
    i = i - lsb(i)
  end
  return s
end

function BITRR:range_update(l, r, val)
  local n = self.n
  _bit_add(self.b1, n, l, val)
  _bit_add(self.b1, n, r + 1, -val)
  _bit_add(self.b2, n, l, val * (l - 1))
  _bit_add(self.b2, n, r + 1, -val * r)
end

local function _prefix(b1, b2, i)
  return _bit_sum(b1, i) * i - _bit_sum(b2, i)
end

function BITRR:range_query(l, r)
  return _prefix(self.b1, self.b2, r) - _prefix(self.b1, self.b2, l - 1)
end

function BITRR:len()
  return self.n
end

return M
