if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.statemachine")

-- ---------------------------------------------------------------------------
-- basic transitions
-- ---------------------------------------------------------------------------
T.describe("basic transitions", function()
  T.it("initial state is correct", function()
    local sc = M.create({ initial = "a", states = { a = {}, b = {} } })
    local s = sc:initial_state()
    T.eq(sc:matches(s, "a"), true)
    T.eq(sc:matches(s, "b"), false)
  end)

  T.it("state value is a string for atomic state", function()
    local sc = M.create({ initial = "a", states = { a = {}, b = {} } })
    local s = sc:initial_state()
    T.eq(type(s.value), "string")
    T.eq(s.value, "a")
  end)

  T.it("transition on event", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = { on = { GO = "b" } },
        b = {},
      },
    })
    local s = sc:initial_state()
    local s2 = sc:transition(s, "GO")
    T.eq(sc:matches(s2, "b"), true)
    T.eq(sc:matches(s2, "a"), false)
  end)

  T.it("unknown event returns original state", function()
    local sc = M.create({
      initial = "a",
      states = { a = { on = { GO = "b" } }, b = {} },
    })
    local s = sc:initial_state()
    local s2, err = sc:transition(s, "NOOP")
    -- No transition: returns same state object, err is nil
    T.eq(s2, s)
    T.eq(err, nil)
  end)

  T.it("chain of transitions", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = { on = { NEXT = "b" } },
        b = { on = { NEXT = "c" } },
        c = {},
      },
    })
    local s = sc:initial_state()
    s = sc:transition(s, "NEXT")
    T.eq(sc:matches(s, "b"), true)
    s = sc:transition(s, "NEXT")
    T.eq(sc:matches(s, "c"), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- context
-- ---------------------------------------------------------------------------
T.describe("context", function()
  T.it("initial context is copied from config", function()
    local sc = M.create({
      initial = "a",
      context = { x = 42 },
      states = { a = {} },
    })
    local s = sc:initial_state()
    T.eq(s.context.x, 42)
  end)

  T.it("action modifies context (service)", function()
    local sc = M.create({
      initial = "a",
      context = { x = 0 },
      states = {
        a = { on = { INC = { target = "a", action = function(ctx) ctx.x = ctx.x + 1 end } } },
      },
    })
    local svc = sc:start()
    svc:send("INC")
    svc:send("INC")
    T.eq(svc.context.x, 2)
  end)

  T.it("action receives event data", function()
    local sc = M.create({
      initial = "a",
      context = { last = nil },
      states = {
        a = { on = { SET = { target = "a", action = function(ctx, data) ctx.last = data end } } },
      },
    })
    local svc = sc:start()
    svc:send("SET", "hello")
    T.eq(svc.context.last, "hello")
  end)

  T.it("transition context is immutable snapshot (pure transition)", function()
    local sc = M.create({
      initial = "a",
      context = { x = 0 },
      states = {
        a = { on = { INC = { target = "a", action = function(ctx) ctx.x = ctx.x + 1 end } } },
      },
    })
    local s0 = sc:initial_state()
    local s1 = sc:transition(s0, "INC")
    -- s0 context unchanged
    T.eq(s0.context.x, 0)
    T.eq(s1.context.x, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- guards
-- ---------------------------------------------------------------------------
T.describe("guards", function()
  T.it("guard prevents transition when false", function()
    local sc = M.create({
      initial = "a",
      context = { ok = false },
      states = {
        a = { on = { GO = { target = "b", guard = function(ctx) return ctx.ok end } } },
        b = {},
      },
    })
    local s = sc:initial_state()
    local s2, _ = sc:transition(s, "GO")
    -- Guard rejected, no transition
    T.eq(sc:matches(s2, "a"), true)
  end)

  T.it("guard allows transition when true", function()
    local sc = M.create({
      initial = "a",
      context = { ok = true },
      states = {
        a = { on = { GO = { target = "b", guard = function(ctx) return ctx.ok end } } },
        b = {},
      },
    })
    local s = sc:initial_state()
    local s2 = sc:transition(s, "GO")
    T.eq(sc:matches(s2, "b"), true)
  end)

  T.it("guard receives event data", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = { on = {
          GO = { target = "b", guard = function(ctx, data) return data == "open sesame" end },
        }},
        b = {},
      },
    })
    local s = sc:initial_state()
    local s2 = sc:transition(s, "GO", "wrong")
    T.eq(sc:matches(s2, "a"), true)  -- rejected
    local s3 = sc:transition(s, "GO", "open sesame")
    T.eq(sc:matches(s3, "b"), true)  -- accepted
  end)
end)

-- ---------------------------------------------------------------------------
-- entry / exit actions
-- ---------------------------------------------------------------------------
T.describe("entry/exit actions", function()
  T.it("entry called on initial state", function()
    local log = {}
    local sc = M.create({
      initial = "a",
      states = {
        a = { entry = function() log[#log+1] = "enter_a" end },
      },
    })
    sc:initial_state()
    T.eq(log[1], "enter_a")
  end)

  T.it("exit called on leaving state", function()
    local log = {}
    local sc = M.create({
      initial = "a",
      states = {
        a = { exit = function() log[#log+1] = "exit_a" end, on = { GO = "b" } },
        b = {},
      },
    })
    local s = sc:initial_state()
    sc:transition(s, "GO")
    T.eq(log[1], "exit_a")
  end)

  T.it("entry called on entering state", function()
    local log = {}
    local sc = M.create({
      initial = "a",
      states = {
        a = { on = { GO = "b" } },
        b = { entry = function() log[#log+1] = "enter_b" end },
      },
    })
    local s = sc:initial_state()
    sc:transition(s, "GO")
    T.eq(log[1], "enter_b")
  end)

  T.it("exit then entry order on transition", function()
    local log = {}
    local sc = M.create({
      initial = "a",
      states = {
        a = {
          exit  = function() log[#log+1] = "exit_a" end,
          on = { GO = "b" },
        },
        b = { entry = function() log[#log+1] = "enter_b" end },
      },
    })
    local s = sc:initial_state()
    sc:transition(s, "GO")
    T.eq(log[1], "exit_a")
    T.eq(log[2], "enter_b")
  end)

  T.it("no exit/entry on self-transition", function()
    -- self-transition should fire exit then re-entry
    local count = 0
    local sc = M.create({
      initial = "a",
      states = {
        a = {
          entry = function() count = count + 1 end,
          on = { LOOP = "a" },
        },
      },
    })
    local s = sc:initial_state()  -- entry fires once
    T.eq(count, 1)
    sc:transition(s, "LOOP")      -- exit then re-entry
    T.eq(count, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- compound (nested) states
-- ---------------------------------------------------------------------------
T.describe("compound states", function()
  T.it("compound initial sub-state", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          states = {
            working = {},
            paused  = {},
          },
        },
      },
    })
    local s = sc:initial_state()
    T.eq(sc:matches(s, "active"), true)
    T.eq(sc:matches(s, "active.working"), true)
    T.eq(sc:matches(s, "active.paused"), false)
  end)

  T.it("state value is table for compound state", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          states = { working = {}, paused = {} },
        },
      },
    })
    local s = sc:initial_state()
    T.eq(type(s.value), "table")
    T.eq(s.value[1], "active")
    T.eq(s.value[2], "working")
  end)

  T.it("event in sub-state", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          states = {
            working = { on = { PAUSE = "paused" } },
            paused  = { on = { RESUME = "working" } },
          },
        },
        idle = {},
      },
    })
    local s = sc:initial_state()
    local s2 = sc:transition(s, "PAUSE")
    T.eq(sc:matches(s2, "active.paused"), true)
    T.eq(sc:matches(s2, "active"), true)
    local s3 = sc:transition(s2, "RESUME")
    T.eq(sc:matches(s3, "active.working"), true)
  end)

  T.it("matches parent state pattern", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          states = { working = {}, paused = {} },
        },
        idle = {},
      },
    })
    local s = sc:initial_state()
    T.eq(sc:matches(s, "active"), true)
    T.eq(sc:matches(s, "idle"), false)
  end)

  T.it("transition from sub-state to sibling (same parent)", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "a",
          states = {
            a = { on = { NEXT = "b" } },
            b = {},
          },
        },
      },
    })
    local s = sc:initial_state()
    T.eq(sc:matches(s, "active.a"), true)
    local s2 = sc:transition(s, "NEXT")
    T.eq(sc:matches(s2, "active.b"), true)
  end)

  T.it("transition out of compound state to sibling", function()
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          states = {
            working = { on = { DONE = "idle" } },
          },
        },
        idle = {},
      },
    })
    local s = sc:initial_state()
    local s2 = sc:transition(s, "DONE")
    T.eq(sc:matches(s2, "idle"), true)
  end)

  T.it("entry/exit fire correctly crossing compound boundary", function()
    local log = {}
    local sc = M.create({
      initial = "active",
      states = {
        active = {
          initial = "working",
          entry = function() log[#log+1] = "enter_active" end,
          exit  = function() log[#log+1] = "exit_active" end,
          states = {
            working = {
              entry = function() log[#log+1] = "enter_working" end,
              exit  = function() log[#log+1] = "exit_working" end,
              on = { DONE = "idle" },
            },
          },
        },
        idle = {
          entry = function() log[#log+1] = "enter_idle" end,
        },
      },
    })
    local s = sc:initial_state()
    -- initial_state fires entry for active then working
    T.eq(log[1], "enter_active")
    T.eq(log[2], "enter_working")
    sc:transition(s, "DONE")
    -- exit working, exit active, enter idle
    T.eq(log[3], "exit_working")
    T.eq(log[4], "exit_active")
    T.eq(log[5], "enter_idle")
  end)

  T.it("three-level nesting", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = {
          initial = "b",
          states = {
            b = {
              initial = "c",
              states = {
                c = {},
              },
            },
          },
        },
      },
    })
    local s = sc:initial_state()
    T.eq(sc:matches(s, "a"), true)
    T.eq(sc:matches(s, "a.b"), true)
    T.eq(sc:matches(s, "a.b.c"), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- final states
-- ---------------------------------------------------------------------------
T.describe("final states", function()
  T.it("is_final returns true for final state", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = { on = { FINISH = "done" } },
        done = { type = "final" },
      },
    })
    local s = sc:initial_state()
    T.eq(sc:is_final(s), false)
    local s2 = sc:transition(s, "FINISH")
    T.eq(sc:is_final(s2), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- service API
-- ---------------------------------------------------------------------------
T.describe("service API", function()
  T.it("service:send transitions state", function()
    local sc = M.create({
      initial = "a",
      states = { a = { on = { GO = "b" } }, b = {} },
    })
    local svc = sc:start()
    T.eq(svc:matches("a"), true)
    svc:send("GO")
    T.eq(svc:matches("b"), true)
  end)

  T.it("service.context reflects mutations", function()
    local sc = M.create({
      initial = "a",
      context = { n = 0 },
      states = {
        a = { on = { INC = { target = "a", action = function(ctx) ctx.n = ctx.n + 1 end } } },
      },
    })
    local svc = sc:start()
    svc:send("INC")
    svc:send("INC")
    svc:send("INC")
    T.eq(svc.context.n, 3)
  end)

  T.it("service:stop prevents further sends", function()
    local sc = M.create({
      initial = "a",
      states = { a = { on = { GO = "b" } }, b = {} },
    })
    local svc = sc:start()
    svc:stop()
    svc:send("GO")
    T.eq(svc:matches("a"), true)  -- still at "a" because stopped
  end)

  T.it("service:start with override context", function()
    local sc = M.create({
      initial = "a",
      context = { x = 1 },
      states = { a = {} },
    })
    local svc = sc:start({ x = 99 })
    T.eq(svc.context.x, 99)
  end)

  T.it("compound state in service", function()
    local sc = M.create({
      initial = "active",
      context = { count = 0 },
      states = {
        active = {
          initial = "working",
          states = {
            working = {
              on = {
                PAUSE = "paused",
                TICK  = { target = "working",
                          action = function(ctx) ctx.count = ctx.count + 1 end },
              },
            },
            paused = { on = { RESUME = "working" } },
          },
        },
        idle = {},
      },
    })
    local svc = sc:start()
    svc:send("TICK")
    svc:send("TICK")
    T.eq(svc.context.count, 2)
    T.eq(svc:matches("active.working"), true)
    svc:send("PAUSE")
    T.eq(svc:matches("active.paused"), true)
    svc:send("RESUME")
    T.eq(svc:matches("active.working"), true)
  end)
end)

-- ---------------------------------------------------------------------------
-- states_list
-- ---------------------------------------------------------------------------
T.describe("states_list", function()
  T.it("returns all state names", function()
    local sc = M.create({
      initial = "a",
      states = { a = {}, b = {}, c = {} },
    })
    local list = sc:states_list()
    -- sort for determinism
    table.sort(list)
    T.eq(#list, 3)
    T.eq(list[1], "a")
    T.eq(list[2], "b")
    T.eq(list[3], "c")
  end)

  T.it("includes nested state names", function()
    local sc = M.create({
      initial = "a",
      states = {
        a = {
          initial = "x",
          states = { x = {}, y = {} },
        },
        b = {},
      },
    })
    local list = sc:states_list()
    table.sort(list)
    -- expects: a, a.x, a.y, b
    T.eq(#list, 4)
    T.eq(list[1], "a")
    T.eq(list[2], "a.x")
    T.eq(list[3], "a.y")
    T.eq(list[4], "b")
  end)
end)

-- ---------------------------------------------------------------------------
-- error handling
-- ---------------------------------------------------------------------------
T.describe("error handling", function()
  T.it("create returns nil,err when config missing initial", function()
    local sc, err = M.create({ states = { a = {} } })
    T.eq(sc, nil)
    T.ok(err)
  end)

  T.it("create returns nil,err when config missing states", function()
    local sc, err = M.create({ initial = "a" })
    T.eq(sc, nil)
    T.ok(err)
  end)

  T.it("transition to unknown target returns nil,err", function()
    local sc = M.create({
      initial = "a",
      states = { a = { on = { GO = "nonexistent" } } },
    })
    local s = sc:initial_state()
    local s2, err = sc:transition(s, "GO")
    T.eq(s2, nil)
    T.ok(err)
  end)
end)
