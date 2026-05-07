local ffi = require("ffi")
if ffi.os ~= "Linux" then return end

ffi.cdef([[
  struct timespec { long tv_sec; long tv_nsec; };
  struct itimerspec { struct timespec it_interval; struct timespec it_value; };
  int timerfd_create(int clockid, int flags);
  int timerfd_settime(int fd, int flags, void *new_value, void *old_value);
  long read(int fd, void *buf, unsigned long count);
  int close(int fd);
]])

local T = require("lib.test.assert")

-- Check that epoll syscalls are available
local ok_epoll, epoll = pcall(require, "lib.epoll")
if not ok_epoll then return end

T.describe("epoll", function()
  T.it("creates an epoll instance", function()
    local ep = epoll.new()
    T.ok(ep, "epoll.new() returned a value")
    T.ok(ep.fd >= 0, "epoll fd is non-negative")
    T.eq(ep.count, 0)
  end)

  T.it("adds a file descriptor and waits with timeout", function()
    -- Use timerfd as a real fd to add to epoll
    local ok_create = pcall(function()
      ffi.C.timerfd_create(1, 0)
    end)
    if not ok_create then
      -- timerfd_create cdef might not be loaded yet, load timerfd module
      pcall(require, "lib.timerfd")
    end

    local tfd = ffi.C.timerfd_create(1, 0) -- CLOCK_MONOTONIC
    T.ok(tfd >= 0, "timerfd_create returned valid fd")

    -- Set timer to fire in 10ms
    local timespec = ffi.typeof("struct timespec")
    local itimerspec = ffi.typeof("struct itimerspec")
    local ts_zero = timespec(0, 0)
    local ts_10ms = timespec(0, 10000000) -- 10ms
    ffi.C.timerfd_settime(tfd, 0, itimerspec(ts_zero, ts_10ms), nil)

    local ep = epoll.new()
    local received = false
    local write_fn, remove_fn = ep:add(tfd, function()
      -- Read the timerfd to clear it
      local rdbuf = ffi.new("char[8]")
      ffi.C.read(tfd, rdbuf, 8)
      received = true
    end)

    T.ok(write_fn, "add returned write function")
    T.ok(remove_fn, "add returned remove function")
    T.eq(ep.count, 1)

    -- Wait for the timer to fire (epoll.wait blocks until event)
    -- The timer is set for 10ms so this should return quickly
    ep:wait()
    T.ok(received, "read callback was called after timer fired")

    -- Clean up
    remove_fn()
    T.eq(ep.count, 0)
    ffi.C.close(tfd)
  end)

  T.it("returns error when adding duplicate fd", function()
    local tfd = ffi.C.timerfd_create(1, 0)
    T.ok(tfd >= 0, "timerfd_create returned valid fd")

    local ep = epoll.new()
    local _, _ = ep:add(tfd, function() end)
    local w2, r2, err = ep:add(tfd, function() end)
    T.eq(w2, nil)
    T.eq(r2, nil)
    T.ok(err, "got error string for duplicate fd")

    -- Clean up
    ffi.C.close(tfd)
  end)

  T.it("supports weak fds that don't increment count", function()
    local tfd = ffi.C.timerfd_create(1, 0)
    T.ok(tfd >= 0, "timerfd_create returned valid fd")

    local ep = epoll.new()
    local _, remove = ep:add(tfd, function() end, nil, true) -- weak = true
    T.eq(ep.count, 0, "weak fd does not increment count")

    remove()
    T.eq(ep.count, 0)
    ffi.C.close(tfd)
  end)

  T.it("modifies a watched fd", function()
    local tfd = ffi.C.timerfd_create(1, 0)
    T.ok(tfd >= 0, "timerfd_create returned valid fd")

    local ep = epoll.new()
    ep:add(tfd, function() end)

    local w, r = ep:modify(tfd, function() end)
    T.ok(w, "modify returned write function")
    T.ok(r, "modify returned remove function")

    -- modify on unknown fd returns error
    local w2, r2, err = ep:modify(99999, function() end)
    T.eq(w2, nil)
    T.eq(r2, nil)
    T.ok(err, "got error for unknown fd")

    ffi.C.close(tfd)
  end)
end)
