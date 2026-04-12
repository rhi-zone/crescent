if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- LRU (Least Recently Used) cache with O(1) get/set.
-- Uses a doubly-linked list + hash map for O(1) operations.
-- The list is ordered MRU (head) → LRU (tail).
-- Sentinel nodes `self._head` and `self._tail` are never evicted.
local M = {}
M._tier = "pure"

-- Node layout: { key, value, prev, next }
-- _head.next = MRU node; _tail.prev = LRU node

local Cache = {}
Cache.__index = Cache

--- Create a new LRU cache with the given capacity (must be >= 1).
function M.new(capacity)
  assert(capacity and capacity >= 1, "capacity must be >= 1")
  local head = {}   -- sentinel MRU end
  local tail = {}   -- sentinel LRU end
  head[4] = tail    -- head.next = tail
  tail[3] = head    -- tail.prev = head
  return setmetatable({
    _cap      = capacity,
    _len      = 0,
    _map      = {},   -- key → node
    _head     = head,
    _tail     = tail,
    _on_evict = nil,
  }, Cache)
end

-- Unlink a node from the list (does not touch _map).
local function _unlink(node)
  local p, n = node[3], node[4]
  p[4] = n  -- prev.next = next
  n[3] = p  -- next.prev = prev
end

-- Insert a node right after _head (MRU position).
local function _insert_front(self, node)
  local head = self._head
  local after = head[4]
  node[3] = head   -- node.prev = head
  node[4] = after  -- node.next = old first
  head[4] = node
  after[3] = node
end

--- Get the value for key; promotes it to MRU. Returns nil if absent.
function Cache:get(key)
  local node = self._map[key]
  if not node then return nil end
  _unlink(node)
  _insert_front(self, node)
  return node[2]
end

--- Peek at the value for key without promoting it. Returns nil if absent.
function Cache:peek(key)
  local node = self._map[key]
  if not node then return nil end
  return node[2]
end

--- Return true if key is present.
function Cache:has(key)
  return self._map[key] ~= nil
end

--- Set key to value. Promotes to MRU. Evicts LRU if at capacity.
function Cache:set(key, value)
  local node = self._map[key]
  if node then
    node[2] = value
    _unlink(node)
    _insert_front(self, node)
    return
  end
  -- Evict LRU if full.
  if self._len == self._cap then
    local lru = self._tail[3]  -- node just before tail sentinel
    _unlink(lru)
    self._map[lru[1]] = nil
    self._len = self._len - 1
    if self._on_evict then
      self._on_evict(lru[1], lru[2])
    end
  end
  local new_node = { key, value, nil, nil }
  self._map[key] = new_node
  _insert_front(self, new_node)
  self._len = self._len + 1
end

--- Delete a key. Returns true if it existed, false otherwise.
function Cache:delete(key)
  local node = self._map[key]
  if not node then return false end
  _unlink(node)
  self._map[key] = nil
  self._len = self._len - 1
  return true
end

--- Return the current number of entries.
function Cache:size()
  return self._len
end

--- Remove all entries.
function Cache:clear()
  self._map = {}
  self._len = 0
  -- Re-link sentinels.
  self._head[4] = self._tail
  self._tail[3] = self._head
end

--- Return keys in MRU → LRU order.
function Cache:keys()
  local result = {}
  local node = self._head[4]
  local tail = self._tail
  while node ~= tail do
    result[#result + 1] = node[1]
    node = node[4]
  end
  return result
end

--- Set a callback invoked with (key, value) whenever an entry is evicted.
-- Pass nil to remove the callback.
function Cache:evict_callback(fn)
  self._on_evict = fn
end

return M
