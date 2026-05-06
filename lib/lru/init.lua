if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: LruNode = { key: unknown, value: unknown, prev: LruNode | nil, next: LruNode | nil, expires_at: number | nil }
--:: Cache = { _cap: number, _size: number, _map: { [unknown]: LruNode }, _head: LruNode | nil, _tail: LruNode | nil, _ttl: number | nil, _on_evict: ((unknown, unknown) -> nil) | nil, _clock: (() -> number) | nil, _hits: number, _misses: number, _evictions: number, ... }
--:: LfuNode = { key: unknown, value: unknown, freq: number, b_prev: LfuNode | nil, b_next: LfuNode | nil }
--:: LfuBucket = { head: LfuNode | nil, tail: LfuNode | nil, count: number }
--:: Lfu = { _cap: number, _size: number, _min_freq: number, _map: { [unknown]: LfuNode }, _freq: { [number]: LfuBucket }, _on_evict: ((unknown, unknown) -> nil) | nil, _hits: number, _misses: number, _evictions: number, ... }
--:: TwoQFifoQ = { head: TwoQNode | nil, tail: TwoQNode | nil, count: number }
--:: TwoQLruQ = { head: TwoQNode | nil, tail: TwoQNode | nil, count: number }
--:: TwoQNode = { key: unknown, value: unknown, queue: string, f_prev: TwoQNode | nil, f_next: TwoQNode | nil, o_prev: TwoQNode | nil, o_next: TwoQNode | nil }
--:: TwoQ = { _cap: number, _in_cap: number, _out_cap: number, _in_q: TwoQFifoQ, _out_q: TwoQLruQ, _ghost: { [unknown]: boolean }, _map: { [unknown]: TwoQNode }, _on_evict: ((unknown, unknown) -> nil) | nil, _hits: number, _misses: number, _evictions: number, ... }
M._tier = "pure"

-- ── Internal helpers ──────────────────────────────────────────────────────────

--: (Cache, LruNode) -> nil
local function _detach(self, node)
  local p, n = node.prev, node.next
  if p then p.next = n else self._head = n end
  if n then n.prev = p else self._tail = p end
  node.prev = nil
  node.next = nil
end

--: (Cache, LruNode) -> nil
local function _push_head(self, node)
  node.prev = nil
  node.next = self._head
  if self._head then self._head.prev = node end
  self._head = node
  if not self._tail then self._tail = node end
end

--: (Cache, LruNode) -> nil
local function _promote(self, node)
  if node == self._head then return end
  _detach(self, node)
  _push_head(self, node)
end

-- Returns true (and removes node) if expired.
--: (Cache, LruNode) -> boolean
local function _check_expired(self, node)
  if not node.expires_at then return false end
  if not self._clock then return false end
  if self._clock() < node.expires_at then return false end
  _detach(self, node)
  self._map[node.key] = nil
  self._size = self._size - 1
  self._evictions = self._evictions + 1
  if self._on_evict then self._on_evict(node.key, node.value) end
  return true
end

--: (Cache) -> nil
local function _evict_tail(self)
  local node = self._tail
  if not node then return end
  _detach(self, node --[[:! LruNode]])
  self._map[node.key] = nil
  self._size = self._size - 1
  self._evictions = self._evictions + 1
  if self._on_evict then self._on_evict(node.key, node.value) end
end

-- ── LRU Cache ─────────────────────────────────────────────────────────────────

--:: LruOpts = { ttl: number | nil, on_evict: ((unknown, unknown) -> nil) | nil, clock: (() -> number) | nil }

local Cache = {}
Cache.__index = Cache

-- Create a new LRU cache with the given maximum capacity.
-- opts.ttl: default TTL in seconds (optional)
-- opts.on_evict: callback(key, value) on eviction (optional)
-- opts.clock: injectable clock (required for TTL)
--: (number, LruOpts | nil) -> Cache | (nil, string)
function M.new(capacity, opts)
  if type(capacity) ~= "number" or capacity < 1 then
    return nil, "capacity must be a positive number"
  end
  local cap = math.floor(capacity --[[:! number]])
  local o = opts or {} --[[:! LruOpts]]
  return setmetatable({
    _cap       = cap,
    _size      = 0,
    _map       = {},
    _head      = nil,
    _tail      = nil,
    _ttl       = o.ttl,
    _on_evict  = o.on_evict,
    _clock     = o.clock,
    _hits      = 0,
    _misses    = 0,
    _evictions = 0,
  }, Cache) --[[:! Cache]]
end

-- Set a key-value pair. ttl overrides the default TTL for this entry (seconds).
-- Returns the old value if the key already existed, or nil.
--: (Cache, unknown, unknown, number | nil) -> unknown | nil
function Cache:set(key, value, ttl)
  local node = self._map[key]
  local clock = self._clock --[[:! (() -> number) | nil]]
  if node then
    local old = node.value
    node.value = value
    local t = ttl or self._ttl
    node.expires_at = t and clock and (clock() + (t --[[:! number]])) or nil
    _promote(self, node)
    return old
  end
  if self._size >= self._cap then
    _evict_tail(self)
  end
  local t = ttl or self._ttl
  node = {
    key        = key,
    value      = value,
    prev       = nil,
    next       = nil,
    expires_at = t and clock and (clock() + (t --[[:! number]])) or nil,
  }
  self._map[key] = node
  self._size = self._size + 1
  _push_head(self, node)
  return nil
end

-- Get the value for a key, promoting it to most recently used.
-- Returns nil if missing or expired.
--: (Cache, unknown) -> unknown | nil
function Cache:get(key)
  local node = self._map[key]
  if not node then
    self._misses = self._misses + 1
    return nil
  end
  if _check_expired(self, node) then
    self._misses = self._misses + 1
    return nil
  end
  self._hits = self._hits + 1
  _promote(self, node)
  return node.value
end

-- Get without promoting. Returns nil if missing or expired.
--: (Cache, unknown) -> unknown | nil
function Cache:peek(key)
  local node = self._map[key]
  if not node then return nil end
  if _check_expired(self, node) then return nil end
  return node.value
end

-- Check existence without promoting. Does NOT count as a hit/miss.
--: (Cache, unknown) -> boolean
function Cache:has(key)
  local node = self._map[key]
  if not node then return false end
  if _check_expired(self, node) then return false end
  return true
end

-- Delete a key. Returns the old value, or nil if not found.
-- Does NOT fire on_evict.
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
--: (Cache) -> nil
function Cache:clear()
  self._map  = {}
  self._head = nil
  self._tail = nil
  self._size = 0
end

-- Current number of (non-expired) entries. O(1); does not scan for expired items.
--: (Cache) -> number
function Cache:size()
  return self._size
end

-- Maximum capacity.
--: (Cache) -> number
function Cache:capacity()
  return self._cap
end

-- True when size == capacity.
--: (Cache) -> boolean
function Cache:is_full()
  return self._size >= self._cap
end

-- Return value for key; if missing, call loader(), store result, and return it.
--: (Cache, unknown, () -> unknown) -> unknown
function Cache:get_or_set(key, loader)
  local v = self:get(key)
  if v ~= nil then return v end
  -- also handle false stored as value: check existence separately
  local node = self._map[key]
  if node and not _check_expired(self, node) then
    _promote(self, node)
    return node.value
  end
  v = loader()
  self:set(key, v)
  return v
end

-- Get multiple keys. Returns table mapping each found key to its value.
-- Missing/expired keys are omitted.
--: (Cache, { [number]: unknown }) -> { [unknown]: unknown }
function Cache:mget(keys_list)
  local result = {}
  for i = 1, #keys_list do
    local k = keys_list[i]
    local v = self:get(k)
    if v ~= nil then
      result[k] = v
    end
  end
  return result
end

-- Set multiple key-value pairs from a table {key=value, ...}.
--: (Cache, { [unknown]: unknown }) -> nil
function Cache:mset(pairs_table)
  for k, v in pairs(pairs_table) do
    self:set(k, v)
  end
end

-- Iterator over (key, value) pairs, most recently used first.
-- Expired entries are lazily removed during iteration.
--: (Cache) -> (() -> (unknown, unknown) | nil)
function Cache:iter()
  local cache = self --[[:! Cache]]
  local node = self._head
  return function()
    while node do
      local current = node --[[:! LruNode]]
      node = node.next
      if not _check_expired(cache, current) then
        return current.key, current.value
      end
    end
    return nil
  end
end

-- Array of all keys, most recently used first.
-- Expired entries are skipped and lazily removed.
--: (Cache) -> { [number]: unknown }
function Cache:keys()
  local result = {}
  local node = self._head
  while node do
    local n = node --[[:! LruNode]]
    local nxt = n.next
    if not _check_expired(self, n) then
      result[#result + 1] = n.key
    end
    node = nxt
  end
  return result
end

-- Array of all values, most recently used first.
--: (Cache) -> { [number]: unknown }
function Cache:values()
  local result = {}
  local node = self._head
  while node do
    local n = node --[[:! LruNode]]
    local nxt = n.next
    if not _check_expired(self, n) then
      result[#result + 1] = n.value
    end
    node = nxt
  end
  return result
end

-- Array of {key, value} pairs, most recently used first.
--: (Cache) -> { [number]: { [number]: unknown } }
function Cache:pairs()
  local result = {}
  local node = self._head
  while node do
    local n = node --[[:! LruNode]]
    local nxt = n.next
    if not _check_expired(self, n) then
      result[#result + 1] = { n.key, n.value }
    end
    node = nxt
  end
  return result
end

-- Hits / (hits + misses) since creation or last reset_stats. Returns 0 when no lookups.
--: (Cache) -> number
function Cache:hit_rate()
  local total = self._hits + self._misses
  if total == 0 then return 0 end
  return self._hits / total
end

-- {hits, misses, evictions, size, capacity}
--: (Cache) -> { hits: number, misses: number, evictions: number, size: number, capacity: number }
function Cache:stats()
  return {
    hits      = self._hits,
    misses    = self._misses,
    evictions = self._evictions,
    size      = self._size,
    capacity  = self._cap,
  }
end

-- Reset hit/miss/eviction counters.
--: (Cache) -> nil
function Cache:reset_stats()
  self._hits      = 0
  self._misses    = 0
  self._evictions = 0
end

-- ── LFU Cache (Least Frequently Used) ────────────────────────────────────────
-- O(1) get/set via frequency buckets with doubly-linked lists (Ketan Shah et al.)

--:: LfuOpts = { on_evict: ((unknown, unknown) -> nil) | nil }

local Lfu = {}
Lfu.__index = Lfu

-- Doubly-linked list helpers operating on per-frequency buckets.
-- Each bucket is { head, tail, count } of nodes.

--: (LfuBucket, LfuNode) -> nil
local function _lfu_bucket_push_head(bucket, node)
  node.b_prev = nil
  node.b_next = bucket.head
  if bucket.head then bucket.head.b_prev = node end
  bucket.head = node
  if not bucket.tail then bucket.tail = node end
  bucket.count = bucket.count + 1
end

--: (LfuBucket, LfuNode) -> nil
local function _lfu_bucket_detach(bucket, node)
  local p, n = node.b_prev, node.b_next
  if p then p.b_next = n else bucket.head = n end
  if n then n.b_prev = p else bucket.tail = p end
  node.b_prev = nil
  node.b_next = nil
  bucket.count = bucket.count - 1
end

-- Create a new LFU cache.
--: (number, LfuOpts | nil) -> Lfu | (nil, string)
function M.lfu_new(capacity, opts)
  if type(capacity) ~= "number" or capacity < 1 then
    return nil, "capacity must be a positive number"
  end
  local cap = math.floor(capacity --[[:! number]])
  local o = opts or {} --[[:! LfuOpts]]
  return setmetatable({
    _cap      = cap,
    _size     = 0,
    _min_freq = 1,
    _map      = {},   -- key -> node
    _freq     = {},   -- freq -> bucket {head, tail, count}
    _on_evict = o.on_evict,
    _hits      = 0,
    _misses    = 0,
    _evictions = 0,
  }, Lfu) --[[:! Lfu]]
end

--: (Lfu, number) -> LfuBucket
local function _lfu_get_or_create_bucket(self, freq)
  local b = self._freq[freq]
  if not b then
    b = { head = nil, tail = nil, count = 0 }
    self._freq[freq] = b
  end
  return b
end

--: (Lfu, LfuNode) -> nil
local function _lfu_promote(self, node)
  local old_freq = node.freq
  local old_bucket = self._freq[old_freq] --[[:! LfuBucket]]
  _lfu_bucket_detach(old_bucket, node)
  -- Clean up empty bucket and advance min_freq if needed
  if old_bucket.count == 0 then
    self._freq[old_freq] = nil
    if self._min_freq == old_freq then
      self._min_freq = old_freq + 1
    end
  end
  node.freq = old_freq + 1
  local new_bucket = _lfu_get_or_create_bucket(self, node.freq)
  _lfu_bucket_push_head(new_bucket, node)
end

--: (Lfu) -> nil
local function _lfu_evict(self)
  local bucket = self._freq[self._min_freq]
  if not bucket or not bucket.tail then return end
  local victim = bucket.tail
  _lfu_bucket_detach(bucket, victim)
  if bucket.count == 0 then
    self._freq[self._min_freq] = nil
  end
  self._map[victim.key] = nil
  self._size = self._size - 1
  self._evictions = self._evictions + 1
  if self._on_evict then self._on_evict(victim.key, victim.value) end
end

--: (Lfu, unknown, unknown) -> nil
function Lfu:set(key, value)
  local node = self._map[key]
  if node then
    node.value = value
    _lfu_promote(self, node)
    return
  end
  if self._size >= self._cap then
    _lfu_evict(self)
  end
  node = {
    key    = key,
    value  = value,
    freq   = 1,
    b_prev = nil,
    b_next = nil,
  }
  self._map[key] = node
  self._size = self._size + 1
  self._min_freq = 1
  local bucket = _lfu_get_or_create_bucket(self, 1)
  _lfu_bucket_push_head(bucket, node)
end

--: (Lfu, unknown) -> unknown | nil
function Lfu:get(key)
  local node = self._map[key]
  if not node then
    self._misses = self._misses + 1
    return nil
  end
  self._hits = self._hits + 1
  _lfu_promote(self, node)
  return node.value
end

--: (Lfu, unknown) -> unknown | nil
function Lfu:peek(key)
  local node = self._map[key]
  if not node then return nil end
  return node.value
end

--: (Lfu, unknown) -> boolean
function Lfu:has(key)
  return self._map[key] ~= nil
end

--: (Lfu, unknown) -> unknown | nil
function Lfu:delete(key)
  local node = self._map[key]
  if not node then return nil end
  local bucket = self._freq[node.freq]
  if bucket then
    _lfu_bucket_detach(bucket, node)
    if bucket.count == 0 then
      self._freq[node.freq] = nil
    end
  end
  self._map[key] = nil
  self._size = self._size - 1
  return node.value
end

--: (Lfu) -> nil
function Lfu:clear()
  self._map      = {}
  self._freq     = {}
  self._size     = 0
  self._min_freq = 1
end

--: (Lfu) -> number
function Lfu:size()
  return self._size
end

--: (Lfu) -> number
function Lfu:capacity()
  return self._cap
end

--: (Lfu) -> boolean
function Lfu:is_full()
  return self._size >= self._cap
end

--: (Lfu, unknown) -> number
function Lfu:frequency(key)
  local node = self._map[key]
  if not node then return 0 end
  return node.freq
end

--: (Lfu) -> number
function Lfu:hit_rate()
  local total = self._hits + self._misses
  if total == 0 then return 0 end
  return self._hits / total
end

--: (Lfu) -> { hits: number, misses: number, evictions: number, size: number, capacity: number }
function Lfu:stats()
  return {
    hits      = self._hits,
    misses    = self._misses,
    evictions = self._evictions,
    size      = self._size,
    capacity  = self._cap,
  }
end

--: (Lfu) -> nil
function Lfu:reset_stats()
  self._hits      = 0
  self._misses    = 0
  self._evictions = 0
end

-- ── TwoQ Cache ────────────────────────────────────────────────────────────────
-- Ghost-buffer variant of 2Q: items first enter "in" FIFO; on second access
-- they are promoted to "out" LRU. Items evicted from "out" go to a ghost set;
-- if seen again while in ghost, they skip "in" and go straight to "out".
-- Default split: 25% "in", 75% "out".

--:: TwoQOpts = { in_ratio: number | nil, on_evict: ((unknown, unknown) -> nil) | nil }

local TwoQ = {}
TwoQ.__index = TwoQ

-- TwoQ FIFO helpers (singly-linked, tail-insert, head-evict).
--: (TwoQFifoQ, TwoQNode) -> nil
local function _fifo_push(q, node)
  node.f_prev = nil
  node.f_next = nil
  if q.tail then
    q.tail.f_next = node
    node.f_prev = q.tail
  else
    q.head = node
  end
  q.tail  = node
  q.count = q.count + 1
end

--: (TwoQFifoQ, TwoQNode) -> nil
local function _fifo_remove(q, node)
  local p, n = node.f_prev, node.f_next
  if p then p.f_next = n else q.head = n end
  if n then n.f_prev = p else q.tail = p end
  node.f_prev = nil
  node.f_next = nil
  q.count = q.count - 1
end

-- TwoQ out-LRU helpers (doubly-linked list, same as main LRU above).
--: (TwoQLruQ, TwoQNode) -> nil
local function _out_detach(q, node)
  local p, n = node.o_prev, node.o_next
  if p then p.o_next = n else q.head = n end
  if n then n.o_prev = p else q.tail = p end
  node.o_prev = nil
  node.o_next = nil
end

--: (TwoQLruQ, TwoQNode) -> nil
local function _out_push_head(q, node)
  node.o_prev = nil
  node.o_next = q.head
  if q.head then q.head.o_prev = node end
  q.head = node
  if not q.tail then q.tail = node end
  q.count = q.count + 1
end

--: (TwoQLruQ, TwoQNode) -> nil
local function _out_promote(q, node)
  if node == q.head then return end
  _out_detach(q, node)
  _out_push_head(q, node)
end

-- Create a new TwoQ cache.
-- in_ratio: fraction of capacity for the "in" FIFO queue (default 0.25).
--: (number, TwoQOpts | nil) -> TwoQ | (nil, string)
function M.twoq_new(capacity, opts)
  if type(capacity) ~= "number" or capacity < 1 then
    return nil, "capacity must be a positive number"
  end
  local cap = math.floor(capacity --[[:! number]])
  local o = opts or {} --[[:! TwoQOpts]]
  local in_ratio = o.in_ratio or 0.25
  local in_cap   = math.max(1, math.floor(cap * in_ratio))
  local out_cap  = math.max(1, cap - in_cap)
  return setmetatable({
    _cap      = cap,
    _in_cap   = in_cap,
    _out_cap  = out_cap,
    -- "in" FIFO queue: {head, tail, count}
    _in_q     = { head = nil, tail = nil, count = 0 },
    -- "out" LRU queue: {head, tail, count}
    _out_q    = { head = nil, tail = nil, count = 0 },
    -- ghost set: keys of items evicted from "out"
    _ghost    = {},
    _map      = {},   -- key -> node (only live entries)
    _on_evict = o.on_evict,
    _hits      = 0,
    _misses    = 0,
    _evictions = 0,
  }, TwoQ) --[[:! TwoQ]]
end

-- Evict from "in" FIFO (oldest = head).
--: (TwoQ) -> nil
local function _twoq_evict_in(self)
  local q    = self._in_q
  local node = q.head
  if not node then return end
  _fifo_remove(q, node --[[:! TwoQNode]])
  self._map[node.key] = nil
  self._evictions = self._evictions + 1
  if self._on_evict then self._on_evict(node.key, node.value) end
end

-- Evict from "out" LRU (least recent = tail).
--: (TwoQ) -> nil
local function _twoq_evict_out(self)
  local q    = self._out_q
  local node = q.tail
  if not node then return end
  _out_detach(q, node --[[:! TwoQNode]])
  q.count = q.count - 1
  -- Move key to ghost set.
  self._ghost[node.key] = true
  self._map[node.key]   = nil
  self._evictions = self._evictions + 1
  if self._on_evict then self._on_evict(node.key, node.value) end
end

--: (TwoQ, unknown, unknown) -> nil
function TwoQ:set(key, value)
  local node = self._map[key]
  if node then
    -- Update in place; keep queue membership unchanged, but promote in "out".
    node.value = value
    if node.queue == "out" then
      _out_promote(self._out_q, node)
    end
    return
  end
  -- Ghost hit: skip "in", go straight to "out".
  if self._ghost[key] then
    self._ghost[key] = nil
    -- Make room in "out".
    if self._out_q.count >= self._out_cap then
      _twoq_evict_out(self)
    end
    node = { key = key, value = value, queue = "out",
             o_prev = nil, o_next = nil,
             f_prev = nil, f_next = nil }
    self._map[key] = node
    _out_push_head(self._out_q, node)
    return
  end
  -- New item: go into "in" FIFO.
  if self._in_q.count >= self._in_cap then
    _twoq_evict_in(self)
  end
  node = { key = key, value = value, queue = "in",
           f_prev = nil, f_next = nil,
           o_prev = nil, o_next = nil }
  self._map[key] = node
  _fifo_push(self._in_q, node)
end

--: (TwoQ, unknown) -> unknown | nil
function TwoQ:get(key)
  local node = self._map[key]
  if not node then
    self._misses = self._misses + 1
    return nil
  end
  self._hits = self._hits + 1
  if node.queue == "in" then
    -- Second access: promote from "in" to "out".
    _fifo_remove(self._in_q, node)
    node.queue = "out"
    if self._out_q.count >= self._out_cap then
      _twoq_evict_out(self)
    end
    _out_push_head(self._out_q, node)
  else
    -- Already in "out": promote in LRU.
    _out_promote(self._out_q, node)
  end
  return node.value
end

--: (TwoQ, unknown) -> unknown | nil
function TwoQ:peek(key)
  local node = self._map[key]
  if not node then return nil end
  return node.value
end

--: (TwoQ, unknown) -> boolean
function TwoQ:has(key)
  return self._map[key] ~= nil
end

--: (TwoQ, unknown) -> unknown | nil
function TwoQ:delete(key)
  local node = self._map[key]
  if not node then return nil end
  if node.queue == "in" then
    _fifo_remove(self._in_q, node)
  else
    _out_detach(self._out_q, node)
    self._out_q.count = self._out_q.count - 1
  end
  self._map[key] = nil
  return node.value
end

--: (TwoQ) -> nil
function TwoQ:clear()
  self._map     = {}
  self._ghost   = {}
  self._in_q    = { head = nil, tail = nil, count = 0 }
  self._out_q   = { head = nil, tail = nil, count = 0 }
end

--: (TwoQ) -> number
function TwoQ:size()
  return self._in_q.count + self._out_q.count
end

--: (TwoQ) -> number
function TwoQ:capacity()
  return self._cap
end

--: (TwoQ) -> boolean
function TwoQ:is_full()
  return (self._in_q.count + self._out_q.count) >= self._cap
end

-- "in" queue (FIFO) membership: true if key is in the "in" queue.
--: (TwoQ, unknown) -> boolean
function TwoQ:in_queue(key)
  local node = self._map[key]
  return (node ~= nil and node.queue == "in") and true or false
end

-- "out" queue (LRU) membership: true if key is in the "out" queue.
--: (TwoQ, unknown) -> boolean
function TwoQ:out_queue(key)
  local node = self._map[key]
  return (node ~= nil and node.queue == "out") and true or false
end

-- True if key is in the ghost set (evicted from "out" but not yet re-inserted).
--: (TwoQ, unknown) -> boolean
function TwoQ:in_ghost(key)
  return self._ghost[key] == true
end

--: (TwoQ) -> number
function TwoQ:hit_rate()
  local total = self._hits + self._misses
  if total == 0 then return 0 end
  return self._hits / total
end

--: (TwoQ) -> { hits: number, misses: number, evictions: number, size: number, capacity: number }
function TwoQ:stats()
  return {
    hits      = self._hits,
    misses    = self._misses,
    evictions = self._evictions,
    size      = self._in_q.count + self._out_q.count,
    capacity  = self._cap,
  }
end

--: (TwoQ) -> nil
function TwoQ:reset_stats()
  self._hits      = 0
  self._misses    = 0
  self._evictions = 0
end

return M
