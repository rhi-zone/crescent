if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local ai = require("lib.ai")

local mod = {}

--- Run an agentic tool loop.
-- Calls ai.generate in a loop, executes tool calls via handlers,
-- appends results, repeats until no more tool calls or max_rounds.
--: ({ model: string, messages: ai_message[], tools: ai_tool[], handlers: { [string]: (args: { [string]: any }) -> string }, max_rounds?: integer, max_tokens?: integer, temperature?: number, provider?: ai_provider }) -> ai_response?, string?
mod.run = function(opts)
	local messages = {}
	for i = 1, #opts.messages do
		messages[i] = opts.messages[i]
	end
	local max_rounds = opts.max_rounds or 10

	for _ = 1, max_rounds do
		local res, err = ai.generate({
			model = opts.model,
			messages = messages,
			tools = opts.tools,
			max_tokens = opts.max_tokens,
			temperature = opts.temperature,
			provider = opts.provider,
		})
		if not res then return nil, err end

		-- if no tool calls, return final response
		if not res.tool_calls or #res.tool_calls == 0 then
			return res
		end

		-- append assistant message with tool calls
		-- reconstruct content for the message
		local assistant_content = res.text or ""
		messages[#messages + 1] = { role = "assistant", content = assistant_content }

		-- execute each tool call and append results
		for i = 1, #res.tool_calls do
			local tc = res.tool_calls[i]
			local handler = opts.handlers[tc.name]
			local result
			if handler then
				local ok, ret = pcall(handler, tc.arguments)
				if ok then
					result = type(ret) == "string" and ret or require("lib.format.json").encode(ret)
				else
					result = '{"error": ' .. require("lib.format.json").encode(tostring(ret)) .. '}'
				end
			else
				result = '{"error": "unknown tool: ' .. tc.name .. '"}'
			end
			messages[#messages + 1] = {
				role = "tool",
				content = result,
				tool_call_id = tc.id,
				name = tc.name,
			}
		end
	end

	return nil, "max rounds exceeded"
end

return mod
