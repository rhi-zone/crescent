-- lib/platform/caps/llm/init.lua
-- llm_cap(opts) -> cap_table, revoke_fn
-- Provider-agnostic LLM capability backed by lib/ai/.
--
-- opts.provider  : provider name string — anything lib/ai/ supports
--                  (e.g. "anthropic", "openai", "groq", "gemini", ...)
-- opts.key       : API key string (already resolved from keyring by the platform)
-- opts.model     : default model name (optional, provider defaults apply)
-- opts.base_url  : for openai-compatible providers — local model host:port
-- Any extra opts are passed through to generate/stream calls.
--
-- Capability API (what the app sees):
--   cap.call(messages, call_opts?)                    -> content_string | nil, err
--   cap.call_stream(messages, on_token, call_opts?)   -> full_content   | nil, err
--   cap.count_tokens(text)                            -> integer
--
-- messages: array of { role = "user"|"assistant"|"system", content = string }
-- call_opts may include: model, temperature, max_tokens, top_p, stop

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ai = require("lib.ai")

local M = {}

-- llm_cap(opts) -> cap, revoke | nil, err
function M.llm_cap(opts)
	opts = opts or {}

	local provider_name = opts.provider
	if not provider_name then
		return nil, "llm_cap: opts.provider is required"
	end

	local revoked = false

	local cap = {}

	-- Build the base request table from opts, merging call_opts on top.
	local function make_req(messages, call_opts)
		local req = {}
		-- carry through all opts as defaults
		for k, v in pairs(opts) do req[k] = v end
		-- call_opts override opts
		if call_opts then
			for k, v in pairs(call_opts) do req[k] = v end
		end
		req.provider = provider_name
		req.api_key  = opts.key
		req.messages = messages
		if req.model == nil and opts.model then
			req.model = opts.model
		end
		return req
	end

	-- cap.call(messages, call_opts?) -> content_string | nil, err
	function cap.call(messages, call_opts)
		if revoked then return nil, "capability revoked" end
		local req = make_req(messages, call_opts)
		local resp, err = ai.generate(req)
		if not resp then return nil, err end
		return resp.text
	end

	-- cap.call_stream(messages, on_token, call_opts?) -> full_content | nil, err
	function cap.call_stream(messages, on_token, call_opts)
		if revoked then return nil, "capability revoked" end
		local req = make_req(messages, call_opts)
		local iter, err = ai.stream(req)
		if type(iter) ~= "function" then return nil, err end
		local buf = {}
		while true do
			local delta = iter()
			if delta == nil then break end
			if delta.text and delta.text ~= "" then
				buf[#buf + 1] = delta.text
				on_token(delta.text)
			end
		end
		return table.concat(buf)
	end

	-- cap.count_tokens(text) -> integer
	-- Simple estimate: ~4 chars per token.
	function cap.count_tokens(text)
		if revoked then return nil, "capability revoked" end
		return math.ceil(#text / 4)
	end

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

return M
