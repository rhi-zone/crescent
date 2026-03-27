if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- map: spawn N child tasks, collect their outputs into a list.
-- input = { tasks = [{type, input}, ...] }
-- output = { results = [...] }
local function exec_map(task, ctx)
	local ids = {}
	for i = 1, #task.input.tasks do
		ids[i] = ctx:spawn(task.input.tasks[i])
	end
	local results = {}
	for i = 1, #ids do
		results[i] = ctx:result(ids[i])
	end
	return { results = results }
end

-- retry: run a task up to max times, returning on first success.
-- input = { task = {type, input}, max = 3 }
-- output = whatever the inner task returns
local function exec_retry(task, ctx)
	local inner = task.input.task
	local max   = task.input.max or 3
	local last_err
	for _ = 1, max do
		local id = ctx:spawn(inner)
		local ok, res = pcall(ctx.result, ctx, id)
		if ok then return res end
		last_err = res
	end
	error("retry exhausted after " .. max .. " attempts: " .. tostring(last_err))
end

-- refine: run first task, pipe its output as input to second task.
-- input = { task = {type, input}, then_task = {type, input} }
-- output = whatever then_task returns
local function exec_refine(task, ctx)
	local first_id = ctx:spawn(task.input.task)
	local first_out = ctx:result(first_id)
	local second_def = {
		type  = task.input.then_task.type,
		input = first_out,
	}
	local second_id = ctx:spawn(second_def)
	return ctx:result(second_id)
end

M.executors = {
	map    = exec_map,
	retry  = exec_retry,
	refine = exec_refine,
}

return M
