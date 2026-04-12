if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local BT = require("lib.behavior_tree")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function always(status)
  return BT.action(function() return status end)
end

local function counter_action(t, key)
  -- increments t[key] each tick, returns "running" until count reaches t[key.."_max"]
  return BT.action(function(bb)
    bb[key] = (bb[key] or 0) + 1
    if bb[key] >= (bb[key .. "_max"] or 1) then
      return "success"
    end
    return "running"
  end)
end

-- ---------------------------------------------------------------------------
-- Sequence
-- ---------------------------------------------------------------------------

T.describe("Sequence", function()
  T.it("all succeed → success", function()
    local tree = BT.new(BT.sequence({ always("success"), always("success"), always("success") }))
    T.eq(tree:tick({}), "success")
  end)

  T.it("first fails → failure", function()
    local tree = BT.new(BT.sequence({ always("failure"), always("success") }))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("middle fails → failure", function()
    local tree = BT.new(BT.sequence({ always("success"), always("failure"), always("success") }))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("last fails → failure", function()
    local tree = BT.new(BT.sequence({ always("success"), always("success"), always("failure") }))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("empty sequence → success", function()
    local tree = BT.new(BT.sequence({}))
    T.eq(tree:tick({}), "success")
  end)

  T.it("resumes from running child", function()
    local calls = {}
    local ticks = 0
    local child1 = BT.action(function()
      calls[#calls + 1] = "c1"
      return "success"
    end)
    local child2 = BT.action(function()
      calls[#calls + 1] = "c2"
      ticks = ticks + 1
      if ticks < 3 then return "running" end
      return "success"
    end)
    local child3 = BT.action(function()
      calls[#calls + 1] = "c3"
      return "success"
    end)
    local tree = BT.new(BT.sequence({ child1, child2, child3 }))
    -- tick 1: c1 ok, c2 running → stops here
    T.eq(tree:tick({}), "running")
    T.eq(#calls, 2)
    T.eq(calls[1], "c1")
    T.eq(calls[2], "c2")
    -- tick 2: should resume from c2 (not call c1 again)
    T.eq(tree:tick({}), "running")
    T.eq(#calls, 3)
    T.eq(calls[3], "c2")
    -- tick 3: c2 finally succeeds, c3 runs
    T.eq(tree:tick({}), "success")
    T.eq(#calls, 5)
    T.eq(calls[4], "c2")
    T.eq(calls[5], "c3")
  end)
end)

-- ---------------------------------------------------------------------------
-- Selector
-- ---------------------------------------------------------------------------

T.describe("Selector", function()
  T.it("first succeeds → success", function()
    local tree = BT.new(BT.selector({ always("success"), always("failure") }))
    T.eq(tree:tick({}), "success")
  end)

  T.it("all fail → failure", function()
    local tree = BT.new(BT.selector({ always("failure"), always("failure"), always("failure") }))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("second succeeds → success", function()
    local tree = BT.new(BT.selector({ always("failure"), always("success") }))
    T.eq(tree:tick({}), "success")
  end)

  T.it("empty selector → failure", function()
    local tree = BT.new(BT.selector({}))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("resumes from running child", function()
    local ticks = 0
    local child1_calls = 0
    local child1 = BT.action(function()
      child1_calls = child1_calls + 1
      return "failure"
    end)
    local child2 = BT.action(function()
      ticks = ticks + 1
      if ticks < 2 then return "running" end
      return "success"
    end)
    local tree = BT.new(BT.selector({ child1, child2 }))
    T.eq(tree:tick({}), "running")
    T.eq(child1_calls, 1)
    -- second tick: resumes from child2, does NOT re-run child1
    T.eq(tree:tick({}), "success")
    T.eq(child1_calls, 1)  -- still 1
  end)
end)

-- ---------------------------------------------------------------------------
-- Parallel
-- ---------------------------------------------------------------------------

T.describe("Parallel", function()
  T.it("all=all: all succeed → success", function()
    local tree = BT.new(BT.parallel({ always("success"), always("success") }, "all"))
    T.eq(tree:tick({}), "success")
  end)

  T.it("all=all: one fails → failure", function()
    local tree = BT.new(BT.parallel({ always("success"), always("failure") }, "all"))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("any: one succeeds → success", function()
    local tree = BT.new(BT.parallel({ always("success"), always("failure") }, "any"))
    T.eq(tree:tick({}), "success")
  end)

  T.it("any: all fail → failure", function()
    local tree = BT.new(BT.parallel({ always("failure"), always("failure") }, "any"))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("threshold number: 2 of 3 succeed → success", function()
    local tree = BT.new(BT.parallel({ always("success"), always("success"), always("failure") }, 2))
    T.eq(tree:tick({}), "success")
  end)

  T.it("threshold number: only 1 of 3 succeed → failure when 2 needed", function()
    local tree = BT.new(BT.parallel({ always("success"), always("failure"), always("failure") }, 2))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("default threshold is all", function()
    local tree = BT.new(BT.parallel({ always("success"), always("success") }))
    T.eq(tree:tick({}), "success")
    tree:reset()
    local tree2 = BT.new(BT.parallel({ always("success"), always("failure") }))
    T.eq(tree2:tick({}), "failure")
  end)

  T.it("running when threshold not met and not failed", function()
    local tree = BT.new(BT.parallel({ always("running"), always("running") }, "any"))
    T.eq(tree:tick({}), "running")
  end)
end)

-- ---------------------------------------------------------------------------
-- Decorators
-- ---------------------------------------------------------------------------

T.describe("Inverter", function()
  T.it("success → failure", function()
    local tree = BT.new(BT.inverter(always("success")))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("failure → success", function()
    local tree = BT.new(BT.inverter(always("failure")))
    T.eq(tree:tick({}), "success")
  end)

  T.it("running → running", function()
    local tree = BT.new(BT.inverter(always("running")))
    T.eq(tree:tick({}), "running")
  end)
end)

T.describe("Succeeder", function()
  T.it("always returns success even on failure", function()
    local tree = BT.new(BT.succeeder(always("failure")))
    T.eq(tree:tick({}), "success")
  end)

  T.it("returns success when child succeeds", function()
    local tree = BT.new(BT.succeeder(always("success")))
    T.eq(tree:tick({}), "success")
  end)

  T.it("returns success even when child is running", function()
    local tree = BT.new(BT.succeeder(always("running")))
    T.eq(tree:tick({}), "success")
  end)
end)

T.describe("Failer", function()
  T.it("always returns failure even on success", function()
    local tree = BT.new(BT.failer(always("success")))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("returns failure when child fails", function()
    local tree = BT.new(BT.failer(always("failure")))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("returns failure even when child is running", function()
    local tree = BT.new(BT.failer(always("running")))
    T.eq(tree:tick({}), "failure")
  end)
end)

T.describe("Repeater", function()
  T.it("runs child n times then success", function()
    local count = 0
    local child = BT.action(function()
      count = count + 1
      return "success"
    end)
    local tree = BT.new(BT.repeater(child, 3))
    -- Should stay running until 3 completions, then succeed
    local status = tree:tick({})
    -- The repeater loops internally: tick 1 runs child 3 times synchronously
    -- (since child returns success immediately each time)
    T.eq(status, "success")
    T.eq(count, 3)
  end)

  T.it("child returns running → repeater returns running", function()
    local ticks = 0
    local child = BT.action(function()
      ticks = ticks + 1
      if ticks < 2 then return "running" end
      return "success"
    end)
    local tree = BT.new(BT.repeater(child, 2))
    T.eq(tree:tick({}), "running")  -- child still running
    T.eq(tree:tick({}), "success")  -- child finishes, repeater cycles, child succeeds again → success
  end)

  T.it("n=-1 runs forever (returns running)", function()
    local count = 0
    local child = BT.action(function()
      count = count + 1
      return "success"
    end)
    local tree = BT.new(BT.repeater(child, -1))
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "running")
    T.ok(count >= 2)
  end)
end)

T.describe("RepeatUntilFail", function()
  T.it("succeeds when child finally fails", function()
    local ticks = 0
    local child = BT.action(function()
      ticks = ticks + 1
      if ticks >= 3 then return "failure" end
      return "success"
    end)
    local tree = BT.new(BT.repeat_until_fail(child))
    -- loops internally until failure, returns success
    T.eq(tree:tick({}), "success")
    T.eq(ticks, 3)
  end)

  T.it("with running child: returns running until child fails", function()
    local phase = 0
    local child = BT.action(function()
      phase = phase + 1
      if phase == 1 then return "running" end
      if phase == 2 then return "success" end
      return "failure"
    end)
    local tree = BT.new(BT.repeat_until_fail(child))
    T.eq(tree:tick({}), "running")  -- phase 1: running
    T.eq(tree:tick({}), "success")  -- phase 2: success → loop; phase 3: failure → return success
  end)
end)

T.describe("Retry", function()
  T.it("succeeds on first try", function()
    local tree = BT.new(BT.retry(always("success"), 3))
    T.eq(tree:tick({}), "success")
  end)

  T.it("fails after n retries exhausted", function()
    local tree = BT.new(BT.retry(always("failure"), 3))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("succeeds on second try", function()
    local ticks = 0
    local child = BT.action(function()
      ticks = ticks + 1
      if ticks >= 2 then return "success" end
      return "failure"
    end)
    local tree = BT.new(BT.retry(child, 3))
    T.eq(tree:tick({}), "success")
    T.eq(ticks, 2)
  end)
end)

T.describe("Cooldown", function()
  T.it("allows execution initially", function()
    local tree = BT.new(BT.cooldown(always("success"), 3))
    T.eq(tree:tick({}), "success")
  end)

  T.it("blocks for N ticks after success", function()
    local tree = BT.new(BT.cooldown(always("success"), 3))
    T.eq(tree:tick({}), "success")  -- tick 1: succeeds → cooldown until tick 4
    T.eq(tree:tick({}), "failure")  -- tick 2: in cooldown
    T.eq(tree:tick({}), "failure")  -- tick 3: in cooldown
    T.eq(tree:tick({}), "failure")  -- tick 4: still in cooldown (blocked until tick 4+)
    T.eq(tree:tick({}), "success")  -- tick 5: cooldown expired
  end)

  T.it("does not block on failure", function()
    local tree = BT.new(BT.cooldown(always("failure"), 3))
    T.eq(tree:tick({}), "failure")
    T.eq(tree:tick({}), "failure")  -- no cooldown on failure
  end)
end)

-- ---------------------------------------------------------------------------
-- Leaf nodes
-- ---------------------------------------------------------------------------

T.describe("Condition", function()
  T.it("true → success", function()
    local tree = BT.new(BT.condition(function() return true end))
    T.eq(tree:tick({}), "success")
  end)

  T.it("false → failure", function()
    local tree = BT.new(BT.condition(function() return false end))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("reads from blackboard", function()
    local tree = BT.new(BT.condition(function(bb) return bb.alive end))
    T.eq(tree:tick({ alive = true }),  "success")
    T.eq(tree:tick({ alive = false }), "failure")
  end)
end)

T.describe("Action", function()
  T.it("returns status from fn", function()
    local tree = BT.new(BT.action(function() return "success" end))
    T.eq(tree:tick({}), "success")
  end)

  T.it("action tracks ticks via node_state", function()
    local node = BT.action(function(bb, state)
      state.count = (state.count or 0) + 1
      bb.total = state.count
      if state.count >= 3 then return "success" end
      return "running"
    end)
    local tree = BT.new(node)
    local bb = {}
    T.eq(tree:tick(bb), "running")
    T.eq(bb.total, 1)
    T.eq(tree:tick(bb), "running")
    T.eq(bb.total, 2)
    T.eq(tree:tick(bb), "success")
    T.eq(bb.total, 3)
  end)

  T.it("writes to blackboard", function()
    local tree = BT.new(BT.action(function(bb) bb.fired = true; return "success" end))
    local bb = {}
    tree:tick(bb)
    T.eq(bb.fired, true)
  end)
end)

T.describe("Wait", function()
  T.it("returns running for N-1 ticks then success", function()
    local tree = BT.new(BT.wait(3))
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "success")
  end)

  T.it("wait(1) succeeds on first tick", function()
    local tree = BT.new(BT.wait(1))
    T.eq(tree:tick({}), "success")
  end)

  T.it("resets and runs again after tree:reset()", function()
    local tree = BT.new(BT.wait(2))
    T.eq(tree:tick({}), "running")
    tree:reset()
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "success")
  end)
end)

-- ---------------------------------------------------------------------------
-- Blackboard shared state
-- ---------------------------------------------------------------------------

T.describe("Blackboard", function()
  T.it("multiple nodes share the same blackboard", function()
    local writer = BT.action(function(bb) bb.x = 42; return "success" end)
    local reader = BT.condition(function(bb) return bb.x == 42 end)
    local tree = BT.new(BT.sequence({ writer, reader }))
    local bb = {}
    T.eq(tree:tick(bb), "success")
    T.eq(bb.x, 42)
  end)

  T.it("blackboard persists across ticks", function()
    local tree = BT.new(BT.action(function(bb) bb.n = (bb.n or 0) + 1; return "running" end))
    local bb = {}
    tree:tick(bb)
    tree:tick(bb)
    tree:tick(bb)
    T.eq(bb.n, 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- Random variants
-- ---------------------------------------------------------------------------

T.describe("RandomSequence", function()
  T.it("succeeds when all children succeed", function()
    local tree = BT.new(BT.random_sequence({ always("success"), always("success") }))
    T.eq(tree:tick({}), "success")
  end)

  T.it("fails when any child fails", function()
    local tree = BT.new(BT.random_sequence({ always("success"), always("failure") }))
    T.eq(tree:tick({}), "failure")
  end)

  T.it("order varies across runs (statistical)", function()
    math.randomseed(12345)
    local orders = {}
    for _ = 1, 20 do
      local order = {}
      local tree = BT.new(BT.random_sequence({
        BT.action(function() order[#order + 1] = "A"; return "success" end),
        BT.action(function() order[#order + 1] = "B"; return "success" end),
        BT.action(function() order[#order + 1] = "C"; return "success" end),
      }))
      tree:tick({})
      orders[#orders + 1] = table.concat(order)
    end
    -- Check that not all orders are identical (with high probability)
    local first = orders[1]
    local all_same = true
    for i = 2, #orders do
      if orders[i] ~= first then all_same = false; break end
    end
    T.ok(not all_same, "expected some variation in order across 20 runs")
  end)
end)

T.describe("RandomSelector", function()
  T.it("succeeds when one child succeeds", function()
    local tree = BT.new(BT.random_selector({ always("failure"), always("success") }))
    T.eq(tree:tick({}), "success")
  end)

  T.it("fails when all children fail", function()
    local tree = BT.new(BT.random_selector({ always("failure"), always("failure") }))
    T.eq(tree:tick({}), "failure")
  end)
end)

-- ---------------------------------------------------------------------------
-- Subtree
-- ---------------------------------------------------------------------------

T.describe("Subtree", function()
  T.it("embeds another tree correctly", function()
    local inner = BT.new(BT.sequence({ always("success"), always("success") }))
    local outer = BT.new(BT.subtree(inner))
    T.eq(outer:tick({}), "success")
  end)

  T.it("propagates failure from inner tree", function()
    local inner = BT.new(BT.sequence({ always("success"), always("failure") }))
    local outer = BT.new(BT.subtree(inner))
    T.eq(outer:tick({}), "failure")
  end)
end)

-- ---------------------------------------------------------------------------
-- tree:reset()
-- ---------------------------------------------------------------------------

T.describe("tree:reset()", function()
  T.it("resets sequence child index", function()
    local ticks = 0
    local child2 = BT.action(function()
      ticks = ticks + 1
      if ticks < 2 then return "running" end
      return "success"
    end)
    local tree = BT.new(BT.sequence({ always("success"), child2, always("success") }))
    T.eq(tree:tick({}), "running")  -- child2 running on tick 1
    tree:reset()
    ticks = 0
    T.eq(tree:tick({}), "running")  -- starts fresh: child2 is running again
    T.eq(tree:tick({}), "success")
  end)

  T.it("resets wait elapsed counter", function()
    local tree = BT.new(BT.wait(3))
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "running")
    tree:reset()
    -- After reset, should take 3 ticks again
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "running")
    T.eq(tree:tick({}), "success")
  end)

  T.it("tree:status() returns nil after reset", function()
    local tree = BT.new(always("success"))
    tree:tick({})
    T.eq(tree:status(), "success")
    tree:reset()
    T.eq(tree:status(), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- tree:status() and tree:debug()
-- ---------------------------------------------------------------------------

T.describe("tree:status()", function()
  T.it("nil before first tick", function()
    local tree = BT.new(always("success"))
    T.eq(tree:status(), nil)
  end)

  T.it("returns last tick status", function()
    local tree = BT.new(always("running"))
    tree:tick({})
    T.eq(tree:status(), "running")
  end)
end)

T.describe("tree:debug()", function()
  T.it("returns a string", function()
    local tree = BT.new(BT.sequence({ always("success"), always("failure") }))
    tree:tick({})
    local d = tree:debug()
    T.ok(type(d) == "string")
    T.ok(d:find("sequence") ~= nil)
    T.ok(d:find("action") ~= nil)
  end)

  T.it("includes last status in debug output", function()
    local tree = BT.new(always("success"))
    tree:tick({})
    local d = tree:debug()
    T.ok(d:find("success") ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Complex integration: enemy patrol AI
-- ---------------------------------------------------------------------------

T.describe("Integration: patrol AI", function()
  T.it("attacks when enemy seen, patrols otherwise", function()
    local attack_count = 0
    local patrol_count = 0

    local see_enemy  = BT.condition(function(bb) return bb.enemy_visible end)
    local attack     = BT.action(function(bb) attack_count = attack_count + 1; return "success" end)
    local patrol     = BT.action(function(bb) patrol_count = patrol_count + 1; return "success" end)

    local tree = BT.new(BT.selector({
      BT.sequence({ see_enemy, attack }),
      patrol,
    }))

    -- No enemy: should patrol
    tree:tick({ enemy_visible = false })
    T.eq(attack_count, 0)
    T.eq(patrol_count, 1)

    -- Enemy seen: should attack
    tree:tick({ enemy_visible = true })
    T.eq(attack_count, 1)
    T.eq(patrol_count, 1)
  end)
end)
