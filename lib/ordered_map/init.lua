-- lib/ordered_map/init.lua
-- Insertion-order preserving map (LinkedHashMap equivalent).
-- Doubly-linked list of nodes + hash table: O(1) get/set/delete.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: OmNode = { key: any, value: any, prev: OmNode | nil, next: OmNode | nil }
--:: OmMap = { _map: { [any]: OmNode }, _head: OmNode | nil, _tail: OmNode | nil, _len: integer, ... }

-- Node fields: key, value, prev, next

local om_mt = {}
om_mt.__index = om_mt

-- Internal: unlink a node from the list (does not remove from hash).
local function unlink(self, node)
  local p, n = node.prev, node.next
  if p then p.next = n else self._head = n end
  if n then n.prev = p else self._tail = p end
  node.prev = nil
  node.next = nil
end

-- Internal: append a node at the tail.
local function append_tail(self, node)
  node.prev = self._tail
  node.next = nil
  if self._tail then self._tail.next = node else self._head = node end
  self._tail = node
end

-- Internal: prepend a node at the head.
local function prepend_head(self, node)
  node.next = self._head
  node.prev = nil
  if self._head then self._head.prev = node else self._tail = node end
  self._head = node
end

--- Create a new empty ordered map.
function M.new()
  local head = nil --: OmNode | nil
  local tail = nil --: OmNode | nil
  local len = 0 --: integer
  return setmetatable({ _map = {}, _head = head, _tail = tail, _len = len }, om_mt)
end

--- Construct from a plain table, with optional explicit key order.
-- @param t  plain Lua table
-- @param keys  array of keys specifying insertion order (default: pairs order)
function M.from_table(t, keys)
  local om = M.new()
  if keys then
    for _, k in ipairs(keys) do
      if t[k] ~= nil then om:set(k, t[k]) end
    end
  else
    for k, v in pairs(t) do om:set(k, v) end
  end
  return om
end

--- Construct from an array of {key, value} pairs.
function M.from_entries(arr)
  local om = M.new()
  for _, entry in ipairs(arr) do
    om:set(entry[1], entry[2])
  end
  return om
end

--- Insert or update a key. Updates keep the existing position.
--: (self: OmMap, k: any, v: any) -> nil
function om_mt:set(k, v)
  local node = self._map[k]
  if node then
    node.value = v
  else
    node = { key = k, value = v }
    self._map[k] = node
    append_tail(self, node)
    self._len = self._len + 1
  end
end

--- Get the value for a key, or nil.
function om_mt:get(k)
  local node = self._map[k]
  return node and node.value
end

--- Return true if the key exists.
function om_mt:has(k)
  return self._map[k] ~= nil
end

--- Delete a key. Returns true if deleted, false if not present.
--: (self: OmMap, k: any) -> boolean
function om_mt:delete(k)
  local node = self._map[k]
  if not node then return false end
  unlink(self, node)
  self._map[k] = nil
  self._len = self._len - 1
  return true
end

--- Return the number of entries.
function om_mt:len()
  return self._len
end

--- Iterator in insertion order (k, v).
function om_mt:each()
  local node = self._head
  return function()
    if not node then return nil end
    local k, v = node.key, node.value
    node = node.next
    return k, v
  end
end

--- Iterator in reverse insertion order (k, v).
function om_mt:each_reverse()
  local node = self._tail
  return function()
    if not node then return nil end
    local k, v = node.key, node.value
    node = node.prev
    return k, v
  end
end

--- Return an array of keys in insertion order.
function om_mt:keys()
  local arr, i = {}, 1
  local node = self._head
  while node do
    arr[i] = node.key
    i = i + 1
    node = node.next
  end
  return arr
end

--- Return an array of values in insertion order.
function om_mt:values()
  local arr, i = {}, 1
  local node = self._head
  while node do
    arr[i] = node.value
    i = i + 1
    node = node.next
  end
  return arr
end

--- Return an array of {key, value} pairs in insertion order.
function om_mt:entries()
  local arr, i = {}, 1
  local node = self._head
  while node do
    arr[i] = { node.key, node.value }
    i = i + 1
    node = node.next
  end
  return arr
end

--- Return the key and value at 1-based index i (negative = from end).
-- Returns nil, nil if out of range.
--: (self: OmMap, i: integer) -> (any, any)
function om_mt:at(i)
  local len = self._len
  if i < 0 then i = len + i + 1 end
  if i < 1 or i > len then return nil, nil end
  local node
  if i <= len / 2 then
    node = self._head
    for _ = 1, i - 1 do node = node.next end
  else
    node = self._tail
    for _ = len, i + 1, -1 do node = node.prev end
  end
  return node.key, node.value
end

--- Move an existing key to the end of the order. No-op if key absent.
function om_mt:move_to_end(k)
  local node = self._map[k]
  if not node then return end
  if node == self._tail then return end
  unlink(self, node)
  append_tail(self, node)
end

--- Move an existing key to the front of the order. No-op if key absent.
function om_mt:move_to_front(k)
  local node = self._map[k]
  if not node then return end
  if node == self._head then return end
  unlink(self, node)
  prepend_head(self, node)
end

--- Return a new ordered_map with entries from index i to j (1-based).
--: (self: OmMap, i: integer, j: integer) -> OmMap
function om_mt:slice(i, j)
  local len = self._len
  if i < 0 then i = len + i + 1 end
  if j < 0 then j = len + j + 1 end
  i = math.max(1, i)
  j = math.min(len, j)
  local result = M.new()
  local idx = 1
  local node = self._head
  while node and idx <= j do
    if idx >= i then result:set(node.key, node.value) end
    idx = idx + 1
    node = node.next
  end
  return result
end

--- Return an independent copy with the same insertion order.
--: (self: OmMap) -> OmMap
function om_mt:copy()
  local result = M.new()
  local node = self._head
  while node do
    result:set(node.key, node.value)
    node = node.next
  end
  return result
end

--- Return a plain Lua table (loses order).
function om_mt:to_table()
  local t = {}
  local node = self._head
  while node do
    t[node.key] = node.value
    node = node.next
  end
  return t
end

--- Return a new ordered_map by applying fn(k, v) -> newk, newv to every entry.
function om_mt:map(fn)
  local result = M.new()
  local node = self._head
  while node do
    local nk, nv = fn(node.key, node.value)
    result:set(nk, nv)
    node = node.next
  end
  return result
end

--- Return a new ordered_map keeping only entries where pred(k, v) is true.
--: (self: OmMap, pred: (any, any) -> boolean) -> OmMap
function om_mt:filter(pred)
  local result = M.new()
  local node = self._head
  while node do
    if pred(node.key, node.value) then result:set(node.key, node.value) end
    node = node.next
  end
  return result
end

return M
