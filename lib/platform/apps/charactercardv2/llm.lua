-- lib/platform/apps/charactercardv2/llm.lua
-- LLM client library -- wraps an http_client cap with OpenAI chat completions protocol.
--
-- The http_client cap is a table with:
--   request(req) -> {status, headers, body} | nil, err
--   request_stream(req, on_chunk) -> {status, headers} | nil, err
--
-- Usage:
--   local llm = require("lib.platform.apps.charactercardv2.llm")
--   local client = llm.create(http_client, { model = "gpt-4" })
--   local content, err = client.call(messages)
--   local full, err = client.call_stream(messages, function(delta) io.write(delta) end)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.json")

local M = {}

-- create(http_client, opts?) -> llm
-- http_client: a table with request() and request_stream()
-- opts.model: model name (default "default")
-- opts.path: completions path (default "/v1/chat/completions")
--: (http_client: { request: (unknown) -> (unknown, string | nil), request_stream: (unknown) -> (unknown, string | nil), ... }, opts: ({ model: (string | nil), path: (string | nil), api_key: (string | nil) } | nil)) -> { call: (unknown, unknown) -> (unknown, string | nil), stream: (unknown, unknown) -> (unknown, string | nil) }
function M.create(http_client, opts)
	local opts_t = opts or { model = nil, path = nil, api_key = nil }
	local model = opts_t.model or "default"
	local path = opts_t.path or "/v1/chat/completions"
	local api_key = opts_t.api_key

	local llm = {}

	-- call(messages, gen_opts?) -> content_string | nil, err
	-- messages: array of {role, content}
	-- gen_opts: optional table with temperature, max_tokens, etc.
	function llm.call(messages, gen_opts)
		local body_t = { model = model, messages = messages }
		if gen_opts then
			if gen_opts.temperature then body_t.temperature = gen_opts.temperature end
			if gen_opts.max_tokens then body_t.max_tokens = gen_opts.max_tokens end
			if gen_opts.top_p then body_t.top_p = gen_opts.top_p end
			if gen_opts.stop then body_t.stop = gen_opts.stop end
		end
		local body, berr = json.encode(body_t)
		if not body then return nil, "llm: JSON encode failed: " .. tostring(berr) end

		local resp, err = http_client.request({
			method = "POST",
			path = path,
			headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = (api_key ~= nil and api_key ~= "") and ("Bearer " .. (api_key --[[:! string]])) or nil,
			},
			body = body,
		})
		if not resp then return nil, "llm: HTTP request failed: " .. tostring(err) end
		local resp_ = resp --[[:! { status: integer, body: string | nil, ... }]]
		if resp_.status ~= 200 then
			return nil, "llm: HTTP " .. tostring(resp_.status) .. (resp_.body and (": " .. resp_.body) or "")
		end

		if not resp_.body then return nil, "llm: empty response body" end
		local ok, data = pcall(json.decode, resp_.body)
		if not ok or not data then
			return nil, "llm: JSON decode failed"
		end
		local data_t = data --[[:! { choices: { [integer]: { message: { content: string | nil } | nil, delta: { content: string | nil } | nil } } | nil }]]

		local choices = data_t.choices
		if not choices or not choices[1] then
			return nil, "llm: no choices in response"
		end
		local msg = choices[1].message
		if not msg then return nil, "llm: no message in choice" end
		return msg.content
	end

	-- call_stream(messages, on_token, gen_opts?) -> full_content | nil, err
	-- Streams tokens via on_token(delta). Returns concatenated full content.
	-- Requires http_client.request_stream to be available.
	if http_client.request_stream then
		function llm.call_stream(messages, on_token, gen_opts)
			local body_t = { model = model, messages = messages, stream = true }
			if gen_opts then
				if gen_opts.temperature then body_t.temperature = gen_opts.temperature end
				if gen_opts.max_tokens then body_t.max_tokens = gen_opts.max_tokens end
				if gen_opts.top_p then body_t.top_p = gen_opts.top_p end
				if gen_opts.stop then body_t.stop = gen_opts.stop end
			end
			local body, berr = json.encode(body_t)
			if not body then return nil, "llm: JSON encode failed: " .. tostring(berr) end

			local parts = {}
			local buf = ""

			local function process_sse_line(line)
				if line == "" then return end
				local data = line:match("^data: (.+)")
				if not data then return end
				if data == "[DONE]" then return end
				local ok, event = pcall(json.decode, data)
				if not ok or not event then return end
				local event_t = event --[[:! { choices: { [integer]: { delta: { content: string | nil } | nil } } | nil }]]
				local choices = event_t.choices
				if not choices or not choices[1] then return end
				local delta = choices[1].delta
				if delta and delta.content then
					parts[#parts + 1] = delta.content
					on_token(delta.content)
				end
			end

			local function on_chunk(chunk)
				buf = buf .. chunk
				-- Parse complete SSE lines (terminated by \n)
				while true do
					local nl = buf:find("\n", 1, true)
					if not nl then break end
					local line = buf:sub(1, nl - 1)
					-- Strip trailing \r if present
					if line:sub(-1) == "\r" then line = line:sub(1, -2) end
					buf = buf:sub(nl + 1)
					process_sse_line(line)
				end
			end

			local resp, err = http_client.request_stream({
				method = "POST",
				path = path,
				headers = {
					["Content-Type"] = "application/json",
					["Authorization"] = (api_key ~= nil and api_key ~= "") and ("Bearer " .. (api_key --[[:! string]])) or nil,
				},
				body = body,
			}, on_chunk)
			if not resp then return nil, "llm: HTTP request failed: " .. tostring(err) end
			local resp2_ = resp --[[:! { status: integer, ... }]]
			if resp2_.status ~= 200 then
				return nil, "llm: HTTP " .. tostring(resp2_.status)
			end

			-- Process any remaining data in buffer
			if #buf > 0 then
				process_sse_line(buf)
			end

			return table.concat(parts)
		end
	end

	-- count_tokens(text) -> number
	-- Simple estimate: ~4 chars per token (rough approximation).
	function llm.count_tokens(text)
		return math.ceil(#text / 4)
	end

	return llm
end

return M
