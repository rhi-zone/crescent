local socket = require("lib.ljsocket")
local epoll_mod = require("lib.epoll")
local format = require("lib.http.format")

local mod = {}

--[[TODO: tls: https://github.com/CapsAdmin/luajitsocket/blob/master/examples/tcp_client_blocking_tls.lua]]

-- Blocking send: connect, send request, receive full response, return it.
--: ({ host: string, port: string | nil, method: string | nil, path: string | nil, version: string | nil, headers: { [string]: unknown } | nil, body: string | nil, ... }) -> (string | nil, string | nil)
mod.send = function (req)
	if not req.host then error("http_client.send: missing host") end
	local client, err = socket.create("inet", "stream", "tcp")
	if not client then return nil, err end
	local ok
	ok, err = client:connect(req.host, req.port or "http")
	if not ok then return nil, err end
	req.headers = req.headers or {}
	local headers_ = req.headers --[[:! { [string]: unknown }]]
	if not headers_["Host"] then headers_["Host"] = { req.host } end
	ok, err = client:send(format.serialize_request({ method = req.method, target = req.path or "/", version = req.version or "HTTP/1.1", headers = req.headers, body = req.body }))
	if not ok then return nil, err end
	return client:receive()
end

-- Non-blocking send via epoll.
-- When epoll is provided, registers the socket on the caller's loop and returns immediately.
-- When epoll is nil, creates a local epoll instance and blocks until the response is complete.
-- cb is called as cb(response_string, err_string).
--: ({ host: string, port: string | nil, method: string | nil, path: string | nil, version: string | nil, headers: { [string]: unknown } | nil, body: string | nil, ... }, (string | nil, string | nil) -> nil, unknown | nil) -> nil
mod.send_async = function (req, cb, ep)
	if not req.host then cb(nil, "http_client.send_async: missing host"); return end
	local is_owner = not ep
	ep = ep or epoll_mod.new()

	local client_, err = socket.create("inet", "stream", "tcp")
	if not client_ then cb(nil, err); return end
	local client = client_ --[[: any]]

	local ok
	ok, err = client:set_blocking(false)
	if not ok then client:close(); cb(nil, err); return end

	-- Non-blocking connect: EINPROGRESS is normal; poll until connected.
	client:connect(req.host, req.port or "http")
	while not client:is_connected() do client:poll_connect() end

	req.headers = req.headers or {}
	local headers2_ = req.headers --[[:! { [string]: unknown }]]
	if not headers2_["Host"] then headers2_["Host"] = { req.host } end
	local request_bytes = format.serialize_request({
		method = req.method,
		target = req.path or "/",
		version = req.version or "HTTP/1.1",
		headers = req.headers,
		body = req.body,
	})
	ok, err = client:send(request_bytes)
	if not ok then client:close(); cb(nil, err); return end

	local buf = {}
	local done = false
	local remove  -- forward-declared so the read callback can capture it as an upvalue

	local ep_ = ep --[[: any]]
	local _ -- write callback (unused by client)
	_, remove = ep_:add(client.fd, function ()
		if done then return end
		-- epoll notifies readability; we read from the socket ourselves.
		local chunk = client:receive()
		if chunk and #chunk > 0 then
			buf[#buf + 1] = chunk
		end
		-- Check if we have a complete response: headers terminated + content-length satisfied.
		local data = table.concat(buf)
		local parse_response_ = format.parse_response --[[:! (string) -> unknown]]
		local resp = parse_response_(data)
		if resp then
			done = true
			if remove then remove() end
			client:close()
			cb(data, nil)
		end
	end, function ()
		if not done then
			done = true
			local data = table.concat(buf)
			if #data > 0 then cb(data, nil)
			else cb(nil, "http_client: connection closed before response") end
		end
		client:close()
	end)

	if not remove then
		client:close()
		cb(nil, "http_client: epoll registration failed")
		return
	end

	if is_owner then
		local ep_ = ep --[[: any]]
		ep_:loop()
	end
end

return mod
