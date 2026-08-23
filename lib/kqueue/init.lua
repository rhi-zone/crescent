if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")
local bit = require("bit")

--[[kqueue backend for macOS/BSD.]]
--[[matches the lib/epoll interface (new, add, modify, wait, loop).]]
--[[this is the system tier; no pure-Lua fallback, same as lib/epoll.]]

local M = {}

--:: kqueue_poller = { fd: integer, read_cbs: { [integer]: unknown }, write_cbs: { [integer]: unknown }, close_cbs: { [integer]: unknown }, rets: { [integer]: { write: ((string) -> nil) | nil, remove: () -> nil, _write_toggle: unknown, _del_changes: unknown } }, weak: { [integer]: boolean }, count: integer, add: (self: kqueue_poller, fd: integer, on_read: ((string) -> nil) | (() -> nil), close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil), modify: (self: kqueue_poller, fd: integer, on_read: ((string) -> nil) | (() -> nil), close: (() -> nil) | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil), watch_writable: (self: kqueue_poller, fd: integer, cb: () -> nil) -> (nil | string), unwatch_writable: (self: kqueue_poller, fd: integer) -> (nil | string), wait: (self: kqueue_poller, timeout_ms: integer | nil) -> nil, loop: (self: kqueue_poller) -> nil }

pcall(ffi.cdef, "struct timespec { long tv_sec; long tv_nsec; };")

pcall(ffi.cdef, [[
	struct kevent {
		uintptr_t ident;
		int16_t   filter;
		uint16_t  flags;
		uint32_t  fflags;
		intptr_t  data;
		void      *udata;
	};
]])

pcall(ffi.cdef, [[
	int kqueue(void);
	int kevent(int kq, const struct kevent *changelist, int nchanges,
	           struct kevent *eventlist, int nevents,
	           const struct timespec *timeout);
]])

pcall(ffi.cdef, "ssize_t read(int fd, void *buf, size_t count);")
pcall(ffi.cdef, "ssize_t write(int fd, const void *buf, size_t count);")

local kevent_arr1 = ffi.typeof("struct kevent[1]")
local kevent_arr2 = ffi.typeof("struct kevent[2]")
local buf = ffi.new("char[65536]") --: cdata

--: integer
local EVFILT_READ  = -1
--: integer
local EVFILT_WRITE = -2
--: integer
local EV_ADD       = 0x0001
--: integer
local EV_DELETE    = 0x0002
--: integer
local EV_ENABLE    = 0x0004
--: integer
local EV_DISABLE   = 0x0008
--: integer
local EV_EOF       = 0x8000

--: (cdata, integer, integer, integer, integer, integer, unknown) -> nil
local ev_set = function (ev, ident, filter, flags, fflags, data, udata)
	ev.ident = ident
	ev.filter = filter
	ev.flags = flags
	ev.fflags = fflags
	ev.data = data
	ev.udata = udata
end

-- If the read callback accepts a parameter, kqueue wraps it to read from the fd
-- via raw ffi.C.read and deliver the data as a string. If the callback takes no
-- parameters, it is called as a bare notification and must read from the fd
-- itself (e.g. via ljsocket:receive()). Mixing ffi.C.read and ljsocket receive
-- on the same fd is undefined -- use one or the other consistently.
--: (integer, (string) -> nil) -> (() -> nil)
local read_cb = function (fd, read_fn)
	return function ()
		local len = ffi.C.read(fd, buf, 65536) --[[:! integer]]
		if len ~= -1 then read_fn(ffi.string(buf, len)) end
	end
end

local kqueue = {}
kqueue.__index = kqueue
M.kqueue = kqueue

--: ({ [string]: unknown, ... }) -> kqueue_poller
kqueue.new = function (self)
	local obj = {
		fd = ffi.C.kqueue() --[[:! integer]],
		read_cbs = {},
		write_cbs = {},
		close_cbs = {},
		rets = {},
		weak = {},
		count = 0,
	}
	return setmetatable(obj, self)
end
--: () -> kqueue_poller
M.new = function () return kqueue:new() end

-- The one true removal path: clears bookkeeping AND issues the EV_DELETE
-- kevent changes so the kernel's registration is actually dropped. Both
-- add()'s returned `remove` closure and wait()'s EV_EOF handling call this
-- same function -- previously they diverged, and the EV_EOF path only
-- cleared Lua-side bookkeeping, leaving the fd registered in the kernel
-- kqueue set. A hung-up fd stayed registered forever and (being level-style
-- for EOF conditions) kept re-firing on every subsequent kevent() call,
-- mirroring the epoll HUP/RDHUP bug fixed alongside this one.
--: (self: kqueue_poller, fd: number) -> nil
local remove_fd = function (self, fd)
	local ret = self.rets[fd]
	if ret then
		self.read_cbs[fd] = nil
		self.write_cbs[fd] = nil
		self.close_cbs[fd] = nil
		self.rets[fd] = nil
		if not self.weak[fd] then self.count = self.count - 1 end
		self.weak[fd] = nil
		-- may silently fail if fd already closed
		ffi.C.kevent(self.fd, ret._del_changes, 2, nil, 0, nil)
	end
end

-- ── Write-readiness primitive ────────────────────────────────────────────────
-- watch_writable enables EVFILT_WRITE interest for an already-registered fd and
-- stores cb as the write-ready callback. unwatch_writable disables it.
-- These are the primitive layer; the buffered write helper returned by add()
-- is sugar built on top.

--: (kqueue_poller, integer, () -> nil) -> (nil | string)
kqueue.watch_writable = function (self, fd, cb)
	if not self.rets[fd] then return "kqueue: watch_writable: fd not registered: " .. fd end
	self.write_cbs[fd] = cb
	local write_toggle = self.rets[fd]._write_toggle
	write_toggle[0].flags = EV_ENABLE
	if ffi.C.kevent(self.fd, write_toggle, 1, nil, 0, nil) < 0 then
		return "kqueue: watch_writable: kevent failed"
	end
	return nil
end
M.watch_writable = kqueue.watch_writable

--: (kqueue_poller, integer) -> (nil | string)
kqueue.unwatch_writable = function (self, fd)
	if not self.rets[fd] then return "kqueue: unwatch_writable: fd not registered: " .. fd end
	self.write_cbs[fd] = nil
	local write_toggle = self.rets[fd]._write_toggle
	write_toggle[0].flags = EV_DISABLE
	if ffi.C.kevent(self.fd, write_toggle, 1, nil, 0, nil) < 0 then
		return "kqueue: unwatch_writable: kevent failed"
	end
	return nil
end
M.unwatch_writable = kqueue.unwatch_writable

-- ── add ──────────────────────────────────────────────────────────────────────

--: (self: kqueue_poller, fd: integer, on_read: (string) -> nil, close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
kqueue.add = function (self, fd, on_read, close, weak)
	local ep = self
	if ep.read_cbs[fd] then return nil, nil, "kqueue: already polling fd: " .. fd end

	-- register both EVFILT_READ (enabled) and EVFILT_WRITE (disabled initially)
	-- both filters always present so EV_EOF is caught on either path
	local reg = kevent_arr2()
	ev_set(reg[0], fd, EVFILT_READ, EV_ADD + EV_ENABLE, 0, 0, nil)
	ev_set(reg[1], fd, EVFILT_WRITE, EV_ADD + EV_DISABLE, 0, 0, nil)
	if ffi.C.kevent(ep.fd, reg, 2, nil, 0, nil) < 0 then
		return nil, nil, "kqueue: add failed"
	end

	local on_read_fn = on_read
	local fninfo = debug.getinfo(on_read_fn)
	if fninfo then
		local nparams = fninfo.nparams
		if (type(nparams) == "number" and nparams > 0) or fninfo.isvararg then
			ep.read_cbs[fd] = read_cb(fd, on_read_fn)
		else
			ep.read_cbs[fd] = on_read_fn
		end
	else
		ep.read_cbs[fd] = on_read_fn
	end
	ep.close_cbs[fd] = close

	-- pre-allocate change structs to avoid hot-path allocation
	local write_toggle = kevent_arr1()
	ev_set(write_toggle[0], fd, EVFILT_WRITE, 0, 0, 0, nil)

	local del_changes = kevent_arr2()
	ev_set(del_changes[0], fd, EVFILT_READ, EV_DELETE, 0, 0, nil)
	ev_set(del_changes[1], fd, EVFILT_WRITE, EV_DELETE, 0, 0, nil)

	--: () -> nil
	local remove = function ()
		remove_fd(ep, fd)
	end

	ep.rets[fd] = { write = nil, remove = remove, _write_toggle = write_toggle, _del_changes = del_changes }
	if weak then ep.weak[fd] = true
	else ep.count = ep.count + 1 end

	-- Build the buffered-write convenience function on top of the primitive.
	local write_buf = ""
	--: () -> nil
	local flush_cb = function ()
		ffi.C.write(fd, write_buf, #write_buf)
		write_buf = ""
		ep:unwatch_writable(fd)
	end
	--: (string) -> nil
	local write = function (data)
		write_buf = write_buf .. data
		ep:watch_writable(fd, flush_cb)
	end
	ep.rets[fd].write = write
	return write, remove, nil
end
M.add = kqueue.add

--: (kqueue_poller, integer, (string) -> nil, (() -> nil) | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
kqueue.modify = function (self, fd, on_read, close)
	if not self.read_cbs[fd] then return nil, nil, "kqueue: error: not polling fd: " .. fd end
	local on_read_fn = on_read
	local fninfo = debug.getinfo(on_read_fn)
	if fninfo then
		local nparams = fninfo.nparams
		if (type(nparams) == "number" and nparams > 0) or fninfo.isvararg then
			self.read_cbs[fd] = read_cb(fd, on_read_fn)
		else
			self.read_cbs[fd] = on_read_fn
		end
	else
		self.read_cbs[fd] = on_read_fn
	end
	self.close_cbs[fd] = close
	local rets = self.rets[fd]
	return rets.write, rets.remove, nil
end

-- timeout_ms: milliseconds to block for. nil or a negative value blocks
-- indefinitely (previous behavior, passed to kevent as a NULL timespec);
-- 0 returns immediately. If the timeout elapses with no event, wait
-- returns without invoking any callback.
--: (kqueue_poller, integer | nil) -> nil
kqueue.wait = function (self, timeout_ms)
	local events = kevent_arr1()
	local timeout_ptr --[[: unknown]] = nil
	if timeout_ms and timeout_ms >= 0 then
		local sec = math.floor(timeout_ms / 1000)
		local nsec = (timeout_ms - sec * 1000) * 1000000
		timeout_ptr = ffi.new("struct timespec", { sec, nsec })
	end
	local n = ffi.C.kevent(self.fd, nil, 0, events, 1, timeout_ptr)
	if n < 1 then return end

	local event = events[0]
	local fd = tonumber(event.ident)
	if not fd then return end
	local filter = event.filter --[[:! integer]]
	local flags = event.flags --[[:! integer]]

	if filter == EVFILT_READ then
		local cb = self.read_cbs[fd]
		if cb then cb()
		else ffi.C.read(fd, buf, 65536) end --[[discard]]
	elseif filter == EVFILT_WRITE then
		local cb = self.write_cbs[fd]
		if cb then cb() end
	end

	-- EV_EOF on either filter triggers close callback, matching EPOLLHUP
	if bit.band(flags, EV_EOF) ~= 0 then
		local cb = self.close_cbs[fd]
		if cb then cb() end
		if self.rets[fd] then remove_fd(self, fd) end
	end
end
M.wait = kqueue.wait

--: (kqueue_poller) -> nil
kqueue.loop = function (self)
	while self.count > 0 do
		local ok, err = pcall(kqueue.wait, self)
		if not ok then
			if type(err) == "string" and err:find("interrupted!", 1, true) then return end
			error(err, 0)
		end
	end
end
M.loop = kqueue.loop

return M
