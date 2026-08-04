local socket = require("lib.socket.server")
local http = require("lib.http.format")
local async = require("lib.async")

local mod = {}

--:: http_request = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil }
--:: http_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil }

-- What the server itself knows about the connection it is answering on.
-- RFC 9112 §3.3 (Reconstructing the Target URI) is the authority for these.
-- There is no X-Forwarded-* handling here and none should be added at this
-- layer: a reverse proxy's claims are a separate, trust-gated input.
--:: http_origin = { scheme: string, host: string | nil, port: integer | nil }

-- The request as delivered to a handler: the parsed message plus the origin
-- fields the wire codec cannot know.
--   scheme — "https" when this connection is TLS-wrapped, else "http"
--            (RFC 9112 §3.3: scheme is https if the connection is secured).
--   host   — the RFC 9112 §3.3 authority: the Host field value when non-empty
--            (verbatim, so it retains any ":port" the client sent), otherwise
--            the server's configured host name (opts.host). nil means neither
--            exists — the server genuinely has no configured host name, and a
--            caller must not fabricate one. Note opts.host is a *bind*
--            address, so an operator who binds a wildcard ("0.0.0.0", "*")
--            gets that value back here; it is reported verbatim rather than
--            filtered, because any filter list would be invented.
--   port   — the port this server is bound to (not any port in the Host
--            field, which is part of `host` above).
--:: http_server_request = { method: string, target: string, version: string, headers: { [string]: string[] }, body: string | nil, scheme: string, host: string | nil, port: integer | nil }

-- raw        — handler has taken ownership of the socket; the core neither
--              serializes nor closes. Set by mod.response_stream, and by
--              protocol-upgrade handlers (lib/http/server_ws) directly.
-- keep_alive — per-response override of the connection-reuse decision the
--              core derives from the request. false pins this connection to
--              a single response (`connection: close`, then close) even when
--              the request would have permitted reuse. nil leaves the derived
--              decision in place. The server-wide equivalents are
--              opts.max_requests and opts.idle_timeout.
--:: http_server_response = { status: integer, reason: string, version: string, headers: { [string]: string[] }, body: string | nil, raw: boolean | nil, keep_alive: boolean | nil }

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

-- What this server requires of an accepted client socket, not the whole of
-- what one is — hence the `...`: lib/socket/server declares its client the
-- same way, and real clients (LjSocket instances) carry more members than
-- this. set_option mirrors LjSocket's member of the same name, so a handler
-- that needs socket-level options (TCP_NODELAY on a stream, keepalive) can
-- reach it without casting past this declaration.
--:: http_client_sock = { receive: (self: http_client_sock, unknown) -> string | nil, send: (self: http_client_sock, string) -> unknown, close: (self: http_client_sock) -> unknown, set_option: (self: http_client_sock, string, unknown, string | nil) -> (boolean | nil, string | nil), fd: integer, on_send: unknown, on_receive: unknown, _loop: unknown, ... }
--:: HttpHandlerFn = (req: http_server_request, res: http_server_response, sock: http_client_sock) -> (boolean | nil)
--:: HttpKeepAliveOpts = { idle_timeout: number | nil, max_requests: integer | nil }

-- NOTE: cross-module named types are not yet supported; AsyncLoop is the
-- structural subset of lib/async LoopObj used here. AsyncPromiseLike mirrors
-- just enough of lib/async's PromiseP (and_then) for the idle-timeout race.
--:: AsyncPromiseLike = { and_then: (self: AsyncPromiseLike, (unknown) -> unknown) -> AsyncPromiseLike, ... }
--:: AsyncLoop = { await_readable: (self: AsyncLoop, integer) -> (AsyncPromiseLike | nil, string | nil, (() -> nil) | nil), sleep: (self: AsyncLoop, number) -> AsyncPromiseLike, step: (self: AsyncLoop) -> nil, ... }

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

-- Connection handler factory. Takes an HTTP handler, keep-alive options, and
-- the connection origin (scheme/host/port) the server knows about itself.
-- origin is optional: callers that bind their own listener and know nothing
-- about it get scheme "http" and no host/port.
--: (HttpHandlerFn | nil, HttpKeepAliveOpts | nil, http_origin | nil) -> (http_client_sock) -> nil
local function make_handler_core(http_handler, ka_opts, origin)
	local ka = ka_opts or {}
	local idle_timeout_ms = ka.idle_timeout or 60000
	local max_requests = ka.max_requests or 0
	local org = origin or { scheme = "http", host = nil, port = nil } --: http_origin
	local origin_scheme = org.scheme
	local origin_host = org.host
	local origin_port = org.port

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
				local timer = loop:sleep(idle_timeout_ms)

				-- Race the readable notification against the idle timer via
				-- async.race, recording which one settled *first* in `winner`.
				-- Each subscription below is registered before async.race's own
				-- internal subscriptions, so `winner` reflects true settle order
				-- even if the loser (e.g. the timer coincidentally expiring the
				-- same tick as a successful read) still fires its callback
				-- afterward — the `if not winner` guard makes that late firing a
				-- no-op instead of, as before, unconditionally treating it as a
				-- timeout and closing a connection that had just been read
				-- successfully.
				local winner --: string | nil
				p:and_then(function(v)
					if not winner then winner = "readable" end
					return v
				end)
				timer:and_then(function(v)
					if not winner then
						winner = "timeout"
						if cancel then cancel() end
					end
					return v
				end)

				local raced = async.race({ p, timer })
				local await_ok = pcall(async.await, raced)
				if not await_ok or winner == "timeout" then break end
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

			-- RFC 9112 §3.3 — reconstruct the authority the handler should see.
			-- The Host field wins when non-empty; otherwise the server's own
			-- configured host name. See http_server_request for why nil is a
			-- legitimate outcome rather than a fabricated placeholder.
			local host_hdr = req_.headers["host"]
			local host_val = host_hdr and host_hdr[1]
			if host_val == "" then host_val = nil end

			local sreq = {
				method = req_.method,
				target = req_.target,
				version = req_.version,
				headers = req_.headers,
				body = req_.body,
				scheme = origin_scheme,
				host = host_val or origin_host,
				port = origin_port,
			} --: http_server_request

			-- HTTP request handling.
			local res = { status = 200, reason = "", version = "HTTP/1.1", headers = {}, body = nil, raw = nil, keep_alive = nil } --: http_server_response
			if not http_handler then
				res.status = 404
				res.reason = "Not Found"
			else
				http_handler(sreq, res, client_)
			end

			if res.raw then
				-- Handler took ownership of the socket: an incremental response
				-- in flight (mod.response_stream) or a protocol upgrade. Neither
				-- serialize nor close — the handler owns both from here.
				return
			end

			-- A handler may pin this connection to a single response even when
			-- the request permitted reuse (opts.max_requests is the server-wide
			-- equivalent; this is the per-response one).
			if res.keep_alive == false then keep_alive = false end

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

-- Public API: accepts an HTTP handler function, optional keep-alive options,
-- and the optional connection origin (see http_origin).
--: (HttpHandlerFn, HttpKeepAliveOpts | nil, http_origin | nil) -> (http_client_sock) -> nil
mod.make_connection_handler = function(handler, ka_opts, origin)
	return make_handler_core(handler, ka_opts, origin)
end

--:: http_response_stream = { send_head: (self: http_response_stream) -> (boolean | nil, string | nil), write: (self: http_response_stream, string) -> (boolean | nil, string | nil), close: (self: http_response_stream) -> nil, is_open: (self: http_response_stream) -> boolean }

-- Take ownership of `sock` for an incremental (streamed) response: send the
-- head once, then write body bytes over time, then close. This is the
-- supported alternative to buffering a whole body into res.body, and it
-- removes the need for a caller to re-implement the connection loop just to
-- keep a socket open (SSE, long-poll, progressive rendering).
--
-- Calling this marks res.raw, so the connection core stops treating the
-- response as something it will serialize or close: from here the stream owns
-- both. Nothing is written until the first send_head/write call, so a handler
-- may create the stream and still decide to fail before any bytes go out.
--
-- Framing is the caller's to state. The head is serialized with
-- serialize_response_head, which synthesizes no content-length — see the note
-- there on RFC 9112 §6.1. A caller that knows its exact body length may set
-- `content-length` in res.headers itself; a caller that does not (SSE and
-- friends) sets none and ends the body by closing.
--: (http_server_response, http_client_sock) -> http_response_stream
mod.response_stream = function(res, sock)
	local res_ = res
	local sock_ = sock
	local head_sent = false
	local closed = false

	res_.raw = true

	local stream = {}

	-- Serialize and send the response head. Idempotent: the second and later
	-- calls succeed without writing. Returns (nil, err) once the peer is gone.
	--: (self: http_response_stream) -> (boolean | nil, string | nil)
	function stream:send_head()
		if closed then return nil, "stream closed" end
		if head_sent then return true end
		head_sent = true
		local ok, err = sock_:send(http.serialize_response_head(res_))
		if not ok then
			closed = true
			return nil, tostring(err or "client closed")
		end
		return true
	end

	-- Write body bytes. Sends the head first if it has not gone out yet, so a
	-- handler that only ever calls write still emits a well-formed response.
	--: (self: http_response_stream, string) -> (boolean | nil, string | nil)
	function stream:write(chunk)
		if closed then return nil, "stream closed" end
		if not head_sent then
			local ok_h, err_h = stream:send_head()
			if not ok_h then return nil, err_h end
		end
		local ok, err = sock_:send(chunk)
		if not ok then
			closed = true
			return nil, tostring(err or "client closed")
		end
		return true
	end

	-- End the response. Closing is what delimits a body with no declared
	-- length, so this is the normal termination, not only the error path.
	--: (self: http_response_stream) -> nil
	function stream:close()
		if closed then return end
		closed = true
		sock_:close()
	end

	--: (self: http_response_stream) -> boolean
	function stream:is_open()
		return not closed
	end

	return stream
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
--: (HttpHandlerFn, integer | nil, unknown | nil, { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil, loop: unknown | nil } | nil) -> unknown
mod.server = function(handler, port, epoll, opts)
	local opts_ = opts or { host = nil, tls_cert = nil, tls_key = nil, idle_timeout = nil, max_requests = nil, loop = nil } --: { host: string | nil, tls_cert: string | nil, tls_key: string | nil, idle_timeout: number | nil, max_requests: integer | nil, loop: unknown | nil }
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
	local server_opts = { host = opts_.host, loop = opts_.loop }
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
	-- The origin is what this server knows about itself: TLS actually got
	-- established (not merely requested — the blocks above fall back to
	-- plaintext on failure), the configured bind host, and the bound port.
	local bind_port = port or 80
	local origin = { scheme = tls_ctx and "https" or "http", host = opts_.host, port = bind_port } --: http_origin
	return socket.server(mod.make_connection_handler(handler, ka_opts, origin), bind_port, epoll, server_opts)
end

return mod
