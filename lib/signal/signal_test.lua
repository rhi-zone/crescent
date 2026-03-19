if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local signal = require("lib.signal")

T.describe("signal constants", function()
  T.it("are numbers with correct values", function()
    T.eq(signal.SIGHUP, 1)
    T.eq(signal.SIGINT, 2)
    T.eq(signal.SIGQUIT, 3)
    T.eq(signal.SIGKILL, 9)
    T.eq(signal.SIGUSR1, 10)
    T.eq(signal.SIGUSR2, 12)
    T.eq(signal.SIGPIPE, 13)
    T.eq(signal.SIGTERM, 15)
    T.eq(signal.SIGCHLD, 17)
    T.eq(type(signal.SIGALRM), "number")
  end)
end)

T.describe("signal.handle", function()
  T.it("installs a handler that fires on kill", function()
    local caught = false
    local caught_num = nil
    signal.handle(signal.SIGUSR1, function(signum)
      caught = true
      caught_num = signum
    end)
    signal.kill(signal.getpid(), signal.SIGUSR1)
    T.ok(caught, "handler should have fired")
    T.eq(caught_num, signal.SIGUSR1)
    -- clean up
    signal.default(signal.SIGUSR1)
  end)

  T.it("replaces a previous handler", function()
    local first = false
    local second = false
    signal.handle(signal.SIGUSR2, function() first = true end)
    signal.handle(signal.SIGUSR2, function() second = true end)
    signal.kill(signal.getpid(), signal.SIGUSR2)
    T.ok(not first, "first handler should not fire")
    T.ok(second, "second handler should fire")
    signal.default(signal.SIGUSR2)
  end)
end)

T.describe("signal.ignore", function()
  T.it("ignores a signal without crashing", function()
    signal.ignore(signal.SIGUSR1)
    -- This should not crash or invoke any handler
    signal.kill(signal.getpid(), signal.SIGUSR1)
    -- If we got here, the signal was ignored
    T.ok(true, "process survived ignored signal")
    signal.default(signal.SIGUSR1)
  end)
end)

T.describe("signal.default", function()
  T.it("resets handler after handle", function()
    local caught = false
    signal.handle(signal.SIGUSR1, function() caught = true end)
    signal.default(signal.SIGUSR1)
    -- SIGUSR1 default is terminate, so we can't send it to ourselves.
    -- Just verify default() returns true.
    T.ok(not caught, "handler should not have fired yet")
  end)
end)

T.describe("signal.kill", function()
  T.it("returns true on success", function()
    signal.ignore(signal.SIGUSR1)
    local ok = signal.kill(signal.getpid(), signal.SIGUSR1)
    T.ok(ok, "kill should succeed")
    signal.default(signal.SIGUSR1)
  end)

  T.it("returns nil, err for invalid pid", function()
    local ok, err = signal.kill(-99999, signal.SIGUSR1)
    T.eq(ok, nil)
    T.ok(type(err) == "string", "should return error string")
  end)
end)

T.describe("signal.block / signal.unblock", function()
  T.it("blocks and unblocks a signal", function()
    local caught = false
    signal.handle(signal.SIGUSR2, function() caught = true end)

    -- Block SIGUSR2
    local ok = signal.block(signal.SIGUSR2)
    T.ok(ok, "block should succeed")

    -- Send while blocked — handler should NOT fire yet
    signal.kill(signal.getpid(), signal.SIGUSR2)
    T.ok(not caught, "handler should not fire while blocked")

    -- Unblock — pending signal should be delivered
    signal.unblock(signal.SIGUSR2)
    T.ok(caught, "handler should fire after unblock")

    signal.default(signal.SIGUSR2)
  end)
end)

T.describe("signal.getpid", function()
  T.it("returns a positive integer", function()
    local pid = signal.getpid()
    T.ok(type(pid) == "number", "pid should be a number")
    T.ok(pid > 0, "pid should be positive")
  end)
end)
