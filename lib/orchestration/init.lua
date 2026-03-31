if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local exec        = require("lib.orchestration.exec")
local combinators = require("lib.orchestration.combinators")

local M = {}

M.graph = require("lib.orchestration.graph")

-- Global executor registry.
M._registry = {}

-- Register combinators as built-in task types.
for k, v in pairs(combinators.executors) do
	M._registry[k] = v
end

--: (string, (task: unknown, ctx: unknown) -> unknown) -> nil
function M.register(type_name, fn)
	M._registry[type_name] = fn
end

--: (unknown, any | nil) -> unknown, unknown
function M.run(task_def, opts)
	opts = opts or {}
	local opts_any = opts --: any
	-- merge: global registry < opts.executors (opts win)
	local executors = {}
	for k, v in pairs(M._registry) do executors[k] = v end
	if opts_any.executors then
		for k, v in pairs(opts_any.executors) do executors[k] = v end
	end
	return exec.run(task_def, {
		executors = executors,
		on_task   = opts_any.on_task,
	})
end

return M
