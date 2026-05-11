local epoll_ = require("lib.epoll")
local socket = require("lib.ljsocket")

local mod = {}

--: (string, integer, (string) -> nil, unknown | nil) -> ((string) -> nil, () -> nil)
mod.client = function (host, port, cb, epoll)
	local is_running = not epoll
	epoll = epoll or epoll_.new()
	local epoll_any = (epoll --[[: unknown]]) --[[:! { add: (self: unknown, unknown, unknown, unknown) -> (unknown, unknown), wait: (...unknown) -> unknown, ... }]]
	local client = (assert(socket.create(host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") and "inet" or "inet6", "stream", "tcp")) --[[: unknown]]) --[[:! { set_blocking: (...unknown) -> unknown, connect: (...unknown) -> unknown, is_connected: (...unknown) -> unknown, poll_connect: (...unknown) -> unknown, send: (...unknown) -> unknown, close: (...unknown) -> unknown, fd: integer, ... }]]
	assert(client:set_blocking(false))
	local success, err = client:connect(host, port)
	if not success then
		client = (assert(socket.create("inet", "stream", "tcp")) --[[: unknown]]) --[[:! { set_blocking: (...unknown) -> unknown, connect: (...unknown) -> unknown, is_connected: (...unknown) -> unknown, poll_connect: (...unknown) -> unknown, send: (...unknown) -> unknown, close: (...unknown) -> unknown, fd: integer, ... }]]
		assert(client:set_blocking(false))
		assert(client:connect(host, port))
	end
	while not client:is_connected() do client:poll_connect() end
	--[[TODO: receive all at once?]]
	local _, remove = epoll_any:add(client.fd, cb, function () client:close() end)
	assert(remove, "tcp_client: could not listen to socket")
	while is_running do (epoll_any --[[:! { wait: (...unknown) -> unknown, ... }]]):wait() end
	local remove_any = (remove --[[: unknown]]) --[[:! () -> nil]]
	return function (s) client:send(s) end, function () remove_any(); client:close() end
end

return mod
