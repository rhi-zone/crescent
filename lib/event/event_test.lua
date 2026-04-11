if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local event = require("lib.event")

-- on / emit basics
T.describe("on and emit", function()
  T.it("calls a registered listener", function()
    local e = event.new()
    local called = false
    e:on("click", function() called = true end)
    e:emit("click")
    T.ok(called)
  end)

  T.it("passes arguments to listener", function()
    local e = event.new()
    local got_a, got_b
    e:on("data", function(evt, a, b) got_a = a; got_b = b end)
    e:emit("data", 1, 2)
    T.eq(got_a, 1)
    T.eq(got_b, 2)
  end)

  T.it("passes event object as first arg", function()
    local e = event.new()
    local got_evt
    e:on("test", function(evt) got_evt = evt end)
    e:emit("test")
    T.ok(got_evt)
    T.eq(got_evt.name, "test")
  end)

  T.it("calls multiple listeners in order", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = 1 end)
    e:on("x", function() order[#order + 1] = 2 end)
    e:on("x", function() order[#order + 1] = 3 end)
    e:emit("x")
    T.eq(#order, 3)
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)

  T.it("returns true when listeners were called", function()
    local e = event.new()
    e:on("a", function() end)
    T.ok(e:emit("a"))
  end)

  T.it("returns false when no listeners", function()
    local e = event.new()
    T.eq(e:emit("nothing"), false)
  end)

  T.it("returns id from on()", function()
    local e = event.new()
    local id = e:on("a", function() end)
    T.ok(type(id) == "number")
    T.ok(id > 0)
  end)

  T.it("returns unique ids", function()
    local e = event.new()
    local id1 = e:on("a", function() end)
    local id2 = e:on("a", function() end)
    T.neq(id1, id2)
  end)
end)

-- once
T.describe("once", function()
  T.it("fires listener only once", function()
    local e = event.new()
    local count = 0
    e:once("ping", function() count = count + 1 end)
    e:emit("ping")
    e:emit("ping")
    e:emit("ping")
    T.eq(count, 1)
  end)

  T.it("removes listener after first call", function()
    local e = event.new()
    e:once("ping", function() end)
    e:emit("ping")
    T.eq(e:listener_count("ping"), 0)
  end)

  T.it("once with priority", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = "normal" end)
    e:once("x", function() order[#order + 1] = "once-high" end, { priority = 10 })
    e:emit("x")
    T.eq(order[1], "once-high")
    T.eq(order[2], "normal")
    -- second emit: once listener gone
    order = {}
    e:emit("x")
    T.eq(#order, 1)
    T.eq(order[1], "normal")
  end)
end)

-- off
T.describe("off", function()
  T.it("removes a specific listener by function", function()
    local e = event.new()
    local count = 0
    local fn = function() count = count + 1 end
    e:on("a", fn)
    e:off("a", fn)
    e:emit("a")
    T.eq(count, 0)
  end)

  T.it("removes all listeners for an event", function()
    local e = event.new()
    e:on("a", function() end)
    e:on("a", function() end)
    e:off("a")
    T.eq(e:listener_count("a"), 0)
  end)

  T.it("does not affect other events", function()
    local e = event.new()
    e:on("a", function() end)
    e:on("b", function() end)
    e:off("a")
    T.eq(e:listener_count("a"), 0)
    T.eq(e:listener_count("b"), 1)
  end)

  T.it("is safe to call off for nonexistent event", function()
    local e = event.new()
    e:off("nope")
    e:off("nope", function() end)
    T.ok(true)
  end)

  T.it("removes only the matching function", function()
    local e = event.new()
    local a_count, b_count = 0, 0
    local fn_a = function() a_count = a_count + 1 end
    local fn_b = function() b_count = b_count + 1 end
    e:on("x", fn_a)
    e:on("x", fn_b)
    e:off("x", fn_a)
    e:emit("x")
    T.eq(a_count, 0)
    T.eq(b_count, 1)
  end)
end)

-- off_by_id
T.describe("off_by_id", function()
  T.it("removes listener by id", function()
    local e = event.new()
    local count = 0
    local id = e:on("a", function() count = count + 1 end)
    T.ok(e:off_by_id(id))
    e:emit("a")
    T.eq(count, 0)
  end)

  T.it("returns false for unknown id", function()
    local e = event.new()
    T.eq(e:off_by_id(999999), false)
  end)

  T.it("only removes the specific listener", function()
    local e = event.new()
    local a, b = 0, 0
    local id1 = e:on("x", function() a = a + 1 end)
    e:on("x", function() b = b + 1 end)
    e:off_by_id(id1)
    e:emit("x")
    T.eq(a, 0)
    T.eq(b, 1)
  end)
end)

-- priority
T.describe("priority", function()
  T.it("higher priority runs first", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = "low" end, { priority = 1 })
    e:on("x", function() order[#order + 1] = "high" end, { priority = 10 })
    e:on("x", function() order[#order + 1] = "mid" end, { priority = 5 })
    e:emit("x")
    T.eq(order[1], "high")
    T.eq(order[2], "mid")
    T.eq(order[3], "low")
  end)

  T.it("same priority preserves insertion order", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = "first" end, { priority = 5 })
    e:on("x", function() order[#order + 1] = "second" end, { priority = 5 })
    e:on("x", function() order[#order + 1] = "third" end, { priority = 5 })
    e:emit("x")
    T.eq(order[1], "first")
    T.eq(order[2], "second")
    T.eq(order[3], "third")
  end)

  T.it("default priority is 0", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = "default" end)
    e:on("x", function() order[#order + 1] = "positive" end, { priority = 1 })
    e:emit("x")
    T.eq(order[1], "positive")
    T.eq(order[2], "default")
  end)

  T.it("negative priority runs after default", function()
    local e = event.new()
    local order = {}
    e:on("x", function() order[#order + 1] = "default" end)
    e:on("x", function() order[#order + 1] = "negative" end, { priority = -5 })
    e:emit("x")
    T.eq(order[1], "default")
    T.eq(order[2], "negative")
  end)
end)

-- wildcards
T.describe("wildcards", function()
  T.it("user.* matches user.login", function()
    local e = event.new()
    local called = false
    e:on("user.*", function() called = true end)
    e:emit("user.login")
    T.ok(called)
  end)

  T.it("user.* matches user.logout", function()
    local e = event.new()
    local called = false
    e:on("user.*", function() called = true end)
    e:emit("user.logout")
    T.ok(called)
  end)

  T.it("user.* does not match order.create", function()
    local e = event.new()
    local called = false
    e:on("user.*", function() called = true end)
    e:emit("order.create")
    T.eq(called, false)
  end)

  T.it("* matches any event", function()
    local e = event.new()
    local count = 0
    e:on("*", function() count = count + 1 end)
    e:emit("foo")
    e:emit("bar.baz")
    e:emit("x.y.z")
    T.eq(count, 3)
  end)

  T.it("wildcard listener receives event args", function()
    local e = event.new()
    local got
    e:on("*", function(evt, v) got = v end)
    e:emit("test", 42)
    T.eq(got, 42)
  end)

  T.it("wildcard and exact listeners both fire", function()
    local e = event.new()
    local results = {}
    e:on("click", function() results[#results + 1] = "exact" end)
    e:on("*", function() results[#results + 1] = "wild" end)
    e:emit("click")
    T.eq(#results, 2)
    T.ok(results[1] == "exact" or results[2] == "exact")
    T.ok(results[1] == "wild" or results[2] == "wild")
  end)

  T.it("exact listeners run before wildcard at same priority", function()
    local e = event.new()
    local order = {}
    e:on("*", function() order[#order + 1] = "wild" end)
    e:on("click", function() order[#order + 1] = "exact" end)
    e:emit("click")
    T.eq(order[1], "exact")
    T.eq(order[2], "wild")
  end)

  T.it("wildcard with higher priority runs before exact", function()
    local e = event.new()
    local order = {}
    e:on("click", function() order[#order + 1] = "exact" end)
    e:on("*", function() order[#order + 1] = "wild" end, { priority = 10 })
    e:emit("click")
    T.eq(order[1], "wild")
    T.eq(order[2], "exact")
  end)

  T.it("user.* does not match bare 'user'", function()
    local e = event.new()
    local called = false
    e:on("user.*", function() called = true end)
    e:emit("user")
    T.eq(called, false)
  end)

  T.it("off removes wildcard listener", function()
    local e = event.new()
    local fn = function() end
    e:on("*", fn)
    e:off("*", fn)
    T.eq(e:listener_count("*"), 0)
  end)
end)

-- stop propagation
T.describe("stop propagation", function()
  T.it("stops further listeners", function()
    local e = event.new()
    local order = {}
    e:on("x", function(evt)
      order[#order + 1] = 1
      evt:stop()
    end)
    e:on("x", function() order[#order + 1] = 2 end)
    e:emit("x")
    T.eq(#order, 1)
    T.eq(order[1], 1)
  end)

  T.it("stops wildcard listeners too", function()
    local e = event.new()
    local wild_called = false
    e:on("click", function(evt) evt:stop() end)
    e:on("*", function() wild_called = true end)
    e:emit("click")
    T.eq(wild_called, false)
  end)

  T.it("stop respects priority order", function()
    local e = event.new()
    local order = {}
    e:on("x", function(evt)
      order[#order + 1] = "high"
      evt:stop()
    end, { priority = 10 })
    e:on("x", function() order[#order + 1] = "low" end)
    e:emit("x")
    T.eq(#order, 1)
    T.eq(order[1], "high")
  end)
end)

-- listeners / listener_count / event_names
T.describe("introspection", function()
  T.it("listeners returns array of functions", function()
    local e = event.new()
    local fn1 = function() end
    local fn2 = function() end
    e:on("a", fn1)
    e:on("a", fn2)
    local ls = e:listeners("a")
    T.eq(#ls, 2)
    T.eq(ls[1], fn1)
    T.eq(ls[2], fn2)
  end)

  T.it("listeners returns empty for unknown event", function()
    local e = event.new()
    T.eq(#e:listeners("nope"), 0)
  end)

  T.it("listener_count returns correct count", function()
    local e = event.new()
    T.eq(e:listener_count("a"), 0)
    e:on("a", function() end)
    T.eq(e:listener_count("a"), 1)
    e:on("a", function() end)
    T.eq(e:listener_count("a"), 2)
  end)

  T.it("event_names returns sorted names", function()
    local e = event.new()
    e:on("zebra", function() end)
    e:on("alpha", function() end)
    e:on("mid", function() end)
    local names = e:event_names()
    T.eq(#names, 3)
    T.eq(names[1], "alpha")
    T.eq(names[2], "mid")
    T.eq(names[3], "zebra")
  end)

  T.it("event_names is empty for new emitter", function()
    local e = event.new()
    T.eq(#e:event_names(), 0)
  end)

  T.it("event_names removes names after off", function()
    local e = event.new()
    e:on("a", function() end)
    e:off("a")
    T.eq(#e:event_names(), 0)
  end)
end)

-- mixin
T.describe("mixin", function()
  T.it("adds event methods to a table", function()
    local obj = { x = 1 }
    event.mixin(obj)
    T.ok(type(obj.on) == "function")
    T.ok(type(obj.off) == "function")
    T.ok(type(obj.emit) == "function")
    T.ok(type(obj.once) == "function")
    T.ok(type(obj.listeners) == "function")
    T.ok(type(obj.listener_count) == "function")
    T.ok(type(obj.event_names) == "function")
    T.ok(type(obj.off_by_id) == "function")
  end)

  T.it("preserves existing properties", function()
    local obj = { x = 42 }
    event.mixin(obj)
    T.eq(obj.x, 42)
  end)

  T.it("mixin object can emit events", function()
    local obj = {}
    event.mixin(obj)
    local called = false
    obj:on("change", function() called = true end)
    obj:emit("change")
    T.ok(called)
  end)

  T.it("returns the target table", function()
    local obj = {}
    local ret = event.mixin(obj)
    T.eq(ret, obj)
  end)
end)

-- edge cases
T.describe("edge cases", function()
  T.it("emit with no listeners does not error", function()
    local e = event.new()
    T.eq(e:emit("nonexistent"), false)
  end)

  T.it("on returns nil,errmsg for non-string name", function()
    local e = event.new()
    local r, err = e:on(123, function() end)
    T.eq(r, nil)
    T.ok(type(err) == "string")
  end)

  T.it("on returns nil,errmsg for non-function listener", function()
    local e = event.new()
    local r, err = e:on("a", "not a function")
    T.eq(r, nil)
    T.ok(type(err) == "string")
  end)

  T.it("emit returns nil,errmsg for non-string name", function()
    local e = event.new()
    local r, err = e:emit(123)
    T.eq(r, nil)
    T.ok(type(err) == "string")
  end)

  T.it("removing a listener during emit is safe", function()
    local e = event.new()
    local fn2_called = false
    local fn1
    fn1 = function()
      e:off("x", fn1)
    end
    local fn2 = function() fn2_called = true end
    e:on("x", fn1)
    e:on("x", fn2)
    e:emit("x")
    T.ok(fn2_called)
  end)

  T.it("adding a listener during emit does not affect current emit", function()
    local e = event.new()
    local late_called = false
    e:on("x", function()
      e:on("x", function() late_called = true end)
    end)
    e:emit("x")
    T.eq(late_called, false)
  end)

  T.it("same function registered twice fires twice", function()
    local e = event.new()
    local count = 0
    local fn = function() count = count + 1 end
    e:on("x", fn)
    e:on("x", fn)
    e:emit("x")
    T.eq(count, 2)
  end)

  T.it("off with function removes all instances of that function", function()
    local e = event.new()
    local count = 0
    local fn = function() count = count + 1 end
    e:on("x", fn)
    e:on("x", fn)
    e:off("x", fn)
    e:emit("x")
    T.eq(count, 0)
  end)

  T.it("many args pass through", function()
    local e = event.new()
    local got = {}
    e:on("x", function(evt, a, b, c, d, e_arg)
      got = { a, b, c, d, e_arg }
    end)
    e:emit("x", 1, 2, 3, 4, 5)
    T.eq(got[1], 1)
    T.eq(got[2], 2)
    T.eq(got[3], 3)
    T.eq(got[4], 4)
    T.eq(got[5], 5)
  end)

  T.it("event object has correct name", function()
    local e = event.new()
    local names = {}
    e:on("*", function(evt) names[#names + 1] = evt.name end)
    e:emit("foo")
    e:emit("bar")
    T.eq(names[1], "foo")
    T.eq(names[2], "bar")
  end)

  T.it("once listener with stop propagation", function()
    local e = event.new()
    local second_called = false
    e:once("x", function(evt) evt:stop() end, { priority = 10 })
    e:on("x", function() second_called = true end)
    e:emit("x")
    T.eq(second_called, false)
    -- once is gone, second emit should call remaining listener
    second_called = false
    e:emit("x")
    T.ok(second_called)
  end)

  T.it("off_by_id for already-removed listener", function()
    local e = event.new()
    local id = e:on("a", function() end)
    e:off("a")
    T.eq(e:off_by_id(id), false)
  end)
end)

T.describe("multiple emitters are independent", function()
  T.it("events on one do not fire on another", function()
    local e1 = event.new()
    local e2 = event.new()
    local called = false
    e1:on("x", function() called = true end)
    e2:emit("x")
    T.eq(called, false)
  end)
end)
