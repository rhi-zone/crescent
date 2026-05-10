if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local set_mod    = require("lib.agent.set")
local render_mod = require("lib.agent.render")

local M = {}

--:: LeafTaskDef = {
--::   type: string,
--::   inputs: unknown,
--::   max_iterations: integer | nil,
--:: }

--:: LlmResponse = { notes_add: { [integer]: { key: string, value: unknown }, ... } | nil, notes_drop: { [integer]: string, ... } | nil, tool_call: { name: string, args: { [string]: unknown } | nil, ... } | nil, result: unknown }
--:: LlmCap = { generate: (req: { [string]: unknown }) -> (LlmResponse | nil, string | nil) }
--:: ExecCap = (name: string, args: { [string]: unknown }) -> (unknown, string | nil)
--:: LeafCaps = { llm: LlmCap, exec: ExecCap | nil }

-- Run a single leaf task. Returns task output or nil+errmsg.
--: (LeafTaskDef, AgentSet, LeafCaps, { [string]: unknown } | nil) -> (unknown, string | nil)
function M.run(task_def, initial_set, caps, preset_spec)
	local s         = initial_set
	local max_iter  = task_def.max_iterations or 10
	local iteration = 0

	-- Whether a tool result is pending (present in set and not yet cleared).
	-- We track this externally so we can clear it after the LLM decision that consumes it.
	local tool_result_pending = set_mod.get(s, "_tool_result") ~= nil

	while true do
		-- 1. Clear _tool_result if none pending.
		if not tool_result_pending then
			s = set_mod.drop(s, "_tool_result")
		end

		-- 2. Render messages.
		local messages = render_mod.render(s, task_def.inputs)

		-- 3. Call LLM.
		local schema = preset_spec and preset_spec.output_schema or nil
		local raw_response, err = caps.llm.generate({ messages = messages, schema = schema })
		if err then return nil, err end
		if raw_response == nil then return nil, "llm returned nil response" end
		local response = raw_response --[[:! LlmResponse]]

		-- After consuming the render (which included _tool_result), clear the pending flag
		-- so next iteration drops it.
		tool_result_pending = false

		-- 4. Parse response fields.

		-- notes_add: array of {key, value} pairs.
		if type(response.notes_add) == "table" then
			local notes_add = response.notes_add --[[:! { [integer]: { key: string, value: unknown, ... }, ... }]]
			for _, entry in ipairs(notes_add) do
				local k = entry.key
				local v = entry.value
				if type(k) == "string" and k:sub(1, 1) ~= "_" then
					s = set_mod.note(s, k, v)
				end
			end
		end

		-- notes_drop: array of keys.
		if type(response.notes_drop) == "table" then
			local notes_drop = response.notes_drop --[[:! { [integer]: string, ... }]]
			for _, raw_k in ipairs(notes_drop) do
				local k = raw_k --[[:! string]]
				if type(k) == "string" and k:sub(1, 1) ~= "_" then
					s = set_mod.drop(s, k)
				end
			end
		end

		-- tool_call: execute and store result.
		if response.tool_call ~= nil then
			if caps.exec == nil then
				return nil, "tool_call in response but no exec cap provided"
			end
			local exec_fn = caps.exec --[[:! ExecCap]]
			local tc     = response.tool_call --[[:! { name: string, args: { [string]: unknown } | nil, ... }]]
			local out, terr = exec_fn(tc.name, tc.args or {})
			if terr then return nil, terr end
			s = set_mod.note(s, "_tool_result", out)
			tool_result_pending = true
		end

		-- result: task output — return immediately.
		if response.result ~= nil then
			return response.result
		end

		-- 5. Check iteration limit.
		iteration = iteration + 1
		if iteration >= max_iter then
			return nil, "max_iterations reached"
		end
	end
end

return M
