-- lib/treap/init.lua
-- Treap: randomized BST with heap-ordered priorities.
-- Split/merge based implementation for clean O(log n) expected operations.
-- Pure Lua — no dependencies beyond LuaJIT bit library.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Node = { key: unknown, value: unknown, priority: number, left: Node | nil, right: Node | nil }
--:: Cmp = (a: unknown, b: unknown) -> integer

local bit = bit
local bxor, lshift, rshift = bit.bxor, bit.lshift, bit.rshift

-- ---------------------------------------------------------------------------
-- Xorshift RNG for priorities (deterministic, faster than math.random)
-- ---------------------------------------------------------------------------

local rng_state = 123456789
local function rand_priority()
  rng_state = bxor(rng_state, lshift(rng_state, 13))
  rng_state = bxor(rng_state, rshift(rng_state, 17))
  rng_state = bxor(rng_state, lshift(rng_state, 5))
  -- normalize to (0, 1] avoiding 0 (which would be a degenerate heap)
  local v = rng_state / 4294967296
  if v < 0 then v = -v end
  if v == 0 then v = 1e-9 end
  return v
end

-- ---------------------------------------------------------------------------
-- Default comparator
-- ---------------------------------------------------------------------------

local function default_cmp(a, b)
  if a < b then return -1
  elseif a > b then return 1
  else return 0
  end
end

-- ---------------------------------------------------------------------------
-- Core split/merge primitives (operate on raw nodes, not treap objects)
-- ---------------------------------------------------------------------------

-- Split node t into (l, r):
--   l has all keys where cmp(key, k) < 0  (keys strictly less than k)
--   r has all keys where cmp(key, k) >= 0 (keys >= k)
--: (t: Node | nil, k: unknown, cmp: Cmp) -> (Node | nil, Node | nil)
local function split(t, k, cmp)
  if t == nil then return nil, nil end
  if cmp(t.key, k) < 0 then
    local l, r = split(t.right, k, cmp)
    t.right = l
    return t, r
  else
    local l, r = split(t.left, k, cmp)
    t.left = r
    return l, t
  end
end

-- Merge l and r into one node: assumes all keys in l < all keys in r.
--: (l: Node | nil, r: Node | nil) -> Node | nil
local function merge(l, r)
  if l == nil then return r end
  if r == nil then return l end
  if l.priority > r.priority then
    l.right = merge(l.right, r)
    return l
  else
    r.left = merge(l, r.left)
    return r
  end
end

-- ---------------------------------------------------------------------------
-- Internal traversal helpers
-- ---------------------------------------------------------------------------

--: (t: Node | nil) -> Node | nil
local function node_min(t)
  if t == nil then return nil end
  while t.left ~= nil do t = t.left end
  return t
end

--: (t: Node | nil) -> Node | nil
local function node_max(t)
  if t == nil then return nil end
  while t.right ~= nil do t = t.right end
  return t
end

--: (t: Node | nil, k: unknown, cmp: Cmp, best: Node | nil) -> Node | nil
local function node_floor(t, k, cmp, best)
  -- largest key <= k
  if t == nil then return best end
  local c = cmp(t.key, k)
  if c == 0 then
    return t
  elseif c < 0 then
    -- t.key < k: t is a candidate, try right subtree for something larger but still <= k
    return node_floor(t.right, k, cmp, t)
  else
    -- t.key > k: go left
    return node_floor(t.left, k, cmp, best)
  end
end

--: (t: Node | nil, k: unknown, cmp: Cmp, best: Node | nil) -> Node | nil
local function node_ceil(t, k, cmp, best)
  -- smallest key >= k
  if t == nil then return best end
  local c = cmp(t.key, k)
  if c == 0 then
    return t
  elseif c > 0 then
    -- t.key > k: t is a candidate, try left subtree for something smaller but still >= k
    return node_ceil(t.left, k, cmp, t)
  else
    -- t.key < k: go right
    return node_ceil(t.right, k, cmp, best)
  end
end

-- In-order traversal: calls fn(key, value) for each node
--: (t: Node | nil, fn: (unknown, unknown) -> nil) -> nil
local function each_node(t, fn)
  if t == nil then return end
  each_node(t.left, fn)
  fn(t.key, t.value)
  each_node(t.right, fn)
end

-- Range traversal: calls fn(key, value) for all keys in [lo, hi]
--: (t: Node | nil, lo: unknown, hi: unknown, cmp: Cmp, fn: (unknown, unknown) -> nil) -> nil
local function range_node(t, lo, hi, cmp, fn)
  if t == nil then return end
  local clo = cmp(t.key, lo)
  local chi = cmp(t.key, hi)
  if clo > 0 then
    -- t.key > lo: left subtree may have keys in range
    range_node(t.left, lo, hi, cmp, fn)
  end
  if clo >= 0 and chi <= 0 then
    -- lo <= t.key <= hi
    fn(t.key, t.value)
  end
  if chi < 0 then
    -- t.key < hi: right subtree may have keys in range
    range_node(t.right, lo, hi, cmp, fn)
  end
end

-- ---------------------------------------------------------------------------
-- Treap object methods
-- ---------------------------------------------------------------------------

--:: TreapObj = { _root: Node | nil, _size: integer, _cmp: Cmp }
local Treap = {}
Treap.__index = Treap

-- Insert key-value pair; update value if key exists.
--: (self: TreapObj, key: unknown, value: unknown) -> nil
function Treap:insert(key, value)
  local cmp = self._cmp
  -- Split at key and at key+epsilon to isolate any existing node for that key.
  -- Strategy: split into keys<key and keys>=key; then check if right's min == key.
  local l, r = split(self._root, key, cmp)
  -- Check if the minimum of r has exactly key (i.e., key already exists)
  local existing = node_min(r)
  if existing ~= nil and cmp(existing.key, key) == 0 then
    -- Update in place; no size change
    existing.value = value
    self._root = merge(l, r)
    return
  end
  -- New key: create singleton node
  local node = { key = key, value = value, priority = rand_priority(), left = nil, right = nil }
  self._size = self._size + 1
  self._root = merge(merge(l, node), r)
end

-- Remove key. Returns true if removed, false if not found.
--: (self: TreapObj, key: unknown) -> boolean
function Treap:remove(key)
  local cmp = self._cmp
  -- Split into keys<key and keys>=key
  local l, r = split(self._root, key, cmp)
  -- Check r's minimum node
  local existing = node_min(r)
  if existing == nil or cmp(existing.key, key) ~= 0 then
    -- Not found; reassemble and return false
    self._root = merge(l, r)
    return false
  end
  -- Split off just the minimum from r (the node we want to delete)
  -- We split r at the successor of key to get (singleton, rest)
  -- Easier: split r into (exact_node, remainder) by splitting r at the successor.
  -- Since existing is the minimum of r, split r's right subtree off:
  -- Actually, we can just merge(r.left, r.right) after detaching existing.
  -- But node_min may not return the direct root. Use split again with a key
  -- just above 'key' — but we don't have "just above" generically.
  -- Instead: since existing is the minimum of r, we split r at a key that is
  -- strictly greater than existing.key. We do this by splitting r to isolate
  -- the minimum: walk to the minimum and detach.
  -- Simplest approach: split r into (r_left_of_min, r_right) where r_left_of_min
  -- contains only the minimum node. We know existing is at some position in r.
  -- Because existing is the min of r, existing has no left child.
  -- So we can split r into ({existing}, rest_of_r) by splitting on the successor.
  -- Find successor key in r:
  local r_without_min
  if existing.right ~= nil then
    -- The rest of r is: merge(nothing, existing.right + rest-after-existing)
    -- We need to remove existing from r. Since existing is the leftmost node in r:
    -- r = existing merged with its right subtree placed appropriately.
    -- Split r into (nodes_less_than_just_above_existing, rest).
    -- Since existing is min of r, we can reconstruct r without it:
    -- existing has no left child. We rebuild r by removing existing from the front.
    -- Traverse down the leftmost path and detach.
    local cur = r
    local parent = nil
    while cur.left ~= nil do
      parent = cur
      cur = cur.left
    end
    -- cur == existing (the min node)
    if parent == nil then
      -- existing is the root of r
      r_without_min = existing.right
    else
      parent.left = existing.right
      r_without_min = r
    end
  else
    -- existing has no right child either — walk leftmost path to detach
    local cur = r
    local parent = nil
    while cur.left ~= nil do
      parent = cur
      cur = cur.left
    end
    if parent == nil then
      r_without_min = nil
    else
      parent.left = nil
      r_without_min = r
    end
  end
  self._size = self._size - 1
  self._root = merge(l, r_without_min)
  return true
end

-- Get value for key; returns nil if not found.
--: (self: TreapObj, key: unknown) -> unknown
function Treap:get(key)
  local cmp = self._cmp
  local t = self._root
  while t ~= nil do
    local c = cmp(key, t.key)
    if c == 0 then return t.value
    elseif c < 0 then t = t.left
    else t = t.right
    end
  end
  return nil
end

-- Check existence.
--: (self: TreapObj, key: unknown) -> boolean
function Treap:contains(key)
  local cmp = self._cmp
  local t = self._root
  while t ~= nil do
    local c = cmp(key, t.key)
    if c == 0 then return true
    elseif c < 0 then t = t.left
    else t = t.right
    end
  end
  return false
end

-- Minimum key/value pair; nil if empty.
--: (self: TreapObj) -> (unknown, unknown)
function Treap:min()
  local n = node_min(self._root)
  if n == nil then return nil, nil end
  return n.key, n.value
end

-- Maximum key/value pair; nil if empty.
--: (self: TreapObj) -> (unknown, unknown)
function Treap:max()
  local n = node_max(self._root)
  if n == nil then return nil, nil end
  return n.key, n.value
end

-- Floor: largest key <= k. Returns key, value or nil, nil.
--: (self: TreapObj, k: unknown) -> (unknown, unknown)
function Treap:floor(k)
  local n = node_floor(self._root, k, self._cmp, nil)
  if n == nil then return nil, nil end
  return n.key, n.value
end

-- Ceil: smallest key >= k. Returns key, value or nil, nil.
--: (self: TreapObj, k: unknown) -> (unknown, unknown)
function Treap:ceil(k)
  local n = node_ceil(self._root, k, self._cmp, nil)
  if n == nil then return nil, nil end
  return n.key, n.value
end

-- Predecessor: largest key strictly < k.
--: (self: TreapObj, k: unknown) -> (unknown, unknown)
function Treap:pred(k)
  local cmp = self._cmp
  -- floor of (k-epsilon): find largest key where cmp(key, k) < 0
  local best = nil
  local t = self._root
  while t ~= nil do
    local c = cmp(t.key, k)
    if c < 0 then
      -- t.key < k: candidate
      if best == nil or cmp(t.key, best.key) > 0 then
        best = t
      end
      t = t.right  -- try to find something larger but still < k
    else
      t = t.left
    end
  end
  if best == nil then return nil, nil end
  return best.key, best.value
end

-- Successor: smallest key strictly > k.
--: (self: TreapObj, k: unknown) -> (unknown, unknown)
function Treap:succ(k)
  local cmp = self._cmp
  local best = nil
  local t = self._root
  while t ~= nil do
    local c = cmp(t.key, k)
    if c > 0 then
      -- t.key > k: candidate
      if best == nil or cmp(t.key, best.key) < 0 then
        best = t
      end
      t = t.left  -- try to find something smaller but still > k
    else
      t = t.right
    end
  end
  if best == nil then return nil, nil end
  return best.key, best.value
end

-- Size.
--: (self: TreapObj) -> integer
function Treap:size()
  return self._size
end

-- In-order traversal.
--: (self: TreapObj, fn: (unknown, unknown) -> nil) -> nil
function Treap:each(fn)
  each_node(self._root, fn)
end

-- Range query: fn(key, value) for all keys in [lo, hi].
--: (self: TreapObj, lo: unknown, hi: unknown, fn: (unknown, unknown) -> nil) -> nil
function Treap:range(lo, hi, fn)
  range_node(self._root, lo, hi, self._cmp, fn)
end

-- Convert to sorted array of {key, value} pairs.
--: (self: TreapObj) -> { [integer]: { [integer]: unknown } }
function Treap:to_array()
  local arr = {}
  each_node(self._root, function(k, v)
    arr[#arr + 1] = {k, v}
  end)
  return arr
end

-- Split at k: returns two new treap objects (keys < k, keys >= k).
--: (self: TreapObj, k: unknown) -> (TreapObj, TreapObj)
function Treap:split(k)
  local l_root, r_root = split(self._root, k, self._cmp)
  -- Count sizes by traversal (split doesn't maintain counts)
  local lsize, rsize = 0, 0
  each_node(l_root, function(_k, _v) lsize = lsize + 1 end)
  each_node(r_root, function(_k, _v) rsize = rsize + 1 end)
  local lt = setmetatable({ _root = l_root, _size = lsize, _cmp = self._cmp }, Treap)
  local rt = setmetatable({ _root = r_root, _size = rsize, _cmp = self._cmp }, Treap)
  -- Invalidate self (consumed by split)
  self._root = nil
  self._size = 0
  return lt, rt
end

-- ---------------------------------------------------------------------------
-- Module-level merge: all keys in left < all keys in right
-- ---------------------------------------------------------------------------

--: (left: TreapObj, right: TreapObj) -> TreapObj
function M.merge(left, right)
  assert(left._cmp == right._cmp, "merge: treaps must use the same comparator")
  local root = merge(left._root, right._root)
  local sz = left._size + right._size
  local t = setmetatable({ _root = root, _size = sz, _cmp = left._cmp }, Treap)
  -- Invalidate inputs
  left._root = nil; left._size = 0
  right._root = nil; right._size = 0
  return t
end

-- ---------------------------------------------------------------------------
-- Constructor
-- ---------------------------------------------------------------------------

-- Create a new empty treap.
-- cmp: optional comparator function(a, b) -> negative/zero/positive
function M.new(cmp)
  return setmetatable({
    _root = nil,
    _size = 0,
    _cmp = cmp or default_cmp,
  }, Treap)
end

return M
