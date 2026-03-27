if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: task_status = "pending" | "running" | "done" | "error"

--: () -> graph
function M.new()
	return { tasks = {}, root = nil, _seq = 0 }
end

--: (graph, table, string?) -> string
function M.add(g, task_def, parent_id)
	g._seq = g._seq + 1
	local id = "task_" .. g._seq
	local task = {
		id        = id,
		type      = task_def.type,
		input     = task_def.input,
		parent_id = parent_id,
		status    = "pending",
		output    = nil,
		error     = nil,
		spawned   = {},
		log       = {},
	}
	g.tasks[id] = task
	if parent_id then
		local parent = g.tasks[parent_id]
		if parent then
			parent.spawned[#parent.spawned + 1] = id
		end
	end
	return id
end

--: (graph, string) -> table?
function M.get(g, id)
	return g.tasks[id]
end

--: (graph) -> () -> table?
function M.tasks(g)
	local ids = {}
	for id in pairs(g.tasks) do ids[#ids + 1] = id end
	local i = 0
	return function()
		i = i + 1
		return g.tasks[ids[i]]
	end
end

return M
