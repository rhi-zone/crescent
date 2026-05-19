if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local ai = require("lib.ai")

local mod = {}

--:: require "lib.ai.types"
-- Local helper alias (not in types.lua).
--:: ai_tool_call_list = { [integer]: ai_tool_call }

--- Run an agentic tool loop.
-- Calls ai.generate in a loop, executes tool calls via handlers,
-- appends results, repeats until no more tool calls or max_rounds.
--: ({ model: string, messages: ai_message[], tools: ai_tool[], handlers: { [string]: (args: { [string]: unknown }) -> string }, max_rounds?: integer, max_tokens?: integer, temperature?: number, provider?: ai_provider, http_client?: ai_http_client, api_key?: string }) -> (ai_response | nil, string | nil)
mod.run = function(opts)
	local messages = {}
	for i = 1, #opts.messages do
		messages[i] = opts.messages[i]
	end
	local max_rounds = opts.max_rounds or 10

	for _ = 1, max_rounds do
		local req = {
			model = opts.model,
			messages = messages,
			tools = opts.tools,
			max_tokens = opts.max_tokens,
			temperature = opts.temperature,
			provider = opts.provider,
			http_client = opts.http_client,
			api_key = opts.api_key,
		} --[[: unknown]]
		local res, err = ai.generate(req --[[:! ai_request]])
		if not res then return nil, err end

		-- if no tool calls, return final response
		local tool_calls = res.tool_calls
		if not tool_calls then return res end
		local tool_calls_ = tool_calls --[[:! ai_tool_call_list]]
		if #tool_calls_ == 0 then
			return res
		end

		-- append assistant message with tool calls
		-- reconstruct content for the message
		local assistant_content = res.text or ""
		messages[#messages + 1] = { role = "assistant", content = assistant_content }

		-- execute each tool call and append results
		local json_encode = require("lib.format.json").encode --[[:! (unknown) -> string]]
		for i = 1, #tool_calls_ do
			local tc = tool_calls_[i]
			local handler = opts.handlers[tc.name]
			local result
			if handler then
				local ok, ret = pcall(handler, tc.arguments)
				if ok then
					result = type(ret) == "string" and ret or json_encode(ret)
				else
					result = '{"error": ' .. json_encode(tostring(ret)) .. '}'
				end
			else
				result = '{"error": "unknown tool: ' .. tc.name .. '"}'
			end
			messages[#messages + 1] = {
				role = "tool",
				content = result or "",
				tool_call_id = tc.id,
				name = tc.name,
			}
		end
	end

	return nil, "max rounds exceeded"
end

return mod
