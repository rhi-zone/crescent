if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: RLStats = { allowed: number, denied: number, total: number }
--:: TokenBucket = { allow: (TokenBucket, number | nil) -> (boolean, number | nil), refill: (TokenBucket) -> nil, tokens: (TokenBucket) -> number, stats: (TokenBucket) -> RLStats }
--:: LeakyBucket = { allow: (LeakyBucket, number | nil) -> (boolean, number | nil), size: (LeakyBucket) -> number, stats: (LeakyBucket) -> RLStats }
--:: FixedWindow = { allow: (FixedWindow, string | nil) -> (boolean, number | nil), count: (FixedWindow, string | nil) -> number, reset: (FixedWindow, string | nil) -> nil, stats: (FixedWindow) -> RLStats }
--:: SlidingWindowLog = { allow: (SlidingWindowLog, string | nil) -> (boolean, number | nil), stats: (SlidingWindowLog) -> RLStats }
--:: SlidingWindowCounter = { allow: (SlidingWindowCounter, string | nil) -> (boolean, number | nil), stats: (SlidingWindowCounter) -> RLStats }
--:: ReleaseFn = () -> nil
--:: ConcurrentLimiter = { acquire: (ConcurrentLimiter) -> ReleaseFn | nil, count: (ConcurrentLimiter) -> number, stats: (ConcurrentLimiter) -> RLStats }
--:: MultiLimiter = { allow: (MultiLimiter, string | nil) -> (boolean, number | nil), stats: (MultiLimiter) -> RLStats }
--:: FWEntry = { count: number, window_start: number }
--:: SWCEntry = { prev: number, curr: number, window_start: number }

-- Token bucket: smooth bursts.
-- Tokens refill at `rate` per second up to `capacity`.
-- opts: { capacity: number, rate: number, clock: () -> number }
--: (opts: { capacity: number, rate: number, clock: () -> number }) -> (TokenBucket | nil, string | nil)
function M.token_bucket(opts)
  local capacity = opts.capacity
  local rate = opts.rate
  local clock = opts.clock
  if not capacity or capacity <= 0 then return nil, "capacity must be positive" end
  if not rate or rate <= 0 then return nil, "rate must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local token_count = capacity
  local last_refill = clock()
  local allowed = 0
  local denied = 0

  local function do_refill()
    local now = clock()
    local elapsed = now - last_refill
    if elapsed > 0 then
      token_count = token_count + elapsed * rate
      if token_count > capacity then token_count = capacity end
      last_refill = now
    end
  end

  --: (n: (number | nil)) -> (boolean, (number | nil))
  function self:allow(n)
    n = n or 1
    do_refill()
    if token_count >= n then
      token_count = token_count - n
      allowed = allowed + 1
      return true
    end
    denied = denied + 1
    local wait = (n - token_count) / rate
    return false, wait
  end

  --: () -> nil
  function self:refill()
    do_refill()
  end

  --: () -> number
  function self:tokens()
    do_refill()
    return token_count
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Leaky bucket: strict output rate.
-- Requests add water; water drains at `rate` per second.
-- Rejects when bucket would overflow.
-- opts: { capacity: number, rate: number, clock: () -> number }
--: (opts: { capacity: number, rate: number, clock: () -> number }) -> (LeakyBucket | nil, string | nil)
function M.leaky_bucket(opts)
  local capacity = opts.capacity
  local rate = opts.rate
  local clock = opts.clock
  if not capacity or capacity <= 0 then return nil, "capacity must be positive" end
  if not rate or rate <= 0 then return nil, "rate must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  local water = 0 --: number
  local last_time = clock()
  local allowed = 0
  local denied = 0

  local function do_leak()
    local now = clock()
    local elapsed = now - last_time
    if elapsed > 0 then
      water = water - elapsed * rate
      if water < 0 then water = 0 end
      last_time = now
    end
  end

  --: (n: (number | nil)) -> (boolean, (number | nil))
  function self:allow(n)
    n = n or 1
    do_leak()
    if water + n <= capacity then
      water = water + n
      allowed = allowed + 1
      return true
    end
    denied = denied + 1
    -- wait until enough drains: need to drain (water + n - capacity) more
    local wait = (water + n - capacity) / rate
    return false, wait
  end

  --: () -> number
  function self:size()
    do_leak()
    return water
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Fixed window counter: simple, efficient per-key limiting.
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
  -- per-key store: key -> { count: number, window_start: number }
  local store = {} --: { [string]: FWEntry }
  local allowed = 0
  local denied = 0

  --: (string) -> FWEntry
  local function get_entry(key)
    local entry = store[key]
    if not entry then
      entry = { count = 0, window_start = clock() }
      store[key] = entry
    end
    return entry
  end

  --: (FWEntry) -> nil
  local function check_window(entry)
    local now = clock()
    if now >= entry.window_start + window then
      entry.count = 0
      local elapsed = now - entry.window_start
      entry.window_start = entry.window_start + math.floor(elapsed / window) * window
    end
  end

  --: (key: (string | nil)) -> (boolean, (number | nil))
  function self:allow(key)
    local k = key or "_default"
    local entry = get_entry(k)
    check_window(entry)
    if entry.count < limit then
      entry.count = entry.count + 1
      allowed = allowed + 1
      return true
    end
    denied = denied + 1
    local wait = entry.window_start + window - clock()
    if wait < 0 then wait = 0 end
    return false, wait
  end

  --: (key: (string | nil)) -> number
  function self:count(key)
    local k = key or "_default"
    local entry = get_entry(k)
    check_window(entry)
    return entry.count
  end

  --: (key: (string | nil)) -> nil
  function self:reset(key)
    local k = key or "_default"
    store[k] = { count = 0, window_start = clock() }
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Sliding window log: precise limiting using sorted timestamp log.
-- Memory usage grows with limit (stores one timestamp per allowed request).
-- opts: { limit: number, window: number, clock: () -> number }
--: (opts: { limit: number, window: number, clock: () -> number }) -> (SlidingWindowLog | nil, string | nil)
function M.sliding_window_log(opts)
  local limit = opts.limit
  local window = opts.window
  local clock = opts.clock
  if not limit or limit <= 0 then return nil, "limit must be positive" end
  if not window or window <= 0 then return nil, "window must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  -- per-key log: key -> array of timestamps (sorted ascending)
  local logs = {} --: { [string]: { [integer]: number } }
  local allowed = 0
  local denied = 0

  --: (string) -> { [integer]: number }
  local function get_log(key)
    local l = logs[key]
    if not l then
      l = {}
      logs[key] = l
    end
    return l
  end

  --: ({ [integer]: number }, number) -> nil
  local function prune(log, cutoff)
    -- remove timestamps older than cutoff from the front
    local i = 1
    while i <= #log and log[i] <= cutoff do
      i = i + 1
    end
    if i > 1 then
      -- shift remaining down
      local n = #log - i + 1
      for j = 1, n do
        log[j] = log[j + i - 1]
      end
      local log_any = log --[[: any]]
      for j = n + 1, #log do
        log_any[j] = nil
      end
    end
  end

  --: (key: (string | nil)) -> (boolean, (number | nil))
  function self:allow(key)
    local k = key or "_default"
    local log = get_log(k)
    local now = clock()
    local cutoff = now - window
    prune(log, cutoff)
    if #log < limit then
      log[#log + 1] = now
      allowed = allowed + 1
      return true
    end
    denied = denied + 1
    -- oldest entry + window = when it expires
    local wait = log[1] + window - now
    if wait < 0 then wait = 0 end
    return false, wait
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Sliding window counter: approximate limiting using two fixed windows.
-- Memory-efficient; error is at most 1/limit of limit for smooth traffic.
-- opts: { limit: number, window: number, clock: () -> number }
--: (opts: { limit: number, window: number, clock: () -> number }) -> (SlidingWindowCounter | nil, string | nil)
function M.sliding_window_counter(opts)
  local limit = opts.limit
  local window = opts.window
  local clock = opts.clock
  if not limit or limit <= 0 then return nil, "limit must be positive" end
  if not window or window <= 0 then return nil, "window must be positive" end
  if not clock then return nil, "clock is required" end

  local self = {}
  -- per-key store: key -> { prev: number, curr: number, window_start: number }
  local store = {} --: { [string]: SWCEntry }
  local allowed = 0
  local denied = 0

  --: (string) -> SWCEntry
  local function get_entry(key)
    local entry = store[key]
    if not entry then
      entry = { prev = 0, curr = 0, window_start = clock() }
      store[key] = entry
    end
    return entry
  end

  --: (SWCEntry) -> nil
  local function advance(entry)
    local now = clock()
    local elapsed = now - entry.window_start
    if elapsed >= window * 2 then
      entry.prev = 0
      entry.curr = 0
      entry.window_start = now
    elseif elapsed >= window then
      entry.prev = entry.curr
      entry.curr = 0
      entry.window_start = entry.window_start + window
    end
  end

  --: (SWCEntry) -> number
  local function weighted_count(entry)
    local now = clock()
    local elapsed = now - entry.window_start
    local fraction = elapsed / window
    if fraction > 1 then fraction = 1 end
    return entry.curr + entry.prev * (1 - fraction)
  end

  --: (key: (string | nil)) -> (boolean, (number | nil))
  function self:allow(key)
    local k = key or "_default"
    local entry = get_entry(k)
    advance(entry)
    if weighted_count(entry) + 1 <= limit then
      entry.curr = entry.curr + 1
      allowed = allowed + 1
      return true
    end
    denied = denied + 1
    -- approximate wait: when weighted count drops below limit
    -- weighted = curr + prev*(1-t/w) < limit => t > w*(1 - (limit-curr)/prev)
    local wait = 0 --: number
    if entry.prev > 0 then
      local frac_needed = 1 - (limit - entry.curr) / entry.prev
      if frac_needed > 0 then
        local now = clock()
        local elapsed = now - entry.window_start
        wait = frac_needed * window - elapsed
        if wait < 0 then wait = 0 end
      end
    end
    return false, wait
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Concurrent limiter: caps simultaneous in-flight requests.
-- opts: { limit: number }
--: (opts: { limit: number }) -> (ConcurrentLimiter | nil, string | nil)
function M.concurrent(opts)
  local limit = opts.limit
  if not limit or limit <= 0 then return nil, "limit must be positive" end

  local self = {}
  local current = 0
  local allowed = 0
  local denied = 0

  --: () -> ReleaseFn | nil
  function self:acquire()
    if current >= limit then
      denied = denied + 1
      return nil
    end
    current = current + 1
    allowed = allowed + 1
    local released = false
    return function()
      if not released then
        released = true
        current = current - 1
      end
    end
  end

  --: () -> number
  function self:count()
    return current
  end

  --: () -> { allowed: number, denied: number, total: number }
  function self:stats()
    return { allowed = allowed, denied = denied, total = allowed + denied }
  end

  return self
end

-- Multi-limiter: all constituent limiters must pass.
-- Returns false (and max wait) if any limiter denies.
-- Variadic: RL.multi(limiter1, limiter2, ...)
--: (...unknown) -> (MultiLimiter | nil, string | nil)
function M.multi(...)
  local limiters_ = {...}
  local limiters = limiters_ --[[:! { [integer]: { allow: (unknown, string | nil) -> (boolean, number | nil) } }]]
  if #limiters == 0 then return nil, "at least one limiter is required" end

  local self = {}

  --: (key: (string | nil)) -> (boolean, (number | nil))
  function self:allow(key)
    local max_wait = 0 --: number
    for i = 1, #limiters do
      local ok, wait = limiters[i]:allow(key)
      if not ok then
        local wait_ = wait or 0
        if wait_ > max_wait then max_wait = wait_ end
        -- consume remaining limiters without side effects by not calling them
        -- but we must still return denied
        -- We already called allow on limiters[i]; the others are not called,
        -- which is intentional: don't consume quota from limiters that haven't
        -- been reached yet. We return early.
        return false, max_wait
      end
    end
    return true
  end

  return self
end

return M
