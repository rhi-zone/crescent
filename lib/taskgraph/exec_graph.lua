if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/taskgraph/exec_graph — monotonic audit log of every task spawned.
--
-- Only populated when the runtime is created with { track = true }.
-- Never shrinks. Nodes record full lifecycle: pending → running → completed/failed.

local M = {}

--:: exec_node = { id: string, type: string, input: unknown, output: unknown, status: string, error: string | nil, parent_id: string | nil, children: string[] }

--: () -> unknown
function M.new()
	return { _nodes = {}, _order = {} }
end

--: (unknown, string, string, unknown, string | nil) -> nil
function M.record(eg, id, task_type, input, parent_id)
	local e = eg --: any
	local node = {
		id        = id,
		type      = task_type,
		input     = input,
		output    = nil,
		status    = "pending",
		error     = nil,
		parent_id = parent_id,
		children  = {},
	}
	e._nodes[id] = node
	e._order[#e._order + 1] = id
	if parent_id then
		local p = e._nodes[parent_id]
		if p then
			p.children[#p.children + 1] = id
		end
	end
end

--: (unknown, string) -> nil
function M.set_running(eg, id)
	local e = eg --: any
	local n = e._nodes[id]
	if n then n.status = "running" end
end

--: (unknown, string, unknown) -> nil
function M.set_completed(eg, id, output)
	local e = eg --: any
	local n = e._nodes[id]
	if n then n.status = "completed"; n.output = output end
end

--: (unknown, string, string) -> nil
function M.set_failed(eg, id, errmsg)
	local e = eg --: any
	local n = e._nodes[id]
	if n then n.status = "failed"; n.error = errmsg end
end

-- Return array of all nodes in spawn order.
--: (unknown) -> exec_node[]
function M.snapshot(eg)
	local e = eg --: any
	local out = {}
	for i = 1, #e._order do
		out[i] = e._nodes[e._order[i]]
	end
	return out
end

--: (unknown) -> integer
function M.len(eg)
	local e = eg --: any
	return #e._order
end

return M
