if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- lib/taskgraph/frontier — live set of pending+running tasks.
--
-- Only populated when the runtime is created with { track = true }.
-- Nodes are added on spawn and removed when a task finishes (done or error).

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

--: () -> Frontier
function M.new()
	return { _nodes = {} }
end

--: (Frontier, string, string, unknown, string | nil) -> nil
function M.add(f, id, task_type, input, parent_id)
	f._nodes[id] = {
		id        = id,
		type      = task_type,
		input     = input,
		status    = "pending",
		parent_id = parent_id,
	}
end

--: (Frontier, string) -> nil
function M.set_running(f, id)
	local n = f._nodes[id]
	if n then n.status = "running" end
end

--: (Frontier, string) -> nil
function M.remove(f, id)
	f._nodes[id] = nil
end

-- Return array of all live frontier nodes (snapshot).
--: (Frontier) -> { [integer]: FrontierNode }
function M.snapshot(f)
	local out = {}
	for _, n in pairs(f._nodes) do
		out[#out + 1] = n
	end
	return out
end

--: (Frontier) -> integer
function M.len(f)
	local c = 0
	for _ in pairs(f._nodes) do c = c + 1 end
	return c
end

return M
