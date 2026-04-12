if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = require("lib.mediator")
local T = require("lib.test.assert")

-- ── register + send: basic round-trip ───────────────────────────────────────

T.describe("register + send", function()
  T.it("returns handler result", function()
    local med = M.new()
    med:register("Add", function(cmd) return cmd.a + cmd.b end)
    local result, err = med:send("Add", {a = 3, b = 4})
    T.eq(result, 7)
    T.eq(err, nil)
  end)

  T.it("handler can return nil, err", function()
    local med = M.new()
    med:register("Fail", function(_) return nil, "oops" end)
    local result, err = med:send("Fail", {})
    T.eq(result, nil)
    T.eq(err, "oops")
  end)

  T.it("send unregistered returns nil, err", function()
    local med = M.new()
    local result, err = med:send("Missing", {})
    T.eq(result, nil)
    T.ok(err ~= nil, "error message present")
    T.ok(err:find("Missing"), "error names the command")
  end)

  T.it("overwriting a handler replaces it", function()
    local med = M.new()
    med:register("Greet", function(_) return "hello" end)
    med:register("Greet", function(_) return "world" end)
    local result = med:send("Greet", {})
    T.eq(result, "world")
  end)
end)

-- ── register_query / query alias ────────────────────────────────────────────

T.describe("query alias", function()
  T.it("register_query + query works same as register + send", function()
    local med = M.new()
    med:register_query("GetVal", function(q) return q.x * 2 end)
    local result, err = med:query("GetVal", {x = 5})
    T.eq(result, 10)
    T.eq(err, nil)
  end)

  T.it("query unregistered returns nil, err", function()
    local med = M.new()
    local result, err = med:query("Nope", {})
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)
end)

-- ── events: on / emit ───────────────────────────────────────────────────────

T.describe("events", function()
  T.it("single handler is called", function()
    local med = M.new()
    local called = false
    med:on("Ping", function(_) called = true end)
    local errs = med:emit("Ping", {})
    T.ok(called)
    T.eq(#errs, 0)
  end)

  T.it("multiple handlers all called", function()
    local med = M.new()
    local log = {}
    med:on("Ev", function(_) log[#log+1] = "a" end)
    med:on("Ev", function(_) log[#log+1] = "b" end)
    med:on("Ev", function(_) log[#log+1] = "c" end)
    med:emit("Ev", {})
    T.eq(#log, 3)
    T.eq(log[1], "a")
    T.eq(log[2], "b")
    T.eq(log[3], "c")
  end)

  T.it("emit with no subscribers returns empty errors", function()
    local med = M.new()
    local errs = med:emit("Nobody", {})
    T.eq(#errs, 0)
  end)

  T.it("handler error collected, others still called", function()
    local med = M.new()
    local second_called = false
    med:on("Bad", function(_) error("boom") end)
    med:on("Bad", function(_) second_called = true end)
    local errs = med:emit("Bad", {})
    T.ok(second_called, "second handler runs despite first error")
    T.eq(#errs, 1)
    T.ok(errs[1]:find("boom"), "error message captured")
  end)

  T.it("emit returns all errors when multiple handlers fail", function()
    local med = M.new()
    med:on("Multi", function(_) error("err1") end)
    med:on("Multi", function(_) error("err2") end)
    local errs = med:emit("Multi", {})
    T.eq(#errs, 2)
  end)
end)

-- ── off / token:remove() ────────────────────────────────────────────────────

T.describe("off / remove", function()
  T.it("off unsubscribes a handler", function()
    local med = M.new()
    local count = 0
    local function h(_) count = count + 1 end
    med:on("X", h)
    med:emit("X", {})
    T.eq(count, 1)
    med:off("X", h)
    med:emit("X", {})
    T.eq(count, 1, "handler not called after off")
  end)

  T.it("token:remove() unsubscribes", function()
    local med = M.new()
    local count = 0
    local handle = med:on("Y", function(_) count = count + 1 end)
    med:emit("Y", {})
    T.eq(count, 1)
    handle:remove()
    med:emit("Y", {})
    T.eq(count, 1, "handler not called after remove")
  end)

  T.it("removing one handler leaves others", function()
    local med = M.new()
    local log = {}
    local function h1(_) log[#log+1] = "h1" end
    local function h2(_) log[#log+1] = "h2" end
    med:on("Z", h1)
    med:on("Z", h2)
    med:off("Z", h1)
    med:emit("Z", {})
    T.eq(#log, 1)
    T.eq(log[1], "h2")
  end)

  T.it("off on unknown event is a no-op", function()
    local med = M.new()
    -- Should not error.
    med:off("NoSuch", function() end)
    T.ok(true)
  end)
end)

-- ── middleware ───────────────────────────────────────────────────────────────

T.describe("middleware", function()
  T.it("global middleware called before handler", function()
    local med = M.new()
    local order = {}
    med:use(function(name, payload, next)
      order[#order+1] = "mw"
      return next(name, payload)
    end)
    med:register("Cmd", function(_)
      order[#order+1] = "handler"
      return "ok"
    end)
    med:send("Cmd", {})
    T.eq(order[1], "mw")
    T.eq(order[2], "handler")
  end)

  T.it("middleware can short-circuit (skip handler)", function()
    local med = M.new()
    local handler_called = false
    med:use(function(_, _, _next)
      return nil, "blocked"
    end)
    med:register("Cmd", function(_)
      handler_called = true
      return "ok"
    end)
    local result, err = med:send("Cmd", {})
    T.eq(result, nil)
    T.eq(err, "blocked")
    T.ok(not handler_called)
  end)

  T.it("middleware chain order is FIFO (first registered = outermost)", function()
    local med = M.new()
    local order = {}
    med:use(function(name, payload, next)
      order[#order+1] = "mw1-before"
      local r, e = next(name, payload)
      order[#order+1] = "mw1-after"
      return r, e
    end)
    med:use(function(name, payload, next)
      order[#order+1] = "mw2-before"
      local r, e = next(name, payload)
      order[#order+1] = "mw2-after"
      return r, e
    end)
    med:register("Cmd", function(_)
      order[#order+1] = "handler"
      return "ok"
    end)
    med:send("Cmd", {})
    -- FIFO: mw1 outermost → enters first, exits last
    T.eq(order[1], "mw1-before")
    T.eq(order[2], "mw2-before")
    T.eq(order[3], "handler")
    T.eq(order[4], "mw2-after")
    T.eq(order[5], "mw1-after")
  end)

  T.it("command-specific middleware only fires for that command", function()
    local med = M.new()
    local mw_fired = false
    med:use("TargetCmd", function(name, payload, next)
      mw_fired = true
      return next(name, payload)
    end)
    med:register("TargetCmd", function(_) return "target" end)
    med:register("OtherCmd",  function(_) return "other" end)

    mw_fired = false
    med:send("OtherCmd", {})
    T.ok(not mw_fired, "command-specific mw not fired for OtherCmd")

    mw_fired = false
    med:send("TargetCmd", {})
    T.ok(mw_fired, "command-specific mw fired for TargetCmd")
  end)

  T.it("command-specific middleware can validate payload", function()
    local med = M.new()
    med:use("Create", function(name, payload, next)
      if not payload.name then return nil, "name required" end
      return next(name, payload)
    end)
    med:register("Create", function(p) return {name = p.name} end)

    local r1, e1 = med:send("Create", {})
    T.eq(r1, nil)
    T.eq(e1, "name required")

    local r2, e2 = med:send("Create", {name = "Alice"})
    T.eq(r2.name, "Alice")
    T.eq(e2, nil)
  end)

  T.it("global and command-specific middleware compose (global outermost)", function()
    local med = M.new()
    local order = {}
    med:use(function(name, payload, next)
      order[#order+1] = "global"
      return next(name, payload)
    end)
    med:use("Cmd", function(name, payload, next)
      order[#order+1] = "specific"
      return next(name, payload)
    end)
    med:register("Cmd", function(_)
      order[#order+1] = "handler"
      return "ok"
    end)
    med:send("Cmd", {})
    T.eq(order[1], "global")
    T.eq(order[2], "specific")
    T.eq(order[3], "handler")
  end)

  T.it("middleware does not fire for emit/events", function()
    local med = M.new()
    local mw_fired = false
    med:use(function(name, payload, next)
      mw_fired = true
      return next(name, payload)
    end)
    med:on("Ev", function(_) end)
    med:emit("Ev", {})
    T.ok(not mw_fired, "middleware not invoked for emit")
  end)
end)

-- ── namespace ────────────────────────────────────────────────────────────────

T.describe("namespace", function()
  T.it("register on sub-mediator is prefixed", function()
    local med = M.new()
    local user = med:namespace("user")
    user:register("Create", function(p) return {id = 1, name = p.name} end)

    -- Dispatch via namespace.
    local r1, e1 = user:send("Create", {name = "Alice"})
    T.eq(r1.name, "Alice")
    T.eq(e1, nil)

    -- Dispatch via parent with full name.
    local r2, e2 = med:send("user.Create", {name = "Bob"})
    T.eq(r2.name, "Bob")
    T.eq(e2, nil)
  end)

  T.it("namespace send does not match unprefixed name", function()
    local med = M.new()
    med:register("Create", function(_) return "root" end)
    local user = med:namespace("user")
    -- user:send("Create") → dispatches "user.Create", which is not registered
    local result, err = user:send("Create", {})
    T.eq(result, nil)
    T.ok(err ~= nil)
  end)

  T.it("events are prefixed in namespaces", function()
    local med = M.new()
    local user = med:namespace("user")
    local log = {}
    user:on("Created", function(ev) log[#log+1] = ev.name end)

    user:emit("Created", {name = "Alice"})
    T.eq(#log, 1)
    T.eq(log[1], "Alice")

    -- Parent emitting unprefixed event should not hit namespace handler.
    med:emit("Created", {name = "Root"})
    T.eq(#log, 1, "root event does not fire namespace handler")

    -- Parent emitting prefixed event reaches namespace handler.
    med:emit("user.Created", {name = "Bob"})
    T.eq(#log, 2)
    T.eq(log[2], "Bob")
  end)

  T.it("nested namespaces", function()
    local med = M.new()
    local admin = med:namespace("admin")
    local user  = admin:namespace("user")
    user:register("Delete", function(_) return "deleted" end)

    local r, e = user:send("Delete", {})
    T.eq(r, "deleted")
    T.eq(e, nil)

    -- Also reachable via root with full name.
    local r2, e2 = med:send("admin.user.Delete", {})
    T.eq(r2, "deleted")
    T.eq(e2, nil)
  end)
end)
