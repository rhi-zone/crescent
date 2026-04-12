if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local TQ = require("lib.task_queue")

T.describe("task_queue", function()

  T.describe("basic push and process", function()
    T.it("processes a single task and returns result", function()
      local q = TQ.new()
      q:push({ fn = function() return "hello" end, priority = 1 })
      local results = q:process(1)
      T.eq(#results, 1)
      T.eq(results[1].status, "success")
      T.eq(results[1].result, "hello")
    end)

    T.it("returns the task id from push", function()
      local q = TQ.new()
      local id = q:push({ fn = function() return 1 end, id = "my-task" })
      T.eq(id, "my-task")
    end)

    T.it("auto-generates id when not provided", function()
      local q = TQ.new()
      local id = q:push({ fn = function() return 1 end })
      T.ok(id ~= nil)
    end)

    T.it("result record contains the task id", function()
      local q = TQ.new()
      q:push({ fn = function() return 42 end, id = "t1" })
      local results = q:process(1)
      T.eq(results[1].id, "t1")
    end)

    T.it("process(n) returns up to n results", function()
      local q = TQ.new()
      for i = 1, 5 do
        q:push({ fn = function() return i end, priority = i })
      end
      local results = q:process(3)
      T.eq(#results, 3)
    end)

    T.it("process with no args defaults to 1", function()
      local q = TQ.new()
      q:push({ fn = function() return 1 end })
      q:push({ fn = function() return 2 end })
      local results = q:process()
      T.eq(#results, 1)
    end)
  end)

  T.describe("priority ordering", function()
    T.it("processes tasks in priority order (lower = first)", function()
      local q = TQ.new()
      local order = {}
      q:push({ fn = function() order[#order+1] = "c"; return "c" end, priority = 3 })
      q:push({ fn = function() order[#order+1] = "a"; return "a" end, priority = 1 })
      q:push({ fn = function() order[#order+1] = "b"; return "b" end, priority = 2 })
      q:process(3)
      T.eq(order[1], "a")
      T.eq(order[2], "b")
      T.eq(order[3], "c")
    end)

    T.it("results are returned in processing order", function()
      local q = TQ.new()
      q:push({ fn = function() return "low" end, priority = 10 })
      q:push({ fn = function() return "high" end, priority = 1 })
      local results = q:process(2)
      T.eq(results[1].result, "high")
      T.eq(results[2].result, "low")
    end)

    T.it("same priority tasks are FIFO", function()
      local q = TQ.new()
      local order = {}
      q:push({ fn = function() order[#order+1] = 1; return 1 end, priority = 5 })
      q:push({ fn = function() order[#order+1] = 2; return 2 end, priority = 5 })
      q:push({ fn = function() order[#order+1] = 3; return 3 end, priority = 5 })
      q:process(3)
      T.eq(order[1], 1)
      T.eq(order[2], 2)
      T.eq(order[3], 3)
    end)
  end)

  T.describe("retry on (nil, err)", function()
    T.it("retries a task that returns (nil, err)", function()
      local q = TQ.new({ max_retries = 2 })
      local calls = 0
      q:push({
        fn = function()
          calls = calls + 1
          if calls < 3 then return nil, "not yet" end
          return "done"
        end,
        priority = 1,
      })
      local r1 = q:process(1)
      T.eq(r1[1].status, "retry")
      local r2 = q:process(1)
      T.eq(r2[1].status, "retry")
      local r3 = q:process(1)
      T.eq(r3[1].status, "success")
      T.eq(r3[1].result, "done")
      T.eq(calls, 3)
    end)

    T.it("status is failed after max_retries exhausted", function()
      local q = TQ.new({ max_retries = 2 })
      local calls = 0
      q:push({
        fn = function()
          calls = calls + 1
          return nil, "always fails"
        end,
        priority = 1,
      })
      -- max_retries=2 means: 1 initial attempt + 2 retries = 3 total calls before failed
      local r1 = q:process(1); T.eq(r1[1].status, "retry")
      local r2 = q:process(1); T.eq(r2[1].status, "retry")
      local r3 = q:process(1); T.eq(r3[1].status, "failed")
      T.eq(calls, 3)
      -- queue is now empty
      T.eq(q:size(), 0)
    end)

    T.it("failed result contains the error message", function()
      local q = TQ.new({ max_retries = 0 })
      q:push({ fn = function() return nil, "boom" end })
      local results = q:process(1)
      T.eq(results[1].status, "failed")
      T.eq(results[1].error, "boom")
    end)
  end)

  T.describe("retry on thrown error", function()
    T.it("pcall catches thrown errors and retries", function()
      local q = TQ.new({ max_retries = 1 })
      local calls = 0
      q:push({
        fn = function()
          calls = calls + 1
          if calls == 1 then error("oops") end
          return "recovered"
        end,
      })
      local r1 = q:process(1); T.eq(r1[1].status, "retry")
      local r2 = q:process(1); T.eq(r2[1].status, "success")
      T.eq(calls, 2)
    end)

    T.it("thrown error exhausts retries and becomes failed", function()
      local q = TQ.new({ max_retries = 0 })
      q:push({ fn = function() error("hard fail") end })
      local results = q:process(1)
      T.eq(results[1].status, "failed")
      T.ok(results[1].error ~= nil)
    end)
  end)

  T.describe("retry_delay", function()
    T.it("retried task not eligible until retry_delay ticks have passed", function()
      local q = TQ.new({ max_retries = 2, retry_delay = 2 })
      local calls = 0
      q:push({
        fn = function()
          calls = calls + 1
          if calls < 3 then return nil, "wait" end
          return "ok"
        end,
      })
      -- First attempt (tick=0)
      local r1 = q:process(1); T.eq(r1[1].status, "retry")
      -- Not eligible yet at tick=0
      local r2 = q:process(1); T.eq(#r2, 0)
      -- Advance 2 ticks
      q:tick(); q:tick()
      -- Now eligible (tick=2)
      local r3 = q:process(1); T.eq(r3[1].status, "retry")
      -- Not eligible yet
      local r4 = q:process(1); T.eq(#r4, 0)
      q:tick(); q:tick()
      -- Final attempt
      local r5 = q:process(1); T.eq(r5[1].status, "success")
      T.eq(calls, 3)
    end)
  end)

  T.describe("delay", function()
    T.it("task with delay not eligible until enough ticks", function()
      local q = TQ.new()
      q:push({ fn = function() return "delayed" end, delay = 3 })
      -- tick=0: not eligible
      T.eq(#q:process(1), 0)
      q:tick() -- tick=1
      T.eq(#q:process(1), 0)
      q:tick() -- tick=2
      T.eq(#q:process(1), 0)
      q:tick() -- tick=3
      local results = q:process(1)
      T.eq(#results, 1)
      T.eq(results[1].status, "success")
      T.eq(results[1].result, "delayed")
    end)

    T.it("task with delay=0 is immediately eligible", function()
      local q = TQ.new()
      q:push({ fn = function() return "now" end, delay = 0 })
      local results = q:process(1)
      T.eq(#results, 1)
      T.eq(results[1].status, "success")
    end)
  end)

  T.describe("cancel", function()
    T.it("cancel() removes a pending task", function()
      local q = TQ.new()
      local id = q:push({ fn = function() return 1 end, id = "to-cancel" })
      T.ok(q:cancel(id))
      T.eq(q:size(), 0)
      local results = q:process(1)
      T.eq(#results, 0)
    end)

    T.it("cancel() returns false for nonexistent id", function()
      local q = TQ.new()
      T.eq(q:cancel("no-such-id"), false)
    end)

    T.it("cancel() returns false for already-cancelled id", function()
      local q = TQ.new()
      local id = q:push({ fn = function() return 1 end })
      q:cancel(id)
      T.eq(q:cancel(id), false)
    end)

    T.it("other tasks unaffected after cancel", function()
      local q = TQ.new()
      local id1 = q:push({ fn = function() return "keep" end, priority = 1 })
      local id2 = q:push({ fn = function() return "gone" end, priority = 2, id = "del" })
      q:cancel(id2)
      local results = q:process(2)
      T.eq(#results, 1)
      T.eq(results[1].result, "keep")
    end)
  end)

  T.describe("clear", function()
    T.it("clear() removes all pending tasks", function()
      local q = TQ.new()
      for i = 1, 5 do q:push({ fn = function() return i end }) end
      q:clear()
      T.eq(q:size(), 0)
      T.eq(#q:process(5), 0)
    end)
  end)

  T.describe("size and active", function()
    T.it("size() returns number of pending tasks", function()
      local q = TQ.new()
      T.eq(q:size(), 0)
      q:push({ fn = function() return 1 end })
      q:push({ fn = function() return 2 end })
      T.eq(q:size(), 2)
      q:process(1)
      T.eq(q:size(), 1)
    end)

    T.it("active() returns 0 outside of process()", function()
      local q = TQ.new()
      q:push({ fn = function() return 1 end })
      T.eq(q:active(), 0)
      q:process(1)
      T.eq(q:active(), 0)
    end)
  end)

  T.describe("peek", function()
    T.it("peek() returns the highest-priority task without removing it", function()
      local q = TQ.new()
      q:push({ fn = function() return "b" end, priority = 2, id = "b" })
      q:push({ fn = function() return "a" end, priority = 1, id = "a" })
      local entry = q:peek()
      T.ok(entry ~= nil)
      T.eq(entry.id, "a")
      T.eq(q:size(), 2)  -- not removed
    end)

    T.it("peek() returns nil when queue is empty", function()
      local q = TQ.new()
      T.eq(q:peek(), nil)
    end)

    T.it("peek() ignores ineligible tasks", function()
      local q = TQ.new()
      q:push({ fn = function() return "future" end, priority = 1, id = "future", delay = 5 })
      q:push({ fn = function() return "now" end, priority = 2, id = "now", delay = 0 })
      local entry = q:peek()
      T.ok(entry ~= nil)
      T.eq(entry.id, "now")
    end)
  end)

  T.describe("stats", function()
    T.it("stats() counts successes", function()
      local q = TQ.new()
      q:push({ fn = function() return 1 end })
      q:push({ fn = function() return 2 end })
      q:process(2)
      local s = q:stats()
      T.eq(s.processed, 2)
      T.eq(s.succeeded, 2)
      T.eq(s.failed, 0)
      T.eq(s.retried, 0)
      T.eq(s.cancelled, 0)
    end)

    T.it("stats() counts failures", function()
      local q = TQ.new({ max_retries = 0 })
      q:push({ fn = function() return nil, "err" end })
      q:process(1)
      local s = q:stats()
      T.eq(s.processed, 1)
      T.eq(s.succeeded, 0)
      T.eq(s.failed, 1)
    end)

    T.it("stats() counts retries", function()
      local q = TQ.new({ max_retries = 2 })
      local n = 0
      q:push({
        fn = function()
          n = n + 1
          if n < 3 then return nil, "retry me" end
          return "ok"
        end
      })
      q:process(1) -- retry 1
      q:process(1) -- retry 2
      q:process(1) -- success
      local s = q:stats()
      T.eq(s.retried, 2)
      T.eq(s.succeeded, 1)
      T.eq(s.processed, 3)
    end)

    T.it("stats() counts cancellations", function()
      local q = TQ.new()
      local id = q:push({ fn = function() return 1 end })
      q:cancel(id)
      local s = q:stats()
      T.eq(s.cancelled, 1)
    end)
  end)

  T.describe("event callbacks", function()
    T.it("on('success') fires when task succeeds", function()
      local q = TQ.new()
      local fired = {}
      q:on("success", function(id, result)
        fired[#fired+1] = { id = id, result = result }
      end)
      q:push({ fn = function() return "win" end, id = "t1" })
      q:process(1)
      T.eq(#fired, 1)
      T.eq(fired[1].id, "t1")
      T.eq(fired[1].result, "win")
    end)

    T.it("on('failure') fires after all retries exhausted", function()
      local q = TQ.new({ max_retries = 1 })
      local fired = {}
      q:on("failure", function(id, err, attempts)
        fired[#fired+1] = { id = id, err = err, attempts = attempts }
      end)
      q:push({ fn = function() return nil, "boom" end, id = "t2" })
      q:process(1) -- retry
      q:process(1) -- failed
      T.eq(#fired, 1)
      T.eq(fired[1].id, "t2")
      T.eq(fired[1].err, "boom")
      T.eq(fired[1].attempts, 2)
    end)

    T.it("on('retry') fires on each retry", function()
      local q = TQ.new({ max_retries = 3 })
      local retries = {}
      q:on("retry", function(id, err, attempt)
        retries[#retries+1] = attempt
      end)
      local n = 0
      q:push({
        fn = function()
          n = n + 1
          if n < 4 then return nil, "not yet" end
          return "done"
        end,
        id = "t3",
      })
      q:process(1); q:process(1); q:process(1); q:process(1)
      T.eq(#retries, 3)
      T.eq(retries[1], 1)
      T.eq(retries[2], 2)
      T.eq(retries[3], 3)
    end)

    T.it("multiple listeners on same event all fire", function()
      local q = TQ.new()
      local count = 0
      q:on("success", function() count = count + 1 end)
      q:on("success", function() count = count + 1 end)
      q:push({ fn = function() return "x" end })
      q:process(1)
      T.eq(count, 2)
    end)
  end)

  T.describe("max_concurrent", function()
    T.it("process(n) respects n as max tasks per call", function()
      local q = TQ.new({ max_concurrent = 5 })
      for i = 1, 10 do
        q:push({ fn = function() return i end, priority = i })
      end
      local r = q:process(4)
      T.eq(#r, 4)
      T.eq(q:size(), 6)
    end)
  end)

  T.describe("edge cases", function()
    T.it("push returns nil, err for non-table task", function()
      local q = TQ.new()
      local id, err = q:push("not a table")
      T.eq(id, nil)
      T.ok(err ~= nil)
    end)

    T.it("push returns nil, err when fn is missing", function()
      local q = TQ.new()
      local id, err = q:push({ priority = 1 })
      T.eq(id, nil)
      T.ok(err ~= nil)
    end)

    T.it("process on empty queue returns empty array", function()
      local q = TQ.new()
      local results = q:process(5)
      T.eq(#results, 0)
    end)

    T.it("tick advances the internal clock for delay purposes", function()
      local q = TQ.new()
      q:push({ fn = function() return "tick" end, delay = 1 })
      T.eq(#q:process(1), 0)
      q:tick()
      T.eq(#q:process(1), 1)
    end)

    T.it("task fn returning nil (no error) is a success", function()
      local q = TQ.new()
      q:push({ fn = function() return nil end })
      -- fn returns (nil) — one return value. This is ambiguous with (nil, err).
      -- The spec says return (nil, err) is failure. Single nil return is success.
      -- In Lua, fn() returning nil gives val=nil, err_or_second=nil.
      local results = q:process(1)
      T.eq(results[1].status, "success")
    end)

    T.it("zero priority is valid and processes before priority=1", function()
      local q = TQ.new()
      q:push({ fn = function() return "one" end, priority = 1, id = "one" })
      q:push({ fn = function() return "zero" end, priority = 0, id = "zero" })
      local results = q:process(2)
      T.eq(results[1].id, "zero")
      T.eq(results[2].id, "one")
    end)

    T.it("negative priority processes before zero", function()
      local q = TQ.new()
      q:push({ fn = function() return "neg" end, priority = -1, id = "neg" })
      q:push({ fn = function() return "zero" end, priority = 0, id = "zero" })
      local results = q:process(2)
      T.eq(results[1].id, "neg")
    end)
  end)

end)
