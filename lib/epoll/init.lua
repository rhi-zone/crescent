if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

--[[notes:]]
--[[EPOLLET (edge triggered) is not supported at all since wepoll does not support it.]]
--[[same with EPOLLWAKEUP and EPOLLEXCLUSIVE]]
--[[also same with things that are not sockets... like files, like stdin :(]]

local mod = {}

--:: epoll = { fd: integer, read_cbs: { [integer]: unknown }, write_cbs: { [integer]: unknown }, close_cbs: { [integer]: unknown }, rets: { [integer]: { write: (string) -> nil, remove: () -> nil } }, weak: { [integer]: boolean }, count: integer }

local epoll_ffi
local read_c
local write_c

if ffi.os == "Windows" then
	--[[@type epoll_ffi]]
	epoll_ffi = assert(ffi.load("wepoll.dll"))
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
	read_c = function (s, buf, len) return ws2_32.recv(s, buf, len, 0) end
	write_c = function (s, buf, len) return ws2_32.send(s, buf, len, 0) end
else
	--[[@type epoll_ffi]]
	epoll_ffi = ffi.C
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
	read_c = epoll_ffi.read
	write_c = epoll_ffi.write
end

local epoll_event = ffi.typeof("struct epoll_event[1]")
local buf = ffi.new("char[65536]") --[[@type string_c]]

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
mod.epoll = epoll

--: (epoll) -> epoll
epoll.new = function (self)
	--[[@class epoll]]
	local obj = {
	fd = epoll_ffi.epoll_create(1) --[[:! integer]],
	read_cbs = {}, --[[@type (fun()?)[] ]]
	write_cbs = {}, --[[@type (fun()?)[] ]]
	close_cbs = {}, --[[@type (fun()?)[] ]]
	rets = {}, --[[@type ({write:epoll_write;remove:epoll_remove;}?)[] ]]
	weak = {}, --[[@type boolean[] ]]
	count = 0,
}
	return setmetatable(obj, self) --[[:! epoll]]
end
--: () -> epoll
mod.new = function () return epoll:new() end

--[[@param fd fd_c]] --[[@param read epoll_read]]
-- If the read callback accepts a parameter, epoll wraps it to read from the fd
-- via raw read_c and deliver the data as a string. If the callback takes no
-- parameters, it is called as a bare notification and must read from the fd
-- itself (e.g. via ljsocket:receive()). Mixing read_c and ljsocket receive on
-- the same fd is undefined — use one or the other consistently.
local read_cb = function (fd, read)
	return function ()
		--[[FIXME: ioctl to get full message in one call]]
		local len = read_c(fd, buf, 65536)
		if len ~= -1 then read(ffi.string(buf, len)) end
	end
end

--[[@param self epoll]] --[[@param fd fd_c]]
--: (self: epoll, fd: integer) -> nil
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

--: (self: epoll, fd: integer, read: (string) -> nil, close: (() -> nil) | nil, weak: boolean | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
--[[@return epoll_write? write, epoll_remove? remove, string? err]]
--[[@param fd fd_c]] --[[@param read epoll_read]] --[[@param close epoll_close?]] --[[@param weak boolean? if false, self.count is not incremented]]
epoll.add = function (self, fd, read, close, weak)
	local self = self --[[:! epoll]]
	--[[@diagnostic disable-next-line: assign-type-mismatch]]
	fd = tonumber(fd) --[[:! integer]]
	if self.read_cbs[fd] then return nil, nil, "epoll: already polling fd: " .. fd end
	local events = epoll_event({ { events = 1, fd = fd } }) --- @type {[0]:epoll_event}
	local fninfo = debug.getinfo(read)
	self.read_cbs[fd] = (fninfo.nparams > 0 or fninfo.isvararg) and read_cb(fd, read) or read
	local write_buf = ""
	self.write_cbs[fd] = function ()
		write_c(fd, write_buf, #write_buf)
		write_buf = ""
		events[0].events = 1 --[[EPOLLIN]]
		if epoll_ffi.epoll_ctl(self.fd, --[[EPOLL_CTL_MOD]] 3, fd, events) ~= 0 then
			error("epoll: write callback failed")
		end
	end
	self.close_cbs[fd] = close
	local write = function (data) --[[@param data string]]
		write_buf = write_buf .. data
		events[0].events = 5 --[[EPOLLIN | EPOLLOUT]]
		if epoll_ffi.epoll_ctl(self.fd, --[[EPOLL_CTL_MOD]] 3, fd, events) ~= 0 then
			error("epoll: write failed")
		end
	end
	local remove = function ()
		remove_fd(self, fd)
		--[[this may silently fail if the socket has been closed.]]
		epoll_ffi.epoll_ctl(self.fd, --[[EPOLL_CTL_DEL]] 2, fd, events)
	end
	if epoll_ffi.epoll_ctl(self.fd, --[[EPOLL_CTL_ADD]] 1, fd, events) ~= 0 then
		return nil, nil, "epoll: add failed"
	end
	self.rets[fd] = { write = write, remove = remove }
	if weak then self.weak[fd] = true
	else self.count = self.count + 1 end
	return write, remove
end
mod.add = epoll.add

--: (epoll, number, (string) -> nil, (() -> nil) | nil) -> (((string) -> nil) | nil, (() -> nil) | nil, string | nil)
--[[@return epoll_write? write, epoll_remove? remove, string? error]]
--[[@param fd fd_c]] --[[@param read epoll_read]] --[[@param close epoll_close?]]
epoll.modify = function (self, fd, read, close)
	if not self.read_cbs[fd] then return nil, nil, "epoll: error: not polling fd: " .. fd end
	local fninfo = debug.getinfo(read)
	self.read_cbs[fd] = (fninfo.nparams > 0 or fninfo.isvararg) and read_cb(fd, read) or read
	self.close_cbs[fd] = close
	local rets = self.rets[fd]
	--[[@diagnostic disable-next-line: need-check-nil]]
	return rets.write, rets.remove
end

--: (epoll) -> nil
epoll.wait = function (self)
	local events = epoll_event() --[[@type epoll_event[] ]]
	epoll_ffi.epoll_wait(self.fd, events, 1, -1)
	local event = events[0] --[[@type epoll_event]]
	--[[@diagnostic disable-next-line: assign-type-mismatch]]
	local fd = tonumber(event.fd) --[[:! integer]]
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
mod.wait = epoll.wait

--: (epoll) -> nil
--[[loops forever]]
epoll.loop = function (self)
	while self.count > 0 do
		local ok, err = pcall(self.wait, self)
		if not ok then
			if type(err) == "string" and err:find("interrupted!", 1, true) then return end
			error(err, 0)
		end
	end
end
mod.loop = epoll.loop

return mod
