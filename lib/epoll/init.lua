if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")
local bit = require("bit")

--[[notes:]]
--[[EPOLLET (edge triggered) is not supported at all since wepoll does not support it.]]
--[[same with EPOLLWAKEUP and EPOLLEXCLUSIVE]]
--[[also same with things that are not sockets... like files, like stdin :(]]

local M = {}

--:: epoll = { fd: integer, read_cbs: { [integer]: unknown }, write_cbs: { [integer]: unknown }, close_cbs: { [integer]: unknown }, rets: { [integer]: { write: (string) -> nil, remove: () -> nil } }, weak: { [integer]: boolean }, count: integer, add: (self: epoll, fd: integer, on_read: ((string) -> nil) | (() -> nil), close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil), remove: (self: epoll, fd: integer) -> nil, wait: (self: epoll) -> nil, loop: (self: epoll) -> nil }

--: (number, cdata, integer) -> integer
local read_c = function(_fd, _buf, _n) error("epoll: read_c not initialized") end
--: (integer, string, integer) -> integer
local write_c = function(_fd, _buf, _n) error("epoll: write_c not initialized") end
--: (integer) -> integer
local epoll_create_c = function(_size) error("epoll: epoll_create_c not initialized") end
--: (integer, integer, integer, cdata) -> integer
local epoll_ctl_c = function(_epfd, _op, _fd, _event) error("epoll: epoll_ctl_c not initialized") end
--: (integer, cdata, integer, integer) -> integer
local epoll_wait_c = function(_epfd, _events, _max, _timeout) error("epoll: epoll_wait_c not initialized") end

if ffi.os == "Windows" then
	local wepoll = assert(ffi.load("wepoll.dll"))
	local ws2_32 = assert(ffi.load("Ws2_32.dll"))
	-- https://github.com/piscisaureus/wepoll/blob/0598a791bf9cbbf480793d778930fc635b044980/wepoll.h
	ffi.cdef [[
		typedef uintptr_t /* void* */ HANDLE;
		typedef uintptr_t SOCKET;

		struct epoll_event {
			uint32_t events;	 /* Epoll events and flags */
			union {
				void* ptr;
				int fd_;
				uint32_t u32;
				uint64_t u64;
				SOCKET fd/*sock*/; /* Windows specific */
				HANDLE hnd;	/* Windows specific */
			}; /* User data variable */
		};

		int recv(SOCKET s, char *buf, int len, int flags);
		int send(SOCKET s, const char *buf, int len, int flags);
		HANDLE epoll_create(int size);
		HANDLE epoll_create1(int flags);
		int epoll_close(HANDLE ephnd);
		int epoll_ctl(HANDLE ephnd, int op, SOCKET sock, struct epoll_event* event);
		int epoll_wait(HANDLE ephnd, struct epoll_event* events, int maxevents, int timeout);
	]]
	--: (number, cdata, integer) -> integer
	read_c = function (s, b, len) return ws2_32.recv(s, b, len, 0) end
	--: (integer, string, integer) -> integer
	write_c = function (s, b, len) return ws2_32.send(s, b, len, 0) end
	--: (integer) -> integer
	epoll_create_c = function (size) return wepoll.epoll_create(size) end
	--: (integer, integer, integer, cdata) -> integer
	epoll_ctl_c = function (epfd, op, fd, event) return wepoll.epoll_ctl(epfd, op, fd, event) end
	--: (integer, cdata, integer, integer) -> integer
	epoll_wait_c = function (epfd, events, max, timeout) return wepoll.epoll_wait(epfd, events, max, timeout) end
else
	--[[https://github.com/torvalds/linux/blob/5bfc75d92efd494db37f5c4c173d3639d4772966/include/uapi/linux/eventpoll.h]]
	ffi.cdef [[
		struct epoll_event {
			uint32_t events; /* Epoll events */
			union { int fd; int64_t padding; }; /* User data */
		};

		ssize_t read(int fd, void *buf, size_t count);
		ssize_t write(int fd, const void *buf, size_t count);
		int epoll_create(int size);
		int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
		int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
	]]
	--: (number, cdata, integer) -> integer
	read_c = function (fd, b, n) return ffi.C.read(fd, b, n) end
	--: (integer, string, integer) -> integer
	write_c = function (fd, b, n) return ffi.C.write(fd, b, n) end
	--: (integer) -> integer
	epoll_create_c = function (size) return ffi.C.epoll_create(size) end
	--: (integer, integer, integer, cdata) -> integer
	epoll_ctl_c = function (epfd, op, fd, event) return ffi.C.epoll_ctl(epfd, op, fd, event) end
	--: (integer, cdata, integer, integer) -> integer
	epoll_wait_c = function (epfd, events, max, timeout) return ffi.C.epoll_wait(epfd, events, max, timeout) end
end

local epoll_event = ffi.typeof("struct epoll_event[1]")
local buf = ffi.new("char[65536]") --: cdata

--[[@class epoll_event]]
--[[@field events integer]]
--[[@field fd fd_c]]
--[[@class epoll_ffi]]
--[[@field read fun(fd: fd_c, buf: ffi.cdata*, count: integer): integer]]
--[[@field write fun(fd: fd_c, buf: string, count: integer): integer]]
--[[@field epoll_create fun(size: integer): fd_c]]
--[[@field epoll_ctl fun(epfd: fd_c, op: integer, fd: fd_c, event: epoll_event?): integer]]
--[[@field epoll_wait fun(epfd: fd_c, events: epoll_event[], maxevents: integer, timeout: integer): integer]]

--[[@alias epoll_read fun(data: string)]]
--[[@alias epoll_write fun(data: string)]]
--[[@alias epoll_close fun()]]
--[[@alias epoll_remove fun()]]

--[[@class epoll]]
local epoll = {}
epoll.__index = epoll
M.epoll = epoll

--: ({ [string]: unknown, ... }) -> epoll
epoll.new = function (self)
	--[[@class epoll]]
	local obj = {
	fd = epoll_create_c(1),
	read_cbs = {}, --[[@type (fun()?)[] ]]
	write_cbs = {}, --[[@type (fun()?)[] ]]
	close_cbs = {}, --[[@type (fun()?)[] ]]
	rets = {}, --[[@type ({write:epoll_write;remove:epoll_remove;}?)[] ]]
	weak = {}, --[[@type boolean[] ]]
	count = 0,
}
	return setmetatable(obj, self)
end
--: () -> epoll
M.new = function () return epoll:new() end

-- If the read callback accepts a parameter, epoll wraps it to read from the fd
-- via raw read_c and deliver the data as a string. If the callback takes no
-- parameters, it is called as a bare notification and must read from the fd
-- itself (e.g. via ljsocket:receive()). Mixing read_c and ljsocket receive on
-- the same fd is undefined — use one or the other consistently.
--: (integer, (string) -> nil) -> (() -> nil)
local read_cb = function (fd, read_fn)
	return function ()
		--[[FIXME: ioctl to get full message in one call]]
		local len = read_c(fd, buf, 65536)
		if len ~= -1 then read_fn(ffi.string(buf, len)) end
	end
end

--: (self: epoll, fd: number) -> nil
local remove_fd = function (self, fd)
	if self.rets[fd] then
		self.read_cbs[fd] = nil
		self.write_cbs[fd] = nil
		self.close_cbs[fd] = nil
		self.rets[fd] = nil
		if not self.weak[fd] then self.count = self.count - 1 end
		self.weak[fd] = nil
		--[[do i need to close?]]
	end
end

--: (self: epoll, fd: integer, on_read: (string) -> nil, close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
epoll.add = function (self, fd, on_read, close, weak)
	local ep = self
	if ep.read_cbs[fd] then return nil, nil, "epoll: already polling fd: " .. fd end
	local events = epoll_event({ { events = 1, fd = fd } }) --- @type {[0]:epoll_event}
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
	local write_buf = ""
	local epfd = ep.fd
	ep.write_cbs[fd] = function ()
		write_c(fd, write_buf, #write_buf)
		write_buf = ""
		events[0].events = 1 --[[EPOLLIN]]
		if epoll_ctl_c(epfd, --[[EPOLL_CTL_MOD]] 3, fd, events) ~= 0 then
			error("epoll: write callback failed")
		end
	end
	ep.close_cbs[fd] = close
	--: (string) -> nil
	local write = function (data)
		write_buf = write_buf .. data
		events[0].events = 5 --[[EPOLLIN | EPOLLOUT]]
		if epoll_ctl_c(epfd, --[[EPOLL_CTL_MOD]] 3, fd, events) ~= 0 then
			error("epoll: write failed")
		end
	end
	--: () -> nil
	local remove = function ()
		remove_fd(ep, fd)
		--[[this may silently fail if the socket has been closed.]]
		epoll_ctl_c(epfd, --[[EPOLL_CTL_DEL]] 2, fd, events)
	end
	if epoll_ctl_c(epfd, --[[EPOLL_CTL_ADD]] 1, fd, events) ~= 0 then
		return nil, nil, "epoll: add failed"
	end
	ep.rets[fd] = { write = write, remove = remove }
	if weak then ep.weak[fd] = true
	else ep.count = ep.count + 1 end
	return write, remove, nil
end
M.add = epoll.add

--: (epoll, integer, (string) -> nil, (() -> nil) | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
epoll.modify = function (self, fd, on_read, close)
	if not self.read_cbs[fd] then return nil, nil, "epoll: error: not polling fd: " .. fd end
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

--: (epoll) -> nil
epoll.wait = function (self)
	local events = epoll_event() --[[@type epoll_event[] ]]
	epoll_wait_c(self.fd, events, 1, -1)
	local event = events[0] --[[@type epoll_event]]
	local fd = tonumber(event.fd)
	if not fd then return end
	if bit.band(event.events, --[[EPOLLIN]] 0x1) ~= 0 then
		local cb = self.read_cbs[fd]
		if cb then cb()
		else read_c(fd, buf, 65536) end --[[discard]]
	end
	if bit.band(event.events, --[[EPOLLOUT]] 0x4) ~= 0 then
		local cb = self.write_cbs[fd]
		if cb then cb() end
	end
	if bit.band(event.events, --[[EPOLLHUP]] 0x10) ~= 0 then
		local cb = self.close_cbs[fd]
		if cb then cb() end
		if self.rets[fd] then remove_fd(self, fd) end
	end
	if bit.band(event.events, --[[EPOLLRDHUP]] 0x2000) ~= 0 then
		local cb = self.close_cbs[fd]
		if cb then cb() end
		if self.rets[fd] then remove_fd(self, fd) end
	end
end
M.wait = epoll.wait

--: (epoll) -> nil
--[[loops forever]]
epoll.loop = function (self)
	while self.count > 0 do
		local ok, err = pcall(epoll.wait, self)
		if not ok then
			if type(err) == "string" and err:find("interrupted!", 1, true) then return end
			error(err, 0)
		end
	end
end
M.loop = epoll.loop

return M
