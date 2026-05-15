if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local Obs = require("lib.observer")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function collect(obs)
  local result = {}
  local err_msg
  local completed = false
  obs:subscribe({
    next     = function(v) result[#result + 1] = v end,
    error    = function(e) err_msg = e end,
    complete = function()  completed = true end,
  })
  return result, err_msg, completed
end

-- ---------------------------------------------------------------------------
-- Factory constructors
-- ---------------------------------------------------------------------------

T.describe("Obs.of", function()
  T.it("emits each argument in order", function()
    local vals, _, done = collect(Obs.of(10, 20, 30))
    T.eq(#vals, 3)
    T.eq(vals[1], 10)
    T.eq(vals[2], 20)
    T.eq(vals[3], 30)
    T.ok(done)
  end)

  T.it("emits nothing when called with no args", function()
    local vals, _, done = collect(Obs.of())
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("Obs.from", function()
  T.it("emits each element of an array", function()
    local vals, _, done = collect(Obs.from({ 1, 2, 3, 4, 5 }))
    T.eq(#vals, 5)
    T.eq(vals[3], 3)
    T.ok(done)
  end)

  T.it("emits nothing for empty table", function()
    local vals, _, done = collect(Obs.from({}))
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("Obs.range", function()
  T.it("emits integers start..stop inclusive", function()
    local vals = collect(Obs.range(1, 5))
    T.eq(#vals, 5)
    T.eq(vals[1], 1)
    T.eq(vals[5], 5)
  end)

  T.it("emits single value when start == stop", function()
    local vals = collect(Obs.range(3, 3))
    T.eq(#vals, 1)
    T.eq(vals[1], 3)
  end)

  T.it("supports custom step", function()
    local vals = collect(Obs.range(0, 10, 2))
    T.eq(#vals, 6) -- 0,2,4,6,8,10
    T.eq(vals[1], 0)
    T.eq(vals[6], 10)
  end)
end)

T.describe("Obs.empty", function()
  T.it("completes without emitting values", function()
    local vals, _, done = collect(Obs.empty())
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("Obs.never", function()
  T.it("neither emits nor completes", function()
    local vals, _, done = collect(Obs.never())
    T.eq(#vals, 0)
    T.fail(done)
  end)
end)

T.describe("Obs.error", function()
  T.it("delivers error to subscriber", function()
    local vals, err, done = collect(Obs.error("something went wrong"))
    T.eq(#vals, 0)
    T.eq(err, "something went wrong")
    T.fail(done)
  end)
end)

T.describe("Obs.create", function()
  T.it("allows custom push logic", function()
    local obs = Obs.create(function(s)
      s:next(100)
      s:next(200)
      s:complete()
    end)
    local vals, _, done = collect(obs)
    T.eq(#vals, 2)
    T.eq(vals[1], 100)
    T.eq(vals[2], 200)
    T.ok(done)
  end)

  T.it("can emit an error", function()
    local obs = Obs.create(function(s)
      s:next(1)
      s:error("fail!")
    end)
    local vals, err = collect(obs)
    T.eq(#vals, 1)
    T.eq(err, "fail!")
  end)
end)

T.describe("Obs.defer", function()
  T.it("creates observable lazily per subscription", function()
    local call_count = 0
    local deferred = Obs.defer(function()
      call_count = call_count + 1
      return Obs.from({ call_count })
    end)
    T.eq(call_count, 0)
    local a = collect(deferred)
    T.eq(call_count, 1)
    T.eq(a[1], 1)
    local b = collect(deferred)
    T.eq(call_count, 2)
    T.eq(b[1], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Subscribe variants
-- ---------------------------------------------------------------------------

T.describe("subscribe", function()
  T.it("accepts function shorthand for next", function()
    local got = {}
    Obs.of(1, 2, 3):subscribe(function(v) got[#got + 1] = v end)
    T.eq(#got, 3)
  end)

  T.it("subscribe returns subscription with unsubscribe", function()
    local got = {}
    local obs = Obs.create(function(s)
      s:next(1)
      s:next(2)
      s:next(3)
      s:complete()
    end)
    local sub = obs:subscribe({ next = function(v) got[#got + 1] = v end })
    T.ok(sub.unsubscribe)
  end)
end)

T.describe("unsubscribe", function()
  T.it("stops receiving values after unsubscription", function()
    local got = {}
    local sub_ref
    local obs = Obs.create(function(s)
      s:next(1)
      -- In synchronous context, unsubscribe during emission
      s:next(2)
      s:next(3)
    end)
    -- Test by subscribing to a subject and unsubscribing mid-sequence
    local subj = Obs.subject()
    sub_ref = subj:subscribe(function(v)
      got[#got + 1] = v
      if v == 2 then sub_ref:unsubscribe() end
    end)
    subj:next(1)
    subj:next(2)
    subj:next(3)  -- should not be received
    T.eq(#got, 2)
    T.eq(got[1], 1)
    T.eq(got[2], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Operators
-- ---------------------------------------------------------------------------

T.describe("map", function()
  T.it("transforms each value", function()
    local vals = collect(Obs.from({ 1, 2, 3 }):map(function(v) return v * 2 end))
    T.eq(vals[1], 2)
    T.eq(vals[2], 4)
    T.eq(vals[3], 6)
  end)

  T.it("propagates error", function()
    local _, err = collect(Obs.error("boom"):map(function(v) return v end))
    T.eq(err, "boom")
  end)
end)

T.describe("filter", function()
  T.it("keeps only matching values", function()
    local vals = collect(Obs.range(1, 6):filter(function(v) return v % 2 == 0 end))
    T.eq(#vals, 3)
    T.eq(vals[1], 2)
    T.eq(vals[2], 4)
    T.eq(vals[3], 6)
  end)
end)

T.describe("take", function()
  T.it("emits only first n values", function()
    local vals, _, done = collect(Obs.range(1, 100):take(3))
    T.eq(#vals, 3)
    T.eq(vals[3], 3)
    T.ok(done)
  end)

  T.it("take(0) emits nothing but completes", function()
    local vals, _, done = collect(Obs.range(1, 5):take(0))
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("drop", function()
  T.it("skips first n values", function()
    local vals = collect(Obs.range(1, 5):drop(2))
    T.eq(#vals, 3)
    T.eq(vals[1], 3)
  end)

  T.it("drop(0) passes all values through", function()
    local vals = collect(Obs.range(1, 3):drop(0))
    T.eq(#vals, 3)
  end)
end)

T.describe("take_while", function()
  T.it("emits while predicate is true, then stops", function()
    local vals, _, done = collect(Obs.range(1, 10):take_while(function(v) return v < 5 end))
    T.eq(#vals, 4)
    T.eq(vals[4], 4)
    T.ok(done)
  end)
end)

T.describe("drop_while", function()
  T.it("drops values while predicate is true", function()
    local vals = collect(Obs.range(1, 6):drop_while(function(v) return v < 4 end))
    T.eq(#vals, 3)
    T.eq(vals[1], 4)
  end)
end)

T.describe("flat_map / merge_map", function()
  T.it("maps each value to inner observable and merges", function()
    local vals = collect(Obs.of(1, 2, 3):flat_map(function(v)
      return Obs.of(v * 10, v * 10 + 1)
    end))
    T.eq(#vals, 6)
    T.eq(vals[1], 10)
    T.eq(vals[2], 11)
    T.eq(vals[3], 20)
    T.eq(vals[4], 21)
  end)

  T.it("merge_map is an alias for flat_map", function()
    local vals = collect(Obs.of(1, 2):merge_map(function(v) return Obs.of(v) end))
    T.eq(#vals, 2)
  end)

  T.it("propagates inner error", function()
    local _, err = collect(Obs.of(1):flat_map(function(_)
      return Obs.error("inner err")
    end))
    T.eq(err, "inner err")
  end)
end)

T.describe("concat_map", function()
  T.it("subscribes to inner observables sequentially", function()
    local vals = collect(Obs.of(1, 2, 3):concat_map(function(v)
      return Obs.of(v, v * 100)
    end))
    T.eq(#vals, 6)
    T.eq(vals[1], 1)
    T.eq(vals[2], 100)
    T.eq(vals[3], 2)
    T.eq(vals[4], 200)
  end)
end)

T.describe("reduce", function()
  T.it("emits single accumulated value on complete", function()
    local vals, _, done = collect(Obs.range(1, 5):reduce(function(acc, v) return acc + v end, 0))
    T.eq(#vals, 1)
    T.eq(vals[1], 15)
    T.ok(done)
  end)

  T.it("emits seed when source is empty", function()
    local vals = collect(Obs.empty():reduce(function(acc, v) return acc + v end, 42))
    T.eq(#vals, 1)
    T.eq(vals[1], 42)
  end)
end)

T.describe("scan", function()
  T.it("emits running accumulator for each value", function()
    local vals = collect(Obs.range(1, 4):scan(function(acc, v) return acc + v end, 0))
    T.eq(#vals, 4)
    T.eq(vals[1], 1)
    T.eq(vals[2], 3)
    T.eq(vals[3], 6)
    T.eq(vals[4], 10)
  end)
end)

T.describe("distinct / distinct_until_changed", function()
  T.it("suppresses consecutive duplicates", function()
    local vals = collect(Obs.from({ 1, 1, 2, 2, 3, 1, 1 }):distinct())
    T.eq(#vals, 4)
    T.eq(vals[1], 1)
    T.eq(vals[2], 2)
    T.eq(vals[3], 3)
    T.eq(vals[4], 1)
  end)

  T.it("distinct_until_changed is an alias", function()
    local vals = collect(Obs.from({ 5, 5, 6 }):distinct_until_changed())
    T.eq(#vals, 2)
  end)
end)

T.describe("do_next / do_error / do_complete", function()
  T.it("do_next calls side effect and passes value through", function()
    local side = {}
    local vals = collect(Obs.of(1, 2, 3):do_next(function(v) side[#side + 1] = v end))
    T.eq(#side, 3)
    T.eq(#vals, 3)
    T.eq(vals[2], 2)
  end)

  T.it("do_error calls side effect on error", function()
    local got_err
    local _, err = collect(Obs.error("oops"):do_error(function(e) got_err = e end))
    T.eq(got_err, "oops")
    T.eq(err, "oops")
  end)

  T.it("do_complete calls side effect on completion", function()
    local done_called = false
    local _, _, done = collect(Obs.empty():do_complete(function() done_called = true end))
    T.ok(done_called)
    T.ok(done)
  end)
end)

T.describe("catch", function()
  T.it("replaces error stream with recovery observable", function()
    local vals, err, done = collect(
      Obs.error("bad"):catch(function(_) return Obs.of(99, 100) end)
    )
    T.eq(#vals, 2)
    T.eq(vals[1], 99)
    T.eq(vals[2], 100)
    T.fail(err)
    T.ok(done)
  end)

  T.it("passes through values when no error", function()
    local vals = collect(
      Obs.of(1, 2):catch(function(_) return Obs.of(99) end)
    )
    T.eq(#vals, 2)
    T.eq(vals[1], 1)
  end)

  T.it("receives error message in handler", function()
    local received_err
    collect(Obs.error("details"):catch(function(e)
      received_err = e
      return Obs.empty()
    end))
    T.eq(received_err, "details")
  end)
end)

T.describe("retry", function()
  T.it("re-subscribes on error up to n times", function()
    local attempts = 0
    local obs = Obs.create(function(s)
      attempts = attempts + 1
      if attempts < 3 then
        s:error("retry me")
      else
        s:next(42)
        s:complete()
      end
    end)
    local vals, err = collect(obs:retry(5))
    T.eq(attempts, 3)
    T.eq(#vals, 1)
    T.eq(vals[1], 42)
    T.fail(err)
  end)

  T.it("propagates error after exhausting retries", function()
    local obs = Obs.create(function(s) s:error("persistent") end)
    local _, err = collect(obs:retry(2))
    T.eq(err, "persistent")
  end)
end)

T.describe("timeout", function()
  T.it("passes values through when within deadline", function()
    local clock = 0
    local vals = collect(Obs.of(1, 2, 3):timeout(100, function() return clock end))
    T.eq(#vals, 3)
  end)

  T.it("errors when clock exceeds deadline", function()
    local clock = 0
    local obs = Obs.create(function(s)
      s:next(1)
      clock = 200  -- advance past deadline
      s:next(2)
    end)
    local vals, err = collect(obs:timeout(100, function() return clock end))
    T.eq(#vals, 1)
    T.eq(err, "timeout")
  end)
end)

T.describe("default_if_empty", function()
  T.it("emits default when source completes without values", function()
    local vals, _, done = collect(Obs.empty():default_if_empty(99))
    T.eq(#vals, 1)
    T.eq(vals[1], 99)
    T.ok(done)
  end)

  T.it("does not emit default when source has values", function()
    local vals = collect(Obs.of(1, 2):default_if_empty(99))
    T.eq(#vals, 2)
    T.eq(vals[1], 1)
  end)
end)

T.describe("first", function()
  T.it("emits only the first value", function()
    local vals, _, done = collect(Obs.range(1, 100):first())
    T.eq(#vals, 1)
    T.eq(vals[1], 1)
    T.ok(done)
  end)
end)

T.describe("last", function()
  T.it("emits only the last value on complete", function()
    local vals, _, done = collect(Obs.range(1, 5):last())
    T.eq(#vals, 1)
    T.eq(vals[1], 5)
    T.ok(done)
  end)

  T.it("emits nothing when source is empty", function()
    local vals, _, done = collect(Obs.empty():last())
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("to_array", function()
  T.it("returns all values as array", function()
    local arr = Obs.range(1, 4):to_array()
    T.eq(#arr, 4)
    T.eq(arr[1], 1)
    T.eq(arr[4], 4)
  end)

  T.it("returns nil, errmsg on error", function()
    local arr, err = Obs.error("fail"):to_array()
    T.fail(arr)
    T.eq(err, "fail")
  end)
end)

T.describe("count", function()
  T.it("emits count of values", function()
    local vals = collect(Obs.range(1, 7):count())
    T.eq(#vals, 1)
    T.eq(vals[1], 7)
  end)

  T.it("emits 0 for empty source", function()
    local vals = collect(Obs.empty():count())
    T.eq(vals[1], 0)
  end)
end)

T.describe("sum", function()
  T.it("emits sum of all values", function()
    local vals = collect(Obs.from({ 1, 2, 3, 4 }):sum())
    T.eq(vals[1], 10)
  end)
end)

T.describe("min", function()
  T.it("emits minimum value", function()
    local vals = collect(Obs.from({ 5, 2, 8, 1, 9 }):min())
    T.eq(vals[1], 1)
  end)

  T.it("emits nothing for empty source", function()
    local vals, _, done = collect(Obs.empty():min())
    T.eq(#vals, 0)
    T.ok(done)
  end)
end)

T.describe("max", function()
  T.it("emits maximum value", function()
    local vals = collect(Obs.from({ 5, 2, 8, 1, 9 }):max())
    T.eq(vals[1], 9)
  end)
end)

-- ---------------------------------------------------------------------------
-- Error propagation
-- ---------------------------------------------------------------------------

T.describe("error propagation", function()
  T.it("map propagates source error to observer", function()
    local _, err = collect(Obs.error("source err"):map(function(v) return v end))
    T.eq(err, "source err")
  end)

  T.it("filter propagates source error", function()
    local _, err = collect(Obs.error("e"):filter(function() return true end))
    T.eq(err, "e")
  end)

  T.it("take propagates error", function()
    local _, err = collect(Obs.error("e"):take(3))
    T.eq(err, "e")
  end)

  T.it("chained operators propagate error", function()
    local _, err = collect(
      Obs.error("chain"):map(function(v) return v end):filter(function() return true end)
    )
    T.eq(err, "chain")
  end)
end)

-- ---------------------------------------------------------------------------
-- Combining
-- ---------------------------------------------------------------------------

T.describe("Obs.merge", function()
  T.it("interleaves values from multiple observables", function()
    local vals, _, done = collect(Obs.merge(Obs.of(1, 2), Obs.of(3, 4)))
    T.eq(#vals, 4)
    T.ok(done)
  end)

  T.it("completes only when all sources complete", function()
    local _, _, done = collect(Obs.merge(Obs.of(1), Obs.never()))
    T.fail(done)
  end)

  T.it("propagates error from any source", function()
    local _, err = collect(Obs.merge(Obs.of(1), Obs.error("merge err")))
    T.eq(err, "merge err")
  end)
end)

T.describe("Obs.concat", function()
  T.it("subscribes to sources sequentially", function()
    local vals, _, done = collect(Obs.concat(Obs.of(1, 2), Obs.of(3, 4)))
    T.eq(#vals, 4)
    T.eq(vals[1], 1)
    T.eq(vals[3], 3)
    T.ok(done)
  end)

  T.it("handles empty sources", function()
    local vals = collect(Obs.concat(Obs.empty(), Obs.of(5), Obs.empty()))
    T.eq(#vals, 1)
    T.eq(vals[1], 5)
  end)
end)

T.describe("Obs.zip", function()
  T.it("pairs values by index as arrays", function()
    local vals = collect(Obs.zip(Obs.of(1, 2, 3), Obs.of("a", "b", "c")))
    T.eq(#vals, 3)
    T.eq(vals[1][1], 1)
    T.eq(vals[1][2], "a")
    T.eq(vals[2][1], 2)
  end)

  T.it("stops when shorter source completes", function()
    local vals = collect(Obs.zip(Obs.of(1, 2), Obs.of("a", "b", "c")))
    T.eq(#vals, 2)
  end)

  T.it("accepts optional combine function", function()
    local vals = collect(Obs.zip(Obs.of(1, 2), Obs.of(10, 20), function(a, b) return a + b end))
    T.eq(vals[1], 11)
    T.eq(vals[2], 22)
  end)
end)

T.describe("Obs.combine_latest", function()
  T.it("emits array of latest values when any source updates", function()
    local subj1 = Obs.subject()
    local subj2 = Obs.subject()
    local vals = {}
    Obs.combine_latest(subj1, subj2):subscribe(function(v) vals[#vals + 1] = v end)
    subj1:next(1)      -- only subj1 has value, no emit
    subj2:next("a")    -- both have values, emit {1,"a"}
    subj1:next(2)      -- emit {2,"a"}
    T.eq(#vals, 2)
    T.eq(vals[1][1], 1)
    T.eq(vals[1][2], "a")
    T.eq(vals[2][1], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Subject
-- ---------------------------------------------------------------------------

T.describe("subject (hot observable)", function()
  T.it("new subscribers miss past values", function()
    local subj = Obs.subject()
    local got = {}
    subj:next(1)  -- before subscribe
    subj:next(2)
    subj:subscribe(function(v) got[#got + 1] = v end)
    subj:next(3)
    T.eq(#got, 1)
    T.eq(got[1], 3)
  end)

  T.it("multicasts to multiple subscribers", function()
    local subj = Obs.subject()
    local a, b = {}, {}
    subj:subscribe(function(v) a[#a + 1] = v end)
    subj:subscribe(function(v) b[#b + 1] = v end)
    subj:next(42)
    T.eq(a[1], 42)
    T.eq(b[1], 42)
  end)

  T.it("complete notifies all subscribers", function()
    local subj = Obs.subject()
    local done_count = 0
    subj:subscribe({ complete = function() done_count = done_count + 1 end })
    subj:subscribe({ complete = function() done_count = done_count + 1 end })
    subj:complete()
    T.eq(done_count, 2)
  end)

  T.it("error notifies all subscribers", function()
    local subj = Obs.subject()
    local errs = {}
    subj:subscribe({ error = function(e) errs[#errs + 1] = e end })
    subj:subscribe({ error = function(e) errs[#errs + 1] = e end })
    subj:error("subj err")
    T.eq(#errs, 2)
    T.eq(errs[1], "subj err")
  end)

  T.it("unsubscribe stops receiving values", function()
    local subj = Obs.subject()
    local got = {}
    local sub = subj:subscribe(function(v) got[#got + 1] = v end)
    subj:next(1)
    sub:unsubscribe()
    subj:next(2)
    T.eq(#got, 1)
  end)

  T.it("after complete, new subscriber gets complete immediately", function()
    local subj = Obs.subject()
    subj:complete()
    local done = false
    subj:subscribe({ complete = function() done = true end })
    T.ok(done)
  end)
end)

-- ---------------------------------------------------------------------------
-- BehaviorSubject
-- ---------------------------------------------------------------------------

T.describe("behavior_subject", function()
  T.it("emits current value to new subscriber immediately", function()
    local bs = Obs.behavior_subject(0)
    bs:next(1)
    bs:next(5)
    local got = {}
    bs:subscribe(function(v) got[#got + 1] = v end)
    T.eq(got[1], 5)
  end)

  T.it("initial value emitted to first subscriber", function()
    local bs = Obs.behavior_subject(42)
    local got = {}
    bs:subscribe(function(v) got[#got + 1] = v end)
    T.eq(got[1], 42)
  end)

  T.it("subsequent values delivered to all subscribers", function()
    local bs = Obs.behavior_subject(0)
    local a, b = {}, {}
    bs:subscribe(function(v) a[#a + 1] = v end)
    bs:subscribe(function(v) b[#b + 1] = v end)
    bs:next(7)
    -- a: received 0 (initial) then 7
    -- b: received 0 (initial) then 7
    T.eq(a[1], 0)
    T.eq(a[2], 7)
    T.eq(b[2], 7)
  end)

  T.it("get_value returns current value", function()
    local bs = Obs.behavior_subject(10)
    T.eq(bs:get_value(), 10)
    bs:next(20)
    T.eq(bs:get_value(), 20)
  end)

  T.it("after complete, new subscriber gets last value then complete", function()
    local bs = Obs.behavior_subject(99)
    bs:complete()
    local got = {}
    local done = false
    bs:subscribe({
      next     = function(v) got[#got + 1] = v end,
      complete = function()  done = true end,
    })
    T.eq(got[1], 99)
    T.ok(done)
  end)
end)

T.describe("replay_subject", function()
  T.it("new subscriber receives all buffered values", function()
    local rs = Obs.replay_subject(10)
    rs:next(1)
    rs:next(2)
    rs:next(3)
    local got = {}
    rs:subscribe(function(v) got[#got + 1] = v end)
    T.eq(got[1], 1)
    T.eq(got[2], 2)
    T.eq(got[3], 3)
  end)

  T.it("buffer is bounded to size n", function()
    local rs = Obs.replay_subject(2)
    rs:next(1)
    rs:next(2)
    rs:next(3)
    local got = {}
    rs:subscribe(function(v) got[#got + 1] = v end)
    T.eq(#got, 2)
    T.eq(got[1], 2)
    T.eq(got[2], 3)
  end)

  T.it("late subscriber receives buffered values then live values", function()
    local rs = Obs.replay_subject(5)
    rs:next("a")
    local got = {}
    rs:subscribe(function(v) got[#got + 1] = v end)
    rs:next("b")
    T.eq(got[1], "a")
    T.eq(got[2], "b")
  end)

  T.it("after complete, new subscriber gets buffered values then complete", function()
    local rs = Obs.replay_subject(3)
    rs:next(10)
    rs:next(20)
    rs:complete()
    local got = {}
    local done = false
    rs:subscribe({
      next = function(v) got[#got + 1] = v end,
      complete = function() done = true end,
    })
    T.eq(got[1], 10)
    T.eq(got[2], 20)
    T.ok(done)
  end)

  T.it("after error, new subscriber gets buffered values then error", function()
    local rs = Obs.replay_subject(3)
    rs:next(1)
    rs:error("boom")
    local got = {}
    local err
    rs:subscribe({
      next = function(v) got[#got + 1] = v end,
      error = function(e) err = e end,
    })
    T.eq(got[1], 1)
    T.eq(err, "boom")
  end)

  T.it("nil n means unbounded buffer", function()
    local rs = Obs.replay_subject()
    for i = 1, 50 do rs:next(i) end
    local got = {}
    rs:subscribe(function(v) got[#got + 1] = v end)
    T.eq(#got, 50)
    T.eq(got[1], 1)
    T.eq(got[50], 50)
  end)

  T.it("values emitted after subscribe are delivered", function()
    local rs = Obs.replay_subject(2)
    local got = {}
    rs:subscribe(function(v) got[#got + 1] = v end)
    rs:next(1)
    rs:next(2)
    T.eq(got[1], 1)
    T.eq(got[2], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Chaining / composition
-- ---------------------------------------------------------------------------

T.describe("operator chaining", function()
  T.it("map + filter + take compose correctly", function()
    local vals = collect(
      Obs.range(1, 20)
        :map(function(v) return v * v end)
        :filter(function(v) return v % 2 == 0 end)
        :take(3)
    )
    -- squares: 1,4,9,16,25,36... even squares: 4,16,36...
    T.eq(#vals, 3)
    T.eq(vals[1], 4)
    T.eq(vals[2], 16)
    T.eq(vals[3], 36)
  end)

  T.it("scan + last gives final accumulator", function()
    local vals = collect(
      Obs.range(1, 5):scan(function(acc, v) return acc + v end, 0):last()
    )
    T.eq(vals[1], 15)
  end)
end)
