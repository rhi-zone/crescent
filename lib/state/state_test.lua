if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local state = require("lib.state")

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Build a simple 3-state FSM: idle → running ↔ paused, running/paused → idle
local function make_basic()
  return state.machine({
    initial = "idle",
    states = {
      idle = {
        on = { start = "running" },
      },
      running = {
        on = {
          pause = "paused",
          stop  = "idle",
        },
      },
      paused = {
        on = {
          resume = "running",
          stop   = "idle",
        },
      },
    },
  })
end

-- ── Initial state ─────────────────────────────────────────────────────────────

T.describe("initial state", function()
  T.it("starts in the declared initial state", function()
    local fsm = make_basic()
    T.eq(fsm:state(), "idle")
  end)

  T.it("matches() is true for initial state", function()
    local fsm = make_basic()
    T.ok(fsm:matches("idle"))
  end)

  T.it("matches() is false for non-current state", function()
    local fsm = make_basic()
    T.ok(not fsm:matches("running"))
    T.ok(not fsm:matches("paused"))
  end)
end)

-- ── Basic transitions ─────────────────────────────────────────────────────────

T.describe("basic transitions", function()
  T.it("send() returns true on valid transition", function()
    local fsm = make_basic()
    local ok = fsm:send("start")
    T.ok(ok == true)
  end)

  T.it("state changes after send()", function()
    local fsm = make_basic()
    fsm:send("start")
    T.eq(fsm:state(), "running")
  end)

  T.it("chains multiple transitions", function()
    local fsm = make_basic()
    fsm:send("start")
    fsm:send("pause")
    T.eq(fsm:state(), "paused")
    fsm:send("resume")
    T.eq(fsm:state(), "running")
    fsm:send("stop")
    T.eq(fsm:state(), "idle")
  end)

  T.it("unknown event returns (nil, errmsg)", function()
    local fsm = make_basic()
    local ok, err = fsm:send("bogus")
    T.ok(ok == nil)
    T.ok(type(err) == "string")
    T.ok(err:find("bogus") ~= nil)
  end)

  T.it("event not valid in current state returns (nil, errmsg)", function()
    local fsm = make_basic()
    -- 'pause' is only valid in running, not idle
    local ok, err = fsm:send("pause")
    T.ok(ok == nil)
    T.ok(type(err) == "string")
  end)

  T.it("state does not change on failed transition", function()
    local fsm = make_basic()
    fsm:send("bogus")
    T.eq(fsm:state(), "idle")
  end)

  T.it("stop from paused goes to idle", function()
    local fsm = make_basic()
    fsm:send("start")
    fsm:send("pause")
    fsm:send("stop")
    T.eq(fsm:state(), "idle")
  end)
end)

-- ── can() predicate ───────────────────────────────────────────────────────────

T.describe("can()", function()
  T.it("returns true for a valid event in current state", function()
    local fsm = make_basic()
    T.ok(fsm:can("start"))
  end)

  T.it("returns false for an invalid event in current state", function()
    local fsm = make_basic()
    T.ok(not fsm:can("pause"))
    T.ok(not fsm:can("stop"))
    T.ok(not fsm:can("resume"))
  end)

  T.it("updates after a transition", function()
    local fsm = make_basic()
    fsm:send("start")
    T.ok(not fsm:can("start"))
    T.ok(fsm:can("pause"))
    T.ok(fsm:can("stop"))
  end)

  T.it("returns false for completely unknown event", function()
    local fsm = make_basic()
    T.ok(not fsm:can("nonexistent"))
  end)
end)

-- ── entry / exit callbacks ────────────────────────────────────────────────────

T.describe("entry/exit callbacks", function()
  T.it("entry is called when entering a state", function()
    local entered = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = { on = { go = "b" } },
        b = {
          on = { go = "c" },
          entry = function() entered[#entered+1] = "b" end,
        },
        c = {
          entry = function() entered[#entered+1] = "c" end,
        },
      },
    })
    T.eq(#entered, 0)
    fsm:send("go")
    T.eq(#entered, 1)
    T.eq(entered[1], "b")
    fsm:send("go")
    T.eq(#entered, 2)
    T.eq(entered[2], "c")
  end)

  T.it("exit is called when leaving a state", function()
    local exited = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {
          on = { go = "b" },
          exit = function() exited[#exited+1] = "a" end,
        },
        b = {
          on = { go = "c" },
          exit = function() exited[#exited+1] = "b" end,
        },
        c = {},
      },
    })
    T.eq(#exited, 0)
    fsm:send("go")
    T.eq(#exited, 1)
    T.eq(exited[1], "a")
    fsm:send("go")
    T.eq(#exited, 2)
    T.eq(exited[2], "b")
  end)

  T.it("exit is called before entry on the same transition", function()
    local order = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {
          on = { go = "b" },
          exit  = function() order[#order+1] = "exit_a" end,
        },
        b = {
          entry = function() order[#order+1] = "entry_b" end,
        },
      },
    })
    fsm:send("go")
    T.eq(#order, 2)
    T.eq(order[1], "exit_a")
    T.eq(order[2], "entry_b")
  end)

  T.it("entry is called for the initial state at construction", function()
    local entered = {}
    state.machine({
      initial = "init",
      states = {
        init = {
          entry = function() entered[#entered+1] = "init" end,
        },
      },
    })
    T.eq(#entered, 1)
    T.eq(entered[1], "init")
  end)

  T.it("entry/exit not called on failed transition", function()
    local calls = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {
          on = { go = "b" },
          exit  = function() calls[#calls+1] = "exit_a" end,
        },
        b = {
          entry = function() calls[#calls+1] = "entry_b" end,
        },
      },
    })
    fsm:send("bogus")
    T.eq(#calls, 0)
  end)
end)

-- ── on_transition listeners ───────────────────────────────────────────────────

T.describe("on_transition listeners", function()
  T.it("listener is called with correct (from, to, event, data)", function()
    local fsm = make_basic()
    local calls = {}
    fsm:on_transition(function(from, to, event, data)
      calls[#calls+1] = { from=from, to=to, event=event, data=data }
    end)
    fsm:send("start", 42)
    T.eq(#calls, 1)
    T.eq(calls[1].from,  "idle")
    T.eq(calls[1].to,    "running")
    T.eq(calls[1].event, "start")
    T.eq(calls[1].data,  42)
  end)

  T.it("listener is NOT called on failed transition", function()
    local fsm = make_basic()
    local calls = {}
    fsm:on_transition(function() calls[#calls+1] = true end)
    fsm:send("bogus")
    T.eq(#calls, 0)
  end)

  T.it("multiple listeners are all called in registration order", function()
    local fsm = make_basic()
    local order = {}
    fsm:on_transition(function() order[#order+1] = 1 end)
    fsm:on_transition(function() order[#order+1] = 2 end)
    fsm:on_transition(function() order[#order+1] = 3 end)
    fsm:send("start")
    T.eq(#order, 3)
    T.eq(order[1], 1)
    T.eq(order[2], 2)
    T.eq(order[3], 3)
  end)

  T.it("listener receives nil data when not provided", function()
    local fsm = make_basic()
    local received_data = "sentinel"
    fsm:on_transition(function(_, _, _, data) received_data = data end)
    fsm:send("start")
    T.ok(received_data == nil)
  end)
end)

-- ── reset() ───────────────────────────────────────────────────────────────────

T.describe("reset()", function()
  T.it("returns to initial state", function()
    local fsm = make_basic()
    fsm:send("start")
    fsm:send("pause")
    T.eq(fsm:state(), "paused")
    fsm:reset()
    T.eq(fsm:state(), "idle")
  end)

  T.it("allows events from initial state after reset", function()
    local fsm = make_basic()
    fsm:send("start")
    fsm:reset()
    local ok = fsm:send("start")
    T.ok(ok == true)
    T.eq(fsm:state(), "running")
  end)

  T.it("notifies listeners on reset when state changes", function()
    local fsm = make_basic()
    local calls = {}
    fsm:on_transition(function(from, to, event, _)
      calls[#calls+1] = { from=from, to=to, event=event }
    end)
    fsm:send("start")
    fsm:reset()
    -- calls[1] = start transition, calls[2] = reset
    T.eq(#calls, 2)
    T.eq(calls[2].from,  "running")
    T.eq(calls[2].to,    "idle")
    T.eq(calls[2].event, "__reset__")
  end)

  T.it("reset when already in initial state does NOT notify listeners", function()
    local fsm = make_basic()
    local calls = {}
    fsm:on_transition(function() calls[#calls+1] = true end)
    fsm:reset()  -- already idle
    T.eq(#calls, 0)
  end)

  T.it("exit called for current state on reset", function()
    local exited = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {},
        b = {
          on   = { back = "a" },
          exit = function() exited[#exited+1] = "b" end,
        },
      },
    })
    -- manually override to b to test reset
    fsm._current = "b"
    fsm:reset()
    T.eq(#exited, 1)
    T.eq(exited[1], "b")
  end)
end)

-- ── Guard conditions ──────────────────────────────────────────────────────────

T.describe("guard conditions", function()
  T.it("transition is allowed when guard returns true", function()
    local fsm = state.machine({
      initial = "locked",
      states = {
        locked = {
          on = {
            insert_coin = {
              target = "unlocked",
              guard  = function(_, data) return data and data.amount >= 25 end,
            },
          },
        },
        unlocked = {},
      },
    })
    local ok = fsm:send("insert_coin", { amount = 25 })
    T.ok(ok == true)
    T.eq(fsm:state(), "unlocked")
  end)

  T.it("transition is blocked when guard returns false", function()
    local fsm = state.machine({
      initial = "locked",
      states = {
        locked = {
          on = {
            insert_coin = {
              target = "unlocked",
              guard  = function(_, data) return data and data.amount >= 25 end,
            },
          },
        },
        unlocked = {},
      },
    })
    local ok, err = fsm:send("insert_coin", { amount = 10 })
    T.ok(ok == nil)
    T.ok(type(err) == "string")
    T.eq(fsm:state(), "locked")
  end)

  T.it("can() returns false when guard would block", function()
    local fsm = state.machine({
      initial = "locked",
      states = {
        locked = {
          on = {
            insert_coin = {
              target = "unlocked",
              guard  = function() return false end,
            },
          },
        },
        unlocked = {},
      },
    })
    T.ok(not fsm:can("insert_coin"))
  end)

  T.it("data is passed to guard", function()
    local received = nil
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {
          on = {
            go = {
              target = "b",
              guard  = function(_, data)
                received = data
                return true
              end,
            },
          },
        },
        b = {},
      },
    })
    local payload = { x = 99 }
    fsm:send("go", payload)
    T.ok(received == payload)
  end)

  T.it("entry/exit not called when guard blocks", function()
    local calls = {}
    local fsm = state.machine({
      initial = "a",
      states = {
        a = {
          on = {
            go = {
              target = "b",
              guard  = function() return false end,
            },
          },
          exit  = function() calls[#calls+1] = "exit_a" end,
        },
        b = {
          entry = function() calls[#calls+1] = "entry_b" end,
        },
      },
    })
    fsm:send("go")
    T.eq(#calls, 0)
  end)
end)

-- ── Data passed to callbacks ──────────────────────────────────────────────────

T.describe("data in callbacks", function()
  T.it("context passed to entry/exit", function()
    local ctx = { log = {} }
    local fsm = state.machine({
      initial = "a",
      context = ctx,
      states = {
        a = {
          on   = { go = "b" },
          exit = function(c) c.log[#c.log+1] = "exit_a" end,
        },
        b = {
          entry = function(c) c.log[#c.log+1] = "entry_b" end,
        },
      },
    })
    fsm:send("go")
    T.eq(ctx.log[1], "exit_a")
    T.eq(ctx.log[2], "entry_b")
  end)

  T.it("action callback receives ctx and data", function()
    local got_ctx, got_data
    local ctx = { id = "myctx" }
    local fsm = state.machine({
      initial = "a",
      context = ctx,
      states = {
        a = {
          on = {
            go = {
              target = "b",
              action = function(c, d)
                got_ctx = c
                got_data = d
              end,
            },
          },
        },
        b = {},
      },
    })
    fsm:send("go", "hello")
    T.ok(got_ctx == ctx)
    T.eq(got_data, "hello")
  end)
end)

-- ── history() ────────────────────────────────────────────────────────────────

T.describe("history()", function()
  T.it("returns a table", function()
    local fsm = make_basic()
    T.ok(type(fsm:history()) == "table")
  end)

  T.it("records visited states after transitions", function()
    local fsm = make_basic()
    fsm:send("start")
    local h = fsm:history()
    T.ok(h["idle"] ~= nil)
  end)

  T.it("history persists across multiple transitions", function()
    local fsm = make_basic()
    fsm:send("start")
    fsm:send("pause")
    local h = fsm:history()
    T.ok(h["idle"] ~= nil)
    T.ok(h["running"] ~= nil)
  end)
end)

-- ── Traffic light example ────────────────────────────────────────────────────

T.describe("traffic light (3-state cycle)", function()
  local function make_light()
    return state.machine({
      initial = "red",
      states = {
        red    = { on = { next = "green"  } },
        green  = { on = { next = "yellow" } },
        yellow = { on = { next = "red"    } },
      },
    })
  end

  T.it("starts red", function()
    local light = make_light()
    T.eq(light:state(), "red")
  end)

  T.it("red → green → yellow → red cycle", function()
    local light = make_light()
    light:send("next")
    T.eq(light:state(), "green")
    light:send("next")
    T.eq(light:state(), "yellow")
    light:send("next")
    T.eq(light:state(), "red")
  end)

  T.it("full two-cycle run", function()
    local light = make_light()
    local seq = {}
    for _ = 1, 6 do
      light:send("next")
      seq[#seq+1] = light:state()
    end
    T.eq(seq[1], "green")
    T.eq(seq[2], "yellow")
    T.eq(seq[3], "red")
    T.eq(seq[4], "green")
    T.eq(seq[5], "yellow")
    T.eq(seq[6], "red")
  end)

  T.it("invalid event in red returns error", function()
    local light = make_light()
    local ok, err = light:send("stop")
    T.ok(ok == nil)
    T.ok(type(err) == "string")
  end)

  T.it("can() true only for 'next'", function()
    local light = make_light()
    T.ok(light:can("next"))
    T.ok(not light:can("stop"))
    T.ok(not light:can("go"))
  end)
end)

-- ── Turnstile example ────────────────────────────────────────────────────────

T.describe("turnstile (locked/unlocked with guard)", function()
  local function make_turnstile(min_coins)
    min_coins = min_coins or 1
    return state.machine({
      initial = "locked",
      states = {
        locked = {
          on = {
            coin = {
              target = "unlocked",
              guard  = function(_, data)
                return type(data) == "number" and data >= min_coins
              end,
            },
          },
        },
        unlocked = {
          on = {
            push  = "locked",
            coin  = "unlocked",   -- return coin, stay unlocked
          },
        },
      },
    })
  end

  T.it("starts locked", function()
    local t = make_turnstile()
    T.eq(t:state(), "locked")
  end)

  T.it("coin (valid) unlocks", function()
    local t = make_turnstile()
    local ok = t:send("coin", 1)
    T.ok(ok == true)
    T.eq(t:state(), "unlocked")
  end)

  T.it("coin (invalid) stays locked", function()
    local t = make_turnstile()
    local ok, err = t:send("coin", 0)
    T.ok(ok == nil)
    T.ok(type(err) == "string")
    T.eq(t:state(), "locked")
  end)

  T.it("push when unlocked locks again", function()
    local t = make_turnstile()
    t:send("coin", 1)
    t:send("push")
    T.eq(t:state(), "locked")
  end)

  T.it("push when locked returns error", function()
    local t = make_turnstile()
    local ok, err = t:send("push")
    T.ok(ok == nil)
    T.ok(type(err) == "string")
  end)

  T.it("coin when unlocked stays unlocked", function()
    local t = make_turnstile()
    t:send("coin", 1)
    t:send("coin", 999)
    T.eq(t:state(), "unlocked")
  end)

  T.it("full locked→unlocked→locked sequence", function()
    local t = make_turnstile()
    T.ok(t:matches("locked"))
    t:send("coin", 1)
    T.ok(t:matches("unlocked"))
    t:send("push")
    T.ok(t:matches("locked"))
  end)

  T.it("on_transition tracks sequence correctly", function()
    local t = make_turnstile()
    local history = {}
    t:on_transition(function(from, to, event, _)
      history[#history+1] = { from=from, to=to, event=event }
    end)
    t:send("coin", 1)
    t:send("push")
    T.eq(#history, 2)
    T.eq(history[1].from,  "locked")
    T.eq(history[1].to,    "unlocked")
    T.eq(history[1].event, "coin")
    T.eq(history[2].from,  "unlocked")
    T.eq(history[2].to,    "locked")
    T.eq(history[2].event, "push")
  end)
end)

-- ── Metadata ─────────────────────────────────────────────────────────────────

T.describe("module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(state._tier, "pure")
  end)
end)
