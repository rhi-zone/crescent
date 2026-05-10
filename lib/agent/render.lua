if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local set_mod = require("lib.agent.set")
local json_mod = require("lib.format.json")

local M = {}

--:: RenderMessage = { role: string, content: string }

-- Serialize a value to a human-readable string.
-- Tables become JSON; everything else becomes tostring.
--: (unknown) -> string
local function val_to_str(v)
	if type(v) == "table" then
		local s, _ = json_mod.encode(v)
		return s or tostring(v)
	end
	return tostring(v)
end

-- Render a set into a messages array for an LLM call.
-- task_inputs is the current task's inputs (injected into user turn).
--: (AgentSet, unknown) -> RenderMessage[]
function M.render(s, task_inputs)
	local messages = {} --: RenderMessage[]

	-- System turn: only if _system is present.
	local system_val = set_mod.get(s, "_system")
	if system_val ~= nil then
		messages[#messages + 1] = { role = "system", content = val_to_str(system_val) }
	end

	-- User turn: task inputs + notes.
	local user_lines = {}

	-- Task inputs section.
	if task_inputs ~= nil then
		if type(task_inputs) == "table" then
			-- Sort input keys for determinism.
			local input_keys = {}
			for k in pairs(task_inputs) do input_keys[#input_keys + 1] = k end
			table.sort(input_keys)
			for _, k in ipairs(input_keys) do
				local v = task_inputs[k]
				if v ~= nil then
					user_lines[#user_lines + 1] = tostring(k) .. ": " .. val_to_str(v)
				end
			end
		else
			user_lines[#user_lines + 1] = val_to_str(task_inputs)
		end
	end

	-- Notes: all non-reserved keys, sorted alphabetically.
	local note_keys = {}
	for _, k in ipairs(set_mod.keys(s)) do
		if k:sub(1, 1) ~= "_" then
			note_keys[#note_keys + 1] = k
		end
	end

	if #note_keys > 0 then
		user_lines[#user_lines + 1] = "notes:"
		for _, k in ipairs(note_keys) do
			user_lines[#user_lines + 1] = "- " .. k .. ": " .. val_to_str(set_mod.get(s, k))
		end
	end

	-- Always emit a user turn (even if empty).
	messages[#messages + 1] = { role = "user", content = table.concat(user_lines, "\n") }

	-- Tool result turn: final user turn if _tool_result is set.
	local tool_result = set_mod.get(s, "_tool_result")
	if tool_result ~= nil then
		messages[#messages + 1] = {
			role    = "user",
			content = "tool result:\n" .. val_to_str(tool_result),
		}
	end

	return messages
end

return M
