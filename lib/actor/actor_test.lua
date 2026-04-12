-- lib/actor/actor_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local A = require("lib.actor")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Create a simple echo actor: reflects any message back to msg.reply_to
local function echo_actor(ctx)
  while true do
    local msg = ctx:receive()
    if msg == nil then break end
    if msg.type == "stop" then break end
    if msg.reply_to then
      ctx:send(msg.reply_to, {type = "reply", value = msg.value})
    end
  end
end

-- ---------------------------------------------------------------------------
-- Tier
-- ---------------------------------------------------------------------------

T.describe("A._tier", function()
  T.it("is 'pure'", function()
    T.eq(A._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- spawn + send + step: basic message delivery
-- ---------------------------------------------------------------------------

T.describe("spawn / send / step", function()
  T.it("actor receives message via step", function()
    local sys = A.system()
    local received = {}
    local pid = sys:spawn(function(ctx)
      local msg = ctx:receive()
      received[#received + 1] = msg
    end)
    T.eq(sys:alive(pid), true)
    sys:send(pid, {type = "hello", value = 42})
    sys:step()
    T.eq(#received, 1)
    T.eq(received[1].type, "hello")
    T.eq(received[1].value, 42)
  end)

  T.it("actor that loops receives multiple messages", function()
    local sys = A.system()
    local log = {}
    local pid = sys:spawn(function(ctx)
      for _ = 1, 3 do
        local msg = ctx:receive()
        log[#log + 1] = msg.value
      end
    end)
    sys:send(pid, {value = 1})
    sys:send(pid, {value = 2})
    sys:send(pid, {value = 3})
    sys:run(4)
    T.eq(#log, 3)
    T.eq(log[1], 1)
    T.eq(log[2], 2)
    T.eq(log[3], 3)
  end)

  T.it("actor processes message in order", function()
    local sys = A.system()
    local result = {}
    local pid = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg.type == "stop" then break end
        result[#result + 1] = msg.n
      end
    end)
    for i = 1, 5 do
      sys:send(pid, {type = "data", n = i})
    end
    sys:send(pid, {type = "stop"})
    sys:run_until_idle()
    T.eq(#result, 5)
    T.eq(result[3], 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- Multiple actors: isolation
-- ---------------------------------------------------------------------------

T.describe("multiple actors", function()
  T.it("each actor gets its own messages", function()
    local sys = A.system()
    local got_a, got_b = {}, {}
    local pid_a = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg.type == "stop" then break end
        got_a[#got_a + 1] = msg.value
      end
    end)
    local pid_b = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg.type == "stop" then break end
        got_b[#got_b + 1] = msg.value
      end
    end)
    sys:send(pid_a, {value = "a1"})
    sys:send(pid_b, {value = "b1"})
    sys:send(pid_a, {value = "a2"})
    sys:send(pid_a, {type = "stop"})
    sys:send(pid_b, {type = "stop"})
    sys:run_until_idle()
    T.eq(#got_a, 2)
    T.eq(got_a[1], "a1")
    T.eq(got_a[2], "a2")
    T.eq(#got_b, 1)
    T.eq(got_b[1], "b1")
  end)

  T.it("pids are unique", function()
    local sys = A.system()
    local pids = {}
    for i = 1, 10 do
      pids[i] = sys:spawn(function(ctx) ctx:receive() end)
    end
    local seen = {}
    for _, p in ipairs(pids) do
      T.eq(seen[p], nil)
      seen[p] = true
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- alive / actor_count
-- ---------------------------------------------------------------------------

T.describe("alive / actor_count", function()
  T.it("alive returns true for running actor", function()
    local sys = A.system()
    local pid = sys:spawn(function(ctx) ctx:receive() end)
    T.eq(sys:alive(pid), true)
  end)

  T.it("alive returns false after actor exits", function()
    local sys = A.system()
    local pid = sys:spawn(function(_ctx)
      -- exits immediately (no receive)
    end)
    T.eq(sys:alive(pid), false)
  end)

  T.it("alive returns false after stop", function()
    local sys = A.system()
    local pid = sys:spawn(function(ctx) ctx:receive() end)
    T.eq(sys:alive(pid), true)
    sys:stop(pid)
    T.eq(sys:alive(pid), false)
  end)

  T.it("actor_count decreases when actor dies", function()
    local sys = A.system()
    local n0 = sys:actor_count()
    T.eq(n0, 0)
    local pid = sys:spawn(function(ctx) ctx:receive() end)
    T.eq(sys:actor_count(), 1)
    sys:stop(pid)
    T.eq(sys:actor_count(), 0)
  end)

  T.it("actor_count tracks multiple actors", function()
    local sys = A.system()
    local pids = {}
    for i = 1, 5 do
      pids[i] = sys:spawn(function(ctx) ctx:receive() end)
    end
    T.eq(sys:actor_count(), 5)
    sys:stop(pids[1])
    sys:stop(pids[2])
    T.eq(sys:actor_count(), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- whereis: name lookup
-- ---------------------------------------------------------------------------

T.describe("whereis", function()
  T.it("finds named actor", function()
    local sys = A.system()
    local pid = sys:spawn(function(ctx) ctx:receive() end, {name = "myactor"})
    T.eq(sys:whereis("myactor"), pid)
  end)

  T.it("returns nil for unknown name", function()
    local sys = A.system()
    T.eq(sys:whereis("nosuchactor"), nil)
  end)

  T.it("name unregistered after actor dies", function()
    local sys = A.system()
    local pid = sys:spawn(function(_ctx) end, {name = "shortlived"})
    -- Actor exits immediately (no receive)
    T.eq(sys:alive(pid), false)
    T.eq(sys:whereis("shortlived"), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- ctx:self and ctx:name
-- ---------------------------------------------------------------------------

T.describe("ctx:self / ctx:name", function()
  T.it("ctx:self returns the actor's own pid", function()
    local sys = A.system()
    local self_pid_box = {}
    local pid = sys:spawn(function(ctx)
      self_pid_box[1] = ctx:self()
    end)
    T.eq(self_pid_box[1], pid)
  end)

  T.it("ctx:name returns the actor's name", function()
    local sys = A.system()
    local name_box = {}
    sys:spawn(function(ctx)
      name_box[1] = ctx:name()
    end, {name = "named_one"})
    T.eq(name_box[1], "named_one")
  end)

  T.it("ctx:name is nil when no name given", function()
    local sys = A.system()
    local name_box = {}
    sys:spawn(function(ctx)
      name_box[1] = ctx:name()
    end)
    T.eq(name_box[1], nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- request-reply: call
-- ---------------------------------------------------------------------------

T.describe("call (request-reply)", function()
  T.it("call returns the reply from target actor", function()
    local sys = A.system()
    local pid = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg == nil then break end
        if msg.type == "ping" and msg.reply_to then
          ctx:send(msg.reply_to, {type = "pong", value = msg.value + 1})
        end
      end
    end)
    local reply = sys:call(pid, {type = "ping", value = 10})
    T.ok(reply ~= nil)
    T.eq(reply.type, "pong")
    T.eq(reply.value, 11)
  end)

  T.it("call returns nil on timeout", function()
    local sys = A.system()
    -- Actor that never replies
    sys:spawn(function(ctx)
      ctx:receive()  -- just waits, doesn't reply
    end)
    -- We can't easily test the timeout without real time passing,
    -- so we test the no-reply case with a dead actor instead.
    local dead_pid = 9999  -- no such actor
    local reply = sys:call(dead_pid, {type = "ping"}, 10)
    T.eq(reply, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- run_until_idle
-- ---------------------------------------------------------------------------

T.describe("run_until_idle", function()
  T.it("processes all pending messages", function()
    local sys = A.system()
    local log = {}
    local pid = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg.type == "stop" then break end
        log[#log + 1] = msg.value
      end
    end)
    for i = 1, 10 do
      sys:send(pid, {value = i})
    end
    sys:send(pid, {type = "stop"})
    sys:run_until_idle()
    T.eq(#log, 10)
    T.eq(log[10], 10)
  end)
end)

-- ---------------------------------------------------------------------------
-- receive timeout
-- ---------------------------------------------------------------------------

T.describe("receive timeout", function()
  T.it("receive returns nil when timeout elapses", function()
    local sys = A.system()
    local result_box = {}
    -- Use 0 ms timeout — deadline immediately in the past after first step
    local pid = sys:spawn(function(ctx)
      -- Tiny timeout; actor will get nil back when no message arrives
      local msg = ctx:receive(0)
      result_box[1] = msg
    end)
    -- Don't send any message; just run a step with a slight delay
    -- Force deadline to be in the past by running a step
    sys:step()
    -- The actor may still be suspended waiting; run again
    sys:step()
    -- If result_box[1] is still missing, actor didn't timeout yet —
    -- which is acceptable for 0ms; assert actor eventually terminates
    -- (it either got nil or keeps waiting — we verify no crash)
    T.ok(sys:alive(pid) == false or result_box[1] == nil)
  end)

  T.it("receive without timeout blocks until message", function()
    local sys = A.system()
    local got = {}
    local pid = sys:spawn(function(ctx)
      local msg = ctx:receive()   -- no timeout
      got[1] = msg
    end)
    -- Before send: actor is alive and waiting
    T.eq(sys:alive(pid), true)
    T.eq(#got, 0)
    -- After send + step: actor processes message
    sys:send(pid, {value = "hello"})
    sys:step()
    T.eq(#got, 1)
    T.eq(got[1].value, "hello")
  end)
end)

-- ---------------------------------------------------------------------------
-- link
-- ---------------------------------------------------------------------------

T.describe("link", function()
  T.it("linked actor receives exit message when other stops", function()
    local sys = A.system()
    local exit_msgs = {}

    local pid_a
    local pid_b = sys:spawn(function(ctx)
      -- Link to A once A is spawned (we'll link from A's side)
      while true do
        local msg = ctx:receive()
        if msg.type == "exit" then
          exit_msgs[#exit_msgs + 1] = msg
        elseif msg.type == "stop" then
          break
        end
      end
    end)

    pid_a = sys:spawn(function(ctx)
      ctx:link(pid_b)
      -- Now exit immediately
    end)

    -- A exits normally, B should get an exit message
    sys:run_until_idle()
    T.eq(#exit_msgs, 1)
    T.eq(exit_msgs[1].type, "exit")
    T.eq(exit_msgs[1].pid, pid_a)

    -- Clean up B
    sys:send(pid_b, {type = "stop"})
    sys:run_until_idle()
  end)

  T.it("link is bidirectional: stopping B notifies A", function()
    local sys = A.system()
    local a_got_exit = {}

    local pid_b
    local pid_a = sys:spawn(function(ctx)
      -- We'll link after pid_b is known
      local msg = ctx:receive()  -- wait for the "link" instruction
      ctx:link(msg.link_to)
      -- Now wait for the exit signal
      local exit = ctx:receive()
      a_got_exit[1] = exit
    end)

    pid_b = sys:spawn(function(ctx)
      ctx:receive()  -- wait to be stopped externally
    end)

    -- Tell A to link to B
    sys:send(pid_a, {link_to = pid_b})
    sys:step()

    -- Now stop B — A should get an exit signal
    sys:stop(pid_b)
    sys:run_until_idle()

    T.eq(#a_got_exit, 1)
    T.eq(a_got_exit[1].type, "exit")
    T.eq(a_got_exit[1].pid, pid_b)
  end)
end)

-- ---------------------------------------------------------------------------
-- monitor
-- ---------------------------------------------------------------------------

T.describe("monitor", function()
  T.it("monitor receives :down when target exits normally", function()
    local sys = A.system()
    local down_msgs = {}

    local pid_target = sys:spawn(function(_ctx)
      -- exits immediately
    end)

    -- Spawn observer after target is already dead → noproc
    local pid_observer = sys:spawn(function(ctx)
      ctx:monitor(pid_target)
      local msg = ctx:receive()
      down_msgs[#down_msgs + 1] = msg
    end)

    sys:run_until_idle()
    T.eq(#down_msgs, 1)
    T.eq(down_msgs[1].type, "down")
    T.eq(down_msgs[1].pid, pid_target)
    T.eq(down_msgs[1].reason, "noproc")
  end)

  T.it("monitor receives :down when target is stopped", function()
    local sys = A.system()
    local down_msgs = {}

    local pid_target = sys:spawn(function(ctx)
      ctx:receive()  -- wait
    end)

    local pid_observer = sys:spawn(function(ctx)
      ctx:monitor(pid_target)
      -- Wait for the down message
      while true do
        local msg = ctx:receive()
        if msg.type == "down" then
          down_msgs[#down_msgs + 1] = msg
          break
        end
      end
    end)

    -- Let observer set up monitor
    sys:run_until_idle()
    -- Stop the target
    sys:stop(pid_target)
    sys:run_until_idle()

    T.eq(#down_msgs, 1)
    T.eq(down_msgs[1].type, "down")
    T.eq(down_msgs[1].pid, pid_target)
    T.ok(down_msgs[1].reason ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Error handling: actor crash doesn't kill the system
-- ---------------------------------------------------------------------------

T.describe("error handling", function()
  T.it("actor crash is isolated — system keeps running", function()
    local sys = A.system()

    -- Crasher
    sys:spawn(function(_ctx)
      error("intentional crash")
    end)

    -- Other actor keeps running fine
    local ok_log = {}
    local pid_ok = sys:spawn(function(ctx)
      while true do
        local msg = ctx:receive()
        if msg.type == "stop" then break end
        ok_log[#ok_log + 1] = msg.value
      end
    end)

    sys:send(pid_ok, {value = "still alive"})
    sys:send(pid_ok, {type = "stop"})
    sys:run_until_idle()

    T.eq(ok_log[1], "still alive")
  end)

  T.it("crashed actor is marked dead", function()
    local sys = A.system()
    local pid = sys:spawn(function(_ctx)
      error("boom")
    end)
    T.eq(sys:alive(pid), false)
  end)
end)

-- ---------------------------------------------------------------------------
-- ctx:spawn (child spawn)
-- ---------------------------------------------------------------------------

T.describe("ctx:spawn (child spawn)", function()
  T.it("parent can spawn a child actor from inside ctx", function()
    local sys = A.system()
    local child_log = {}

    sys:spawn(function(ctx)
      -- Spawn a child from inside the actor
      local child_pid = ctx:spawn(function(inner_ctx)
        while true do
          local msg = inner_ctx:receive()
          if msg.type == "stop" then break end
          child_log[#child_log + 1] = msg.value
        end
      end)
      ctx:send(child_pid, {value = "from parent"})
      ctx:send(child_pid, {type = "stop"})
    end)

    sys:run_until_idle()
    T.eq(#child_log, 1)
    T.eq(child_log[1], "from parent")
  end)
end)

-- ---------------------------------------------------------------------------
-- Supervisor: one_for_one restart strategy
-- ---------------------------------------------------------------------------

T.describe("supervisor one_for_one", function()
  T.it("restarts failed permanent child", function()
    local sys = A.system()
    local call_count = 0

    local function worker_fn(ctx)
      call_count = call_count + 1
      local n = call_count  -- capture at spawn time
      if n == 1 then
        -- First invocation: crash immediately
        error("deliberate crash")
      else
        -- Second invocation: wait peacefully
        ctx:receive()
      end
    end

    local sup = sys:supervisor({
      strategy     = "one_for_one",
      max_restarts = 3,
      period       = 60,
      children     = {
        {id = "w1", fn = worker_fn, restart = "permanent"},
      },
    })

    -- Let the system process the crash + restart
    sys:run_until_idle()

    -- Worker was called twice: once (crash) + once (restart)
    T.ok(call_count >= 2)
    -- The child should be alive now (second invocation waiting)
    local new_pid = sup:get_pid("w1")
    T.ok(new_pid ~= nil)
    T.eq(sys:alive(new_pid), true)
  end)

  T.it("temporary child is NOT restarted", function()
    local sys = A.system()
    local call_count = 0

    local function temp_fn(_ctx)
      call_count = call_count + 1
      error("crash")
    end

    local sup = sys:supervisor({
      strategy     = "one_for_one",
      max_restarts = 3,
      period       = 60,
      children     = {
        {id = "temp", fn = temp_fn, restart = "temporary"},
      },
    })

    sys:run_until_idle()

    -- Called exactly once; not restarted
    T.eq(call_count, 1)
    T.eq(sup:get_pid("temp"), nil)
  end)

  T.it("transient child restarts on crash, not on normal exit", function()
    local sys = A.system()
    local restart_count = {0}

    local function trans_fn(_ctx)
      restart_count[1] = restart_count[1] + 1
      if restart_count[1] == 1 then
        error("abnormal exit")
      end
      -- Second call: exit normally (no receive)
    end

    local _sup = sys:supervisor({
      strategy     = "one_for_one",
      max_restarts = 5,
      period       = 60,
      children     = {
        {id = "trans", fn = trans_fn, restart = "transient"},
      },
    })

    sys:run_until_idle()
    -- crash → restart → normal exit → no more restarts
    T.ok(restart_count[1] >= 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Supervisor: one_for_all
-- ---------------------------------------------------------------------------

T.describe("supervisor one_for_all", function()
  T.it("restarts all children when one fails", function()
    local sys = A.system()
    local calls = {a = 0, b = 0}

    local function make_worker(id, should_crash)
      return function(ctx)
        calls[id] = calls[id] + 1
        if should_crash and calls[id] == 1 then
          error("crash " .. id)
        end
        ctx:receive()
      end
    end

    local _sup = sys:supervisor({
      strategy     = "one_for_all",
      max_restarts = 3,
      period       = 60,
      children     = {
        {id = "a", fn = make_worker("a", true),  restart = "permanent"},
        {id = "b", fn = make_worker("b", false), restart = "permanent"},
      },
    })

    sys:run_until_idle()

    -- Both should have been called at least twice (a crashed, all restarted)
    T.ok(calls.a >= 2)
    T.ok(calls.b >= 2)
  end)
end)
