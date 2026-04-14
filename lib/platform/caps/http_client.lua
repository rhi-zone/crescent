-- lib/platform/caps/http_client.lua
-- http_client_cap(opts) -> cap_table, revoke_fn
-- Outbound HTTP requests scoped to a single whitelisted host.
--
-- opts.host : required string (e.g. "api.openai.com", "localhost:11434")
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

local M = {}

-- Parse "host:port" -> host, port_string. Default port 80.
--: (string) -> string, string
local function parse_host_port(s)
	local h, p = s:match("^(.+):(%d+)$")
	if h then return h, p end
	return s, "80"
end

-- http_client_cap(opts) -> cap_table, revoke_fn
function M.http_client_cap(opts)
	if not opts or not opts.host then
		error("http_client_cap: opts.host is required")
	end

	local allowed_host = opts.host
	local host, port = parse_host_port(allowed_host)
	local revoked = false

	local cap = {}

	-- Non-streaming request.
	--: (table) -> table | nil, string
	function cap.request(req)
		if revoked then return nil, "capability revoked" end
		if not req then return nil, "http_client: missing request" end
		if not req.method then return nil, "http_client: missing method" end
		if not req.path then return nil, "http_client: missing path" end

		-- Normalize headers: convert {name = value} to {name = {value}} where needed
		local headers = {}
		if req.headers then
			for k, v in pairs(req.headers) do
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
		if req.body and not headers["Content-Length"] then
			headers["Content-Length"] = { tostring(#req.body) }
		end

		local resp, err = http.send({
			host    = host,
			port    = port,
			method  = req.method,
			path    = req.path,
			headers = headers,
			body    = req.body,
		})
		if not resp then return nil, "http_client: request failed: " .. tostring(err) end

		local parsed = hfmt.parse_response(resp)
		if not parsed then return nil, "http_client: invalid HTTP response" end

		return {
			status  = parsed.status,
			headers = parsed.headers,
			body    = parsed.body,
		}
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

		-- Normalize headers
		local headers = {}
		if req.headers then
			for k, v in pairs(req.headers) do
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
		if req.body and not headers["Content-Length"] then
			headers["Content-Length"] = { tostring(#req.body) }
		end

		-- Open socket directly for streaming
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
		local buf = {}
		local head_end
		while true do
			if revoked then client:close(); return nil, "capability revoked" end
			local chunk = client:receive()
			if not chunk or #chunk == 0 then
				client:close()
				return nil, "http_client: connection closed before headers"
			end
			buf[#buf + 1] = chunk
			local data = table.concat(buf)
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

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
