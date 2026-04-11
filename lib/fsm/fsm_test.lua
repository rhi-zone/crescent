if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fsm = require("lib.fsm")

-- Helper: basic traffic light machine
local function traffic_light()
  return fsm.new({
    initial = "red",
    states = { red = {}, yellow = {}, green = {} },
    transitions = {
      { from = "red",    to = "green",  event = "go" },
      { from = "green",  to = "yellow", event = "slow" },
      { from = "yellow", to = "red",    event = "stop" },
    },
  })
end

T.describe("fsm", function()

  T.describe("new", function()
    T.it("creates a machine from valid config", function()
      local m, err = traffic_light()
      T.ok(m, "machine created")
      T.eq(err, nil)
    end)

    T.it("returns error when config is nil", function()
      local m, err = fsm.new(nil)
      T.eq(m, nil)
      T.eq(err, "config is required")
    end)

    T.it("returns error when initial is missing", function()
      local m, err = fsm.new({ states = {}, transitions = {} })
      T.eq(m, nil)
      T.eq(err, "initial state is required")
    end)

    T.it("returns error when states is missing", function()
      local m, err = fsm.new({ initial = "a", transitions = {} })
      T.eq(m, nil)
      T.eq(err, "states table is required")
    end)

    T.it("returns error when transitions is missing", function()
      local m, err = fsm.new({ initial = "a", states = { a = {} } })
      T.eq(m, nil)
      T.eq(err, "transitions table is required")
    end)

    T.it("returns error when initial state not in states", function()
      local m, err = fsm.new({ initial = "x", states = { a = {} }, transitions = {} })
      T.eq(m, nil)
      T.ok(err:find("initial state 'x' is not in states"))
    end)

    T.it("returns error when transition references unknown to-state", function()
      local m, err = fsm.new({
        initial = "a",
        states = { a = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      T.eq(m, nil)
      T.ok(err:find("unknown state 'b'"))
    end)

    T.it("returns error when transition references unknown from-state", function()
      local m, err = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "z", to = "b", event = "go" } },
      })
      T.eq(m, nil)
      T.ok(err:find("unknown state 'z'"))
    end)

    T.it("returns error when transition missing event", function()
      local m, err = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b" } },
      })
      T.eq(m, nil)
      T.ok(err:find("missing event"))
    end)

    T.it("returns error when transition from-array references unknown state", function()
      local m, err = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = { "a", "z" }, to = "b", event = "go" } },
      })
      T.eq(m, nil)
      T.ok(err:find("unknown state 'z'"))
    end)
  end)

  T.describe("start", function()
    T.it("starts in the initial state", function()
      local machine = traffic_light()
      local m = machine:start()
      T.eq(m:state(), "red")
    end)

    T.it("accepts initial context", function()
      local machine = traffic_light()
      local m = machine:start({ count = 0 })
      T.eq(m:context().count, 0)
    end)

    T.it("defaults to empty context", function()
      local machine = traffic_light()
      local m = machine:start()
      T.ok(m:context())
      T.eq(next(m:context()), nil)
    end)

    T.it("fires on_enter for initial state", function()
      local entered = false
      local machine = fsm.new({
        initial = "a",
        states = { a = { on_enter = function() entered = true end }, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      T.eq(entered, false)
      machine:start()
      T.eq(entered, true)
    end)
  end)

  T.describe("send", function()
    T.it("transitions between states", function()
      local machine = traffic_light()
      local m = machine:start()
      T.eq(m:state(), "red")
      local ok = m:send("go")
      T.eq(ok, true)
      T.eq(m:state(), "green")
      m:send("slow")
      T.eq(m:state(), "yellow")
      m:send("stop")
      T.eq(m:state(), "red")
    end)

    T.it("returns nil and error for invalid transition", function()
      local machine = traffic_light()
      local m = machine:start()
      local ok, err = m:send("slow")
      T.eq(ok, nil)
      T.ok(err:find("no transition"))
      T.eq(m:state(), "red") -- state unchanged
    end)

    T.it("returns nil and error for unknown event", function()
      local machine = traffic_light()
      local m = machine:start()
      local ok, err = m:send("nonexistent")
      T.eq(ok, nil)
      T.ok(err:find("no transition"))
    end)

    T.it("passes event data to guards and actions", function()
      local received_data = nil
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
        actions = { go = function(ctx, data) received_data = data end },
      })
      local m = machine:start()
      m:send("go", { payload = 42 })
      T.ok(received_data)
      T.eq(received_data.payload, 42)
    end)
  end)

  T.describe("guards", function()
    T.it("blocks transition when guard returns false", function()
      local machine = fsm.new({
        initial = "locked",
        states = { locked = {}, unlocked = {} },
        transitions = { { from = "locked", to = "unlocked", event = "unlock" } },
        guards = { unlock = function(ctx) return ctx.has_key == true end },
      })
      local m = machine:start({ has_key = false })
      local ok, err = m:send("unlock")
      T.eq(ok, nil)
      T.ok(err:find("guard rejected"))
      T.eq(m:state(), "locked")
    end)

    T.it("allows transition when guard returns true", function()
      local machine = fsm.new({
        initial = "locked",
        states = { locked = {}, unlocked = {} },
        transitions = { { from = "locked", to = "unlocked", event = "unlock" } },
        guards = { unlock = function(ctx) return ctx.has_key == true end },
      })
      local m = machine:start({ has_key = true })
      local ok = m:send("unlock")
      T.eq(ok, true)
      T.eq(m:state(), "unlocked")
    end)

    T.it("guard receives event data", function()
      local received = nil
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
        guards = { go = function(ctx, data) received = data; return true end },
      })
      local m = machine:start()
      m:send("go", "hello")
      T.eq(received, "hello")
    end)
  end)

  T.describe("actions", function()
    T.it("fires action on transition", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
        actions = { go = function(ctx) ctx.went = true end },
      })
      local m = machine:start()
      T.eq(m:context().went, nil)
      m:send("go")
      T.eq(m:context().went, true)
    end)

    T.it("action does not fire when guard blocks", function()
      local fired = false
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
        guards = { go = function() return false end },
        actions = { go = function() fired = true end },
      })
      local m = machine:start()
      m:send("go")
      T.eq(fired, false)
    end)

    T.it("action can modify context", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {}, c = {} },
        transitions = {
          { from = "a", to = "b", event = "step" },
          { from = "b", to = "c", event = "step" },
        },
        actions = { step = function(ctx) ctx.count = (ctx.count or 0) + 1 end },
      })
      local m = machine:start()
      m:send("step")
      T.eq(m:context().count, 1)
      m:send("step")
      T.eq(m:context().count, 2)
    end)
  end)

  T.describe("on_enter / on_exit", function()
    T.it("calls on_exit then on_enter during transition", function()
      local log = {}
      local machine = fsm.new({
        initial = "a",
        states = {
          a = {
            on_exit = function() log[#log + 1] = "exit_a" end,
          },
          b = {
            on_enter = function() log[#log + 1] = "enter_b" end,
          },
        },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      local m = machine:start()
      m:send("go")
      T.eq(#log, 2)
      T.eq(log[1], "exit_a")
      T.eq(log[2], "enter_b")
    end)

    T.it("on_enter receives context", function()
      local got_ctx = nil
      local machine = fsm.new({
        initial = "a",
        states = {
          a = {},
          b = { on_enter = function(ctx) got_ctx = ctx end },
        },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      local m = machine:start({ val = 99 })
      m:send("go")
      T.ok(got_ctx)
      T.eq(got_ctx.val, 99)
    end)

    T.it("on_exit receives context", function()
      local got_ctx = nil
      local machine = fsm.new({
        initial = "a",
        states = {
          a = { on_exit = function(ctx) got_ctx = ctx end },
          b = {},
        },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      local m = machine:start({ val = 77 })
      m:send("go")
      T.ok(got_ctx)
      T.eq(got_ctx.val, 77)
    end)

    T.it("on_enter/on_exit not called when guard blocks", function()
      local called = false
      local machine = fsm.new({
        initial = "a",
        states = {
          a = { on_exit = function() called = true end },
          b = { on_enter = function() called = true end },
        },
        transitions = { { from = "a", to = "b", event = "go" } },
        guards = { go = function() return false end },
      })
      local m = machine:start()
      m:send("go")
      T.eq(called, false)
    end)

    T.it("callback order: on_exit -> action -> on_enter -> listeners", function()
      local log = {}
      local machine = fsm.new({
        initial = "a",
        states = {
          a = { on_exit = function() log[#log + 1] = "exit" end },
          b = { on_enter = function() log[#log + 1] = "enter" end },
        },
        transitions = { { from = "a", to = "b", event = "go" } },
        actions = { go = function() log[#log + 1] = "action" end },
      })
      machine:on_transition(function() log[#log + 1] = "listener" end)
      local m = machine:start()
      m:send("go")
      T.eq(log[1], "exit")
      T.eq(log[2], "action")
      T.eq(log[3], "enter")
      T.eq(log[4], "listener")
      T.eq(#log, 4)
    end)
  end)

  T.describe("multiple source states", function()
    T.it("allows transition from any listed source", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {}, c = {} },
        transitions = {
          { from = "a", to = "b", event = "next" },
          { from = { "a", "b" }, to = "c", event = "jump" },
        },
      })
      -- From a
      local m1 = machine:start()
      T.eq(m1:state(), "a")
      local ok = m1:send("jump")
      T.eq(ok, true)
      T.eq(m1:state(), "c")

      -- From b
      local m2 = machine:start()
      m2:send("next")
      T.eq(m2:state(), "b")
      ok = m2:send("jump")
      T.eq(ok, true)
      T.eq(m2:state(), "c")
    end)
  end)

  T.describe("wildcard from = '*'", function()
    T.it("matches any current state", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {}, c = {} },
        transitions = {
          { from = "a", to = "b", event = "next" },
          { from = "b", to = "c", event = "next" },
          { from = "*", to = "a", event = "reset" },
        },
      })
      local m = machine:start()
      m:send("next")
      T.eq(m:state(), "b")
      m:send("reset")
      T.eq(m:state(), "a")

      m:send("next")
      m:send("next")
      T.eq(m:state(), "c")
      m:send("reset")
      T.eq(m:state(), "a")
    end)

    T.it("specific state transition takes priority over wildcard", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {}, c = {} },
        transitions = {
          { from = "a", to = "b", event = "go" },
          { from = "*", to = "c", event = "go" },
        },
      })
      local m = machine:start()
      m:send("go")
      -- Specific "a" -> "b" takes priority
      T.eq(m:state(), "b")
      -- From "b", wildcard applies
      m:send("go")
      T.eq(m:state(), "c")
    end)
  end)

  T.describe("can", function()
    T.it("returns true for valid transition", function()
      local machine = traffic_light()
      local m = machine:start()
      T.eq(m:can("go"), true)
    end)

    T.it("returns false for invalid transition", function()
      local machine = traffic_light()
      local m = machine:start()
      T.eq(m:can("slow"), false)
      T.eq(m:can("stop"), false)
    end)

    T.it("returns false for unknown event", function()
      local machine = traffic_light()
      local m = machine:start()
      T.eq(m:can("fly"), false)
    end)

    T.it("considers guards", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
        guards = { go = function(ctx) return ctx.ok == true end },
      })
      local m = machine:start({ ok = false })
      T.eq(m:can("go"), false)
      m:set_context({ ok = true })
      T.eq(m:can("go"), true)
    end)
  end)

  T.describe("history", function()
    T.it("starts with initial state", function()
      local machine = traffic_light()
      local m = machine:start()
      local h = m:history()
      T.eq(#h, 1)
      T.eq(h[1], "red")
    end)

    T.it("tracks all state changes", function()
      local machine = traffic_light()
      local m = machine:start()
      m:send("go")
      m:send("slow")
      m:send("stop")
      local h = m:history()
      T.eq(#h, 4)
      T.eq(h[1], "red")
      T.eq(h[2], "green")
      T.eq(h[3], "yellow")
      T.eq(h[4], "red")
    end)

    T.it("does not record failed transitions", function()
      local machine = traffic_light()
      local m = machine:start()
      m:send("slow") -- invalid, should not record
      local h = m:history()
      T.eq(#h, 1)
      T.eq(h[1], "red")
    end)

    T.it("returns a copy, not the internal table", function()
      local machine = traffic_light()
      local m = machine:start()
      local h1 = m:history()
      h1[1] = "tampered"
      local h2 = m:history()
      T.eq(h2[1], "red")
    end)
  end)

  T.describe("context", function()
    T.it("set_context replaces context", function()
      local machine = traffic_light()
      local m = machine:start({ a = 1 })
      T.eq(m:context().a, 1)
      m:set_context({ b = 2 })
      T.eq(m:context().a, nil)
      T.eq(m:context().b, 2)
    end)

    T.it("actions can modify context persistently", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = {
          { from = "a", to = "b", event = "go" },
          { from = "b", to = "a", event = "back" },
        },
        actions = {
          go = function(ctx) ctx.trips = (ctx.trips or 0) + 1 end,
          back = function(ctx) ctx.trips = (ctx.trips or 0) + 1 end,
        },
      })
      local m = machine:start()
      m:send("go")
      m:send("back")
      m:send("go")
      T.eq(m:context().trips, 3)
    end)
  end)

  T.describe("introspection", function()
    T.it("states() returns all state names sorted", function()
      local machine = traffic_light()
      local s = machine:states()
      T.eq(#s, 3)
      T.eq(s[1], "green")
      T.eq(s[2], "red")
      T.eq(s[3], "yellow")
    end)

    T.it("events() returns all event names", function()
      local machine = traffic_light()
      local e = machine:events()
      T.eq(#e, 3)
      -- Order matches transition declaration order
      T.eq(e[1], "go")
      T.eq(e[2], "slow")
      T.eq(e[3], "stop")
    end)

    T.it("transitions_from returns matching transitions", function()
      local machine = traffic_light()
      local t = machine:transitions_from("red")
      T.eq(#t, 1)
      T.eq(t[1].event, "go")
      T.eq(t[1].to, "green")
    end)

    T.it("transitions_from includes wildcard", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = {
          { from = "a", to = "b", event = "go" },
          { from = "*", to = "a", event = "reset" },
        },
      })
      local t = machine:transitions_from("b")
      T.eq(#t, 1)
      T.eq(t[1].event, "reset")
      T.eq(t[1].to, "a")

      local t2 = machine:transitions_from("a")
      T.eq(#t2, 2)
    end)

    T.it("transitions_from returns empty for state with no transitions", function()
      local machine = fsm.new({
        initial = "a",
        states = { a = {}, b = {} },
        transitions = { { from = "a", to = "b", event = "go" } },
      })
      local t = machine:transitions_from("b")
      T.eq(#t, 0)
    end)
  end)

  T.describe("on_transition callback", function()
    T.it("fires on successful transition", function()
      local log = {}
      local machine = traffic_light()
      machine:on_transition(function(from, to, event, ctx)
        log[#log + 1] = { from = from, to = to, event = event }
      end)
      local m = machine:start()
      m:send("go")
      T.eq(#log, 1)
      T.eq(log[1].from, "red")
      T.eq(log[1].to, "green")
      T.eq(log[1].event, "go")
    end)

    T.it("does not fire on failed transition", function()
      local count = 0
      local machine = traffic_light()
      machine:on_transition(function() count = count + 1 end)
      local m = machine:start()
      m:send("slow") -- invalid
      T.eq(count, 0)
    end)

    T.it("multiple listeners all fire", function()
      local a, b = 0, 0
      local machine = traffic_light()
      machine:on_transition(function() a = a + 1 end)
      machine:on_transition(function() b = b + 1 end)
      local m = machine:start()
      m:send("go")
      T.eq(a, 1)
      T.eq(b, 1)
    end)

    T.it("listener receives context", function()
      local got_ctx = nil
      local machine = traffic_light()
      machine:on_transition(function(_, _, _, ctx) got_ctx = ctx end)
      local m = machine:start({ val = 55 })
      m:send("go")
      T.ok(got_ctx)
      T.eq(got_ctx.val, 55)
    end)
  end)

  T.describe("multiple instances", function()
    T.it("instances are independent", function()
      local machine = traffic_light()
      local m1 = machine:start()
      local m2 = machine:start()
      m1:send("go")
      T.eq(m1:state(), "green")
      T.eq(m2:state(), "red")
    end)

    T.it("instances have independent context", function()
      local machine = traffic_light()
      local m1 = machine:start({ id = 1 })
      local m2 = machine:start({ id = 2 })
      T.eq(m1:context().id, 1)
      T.eq(m2:context().id, 2)
    end)

    T.it("instances have independent history", function()
      local machine = traffic_light()
      local m1 = machine:start()
      local m2 = machine:start()
      m1:send("go")
      m1:send("slow")
      T.eq(#m1:history(), 3)
      T.eq(#m2:history(), 1)
    end)
  end)

end)
