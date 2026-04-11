if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.semaphore")

-- ---------------------------------------------------------------------------
-- Helper: run a function as the root of a coroutine-driven test.
-- Within fn, you may spawn additional coroutines with coroutine.create/resume.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Semaphore tests
-- ---------------------------------------------------------------------------

T.describe("semaphore", function()
  T.it("default count is 1", function()
    local sem = M.new()
    T.eq(sem:count(), 1)
    T.eq(sem:waiting(), 0)
  end)

  T.it("explicit initial count", function()
    local sem = M.new(5)
    T.eq(sem:count(), 5)
  end)

  T.it("acquire decrements count", function()
    local sem = M.new(3)
    sem:acquire()
    T.eq(sem:count(), 2)
    sem:acquire()
    T.eq(sem:count(), 1)
    sem:acquire()
    T.eq(sem:count(), 0)
  end)

  T.it("release increments count when no waiters", function()
    local sem = M.new(0)
    sem:release()
    T.eq(sem:count(), 1)
    sem:release()
    T.eq(sem:count(), 2)
  end)

  T.it("try_acquire succeeds when count > 0", function()
    local sem = M.new(2)
    T.ok(sem:try_acquire())
    T.eq(sem:count(), 1)
    T.ok(sem:try_acquire())
    T.eq(sem:count(), 0)
  end)

  T.it("try_acquire fails when count is 0", function()
    local sem = M.new(0)
    T.eq(sem:try_acquire(), false)
    T.eq(sem:count(), 0)
  end)

  T.it("blocking acquire via coroutine", function()
    local sem = M.new(1)
    local log = {}
    sem:acquire()  -- main holds it
    T.eq(sem:count(), 0)
    local co = coroutine.create(function()
      log[#log + 1] = "before"
      sem:acquire()  -- will block
      log[#log + 1] = "after"
    end)
    coroutine.resume(co)
    -- co is now waiting
    T.eq(log[1], "before")
    T.eq(#log, 1)
    T.eq(sem:waiting(), 1)
    -- release: resumes co directly
    sem:release()
    T.eq(log[2], "after")
    T.eq(sem:waiting(), 0)
    T.eq(sem:count(), 0)  -- slot was transferred to co, not incremented
  end)

  T.it("waiting() counts suspended coroutines", function()
    local sem = M.new(0)
    local co1 = coroutine.create(function() sem:acquire() end)
    local co2 = coroutine.create(function() sem:acquire() end)
    coroutine.resume(co1)
    T.eq(sem:waiting(), 1)
    coroutine.resume(co2)
    T.eq(sem:waiting(), 2)
    sem:release()
    T.eq(sem:waiting(), 1)
    sem:release()
    T.eq(sem:waiting(), 0)
  end)

  T.it("release wakes waiters in FIFO order", function()
    local order = {}
    local sem = M.new(0)
    for i = 1, 3 do
      local id = i
      local co = coroutine.create(function()
        sem:acquire()
        order[#order + 1] = id
      end)
      coroutine.resume(co)
    end
    sem:release()
    sem:release()
    sem:release()
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)

  T.it("with() acquires, runs fn, releases", function()
    local sem = M.new(1)
    local ran = false
    sem:with(function()
      T.eq(sem:count(), 0)
      ran = true
    end)
    T.ok(ran)
    T.eq(sem:count(), 1)
  end)

  T.it("with() releases on error", function()
    local sem = M.new(1)
    local ok = pcall(function()
      sem:with(function()
        error("oops")
      end)
    end)
    T.eq(ok, false)
    T.eq(sem:count(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Mutex tests (sugar: M.mutex() == M.new(1))
-- ---------------------------------------------------------------------------

T.describe("mutex", function()
  T.it("mutex() returns a semaphore with count 1", function()
    local m = M.mutex()
    T.eq(m:count(), 1)
  end)

  T.it("acquire/release as lock/unlock", function()
    local m = M.mutex()
    m:acquire()
    T.eq(m:count(), 0)
    m:release()
    T.eq(m:count(), 1)
  end)

  T.it("try_acquire on unlocked mutex", function()
    local m = M.mutex()
    T.ok(m:try_acquire())
    T.eq(m:count(), 0)
  end)

  T.it("try_acquire on locked mutex", function()
    local m = M.mutex()
    m:acquire()
    T.eq(m:try_acquire(), false)
    m:release()
  end)

  T.it("with() works on mutex", function()
    local m = M.mutex()
    local ran = false
    m:with(function()
      T.eq(m:count(), 0)
      ran = true
    end)
    T.ok(ran)
    T.eq(m:count(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Event tests
-- ---------------------------------------------------------------------------

T.describe("event", function()
  T.it("starts unfired", function()
    local ev = M.event()
    T.eq(ev:is_fired(), false)
  end)

  T.it("fire() sets fired state", function()
    local ev = M.event()
    ev:fire()
    T.ok(ev:is_fired())
  end)

  T.it("wait() returns immediately if already fired", function()
    local ev = M.event()
    ev:fire()
    -- This must not block (no coroutine needed)
    ev:wait()
    T.ok(true)
  end)

  T.it("reset() clears fired state", function()
    local ev = M.event()
    ev:fire()
    ev:reset()
    T.eq(ev:is_fired(), false)
  end)

  T.it("blocking wait() — woken by fire()", function()
    local ev = M.event()
    local log = {}
    local co = coroutine.create(function()
      log[#log + 1] = "before"
      ev:wait()
      log[#log + 1] = "after"
    end)
    coroutine.resume(co)
    T.eq(log[1], "before")
    T.eq(#log, 1)
    ev:fire()
    T.eq(log[2], "after")
  end)

  T.it("multiple waiters all wake on fire()", function()
    local ev = M.event()
    local woke = 0
    for _ = 1, 4 do
      local co = coroutine.create(function()
        ev:wait()
        woke = woke + 1
      end)
      coroutine.resume(co)
    end
    T.eq(woke, 0)
    ev:fire()
    T.eq(woke, 4)
  end)

  T.it("fire() is idempotent", function()
    local ev = M.event()
    local woke = 0
    local co = coroutine.create(function()
      ev:wait()
      woke = woke + 1
    end)
    coroutine.resume(co)
    ev:fire()
    ev:fire()  -- second fire must not error or double-wake
    T.eq(woke, 1)
    T.ok(ev:is_fired())
  end)

  T.it("reset() then wait() blocks again", function()
    local ev = M.event()
    ev:fire()
    ev:reset()
    local blocked = false
    local co = coroutine.create(function()
      blocked = true
      ev:wait()
      blocked = false
    end)
    coroutine.resume(co)
    -- co entered wait and suspended
    T.ok(blocked)
    T.eq(coroutine.status(co), "suspended")
    ev:fire()
    T.eq(coroutine.status(co), "dead")
  end)
end)

-- ---------------------------------------------------------------------------
-- Condition variable tests
-- ---------------------------------------------------------------------------

T.describe("cond", function()
  T.it("signal wakes one waiter", function()
    local cv = M.cond()
    local m = M.mutex()
    local woke = 0

    -- Set up two waiters
    local function make_waiter()
      return coroutine.create(function()
        m:acquire()
        cv:wait(m)
        woke = woke + 1
        m:release()
      end)
    end
    local co1 = make_waiter()
    local co2 = make_waiter()

    -- Start both — they will block in cv:wait after releasing m
    m:release()  -- prime: count to 1 so first acquire succeeds
    coroutine.resume(co1)  -- co1 acquires m, enters cv:wait, releases m
    coroutine.resume(co2)  -- co2 acquires m (released by co1), enters cv:wait, releases m

    T.eq(woke, 0)
    -- Signal one
    m:acquire()
    cv:signal()
    m:release()
    T.eq(woke, 1)

    -- The other is still waiting
    m:acquire()
    cv:signal()
    m:release()
    T.eq(woke, 2)
  end)

  T.it("broadcast wakes all waiters", function()
    local cv = M.cond()
    local m = M.mutex()
    local woke = 0
    local n = 3

    m:release()  -- prime
    for _ = 1, n do
      local co = coroutine.create(function()
        m:acquire()
        cv:wait(m)
        woke = woke + 1
        m:release()
      end)
      coroutine.resume(co)
    end

    T.eq(woke, 0)
    m:acquire()
    cv:broadcast()
    m:release()
    T.eq(woke, n)
  end)

  T.it("wait re-acquires mutex before returning", function()
    local cv = M.cond()
    local m = M.mutex()
    local mutex_held = false

    m:release()  -- prime
    local co = coroutine.create(function()
      m:acquire()
      cv:wait(m)
      -- After wait() returns, mutex must be held (count == 0)
      mutex_held = (m:count() == 0)
      m:release()
    end)
    coroutine.resume(co)

    m:acquire()
    cv:signal()
    m:release()
    T.ok(mutex_held)
  end)
end)

-- ---------------------------------------------------------------------------
-- Channel tests
-- ---------------------------------------------------------------------------

T.describe("channel", function()
  T.it("cap() and len() on new channel", function()
    local ch = M.channel(3)
    T.eq(ch:cap(), 3)
    T.eq(ch:len(), 0)
    T.eq(ch:is_closed(), false)
  end)

  T.it("buffered: send/recv without blocking", function()
    local ch = M.channel(3)
    ch:send(10)
    ch:send(20)
    ch:send(30)
    T.eq(ch:len(), 3)
    local v1, ok1 = ch:recv()
    T.eq(v1, 10)
    T.ok(ok1)
    local v2, ok2 = ch:recv()
    T.eq(v2, 20)
    T.ok(ok2)
    local v3, ok3 = ch:recv()
    T.eq(v3, 30)
    T.ok(ok3)
    T.eq(ch:len(), 0)
  end)

  T.it("try_send succeeds when space available", function()
    local ch = M.channel(2)
    T.ok(ch:try_send(1))
    T.ok(ch:try_send(2))
    T.eq(ch:len(), 2)
  end)

  T.it("try_send fails when full", function()
    local ch = M.channel(1)
    T.ok(ch:try_send(99))
    T.eq(ch:try_send(100), false)
    T.eq(ch:len(), 1)
  end)

  T.it("try_recv succeeds when items present", function()
    local ch = M.channel(2)
    ch:send(42)
    local v, ok = ch:try_recv()
    T.eq(v, 42)
    T.ok(ok)
    T.eq(ch:len(), 0)
  end)

  T.it("try_recv returns nil,false when empty", function()
    local ch = M.channel(2)
    local v, ok = ch:try_recv()
    T.eq(v, nil)
    T.eq(ok, false)
  end)

  T.it("blocking recv — woken by send", function()
    local ch = M.channel(0)
    local received = nil
    local co = coroutine.create(function()
      local v, ok = ch:recv()
      received = v
      T.ok(ok)
    end)
    coroutine.resume(co)
    T.eq(received, nil)
    -- co is suspended waiting for a value
    T.eq(coroutine.status(co), "suspended")
    ch:send(77)
    T.eq(received, 77)
  end)

  T.it("blocking send — woken by recv", function()
    local ch = M.channel(0)
    local sent = false
    local co = coroutine.create(function()
      ch:send(55)
      sent = true
    end)
    coroutine.resume(co)
    T.eq(sent, false)
    T.eq(coroutine.status(co), "suspended")
    local v, ok = ch:recv()
    T.eq(v, 55)
    T.ok(ok)
    T.ok(sent)
  end)

  T.it("blocking recv when buffer full — sender enqueues, receiver drains", function()
    local ch = M.channel(1)
    -- Fill the buffer
    ch:send(1)
    T.eq(ch:len(), 1)
    -- This send will block
    local co = coroutine.create(function()
      ch:send(2)
    end)
    coroutine.resume(co)
    T.eq(coroutine.status(co), "suspended")
    -- Drain one: should unblock sender
    local v1, ok1 = ch:recv()
    T.eq(v1, 1)
    T.ok(ok1)
    -- sender should now be unblocked and the buffer has 2
    T.eq(ch:len(), 1)
    local v2, ok2 = ch:recv()
    T.eq(v2, 2)
    T.ok(ok2)
  end)

  T.it("close() prevents further sends", function()
    local ch = M.channel(2)
    ch:close()
    T.ok(ch:is_closed())
    local ok, err = ch:send(1)
    T.eq(ok, nil)
    T.eq(err, "closed")
  end)

  T.it("recv on closed empty channel returns nil,'closed'", function()
    local ch = M.channel(2)
    ch:close()
    local v, ok = ch:recv()
    T.eq(v, nil)
    T.eq(ok, "closed")
  end)

  T.it("recv drains buffer after close", function()
    local ch = M.channel(3)
    ch:send(1)
    ch:send(2)
    ch:send(3)
    ch:close()
    local v1, ok1 = ch:recv()
    T.eq(v1, 1)
    T.ok(ok1)
    local v2, ok2 = ch:recv()
    T.eq(v2, 2)
    T.ok(ok2)
    local v3, ok3 = ch:recv()
    T.eq(v3, 3)
    T.ok(ok3)
    -- Now empty and closed
    local v4, ok4 = ch:recv()
    T.eq(v4, nil)
    T.eq(ok4, "closed")
  end)

  T.it("close() wakes pending receivers", function()
    local ch = M.channel(0)
    local got_ok = nil
    local co = coroutine.create(function()
      local v, ok = ch:recv()
      got_ok = ok
      T.eq(v, nil)
    end)
    coroutine.resume(co)
    T.eq(coroutine.status(co), "suspended")
    ch:close()
    T.eq(got_ok, "closed")
  end)

  T.it("try_recv on closed empty channel returns nil,'closed'", function()
    local ch = M.channel(1)
    ch:close()
    local v, ok = ch:try_recv()
    T.eq(v, nil)
    T.eq(ok, "closed")
  end)

  T.it("try_send fails on closed channel", function()
    local ch = M.channel(2)
    ch:close()
    T.eq(ch:try_send(1), false)
  end)

  T.it("multiple receivers wake in order on successive sends", function()
    local ch = M.channel(0)
    local order = {}
    for i = 1, 3 do
      local id = i
      local co = coroutine.create(function()
        ch:recv()
        order[#order + 1] = id
      end)
      coroutine.resume(co)
    end
    ch:send("a")
    ch:send("b")
    ch:send("c")
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)
end)
