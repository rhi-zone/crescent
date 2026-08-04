-- WebSocket-capable HTTP server. Wraps lib/http/server with upgrade detection.
-- Handler contract: { http = fn?, ws_accept = fn?, ws = fn? }
--   ws_accept(req) -> (true | nil, errmsg) — called pre-handshake; optional (accept all if absent).
--   ws(ws_conn, req) -> nil — coroutine message loop, called after handshake.
--   No ws handler at all -> reject upgrades with 426.

local server = require("lib.http.server")
local ws_frame = require("lib.websocket.frame")
local sha1_binary = require("lib.hash.sha1").binary
local base64_encode = require("lib.encode.base64").encode

local ffi = require("ffi")

local mod = {}

--:: require "lib.http.server"

--:: WsMessage = { type: string, payload: string, status?: integer }
--:: WsConn = { recv: (self: WsConn) -> (WsMessage | nil, string | nil), send: (self: WsConn, string, string | nil) -> (boolean | nil, string | nil), close: (self: WsConn, integer | nil, string | nil) -> nil }
--:: WsHandlerFn = (ws_conn: WsConn, req: http_server_request) -> nil
--:: WsAcceptFn = (req: http_server_request) -> (boolean | nil, string | nil)
--:: WsHandlerTable = { http: HttpHandlerFn | nil, ws_accept: WsAcceptFn | nil, ws: WsHandlerFn | nil }

-- RFC 6455 §4.2.2 — WebSocket GUID for accept-key computation.
local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- Validate WebSocket upgrade request headers (RFC 6455 §4.2.1).
-- Returns the Sec-WebSocket-Key on success, or (nil, errmsg) on failure.
--: (http_server_request) -> (string | nil, string | nil)
local function ws_validate_upgrade(req)
	local conn_arr = req.headers["connection"]
	local conn_hdr = conn_arr and conn_arr[1]
	if not conn_hdr or not conn_hdr:lower():find("upgrade", 1, true) then
		return nil, "Connection header must include Upgrade"
	end
	local ver_arr = req.headers["sec-websocket-version"]
	if not ver_arr or ver_arr[1] ~= "13" then
		return nil, "unsupported WebSocket version"
	end
	local key_arr = req.headers["sec-websocket-key"]
	local key = key_arr and key_arr[1]
	if not key then return nil, "missing Sec-WebSocket-Key" end
	if #key ~= 24 then return nil, "invalid Sec-WebSocket-Key length" end
	if not key:find("^[A-Za-z0-9+/]+==$") then return nil, "invalid Sec-WebSocket-Key encoding" end
	return key
end

-- Compute the total byte count of a WebSocket frame from its header prefix.
-- Client-to-server frames always have the mask bit set (4-byte mask key).
-- Returns the total frame size, or nil if not enough bytes buffered yet.
--: (string, integer) -> integer | nil
local function ws_frame_byte_count(data, len)
	if len < 2 then return nil end
	local b1 = string.byte(data, 2) or 0
	local has_mask = bit.band(b1, 0x80) ~= 0
	local len_indicator = bit.band(b1, 0x7f)
	local header_size = 2 --: integer
	local payload_len = 0 --: integer
	if len_indicator <= 125 then
		payload_len = len_indicator
	elseif len_indicator == 126 then
		if len < 4 then return nil end
		header_size = 4
		payload_len = bit.bor(bit.lshift(string.byte(data, 3) or 0, 8), string.byte(data, 4) or 0)
	else
		if len < 10 then return nil end
		header_size = 10
		local b3, b4, b5, b6, b7, b8, b9, b10 = string.byte(data, 3, 10)
		local hi = bit.bor(bit.lshift(b3 or 0, 24), bit.lshift(b4 or 0, 16), bit.lshift(b5 or 0, 8), b6 or 0)
		local lo = bit.bor(bit.lshift(b7 or 0, 24), bit.lshift(b8 or 0, 16), bit.lshift(b9 or 0, 8), b10 or 0)
		-- TYPECHECKER WORKAROUND: 64-bit payload length computed as double
		-- from hi * 2^32 + lo. The natural type is number but callers need
		-- integer. The typechecker lacks number-to-integer narrowing for
		-- arithmetic results known to be integral. Same pattern as frame.lua:197.
		payload_len = (hi * 0x100000000 + lo) --[[:! integer]]
	end
	if has_mask then header_size = header_size + 4 end
	return header_size + payload_len
end

-- Create a coroutine-friendly WebSocket connection object.
-- Wraps the async socket for frame-level I/O with correct buffering.
-- recv() yields until a complete application message arrives; send() encodes
-- and writes a frame via the yield-aware socket; close() initiates the close
-- handshake. Control frames (ping/pong/close) are handled transparently.
--: (http_client_sock, cdata) -> WsConn
local function make_ws_conn(client, recv_buf)
	local buffer = "" --: string
	local closed = false --: boolean

	-- Read bytes from socket into buffer. Yields on EAGAIN via async I/O.
	--: () -> boolean
	local function fill()
		local s = client:receive(recv_buf)
		if not s then return false end
		buffer = buffer .. s
		return true
	end

	-- Ensure the buffer contains at least n bytes. Yields as needed.
	--: (integer) -> boolean
	local function ensure(n)
		while #buffer < n do
			if not fill() then return false end
		end
		return true
	end

	local conn = {}

	-- Yield until a complete application message (text or binary) arrives.
	-- Returns (message, nil) on success, or (nil, errmsg) on close/error.
	-- Handles continuation frames transparently. Auto-responds to pings
	-- with pongs. Control frames interleaved mid-fragmentation are decoded
	-- independently so they do not clobber the data-frame accumulator.
	--: (self: WsConn) -> (WsMessage | nil, string | nil)
	function conn:recv()
		if closed then return nil, "closed" end
		local acc = nil --: WsMessage | nil
		while true do
			if not ensure(2) then return nil, "connection closed" end
			local frame_total = ws_frame_byte_count(buffer, #buffer)
			while not frame_total do
				if not fill() then return nil, "connection closed" end
				frame_total = ws_frame_byte_count(buffer, #buffer)
			end
			-- Redundant guard: the while loop above ensures frame_total is
			-- non-nil, but the typechecker cannot track loop invariants.
			if not frame_total then return nil, "connection closed" end
			if not ensure(frame_total) then return nil, "connection closed" end
			local frame_bytes = buffer:sub(1, frame_total)
			buffer = buffer:sub(frame_total + 1)
			-- Control frames (opcode >= 8) decoded independently to avoid
			-- clobbering the fragmentation accumulator (RFC 6455 §5.4).
			local opcode = bit.band(string.byte(frame_bytes, 1) or 0, 0x0f)
			if opcode >= 0x8 then
				local msg, fin_or_err = ws_frame._decode_full(frame_bytes, nil)
				if not msg then return nil, "frame error: " .. tostring(fin_or_err) end
				if msg.type == "ping" then
					-- RFC 6455 §5.5.3 — respond with pong echoing the payload.
					local pong = ws_frame.encode({ type = "pong", payload = msg.payload or "" })
					if pong then client:send(pong) end
				elseif msg.type == "close" then
					-- RFC 6455 §5.5.1 — echo close frame, mark connection closed.
					local status_code = msg.status or 1000
					local close_payload = string.char(bit.rshift(status_code, 8), bit.band(status_code, 0xff))
					local resp = ws_frame.encode({ type = "close", payload = close_payload })
					if resp then pcall(client.send, client, resp) end
					closed = true
					return nil, "closed"
				end
				-- Pong: ignore, continue waiting for data frames.
			else
				-- Data frame (text, binary, or continuation).
				local msg, fin_or_err = ws_frame._decode_full(frame_bytes, acc)
				if not msg then return nil, "frame error: " .. tostring(fin_or_err) end
				if fin_or_err == true then return msg, nil end
				-- Fragmented: save accumulator and continue.
				acc = msg
			end
		end
	end

	-- Send a WebSocket message frame.
	-- msg_type: "text" (default) or "binary".
	--: (self: WsConn, string, string | nil) -> (boolean | nil, string | nil)
	function conn:send(data, msg_type)
		if closed then return nil, "closed" end
		local encoded = ws_frame.encode({ type = msg_type or "text", payload = data })
		if not encoded then return nil, "invalid frame type" end
		local sent, err = client:send(encoded)
		if not sent then return nil, err end
		return true
	end

	-- Initiate the close handshake. No-op if already closed.
	-- code: status code (default 1000). reason: optional UTF-8 string.
	--: (self: WsConn, integer | nil, string | nil) -> nil
	function conn:close(code, reason)
		if closed then return end
		closed = true
		local status_code = code or 1000
		local payload = string.char(bit.rshift(status_code, 8), bit.band(status_code, 0xff))
		if reason then payload = payload .. reason end
		local encoded = ws_frame.encode({ type = "close", payload = payload })
		if encoded then pcall(client.send, client, encoded) end
	end

	return conn
end

-- Build an HttpHandlerFn wrapper that intercepts WebSocket upgrade requests
-- and delegates non-upgrade requests to the user's http handler.
--: (WsHandlerTable) -> HttpHandlerFn
local function make_ws_wrapper(handler_table)
	local http_handler = handler_table.http
	local ws_accept_fn = handler_table.ws_accept
	local ws_handler_fn = handler_table.ws
	local recv_buf = ffi.new("char[65536]")

	--: (http_server_request, http_server_response, http_client_sock) -> (boolean | nil)
	return function(req, res, client)
		local upgrade_val = req.headers["upgrade"]
		if not (upgrade_val and upgrade_val[1] and upgrade_val[1]:lower() == "websocket") then
			-- Not an upgrade request — delegate to http handler.
			if http_handler then
				return http_handler(req, res, client)
			end
			res.status = 404
			res.reason = "Not Found"
			return
		end

		-- WebSocket upgrade detection (RFC 6455 §4.2.1).
		if not ws_handler_fn then
			res.status = 426
			res.reason = "Upgrade Required"
			res.headers["upgrade"] = { "websocket" }
			return
		end

		if ws_accept_fn then
			local accepted, reject_reason = ws_accept_fn(req)
			if not accepted then
				local body = reject_reason or "WebSocket upgrade rejected"
				res.status = 403
				res.reason = "Forbidden"
				res.headers["content-length"] = { tostring(#body) }
				res.body = body
				return
			end
		end

		local client_key, verr = ws_validate_upgrade(req)
		if not client_key then
			local body = verr or "Bad WebSocket request"
			res.status = 400
			res.reason = "Bad Request"
			res.headers["content-length"] = { tostring(#body) }
			res.body = body
			return
		end

		local accept_value = base64_encode(sha1_binary(client_key .. WS_GUID))
		client:send(
			"HTTP/1.1 101 Switching Protocols\r\n"
			.. "Upgrade: websocket\r\n"
			.. "Connection: Upgrade\r\n"
			.. "Sec-WebSocket-Accept: " .. accept_value .. "\r\n"
			.. "\r\n"
		)

		local ws_conn = make_ws_conn(client, recv_buf)
		ws_handler_fn(ws_conn, req)
		ws_conn:close()
		client:close()
		res.raw = true
	end
end

-- Public API: accepts a handler table { http?, ws_accept?, ws? }, optional
-- keep-alive options, and the optional connection origin (see http_origin).
-- Returns a connection handler suitable for socket.server.
--: (WsHandlerTable, HttpKeepAliveOpts | nil, http_origin | nil) -> (http_client_sock) -> nil
mod.make_connection_handler = function(handler_table, ka_opts, origin)
	return server.make_connection_handler(make_ws_wrapper(handler_table), ka_opts, origin)
end

-- Convenience entry point mirroring server.server() but accepting a handler
-- table instead of a plain function.
--: (WsHandlerTable, integer | nil, unknown | nil, { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil } | nil) -> unknown
mod.server = function(handler_table, port, epoll, opts)
	local wrapper = make_ws_wrapper(handler_table)
	return server.server(wrapper, port, epoll, opts)
end

-- Test-only exports.
mod._ws_validate_upgrade = ws_validate_upgrade
mod._ws_frame_byte_count = ws_frame_byte_count
mod._make_ws_conn = make_ws_conn
mod._WS_GUID = WS_GUID

return mod
