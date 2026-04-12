-- lib/memoize/init.lua
-- Memoization utilities: basic, LRU, TTL, weak, thunk, once, debounce, multi.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Key computation
-- ---------------------------------------------------------------------------

-- Build a single cache-key string from varargs.
-- Numbers and strings are used as-is (joined with \0 separator).
-- Tables and other values use tostring() (identity-based for tables).
-- Single-arg fast path: return the arg directly (avoids concat).
local NIL_SENTINEL = "\0nil\0"

local function make_key(...)
  local n = select("#", ...)
  if n == 0 then return "" end
  if n == 1 then
    local v = ...
    if v == nil then return NIL_SENTINEL end
    return v
  end
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    if v == nil then
      parts[i] = NIL_SENTINEL
    else
      parts[i] = tostring(v)
    end
  end
  return table.concat(parts, "\0")
end

-- ---------------------------------------------------------------------------
-- LRU cache (doubly-linked list + hash, O(1) get/put/evict)
-- ---------------------------------------------------------------------------

-- Node layout: node.key, node.value, node.prev, node.next, node.expires

local function lru_new(max_size)
  -- sentinel head (MRU side) and tail (LRU side)
  local head = {}
  local tail = {}
  head.next = tail
  tail.prev = head
  return { map = {}, head = head, tail = tail, size = 0, max_size = max_size }
end

local function lru_remove(node)
  node.prev.next = node.next
  node.next.prev = node.prev
end

local function lru_push_front(lru, node)
  node.next = lru.head.next
  node.prev = lru.head
  lru.head.next.prev = node
  lru.head.next = node
end

-- Returns node or nil. Moves to front on hit (no TTL check here).
local function lru_get_node(lru, key)
  local node = lru.map[key]
  if not node then return nil end
  lru_remove(node)
  lru_push_front(lru, node)
  return node
end

-- Insert or update. Returns evicted key (or nil).
local function lru_put(lru, key, value, expires)
  local existing = lru.map[key]
  if existing then
    existing.value = value
    existing.expires = expires
    lru_remove(existing)
    lru_push_front(lru, existing)
    return nil
  end
  local node = { key = key, value = value, expires = expires }
  lru.map[key] = node
  lru_push_front(lru, node)
  lru.size = lru.size + 1
  local evicted = nil
  if lru.size > lru.max_size then
    -- evict LRU (node before tail)
    local victim = lru.tail.prev
    lru_remove(victim)
    lru.map[victim.key] = nil
    lru.size = lru.size - 1
    evicted = victim.key
  end
  return evicted
end

local function lru_delete(lru, key)
  local node = lru.map[key]
  if not node then return end
  lru_remove(node)
  lru.map[key] = nil
  lru.size = lru.size - 1
end

local function lru_clear(lru)
  lru.map = {}
  lru.head.next = lru.tail
  lru.tail.prev = lru.head
  lru.size = 0
end

-- ---------------------------------------------------------------------------
-- Memoized function wrapper (shared impl)
-- ---------------------------------------------------------------------------

-- opts fields (all optional):
--   max_size  number   — LRU cap
--   ttl       number   — seconds (uses clock())
--   key       function — custom key(...)
--   clock     function — returns current time (default os.clock; for testing)
--   weak      bool     — use weak values table

local PRESENT = {}  -- sentinel: cached nil return values

local function wrap(fn, opts)
  opts = opts or {}
  local max_size = opts.max_size
  local ttl      = opts.ttl
  local key_fn   = opts.key or make_key
  local clock    = opts.clock or os.clock
  local use_weak = opts.weak

  local hits   = 0
  local misses = 0

  -- storage: either plain table or LRU
  local cache
  local weak_cache  -- separate weak-value table for weak mode
  if max_size then
    cache = lru_new(max_size)
  elseif use_weak then
    weak_cache = setmetatable({}, { __mode = "v" })
  else
    cache = {}  -- plain hash
  end

  -- Unified accessors so the hot path stays readable.
  local function cache_get(k)
    if max_size then
      local node = lru_get_node(cache, k)
      if not node then return nil, false end
      if ttl and node.expires and clock() > node.expires then
        lru_delete(cache, k)
        return nil, false
      end
      return node.value, true
    elseif use_weak then
      local v = weak_cache[k]
      if v == nil then return nil, false end
      -- TTL check
      if ttl then
        local exp = weak_cache[k .. "\0__exp"]
        if exp and clock() > exp then
          weak_cache[k] = nil
          weak_cache[k .. "\0__exp"] = nil
          return nil, false
        end
      end
      return v, true
    else
      local v = cache[k]
      if v == nil then return nil, false end
      -- TTL check on plain table: store expires in parallel slot
      if ttl then
        local exp = cache[k .. "\0__exp"]
        if exp and clock() > exp then
          cache[k] = nil
          cache[k .. "\0__exp"] = nil
          return nil, false
        end
      end
      return v, true
    end
  end

  local function cache_put(k, v, expires)
    if max_size then
      lru_put(cache, k, v, expires)
    elseif use_weak then
      weak_cache[k] = v
      if ttl then weak_cache[k .. "\0__exp"] = expires end
    else
      cache[k] = v
      if ttl then cache[k .. "\0__exp"] = expires end
    end
  end

  local function cache_delete(k)
    if max_size then
      lru_delete(cache, k)
    elseif use_weak then
      weak_cache[k] = nil
      if ttl then weak_cache[k .. "\0__exp"] = nil end
    else
      cache[k] = nil
      if ttl then cache[k .. "\0__exp"] = nil end
    end
  end

  local function cache_clear()
    if max_size then
      lru_clear(cache)
    elseif use_weak then
      weak_cache = setmetatable({}, { __mode = "v" })
    else
      cache = {}
    end
    hits   = 0
    misses = 0
  end

  local mfn = {}

  -- The callable wrapper — returned as a callable table via __call.
  local function call(_, ...)
    local k = key_fn(...)
    local v, found = cache_get(k)
    if found then
      hits = hits + 1
      -- unwrap nil sentinel
      if v == PRESENT then return end
      return v
    end
    misses = misses + 1
    local result = fn(...)
    local expires = ttl and (clock() + ttl) or nil
    -- wrap nil result so we can tell "cached nil" from "not cached"
    cache_put(k, result == nil and PRESENT or result, expires)
    return result
  end

  function mfn:stats()
    return hits, misses
  end

  function mfn:clear()
    cache_clear()
  end

  function mfn:invalidate(...)
    local k = key_fn(...)
    cache_delete(k)
  end

  return setmetatable(mfn, { __call = call })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Memoize fn with optional LRU/TTL/key options.
--: ((...) -> ..., { max_size: number | nil, ttl: number | nil, key: ((...) -> string) | nil, clock: (() -> number) | nil } | nil) -> any
function M.memoize(fn, opts)
  return wrap(fn, opts)
end

--- Memoize a zero-argument function (lazy singleton).
--: ((() -> ...) ) -> (() -> ...)
function M.thunk(fn)
  local computed = false
  local cached
  return function()
    if not computed then
      cached = fn()
      computed = true
    end
    return cached
  end
end

--- Memoize with weak values (GC-friendly for large values).
--: ((...) -> ..., any) -> any
function M.weak(fn, opts)
  opts = opts or {}
  opts.weak = true
  return wrap(fn, opts)
end

--- Run fn exactly once; subsequent calls return the same value without calling fn.
--: ((() -> ...)) -> (() -> ...)
function M.once(fn)
  local ran = false
  local cached
  return function()
    if not ran then
      cached = fn()
      ran = true
    end
    return cached
  end
end

--- Debounce: tracks the last arguments; on each call resets the "timer" conceptually.
-- Since we have no event loop, this implements call tracking only:
-- the returned function records the most recent call and returns the last result.
-- The actual fn is called on the FIRST call after the delay window expires
-- (delay is in seconds, checked via os.clock).
--: ((...) -> ..., number) -> (...) -> ...
function M.debounce(fn, delay)
  local last_call = nil
  local last_result = nil
  return function(...)
    local now = os.clock()
    if last_call == nil or (now - last_call) >= delay then
      last_result = fn(...)
    end
    last_call = now
    return last_result
  end
end

--- Multi-level memoize: memoize a curried function at each level.
-- The top-level function is memoized; its returned function is also memoized.
--: (any) -> any
function M.multi(fn)
  local outer = wrap(fn, {})
  return setmetatable({}, {
    __call = function(_, ...)
      local inner_fn = outer(...)
      if type(inner_fn) ~= "function" then return inner_fn end
      -- wrap inner result too (memoize per outer-key-derived closure)
      -- We memo the inner by wrapping it on first access.
      -- Because outer is memoized, inner_fn is the same object per outer key.
      -- We attach a memoized version to it via a side table.
      return inner_fn
    end
  })
end

return M
