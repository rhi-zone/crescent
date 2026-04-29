-- lib/quadtree/init.lua
-- Point quadtree for 2D spatial queries.
-- Supports rect/circle range queries, nearest neighbor, KNN, and move/remove.
--
-- Pure Lua — no dependencies beyond standard LuaJIT libraries.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local sqrt, huge, max = math.sqrt, math.huge, math.max

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Minimum distance from point (cx,cy) to the boundary of rect b.
-- Returns 0 if the point is inside the rect.
--: (number, number, {x: number, y: number, w: number, h: number}) -> number
local function rect_min_dist(cx, cy, b)
  local dx = max(b.x - cx, 0, cx - (b.x + b.w))
  local dy = max(b.y - cy, 0, cy - (b.y + b.h))
  return sqrt(dx * dx + dy * dy)
end

-- Check whether two rects overlap.
--: ({x:number,y:number,w:number,h:number}, {x:number,y:number,w:number,h:number}) -> boolean
local function rects_overlap(a, b)
  return a.x < b.x + b.w and a.x + a.w > b.x
     and a.y < b.y + b.h and a.y + a.h > b.y
end

-- Check whether a rect overlaps a circle.
--: ({x:number,y:number,w:number,h:number}, number, number, number) -> boolean
local function rect_overlaps_circle(b, cx, cy, r)
  return rect_min_dist(cx, cy, b) <= r
end

-- Check whether point (px,py) is inside bounds b (inclusive left/top, exclusive right/bottom).
-- We use half-open intervals [x, x+w) x [y, y+h) so each point belongs to exactly one node.
--: (number, number, {x:number,y:number,w:number,h:number}) -> boolean
local function point_in_bounds(px, py, b)
  return px >= b.x and px < b.x + b.w
     and py >= b.y and py < b.y + b.h
end

-- Split a node into four children and redistribute its points.
--: (table) -> nil
local function subdivide(node)
  local b = node.bounds
  local hw = b.w / 2
  local hh = b.h / 2
  local cap = node.capacity
  node.children = {
    { bounds = { x = b.x,      y = b.y,      w = hw, h = hh }, points = {}, children = nil, capacity = cap }, -- NW
    { bounds = { x = b.x + hw, y = b.y,      w = hw, h = hh }, points = {}, children = nil, capacity = cap }, -- NE
    { bounds = { x = b.x,      y = b.y + hh, w = hw, h = hh }, points = {}, children = nil, capacity = cap }, -- SW
    { bounds = { x = b.x + hw, y = b.y + hh, w = hw, h = hh }, points = {}, children = nil, capacity = cap }, -- SE
  }
  -- Redistribute existing points into children.
  -- Use mid_x/mid_y for quadrant membership (matches standard quadrant logic).
  local mid_x = b.x + hw
  local mid_y = b.y + hh
  local pts = node.points
  for i = 1, #pts do
    local p = pts[i]
    local child
    if p[1] < mid_x then
      child = p[2] < mid_y and node.children[1] or node.children[3]
    else
      child = p[2] < mid_y and node.children[2] or node.children[4]
    end
    local cp = child.points
    cp[#cp + 1] = p
  end
  node.points = nil  -- leaf storage moved to children
end

-- Insert a point into a node (recursive).
--: (table, number, number, any) -> nil
local function node_insert(node, px, py, data)
  if node.children then
    local b = node.bounds
    local mid_x = b.x + b.w / 2
    local mid_y = b.y + b.h / 2
    local child
    if px < mid_x then
      child = py < mid_y and node.children[1] or node.children[3]
    else
      child = py < mid_y and node.children[2] or node.children[4]
    end
    node_insert(child, px, py, data)
  else
    local pts = node.points
    pts[#pts + 1] = { px, py, data }
    if #pts > node.capacity then
      subdivide(node)
    end
  end
end

-- Remove a point from a node (recursive). Returns true if removed.
--: (table, number, number) -> boolean
local function node_remove(node, px, py)
  if node.children then
    local b = node.bounds
    local mid_x = b.x + b.w / 2
    local mid_y = b.y + b.h / 2
    local child
    if px < mid_x then
      child = py < mid_y and node.children[1] or node.children[3]
    else
      child = py < mid_y and node.children[2] or node.children[4]
    end
    return node_remove(child, px, py)
  else
    local pts = node.points
    for i = 1, #pts do
      if pts[i][1] == px and pts[i][2] == py then
        table.remove(pts, i)
        return true
      end
    end
    return false
  end
end

-- Query all points in a rect (recursive).
--: (table, {x:number,y:number,w:number,h:number}, {any}) -> nil
local function node_query_rect(node, rect, out)
  if not rects_overlap(node.bounds, rect) then return end
  if node.children then
    for i = 1, 4 do
      node_query_rect(node.children[i], rect, out)
    end
  else
    local pts = node.points
    local rx1, ry1, rx2, ry2 = rect.x, rect.y, rect.x + rect.w, rect.y + rect.h
    for i = 1, #pts do
      local p = pts[i]
      if p[1] >= rx1 and p[1] <= rx2 and p[2] >= ry1 and p[2] <= ry2 then
        out[#out + 1] = { p[1], p[2], p[3] }
      end
    end
  end
end

-- Query all points in a circle (recursive).
--: (table, number, number, number, number, {any}) -> nil
local function node_query_circle(node, cx, cy, r, r_sq, out)
  if not rect_overlaps_circle(node.bounds, cx, cy, r) then return end
  if node.children then
    for i = 1, 4 do
      node_query_circle(node.children[i], cx, cy, r, r_sq, out)
    end
  else
    local pts = node.points
    for i = 1, #pts do
      local p = pts[i]
      local dx = p[1] - cx
      local dy = p[2] - cy
      local d2 = dx * dx + dy * dy
      if d2 <= r_sq then
        out[#out + 1] = { p[1], p[2], p[3], sqrt(d2) }
      end
    end
  end
end

-- Nearest neighbor search (recursive). best = {dist, x, y, data}.
--: (table, number, number, {any}) -> nil
local function node_nearest(node, cx, cy, best)
  if rect_min_dist(cx, cy, node.bounds) >= best[1] then return end
  if node.children then
    -- Visit children sorted by min distance to their bounds (closest first).
    local dists = {}
    for i = 1, 4 do
      dists[i] = { rect_min_dist(cx, cy, node.children[i].bounds), i }
    end
    table.sort(dists, function(a, b) return a[1] < b[1] end)
    for i = 1, 4 do
      node_nearest(node.children[dists[i][2]], cx, cy, best)
    end
  else
    local pts = node.points
    for i = 1, #pts do
      local p = pts[i]
      local dx = p[1] - cx
      local dy = p[2] - cy
      local d = sqrt(dx * dx + dy * dy)
      if d < best[1] then
        best[1] = d
        best[2] = p[1]
        best[3] = p[2]
        best[4] = p[3]
      end
    end
  end
end

-- KNN search (recursive). heap = max-heap of {dist, x, y, data}, capped at k.
--: (table, number, number, integer, {any}) -> nil
local function heap_push_knn(heap, k, item)
  -- max-heap: largest dist at top
  local n = #heap + 1
  heap[n] = item
  local i = n
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent][1] < heap[i][1] then
      heap[parent], heap[i] = heap[i], heap[parent]
      i = parent
    else break end
  end
  if #heap > k then
    -- pop max
    heap[1] = heap[#heap]
    heap[#heap] = nil
    local sz = #heap
    local j = 1
    while true do
      local l, r, lg = 2*j, 2*j+1, j
      if l <= sz and heap[l][1] > heap[lg][1] then lg = l end
      if r <= sz and heap[r][1] > heap[lg][1] then lg = r end
      if lg == j then break end
      heap[j], heap[lg] = heap[lg], heap[j]
      j = lg
    end
  end
end

--: (table, number, number, integer, {any}) -> nil
local function node_knn(node, cx, cy, k, heap)
  local worst = #heap < k and huge or heap[1][1]
  if rect_min_dist(cx, cy, node.bounds) >= worst then return end
  if node.children then
    local dists = {}
    for i = 1, 4 do
      dists[i] = { rect_min_dist(cx, cy, node.children[i].bounds), i }
    end
    table.sort(dists, function(a, b) return a[1] < b[1] end)
    for i = 1, 4 do
      node_knn(node.children[dists[i][2]], cx, cy, k, heap)
    end
  else
    local pts = node.points
    for i = 1, #pts do
      local p = pts[i]
      local dx = p[1] - cx
      local dy = p[2] - cy
      local d = sqrt(dx * dx + dy * dy)
      heap_push_knn(heap, k, { d, p[1], p[2], p[3] })
    end
  end
end

-- Count points (recursive).
--: (table) -> integer
local function node_count(node)
  if node.children then
    return node_count(node.children[1]) + node_count(node.children[2])
         + node_count(node.children[3]) + node_count(node.children[4])
  else
    return #node.points
  end
end

-- Collect all points into out (recursive).
--: (table, {any}) -> nil
local function node_each(node, out)
  if node.children then
    for i = 1, 4 do node_each(node.children[i], out) end
  else
    local pts = node.points
    for i = 1, #pts do out[#out + 1] = pts[i] end
  end
end

-- Tree depth (recursive).
--: (table) -> integer
local function node_depth(node)
  if not node.children then return 1 end
  local d = 0
  for i = 1, 4 do
    local cd = node_depth(node.children[i])
    if cd > d then d = cd end
  end
  return 1 + d
end

-- ---------------------------------------------------------------------------
-- Quadtree object
-- ---------------------------------------------------------------------------

local QT = {}
QT.__index = QT

-- Insert a point into the quadtree.
-- Returns false (without error) if the point is outside the bounds.
--: (number, number, any) -> boolean
function QT:insert(px, py, data)
  if not point_in_bounds(px, py, self._root.bounds) then
    return false
  end
  node_insert(self._root, px, py, data)
  return true
end

-- Remove the first point with exact (px, py) coordinates.
-- Returns true if found and removed, false otherwise.
--: (number, number) -> boolean
function QT:remove(px, py)
  return node_remove(self._root, px, py)
end

-- Query all points inside rect {x, y, w, h} (inclusive boundary).
-- Returns array of {x, y, data}.
--: (number, number, number, number) -> {any}
function QT:query_rect(x, y, w, h)
  local out = {}
  node_query_rect(self._root, { x = x, y = y, w = w, h = h }, out)
  return out
end

-- Query all points within radius r of (cx, cy).
-- Returns array of {x, y, data, dist} sorted by distance ascending.
--: (number, number, number) -> {any}
function QT:query_circle(cx, cy, r)
  local out = {}
  node_query_circle(self._root, cx, cy, r, r * r, out)
  table.sort(out, function(a, b) return a[4] < b[4] end)
  return out
end

-- Nearest neighbor.
-- Returns x, y, data, dist  or nil if the tree is empty.
--: (number, number) -> (number, number, any, number)
function QT:nearest(cx, cy)
  if node_count(self._root) == 0 then return nil end
  local best = { huge, nil, nil, nil }
  node_nearest(self._root, cx, cy, best)
  if best[2] == nil then return nil end
  return best[2], best[3], best[4], best[1]
end

-- K nearest neighbors sorted by distance ascending.
-- Returns array of {x, y, data, dist}.
--: (number, number, integer) -> {any}
function QT:knn(cx, cy, k)
  if k <= 0 then return {} end
  local heap = {}
  node_knn(self._root, cx, cy, k, heap)
  -- heap is a max-heap; sort ascending
  table.sort(heap, function(a, b) return a[1] < b[1] end)
  local out = {}
  for i = 1, #heap do
    local h = heap[i]
    out[i] = { h[2], h[3], h[4], h[1] }
  end
  return out
end

-- Total number of points in the tree.
--: () -> integer
function QT:count()
  return node_count(self._root)
end

-- Remove all points.
--: () -> nil
function QT:clear()
  self._root.points = {}
  self._root.children = nil
end

-- Call fn(x, y, data) for every point.
--: (function) -> nil
function QT:each(fn)
  local all = {}
  node_each(self._root, all)
  for i = 1, #all do
    local p = all[i]
    fn(p[1], p[2], p[3])
  end
end

-- Axis-aligned bounding box of all inserted points.
-- Returns x_min, y_min, x_max, y_max, or nil if empty.
--: () -> (number, number, number, number)
function QT:bbox()
  local all = {}
  node_each(self._root, all)
  if #all == 0 then return nil end
  local x_min, y_min, x_max, y_max = huge, huge, -huge, -huge
  for i = 1, #all do
    local p = all[i]
    if p[1] < x_min then x_min = p[1] end
    if p[2] < y_min then y_min = p[2] end
    if p[1] > x_max then x_max = p[1] end
    if p[2] > y_max then y_max = p[2] end
  end
  return x_min, y_min, x_max, y_max
end

-- Move a point from (old_x, old_y) to (new_x, new_y).
-- Returns false if old point not found or new position is out of bounds.
--: (number, number, number, number) -> boolean
function QT:move(old_x, old_y, new_x, new_y)
  -- Find the data before removing
  local found_data = nil
  local found = false
  -- Search for the point first to capture its data
  local results = self:query_rect(old_x, old_y, 0, 0)
  -- query_rect uses inclusive boundary, so exact match works
  for i = 1, #results do
    if results[i][1] == old_x and results[i][2] == old_y then
      found_data = results[i][3]
      found = true
      break
    end
  end
  if not found then return false end
  if not self:remove(old_x, old_y) then return false end
  return self:insert(new_x, new_y, found_data)
end

-- Reinsert all points into a fresh tree (useful after many removes to compact nodes).
--: () -> nil
function QT:rebuild()
  local all = {}
  node_each(self._root, all)
  local b = self._root.bounds
  local cap = self._root.capacity
  self._root = { bounds = b, points = {}, children = nil, capacity = cap }
  for i = 1, #all do
    local p = all[i]
    node_insert(self._root, p[1], p[2], p[3])
  end
end

-- Tree depth (1 = single leaf node).
--: () -> integer
function QT:depth()
  return node_depth(self._root)
end

-- ---------------------------------------------------------------------------
-- Public constructor
-- ---------------------------------------------------------------------------

-- Create a new quadtree.
-- bounds: {x, y, w, h}  — top-left corner + dimensions
-- capacity: max points per leaf node before subdivision (default 4)
--: ({x:number,y:number,w:number,h:number}, (integer | nil)) -> table
function M.new(bounds, capacity)
  capacity = capacity or 4
  local root = {
    bounds   = { x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h },
    points   = {},
    children = nil,
    capacity = capacity,
  }
  return setmetatable({ _root = root }, QT)
end

return M
