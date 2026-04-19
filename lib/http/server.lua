local socket = require("lib.socket.server")
local http = require("lib.http.format")

local mod = {}

--[[@alias http_callback fun(req: http_request, res: http_response, sock: luajitsocket): boolean?]]

local ffi = require("ffi")
local buf = ffi.new("char[65536]")
local err_res = http.serialize_response({ status = 400, headers = {} })
local max_header_size = 65536

-- TLS support: loaded lazily so the server still works when libtls is absent.
-- tls_lib is the lib/tls module (or nil if unavailable).
local tls_lib --: unknown
local tls_loaded = false
local function get_tls()
	if not tls_loaded then
		tls_loaded = true
		local ok, t = pcall(require, "lib.tls")
		if ok then tls_lib = t end
	end
	return tls_lib
end

--[[@param handler http_callback]]
mod.make_connection_handler = function (handler)
	--[[@param client luajitsocket]]
	return function (client)
		local parts = {}
		local total = 0
		local header_end
		--[[read until we have complete headers (\r\n\r\n)]]
		while not header_end do
			local s = client:receive(buf)
			if not s then return end
			parts[#parts + 1] = s
			total = total + #s
			if total > max_header_size then client:send(err_res); return end
			local combined = table.concat(parts)
			header_end = combined:find("\r\n\r\n", 1, true)
			if header_end then parts = { combined } end
		end
		local data = parts[1]
		local req, i = http.parse_request(data)
		if not req or not i then client:send(err_res); return end
		--[[read remaining body if Content-Length specified]]
		local content_length = req.headers["content-length"]
		if content_length then
			content_length = tonumber(content_length[1])
			if content_length then
				local body_start = header_end + 4
				local body_so_far = #data - body_start + 1
				while body_so_far < content_length do
					local s = client:receive(buf)
					if not s then break end
					parts[#parts + 1] = s
					body_so_far = body_so_far + #s
				end
				if #parts > 1 then
					data = table.concat(parts)
					req = http.parse_request(data)
					if not req then client:send(err_res); return end
				end
			end
		end
		local res = { headers = {} } --[[@type http_response]]
		handler(req, res, client)
		if not res.raw then
			client:send(http.serialize_response(res))
			client:close()
		end
	end
end

-- Wrap an accepted client socket with TLS server-side hooks.
-- tls_ctx is the listening tls_server() context (already configured).
-- Returns true on success, or (nil, errmsg) on failure.
-- After this call, client.on_send and client.on_receive are set to go
-- through the per-connection TLS context.
--: (unknown, unknown) -> true | nil, string | nil
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
	client.on_send = function(self, data, flags)
		local len = t.write(cctx, data, #data)
		if len < 0 then return nil, ffi.string(t.error(cctx)) end
		return len
	end
	client.on_receive = function(self, buffer, max_size, flags)
		-- max_size may be a cdata buffer (passed through from receive(cdata)) or
		-- an integer. Use ffi.sizeof when it is cdata.
		local sz = type(max_size) == "cdata" and ffi.sizeof(max_size) or max_size
		local len = t.read(cctx, buffer, sz)
		if len < 0 then return nil, ffi.string(t.error(cctx)) end
		return ffi.string(buffer, len)
	end

	-- Extend client:close() to also close the TLS context.
	local orig_close = client.close
	client.close = function(self)
		t.close(cctx)
		t.free(cctx)
		return orig_close(self)
	end

	return true
end

--[[@return luajitsocket sock]]
--[[@param handler http_callback]] --[[@param port? integer]] --[[@param epoll? epoll]]
--[[@param opts? { host?: string, tls_cert?: string, tls_key?: string }]]
-- opts.host (optional): interface to bind, e.g. "127.0.0.1" or "0.0.0.0".
-- Forwarded to lib.socket.server, which defaults to "*" (all interfaces) if
-- omitted. Prefer loopback-only binds for daemons on untrusted networks.
-- opts.tls_cert / opts.tls_key (optional): paths to PEM cert and key files.
-- When both are set and libtls is available, accepted connections are wrapped
-- in TLS. If libtls is unavailable a warning is printed and the server falls
-- back to plaintext — it does not hard-fail.
mod.server = function (handler, port, epoll, opts)
	opts = opts or {}
	local tls_ctx --: unknown

	if opts.tls_cert and opts.tls_key then
		local t = get_tls()
		if not t then
			io.stderr:write("lib/http/server: WARNING: tls_cert/tls_key set but libtls unavailable — falling back to plaintext\n")
		else
			local cfg = t.config_new()
			local rc = t.config_set_keypair_file(cfg, opts.tls_cert, opts.tls_key)
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
				client:close()
			end
		end
	end

	return socket.server(mod.make_connection_handler(handler), port or 80, epoll, server_opts)
end

return mod
