if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local exec        = require("lib.taskgraph.exec")
local combinators = require("lib.taskgraph.combinators")

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

M.graph      = require("lib.taskgraph.graph")
M.frontier   = require("lib.taskgraph.frontier")
M.exec_graph = require("lib.taskgraph.exec_graph")

-- Global executor registry.
--: ExecutorRegistry
M._registry = {}

-- Register combinators as built-in task types.
for k, v in pairs(combinators.executors) do
	M._registry[k] = v
end

--: (string, ExecutorFn) -> nil
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
-- When opts.track = true, the returned graph carries a ._frontier and ._exec_graph
-- that can be inspected via M.frontier and M.exec_graph module functions.
--: (TaskDef, RunOpts | nil) -> unknown, TrackedGraph
function M.run(task_def, opts)
	-- merge: global registry < opts.executors (opts win)
	local executors = {}
	for k, v in pairs(M._registry) do executors[k] = v end
	if opts and opts.executors then
		for k, v in pairs(opts.executors) do executors[k] = v end
	end
	return exec.run(task_def, {
		executors = executors,
		on_task   = opts and opts.on_task or nil,
		track     = opts and opts.track or nil,
		scaffolds = opts and opts.scaffolds or nil,
	})
end

-- Convenience: return frontier snapshot from a tracked graph.
-- g is the second return value of orch.run() when opts.track = true.
--: (TrackedGraph) -> { [integer]: FrontierNode }
function M.frontier_snapshot(g)
	if g._frontier then
		return M.frontier.snapshot(g._frontier)
	end
	return {}
end

-- Convenience: return exec_graph snapshot from a tracked graph.
-- g is the second return value of orch.run() when opts.track = true.
--: (TrackedGraph) -> { [integer]: ExecGraphNode }
function M.exec_graph_snapshot(g)
	if g._exec_graph then
		return M.exec_graph.snapshot(g._exec_graph)
	end
	return {}
end

return M
