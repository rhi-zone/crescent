local socket_ = require("lib.socket.server")

local mod = {}

--: (((string) -> nil, () -> nil) -> (string) -> nil, integer, unknown | nil) -> nil
mod.server = function (handler, port, epoll)
	return socket_.server(function (client, state)
		local client_ = client --[[: unknown]]
		state = state or { handler = handler(function (s) client_:send(s) end, function () client_:close() end) }
		local received = client_:receive()
		if received then  state.handler(received) else client_:close() end
		return state
	end, port, epoll)
end

return mod
