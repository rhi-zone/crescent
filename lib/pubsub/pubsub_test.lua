if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local bus_mod = require("lib.pubsub")

-- Helper: fresh bus for each group.
local function new_bus() return bus_mod.new() end

-- Deep equality for flat arrays of primitives.
local function arr_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

T.describe("matches_pattern", function()
  T.it("exact match", function()
    T.ok(bus_mod.matches_pattern("user.created", "user.created"))
  end)
  T.it("no match on different topic", function()
    T.ok(not bus_mod.matches_pattern("user.created", "user.deleted"))
  end)
  T.it("* matches one segment", function()
    T.ok(bus_mod.matches_pattern("user.created", "user.*"))
    T.ok(bus_mod.matches_pattern("order.updated", "order.*"))
  end)
  T.it("* does not match two segments", function()
    T.ok(not bus_mod.matches_pattern("user.profile.updated", "user.*"))
  end)
  T.it("** matches one segment", function()
    T.ok(bus_mod.matches_pattern("user.created", "user.**"))
  end)
  T.it("** matches two segments", function()
    T.ok(bus_mod.matches_pattern("user.profile.updated", "user.**"))
  end)
  T.it("# matches everything (root wildcard)", function()
    T.ok(bus_mod.matches_pattern("anything", "#"))
    T.ok(bus_mod.matches_pattern("a.b.c.d", "#"))
  end)
  T.it("user.# matches one segment subtopic", function()
    T.ok(bus_mod.matches_pattern("user.created", "user.#"))
  end)
  T.it("user.# matches nested subtopic", function()
    T.ok(bus_mod.matches_pattern("user.profile.updated", "user.#"))
  end)
  T.it("user.# does not match bare user", function()
    T.ok(not bus_mod.matches_pattern("user", "user.#"))
  end)
  T.it("? matches single character in segment", function()
    T.ok(bus_mod.matches_pattern("abc", "a?c"))
    T.ok(bus_mod.matches_pattern("axc", "a?c"))
  end)
  T.it("? does not match zero or two characters", function()
    T.ok(not bus_mod.matches_pattern("ac", "a?c"))
    T.ok(not bus_mod.matches_pattern("axyc", "a?c"))
  end)
  T.it("* at root matches single-segment topic", function()
    T.ok(bus_mod.matches_pattern("hello", "*"))
  end)
  T.it("* at root does not match two-segment topic", function()
    T.ok(not bus_mod.matches_pattern("hello.world", "*"))
  end)
  T.it("** at root matches everything", function()
    T.ok(bus_mod.matches_pattern("a.b.c", "**"))
  end)
end)

T.describe("subscribe + publish", function()
  T.it("handler receives message", function()
    local bus = new_bus()
    local received
    bus:subscribe("user.created", function(msg) received = msg end)
    local data = { name = "Alice" }
    bus:publish("user.created", data)
    -- received is the same table reference as data
    T.ok(received ~= nil, "handler must be called")
    T.eq(received.name, "Alice")
  end)

  T.it("multiple subscribers on same topic all called", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("evt", function() count = count + 1 end)
    bus:subscribe("evt", function() count = count + 1 end)
    bus:subscribe("evt", function() count = count + 1 end)
    bus:publish("evt", {})
    T.eq(count, 3)
  end)

  T.it("wildcard * handler receives matching messages", function()
    local bus = new_bus()
    local got = {}
    bus:subscribe("order.*", function(msg) got[#got + 1] = msg.kind end)
    bus:publish("order.created",  { kind = "created" })
    bus:publish("order.updated",  { kind = "updated" })
    bus:publish("order.deleted",  { kind = "deleted" })
    T.eq(#got, 3)
    T.eq(got[1], "created")
    T.eq(got[2], "updated")
    T.eq(got[3], "deleted")
  end)

  T.it("wildcard * does not match nested topics", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("order.*", function() count = count + 1 end)
    bus:publish("order.item.added", {})
    T.eq(count, 0)
  end)

  T.it("wildcard ** matches nested topics", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("sys.**", function() count = count + 1 end)
    bus:publish("sys.start", {})
    bus:publish("sys.net.up", {})
    bus:publish("sys.net.wifi.connected", {})
    T.eq(count, 3)
  end)

  T.it("# matches all topics", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("#", function() count = count + 1 end)
    bus:publish("a", {})
    bus:publish("b.c", {})
    bus:publish("d.e.f", {})
    T.eq(count, 3)
  end)

  T.it("non-matching topics do not trigger handler", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("user.*", function() count = count + 1 end)
    bus:publish("order.created", {})
    T.eq(count, 0)
  end)
end)

T.describe("once", function()
  T.it("handler called exactly once then unsubscribed", function()
    local bus = new_bus()
    local count = 0
    bus:once("ping", function() count = count + 1 end)
    bus:publish("ping", {})
    bus:publish("ping", {})
    bus:publish("ping", {})
    T.eq(count, 1)
  end)

  T.it("once with wildcard fires once", function()
    local bus = new_bus()
    local count = 0
    bus:once("msg.*", function() count = count + 1 end)
    bus:publish("msg.a", {})
    bus:publish("msg.b", {})
    T.eq(count, 1)
  end)

  T.it("once returns unsubscribe that prevents the one delivery", function()
    local bus = new_bus()
    local count = 0
    local unsub = bus:once("x", function() count = count + 1 end)
    unsub()
    bus:publish("x", {})
    T.eq(count, 0)
  end)
end)

T.describe("unsubscribe", function()
  T.it("returned function removes the subscription", function()
    local bus = new_bus()
    local count = 0
    local unsub = bus:subscribe("tick", function() count = count + 1 end)
    bus:publish("tick", {})
    unsub()
    bus:publish("tick", {})
    T.eq(count, 1)
  end)

  T.it("unsubscribe only removes that specific handler", function()
    local bus = new_bus()
    local a, b = 0, 0
    local unsub = bus:subscribe("tick", function() a = a + 1 end)
    bus:subscribe("tick", function() b = b + 1 end)
    unsub()
    bus:publish("tick", {})
    T.eq(a, 0)
    T.eq(b, 1)
  end)

  T.it("unsubscribe_all removes every handler for a pattern", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("evt", function() count = count + 1 end)
    bus:subscribe("evt", function() count = count + 1 end)
    bus:unsubscribe_all("evt")
    bus:publish("evt", {})
    T.eq(count, 0)
  end)

  T.it("unsubscribe_all does not affect other patterns", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("a", function() count = count + 1 end)
    bus:subscribe("b", function() count = count + 1 end)
    bus:unsubscribe_all("a")
    bus:publish("a", {})
    bus:publish("b", {})
    T.eq(count, 1)
  end)

  T.it("calling unsub twice is safe", function()
    local bus = new_bus()
    local count = 0
    local unsub = bus:subscribe("x", function() count = count + 1 end)
    unsub()
    unsub()  -- should not error
    bus:publish("x", {})
    T.eq(count, 0)
  end)
end)

T.describe("filter", function()
  T.it("handler only called when filter returns true", function()
    local bus = new_bus()
    local got = {}
    bus:subscribe("order.*", function(msg)
      got[#got + 1] = msg.amount
    end, { filter = function(msg) return msg.amount > 100 end })
    bus:publish("order.created", { amount = 50 })
    bus:publish("order.created", { amount = 200 })
    bus:publish("order.created", { amount = 150 })
    T.eq(#got, 2)
    T.eq(got[1], 200)
    T.eq(got[2], 150)
  end)

  T.it("filter returning false suppresses delivery", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("e", function() count = count + 1 end,
      { filter = function() return false end })
    bus:publish("e", {})
    bus:publish("e", {})
    T.eq(count, 0)
  end)

  T.it("once + filter: fires once when filter passes", function()
    local bus = new_bus()
    local count = 0
    bus:once("v", function() count = count + 1 end,
      { filter = function(msg) return msg.ok end })
    bus:publish("v", { ok = false })
    bus:publish("v", { ok = true })
    bus:publish("v", { ok = true })
    T.eq(count, 1)
  end)
end)

T.describe("middleware", function()
  T.it("middleware intercepts publish", function()
    local bus = new_bus()
    local log = {}
    bus:use(function(topic, msg, next)
      log[#log + 1] = topic
      next()
    end)
    local got
    bus:subscribe("x", function(msg) got = msg end)
    local data = { v = 1 }
    bus:publish("x", data)
    T.eq(#log, 1)
    T.eq(log[1], "x")
    T.ok(got ~= nil, "handler must be called")
    T.eq(got.v, 1)
  end)

  T.it("middleware can block delivery by not calling next", function()
    local bus = new_bus()
    bus:use(function(topic, msg, next)
      -- Intentionally don't call next for "blocked" topics.
      if topic ~= "blocked" then next() end
    end)
    local count = 0
    bus:subscribe("blocked", function() count = count + 1 end)
    bus:subscribe("allowed", function() count = count + 1 end)
    bus:publish("blocked", {})
    bus:publish("allowed", {})
    T.eq(count, 1)
  end)

  T.it("multiple middleware run in order", function()
    local bus = new_bus()
    local order = {}
    bus:use(function(t, m, next) order[#order+1] = 1; next() end)
    bus:use(function(t, m, next) order[#order+1] = 2; next() end)
    bus:use(function(t, m, next) order[#order+1] = 3; next() end)
    bus:subscribe("e", function() order[#order+1] = 4 end)
    bus:publish("e", {})
    T.ok(arr_eq(order, { 1, 2, 3, 4 }), "middleware order must be 1,2,3,4")
  end)

  T.it("middleware can modify msg before delivery", function()
    local bus = new_bus()
    bus:use(function(topic, msg, next)
      msg.stamped = true
      next()
    end)
    local got
    bus:subscribe("e", function(msg) got = msg end)
    bus:publish("e", { value = 42 })
    T.ok(got.stamped)
    T.eq(got.value, 42)
  end)
end)

T.describe("subscriber_count and topics", function()
  T.it("subscriber_count returns correct count", function()
    local bus = new_bus()
    T.eq(bus:subscriber_count("x"), 0)
    bus:subscribe("x", function() end)
    T.eq(bus:subscriber_count("x"), 1)
    bus:subscribe("x", function() end)
    T.eq(bus:subscriber_count("x"), 2)
  end)

  T.it("subscriber_count decreases after unsub", function()
    local bus = new_bus()
    local unsub = bus:subscribe("x", function() end)
    T.eq(bus:subscriber_count("x"), 1)
    unsub()
    T.eq(bus:subscriber_count("x"), 0)
  end)

  T.it("topics returns all patterns with subscribers", function()
    local bus = new_bus()
    bus:subscribe("a", function() end)
    bus:subscribe("b.*", function() end)
    bus:subscribe("c.#", function() end)
    local t = bus:topics()
    -- Sorted alphabetically.
    T.ok(arr_eq(t, { "a", "b.*", "c.#" }), "topics must be sorted: a, b.*, c.#")
  end)

  T.it("topics omits patterns with zero subscribers", function()
    local bus = new_bus()
    local unsub = bus:subscribe("gone", function() end)
    unsub()
    local t = bus:topics()
    T.eq(#t, 0)
  end)
end)

T.describe("clear", function()
  T.it("clear removes all subscribers", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("a", function() count = count + 1 end)
    bus:subscribe("b", function() count = count + 1 end)
    bus:clear()
    bus:publish("a", {})
    bus:publish("b", {})
    T.eq(count, 0)
  end)

  T.it("clear removes all middleware", function()
    local bus = new_bus()
    local mw_called = false
    bus:use(function(t, m, next) mw_called = true; next() end)
    bus:clear()
    local count = 0
    bus:subscribe("e", function() count = count + 1 end)
    bus:publish("e", {})
    -- Middleware was cleared so mw_called stays false, but delivery still works.
    T.ok(not mw_called)
    T.eq(count, 1)
  end)

  T.it("clear resets topics list", function()
    local bus = new_bus()
    bus:subscribe("x", function() end)
    bus:clear()
    T.eq(#bus:topics(), 0)
  end)
end)

T.describe("async publish / flush", function()
  T.it("publish_async does not deliver immediately", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("e", function() count = count + 1 end)
    bus:publish_async("e", {})
    T.eq(count, 0)
  end)

  T.it("flush delivers queued messages in order", function()
    local bus = new_bus()
    local got = {}
    bus:subscribe("e", function(msg) got[#got + 1] = msg.n end)
    bus:publish_async("e", { n = 1 })
    bus:publish_async("e", { n = 2 })
    bus:publish_async("e", { n = 3 })
    bus:flush()
    T.ok(arr_eq(got, { 1, 2, 3 }), "flush must deliver in order: 1, 2, 3")
  end)

  T.it("flush clears the queue", function()
    local bus = new_bus()
    local count = 0
    bus:subscribe("e", function() count = count + 1 end)
    bus:publish_async("e", {})
    bus:flush()
    bus:flush()  -- second flush delivers nothing
    T.eq(count, 1)
  end)

  T.it("publish_async respects middleware", function()
    local bus = new_bus()
    local intercepted = false
    bus:use(function(t, m, next) intercepted = true; next() end)
    bus:subscribe("e", function() end)
    bus:publish_async("e", {})
    bus:flush()
    T.ok(intercepted)
  end)
end)
