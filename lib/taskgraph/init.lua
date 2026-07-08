if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local exec = require("lib.taskgraph.exec")

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

M.graph      = require("lib.taskgraph.graph")
M.frontier   = require("lib.taskgraph.frontier")
M.exec_graph = require("lib.taskgraph.exec_graph")
M.combinators = require("lib.taskgraph.combinators")

-- opts:
--   on_task    fn                — hook called after each task completes
--   track      boolean           — enable frontier + exec_graph tracking
--   scaffolds  fn[]              — pre-execution hooks applied to every task def
--
-- Returns: output, graph
-- When opts.track = true, the returned graph carries a ._frontier and ._exec_graph
-- that can be inspected via M.frontier and M.exec_graph module functions.
--: (TaskDef, ExecutorFn, RunOpts | nil) -> (unknown, TrackedGraph)
function M.run(task_def, executor, opts)
	return exec.run(task_def, executor, opts)
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
