local ffi = require("ffi")
if ffi.os ~= "Linux" then return end

local T = require("lib.test.assert")

-- Load timerfd module (registers cdefs and provides set_timeout/set_interval)
local ok_timerfd, timerfd = pcall(require, "lib.timerfd")
if not ok_timerfd then return end

-- Also need epoll since timerfd's high-level API requires it
local ok_epoll, epoll = pcall(require, "lib.epoll")
if not ok_epoll then return end

local timespec = ffi.typeof("struct timespec")
local itimerspec = ffi.typeof("struct itimerspec")

T.describe("timerfd", function()
  T.it("creates a timerfd", function()
    local fd = ffi.C.timerfd_create(1, 0) -- CLOCK_MONOTONIC
    T.ok(fd >= 0, "timerfd_create returned valid fd")
    T.eq(ffi.C.close(fd), 0)
  end)

  T.it("sets and reads a timer", function()
    local fd = ffi.C.timerfd_create(1, 0)
    T.ok(fd >= 0, "timerfd_create returned valid fd")

    -- Set timer to fire in 1ms
    local ts_zero = timespec(0, 0)
    local ts_1ms = timespec(0, 1000000) -- 1ms
    local ret = ffi.C.timerfd_settime(fd, 0, itimerspec(ts_zero, ts_1ms), nil)
    T.eq(ret, 0, "timerfd_settime succeeded")

    -- Use epoll to wait for the timer instead of blocking read
    local ep = epoll.new()
    local rdbuf = ffi.new("uint64_t[1]")
    local count = 0ULL
    local _, remove = ep:add(fd, function()
      ffi.C.read(fd, rdbuf, 8)
      count = rdbuf[0]
    end)

    ep:wait()
    T.ok(count >= 1ULL, "timer expired at least once")

    remove()
    ffi.C.close(fd)
  end)

  T.it("gets current timer value", function()
    local fd = ffi.C.timerfd_create(1, 0)
    T.ok(fd >= 0, "timerfd_create returned valid fd")

    local ts_zero = timespec(0, 0)
    local ts_50ms = timespec(0, 50000000) -- 50ms
    ffi.C.timerfd_settime(fd, 0, itimerspec(ts_zero, ts_50ms), nil)

    local curr = ffi.new("struct itimerspec[1]")
    local ret = ffi.C.timerfd_gettime(fd, curr)
    T.eq(ret, 0, "timerfd_gettime succeeded")
    -- The remaining time should be > 0 since the timer hasn't fired yet
    T.ok(curr[0].it_value.tv_nsec > 0 or curr[0].it_value.tv_sec > 0,
      "timer has remaining time")

    ffi.C.close(fd)
  end)

  T.it("set_timeout fires callback once", function()
    local ep = epoll.new()
    local fired = 0

    timerfd.set_timeout(ep, 5, function() -- 5ms
      fired = fired + 1
    end)

    T.eq(ep.count, 1)
    ep:wait() -- should fire after ~5ms
    T.eq(fired, 1)
    -- After timeout fires, the fd is removed
    T.eq(ep.count, 0)
  end)

  T.it("set_interval fires callback multiple times", function()
    local ep = epoll.new()
    local fired = 0

    local clear = timerfd.set_interval(ep, 5, function() -- 5ms interval
      fired = fired + 1
    end)

    T.eq(ep.count, 1)
    ep:wait()
    T.ok(fired >= 1, "interval fired at least once")
    ep:wait()
    T.ok(fired >= 2, "interval fired at least twice")

    clear()
    T.eq(ep.count, 0)
  end)

  T.it("set_timeout can be cleared before firing", function()
    local ep = epoll.new()
    local fired = false

    local clear = timerfd.set_timeout(ep, 50, function() -- 50ms
      fired = true
    end)

    T.eq(ep.count, 1)
    clear()
    T.eq(ep.count, 0)
    T.ok(not fired, "callback was not called after clear")
  end)
end)
