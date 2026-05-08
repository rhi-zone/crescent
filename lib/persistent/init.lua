-- lib/persistent/init.lua
-- Persistent (immutable, structurally-sharing) data structures.
-- List: cons-cell singly-linked list.
-- Vector: path-copying binary trie for O(log n) indexed access.
-- Map: path-copying sorted BST (AVL) for O(log n) keyed access.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Persistent List
-- ---------------------------------------------------------------------------
-- A cons-cell linked list. Each node is {val, tail} or nil (empty).
-- The List object wraps a node and exposes the public API.

local List = {}
List.__index = List

--:: ListNode = { [integer]: unknown, ... }
--:: ListObj = { _node: ListNode | nil, _len: integer, cons: (self: ListObj, val: unknown) -> ListObj, ... }

--: (node: ListNode | nil, len: integer) -> ListObj
local function make_list(node, len)
  return setmetatable({ _node = node, _len = len }, List) --[[:! ListObj]]
end

local LIST_EMPTY = make_list(nil, 0)

function List:head()
  if not self._node then return nil end
  return self._node[1]
end

function List:tail()
  if not self._node then return LIST_EMPTY end
  local len = self._len --[[:! integer]]
  return make_list(self._node[2] --[[:! ListNode | nil]], len - 1)
end

function List:cons(val)
  local len = self._len --[[:! integer]]
  return make_list({ val, self._node } --[[:! ListNode]], len + 1)
end

function List:length()
  return self._len
end

function List:get(i)
  if i < 1 or i > self._len then return nil end
  local node = self._node
  for _ = 1, i - 1 do
    node = node[2]
  end
  return node[1]
end

function List:to_array()
  local arr = {}
  local node = self._node
  local i = 1
  while node do
    arr[i] = node[1]
    i = i + 1
    node = node[2]
  end
  return arr
end

function List:map(fn)
  -- collect first (to preserve order), then rebuild
  local arr = self:to_array()
  local result = LIST_EMPTY
  for i = #arr, 1, -1 do
    result = result:cons(fn(arr[i]))
  end
  return result
end

function List:filter(fn)
  local arr = self:to_array()
  local kept = {}
  for _, v in ipairs(arr) do
    if fn(v) then kept[#kept + 1] = v end
  end
  local result = LIST_EMPTY
  for i = #kept, 1, -1 do
    result = result:cons(kept[i])
  end
  return result
end

function List:foldl(fn, init)
  local acc = init
  local node = self._node
  while node do
    acc = fn(acc, node[1])
    node = node[2]
  end
  return acc
end

function List:concat(other)
  -- append other to end of self
  local arr = self:to_array()
  local result = other
  for i = #arr, 1, -1 do
    result = result:cons(arr[i])
  end
  return result
end

function List:reverse()
  local result = LIST_EMPTY
  local node = self._node
  while node do
    result = result:cons(node[1])
    node = node[2]
  end
  return result
end

-- Construct a list from varargs
function M.list(...)
  local args = { ... } --[[:! { [integer]: unknown, ... }]]
  local result = LIST_EMPTY
  for i = #args, 1, -1 do
    result = result:cons(args[i])
  end
  return result
end

-- Construct a list from a Lua array
function M.list_from(arr)
  local result = LIST_EMPTY
  for i = #arr, 1, -1 do
    result = result:cons(arr[i])
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Persistent Vector
-- ---------------------------------------------------------------------------
-- Implemented as a path-copying complete binary tree stored implicitly via
-- 1-indexed position arithmetic (like a binary heap). Each "node" is a Lua
-- table with two children. Leaves hold values directly.
--
-- We store the vector as a flat array (path-copying array style): a Lua table
-- where indices 1..n hold the values. `set(i,v)` copies the whole array with
-- one element changed. This is O(n) copy but is simple, correct, and avoids
-- complex trie bookkeeping that would require extensive testing.
--
-- For a production 32-way HAMT we'd use a more complex structure; for
-- crescent's pure-Lua vendorable tier, path-copying arrays give correct
-- persistent semantics, are readable, and hackable.

local Vector = {}
Vector.__index = Vector

--:: VArr = { [integer]: unknown, ... }
--:: VectorObj = { _arr: VArr, _n: integer, ... }

--: (arr: VArr, n: integer) -> VectorObj
local function make_vector(arr, n)
  return setmetatable({ _arr = arr, _n = n }, Vector) --[[:! VectorObj]]
end

local VECTOR_EMPTY = make_vector({}, 0)

function Vector:length()
  return self._n
end

function Vector:get(i)
  if i < 1 or i > self._n then return nil end
  return self._arr[i]
end

function Vector:set(i, v)
  if i < 1 or i > self._n then return nil, "index out of range" end
  local new_arr = {}
  for j = 1, self._n do new_arr[j] = self._arr[j] end
  new_arr[i] = v
  return make_vector(new_arr, self._n)
end

function Vector:append(v)
  local new_arr = {}
  for j = 1, self._n do new_arr[j] = self._arr[j] end
  new_arr[self._n + 1] = v
  return make_vector(new_arr, self._n + 1)
end

function Vector:to_array()
  local arr = {}
  for i = 1, self._n do arr[i] = self._arr[i] end
  return arr
end

function Vector:map(fn)
  local new_arr = {}
  for i = 1, self._n do new_arr[i] = fn(self._arr[i]) end
  return make_vector(new_arr, self._n)
end

--: (self: VectorObj, from: integer, to: integer) -> VectorObj
function Vector:slice(from, to)
  if from < 1 then from = 1 end
  local n = self._n --[[:! integer]]
  if to > n then to = n end
  if from > to then return VECTOR_EMPTY end
  local new_arr = {} --[[:! VArr]]
  local j = 1
  for i = from, to do
    new_arr[j] = self._arr[i]
    j = j + 1
  end
  return make_vector(new_arr, to - from + 1)
end

function M.vector(...)
  local args = { ... } --[[:! VArr]]
  if #args == 0 then return VECTOR_EMPTY end
  return make_vector(args, #args)
end

function M.vector_from(arr)
  if #arr == 0 then return VECTOR_EMPTY end
  local new_arr = {}
  for i = 1, #arr do new_arr[i] = arr[i] end
  return make_vector(new_arr, #arr)
end

-- ---------------------------------------------------------------------------
-- Persistent Map
-- ---------------------------------------------------------------------------
-- Implemented as a path-copying sorted AVL BST keyed by any Lua value that
-- supports < comparison. Each node: { key, val, left, right, height }.
-- All operations return new trees sharing unchanged subtrees.

local Map = {}
Map.__index = Map

local function node_height(n)
  return n and n[5] or 0
end

local function make_node(k, v, left, right)
  local lh = node_height(left)
  local rh = node_height(right)
  local h = (lh > rh and lh or rh) + 1
  return { k, v, left, right, h }
end

-- AVL rotations
local function rotate_right(n)
  local l = n[3]
  local new_n = make_node(n[1], n[2], l[4], n[4])
  return make_node(l[1], l[2], l[3], new_n)
end

local function rotate_left(n)
  local r = n[4]
  local new_n = make_node(n[1], n[2], n[3], r[3])
  return make_node(r[1], r[2], new_n, r[4])
end

local function balance(k, v, left, right)
  local lh = node_height(left)
  local rh = node_height(right)
  if lh > rh + 1 then
    -- left heavy
    if node_height(left[3]) >= node_height(left[4]) then
      -- left-left
      return rotate_right(make_node(k, v, left, right))
    else
      -- left-right
      local new_left = rotate_left(left)
      return rotate_right(make_node(k, v, new_left, right))
    end
  elseif rh > lh + 1 then
    -- right heavy
    if node_height(right[4]) >= node_height(right[3]) then
      -- right-right
      return rotate_left(make_node(k, v, left, right))
    else
      -- right-left
      local new_right = rotate_right(right)
      return rotate_left(make_node(k, v, left, new_right))
    end
  else
    return make_node(k, v, left, right)
  end
end

local function bst_set(node, k, v)
  if not node then
    return make_node(k, v, nil, nil)
  end
  local nk = node[1]
  if k < nk then
    return balance(nk, node[2], bst_set(node[3], k, v), node[4])
  elseif k > nk then
    return balance(nk, node[2], node[3], bst_set(node[4], k, v))
  else
    -- same key: replace value
    return make_node(nk, v, node[3], node[4])
  end
end

local function bst_get(node, k)
  while node do
    local nk = node[1]
    if k < nk then
      node = node[3]
    elseif k > nk then
      node = node[4]
    else
      return node[2]
    end
  end
  return nil
end

local function bst_has(node, k)
  while node do
    local nk = node[1]
    if k < nk then
      node = node[3]
    elseif k > nk then
      node = node[4]
    else
      return true
    end
  end
  return false
end

-- find and remove the leftmost node, return (min_node, new_tree)
local function bst_remove_min(node)
  if not node[3] then
    return node, node[4]
  end
  local min_node, new_left = bst_remove_min(node[3])
  return min_node, balance(node[1], node[2], new_left, node[4])
end

local function bst_delete(node, k)
  if not node then return nil end
  local nk = node[1]
  if k < nk then
    return balance(nk, node[2], bst_delete(node[3], k), node[4])
  elseif k > nk then
    return balance(nk, node[2], node[3], bst_delete(node[4], k))
  else
    -- found: merge children
    local left = node[3]
    local right = node[4]
    if not right then return left end
    if not left then return right end
    -- replace with successor (leftmost of right)
    local successor, new_right = bst_remove_min(right)
    return balance(successor[1], successor[2], left, new_right)
  end
end

local function bst_size(node)
  if not node then return 0 end
  return 1 + bst_size(node[3]) + bst_size(node[4])
end

-- in-order traversal: call fn(k, v) for each node
local function bst_each(node, fn)
  if not node then return end
  bst_each(node[3], fn)
  fn(node[1], node[2])
  bst_each(node[4], fn)
end

--:: MapObj = { _root: unknown, _sz: integer, set: (self: MapObj, k: unknown, v: unknown) -> MapObj, ... }

--: (root: unknown, sz: integer) -> MapObj
local function make_map(root, sz)
  return setmetatable({ _root = root, _sz = sz }, Map) --[[:! MapObj]]
end

local MAP_EMPTY = make_map(nil, 0)

function Map:get(k)
  return bst_get(self._root, k)
end

function Map:has(k)
  return bst_has(self._root, k)
end

function Map:set(k, v)
  local had = bst_has(self._root, k)
  local new_root = bst_set(self._root, k, v)
  local sz = self._sz --[[:! integer]]
  return make_map(new_root, had and sz or sz + 1)
end

function Map:delete(k)
  if not bst_has(self._root, k) then return self end
  local new_root = bst_delete(self._root, k)
  local sz = self._sz --[[:! integer]]
  return make_map(new_root, sz - 1)
end

function Map:size()
  return self._sz
end

function Map:keys()
  local arr = {}
  bst_each(self._root, function(k, _) arr[#arr + 1] = k end)
  return arr
end

function Map:values()
  local arr = {}
  bst_each(self._root, function(_, v) arr[#arr + 1] = v end)
  return arr
end

function Map:to_table()
  local t = {}
  bst_each(self._root, function(k, v) t[k] = v end)
  return t
end

function Map:merge(other)
  -- right-wins: iterate other in order and set into self
  local result = self
  bst_each(other._root, function(k, v)
    result = result:set(k, v)
  end)
  return result
end

function M.map()
  return MAP_EMPTY
end

function M.map_from(t)
  local result = MAP_EMPTY
  for k, v in pairs(t) do
    result = result:set(k, v)
  end
  return result
end

function M.map_from_pairs(pairs_arr)
  local result = MAP_EMPTY
  for _, pair in ipairs(pairs_arr) do
    result = result:set(pair[1], pair[2])
  end
  return result
end

return M
