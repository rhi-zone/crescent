if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- LRU cache with TTL expiry, per-entry metadata, stats, and events.
-- O(1) get/set via doubly-linked list + hash map.
-- Lazy expiry: expired entries are removed on access, not on a timer.

local M = {}
M._tier = "pure"

--:: LruNode = { key: unknown, value: unknown, prev: LruNode | nil, next: LruNode | nil, created_at: number, last_access: number, hit_count: number, expires_at: number | nil }
--:: LruStats = { hits: number, misses: number, sets: number, deletes: number, evictions: number, expirations: number }
--:: Cache = { _cap: number, _size: number, _map: { [unknown]: LruNode }, _head: LruNode | nil, _tail: LruNode | nil, _ttl: number | nil, _clock: () -> number, _handlers: { [string]: (unknown, unknown) -> nil }, _stats: LruStats }

-- ── Internal helpers ──────────────────────────────────────────────────────────

--: (self: Cache, node: LruNode) -> nil
local function _detach(self, node)
  local p, n = node.prev, node.next
  if p then p.next = n else self._head = n end
  if n then n.prev = p else self._tail = p end
  node.prev = nil
  node.next = nil
end

--: (self: Cache, node: LruNode) -> nil
local function _push_head(self, node)
  node.prev = nil
  node.next = self._head
  if self._head then self._head.prev = node end
  self._head = node
  if not self._tail then self._tail = node end
end

--: (self: Cache, node: LruNode) -> nil
local function _promote(self, node)
  if node == self._head then return end
  _detach(self, node)
  _push_head(self, node)
end

-- Fire a named event if a handler is registered.
--: (self: Cache, event: string, key: unknown, value: unknown) -> nil
local function _emit(self, event, key, value)
  local h = self._handlers[event]
  if h then h(key, value) end
end

-- Remove an expired node. Returns true if the node was expired.
-- Does NOT count as a miss — callers increment stats themselves.
--: (self: Cache, node: LruNode) -> boolean
local function _remove_expired(self, node)
  if not node.expires_at then return false end
  if self._clock() < node.expires_at then return false end
  _detach(self, node)
  self._map[node.key] = nil
  self._size = self._size - 1
  self._stats.expirations = self._stats.expirations + 1
  _emit(self, "expire", node.key, node.value)
  return true
end

-- Evict the LRU (tail) node due to capacity pressure.
--: (self: Cache) -> nil
local function _evict_tail(self)
  local node = self._tail
  if not node then return end
  local node_ = node --[[:! LruNode]]
  _detach(self, node_)
  self._map[node_.key] = nil
  self._size = self._size - 1
  self._stats.evictions = self._stats.evictions + 1
  _emit(self, "evict", node_.key, node_.value)
end

-- ── Cache object ──────────────────────────────────────────────────────────────

--:: LruTtlOpts = {
--::   max_size: number,
--::   default_ttl: number | nil,
--::   clock: (() -> number) | nil,
--:: }

local Cache = {}
Cache.__index = Cache

-- Create a new LRU+TTL cache.
-- opts.max_size:    maximum number of entries (required, positive integer)
-- opts.default_ttl: default TTL in seconds; nil means no expiry
-- opts.clock:       injectable clock function (required)
--: (opts: LruTtlOpts) -> (Cache | nil, string | nil)
function M.new(opts)
  if type(opts) ~= "table" then
    return nil, "opts must be a table"
  end
  local max_size = opts.max_size
  if type(max_size) ~= "number" or max_size < 1 then
    return nil, "opts.max_size must be a positive number"
  end
  max_size = math.floor(max_size)
  local cache = setmetatable({
    _cap      = max_size,
    _size     = 0,
    _map      = {},
    _head     = nil,
    _tail     = nil,
    _ttl      = opts.default_ttl,
    _clock    = opts.clock,
    _handlers = {},
    _stats    = {
      hits        = 0,
      misses      = 0,
      sets        = 0,
      deletes     = 0,
      evictions   = 0,
      expirations = 0,
    },
  }, Cache) --[[: any]]
  return cache --[[:! Cache]]
end

-- ── Event system ──────────────────────────────────────────────────────────────

-- Register a handler for an event: "evict", "expire", "set".
-- Only one handler per event; calling on() again replaces the previous one.
--: (self: Cache, event: string, handler: (unknown, unknown) -> nil) -> nil
function Cache:on(event, handler)
  local self_ = self --[[:! Cache]]
  self_._handlers[event] = handler
end

-- ── Core operations ───────────────────────────────────────────────────────────

-- Compute expires_at from a ttl argument and the cache default.
-- ttl=0 means no expiry (overrides default_ttl).
-- ttl=nil means use default_ttl. default_ttl=nil means no expiry.
--: (now: number, ttl: number | nil, default_ttl: number | nil) -> number | nil
local function _resolve_expiry(now, ttl, default_ttl)
  if ttl == 0 then return nil end         -- explicit "no expiry"
  local t = (ttl ~= nil) and ttl or default_ttl
  if not t then return nil end
  return now + (t --[[:! number]])
end

-- Set a key-value pair. ttl (seconds) overrides the cache default for this entry.
-- Pass ttl=0 to store with no expiry regardless of the default.
-- Fires the "set" event.
--: (self: Cache, key: unknown, value: unknown, ttl: number | nil) -> nil
function Cache:set(key, value, ttl)
  local self_ = self --[[:! Cache]]
  local now = self_._clock()
  local node = self_._map[key]
  if node then
    local node_ = node --[[:! LruNode]]
    node_.value       = value
    node_.created_at  = now
    node_.last_access = now
    node_.hit_count   = 0
    node_.expires_at  = _resolve_expiry(now, ttl, self_._ttl)
    _promote(self_, node_)
  else
    if self_._size >= self_._cap then
      _evict_tail(self_)
    end
    local newnode = {
      key         = key,
      value       = value,
      prev        = nil,
      next        = nil,
      created_at  = now,
      last_access = now,
      hit_count   = 0,
      expires_at  = _resolve_expiry(now, ttl, self_._ttl),
    } --[[:! LruNode]]
    self_._map[key] = newnode
    self_._size = self_._size + 1
    _push_head(self_, newnode)
  end
  self_._stats.sets = self_._stats.sets + 1
  _emit(self_, "set", key, value)
end

-- Get the value for a key, promoting it to MRU.
-- Returns nil if missing or expired.
--: (self: Cache, key: unknown) -> unknown | nil
function Cache:get(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then
    self_._stats.misses = self_._stats.misses + 1
    return nil
  end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then
    self_._stats.misses = self_._stats.misses + 1
    return nil
  end
  self_._stats.hits = (self_._stats.hits + 1) --[[:! number]]
  local now_ = self_._clock()
  node_.last_access = now_
  node_.hit_count   = node_.hit_count + 1
  _promote(self_, node_)
  return node_.value
end

-- Get value and metadata for a key, promoting it to MRU.
-- Returns nil, nil if missing or expired.
-- meta: {expires_at, created_at, last_accessed, hit_count}
--: (self: Cache, key: unknown) -> (unknown | nil, { expires_at: number | nil, created_at: number, last_accessed: number, hit_count: number } | nil)
function Cache:get_with_meta(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then
    self_._stats.misses = self_._stats.misses + 1
    return nil, nil
  end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then
    self_._stats.misses = self_._stats.misses + 1
    return nil, nil
  end
  self_._stats.hits = (self_._stats.hits + 1) --[[:! number]]
  local now_ = self_._clock()
  node_.last_access = now_
  node_.hit_count   = node_.hit_count + 1
  _promote(self_, node_)
  return node_.value, {
    expires_at    = node_.expires_at,
    created_at    = node_.created_at,
    last_accessed = node_.last_access,
    hit_count     = node_.hit_count,
  }
end

-- Get value without updating LRU order. Returns nil if missing or expired.
--: (self: Cache, key: unknown) -> unknown | nil
function Cache:peek(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return nil end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then return nil end
  return node_.value
end

-- Check existence without updating LRU order or stats.
-- Returns false if missing OR expired.
--: (self: Cache, key: unknown) -> boolean
function Cache:has(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return false end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then return false end
  return true
end

-- True if the key exists and its TTL has elapsed; false if missing or not expired.
--: (self: Cache, key: unknown) -> boolean
function Cache:is_expired(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return false end
  local node_ = node --[[:! LruNode]]
  if not node_.expires_at then return false end
  return self_._clock() >= node_.expires_at
end

-- Delete a key. Returns the old value, or nil if not found.
-- Does NOT fire "evict" or "expire".
--: (self: Cache, key: unknown) -> unknown | nil
function Cache:delete(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return nil end
  local node_ = node --[[:! LruNode]]
  _detach(self_, node_)
  self_._map[key] = nil
  self_._size = self_._size - 1
  self_._stats.deletes = self_._stats.deletes + 1
  return node_.value
end

-- Remove all entries. Does NOT fire events or update stats.
--: (self: Cache) -> nil
function Cache:clear()
  local self_ = self --[[:! Cache]]
  self_._map  = {}
  self_._head = nil
  self_._tail = nil
  self_._size = 0
end

-- ── TTL management ────────────────────────────────────────────────────────────

-- Reset the TTL timer for key without changing its value.
-- If the entry has no TTL (and no default_ttl), this is a no-op.
-- Returns true if the key exists and is not expired, false otherwise.
--: (self: Cache, key: unknown) -> boolean
function Cache:touch(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return false end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then return false end
  local t = self_._ttl
  if node_.expires_at and t then
    node_.expires_at = self_._clock() + (t --[[:! number]])
  end
  return true
end

-- Extend the TTL of key by extra_seconds beyond its current expiry.
-- If the entry has no expiry, sets expiry to now + extra_seconds.
-- Returns true if the key exists and is not expired, false otherwise.
--: (self: Cache, key: unknown, extra_seconds: number) -> boolean
function Cache:extend(key, extra_seconds)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return false end
  local node_ = node --[[:! LruNode]]
  if _remove_expired(self_, node_) then return false end
  if node_.expires_at then
    node_.expires_at = node_.expires_at + extra_seconds
  else
    node_.expires_at = self_._clock() + extra_seconds
  end
  return true
end

-- Immediately expire a key (sets its expiry to the past).
-- Returns true if the key existed, false if missing.
-- The entry is lazily removed on the next access.
--: (self: Cache, key: unknown) -> boolean
function Cache:expire(key)
  local self_ = self --[[:! Cache]]
  local node = self_._map[key]
  if not node then return false end
  local node_ = node --[[:! LruNode]]
  node_.expires_at = self_._clock() - 1
  return true
end

-- ── Bulk operations ───────────────────────────────────────────────────────────

-- Remove all expired entries immediately. Returns the count of removed entries.
--: (self: Cache) -> number
function Cache:evict_expired()
  local self_ = self --[[:! Cache]]
  local removed = 0
  local node = self_._head
  while node do
    local node_ = node --[[:! LruNode]]
    local nxt = node_.next
    if node_.expires_at and self_._clock() >= node_.expires_at then
      _detach(self_, node_)
      self_._map[node_.key] = nil
      self_._size = self_._size - 1
      self_._stats.expirations = self_._stats.expirations + 1
      _emit(self_, "expire", node_.key, node_.value)
      removed = removed + 1
    end
    node = nxt
  end
  return removed
end

-- ── Size / capacity ───────────────────────────────────────────────────────────

-- Current number of entries (O(1); does not scan for expired items).
--: (self: Cache) -> number
function Cache:size()
  local self_ = self --[[:! Cache]]
  return self_._size
end

-- Maximum capacity.
--: (self: Cache) -> number
function Cache:capacity()
  local self_ = self --[[:! Cache]]
  return self_._cap
end

-- True when size() == capacity().
--: (self: Cache) -> boolean
function Cache:full()
  local self_ = self --[[:! Cache]]
  return self_._size >= self_._cap
end

-- ── Iteration ─────────────────────────────────────────────────────────────────

-- Iterator over (key, value) pairs, MRU first. Skips expired entries (lazy remove).
--: (self: Cache) -> (() -> (unknown | nil, unknown | nil))
function Cache:pairs()
  local self_ = self --[[:! Cache]]
  local node = self_._head
  return function()
    while node do
      local node_ = node --[[:! LruNode]]
      local current = node_
      node = node_.next
      if not _remove_expired(self_, current) then
        return current.key, current.value
      end
    end
    return nil, nil
  end
end

-- Array of non-expired keys, MRU first.
--: (self: Cache) -> { [number]: unknown }
function Cache:keys()
  local self_ = self --[[:! Cache]]
  local result = {}
  local node = self_._head
  while node do
    local node_ = node --[[:! LruNode]]
    local nxt = node_.next
    if not _remove_expired(self_, node_) then
      result[#result + 1] = node_.key
    end
    node = nxt
  end
  return result
end

-- Array of non-expired values, MRU first.
--: (self: Cache) -> { [number]: unknown }
function Cache:values()
  local self_ = self --[[:! Cache]]
  local result = {}
  local node = self_._head
  while node do
    local node_ = node --[[:! LruNode]]
    local nxt = node_.next
    if not _remove_expired(self_, node_) then
      result[#result + 1] = node_.value
    end
    node = nxt
  end
  return result
end

-- Array of {key, value} pairs, MRU first.
--: (self: Cache) -> { [number]: { [number]: unknown } }
function Cache:entries()
  local self_ = self --[[:! Cache]]
  local result = {}
  local node = self_._head
  while node do
    local node_ = node --[[:! LruNode]]
    local nxt = node_.next
    if not _remove_expired(self_, node_) then
      result[#result + 1] = { node_.key, node_.value }
    end
    node = nxt
  end
  return result
end

-- ── Statistics ────────────────────────────────────────────────────────────────

-- Hits / (hits + misses) since creation or last reset_stats. Returns 0 when no lookups.
--: (self: Cache) -> number
function Cache:hit_rate()
  local self_ = self --[[:! Cache]]
  local total = self_._stats.hits + self_._stats.misses
  if total == 0 then return 0 end
  return self_._stats.hits / total
end

-- Snapshot of all counters plus hit_rate.
--: (self: Cache) -> { hits: number, misses: number, sets: number, deletes: number, evictions: number, expirations: number, hit_rate: number }
function Cache:stats()
  local self_ = self --[[:! Cache]]
  local s = self_._stats
  local total = s.hits + s.misses
  return {
    hits        = s.hits,
    misses      = s.misses,
    sets        = s.sets,
    deletes     = s.deletes,
    evictions   = s.evictions,
    expirations = s.expirations,
    hit_rate    = total > 0 and (s.hits / total) or 0,
  }
end

-- Reset all counters to zero.
--: (self: Cache) -> nil
function Cache:reset_stats()
  local self_ = self --[[:! Cache]]
  local s = self_._stats
  s.hits        = 0
  s.misses      = 0
  s.sets        = 0
  s.deletes     = 0
  s.evictions   = 0
  s.expirations = 0
end

return M
