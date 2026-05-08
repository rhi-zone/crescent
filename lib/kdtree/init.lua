-- lib/kdtree/init.lua
-- K-d tree spatial index for efficient nearest-neighbor and range queries
-- on points in k-dimensional space.
--
-- Pure Lua — no dependencies beyond standard LuaJIT libraries.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

--:: KdEntry = { point: { [integer]: number }, data: unknown }
--:: KdNode = { split_dim: integer, split_val: number, point: { [integer]: number }, data: unknown, left: KdNode | nil, right: KdNode | nil }
--:: KdBest = { [integer]: unknown }
--:: KdHeapItem = { [integer]: unknown }
--:: KdHeap = { [integer]: KdHeapItem }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Squared Euclidean distance between two k-dimensional points.
--: ({number}, {number}) -> number
local function dist_sq(a, b)
  local s = 0 --: number
  for i = 1, #a do
    local d = a[i] - b[i]
    s = s + d * d
  end
  return s
end

-- Euclidean distance between two k-dimensional points.
--: ({number}, {number}) -> number
local function dist(a, b)
  return sqrt(dist_sq(a, b))
end

-- Partial sort (quickselect) to find the median index in-place.
-- Rearranges entries[lo..hi] so that entries[mid] holds the median
-- by coordinate `dim`, and everything left of mid is <= median,
-- everything right is >= median.
--: ({ [integer]: KdEntry }, integer, integer, integer, integer) -> nil
local function quickselect(entries, lo, hi, mid, dim)
  while lo < hi do
    local pivot_val = entries[floor((lo + hi) / 2)].point[dim]
    local i, j = lo, hi
    while i <= j do
      while entries[i].point[dim] < pivot_val do i = i + 1 end
      while entries[j].point[dim] > pivot_val do j = j - 1 end
      if i <= j then
        entries[i], entries[j] = entries[j], entries[i]
        i = i + 1
        j = j - 1
      end
    end
    if j < mid then lo = i end
    if i > mid then hi = j end
    if j >= mid and i <= mid then break end
  end
end

-- Recursively build a k-d tree node from entries[lo..hi].
-- entries: array of {point={...}, data=...}
-- dim: current split dimension (0-based cycling)
-- k: number of dimensions
--: ({ [integer]: KdEntry }, integer, integer, integer, integer) -> KdNode | nil
local function build_node(entries, lo, hi, dim, k)
  if lo > hi then return nil end
  if lo == hi then
    return {
      split_dim = dim,
      split_val = entries[lo].point[dim],
      point     = entries[lo].point,
      data      = entries[lo].data,
      left      = nil,
      right     = nil,
    }
  end
  local mid = floor((lo + hi) / 2)
  quickselect(entries, lo, hi, mid, dim)
  local next_dim = (dim % k) + 1
  return {
    split_dim = dim,
    split_val = entries[mid].point[dim],
    point     = entries[mid].point,
    data      = entries[mid].data,
    left      = build_node(entries, lo, mid - 1, next_dim, k),
    right     = build_node(entries, mid + 1, hi, next_dim, k),
  }
end

-- ---------------------------------------------------------------------------
-- Max-heap for KNN (stores {dist_sq, point, data} with largest dist_sq on top)
-- ---------------------------------------------------------------------------

local function heap_push(heap, item)
  heap[#heap + 1] = item
  local i = #heap
  while i > 1 do
    local parent = floor(i / 2)
    if heap[parent][1] < heap[i][1] then
      heap[parent], heap[i] = heap[i], heap[parent]
      i = parent
    else
      break
    end
  end
end

local function heap_pop(heap)
  local top = heap[1]
  local n = #heap
  heap[1] = heap[n]
  heap[n] = nil
  -- sift down
  local i = 1
  while true do
    local left  = 2 * i
    local right = 2 * i + 1
    local largest = i
    if left <= #heap and heap[left][1] > heap[largest][1] then
      largest = left
    end
    if right <= #heap and heap[right][1] > heap[largest][1] then
      largest = right
    end
    if largest == i then break end
    heap[i], heap[largest] = heap[largest], heap[i]
    i = largest
  end
  return top
end

-- ---------------------------------------------------------------------------
-- Nearest-neighbor search
-- ---------------------------------------------------------------------------

-- Recursive NN search. Updates best = {dist_sq, point, data} in place.
--: (KdNode | nil, { [integer]: number }, KdBest) -> nil
local function nn_search(node, query, best)
  if node == nil then return end

  local d2 = dist_sq(query, node.point)
  if d2 < best[1] then
    best[1] = d2
    best[2] = node.point
    best[3] = node.data
  end

  local dim  = node.split_dim
  local diff = query[dim] - node.split_val

  -- Recurse into the closer half first
  local near, far
  if diff <= 0 then
    near, far = node.left, node.right
  else
    near, far = node.right, node.left
  end

  nn_search(near, query, best)

  -- Only visit the far side if it could contain a closer point
  if diff * diff < best[1] then
    nn_search(far, query, best)
  end
end

-- ---------------------------------------------------------------------------
-- KNN search (k nearest neighbors via max-heap)
-- ---------------------------------------------------------------------------

--: (KdNode | nil, { [integer]: number }, integer, KdHeap) -> nil
local function knn_search(node, query, k, heap)
  if node == nil then return end

  local d2 = dist_sq(query, node.point)
  if #heap < k then
    heap_push(heap, { d2, node.point, node.data })
  elseif d2 < heap[1][1] then
    heap_pop(heap)
    heap_push(heap, { d2, node.point, node.data })
  end

  local dim  = node.split_dim
  local diff = query[dim] - node.split_val

  local near, far
  if diff <= 0 then
    near, far = node.left, node.right
  else
    near, far = node.right, node.left
  end

  knn_search(near, query, k, heap)

  -- Prune: only visit far side if it could improve the heap
  local worst = #heap < k and huge or heap[1][1]
  if diff * diff < worst then
    knn_search(far, query, k, heap)
  end
end

-- ---------------------------------------------------------------------------
-- Range search (all points within Euclidean radius r)
-- ---------------------------------------------------------------------------

--: (KdNode | nil, { [integer]: number }, number, { [integer]: unknown }) -> nil
local function range_search(node, query, r_sq, results)
  if node == nil then return end

  local d2 = dist_sq(query, node.point)
  if d2 <= r_sq then
    results[#results + 1] = { point = node.point, data = node.data, dist = sqrt(d2) }
  end

  local dim  = node.split_dim
  local diff = query[dim] - node.split_val

  -- Visit near side always; far side only if the splitting plane is within radius
  local near, far
  if diff <= 0 then
    near, far = node.left, node.right
  else
    near, far = node.right, node.left
  end

  range_search(near, query, r_sq, results)

  if diff * diff <= r_sq then
    range_search(far, query, r_sq, results)
  end
end

-- ---------------------------------------------------------------------------
-- Box search (all points inside axis-aligned bounding box)
-- ---------------------------------------------------------------------------

-- Check whether a point is inside the box {min={...}, max={...}}
--: ({ [integer]: number }, { min: { [integer]: number }, max: { [integer]: number } }) -> boolean
local function point_in_box(pt, box)
  local mn, mx = box.min, box.max
  for i = 1, #pt do
    if pt[i] < mn[i] or pt[i] > mx[i] then return false end
  end
  return true
end

-- Check whether the subtree rooted at node can possibly overlap the box.
-- We track the bounding region implicitly via the split planes on the path —
-- simpler approach: just check overlap at each node using the split dimension.
--: (KdNode | nil, { min: { [integer]: number }, max: { [integer]: number } }, { [integer]: unknown }) -> nil
local function box_search(node, box, results)
  if node == nil then return end

  if point_in_box(node.point, box) then
    results[#results + 1] = { point = node.point, data = node.data }
  end

  local dim = node.split_dim
  local mn  = box.min[dim]
  local mx  = box.max[dim]
  local val = node.split_val

  -- Left subtree contains points with coordinate[dim] <= val
  if mn <= val then
    box_search(node.left, box, results)
  end
  -- Right subtree contains points with coordinate[dim] >= val
  if mx >= val then
    box_search(node.right, box, results)
  end
end

-- ---------------------------------------------------------------------------
-- Dynamic insert (unbalanced; call rebuild() to rebalance)
-- ---------------------------------------------------------------------------

--: (KdNode | nil, { [integer]: number }, unknown, integer, integer) -> KdNode
local function insert_node(node, point, data, dim, k)
  if node == nil then
    return {
      split_dim = dim,
      split_val = point[dim],
      point     = point,
      data      = data,
      left      = nil,
      right     = nil,
    }
  end
  local next_dim = (node.split_dim % k) + 1
  if point[node.split_dim] <= node.split_val then
    node.left = insert_node(node.left, point, data, next_dim, k)
  else
    node.right = insert_node(node.right, point, data, next_dim, k)
  end
  return node
end

-- Collect all entries from a subtree into a flat array.
--: (KdNode | nil, { [integer]: unknown }) -> nil
local function collect(node, out)
  if node == nil then return end
  out[#out + 1] = { point = node.point, data = node.data }
  collect(node.left,  out)
  collect(node.right, out)
end

-- ---------------------------------------------------------------------------
-- Size counting
-- ---------------------------------------------------------------------------

--: (KdNode | nil) -> integer
local function count_nodes(node)
  if node == nil then return 0 end
  return 1 + count_nodes(node.left) + count_nodes(node.right)
end

-- ---------------------------------------------------------------------------
-- Tree object (methods)
-- ---------------------------------------------------------------------------

--:: KdTree = { _root: KdNode | nil, _k: integer, _entries: { [integer]: KdEntry }, nearest: (self: KdTree, query: { [integer]: number }) -> { point: { [integer]: number }, data: unknown, dist: number } | nil, knn: (self: KdTree, query: { [integer]: number }, k: integer) -> { [integer]: { point: { [integer]: number }, data: unknown, dist: number } }, range: (self: KdTree, query: { [integer]: number }, r: number) -> { [integer]: { point: { [integer]: number }, data: unknown, dist: number } }, box: (self: KdTree, box: { min: { [integer]: number }, max: { [integer]: number } }) -> { [integer]: { point: { [integer]: number }, data: unknown } }, size: (self: KdTree) -> integer, insert: (self: KdTree, point: { [integer]: number }, data: unknown) -> nil, rebuild: (self: KdTree) -> nil }
local Tree = {}
Tree.__index = Tree

-- Return the nearest point to `query`.
-- Returns {point, data, dist} or nil if tree is empty.
--: (self: KdTree, query: { [integer]: number }) -> { point: { [integer]: number }, data: unknown, dist: number } | nil
function Tree:nearest(query)
  if self._root == nil then return nil end
  local best = { huge, nil, nil }
  nn_search(self._root, query, best)
  if best[2] == nil then return nil end
  return { point = best[2] --[[:! { [integer]: number }]], data = best[3], dist = sqrt(best[1] --[[:! number]]) }
end

-- Return the k nearest neighbors to `query` sorted by distance (closest first).
-- Returns array of {point, data, dist}.
--: (self: KdTree, query: { [integer]: number }, k: integer) -> { [integer]: { point: { [integer]: number }, data: unknown, dist: number } }
function Tree:knn(query, k)
  if self._root == nil then return {} end
  local heap = {}
  knn_search(self._root, query, k, heap)
  -- Sort results: drain heap into array then sort by dist_sq ascending
  local results = {}
  for i = 1, #heap do
    results[i] = heap[i]
  end
  table.sort(results, function(a, b) return a[1] < b[1] end)
  local out = {}
  for i = 1, #results do
    out[i] = { point = results[i][2] --[[:! { [integer]: number }]], data = results[i][3], dist = sqrt(results[i][1] --[[:! number]]) }
  end
  return out
end

-- Return all points within Euclidean radius `r` of `query`.
-- Returns array of {point, data, dist}.
--: (self: KdTree, query: { [integer]: number }, r: number) -> { [integer]: { point: { [integer]: number }, data: unknown, dist: number } }
function Tree:range(query, r)
  if self._root == nil then return {} end
  local results = {}
  range_search(self._root, query, r * r, results)
  return results
end

-- Return all points inside the axis-aligned bounding box.
-- box = {min={...}, max={...}}
-- Returns array of {point, data}.
--: (self: KdTree, box: { min: { [integer]: number }, max: { [integer]: number } }) -> { [integer]: { point: { [integer]: number }, data: unknown } }
function Tree:box(box)
  if self._root == nil then return {} end
  local results = {}
  box_search(self._root, box, results)
  return results
end

-- Return the total number of points in the tree.
--: (self: KdTree) -> integer
function Tree:size()
  return count_nodes(self._root)
end

-- Insert a single point (with optional data) into the tree.
-- Does not rebalance. Call rebuild() after many inserts.
--: (self: KdTree, point: { [integer]: number }, data: unknown) -> nil
function Tree:insert(point, data)
  self._root = insert_node(self._root, point, data, 1, self._k)
  self._entries[#self._entries + 1] = { point = point, data = data }
end

-- Rebuild the tree from scratch (rebalances after many inserts).
--: (self: KdTree) -> nil
function Tree:rebuild()
  -- Collect all current entries from the root (handles entries added via insert)
  local entries = {}
  collect(self._root, entries)
  self._entries = entries
  local k = self._k
  if #entries == 0 then
    self._root = nil
  else
    self._root = build_node(entries, 1, #entries, 1, k)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Build a k-d tree from an array of points or {point, data} entries.
--
-- Accepts two forms:
--   kdtree.build({{1,2}, {3,4}, ...})
--   kdtree.build({{point={1,2}, data="A"}, ...})
--
-- Returns a Tree object, or (nil, errmsg) on invalid input.
--: ({ [integer]: KdEntry }) -> KdTree | (nil, string)
function M.build(input)
  if type(input) ~= "table" then
    return nil, "build: expected table, got " .. type(input)
  end

  -- Normalise entries to {point, data} form
  local entries = {} --: { [integer]: KdEntry }
  for i = 1, #input do
    local item = input[i]
    if type(item) ~= "table" then
      return nil, "build: entry " .. i .. " is not a table"
    end
    if item.point then
      entries[i] = { point = item.point, data = item.data }
    else
      entries[i] = { point = item, data = nil }
    end
  end

  -- Detect dimensionality from first entry
  local k
  if #entries > 0 then
    k = #entries[1].point
    if k == 0 then
      return nil, "build: points must have at least 1 dimension"
    end
  else
    k = 1  -- empty tree; dimension is notional
  end

  local root
  if #entries == 0 then
    root = nil
  else
    root = build_node(entries, 1, #entries, 1, k)
  end

  local tree = setmetatable({
    _root    = root,
    _k       = k,
    _entries = entries,
  }, Tree)
  return tree
end

return M
