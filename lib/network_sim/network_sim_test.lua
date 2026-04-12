if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local network_sim = require("lib.network_sim")

T.describe("network_sim", function()

  T.it("send + tick delivers message to handler", function()
    local net = network_sim.network({ seed = 1, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg, from)
      received[#received + 1] = { msg = msg, from = from }
    end)

    net:send("a", "b", "hello")
    -- Not yet delivered (deliver_at = tick 1, current tick = 0)
    T.eq(#received, 0)

    local result = net:tick()
    T.eq(#received, 1)
    T.eq(received[1].msg, "hello")
    T.eq(received[1].from, "a")
    T.eq(#result.delivered, 1)
    T.eq(#result.dropped, 0)
  end)

  T.it("broadcast: all nodes receive", function()
    local net = network_sim.network({ seed = 2, default_latency = 1 })
    local counts = { b = 0, c = 0, d = 0 }
    net:node("a", function() end)
    net:node("b", function() counts.b = counts.b + 1 end)
    net:node("c", function() counts.c = counts.c + 1 end)
    net:node("d", function() counts.d = counts.d + 1 end)

    local ids = net:broadcast("a", "ping")
    T.eq(type(ids), "table")
    T.eq(#ids, 3)

    net:tick()
    T.eq(counts.b, 1)
    T.eq(counts.c, 1)
    T.eq(counts.d, 1)
  end)

  T.it("partition: messages dropped", function()
    local net = network_sim.network({ seed = 3, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:partition("a", "b")
    net:send("a", "b", "blocked")
    local result = net:tick()

    T.eq(#received, 0)
    T.eq(#result.dropped, 1)
    T.eq(#result.delivered, 0)
  end)

  T.it("heal: messages flow again after heal", function()
    local net = network_sim.network({ seed = 4, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:partition("a", "b")
    net:send("a", "b", "before-heal")
    net:tick()
    T.eq(#received, 0)

    net:heal("a", "b")
    net:send("a", "b", "after-heal")
    net:tick()
    T.eq(#received, 1)
    T.eq(received[1], "after-heal")
  end)

  T.it("latency: message arrives after correct number of ticks", function()
    local net = network_sim.network({ seed = 5, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = { msg = msg, tick = net.tick_count }
    end)

    -- Override latency to 3 ticks for a->b
    net:set_latency("a", "b", 3)
    net:send("a", "b", "delayed")

    -- Should not arrive at tick 1 or 2
    net:tick()
    T.eq(#received, 0)
    net:tick()
    T.eq(#received, 0)
    -- Should arrive at tick 3
    net:tick()
    T.eq(#received, 1)
    T.eq(received[1].msg, "delayed")
    T.eq(received[1].tick, 3)
  end)

  T.it("loss_rate=1.0: all messages dropped", function()
    local net = network_sim.network({ seed = 6, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:set_loss_rate("a", "b", 1.0)
    -- unreliable sends are subject to loss
    net:send("a", "b", "lost1", { reliable = false })
    net:send("a", "b", "lost2", { reliable = false })
    net:send("a", "b", "lost3", { reliable = false })
    local result = net:tick()

    T.eq(#received, 0)
    T.eq(#result.dropped, 3)
  end)

  T.it("loss_rate does not affect reliable messages", function()
    local net = network_sim.network({ seed = 7, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:set_loss_rate("a", "b", 1.0)
    -- reliable=true (default) bypasses loss
    net:send("a", "b", "reliable")
    net:tick()
    T.eq(#received, 1)
  end)

  T.it("pending: shows in-flight messages", function()
    local net = network_sim.network({ seed = 8, default_latency = 2 })
    net:node("a", function() end)
    net:node("b", function() end)
    net:node("c", function() end)

    net:send("a", "b", "m1")
    net:send("a", "c", "m2")

    local p = net:pending()
    T.eq(#p, 2)

    -- After one tick they should still be pending (latency=2)
    net:tick()
    p = net:pending()
    T.eq(#p, 2)

    -- After second tick they are delivered
    net:tick()
    p = net:pending()
    T.eq(#p, 0)
  end)

  T.it("history: records delivered events", function()
    local net = network_sim.network({ seed = 9, default_latency = 1 })
    net:node("a", function() end)
    net:node("b", function() end)

    net:send("a", "b", "ev1")
    net:tick()
    net:send("a", "b", "ev2")
    net:tick()

    local h = net:history()
    T.eq(#h, 2)
    T.eq(h[1].type, "delivered")
    T.eq(h[1].from, "a")
    T.eq(h[1].to, "b")
    T.eq(h[1].msg, "ev1")
    T.eq(h[1].tick, 1)
    T.eq(h[2].tick, 2)
  end)

  T.it("history: records dropped events", function()
    local net = network_sim.network({ seed = 10, default_latency = 1 })
    net:node("a", function() end)
    net:node("b", function() end)

    net:partition("a", "b")
    net:send("a", "b", "blocked")
    net:tick()

    local h = net:history()
    T.eq(#h, 1)
    T.eq(h[1].type, "dropped")
    T.eq(h[1].msg, "blocked")
  end)

  T.it("tick(n): advances n steps at once", function()
    local net = network_sim.network({ seed = 11, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:send("a", "b", "m1")  -- deliver_at = 1
    net:send("a", "b", "m2", { delay = 3 })  -- deliver_at = 3
    net:send("a", "b", "m3", { delay = 5 })  -- deliver_at = 5

    -- Advance 5 ticks at once
    local result = net:tick(5)
    T.eq(net.tick_count, 5)
    T.eq(#received, 3)
    T.eq(#result.delivered, 3)
  end)

  T.it("tick(n): returns aggregate of all ticks", function()
    local net = network_sim.network({ seed = 12, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg)
      received[#received + 1] = msg
    end)

    net:send("a", "b", "m1")  -- deliver_at=1
    net:send("a", "b", "m2", { delay = 2 })  -- deliver_at=2

    local result = net:tick(2)
    T.eq(#result.delivered, 2)
  end)

  T.it("deterministic: same seed gives same simulation", function()
    local function run(seed)
      local net = network_sim.network({ seed = seed, default_latency = 1 })
      net:node("a", function() end)
      net:node("b", function() end)
      net:set_loss_rate("a", "b", 0.5)
      local dropped_count = 0
      for _ = 1, 10 do
        net:send("a", "b", "x", { reliable = false })
      end
      local result = net:tick()
      for _, _ in ipairs(result.dropped) do
        dropped_count = dropped_count + 1
      end
      return dropped_count
    end

    local r1 = run(42)
    local r2 = run(42)
    T.eq(r1, r2)

    -- Different seed should (likely) give different result
    -- (not guaranteed but almost certain with 50% loss over 10 msgs)
    -- We just verify same seed is same
    local r3 = run(99)
    local r4 = run(99)
    T.eq(r3, r4)
  end)

  T.it("partition_all: partitions two groups from each other", function()
    local net = network_sim.network({ seed = 13, default_latency = 1 })
    local received = {}
    net:node("a1", function() end)
    net:node("a2", function() end)
    net:node("b1", function(msg) received[#received + 1] = { to = "b1", msg = msg } end)
    net:node("b2", function(msg) received[#received + 1] = { to = "b2", msg = msg } end)

    net:partition_all({ "a1", "a2" }, { "b1", "b2" })
    net:send("a1", "b1", "cross1")
    net:send("a2", "b2", "cross2")
    -- Within-group: a1 -> a2 should still work
    net:send("a1", "a2", "intra")
    local intra_received = {}
    net._nodes["a2"] = function(msg) intra_received[#intra_received + 1] = msg end

    net:tick()
    T.eq(#received, 0)  -- cross-group messages dropped
    T.eq(#intra_received, 1)  -- within-group still works
  end)

  T.it("random: deterministic float in [0,1)", function()
    local net = network_sim.network({ seed = 77 })
    net:node("x", function() end)
    local f1 = net:random()
    T.ok(f1 >= 0 and f1 < 1)

    -- Same seed gives same sequence
    local net2 = network_sim.network({ seed = 77 })
    net2:node("x", function() end)
    local f2 = net2:random()
    T.eq(f1, f2)
  end)

  T.it("random_int: deterministic integer in [a,b]", function()
    local net = network_sim.network({ seed = 88 })
    net:node("x", function() end)
    for _ = 1, 20 do
      local v = net:random_int(1, 6)
      T.ok(v >= 1 and v <= 6)
    end
  end)

  T.it("remove_node: removed node no longer receives", function()
    local net = network_sim.network({ seed = 14, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg) received[#received + 1] = msg end)

    net:send("a", "b", "before-remove")
    net:tick()
    T.eq(#received, 1)

    net:remove_node("b")
    -- Node b no longer in the network, send should fail
    local id, err = net:send("a", "b", "after-remove")
    T.eq(id, nil)
    T.ok(err ~= nil)
  end)

  T.it("majority_vote: converges to correct value", function()
    local net = network_sim.network({ seed = 15, default_latency = 1 })
    net:node("n1", function() end)
    net:node("n2", function() end)
    net:node("n3", function() end)

    local result = network_sim.majority_vote(net, { "n1", "n2", "n3" }, "yes")
    T.eq(result, "yes")
  end)

  T.it("reliable_broadcast: all nodes receive via helper", function()
    local net = network_sim.network({ seed = 16, default_latency = 1 })
    local got = {}
    net:node("leader", function() end)
    net:node("f1", function(msg) got[#got + 1] = msg end)
    net:node("f2", function(msg) got[#got + 1] = msg end)
    net:node("f3", function(msg) got[#got + 1] = msg end)

    network_sim.reliable_broadcast(net, { "leader", "f1", "f2", "f3" }, "commit")
    T.eq(#got, 3)
    T.eq(got[1], "commit")
  end)

  T.it("set_duplicate_rate=1.0: every message duplicated", function()
    local net = network_sim.network({ seed = 17, default_latency = 1 })
    local received = {}
    net:node("a", function() end)
    net:node("b", function(msg) received[#received + 1] = msg end)

    net:set_duplicate_rate("a", "b", 1.0)
    net:send("a", "b", "dup-me")
    net:tick()

    -- Should receive 2 copies
    T.eq(#received, 2)
    T.eq(received[1], "dup-me")
    T.eq(received[2], "dup-me")
  end)

  T.it("send returns error for unknown source", function()
    local net = network_sim.network({ seed = 18 })
    net:node("b", function() end)
    local id, err = net:send("ghost", "b", "x")
    T.eq(id, nil)
    T.ok(type(err) == "string")
  end)

  T.it("send returns error for unknown destination", function()
    local net = network_sim.network({ seed = 19 })
    net:node("a", function() end)
    local id, err = net:send("a", "ghost", "x")
    T.eq(id, nil)
    T.ok(type(err) == "string")
  end)

  T.it("tick_count advances correctly", function()
    local net = network_sim.network({ seed = 20 })
    net:node("a", function() end)
    T.eq(net.tick_count, 0)
    net:tick()
    T.eq(net.tick_count, 1)
    net:tick(4)
    T.eq(net.tick_count, 5)
  end)

end)
