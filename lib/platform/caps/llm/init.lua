-- lib/platform/caps/llm/init.lua
-- llm_cap(opts) -> cap_table, revoke_fn
-- Provider-agnostic LLM capability backed by lib/ai/.
--
-- opts.provider    : provider name string — anything lib/ai/ supports
--                    (e.g. "anthropic", "openai", "groq", "gemini", ...)
-- opts.key         : API key string (already resolved from keyring by the platform)
-- opts.model       : default model name (optional, provider defaults apply)
-- opts.base_url    : for openai-compatible providers — local model host:port
-- opts.http_client : required HTTP client capability, shape:
--                    { request(req) -> (resp|nil, err), stream(req) -> (recv_fn, close_fn) | (nil, err) }
--                    Must be injected by the caller — lib/ai providers will
--                    not fall back to a global HTTP client.
-- Any extra opts are passed through to generate/stream calls.
--
-- Capability API (what the app sees):
--   cap.call(messages, call_opts?)                    -> content_string | nil, err
--   cap.call_stream(messages, on_token, call_opts?)   -> full_content   | nil, err
--   cap.count_tokens(text)                            -> integer
--
-- messages: array of { role = "user"|"assistant"|"system", content = string }
-- call_opts may include: model, temperature, max_tokens, top_p, stop
--
-- ── Structured-output cap (M.new) ────────────────────────────────────────────
-- M.new(manifest_entry) -> cap_table, revoke_fn
-- Grammar-constrained LLM generation cap backed by lib/ai/providers/openai_compat.
--
-- manifest_entry.endpoint    : full URL e.g. "http://127.0.0.1:8081"
--                              (default "http://127.0.0.1:8081")
-- manifest_entry.model       : model name string (default "local")
-- manifest_entry.api_key     : passed through to openai_compat (default "")
-- manifest_entry.http_client : required HTTP client capability
--
-- cap.generate({messages, schema?, max_tokens?, temperature?})
--   -> decoded_table | nil, string | nil
-- If schema is provided, response_format (json_schema) is added to the request,
-- the JSON response is decoded, and required top-level keys are validated.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ai = require("lib.ai")
local json = require("lib.format.json")

local M = {}

-- llm_cap(opts) -> cap, revoke | nil, err
function M.llm_cap(opts)
	opts = opts or {}

	local provider_name = opts.provider
	if not provider_name then
		return nil, "llm_cap: opts.provider is required"
	end

	local http_client = opts.http_client
	if not http_client then
		return nil, "llm_cap: opts.http_client is required"
	end

	local revoked = false

	local cap = { _type = "llm" }

	-- Build the base request table from opts, merging call_opts on top.
	local function make_req(messages, call_opts)
		local req = {}
		-- carry through all opts as defaults
		for k, v in pairs(opts) do req[k] = v end
		-- call_opts override opts
		if call_opts then
			for k, v in pairs(call_opts) do req[k] = v end
		end
		req.provider    = provider_name
		req.api_key     = opts.key
		req.http_client = http_client
		req.messages    = messages
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

-- ── M.new: structured-output cap ─────────────────────────────────────────────

--:: LlmManifestEntry = {
--::   endpoint: string | nil,
--::   model: string | nil,
--::   api_key: string | nil,
--::   http_client: unknown | nil,
--:: }

--:: LlmGenerateRequest = {
--::   messages: unknown,
--::   schema: unknown | nil,
--::   max_tokens: integer | nil,
--::   temperature: number | nil,
--:: }

-- Strip scheme from a URL and return the bare host:port string.
-- "http://127.0.0.1:8081"  -> "127.0.0.1:8081"
-- "https://api.example.com" -> "api.example.com"
--: (string) -> string
local function strip_scheme(url)
	return url:match("^https?://(.+)$") or url
end

-- Validate that all keys in schema.required are present in decoded_table.
-- Returns true, nil on success; nil, errmsg on failure.
local function validate_required(decoded, schema)
	if type(schema) ~= "table" then return true end
	local s = schema --[[:! { required: unknown, ... }]]
	local required = s["required"]
	if type(required) ~= "table" then return true end
	local d = decoded --[[:! { [string]: unknown } ]]
	for i = 1, #required do
		local key = required[i]
		if d[key] == nil then
			return nil, "response failed schema validation: missing required field '" .. tostring(key) .. "'"
		end
	end
	return true
end

-- M.new(manifest_entry) -> cap, revoke_fn
function M.new(manifest_entry)
	local entry = (manifest_entry or {}) --[[:! { endpoint: unknown, model: unknown, api_key: unknown, http_client: unknown, ... }]]

	local endpoint    = entry.endpoint   or "http://127.0.0.1:8081"
	local model       = entry.model      or "local"
	local api_key     = entry.api_key    or ""
	local http_client = entry.http_client --[[:! { request: (unknown) -> (unknown, unknown) } | nil]]

	local host = strip_scheme(endpoint)

	local revoked = false

	local cap = { _type = "llm" }

	-- cap.generate(req) -> decoded_table | nil, string | nil
	function cap.generate(req)
		if revoked then return nil, "capability revoked" end
		local r = (req or {}) --[[:! { messages: unknown, max_tokens: unknown, temperature: unknown, schema: unknown, ... }]]

		-- Build the request body. openai_compat does not forward arbitrary fields
		-- like response_format, so we build the body and POST via http_client directly.
		local msgs = (r.messages or {}) --[[:! { [integer]: { role: unknown, content: unknown } }]]
		local messages_converted = {}
		for i = 1, #msgs do
			messages_converted[i] = { role = msgs[i].role, content = msgs[i].content }
		end

		local body = --[[:! { [string]: unknown }]] {
			model    = model,
			messages = messages_converted,
		}
		if r.max_tokens  then body.max_tokens  = r.max_tokens  end
		if r.temperature then body.temperature = r.temperature end
		if r.schema then
			body.response_format = {
				type        = "json_schema",
				json_schema = { schema = r.schema },
			}
		end

		local json_mod = json --[[:! { encode: (unknown) -> (string | nil, unknown), decode: (string) -> (unknown, unknown) }]]
		local body_str, enc_err = json_mod.encode(body)
		if not body_str then return nil, "llm.generate: json encode: " .. tostring(enc_err) end

		if not http_client then return nil, "llm.generate: http_client is required" end

		local res, req_err = http_client.request({
			host    = host,
			method  = "POST",
			path    = "/v1/chat/completions",
			headers = {
				["Content-Type"]   = { "application/json" },
				["Authorization"]  = { "Bearer " .. api_key },
				["Content-Length"] = { tostring(#body_str) },
			},
			body = body_str,
		})
		if not res then return nil, "llm.generate: http error: " .. tostring(req_err) end
		local res_raw = res --[[: unknown]]
		local res_any = res_raw --[[:! { status: integer, body: string }]]
		if res_any.status ~= 200 then
			return nil, "llm.generate: HTTP " .. tostring(res_any.status) .. ": " .. tostring(res_any.body or "")
		end

		-- Parse the OpenAI completion response.
		local resp_data, dec_err = json_mod.decode(res_any.body)
		if not resp_data then
			return nil, "llm.generate: json decode response: " .. tostring(dec_err)
		end
		local rd = resp_data --[[:! { error: { message: unknown, ... } | nil, choices: { [integer]: { message: { content: unknown } | nil } } | nil }]]

		if rd.error then
			local rderr = rd.error --[[:! { message: unknown, ... }]]
			return nil, "llm.generate: API error: " .. tostring(rderr.message or json_mod.encode(rderr))
		end

		local choices_u = rd.choices
		if not choices_u then
			return nil, "llm.generate: no choices in response"
		end
		local choices = choices_u --[[:! { [integer]: { message: { content: unknown } | nil } }]]
		if #choices == 0 then
			return nil, "llm.generate: no choices in response"
		end

		local c1 = choices[1]
		local content = c1.message and c1.message.content
		if content == nil then
			return nil, "llm.generate: missing content in response"
		end

		-- Without schema: return the raw text wrapped in a table.
		if not r.schema then
			return { text = content }
		end

		-- With schema: decode content as JSON and validate required fields.
		local decoded, json_err = json_mod.decode(content --[[:! string]])
		if not decoded then
			return nil, "llm.generate: content is not valid JSON: " .. tostring(json_err)
		end

		local ok, val_err = validate_required(decoded, r.schema)
		if not ok then return nil, val_err end

		return decoded
	end

	local function revoke()
		revoked = true
	end

	return cap, revoke
end

function M.risk(_)
	return { severity = "medium", text = "Sends prompts and receives responses from a language model API. Prompt content may leave your machine." }
end

return M
