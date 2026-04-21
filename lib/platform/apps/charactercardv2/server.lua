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

local service  = require("lib.platform.service")

--:: LlmCap = { call: (unknown, unknown | nil) -> (string | nil, string | nil), call_stream: (unknown, unknown, unknown | nil) -> (string | nil, string | nil), count_tokens: (unknown) -> integer }

local M = {}

-- create(caps, opts?) -> app
-- caps.llm: pre-built LLM cap (call/call_stream/count_tokens)
-- opts.model: model name (default "default")
-- opts.system_prompt: default system prompt prepended to messages
function M.create(caps, opts)
	opts = opts or {}

	--: LlmCap | nil
	local llm = caps.llm

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

	local methods = {
		chat         = chat,
		chat_stream  = chat_stream,
		count_tokens = count_tokens,
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
	}
end

return M
