if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod      = require("lib.taskgraph.graph")
local frontier_mod   = require("lib.taskgraph.frontier")
local exec_graph_mod = require("lib.taskgraph.exec_graph")

local M = {}

--:: ctx = { task_id: string }

-- forward declaration — exec.lua sets this to avoid a circular require
--: any
M._run_task = nil

--: (unknown, any, any, string) -> ctx
function M.make(g, executors, hooks, task_id)
	local ctx = {}
	ctx.task_id = task_id
	local hooks_any = hooks --: any

	function ctx:spawn(task_def)
		local id = graph_mod.add(g, task_def, task_id)
		-- tracking: register child in frontier and exec_graph
		if hooks_any then
			local td = task_def --: any
			if hooks_any.frontier then
				frontier_mod.add(hooks_any.frontier, id, td.type, td.input, task_id)
			end
			if hooks_any.exec_graph then
				exec_graph_mod.record(hooks_any.exec_graph, id, td.type, td.input, task_id)
			end
		end
		return id
	end

	-- Return a live snapshot of the frontier (only available when track=true).
	--: (ctx) -> frontier_node[]
	function ctx:frontier()
		if hooks_any and hooks_any.frontier then
			return frontier_mod.snapshot(hooks_any.frontier)
		end
		return {}
	end

	-- Return a snapshot of the exec_graph log (only available when track=true).
	--: (ctx) -> exec_node[]
	function ctx:exec_graph()
		if hooks_any and hooks_any.exec_graph then
			return exec_graph_mod.snapshot(hooks_any.exec_graph)
		end
		return {}
	end

	function ctx:result(id)
		local task = graph_mod.get(g, id)
		if not task then error("unknown task id: " .. tostring(id)) end
		if task.status == "pending" then
			M._run_task(g, executors, hooks, id)
		end
		if task.status == "error" then
			error(task.error)
		end
		return task.output
	end

	function ctx:log(msg)
		local task = graph_mod.get(g, task_id)
		if task then
			task.log[#task.log + 1] = msg
		end
	end

	return ctx
end

return M
