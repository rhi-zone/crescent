if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Generic connection pool with health checking, lifecycle hooks, and stats.
-- Supports idle timeouts, max lifetime, validation, drain/close, and pre-warming.

local M = {}

M._tier = "pure"

--:: PoolStats = { active: integer, created: integer, destroyed: integer, acquire_count: integer, acquire_errors: integer }
--:: ConnMeta = { created_at: number }
--:: ConnEntry = { conn: unknown, created_at: number, idle_since: number }
--:: Pool = { _create: () -> unknown, _destroy: (( unknown) -> nil) | nil, _validate: (( unknown) -> boolean) | nil, _min_size: integer, _max_size: integer, _idle_timeout: number | nil, _max_lifetime: number | nil, _clock: () -> number, _idle: { [integer]: ConnEntry }, _conn_meta: { [unknown]: ConnMeta }, _total: integer, _closed: boolean, _draining: boolean, _stats: PoolStats, acquire: (Pool) -> (unknown | nil, string | nil), release: (Pool, unknown) -> nil, with: (Pool, ( unknown) -> unknown) -> (unknown | nil, string | nil), stats: (Pool) -> unknown, evict: (Pool) -> nil, drain: (Pool) -> nil, close: (Pool) -> nil, warm: (Pool) -> nil, resize: (Pool, integer) -> nil }

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
    local destroy_ = pool._destroy --[[:! ( unknown) -> nil]]
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
      idle[#idle] = nil --[[: unknown]]
      destroy_entry(pool, entry)
    else
      i = i + 1
    end
  end
end

-- acquire() returns (conn, nil) or (nil, errmsg)
--: (Pool) -> (unknown | nil, string | nil)
function pool_mt:acquire()
  if self._closed or self._draining then
    self._stats.acquire_errors = self._stats.acquire_errors + 1
    return nil, self._closed and "pool closed" or "pool draining"
  end

  -- evict stale connections before acquiring
  evict_idle(self)

  local now = self._clock()
  local idle = self._idle

  -- Try idle connections first, skipping invalid or lifetime-expired ones
  while #idle > 0 do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: unknown]]

    -- Check lifetime before validating
    if is_lifetime_expired(self, entry, now) then
      destroy_entry(self, entry)
    else
      -- Run validate if provided
      local valid = true
      if self._validate then
        local validate_ = self._validate --[[:! ( unknown) -> boolean]]
        local ok, result = pcall(validate_, entry.conn)
        if ok and result then valid = true else valid = false end
      end

      if valid then
        self._stats.active = self._stats.active + 1
        self._stats.acquire_count = self._stats.acquire_count + 1
        return entry.conn, nil
      else
        -- Invalid connection: destroy it
        destroy_entry(self, entry)
      end
    end
  end

  -- No idle connections available: create a new one
  if self._total >= self._max_size then
    self._stats.acquire_errors = self._stats.acquire_errors + 1
    return nil, "pool exhausted"
  end

  local ok, conn_or_err = pcall(self._create)
  if not ok then
    self._stats.acquire_errors = self._stats.acquire_errors + 1
    return nil, "create failed: " .. tostring(conn_or_err)
  end

  self._total = self._total + 1
  self._stats.created = self._stats.created + 1
  self._stats.active = self._stats.active + 1
  self._stats.acquire_count = self._stats.acquire_count + 1

  -- Store the creation time for this connection
  -- We need to track per-connection metadata; store in a lookup table
  self._conn_meta[conn_or_err] = { created_at = now }

  return conn_or_err, nil
end

-- release(conn) returns conn to idle pool
--: (Pool, unknown) -> nil
function pool_mt:release(conn)
  if conn == nil then return end

  self._stats.active = self._stats.active - 1

  if self._closed then
    -- pool is closed: destroy the connection
    local meta = self._conn_meta[conn]
    self._conn_meta[conn] = nil --[[: unknown]]
    if meta then
      local entry = { conn = conn, created_at = meta.created_at, idle_since = 0 } --: ConnEntry
      destroy_entry(self, entry)
    else
      if self._destroy then
        local destroy_ = self._destroy --[[:! ( unknown) -> nil]]
        pcall(destroy_, conn)
      end
      self._stats.destroyed = self._stats.destroyed + 1
      self._total = self._total - 1
    end
    return
  end

  if self._draining then
    -- pool is draining: destroy the connection
    local meta = self._conn_meta[conn]
    self._conn_meta[conn] = nil --[[: unknown]]
    if meta then
      local entry = { conn = conn, created_at = meta.created_at, idle_since = 0 } --: ConnEntry
      destroy_entry(self, entry)
    else
      if self._destroy then
        local destroy_ = self._destroy --[[:! ( unknown) -> nil]]
        pcall(destroy_, conn)
      end
      self._stats.destroyed = self._stats.destroyed + 1
      self._total = self._total - 1
    end
    return
  end

  -- Return to idle pool if there's room
  local now = self._clock()
  local meta = self._conn_meta[conn]
  local created_at = meta and meta.created_at or now

  if self._total <= self._max_size then
    local entry = { conn = conn, created_at = created_at, idle_since = now } --: ConnEntry
    self._idle[#self._idle + 1] = entry
  else
    -- over capacity: destroy
    local entry = { conn = conn, created_at = created_at, idle_since = now } --: ConnEntry
    destroy_entry(self, entry)
  end
end

-- with(fn) acquires a connection, calls fn(conn), releases on return or error
--: (Pool, (unknown) -> unknown) -> (unknown | nil, string | nil)
function pool_mt:with(fn)
  local conn, err = self:acquire()
  if conn == nil then
    return nil, err
  end
  local ok, result = pcall(fn, conn)
  self:release(conn)
  if not ok then
    return nil, result
  end
  return result
end

-- stats() returns a snapshot of pool statistics
--: (Pool) -> unknown
function pool_mt:stats()
  local s = self._stats
  return {
    size    = self._total,
    idle    = #self._idle,
    active  = s.active,
    created = s.created,
    destroyed = s.destroyed,
    acquire_count  = s.acquire_count,
    acquire_errors = s.acquire_errors,
  }
end

-- evict() removes stale idle connections based on idle_timeout and max_lifetime
--: (Pool) -> nil
function pool_mt:evict()
  evict_idle(self)
end

-- drain() blocks new acquires and destroys all idle connections
--: (Pool) -> nil
function pool_mt:drain()
  self._draining = true
  local idle = self._idle
  while #idle > 0 do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: unknown]]
    destroy_entry(self, entry)
  end
end

-- close() drains + destroys all active connections (marks pool closed)
--: (Pool) -> nil
function pool_mt:close()
  self:drain()
  self._closed = true
  -- Active connections will be destroyed when released
end

-- warm() pre-creates min_size connections
--: (Pool) -> nil
function pool_mt:warm()
  local target = self._min_size
  if target == 0 then return end
  local now = self._clock()
  while self._total < target and self._total < self._max_size do
    local ok, conn_or_err = pcall(self._create)
    if not ok then break end
    self._total = self._total + 1
    self._stats.created = self._stats.created + 1
    self._conn_meta[conn_or_err] = { created_at = now }
    local entry = { conn = conn_or_err, created_at = now, idle_since = now } --: ConnEntry
    self._idle[#self._idle + 1] = entry
  end
end

-- resize(new_max) adjusts the max pool size
--: (Pool, integer) -> nil
function pool_mt:resize(new_max)
  self._max_size = new_max
  -- Evict excess idle connections if needed
  local idle = self._idle
  while #idle > 0 and self._total > new_max do
    local entry = idle[#idle]
    idle[#idle] = nil --[[: unknown]]
    destroy_entry(self, entry)
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

  local pool = setmetatable({}, pool_mt) --[[: unknown]]
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
