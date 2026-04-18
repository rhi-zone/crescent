if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod      = require("lib.taskgraph.graph")
local frontier_mod   = require("lib.taskgraph.frontier")
local exec_graph_mod = require("lib.taskgraph.exec_graph")

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

-- forward declaration — exec.lua sets this to avoid a circular require.
-- Always non-nil at runtime (exec.lua sets it before any task executes).
--: RunTaskFn | nil
M._run_task = nil

--: (Graph, ExecutorRegistry, Hooks, string) -> Context
function M.make(g, executors, hooks, task_id)
	local ctx = {}
	ctx.task_id = task_id

	function ctx:spawn(task_def)
		local id = graph_mod.add(g, task_def, task_id)
		-- tracking: register child in frontier and exec_graph
		if hooks.frontier then
			frontier_mod.add(hooks.frontier, id, task_def.type, task_def.input, task_id)
		end
		if hooks.exec_graph then
			exec_graph_mod.record(hooks.exec_graph, id, task_def.type, task_def.input, task_id)
		end
		return id
	end

	-- Return a live snapshot of the frontier (only available when track=true).
	--: (Context) -> { [integer]: FrontierNode }
	function ctx:frontier()
		if hooks.frontier then
			return frontier_mod.snapshot(hooks.frontier)
		end
		return {}
	end

	-- Return a snapshot of the exec_graph log (only available when track=true).
	--: (Context) -> { [integer]: ExecGraphNode }
	function ctx:exec_graph()
		if hooks.exec_graph then
			return exec_graph_mod.snapshot(hooks.exec_graph)
		end
		return {}
	end

	function ctx:result(id)
		-- Annotate as TaskNode | nil so narrowing works (known typechecker gap:
		-- locals from function call returns aren't narrowed without annotation).
		local task = graph_mod.get(g, id) --: TaskNode | nil
		if not task then error("unknown task id: " .. tostring(id)); return nil end
		if task.status == "pending" then
			-- M._run_task is always set by exec.lua before any task runs.
			if M._run_task then M._run_task(g, executors, hooks, id) end
		end
		if task.status == "error" then
			error(task.error)
		end
		return task.output
	end

	function ctx:log(msg)
		local task = graph_mod.get(g, task_id) --: TaskNode | nil
		if task then
			task.log[#task.log + 1] = msg
		end
	end

	return ctx
end

return M
