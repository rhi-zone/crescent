-- TODO: let static plugin support last-modified
-- alternatively leave it until panek web:
-- get last modified -> set header -> read file ------------> serve
--                                       `-detect mimetype-----^

local socket = require("lib.socket.server")
local ws = require("lib.websocket")
--:: WsHttpRequest = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: WsHttpResponse = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }
local http = require("lib.http.format")
local epoll_ = require("lib.epoll")

local mod = {}

--[[TODO: sse]]

--[[TODO: figure out whether `make_connection_handler` can be removed after restructuring https server?]]

--:: WsSockClient = { receive: (WsSockClient) -> string | nil, send: (WsSockClient, string) -> nil, close: (WsSockClient) -> nil }
--:: WsHandler = { http: ((WsHttpRequest, WsHttpResponse, WsSockClient) -> nil) | nil, ws: ((WsSockClient, { payload: string, status: integer | nil, type: string }) -> nil) | nil, ws_open: ((WsSockClient, unknown, unknown) -> nil) | nil, ws_close: ((WsSockClient) -> nil) | nil }
--: (WsHandler, ws_epoll) -> (WsSockClient) -> nil
mod.make_connection_handler = function (handler, epoll)
	local handler_ = handler
	--: (WsSockClient) -> nil
	return function (client)
		local client_ = client
		local s = client_:receive()
		if not s then return end -- silently fail

		-- TODO: multi-packet bodies
		local req, i = http.parse_request(s)
		if not req or not i then return end
		-- TODO: send response
		local res = { status = 200, reason = "OK", version = "HTTP/1.1", headers = {}, body = nil } --: WsHttpResponse
		-- TODO: sse - since the request is the same as normal http
		-- it's a lot harder to just use if-else
		if (req.headers["upgrade"] or {})[1] == "websocket" then
			--[[FIXME: api. the handler needs a persistent handle to the connection]]
			local send, close = ws.websocket(
				(client_ --[[:! { close: (ws_sock) -> unknown, fd: integer, receive: (ws_sock) -> string | nil, send: (ws_sock, string) -> unknown }]]),
				req,
				((handler_.ws --[[: unknown]]) --[[:! (ws_sock, { payload?: string, status?: integer, type: string }) -> nil]]),
				handler_.ws_close, epoll)
			local ws_open_ = handler_.ws_open
			if send and close and ws_open_ then
				ws_open_(client_, send, close)
			end
		else
			local http_fn = handler_.http
			if not http_fn then client_:close(); return end
			local ok, err = pcall(http_fn, req, res, client_)
			if not ok then
				local msg = tostring(err):gsub('"', '\\"')
				res.status = 500
				res.headers["Content-Type"] = "application/json"
				res.body = '{"error":"' .. msg .. '"}'
			end
			client_:send(http.serialize_response(res))
			client_:close()
		end
	end
end

--: (WsHandler, integer | nil, ws_epoll | nil) -> nil
mod.server = function (handler, port, epoll)
	local is_running = not epoll
	epoll = (epoll or epoll_:new()) --[[:! ws_epoll]]
	if type(handler) == "function" then handler = ({ http = handler } --[[:! WsHandler]]) end
	socket.server(mod.make_connection_handler(handler, epoll), port or 80, epoll)
	if is_running then (epoll --[[:! { loop: (unknown) -> nil, ... }]]):loop() end
end

return mod
