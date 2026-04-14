-- lib/platform/apps/card/llm.lua
-- LLM client library -- wraps an http_client cap with OpenAI chat completions protocol.
--
-- The http_client cap is a table with:
--   request(req) -> {status, headers, body} | nil, err
--   request_stream(req, on_chunk) -> {status, headers} | nil, err
--
-- Usage:
--   local llm = require("lib.platform.apps.card.llm")
--   local client = llm.create(http_client, { model = "gpt-4" })
--   local content, err = client.call(messages)
--   local full, err = client.call_stream(messages, function(delta) io.write(delta) end)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.json")

local M = {}

-- create(http_client, opts?) -> llm
-- http_client: a table with request() and request_stream()
-- opts.model: model name (default "default")
-- opts.path: completions path (default "/v1/chat/completions")
--: (http_client: { request: (req: unknown) -> unknown, request_stream: ((req: unknown, on_chunk: (data: string) -> ()) -> unknown)? }, opts: { model: string?, path: string? }?) -> { call: (messages: unknown, gen_opts: unknown?) -> string?, string?, call_stream: ((messages: unknown, on_token: (delta: string) -> (), gen_opts: unknown?) -> string?, string?)?, count_tokens: (text: string) -> number }
function M.create(http_client, opts)
	opts = opts or {}
	local model = opts.model or "default"
	local path = opts.path or "/v1/chat/completions"

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
			},
			body = body,
		})
		if not resp then return nil, "llm: HTTP request failed: " .. tostring(err) end

		if resp.status ~= 200 then
			return nil, "llm: HTTP " .. tostring(resp.status) .. (resp.body and (": " .. resp.body) or "")
		end

		local ok, data = pcall(json.decode, resp.body)
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
				local choices = event.choices
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
				},
				body = body,
			}, on_chunk)
			if not resp then return nil, "llm: HTTP request failed: " .. tostring(err) end

			if resp.status ~= 200 then
				return nil, "llm: HTTP " .. tostring(resp.status)
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
