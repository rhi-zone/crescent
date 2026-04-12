-- lib/reactive_var/reactive_var_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local R = require("lib.reactive_var")

-- ---------------------------------------------------------------------------
-- var: basic read/write
-- ---------------------------------------------------------------------------

T.describe("R.var", function()
  T.it("initial value readable via call syntax", function()
    local x = R.var(42)
    T.eq(x(), 42)
  end)

  T.it("initial value readable via :get()", function()
    local x = R.var(7)
    T.eq(x:get(), 7)
  end)

  T.it("write via call syntax updates value", function()
    local x = R.var(0)
    x(99)
    T.eq(x(), 99)
  end)

  T.it("write via :set() updates value", function()
    local x = R.var(0)
    x:set(55)
    T.eq(x:get(), 55)
  end)

  T.it("nil initial value allowed", function()
    local x = R.var(nil)
    -- read returns nil; no crash
    T.eq(x:get(), nil)
  end)

  T.it("multiple independent vars don't interfere", function()
    local a = R.var(1)
    local b = R.var(2)
    a(10)
    T.eq(a(), 10)
    T.eq(b(), 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- computed: derived values
-- ---------------------------------------------------------------------------

T.describe("R.computed", function()
  T.it("returns derived value", function()
    local x = R.var(3)
    local d = R.computed(function() return x() * 2 end)
    T.eq(d(), 6)
  end)

  T.it("updates when dependency changes", function()
    local x = R.var(5)
    local d = R.computed(function() return x() + 1 end)
    T.eq(d(), 6)
    x(10)
    T.eq(d(), 11)
  end)

  T.it("is lazy — fn not called until read", function()
    local calls = 0
    local x = R.var(1)
    local d = R.computed(function()
      calls = calls + 1
      return x() * 3
    end)
    T.eq(calls, 0)
    d()
    T.eq(calls, 1)
  end)

  T.it("does not recompute when dep unchanged between reads", function()
    local calls = 0
    local x = R.var(4)
    local d = R.computed(function()
      calls = calls + 1
      return x() + 0
    end)
    d(); d(); d()
    T.eq(calls, 1)
  end)

  T.it("recomputes when dep changes between reads", function()
    local calls = 0
    local x = R.var(1)
    local d = R.computed(function()
      calls = calls + 1
      return x() * 2
    end)
    d()
    T.eq(calls, 1)
    x(2)
    d()
    T.eq(calls, 2)
  end)

  T.it("call syntax: d() is same as d:get()", function()
    local x = R.var(7)
    local d = R.computed(function() return x() - 1 end)
    T.eq(d(), d:get())
  end)

  T.it("nested computed: deep dependency chain", function()
    local x = R.var(1)
    local a = R.computed(function() return x() * 2 end)
    local b = R.computed(function() return a() + 1 end)
    local c = R.computed(function() return b() * b() end)
    -- x=1 → a=2 → b=3 → c=9
    T.eq(c(), 9)
    x(2)
    -- x=2 → a=4 → b=5 → c=25
    T.eq(c(), 25)
  end)

  T.it("computed can depend on multiple vars", function()
    local a = R.var(3)
    local b = R.var(4)
    local hyp = R.computed(function() return a() * a() + b() * b() end)
    T.eq(hyp(), 25)
    b(0)
    T.eq(hyp(), 9)
  end)
end)

-- ---------------------------------------------------------------------------
-- memo: alias for computed
-- ---------------------------------------------------------------------------

T.describe("R.memo", function()
  T.it("memo behaves like computed", function()
    local x = R.var(10)
    local m = R.memo(function() return x() * 3 end)
    T.eq(m(), 30)
    x(5)
    T.eq(m(), 15)
  end)
end)

-- ---------------------------------------------------------------------------
-- effect / autorun
-- ---------------------------------------------------------------------------

T.describe("R.effect", function()
  T.it("runs immediately on creation", function()
    local ran = 0
    local x = R.var(1)
    local stop = R.effect(function()
      ran = ran + 1
      x()  -- subscribe
    end)
    T.eq(ran, 1)
    stop()
  end)

  T.it("re-runs when dependency changes", function()
    local log = {}
    local x = R.var(0)
    local stop = R.effect(function()
      log[#log + 1] = x()
    end)
    x(1); x(2)
    T.eq(#log, 3)   -- initial + 2 writes
    T.eq(log[1], 0)
    T.eq(log[2], 1)
    T.eq(log[3], 2)
    stop()
  end)

  T.it("dispose stops reactions", function()
    local runs = 0
    local x = R.var(0)
    local stop = R.effect(function()
      runs = runs + 1
      x()
    end)
    T.eq(runs, 1)
    stop()
    x(99)
    T.eq(runs, 1)   -- no re-run after dispose
  end)

  T.it("dispose is idempotent", function()
    local x = R.var(0)
    local stop = R.effect(function() x() end)
    stop(); stop()   -- should not error
    T.ok(true)
  end)

  T.it("autorun is an alias for effect", function()
    local ran = 0
    local x = R.var(0)
    local stop = R.autorun(function()
      ran = ran + 1
      x()
    end)
    x(1)
    T.eq(ran, 2)
    stop()
  end)
end)

-- ---------------------------------------------------------------------------
-- batch
-- ---------------------------------------------------------------------------

T.describe("R.batch", function()
  T.it("defers effects until batch completes", function()
    local x = R.var(0)
    local runs = 0
    local stop = R.effect(function()
      runs = runs + 1
      x()
    end)
    T.eq(runs, 1)  -- initial run
    R.batch(function()
      x(1); x(2); x(3)
    end)
    T.eq(runs, 2)  -- one extra run after batch
    stop()
  end)

  T.it("effects see final value after batch", function()
    local x = R.var(0)
    local seen = {}
    local stop = R.effect(function()
      seen[#seen + 1] = x()
    end)
    R.batch(function()
      x(10); x(20); x(30)
    end)
    T.eq(seen[#seen], 30)
    stop()
  end)

  T.it("nested batches flush only at outermost end", function()
    local x = R.var(0)
    local runs = 0
    local stop = R.effect(function()
      runs = runs + 1
      x()
    end)
    T.eq(runs, 1)
    R.batch(function()
      R.batch(function()
        x(1); x(2)
      end)
      T.eq(runs, 1)  -- still inside outer batch
      x(3)
    end)
    T.eq(runs, 2)  -- flushed after outermost batch
    stop()
  end)
end)

-- ---------------------------------------------------------------------------
-- untracked
-- ---------------------------------------------------------------------------

T.describe("R.untracked", function()
  T.it("reads inside untracked do not create dependencies", function()
    local x = R.var(1)
    local runs = 0
    local stop = R.effect(function()
      runs = runs + 1
      R.untracked(function() x() end)  -- read without tracking
    end)
    T.eq(runs, 1)
    x(2)
    T.eq(runs, 1)  -- effect did NOT re-run
    stop()
  end)

  T.it("untracked returns value from fn", function()
    local x = R.var(42)
    local v = R.untracked(function() return x() end)
    T.eq(v, 42)
  end)

  T.it("untracked outside any effect is safe", function()
    local x = R.var(5)
    local v = R.untracked(function() return x() * 2 end)
    T.eq(v, 10)
  end)
end)

-- ---------------------------------------------------------------------------
-- watch
-- ---------------------------------------------------------------------------

T.describe("R.watch", function()
  T.it("callback receives new and old value on change", function()
    local x = R.var(10)
    local news, olds = {}, {}
    local stop = R.watch(x, function(new_val, old_val)
      news[#news + 1] = new_val
      olds[#olds + 1] = old_val
    end)
    x(20); x(30)
    T.eq(#news, 2)
    T.eq(news[1], 20)
    T.eq(olds[1], 10)
    T.eq(news[2], 30)
    T.eq(olds[2], 20)
    stop()
  end)

  T.it("stop() unsubscribes the watcher", function()
    local x = R.var(0)
    local calls = 0
    local stop = R.watch(x, function() calls = calls + 1 end)
    x(1)
    T.eq(calls, 1)
    stop()
    x(2)
    T.eq(calls, 1)  -- no further calls
  end)

  T.it("multiple watchers on same var are independent", function()
    local x = R.var(0)
    local a_calls, b_calls = 0, 0
    local stop_a = R.watch(x, function() a_calls = a_calls + 1 end)
    local stop_b = R.watch(x, function() b_calls = b_calls + 1 end)
    x(1)
    T.eq(a_calls, 1)
    T.eq(b_calls, 1)
    stop_a()
    x(2)
    T.eq(a_calls, 1)
    T.eq(b_calls, 2)
    stop_b()
  end)

  T.it("watch not triggered when same value re-set", function()
    local x = R.var(5)
    local calls = 0
    local stop = R.watch(x, function() calls = calls + 1 end)
    x(5)  -- no change
    T.eq(calls, 0)
    x(6)
    T.eq(calls, 1)
    stop()
  end)
end)

-- ---------------------------------------------------------------------------
-- list
-- ---------------------------------------------------------------------------

T.describe("R.list", function()
  T.it("initial values readable via :get()", function()
    local l = R.list({10, 20, 30})
    T.eq(l:get(1), 10)
    T.eq(l:get(2), 20)
    T.eq(l:get(3), 30)
  end)

  T.it(":length() returns count", function()
    local l = R.list({1, 2, 3})
    T.eq(l:length(), 3)
  end)

  T.it(":push() appends element", function()
    local l = R.list({})
    l:push("a"); l:push("b")
    T.eq(l:length(), 2)
    T.eq(l:get(2), "b")
  end)

  T.it(":pop() removes and returns last element", function()
    local l = R.list({1, 2, 3})
    local v = l:pop()
    T.eq(v, 3)
    T.eq(l:length(), 2)
  end)

  T.it(":pop() on empty list returns nil", function()
    local l = R.list({})
    T.eq(l:pop(), nil)
  end)

  T.it(":set() replaces element at index", function()
    local l = R.list({1, 2, 3})
    l:set(2, 99)
    T.eq(l:get(2), 99)
  end)

  T.it(":to_array() returns a copy", function()
    local l = R.list({4, 5, 6})
    local arr = l:to_array()
    T.eq(arr[1], 4)
    T.eq(arr[2], 5)
    T.eq(arr[3], 6)
    T.eq(#arr, 3)
  end)

  T.it("effect re-runs when list mutated", function()
    local l = R.list({1, 2})
    local len_seen = {}
    local stop = R.effect(function()
      len_seen[#len_seen + 1] = l:length()
    end)
    l:push(3)
    l:push(4)
    T.ok(#len_seen >= 3)  -- initial + 2 mutations
    stop()
  end)

  T.it("to_array returns independent copy", function()
    local l = R.list({1, 2, 3})
    local arr = l:to_array()
    l:set(1, 999)
    T.eq(arr[1], 1)  -- copy not affected
  end)
end)

-- ---------------------------------------------------------------------------
-- map
-- ---------------------------------------------------------------------------

T.describe("R.map", function()
  T.it("initial values readable via :get()", function()
    local m = R.map({a = 1, b = 2})
    T.eq(m:get("a"), 1)
    T.eq(m:get("b"), 2)
  end)

  T.it(":set() and :get() round-trip", function()
    local m = R.map({})
    m:set("x", 42)
    T.eq(m:get("x"), 42)
  end)

  T.it(":has() returns true when key exists", function()
    local m = R.map({k = "v"})
    T.ok(m:has("k"))
  end)

  T.it(":has() returns false when key absent", function()
    local m = R.map({})
    T.ok(not m:has("missing"))
  end)

  T.it(":delete() removes key", function()
    local m = R.map({k = "v"})
    m:delete("k")
    T.ok(not m:has("k"))
    T.eq(m:get("k"), nil)
  end)

  T.it(":size() counts entries", function()
    local m = R.map({a = 1, b = 2, c = 3})
    T.eq(m:size(), 3)
    m:delete("b")
    T.eq(m:size(), 2)
  end)

  T.it(":keys() returns sorted list of keys", function()
    local m = R.map({c = 3, a = 1, b = 2})
    local ks = m:keys()
    T.eq(ks[1], "a")
    T.eq(ks[2], "b")
    T.eq(ks[3], "c")
  end)

  T.it("empty map has size 0 and empty keys", function()
    local m = R.map({})
    T.eq(m:size(), 0)
    T.eq(#m:keys(), 0)
  end)

  T.it("effect re-runs when map mutated", function()
    local m = R.map({a = 1})
    local sizes = {}
    local stop = R.effect(function()
      sizes[#sizes + 1] = m:size()
    end)
    m:set("b", 2)
    m:delete("a")
    T.ok(#sizes >= 3)
    stop()
  end)
end)

-- ---------------------------------------------------------------------------
-- Circular dependency guard
-- ---------------------------------------------------------------------------

T.describe("circular dependency guard", function()
  T.it("computed circular dep returns stale value without infinite loop", function()
    local x = R.var(1)
    local c
    c = R.computed(function()
      local v = x()
      -- try to read c itself while computing (circular)
      if c then
        -- safely access stale value via the guard
        local ok, _ = pcall(function() return c() end)
        T.ok(ok)  -- should not infinitely recurse
      end
      return v * 2
    end)
    -- First read triggers computation
    local v = c()
    T.eq(v, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- effect + computed interaction
-- ---------------------------------------------------------------------------

T.describe("effect + computed interaction", function()
  T.it("effect depending on computed re-runs when base var changes", function()
    local x = R.var(1)
    local d = R.computed(function() return x() * 10 end)
    local seen = {}
    local stop = R.effect(function()
      seen[#seen + 1] = d()
    end)
    x(2); x(3)
    T.eq(seen[1], 10)
    T.eq(seen[2], 20)
    T.eq(seen[3], 30)
    stop()
  end)

  T.it("computed not recomputed more than necessary via effects", function()
    local calls = 0
    local x = R.var(0)
    local d = R.computed(function()
      calls = calls + 1
      return x() + 1
    end)
    local stop = R.effect(function() d() end)
    T.eq(calls, 1)  -- initial effect run
    x(1)
    T.eq(calls, 2)
    x(1)  -- same value, no recompute
    T.eq(calls, 2)
    stop()
  end)
end)

-- ---------------------------------------------------------------------------
-- R._tier
-- ---------------------------------------------------------------------------

T.describe("R._tier", function()
  T.it("is 'pure'", function()
    T.eq(R._tier, "pure")
  end)
end)
