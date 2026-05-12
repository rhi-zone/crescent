if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: CacheNode = { key: unknown, value: unknown, prev: CacheNode | nil, next: CacheNode | nil, expires_at: number | nil }

--:: Cache = { _cap: integer, _size: integer, _map: { [unknown]: CacheNode }, _head: CacheNode | nil, _tail: CacheNode | nil, _ttl: number | nil, _on_evict: ((unknown, unknown) -> nil) | nil, _clock: (() -> number) | nil }

--:: CacheOpts = { ttl: number | nil, on_evict: ((unknown, unknown) -> nil) | nil, clock: (() -> number) | nil }

local Cache = {}
Cache.__index = Cache

-- Create a new LRU cache with the given maximum capacity.
-- opts.ttl: default TTL in seconds (optional)
-- opts.on_evict: callback(key, value) on eviction (optional)
-- opts.clock: injectable clock function (required for TTL)
--: (number, CacheOpts | nil) -> Cache | (nil, string)
function M.new(capacity, opts)
  if type(capacity) ~= "number" or capacity < 1 then
    return nil, "capacity must be a positive number"
  end
  capacity = math.floor(capacity)
  local self = setmetatable({
    _cap = capacity,
    _size = 0,
    _map = {},       -- key -> node
    _head = nil,     -- most recent
    _tail = nil,     -- least recent
    _ttl = opts and opts.ttl or nil,
    _on_evict = opts and opts.on_evict or nil,
    _clock = opts and opts.clock or nil,
  }, Cache)
  return self
end

-- Detach a node from the doubly-linked list.
--: (Cache, CacheNode) -> nil
local function _detach(self, node)
  local p, n = node.prev, node.next
  if p then p.next = n else self._head = n end
  if n then n.prev = p else self._tail = p end
  node.prev = nil
  node.next = nil
end

-- Push a node to the head (most recent).
--: (Cache, CacheNode) -> nil
local function _push_head(self, node)
  node.prev = nil
  node.next = self._head
  if self._head then self._head.prev = node end
  self._head = node
  if not self._tail then self._tail = node end
end

-- Move an existing node to the head.
--: (Cache, CacheNode) -> nil
local function _promote(self, node)
  if node == self._head then return end
  _detach(self, node)
  _push_head(self, node)
end

-- Check if a node has expired. If expired, remove it and fire on_evict.
-- Returns true if the node was expired and removed.
--: (Cache, CacheNode) -> boolean
local function _check_expired(self, node)
  local expires_at = node.expires_at
  if not expires_at then return false end
  local at = expires_at --[[:! number]]
  local clock = self._clock
  if not clock then return false end
  if (clock --[[:! () -> number]])() < at then return false end
  _detach(self, node)
  self._map[node.key] = nil
  self._size = self._size - 1
  local evict = self._on_evict
  if evict then (evict --[[:! (unknown, unknown) -> nil]])(node.key, node.value) end
  return true
end

-- Evict the tail (least recently used) node.
--: (Cache) -> nil
local function _evict_tail(self)
  local node = self._tail
  if not node then return end
  local n = node --[[:! CacheNode]]
  _detach(self, n)
  self._map[n.key] = nil
  self._size = self._size - 1
  local evict = self._on_evict
  if evict then (evict --[[:! (unknown, unknown) -> nil]])(n.key, n.value) end
end

-- Set a key-value pair. Returns the old value if the key existed, or nil.
-- ttl overrides the default TTL for this entry (in seconds).
--: (Cache, unknown, unknown, number | nil) -> unknown | nil
function Cache:set(key, value, ttl)
  local node = self._map[key]
  local clock = self._clock
  local function compute_expiry(t)
    if not t then return nil end
    if not clock then return nil end
    return (clock --[[:! () -> number]])() + t
  end
  if node then
    -- Key exists: update value, promote, update expiry
    local old = node.value
    node.value = value
    local t = ttl or self._ttl
    node.expires_at = compute_expiry(t)
    _promote(self, node)
    return old
  end
  -- New key: evict if at capacity
  if self._size >= self._cap then
    _evict_tail(self)
  end
  local t = ttl or self._ttl
  local new_node --[[:! CacheNode]] = {
    key = key,
    value = value,
    prev = nil,
    next = nil,
    expires_at = compute_expiry(t),
  }
  self._map[key] = new_node
  self._size = self._size + 1
  _push_head(self, new_node)
  return nil
end

-- Get the value for a key, promoting it to most recent.
-- Returns nil if missing or expired.
--: (Cache, unknown) -> unknown | nil
function Cache:get(key)
  local node = self._map[key]
  if not node then return nil end
  if _check_expired(self, node) then return nil end
  _promote(self, node)
  return node.value
end

-- Get the value for a key without promoting it.
-- Returns nil if missing or expired.
--: (Cache, unknown) -> unknown | nil
function Cache:peek(key)
  local node = self._map[key]
  if not node then return nil end
  if _check_expired(self, node) then return nil end
  return node.value
end

-- Check if a key exists and is not expired.
--: (Cache, unknown) -> boolean
function Cache:has(key)
  local node = self._map[key]
  if not node then return false end
  if _check_expired(self, node) then return false end
  return true
end

-- Delete a key. Returns the old value, or nil if not found.
--: (Cache, unknown) -> unknown | nil
function Cache:delete(key)
  local node = self._map[key]
  if not node then return nil end
  _detach(self, node)
  self._map[key] = nil
  self._size = self._size - 1
  return node.value
end

-- Remove all entries. Does NOT fire on_evict.
function Cache:clear()
  self._map = {}
  self._head = nil
  self._tail = nil
  self._size = 0
end

-- Return the number of live (non-expired) entries.
-- Note: this is O(1) and does not scan for expired entries.
--: () -> number
function Cache:count()
  return self._size
end

-- Return the maximum capacity.
--: () -> number
function Cache:capacity()
  return self._cap
end

-- Return an array of keys in order from most recent to least recent.
-- Expired entries are skipped (and lazily removed).
--: () -> { [number]: unknown }
function Cache:keys()
  local result = {}
  local node = self._head
  while node do
    local cur = node --[[:! CacheNode]]
    local nxt = cur.next
    if not _check_expired(self, cur) then
      result[#result + 1] = cur.key
    end
    node = nxt
  end
  return result
end

-- Iterator over (key, value) pairs, most recent first.
-- Expired entries are skipped (and lazily removed).
--: () -> () -> (unknown, unknown)
function Cache:pairs()
  local node = self._head
  return function()
    while node do
      local current = node --[[:! CacheNode]]
      node = current.next
      if not _check_expired(self, current) then
        return current.key, current.value
      end
    end
    return nil
  end
end

-- Set multiple key-value pairs. Each entry is {key, value} or {key, value, ttl}.
--: (Cache, { [number]: { [number]: unknown } }) -> nil
function Cache:set_many(entries)
  local set_fn = Cache.set
  for i = 1, #entries do
    local e = entries[i]
    set_fn(self, e[1], e[2], e[3] --[[:! number | nil]])
  end
end

-- Get multiple keys. Returns a table mapping each found key to its value.
--: (Cache, { [number]: unknown }) -> { [unknown]: unknown }
function Cache:get_many(keys_list)
  local get_fn = Cache.get
  local result = {}
  for i = 1, #keys_list do
    local k = keys_list[i]
    local v = get_fn(self, k)
    if v ~= nil then
      result[k] = v
    end
  end
  return result
end

-- Resize the cache. If shrinking, evicts least recently used entries.
function Cache:resize(new_cap)
  if type(new_cap) ~= "number" or new_cap < 1 then
    return nil, "capacity must be a positive number"
  end
  new_cap = math.floor(new_cap)
  while self._size > new_cap do
    _evict_tail(self)
  end
  self._cap = new_cap
end

return M
