-- lib/interval_tree/init.lua
-- Augmented BST interval tree for storing and querying intervals.
-- Supports stabbing, overlap, containment, nearest, delete, and bulk load.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor = math.floor
local abs = math.abs
local huge = math.huge

-- ---------------------------------------------------------------------------
-- Internal node structure
-- Each node: { lo, hi, data, left, right, max_hi }
-- max_hi = max hi in subtree rooted at this node (augmented BST invariant)
-- ---------------------------------------------------------------------------

--:: ITreeNode = { lo: number, hi: number, data: any, left: ITreeNode | nil, right: ITreeNode | nil, max_hi: number }
--:: ITreeObj = { _root: ITreeNode | nil, _n: integer }

--: (number, number, any) -> ITreeNode
local function node_new(lo, hi, data)
  return { lo = lo, hi = hi, data = data, left = nil, right = nil, max_hi = hi }
end

--: (ITreeNode | nil) -> number
local function max_hi(n)
  if n == nil then return -huge end
  return n.max_hi
end

--: (ITreeNode) -> nil
local function update_max(n)
  local m = n.hi
  local lm = max_hi(n.left --[[:! ITreeNode | nil]])
  local rm = max_hi(n.right --[[:! ITreeNode | nil]])
  if lm > m then m = lm end
  if rm > m then m = rm end
  n.max_hi = m
end

-- ---------------------------------------------------------------------------
-- BST insert (by lo, then hi as tiebreak)
-- ---------------------------------------------------------------------------

--: (ITreeNode | nil, number, number, any) -> ITreeNode
local function bst_insert(root, lo, hi, data)
  if root == nil then
    return node_new(lo, hi, data)
  end
  if lo < root.lo or (lo == root.lo and hi < root.hi) then
    root.left = bst_insert(root.left --[[:! ITreeNode | nil]], lo, hi, data)
  else
    root.right = bst_insert(root.right --[[:! ITreeNode | nil]], lo, hi, data)
  end
  update_max(root)
  return root
end

-- ---------------------------------------------------------------------------
-- BST delete: remove one node matching lo, hi, and optionally data
-- Returns root, removed_bool
-- ---------------------------------------------------------------------------

--: (ITreeNode) -> ITreeNode
local function find_min(n)
  while n.left do n = n.left --[[:! ITreeNode]] end
  return n
end

--: (ITreeNode | nil, number, number, any, { [integer]: boolean }) -> (ITreeNode | nil, { [integer]: boolean })
local function bst_delete(root, lo, hi, data, removed)
  if root == nil then return nil, removed end
  local new_left, new_right --: ITreeNode | nil
  local rm2 --: { [integer]: boolean } | nil
  if lo < root.lo or (lo == root.lo and hi < root.hi) then
    new_left, rm2 = bst_delete(root.left --[[:! ITreeNode | nil]], lo, hi, data, removed)
    root.left = new_left; removed = rm2
  elseif lo > root.lo or (lo == root.lo and hi > root.hi) then
    new_right, rm2 = bst_delete(root.right --[[:! ITreeNode | nil]], lo, hi, data, removed)
    root.right = new_right; removed = rm2
  else
    -- lo and hi match; check data if provided
    if data ~= nil and root.data ~= data then
      -- same lo/hi but different data — try right subtree (duplicates go right)
      new_right, rm2 = bst_delete(root.right --[[:! ITreeNode | nil]], lo, hi, data, removed)
      root.right = new_right; removed = rm2
    else
      removed[1] = true
      if root.left == nil then
        return root.right --[[:! ITreeNode | nil]], removed
      elseif root.right == nil then
        return root.left --[[:! ITreeNode | nil]], removed
      else
        -- Replace with in-order successor
        local succ = find_min(root.right --[[:! ITreeNode]])
        root.lo = succ.lo
        root.hi = succ.hi
        root.data = succ.data
        -- Delete successor from right subtree (no data filter — exact match)
        new_right, rm2 = bst_delete(root.right --[[:! ITreeNode | nil]], succ.lo, succ.hi, nil, removed)
        root.right = new_right; removed = rm2
      end
    end
  end
  update_max(root)
  return root, removed
end

-- ---------------------------------------------------------------------------
-- Stabbing query: all intervals [lo,hi] where lo <= point <= hi
-- ---------------------------------------------------------------------------

local function stab_collect(node, point, result)
  if node == nil then return end
  -- Prune: if max_hi of subtree < point, no interval can contain it
  if node.max_hi < point then return end
  -- Recurse left
  stab_collect(node.left --[[:! ITreeNode | nil]], point, result)
  -- Check this node
  if node.lo <= point and point <= node.hi then
    result[#result + 1] = { lo = node.lo, hi = node.hi, data = node.data }
  end
  -- Prune right: if node.lo > point, no right subtree node can have lo <= point
  if node.lo > point then return end
  stab_collect(node.right --[[:! ITreeNode | nil]], point, result)
end

-- ---------------------------------------------------------------------------
-- Overlap query: all intervals overlapping [qlo, qhi]
-- Two intervals [a,b] and [c,d] overlap iff a <= d and c <= b
-- ---------------------------------------------------------------------------

local function overlap_collect(node, qlo, qhi, result)
  if node == nil then return end
  -- Prune: subtree max_hi < qlo means no interval can reach qlo
  if node.max_hi < qlo then return end
  -- Recurse left
  overlap_collect(node.left --[[:! ITreeNode | nil]], qlo, qhi, result)
  -- Check this node
  if node.lo <= qhi and node.hi >= qlo then
    result[#result + 1] = { lo = node.lo, hi = node.hi, data = node.data }
  end
  -- Prune right: if node.lo > qhi, right subtree has lo > qhi too
  if node.lo > qhi then return end
  overlap_collect(node.right --[[:! ITreeNode | nil]], qlo, qhi, result)
end

-- ---------------------------------------------------------------------------
-- Containment query: intervals fully inside [qlo, qhi]
-- i.e. qlo <= lo and hi <= qhi
-- ---------------------------------------------------------------------------

local function contained_collect(node, qlo, qhi, result)
  if node == nil then return end
  if node.max_hi < qlo then return end
  -- Recurse left
  contained_collect(node.left --[[:! ITreeNode | nil]], qlo, qhi, result)
  -- Check this node
  if node.lo >= qlo and node.hi <= qhi then
    result[#result + 1] = { lo = node.lo, hi = node.hi, data = node.data }
  end
  if node.lo > qhi then return end
  contained_collect(node.right --[[:! ITreeNode | nil]], qlo, qhi, result)
end

-- ---------------------------------------------------------------------------
-- Nearest query: interval closest to point
-- Distance = 0 if point is inside, else min(|point - lo|, |point - hi|)
-- ---------------------------------------------------------------------------

local function interval_dist(lo, hi, point)
  if point >= lo and point <= hi then return 0 end
  local dl = abs(point - lo)
  local dh = abs(point - hi)
  return dl < dh and dl or dh
end

local function nearest_walk(node, point, best)
  if node == nil then return best end
  -- Pruning: minimum possible distance from subtree
  -- If point > max_hi, nearest end is max_hi; distance is point - max_hi
  if node.max_hi < point then
    local min_dist = point - node.max_hi
    if best[2] ~= nil and min_dist >= best[2] then return best end
  end
  -- Recurse left first (may contain closer intervals)
  best = nearest_walk(node.left --[[:! ITreeNode | nil]], point, best)
  -- Check this node
  local d = interval_dist(node.lo, node.hi, point)
  if best[2] == nil or d < best[2] then
    best[1] = node
    best[2] = d
  end
  if d == 0 then return best end  -- can't do better
  -- Recurse right
  best = nearest_walk(node.right --[[:! ITreeNode | nil]], point, best)
  return best
end

-- ---------------------------------------------------------------------------
-- In-order traversal
-- ---------------------------------------------------------------------------

local function each_inorder(node, fn)
  if node == nil then return end
  each_inorder(node.left --[[:! ITreeNode | nil]], fn)
  fn(node.lo, node.hi, node.data)
  each_inorder(node.right --[[:! ITreeNode | nil]], fn)
end

-- ---------------------------------------------------------------------------
-- Count
-- ---------------------------------------------------------------------------

--: (ITreeNode | nil) -> integer
local function count_nodes(node)
  if node == nil then return 0 end
  return 1 + count_nodes(node.left --[[:! ITreeNode | nil]]) + count_nodes(node.right --[[:! ITreeNode | nil]])
end

-- ---------------------------------------------------------------------------
-- Tree object
-- ---------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

function M.tree()
  return setmetatable({ _root = nil, _n = 0 }, Tree)
end

function Tree:insert(lo, hi, data)
  local self_ = self --[[:! ITreeObj]]
  self_._root = bst_insert(self_._root, lo, hi, data)
  self_._n = self_._n + 1
end

-- Returns true if deleted, false if not found.
function Tree:delete(lo, hi, data)
  local self_ = self --[[:! ITreeObj]]
  local removed = {} --: { [integer]: boolean }
  removed[1] = false
  self_._root, removed = bst_delete(self_._root, lo, hi, data, removed)
  if removed[1] then
    self_._n = self_._n - 1
    return true
  end
  return false
end

-- Point stabbing: returns array of {lo, hi, data} for all intervals containing point.
function Tree:stab(point)
  local self_ = self --[[:! ITreeObj]]
  local result = {}
  stab_collect(self_._root, point, result)
  return result
end

-- Overlap query: returns array of {lo, hi, data} for all intervals overlapping [lo, hi].
function Tree:overlap(lo, hi)
  local self_ = self --[[:! ITreeObj]]
  local result = {}
  overlap_collect(self_._root, lo, hi, result)
  return result
end

-- Containment query: returns array of {lo, hi, data} for intervals fully inside [lo, hi].
function Tree:contained(lo, hi)
  local self_ = self --[[:! ITreeObj]]
  local result = {}
  contained_collect(self_._root, lo, hi, result)
  return result
end

-- Nearest interval to point. Returns {lo, hi, data} or nil.
function Tree:nearest(point)
  local self_ = self --[[:! ITreeObj]]
  local best = nearest_walk(self_._root, point, { nil, nil })
  if best[1] == nil then return nil end
  local n = best[1] --[[:! ITreeNode]]
  return { lo = n.lo, hi = n.hi, data = n.data }
end

-- In-order traversal: calls fn(lo, hi, data) for each interval in sorted order.
function Tree:each(fn)
  local self_ = self --[[:! ITreeObj]]
  each_inorder(self_._root, fn)
end

-- Number of intervals in the tree.
function Tree:len()
  local self_ = self --[[:! ITreeObj]]
  return self_._n
end

M.Tree = Tree

-- ---------------------------------------------------------------------------
-- Bulk load: build a balanced BST from a sorted array of intervals.
-- Faster than repeated insert because it avoids O(n log n) insertions.
-- ---------------------------------------------------------------------------

local function build_balanced(sorted, lo, hi)
  if lo > hi then return nil end
  local mid = lo + floor((hi - lo) / 2)
  local entry = sorted[mid]
  local node = node_new(entry[1], entry[2], entry[3])
  node.left = build_balanced(sorted, lo, mid - 1)
  node.right = build_balanced(sorted, mid + 1, hi)
  update_max(node)
  return node
end

-- Build a tree from an array of {lo, hi, data?} triples.
function M.from_array(intervals)
  local t = M.tree()
  if #intervals == 0 then return t end
  -- Sort by lo, then hi as tiebreak
  local sorted = {}
  for i = 1, #intervals do sorted[i] = intervals[i] end
  table.sort(sorted, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  local t_ = t --[[:! ITreeObj]]
  t_._root = build_balanced(sorted, 1, #sorted)
  t_._n = #sorted
  return t
end

return M
