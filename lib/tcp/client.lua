local epoll_ = require("lib.epoll") --[[: any]]
local socket = require("lib.ljsocket") --[[: any]]

local mod = {}

--[[@return fun(s: string) write, fun() close]]
--[[@param host string]] --[[@param port integer]] --[[@param cb fun(s: string) callback]] --[[@param epoll epoll?]]
mod.client = function (host, port, cb, epoll)
	local is_running = not epoll
	epoll = epoll or epoll_.new()
	local epoll_any = epoll --[[: any]]
	local client = assert(socket.create(host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") and "inet" or "inet6", "stream", "tcp"))
	assert(client:set_blocking(false))
	local success, err = client:connect(host, port)
	if not success then
		client = assert(socket.create("inet", "stream", "tcp"))
		assert(client:set_blocking(false))
		assert(client:connect(host, port))
	end
	local client_any = client --[[: any]]
	while not client_any:is_connected() do client_any:poll_connect() end
	--[[TODO: receive all at once?]]
	local _, remove = epoll_any:add(client_any.fd, cb, function () client_any:close() end)
	assert(remove, "tcp_client: could not listen to socket")
	while is_running do epoll_any:wait() end
	--[[@param s string]]
	local remove_any = remove --[[: any]]
	return function (s) client_any:send(s) end, function () remove_any(); client_any:close() end
end

return mod
