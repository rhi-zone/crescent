if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local hsm = require("lib.state_machine_hsm")

-- ── Simple FSM ────────────────────────────────────────────────────────────────

T.describe("simple FSM", function()
  T.it("transitions between flat states", function()
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle   = { on = { START = "running" } },
        running = { on = { STOP = "idle" } },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "idle")
    m:send("START")
    T.eq(m:state(), "running")
    m:send("STOP")
    T.eq(m:state(), "idle")
  end)
end)

-- ── Nested states ─────────────────────────────────────────────────────────────

T.describe("nested states", function()
  T.it("enters initial child on start", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        active = {
          initial = "running",
          states = {
            running = { on = { PAUSE = "active.paused" } },
            paused  = { on = { RESUME = "active.running" } },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "active.running")
  end)

  T.it("transitions between sibling child states", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        active = {
          initial = "running",
          states = {
            running = { on = { PAUSE = "active.paused" } },
            paused  = { on = { RESUME = "active.running" } },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    m:send("PAUSE")
    T.eq(m:state(), "active.paused")
    m:send("RESUME")
    T.eq(m:state(), "active.running")
  end)

  T.it("transitions from child to sibling of parent", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        idle   = {},
        active = {
          initial = "running",
          states = {
            running = { on = { STOP = "idle" } },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "active.running")
    m:send("STOP")
    T.eq(m:state(), "idle")
  end)
end)

-- ── Entry/exit order ──────────────────────────────────────────────────────────

T.describe("entry/exit order", function()
  T.it("fires parent entry before child entry on start", function()
    local log = {}
    local chart = hsm.chart({
      initial = "outer",
      states = {
        outer = {
          initial = "inner",
          entry   = function() log[#log+1] = "outer:entry" end,
          exit    = function() log[#log+1] = "outer:exit" end,
          states = {
            inner = {
              entry = function() log[#log+1] = "inner:entry" end,
              exit  = function() log[#log+1] = "inner:exit" end,
            },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(log[1], "outer:entry")
    T.eq(log[2], "inner:entry")
  end)

  T.it("fires child exit before parent exit on transition out", function()
    local log = {}
    local chart = hsm.chart({
      initial = "active",
      states = {
        idle = {},
        active = {
          initial = "running",
          exit    = function() log[#log+1] = "active:exit" end,
          states = {
            running = {
              on   = { STOP = "idle" },
              exit = function() log[#log+1] = "running:exit" end,
            },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    m:send("STOP")
    T.eq(log[1], "running:exit")
    T.eq(log[2], "active:exit")
  end)

  T.it("sibling transition does not re-enter parent", function()
    local log = {}
    local chart = hsm.chart({
      initial = "active",
      states = {
        active = {
          initial = "a",
          entry   = function() log[#log+1] = "active:entry" end,
          exit    = function() log[#log+1] = "active:exit" end,
          states = {
            a = {
              on    = { NEXT = "active.b" },
              entry = function() log[#log+1] = "a:entry" end,
              exit  = function() log[#log+1] = "a:exit" end,
            },
            b = {
              entry = function() log[#log+1] = "b:entry" end,
              exit  = function() log[#log+1] = "b:exit" end,
            },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    log = {}  -- clear start entries
    m:send("NEXT")
    -- Should be: a:exit, b:entry (NOT active:exit/active:entry)
    T.eq(#log, 2)
    T.eq(log[1], "a:exit")
    T.eq(log[2], "b:entry")
  end)
end)

-- ── in_state ─────────────────────────────────────────────────────────────────

T.describe("in_state", function()
  T.it("returns true for exact leaf state", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        active = {
          initial = "running",
          states = {
            running = {},
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.ok(m:in_state("active.running"))
  end)

  T.it("returns true for parent state when in child", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        active = {
          initial = "running",
          states = {
            running = {},
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.ok(m:in_state("active"))
  end)

  T.it("returns false for unrelated state", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        idle   = {},
        active = {
          initial = "running",
          states  = { running = {} },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:in_state("idle"), false)
  end)
end)

-- ── Guard ─────────────────────────────────────────────────────────────────────

T.describe("guard", function()
  T.it("blocks transition when guard returns false", function()
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle    = { on = { GO = { target = "active", guard = function() return false end } } },
        active  = {},
      },
    })
    local m = chart:machine()
    m:start()
    local handled = m:send("GO")
    T.eq(handled, false)
    T.eq(m:state(), "idle")
  end)

  T.it("allows transition when guard returns true", function()
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle   = { on = { GO = { target = "active", guard = function() return true end } } },
        active = {},
      },
    })
    local m = chart:machine()
    m:start()
    local handled = m:send("GO")
    T.ok(handled)
    T.eq(m:state(), "active")
  end)

  T.it("guard receives context and event data", function()
    local got_ctx, got_data
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle   = {
          on = { GO = {
            target = "active",
            guard  = function(ctx, data) got_ctx = ctx; got_data = data; return true end,
          }}
        },
        active = {},
      },
    })
    local m = chart:machine({ context = { x = 42 } })
    m:start()
    m:send("GO", "payload")
    T.eq(got_ctx.x, 42)
    T.eq(got_data, "payload")
  end)
end)

-- ── Action ────────────────────────────────────────────────────────────────────

T.describe("action", function()
  T.it("mutates context on transition", function()
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle = {
          on = { INC = {
            target = "idle",
            action = function(ctx) ctx.count = ctx.count + 1 end,
          }},
        },
      },
    })
    local m = chart:machine({ context = { count = 0 } })
    m:start()
    m:send("INC")
    m:send("INC")
    T.eq(m:context().count, 2)
  end)
end)

-- ── History (shallow) ─────────────────────────────────────────────────────────

T.describe("shallow history", function()
  T.it("re-entering parent resumes last child", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        idle = { on = { RESUME = "active" } },
        active = {
          initial  = "a",
          history  = "shallow",
          states = {
            a = { on = { NEXT = "active.b" } },
            b = { on = { PAUSE = "idle" } },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "active.a")
    m:send("NEXT")
    T.eq(m:state(), "active.b")
    m:send("PAUSE")
    T.eq(m:state(), "idle")
    -- Re-enter active: should resume at b (last child)
    m:send("RESUME")
    T.eq(m:state(), "active.b")
  end)

  T.it("without history, re-entering parent starts at initial", function()
    local chart = hsm.chart({
      initial = "active",
      states = {
        idle = { on = { RESUME = "active" } },
        active = {
          initial = "a",
          -- no history
          states = {
            a = { on = { NEXT = "active.b" } },
            b = { on = { PAUSE = "idle" } },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    m:send("NEXT")
    T.eq(m:state(), "active.b")
    m:send("PAUSE")
    m:send("RESUME")
    -- No history: goes to initial (a)
    T.eq(m:state(), "active.a")
  end)
end)

-- ── Self-transition ───────────────────────────────────────────────────────────

T.describe("self-transition", function()
  T.it("fires exit and entry for self-transition", function()
    local log = {}
    local chart = hsm.chart({
      initial = "idle",
      states = {
        idle = {
          on    = { RESET = "idle" },
          entry = function() log[#log+1] = "entry" end,
          exit  = function() log[#log+1] = "exit" end,
        },
      },
    })
    local m = chart:machine()
    m:start()
    log = {}
    m:send("RESET")
    T.eq(log[1], "exit")
    T.eq(log[2], "entry")
  end)
end)

-- ── Multiple nesting levels ───────────────────────────────────────────────────

T.describe("multiple nesting levels", function()
  T.it("navigates three levels deep", function()
    local chart = hsm.chart({
      initial = "a",
      states = {
        a = {
          initial = "b",
          states = {
            b = {
              initial = "c",
              states = {
                c = { on = { GO = "done" } },
              },
            },
          },
        },
        done = {},
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "a.b.c")
    T.ok(m:in_state("a"))
    T.ok(m:in_state("a.b"))
    T.ok(m:in_state("a.b.c"))
    m:send("GO")
    T.eq(m:state(), "done")
  end)

  T.it("exit fires innermost-first across multiple levels", function()
    local log = {}
    local chart = hsm.chart({
      initial = "a",
      states = {
        done = {},
        a = {
          initial = "b",
          exit    = function() log[#log+1] = "a:exit" end,
          states = {
            b = {
              initial = "c",
              exit    = function() log[#log+1] = "b:exit" end,
              states = {
                c = {
                  on   = { GO = "done" },
                  exit = function() log[#log+1] = "c:exit" end,
                },
              },
            },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    m:send("GO")
    T.eq(log[1], "c:exit")
    T.eq(log[2], "b:exit")
    T.eq(log[3], "a:exit")
  end)
end)

-- ── state() dot-notation path ─────────────────────────────────────────────────

T.describe("state() dot-notation", function()
  T.it("returns correct path for deeply nested state", function()
    local chart = hsm.chart({
      initial = "x",
      states = {
        x = {
          initial = "y",
          states = {
            y = {
              initial = "z",
              states  = { z = {} },
            },
          },
        },
      },
    })
    local m = chart:machine()
    m:start()
    T.eq(m:state(), "x.y.z")
  end)
end)
