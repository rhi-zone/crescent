-- lib/nanites — task graph executor with dynamic spawning, frontier, exec_graph.
--
-- Design:
--   Task      = plain Lua table { type, config, input, ... }
--   Executor  = function(task, ctx) -> output  (registered by task.type)
--   Scaffold  = function(task) -> task          (pre-execution hook)
--   Ctx       = object passed to each executor; exposes spawn/result/spawn_all
--   Frontier  = live set of pending+running tasks
--   ExecGraph = monotonic audit log of every task ever spawned
--
-- Concurrency model:
--   LuaJIT coroutines are cooperative, not truly parallel.
--   ctx:spawn(task_def) creates a coroutine for the child and registers it.
--   ctx:result(handle)  drives the coroutine to completion (depth-first),
--   resuming the child until it finishes, then returning its output.
--   This gives correct sequential semantics and full parent→child lineage
--   without threads. True async (epoll, HTTP) is a follow-on.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ─── IDs ─────────────────────────────────────────────────────────────────────

local _next_id = 0
local function new_id()
	_next_id = _next_id + 1
	return _next_id
end

-- ─── ExecGraph ───────────────────────────────────────────────────────────────
-- Monotonically-growing audit log. Never shrinks.

--:: exec_node = { id: integer, type: string, config: unknown, input: unknown, output: unknown, status: string, error: string | nil, parent: integer | nil, children: integer[] }

local ExecGraph = {}
ExecGraph.__index = ExecGraph

function ExecGraph.new()
	return setmetatable({ _nodes = {}, _order = {} }, ExecGraph)
end

-- Record a new spawned task (called before execution begins).
--: (ExecGraph, integer, string, unknown, unknown, integer | nil) -> nil
function ExecGraph:record(id, task_type, config, input, parent_id)
	local node = {
		id       = id,
		type     = task_type,
		config   = config,
		input    = input,
		output   = nil,
		status   = "pending",
		error    = nil,
		parent   = parent_id,
		children = {},
	}
	self._nodes[id] = node
	self._order[#self._order + 1] = id
	if parent_id then
		local p = self._nodes[parent_id]
		if p then
			p.children[#p.children + 1] = id
		end
	end
end

function ExecGraph:_get(id) return self._nodes[id] end

function ExecGraph:set_running(id)
	local n = self._nodes[id]
	if n then n.status = "running" end
end

function ExecGraph:set_completed(id, output)
	local n = self._nodes[id]
	if n then n.status = "completed"; n.output = output end
end

function ExecGraph:set_failed(id, errmsg)
	local n = self._nodes[id]
	if n then n.status = "failed"; n.error = errmsg end
end

function ExecGraph:set_cancelled(id)
	local n = self._nodes[id]
	if n then n.status = "cancelled" end
end

-- Return array of all nodes in spawn order.
--: (ExecGraph) -> exec_node[]
function ExecGraph:snapshot()
	local out = {}
	for i = 1, #self._order do
		out[i] = self._nodes[self._order[i]]
	end
	return out
end

function ExecGraph:len() return #self._order end

-- ─── Frontier ────────────────────────────────────────────────────────────────
-- Live set of pending+running tasks.

--:: frontier_node = { id: integer, type: string, config: unknown, input: unknown, status: string, parent: integer | nil, children: integer[] }

local Frontier = {}
Frontier.__index = Frontier

function Frontier.new()
	return setmetatable({ _nodes = {} }, Frontier)
end

function Frontier:add(id, task_type, config, input, parent_id)
	self._nodes[id] = {
		id       = id,
		type     = task_type,
		config   = config,
		input    = input,
		status   = "pending",
		parent   = parent_id,
		children = {},
	}
	if parent_id and self._nodes[parent_id] then
		local p = self._nodes[parent_id]
		p.children[#p.children + 1] = id
	end
end

function Frontier:set_running(id)
	local n = self._nodes[id]
	if n then n.status = "running" end
end

function Frontier:remove(id)
	self._nodes[id] = nil
end

-- Return array of all live frontier nodes.
--: (Frontier) -> frontier_node[]
function Frontier:snapshot()
	local out = {}
	for _, n in pairs(self._nodes) do
		out[#out + 1] = n
	end
	return out
end

function Frontier:len()
	local c = 0
	for _ in pairs(self._nodes) do c = c + 1 end
	return c
end

-- ─── Handle ──────────────────────────────────────────────────────────────────
-- Returned by ctx:spawn; resolved by ctx:result.

local Handle = {}
Handle.__index = Handle

-- state: "pending" | "running" | "done" | "error"
function Handle.new(id, co)
	return setmetatable({ id = id, _co = co, _state = "pending", _value = nil }, Handle)
end

-- ─── Ctx ─────────────────────────────────────────────────────────────────────

local Ctx = {}
Ctx.__index = Ctx

-- Internal constructor. rt is the Runtime table (shared state).
function Ctx._new(rt, node_id)
	return setmetatable({ _rt = rt, _node_id = node_id }, Ctx)
end

-- Spawn a child task. Returns a Handle (opaque).
--: (Ctx, unknown) -> Handle
function Ctx:spawn(task_def)
	return self._rt:_spawn(task_def, self._node_id)
end

-- Spawn multiple child tasks. Returns array of Handles.
--: (Ctx, unknown[]) -> Handle[]
function Ctx:spawn_all(task_defs)
	local handles = {}
	for i = 1, #task_defs do
		handles[i] = self:spawn(task_defs[i])
	end
	return handles
end

-- Block (cooperatively) until the handle's task is complete. Returns output.
-- Errors if the child failed (propagates the child's error message).
--: (Ctx, Handle) -> unknown
function Ctx:result(handle)
	return self._rt:_drive(handle)
end

-- ─── Runtime ─────────────────────────────────────────────────────────────────

local Runtime = {}
Runtime.__index = Runtime

--: ({ executors: { [string]: (unknown, Ctx) -> unknown } | nil, scaffolds: ((unknown) -> unknown)[] | nil }) -> Runtime
function M.runtime(opts)
	opts = opts or {}
	local o = opts --: any
	local rt = setmetatable({
		_executors  = o.executors  or {},
		_scaffolds  = o.scaffolds  or {},
		_exec_graph = ExecGraph.new(),
		_frontier   = Frontier.new(),
	}, Runtime)
	return rt
end

-- Apply scaffolds to a task def. Returns (possibly transformed) task def.
function Runtime:_apply_scaffolds(task_def)
	local t = task_def
	for i = 1, #self._scaffolds do
		t = self._scaffolds[i](t) or t
	end
	return t
end

-- Internal: create a Handle+coroutine for a task def.
--: (Runtime, unknown, integer | nil) -> Handle
function Runtime:_spawn(task_def, parent_id)
	local td = task_def --: any
	local task_type = td.type
	local config    = td.config
	local input     = td.input

	-- Apply scaffolds before registering.
	task_def = self:_apply_scaffolds(task_def)
	td = task_def --: any
	task_type = td.type or task_type
	config    = td.config or config
	input     = td.input

	local id = new_id()

	-- Register in both frontier and exec_graph before execution.
	self._frontier:add(id, task_type, config, input, parent_id)
	self._exec_graph:record(id, task_type, config, input, parent_id)

	local executor = self._executors[task_type]

	-- Build the coroutine body.
	local rt = self
	local co = coroutine.create(function()
		if not executor then
			error("no executor for task type: " .. tostring(task_type))
		end
		local ctx = Ctx._new(rt, id)
		-- Mark running in both frontier and exec_graph.
		rt._frontier:set_running(id)
		rt._exec_graph:set_running(id)
		-- Executors may error(); runtime catches via pcall inside _drive.
		return executor(task_def, ctx)
	end)

	return Handle.new(id, co)
end

-- Internal: drive a handle's coroutine to completion.
-- Returns output or propagates error.
--: (Runtime, Handle) -> unknown
function Runtime:_drive(handle)
	-- Already resolved?
	if handle._state == "done" then
		return handle._value
	end
	if handle._state == "error" then
		error(handle._value, 2)
	end

	local id = handle.id
	local co = handle._co

	-- Drive the coroutine. Since ctx:result internally calls _drive on child
	-- handles (which resumes them), and coroutines are cooperative, we get a
	-- depth-first traversal: when a parent calls ctx:result(child_handle),
	-- _drive runs the child to completion before returning.
	--
	-- The coroutine may itself call ctx:result on grandchildren, which
	-- recursively drives them first — this works because each _drive call is
	-- a direct function call in the same OS thread, not a yield.
	--
	-- A coroutine "yields" if its executor itself calls coroutine.yield()
	-- (e.g. for async I/O). For now executors are synchronous; the framework
	-- is structured to allow future integration.

	while true do
		local ok, val = coroutine.resume(co)
		local status  = coroutine.status(co)

		if status == "dead" then
			-- coroutine finished (either returned or threw)
			if ok then
				-- val is the return value of the coroutine body
				handle._state = "done"
				handle._value = val
				self._frontier:remove(id)
				self._exec_graph:set_completed(id, val)
				return val
			else
				-- val is the error message
				local errmsg = tostring(val)
				handle._state = "error"
				handle._value = errmsg
				self._frontier:remove(id)
				self._exec_graph:set_failed(id, errmsg)
				error(errmsg, 2)
			end
		elseif status == "suspended" then
			-- Executor yielded (future async integration point).
			-- For now, just resume immediately.
			-- (This path is not exercised by synchronous executors.)
		else
			-- "running" or "normal" — shouldn't occur from outside.
			break
		end
	end

	-- Should be unreachable in normal operation.
	error("internal: unexpected coroutine state for task " .. tostring(id))
end

-- Run a task definition to completion (blocking). Returns (true, output) or (nil, errmsg).
--: (Runtime, unknown) -> boolean | nil, unknown
function Runtime:run(task_def)
	local handle = self:_spawn(task_def, nil)
	local ok, result = pcall(self._drive, self, handle)
	if ok then
		return true, result
	else
		return nil, result
	end
end

-- Return a snapshot of the live frontier (array of frontier_node).
--: (Runtime) -> frontier_node[]
function Runtime:frontier()
	return self._frontier:snapshot()
end

-- Return a snapshot of the exec_graph (array of exec_node, in spawn order).
--: (Runtime) -> exec_node[]
function Runtime:exec_graph()
	return self._exec_graph:snapshot()
end

-- ─── Built-in executors ───────────────────────────────────────────────────────

-- exec_map: spawn N child tasks from task.input.tasks, collect results.
-- task.input = { tasks = [{type, ...}, ...] }
-- output = { results = [...] }
local function exec_map(task, ctx)
	local t   = task --: any
	local inp = t.input --: any
	local task_defs = inp.tasks
	local handles = ctx:spawn_all(task_defs)
	local results = {}
	for i = 1, #handles do
		results[i] = ctx:result(handles[i])
	end
	return { results = results }
end

M.exec_map = exec_map

return M
