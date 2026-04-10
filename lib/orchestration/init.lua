if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local exec        = require("lib.orchestration.exec")
local combinators = require("lib.orchestration.combinators")

local M = {}

M.graph      = require("lib.orchestration.graph")
M.frontier   = require("lib.orchestration.frontier")
M.exec_graph = require("lib.orchestration.exec_graph")

-- Global executor registry.
M._registry = {}

-- Register combinators as built-in task types.
for k, v in pairs(combinators.executors) do
	M._registry[k] = v
end

--: (string, (task: unknown, ctx: unknown) -> unknown) -> nil
function M.register(type_name, fn)
	M._registry[type_name] = fn
end

-- opts:
--   executors  { [string]: fn }  — inline executors (override global registry)
--   on_task    fn                — hook called after each task completes
--   track      boolean           — enable frontier + exec_graph tracking
--   scaffolds  fn[]              — pre-execution hooks applied to every task def
--
-- Returns: output, graph
-- When opts.track = true, the returned graph carries a .frontier and .exec_graph
-- that can be inspected via M.frontier and M.exec_graph module functions.
--: (unknown, any | nil) -> unknown, unknown
function M.run(task_def, opts)
	opts = opts or {}
	local opts_any = opts --: any
	-- merge: global registry < opts.executors (opts win)
	local executors = {}
	for k, v in pairs(M._registry) do executors[k] = v end
	if opts_any.executors then
		for k, v in pairs(opts_any.executors) do executors[k] = v end
	end
	return exec.run(task_def, {
		executors = executors,
		on_task   = opts_any.on_task,
		track     = opts_any.track,
		scaffolds = opts_any.scaffolds,
	})
end

-- Convenience: return frontier snapshot from a tracked graph.
-- g is the second return value of orch.run() when opts.track = true.
--: (unknown) -> frontier_node[]
function M.frontier_snapshot(g)
	local ga = g --: any
	if ga._frontier then
		return M.frontier.snapshot(ga._frontier)
	end
	return {}
end

-- Convenience: return exec_graph snapshot from a tracked graph.
-- g is the second return value of orch.run() when opts.track = true.
--: (unknown) -> exec_node[]
function M.exec_graph_snapshot(g)
	local ga = g --: any
	if ga._exec_graph then
		return M.exec_graph.snapshot(ga._exec_graph)
	end
	return {}
end

return M
