if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- map: spawn N child tasks, collect their outputs into a list.
-- input = { tasks = [{type, input}, ...] }
-- output = { results = [...] }
local function exec_map(task, ctx)
	-- executor params are any — inputs are caller-defined, ctx is a dynamic object
	local inp = task.input --: any
	local c   = ctx        --: any
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
	-- executor params are any — inputs are caller-defined, ctx is a dynamic object
	local inp = task.input --: any
	local c   = ctx        --: any
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
	-- executor params are any — inputs are caller-defined, ctx is a dynamic object
	local inp = task.input --: any
	local c   = ctx        --: any
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
