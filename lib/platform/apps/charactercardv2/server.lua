-- lib/platform/apps/charactercardv2/server.lua
-- Card app server -- assembles prompts and streams LLM responses.
--
-- Usage:
--   local card = require("lib.platform.apps.charactercardv2.server")
--   local app = card.create(caps, opts)
--   local content, err = app.chat(messages)
--   local content, err = app.chat_stream(messages, on_token)

if package and not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local llm_lib = require("lib.platform.apps.charactercardv2.llm")
local service  = require("lib.platform.service")

-- Keyring is optional: fail gracefully when unavailable (no libcrypto etc.).
local keyring
do
	local ok, mod = pcall(require, "lib.keyring")
	if ok then keyring = mod end
end

-- infer_provider(host) -> provider_string | nil
-- Maps an LLM API hostname to a crescent provider name.
local function infer_provider(host)
	if not host then return nil end
	if host:find("openai%.com") then return "openai" end
	if host:find("anthropic%.com") then return "anthropic" end
	if host:find("openrouter%.ai") then return "openrouter" end
	if host:find("googleapis%.com") or host:find("generativelanguage") then return "google" end
	if host:find("cohere%.com") then return "cohere" end
	if host:find("mistral%.ai") then return "mistral" end
	if host:find("together%.ai") or host:find("togethercomputer") then return "together" end
	return nil
end

local M = {}

-- create(caps, opts?) -> app
-- caps.llm: pre-built LLM client (for tests / backward compat)
-- caps.llm_api: http_client table -- constructs LLM client via llm_lib
-- opts.model: model name (default "default")
-- opts.path: completions path
-- opts.api_key: explicit API key (takes priority over keyring and env)
-- opts.system_prompt: default system prompt prepended to messages
function M.create(caps, opts)
	opts = opts or {}

	local llm
	-- caps.llm is a pre-built client for tests/backward compat.
	-- Use pcall because the strict caps proxy errors on undeclared cap names.
	local ok_llm, llm_cap = pcall(function() return caps.llm end)
	if ok_llm and llm_cap then
		llm = llm_cap -- pre-built (tests, backward compat)
	elseif caps.llm_api then
		-- Resolve api_key in priority order:
		--   1. opts.api_key (explicit — e.g. injected from env var at CLI launch)
		--   2. keyring.get("crescent/llm/<provider>") (provider inferred from host)
		--   3. nil (unauthenticated — local models)
		local api_key = opts.api_key
		if not api_key and keyring then
			local provider = infer_provider(caps.llm_api.host)
			if provider then
				local stored = keyring.get("crescent/llm/" .. provider)
				if stored then api_key = stored end
			end
		end
		llm = llm_lib.create(caps.llm_api, {
			-- Priority: opts > cap field (from --cap.llm_api.model=...) > default
			model = opts.model or caps.llm_api.model or "default",
			path = opts.path or caps.llm_api.path,
			api_key = api_key,
		})
	end

	-- ── Helpers ──────────────────────────────────────────────────────────────

	-- prepend_system(messages) -> messages
	local function prepend_system(messages)
		if not opts.system_prompt then return messages end
		local msgs = { { role = "system", content = opts.system_prompt } }
		for i = 1, #messages do
			msgs[#msgs + 1] = messages[i]
		end
		return msgs
	end

	-- ── Methods (caps as first arg for service projection) ───────────────────

	-- chat(caps, messages, gen_opts?) -> content | nil, err
	-- Prepends system prompt if configured, then calls llm.call.
	-- messages may be a string (CLI usage: treated as user message) or
	-- a table of {role, content} pairs (HTTP usage).
	local function chat(_caps, messages, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		if type(messages) == "string" then
			messages = { { role = "user", content = messages } }
		end
		return llm.call(prepend_system(messages), gen_opts)
	end

	-- chat_stream(caps, messages, on_token, gen_opts?) -> content | nil, err
	-- Streaming variant. Requires llm.call_stream.
	local function chat_stream(_caps, messages, on_token, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		if not llm.call_stream then return nil, "card: streaming not supported" end
		return llm.call_stream(prepend_system(messages), on_token, gen_opts)
	end

	-- count_tokens(caps, text) -> number
	local function count_tokens(_caps, text)
		if not llm then return 0 end
		return llm.count_tokens(text)
	end

	-- ── Key management endpoints ──────────────────────────────────────────────
	-- Keys are stored in the keyring (write-only from the client's perspective).
	-- GET /api/keys          -> { providers: ["openai", ...] }  (names only, no values)
	-- POST /api/keys         body { provider, key }             -> { ok = true }
	-- DELETE /api/keys/:provider_id                             -> { ok = true }

	-- list_keys(_caps) -> { providers: [...] }
	local function list_keys(_caps)
		if not keyring then return nil, "keyring unavailable" end
		-- We don't store a separate index; enumerate by probing the well-known providers.
		-- This is intentionally conservative: only providers we know about are surfaced.
		local known = { "openai", "anthropic", "openrouter", "google", "cohere", "mistral", "together" }
		local found = {}
		for _, provider in ipairs(known) do
			local v = keyring.get("crescent/llm/" .. provider)
			if v then found[#found + 1] = provider end
		end
		return { providers = found }
	end

	-- set_key(_caps, provider, key) -> { ok = true } | nil, err
	-- Stores key under "crescent/llm/<provider>".  Key is never echoed back.
	local function set_key(_caps, provider, key)
		if not keyring then return nil, "keyring unavailable" end
		if not provider or provider == "" then return nil, "provider required" end
		if not key or key == "" then return nil, "key required" end
		local ok, err = keyring.set("crescent/llm/" .. provider, key)
		if not ok then return nil, err end
		return { ok = true }
	end

	-- delete_key(_caps, provider_id) -> { ok = true } | nil, err
	local function delete_key(_caps, provider_id)
		if not keyring then return nil, "keyring unavailable" end
		if not provider_id or provider_id == "" then return nil, "provider required" end
		local ok, err = keyring.delete("crescent/llm/" .. provider_id)
		if not ok then return nil, err end
		return { ok = true }
	end

	local methods = {
		chat         = chat,
		chat_stream  = chat_stream,
		count_tokens = count_tokens,
		list_keys    = list_keys,
		set_key      = set_key,
		delete_key   = delete_key,
	}

	local descriptors = {
		chat = {
			method = "POST",
			path   = "/chat",
			help   = "Send messages to the LLM; returns assistant content.",
		},
		chat_stream = {
			method = "POST",
			path   = "/chat-stream",
			help   = "Streaming variant; returns assembled content.",
		},
		count_tokens = {
			method = "GET",
			path   = "/count-tokens",
			help   = "Count tokens in a text string.",
		},
		list_keys = {
			method = "GET",
			path   = "/api/keys",
			help   = "List stored provider names (no key values returned).",
		},
		set_key = {
			method = "POST",
			path   = "/api/keys",
			help   = "Store an API key for a provider (write-only).",
		},
		delete_key = {
			method = "DELETE",
			path   = "/api/keys/:provider_id",
			help   = "Delete the stored API key for a provider.",
		},
	}

	local svc = service.create(caps, methods, descriptors)

	-- Expose direct method accessors for callers that invoke them without the
	-- HTTP/CLI projection (e.g. existing tests and embedders).
	return {
		handler      = svc.handler,
		cli          = svc.cli,
		-- Direct accessors: caps already closed over, no need to pass it.
		chat         = function(messages, gen_opts)  return chat(caps, messages, gen_opts) end,
		chat_stream  = function(messages, on_token, gen_opts) return chat_stream(caps, messages, on_token, gen_opts) end,
		count_tokens = function(text)                return count_tokens(caps, text) end,
		list_keys    = function()                    return list_keys(caps) end,
		set_key      = function(provider, key)       return set_key(caps, provider, key) end,
		delete_key   = function(provider_id)         return delete_key(caps, provider_id) end,
	}
end

return M
