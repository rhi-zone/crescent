if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local A = require("lib.async")

-- ── Promise basics ───────────────────────────────────────────────────────────

T.describe("promise state transitions", function()
  T.it("starts as pending", function()
    local p = A.promise()
    T.ok(p:is_pending(), "should be pending")
    T.ok(not p:is_resolved(), "not resolved")
    T.ok(not p:is_rejected(), "not rejected")
  end)

  T.it("transitions to fulfilled on resolve", function()
    local p, resolve = A.promise()
    resolve(42)
    T.ok(not p:is_pending(), "not pending")
    T.ok(p:is_resolved(), "is resolved")
    T.ok(not p:is_rejected(), "not rejected")
    T.eq(p.value, 42)
  end)

  T.it("transitions to rejected on reject", function()
    local p, _, reject = A.promise()
    reject("boom")
    T.ok(not p:is_pending(), "not pending")
    T.ok(not p:is_resolved(), "not resolved")
    T.ok(p:is_rejected(), "is rejected")
    T.eq(p.reason, "boom")
  end)

  T.it("ignores second settle after resolved", function()
    local p, resolve, reject = A.promise()
    resolve(1)
    reject("oops")
    resolve(2)
    T.ok(p:is_resolved())
    T.eq(p.value, 1)
  end)
end)

-- ── M.resolved / M.rejected ──────────────────────────────────────────────────

T.describe("M.resolved / M.rejected", function()
  T.it("M.resolved returns fulfilled promise", function()
    local p = A.resolved("hello")
    T.ok(p:is_resolved())
    T.eq(p.value, "hello")
  end)

  T.it("M.rejected returns rejected promise", function()
    local p = A.rejected("err")
    T.ok(p:is_rejected())
    T.eq(p.reason, "err")
  end)
end)

-- ── and_then ─────────────────────────────────────────────────────────────────

T.describe("and_then", function()
  T.it("chains a resolved value through handler", function()
    local result
    A.resolved(10):and_then(function(v) result = v * 2 end)
    T.eq(result, 20)
  end)

  T.it("returns a new promise with transformed value", function()
    local p = A.resolved(5):and_then(function(v) return v + 1 end)
    T.ok(p:is_resolved())
    T.eq(p.value, 6)
  end)

  T.it("flattens when handler returns a promise", function()
    local p = A.resolved(3):and_then(function(v)
      return A.resolved(v * 10)
    end)
    T.ok(p:is_resolved())
    T.eq(p.value, 30)
  end)

  T.it("propagates rejection through and_then (no handler)", function()
    local p = A.rejected("fail"):and_then(function(v) return v end)
    T.ok(p:is_rejected())
    T.eq(p.reason, "fail")
  end)

  T.it("rejects result promise when handler throws", function()
    local p = A.resolved(1):and_then(function() error("handler exploded") end)
    T.ok(p:is_rejected())
  end)

  T.it("subscribes before settle — fires when promise later resolves", function()
    local p, resolve = A.promise()
    local got
    p:and_then(function(v) got = v end)
    T.eq(got, nil)
    resolve("late")
    T.eq(got, "late")
  end)
end)

-- ── catch ────────────────────────────────────────────────────────────────────

T.describe("catch", function()
  T.it("catches a rejection", function()
    local got
    A.rejected("oops"):catch(function(r) got = r end)
    T.eq(got, "oops")
  end)

  T.it("can recover — next promise is fulfilled", function()
    local p = A.rejected("bad"):catch(function() return "recovered" end)
    T.ok(p:is_resolved())
    T.eq(p.value, "recovered")
  end)

  T.it("does not fire on fulfilled promise", function()
    local fired = false
    A.resolved(1):catch(function() fired = true end)
    T.ok(not fired)
  end)

  T.it("passes fulfillment through catch unchanged", function()
    local p = A.resolved(99):catch(function() return 0 end)
    T.ok(p:is_resolved())
    T.eq(p.value, 99)
  end)
end)

-- ── finally ──────────────────────────────────────────────────────────────────

T.describe("finally", function()
  T.it("called on fulfillment", function()
    local called = false
    local p = A.resolved("x"):finally(function() called = true end)
    T.ok(called)
    T.ok(p:is_resolved())
    T.eq(p.value, "x")
  end)

  T.it("called on rejection", function()
    local called = false
    local p = A.rejected("y"):finally(function() called = true end)
    T.ok(called)
    T.ok(p:is_rejected())
    T.eq(p.reason, "y")
  end)

  T.it("preserves fulfillment value", function()
    local p = A.resolved(7):finally(function() end)
    T.eq(p.value, 7)
  end)

  T.it("preserves rejection reason", function()
    local p = A.rejected("z"):finally(function() end)
    T.eq(p.reason, "z")
  end)

  T.it("fires for pending promise when it later settles", function()
    local p2, resolve = A.promise()
    local called = false
    p2:finally(function() called = true end)
    T.ok(not called)
    resolve(1)
    T.ok(called)
  end)
end)

-- ── M.all ────────────────────────────────────────────────────────────────────

T.describe("M.all", function()
  T.it("resolves with array of values when all fulfill", function()
    local p = A.all({ A.resolved(1), A.resolved(2), A.resolved(3) })
    T.ok(p:is_resolved())
    T.eq(p.value[1], 1)
    T.eq(p.value[2], 2)
    T.eq(p.value[3], 3)
  end)

  T.it("rejects on first rejection", function()
    local p = A.all({ A.resolved(1), A.rejected("bad"), A.resolved(3) })
    T.ok(p:is_rejected())
    T.eq(p.reason, "bad")
  end)

  T.it("empty array resolves immediately", function()
    local p = A.all({})
    T.ok(p:is_resolved())
    T.eq(#p.value, 0)
  end)

  T.it("preserves order with async resolution", function()
    local p1, r1 = A.promise()
    local p2, r2 = A.promise()
    local all_p = A.all({ p1, p2 })
    r2("second")
    r1("first")
    T.ok(all_p:is_resolved())
    T.eq(all_p.value[1], "first")
    T.eq(all_p.value[2], "second")
  end)
end)

-- ── M.race ───────────────────────────────────────────────────────────────────

T.describe("M.race", function()
  T.it("resolves with first fulfillment", function()
    local p1, r1 = A.promise()
    local p2, r2 = A.promise()
    local rp = A.race({ p1, p2 })
    r1("winner")
    T.ok(rp:is_resolved())
    T.eq(rp.value, "winner")
  end)

  T.it("ignores later settlements after first", function()
    local p1, r1 = A.promise()
    local p2, r2 = A.promise()
    local rp = A.race({ p1, p2 })
    r1("first")
    r2("second")
    T.ok(rp:is_resolved())
    T.eq(rp.value, "first")
  end)

  T.it("rejects when first promise rejects", function()
    local p1, _, rej1 = A.promise()
    local p2, r2 = A.promise()
    local rp = A.race({ p1, p2 })
    rej1("fast reject")
    T.ok(rp:is_rejected())
    T.eq(rp.reason, "fast reject")
  end)

  T.it("handles already-resolved promises", function()
    local rp = A.race({ A.resolved("quick"), A.resolved("slow") })
    T.ok(rp:is_resolved())
    T.eq(rp.value, "quick")
  end)
end)

-- ── M.any ────────────────────────────────────────────────────────────────────

T.describe("M.any", function()
  T.it("resolves with first fulfillment", function()
    local p1, _, rej1 = A.promise()
    local p2, r2 = A.promise()
    local ap = A.any({ p1, p2 })
    rej1("nope")
    r2("yes")
    T.ok(ap:is_resolved())
    T.eq(ap.value, "yes")
  end)

  T.it("rejects with aggregate when all reject", function()
    local p = A.any({ A.rejected("e1"), A.rejected("e2") })
    T.ok(p:is_rejected())
    T.ok(type(p.reason) == "table", "reason is aggregate table")
    T.eq(p.reason.errors[1], "e1")
    T.eq(p.reason.errors[2], "e2")
  end)

  T.it("empty array rejects immediately", function()
    local p = A.any({})
    T.ok(p:is_rejected())
  end)
end)

-- ── M.all_settled ────────────────────────────────────────────────────────────

T.describe("M.all_settled", function()
  T.it("always resolves", function()
    local p = A.all_settled({ A.resolved(1), A.rejected("e"), A.resolved(3) })
    T.ok(p:is_resolved())
    T.eq(#p.value, 3)
  end)

  T.it("fulfilled entry has status and value", function()
    local p = A.all_settled({ A.resolved(42) })
    T.eq(p.value[1].status, "fulfilled")
    T.eq(p.value[1].value, 42)
  end)

  T.it("rejected entry has status and reason", function()
    local p = A.all_settled({ A.rejected("bad") })
    T.eq(p.value[1].status, "rejected")
    T.eq(p.value[1].reason, "bad")
  end)

  T.it("empty array resolves with empty table", function()
    local p = A.all_settled({})
    T.ok(p:is_resolved())
    T.eq(#p.value, 0)
  end)
end)

-- ── M.defer ──────────────────────────────────────────────────────────────────

T.describe("M.defer", function()
  T.it("resolves with fn return value", function()
    local p = A.defer(function() return "deferred" end)
    T.ok(p:is_resolved())
    T.eq(p.value, "deferred")
  end)

  T.it("rejects when fn raises", function()
    local p = A.defer(function() error("bad defer") end)
    T.ok(p:is_rejected())
  end)
end)

-- ── Event loop ───────────────────────────────────────────────────────────────

T.describe("event loop queue / tick", function()
  T.it("runs queued functions on tick", function()
    local lp = A.loop()
    local log = {}
    lp:queue(function() log[#log + 1] = "a" end)
    lp:queue(function() log[#log + 1] = "b" end)
    T.eq(#log, 0)
    lp:tick()
    T.eq(log[1], "a")
    T.eq(log[2], "b")
  end)

  T.it("respects FIFO order", function()
    local lp = A.loop()
    local order = {}
    for i = 1, 5 do
      local n = i
      lp:queue(function() order[#order + 1] = n end)
    end
    lp:tick()
    for i = 1, 5 do T.eq(order[i], i) end
  end)

  T.it("clear removes all queued fns", function()
    local lp = A.loop()
    local ran = false
    lp:queue(function() ran = true end)
    lp:clear()
    lp:tick()
    T.ok(not ran)
  end)

  T.it("re-queued fns run on next tick", function()
    local lp = A.loop()
    local count = 0
    local function inc()
      count = count + 1
      if count < 3 then lp:queue(inc) end
    end
    lp:queue(inc)
    lp:tick()
    T.eq(count, 1)
    lp:tick()
    T.eq(count, 2)
    lp:tick()
    T.eq(count, 3)
  end)
end)

-- ── Sleep ────────────────────────────────────────────────────────────────────

T.describe("loop:sleep", function()
  T.it("does not resolve before deadline", function()
    local lp = A.loop()
    local p = lp:sleep(100)
    T.ok(p:is_pending())
    lp:tick(50)
    T.ok(p:is_pending())
  end)

  T.it("resolves at or after deadline", function()
    local lp = A.loop()
    local p = lp:sleep(100)
    lp:tick(100)
    T.ok(p:is_resolved())
  end)

  T.it("multiple sleeps resolve in order", function()
    local lp = A.loop()
    local p1 = lp:sleep(50)
    local p2 = lp:sleep(150)
    lp:tick(100)
    T.ok(p1:is_resolved(), "p1 resolved at 100ms")
    T.ok(p2:is_pending(), "p2 still pending at 100ms")
    lp:tick(60)
    T.ok(p2:is_resolved(), "p2 resolved at 160ms")
  end)
end)

-- ── M.run ────────────────────────────────────────────────────────────────────

T.describe("M.run", function()
  T.it("drives a simple resolved promise", function()
    local val, err = A.run(A.resolved(123))
    T.eq(err, nil)
    T.eq(val, 123)
  end)

  T.it("returns nil, reason for rejected promise", function()
    local val, err = A.run(A.rejected("problem"))
    T.eq(val, nil)
    T.eq(err, "problem")
  end)

  T.it("accepts a function", function()
    local val, err = A.run(function() return A.resolved("from fn") end)
    T.eq(err, nil)
    T.eq(val, "from fn")
  end)

  T.it("drives a chain", function()
    local p = A.resolved(1)
      :and_then(function(v) return v + 1 end)
      :and_then(function(v) return v * 3 end)
    local val, err = A.run(p)
    T.eq(err, nil)
    T.eq(val, 6)
  end)
end)

-- ── M.async + M.await ────────────────────────────────────────────────────────

T.describe("M.async + M.await", function()
  T.it("async fn returns a promise", function()
    local fn = A.async(function() return 42 end)
    local p = fn()
    T.ok(type(p) == "table" and p._state ~= nil, "is a promise")
    T.ok(p:is_resolved())
    T.eq(p.value, 42)
  end)

  T.it("await inside async fn waits for already-resolved promise", function()
    local fn = A.async(function()
      local v = A.await(A.resolved(7))
      return v * 2
    end)
    local val, err = A.run(fn())
    T.eq(err, nil)
    T.eq(val, 14)
  end)

  T.it("await propagates rejection as error", function()
    local fn = A.async(function()
      A.await(A.rejected("fail inside"))
      return "should not reach"
    end)
    local val, err = A.run(fn())
    T.eq(val, nil)
    T.ok(err ~= nil, "got an error")
  end)

  T.it("await on pending promise suspends coroutine", function()
    local p1, resolve1 = A.promise()
    local fn = A.async(function()
      local v = A.await(p1)
      return v + 100
    end)
    local result_p = fn()
    T.ok(result_p:is_pending(), "result not ready yet")
    resolve1(5)
    T.ok(result_p:is_resolved(), "resolved after p1 settled")
    T.eq(result_p.value, 105)
  end)

  T.it("await can chain multiple promises sequentially", function()
    local fn = A.async(function()
      local a = A.await(A.resolved(10))
      local b = A.await(A.resolved(20))
      return a + b
    end)
    local val, err = A.run(fn())
    T.eq(err, nil)
    T.eq(val, 30)
  end)

  T.it("async fn can call another async fn", function()
    local inner = A.async(function(x)
      return A.await(A.resolved(x * 2))
    end)
    local outer = A.async(function()
      local v = A.await(inner(5))
      return v + 1
    end)
    local val, err = A.run(outer())
    T.eq(err, nil)
    T.eq(val, 11)
  end)

  T.it("async fn with no yield resolves immediately", function()
    local fn = A.async(function(a, b) return a + b end)
    local p = fn(3, 4)
    T.ok(p:is_resolved())
    T.eq(p.value, 7)
  end)

  T.it("async fn receives multiple arguments", function()
    local fn = A.async(function(a, b, c) return a .. b .. c end)
    local p = fn("x", "y", "z")
    T.ok(p:is_resolved())
    T.eq(p.value, "xyz")
  end)
end)

-- ── loop:run_until ───────────────────────────────────────────────────────────

T.describe("loop:run_until", function()
  T.it("runs until promise resolves via queue", function()
    local lp = A.loop()
    local p, resolve = A.promise()
    lp:queue(function() resolve("done") end)
    local val, err = lp:run_until(p)
    T.eq(err, nil)
    T.eq(val, "done")
  end)

  T.it("returns nil, reason for rejected promise", function()
    local lp = A.loop()
    local p, _, reject = A.promise()
    lp:queue(function() reject("bad") end)
    local val, err = lp:run_until(p)
    T.eq(val, nil)
    T.eq(err, "bad")
  end)
end)
