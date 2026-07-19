local socket_ = require("lib.socket.server")

local mod = {}

--: (((string) -> nil, () -> nil) -> (string) -> nil, integer, unknown | nil) -> nil
mod.server = function (handler, port, epoll)
	return socket_.server(function (client)
		local client_ = client --[[:! { send: (unknown, string) -> nil, close: (unknown) -> nil, receive: (unknown) -> string | nil, ... }]]
		local h = handler(function (s) client_:send(s) end, function () client_:close() end)
		while true do
			local received = client_:receive()
			if not received then client_:close(); break end
			h(received)
		end
	end, port, epoll)
end

return mod
