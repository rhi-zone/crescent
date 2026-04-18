if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: require "lib.taskgraph.taskgraph_types"

--:: MapInput = { tasks: { [integer]: TaskDef } }
--:: RetryInput = { task: TaskDef, max: integer | nil }
--:: RefineInput = { task: TaskDef, then_task: TaskDef }

-- map: spawn N child tasks, collect their outputs into a list.
-- input = { tasks = [{type, input}, ...] }
-- output = { results = [...] }
local function exec_map(task, ctx)
	local inp = task.input --: MapInput
	local c   = ctx        --: Context
	local ids = {}
	for i = 1, #inp.tasks do
		ids[i] = c:spawn(inp.tasks[i])
	end
	local results = {}
	for i = 1, #ids do
		results[i] = c:result(ids[i])
	end
	return { results = results }
end

-- retry: run a task up to max times, returning on first success.
-- input = { task = {type, input}, max = 3 }
-- output = whatever the inner task returns
local function exec_retry(task, ctx)
	local inp = task.input --: RetryInput
	local c   = ctx        --: Context
	local inner = inp.task
	local max   = inp.max or 3
	local last_err
	for _ = 1, max do
		local id = c:spawn(inner)
		local ok, res = pcall(c.result, c, id)
		if ok then return res end
		last_err = res
	end
	error("retry exhausted after " .. tostring(max) .. " attempts: " .. tostring(last_err))
end

-- refine: run first task, pipe its output as input to second task.
-- input = { task = {type, input}, then_task = {type, input} }
-- output = whatever then_task returns
local function exec_refine(task, ctx)
	local inp = task.input --: RefineInput
	local c   = ctx        --: Context
	local first_id  = c:spawn(inp.task)
	local first_out = c:result(first_id)
	local second_def = {
		type  = inp.then_task.type,
		input = first_out,
	}
	local second_id = c:spawn(second_def)
	return c:result(second_id)
end

M.executors = {
	map    = exec_map,
	retry  = exec_retry,
	refine = exec_refine,
}

return M
