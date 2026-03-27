local ffi = require("ffi")
local socket = require("lib.ljsocket")
local tls = require("lib.tls")
local format = require("lib.http.format")

--:: http_client_request = { method: string, host: string, port?: number, path: string, headers: { [string]: string }, body: string }
--:: http_client_response = { version: number, status: number, status_text: string, headers: { [string]: string }, body: string }

local mod = {}

local buf = ffi.new("char[65536]")

--[[TODO: module-level TLS state limits to one concurrent connection — acceptable for now]]

--: (http_client_request) -> http_client_response?, string?
mod.request = function(req)
	req.body = req.body or ""
	local client, err = socket.create("inet", "stream", "tcp")
	if not client then return nil, err end

	local client_tls = tls.client()
	local tls_config = tls.config_new()
	tls.configure(client_tls, tls_config)

	client.on_connect = function(self, host, service)
		if tls.connect_socket(client_tls, self.fd, host) < 0 then
			return nil, ffi.string(tls.error(client_tls))
		end
		if tls.handshake(client_tls) < 0 then
			return nil, ffi.string(tls.error(client_tls))
		end
		return true
	end

	client.on_send = function(self, data, flags)
		local len = tls.write(client_tls, data, #data)
		if len < 0 then return nil, ffi.string(tls.error(client_tls)) end
		return len
	end

	client.on_receive = function(self, buffer, max_size, flags)
		local len = tls.read(client_tls, buffer, max_size)
		if len < 0 then return nil, ffi.string(tls.error(client_tls)) end
		return ffi.string(buffer, len)
	end

	local ok
	ok, err = client:connect(req.host, "https")
	if not ok then
		tls.free(client_tls)
		tls.config_free(tls_config)
		return nil, err
	end

	req.headers = req.headers or {}
	if not req.headers["User-Agent"] then
		req.headers["User-Agent"] = "crescent/0.1"
	end
	if req.body and #req.body > 0 and not req.headers["Content-Length"] then
		req.headers["Content-Length"] = tostring(#req.body)
	end

	ok, err = client:send(format.http_client_request_to_string(req))
	if not ok then
		tls.free(client_tls)
		tls.config_free(tls_config)
		client:close()
		return nil, err
	end

	-- read response headers
	--: string[]
	local parts = {}
	local total = 0
	local header_end
	while not header_end do
		local s
		s, err = client:receive()
		if not s then
			tls.free(client_tls)
			tls.config_free(tls_config)
			client:close()
			return nil, err or "connection closed"
		end
		parts[#parts + 1] = s
		total = total + #s
		local combined = table.concat(parts)
		header_end = combined:find("\r\n\r\n", 1, true)
		if header_end then parts = { combined } end
	end

	local data = parts[1]
	local res = format.string_to_http_client_response(data)
	if not res then
		tls.free(client_tls)
		tls.config_free(tls_config)
		client:close()
		return nil, "failed to parse response"
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
				res = format.string_to_http_client_response(data)
			end
		end
	end

	tls.close(client_tls)
	tls.free(client_tls)
	tls.config_free(tls_config)
	client:close()

	return res
end

--: (http_client_request) -> (() -> string?, string?)?, (() -> nil)? | nil, string?
mod.stream = function(req)
	req.body = req.body or ""
	local client, err = socket.create("inet", "stream", "tcp")
	if not client then return nil, err end

	local client_tls = tls.client()
	local tls_config = tls.config_new()
	tls.configure(client_tls, tls_config)

	client.on_connect = function(self, host, service)
		if tls.connect_socket(client_tls, self.fd, host) < 0 then
			return nil, ffi.string(tls.error(client_tls))
		end
		if tls.handshake(client_tls) < 0 then
			return nil, ffi.string(tls.error(client_tls))
		end
		return true
	end

	client.on_send = function(self, data, flags)
		local len = tls.write(client_tls, data, #data)
		if len < 0 then return nil, ffi.string(tls.error(client_tls)) end
		return len
	end

	client.on_receive = function(self, buffer, max_size, flags)
		local len = tls.read(client_tls, buffer, max_size)
		if len < 0 then return nil, ffi.string(tls.error(client_tls)) end
		return ffi.string(buffer, len)
	end

	local ok
	ok, err = client:connect(req.host, "https")
	if not ok then
		tls.free(client_tls)
		tls.config_free(tls_config)
		return nil, err
	end

	req.headers = req.headers or {}
	if not req.headers["User-Agent"] then
		req.headers["User-Agent"] = "crescent/0.1"
	end
	if req.body and #req.body > 0 and not req.headers["Content-Length"] then
		req.headers["Content-Length"] = tostring(#req.body)
	end

	ok, err = client:send(format.http_client_request_to_string(req))
	if not ok then
		tls.free(client_tls)
		tls.config_free(tls_config)
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
		tls.free(client_tls)
		tls.config_free(tls_config)
		client:close()
	end

	return recv_fn, close_fn
end

return mod
