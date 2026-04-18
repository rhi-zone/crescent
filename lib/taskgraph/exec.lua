if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod     = require("lib.taskgraph.graph")
local ctx_mod       = require("lib.taskgraph.context")
local frontier_mod  = require("lib.taskgraph.frontier")
local exec_graph_mod = require("lib.taskgraph.exec_graph")

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

-- Apply scaffolds (pre-execution hooks) to a task def.
-- Returns the (possibly transformed) task def.
--: ({ [integer]: Scaffold }, TaskDef) -> TaskDef
local function apply_scaffolds(scaffolds, task_def)
	local t = task_def
	for i = 1, #scaffolds do
		t = scaffolds[i](t) or t
	end
	return t
end

--: (Graph, ExecutorRegistry, Hooks, string) -> nil
function M.run_task(g, executors, hooks, task_id)
	-- Annotate as TaskNode | nil so narrowing works (known typechecker gap:
	-- locals from function call returns aren't narrowed without annotation).
	local task = graph_mod.get(g, task_id) --: TaskNode | nil
	if not task then error("unknown task id: " .. tostring(task_id)); return end

	if task.status ~= "pending" then return end

	-- Apply scaffolds before execution.
	if hooks.scaffolds and #hooks.scaffolds > 0 then
		local task_def = apply_scaffolds(hooks.scaffolds, { type = task.type, input = task.input })
		task.type  = task_def.type
		task.input = task_def.input
	end

	local executor = executors[task.type]
	if not executor then
		task.status = "error"
		task.error  = "no executor for task type: " .. tostring(task.type)
		-- tracking: mark failed in frontier and exec_graph
		if hooks.frontier  then frontier_mod.remove(hooks.frontier, task_id) end
		if hooks.exec_graph and task.error then
			exec_graph_mod.set_failed(hooks.exec_graph, task_id, task.error)
		end
		if hooks.on_task then hooks.on_task(task) end
		return
	end

	task.status = "running"
	-- tracking: mark running
	if hooks.frontier   then frontier_mod.set_running(hooks.frontier, task_id) end
	if hooks.exec_graph then exec_graph_mod.set_running(hooks.exec_graph, task_id) end

	local ctx = ctx_mod.make(g, executors, hooks, task_id)
	local ok, result = pcall(executor, task, ctx)
	if ok then
		task.status = "done"
		task.output = result
		-- tracking: mark completed
		if hooks.frontier   then frontier_mod.remove(hooks.frontier, task_id) end
		if hooks.exec_graph then exec_graph_mod.set_completed(hooks.exec_graph, task_id, result) end
	else
		task.status = "error"
		task.error  = tostring(result)
		-- tracking: mark failed
		if hooks.frontier  then frontier_mod.remove(hooks.frontier, task_id) end
		if hooks.exec_graph and task.error then
			exec_graph_mod.set_failed(hooks.exec_graph, task_id, task.error)
		end
	end
	if hooks.on_task then hooks.on_task(task) end
end

--: (TaskDef, RunOpts | nil) -> unknown, TrackedGraph
function M.run(task_def, opts)
	local executors = {}
	local track     = false
	local scaffolds = {}
	local on_task   = nil
	if opts then
		if opts.executors then
			for k, v in pairs(opts.executors) do executors[k] = v end
		end
		if opts.track then track = opts.track end
		if opts.scaffolds then scaffolds = opts.scaffolds end
		if opts.on_task then on_task = opts.on_task end
	end

	local g = graph_mod.new()
	local root_id = graph_mod.add(g, task_def, nil)
	g.root = root_id

	if track then
		local frontier   = frontier_mod.new()
		local exec_graph = exec_graph_mod.new()
		frontier_mod.add(frontier, root_id, task_def.type, task_def.input, nil)
		exec_graph_mod.record(exec_graph, root_id, task_def.type, task_def.input, nil)
		local hooks = {
			on_task    = on_task,
			scaffolds  = scaffolds,
			frontier   = frontier,
			exec_graph = exec_graph,
		}
		M.run_task(g, executors, hooks, root_id)
		local root = graph_mod.get(g, root_id) --: TaskNode | nil
		if root and root.status == "error" then error(root.error) end
		local tg = {
			tasks       = g.tasks,
			root        = g.root,
			_seq        = g._seq,
			_frontier   = frontier,
			_exec_graph = exec_graph,
		} --: TrackedGraph
		return root and root.output, tg
	else
		local hooks = {
			on_task    = on_task,
			scaffolds  = scaffolds,
			frontier   = nil,
			exec_graph = nil,
		}
		M.run_task(g, executors, hooks, root_id)
		local root = graph_mod.get(g, root_id) --: TaskNode | nil
		if root and root.status == "error" then error(root.error) end
		local tg = {
			tasks       = g.tasks,
			root        = g.root,
			_seq        = g._seq,
			_frontier   = nil,
			_exec_graph = nil,
		} --: TrackedGraph
		return root and root.output, tg
	end
end

-- wire the circular reference so context.lua can call run_task
ctx_mod._run_task = M.run_task

return M
