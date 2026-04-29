if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Default comparator: min-heap (lower key = higher priority)
local function default_cmp(a, b) return a < b end

-- Internal: merge two heap nodes (h2 becomes child of winner)
-- Returns the new root node (or nil if both nil)
local function heap_merge(h1, h2, cmp)
  if h1 == nil then return h2 end
  if h2 == nil then return h1 end
  if cmp(h1.key, h2.key) then
    -- h1 wins: h2 becomes leftmost child of h1
    local c = h1.children
    c[#c + 1] = h2
    return h1
  else
    -- h2 wins: h1 becomes leftmost child of h2
    local c = h2.children
    c[#c + 1] = h1
    return h2
  end
end

-- Two-pass pairing of a list of sub-heaps
local function pair_children(children, cmp)
  local n = #children
  if n == 0 then return nil end
  if n == 1 then return children[1] end
  -- First pass: merge consecutive pairs
  local pairs = {}
  local i = 1
  while i <= n do
    if i + 1 <= n then
      pairs[#pairs + 1] = heap_merge(children[i], children[i + 1], cmp)
      i = i + 2
    else
      pairs[#pairs + 1] = children[i]
      i = i + 1
    end
  end
  -- Second pass: merge right to left
  local result = pairs[#pairs]
  for j = #pairs - 1, 1, -1 do
    result = heap_merge(pairs[j], result, cmp)
  end
  return result
end

-- Advance root past lazily-deleted nodes, rebuilding heap as needed.
-- Does NOT touch _n: remove() already decremented it at removal time.
local function normalize(heap)
  while heap._root ~= nil and heap._root.removed do
    local children = heap._root.children
    heap._root.children = nil  -- help GC
    heap._root = pair_children(children, heap._cmp)
  end
end

-- Heap metatable
local Heap = {}
Heap.__index = Heap

--- Create a new pairing heap.
-- cmp(a, b) returns true if a has higher priority than b (default: min-heap)
--: (cmp: ((a: unknown, b: unknown) -> boolean) | nil) -> Heap
function M.new(cmp)
  return setmetatable({
    _root = nil,
    _n = 0,
    _cmp = cmp or default_cmp,
    _next_id = 0,
    _handles = {},  -- handle_id -> node
  }, Heap)
end

--- Insert a key-value pair. Returns a handle for decrease_key/remove.
--: (self: Heap, key: unknown, value: unknown) -> handle
function Heap:insert(key, value)
  local id = self._next_id + 1
  self._next_id = id
  local node = {
    key = key,
    value = value,
    children = {},
    removed = false,
    handle_id = id,
  }
  self._handles[id] = node
  self._root = heap_merge(self._root, node, self._cmp)
  self._n = self._n + 1
  return node  -- the node itself is the handle
end

--- Get minimum key and value without removing. Returns nil, nil if empty.
--: (self: Heap) -> (unknown, unknown)
function Heap:peek()
  normalize(self)
  if self._root == nil then return nil, nil end
  return self._root.key, self._root.value
end

--- Remove and return minimum key and value. Returns nil, nil if empty.
--: (self: Heap) -> (unknown, unknown)
function Heap:pop()
  normalize(self)
  if self._root == nil then return nil, nil end
  local root = self._root
  local key, value = root.key, root.value
  self._handles[root.handle_id] = nil
  root.removed = true  -- mark as gone
  local children = root.children
  root.children = nil  -- help GC
  self._n = self._n - 1
  self._root = pair_children(children, self._cmp)
  return key, value
end

--- Decrease key of a handle (lazy: mark old node removed, insert new node).
-- new_key must have higher priority than old_key (i.e. cmp(new_key, old_key) == true
-- or new_key == old_key). Returns new handle on success, nil + err on failure.
--: (self: Heap, handle: handle, new_key: unknown) -> (handle | nil, string | nil)
function Heap:decrease_key(handle, new_key)
  if handle.removed then
    return nil, "handle is already removed"
  end
  -- Validate: new_key must be <= old_key in heap order
  -- (i.e. new_key has >= priority: cmp(new_key, old_key) or equal)
  if handle.key ~= new_key and not self._cmp(new_key, handle.key) then
    return nil, "new_key does not have higher priority than current key"
  end
  -- Mark old node as removed (lazy deletion)
  handle.removed = true
  self._handles[handle.handle_id] = nil
  self._n = self._n - 1
  -- Insert new node with updated key
  return self:insert(new_key, handle.value)
end

--- Remove an arbitrary element by handle (lazy deletion).
--: (self: Heap, handle: handle) -> nil
function Heap:remove(handle)
  if handle.removed then return end
  handle.removed = true
  self._handles[handle.handle_id] = nil
  self._n = self._n - 1
end

--- Merge another heap into this one (destructive: other becomes empty).
--: (self: Heap, other: Heap) -> nil
function Heap:merge(other)
  self._root = heap_merge(self._root, other._root, self._cmp)
  self._n = self._n + other._n
  -- Transfer handles
  for id, node in pairs(other._handles) do
    self._handles[id] = node
  end
  -- Clear other
  other._root = nil
  other._n = 0
  other._handles = {}
end

--- Return the number of live elements.
--: (self: Heap) -> number
function Heap:size()
  return self._n
end

--- Return true if the heap is empty.
--: (self: Heap) -> boolean
function Heap:is_empty()
  return self._n == 0
end

--- Convert to sorted array of {key, value} pairs (consumes the heap).
--: (self: Heap) -> {{unknown, unknown}}
function Heap:to_sorted()
  local result = {}
  while true do
    local k, v = self:pop()
    if k == nil then break end
    result[#result + 1] = { k, v }
  end
  return result
end

return M
