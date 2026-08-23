local ffi = require("ffi")
if ffi.os ~= "Linux" then return end

-- struct timespec/itimerspec are also declared by lib.timerfd (and, with a
-- differently-shaped struct timespec, by lib.async and lib.kqueue -- see the
-- TODO.md entry on consolidating these). LuaJIT errors on redeclaring a
-- struct tag (even identically) but allows redeclaring an identical function
-- prototype, so only the struct decls need the pcall guard -- this is the
-- same convention lib/kqueue/init.lua and lib/async/init.lua already use.
-- Without it, this file colliding with lib/timerfd/timerfd_test.lua's
-- `require("lib.timerfd")` in the same worker process (whichever runs its
-- struct cdef second) throws "attempt to redefine 'timespec'" and aborts
-- that worker's whole test run.
--
-- The two structs are declared in SEPARATE pcall calls, not one string: a
-- single ffi.cdef call aborts entirely on its first parse error, so bundling
-- both in one pcall'd string meant that whenever `struct timespec` collided
-- (already declared, even identically) `struct itimerspec` silently never
-- got declared either -- not just here-and-suppressed but genuinely absent,
-- surfacing later as "undeclared or implicit tag 'itimerspec'" wherever this
-- file's own itimerspec-typed code ran. Measured live: this exact failure
-- reproduced when lib.timerfd's cdef ran first in the same worker process.
--
-- The `long long tv_sec` spelling here (rather than plain `long`, which is
-- what lib.kqueue/lib.async use) matches lib.timerfd's struct timespec
-- byte-for-byte, so that IF this file's declaration loses the race against
-- lib.timerfd's, the two are textually identical and the loser's pcall
-- failure changes nothing observable -- unlike a same-name-different-layout
-- struct, where whichever module's cdef happened to run first would
-- silently decide the field layout every later caller in the process gets.
pcall(ffi.cdef, "struct timespec { long long tv_sec; long tv_nsec; };")
pcall(ffi.cdef, "struct itimerspec { struct timespec it_interval; struct timespec it_value; };")
ffi.cdef([[
  int timerfd_create(int clockid, int flags);
  int timerfd_settime(int fd, int flags, void *new_value, void *old_value);
  long read(int fd, void *buf, unsigned long count);
  int close(int fd);
  int pipe(int pipefd[2]);
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

  -- Regression test: wait()'s EPOLLHUP/EPOLLRDHUP handling used to clear only
  -- this module's own bookkeeping (read_cbs/rets/count/...) without issuing
  -- EPOLL_CTL_DEL, unlike add()'s returned `remove` closure which always did.
  -- A fd removed via that path stayed registered in the kernel epoll set
  -- forever. We can't observe the kernel's registration table directly, but
  -- EPOLL_CTL_ADD on an already-registered fd fails with EEXIST -- so
  -- re-adding the same fd number after an internal HUP-triggered removal is
  -- a direct, non-flaky witness that EPOLL_CTL_DEL actually ran.
  T.it("a fd removed via the internal HUP path is fully deregistered from the kernel", function()
    local pipefd = ffi.new("int[2]")
    T.ok(ffi.C.pipe(pipefd) == 0, "pipe() succeeded")
    local rfd, wfd = pipefd[0], pipefd[1]

    local ep = epoll.new()
    local hup_count = 0
    local w, r = ep:add(rfd, function() end, function() hup_count = hup_count + 1 end)
    T.ok(w, "add returned write function")
    T.ok(r, "add returned remove function")

    -- Closing the write end makes the read end hang up.
    ffi.C.close(wfd)

    -- wait() observes the hangup and removes rfd via the internal HUP path
    -- (remove_fd), NOT via the `r` closure returned above.
    ep:wait(1000)
    T.eq(hup_count, 1, "close callback fired once on hangup")
    T.eq(ep.count, 0, "bookkeeping count dropped to 0 after internal removal")

    -- If the HUP path didn't issue EPOLL_CTL_DEL, rfd is still registered in
    -- the kernel epoll set even though our own bookkeeping says otherwise,
    -- and this ADD fails with EEXIST.
    local w2, r2, err2 = ep:add(rfd, function() end)
    T.ok(w2 ~= nil, "re-add on the same fd succeeded (regression: HUP-path removal left the fd registered in the kernel)")
    T.ok(r2 ~= nil, "re-add returned a remove function")
    T.eq(err2, nil, "re-add reported no error")

    if r2 then r2() end
    ffi.C.close(rfd)
  end)
end)
