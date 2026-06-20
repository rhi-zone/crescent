-- lib/sem/lang/lua/print.lua
-- Pretty-print the SAME surface AST (lib/sem/lang/lua/lower.lua's SX/SS) to
-- runnable Lua SOURCE text, for feeding to a real LuaJIT (Loop-α's real oracle).
--
-- The printed source is a self-contained Lua chunk: top-level statements plus a
-- top-level `return e1, ..., en` that yields the observable tuple. Loop-α runs
-- the chunk through `bin/luajit` and captures the returned tuple (the alpha test
-- arranges the capture). Names are emitted verbatim — the generator guarantees
-- they are valid Lua identifiers and well-scoped.
--
-- This is the OTHER half of the dumb surface representation: lower.lua maps the
-- surface to control terms (for our spec); print.lua maps the SAME surface to
-- Lua text (for real LuaJIT). Both are purely syntactic.

--:: require "lib.sem.lang.lua.lower"

local M = {}

-- format a number the way Lua source would accept and LuaJIT would reproduce.
--: (number) -> string
local function num_lit(n)
	if n ~= n then return "(0/0)" end          -- NaN
	if n == math.huge then return "(1/0)" end
	if n == -math.huge then return "(-1/0)" end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.17g", n)
end

-- quote a string as a Lua string literal (%q is Lua-source-safe).
--: (string) -> string
local function str_lit(s)
	return string.format("%q", s)
end

--: (SX) -> string
function M.print_expr(sx)
	if sx.x == "num" then return num_lit(sx.n) end
	if sx.x == "str" then return str_lit(sx.s) end
	if sx.x == "bool" then return sx.b and "true" or "false" end
	if sx.x == "nil" then return "nil" end
	if sx.x == "vararg" then return "..." end
	if sx.x == "name" then return sx.name end
	if sx.x == "binop" then
		local ops = {
			add = "+", sub = "-", mul = "*", div = "/", mod = "%",
			eq = "==", ne = "~=", lt = "<", le = "<=", gt = ">", ge = ">=",
			concat = "..",
		} --[[: { [string]: string } ]]
		local sym = ops[sx.op] or "??"
		return "(" .. M.print_expr(sx.a) .. " " .. sym .. " " .. M.print_expr(sx.b) .. ")"
	end
	if sx.x == "index" then
		-- parenthesize the object: a table-constructor or other non-primary obj
		-- (`{...}[k]`) is a Lua syntax error; `({...})[k]` is valid. Wrapping a
		-- name is harmless. This keeps the printed source a faithful, parseable
		-- rendering of the SAME AST the spec lowers.
		return "(" .. M.print_expr(sx.obj) .. ")[" .. M.print_expr(sx.key) .. "]"
	end
	if sx.x == "table" then
		local parts = {} --[[: { [integer]: string } ]]
		for i = 1, #sx.items do
			local it = sx.items[i]
			if it ~= nil then parts[#parts + 1] = M.print_expr(it) end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	if sx.x == "func" then
		local ps = {} --[[: { [integer]: string } ]]
		for i = 1, #sx.params do
			local p = sx.params[i]
			if p ~= nil then ps[#ps + 1] = p end
		end
		if sx.vararg then ps[#ps + 1] = "..." end
		return "(function(" .. table.concat(ps, ", ") .. ")\n"
			.. M.print_block(sx.body, "  ") .. "end)"
	end
	if sx.x == "call" then
		local as = {} --[[: { [integer]: string } ]]
		for i = 1, #sx.args do
			local a = sx.args[i]
			if a ~= nil then as[#as + 1] = M.print_expr(a) end
		end
		return "(" .. M.print_expr(sx.fn) .. ")(" .. table.concat(as, ", ") .. ")"
	end
	return "nil --[[unknown expr]]"
end

-- print a comma-separated expression list.
--: (SX[]) -> string
local function print_exprlist(exprs)
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #exprs do
		local e = exprs[i]
		if e ~= nil then parts[#parts + 1] = M.print_expr(e) end
	end
	return table.concat(parts, ", ")
end

--: (SS, string) -> string
function M.print_stmt(ss, indent)
	if ss.s == "local" then
		local ns = {} --[[: { [integer]: string } ]]
		for i = 1, #ss.names do
			local nm = ss.names[i]
			if nm ~= nil then ns[#ns + 1] = nm end
		end
		local line = indent .. "local " .. table.concat(ns, ", ")
		if #ss.exprs > 0 then line = line .. " = " .. print_exprlist(ss.exprs) end
		return line .. "\n"
	end
	if ss.s == "assign" then
		return indent .. ss.name .. " = " .. M.print_expr(ss.expr) .. "\n"
	end
	if ss.s == "setindex" then
		return indent .. M.print_expr(ss.obj) .. "[" .. M.print_expr(ss.key) .. "] = "
			.. M.print_expr(ss.val) .. "\n"
	end
	if ss.s == "exprstmt" then
		-- statement-context call. Wrap to make a call a statement; a non-call
		-- expr-statement is illegal Lua, but the generator only emits calls here.
		return indent .. M.print_expr(ss.expr) .. "\n"
	end
	if ss.s == "if" then
		local out = indent .. "if " .. M.print_expr(ss.cond) .. " then\n"
			.. M.print_block(ss.then_body, indent .. "  ")
		if #ss.else_body > 0 then
			out = out .. indent .. "else\n" .. M.print_block(ss.else_body, indent .. "  ")
		end
		return out .. indent .. "end\n"
	end
	if ss.s == "while" then
		return indent .. "while " .. M.print_expr(ss.cond) .. " do\n"
			.. M.print_block(ss.body, indent .. "  ") .. indent .. "end\n"
	end
	if ss.s == "return" then
		return indent .. "return " .. print_exprlist(ss.exprs) .. "\n"
	end
	return indent .. "-- unknown stmt\n"
end

--: (SS[], string) -> string
function M.print_block(body, indent)
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #body do
		local s = body[i]
		if s ~= nil then parts[#parts + 1] = M.print_stmt(s, indent) end
	end
	return table.concat(parts)
end

-- print a whole program (a statement list) as a runnable Lua chunk.
--: (SS[]) -> string
function M.print_program(prog)
	return M.print_block(prog, "")
end

return M
