-- lib/scheduler/scheduler_test.lua
-- Tests for the cooperative coroutine scheduler.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.scheduler")

-- Helper: make an injected-clock scheduler
local function make_sched(t_ref)
  -- t_ref is a table with field .t so we can mutate it
  return S.new({ clock = function() return t_ref.t end })
end

-- ---------------------------------------------------------------------------
T.describe("scheduler", function()

  -- Basic: spawn runs to completion
  T.it("single task runs to completion", function()
    local sched = S.new()
    local ran = false
    local task = sched:spawn(function(ctx)
      ran = true
    end)
    T.eq(task.status, "pending", "initially pending")
    sched:run()
    T.ok(ran, "task body executed")
    T.eq(task.status, "done", "status is done")
  end)

  -- Multiple tasks: all run
  T.it("multiple tasks all run", function()
    local sched = S.new()
    local count = 0
    for i = 1, 5 do
      sched:spawn(function(ctx) count = count + 1 end)
    end
    sched:run()
    T.eq(count, 5, "all 5 tasks executed")
    T.ok(sched:done(), "scheduler is done")
  end)

  -- yield(): tasks interleave ABAB
  T.it("yield interleaves tasks", function()
    local sched = S.new()
    local order = {}
    sched:spawn(function(ctx)
      order[#order + 1] = "A1"
      ctx.yield()
      order[#order + 1] = "A2"
    end, { name = "A" })
    sched:spawn(function(ctx)
      order[#order + 1] = "B1"
      ctx.yield()
      order[#order + 1] = "B2"
    end, { name = "B" })
    sched:run()
    -- After step 1: A1, B1 (both yield). After step 2: A2, B2.
    T.eq(order[1], "A1")
    T.eq(order[2], "B1")
    T.eq(order[3], "A2")
    T.eq(order[4], "B2")
    T.eq(#order, 4)
  end)

  -- Priority: higher priority tasks run first
  T.it("higher priority runs first", function()
    local sched = S.new()
    local order = {}
    sched:spawn(function(ctx) order[#order + 1] = "low"  end, { priority = 1 })
    sched:spawn(function(ctx) order[#order + 1] = "high" end, { priority = 10 })
    sched:spawn(function(ctx) order[#order + 1] = "mid"  end, { priority = 5 })
    sched:run()
    T.eq(order[1], "high", "highest priority first")
    T.eq(order[2], "mid",  "mid priority second")
    T.eq(order[3], "low",  "low priority last")
  end)

  -- sleep(): task wakes after correct delay (injected clock)
  T.it("sleep wakes after delay", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local woke = false
    sched:spawn(function(ctx)
      ctx.sleep(0.5)
      woke = true
    end)
    sched:step()       -- task sees sleep, queued on timer heap; clk.t = 0
    T.ok(not woke, "not woken yet at t=0")
    clk.t = 0.3
    sched:step()       -- still before 0.5
    T.ok(not woke, "not woken yet at t=0.3")
    clk.t = 0.5
    sched:step()       -- wake_time = 0.5, now = 0.5 → moves to ready
    sched:step()       -- actually runs the resumed task
    T.ok(woke, "woken at t=0.5")
  end)

  -- Channel send/await: producer unblocks consumer
  T.it("channel: send unblocks await", function()
    local sched = S.new()
    local ch = S.channel()
    local received = nil
    sched:spawn(function(ctx)
      received = ctx.await(ch)
    end, { name = "consumer" })
    sched:spawn(function(ctx)
      ctx.send(ch, 42)
    end, { name = "producer" })
    sched:run()
    T.eq(received, 42, "consumer received value from channel")
  end)

  -- Multiple waiters on channel: all woken
  T.it("channel: multiple waiters all woken", function()
    local sched = S.new()
    local ch = S.channel()
    local results = {}
    for i = 1, 3 do
      local idx = i
      sched:spawn(function(ctx)
        local v = ctx.await(ch)
        results[idx] = v
      end)
    end
    sched:spawn(function(ctx)
      ctx.send(ch, "hello")
    end)
    sched:run()
    T.eq(results[1], "hello")
    T.eq(results[2], "hello")
    T.eq(results[3], "hello")
  end)

  -- Channel peek / has_value
  T.it("channel peek and has_value", function()
    local ch = S.channel()
    T.ok(not ch:has_value(), "initially no value")
    T.eq(ch:peek(), nil, "peek returns nil initially")
    -- Manually set for inspection (outside scheduler context)
    ch._value = 99
    ch._has   = true
    T.ok(ch:has_value(), "has value after set")
    T.eq(ch:peek(), 99, "peek returns value")
  end)

  -- after(): runs once at correct time
  T.it("after() fires once at correct time", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local fired = 0
    sched:after(1.0, function(ctx) fired = fired + 1 end)
    -- Run several steps before time elapses
    for _ = 1, 5 do sched:step() end
    T.eq(fired, 0, "not fired before delay")
    clk.t = 1.0
    sched:run()
    T.eq(fired, 1, "fired exactly once after delay")
  end)

  -- every(): runs N times, return false cancels
  T.it("every() runs repeatedly and stops on false", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local count = 0
    sched:every(1.0, function(ctx)
      count = count + 1
      if count >= 3 then return false end
    end)
    -- Advance time and run
    for i = 1, 4 do
      clk.t = i * 1.0
      sched:run_for(10)
    end
    T.eq(count, 3, "ran exactly 3 times before false")
  end)

  -- task.status transitions: pending → running → done
  T.it("status transitions: pending -> done", function()
    local sched = S.new()
    local captured_status = nil
    local task = sched:spawn(function(ctx)
      -- Can't easily read status from inside (it's set to running before resume)
    end)
    T.eq(task.status, "pending", "pending before step")
    sched:step()
    T.eq(task.status, "done", "done after step")
  end)

  -- sleeping status
  T.it("status is sleeping while sleeping", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local task = sched:spawn(function(ctx)
      ctx.sleep(10)
    end)
    sched:step()   -- task starts, yields with sleep signal
    T.eq(task.status, "sleeping", "sleeping after sleep()")
    clk.t = 10
    sched:step()   -- moves to ready
    sched:step()   -- resumes and finishes
    T.eq(task.status, "done", "done after wake")
  end)

  -- waiting status
  T.it("status is waiting while awaiting channel", function()
    local sched = S.new()
    local ch = S.channel()
    local task = sched:spawn(function(ctx)
      ctx.await(ch)
    end)
    sched:step()   -- task yields into waiting
    T.eq(task.status, "waiting", "waiting while awaiting channel")
  end)

  -- Error in task: status=failed, error captured
  T.it("error in task: status=failed, error captured", function()
    local sched = S.new()
    local task = sched:spawn(function(ctx)
      error("boom")
    end)
    sched:run()
    T.eq(task.status, "failed", "status is failed")
    T.ok(task.error ~= nil, "error is captured")
    T.ok(task.error:find("boom"), "error message contains 'boom'")
  end)

  -- on_task_done hook
  T.it("on_task_done hook is called", function()
    local sched = S.new()
    local hooked = nil
    sched:on_task_done(function(task) hooked = task end)
    local task = sched:spawn(function(ctx) end)
    sched:run()
    T.ok(hooked ~= nil, "hook was called")
    T.ok(hooked == task, "hook received the correct task")
  end)

  -- on_task_failed hook
  T.it("on_task_failed hook is called", function()
    local sched = S.new()
    local hooked_task = nil
    local hooked_err  = nil
    sched:on_task_failed(function(task, err)
      hooked_task = task
      hooked_err  = err
    end)
    local task = sched:spawn(function(ctx)
      error("oops")
    end)
    sched:run()
    T.ok(hooked_task ~= nil, "failed hook was called")
    T.ok(hooked_err:find("oops"), "error passed to hook")
  end)

  -- cancel(): cancelled task doesn't run
  T.it("cancel prevents task from running", function()
    local sched = S.new()
    local ran = false
    local task = sched:spawn(function(ctx)
      ran = true
    end)
    sched:cancel(task)
    sched:run()
    T.ok(not ran, "cancelled task did not run")
    T.ok(sched:done(), "scheduler considers itself done")
  end)

  -- cancel sleeping task
  T.it("cancel stops a sleeping task", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local ran_after = false
    local task = sched:spawn(function(ctx)
      ctx.sleep(5)
      ran_after = true
    end)
    sched:step()  -- task sleeps
    T.eq(task.status, "sleeping")
    sched:cancel(task)
    clk.t = 10
    sched:run()
    T.ok(not ran_after, "body after sleep did not run")
  end)

  -- stats(): correct counts
  T.it("stats() returns correct counts", function()
    local sched = S.new()
    sched:spawn(function(ctx) end)
    sched:spawn(function(ctx) end)
    sched:spawn(function(ctx) error("fail") end)
    sched:run()
    local st = sched:stats()
    T.eq(st.total,   3, "total = 3")
    T.eq(st.done,    2, "done = 2")
    T.eq(st.failed,  1, "failed = 1")
    T.eq(st.pending, 0, "pending = 0")
    T.ok(st.steps >= 1, "steps >= 1")
  end)

  -- done(): true when all tasks complete
  T.it("done() is true when all tasks complete", function()
    local sched = S.new()
    sched:spawn(function(ctx) end)
    sched:spawn(function(ctx) end)
    T.ok(not sched:done(), "not done before run")
    sched:run()
    T.ok(sched:done(), "done after all tasks finish")
  end)

  -- task_count()
  T.it("task_count() reflects active tasks", function()
    local sched = S.new()
    sched:spawn(function(ctx) end)
    sched:spawn(function(ctx) end)
    T.eq(sched:task_count(), 2, "2 active tasks before run")
    sched:run()
    T.eq(sched:task_count(), 0, "0 active tasks after run")
  end)

  -- run_for()
  T.it("run_for() runs at most N steps", function()
    local sched = S.new()
    local count = 0
    sched:spawn(function(ctx)
      while true do
        count = count + 1
        ctx.yield()
      end
    end)
    sched:run_for(5)
    -- Each step runs the task once; it yields, so 5 steps → 5 increments
    T.eq(count, 5, "ran exactly 5 times")
    T.ok(not sched:done(), "scheduler not done (infinite task)")
  end)

  -- Priority with yield: higher priority task always runs before lower in same step
  T.it("priority preserved across yields", function()
    local sched = S.new()
    local order = {}
    -- Both tasks yield once; each step should run high before low
    sched:spawn(function(ctx)
      order[#order + 1] = "H1"
      ctx.yield()
      order[#order + 1] = "H2"
    end, { priority = 10 })
    sched:spawn(function(ctx)
      order[#order + 1] = "L1"
      ctx.yield()
      order[#order + 1] = "L2"
    end, { priority = 1 })
    sched:run()
    T.eq(order[1], "H1")
    T.eq(order[2], "L1")
    T.eq(order[3], "H2")
    T.eq(order[4], "L2")
  end)

  -- Channel: await returns immediately if channel already has a value
  T.it("channel: await returns immediately if already set", function()
    local sched = S.new()
    local ch = S.channel()
    ch._value = "preloaded"
    ch._has   = true
    local received = nil
    sched:spawn(function(ctx)
      received = ctx.await(ch)
    end)
    sched:run()
    T.eq(received, "preloaded", "await returned pre-existing value")
  end)

  -- Multiple sleeps in sequence
  T.it("multiple sequential sleeps in one task", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local log = {}
    sched:spawn(function(ctx)
      log[#log + 1] = "start"
      ctx.sleep(1)
      log[#log + 1] = "after 1"
      ctx.sleep(1)
      log[#log + 1] = "after 2"
    end)
    -- t=0: task runs, hits first sleep
    sched:step()
    T.eq(#log, 1)
    clk.t = 1
    sched:step()  -- wakes and runs to second sleep
    sched:step()  -- resumes: logs "after 1", hits second sleep
    T.eq(log[2], "after 1")
    clk.t = 2
    sched:step()  -- wakes
    sched:step()  -- resumes: logs "after 2", finishes
    T.eq(log[3], "after 2")
  end)

  -- Spawning a task from within a task
  T.it("task can spawn sub-tasks", function()
    local sched = S.new()
    local results = {}
    sched:spawn(function(ctx)
      sched:spawn(function(ctx2)
        results[#results + 1] = "child"
      end)
      results[#results + 1] = "parent"
    end)
    sched:run()
    T.ok(#results == 2, "both parent and child ran")
    -- parent ran first (already in ready queue), child added during step
    T.eq(results[1], "parent")
    T.eq(results[2], "child")
  end)

  -- stats().steps increments
  T.it("stats().steps increments each step", function()
    local sched = S.new()
    T.eq(sched:stats().steps, 0)
    sched:step()
    T.eq(sched:stats().steps, 1)
    sched:step()
    T.eq(sched:stats().steps, 2)
  end)

  -- on_task_done and on_task_failed not called for cancelled tasks
  T.it("hooks not called for cancelled tasks", function()
    local sched = S.new()
    local done_count   = 0
    local failed_count = 0
    sched:on_task_done(function() done_count = done_count + 1 end)
    sched:on_task_failed(function() failed_count = failed_count + 1 end)
    local t1 = sched:spawn(function(ctx) end)
    sched:cancel(t1)
    sched:run()
    T.eq(done_count,   0, "done hook not called for cancelled task")
    T.eq(failed_count, 0, "failed hook not called for cancelled task")
  end)

  -- S._tier
  T.it("_tier is pure", function()
    T.eq(S._tier, "pure")
  end)

  -- task.name is set
  T.it("task.name is set from opts", function()
    local sched = S.new()
    local t1 = sched:spawn(function() end, { name = "myjob" })
    T.eq(t1.name, "myjob")
  end)

  -- default name is assigned
  T.it("task.name has a default", function()
    local sched = S.new()
    local t1 = sched:spawn(function() end)
    T.ok(type(t1.name) == "string", "name is a string")
    T.ok(#t1.name > 0, "name is non-empty")
  end)

  -- task.priority is set from opts
  T.it("task.priority reflects opts", function()
    local sched = S.new()
    local t1 = sched:spawn(function() end, { priority = 7 })
    T.eq(t1.priority, 7)
  end)

  -- Three tasks with same priority run in spawn order (FIFO)
  T.it("same-priority tasks run in spawn order", function()
    local sched = S.new()
    local order = {}
    sched:spawn(function() order[#order+1] = 1 end)
    sched:spawn(function() order[#order+1] = 2 end)
    sched:spawn(function() order[#order+1] = 3 end)
    sched:run()
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)

  -- Channel: send wakes a single waiting task
  T.it("channel send gives correct value to waiter", function()
    local sched = S.new()
    local ch = S.channel()
    local got = nil
    sched:spawn(function(ctx) got = ctx.await(ch) end)
    sched:spawn(function(ctx) ctx.send(ch, "data") end)
    sched:run()
    T.eq(got, "data")
    T.ok(ch:has_value(), "channel still holds value after send")
    T.eq(ch:peek(), "data", "peek returns sent value")
  end)

  -- after() task is done after run
  T.it("after() task finishes done after running", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    local task = sched:after(0.1, function(ctx) end)
    T.eq(task.status, "pending")
    sched:step()   -- task starts, calls sleep(0.1), wake_time = 0 + 0.1 = 0.1
    T.eq(task.status, "sleeping")
    clk.t = 0.1
    sched:run()    -- wakes up, runs fn, done
    T.eq(task.status, "done")
  end)

  -- run() terminates even with no tasks
  T.it("run() with no tasks completes immediately", function()
    local sched = S.new()
    T.ok(sched:done(), "no tasks → already done")
    sched:run()
    local st = sched:stats()
    T.eq(st.total, 0)
    T.eq(st.done, 0)
  end)

  -- task_count decrements as tasks finish
  T.it("task_count decrements as tasks finish", function()
    local clk = { t = 0 }
    local sched = make_sched(clk)
    sched:spawn(function(ctx) end)
    sched:spawn(function(ctx) ctx.sleep(5) end)
    T.eq(sched:task_count(), 2)
    sched:step()   -- fast task finishes, slow task sleeps
    T.eq(sched:task_count(), 1, "one still sleeping")
    clk.t = 5
    sched:run()
    T.eq(sched:task_count(), 0, "all done")
  end)

end)
