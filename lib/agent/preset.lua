if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local set_mod  = require("lib.agent.set")
local leaf_mod = require("lib.agent.leaf")

local M = {}

--:: AgentCaps = { llm: { generate: (req: { [string]: unknown }) -> (unknown, string | nil) }, exec: any | nil }

--:: PresetSpec = {
--::   input_schema: unknown,
--::   output_schema: unknown,
--::   system: string | nil,
--::   max_iterations: integer | nil,
--::   executor_fn: ((inputs: unknown, caps: AgentCaps) -> (unknown, string | nil)) | nil,
--:: }

-- Module-level registry (not global).
--: { [string]: PresetSpec }
local registry = {}

-- Register a named preset.
--: (string, PresetSpec) -> nil
function M.register(name, spec)
	registry[name] = spec
end

-- Run a named preset with given inputs and caps.
-- Returns preset output or nil+errmsg.
--: (string, unknown, AgentCaps) -> (unknown, string | nil)
function M.run(name, inputs, caps)
	local spec = registry[name]
	if not spec then
		return nil, "preset not registered: " .. tostring(name)
	end

	-- If the preset provides its own executor function, delegate entirely.
	if spec.executor_fn then
		return spec.executor_fn(inputs, caps)
	end

	-- Build initial set: inject _system if present.
	local s = set_mod.new()
	if spec.system ~= nil then
		s = set_mod.note(s, "_system", spec.system)
	end

	-- Build task_def.
	local task_def = {
		type           = name,
		inputs         = inputs,
		max_iterations = spec.max_iterations,
	}

	--: any
	local spec_any = spec
	--: any
	local caps_any = caps
	return leaf_mod.run(task_def, s, caps_any, spec_any)
end

return M
