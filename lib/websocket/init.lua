if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sha1 = require("lib.hash.sha1").binary
local to_base64 = require("lib.encode.base64").encode
local frame = require("lib.websocket.frame")

local mod = {}

--:: websocket_message = { type: string, payload?: string, status?: integer }
--:: websocket_decode_acc = { [string]: unknown, ... }
--:: ws_sock = { fd: integer, send: (self: ws_sock, string) -> unknown, receive: (self: ws_sock) -> string | nil, close: (self: ws_sock) -> unknown }
--:: ws_epoll = { modify: (self: ws_epoll, fd: integer, read_fn: () -> (), close_fn: () -> ()) -> (((string) -> ()) | nil, (() -> ()) | nil) }

-- Re-export frame codec tables for backward compatibility
-- status_ids keeps the original verbose key names from RFC 6455 §7.4.1
--: { [string]: integer }
mod.status_ids = {
	normal = 1000,
	going_away = 1001,
	protocol_error = 1002,
	unknown_data_format = 1003,
	-- reserved = 1004,
	--[[@deprecated Reserved value. Marked deprecated to ensure it is being used properly.]]
	status_missing = 1005,
	--[[@deprecated Reserved value. Marked deprecated to ensure it is being used properly.]]
	abnormal_closure = 1006,
	-- RFC 6455 §7.4.1: received data within a message that was not consistent
	-- with the type of the message (e.g., non-UTF-8 data in a text message).
	data_not_consistent_with_message_type = 1007,
	violates_policy = 1008,
	message_too_big = 1009,
	client_server_did_not_negotiate_extensions = 1010,
	server_unexpected_failure = 1011,
	--[[@deprecated Reserved value. Marked deprecated to ensure it is being used properly.]]
	tls_handshake_failure = 1015,
}
--: { [string]: integer }
mod.opcode = frame.opcode
--: { [string]: integer }
mod.error = frame.error

-- Re-export frame module
mod.frame = frame

-- Expose frame codec for testing and advanced use (backward compat).
mod._encode = frame.encode
-- Backward-compat: decode(packet, acc?) returning msg, fin_or_err, mask, mi, remaining_len
--: (string, websocket_decode_acc | nil) -> (websocket_message | nil, boolean|integer, { [integer]: integer } | nil, integer | nil, integer)
mod._decode = function(packet, acc)
	return frame._decode_full(packet, acc)
end

--: (ws_sock, string) -> nil
local err = function(sock, body)
	sock:send("HTTP/1.1 400 Bad Request\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
	sock:close()
end

-- TODO(api): error representation is integer codes; consider converting to string
-- errors for a more ergonomic API. Deferred — requires a breaking API change.
-- The second return value of decode() is currently overloaded (boolean ready OR
-- error code). Fixing the return convention is also a breaking change. Deferred.

-- TODO(policy): consider enforcing a maximum incoming frame/packet size to
-- guard against memory exhaustion. Deferred — policy decision for the caller.

-- TODO(refactor): refactor so the outer function takes the handler and returns
-- function(sock, req), enabling use as middleware without a closure per call.
--: (sock: ws_sock, req: { headers: { [string]: string[] }, ... }, read: (sock: ws_sock, msg: websocket_message) -> nil, close: ((sock: ws_sock) -> nil) | nil, epoll: ws_epoll) -> (((msg: websocket_message) -> nil) | nil, (() -> nil) | nil)
mod.websocket = function(sock, req, read, close, epoll)
	if (req.headers["upgrade"] or {})[1] ~= "websocket" or (req.headers["connection"] or {})[1] ~= "Upgrade" then return nil end
	-- TODO(api): return a numeric error code here instead of sending the HTTP
	-- response inline, so the caller can decide how to respond. Deferred —
	-- requires a breaking API change.
	if (req.headers["sec-websocket-version"] or {})[1] ~= "13" then return err(sock, "Unsupported WebSocket version - only v13 supported") end
	--[[chrome supports permessage-deflate and client_max_window_bits]]
	--[[if req.headers["sec-websocket-extensions"] then return err(sock, "WebSocket extensions are not supported") end]]
	local key = (req.headers["sec-websocket-key"] or {})[1]
	if key == nil then return err(sock, "Missing header: Sec-WebSocket-Key") end
	if #key ~= 24 then return err(sock, "Invalid header length - should be 24: Sec-WebSocket-Key") end
	if not key:find("^[A-Za-z0-9+/]+==$") then return err(sock, "Invalid header - not base64: Sec-WebSocket-Key") end
	-- Sec-WebSocket-Protocol: subprotocol negotiation is not implemented.
	-- If a client requests a subprotocol, we ignore it and proceed without one.
	-- RFC 6455 §4.1 allows the server to omit the Sec-WebSocket-Protocol
	-- header if it does not support the requested subprotocol.
	local msg, ready, mask, mi
	local remaining_len = 0
	local unmask = frame._unmask
	local write, remove = epoll:modify(sock.fd, function()
		-- TODO(perf): once multi-frame handling is confirmed correct, set
		-- receive size to 131072 for better throughput with Chrome.
		local packet = sock:receive()
		-- TODO(perf): pass an offset index into packet instead of slicing with
		-- :sub() to avoid allocation in the multi-frame loop.
		if not packet then return end
		while #packet > 0 do
			if remaining_len > 0 then
				local part
				part, mi = unmask(packet, 1, remaining_len, mask, mi)
				if msg then msg.payload = msg.payload .. part end
			else
				msg, ready, mask, mi, remaining_len = frame._decode_full(packet, msg)
				if not msg then ready = nil; remaining_len = 0; return end --[[errored]]
			end
			local old_packet_len = #packet
			packet = packet:sub(remaining_len + 1)
			remaining_len = remaining_len - old_packet_len
			if ready and remaining_len == 0 then
				if msg then read(sock, msg --[[:! websocket_message]]) end
				msg = nil
			end
		end
	end, function() if close then close(sock) end end)
	if not write then return nil end
	local sha1_fn = sha1 --[[:! (string) -> string]]
	local b64_fn = to_base64 --[[:! (string) -> string]]
	write((([[
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: ]] .. b64_fn(sha1_fn(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) .. [[


]]):gsub("\n", "\r\n")))
	local send = function(msg2)
		local buf = frame.encode(msg2)
		if buf then write(buf) end
	end
	return send, remove
end

return mod
