local ffi = require("ffi")
local socket = require("lib.ljsocket")
local tls = require("lib.tls")
local format = require("lib.http.format")

--:: http_request = { method: string, host: string, port?: number, path: string, version?: string, headers?: { [string]: { string } }, body?: string }
--:: http_response = { version: number, status: number, status_text: string, headers: { [string]: { string } }, body: string }

local M = {}

--[[TODO: module-level TLS state limits to one concurrent connection — acceptable for now]]

local function make_tls_hooks(client_tls, client)
	client.on_connect = function(self, host, service)
		if tls.connect_socket(client_tls, self.fd, host) < 0 then
			return nil, ffi.string(tls.error(client_tls) --[[: unknown]])
		end
		if tls.handshake(client_tls) < 0 then
			return nil, ffi.string(tls.error(client_tls) --[[: unknown]])
		end
		return true
	end

	client.on_send = function(self, data, flags)
		local len = tls.write(client_tls, data, #data)
		if len < 0 then return nil, ffi.string(tls.error(client_tls) --[[: unknown]]) end
		return len
	end

	client.on_receive = function(self, buffer, max_size, flags)
		local len = tls.read(client_tls, buffer, max_size)
		if len < 0 then return nil, ffi.string(tls.error(client_tls) --[[: unknown]]) end
		return ffi.string(buffer, len)
	end
end

local function tls_setup()
	local client_tls = tls.client()
	local tls_config = tls.config_new()
	tls.configure(client_tls, tls_config)
	return client_tls, tls_config
end

local function tls_teardown(client_tls, tls_config)
	tls.free(client_tls)
	tls.config_free(tls_config)
end

--: (req: http_request) -> nil
local function add_default_headers(req)
	local headers = req.headers or {}
	req.headers = headers
	if not headers["Host"] then headers["Host"] = { req.host } end
	if not headers["User-Agent"] then
		headers["User-Agent"] = { "crescent/0.1" }
	end
	local body = req.body
	if type(body) == "string" then
		local body_str = body --: string
		if #body_str > 0 and not headers["Content-Length"] then
			headers["Content-Length"] = { tostring(#body_str) }
		end
	end
end

-- Send an HTTPS request and return the full response.
-- Returns (nil, errmsg) on any failure.
--: (http_request) -> (http_response | nil, string | nil)
M.request = function(req)
	req.body = req.body or ""
	local client_, err = socket.create("inet", "stream", "tcp")
	if not client_ then return nil, err end
	local client = client_ --[[: unknown]]

	local client_tls, tls_config = tls_setup()
	make_tls_hooks(client_tls, client)

	local ok
	ok, err = client:connect(req.host, "https")
	if not ok then
		tls_teardown(client_tls, tls_config)
		return nil, err
	end

	add_default_headers(req)

	ok, err = client:send(format.serialize_request({ method = req.method, target = req.path or "/", version = req.version or "HTTP/1.1", headers = req.headers, body = req.body }))
	if not ok then
		tls_teardown(client_tls, tls_config)
		client:close()
		return nil, err
	end

	-- read response headers
	local parts = {} --: { [integer]: string }
	local header_end
	while not header_end do
		local s
		s, err = client:receive()
		if not s then
			tls_teardown(client_tls, tls_config)
			client:close()
			return nil, err or "connection closed"
		end
		parts[#parts + 1] = s
		local combined = table.concat(parts)
		header_end = combined:find("\r\n\r\n", 1, true)
		if header_end then parts = { combined } end
	end

	local data = parts[1] --[[:! string]]
	local res, _, parse_err = (format.parse_response --[[:! (s: string, i: integer | nil) -> (any, integer | nil, string | nil)]])(data)
	if not res then
		tls_teardown(client_tls, tls_config)
		client:close()
		return nil, parse_err or "failed to parse response"
	end

	-- read remaining body if Content-Length specified
	local cl_header = res.headers["content-length"]
	if cl_header then
		local content_length = tonumber(cl_header[1]) or 0
		if content_length > 0 then
			local body_start = header_end + 4
			local body_so_far = #data - body_start
			while body_so_far < content_length do
				local s
				s, err = client:receive()
				if not s then break end
				parts[#parts + 1] = s
				body_so_far = body_so_far + #s
			end
			if #parts > 1 then
				data = table.concat(parts)
				res = (format.parse_response --[[:! (s: string, i: integer | nil) -> (any, integer | nil, string | nil)]])(data)
			end
		end
	end

	tls.close(client_tls)
	tls_teardown(client_tls, tls_config)
	client:close()

	return res
end

-- Send an HTTPS request and return streaming read/close functions.
-- On success: returns (recv_fn, close_fn).
--   recv_fn() -> string?, string? — yields chunks; nil signals end or error.
--   close_fn() -> nil             — releases TLS and socket resources.
-- On failure: returns (nil, errmsg).
--: (req: http_request) -> ((() -> (string | nil, string | nil)) | nil, (() -> nil) | string | nil)
M.stream = function(req)
	req.body = req.body or ""
	local client_, err = socket.create("inet", "stream", "tcp")
	if not client_ then return nil, err end
	local client = client_ --[[: unknown]]

	local client_tls, tls_config = tls_setup()
	make_tls_hooks(client_tls, client)

	local ok
	ok, err = client:connect(req.host, "https")
	if not ok then
		tls_teardown(client_tls, tls_config)
		return nil, err
	end

	add_default_headers(req)

	ok, err = client:send(format.serialize_request({ method = req.method, target = req.path or "/", version = req.version or "HTTP/1.1", headers = req.headers, body = req.body }))
	if not ok then
		tls_teardown(client_tls, tls_config)
		client:close()
		return nil, err
	end

	local closed = false

	local recv_fn = function()
		if closed then return nil end
		local s, recv_err = client:receive()
		if not s then return nil, recv_err end
		return s
	end

	local close_fn = function()
		if closed then return end
		closed = true
		tls.close(client_tls)
		tls_teardown(client_tls, tls_config)
		client:close()
	end

	return recv_fn, close_fn
end

return M
