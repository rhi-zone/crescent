if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local obs = require("lib.observable")

-- Deep equality assertion for tables (recursive).
local function arr_eq(a, b, msg)
  local prefix = msg and (msg .. ": ") or ""
  T.eq(type(a), "table", prefix .. "expected table for a")
  T.eq(type(b), "table", prefix .. "expected table for b")
  T.eq(#a, #b, prefix .. "length mismatch")
  for i = 1, #a do
    if type(a[i]) == "table" and type(b[i]) == "table" then
      arr_eq(a[i], b[i], prefix .. "[" .. i .. "]")
    else
      T.eq(a[i], b[i], prefix .. "[" .. i .. "]")
    end
  end
end

-- Helpers
local function collect(o)
  local values = {}
  local err_val = nil
  local completed = false
  o:subscribe({
    next = function(v) values[#values + 1] = v end,
    error = function(e) err_val = e end,
    complete = function() completed = true end,
  })
  return values, completed, err_val
end

-- of

T.describe("obs.of", function()
  T.it("emits values in order", function()
    local v, c = collect(obs.of(1, 2, 3))
    arr_eq(v, { 1, 2, 3 })
    T.ok(c)
  end)

  T.it("emits single value", function()
    local v = collect(obs.of(42))
    arr_eq(v, { 42 })
  end)

  T.it("emits no values and completes", function()
    local v, c = collect(obs.of())
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("emits nil values correctly", function()
    local completed = false
    obs.of(nil):subscribe({
      next = function() end,
      complete = function() completed = true end,
    })
    T.ok(completed)
  end)
end)

-- from_array

T.describe("obs.from_array", function()
  T.it("emits array elements", function()
    local v, c = collect(obs.from_array({ 10, 20, 30 }))
    arr_eq(v, { 10, 20, 30 })
    T.ok(c)
  end)

  T.it("handles empty array", function()
    local v, c = collect(obs.from_array({}))
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("handles string array", function()
    local v = collect(obs.from_array({ "a", "b", "c" }))
    arr_eq(v, { "a", "b", "c" })
  end)
end)

-- empty

T.describe("obs.empty", function()
  T.it("completes immediately", function()
    local v, c = collect(obs.empty())
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- never

T.describe("obs.never", function()
  T.it("never emits or completes", function()
    local v, c = collect(obs.never())
    T.eq(#v, 0)
    T.eq(c, false)
  end)
end)

-- create

T.describe("obs.create", function()
  T.it("calls subscribe function with observer", function()
    local called = false
    local o = obs.create(function(observer)
      called = true
      observer:next(1)
      observer:complete()
    end)
    local v, c = collect(o)
    T.ok(called)
    arr_eq(v, { 1 })
    T.ok(c)
  end)

  T.it("returns teardown function", function()
    local teardown_called = false
    local o = obs.create(function(observer)
      observer:complete()
      return function() teardown_called = true end
    end)
    local teardown = o:subscribe({ complete = function() end })
    if teardown then teardown() end
    T.ok(teardown_called)
  end)

  T.it("error in subscribe fn calls observer error", function()
    local o = obs.create(function()
      error("boom")
    end)
    local err_val = nil
    o:subscribe({
      error = function(e) err_val = e end,
    })
    T.ok(err_val ~= nil)
  end)
end)

-- map

T.describe("Observable:map", function()
  T.it("transforms values", function()
    local v = collect(obs.of(1, 2, 3):map(function(x) return x * 2 end))
    arr_eq(v, { 2, 4, 6 })
  end)

  T.it("preserves completion", function()
    local _, c = collect(obs.of(1):map(function(x) return x end))
    T.ok(c)
  end)

  T.it("chains multiple maps", function()
    local v = collect(obs.of(1, 2):map(function(x) return x + 1 end):map(function(x) return x * 10 end))
    arr_eq(v, { 20, 30 })
  end)
end)

-- filter

T.describe("Observable:filter", function()
  T.it("keeps matching values", function()
    local v = collect(obs.of(1, 2, 3, 4, 5):filter(function(x) return x % 2 == 1 end))
    arr_eq(v, { 1, 3, 5 })
  end)

  T.it("returns empty when nothing matches", function()
    local v, c = collect(obs.of(2, 4):filter(function(x) return x > 10 end))
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("preserves all when all match", function()
    local v = collect(obs.of(1, 2, 3):filter(function() return true end))
    arr_eq(v, { 1, 2, 3 })
  end)
end)

-- take

T.describe("Observable:take", function()
  T.it("takes first n values", function()
    local v, c = collect(obs.of(1, 2, 3, 4, 5):take(3))
    arr_eq(v, { 1, 2, 3 })
    T.ok(c)
  end)

  T.it("takes all if fewer than n", function()
    local v, c = collect(obs.of(1, 2):take(5))
    arr_eq(v, { 1, 2 })
    T.ok(c)
  end)

  T.it("take(0) completes immediately", function()
    local v, c = collect(obs.of(1, 2, 3):take(0))
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- skip

T.describe("Observable:skip", function()
  T.it("skips first n values", function()
    local v = collect(obs.of(1, 2, 3, 4, 5):skip(2))
    arr_eq(v, { 3, 4, 5 })
  end)

  T.it("skips all if n >= count", function()
    local v, c = collect(obs.of(1, 2):skip(5))
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("skip(0) emits all", function()
    local v = collect(obs.of(1, 2, 3):skip(0))
    arr_eq(v, { 1, 2, 3 })
  end)
end)

-- distinct

T.describe("Observable:distinct", function()
  T.it("removes consecutive duplicates", function()
    local v = collect(obs.from_array({ 1, 1, 2, 2, 3, 1, 1 }):distinct())
    arr_eq(v, { 1, 2, 3, 1 })
  end)

  T.it("no duplicates passes through", function()
    local v = collect(obs.of(1, 2, 3):distinct())
    arr_eq(v, { 1, 2, 3 })
  end)

  T.it("all same emits once", function()
    local v = collect(obs.of(5, 5, 5, 5):distinct())
    arr_eq(v, { 5 })
  end)

  T.it("works with strings", function()
    local v = collect(obs.from_array({ "a", "a", "b", "b", "a" }):distinct())
    arr_eq(v, { "a", "b", "a" })
  end)
end)

-- reduce

T.describe("Observable:reduce", function()
  T.it("accumulates values", function()
    local v, c = collect(obs.of(1, 2, 3):reduce(0, function(acc, x) return acc + x end))
    arr_eq(v, { 6 })
    T.ok(c)
  end)

  T.it("emits init on empty", function()
    local v = collect(obs.empty():reduce(42, function(acc, x) return acc + x end))
    arr_eq(v, { 42 })
  end)

  T.it("string concatenation", function()
    local v = collect(obs.of("a", "b", "c"):reduce("", function(acc, x) return acc .. x end))
    arr_eq(v, { "abc" })
  end)
end)

-- scan

T.describe("Observable:scan", function()
  T.it("emits running accumulation", function()
    local v = collect(obs.of(1, 2, 3):scan(0, function(acc, x) return acc + x end))
    arr_eq(v, { 1, 3, 6 })
  end)

  T.it("empty source completes without emitting", function()
    local v, c = collect(obs.empty():scan(0, function(acc, x) return acc + x end))
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- flat_map

T.describe("Observable:flat_map", function()
  T.it("flattens inner observables", function()
    local v = collect(obs.of(1, 2, 3):flat_map(function(x)
      return obs.of(x, x * 10)
    end))
    arr_eq(v, { 1, 10, 2, 20, 3, 30 })
  end)

  T.it("handles empty inner", function()
    local v, c = collect(obs.of(1, 2):flat_map(function()
      return obs.empty()
    end))
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("single element flat_map", function()
    local v = collect(obs.of(5):flat_map(function(x) return obs.of(x + 1) end))
    arr_eq(v, { 6 })
  end)
end)

-- tap

T.describe("Observable:tap", function()
  T.it("executes side effect without transforming", function()
    local side = {}
    local v = collect(obs.of(1, 2, 3):tap(function(x) side[#side + 1] = x end))
    arr_eq(v, { 1, 2, 3 })
    arr_eq(side, { 1, 2, 3 })
  end)
end)

-- concat (method)

T.describe("Observable:concat", function()
  T.it("emits self then other", function()
    local v, c = collect(obs.of(1, 2):concat(obs.of(3, 4)))
    arr_eq(v, { 1, 2, 3, 4 })
    T.ok(c)
  end)

  T.it("empty concat non-empty", function()
    local v = collect(obs.empty():concat(obs.of(1, 2)))
    arr_eq(v, { 1, 2 })
  end)

  T.it("non-empty concat empty", function()
    local v = collect(obs.of(1, 2):concat(obs.empty()))
    arr_eq(v, { 1, 2 })
  end)
end)

-- merge (method)

T.describe("Observable:merge", function()
  T.it("interleaves (sync: self first, then other)", function()
    local v, c = collect(obs.of(1, 2):merge(obs.of(3, 4)))
    arr_eq(v, { 1, 2, 3, 4 })
    T.ok(c)
  end)
end)

-- take_while

T.describe("Observable:take_while", function()
  T.it("takes while predicate holds", function()
    local v, c = collect(obs.of(1, 2, 3, 4, 5):take_while(function(x) return x < 4 end))
    arr_eq(v, { 1, 2, 3 })
    T.ok(c)
  end)

  T.it("takes none if first fails", function()
    local v, c = collect(obs.of(10, 20):take_while(function(x) return x < 5 end))
    T.eq(#v, 0)
    T.ok(c)
  end)

  T.it("takes all if predicate always true", function()
    local v = collect(obs.of(1, 2, 3):take_while(function() return true end))
    arr_eq(v, { 1, 2, 3 })
  end)
end)

-- skip_while

T.describe("Observable:skip_while", function()
  T.it("skips while predicate holds", function()
    local v = collect(obs.of(1, 2, 3, 4, 5):skip_while(function(x) return x < 3 end))
    arr_eq(v, { 3, 4, 5 })
  end)

  T.it("skips none if first fails", function()
    local v = collect(obs.of(10, 20):skip_while(function(x) return x > 100 end))
    arr_eq(v, { 10, 20 })
  end)

  T.it("skips all if always true", function()
    local v, c = collect(obs.of(1, 2, 3):skip_while(function() return true end))
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- debounce

T.describe("Observable:debounce", function()
  T.it("emits first value immediately (starts ready)", function()
    local v = collect(obs.of(1, 2, 3, 4, 5):debounce(3))
    -- starts ready (since_emit = n), so emits 1 (since_emit=0), skips 2,3, emits 4 (since_emit=3>=3), skips 5
    arr_eq(v, { 1, 4 })
  end)

  T.it("debounce(1) emits all", function()
    local v = collect(obs.of(1, 2, 3):debounce(1))
    arr_eq(v, { 1, 2, 3 })
  end)
end)

-- buffer

T.describe("Observable:buffer", function()
  T.it("buffers n items", function()
    local v = collect(obs.of(1, 2, 3, 4, 5, 6):buffer(3))
    T.eq(#v, 2)
    arr_eq(v[1], { 1, 2, 3 })
    arr_eq(v[2], { 4, 5, 6 })
  end)

  T.it("emits remaining on complete", function()
    local v, c = collect(obs.of(1, 2, 3, 4, 5):buffer(3))
    T.eq(#v, 2)
    arr_eq(v[1], { 1, 2, 3 })
    arr_eq(v[2], { 4, 5 })
    T.ok(c)
  end)

  T.it("buffer(1) emits each as array", function()
    local v = collect(obs.of(1, 2):buffer(1))
    T.eq(#v, 2)
    arr_eq(v[1], { 1 })
    arr_eq(v[2], { 2 })
  end)

  T.it("empty source emits nothing", function()
    local v, c = collect(obs.empty():buffer(5))
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- to_array

T.describe("Observable:to_array", function()
  T.it("collects all into single array", function()
    local v = collect(obs.of(1, 2, 3):to_array())
    T.eq(#v, 1)
    arr_eq(v[1], { 1, 2, 3 })
  end)

  T.it("empty produces empty array", function()
    local v, c = collect(obs.empty():to_array())
    T.eq(#v, 1)
    T.eq(#v[1], 0)
    T.ok(c)
  end)
end)

-- M.merge (combinator)

T.describe("obs.merge", function()
  T.it("merges multiple observables", function()
    local v, c = collect(obs.merge(obs.of(1, 2), obs.of(3, 4), obs.of(5)))
    arr_eq(v, { 1, 2, 3, 4, 5 })
    T.ok(c)
  end)
end)

-- M.concat (combinator)

T.describe("obs.concat", function()
  T.it("concats multiple observables", function()
    local v, c = collect(obs.concat(obs.of(1, 2), obs.of(3), obs.of(4, 5)))
    arr_eq(v, { 1, 2, 3, 4, 5 })
    T.ok(c)
  end)

  T.it("handles empty sources", function()
    local v = collect(obs.concat(obs.empty(), obs.of(1), obs.empty()))
    arr_eq(v, { 1 })
  end)
end)

-- M.zip

T.describe("obs.zip", function()
  T.it("pairs elements by index", function()
    local v = collect(obs.zip(obs.of(1, 2, 3), obs.of("a", "b", "c")))
    T.eq(#v, 3)
    arr_eq(v[1], { 1, "a" })
    arr_eq(v[2], { 2, "b" })
    arr_eq(v[3], { 3, "c" })
  end)

  T.it("completes on shortest", function()
    local v, c = collect(obs.zip(obs.of(1, 2), obs.of("a", "b", "c")))
    T.eq(#v, 2)
    arr_eq(v[1], { 1, "a" })
    arr_eq(v[2], { 2, "b" })
    T.ok(c)
  end)

  T.it("three sources", function()
    local v = collect(obs.zip(obs.of(1, 2), obs.of("a", "b"), obs.of(true, false)))
    T.eq(#v, 2)
    arr_eq(v[1], { 1, "a", true })
    arr_eq(v[2], { 2, "b", false })
  end)

  T.it("empty source yields nothing", function()
    local v, c = collect(obs.zip(obs.of(1, 2), obs.empty()))
    T.eq(#v, 0)
    T.ok(c)
  end)
end)

-- M.combine_latest

T.describe("obs.combine_latest", function()
  T.it("emits when all have values (sync)", function()
    -- With sync observables, first source completes before second starts.
    -- So: o1 emits 1,2,3 (no output yet since o2 hasn't emitted).
    -- Then o2 emits "a" -> [3,"a"], "b" -> [3,"b"].
    local v = collect(obs.combine_latest(obs.of(1, 2, 3), obs.of("a", "b")))
    T.eq(#v, 2)
    arr_eq(v[1], { 3, "a" })
    arr_eq(v[2], { 3, "b" })
  end)

  T.it("uses subjects for interleaved emissions", function()
    local s1 = obs.subject()
    local s2 = obs.subject()
    -- wrap subjects as observables
    local o1 = obs.create(function(observer)
      return s1:subscribe({
        next = function(v) observer:next(v) end,
        error = function(e) observer:error(e) end,
        complete = function() observer:complete() end,
      })
    end)
    local o2 = obs.create(function(observer)
      return s2:subscribe({
        next = function(v) observer:next(v) end,
        error = function(e) observer:error(e) end,
        complete = function() observer:complete() end,
      })
    end)
    local v = {}
    obs.combine_latest(o1, o2):subscribe({
      next = function(val) v[#v + 1] = { val[1], val[2] } end,
    })
    s1:next(1)       -- no output (s2 hasn't emitted)
    s2:next("a")     -- [1, "a"]
    s1:next(2)       -- [2, "a"]
    s2:next("b")     -- [2, "b"]
    T.eq(#v, 3)
    arr_eq(v[1], { 1, "a" })
    arr_eq(v[2], { 2, "a" })
    arr_eq(v[3], { 2, "b" })
  end)
end)

-- Subject

T.describe("obs.subject", function()
  T.it("pushes values to subscribers", function()
    local s = obs.subject()
    local v = {}
    s:subscribe({ next = function(x) v[#v + 1] = x end })
    s:next(1)
    s:next(2)
    s:next(3)
    arr_eq(v, { 1, 2, 3 })
  end)

  T.it("supports multiple subscribers", function()
    local s = obs.subject()
    local v1, v2 = {}, {}
    s:subscribe({ next = function(x) v1[#v1 + 1] = x end })
    s:subscribe({ next = function(x) v2[#v2 + 1] = x end })
    s:next(10)
    arr_eq(v1, { 10 })
    arr_eq(v2, { 10 })
  end)

  T.it("completes and stops emitting", function()
    local s = obs.subject()
    local v = {}
    local completed = false
    s:subscribe({
      next = function(x) v[#v + 1] = x end,
      complete = function() completed = true end,
    })
    s:next(1)
    s:complete()
    s:next(2)  -- should be ignored
    arr_eq(v, { 1 })
    T.ok(completed)
  end)

  T.it("error stops further emissions", function()
    local s = obs.subject()
    local v = {}
    local err_val = nil
    s:subscribe({
      next = function(x) v[#v + 1] = x end,
      error = function(e) err_val = e end,
    })
    s:next(1)
    s:error("fail")
    s:next(2)
    arr_eq(v, { 1 })
    T.eq(err_val, "fail")
  end)

  T.it("unsubscribe removes subscriber", function()
    local s = obs.subject()
    local v = {}
    local unsub = s:subscribe({ next = function(x) v[#v + 1] = x end })
    s:next(1)
    unsub()
    s:next(2)
    arr_eq(v, { 1 })
  end)

  T.it("late subscriber does not receive past values", function()
    local s = obs.subject()
    s:next(1)
    local v = {}
    s:subscribe({ next = function(x) v[#v + 1] = x end })
    s:next(2)
    arr_eq(v, { 2 })
  end)

  T.it("subscribe after complete returns nil", function()
    local s = obs.subject()
    s:complete()
    local unsub = s:subscribe({ next = function() end })
    T.eq(unsub, nil)
  end)
end)

-- Replay subject

T.describe("obs.replay_subject", function()
  T.it("replays buffered values to late subscriber", function()
    local rs = obs.replay_subject(3)
    rs:next(1)
    rs:next(2)
    rs:next(3)
    rs:next(4)
    local v = {}
    rs:subscribe({ next = function(x) v[#v + 1] = x end })
    arr_eq(v, { 2, 3, 4 }) -- only last 3
  end)

  T.it("replays fewer than n if fewer emitted", function()
    local rs = obs.replay_subject(5)
    rs:next(1)
    rs:next(2)
    local v = {}
    rs:subscribe({ next = function(x) v[#v + 1] = x end })
    arr_eq(v, { 1, 2 })
  end)

  T.it("replays then receives live values", function()
    local rs = obs.replay_subject(2)
    rs:next(1)
    rs:next(2)
    local v = {}
    rs:subscribe({ next = function(x) v[#v + 1] = x end })
    rs:next(3)
    arr_eq(v, { 1, 2, 3 })
  end)

  T.it("replays and notifies complete for late subscriber", function()
    local rs = obs.replay_subject(2)
    rs:next(1)
    rs:complete()
    local v = {}
    local completed = false
    rs:subscribe({
      next = function(x) v[#v + 1] = x end,
      complete = function() completed = true end,
    })
    arr_eq(v, { 1 })
    T.ok(completed)
  end)

  T.it("replays and notifies error for late subscriber", function()
    local rs = obs.replay_subject(2)
    rs:next(1)
    rs:error("oops")
    local v = {}
    local err_val = nil
    rs:subscribe({
      next = function(x) v[#v + 1] = x end,
      error = function(e) err_val = e end,
    })
    arr_eq(v, { 1 })
    T.eq(err_val, "oops")
  end)
end)

-- Error propagation

T.describe("error propagation", function()
  T.it("map propagates error", function()
    local o = obs.create(function(observer)
      observer:next(1)
      observer:error("err")
      observer:next(2)
    end)
    local v = {}
    local err_val = nil
    o:map(function(x) return x * 2 end):subscribe({
      next = function(x) v[#v + 1] = x end,
      error = function(e) err_val = e end,
    })
    arr_eq(v, { 2 })
    T.eq(err_val, "err")
  end)

  T.it("filter propagates error", function()
    local o = obs.create(function(observer)
      observer:error("fail")
    end)
    local err_val = nil
    o:filter(function() return true end):subscribe({
      error = function(e) err_val = e end,
    })
    T.eq(err_val, "fail")
  end)

  T.it("reduce propagates error", function()
    local o = obs.create(function(observer)
      observer:next(1)
      observer:error("bad")
    end)
    local err_val = nil
    o:reduce(0, function(a, b) return a + b end):subscribe({
      error = function(e) err_val = e end,
    })
    T.eq(err_val, "bad")
  end)
end)

-- Complete semantics

T.describe("complete semantics", function()
  T.it("no next after complete", function()
    local o = obs.create(function(observer)
      observer:next(1)
      observer:complete()
      observer:next(2)
    end)
    local v = {}
    o:subscribe({ next = function(x) v[#v + 1] = x end })
    arr_eq(v, { 1 })
  end)

  T.it("no next after error", function()
    local o = obs.create(function(observer)
      observer:next(1)
      observer:error("e")
      observer:next(2)
    end)
    local v = {}
    o:subscribe({
      next = function(x) v[#v + 1] = x end,
      error = function() end,
    })
    arr_eq(v, { 1 })
  end)

  T.it("complete called only once", function()
    local o = obs.create(function(observer)
      observer:complete()
      observer:complete()
    end)
    local count = 0
    o:subscribe({ complete = function() count = count + 1 end })
    T.eq(count, 1)
  end)
end)

-- Chained operators

T.describe("chained operators", function()
  T.it("map + filter", function()
    local v = collect(obs.of(1, 2, 3, 4, 5)
      :map(function(x) return x * 2 end)
      :filter(function(x) return x > 4 end))
    arr_eq(v, { 6, 8, 10 })
  end)

  T.it("filter + take", function()
    local v = collect(obs.of(1, 2, 3, 4, 5, 6, 7, 8)
      :filter(function(x) return x % 2 == 0 end)
      :take(2))
    arr_eq(v, { 2, 4 })
  end)

  T.it("skip + map + reduce", function()
    local v = collect(obs.of(1, 2, 3, 4, 5)
      :skip(2)
      :map(function(x) return x * 10 end)
      :reduce(0, function(a, b) return a + b end))
    arr_eq(v, { 120 })
  end)

  T.it("scan + take", function()
    local v = collect(obs.of(1, 2, 3, 4, 5)
      :scan(0, function(a, b) return a + b end)
      :take(3))
    arr_eq(v, { 1, 3, 6 })
  end)

  T.it("distinct + to_array", function()
    local v = collect(obs.from_array({ 1, 1, 2, 3, 3 }):distinct():to_array())
    T.eq(#v, 1)
    arr_eq(v[1], { 1, 2, 3 })
  end)

  T.it("flat_map + filter", function()
    local v = collect(obs.of(1, 2, 3)
      :flat_map(function(x) return obs.of(x, x * 10) end)
      :filter(function(x) return x >= 10 end))
    arr_eq(v, { 10, 20, 30 })
  end)

  T.it("map + buffer", function()
    local v = collect(obs.of(1, 2, 3, 4)
      :map(function(x) return x * 2 end)
      :buffer(2))
    T.eq(#v, 2)
    arr_eq(v[1], { 2, 4 })
    arr_eq(v[2], { 6, 8 })
  end)

  T.it("concat + map", function()
    local v = collect(obs.of(1, 2):concat(obs.of(3, 4)):map(function(x) return x + 10 end))
    arr_eq(v, { 11, 12, 13, 14 })
  end)

  T.it("take_while + scan", function()
    local v = collect(obs.of(1, 2, 3, 4, 5)
      :scan(0, function(a, b) return a + b end)
      :take_while(function(x) return x < 10 end))
    arr_eq(v, { 1, 3, 6 })
  end)

  T.it("skip_while + distinct", function()
    local v = collect(obs.from_array({ 1, 1, 2, 2, 3, 3 })
      :skip_while(function(x) return x < 2 end)
      :distinct())
    arr_eq(v, { 2, 3 })
  end)
end)
