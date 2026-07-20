local socket = require("lib.socket.server")
local http = require("lib.http.format")
local async = require("lib.async")
local ws_frame = require("lib.websocket.frame")
local sha1_binary = require("lib.hash.sha1").binary
local base64_encode = require("lib.encode.base64").encode

local mod = {}

--:: http_request = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: http_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: http_server_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil, raw: boolean | nil }

local ffi = require("ffi")
local buf = ffi.new("char[65536]")
local err_res = http.serialize_response({ status = 400, reason = "Bad Request", version = "HTTP/1.1", headers = {}, body = nil })
local max_header_size = 65536

-- TLS support: loaded lazily so the server still works when libtls is absent.
-- tls_lib is the lib/tls module (or nil if unavailable).
--:: TlsMod = { tls_c_ptr: () -> cdata, accept_socket: (cdata, cdata, integer) -> integer, error: (cdata) -> cdata, handshake: (cdata) -> integer, free: (cdata) -> nil, write: (cdata, unknown, integer) -> integer, read: (cdata, cdata, integer) -> integer, close: (cdata) -> nil, config_new: () -> cdata, config_set_keypair_file: (cdata, cdata, cdata) -> integer, config_error: (cdata) -> cdata, config_free: (cdata) -> nil, server: () -> cdata, configure: (cdata, cdata) -> integer }
local tls_lib --: TlsMod | nil
local tls_loaded = false
--: () -> TlsMod | nil
local function get_tls()
	if not tls_loaded then
		tls_loaded = true
		-- TODO: TlsMod type uses cdata for what real lib.tls returns as string; fix TlsMod to match lib.tls export shape, then this can be `tls_lib = require("lib.tls")` directly.
		local ok, t = pcall(require, "lib.tls")
		if ok then tls_lib = (t --[[: unknown]]) --[[:! TlsMod]] end
	end
	return tls_lib
end

--:: http_client_sock = { receive: (self: http_client_sock, unknown) -> string | nil, send: (self: http_client_sock, string) -> unknown, close: (self: http_client_sock) -> unknown, fd: integer, on_send: unknown, on_receive: unknown, _loop: unknown }
--:: HttpHandlerFn = (req: http_request, res: http_server_response, sock: http_client_sock) -> (boolean | nil)
--:: HttpKeepAliveOpts = { idle_timeout: number | nil, max_requests: integer | nil }
--:: WsMessage = { type: string, payload: string, status?: integer }
--:: WsConn = { recv: (self: WsConn) -> (WsMessage | nil, string | nil), send: (self: WsConn, string, string | nil) -> (boolean | nil, string | nil), close: (self: WsConn, integer | nil, string | nil) -> nil }
--:: WsHandlerFn = (ws_conn: WsConn, req: http_request) -> nil
--:: WsAcceptFn = (req: http_request) -> (boolean | nil, string | nil)
--:: WsHandlerTable = { http: HttpHandlerFn | nil, ws_accept: WsAcceptFn | nil, ws: WsHandlerFn | nil }

-- NOTE: cross-module named types are not yet supported; AsyncLoop is the
-- structural subset of lib/async LoopObj used here.
--:: AsyncLoop = { await_readable: (self: AsyncLoop, integer) -> (unknown, string | nil, (() -> nil) | nil), sleep: (self: AsyncLoop, number) -> { and_then: (self: unknown, (unknown) -> unknown) -> unknown, ... }, step: (self: AsyncLoop) -> nil, ... }

-- Determine whether to keep the connection alive based on HTTP version and
-- Connection header value.
--: (string, string) -> boolean
local function should_keep_alive(version, connection_header_val)
	local conn = connection_header_val:lower()
	if version == "HTTP/1.0" then
		return conn == "keep-alive"
	end
	-- HTTP/1.1 defaults to keep-alive unless Connection: close
	return conn ~= "close"
end

-- RFC 6455 §4.2.2 — WebSocket GUID for accept-key computation.
local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- Validate WebSocket upgrade request headers (RFC 6455 §4.2.1).
-- Returns the Sec-WebSocket-Key on success, or (nil, errmsg) on failure.
--: (http_request) -> (string | nil, string | nil)
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

-- Core connection handler factory. Takes pre-extracted handler components so
-- there is no function|table union to discriminate at the type level.
--: (HttpHandlerFn | nil, WsAcceptFn | nil, WsHandlerFn | nil, HttpKeepAliveOpts | nil) -> (http_client_sock) -> nil
local function make_handler_core(http_handler, ws_accept_fn, ws_handler_fn, ka_opts)
	local ka = ka_opts or {}
	local idle_timeout_ms = ka.idle_timeout or 60000
	local max_requests = ka.max_requests or 0

	--: (http_client_sock) -> nil
	return function(client)
		local client_ = client
		-- TYPECHECKER WORKAROUND: _loop is typed as `unknown` in http_client_sock
		-- because cross-module named types are not yet supported. The field is set
		-- by lib/socket/server to a LoopObj; force-cast here until the typechecker
		-- can propagate the type across module boundaries.
		local loop = (client_._loop --[[: unknown]]) --[[:! AsyncLoop | nil]]
		local request_count = 0
		local keep_alive = true

		while keep_alive do
			request_count = request_count + 1
			if max_requests > 0 and request_count > max_requests then break end

			-- Idle timeout between requests (skip for the very first read —
			-- the connection just arrived, data may already be buffered).
			if request_count > 1 and loop then
				local p, _perr, cancel = loop:await_readable(client_.fd)
				if not p then break end
				local timed_out = false
				local timer = loop:sleep(idle_timeout_ms)
				timer:and_then(function(_v)
					timed_out = true
					if cancel then cancel() end
				end)
				local await_ok = pcall(async.await, p)
				if timed_out or not await_ok then break end
			end

			-- Read until we have complete headers (\r\n\r\n).
			local parts = {} --: { [integer]: string }
			local total = 0
			local header_end
			while not header_end do
				local s = client_:receive(buf)
				if not s then keep_alive = false; break end
				parts[#parts + 1] = s
				total = total + #s
				if total > max_header_size then client_:send(err_res); keep_alive = false; break end
				local combined = table.concat(parts)
				header_end = combined:find("\r\n\r\n", 1, true)
				if header_end then parts = { combined } end
			end
			if not keep_alive or not header_end then break end

			local data = parts[1]
			if not data then break end
			local req, i = http.parse_request(data)
			if not req or not i then client_:send(err_res); break end

			-- Read remaining body if Content-Length specified.
			local content_length = (req --[[: http_request]]).headers["content-length"]
			if content_length then
				content_length = tonumber(content_length[1])
				if content_length then
					local body_start = header_end + 4
					local body_so_far = #data - body_start + 1
					while body_so_far < content_length do
						local s = client_:receive(buf)
						if not s then keep_alive = false; break end
						parts[#parts + 1] = s
						body_so_far = body_so_far + #s
					end
					if not keep_alive then break end
					if #parts > 1 then
						data = table.concat(parts)
						req = http.parse_request(data)
						if not req then client_:send(err_res); break end
					end
				end
			end

			-- Determine keep-alive from request headers.
			local req_ = req --[[: http_request]]
			local connection_hdr = req_.headers["connection"]
			local conn_val = connection_hdr and connection_hdr[1] or ""
			keep_alive = should_keep_alive(req_.version, conn_val)

			-- WebSocket upgrade detection (RFC 6455 §4.2.1).
			local upgrade_val = req_.headers["upgrade"]
			if upgrade_val and upgrade_val[1] and upgrade_val[1]:lower() == "websocket" then
				if not ws_handler_fn then
					client_:send(http.serialize_response({
						status = 426, reason = "Upgrade Required", version = "HTTP/1.1",
						headers = { ["upgrade"] = { "websocket" } }, body = nil,
					}))
					client_:close()
					return
				end
				if ws_accept_fn then
					local accepted, reject_reason = ws_accept_fn(req_)
					if not accepted then
						local body = reject_reason or "WebSocket upgrade rejected"
						client_:send(http.serialize_response({
							status = 403, reason = "Forbidden", version = "HTTP/1.1",
							headers = { ["content-length"] = { tostring(#body) } }, body = body,
						}))
						client_:close()
						return
					end
				end
				local client_key, verr = ws_validate_upgrade(req_)
				if not client_key then
					local body = verr or "Bad WebSocket request"
					client_:send(http.serialize_response({
						status = 400, reason = "Bad Request", version = "HTTP/1.1",
						headers = { ["content-length"] = { tostring(#body) } }, body = body,
					}))
					client_:close()
					return
				end
				local accept_value = base64_encode(sha1_binary(client_key .. WS_GUID))
				client_:send(
					"HTTP/1.1 101 Switching Protocols\r\n"
					.. "Upgrade: websocket\r\n"
					.. "Connection: Upgrade\r\n"
					.. "Sec-WebSocket-Accept: " .. accept_value .. "\r\n"
					.. "\r\n"
				)
				local ws_conn = make_ws_conn(client_, buf)
				ws_handler_fn(ws_conn, req_)
				ws_conn:close()
				client_:close()
				return
			end

			-- Normal HTTP request handling.
			local res = { status = 200, reason = "", version = "HTTP/1.1", headers = {}, body = nil, raw = nil } --: http_server_response
			if not http_handler then
				res.status = 404
				res.reason = "Not Found"
			else
				http_handler(req_, res, client_)
			end

			if res.raw then
				-- Handler took ownership of the socket (SSE, websocket, etc.).
				return
			end

			-- Add Connection header to response.
			if keep_alive then
				res.headers["connection"] = { "keep-alive" }
			else
				res.headers["connection"] = { "close" }
			end

			client_:send(http.serialize_response(res))
		end

		client_:close()
	end
end

-- Public API: accepts a plain handler function (backward compat, HTTP only)
-- or a handler table { http?, ws_accept?, ws? }. Normalizes into separate
-- components and delegates to make_handler_core.
mod.make_connection_handler = function(handler, ka_opts)
	if type(handler) == "function" then
		return make_handler_core(handler, nil, nil, ka_opts)
	end
	return make_handler_core(handler.http, handler.ws_accept, handler.ws, ka_opts)
end

-- Wrap an accepted client socket with TLS server-side hooks.
-- tls_ctx is the listening tls_server() context (already configured).
-- Returns true on success, or (nil, errmsg) on failure.
-- After this call, client.on_send and client.on_receive are set to go
-- through the per-connection TLS context.
--: (cdata, http_client_sock) -> (boolean | nil, string | nil)
local function wrap_client_tls(tls_ctx, client)
	local t = get_tls()
	if not t then return nil, "libtls unavailable" end
	local cctx_ptr = t.tls_c_ptr()
	local rc = t.accept_socket(tls_ctx, cctx_ptr, client.fd)
	if rc < 0 then
		return nil, ffi.string(t.error(tls_ctx))
	end
	local cctx = cctx_ptr[0]

	-- Perform the TLS handshake eagerly so errors are visible before the
	-- connection handler tries to read. libtls returns TLS_WANT_POLLIN/OUT
	-- for non-blocking; since the server socket is blocking at this point
	-- we loop until done.
	--: integer
	local TLS_WANT_POLLIN = -2
	--: integer
	local TLS_WANT_POLLOUT = -3
	local hs_rc = t.handshake(cctx)
	while hs_rc == TLS_WANT_POLLIN or hs_rc == TLS_WANT_POLLOUT do
		hs_rc = t.handshake(cctx)
	end
	if hs_rc < 0 then
		t.free(cctx)
		return nil, ffi.string(t.error(cctx))
	end

	-- Override send/receive on the client socket to go through TLS.
	local clientm_ = client --[[: unknown]]
	clientm_.on_send = function(self, data, flags)
		local len = t.write(cctx, data, #data)
		if len < 0 then return nil, ffi.string(t.error(cctx)) end
		return len
	end
	clientm_.on_receive = function(self, buffer, max_size, flags)
		-- max_size may be a cdata buffer (passed through from receive(cdata)) or
		-- an integer. Use ffi.sizeof when it is cdata.
		local sz = type(max_size) == "cdata" and ffi.sizeof(max_size) or max_size
		local len = t.read(cctx, buffer, sz)
		if len < 0 then return nil, ffi.string(t.error(cctx)) end
		return ffi.string(buffer, len)
	end

	-- Extend client:close() to also close the TLS context.
	local orig_close = client.close
	clientm_.close = function(self)
		t.close(cctx)
		t.free(cctx)
		return orig_close(self)
	end

	return true
end

-- opts.host (optional): interface to bind, e.g. "127.0.0.1" or "0.0.0.0".
-- Forwarded to lib.socket.server, which defaults to "*" (all interfaces) if
-- omitted. Prefer loopback-only binds for daemons on untrusted networks.
-- opts.tls_cert / opts.tls_key (optional): paths to PEM cert and key files.
-- When both are set and libtls is available, accepted connections are wrapped
-- in TLS. If libtls is unavailable a warning is printed and the server falls
-- back to plaintext — it does not hard-fail.
-- opts.idle_timeout (optional): ms idle between keep-alive requests (default 60000).
-- opts.max_requests (optional): max requests per connection (default 0 = no limit).
--: (HttpHandlerFn, integer | nil, unknown | nil, { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil } | nil) -> unknown
mod.server = function(handler, port, epoll, opts)
	local opts_ = opts or { host = nil, tls_cert = nil, tls_key = nil, idle_timeout = nil, max_requests = nil } --: { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil }
	local tls_ctx --: cdata | nil

	local tls_cert = opts_.tls_cert
	local tls_key = opts_.tls_key
	if tls_cert and tls_key then
		local t = get_tls()
		if not t then
			io.stderr:write("lib/http/server: WARNING: tls_cert/tls_key set but libtls unavailable — falling back to plaintext\n")
		else
			local cfg = t.config_new()
			local rc = t.config_set_keypair_file(cfg, tls_cert, tls_key)
			if rc < 0 then
				io.stderr:write("lib/http/server: WARNING: tls_config_set_keypair_file failed: "
					.. ffi.string(t.config_error(cfg)) .. " — falling back to plaintext\n")
				t.config_free(cfg)
			else
				tls_ctx = t.server()
				rc = t.configure(tls_ctx, cfg)
				t.config_free(cfg)
				if rc < 0 then
					io.stderr:write("lib/http/server: WARNING: tls_configure failed: "
						.. ffi.string(t.error(tls_ctx)) .. " — falling back to plaintext\n")
					t.free(tls_ctx)
					tls_ctx = nil
				end
			end
		end
	end

	-- When TLS is active, inject an on_client hook that wraps each accepted
	-- connection before the HTTP handler sees it.
	local server_opts = { host = opts_.host }
	if tls_ctx then
		local tls_ctx_ = tls_ctx
		server_opts.on_client = function(client)
			local ok, err = wrap_client_tls(tls_ctx_, client)
			if not ok then
				io.stderr:write("lib/http/server: TLS accept failed: " .. tostring(err) .. "\n")
				client:close()
			end
		end
	end

	local ka_opts = { idle_timeout = opts_.idle_timeout, max_requests = opts_.max_requests }
	return socket.server(mod.make_connection_handler(handler, ka_opts), port or 80, epoll, server_opts)
end

-- Test-only exports.
mod._ws_validate_upgrade = ws_validate_upgrade
mod._ws_frame_byte_count = ws_frame_byte_count
mod._make_ws_conn = make_ws_conn
mod._WS_GUID = WS_GUID

return mod
