if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod = require("lib.orchestration.graph")
local ctx_mod   = require("lib.orchestration.context")

local M = {}

--: (unknown, any, any, string) -> nil
function M.run_task(g, executors, hooks, task_id)
	local task = graph_mod.get(g, task_id)
	if not task then error("unknown task id: " .. tostring(task_id)) end
	if task.status ~= "pending" then return end

	local executor = executors[task.type] --: any
	if not executor then
		task.status = "error"
		task.error  = "no executor for task type: " .. tostring(task.type)
		if hooks and hooks.on_task then hooks.on_task(task) end
		return
	end

	task.status = "running"
	local ctx = ctx_mod.make(g, executors, hooks, task_id)
	local ok, result = pcall(executor, task, ctx)
	if ok then
		task.status = "done"
		task.output = result
	else
		task.status = "error"
		task.error  = tostring(result)
	end
	if hooks and hooks.on_task then hooks.on_task(task) end
end

--: (unknown, any?) -> unknown, unknown
function M.run(task_def, opts)
	opts = opts or {}
	local opts_any  = opts --: any
	local executors = opts_any.executors or {}
	local hooks     = { on_task = opts_any.on_task }

	local g = graph_mod.new()
	local root_id = graph_mod.add(g, task_def, nil)
	g.root = root_id

	M.run_task(g, executors, hooks, root_id)

	local root = graph_mod.get(g, root_id)
	if root.status == "error" then
		error(root.error)
	end
	return root.output, g
end

-- wire the circular reference so context.lua can call run_task
ctx_mod._run_task = M.run_task

return M
