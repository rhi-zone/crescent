if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Generic connection pool with health checking, lifecycle hooks, and stats.
-- Supports idle timeouts, max lifetime, validation, drain/close, and pre-warming.

local M = {}

M._tier = "pure"

--:: PoolStats = { active: integer, created: integer, destroyed: integer, acquire_count: integer, acquire_errors: integer }
--:: ConnMeta = { created_at: number }
--:: ConnEntry = { conn: any, created_at: number, idle_since: number }
--:: Pool = { _create: () -> any, _destroy: ((any) -> nil) | nil, _validate: ((any) -> boolean) | nil, _min_size: integer, _max_size: integer, _idle_timeout: number | nil, _max_lifetime: number | nil, _clock: () -> number, _idle: { [integer]: ConnEntry }, _conn_meta: { [any]: ConnMeta }, _total: integer, _closed: boolean, _draining: boolean, _stats: PoolStats, acquire: (Pool) -> (any | nil, string | nil), release: (Pool, any) -> nil, with: (Pool, (any) -> any) -> (any | nil, string | nil), stats: (Pool) -> any, evict: (Pool) -> nil, drain: (Pool) -> nil, close: (Pool) -> nil, warm: (Pool) -> nil, resize: (Pool, integer) -> nil }

local pool_mt = {}
pool_mt.__index = pool_mt

-- Internal: check if a connection entry is expired by idle_timeout
--: (Pool, ConnEntry, number) -> boolean
local function is_idle_expired(pool, entry, now)
  local timeout = pool._idle_timeout
  if timeout == nil then return false end
  local timeout_ = timeout --[[:! number]]
  return (now - entry.idle_since) > timeout_
end

-- Internal: check if a connection entry is expired by max_lifetime
--: (Pool, ConnEntry, number) -> boolean
local function is_lifetime_expired(pool, entry, now)
  local lifetime = pool._max_lifetime
  if lifetime == nil then return false end
  local lifetime_ = lifetime --[[:! number]]
  return (now - entry.created_at) > lifetime_
end

-- Internal: destroy a connection entry (calls destroy hook and updates stats)
--: (Pool, ConnEntry) -> nil
local function destroy_entry(pool, entry)
  if pool._destroy then
    local destroy_ = pool._destroy --[[:! (any) -> nil]]
    local ok, err = pcall(destroy_, entry.conn)
    if not ok then
      -- suppress errors from destroy callbacks
      _ = err
    end
  end
  pool._stats.destroyed = pool._stats.destroyed + 1
  pool._total = pool._total - 1
end

-- Internal: evict expired idle connections (called from acquire and evict)
--: (Pool) -> nil
local function evict_idle(pool)
  local now = pool._clock()
  local idle = pool._idle
  local i = 1
  while i <= #idle do
    local entry = idle[i]
    if is_idle_expired(pool, entry, now) or is_lifetime_expired(pool, entry, now) then
      -- remove from idle list by swapping with last
      idle[i] = idle[#idle]
      idle[#idle] = nil --[[: any]]
      destroy_entry(pool, entry)
    else
      i = i + 1
    end
  end
end

-- acquire() returns (conn, nil) or (nil, errmsg)
function pool_mt:acquire()
  local self_ = self --[[:! Pool]]
  if self_._closed or self_._draining then
    self_._stats.acquire_errors = self_._stats.acquire_errors + 1
    return nil, self_._closed and "pool closed" or "pool draining"
  end

  -- evict stale connections before acquiring
  evict_idle(self_)

  local now = self_._clock()
  local idle = self_._idle

  -- Try idle connections first, skipping invalid or lifetime-expired ones
  while #idle > 0 do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: any]]

    -- Check lifetime before validating
    if is_lifetime_expired(self_, entry, now) then
      destroy_entry(self_, entry)
    else
      -- Run validate if provided
      local valid = true
      if self_._validate then
        local validate_ = self_._validate --[[:! (any) -> boolean]]
        local ok, result = pcall(validate_, entry.conn)
        if ok and result then valid = true else valid = false end
      end

      if valid then
        self_._stats.active = self_._stats.active + 1
        self_._stats.acquire_count = self_._stats.acquire_count + 1
        return entry.conn, nil
      else
        -- Invalid connection: destroy it
        destroy_entry(self_, entry)
      end
    end
  end

  -- No idle connections available: create a new one
  if self_._total >= self_._max_size then
    self_._stats.acquire_errors = self_._stats.acquire_errors + 1
    return nil, "pool exhausted"
  end

  local ok, conn_or_err = pcall(self_._create)
  if not ok then
    self_._stats.acquire_errors = self_._stats.acquire_errors + 1
    return nil, "create failed: " .. tostring(conn_or_err)
  end

  self_._total = self_._total + 1
  self_._stats.created = self_._stats.created + 1
  self_._stats.active = self_._stats.active + 1
  self_._stats.acquire_count = self_._stats.acquire_count + 1

  -- Store the creation time for this connection
  -- We need to track per-connection metadata; store in a lookup table
  self_._conn_meta[conn_or_err] = { created_at = now }

  return conn_or_err, nil
end

-- release(conn) returns conn to idle pool
function pool_mt:release(conn)
  local self_ = self --[[:! Pool]]
  if conn == nil then return end

  self_._stats.active = self_._stats.active - 1

  if self_._closed then
    -- pool is closed: destroy the connection
    local meta = self_._conn_meta[conn]
    self_._conn_meta[conn] = nil --[[: any]]
    if meta then
      local entry = { conn = conn, created_at = meta.created_at, idle_since = 0 } --: ConnEntry
      destroy_entry(self_, entry)
    else
      if self_._destroy then
        local destroy_ = self_._destroy --[[:! (any) -> nil]]
        pcall(destroy_, conn)
      end
      self_._stats.destroyed = self_._stats.destroyed + 1
      self_._total = self_._total - 1
    end
    return
  end

  if self_._draining then
    -- pool is draining: destroy the connection
    local meta = self_._conn_meta[conn]
    self_._conn_meta[conn] = nil --[[: any]]
    if meta then
      local entry = { conn = conn, created_at = meta.created_at, idle_since = 0 } --: ConnEntry
      destroy_entry(self_, entry)
    else
      if self_._destroy then
        local destroy_ = self_._destroy --[[:! (any) -> nil]]
        pcall(destroy_, conn)
      end
      self_._stats.destroyed = self_._stats.destroyed + 1
      self_._total = self_._total - 1
    end
    return
  end

  -- Return to idle pool if there's room
  local now = self_._clock()
  local meta = self_._conn_meta[conn]
  local created_at = meta and meta.created_at or now

  if self_._total <= self_._max_size then
    local entry = { conn = conn, created_at = created_at, idle_since = now } --: ConnEntry
    self_._idle[#self_._idle + 1] = entry
  else
    -- over capacity: destroy
    local entry = { conn = conn, created_at = created_at, idle_since = now } --: ConnEntry
    destroy_entry(self_, entry)
  end
end

-- with(fn) acquires a connection, calls fn(conn), releases on return or error
function pool_mt:with(fn)
  local self_ = self --[[:! Pool]]
  local conn, err = self_:acquire()
  if conn == nil then
    return nil, err
  end
  local ok, result = pcall(fn, conn)
  self_:release(conn)
  if not ok then
    return nil, result
  end
  return result
end

-- stats() returns a snapshot of pool statistics
function pool_mt:stats()
  local self_ = self --[[:! Pool]]
  local s = self_._stats
  return {
    size    = self_._total,
    idle    = #self_._idle,
    active  = s.active,
    created = s.created,
    destroyed = s.destroyed,
    acquire_count  = s.acquire_count,
    acquire_errors = s.acquire_errors,
  }
end

-- evict() removes stale idle connections based on idle_timeout and max_lifetime
function pool_mt:evict()
  local self_ = self --[[:! Pool]]
  evict_idle(self_)
end

-- drain() blocks new acquires and destroys all idle connections
function pool_mt:drain()
  local self_ = self --[[:! Pool]]
  self_._draining = true
  local idle = self_._idle
  while #idle > 0 do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: any]]
    destroy_entry(self_, entry)
  end
end

-- close() drains + destroys all active connections (marks pool closed)
function pool_mt:close()
  local self_ = self --[[:! Pool]]
  self_:drain()
  self_._closed = true
  -- Active connections will be destroyed when released
end

-- warm() pre-creates min_size connections
function pool_mt:warm()
  local self_ = self --[[:! Pool]]
  local target = self_._min_size
  if target == 0 then return end
  local now = self_._clock()
  while self_._total < target and self_._total < self_._max_size do
    local ok, conn_or_err = pcall(self_._create)
    if not ok then break end
    self_._total = self_._total + 1
    self_._stats.created = self_._stats.created + 1
    self_._conn_meta[conn_or_err] = { created_at = now }
    local entry = { conn = conn_or_err, created_at = now, idle_since = now } --: ConnEntry
    self_._idle[#self_._idle + 1] = entry
  end
end

-- resize(new_max) adjusts the max pool size
function pool_mt:resize(new_max)
  local self_ = self --[[:! Pool]]
  self_._max_size = new_max
  -- Evict excess idle connections if needed
  local idle = self_._idle
  while #idle > 0 and self_._total > new_max do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: any]]
    destroy_entry(self_, entry)
  end
end

-- Create a new connection pool.
-- opts.create      function() -> conn  (required)
-- opts.destroy     function(conn)       (optional)
-- opts.validate    function(conn) -> bool  (optional)
-- opts.min_size    number  (default 0)
-- opts.max_size    number  (default 10)
-- opts.idle_timeout  number  (default nil = no timeout)
-- opts.max_lifetime  number  (default nil = no limit)
-- opts.clock       function() -> number  (required)
--: ({ create: () -> unknown, destroy: ((unknown) -> nil) | nil, validate: ((unknown) -> boolean) | nil, min_size: integer | nil, max_size: integer | nil, idle_timeout: number | nil, max_lifetime: number | nil, clock: () -> number } | nil) -> (Pool | nil, string | nil)
function M.new(opts)
  if not opts or not opts.create then
    return nil, "connection_pool.new: opts.create is required"
  end

  local pool = setmetatable({}, pool_mt) --[[: any]]
  local self_ = pool --[[:! Pool]]
  self_._create       = opts.create
  self_._destroy      = opts.destroy
  self_._validate     = opts.validate
  self_._min_size     = opts.min_size or 0
  self_._max_size     = opts.max_size or 10
  self_._idle_timeout = opts.idle_timeout
  self_._max_lifetime = opts.max_lifetime
  self_._clock        = opts.clock

  self_._idle      = {}
  self_._conn_meta = {}  -- conn -> { created_at }
  self_._total     = 0   -- total connections (idle + active)
  self_._closed    = false
  self_._draining  = false

  self_._stats = {
    active         = 0,
    created        = 0,
    destroyed      = 0,
    acquire_count  = 0,
    acquire_errors = 0,
  }

  if self_._min_size > 0 then
    self_:warm()
  end

  return self_
end

return M
