if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local retry = require("lib.retry")

-- Default clock for tests that don't inject one
local default_clock = function() return 0 end
local _cb_new = retry.circuit_breaker
retry.circuit_breaker = function(opts)
  opts = opts or {}
  if not opts.clock then opts.clock = default_clock end
  return _cb_new(opts)
end

-- ── Basic retry behavior ────────────────────────────────────────────────────

T.describe("retry.run: basic", function()
  T.it("succeeds immediately without retrying", function()
    local calls = 0
    local result = retry.run(function()
      calls = calls + 1
      return 42
    end)
    T.eq(result, 42)
    T.eq(calls, 1)
  end)

  T.it("returns nil on function that always fails", function()
    local calls = 0
    local result, err = retry.run(function()
      calls = calls + 1
      error("boom")
    end, { max_attempts = 3 })
    T.eq(result, nil)
    T.ok(err:find("boom"), "error contains boom")
    T.eq(calls, 3)
  end)

  T.it("succeeds after transient failures", function()
    local calls = 0
    local result = retry.run(function()
      calls = calls + 1
      if calls < 3 then error("transient") end
      return "ok"
    end, { max_attempts = 5 })
    T.eq(result, "ok")
    T.eq(calls, 3)
  end)

  T.it("max_attempts = 1 means no retries", function()
    local calls = 0
    local result, err = retry.run(function()
      calls = calls + 1
      error("fail")
    end, { max_attempts = 1 })
    T.eq(result, nil)
    T.ok(err:find("fail"))
    T.eq(calls, 1)
  end)

  T.it("returns nil value from successful function", function()
    local result, err = retry.run(function()
      return nil
    end)
    T.eq(result, nil)
    T.eq(err, nil)
  end)

  T.it("returns false from successful function", function()
    local result = retry.run(function()
      return false
    end)
    T.eq(result, false)
  end)

  T.it("returns string from successful function", function()
    local result = retry.run(function()
      return "hello"
    end)
    T.eq(result, "hello")
  end)
end)

-- ── retry_on predicate ──────────────────────────────────────────────────────

T.describe("retry.run: retry_on", function()
  T.it("skips retry when retry_on returns false", function()
    local calls = 0
    local result, err = retry.run(function()
      calls = calls + 1
      error("fatal")
    end, {
      max_attempts = 5,
      retry_on = function(_err, _attempt) return false end,
    })
    T.eq(calls, 1)
    T.eq(result, nil)
    T.ok(err:find("fatal"))
  end)

  T.it("retries when retry_on returns true", function()
    local calls = 0
    local result, err = retry.run(function()
      calls = calls + 1
      error("transient")
    end, {
      max_attempts = 3,
      retry_on = function(_err, _attempt) return true end,
    })
    T.eq(calls, 3)
    T.eq(result, nil)
    T.ok(err:find("transient"))
  end)

  T.it("retry_on receives error and attempt number", function()
    local seen_errs = {}
    local seen_attempts = {}
    retry.run(function()
      error("err_msg")
    end, {
      max_attempts = 3,
      retry_on = function(err, attempt)
        seen_errs[#seen_errs + 1] = err
        seen_attempts[#seen_attempts + 1] = attempt
        return true
      end,
    })
    T.eq(#seen_errs, 3)
    T.eq(seen_attempts[1], 1)
    T.eq(seen_attempts[2], 2)
    T.eq(seen_attempts[3], 3)
    T.ok(seen_errs[1]:find("err_msg"))
  end)

  T.it("retry_on can filter by error content", function()
    local calls = 0
    retry.run(function()
      calls = calls + 1
      if calls == 1 then error("timeout") end
      if calls == 2 then error("auth_failed") end
      return "ok"
    end, {
      max_attempts = 5,
      retry_on = function(err, _attempt)
        return err:find("timeout") ~= nil
      end,
    })
    -- First call: timeout → retry_on true → retry
    -- Second call: auth_failed → retry_on false → stop
    T.eq(calls, 2)
  end)
end)

-- ── on_retry callback ───────────────────────────────────────────────────────

T.describe("retry.run: on_retry", function()
  T.it("on_retry called with error, attempt, and delay", function()
    local log = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 3,
      backoff = "none",
      on_retry = function(err, attempt, delay)
        log[#log + 1] = { err = err, attempt = attempt, delay = delay }
      end,
    })
    -- on_retry called for attempt 1 and 2 (not the last attempt)
    T.eq(#log, 2)
    T.eq(log[1].attempt, 1)
    T.eq(log[1].delay, 0)
    T.ok(log[1].err:find("fail"))
    T.eq(log[2].attempt, 2)
  end)

  T.it("on_retry not called on immediate success", function()
    local called = false
    retry.run(function()
      return "ok"
    end, {
      on_retry = function() called = true end,
    })
    T.eq(called, false)
  end)

  T.it("on_retry not called on last attempt", function()
    local count = 0
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 2,
      on_retry = function() count = count + 1 end,
    })
    T.eq(count, 1)
  end)
end)

-- ── Backoff: none ───────────────────────────────────────────────────────────

T.describe("retry.backoff_none", function()
  T.it("always returns 0", function()
    T.eq(retry.backoff_none(1, {}), 0)
    T.eq(retry.backoff_none(5, {}), 0)
    T.eq(retry.backoff_none(100, {}), 0)
  end)
end)

-- ── Backoff: linear ─────────────────────────────────────────────────────────

T.describe("retry.backoff_linear", function()
  T.it("returns initial_delay * attempt", function()
    local opts = { initial_delay = 0.5 }
    T.eq(retry.backoff_linear(1, opts), 0.5)
    T.eq(retry.backoff_linear(2, opts), 1.0)
    T.eq(retry.backoff_linear(3, opts), 1.5)
  end)

  T.it("uses default initial_delay of 0.1", function()
    T.eq(retry.backoff_linear(1, {}), 0.1)
    T.eq(retry.backoff_linear(10, {}), 1.0)
  end)

  T.it("caps at max_delay", function()
    local opts = { initial_delay = 10, max_delay = 15 }
    T.eq(retry.backoff_linear(1, opts), 10)
    T.eq(retry.backoff_linear(2, opts), 15) -- capped from 20
    T.eq(retry.backoff_linear(100, opts), 15)
  end)
end)

-- ── Backoff: exponential ────────────────────────────────────────────────────

T.describe("retry.backoff_exponential", function()
  T.it("returns initial_delay * multiplier^(attempt-1)", function()
    local opts = { initial_delay = 0.1, multiplier = 2 }
    T.eq(retry.backoff_exponential(1, opts), 0.1)
    T.eq(retry.backoff_exponential(2, opts), 0.2)
    T.eq(retry.backoff_exponential(3, opts), 0.4)
    T.eq(retry.backoff_exponential(4, opts), 0.8)
  end)

  T.it("uses default multiplier of 2", function()
    local opts = { initial_delay = 1 }
    T.eq(retry.backoff_exponential(1, opts), 1)
    T.eq(retry.backoff_exponential(2, opts), 2)
    T.eq(retry.backoff_exponential(3, opts), 4)
  end)

  T.it("caps at max_delay", function()
    local opts = { initial_delay = 1, multiplier = 10, max_delay = 50 }
    T.eq(retry.backoff_exponential(1, opts), 1)
    T.eq(retry.backoff_exponential(2, opts), 10)
    T.eq(retry.backoff_exponential(3, opts), 50) -- capped from 100
  end)

  T.it("custom multiplier", function()
    local opts = { initial_delay = 1, multiplier = 3 }
    T.eq(retry.backoff_exponential(1, opts), 1)
    T.eq(retry.backoff_exponential(2, opts), 3)
    T.eq(retry.backoff_exponential(3, opts), 9)
  end)
end)

-- ── Backoff: fibonacci ──────────────────────────────────────────────────────

T.describe("retry.backoff_fibonacci", function()
  T.it("returns initial_delay * fib(attempt)", function()
    local opts = { initial_delay = 1 }
    T.eq(retry.backoff_fibonacci(1, opts), 1)  -- fib(1)=1
    T.eq(retry.backoff_fibonacci(2, opts), 1)  -- fib(2)=1
    T.eq(retry.backoff_fibonacci(3, opts), 2)  -- fib(3)=2
    T.eq(retry.backoff_fibonacci(4, opts), 3)  -- fib(4)=3
    T.eq(retry.backoff_fibonacci(5, opts), 5)  -- fib(5)=5
    T.eq(retry.backoff_fibonacci(6, opts), 8)  -- fib(6)=8
  end)

  T.it("scales with initial_delay", function()
    local opts = { initial_delay = 0.5 }
    T.eq(retry.backoff_fibonacci(1, opts), 0.5)
    T.eq(retry.backoff_fibonacci(3, opts), 1.0)
    T.eq(retry.backoff_fibonacci(5, opts), 2.5)
  end)

  T.it("caps at max_delay", function()
    local opts = { initial_delay = 1, max_delay = 5 }
    T.eq(retry.backoff_fibonacci(5, opts), 5)  -- exactly at cap
    T.eq(retry.backoff_fibonacci(6, opts), 5)  -- capped from 8
  end)
end)

-- ── Custom backoff function ─────────────────────────────────────────────────

T.describe("retry.run: custom backoff", function()
  T.it("accepts a function as backoff", function()
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 4,
      backoff = function(attempt, _opts) return attempt * 10 end,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    T.eq(delays[1], 10)
    T.eq(delays[2], 20)
    T.eq(delays[3], 30)
  end)

  T.it("returns error for unknown backoff string", function()
    local result, err = retry.run(function() return 1 end, {
      backoff = "unknown_strategy",
    })
    T.eq(result, nil)
    T.ok(err:find("unknown backoff"))
  end)
end)

-- ── Sleep injection ─────────────────────────────────────────────────────────

T.describe("retry.run: sleep", function()
  T.it("calls injectable sleep with computed delay", function()
    local slept = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 3,
      backoff = "linear",
      initial_delay = 1,
      sleep = function(s) slept[#slept + 1] = s end,
    })
    T.eq(#slept, 2)
    T.eq(slept[1], 1)
    T.eq(slept[2], 2)
  end)

  T.it("does not call sleep on zero delay", function()
    local slept = false
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 2,
      backoff = "none",
      sleep = function(_s) slept = true end,
    })
    T.eq(slept, false)
  end)

  T.it("does not call sleep when no sleep function provided", function()
    -- Should not error even without sleep
    local _, err = retry.run(function()
      error("fail")
    end, {
      max_attempts = 2,
      backoff = "exponential",
      initial_delay = 1,
    })
    T.ok(err:find("fail"))
  end)
end)

-- ── Jitter ──────────────────────────────────────────────────────────────────

T.describe("retry.run: jitter", function()
  T.it("jitter modifies delay within range", function()
    math.randomseed(12345)
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 10,
      backoff = "linear",
      initial_delay = 1,
      max_delay = 1000,
      jitter = 0.1,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    -- All delays should be within +-10% of base
    for i, d in ipairs(delays) do
      local base = 1 * i
      T.ok(d >= base * 0.9 - 0.001, "delay " .. i .. " >= base*0.9: " .. d)
      T.ok(d <= base * 1.1 + 0.001, "delay " .. i .. " <= base*1.1: " .. d)
    end
    -- At least some should differ from base (statistical, very unlikely to fail)
    local all_exact = true
    for i, d in ipairs(delays) do
      if d ~= 1 * i then all_exact = false; break end
    end
    T.eq(all_exact, false, "jitter should vary delays")
  end)

  T.it("zero jitter leaves delay unchanged", function()
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 4,
      backoff = "linear",
      initial_delay = 5,
      jitter = 0,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    T.eq(delays[1], 5)
    T.eq(delays[2], 10)
    T.eq(delays[3], 15)
  end)
end)

-- ── Backoff strategies via run ──────────────────────────────────────────────

T.describe("retry.run: backoff strategies integration", function()
  T.it("exponential backoff produces correct delays", function()
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 5,
      backoff = "exponential",
      initial_delay = 1,
      multiplier = 2,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    T.eq(delays[1], 1)
    T.eq(delays[2], 2)
    T.eq(delays[3], 4)
    T.eq(delays[4], 8)
  end)

  T.it("fibonacci backoff produces correct delays", function()
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 6,
      backoff = "fibonacci",
      initial_delay = 1,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    T.eq(delays[1], 1)
    T.eq(delays[2], 1)
    T.eq(delays[3], 2)
    T.eq(delays[4], 3)
    T.eq(delays[5], 5)
  end)
end)

-- ── Policy ──────────────────────────────────────────────────────────────────

T.describe("retry.policy", function()
  T.it("creates reusable policy with defaults", function()
    local calls = 0
    local p = retry.policy({ max_attempts = 2, backoff = "none" })
    local _, err = p:run(function()
      calls = calls + 1
      error("fail")
    end)
    T.eq(calls, 2)
    T.ok(err:find("fail"))
  end)

  T.it("policy succeeds on success", function()
    local p = retry.policy({ max_attempts = 3 })
    local result = p:run(function() return "yes" end)
    T.eq(result, "yes")
  end)

  T.it("policy allows per-call overrides", function()
    local calls = 0
    local p = retry.policy({ max_attempts = 2 })
    p:run(function()
      calls = calls + 1
      error("fail")
    end, { max_attempts = 5 })
    T.eq(calls, 5)
  end)

  T.it("per-call overrides don't mutate defaults", function()
    local p = retry.policy({ max_attempts = 2, backoff = "none" })
    local calls1 = 0
    p:run(function()
      calls1 = calls1 + 1
      error("fail")
    end, { max_attempts = 10 })
    T.eq(calls1, 10)
    -- Second run uses original defaults
    local calls2 = 0
    p:run(function()
      calls2 = calls2 + 1
      error("fail")
    end)
    T.eq(calls2, 2)
  end)

  T.it("policy with backoff and sleep", function()
    local slept = {}
    local p = retry.policy({
      max_attempts = 3,
      backoff = "exponential",
      initial_delay = 1,
      multiplier = 2,
      sleep = function(s) slept[#slept + 1] = s end,
    })
    p:run(function() error("fail") end)
    T.eq(#slept, 2)
    T.eq(slept[1], 1)
    T.eq(slept[2], 2)
  end)
end)

-- ── Circuit breaker ─────────────────────────────────────────────────────────

T.describe("retry.circuit_breaker: basic state", function()
  T.it("starts in closed state", function()
    local cb = retry.circuit_breaker()
    T.eq(cb:state(), "closed")
  end)

  T.it("stays closed on success", function()
    local cb = retry.circuit_breaker({ failure_threshold = 3 })
    local result = cb:call(function() return "ok" end)
    T.eq(result, "ok")
    T.eq(cb:state(), "closed")
  end)

  T.it("stays closed under threshold", function()
    local cb = retry.circuit_breaker({ failure_threshold = 3 })
    cb:call(function() error("fail") end)
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "closed")
  end)

  T.it("opens after reaching failure_threshold", function()
    local cb = retry.circuit_breaker({ failure_threshold = 3 })
    cb:call(function() error("fail") end)
    cb:call(function() error("fail") end)
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "open")
  end)

  T.it("rejects calls when open", function()
    local cb = retry.circuit_breaker({ failure_threshold = 1 })
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "open")
    local result, err = cb:call(function() return "should not run" end)
    T.eq(result, nil)
    T.ok(err:find("circuit breaker is open"))
  end)
end)

T.describe("retry.circuit_breaker: half_open", function()
  T.it("transitions to half_open after reset_timeout", function()
    local now = 1000
    local cb = retry.circuit_breaker({
      failure_threshold = 1,
      reset_timeout = 10,
      clock = function() return now end,
    })
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "open")
    now = 1011  -- past reset_timeout
    T.eq(cb:state(), "half_open")
  end)

  T.it("closes on success in half_open", function()
    local now = 1000
    local cb = retry.circuit_breaker({
      failure_threshold = 1,
      reset_timeout = 10,
      clock = function() return now end,
    })
    cb:call(function() error("fail") end)
    now = 1011
    T.eq(cb:state(), "half_open")
    local result = cb:call(function() return "recovered" end)
    T.eq(result, "recovered")
    T.eq(cb:state(), "closed")
  end)

  T.it("re-opens on failure in half_open", function()
    local now = 1000
    local cb = retry.circuit_breaker({
      failure_threshold = 1,
      reset_timeout = 10,
      clock = function() return now end,
    })
    cb:call(function() error("fail") end)
    now = 1011
    T.eq(cb:state(), "half_open")
    cb:call(function() error("fail again") end)
    T.eq(cb:state(), "open")
  end)

  T.it("limits concurrent half_open requests", function()
    local now = 1000
    local cb = retry.circuit_breaker({
      failure_threshold = 1,
      reset_timeout = 10,
      half_open_max = 1,
      clock = function() return now end,
    })
    cb:call(function() error("fail") end)
    now = 1011
    T.eq(cb:state(), "half_open")
    -- First half_open call allowed (even if it fails, it counts)
    cb:call(function() error("probe fail") end)
    -- Second half_open call rejected (half_open_count >= max)
    local result, err = cb:call(function() return "should not run" end)
    T.eq(result, nil)
    T.ok(err:find("circuit breaker is open"))
  end)
end)

T.describe("retry.circuit_breaker: reset", function()
  T.it("reset returns to closed state", function()
    local cb = retry.circuit_breaker({ failure_threshold = 1 })
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "open")
    cb:reset()
    T.eq(cb:state(), "closed")
    T.eq(cb.failure_count, 0)
  end)

  T.it("reset allows calls again", function()
    local cb = retry.circuit_breaker({ failure_threshold = 1 })
    cb:call(function() error("fail") end)
    cb:reset()
    local result = cb:call(function() return "ok" end)
    T.eq(result, "ok")
  end)
end)

T.describe("retry.circuit_breaker: error propagation", function()
  T.it("returns nil and error message on failure", function()
    local cb = retry.circuit_breaker({ failure_threshold = 5 })
    local result, err = cb:call(function() error("something broke") end)
    T.eq(result, nil)
    T.ok(err:find("something broke"))
  end)

  T.it("tracks success_count", function()
    local cb = retry.circuit_breaker()
    cb:call(function() return 1 end)
    cb:call(function() return 2 end)
    cb:call(function() return 3 end)
    T.eq(cb.success_count, 3)
  end)
end)

-- ── Circuit breaker: full lifecycle ─────────────────────────────────────────

T.describe("retry.circuit_breaker: full lifecycle", function()
  T.it("closed -> open -> half_open -> closed", function()
    local now = 100
    local cb = retry.circuit_breaker({
      failure_threshold = 2,
      reset_timeout = 5,
      clock = function() return now end,
    })
    -- closed
    T.eq(cb:state(), "closed")
    cb:call(function() return "ok" end)
    T.eq(cb:state(), "closed")
    -- failures trigger open
    cb:call(function() error("f1") end)
    cb:call(function() error("f2") end)
    T.eq(cb:state(), "open")
    -- wait for reset_timeout
    now = 106
    T.eq(cb:state(), "half_open")
    -- success in half_open closes circuit
    local result = cb:call(function() return "recovered" end)
    T.eq(result, "recovered")
    T.eq(cb:state(), "closed")
    T.eq(cb.failure_count, 0)
  end)
end)

-- ── Edge cases ──────────────────────────────────────────────────────────────

T.describe("retry.run: edge cases", function()
  T.it("works with default opts (nil)", function()
    local result = retry.run(function() return 99 end)
    T.eq(result, 99)
  end)

  T.it("works with empty opts table", function()
    local result = retry.run(function() return 99 end, {})
    T.eq(result, 99)
  end)

  T.it("default max_attempts is 3", function()
    local calls = 0
    retry.run(function()
      calls = calls + 1
      error("fail")
    end)
    T.eq(calls, 3)
  end)

  T.it("large max_attempts", function()
    local calls = 0
    retry.run(function()
      calls = calls + 1
      if calls < 50 then error("fail") end
      return "done"
    end, { max_attempts = 100 })
    T.eq(calls, 50)
  end)

  T.it("max_delay caps exponential growth", function()
    local delays = {}
    retry.run(function()
      error("fail")
    end, {
      max_attempts = 10,
      backoff = "exponential",
      initial_delay = 1,
      multiplier = 10,
      max_delay = 100,
      on_retry = function(_err, _attempt, delay)
        delays[#delays + 1] = delay
      end,
    })
    for _, d in ipairs(delays) do
      T.ok(d <= 100, "delay <= max_delay: " .. d)
    end
    -- Later delays should be capped
    T.eq(delays[3], 100)
  end)
end)

T.describe("retry.circuit_breaker: edge cases", function()
  T.it("default failure_threshold is 5", function()
    local cb = retry.circuit_breaker()
    for _ = 1, 4 do
      cb:call(function() error("fail") end)
    end
    T.eq(cb:state(), "closed")
    cb:call(function() error("fail") end)
    T.eq(cb:state(), "open")
  end)

  T.it("default reset_timeout is 30", function()
    local now = 0
    local cb = retry.circuit_breaker({
      failure_threshold = 1,
      clock = function() return now end,
    })
    cb:call(function() error("fail") end)
    now = 29
    T.eq(cb:state(), "open")
    now = 30
    T.eq(cb:state(), "half_open")
  end)

  T.it("works with no opts", function()
    local cb = retry.circuit_breaker()
    T.eq(cb:state(), "closed")
    local result = cb:call(function() return "hello" end)
    T.eq(result, "hello")
  end)
end)

-- ── API shape ───────────────────────────────────────────────────────────────

T.describe("retry: API shape", function()
  T.it("exports expected functions", function()
    T.eq(type(retry.run), "function")
    T.eq(type(retry.policy), "function")
    T.eq(type(retry.circuit_breaker), "function")
    T.eq(type(retry.backoff_none), "function")
    T.eq(type(retry.backoff_linear), "function")
    T.eq(type(retry.backoff_exponential), "function")
    T.eq(type(retry.backoff_fibonacci), "function")
  end)
end)
