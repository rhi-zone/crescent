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

local M = {}

-- create(caps, opts?) -> app
-- caps.llm: pre-built LLM client (for tests / backward compat)
-- caps.llm_api: http_client table -- constructs LLM client via llm_lib
-- opts.model: model name (default "default")
-- opts.path: completions path
-- opts.system_prompt: default system prompt prepended to messages
function M.create(caps, opts)
	opts = opts or {}

	local llm
	if caps.llm then
		llm = caps.llm -- pre-built (tests, backward compat)
	elseif caps.llm_api then
		llm = llm_lib.create(caps.llm_api, {
			model = opts.model or "default",
			path = opts.path,
		})
	end

	local app = {}

	-- chat(messages, gen_opts?) -> content | nil, err
	-- Prepends system prompt if configured, then calls llm.call.
	function app.chat(messages, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		local msgs = messages
		if opts.system_prompt then
			msgs = { { role = "system", content = opts.system_prompt } }
			for i = 1, #messages do
				msgs[#msgs + 1] = messages[i]
			end
		end
		return llm.call(msgs, gen_opts)
	end

	-- chat_stream(messages, on_token, gen_opts?) -> content | nil, err
	-- Streaming variant. Requires llm.call_stream.
	function app.chat_stream(messages, on_token, gen_opts)
		if not llm then return nil, "card: no LLM capability available" end
		if not llm.call_stream then return nil, "card: streaming not supported" end
		local msgs = messages
		if opts.system_prompt then
			msgs = { { role = "system", content = opts.system_prompt } }
			for i = 1, #messages do
				msgs[#msgs + 1] = messages[i]
			end
		end
		return llm.call_stream(msgs, on_token, gen_opts)
	end

	-- count_tokens(text) -> number
	function app.count_tokens(text)
		if not llm then return 0 end
		return llm.count_tokens(text)
	end

	-- cli(args) -> nil
	-- CLI handler: invoked when 'cr run <app> -- [args...]' is used.
	--
	-- Usage:
	--   cr run <app> -- chat <message>       Send a message; print response.
	--   cr run <app> -- chat --json <msg>    Output as {"response":"..."} JSON.
	--   cr run <app> -- --help               Print usage.
	function app.cli(args)
		-- Flags.
		local want_json = false
		local positional = {}
		for i = 1, #args do
			if args[i] == "--json" then
				want_json = true
			elseif args[i] == "--help" or args[i] == "-h" then
				-- Print usage and exit cleanly.
				io.write("usage:\n")
				io.write("  cr run <app> -- chat <message>          Send a message; print response\n")
				io.write("  cr run <app> -- chat --json <message>   Output as JSON\n")
				io.write("  cr run <app> -- --help                  This help text\n")
				return
			else
				positional[#positional + 1] = args[i]
			end
		end

		local subcmd = positional[1]

		if subcmd == "chat" then
			-- Collect the message from remaining positional args.
			local parts = {}
			for i = 2, #positional do
				parts[#parts + 1] = positional[i]
			end
			local message = table.concat(parts, " ")
			if message == "" then
				io.stderr:write("error: 'chat' requires a message argument\n")
				return
			end

			local messages = { { role = "user", content = message } }
			local content, err = app.chat(messages)
			if not content then
				io.stderr:write("error: " .. tostring(err) .. "\n")
				return
			end

			if want_json then
				-- Minimal JSON encoding: escape backslash, double-quote, and control chars.
				local escaped = content
					:gsub('\\', '\\\\')
					:gsub('"',  '\\"')
					:gsub('\n', '\\n')
					:gsub('\r', '\\r')
					:gsub('\t', '\\t')
				io.write('{"response":"' .. escaped .. '"}\n')
			else
				io.write(content .. "\n")
			end
		else
			io.write("usage:\n")
			io.write("  cr run <app> -- chat <message>          Send a message; print response\n")
			io.write("  cr run <app> -- chat --json <message>   Output as JSON\n")
			io.write("  cr run <app> -- --help                  This help text\n")
		end
	end

	return app
end

return M
