local socket = require("lib.ljsocket")
local format = require("lib.http.format")

local mod = {}

--[[TODO: tls: https://github.com/CapsAdmin/luajitsocket/blob/master/examples/tcp_client_blocking_tls.lua]]

--[[@param req http_client_request]]
mod.send = function (req)
	if not req.host then error("http_client.send: missing host") end
	local client, err = socket.create("inet", "stream", "tcp")
	if not client then return nil, err end
	local ok
	ok, err = client:connect(req.host, req.port or "http")
	if not ok then return nil, err end
	req.headers = req.headers or {}
	if not req.headers["Host"] then req.headers["Host"] = { req.host } end
	ok, err = client:send(format.serialize_request({ method = req.method, target = req.path or "/", version = req.version or "HTTP/1.1", headers = req.headers, body = req.body }))
	if not ok then return nil, err end
	return client:receive()
end

return mod
