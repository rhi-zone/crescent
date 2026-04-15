if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local Q = require("lib.async_queue")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Make a task that calls done(nil, value) immediately.
local function ok_task(value)
  return function(done) done(nil, value) end
end

-- Make a task that calls done(err) immediately.
local function fail_task(err)
  return function(done) done(err or "oops") end
end

-- Assert two arrays have the same length and equal elements.
local function eq_array(got, expected, label)
  label = label or "array"
  T.eq(#got, #expected, label .. " length")
  for i = 1, #expected do
    T.eq(got[i], expected[i], label .. "[" .. i .. "]")
  end
end

-- ---------------------------------------------------------------------------
-- Basic execution order
-- ---------------------------------------------------------------------------

T.describe("async_queue: basic task execution", function()
  T.it("executes tasks and completes them", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    local ran = {}
    q:push(function(done) ran[#ran + 1] = 1; done(nil) end)
    q:push(function(done) ran[#ran + 1] = 2; done(nil) end)
    q:push(function(done) ran[#ran + 1] = 3; done(nil) end)
    q:run_all()
    eq_array(ran, {1, 2, 3})
  end)

  T.it("run_all drives until empty", function()
    local q = Q.new({ concurrency = 2, clock_fn = os.clock })
    local count = 0
    for i = 1, 5 do
      q:push(function(done) count = count + 1; done(nil) end)
    end
    q:run_all()
    T.eq(count, 5)
  end)

  T.it("stats: completed count is correct", function()
    local q = Q.new({ concurrency = 2, clock_fn = os.clock })
    for i = 1, 4 do
      q:push(ok_task(i))
    end
    q:run_all()
    local s = q:stats()
    T.eq(s.completed, 4)
    T.eq(s.failed, 0)
    T.eq(s.pending, 0)
    T.eq(s.active, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Concurrency limit
-- ---------------------------------------------------------------------------

T.describe("async_queue: concurrency limit", function()
  T.it("runs at most concurrency tasks at once", function()
    local q = Q.new({ concurrency = 2, clock_fn = os.clock })
    local peak = 0
    local current = 0
    local tasks_done = 0

    for i = 1, 6 do
      q:push(function(done)
        current = current + 1
        if current > peak then peak = current end
        done(nil)
        current = current - 1
        tasks_done = tasks_done + 1
      end)
    end
    q:run_all()
    T.ok(peak <= 2, "peak active should be <= concurrency=2, got " .. peak)
    T.eq(tasks_done, 6)
  end)

  T.it("concurrency=1 runs tasks serially", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    local order = {}
    for i = 1, 3 do
      local n = i
      q:push(function(done) order[#order + 1] = n; done(nil) end)
    end
    q:run_all()
    eq_array(order, {1, 2, 3})
  end)
end)

-- ---------------------------------------------------------------------------
-- Priority ordering
-- ---------------------------------------------------------------------------

T.describe("async_queue: priority ordering", function()
  T.it("lower priority number runs first", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    local order = {}
    -- Push higher-priority-number tasks first, then lower
    q:push({ fn = function(done) order[#order + 1] = "c"; done(nil) end, priority = 20 })
    q:push({ fn = function(done) order[#order + 1] = "a"; done(nil) end, priority = 1 })
    q:push({ fn = function(done) order[#order + 1] = "b"; done(nil) end, priority = 5 })
    q:run_all()
    eq_array(order, {"a", "b", "c"})
  end)

  T.it("same priority preserves insertion order", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    local order = {}
    q:push({ fn = function(done) order[#order + 1] = 1; done(nil) end, priority = 5 })
    q:push({ fn = function(done) order[#order + 1] = 2; done(nil) end, priority = 5 })
    q:push({ fn = function(done) order[#order + 1] = 3; done(nil) end, priority = 5 })
    q:run_all()
    eq_array(order, {1, 2, 3})
  end)
end)

-- ---------------------------------------------------------------------------
-- on_done / on_error callbacks
-- ---------------------------------------------------------------------------

T.describe("async_queue: on_done and on_error callbacks", function()
  T.it("on_done fires with result", function()
    local results = {}
    local q = Q.new({
      concurrency = 1,
      clock_fn = os.clock,
      on_done = function(task, result) results[#results + 1] = result end,
    })
    q:push(ok_task(42))
    q:push(ok_task(99))
    q:run_all()
    eq_array(results, {42, 99})
  end)

  T.it("on_error fires with error message", function()
    local errors = {}
    local q = Q.new({
      concurrency = 1,
      retry = 0,
      clock_fn = os.clock,
      on_error = function(task, err) errors[#errors + 1] = err end,
    })
    q:push(fail_task("boom"))
    q:run_all()
    eq_array(errors, {"boom"})
  end)

  T.it("on_done event listener fires", function()
    local results = {}
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    q:on("done", function(task, result) results[#results + 1] = result end)
    q:push(ok_task("hello"))
    q:push(ok_task("world"))
    q:run_all()
    eq_array(results, {"hello", "world"})
  end)

  T.it("on error event listener fires", function()
    local errs = {}
    local q = Q.new({ concurrency = 1, retry = 0, clock_fn = os.clock })
    q:on("error", function(task, err) errs[#errs + 1] = err end)
    q:push(fail_task("bad"))
    q:run_all()
    eq_array(errs, {"bad"})
  end)
end)

-- ---------------------------------------------------------------------------
-- Retries
-- ---------------------------------------------------------------------------

T.describe("async_queue: retries", function()
  T.it("retries a failing task N times then fails", function()
    local attempts = 0
    local errors = {}
    local q = Q.new({
      concurrency = 1,
      retry = 2,
      retry_delay = 0,
      clock_fn = os.clock,
      on_error = function(task, err) errors[#errors + 1] = err end,
    })
    q:push(function(done)
      attempts = attempts + 1
      done("always fails")
    end)
    q:run_all()
    -- 1 initial + 2 retries = 3 attempts
    T.eq(attempts, 3)
    T.eq(#errors, 1)
    local s = q:stats()
    T.eq(s.failed, 1)
    T.eq(s.retried, 2)
  end)

  T.it("succeeds after retry if task eventually passes", function()
    local attempts = 0
    local done_results = {}
    local q = Q.new({
      concurrency = 1,
      retry = 3,
      retry_delay = 0,
      clock_fn = os.clock,
      on_done = function(task, result) done_results[#done_results + 1] = result end,
    })
    q:push(function(done)
      attempts = attempts + 1
      if attempts < 3 then
        done("not yet")
      else
        done(nil, "success")
      end
    end)
    q:run_all()
    T.eq(attempts, 3)
    eq_array(done_results, {"success"})
    local s = q:stats()
    T.eq(s.completed, 1)
    T.eq(s.failed, 0)
    T.eq(s.retried, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- pause / resume
-- ---------------------------------------------------------------------------

T.describe("async_queue: pause and resume", function()
  T.it("paused queue does not process tasks", function()
    local ran = false
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    q:pause()
    q:push(function(done) ran = true; done(nil) end)
    q:tick()
    T.eq(ran, false)
    q:resume()
    q:tick()
    T.eq(ran, true)
  end)

  T.it("tasks accumulate while paused and run after resume", function()
    local q = Q.new({ concurrency = 2, clock_fn = os.clock })
    local count = 0
    q:pause()
    for i = 1, 4 do
      q:push(function(done) count = count + 1; done(nil) end)
    end
    -- tick while paused — nothing runs
    q:tick()
    T.eq(count, 0)
    q:resume()
    q:run_all()
    T.eq(count, 4)
  end)
end)

-- ---------------------------------------------------------------------------
-- cancel / cancel_all / clear
-- ---------------------------------------------------------------------------

T.describe("async_queue: cancel", function()
  T.it("cancel by id prevents execution", function()
    local ran = {}
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    q:push({ fn = function(done) ran[#ran + 1] = "a"; done(nil) end, id = "a" })
    q:push({ fn = function(done) ran[#ran + 1] = "b"; done(nil) end, id = "b" })
    q:push({ fn = function(done) ran[#ran + 1] = "c"; done(nil) end, id = "c" })
    q:cancel("b")
    q:run_all()
    -- "b" should not appear
    eq_array(ran, {"a", "c"})
  end)

  T.it("cancel_all prevents all pending from running", function()
    local ran = 0
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    for i = 1, 5 do
      q:push(function(done) ran = ran + 1; done(nil) end)
    end
    q:cancel_all()
    q:run_all()
    T.eq(ran, 0)
  end)

  T.it("clear removes all pending", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    local ran = 0
    for i = 1, 3 do
      q:push(function(done) ran = ran + 1; done(nil) end)
    end
    q:clear()
    local s = q:stats()
    T.eq(s.pending, 0)
    q:run_all()
    T.eq(ran, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- drain event
-- ---------------------------------------------------------------------------

T.describe("async_queue: drain event", function()
  T.it("drain event fires when queue empties", function()
    local drained = 0
    local q = Q.new({ concurrency = 2, clock_fn = os.clock })
    q:on("drain", function() drained = drained + 1 end)
    q:push(ok_task(1))
    q:push(ok_task(2))
    q:push(ok_task(3))
    q:run_all()
    T.ok(drained >= 1, "drain event should fire at least once")
  end)
end)

-- ---------------------------------------------------------------------------
-- tick return values
-- ---------------------------------------------------------------------------

T.describe("async_queue: tick return values", function()
  T.it("tick returns (active, pending) counts", function()
    local q = Q.new({ concurrency = 1, clock_fn = os.clock })
    q:push(ok_task(1))
    q:push(ok_task(2))
    q:push(ok_task(3))
    local a, p = q:tick()
    T.ok(type(a) == "number", "active count should be number")
    T.ok(type(p) == "number", "pending count should be number")
  end)
end)

-- ---------------------------------------------------------------------------
-- rate limiting
-- ---------------------------------------------------------------------------

T.describe("async_queue: rate limiting", function()
  T.it("rate limits tasks per second window", function()
    local q = Q.new({ concurrency = 10, rate = 2, clock_fn = os.clock })
    local ran = 0
    for i = 1, 6 do
      q:push(function(done) ran = ran + 1; done(nil) end)
    end
    -- One tick at t=0: rate allows 2
    local clock = 0
    q:tick(clock)
    T.ok(ran <= 2, "only 2 tasks should run in first window, ran=" .. ran)

    -- Advance time past 1 second: another 2 allowed
    clock = 1.1
    q:tick(clock)
    T.ok(ran <= 4, "only 4 tasks should run in first two windows, ran=" .. ran)

    -- Finish remaining
    clock = 2.2
    q:tick(clock)
    clock = 3.3
    q:tick(clock)
    T.eq(ran, 6)
  end)
end)

-- ---------------------------------------------------------------------------
-- Batcher
-- ---------------------------------------------------------------------------

T.describe("batcher: basic grouping by key", function()
  T.it("groups items by key and calls process per group", function()
    local batches = {}
    local b = Q.batcher({
      key = function(item) return item.group end,
      batch_size = 100,
      delay = 0,
      clock_fn = os.clock,
      process = function(batch, done)
        batches[#batches + 1] = batch
        done(nil)
      end,
    })
    b:push({ group = "a", val = 1 })
    b:push({ group = "b", val = 2 })
    b:push({ group = "a", val = 3 })
    b:push({ group = "b", val = 4 })
    b:flush_all()
    T.eq(#batches, 2)
    -- Each batch should have items from one group
    local a_batch, b_batch
    for _, batch in ipairs(batches) do
      if batch[1].group == "a" then a_batch = batch
      elseif batch[1].group == "b" then b_batch = batch
      end
    end
    T.ok(a_batch ~= nil, "should have batch for group a")
    T.ok(b_batch ~= nil, "should have batch for group b")
    T.eq(#a_batch, 2)
    T.eq(#b_batch, 2)
  end)

  T.it("auto-flushes when batch_size is reached", function()
    local flushed = 0
    local b = Q.batcher({
      key = function(item) return "x" end,
      batch_size = 3,
      clock_fn = os.clock,
      process = function(batch, done) flushed = flushed + 1; done(nil) end,
    })
    b:push({v=1})
    b:push({v=2})
    -- Third push triggers auto-flush
    b:push({v=3})
    T.eq(flushed, 1)
  end)

  T.it("flush respects delay", function()
    local flushed = 0
    local b = Q.batcher({
      delay = 1.0,
      clock_fn = os.clock,
      process = function(batch, done) flushed = flushed + 1; done(nil) end,
    })
    -- Push with explicit clock=0 so first_at is tracked from t=0
    b:push({v=1}, 0)
    -- Flush at t=0 — delay not yet elapsed (0 - 0 = 0 < 1.0)
    b:flush(0)
    T.eq(flushed, 0)
    -- Flush at t=1.0 — delay elapsed (1.0 - 0 >= 1.0)
    b:flush(1.0)
    T.eq(flushed, 1)
  end)

  T.it("no key groups all items together", function()
    local batches = {}
    local b = Q.batcher({
      batch_size = 100,
      delay = 0,
      clock_fn = os.clock,
      process = function(batch, done) batches[#batches + 1] = batch; done(nil) end,
    })
    b:push({v=1})
    b:push({v=2})
    b:push({v=3})
    b:flush_all()
    T.eq(#batches, 1)
    T.eq(#batches[1], 3)
  end)
end)
