if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local graph_mod = require("lib.orchestration.graph")

local M = {}

--:: ctx = { task_id: string }

-- forward declaration — exec.lua sets this to avoid a circular require
--: any
M._run_task = nil

--: (unknown, any, any, string) -> ctx
function M.make(g, executors, hooks, task_id)
	local ctx = {}
	ctx.task_id = task_id

	function ctx:spawn(task_def)
		return graph_mod.add(g, task_def, task_id)
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
