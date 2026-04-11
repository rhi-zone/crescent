if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Value ID counter per function
local function make_counter()
	return { n = 0 }
end

local function next_id(counter)
	counter.n = counter.n + 1
	return "%" .. counter.n
end

---------------------------------------------------------------------------
-- Instruction
---------------------------------------------------------------------------

--:: Instruction = { id: string, op: string, args: { [number]: unknown }, block_name: string }

local Instruction = {}
Instruction.__index = Instruction

local function new_instruction(id, op, args, block_name)
	return setmetatable({ id = id, op = op, args = args, block_name = block_name }, Instruction)
end

---------------------------------------------------------------------------
-- Block
---------------------------------------------------------------------------

--:: Block = { name: string, _instrs: { [number]: Instruction }, _func: Func }

local Block = {}
Block.__index = Block

local function new_block(name, func)
	return setmetatable({ name = name, _instrs = {}, _func = func }, Block)
end

function Block:_add(op, args)
	local id = next_id(self._func._counter)
	local instr = new_instruction(id, op, args, self.name)
	self._instrs[#self._instrs + 1] = instr
	return id
end

function Block:const(value)
	return self:_add("const", { value })
end

function Block:param(name)
	return self:_add("param", { name })
end

function Block:add(a, b) return self:_add("add", { a, b }) end
function Block:sub(a, b) return self:_add("sub", { a, b }) end
function Block:mul(a, b) return self:_add("mul", { a, b }) end
function Block:div(a, b) return self:_add("div", { a, b }) end
function Block:mod(a, b) return self:_add("mod", { a, b }) end

function Block:cmp(cmp_op, a, b)
	return self:_add("cmp", { cmp_op, a, b })
end

function Block:phi(...)
	local edges = { ... }
	return self:_add("phi", edges)
end

function Block:call(fn_val, ...)
	local call_args = { fn_val, ... }
	return self:_add("call", call_args)
end

function Block:copy(val)
	return self:_add("copy", { val })
end

function Block:br(cond, true_block, false_block)
	local instr = new_instruction(nil, "br", { cond, true_block.name, false_block.name }, self.name)
	self._instrs[#self._instrs + 1] = instr
end

function Block:jmp(target_block)
	local instr = new_instruction(nil, "jmp", { target_block.name }, self.name)
	self._instrs[#self._instrs + 1] = instr
end

function Block:ret(val)
	local instr = new_instruction(nil, "ret", { val }, self.name)
	self._instrs[#self._instrs + 1] = instr
end

function Block:instructions()
	local out = {}
	for i = 1, #self._instrs do
		out[i] = self._instrs[i]
	end
	return out
end

function Block:successors()
	local out = {}
	if #self._instrs == 0 then return out end
	local last = self._instrs[#self._instrs]
	if last.op == "br" then
		-- args: {cond, true_name, false_name}
		local func = self._func
		out[#out + 1] = func._block_map[last.args[2]]
		out[#out + 1] = func._block_map[last.args[3]]
	elseif last.op == "jmp" then
		local func = self._func
		out[#out + 1] = func._block_map[last.args[1]]
	end
	return out
end

function Block:predecessors()
	local out = {}
	local func = self._func
	for i = 1, #func._blocks do
		local b = func._blocks[i]
		local succs = b:successors()
		for j = 1, #succs do
			if succs[j].name == self.name then
				out[#out + 1] = b
				break
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- CFG
---------------------------------------------------------------------------

--:: CFG = { _func: Func }

local CFG = {}
CFG.__index = CFG

function CFG:postorder()
	local visited = {}
	local order = {}
	local func = self._func

	local function dfs(block)
		if visited[block.name] then return end
		visited[block.name] = true
		local succs = block:successors()
		for i = 1, #succs do
			dfs(succs[i])
		end
		order[#order + 1] = block.name
	end

	if #func._blocks > 0 then
		dfs(func._blocks[1])
	end
	-- reverse for reverse postorder
	local rpo = {}
	for i = #order, 1, -1 do
		rpo[#rpo + 1] = order[i]
	end
	return rpo
end

function CFG:dominators()
	local func = self._func
	if #func._blocks == 0 then return {} end

	local rpo = self:postorder() -- reverse postorder
	-- Map block name to RPO index
	local rpo_idx = {}
	for i = 1, #rpo do
		rpo_idx[rpo[i]] = i
	end

	local doms = {}
	local entry_name = rpo[1]
	doms[entry_name] = entry_name

	-- Intersect function for dominator computation
	local function intersect(b1, b2)
		local f1, f2 = b1, b2
		while f1 ~= f2 do
			while rpo_idx[f1] > rpo_idx[f2] do
				f1 = doms[f1]
			end
			while rpo_idx[f2] > rpo_idx[f1] do
				f2 = doms[f2]
			end
		end
		return f1
	end

	local changed = true
	while changed do
		changed = false
		for i = 2, #rpo do
			local b_name = rpo[i]
			local b = func._block_map[b_name]
			local preds = b:predecessors()
			local new_idom = nil
			-- Find first processed predecessor
			for j = 1, #preds do
				if doms[preds[j].name] then
					new_idom = preds[j].name
					break
				end
			end
			if new_idom then
				for j = 1, #preds do
					local p = preds[j].name
					if p ~= new_idom and doms[p] then
						new_idom = intersect(new_idom, p)
					end
				end
				if doms[b_name] ~= new_idom then
					doms[b_name] = new_idom
					changed = true
				end
			end
		end
	end

	-- Remove self-domination for entry
	doms[entry_name] = nil
	return doms
end

---------------------------------------------------------------------------
-- Func
---------------------------------------------------------------------------

--:: Func = { name: string, params: { [number]: string }, _blocks: { [number]: Block }, _block_map: { [string]: Block }, _counter: { n: number } }

local Func = {}
Func.__index = Func

local function new_func(name, params)
	return setmetatable({
		name = name,
		params = params or {},
		_blocks = {},
		_block_map = {},
		_counter = make_counter(),
	}, Func)
end

function Func:block(name)
	local b = new_block(name, self)
	self._blocks[#self._blocks + 1] = b
	self._block_map[name] = b
	return b
end

function Func:blocks()
	local out = {}
	for i = 1, #self._blocks do
		out[i] = self._blocks[i]
	end
	return out
end

function Func:cfg()
	return setmetatable({ _func = self }, CFG)
end

function Func:dump()
	local lines = {}
	lines[#lines + 1] = "func " .. self.name .. "(" .. table.concat(self.params, ", ") .. "):"
	for bi = 1, #self._blocks do
		local blk = self._blocks[bi]
		lines[#lines + 1] = "  " .. blk.name .. ":"
		for ii = 1, #blk._instrs do
			local instr = blk._instrs[ii]
			local s
			if instr.op == "const" then
				s = "    " .. instr.id .. " = const " .. tostring(instr.args[1])
			elseif instr.op == "param" then
				s = "    " .. instr.id .. " = param " .. instr.args[1]
			elseif instr.op == "add" or instr.op == "sub" or instr.op == "mul"
				or instr.op == "div" or instr.op == "mod" then
				s = "    " .. instr.id .. " = " .. instr.op .. " " .. instr.args[1] .. ", " .. instr.args[2]
			elseif instr.op == "cmp" then
				s = "    " .. instr.id .. " = cmp " .. instr.args[1] .. " " .. instr.args[2] .. ", " .. instr.args[3]
			elseif instr.op == "phi" then
				local parts = {}
				for j = 1, #instr.args do
					local edge = instr.args[j]
					parts[#parts + 1] = "[" .. edge[1].name .. ": " .. edge[2] .. "]"
				end
				s = "    " .. instr.id .. " = phi " .. table.concat(parts, ", ")
			elseif instr.op == "call" then
				local call_args = {}
				for j = 2, #instr.args do
					call_args[#call_args + 1] = instr.args[j]
				end
				s = "    " .. instr.id .. " = call " .. instr.args[1] .. "(" .. table.concat(call_args, ", ") .. ")"
			elseif instr.op == "copy" then
				s = "    " .. instr.id .. " = copy " .. instr.args[1]
			elseif instr.op == "br" then
				s = "    br " .. instr.args[1] .. ", " .. instr.args[2] .. ", " .. instr.args[3]
			elseif instr.op == "jmp" then
				s = "    jmp " .. instr.args[1]
			elseif instr.op == "ret" then
				s = "    ret " .. tostring(instr.args[1])
			else
				s = "    " .. (instr.id or "") .. " = " .. instr.op .. " ?"
			end
			lines[#lines + 1] = s
		end
	end
	return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------

--:: Module = { name: string, _funcs: { [number]: Func } }

local Module = {}
Module.__index = Module

function M.module(name)
	return setmetatable({ name = name, _funcs = {} }, Module)
end

function Module:func(name, params)
	local f = new_func(name, params)
	self._funcs[#self._funcs + 1] = f
	return f
end

function Module:funcs()
	local out = {}
	for i = 1, #self._funcs do
		out[i] = self._funcs[i]
	end
	return out
end

---------------------------------------------------------------------------
-- Optimization passes
---------------------------------------------------------------------------

-- Collect all value IDs that are used as operands anywhere in the function
local function collect_used(func)
	local used = {}
	for bi = 1, #func._blocks do
		local blk = func._blocks[bi]
		for ii = 1, #blk._instrs do
			local instr = blk._instrs[ii]
			if instr.op == "add" or instr.op == "sub" or instr.op == "mul"
				or instr.op == "div" or instr.op == "mod" then
				used[instr.args[1]] = true
				used[instr.args[2]] = true
			elseif instr.op == "cmp" then
				used[instr.args[2]] = true
				used[instr.args[3]] = true
			elseif instr.op == "phi" then
				for j = 1, #instr.args do
					used[instr.args[j][2]] = true
				end
			elseif instr.op == "br" then
				used[instr.args[1]] = true
			elseif instr.op == "ret" then
				if instr.args[1] then used[instr.args[1]] = true end
			elseif instr.op == "call" then
				for j = 1, #instr.args do
					used[instr.args[j]] = true
				end
			elseif instr.op == "copy" then
				used[instr.args[1]] = true
			end
		end
	end
	return used
end

function M.dce(func)
	local removed = 0
	-- Iterate until fixed point
	local changed = true
	while changed do
		changed = false
		local used = collect_used(func)
		for bi = 1, #func._blocks do
			local blk = func._blocks[bi]
			local new_instrs = {}
			for ii = 1, #blk._instrs do
				local instr = blk._instrs[ii]
				-- Keep terminators (no id) and used values; also keep calls (side effects)
				if not instr.id or used[instr.id] or instr.op == "call" then
					new_instrs[#new_instrs + 1] = instr
				else
					removed = removed + 1
					changed = true
				end
			end
			blk._instrs = new_instrs
		end
	end
	return removed
end

-- Build a map from value ID to instruction across all blocks
local function build_val_map(func)
	local map = {}
	for bi = 1, #func._blocks do
		local blk = func._blocks[bi]
		for ii = 1, #blk._instrs do
			local instr = blk._instrs[ii]
			if instr.id then
				map[instr.id] = instr
			end
		end
	end
	return map
end

function M.const_fold(func)
	local folded = 0
	local val_map = build_val_map(func)

	local function const_val(id)
		local instr = val_map[id]
		if instr and instr.op == "const" and type(instr.args[1]) == "number" then
			return instr.args[1]
		end
		return nil
	end

	for bi = 1, #func._blocks do
		local blk = func._blocks[bi]
		for ii = 1, #blk._instrs do
			local instr = blk._instrs[ii]
			if instr.op == "add" or instr.op == "sub" or instr.op == "mul"
				or instr.op == "div" or instr.op == "mod" then
				local a = const_val(instr.args[1])
				local b = const_val(instr.args[2])
				if a and b then
					local result
					if instr.op == "add" then result = a + b
					elseif instr.op == "sub" then result = a - b
					elseif instr.op == "mul" then result = a * b
					elseif instr.op == "div" then result = a / b
					elseif instr.op == "mod" then result = a % b
					end
					instr.op = "const"
					instr.args = { result }
					val_map[instr.id] = instr
					folded = folded + 1
				end
			elseif instr.op == "cmp" then
				local a = const_val(instr.args[2])
				local b = const_val(instr.args[3])
				if a and b then
					local cmp_op = instr.args[1]
					local result
					if cmp_op == "eq" then result = a == b
					elseif cmp_op == "ne" then result = a ~= b
					elseif cmp_op == "lt" then result = a < b
					elseif cmp_op == "le" then result = a <= b
					elseif cmp_op == "gt" then result = a > b
					elseif cmp_op == "ge" then result = a >= b
					end
					instr.op = "const"
					instr.args = { result }
					val_map[instr.id] = instr
					folded = folded + 1
				end
			end
		end
	end
	return folded
end

-- Replace uses of a value ID throughout the function
local function replace_uses(func, old_id, new_id)
	for bi = 1, #func._blocks do
		local blk = func._blocks[bi]
		for ii = 1, #blk._instrs do
			local instr = blk._instrs[ii]
			if instr.op == "add" or instr.op == "sub" or instr.op == "mul"
				or instr.op == "div" or instr.op == "mod" then
				if instr.args[1] == old_id then instr.args[1] = new_id end
				if instr.args[2] == old_id then instr.args[2] = new_id end
			elseif instr.op == "cmp" then
				if instr.args[2] == old_id then instr.args[2] = new_id end
				if instr.args[3] == old_id then instr.args[3] = new_id end
			elseif instr.op == "phi" then
				for j = 1, #instr.args do
					if instr.args[j][2] == old_id then instr.args[j][2] = new_id end
				end
			elseif instr.op == "br" then
				if instr.args[1] == old_id then instr.args[1] = new_id end
			elseif instr.op == "ret" then
				if instr.args[1] == old_id then instr.args[1] = new_id end
			elseif instr.op == "call" then
				for j = 1, #instr.args do
					if instr.args[j] == old_id then instr.args[j] = new_id end
				end
			elseif instr.op == "copy" then
				if instr.args[1] == old_id then instr.args[1] = new_id end
			end
		end
	end
end

function M.copy_prop(func)
	local propagated = 0
	-- Find all copy instructions and replace their uses
	local changed = true
	while changed do
		changed = false
		for bi = 1, #func._blocks do
			local blk = func._blocks[bi]
			for ii = 1, #blk._instrs do
				local instr = blk._instrs[ii]
				if instr.op == "copy" and instr.id then
					replace_uses(func, instr.id, instr.args[1])
					propagated = propagated + 1
					changed = true
				end
			end
		end
		-- After propagation, remove copy instructions (they are now dead)
		if changed then
			for bi = 1, #func._blocks do
				local blk = func._blocks[bi]
				local new_instrs = {}
				for ii = 1, #blk._instrs do
					local instr = blk._instrs[ii]
					if instr.op ~= "copy" then
						new_instrs[#new_instrs + 1] = instr
					end
				end
				blk._instrs = new_instrs
			end
			changed = false -- only one pass needed since we replace all uses
		end
	end
	return propagated
end

return M
