if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

--: () -> Graph
function M.new()
	return { tasks = {}, root = nil, _seq = 0 }
end

--: (Graph, TaskDef, string | nil) -> string
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

--: (Graph, string) -> TaskNode | nil
function M.get(g, id)
	return g.tasks[id]
end

--- Iterate over all tasks in the graph (no guaranteed order).
--: (Graph) -> () -> TaskNode | nil
function M.tasks(g)
	local ids = {}
	for id in pairs(g.tasks) do ids[#ids + 1] = id end
	local n = #ids
	local i = 0
	return function()
		i = i + 1
		if i > n then return nil end
		return g.tasks[ids[i]]
	end
end

return M
