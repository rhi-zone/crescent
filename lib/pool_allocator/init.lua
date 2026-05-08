-- lib/pool_allocator/init.lua
-- Object pool, arena bump allocator, freelist, and ring buffer for
-- performance-sensitive code. Pure Lua — no dependencies, LuaJIT + PUC-Rio 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- pool(opts) — growable object pool
-- opts: { size, create, reset }
--   size     — initial/max pool size for pre-allocation hint (default 0)
--   create() — factory returning a fresh object
--   reset(obj) — called on release, restores object to clean state
-- ---------------------------------------------------------------------------
function M.pool(opts)
  opts = opts or {}
  local create = opts.create or function() return {} end
  local reset  = opts.reset  or function() end

  local free   = {}  -- stack of available objects
  local nfree  = 0
  local n_in_use = 0
  local stats = { acquired = 0, released = 0, created = 0, pool_hits = 0, pool_misses = 0 } --: { acquired: integer, released: integer, created: integer, pool_hits: integer, pool_misses: integer }

  -- Pre-allocate if size given
  local presize = opts.size or 0
  for _ = 1, presize do
    local obj = create()
    stats.created = stats.created + 1
    nfree = nfree + 1
    free[nfree] = obj
  end

  local self = {}

  function self:acquire()
    stats.acquired = stats.acquired + 1
    local obj
    if nfree > 0 then
      obj = free[nfree]
      free[nfree] = nil
      nfree = nfree - 1
      stats.pool_hits = stats.pool_hits + 1
    else
      obj = create()
      stats.created = stats.created + 1
      stats.pool_misses = stats.pool_misses + 1
    end
    n_in_use = n_in_use + 1
    return obj
  end

  function self:release(obj)
    if obj == nil then return end
    reset(obj)
    nfree = nfree + 1
    free[nfree] = obj
    n_in_use = n_in_use - 1
    stats.released = stats.released + 1
  end

  function self:acquire_batch(n)
    local result = {}
    for i = 1, n do
      result[i] = self:acquire()
    end
    return result
  end

  function self:release_batch(arr)
    for i = 1, #arr do
      self:release(arr[i])
    end
  end

  function self:with(fn)
    local obj = self:acquire()
    local ok, err = pcall(fn, obj)
    ;(self --[[:! { release: (unknown, unknown) -> nil }]]):release(obj)
    if not ok then
      error(err, 2)
    end
  end

  function self:size()
    return nfree
  end

  function self:capacity()
    return opts.size or math.huge
  end

  function self:in_use()
    return n_in_use
  end

  function self:stats()
    return {
      acquired    = stats.acquired,
      released    = stats.released,
      created     = stats.created,
      pool_hits   = stats.pool_hits,
      pool_misses = stats.pool_misses,
    }
  end

  return self
end

-- ---------------------------------------------------------------------------
-- fixed_pool(opts) — non-growing pool; returns (nil, err) when exhausted
-- opts: same as pool but size is a hard cap
-- ---------------------------------------------------------------------------
function M.fixed_pool(opts)
  opts = opts or {}
  local cap    = opts.size or 16
  local create = opts.create or function() return {} end
  local reset  = opts.reset  or function() end

  local free     = {}
  local nfree    = 0 --: integer
  local n_in_use = 0 --: integer
  local stats    = { acquired = 0, released = 0, created = 0, pool_hits = 0, pool_misses = 0 } --: { acquired: integer, released: integer, created: integer, pool_hits: integer, pool_misses: integer }

  -- Pre-allocate all objects
  for _ = 1, cap do
    local obj = create()
    stats.created = stats.created + 1
    nfree = nfree + 1
    free[nfree] = obj
  end

  local self = {}

  function self:acquire()
    if nfree == 0 then
      return nil, "pool exhausted"
    end
    stats.acquired  = stats.acquired + 1
    stats.pool_hits = stats.pool_hits + 1
    local obj = free[nfree]
    free[nfree] = nil
    nfree = nfree - 1
    n_in_use = n_in_use + 1
    return obj
  end

  function self:release(obj)
    if obj == nil then return end
    reset(obj)
    nfree = nfree + 1
    free[nfree] = obj
    n_in_use = n_in_use - 1
    stats.released = stats.released + 1
  end

  function self:acquire_batch(n)
    if nfree < n then
      return nil, "pool exhausted"
    end
    local result = {}
    for i = 1, n do
      result[i] = self:acquire()
    end
    return result
  end

  function self:release_batch(arr)
    for i = 1, #arr do
      self:release(arr[i])
    end
  end

  function self:with(fn)
    local obj, err = self:acquire()
    if obj == nil then
      return nil, err
    end
    local ok, e = pcall(fn, obj)
    ;(self --[[:! { release: (unknown, unknown) -> nil }]]):release(obj)
    if not ok then
      error(e, 2)
    end
  end

  function self:size()
    return nfree
  end

  function self:capacity()
    return cap
  end

  function self:in_use()
    return n_in_use
  end

  function self:stats()
    return {
      acquired    = stats.acquired,
      released    = stats.released,
      created     = stats.created,
      pool_hits   = stats.pool_hits,
      pool_misses = stats.pool_misses,
    }
  end

  return self
end

-- ---------------------------------------------------------------------------
-- arena(size) — bump allocator
-- Allocates byte offsets into a virtual buffer of `size` bytes.
-- Supports reset() to free all at once. No individual free.
-- ---------------------------------------------------------------------------
function M.arena(size)
  local cap  = size or 4096
  local used = 0

  local self = {}

  -- Returns the byte offset (0-based) of the allocated region, or (nil, err).
  function self:alloc(nbytes)
    if used + nbytes > cap then
      return nil, "arena out of space"
    end
    local offset = used
    used = used + nbytes
    return offset
  end

  function self:reset()
    used = 0
  end

  function self:used()
    return used
  end

  function self:capacity()
    return cap
  end

  function self:remaining()
    return cap - used
  end

  return self
end

-- ---------------------------------------------------------------------------
-- freelist(n) — integer slot allocator backed by a linked free list
-- Slots are 1-based integers in [1..n].
-- ---------------------------------------------------------------------------
function M.freelist(n)
  -- next[i] = next free slot after i; 0 = end of list
  local next_free = {}
  for i = 1, n do
    next_free[i] = i + 1
  end
  -- next_free[n] points past the end; we use n+1 as sentinel
  -- head is the first free slot (1-based), or n+1 when full
  local head     = 1
  local n_in_use = 0

  local self = {}

  function self:alloc()
    if head > n then
      return nil
    end
    local id = head
    head = next_free[id]
    n_in_use = n_in_use + 1
    return id
  end

  function self:free(id)
    if id == nil or id < 1 or id > n then return end
    next_free[id] = head
    head = id
    n_in_use = n_in_use - 1
  end

  function self:in_use()
    return n_in_use
  end

  function self:available()
    return n - n_in_use
  end

  function self:capacity()
    return n
  end

  return self
end

-- ---------------------------------------------------------------------------
-- ring(n) — fixed-capacity circular buffer (FIFO)
-- push() overwrites oldest item when full.
-- ---------------------------------------------------------------------------
function M.ring(n)
  local buf   = {}
  -- rhead: index of next pop (0-based mod n); rtail: index of next push
  local rhead = 0 --: integer
  local rtail = 0 --: integer
  local count = 0 --: integer

  local self = {}

  function self:push(value)
    if count == n then
      -- Overwrite oldest: advance head
      rhead = (rhead + 1) % n
      count = count - 1
    end
    buf[rtail + 1] = value   -- 1-based storage
    rtail  = (rtail + 1) % n
    count  = count + 1
  end

  function self:pop()
    if count == 0 then return nil end
    local value = buf[rhead + 1]
    buf[rhead + 1] = nil
    rhead = (rhead + 1) % n
    count = count - 1
    return value
  end

  function self:peek()
    if count == 0 then return nil end
    return buf[rhead + 1]
  end

  function self:size()
    return count
  end

  function self:capacity()
    return n
  end

  function self:is_full()
    return count == n
  end

  function self:is_empty()
    return count == 0
  end

  function self:to_array()
    local result = {}
    for i = 0, count - 1 do
      result[i + 1] = buf[(rhead + i) % n + 1]
    end
    return result
  end

  return self
end

return M
