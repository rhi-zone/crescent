if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: CombineFn = (any, any) -> any
--:: UpdateFn = (any, any, integer) -> any
--:: ComposeFn = (any, any) -> any
--:: TreeT = { _data: { [integer]: any }, _n: integer, _size: integer, _combine: CombineFn, ... }
--:: LazyTreeT = { _data: { [integer]: any }, _lazy: { [integer]: any }, _n: integer, _size: integer, _combine: CombineFn, _update: UpdateFn, _compose: ComposeFn, _identity: any, _push_down: (self: LazyTreeT, i: integer, node_l: integer, node_r: integer, n: integer) -> nil, _range_update: (self: LazyTreeT, node: integer, node_l: integer, node_r: integer, l: integer, r: integer, val: any) -> nil, _query: (self: LazyTreeT, node: integer, node_l: integer, node_r: integer, l: integer, r: integer) -> any, ... }
--:: PNode = { val: any, left: any, right: any }
--:: PTreeT = { _root: PNode, _n: integer, _combine: CombineFn, ... }
--:: SparseTreeT = { _root: any, _min: integer, _max: integer, _combine: CombineFn, ... }

-- Common combine functions
--: (number, number) -> number
M.sum = function(a, b) return a + b end
--: (number, number) -> number
M.min = function(a, b) return a < b and a or b end
--: (number, number) -> number
M.max = function(a, b) return a > b and a or b end
--: (integer, integer) -> integer
M.gcd = function(a, b)
  while b ~= 0 do a, b = b, a % b end
  return a
end

-- ============================================================
-- Basic segment tree (point update, range query)
-- ============================================================

local Tree = {}
Tree.__index = Tree

-- Build the internal flat array from the user array.
-- tree.data is 1-indexed, root at 1, children of i at 2i and 2i+1.
-- Leaf data starts at offset tree._offset (next power of 2 >= n).
local function next_pow2(n)
  local p = 1
  while p < n do p = p * 2 end
  return p
end

function M.new(arr, combine_fn)
  local n = #arr
  local size = next_pow2(n)
  local data = {}
  -- Fill with a neutral-like sentinel: we store nil and handle it in combine
  -- by returning the non-nil child (identity for any combine_fn via nil check).
  local t = setmetatable({
    _data = data,
    _n = n,
    _size = size,
    _combine = combine_fn,
  }, Tree)
  -- Copy leaves
  for i = 1, n do
    data[size + i - 1] = arr[i]
  end
  -- Build internal nodes bottom-up
  for i = size - 1, 1, -1 do
    local l = data[2 * i]
    local r = data[2 * i + 1]
    if l == nil then
      data[i] = r
    elseif r == nil then
      data[i] = l
    else
      data[i] = combine_fn(l, r)
    end
  end
  return t
end

--: (self: TreeT) -> integer
function Tree:len()
  return self._n
end

--: (self: TreeT, i: integer) -> any
function Tree:get(i)
  return self._data[self._size + i - 1]
end

--: (self: TreeT, i: integer, val: any) -> nil
function Tree:update(i, val)
  local data = self._data
  local combine = self._combine
  local pos = self._size + i - 1
  data[pos] = val
  pos = math.floor((self._size + i - 1) / 2)
  while pos >= 1 do
    local l = data[2 * pos]
    local r = data[2 * pos + 1]
    if l == nil then
      data[pos] = r
    elseif r == nil then
      data[pos] = l
    else
      data[pos] = combine(l, r)
    end
    pos = math.floor(pos / 2)
  end
end

--: (self: TreeT, l: integer, r: integer) -> any
function Tree:query(l, r)
  local data = self._data
  local combine = self._combine
  local size = self._size
  l = l + size - 1
  r = r + size - 1
  local result = nil
  while l <= r do
    if l % 2 == 1 then  -- l is right child
      local v = data[l]
      if v ~= nil then
        result = result == nil and v or combine(result, v)
      end
      l = l + 1
    end
    if r % 2 == 0 then  -- r is left child
      local v = data[r]
      if v ~= nil then
        result = result == nil and v or combine(result, v)
      end
      r = r - 1
    end
    l = math.floor(l / 2)
    r = math.floor(r / 2)
  end
  return result
end

-- ============================================================
-- Lazy segment tree (range update, range query)
-- opts: { combine, update, compose, identity }
--   combine(a, b)       -> merge two node values
--   update(val, lazy)   -> apply lazy tag to a node value
--   compose(a, b)       -> compose two lazy tags (a applied after b)
--   identity            -> identity for combine (nil = no empty ranges)
-- ============================================================

local LazyTree = {}
LazyTree.__index = LazyTree

--: (arr: { [integer]: any }, opts: { combine: CombineFn, update: UpdateFn, compose: ComposeFn, identity: any }) -> LazyTreeT
function M.new_lazy(arr, opts)
  local n = #arr
  local size = next_pow2(n)
  local combine = opts.combine
  local update_fn = opts.update
  local compose_fn = opts.compose
  local identity = opts.identity
  local data = {}
  local lazy = {}  -- lazy tags, nil = no pending update

  local t = setmetatable({
    _data = data,
    _lazy = lazy,
    _n = n,
    _size = size,
    _combine = combine,
    _update = update_fn,
    _compose = compose_fn,
    _identity = identity,
  }, LazyTree)

  for i = 1, n do
    data[size + i - 1] = arr[i]
  end
  for i = size - 1, 1, -1 do
    local l = data[2 * i]
    local r = data[2 * i + 1]
    if l == nil and r == nil then
      data[i] = --[[: any]] identity
    elseif l == nil then
      data[i] = r
    elseif r == nil then
      data[i] = l
    else
      data[i] = combine(l, r)
    end
  end
  return t
end

--: (self: LazyTreeT) -> integer
function LazyTree:len()
  return self._n
end

--: (node_l: integer, node_r: integer, n: integer) -> integer
local function real_count(node_l, node_r, n)
  if node_l > n then return 0 end
  return (node_r < n and node_r or n) - node_l + 1
end

-- Push lazy tag down from node i to its children
-- node_l, node_r: the range this node covers; n: total element count
--: (self: LazyTreeT, i: integer, node_l: integer, node_r: integer, n: integer) -> nil
function LazyTree:_push_down(i, node_l, node_r, n)
  local tag = self._lazy[i]
  if tag == nil then return end
  local data = self._data
  local lazy = self._lazy
  local update_fn = self._update
  local compose_fn = self._compose
  local mid = math.floor((node_l + node_r) / 2)
  local l, r = 2 * i, 2 * i + 1
  local lcount = real_count(node_l, mid, n)
  local rcount = real_count(mid + 1, node_r, n)
  if lcount > 0 then
    data[l] = update_fn(data[l], tag, lcount)
    lazy[l] = lazy[l] ~= nil and compose_fn(tag, lazy[l]) or tag
  end
  if rcount > 0 then
    data[r] = update_fn(data[r], tag, rcount)
    lazy[r] = lazy[r] ~= nil and compose_fn(tag, lazy[r]) or tag
  end
  lazy[i] = nil
end

-- Internal recursive range update
--: (self: LazyTreeT, node: integer, node_l: integer, node_r: integer, l: integer, r: integer, val: any) -> nil
function LazyTree:_range_update(node, node_l, node_r, l, r, val)
  if l > node_r or r < node_l then return end
  local data = self._data
  local lazy = self._lazy
  local update_fn = self._update
  local compose_fn = self._compose
  local n = self._n
  if l <= node_l and node_r <= r then
    local cnt = real_count(node_l, node_r, n)
    if cnt == 0 then return end
    data[node] = update_fn(data[node], val, cnt)
    lazy[node] = lazy[node] ~= nil and compose_fn(val, lazy[node]) or val
    return
  end
  self:_push_down(node, node_l, node_r, n)
  local mid = math.floor((node_l + node_r) / 2)
  self:_range_update(2 * node, node_l, mid, l, r, val)
  self:_range_update(2 * node + 1, mid + 1, node_r, l, r, val)
  local lv = data[2 * node]
  local rv = data[2 * node + 1]
  local lc = real_count(node_l, mid, n)
  local rc = real_count(mid + 1, node_r, n)
  if lc == 0 then
    data[node] = rv
  elseif rc == 0 then
    data[node] = lv
  else
    data[node] = self._combine(lv, rv)
  end
end

--: (self: LazyTreeT, l: integer, r: integer, val: any) -> nil
function LazyTree:range_update(l, r, val)
  self:_range_update(1, 1, self._size, l, r, val)
end

--: (self: LazyTreeT, node: integer, node_l: integer, node_r: integer, l: integer, r: integer) -> any
function LazyTree:_query(node, node_l, node_r, l, r)
  if l > node_r or r < node_l then return nil end
  if l <= node_l and node_r <= r then return self._data[node] end
  local n = self._n
  self:_push_down(node, node_l, node_r, n)
  local mid = math.floor((node_l + node_r) / 2)
  local lv = self:_query(2 * node, node_l, mid, l, r)
  local rv = self:_query(2 * node + 1, mid + 1, node_r, l, r)
  if lv == nil then return rv end
  if rv == nil then return lv end
  return self._combine(lv, rv)
end

--: (self: LazyTreeT, l: integer, r: integer) -> any
function LazyTree:query(l, r)
  return self:_query(1, 1, self._size, l, r)
end

-- ============================================================
-- Persistent segment tree (functional, path copying)
-- Each node is a table: { val, left, right }
-- Leaves store the value; internal nodes store combined value.
-- ============================================================

local PTree = {}
PTree.__index = PTree

--: (arr: { [integer]: any }, l: integer, r: integer, combine_fn: CombineFn) -> PNode
local function pt_build(arr, l, r, combine_fn)
  if l == r then
    return { val = arr[l] or nil, left = nil, right = nil }
  end
  local mid = math.floor((l + r) / 2)
  local left = pt_build(arr, l, mid, combine_fn)
  local right = pt_build(arr, mid + 1, r, combine_fn)
  local val
  if left.val == nil then
    val = right.val
  elseif right.val == nil then
    val = left.val
  else
    val = combine_fn(left.val, right.val)
  end
  return { val = val, left = left, right = right }
end

--: (node: PNode, node_l: integer, node_r: integer, i: integer, val: any, combine_fn: CombineFn) -> PNode
local function pt_update(node, node_l, node_r, i, val, combine_fn)
  if node_l == node_r then
    return { val = val, left = nil, right = nil }
  end
  local mid = math.floor((node_l + node_r) / 2)
  local new_node
  if i <= mid then
    local new_left = pt_update(node.left, node_l, mid, i, val, combine_fn)
    new_node = { val = nil, left = new_left, right = node.right }
  else
    local new_right = pt_update(node.right, mid + 1, node_r, i, val, combine_fn)
    new_node = { val = nil, left = node.left, right = new_right }
  end
  local lv = new_node.left and new_node.left.val
  local rv = new_node.right and new_node.right.val
  if lv == nil then
    new_node.val = rv
  elseif rv == nil then
    new_node.val = lv
  else
    new_node.val = combine_fn(lv, rv)
  end
  return new_node
end

--: (node: PNode | nil, node_l: integer, node_r: integer, l: integer, r: integer, combine_fn: CombineFn) -> any
local function pt_query(node, node_l, node_r, l, r, combine_fn)
  if node == nil then return nil end
  if l > node_r or r < node_l then return nil end
  if l <= node_l and node_r <= r then return node.val end
  local mid = math.floor((node_l + node_r) / 2)
  local lv = pt_query(node.left, node_l, mid, l, r, combine_fn)
  local rv = pt_query(node.right, mid + 1, node_r, l, r, combine_fn)
  if lv == nil then return rv end
  if rv == nil then return lv end
  return combine_fn(lv, rv)
end

function M.persistent(arr, combine_fn)
  local n = #arr
  local root = pt_build(arr, 1, n, combine_fn)
  return setmetatable({
    _root = root,
    _n = n,
    _combine = combine_fn,
  }, PTree)
end

--: (self: PTreeT, i: integer, val: any) -> PTreeT
function PTree:update(i, val)
  local new_root = pt_update(self._root, 1, self._n, i, val, self._combine)
  return setmetatable({
    _root = new_root,
    _n = self._n,
    _combine = self._combine,
  }, PTree)
end

--: (self: PTreeT, l: integer, r: integer) -> any
function PTree:query(l, r)
  return pt_query(self._root, 1, self._n, l, r, self._combine)
end

--: (self: PTreeT) -> integer
function PTree:len()
  return self._n
end

-- ============================================================
-- Sparse segment tree (dynamic node creation for huge ranges)
-- Nodes created on demand; uses table-based nodes like persistent.
-- ============================================================

local SparseTree = {}
SparseTree.__index = SparseTree

--: (node: PNode | nil, node_l: integer, node_r: integer, i: integer, val: any, combine_fn: CombineFn) -> PNode
local function sparse_update(node, node_l, node_r, i, val, combine_fn)
  if node_l == node_r then
    if node == nil then
      return { val = val, left = nil, right = nil }
    end
    node.val = val
    return node
  end
  if node == nil then
    node = { val = nil, left = nil, right = nil }
  end
  local mid = math.floor((node_l + node_r) / 2)
  if i <= mid then
    node.left = sparse_update(node.left, node_l, mid, i, val, combine_fn)
  else
    node.right = sparse_update(node.right, mid + 1, node_r, i, val, combine_fn)
  end
  local lv = node.left and node.left.val
  local rv = node.right and node.right.val
  if lv == nil then
    node.val = rv
  elseif rv == nil then
    node.val = lv
  else
    node.val = combine_fn(lv, rv)
  end
  return node
end

--: (node: PNode | nil, node_l: integer, node_r: integer, l: integer, r: integer, combine_fn: CombineFn) -> any
local function sparse_query(node, node_l, node_r, l, r, combine_fn)
  if node == nil then return nil end
  if l > node_r or r < node_l then return nil end
  if l <= node_l and node_r <= r then return node.val end
  local mid = math.floor((node_l + node_r) / 2)
  local lv = sparse_query(node.left, node_l, mid, l, r, combine_fn)
  local rv = sparse_query(node.right, mid + 1, node_r, l, r, combine_fn)
  if lv == nil then return rv end
  if rv == nil then return lv end
  return combine_fn(lv, rv)
end

function M.sparse(min_idx, max_idx, combine_fn)
  return setmetatable({
    _root = nil,
    _min = min_idx,
    _max = max_idx,
    _combine = combine_fn,
  }, SparseTree)
end

--: (self: SparseTreeT, i: integer, val: any) -> nil
function SparseTree:update(i, val)
  self._root = sparse_update(self._root, self._min, self._max, i, val, self._combine)
end

--: (self: SparseTreeT, l: integer, r: integer) -> any
function SparseTree:query(l, r)
  return sparse_query(self._root, self._min, self._max, l, r, self._combine)
end

return M
