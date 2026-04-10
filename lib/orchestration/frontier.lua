if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/orchestration/frontier — live set of pending+running tasks.
--
-- Only populated when the runtime is created with { track = true }.
-- Nodes are added on spawn and removed when a task finishes (done or error).

local M = {}

--:: frontier_node = { id: string, type: string, input: unknown, status: string, parent_id: string | nil }

--: () -> unknown
function M.new()
	return { _nodes = {} }
end

--: (unknown, string, string, unknown, string | nil) -> nil
function M.add(f, id, task_type, input, parent_id)
	local fn = f --: any
	fn._nodes[id] = {
		id        = id,
		type      = task_type,
		input     = input,
		status    = "pending",
		parent_id = parent_id,
	}
end

--: (unknown, string) -> nil
function M.set_running(f, id)
	local fn = f --: any
	local n = fn._nodes[id]
	if n then n.status = "running" end
end

--: (unknown, string) -> nil
function M.remove(f, id)
	local fn = f --: any
	fn._nodes[id] = nil
end

-- Return array of all live frontier nodes (snapshot).
--: (unknown) -> frontier_node[]
function M.snapshot(f)
	local fn = f --: any
	local out = {}
	for _, n in pairs(fn._nodes) do
		out[#out + 1] = n
	end
	return out
end

--: (unknown) -> integer
function M.len(f)
	local fn = f --: any
	local c = 0
	for _ in pairs(fn._nodes) do c = c + 1 end
	return c
end

return M
