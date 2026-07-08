if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/taskgraph/exec_graph — monotonic audit log of every task spawned.
--
-- Only populated when the runtime is created with { track = true }.
-- Never shrinks. Nodes record full lifecycle: pending → running → completed/failed.

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

--: () -> ExecGraph
function M.new()
	return { _nodes = {}, _order = {} }
end

--: (ExecGraph, string, string, unknown, string | nil) -> nil
function M.record(eg, id, task_type, input, parent_id)
	local node = {
		id        = id,
		type      = task_type,
		input     = input,
		output    = nil,
		status    = "pending",
		error     = nil,
		parent_id = parent_id,
		children  = {},
		dependencies = {},
	}
	eg._nodes[id] = node
	eg._order[#eg._order + 1] = id
	if parent_id then
		local p = eg._nodes[parent_id]
		if p then
			p.children[#p.children + 1] = id
		end
	end
end

--: (ExecGraph, string, string) -> nil
function M.add_dependency(eg, id, dependency_id)
	local n = eg._nodes[id]
	if not n then return end
	for i = 1, #n.dependencies do
		if n.dependencies[i] == dependency_id then return end
	end
	n.dependencies[#n.dependencies + 1] = dependency_id
end

--: (ExecGraph, string) -> nil
function M.set_running(eg, id)
	local n = eg._nodes[id]
	if n then n.status = "running" end
end

--: (ExecGraph, string, unknown) -> nil
function M.set_completed(eg, id, output)
	local n = eg._nodes[id]
	if n then n.status = "completed"; n.output = output end
end

--: (ExecGraph, string, string) -> nil
function M.set_failed(eg, id, errmsg)
	local n = eg._nodes[id]
	if n then n.status = "failed"; n.error = errmsg end
end

-- Return array of all nodes in spawn order.
--: (ExecGraph) -> { [integer]: ExecGraphNode }
function M.snapshot(eg)
	local out = {}
	for i = 1, #eg._order do
		out[i] = eg._nodes[eg._order[i]]
	end
	return out
end

--: (ExecGraph) -> integer
function M.len(eg)
	return #eg._order
end

return M
