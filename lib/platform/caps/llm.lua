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
--   messages: array of {role, content} tables

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local http   = require("lib.http.client")
local hfmt   = require("lib.http.format")
local json   = require("lib.format.json")

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

	return {
		-- call(messages) -> content_string | nil, err
		call = function (messages)
			local body, berr = json.encode({ model = model, messages = messages })
			if not body then return nil, "llm: JSON encode failed: " .. tostring(berr) end

			local headers = {
				["Content-Type"]   = { "application/json" },
				["Content-Length"] = { tostring(#body) },
			}
			if api_key then
				headers["Authorization"] = { "Bearer " .. api_key }
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
