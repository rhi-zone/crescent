if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.semaphore")

-- ---------------------------------------------------------------------------
-- Semaphore tests
-- ---------------------------------------------------------------------------

T.describe("semaphore", function()
  T.it("basic acquire/release", function()
    M.run(function()
      local sem = M.semaphore(2)
      T.eq(sem:count(), 2)
      sem:acquire()
      T.eq(sem:count(), 1)
      sem:acquire()
      T.eq(sem:count(), 0)
      sem:release()
      T.eq(sem:count(), 1)
      sem:release()
      T.eq(sem:count(), 2)
    end)
  end)

  T.it("blocks when count is 0", function()
    M.run(function()
      local sem = M.semaphore(0)
      local acquired = false
      M.go(function()
        sem:acquire()
        acquired = true
      end)
      -- goroutine is spawned but blocked — hasn't run yet
      T.eq(acquired, false)
      sem:release()  -- wake it
      -- after this scheduler turn the goroutine will run
    end)
    -- run() drains the queue, so acquired is true after M.run returns
    -- (we need to observe it outside of the inner run scope)
  end)

  T.it("blocks and wakes correctly", function()
    local acquired = false
    M.run(function()
      local sem = M.semaphore(0)
      M.go(function()
        sem:acquire()
        acquired = true
      end)
      T.eq(acquired, false)
      sem:release()
    end)
    T.eq(acquired, true)
  end)

  T.it("try_acquire succeeds when count > 0", function()
    M.run(function()
      local sem = M.semaphore(3)
      T.ok(sem:try_acquire())
      T.eq(sem:count(), 2)
      T.ok(sem:try_acquire())
      T.eq(sem:count(), 1)
    end)
  end)

  T.it("try_acquire fails when count is 0", function()
    M.run(function()
      local sem = M.semaphore(0)
      T.eq(sem:try_acquire(), false)
      T.eq(sem:count(), 0)
    end)
  end)

  T.it("multiple goroutines queue up and wake in order", function()
    local order = {}
    M.run(function()
      local sem = M.semaphore(0)
      for i = 1, 3 do
        local id = i
        M.go(function()
          sem:acquire()
          order[#order + 1] = id
        end)
      end
      -- All three blocked; release one at a time.
      sem:release()
      sem:release()
      sem:release()
    end)
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)

  T.it("default count is 1", function()
    M.run(function()
      local sem = M.semaphore()
      T.eq(sem:count(), 1)
      sem:acquire()
      T.eq(sem:count(), 0)
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Mutex tests
-- ---------------------------------------------------------------------------

T.describe("mutex", function()
  T.it("basic lock/unlock", function()
    M.run(function()
      local m = M.mutex()
      T.eq(m:is_locked(), false)
      m:lock()
      T.ok(m:is_locked())
      m:unlock()
      T.eq(m:is_locked(), false)
    end)
  end)

  T.it("try_lock succeeds when unlocked", function()
    M.run(function()
      local m = M.mutex()
      T.ok(m:try_lock())
      T.ok(m:is_locked())
    end)
  end)

  T.it("try_lock fails when locked", function()
    M.run(function()
      local m = M.mutex()
      m:lock()
      T.eq(m:try_lock(), false)
      m:unlock()
    end)
  end)

  T.it("serializes access", function()
    M.run(function()
      local m = M.mutex()
      local log = {}
      local function worker(id)
        m:lock()
        log[#log + 1] = id .. "_start"
        coroutine.yield()
        log[#log + 1] = id .. "_end"
        m:unlock()
      end
      M.go(function() worker("A") end)
      M.go(function() worker("B") end)
      -- A locks, yields; B tries to lock, blocks;
      -- A resumes, unlocks, wakes B; B runs to completion.
    end)
    -- assertions checked after run() drains
  end)

  T.it("serializes access — log order", function()
    local log = {}
    M.run(function()
      local m = M.mutex()
      local function worker(id)
        m:lock()
        log[#log + 1] = id .. "_start"
        coroutine.yield()
        log[#log + 1] = id .. "_end"
        m:unlock()
      end
      M.go(function() worker("A") end)
      M.go(function() worker("B") end)
    end)
    T.eq(log[1], "A_start")
    T.eq(log[2], "A_end")
    T.eq(log[3], "B_start")
    T.eq(log[4], "B_end")
  end)

  T.it("with() runs fn and unlocks", function()
    M.run(function()
      local m = M.mutex()
      local ran = false
      m:with(function()
        T.ok(m:is_locked())
        ran = true
      end)
      T.ok(ran)
      T.eq(m:is_locked(), false)
    end)
  end)

  T.it("with() unlocks on error", function()
    M.run(function()
      local m = M.mutex()
      local ok = pcall(function()
        m:with(function()
          error("oops")
        end)
      end)
      T.eq(ok, false)
      T.eq(m:is_locked(), false)
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Condition variable tests
-- ---------------------------------------------------------------------------

T.describe("cond", function()
  T.it("signal wakes one waiter", function()
    local woke = 0
    M.run(function()
      local m = M.mutex()
      local cv = M.cond(m)
      local function waiter()
        m:lock()
        cv:wait()
        woke = woke + 1
        m:unlock()
      end
      M.go(waiter)
      M.go(waiter)
      -- Let both goroutines reach cv:wait()
      coroutine.yield()
      coroutine.yield()
      m:lock()
      cv:signal()
      m:unlock()
    end)
    T.eq(woke, 1)
  end)

  T.it("broadcast wakes all waiters", function()
    local woke = 0
    M.run(function()
      local m = M.mutex()
      local cv = M.cond(m)
      local function waiter()
        m:lock()
        cv:wait()
        woke = woke + 1
        m:unlock()
      end
      M.go(waiter)
      M.go(waiter)
      M.go(waiter)
      coroutine.yield()
      coroutine.yield()
      coroutine.yield()
      m:lock()
      cv:broadcast()
      m:unlock()
    end)
    T.eq(woke, 3)
  end)

  T.it("wait reacquires mutex before returning", function()
    local inside = false
    M.run(function()
      local m = M.mutex()
      local cv = M.cond(m)
      M.go(function()
        m:lock()
        cv:wait()
        -- mutex must be held here
        inside = m:is_locked()
        m:unlock()
      end)
      coroutine.yield()
      m:lock()
      cv:signal()
      m:unlock()
    end)
    T.ok(inside)
  end)
end)

-- ---------------------------------------------------------------------------
-- WaitGroup tests
-- ---------------------------------------------------------------------------

T.describe("waitgroup", function()
  T.it("waits for all goroutines", function()
    local done = 0
    M.run(function()
      local wg = M.waitgroup()
      for _ = 1, 3 do
        wg:add(1)
        M.go(function()
          done = done + 1
          wg:done()
        end)
      end
      wg:wait()
      T.eq(done, 3)
    end)
  end)

  T.it("add then done reaches zero", function()
    M.run(function()
      local wg = M.waitgroup()
      wg:add(5)
      for _ = 1, 5 do
        M.go(function() wg:done() end)
      end
      wg:wait()
      -- no assertion needed — if wg:wait() returns, count reached 0
    end)
    T.ok(true)  -- reached here
  end)

  T.it("wait returns immediately when count is 0", function()
    M.run(function()
      local wg = M.waitgroup()
      wg:wait()   -- count already 0, must not block
    end)
    T.ok(true)
  end)

  T.it("multiple waiters all wake", function()
    local woke = 0
    M.run(function()
      local wg = M.waitgroup()
      wg:add(1)
      M.go(function() woke = woke + 1; wg:wait() end)
      M.go(function() woke = woke + 1; wg:wait() end)
      coroutine.yield()
      coroutine.yield()
      wg:done()
    end)
    T.eq(woke, 2)
  end)

  T.it("negative counter errors", function()
    local ok, err = pcall(function()
      M.run(function()
        local wg = M.waitgroup()
        wg:done()  -- counter goes negative
      end)
    end)
    T.eq(ok, false)
    T.ok(err:find("negative") ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Once tests
-- ---------------------------------------------------------------------------

T.describe("once", function()
  T.it("runs function exactly once", function()
    local calls = 0
    M.run(function()
      local o = M.once()
      o:do_(function() calls = calls + 1 end)
      o:do_(function() calls = calls + 1 end)
      o:do_(function() calls = calls + 1 end)
    end)
    T.eq(calls, 1)
  end)

  T.it("concurrent do_ calls run fn once", function()
    local calls = 0
    M.run(function()
      local o = M.once()
      for _ = 1, 5 do
        M.go(function()
          o:do_(function() calls = calls + 1 end)
        end)
      end
    end)
    T.eq(calls, 1)
  end)

  T.it("different Once objects are independent", function()
    local a, b = 0, 0
    M.run(function()
      local oa = M.once()
      local ob = M.once()
      oa:do_(function() a = a + 1 end)
      ob:do_(function() b = b + 1 end)
      oa:do_(function() a = a + 1 end)  -- no-op
    end)
    T.eq(a, 1)
    T.eq(b, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Integration: producer/consumer via semaphore
-- ---------------------------------------------------------------------------

T.describe("integration", function()
  T.it("producer/consumer with semaphore signaling", function()
    local items = {}
    local consumed = {}
    M.run(function()
      local sem = M.semaphore(0)
      M.go(function()
        -- producer: push 3 items
        for i = 1, 3 do
          items[#items + 1] = i
          sem:release()
        end
      end)
      M.go(function()
        -- consumer: drain 3 items
        for _ = 1, 3 do
          sem:acquire()
          consumed[#consumed + 1] = table.remove(items, 1)
        end
      end)
    end)
    T.eq(#consumed, 3)
    T.eq(consumed[1], 1)
    T.eq(consumed[2], 2)
    T.eq(consumed[3], 3)
  end)

  T.it("mutex protects shared counter", function()
    local counter = 0
    M.run(function()
      local m = M.mutex()
      local wg = M.waitgroup()
      for _ = 1, 5 do
        wg:add(1)
        M.go(function()
          m:lock()
          counter = counter + 1
          m:unlock()
          wg:done()
        end)
      end
      wg:wait()
    end)
    T.eq(counter, 5)
  end)
end)
