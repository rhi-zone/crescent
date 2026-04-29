if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sha1 = require("lib.hash.sha1").binary
local to_base64 = require("lib.encode.base64").encode
local frame = require("lib.websocket.frame")

local mod = {}

-- Re-export frame codec tables for backward compatibility
-- status_ids keeps the original verbose key names from RFC 6455 §7.4.1
--: table
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
--: table
mod.opcode = frame.opcode
--: table
mod.error = frame.error

-- Re-export frame module
mod.frame = frame

-- Expose frame codec for testing and advanced use (backward compat).
--: (table) -> string | nil
mod._encode = frame.encode
-- Backward-compat: decode(packet, acc?) returning msg, fin_or_err, mask, mi, remaining_len
--: (string, table | nil) -> (table | nil, boolean|integer, table | nil, integer | nil, integer)
mod._decode = function(packet, acc)
	return frame._decode_full(packet, acc)
end

--[[@param sock luajitsocket]]
--[[@param body string]]
local err = function(sock, body)
	sock:send("HTTP/1.1 400 Bad Request\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
	sock:close()
end

--[[@alias websocket_send fun(msg: websocket_message)]]
--[[@alias websocket_close fun()]]

--[[@class websocket_message_base]]
--[[@field type string]]
--[[@field payload string]]

--[[@class websocket_message_text: websocket_message_base]]
--[[@field type "text"]]

--[[@class websocket_message_binary: websocket_message_base]]
--[[@field type "binary"]]

--[[@class websocket_message_close: websocket_message_base]]
--[[@field type "close"]]
--[[@field status integer]]

--[[@class websocket_message_ping: websocket_message_base]]
--[[@field type "ping"]]

--[[@class websocket_message_pong: websocket_message_base]]
--[[@field type "pong"]]
--[[@field payload string Must be the same as the payload of the ping, if sent in response to a ping.]]

--[[@alias websocket_message websocket_message_text|websocket_message_binary|websocket_message_close|websocket_message_ping|websocket_message_pong]]

-- TODO(api): error representation is integer codes; consider converting to string
-- errors for a more ergonomic API. Deferred — requires a breaking API change.
-- The second return value of decode() is currently overloaded (boolean ready OR
-- error code). Fixing the return convention is also a breaking change. Deferred.

-- TODO(policy): consider enforcing a maximum incoming frame/packet size to
-- guard against memory exhaustion. Deferred — policy decision for the caller.

-- TODO(refactor): refactor so the outer function takes the handler and returns
-- function(sock, req), enabling use as middleware without a closure per call.
--[[@return websocket_send? send, websocket_close? close]]
--[[@param sock luajitsocket]]
--[[@param req http_request]]
--[[@param read fun(sock: luajitsocket, msg: websocket_message)]]
--[[@param close fun(sock: luajitsocket)|nil]]
--[[@param epoll epoll]]
--: (table, table, (table, table) -> nil, (table) -> (nil, table) -> (table) -> nil, () -> nil)
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
				msg.payload = msg.payload .. part
			else
				--[[@diagnostic disable-next-line: cast-local-type]]
				msg, ready, mask, mi, remaining_len = frame._decode_full(packet, msg)
				if not msg then ready = nil; remaining_len = 0; return end --[[errored]]
			end
			local old_packet_len = #packet
			packet = packet:sub(remaining_len + 1)
			remaining_len = remaining_len - old_packet_len
			if ready and remaining_len == 0 then read(sock, msg); msg = nil end
		end
	end, function() if close then close(sock) end end)
	assert(write)
	write((([[
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: ]] .. to_base64(sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) .. [[


]]):gsub("\n", "\r\n")))
	--[[@param msg2 websocket_message]]
	local send = function(msg2)
		local buf = frame.encode(msg2)
		if buf then write(buf) end
	end
	return send, remove
end

return mod
