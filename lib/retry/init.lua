if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--: { backoff_none: (attempt: number, opts: RetryOpts) -> number, backoff_linear: (attempt: number, opts: RetryOpts) -> number, backoff_exponential: (attempt: number, opts: RetryOpts) -> number, backoff_fibonacci: (attempt: number, opts: RetryOpts) -> number, run: (fn: () -> unknown, opts: (RetryOpts | nil)) -> unknown, policy: (defaults: RetryOpts) -> RetryPolicy, circuit_breaker: (opts: CircuitBreakerOpts) -> CircuitBreaker }
local M = {}

-- ── Backoff strategies ──────────────────────────────────────────────────────

--: (attempt: number, opts: RetryOpts) -> number
function M.backoff_none(_attempt, _opts)
  return 0
end

--: (attempt: number, opts: RetryOpts) -> number
function M.backoff_linear(attempt, opts)
  local base = (opts and opts.initial_delay or 0.1) * attempt
  local max_delay = opts and opts.max_delay or 30
  if base > max_delay then return max_delay end
  return base
end

--: (attempt: number, opts: RetryOpts) -> number
function M.backoff_exponential(attempt, opts)
  local initial = opts and opts.initial_delay or 0.1
  local multiplier = opts and opts.multiplier or 2
  local base = initial * multiplier ^ (attempt - 1)
  local max_delay = opts and opts.max_delay or 30
  if base > max_delay then return max_delay end
  return base
end

--: (attempt: number, opts: RetryOpts) -> number
function M.backoff_fibonacci(attempt, opts)
  local initial = opts and opts.initial_delay or 0.1
  local a, b = 1, 1
  for _ = 3, attempt do
    a, b = b, a + b
  end
  local base = initial * b
  local max_delay = opts and opts.max_delay or 30
  if base > max_delay then return max_delay end
  return base
end

--:: BackoffStrategies = { none: (attempt: number, opts: RetryOpts) -> number, linear: (attempt: number, opts: RetryOpts) -> number, exponential: (attempt: number, opts: RetryOpts) -> number, fibonacci: (attempt: number, opts: RetryOpts) -> number }
local backoff_strategies = {
  none = M.backoff_none,
  linear = M.backoff_linear,
  exponential = M.backoff_exponential,
  fibonacci = M.backoff_fibonacci,
}

-- ── Apply jitter ────────────────────────────────────────────────────────────

--: (delay: number, jitter: number) -> number
local function apply_jitter(delay, jitter)
  if jitter <= 0 or delay <= 0 then return delay end
  local range = delay * jitter
  local offset = (math.random() * 2 - 1) * range
  local result = delay + offset
  if result < 0 then return 0 end
  return result
end

-- ── Core retry loop ─────────────────────────────────────────────────────────

--:: RetryOpts = { max_attempts: (number | nil), backoff: string | (((attempt: number, opts: RetryOpts) -> number) | nil), initial_delay: (number | nil), max_delay: (number | nil), multiplier: (number | nil), jitter: (number | nil), retry_on: (((err: string, attempt: number) -> boolean) | nil), on_retry: (((err: string, attempt: number, delay: number) -> nil) | nil), sleep: (((seconds: number) -> nil) | nil) }

--: (fn: () -> unknown, opts: (RetryOpts | nil)) -> unknown
function M.run(fn, opts)
  local max_attempts = opts and opts.max_attempts or 3
  local jitter = opts and opts.jitter or 0
  local retry_on = opts and opts.retry_on
  local on_retry = opts and opts.on_retry
  local sleep = opts and opts.sleep
  local backoff_fn
  if opts and opts.backoff then
    if type(opts.backoff) == "function" then
      backoff_fn = opts.backoff
    else
      backoff_fn = backoff_strategies[opts.backoff]
      if not backoff_fn then
        return nil, "unknown backoff strategy: " .. tostring(opts.backoff)
      end
    end
  else
    backoff_fn = M.backoff_none
  end

  local last_err
  for attempt = 1, max_attempts do
    local ok, result = pcall(fn)
    if ok then
      return result
    end
    last_err = result
    if retry_on and not retry_on(result, attempt) then
      return nil, result
    end
    if attempt < max_attempts then
      local delay = backoff_fn(attempt, opts)
      if jitter > 0 then
        delay = apply_jitter(delay, jitter)
      end
      if on_retry then
        on_retry(last_err, attempt, delay)
      end
      if sleep and delay > 0 then
        sleep(delay)
      end
    end
  end
  return nil, last_err
end

-- ── Reusable policy ─────────────────────────────────────────────────────────

--:: RetryPolicy = { defaults: RetryOpts, run: (self: RetryPolicy, fn: () -> unknown, overrides: (RetryOpts | nil)) -> unknown }
local Policy = {}
Policy.__index = Policy

--: (fn: () -> unknown, overrides: (RetryOpts | nil)) -> unknown
function Policy:run(fn, overrides)
  if not overrides then
    return M.run(fn, self.defaults)
  end
  -- Merge: overrides take precedence over defaults
  local merged = {}
  for k, v in pairs(self.defaults) do merged[k] = v end
  for k, v in pairs(overrides) do merged[k] = v end
  return M.run(fn, merged)
end

--: (defaults: RetryOpts) -> RetryPolicy
function M.policy(defaults)
  return setmetatable({ defaults = defaults }, Policy)
end

-- ── Circuit breaker ─────────────────────────────────────────────────────────

--:: CircuitBreakerOpts = { failure_threshold: (number | nil), reset_timeout: (number | nil), half_open_max: (number | nil), clock: ((() -> number) | nil) }
--:: CircuitBreaker = { failure_count: number, success_count: number, _state: string, last_failure_time: number, opts: CircuitBreakerOpts, call: (self: CircuitBreaker, fn: () -> unknown) -> unknown, state: (self: CircuitBreaker) -> string, reset: (self: CircuitBreaker) -> nil }

local CB = {}
CB.__index = CB

--: () -> string
function CB:state()
  if self._state == "open" then
    local clock = self.opts.clock
    local elapsed = clock() - self.last_failure_time
    if elapsed >= (self.opts.reset_timeout or 30) then
      self._state = "half_open"
      self.half_open_count = 0
    end
  end
  return self._state
end

--: () -> nil
function CB:reset()
  self._state = "closed"
  self.failure_count = 0
  self.success_count = 0
  self.half_open_count = 0
  self.last_failure_time = 0
end

--: (fn: () -> unknown) -> unknown
function CB:call(fn)
  local current = self:state()
  if current == "open" then
    return nil, "circuit breaker is open"
  end
  if current == "half_open" then
    local max = self.opts.half_open_max or 1
    if self.half_open_count >= max then
      return nil, "circuit breaker is open"
    end
    self.half_open_count = self.half_open_count + 1
  end
  local ok, result = pcall(fn)
  if ok then
    if current == "half_open" then
      -- Success in half_open → close the circuit
      self._state = "closed"
      self.failure_count = 0
      self.half_open_count = 0
    end
    self.success_count = self.success_count + 1
    return result
  end
  -- Failure
  self.failure_count = self.failure_count + 1
  local clock = self.opts.clock
  self.last_failure_time = clock()
  local threshold = self.opts.failure_threshold or 5
  if self.failure_count >= threshold then
    self._state = "open"
  end
  return nil, result
end

--: (opts: (CircuitBreakerOpts | nil)) -> CircuitBreaker
function M.circuit_breaker(opts)
  return setmetatable({
    opts = opts or {},
    _state = "closed",
    failure_count = 0,
    success_count = 0,
    half_open_count = 0,
    last_failure_time = 0,
  }, CB)
end

return M
