if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--:: Limiter = { allow: (unknown, number | nil) -> boolean, reset: (unknown) -> nil, ... }
--:: TokenBucket = { allow: (unknown, number | nil) -> boolean, tokens: (unknown) -> number, reset: (unknown) -> nil }
--:: SlidingWindow = { allow: (unknown, number | nil) -> boolean, count: (unknown) -> number, remaining: (unknown) -> number, reset: (unknown) -> nil }
--:: FixedWindow = { allow: (unknown, number | nil) -> boolean, count: (unknown) -> number, remaining: (unknown) -> number, reset: (unknown) -> nil }
--:: LeakyBucket = { allow: (unknown, number | nil) -> boolean, level: (unknown) -> number, remaining: (unknown) -> number, reset: (unknown) -> nil }
--:: KeyedLimiter = { allow: (unknown, string, number | nil) -> boolean, get: (unknown, string) -> Limiter, reset: (unknown, string) -> nil }

local M = {}

-- Token bucket: tokens refill at `rate` per second up to `burst`.
-- opts: { rate: number, burst: number, clock: () -> number }
--: (opts: { rate: number, burst: number, clock: () -> number }) -> (TokenBucket | nil, string | nil)
function M.token_bucket(opts)
  local rate = opts.rate
  local burst = opts.burst
  local clock = opts.clock
  if not rate or rate <= 0 then return nil, "rate must be positive" end
  if not burst or burst <= 0 then return nil, "burst must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local token_count = burst
  local last_time = clock()

  local function refill()
    local now = clock()
    local elapsed = now - last_time
    if elapsed > 0 then
      token_count = token_count + elapsed * rate
      if token_count > burst then
        token_count = burst
      end
      last_time = now
    end
  end

  --: (unknown, n: (number | nil)) -> boolean
  function self:allow(n)
    n = n or 1
    refill()
    if token_count >= n then
      token_count = token_count - n
      return true
    end
    return false
  end

  --: (unknown) -> number
  function self:tokens()
    refill()
    return token_count
  end

  --: (unknown) -> nil
  function self:reset()
    token_count = burst
    last_time = clock()
  end

  return self
end

-- Sliding window: counts requests within a rolling time window.
-- Uses two sub-windows for approximation (standard sliding window counter).
-- opts: { limit: number, window: number, clock: () -> number }
--: (opts: { limit: number, window: number, clock: () -> number }) -> (SlidingWindow | nil, string | nil)
function M.sliding_window(opts)
  local limit = opts.limit
  local window = opts.window
  local clock = opts.clock
  if not limit or limit <= 0 then return nil, "limit must be positive" end
  if not window or window <= 0 then return nil, "window must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local prev_count = 0
  local curr_count = 0
  local window_start = clock()

  local function advance()
    local now = clock()
    local elapsed = now - window_start
    if elapsed >= window * 2 then
      -- both windows have passed
      prev_count = 0
      curr_count = 0
      window_start = now - (elapsed % window)
      if now - window_start >= window then
        window_start = window_start + window
      end
    elseif elapsed >= window then
      prev_count = curr_count
      curr_count = 0
      window_start = window_start + window
    end
  end

  local function effective_count()
    advance()
    local now = clock()
    local fraction = (now - window_start) / window
    return curr_count + prev_count * (1 - fraction)
  end

  --: (unknown, n: (number | nil)) -> boolean
  function self:allow(n) -- luacheck: ignore n
    if effective_count() + 1 > limit then
      return false
    end
    advance()
    curr_count = curr_count + 1
    return true
  end

  --: (unknown) -> number
  function self:count()
    return effective_count()
  end

  --: (unknown) -> number
  function self:remaining()
    local c = effective_count()
    local r = limit - c
    if r < 0 then return 0 end
    return r
  end

  --: (unknown) -> nil
  function self:reset()
    prev_count = 0
    curr_count = 0
    window_start = clock()
  end

  return self
end

-- Fixed window: simple counter reset at fixed intervals.
-- opts: { limit: number, window: number, clock: () -> number }
--: (opts: { limit: number, window: number, clock: () -> number }) -> (FixedWindow | nil, string | nil)
function M.fixed_window(opts)
  local limit = opts.limit
  local window = opts.window
  local clock = opts.clock
  if not limit or limit <= 0 then return nil, "limit must be positive" end
  if not window or window <= 0 then return nil, "window must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local count = 0
  local window_start = clock()

  local function check_window()
    local now = clock()
    if now - window_start >= window then
      count = 0
      -- align to window boundary
      local elapsed = now - window_start
      window_start = window_start + math.floor(elapsed / window) * window
    end
  end

  --: (unknown, n: (number | nil)) -> boolean
  function self:allow(n) -- luacheck: ignore n
    check_window()
    if count >= limit then
      return false
    end
    count = count + 1
    return true
  end

  --: (unknown) -> number
  function self:count()
    check_window()
    return count
  end

  --: (unknown) -> number
  function self:remaining()
    check_window()
    local r = limit - count
    if r < 0 then return 0 end
    return r
  end

  --: (unknown) -> nil
  function self:reset()
    count = 0
    window_start = clock()
  end

  return self
end

-- Leaky bucket: requests drain at a fixed rate; rejects when full.
-- opts: { rate: number, capacity: number, clock: () -> number }
--: (opts: { rate: number, capacity: number, clock: () -> number }) -> (LeakyBucket | nil, string | nil)
function M.leaky_bucket(opts)
  local rate = opts.rate
  local capacity = opts.capacity
  local clock = opts.clock
  if not rate or rate <= 0 then return nil, "rate must be positive" end
  if not capacity or capacity <= 0 then return nil, "capacity must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local water = 0.0 --: number
  local last_time = clock()

  local function leak()
    local now = clock()
    local elapsed = now - last_time
    if elapsed > 0 then
      water = water - elapsed * rate
      if water < 0 then
        water = 0.0
      end
      last_time = now
    end
  end

  --: (unknown, n: (number | nil)) -> boolean
  function self:allow(n)
    n = n or 1
    leak()
    if water + n <= capacity then
      water = water + n
      return true
    end
    return false
  end

  --: (unknown) -> number
  function self:level()
    leak()
    return water
  end

  --: (unknown) -> number
  function self:remaining()
    leak()
    local r = capacity - water
    if r < 0 then return 0 end
    return r
  end

  --: (unknown) -> nil
  function self:reset()
    water = 0.0
    last_time = clock()
  end

  return self
end

-- Keyed rate limiter: per-key instances of any algorithm.
-- factory: one of M.token_bucket, M.sliding_window, etc.
-- opts: shared options (clock, rate, etc.) passed to each new instance.
--: <O>(factory: (opts: O) -> unknown, opts: O) -> (KeyedLimiter | nil, string | nil)
function M.keyed(factory, opts)
  if not factory then return nil, "factory is required" end
  if not opts then return nil, "opts is required" end

  local self = {}
  --: { [string]: Limiter }
  local limiters = {}

  local function get(key)
    local l = limiters[key]
    if not l then
      l = factory(opts) --[[:! Limiter]]
      limiters[key] = l
    end
    return l
  end

  --: (unknown, key: string, n: (number | nil)) -> boolean
  function self:allow(key, n)
    return get(key):allow(n)
  end

  --: (unknown, key: string) -> Limiter
  function self:get(key)
    return get(key)
  end

  --: (unknown, key: string) -> nil
  function self:reset(key)
    if key then
      local l = limiters[key]
      if l then l:reset() end
    else
      limiters = {}
    end
  end

  return self
end

return M
