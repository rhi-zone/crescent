local socket = require("lib.socket.server")
local http = require("lib.http.format") --[[:! { parse_request: (string, integer | nil) -> (http_request | nil, integer | nil, string | nil), serialize_response: (http_response) -> string, parse_response: (string) -> unknown }]]

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
--:: TlsMod = { tls_c_ptr: () -> any, accept_socket: (any, any, integer) -> integer, error: (any) -> any, handshake: (any) -> integer, free: (any) -> nil, write: (any, any, integer) -> integer, read: (any, any, integer) -> integer, close: (any) -> nil, config_new: () -> any, config_set_keypair_file: (any, any, any) -> integer, config_error: (any) -> any, config_free: (any) -> nil, server: () -> any, configure: (any, any) -> integer }
local tls_lib --: TlsMod | nil
local tls_loaded = false
--: () -> TlsMod | nil
local function get_tls()
	if not tls_loaded then
		tls_loaded = true
		local ok, t = pcall(require, "lib.tls")
		if ok then tls_lib = (t --[[: unknown]]) --[[:! TlsMod]] end
	end
	return tls_lib
end

--:: http_client_sock = { receive: (self: http_client_sock, unknown) -> string | nil, send: (self: http_client_sock, string) -> unknown, close: (self: http_client_sock) -> unknown, fd: integer, on_send: unknown, on_receive: unknown }
--:: HttpHandlerFn = (req: http_request, res: http_server_response, sock: http_client_sock) -> (boolean | nil)

--: (HttpHandlerFn) -> (http_client_sock) -> nil
mod.make_connection_handler = function (handler)
	return function (client)
		local client_ = client --[[:! http_client_sock]]
		local parts = {}
		local total = 0
		local header_end
		--[[read until we have complete headers (\r\n\r\n)]]
		while not header_end do
			local s = client_:receive(buf)
			if not s then return end
			parts[#parts + 1] = s
			total = total + #s
			if total > max_header_size then client_:send(err_res); return end
			local combined = table.concat(parts)
			header_end = combined:find("\r\n\r\n", 1, true)
			if header_end then parts = { combined } end
		end
		local data = parts[1]
		local req, i = http.parse_request(data)
		if not req or not i then client_:send(err_res); return end
		--[[read remaining body if Content-Length specified]]
		local content_length = req.headers["content-length"]
		if content_length then
			content_length = tonumber(content_length[1])
			if content_length then
				local body_start = header_end + 4
				local body_so_far = #data - body_start + 1
				while body_so_far < content_length do
					local s = client_:receive(buf)
					if not s then break end
					parts[#parts + 1] = s
					body_so_far = body_so_far + #s
				end
				if #parts > 1 then
					data = table.concat(parts)
					req = http.parse_request(data)
					if not req then client_:send(err_res); return end
				end
			end
		end
		local res = { status = 200, reason = "", version = "HTTP/1.1", headers = {}, body = nil } --: http_response
		local res_any = res --[[: unknown]]
		handler(req --[[:! http_request]], res_any --[[:! http_server_response]], client_)
		if not res_any.raw then
			client_:send(http.serialize_response(res))
			client_:close()
		end
	end
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
	local client_ = client --[[:! { fd: integer, ... }]]
	local cctx_ptr = t.tls_c_ptr()
	local rc = t.accept_socket(tls_ctx, cctx_ptr, client_.fd)
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
	local clientm_ = client_ --[[: unknown]]
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
	local orig_close = clientm_.close
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
--: (HttpHandlerFn, integer | nil, unknown | nil, { host: string | nil, tls_cert: string | nil, tls_key: string | nil } | nil) -> unknown
mod.server = function (handler, port, epoll, opts)
	opts = opts or {} --[[:! { host: string | nil, tls_cert: string | nil, tls_key: string | nil }]]
	local tls_ctx --: cdata | nil

	if opts.tls_cert and opts.tls_key then
		local t = get_tls()
		if not t then
			io.stderr:write("lib/http/server: WARNING: tls_cert/tls_key set but libtls unavailable — falling back to plaintext\n")
		else
			local cfg = t.config_new()
			local tls_cert_ = opts.tls_cert --[[:! string]]
			local tls_key_ = opts.tls_key --[[:! string]]
			local rc = t.config_set_keypair_file(cfg, tls_cert_, tls_key_)
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
	local server_opts = { host = opts.host }
	if tls_ctx then
		server_opts.on_client = function(client)
			local ok, err = wrap_client_tls(tls_ctx, client)
			if not ok then
				io.stderr:write("lib/http/server: TLS accept failed: " .. tostring(err) .. "\n")
				local c_ = client --[[:! http_client_sock]]
				c_:close()
			end
		end
	end

	return socket.server(mod.make_connection_handler(handler), port or 80, epoll, server_opts)
end

return mod
