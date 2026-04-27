-- lib/platform/caps/http_server.lua
-- http_server_cap(opts) -> cap_table, revoke_fn
-- Inbound HTTP server capability for sandboxed apps.
-- The platform owns the socket — the app provides a handler function.
--
-- Modes:
--   Standalone (default): the cap binds its own port. cap.serve(handler) blocks.
--     opts.port : integer (required) — port to bind
--     opts.host : string  (default "0.0.0.0") — bind address
--
--   Daemon: the cap does not bind; cap.serve(handler) records the handler and
--   returns immediately. The daemon invokes the handler per request through
--   its own listener. SSE streaming is not supported in daemon mode in v1.
--     opts.daemon   : true  (enables daemon mode)
--     opts.url      : string (optional) — advertised app URL for cap.url
--     opts.on_serve : (handler) -> nil (required) — daemon callback that
--                     captures the handler when the app calls cap.serve()
--
-- Capability API (both modes):
--   cap.serve(handler)  — register handler. handler(req, res) per request.
--                         Standalone: blocks, runs the socket loop.
--                         Daemon: returns immediately after registering.
--   cap.url             — string, e.g. "http://localhost:7860"
--   cap.port            — integer (0 in daemon mode)
--
-- req: { method, path, headers, body, query }
-- res: response builder with .status, .headers, .body, .send_event(data), .close()

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local http_server = require("lib.http.server")
local http_format = require("lib.http.format")

local M = {}

-- Split a request target into path and query components.
-- "/foo?bar=1" -> "/foo", "bar=1"
-- "/foo"       -> "/foo", nil
--: (string) -> string, string | nil
local function split_target(target)
	local q = target:find("?", 1, true)
	if q then
		return target:sub(1, q - 1), target:sub(q + 1)
	end
	return target, nil
end

-- Build the SSE header preamble (sent once on first send_event call).
--: (integer) -> string
local function sse_preamble(status)
	return http_format.serialize_response({
		status = status,
		headers = {
			["content-type"] = { "text/event-stream" },
			["cache-control"] = { "no-cache" },
			["connection"] = { "keep-alive" },
		},
		body = "",
	})
end

-- Wrap the raw HTTP handler to hide the socket from the app.
-- Returns a handler compatible with lib/http/server.make_connection_handler.
--: (((req: unknown, res: unknown) -> nil), boolean) -> (req: unknown, res: unknown, sock: unknown) -> boolean | nil
local function wrap_handler(app_handler, revoked_ref)
	--: (unknown, unknown, unknown) -> boolean | nil
	return function(raw_req, raw_res, sock)
		if revoked_ref[1] then return end

		local path, query = split_target(raw_req.target or "/")

		-- Build the sanitized request (no socket access).
		local req = {
			method  = raw_req.method,
			path    = path,
			query   = query,
			headers = raw_req.headers,
			body    = raw_req.body,
		}

		-- Build the response builder object.
		local streaming = false
		local closed = false
		local res = {
			status  = 200,
			headers = {},
			body    = nil,
		}

		-- send_event(data) — SSE streaming. First call writes headers + flushes.
		-- Subsequent calls write "data: <data>\n\n" frames.
		function res.send_event(data)
			if revoked_ref[1] then return nil, "http_server: revoked" end
			if closed then return nil, "http_server: stream closed" end
			if not streaming then
				streaming = true
				sock:send(sse_preamble(res.status))
			end
			sock:send("data: " .. tostring(data) .. "\n\n")
			return true
		end

		-- close() — end an SSE stream.
		function res.close()
			if closed then return end
			closed = true
			sock:close()
		end

		-- Call the app handler. It may set res.status/headers/body for a normal
		-- response, or call res.send_event() for SSE streaming.
		app_handler(req, res)

		-- If the handler used SSE, the response was already sent incrementally.
		-- Otherwise, serialize the normal response and send it.
		if not streaming then
			raw_res.status  = res.status
			raw_res.headers = res.headers
			raw_res.body    = res.body
		end

		-- Return true for SSE to signal that the connection handler should NOT
		-- serialize+close (the stream manages its own lifecycle).
		-- For normal responses, return nil so the default path runs.
		if streaming then return true end
	end
end

--:: http_server_opts = { port: integer | nil, host: string | nil, daemon: boolean | nil, url: string | nil, on_serve: ((unknown) -> nil) | nil }
-- http_server_cap(opts) -> cap_table, revoke_fn
--: (http_server_opts) -> unknown, string | nil
function M.http_server_cap(opts)
	if not opts then
		return nil, "http_server: opts required"
	end

	-- Shared revocation flag. Using a table so closures share the same reference.
	local revoked_ref = { false }

	-- Daemon mode: register handler only, no socket binding.
	if opts.daemon then
		if type(opts.on_serve) ~= "function" then
			return nil, "http_server: daemon mode requires opts.on_serve callback"
		end
		local cap = {
			_type = "http_server",
			url   = opts.url or "",
			port  = 0,
		}
		function cap.serve(handler)
			if revoked_ref[1] then return nil, "http_server: revoked" end
			if type(handler) ~= "function" then
				return nil, "http_server: handler must be a function"
			end
			opts.on_serve(handler)
			return true
		end
		return cap, function() revoked_ref[1] = true end
	end

	if not opts.port then
		return nil, "http_server: opts.port is required"
	end

	local port = opts.port
	local host = opts.host or "0.0.0.0"
	local url  = "http://localhost:" .. tostring(port)

	local cap = {
		_type = "http_server",
		url   = url,
		port  = port,
	}

	function cap.serve(handler)
		if revoked_ref[1] then return nil, "http_server: revoked" end
		if type(handler) ~= "function" then
			return nil, "http_server: handler must be a function"
		end

		-- Build a custom connection handler that supports SSE.
		-- We cannot use http_server.server() directly because it always
		-- serializes res and closes the socket after the handler returns.
		-- Instead, we use the socket server with a custom connection handler
		-- that delegates to our wrapper.
		local ffi = require("ffi")
		local buf = ffi.new("char[65536]")
		local max_header_size = 65536
		local err_res = http_format.serialize_response({ status = 400, headers = {} })

		local wrapped = wrap_handler(handler, revoked_ref)

		local socket_server = require("lib.socket.server")
		socket_server.server(function(client)
			if revoked_ref[1] then client:close(); return end

			-- Read headers (same logic as lib/http/server.lua)
			local parts = {}
			local total = 0
			local header_end
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
			local req, i = http_format.parse_request(data)
			if not req or not i then client:send(err_res); return end

			-- Read remaining body if Content-Length specified
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
						req = http_format.parse_request(data)
						if not req then client:send(err_res); return end
					end
				end
			end

			local res = { headers = {} }
			local is_streaming = wrapped(req, res, client)

			-- For normal (non-SSE) responses, serialize and close.
			if not is_streaming then
				-- Normalize header values: app may set strings, serialize expects {string}.
				if res.headers then
					for k, v in pairs(res.headers) do
						if type(v) == "string" then
							res.headers[k] = { v }
						end
					end
				end
				client:send(http_format.serialize_response(res))
				client:close()
			end
		end, port, nil, { host = host })
	end

	local function revoke()
		revoked_ref[1] = true
	end

	return cap, revoke
end

-- Exposed for testing: the handler wrapping logic without needing a real server.
M._wrap_handler = wrap_handler
M._split_target = split_target

return M
