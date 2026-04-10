if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod     = require("lib.taskgraph.graph")
local ctx_mod       = require("lib.taskgraph.context")
local frontier_mod  = require("lib.taskgraph.frontier")
local exec_graph_mod = require("lib.taskgraph.exec_graph")

local M = {}

-- Apply scaffolds (pre-execution hooks) to a task def.
-- Returns the (possibly transformed) task def.
--: (((unknown) -> unknown)[], unknown) -> unknown
local function apply_scaffolds(scaffolds, task_def)
	local t = task_def
	for i = 1, #scaffolds do
		t = scaffolds[i](t) or t
	end
	return t
end

--: (unknown, any, any, string) -> nil
function M.run_task(g, executors, hooks, task_id)
	local task = graph_mod.get(g, task_id)
	if not task then error("unknown task id: " .. tostring(task_id)) end
	if task.status ~= "pending" then return end

	local hooks_any = hooks --: any

	-- Apply scaffolds before execution.
	local scaffolds = hooks_any and hooks_any.scaffolds
	if scaffolds and #scaffolds > 0 then
		local task_def = { type = task.type, input = task.input }
		task_def = apply_scaffolds(scaffolds, task_def)
		local td = task_def --: any
		task.type  = td.type  or task.type
		task.input = td.input
	end

	local executor = executors[task.type] --: any
	if not executor then
		task.status = "error"
		task.error  = "no executor for task type: " .. tostring(task.type)
		-- tracking: mark failed in frontier and exec_graph
		if hooks_any then
			if hooks_any.frontier  then frontier_mod.remove(hooks_any.frontier, task_id) end
			if hooks_any.exec_graph then exec_graph_mod.set_failed(hooks_any.exec_graph, task_id, task.error) end
		end
		if hooks_any and hooks_any.on_task then hooks_any.on_task(task) end
		return
	end

	task.status = "running"
	-- tracking: mark running
	if hooks_any then
		if hooks_any.frontier   then frontier_mod.set_running(hooks_any.frontier, task_id) end
		if hooks_any.exec_graph then exec_graph_mod.set_running(hooks_any.exec_graph, task_id) end
	end

	local ctx = ctx_mod.make(g, executors, hooks, task_id)
	local ok, result = pcall(executor, task, ctx)
	if ok then
		task.status = "done"
		task.output = result
		-- tracking: mark completed
		if hooks_any then
			if hooks_any.frontier   then frontier_mod.remove(hooks_any.frontier, task_id) end
			if hooks_any.exec_graph then exec_graph_mod.set_completed(hooks_any.exec_graph, task_id, result) end
		end
	else
		task.status = "error"
		task.error  = tostring(result)
		-- tracking: mark failed
		if hooks_any then
			if hooks_any.frontier   then frontier_mod.remove(hooks_any.frontier, task_id) end
			if hooks_any.exec_graph then exec_graph_mod.set_failed(hooks_any.exec_graph, task_id, task.error) end
		end
	end
	if hooks_any and hooks_any.on_task then hooks_any.on_task(task) end
end

--: (unknown, any | nil) -> unknown, unknown
function M.run(task_def, opts)
	opts = opts or {}
	local opts_any  = opts --: any
	local executors = opts_any.executors or {}
	local track     = opts_any.track
	local scaffolds = opts_any.scaffolds or {}

	local frontier   = track and frontier_mod.new()   or nil
	local exec_graph = track and exec_graph_mod.new() or nil

	local hooks = {
		on_task     = opts_any.on_task,
		scaffolds   = scaffolds,
		frontier    = frontier,
		exec_graph  = exec_graph,
	}

	local g = graph_mod.new()
	local root_id = graph_mod.add(g, task_def, nil)
	g.root = root_id

	-- tracking: record root task before execution and attach to graph for caller access
	if track then
		local td = task_def --: any
		frontier_mod.add(frontier, root_id, td.type, td.input, nil)
		exec_graph_mod.record(exec_graph, root_id, td.type, td.input, nil)
		g._frontier   = frontier
		g._exec_graph = exec_graph
	end

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
