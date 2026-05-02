-- AI executor for lib/taskgraph.
-- Registers "llm.complete" and "llm.tool_loop" task types.
--
-- Usage:
--   local orch = require("lib.taskgraph")
--   require("lib.taskgraph.executor.ai").register(orch)
--
-- Or standalone:
--   local ai_exec = require("lib.taskgraph.executor.ai")
--   local executors = ai_exec.executors   -- merge into your own executor table

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ai = require("lib.ai")

local M = {}

--:: AiMessage = { role: "system" | "user" | "assistant" | "tool", content: string, tool_call_id?: string, name?: string }
--:: CompleteInput = { messages: AiMessage[], model: string, temperature?: number, max_tokens?: integer, provider?: string, http_client?: unknown, api_key?: string }
--:: ToolSpec = { name: string, description: string, input_schema: unknown, handler_type?: string }
--:: ToolLoopInput = { messages: AiMessage[], model: string, temperature?: number, max_tokens?: integer, provider?: string, http_client?: unknown, api_key?: string, max_rounds?: integer, tools: { [integer]: ToolSpec } }

-- llm.complete: single non-streaming generation.
-- input  = { messages, model, temperature?, provider?, max_tokens? }
-- output = { text, usage }
local function exec_complete(task, _ctx)
	local inp = task.input --[[:! CompleteInput]]
	local res, err = ai.generate({
		messages    = inp.messages,
		model       = inp.model,
		temperature = inp.temperature,
		max_tokens  = inp.max_tokens,
		provider    = inp.provider,
		http_client = inp.http_client,
		api_key     = inp.api_key,
	} --[[: any]])
	if not res then error(err or "llm.complete failed") end
	return { text = res.text, usage = res.usage }
end

-- llm.tool_loop: agentic loop with tool call → subtask lineage.
-- input = {
--   messages, model, temperature?, provider?, max_tokens?,
--   max_rounds? (default 10),
--   tools = [{ name, description, input_schema, handler_type }],
-- }
-- output = { text, rounds, tool_calls }
--
-- Each tool call spawns a task of type = tool.handler_type with the
-- tool arguments as input, giving proper lineage in the graph.
local function exec_tool_loop(task, ctx)
	local ctx_ = ctx --[[:! { spawn: (unknown, unknown) -> string, result: (unknown, string) -> unknown, ... }]]
	local inp        = task.input --[[:! ToolLoopInput]]
	local max_rounds = inp.max_rounds or 10
	local messages   = {}
	for i = 1, #inp.messages do messages[i] = inp.messages[i] end

	-- build tool specs for the provider (strip handler_type)
	local tool_specs = {}
	for i = 1, #inp.tools do
		local t = inp.tools[i]
		tool_specs[i] = {
			name         = t.name,
			description  = t.description,
			input_schema = t.input_schema,
		}
	end

	-- build name → handler_type lookup
	local handler_types = {}
	for i = 1, #inp.tools do
		handler_types[inp.tools[i].name] = inp.tools[i].handler_type
	end

	local total_tool_calls = 0
	local rounds = 0

	for _ = 1, max_rounds do
		rounds = rounds + 1
		local res, err = ai.generate({
			messages    = messages,
			model       = inp.model,
			tools       = tool_specs,
			temperature = inp.temperature,
			max_tokens  = inp.max_tokens,
			provider    = inp.provider,
			http_client = inp.http_client,
			api_key     = inp.api_key,
		} --[[: any]])
		if not res then error(err or "llm.tool_loop generation failed") end

		local tool_calls = res.tool_calls
		if not tool_calls then
			return { text = res.text, rounds = rounds, tool_calls = total_tool_calls }
		end
		local tool_calls_ = tool_calls --[[:! { [integer]: { arguments: { [string]: unknown }, id: string, name: string } }]]
		if #tool_calls_ == 0 then
			return { text = res.text, rounds = rounds, tool_calls = total_tool_calls }
		end

		messages[#messages + 1] = { role = "assistant", content = res.text or "" }

		for i = 1, #tool_calls_ do
			local tc      = tool_calls_[i]
			local htype   = handler_types[tc.name]
			local tool_output
			if htype then
				-- spawn a real subtask — proper lineage
				local sub_id = ctx_:spawn({ type = htype, input = tc.arguments })
				local sub_out = ctx_:result(sub_id)
				-- coerce to string for the message
				if type(sub_out) == "string" then
					tool_output = sub_out
				else
					local ok, json = pcall(require, "lib.format.json")
					tool_output = ok and json.encode(sub_out) or tostring(sub_out)
				end
			else
				tool_output = '{"error":"no handler_type for tool ' .. tc.name .. '"}'
			end
			total_tool_calls = total_tool_calls + 1
			messages[#messages + 1] = {
				role         = "tool",
				content      = tool_output,
				tool_call_id = tc.id,
				name         = tc.name,
			}
		end
	end

	error("llm.tool_loop: max_rounds exceeded")
end

M.executors = {
	["llm.complete"]   = exec_complete,
	["llm.tool_loop"]  = exec_tool_loop,
}

-- Convenience: register into an orch instance.
--: ({ register: (string, unknown) -> nil, ... }) -> nil
function M.register(orch)
	for k, v in pairs(M.executors) do
		orch.register(k, v)
	end
end

return M
