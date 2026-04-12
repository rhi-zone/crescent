-- lib/state_machine/state_machine_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SM = require("lib.state_machine")

-- ── helpers ────────────────────────────────────────────────────────────────────

-- Build a standard traffic-light style 3-state machine.
local function make_basic()
  return SM.new({
    initial = "idle",
    states = {
      idle = {
        on = {
          START = "running",
          RESET = "idle",
        },
      },
      running = {
        on = {
          PAUSE = "paused",
          STOP  = "idle",
        },
      },
      paused = {
        on = {
          RESUME = "running",
          STOP   = "idle",
        },
      },
    },
  })
end

-- ── Basic transitions ──────────────────────────────────────────────────────────

T.describe("basic transitions", function()
  T.it("starts in initial state", function()
    local sm = make_basic()
    T.eq(sm:state(), "idle")
  end)

  T.it("transitions on valid event", function()
    local sm = make_basic()
    local ok = sm:send("START")
    T.eq(ok, true)
    T.eq(sm:state(), "running")
  end)

  T.it("returns false for unknown event", function()
    local sm = make_basic()
    local ok = sm:send("UNKNOWN")
    T.eq(ok, false)
    T.eq(sm:state(), "idle")
  end)

  T.it("returns false for event not valid in current state", function()
    local sm = make_basic()
    -- PAUSE is only valid from running
    local ok = sm:send("PAUSE")
    T.eq(ok, false)
    T.eq(sm:state(), "idle")
  end)

  T.it("self-transition (RESET in idle)", function()
    local sm = make_basic()
    local ok = sm:send("RESET")
    T.eq(ok, true)
    T.eq(sm:state(), "idle")
  end)

  T.it("chains transitions", function()
    local sm = make_basic()
    sm:send("START")
    sm:send("PAUSE")
    T.eq(sm:state(), "paused")
    sm:send("RESUME")
    T.eq(sm:state(), "running")
    sm:send("STOP")
    T.eq(sm:state(), "idle")
  end)
end)

-- ── can() query ────────────────────────────────────────────────────────────────

T.describe("can()", function()
  T.it("returns true for valid event in current state", function()
    local sm = make_basic()
    T.eq(sm:can("START"), true)
  end)

  T.it("returns false for event not in current state", function()
    local sm = make_basic()
    T.eq(sm:can("PAUSE"), false)
  end)

  T.it("returns false after transitioning away", function()
    local sm = make_basic()
    sm:send("START")
    T.eq(sm:can("START"), false)
    T.eq(sm:can("PAUSE"), true)
  end)
end)

-- ── Guards ─────────────────────────────────────────────────────────────────────

T.describe("guards", function()
  local function make_turnstile()
    return SM.new({
      initial = "locked",
      states = {
        locked = {
          on = {
            INSERT_COIN = { target = "unlocked", guard = function(ctx) return ctx.coins >= 1 end },
          },
        },
        unlocked = {
          on = {
            PUSH = "locked",
            COIN = "unlocked",
          },
        },
      },
      context = { coins = 0 },
    })
  end

  T.it("blocks transition when guard returns false", function()
    local sm = make_turnstile()
    local ok = sm:send("INSERT_COIN")
    T.eq(ok, false)
    T.eq(sm:state(), "locked")
  end)

  T.it("allows transition when guard returns true", function()
    local sm = make_turnstile()
    sm.context.coins = 1
    local ok = sm:send("INSERT_COIN")
    T.eq(ok, true)
    T.eq(sm:state(), "unlocked")
  end)

  T.it("can() respects guard", function()
    local sm = make_turnstile()
    T.eq(sm:can("INSERT_COIN"), false)
    sm.context.coins = 1
    T.eq(sm:can("INSERT_COIN"), true)
  end)
end)

-- ── Actions ────────────────────────────────────────────────────────────────────

T.describe("actions", function()
  local function make_toggle()
    return SM.new({
      initial = "off",
      states = {
        off = {
          on = {
            TOGGLE = { target = "on", action = function(ctx) ctx.count = ctx.count + 1 end },
          },
        },
        on = {
          on = {
            TOGGLE = { target = "off", action = function(ctx) ctx.count = ctx.count + 1 end },
          },
        },
      },
      context = { count = 0 },
    })
  end

  T.it("action called on transition", function()
    local sm = make_toggle()
    sm:send("TOGGLE")
    T.eq(sm.context.count, 1)
  end)

  T.it("action called multiple times", function()
    local sm = make_toggle()
    sm:send("TOGGLE")
    sm:send("TOGGLE")
    sm:send("TOGGLE")
    T.eq(sm.context.count, 3)
  end)

  T.it("action not called when guard blocks", function()
    local sm = SM.new({
      initial = "a",
      states = {
        a = {
          on = {
            GO = { target = "b", guard = function() return false end, action = function(ctx) ctx.called = true end },
          },
        },
        b = { on = {} },
      },
      context = { called = false },
    })
    sm:send("GO")
    T.eq(sm.context.called, false)
  end)
end)

-- ── on_enter / on_exit hooks ───────────────────────────────────────────────────

T.describe("on_enter / on_exit", function()
  local function make_hooked()
    local log = {}
    local sm = SM.new({
      initial = "a",
      states = {
        a = {
          on_enter = function() log[#log + 1] = "enter_a" end,
          on_exit  = function() log[#log + 1] = "exit_a"  end,
          on = { NEXT = "b" },
        },
        b = {
          on_enter = function() log[#log + 1] = "enter_b" end,
          on_exit  = function() log[#log + 1] = "exit_b"  end,
          on = { NEXT = "a" },
        },
      },
    })
    return sm, log
  end

  T.it("on_enter called for initial state", function()
    local _, log = make_hooked()
    T.eq(log[1], "enter_a")
  end)

  T.it("on_exit and on_enter called on transition", function()
    local sm, log = make_hooked()
    -- log already has "enter_a" at index 1
    sm:send("NEXT")
    T.eq(log[2], "exit_a")
    T.eq(log[3], "enter_b")
  end)

  T.it("hooks fire in correct order across multiple transitions", function()
    local sm, log = make_hooked()
    sm:send("NEXT")   -- a→b
    sm:send("NEXT")   -- b→a
    -- log: enter_a, exit_a, enter_b, exit_b, enter_a
    T.eq(log[1], "enter_a")
    T.eq(log[2], "exit_a")
    T.eq(log[3], "enter_b")
    T.eq(log[4], "exit_b")
    T.eq(log[5], "enter_a")
  end)

  T.it("on_exit not called when transition is blocked by guard", function()
    local exited = false
    local sm = SM.new({
      initial = "a",
      states = {
        a = {
          on_exit = function() exited = true end,
          on = {
            GO = { target = "b", guard = function() return false end },
          },
        },
        b = { on = {} },
      },
    })
    sm:send("GO")
    T.eq(exited, false)
  end)
end)

-- ── context ────────────────────────────────────────────────────────────────────

T.describe("context", function()
  T.it("context is accessible in guard and action", function()
    local sm = SM.new({
      initial = "start",
      states = {
        start = {
          on = {
            GO = {
              target = "done",
              guard  = function(ctx) return ctx.ready end,
              action = function(ctx) ctx.fired = true end,
            },
          },
        },
        done = { on = {} },
      },
      context = { ready = false, fired = false },
    })
    sm:send("GO")
    T.eq(sm.context.fired, false)
    sm.context.ready = true
    sm:send("GO")
    T.eq(sm.context.fired, true)
  end)

  T.it("context initialised from def", function()
    local sm = SM.new({
      initial = "s",
      states  = { s = { on = {} } },
      context = { x = 42 },
    })
    T.eq(sm.context.x, 42)
  end)

  T.it("context def table is not mutated by machine", function()
    local ctx = { x = 1 }
    local sm = SM.new({
      initial = "s",
      states  = { s = { on = {} } },
      context = ctx,
    })
    sm.context.x = 99
    T.eq(ctx.x, 1)
  end)
end)

-- ── states() / transitions() introspection ─────────────────────────────────────

T.describe("introspection", function()
  T.it("states() returns all state names sorted", function()
    local sm = make_basic()
    local list = sm:states()
    T.eq(list[1], "idle")
    T.eq(list[2], "paused")
    T.eq(list[3], "running")
    T.eq(#list, 3)
  end)

  T.it("transitions() returns all {from, event, to} triples", function()
    local sm = SM.new({
      initial = "a",
      states = {
        a = { on = { X = "b", Y = "a" } },
        b = { on = { Z = "a" } },
      },
    })
    local trs = sm:transitions()
    T.eq(#trs, 3)
    -- Sorted by from then event.
    T.eq(trs[1].from,  "a")
    T.eq(trs[1].event, "X")
    T.eq(trs[1].to,    "b")
    T.eq(trs[2].from,  "a")
    T.eq(trs[2].event, "Y")
    T.eq(trs[2].to,    "a")
    T.eq(trs[3].from,  "b")
    T.eq(trs[3].event, "Z")
    T.eq(trs[3].to,    "a")
  end)
end)

-- ── snapshot / restore ─────────────────────────────────────────────────────────

T.describe("snapshot / restore", function()
  local def = {
    initial = "idle",
    states = {
      idle    = { on = { START = "running" } },
      running = { on = { STOP = "idle" } },
    },
    context = { count = 0 },
  }

  T.it("snapshot captures state and context", function()
    local sm = SM.new(def)
    sm:send("START")
    sm.context.count = 7
    local snap = sm:snapshot()
    T.eq(snap.state, "running")
    T.eq(snap.context.count, 7)
  end)

  T.it("snapshot context is a copy, not a reference", function()
    local sm = SM.new(def)
    local snap = sm:snapshot()
    snap.context.count = 99
    T.eq(sm.context.count, 0)
  end)

  T.it("restore reconstructs state and context", function()
    local sm = SM.new(def)
    sm:send("START")
    sm.context.count = 5
    local snap = sm:snapshot()

    local sm2 = SM.restore(def, snap)
    T.eq(sm2:state(), "running")
    T.eq(sm2.context.count, 5)
  end)

  T.it("restored machine can continue transitioning", function()
    local sm = SM.new(def)
    sm:send("START")
    local snap = sm:snapshot()

    local sm2 = SM.restore(def, snap)
    local ok = sm2:send("STOP")
    T.eq(ok, true)
    T.eq(sm2:state(), "idle")
  end)

  T.it("restore does not call on_enter", function()
    local entered = 0
    local def2 = {
      initial = "a",
      states = {
        a = {
          on_enter = function() entered = entered + 1 end,
          on = { GO = "b" },
        },
        b = { on = {} },
      },
    }
    -- new() fires on_enter for initial state.
    SM.new(def2)
    T.eq(entered, 1)
    -- restore() must NOT fire on_enter again.
    SM.restore(def2, { state = "a", context = {} })
    T.eq(entered, 1)
  end)

  T.it("restore returns error for invalid snap.state", function()
    local sm2, err = SM.restore(def, { state = "nonexistent", context = {} })
    T.eq(sm2, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ── Error cases ────────────────────────────────────────────────────────────────

T.describe("error cases", function()
  T.it("error when initial state not in states", function()
    local sm, err = SM.new({
      initial = "missing",
      states  = { a = { on = {} } },
    })
    T.eq(sm, nil)
    T.ok(type(err) == "string")
  end)

  T.it("error when transition target is not a defined state", function()
    local sm, err = SM.new({
      initial = "a",
      states  = { a = { on = { GO = "undefined_state" } } },
    })
    T.eq(sm, nil)
    T.ok(type(err) == "string")
  end)

  T.it("error when def is not a table", function()
    local sm, err = SM.new("not a table")
    T.eq(sm, nil)
    T.ok(type(err) == "string")
  end)

  T.it("error when def.initial is missing", function()
    local sm, err = SM.new({ states = { a = { on = {} } } })
    T.eq(sm, nil)
    T.ok(type(err) == "string")
  end)

  T.it("error when def.states is missing", function()
    local sm, err = SM.new({ initial = "a" })
    T.eq(sm, nil)
    T.ok(type(err) == "string")
  end)
end)
