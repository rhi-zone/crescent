local socket = require("lib.socket.server")
--:: ForkHttpRequest = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: ForkHttpResponse = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }
local http = require("lib.http.format")
local ffi = require("ffi")

local mod = {}

ffi.cdef [[int /*pid_t*/ fork(void);]]

--:: SockClient = { receive: (SockClient) -> string | nil, send: (SockClient, string) -> nil, close: (SockClient) -> nil }
--: ((ForkHttpRequest, ForkHttpResponse, SockClient) -> unknown) -> (SockClient) -> nil
mod.make_connection_handler = function (handler)
	--: (SockClient) -> nil
	return function (client)
		local client_ = client
		local s = client_:receive()
		if not s then return end --[[silently fail]]
		--[[TODO: multi-packet bodies]]
		local req, i = http.parse_request(s)
		if not req or not i then client_:send(http.serialize_response({ status = 400, reason = "Bad Request", version = "HTTP/1.1", headers = {}, body = nil })); return end
		local res = { headers = {}, status = 200, reason = "OK", version = "HTTP/1.1", body = nil } --: ForkHttpResponse
		local pid = ffi.C.fork()
		if pid ~= 0 then client_:close(); print("main ok") return end
		handler(req, res, client_)
		client_:send(http.serialize_response(res))
		client_:close()
		os.exit(0)
	end
end

--: ((ForkHttpRequest, ForkHttpResponse, SockClient) -> unknown, integer | nil, unknown | nil) -> unknown
mod.server = function (handler, port, epoll)
	return socket.server(mod.make_connection_handler(handler), port or 80, epoll)
end

return mod
