if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.signals")

-- ---------------------------------------------------------------------------
T.describe("signal.create — read/write", function()
  T.it("initial value is readable", function()
    local c = S.create(0)
    T.eq(c(), 0)
  end)

  T.it("write changes the value", function()
    local c = S.create(0)
    c(5)
    T.eq(c(), 5)
  end)

  T.it("successive writes accumulate", function()
    local c = S.create(0)
    c(1)
    c(2)
    c(3)
    T.eq(c(), 3)
  end)

  T.it("nil initial value is allowed", function()
    local c = S.create(nil)
    -- nil write is treated as read, so just read works
    T.eq(c(), nil)
  end)

  T.it("writing same value is a no-op (does not notify)", function()
    local c = S.create(10)
    local runs = 0
    S.effect(function() runs = runs + 1; c() end)
    T.eq(runs, 1)
    c(10)  -- same value
    T.eq(runs, 1)
  end)

  T.it("stores string values", function()
    local c = S.create("hello")
    T.eq(c(), "hello")
    c("world")
    T.eq(c(), "world")
  end)

  T.it("stores table values", function()
    local t = { x = 1 }
    local c = S.create(t)
    T.eq(c(), t)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.peek", function()
  T.it("module fn reads without tracking", function()
    local c = S.create(42)
    local reads = 0
    S.effect(function()
      reads = reads + 1
      S.peek(c)  -- should NOT create dependency
    end)
    T.eq(reads, 1)
    c(99)
    T.eq(reads, 1)  -- effect did NOT re-run
  end)

  T.it("method peek reads without tracking", function()
    local c = S.create(42)
    local reads = 0
    S.effect(function()
      reads = reads + 1
      c:peek()
    end)
    T.eq(reads, 1)
    c(99)
    T.eq(reads, 1)
  end)

  T.it("peek returns current value", function()
    local c = S.create(7)
    T.eq(S.peek(c), 7)
    c(8)
    T.eq(S.peek(c), 8)
    T.eq(c:peek(), 8)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.computed", function()
  T.it("derives a value from a signal", function()
    local c = S.create(5)
    local d = S.computed(function() return c() * 2 end)
    T.eq(d(), 10)
  end)

  T.it("updates when dependency changes", function()
    local c = S.create(3)
    local d = S.computed(function() return c() + 1 end)
    T.eq(d(), 4)
    c(9)
    T.eq(d(), 10)
  end)

  T.it("is lazy — does not recompute until read", function()
    local evals = 0
    local c = S.create(1)
    local d = S.computed(function()
      evals = evals + 1
      return c() * 10
    end)
    T.eq(evals, 0)  -- not evaluated yet
    d()             -- trigger first eval
    T.eq(evals, 1)
    c(2)            -- mark dirty
    T.eq(evals, 1)  -- still not re-evaluated
    d()             -- re-read triggers recompute
    T.eq(evals, 2)
  end)

  T.it("caches result — multiple reads do not recompute", function()
    local evals = 0
    local c = S.create(5)
    local d = S.computed(function()
      evals = evals + 1
      return c() * 3
    end)
    d()
    d()
    d()
    T.eq(evals, 1)
  end)

  T.it("chains: computed depending on computed", function()
    local x = S.create(2)
    local a = S.computed(function() return x() * 2 end)
    local b = S.computed(function() return a() + 1 end)
    T.eq(b(), 5)
    x(4)
    T.eq(b(), 9)
  end)

  T.it("multiple signal dependencies", function()
    local x = S.create(10)
    local y = S.create(20)
    local s = S.computed(function() return x() + y() end)
    T.eq(s(), 30)
    x(5)
    T.eq(s(), 25)
    y(5)
    T.eq(s(), 10)
  end)

  T.it("circular dependency does not infinite-loop", function()
    -- Build a computed that would depend on itself (via a mutable upvalue trick)
    local holder
    local evals = 0
    holder = S.computed(function()
      evals = evals + 1
      if evals > 1 then
        -- read holder to create circular dep — should return stale nil
        return (holder() or 0) + 1
      end
      return 1
    end)
    local v = holder()
    T.ok(v ~= nil, "should return a value without infinite loop")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.effect", function()
  T.it("runs immediately on creation", function()
    local ran = false
    S.effect(function() ran = true end)
    T.ok(ran)
  end)

  T.it("re-runs when dependency changes", function()
    local c = S.create(1)
    local log = {}
    S.effect(function() log[#log + 1] = c() end)
    T.eq(#log, 1)
    T.eq(log[1], 1)
    c(2)
    T.eq(#log, 2)
    T.eq(log[2], 2)
    c(3)
    T.eq(#log, 3)
    T.eq(log[3], 3)
  end)

  T.it("stop() prevents future runs", function()
    local c = S.create(0)
    local log = {}
    local stop = S.effect(function() log[#log + 1] = c() end)
    T.eq(#log, 1)
    stop()
    c(1)
    T.eq(#log, 1)  -- should NOT have re-run
  end)

  T.it("stop() is idempotent", function()
    local c = S.create(0)
    local log = {}
    local stop = S.effect(function() log[#log + 1] = c() end)
    stop()
    stop()  -- second call should not error
    c(1)
    T.eq(#log, 1)
  end)

  T.it("effect depending on computed re-runs when computed is dirty", function()
    local x = S.create(1)
    local d = S.computed(function() return x() * 10 end)
    local log = {}
    S.effect(function() log[#log + 1] = d() end)
    T.eq(log[1], 10)
    x(2)
    T.eq(log[2], 20)
  end)

  T.it("multiple effects on same signal each run", function()
    local c = S.create(0)
    local a, b = 0, 0
    S.effect(function() a = c() end)
    S.effect(function() b = c() * 2 end)
    c(5)
    T.eq(a, 5)
    T.eq(b, 10)
  end)

  T.it("effect rebuilds deps after re-run (conditional dep)", function()
    local flag = S.create(true)
    local x    = S.create(1)
    local y    = S.create(100)
    local log  = {}
    S.effect(function()
      if flag() then
        log[#log + 1] = x()
      else
        log[#log + 1] = y()
      end
    end)
    T.eq(log[1], 1)
    x(2)
    T.eq(log[2], 2)
    flag(false)          -- now depends on y, not x
    T.eq(log[3], 100)
    local before = #log
    x(99)                -- x is no longer a dep
    T.eq(#log, before)
    y(200)
    T.eq(log[#log], 200)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.batch", function()
  T.it("defers effect runs until batch completes", function()
    local x = S.create(1)
    local y = S.create(2)
    local runs = 0
    S.effect(function()
      runs = runs + 1
      x(); y()
    end)
    T.eq(runs, 1)
    S.batch(function()
      x(10)
      y(20)
    end)
    T.eq(runs, 2)  -- exactly one run, not two
  end)

  T.it("effect sees final values after batch", function()
    local x = S.create(0)
    local last = 0
    S.effect(function() last = x() end)
    S.batch(function()
      x(1)
      x(2)
      x(3)
    end)
    T.eq(last, 3)
  end)

  T.it("nested batch defers until outermost completes", function()
    local x = S.create(0)
    local runs = 0
    S.effect(function() runs = runs + 1; x() end)
    T.eq(runs, 1)
    S.batch(function()
      S.batch(function()
        x(1)
      end)
      T.eq(runs, 1)  -- still deferred
      x(2)
    end)
    T.eq(runs, 2)  -- one run after outer batch ends
  end)

  T.it("effects that write during batch are also deferred", function()
    local a = S.create(0)
    local b = S.create(0)
    local log = {}
    S.effect(function()
      log[#log + 1] = "a=" .. a() .. ",b=" .. b()
    end)
    T.eq(#log, 1)
    S.batch(function()
      a(1)
      b(2)
    end)
    T.eq(#log, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.memo", function()
  T.it("memo behaves like computed", function()
    local x = S.create(5)
    local m = S.memo(function() return x() * x() end)
    T.eq(m(), 25)
    x(6)
    T.eq(m(), 36)
  end)

  T.it("memo is lazy", function()
    local evals = 0
    local x = S.create(3)
    local m = S.memo(function()
      evals = evals + 1
      return x() + 1
    end)
    T.eq(evals, 0)
    m()
    T.eq(evals, 1)
    x(4)
    T.eq(evals, 1)  -- not re-evaluated yet
    m()
    T.eq(evals, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.untrack", function()
  T.it("prevents dependency creation inside untrack", function()
    local c = S.create(10)
    local runs = 0
    S.effect(function()
      runs = runs + 1
      S.untrack(function() return c() end)
    end)
    T.eq(runs, 1)
    c(20)
    T.eq(runs, 1)  -- effect should NOT have re-run
  end)

  T.it("returns the value from the fn", function()
    local c = S.create(42)
    local v = S.untrack(function() return c() end)
    T.eq(v, 42)
  end)

  T.it("mixed: tracked and untracked reads in same computed", function()
    local x = S.create(1)
    local y = S.create(100)
    local evals = 0
    local d = S.computed(function()
      evals = evals + 1
      local ux = S.untrack(function() return x() end)
      return ux + y()  -- only y is tracked
    end)
    T.eq(d(), 101)
    T.eq(evals, 1)
    x(99)       -- x is untracked, should NOT trigger recompute
    T.eq(d(), 101)
    T.eq(evals, 1)
    y(200)      -- y IS tracked
    T.eq(d(), 299)  -- 99 + 200
    T.eq(evals, 2)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("signal.on", function()
  T.it("calls listener when value changes", function()
    local c = S.create(0)
    local log = {}
    S.on(c, function(new, old)
      log[#log + 1] = { new = new, old = old }
    end)
    c(1)
    T.eq(#log, 1)
    T.eq(log[1].new, 1)
    T.eq(log[1].old, 0)
    c(2)
    T.eq(#log, 2)
    T.eq(log[2].old, 1)
  end)

  T.it("unsub stops further calls", function()
    local c = S.create(0)
    local calls = 0
    local unsub = S.on(c, function() calls = calls + 1 end)
    c(1)
    T.eq(calls, 1)
    unsub()
    c(2)
    T.eq(calls, 1)
  end)

  T.it("multiple on listeners all fire", function()
    local c = S.create(0)
    local a, b = 0, 0
    S.on(c, function(v) a = v end)
    S.on(c, function(v) b = v * 2 end)
    c(5)
    T.eq(a, 5)
    T.eq(b, 10)
  end)

  T.it("on does not run on initial value (not reactive effect)", function()
    local c = S.create(10)
    local calls = 0
    S.on(c, function() calls = calls + 1 end)
    T.eq(calls, 0)  -- on() does NOT fire immediately
  end)

  T.it("on does not fire when same value is written", function()
    local c = S.create(42)
    local calls = 0
    S.on(c, function() calls = calls + 1 end)
    c(42)  -- same value
    T.eq(calls, 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("integration", function()
  T.it("effect sees computed value that depends on two signals", function()
    local x = S.create(3)
    local y = S.create(4)
    local hyp = S.computed(function()
      return x() * x() + y() * y()
    end)
    local last = 0
    S.effect(function() last = hyp() end)
    T.eq(last, 25)
    x(0)
    T.eq(last, 16)
    y(0)
    T.eq(last, 0)
  end)

  T.it("stop effect then batch does not revive it", function()
    local c = S.create(0)
    local runs = 0
    local stop = S.effect(function() runs = runs + 1; c() end)
    stop()
    S.batch(function() c(1) end)
    T.eq(runs, 1)
  end)

  T.it("derived chain: signal → computed → effect", function()
    local base = S.create(1)
    local sq   = S.computed(function() return base() * base() end)
    local cube = S.computed(function() return base() * sq() end)
    local log  = {}
    S.effect(function() log[#log + 1] = cube() end)
    T.eq(log[1], 1)
    base(2)
    T.eq(log[2], 8)
    base(3)
    T.eq(log[3], 27)
  end)

  T.it("batch with computed: reads inside batch see new value", function()
    local x = S.create(5)
    local d = S.computed(function() return x() * 2 end)
    local last = 0
    S.effect(function() last = d() end)
    T.eq(last, 10)
    S.batch(function()
      x(7)
      -- computed is dirty but we can still read it inside the batch
      T.eq(d(), 14)
    end)
    T.eq(last, 14)
  end)

  T.it("untrack inside effect: writing untracked signal triggers own subscribers", function()
    local a = S.create(0)
    local b = S.create(0)
    local b_log = {}
    S.effect(function() b_log[#b_log + 1] = b() end)
    T.eq(#b_log, 1)
    -- effect that reads a (tracked) and writes b (not tracked as dep of this effect)
    S.effect(function()
      local v = a()
      S.untrack(function() b(v * 10) end)
    end)
    T.eq(b_log[#b_log], 0)
    a(1)
    -- effect re-runs (a changed), writes b → b's subscribers fire
    T.eq(b_log[#b_log], 10)
  end)
end)

-- ---------------------------------------------------------------------------
-- Print summary
local summary = T._summary()
local total = summary.pass + summary.fail
print(string.format("reactive: %d/%d assertions passed", summary.pass, total))
for _, t in ipairs(summary.tests) do
  local status = t.ok and "ok" or "FAIL"
  print(string.format("  [%s] %s", status, t.name))
  if t.err then
    print("       " .. t.err)
  end
end
if summary.fail > 0 then
  os.exit(1)
end
