-- lib/platform/caps/llm.lua
-- llm_cap(config) -> capability table
-- Calls an OpenAI-compatible chat completions endpoint (vLLM, Ollama, OpenAI, etc.)
--
-- config.endpoint : base URL (default "http://localhost:8000")
-- config.model    : model name (default "default")
-- config.api_key  : optional bearer token
-- config.path     : completions path (default "/v1/chat/completions")
--
-- Capability API (passed to sandbox as caps.llm):
--   cap.call(messages) -> string | nil, err
--   cap.call_stream(messages, on_token) -> string | nil, err
--   messages: array of {role, content} tables
--   on_token(text): called for each content delta during streaming

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local http   = require("lib.http.client")
local hfmt   = require("lib.http.format")
local json   = require("lib.format.json")
local socket = require("lib.ljsocket")

local M = {}

-- Parse http://host:port/path from endpoint string.
local function parse_endpoint(endpoint)
	local host, port, path = endpoint:match("^https?://([^:/]+):(%d+)(/?.*)")
	if not host then
		host, path = endpoint:match("^https?://([^/]+)(/?.*)")
		port = "80"
	end
	port = (port and #port > 0) and port or "80"
	path = (path and #path > 0) and path or ""
	return host or "localhost", port, path
end

-- llm_cap(config?) -> {call}
function M.llm_cap(config)
	config = config or {}
	local endpoint   = config.endpoint or "http://localhost:8000"
	local model      = config.model    or "default"
	local api_key    = config.api_key
	local base_path  = config.path     -- override completions path if needed

	local host, port, ep_path = parse_endpoint(endpoint)

	local ffi = require("ffi")
	local recv_buf = ffi.new("char[65536]")

	return {
		-- call_stream(messages, on_token) -> full_content | nil, err
		-- Streams tokens via on_token(delta_text), returns full content when done.
		call_stream = function (messages, on_token)
			local body, berr = json.encode({ model = model, messages = messages, stream = true })
			if not body then return nil, "llm: JSON encode failed: " .. tostring(berr) end

			local headers = {
				["Content-Type"]   = { "application/json" },
				["Content-Length"] = { tostring(#body) },
			}
			if api_key then
				headers["Authorization"] = { "Bearer " .. tostring(api_key) }
			end

			local client, cerr = socket.create("inet", "stream", "tcp")
			if not client then return nil, "llm: socket create failed: " .. tostring(cerr) end

			local ok, err = client:connect(host, port)
			if not ok then client:close(); return nil, "llm: connect failed: " .. tostring(err) end

			local req_str = hfmt.serialize_request({
				method = "POST",
				target = base_path or (ep_path .. "/v1/chat/completions"),
				version = "HTTP/1.1",
				headers = headers,
				body = body,
			})
			ok, err = client:send(req_str)
			if not ok then client:close(); return nil, "llm: send failed: " .. tostring(err) end

			-- Read response: first get headers, then parse SSE stream
			local raw_parts = {}
			local header_end
			while not header_end do
				local chunk = client:receive(recv_buf)
				if not chunk then client:close(); return nil, "llm: connection closed reading headers" end
				raw_parts[#raw_parts + 1] = chunk
				local combined = table.concat(raw_parts)
				header_end = combined:find("\r\n\r\n", 1, true)
				if header_end then raw_parts = { combined } end
			end

			local data = raw_parts[1]
			local resp_line = data:sub(1, data:find("\r\n", 1, true) - 1)
			local status_code = tonumber(resp_line:match("HTTP/%S+ (%d+)"))
			if not status_code or status_code ~= 200 then
				client:close()
				return nil, "llm: HTTP " .. tostring(status_code or "unknown")
			end

			-- Stream body: parse SSE events from chunks
			local remainder = data:sub(header_end + 4)
			local content_parts = {}
			local done = false

			local function process_sse(text)
				-- SSE format: lines starting with "data: " separated by blank lines
				local pos = 1
				while pos <= #text do
					local line_end = text:find("\n", pos, true)
					if not line_end then break end
					local line = text:sub(pos, line_end - 1)
					-- Strip trailing \r
					if line:sub(-1) == "\r" then line = line:sub(1, -2) end
					pos = line_end + 1

					if line:sub(1, 6) == "data: " then
						local payload = line:sub(7)
						if payload == "[DONE]" then
							done = true
							return pos
						end
						local parse_ok, event = pcall(json.decode, payload)
						if parse_ok and event then
							local choices = event.choices
							if choices and choices[1] then
								local delta = choices[1].delta
								if delta and delta.content then
									content_parts[#content_parts + 1] = delta.content
									if on_token then on_token(delta.content) end
								end
								if choices[1].finish_reason then
									done = true
									return pos
								end
							end
						end
					end
				end
				return pos
			end

			-- Process any SSE data already in the first chunk
			local consumed = process_sse(remainder)
			remainder = remainder:sub(consumed)

			while not done do
				local chunk = client:receive(recv_buf)
				if not chunk or #chunk == 0 then break end
				remainder = remainder .. chunk
				consumed = process_sse(remainder)
				remainder = remainder:sub(consumed)
			end

			client:close()
			local full = table.concat(content_parts)
			if #full == 0 then return nil, "llm: no content in stream" end
			return full
		end,

		-- call(messages) -> content_string | nil, err
		call = function (messages)
			local body, berr = json.encode({ model = model, messages = messages })
			if not body then return nil, "llm: JSON encode failed: " .. tostring(berr) end

			local headers = {
				["Content-Type"]   = { "application/json" },
				["Content-Length"] = { tostring(#body) },
			}
			if api_key then
				headers["Authorization"] = { "Bearer " .. tostring(api_key) }
			end

			local resp, err = http.send({
				host    = host,
				port    = port,
				method  = "POST",
				path    = (base_path or (ep_path .. "/v1/chat/completions")),
				headers = headers,
				body    = body,
			})
			if not resp then return nil, "llm: HTTP request failed: " .. tostring(err) end

			local parsed = hfmt.parse_response(resp)
			if not parsed then return nil, "llm: invalid HTTP response" end
			if parsed.status ~= 200 then
				return nil, "llm: HTTP " .. parsed.status
			end

			local ok, data = pcall(json.decode, parsed.body)
			if not ok or not data then
				return nil, "llm: JSON decode failed"
			end

			local choices = data.choices
			if not choices or not choices[1] then
				return nil, "llm: no choices in response"
			end
			local msg = choices[1].message
			if not msg then return nil, "llm: no message in choice" end
			return msg.content
		end,
	}
end

return M
