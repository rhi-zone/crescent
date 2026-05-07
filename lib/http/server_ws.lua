-- TODO: let static plugin support last-modified
-- alternatively leave it until panek web:
-- get last modified -> set header -> read file ------------> serve
--                                       `-detect mimetype-----^

local socket = require("lib.socket.server")
local ws = require("lib.websocket")
--:: WsHttpRequest = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: WsHttpResponse = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: WsHttpMod = { parse_request: (string, integer | nil) -> (WsHttpRequest | nil, integer | nil, string | nil), serialize_response: (WsHttpResponse) -> string }
local http = require("lib.http.format") --[[:! WsHttpMod]]
local epoll_ = require("lib.epoll")

local mod = {}

--[[TODO: sse]]
--[[@alias sse_callback fun(): (send: (fun(evt: sse_event)))]]
--[[@alias ws_callback fun(sock: luajitsocket, msg: websocket_message)]]
--[[@alias ws_open_callback fun(sock: luajitsocket, send: websocket_send, close: websocket_close)]]
--[[@alias ws_close_callback fun(sock: luajitsocket)]]

--[[@class sse_event]]

--[[@class http_like_callbacks]]
--[[@field http http_callback?]]
--[[@field sse sse_callback?]]
--[[@field ws ws_callback?]]
--[[@field ws_open ws_open_callback?]]
--[[@field ws_close ws_close_callback?]]

--[[TODO: figure out whether `make_connection_handler` can be removed after restructuring https server?]]

--:: WsSockClient = { receive: (WsSockClient) -> string | nil, send: (WsSockClient, string) -> nil, close: (WsSockClient) -> nil }
--:: WsHandler = { http: ((WsHttpRequest, WsHttpResponse, WsSockClient) -> nil) | nil, ws: ((WsSockClient, { payload: string, status: integer | nil, type: string }) -> nil) | nil, ws_open: ((WsSockClient, unknown, unknown) -> nil) | nil, ws_close: ((WsSockClient) -> nil) | nil }
--[[@param handler http_like_callbacks]] --[[@param epoll epoll]]
mod.make_connection_handler = function (handler, epoll)
	local handler_ = handler --[[:! WsHandler]]
	--: (WsSockClient) -> nil
	return function (client)
		local client_ = client --[[:! WsSockClient]]
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
			local handler_any = handler_ --[[: any]]
			local send, close = ws.websocket(client_ --[[: any]], req, handler_any.ws, handler_any.ws_close, epoll)
			local ws_open_ = handler_.ws_open
			if send and close and ws_open_ then
				local ws_open_fn_ = ws_open_ --[[:! (WsSockClient, unknown, unknown) -> nil]]
				ws_open_fn_(client_, send, close)
			end
		else
			local http_fn_any = handler_ --[[: any]]
			local ok, err = pcall(http_fn_any.http, req, res, client_)
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

--[[@param handler http_callback|http_like_callbacks]] --[[@param port? integer]] --[[@param epoll? epoll]]
mod.server = function (handler, port, epoll)
	local is_running = not epoll
	epoll = epoll or epoll_:new()
	if type(handler) == "function" then handler = { http = handler } end
	socket.server(mod.make_connection_handler(handler, epoll), port or 80, epoll)
	if is_running then (epoll --[[: any]]):loop() end
end

return mod
