-- lib/platform/caps/http_client.lua
-- http_client_cap(opts) -> cap_table, revoke_fn
-- Outbound HTTP requests scoped to a single whitelisted host.
--
-- opts.host  : required string (e.g. "api.openai.com:443", "localhost:11434")
-- opts.model : optional string (exposed as cap.model for LLM client config)
-- opts.path  : optional string (exposed as cap.path for LLM completions path)
-- opts.paths : optional array of strings — path whitelist. Absent/empty = all
--              paths allowed. Each entry matches exactly OR as a prefix when it
--              ends with "/". E.g. "/v1/" allows "/v1/chat/completions".
--
-- TLS: automatic when port is 443 (or when opts.tls = true), using libtls.
-- Falls back to plaintext when libtls is unavailable.
--
-- Capability API:
--   cap.request(req)                -> { status, headers, body } | nil, err
--   cap.request_stream(req, on_chunk) -> { status, headers } | nil, err

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local http   = require("lib.http.client")
local hfmt   = require("lib.http.format")
local socket = require("lib.ljsocket")
local ffi    = require("ffi")

local M = {}

-- ── TLS support via libtls (LibreSSL / OpenBSD) ──────────────────────────────

local tls_lib
do
	-- Try to load libtls: short name first (works when on LD_LIBRARY_PATH),
	-- then fall back to searching known Nix store paths for LibreSSL.
	local function try_load(name)
		local ok, lib = pcall(ffi.load, name)
		if not ok then return nil end
		-- Attempt to define the minimal API we need.
		-- pcall: cdef may error if symbols already declared (harmless).
		pcall(ffi.cdef, [[
			struct tls {};
			struct tls_config {};
			struct tls* tls_client();
			struct tls_config* tls_config_new();
			int  tls_configure(struct tls*, struct tls_config*);
			void tls_config_free(struct tls_config*);
			int  tls_connect(struct tls*, const char*, const char*);
			long tls_write(struct tls*, const void*, unsigned long);
			long tls_read(struct tls*, void*, unsigned long);
			int  tls_close(struct tls*);
			void tls_free(struct tls*);
			const char* tls_error(struct tls*);
			const char* tls_config_error(struct tls_config*);
		]])
		-- Verify the symbol exists.
		local ok2 = pcall(function() return lib.tls_client end)
		if not ok2 then return nil end
		return lib
	end

	tls_lib = try_load("tls")

	if not tls_lib then
		-- Search Nix store for LibreSSL libtls.so.
		local p = io.popen("find /nix/store -maxdepth 3 -name 'libtls.so' 2>/dev/null | grep libressl | head -1")
		if p then
			local path = p:read("*l")
			p:close()
			if path and path ~= "" then
				tls_lib = try_load(path)
			end
		end
	end
end

-- tls_connect_client(host, port_str) -> tls_ctx | nil, err
-- Creates a TLS client context and connects to host:port.
local function tls_make_client(host, port_str)
	if not tls_lib then return nil, "libtls not available" end
	local ctx = tls_lib.tls_client()
	if ctx == nil then return nil, "tls_client() failed" end
	local cfg = tls_lib.tls_config_new()
	if cfg == nil then tls_lib.tls_free(ctx); return nil, "tls_config_new() failed" end
	local rc = tls_lib.tls_configure(ctx, cfg)
	tls_lib.tls_config_free(cfg)
	if rc ~= 0 then
		local e = tls_lib.tls_error(ctx)
		tls_lib.tls_free(ctx)
		return nil, "tls_configure failed: " .. (e ~= nil and ffi.string(e) or "unknown")
	end
	rc = tls_lib.tls_connect(ctx, host, port_str)
	if rc ~= 0 then
		local e = tls_lib.tls_error(ctx)
		tls_lib.tls_free(ctx)
		return nil, "tls_connect failed: " .. (e ~= nil and ffi.string(e) or "unknown")
	end
	return ctx
end

-- tls_write_all(ctx, data) -> true | nil, err
local function tls_write_all(ctx, data)
	local pos = 1
	local len = #data
	while pos <= len do
		local n = tls_lib.tls_write(ctx, data:sub(pos), len - pos + 1)
		if n < 0 then
			local e = tls_lib.tls_error(ctx)
			return nil, "tls_write failed: " .. (e ~= nil and ffi.string(e) or "unknown")
		end
		pos = pos + tonumber(n)
	end
	return true
end

-- tls_read_response(ctx) -> raw_response_string | nil, err
-- Reads a complete HTTP response from a TLS connection.
-- Stops after the full body is received (using Content-Length or chunked TE).
-- This avoids blocking forever on keep-alive connections.
local function tls_read_response(ctx)
	local BUF_SIZE = 16384
	local buf = ffi.new("uint8_t[?]", BUF_SIZE)
	local data = ""

	-- Phase 1: read until headers complete (\r\n\r\n).
	local head_end
	while not head_end do
		local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
		if n == 0 then break end
		if n < 0 then
			if n == -2 or n == -3 then
				-- TLS_WANT_POLLIN/POLLOUT: retry (blocking mode shouldn't hit this)
			else
				local e = tls_lib.tls_error(ctx)
				return nil, "tls_read failed: " .. (e ~= nil and ffi.string(e) or "n=" .. tostring(n))
			end
		else
			data = data .. ffi.string(buf, n)
			head_end = data:find("\r\n\r\n", 1, true)
		end
	end
	if not head_end then return data end  -- return what we have on EOF

	local body_start = head_end + 4

	-- Parse Content-Length and Transfer-Encoding from raw headers.
	local header_block = data:sub(1, head_end - 1)
	local content_length = header_block:lower():match("content%-length:%s*(%d+)")
	local is_chunked = header_block:lower():find("transfer%-encoding:%s*chunked") ~= nil
	local is_close = header_block:lower():find("connection:%s*close") ~= nil

	if content_length then
		local cl = tonumber(content_length)
		-- Read until we have all body bytes.
		while #data - body_start + 1 < cl do
			local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
			if n == 0 then break end
			if n > 0 then data = data .. ffi.string(buf, n) end
		end
		return data

	elseif is_chunked then
		-- Read until the terminal "0\r\n\r\n" chunk.
		while not data:find("0\r\n\r\n", body_start, true) do
			local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
			if n == 0 then break end
			if n > 0 then data = data .. ffi.string(buf, n) end
		end
		return data

	elseif is_close then
		-- Server will close after response.
		while true do
			local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
			if n == 0 then break end
			if n > 0 then data = data .. ffi.string(buf, n) end
		end
		return data

	else
		-- No sizing info; read what's available then return.
		-- This handles responses without body (e.g. 204 No Content).
		return data
	end
end

-- tls_read_streaming(ctx, on_chunk, body_start, initial_data) -> true | nil, err
-- Reads remaining body chunks after headers are parsed, calling on_chunk for each.
local function tls_read_body_streaming(ctx, on_chunk, body_start_offset, initial_data, resp_headers)
	local BUF_SIZE = 16384
	local buf = ffi.new("uint8_t[?]", BUF_SIZE)

	-- Determine stop condition from headers.
	local te = resp_headers and resp_headers["transfer-encoding"]
	local cl = resp_headers and resp_headers["content-length"]
	local content_length = cl and tonumber(cl[1])
	local is_chunked = te and te[1] and te[1]:lower():find("chunked", 1, true)

	-- Continue reading body.
	local body_received = #initial_data - body_start_offset + 1
	if body_received < 0 then body_received = 0 end

	while true do
		-- Check stop conditions.
		if content_length and body_received >= content_length then break end

		local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
		if n == 0 then break end
		if n < 0 then
			if n == -2 or n == -3 then
				-- retry
			else break end
		else
			local chunk = ffi.string(buf, n)
			on_chunk(chunk)
			body_received = body_received + n
		end
	end
	return true
end

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- Parse "host:port" -> host, port_string. Default port 80.
--: (string) -> string, string
local function parse_host_port(s)
	local h, p = s:match("^(.+):(%d+)$")
	if h then return h, p end
	return s, "80"
end

-- normalize_headers(raw, allowed_host, body) -> headers_table
local function normalize_headers(raw, allowed_host, body)
	local headers = {}
	if raw then
		for k, v in pairs(raw) do
			if type(v) == "string" then
				headers[k] = { v }
			else
				headers[k] = v
			end
		end
	end
	if not headers["Host"] then
		headers["Host"] = { allowed_host }
	end
	if body and not headers["Content-Length"] then
		headers["Content-Length"] = { tostring(#body) }
	end
	return headers
end

-- decode_chunked(data) -> decoded_body | nil, err
-- Decodes HTTP/1.1 chunked transfer encoding.
-- Input: raw body bytes with chunk-size\r\nchunk-data\r\n... terminating with 0\r\n\r\n
--: (string) -> string | nil, string | nil
local function decode_chunked(data)
	local parts = {}
	local pos = 1
	while pos <= #data do
		-- Find end of chunk-size line.
		local nl = data:find("\r\n", pos, true)
		if not nl then break end
		local size_str = data:sub(pos, nl - 1)
		-- Strip any chunk extensions (e.g. "a2;ext=val" -> "a2")
		size_str = size_str:match("^([%x]+)")
		if not size_str then break end
		local size = tonumber(size_str, 16)
		if not size then break end
		if size == 0 then break end  -- last chunk
		pos = nl + 2
		if pos + size - 1 > #data then
			return nil, "chunked: truncated chunk"
		end
		parts[#parts + 1] = data:sub(pos, pos + size - 1)
		pos = pos + size + 2  -- skip chunk data + \r\n
	end
	return table.concat(parts)
end

-- post_process_response(parsed) -> parsed (in-place body decode)
-- Decodes chunked body if Transfer-Encoding: chunked is set.
local function post_process_response(parsed)
	if not parsed then return parsed end
	local te = parsed.headers and parsed.headers["transfer-encoding"]
	if te and te[1] and te[1]:lower():find("chunked", 1, true) then
		if parsed.body then
			local decoded = decode_chunked(parsed.body)
			if decoded then parsed.body = decoded end
		end
	end
	return parsed
end

-- ── Path and method whitelists ────────────────────────────────────────────────

-- path_allowed(paths, req_path) -> boolean
-- Returns true when req_path is permitted by the whitelist.
-- paths: nil/empty = allow all; otherwise exact match OR prefix match when
-- the whitelist entry ends with "/".
--: (table | nil, string) -> boolean
local function path_allowed(paths, req_path)
	if not paths or #paths == 0 then return true end
	for i = 1, #paths do
		local p = paths[i]
		if req_path == p then return true end
		-- prefix match: whitelist entry must end with "/"
		if p:sub(-1) == "/" and req_path:sub(1, #p) == p then return true end
	end
	return false
end

-- method_allowed(methods, req_method) -> boolean
-- Returns true when req_method is permitted by the whitelist.
-- methods: nil/empty = allow all; otherwise exact case-insensitive match.
--: (any | nil, string) -> boolean
local function method_allowed(methods, req_method)
	if not methods or #methods == 0 then return true end
	local m = req_method:upper()
	for i = 1, #methods do
		if tostring(methods[i]):upper() == m then return true end
	end
	return false
end

-- paths_subset(new_paths, old_paths) -> boolean
-- Returns true when every path in new_paths is allowed by old_paths.
-- old_paths nil/empty = unrestricted, any new_paths is valid.
--: (any | nil, any | nil) -> boolean
local function paths_subset(new_paths, old_paths)
	if not old_paths or #old_paths == 0 then return true end
	if not new_paths or #new_paths == 0 then return false end
	for i = 1, #new_paths do
		if not path_allowed(old_paths, new_paths[i]) then return false end
	end
	return true
end

-- methods_subset(new_methods, old_methods) -> boolean
-- Returns true when every method in new_methods is allowed by old_methods.
-- old_methods nil/empty = unrestricted, any new_methods is valid.
--: (any | nil, any | nil) -> boolean
local function methods_subset(new_methods, old_methods)
	if not old_methods or #old_methods == 0 then return true end
	if not new_methods or #new_methods == 0 then return false end
	for i = 1, #new_methods do
		if not method_allowed(old_methods, new_methods[i]) then return false end
	end
	return true
end

-- ── Cap factory ───────────────────────────────────────────────────────────────

-- http_client_cap(opts) -> cap_table, revoke_fn
function M.http_client_cap(opts)
	if not opts or not opts.host then
		error("http_client_cap: opts.host is required")
	end

	local allowed_host = opts.host
	local host, port = parse_host_port(allowed_host)
	local use_tls = (port == "443") or (opts.tls == true)
	local allowed_paths   = opts.paths    -- nil or array of strings
	local allowed_methods = opts.methods  -- nil or array of uppercase method strings
	local revoked = false

	local cap = {}

	-- Expose host and any extra opts fields for introspection.
	-- Server code (e.g. server.lua) may read cap.host for provider inference,
	-- and cap.model / cap.path for LLM client configuration.
	cap._type   = "http_client"
	cap.host    = allowed_host
	cap.model   = opts.model
	cap.path    = opts.path
	cap.methods = allowed_methods

	-- Non-streaming request.
	--: (table) -> table | nil, string
	function cap.request(req)
		if revoked then return nil, "capability revoked" end
		if not req then return nil, "http_client: missing request" end
		if not req.method then return nil, "http_client: missing method" end
		if not req.path then return nil, "http_client: missing path" end
		if not path_allowed(allowed_paths, req.path) then
			return nil, "path not allowed: " .. req.path
		end
		if not method_allowed(allowed_methods, req.method) then
			return nil, "method not allowed: " .. req.method
		end

		local headers = normalize_headers(req.headers, allowed_host, req.body)

		if use_tls then
			-- TLS path via libtls.
			local ctx, cerr = tls_make_client(host, port)
			if not ctx then return nil, "http_client: TLS connect failed: " .. tostring(cerr) end

			local request_bytes = hfmt.serialize_request({
				method  = req.method,
				target  = req.path,
				version = "HTTP/1.1",
				headers = headers,
				body    = req.body,
			})
			local ok, werr = tls_write_all(ctx, request_bytes)
			if not ok then
				tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
				return nil, "http_client: TLS write failed: " .. tostring(werr)
			end

			local resp_raw, rerr = tls_read_response(ctx)
			tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
			if not resp_raw then return nil, "http_client: TLS read failed: " .. tostring(rerr) end

			local parsed = post_process_response(hfmt.parse_response(resp_raw))
			if not parsed then return nil, "http_client: invalid HTTP response" end
			return { status = parsed.status, headers = parsed.headers, body = parsed.body }
		else
			-- Plain TCP path.
			local resp, err = http.send({
				host    = host,
				port    = port,
				method  = req.method,
				path    = req.path,
				headers = headers,
				body    = req.body,
			})
			if not resp then return nil, "http_client: request failed: " .. tostring(err) end

			local parsed = post_process_response(hfmt.parse_response(resp))
			if not parsed then return nil, "http_client: invalid HTTP response" end
			return { status = parsed.status, headers = parsed.headers, body = parsed.body }
		end
	end

	-- Streaming request. Calls on_chunk(data) for each received chunk.
	-- Returns { status, headers } on success (body delivered via callbacks).
	--: (table, (string) -> nil) -> table | nil, string
	function cap.request_stream(req, on_chunk)
		if revoked then return nil, "capability revoked" end
		if not req then return nil, "http_client: missing request" end
		if not req.method then return nil, "http_client: missing method" end
		if not req.path then return nil, "http_client: missing path" end
		if not on_chunk then return nil, "http_client: missing on_chunk callback" end
		if not path_allowed(allowed_paths, req.path) then
			return nil, "path not allowed: " .. req.path
		end
		if not method_allowed(allowed_methods, req.method) then
			return nil, "method not allowed: " .. req.method
		end

		local headers = normalize_headers(req.headers, allowed_host, req.body)

		if use_tls then
			-- TLS streaming path.
			local ctx, cerr = tls_make_client(host, port)
			if not ctx then return nil, "http_client: TLS connect failed: " .. tostring(cerr) end

			local request_bytes = hfmt.serialize_request({
				method  = req.method,
				target  = req.path,
				version = "HTTP/1.1",
				headers = headers,
				body    = req.body,
			})
			local ok, werr = tls_write_all(ctx, request_bytes)
			if not ok then
				tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
				return nil, "http_client: TLS write failed: " .. tostring(werr)
			end

			-- Read response with header/body split for streaming.
			local BUF_SIZE = 16384
			local buf = ffi.new("uint8_t[?]", BUF_SIZE)
			local head_buf = ""
			local status, resp_headers

			-- Read until we have complete headers.
			while not status do
				local n = tls_lib.tls_read(ctx, buf, BUF_SIZE)
				if n == 0 then
					tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
					return nil, "http_client: TLS closed before headers"
				end
				if n < 0 then
					if n == -2 or n == -3 then
						-- retry
					else
						tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
						local e = tls_lib.tls_error(ctx)
						return nil, "http_client: TLS read error: " .. (e ~= nil and ffi.string(e) or "n=" .. n)
					end
				else
					head_buf = head_buf .. ffi.string(buf, n)
					local head_end = head_buf:find("\r\n\r\n", 1, true)
					if head_end then
						-- Parse status.
						local line_end = head_buf:find("\r\n", 1, true)
						local status_line = head_buf:sub(1, line_end - 1)
						local sp1 = status_line:find(" ", 1, true)
						local sp2 = sp1 and status_line:find(" ", sp1 + 1, true)
						local status_str = sp2 and status_line:sub(sp1 + 1, sp2 - 1) or (sp1 and status_line:sub(sp1 + 1))
						status = tonumber(status_str) or 0

						local parsed = hfmt.parse_response(head_buf:sub(1, head_end + 3) .. "\r\n")
						resp_headers = parsed and parsed.headers or {}

						-- Deliver body data that arrived with headers.
						local body_start = head_end + 4
						if #head_buf >= body_start then
							local initial = head_buf:sub(body_start)
							if #initial > 0 then on_chunk(initial) end
						end
					end
				end
			end

			-- Stream remaining body.
			tls_read_body_streaming(ctx, on_chunk, body_start, head_buf, resp_headers)

			tls_lib.tls_close(ctx); tls_lib.tls_free(ctx)
			return { status = status, headers = resp_headers }
		else
			-- Plain TCP streaming path (original implementation).
			local client, err = socket.create("inet", "stream", "tcp")
			if not client then return nil, "http_client: socket failed: " .. tostring(err) end

			local ok
			ok, err = client:connect(host, port)
			if not ok then client:close(); return nil, "http_client: connect failed: " .. tostring(err) end

			local request_bytes = hfmt.serialize_request({
				method  = req.method,
				target  = req.path,
				version = "HTTP/1.1",
				headers = headers,
				body    = req.body,
			})
			ok, err = client:send(request_bytes)
			if not ok then client:close(); return nil, "http_client: send failed: " .. tostring(err) end

			-- Read until we have complete headers (terminated by \r\n\r\n)
			local data_buf = {}
			local head_end
			while true do
				if revoked then client:close(); return nil, "capability revoked" end
				local chunk = client:receive()
				if not chunk or #chunk == 0 then
					client:close()
					return nil, "http_client: connection closed before headers"
				end
				data_buf[#data_buf + 1] = chunk
				local data = table.concat(data_buf)
				head_end = data:find("\r\n\r\n", 1, true)
				if head_end then
					-- Parse status line and headers
					local line_end = data:find("\r\n", 1, true)
					if not line_end then client:close(); return nil, "http_client: malformed response" end
					local status_line = data:sub(1, line_end - 1)
					local sp1 = status_line:find(" ", 1, true)
					if not sp1 then client:close(); return nil, "http_client: malformed status line" end
					local sp2 = status_line:find(" ", sp1 + 1, true)
					local status_str = sp2 and status_line:sub(sp1 + 1, sp2 - 1) or status_line:sub(sp1 + 1)
					local status = tonumber(status_str)
					if not status then client:close(); return nil, "http_client: invalid status code" end

					-- Parse headers using format module on the full head
					local parsed = hfmt.parse_response(data:sub(1, head_end + 3) .. "\r\n")
					local resp_headers = parsed and parsed.headers or {}

					-- Deliver any body data that arrived with the headers
					local body_start = head_end + 4
					if #data > body_start - 1 then
						local initial_body = data:sub(body_start)
						if #initial_body > 0 then
							on_chunk(initial_body)
						end
					end

					-- Determine content-length if present
					local cl = resp_headers["content-length"]
					local content_length = cl and tonumber(cl[1])
					local body_received = #data - body_start + 1
					if body_received < 0 then body_received = 0 end

					-- Read remaining body
					while true do
						if revoked then client:close(); return nil, "capability revoked" end
						if content_length and body_received >= content_length then break end
						chunk = client:receive()
						if not chunk or #chunk == 0 then break end
						body_received = body_received + #chunk
						on_chunk(chunk)
					end

					client:close()
					return {
						status  = status,
						headers = resp_headers,
					}
				end
			end
		end
	end

	function cap.attenuate(sub_opts)
		if revoked then return nil, "http_client: capability revoked" end
		sub_opts = sub_opts or {}
		-- Host cannot change.
		if sub_opts.host and sub_opts.host ~= allowed_host then
			return nil, "http_client.attenuate: cannot change host"
		end
		-- Paths must be a subset of the current whitelist.
		local new_paths = sub_opts.paths
		if not paths_subset(new_paths, allowed_paths) then
			return nil, "http_client.attenuate: paths escape current scope"
		end
		-- Methods must be a subset of the current whitelist.
		local new_methods = sub_opts.methods
		if not methods_subset(new_methods, allowed_methods) then
			return nil, "http_client.attenuate: methods escape current scope"
		end
		return M.http_client_cap({
			host    = allowed_host,
			paths   = new_paths,
			methods = new_methods,
			model   = opts.model,
			path    = opts.path,
			tls     = opts.tls,
		})
	end

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
