if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- LRU cache with TTL expiry, per-entry metadata, stats, and events.
-- O(1) get/set via doubly-linked list + hash map.
-- Lazy expiry: expired entries are removed on access, not on a timer.

local M = {}
M._tier = "pure"

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function _detach(self, node)
  local p, n = node.prev, node.next
  if p then p.next = n else self._head = n end
  if n then n.prev = p else self._tail = p end
  node.prev = nil
  node.next = nil
end

local function _push_head(self, node)
  node.prev = nil
  node.next = self._head
  if self._head then self._head.prev = node end
  self._head = node
  if not self._tail then self._tail = node end
end

local function _promote(self, node)
  if node == self._head then return end
  _detach(self, node)
  _push_head(self, node)
end

-- Fire a named event if a handler is registered.
local function _emit(self, event, key, value)
  local h = self._handlers[event]
  if h then h(key, value) end
end

-- Remove an expired node. Returns true if the node was expired.
-- Does NOT count as a miss — callers increment stats themselves.
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
local function _evict_tail(self)
  local node = self._tail
  if not node then return end
  _detach(self, node)
  self._map[node.key] = nil
  self._size = self._size - 1
  self._stats.evictions = self._stats.evictions + 1
  _emit(self, "evict", node.key, node.value)
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
--: (LruTtlOpts) -> Cache | (nil, string)
function M.new(opts)
  if type(opts) ~= "table" then
    return nil, "opts must be a table"
  end
  local max_size = opts.max_size
  if type(max_size) ~= "number" or max_size < 1 then
    return nil, "opts.max_size must be a positive number"
  end
  max_size = math.floor(max_size)
  return setmetatable({
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
  }, Cache)
end

-- ── Event system ──────────────────────────────────────────────────────────────

-- Register a handler for an event: "evict", "expire", "set".
-- Only one handler per event; calling on() again replaces the previous one.
--: (string, (unknown, unknown) -> nil) -> nil
function Cache:on(event, handler)
  self._handlers[event] = handler
end

-- ── Core operations ───────────────────────────────────────────────────────────

-- Compute expires_at from a ttl argument and the cache default.
-- ttl=0 means no expiry (overrides default_ttl).
-- ttl=nil means use default_ttl. default_ttl=nil means no expiry.
local function _resolve_expiry(now, ttl, default_ttl)
  if ttl == 0 then return nil end         -- explicit "no expiry"
  local t = (ttl ~= nil) and ttl or default_ttl
  if not t then return nil end
  return now + t
end

-- Set a key-value pair. ttl (seconds) overrides the cache default for this entry.
-- Pass ttl=0 to store with no expiry regardless of the default.
-- Fires the "set" event.
--: (unknown, unknown, number | nil) -> nil
function Cache:set(key, value, ttl)
  local now = self._clock()
  local node = self._map[key]
  if node then
    node.value       = value
    node.created_at  = now
    node.last_access = now
    node.hit_count   = 0
    node.expires_at  = _resolve_expiry(now, ttl, self._ttl)
    _promote(self, node)
  else
    if self._size >= self._cap then
      _evict_tail(self)
    end
    node = {
      key         = key,
      value       = value,
      prev        = nil,
      next        = nil,
      created_at  = now,
      last_access = now,
      hit_count   = 0,
      expires_at  = _resolve_expiry(now, ttl, self._ttl),
    }
    self._map[key] = node
    self._size = self._size + 1
    _push_head(self, node)
  end
  self._stats.sets = self._stats.sets + 1
  _emit(self, "set", key, value)
end

-- Get the value for a key, promoting it to MRU.
-- Returns nil if missing or expired.
--: (unknown) -> unknown | nil
function Cache:get(key)
  local node = self._map[key]
  if not node then
    self._stats.misses = self._stats.misses + 1
    return nil
  end
  if _remove_expired(self, node) then
    self._stats.misses = self._stats.misses + 1
    return nil
  end
  self._stats.hits = self._stats.hits + 1
  node.last_access = self._clock()
  node.hit_count   = node.hit_count + 1
  _promote(self, node)
  return node.value
end

-- Get value and metadata for a key, promoting it to MRU.
-- Returns nil, nil if missing or expired.
-- meta: {expires_at, created_at, last_accessed, hit_count}
--: (unknown) -> (unknown | nil, { expires_at: number | nil, created_at: number, last_accessed: number, hit_count: number } | nil)
function Cache:get_with_meta(key)
  local node = self._map[key]
  if not node then
    self._stats.misses = self._stats.misses + 1
    return nil, nil
  end
  if _remove_expired(self, node) then
    self._stats.misses = self._stats.misses + 1
    return nil, nil
  end
  self._stats.hits = self._stats.hits + 1
  node.last_access = self._clock()
  node.hit_count   = node.hit_count + 1
  _promote(self, node)
  return node.value, {
    expires_at    = node.expires_at,
    created_at    = node.created_at,
    last_accessed = node.last_access,
    hit_count     = node.hit_count,
  }
end

-- Get value without updating LRU order. Returns nil if missing or expired.
--: (unknown) -> unknown | nil
function Cache:peek(key)
  local node = self._map[key]
  if not node then return nil end
  if _remove_expired(self, node) then return nil end
  return node.value
end

-- Check existence without updating LRU order or stats.
-- Returns false if missing OR expired.
--: (unknown) -> boolean
function Cache:has(key)
  local node = self._map[key]
  if not node then return false end
  if _remove_expired(self, node) then return false end
  return true
end

-- True if the key exists and its TTL has elapsed; false if missing or not expired.
--: (unknown) -> boolean
function Cache:is_expired(key)
  local node = self._map[key]
  if not node then return false end
  if not node.expires_at then return false end
  return self._clock() >= node.expires_at
end

-- Delete a key. Returns the old value, or nil if not found.
-- Does NOT fire "evict" or "expire".
--: (unknown) -> unknown | nil
function Cache:delete(key)
  local node = self._map[key]
  if not node then return nil end
  _detach(self, node)
  self._map[key] = nil
  self._size = self._size - 1
  self._stats.deletes = self._stats.deletes + 1
  return node.value
end

-- Remove all entries. Does NOT fire events or update stats.
function Cache:clear()
  self._map  = {}
  self._head = nil
  self._tail = nil
  self._size = 0
end

-- ── TTL management ────────────────────────────────────────────────────────────

-- Reset the TTL timer for key without changing its value.
-- If the entry has no TTL (and no default_ttl), this is a no-op.
-- Returns true if the key exists and is not expired, false otherwise.
--: (unknown) -> boolean
function Cache:touch(key)
  local node = self._map[key]
  if not node then return false end
  if _remove_expired(self, node) then return false end
  local t = self._ttl
  if node.expires_at and t then
    node.expires_at = self._clock() + t
  end
  return true
end

-- Extend the TTL of key by extra_seconds beyond its current expiry.
-- If the entry has no expiry, sets expiry to now + extra_seconds.
-- Returns true if the key exists and is not expired, false otherwise.
--: (unknown, number) -> boolean
function Cache:extend(key, extra_seconds)
  local node = self._map[key]
  if not node then return false end
  if _remove_expired(self, node) then return false end
  if node.expires_at then
    node.expires_at = node.expires_at + extra_seconds
  else
    node.expires_at = self._clock() + extra_seconds
  end
  return true
end

-- Immediately expire a key (sets its expiry to the past).
-- Returns true if the key existed, false if missing.
-- The entry is lazily removed on the next access.
--: (unknown) -> boolean
function Cache:expire(key)
  local node = self._map[key]
  if not node then return false end
  node.expires_at = self._clock() - 1
  return true
end

-- ── Bulk operations ───────────────────────────────────────────────────────────

-- Remove all expired entries immediately. Returns the count of removed entries.
--: () -> number
function Cache:evict_expired()
  local removed = 0
  local node = self._head
  while node do
    local nxt = node.next
    if node.expires_at and self._clock() >= node.expires_at then
      _detach(self, node)
      self._map[node.key] = nil
      self._size = self._size - 1
      self._stats.expirations = self._stats.expirations + 1
      _emit(self, "expire", node.key, node.value)
      removed = removed + 1
    end
    node = nxt
  end
  return removed
end

-- ── Size / capacity ───────────────────────────────────────────────────────────

-- Current number of entries (O(1); does not scan for expired items).
--: () -> number
function Cache:size()
  return self._size
end

-- Maximum capacity.
--: () -> number
function Cache:capacity()
  return self._cap
end

-- True when size() == capacity().
--: () -> boolean
function Cache:full()
  return self._size >= self._cap
end

-- ── Iteration ─────────────────────────────────────────────────────────────────

-- Iterator over (key, value) pairs, MRU first. Skips expired entries (lazy remove).
--: () -> (() -> (unknown | nil, unknown | nil))
function Cache:pairs()
  local node = self._head
  return function()
    while node do
      local current = node
      node = node.next
      if not _remove_expired(self, current) then
        return current.key, current.value
      end
    end
    return nil, nil
  end
end

-- Array of non-expired keys, MRU first.
--: () -> { [number]: unknown }
function Cache:keys()
  local result = {}
  local node = self._head
  while node do
    local nxt = node.next
    if not _remove_expired(self, node) then
      result[#result + 1] = node.key
    end
    node = nxt
  end
  return result
end

-- Array of non-expired values, MRU first.
--: () -> { [number]: unknown }
function Cache:values()
  local result = {}
  local node = self._head
  while node do
    local nxt = node.next
    if not _remove_expired(self, node) then
      result[#result + 1] = node.value
    end
    node = nxt
  end
  return result
end

-- Array of {key, value} pairs, MRU first.
--: () -> { [number]: { [number]: unknown } }
function Cache:entries()
  local result = {}
  local node = self._head
  while node do
    local nxt = node.next
    if not _remove_expired(self, node) then
      result[#result + 1] = { node.key, node.value }
    end
    node = nxt
  end
  return result
end

-- ── Statistics ────────────────────────────────────────────────────────────────

-- Hits / (hits + misses) since creation or last reset_stats. Returns 0 when no lookups.
--: () -> number
function Cache:hit_rate()
  local total = self._stats.hits + self._stats.misses
  if total == 0 then return 0 end
  return self._stats.hits / total
end

-- Snapshot of all counters plus hit_rate.
--: () -> { hits: number, misses: number, sets: number, deletes: number, evictions: number, expirations: number, hit_rate: number }
function Cache:stats()
  local s = self._stats
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
function Cache:reset_stats()
  local s = self._stats
  s.hits        = 0
  s.misses      = 0
  s.sets        = 0
  s.deletes     = 0
  s.evictions   = 0
  s.expirations = 0
end

return M
