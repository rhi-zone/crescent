-- lib/sem/lang/lua/lower.lua
-- INDEPENDENT, DUMB lowering: our own minimal Lua-surface AST → control terms.
--
-- DELIBERATELY DUMB: this lowering carries NO semantic content. It is a purely
-- syntactic surface→control map (name resolution to slot indices + node-kind
-- renaming). All meaning is assigned by step.lua + prim.lua. This is the
-- decision in docs/typechecker-formal-semantics.md: the prescriptive semantics
-- lives unambiguously in step + prim, never smuggled into the lowering.
--
-- It is INDEPENDENT of `crescent_slice_lower` (docs/agnostic-...): we do our own
-- lowering so the spec's surface is decoupled from the slice typechecker's.
--
-- SLOT MODEL (matches step.lua's activation build): a closure captures its
-- parent frame's ENTIRE slot array (step copies `desc.env[i]` into the callee's
-- low slots), so a free variable keeps its parent slot index inside the nested
-- function. Params/locals of a function are assigned indices starting at `base`
-- = the parent scope's total slot count at closure-creation time. The top-level
-- program is function scope with base 0.
--
-- CAPTURE CAVEAT (S1): captures are by VALUE-SNAPSHOT of the slot array at call
-- time (step copies the array). This matches the corpus's read-only-closure
-- usage; mutable upvalue sharing across closure and outer scope is deferred (a
-- proper upvalue cell is S2+ substrate; recorded in TODO.md).
--
-- DEFERRED (noted, narrow start): μ / union / intersection surface terms are
-- type-level, not runtime-evaluable, so they are NOT lowered here (they have no
-- step rule). The S1 lowering covers the runtime-evaluable v1 subset: scalars,
-- literals, arithmetic, comparison, table construct/index/assign, function
-- def/call with multi-return + vararg, if/while/return.

--:: require "lib.sem.value"
--:: require "lib.sem.config"

local value = require("lib.sem.value")

local M = {}

-- ── Surface AST (independent, minimal) ───────────────────────────────────────
-- Expressions:
--::   SXNum   = { x: "num", n: number }
--::   SXStr   = { x: "str", s: string }
--::   SXBool  = { x: "bool", b: boolean }
--::   SXNil   = { x: "nil" }
--::   SXName  = { x: "name", name: string }
--::   SXVararg= { x: "vararg" }
--::   SXBinop = { x: "binop", op: string, a: SX, b: SX }
--::   SXIndex = { x: "index", obj: SX, key: SX }
--::   SXTable = { x: "table", items: SX[] }
--::   SXFunc  = { x: "func", params: string[], vararg: boolean, body: SS[] }
--::   SXCall  = { x: "call", fn: SX, args: SX[] }
--:: SX = SXNum | SXStr | SXBool | SXNil | SXName | SXVararg | SXBinop | SXIndex | SXTable | SXFunc | SXCall
-- Statements:
--::   SSLocal  = { s: "local", names: string[], exprs: SX[] }
--::   SSAssign = { s: "assign", name: string, expr: SX }
--::   SSSetIdx = { s: "setindex", obj: SX, key: SX, val: SX }
--::   SSExpr   = { s: "exprstmt", expr: SX }
--::   SSIf     = { s: "if", cond: SX, then_body: SS[], else_body: SS[] }
--::   SSWhile  = { s: "while", cond: SX, body: SS[] }
--::   SSReturn = { s: "return", exprs: SX[] }
--:: SS = SSLocal | SSAssign | SSSetIdx | SSExpr | SSIf | SSWhile | SSReturn

-- ── Scope: name → slot resolution ────────────────────────────────────────────
-- A scope maps names to slot indices, chained to a parent. `count` is the total
-- number of slots allocated in THIS function so far (used as a nested function's
-- base). Names introduced by `local`/params get the next slot; lookups walk the
-- chain (an outer name keeps its outer slot index, matching the capture model).
--:: Scope = { names: { [string]: integer }, count: integer, parent: Scope | nil, base: integer }

--: (Scope | nil, integer) -> Scope
local function new_scope(parent, base)
	return { names = {}, count = base, parent = parent, base = base }
end

-- resolve a name to a slot index, walking outward. Returns nil if unbound (a
-- free reference to an unbound name lowers to a nil read, matching Lua's global
-- semantics being out of S1 scope — see lower_name).
--: (Scope, string) -> integer | nil
local function resolve(scope, name)
	local s = scope --: Scope | nil
	while s ~= nil do
		local slot = s.names[name]
		if slot ~= nil then return slot end
		s = s.parent
	end
	return nil
end

-- declare a name in the current scope; allocate the next slot.
--: (Scope, string) -> integer
local function declare(scope, name)
	scope.count = scope.count + 1
	local slot = scope.count
	scope.names[name] = slot
	return slot
end

-- ── expression lowering ──────────────────────────────────────────────────────
-- a `lit` Term from a Value (binds the Value to dodge a value-accessor inference
-- quirk where a bare `va.x(...)` in a record literal reads as nil).
--: (Value) -> Term
local function lit(v)
	local term = { k = "lit", v = v } --[[: Term]]
	return term
end

--: (Scope, SX) -> Term
function M.lower_expr(scope, sx)
	local va = value.luajit51
	if sx.x == "num" then local v = va.number(sx.n) --: Value
		return lit(v) end
	if sx.x == "str" then local v = va.string(sx.s) --: Value
		return lit(v) end
	if sx.x == "bool" then local v = va.bool(sx.b) --: Value
		return lit(v) end
	if sx.x == "nil" then local v = va.nil_v --: Value
		return lit(v) end
	if sx.x == "vararg" then local t = { k = "vararg" } --[[: Term]]
		return t end
	if sx.x == "name" then
		local slot = resolve(scope, sx.name)
		-- unbound name → nil literal (globals are outside S1; print.lua keeps
		-- programs self-contained so this case does not arise for generated ASTs).
		if slot == nil then local v = va.nil_v --: Value
			return lit(v) end
		local t = { k = "var", slot = slot } --[[: Term]]
		return t
	end
	if sx.x == "binop" then
		local t = { k = "binop", op = sx.op, a = M.lower_expr(scope, sx.a), b = M.lower_expr(scope, sx.b) } --[[: Term]]
		return t
	end
	if sx.x == "index" then
		local t = { k = "index", obj = M.lower_expr(scope, sx.obj), key = M.lower_expr(scope, sx.key) } --[[: Term]]
		return t
	end
	if sx.x == "table" then
		local items = {} --[[: Term[] ]]
		for i = 1, #sx.items do
			local it = sx.items[i]
			if it ~= nil then
				local lt = M.lower_expr(scope, it) --: Term
				items[#items + 1] = lt
			end
		end
		local t = { k = "table", items = items } --[[: Term]]
		return t
	end
	if sx.x == "func" then
		-- a nested function: base = parent's current slot count (the captured
		-- array length at runtime). Params and locals start above the base.
		local fscope = new_scope(scope, scope.count)
		for i = 1, #sx.params do
			local p = sx.params[i]
			if p ~= nil then declare(fscope, p) end
		end
		local body = M.lower_block(fscope, sx.body)
		local t = {
			k = "closure", nparams = #sx.params, vararg = sx.vararg,
			body = body, nslots = fscope.count,
		} --[[: Term]]
		return t
	end
	if sx.x == "call" then
		local args = {} --[[: Term[] ]]
		for i = 1, #sx.args do
			local a = sx.args[i]
			if a ~= nil then
				local la = M.lower_expr(scope, a) --: Term
				args[#args + 1] = la
			end
		end
		local t = { k = "call", fn = M.lower_expr(scope, sx.fn), args = args } --[[: Term]]
		return t
	end
	error("lower_expr: unknown surface expr")
end

-- ── statement lowering ───────────────────────────────────────────────────────
--: (Scope, SS) -> Stmt
function M.lower_stmt(scope, ss)
	if ss.s == "local" then
		-- exprs are lowered in the PRE-declaration scope (RHS cannot see the new
		-- names); then declare each name.
		local exprs = {} --[[: Term[] ]]
		for i = 1, #ss.exprs do
			local e = ss.exprs[i]
			if e ~= nil then exprs[#exprs + 1] = M.lower_expr(scope, e) end
		end
		local slots = {} --[[: integer[] ]]
		for i = 1, #ss.names do
			local nm = ss.names[i]
			if nm ~= nil then slots[#slots + 1] = declare(scope, nm) end
		end
		local s = { k = "local", slots = slots, exprs = exprs } --[[: Stmt]]
		return s
	end
	if ss.s == "assign" then
		local slot = resolve(scope, ss.name)
		-- assigning an unbound name: lower to a fresh local declaration (keeps the
		-- machine total; generated ASTs always assign bound names).
		if slot == nil then slot = declare(scope, ss.name) end
		local s = { k = "assign", slot = slot, expr = M.lower_expr(scope, ss.expr) } --[[: Stmt]]
		return s
	end
	if ss.s == "setindex" then
		local s = {
			k = "setindex", obj = M.lower_expr(scope, ss.obj),
			key = M.lower_expr(scope, ss.key), val = M.lower_expr(scope, ss.val),
		} --[[: Stmt]]
		return s
	end
	if ss.s == "exprstmt" then
		local s = { k = "exprstmt", expr = M.lower_expr(scope, ss.expr) } --[[: Stmt]]
		return s
	end
	if ss.s == "if" then
		local s = {
			k = "if", cond = M.lower_expr(scope, ss.cond),
			then_body = M.lower_block(scope, ss.then_body),
			else_body = M.lower_block(scope, ss.else_body),
		} --[[: Stmt]]
		return s
	end
	if ss.s == "while" then
		local s = {
			k = "while", cond = M.lower_expr(scope, ss.cond),
			body = M.lower_block(scope, ss.body),
		} --[[: Stmt]]
		return s
	end
	if ss.s == "return" then
		local exprs = {} --[[: Term[] ]]
		for i = 1, #ss.exprs do
			local e = ss.exprs[i]
			if e ~= nil then exprs[#exprs + 1] = M.lower_expr(scope, e) end
		end
		local s = { k = "return", exprs = exprs } --[[: Stmt]]
		return s
	end
	error("lower_stmt: unknown surface statement")
end

--: (Scope, SS[]) -> Stmt[]
function M.lower_block(scope, body)
	local out = {} --[[: Stmt[] ]]
	for i = 1, #body do
		local s = body[i]
		if s ~= nil then out[#out + 1] = M.lower_stmt(scope, s) end
	end
	return out
end

-- lower a whole program (a statement list) to control statements. The top scope
-- is a function scope with base 0.
--: (SS[]) -> Stmt[]
function M.lower_program(prog)
	local scope = new_scope(nil, 0)
	return M.lower_block(scope, prog)
end

return M
