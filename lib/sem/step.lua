-- lib/sem/step.lua
-- The single small-step relation `step(config) -> config`.
--
-- THE PRESCRIPTIVE SEMANTICS LIVES HERE AND IN prim.lua. The lowering is dumb
-- (pure syntax → control); step + prim assign all meaning. This module mentions
-- NO version: it reads the value algebra + prims off the injected profile.
--
-- MACHINE SHAPE — a CEK machine (Control, Environment, Kontinuation):
--   * focus    — either an expression to evaluate `{ eval = Term }`, a statement
--                list to execute `{ exec = Stmt[], pc = i }`, or a produced value
--                tuple `{ vals = Value[] }`.
--   * env      — the current activation: `{ slots, varargs }`.
--   * kont     — an explicit continuation stack of frames. Each frame names what
--                to do once the focused sub-term produces value(s). Evaluation
--                order, multi-value call/return movement, and vararg adjustment
--                are all encoded as kont frames — NOT as host-language recursion.
--
-- `step(config) -> config` performs EXACTLY ONE reduction. A stuck configuration
-- (no rule) becomes a config whose control is a Fault (faults-as-stuck-primitive):
-- run.lua observes it. step never throws on a data fault and never recurses to a
-- value; it returns the next config. This makes step the phase-2 proof subject.
--
-- DISCIPLINE: step observes values ONLY through the profile's value algebra
-- (`va`). No raw Lua type tag of a Value is read here.

--:: require "lib.sem.value"
--:: require "lib.sem.config"

local config = require("lib.sem.config")
local prim = require("lib.sem.prim")

local M = {}

--:: Profile = { name: string, version: string, va: ValueAlgebra, arith_ops: { [string]: boolean } }

-- ── Environment (activation record) ─────────────────────────────────────────
--:: Env = { slots: Value[], varargs: Value[] }

-- ── Focus ───────────────────────────────────────────────────────────────────
-- Exactly one of `eval` / exec / vals is active (discriminated by `f`).
--::   FEval = { f: "eval", term: Term }
--::   FExec = { f: "exec", code: Stmt[], pc: integer }
--::   FVals = { f: "vals", vals: Value[] }
--:: Focus = FEval | FExec | FVals

-- ── Kontinuation frames ─────────────────────────────────────────────────────
-- Each frame is "what to do with the value(s) just produced". `t` discriminates.
-- The env captured in a frame is the activation that must be restored when the
-- frame resumes (it differs from the current env across a call boundary).
--::   KBinopR  = { t: "binopR", op: string, rhs: Term, env: Env }
--::   KBinopOp = { t: "binopOp", op: string, lhs: Value, env: Env }
--::   KIndexK  = { t: "indexK", key: Term, env: Env }
--::   KIndexDo = { t: "indexDo", obj: Value, env: Env }
--::   KSetObj  = { t: "setObj", key: Term, val: Term, env: Env }
--::   KSetKey  = { t: "setKey", obj: Value, val: Term, env: Env }
--::   KSetVal  = { t: "setVal", obj: Value, key: Value, env: Env }
--::   KTable   = { t: "table", ref: Value, items: Term[], idx: integer, env: Env }
--::   KCallFn  = { t: "callFn", args: Term[], env: Env }
--::   KArgs    = { t: "args", fnv: Value | nil, args: Term[], idx: integer, acc: Value[], env: Env, spread: boolean }
--::   KCall    = { t: "call", fnv: Value, env: Env }
--::   KAdjust1 = { t: "adjust1", env: Env }
--::   KExecAfter = { t: "execAfter", code: Stmt[], pc: integer, env: Env }
--::   KLocal   = { t: "local", slots: integer[], code: Stmt[], pc: integer, env: Env }
--::   KAssign  = { t: "assign", slot: integer, code: Stmt[], pc: integer, env: Env }
--::   KIf      = { t: "if", then_body: Stmt[], else_body: Stmt[], code: Stmt[], pc: integer, env: Env }
--::   KWhile   = { t: "while", cond: Term, body: Stmt[], code: Stmt[], pc: integer, env: Env }
--::   KWhileRecond = { t: "whileRecond", cond: Term, body: Stmt[], code: Stmt[], pc: integer, env: Env }
--::   KRet     = { t: "ret", env: Env }
--::   KDiscard = { t: "discard", code: Stmt[], pc: integer, env: Env }
--:: Kont = KBinopR | KBinopOp | KIndexK | KIndexDo | KSetObj | KSetKey | KSetVal | KTable | KCallFn | KArgs | KCall | KAdjust1 | KExecAfter | KLocal | KAssign | KIf | KWhile | KWhileRecond | KRet | KDiscard

-- ── Machine state (the control component of a Config) ────────────────────────
--:: Machine = { focus: Focus, env: Env, kont: Kont[], fault: Fault | nil, final: Value[] | nil }

-- ── helpers ──────────────────────────────────────────────────────────────────

--: (Profile, Store) -> PrimEnv
local function penv(profile, store)
	return { va = profile.va, store = store, arith_ops = profile.arith_ops }
end

-- push a kont frame (returns the same list mutated; the machine owns one stack)
--: (Kont[], Kont) -> ()
local function push(kont, frame) kont[#kont + 1] = frame end

-- a focus carrying a value tuple
--: (Value[]) -> Focus
local function vals_focus(vs) return { f = "vals", vals = vs } end

-- a focus evaluating a term
--: (Term) -> Focus
local function eval_focus(term) return { f = "eval", term = term } end

-- a stuck machine: control becomes the fault
--: (Machine, Fault) -> Machine
local function stuck(m, fault)
	return { focus = m.focus, env = m.env, kont = m.kont, fault = fault, final = nil }
end

-- ── binop dispatch (meaning assigned here, via prims) ────────────────────────
--: (Profile, Store, string, Value, Value) -> (Value | nil, Fault | nil)
function M.apply_binop(profile, store, op, a, b)
	local env = penv(profile, store)
	-- arithmetic ops route to prim_arith, which checks the profile's enabled
	-- op-set (env.arith_ops) and delegates the numeric behaviour to the value
	-- algebra. step lists the op NAMES it knows how to route; whether a given op
	-- is ENABLED (e.g. `idiv` under 5.1/5.2) is decided by the rule-set data, not
	-- here — so there is no version branch in this dispatch.
	if env.arith_ops[op] ~= nil then
		return prim.prim_arith(env, op, a, b)
	end
	if op == "eq" then return prim.prim_compare(env, "eq", a, b) end
	if op == "ne" then
		local r, f = prim.prim_compare(env, "eq", a, b)
		if r == nil then return nil, f end
		return profile.va.bool(not profile.va.truthy(r)), nil
	end
	if op == "lt" then return prim.prim_compare(env, "lt", a, b) end
	if op == "le" then return prim.prim_compare(env, "le", a, b) end
	if op == "gt" then return prim.prim_compare(env, "lt", b, a) end
	if op == "ge" then return prim.prim_compare(env, "le", b, a) end
	if op == "concat" then return prim.prim_concat(env, a, b) end
	return nil, config.fault("unknown-op", "no rule for binop " .. op)
end

-- ── step: ONE reduction ──────────────────────────────────────────────────────
-- The relation has three top-level cases on the focus:
--   eval Term  → decompose the term, pushing kont frames for sub-evaluations
--   exec Stmts → take the next statement, push its kont, focus its first subterm
--   vals       → feed the produced tuple to the top kont frame (or finish)
-- Each call advances the machine by one reduction and returns the next Machine.

--: (Profile, Store, Machine, FEval) -> Machine
local function step_eval(profile, store, m, focus)
	local va = profile.va
	local term = focus.term --: Term
	local env = m.env

	if term.k == "lit" then
		return { focus = vals_focus({ term.v }), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "var" then
		local v = env.slots[term.slot]
		return { focus = vals_focus({ v ~= nil and v or va.nil_v }), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "vararg" then
		-- general eval: `...` yields its full tuple; a consuming frame adjusts.
		local out = {} --[[: Value[] ]]
		for i = 1, #env.varargs do out[i] = env.varargs[i] end
		return { focus = vals_focus(out), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "binop" then
		push(m.kont, { t = "binopR", op = term.op, rhs = term.b, env = env })
		return { focus = eval_focus(term.a), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "index" then
		push(m.kont, { t = "indexK", key = term.key, env = env })
		return { focus = eval_focus(term.obj), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "table" then
		local ref = prim.alloc_table(penv(profile, store)) --: Value
		if #term.items == 0 then
			return { focus = vals_focus({ ref }), env = env, kont = m.kont, fault = nil, final = nil }
		end
		push(m.kont, { t = "table", ref = ref, items = term.items, idx = 1, env = env })
		return { focus = eval_focus(term.items[1] --[[: Term]]), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "closure" then
		local ref = prim.alloc_closure(penv(profile, store), term.nparams, term.vararg, term.body, term.nslots, env.slots) --: Value
		return { focus = vals_focus({ ref }), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if term.k == "call" then
		push(m.kont, { t = "callFn", args = term.args, env = env })
		return { focus = eval_focus(term.fn), env = env, kont = m.kont, fault = nil, final = nil }
	end
	return stuck(m, config.fault("unknown-term", "no rule for this term kind"))
end

-- exec: focus on a statement list at pc.
--: (Profile, Store, Machine, FExec) -> Machine
local function step_exec(profile, store, m, focus)
	local env = m.env
	local code, pc = focus.code, focus.pc
	if pc > #code then
		-- block exhausted: produce empty tuple to resume the enclosing frame.
		return { focus = vals_focus({}), env = env, kont = m.kont, fault = nil, final = nil }
	end
	local stmt = code[pc] --: Stmt | nil
	if stmt == nil then
		return { focus = vals_focus({}), env = env, kont = m.kont, fault = nil, final = nil }
	end

	if stmt.k == "local" then
		push(m.kont, { t = "local", slots = stmt.slots, code = code, pc = pc + 1, env = env })
		return M.focus_exprlist(env, stmt.exprs, m.kont)
	end
	if stmt.k == "assign" then
		push(m.kont, { t = "assign", slot = stmt.slot, code = code, pc = pc + 1, env = env })
		return { focus = eval_focus(stmt.expr), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if stmt.k == "setindex" then
		push(m.kont, { t = "execAfter", code = code, pc = pc + 1, env = env })
		push(m.kont, { t = "setObj", key = stmt.key, val = stmt.val, env = env })
		return { focus = eval_focus(stmt.obj), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if stmt.k == "exprstmt" then
		push(m.kont, { t = "discard", code = code, pc = pc + 1, env = env })
		return { focus = eval_focus(stmt.expr), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if stmt.k == "if" then
		push(m.kont, { t = "if", then_body = stmt.then_body, else_body = stmt.else_body, code = code, pc = pc + 1, env = env })
		return { focus = eval_focus(stmt.cond), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if stmt.k == "while" then
		push(m.kont, { t = "while", cond = stmt.cond, body = stmt.body, code = code, pc = pc + 1, env = env })
		return { focus = eval_focus(stmt.cond), env = env, kont = m.kont, fault = nil, final = nil }
	end
	if stmt.k == "return" then
		push(m.kont, { t = "ret", env = env })
		return M.focus_exprlist(env, stmt.exprs, m.kont)
	end
	return stuck(m, config.fault("unknown-stmt", "no rule for this statement kind"))
end

-- focus_exprlist: begin evaluating an expression list left-to-right, threading a
-- KArgs-like accumulator. We reuse the "args" frame with spread=true and a nil
-- fnv sentinel meaning "this is a value list, not a call" (resolved in KArgs).
--: (Env, Term[], Kont[]) -> Machine
function M.focus_exprlist(env, exprs, kont)
	if #exprs == 0 then
		return { focus = vals_focus({}), env = env, kont = kont, fault = nil, final = nil }
	end
	push(kont, { t = "args", fnv = nil, args = exprs, idx = 0, acc = {}, env = env, spread = true })
	-- the args frame at idx=0 will, on first resume, consume nothing and kick
	-- evaluation of element 1; but to start we resume with an empty tuple.
	return { focus = vals_focus({}), env = env, kont = kont, fault = nil, final = nil }
end

-- vals: feed the produced tuple to the top continuation frame.
--: (Profile, Store, Machine, FVals) -> Machine
local function step_vals(profile, store, m, focus)
	local va = profile.va
	local vals = focus.vals
	local kont = m.kont
	local top = kont[#kont] --: Kont | nil
	if top == nil then
		-- no continuation: the whole program is done; the tuple is the result.
		return { focus = m.focus, env = m.env, kont = kont, fault = nil, final = vals }
	end
	kont[#kont] = nil  -- pop
	local pe = penv(profile, store)

	-- first value of the produced tuple, adjusted to nil-VALUE when empty.
	--: () -> Value
	local function first1()
		local v = vals[1]
		if v ~= nil then return v end
		return va.nil_v
	end
	if top.t == "binopR" then
		local f = top
		push(kont, { t = "binopOp", op = f.op, lhs = first1(), env = f.env })
		return { focus = eval_focus(f.rhs), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "binopOp" then
		local f = top
		local r, fault = M.apply_binop(profile, store, f.op, f.lhs, first1())
		if r == nil then return stuck(m, fault or config.fault("internal", "missing fault")) end
		return { focus = vals_focus({ r }), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "indexK" then
		local f = top
		push(kont, { t = "indexDo", obj = first1(), env = f.env })
		return { focus = eval_focus(f.key), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "indexDo" then
		local f = top
		local r, fault = prim.raw_get(pe, f.obj, first1())
		if r == nil then return stuck(m, fault or config.fault("internal", "missing fault")) end
		return { focus = vals_focus({ r }), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "setObj" then
		local f = top
		push(kont, { t = "setKey", obj = first1(), val = f.val, env = f.env })
		return { focus = eval_focus(f.key), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "setKey" then
		local f = top
		push(kont, { t = "setVal", obj = f.obj, key = first1(), env = f.env })
		return { focus = eval_focus(f.val), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "setVal" then
		local f = top
		local _ok, fault = prim.raw_set(pe, f.obj, f.key, first1())
		if _ok == nil then return stuck(m, fault or config.fault("internal", "missing fault")) end
		return { focus = vals_focus({}), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "table" then
		local f = top
		local idxkey = va.number(f.idx) --: Value
		local _ok, fault = prim.raw_set(pe, f.ref, idxkey, first1())
		if _ok == nil then return stuck(m, fault or config.fault("internal", "missing fault")) end
		if f.idx >= #f.items then
			return { focus = vals_focus({ f.ref }), env = f.env, kont = kont, fault = nil, final = nil }
		end
		push(kont, { t = "table", ref = f.ref, items = f.items, idx = f.idx + 1, env = f.env })
		return { focus = eval_focus(f.items[f.idx + 1] --[[: Term]]), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "callFn" then
		local f = top
		local fnv = first1()
		if #f.args == 0 then
			return M.enter_call(profile, store, m, fnv, {}, f.env)
		end
		push(kont, { t = "args", fnv = fnv, args = f.args, idx = 0, acc = {}, env = f.env, spread = false })
		-- kick element-1 evaluation by resuming the args frame with empty vals.
		return { focus = vals_focus({}), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "args" then
		return M.resume_args(profile, store, m, top, vals)
	end
	if top.t == "call" then
		local f = top
		-- vals here is the callee's return tuple; just forward it to the frame
		-- below (the call expression's continuation).
		return { focus = vals_focus(vals), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "adjust1" then
		local f = top
		return { focus = vals_focus({ first1() }), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "discard" then
		local f = top
		return { focus = { f = "exec", code = f.code, pc = f.pc }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "execAfter" then
		local f = top
		return { focus = { f = "exec", code = f.code, pc = f.pc }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "local" then
		local f = top
		for i = 1, #f.slots do
			local slot = f.slots[i]
			if slot ~= nil then
				local v = vals[i]
				f.env.slots[slot] = v ~= nil and v or va.nil_v
			end
		end
		return { focus = { f = "exec", code = f.code, pc = f.pc }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "assign" then
		local f = top
		f.env.slots[f.slot] = first1()
		return { focus = { f = "exec", code = f.code, pc = f.pc }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "if" then
		local f = top
		local body = va.truthy(first1()) and f.then_body or f.else_body
		-- run the branch body, then continue with the rest of the outer block.
		push(kont, { t = "execAfter", code = f.code, pc = f.pc, env = f.env })
		return { focus = { f = "exec", code = body, pc = 1 }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "while" then
		local f = top
		-- resumed with the condition value.
		if not va.truthy(first1()) then
			-- loop exits; continue the enclosing block at f.pc.
			return { focus = { f = "exec", code = f.code, pc = f.pc }, env = f.env, kont = kont, fault = nil, final = nil }
		end
		-- condition true: run the body, then re-evaluate the condition. The recond
		-- frame, on body completion, re-focuses cond and re-pushes the while frame.
		push(kont, { t = "whileRecond", cond = f.cond, body = f.body, code = f.code, pc = f.pc, env = f.env })
		return { focus = { f = "exec", code = f.body, pc = 1 }, env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "whileRecond" then
		local f = top
		-- body finished; re-establish the while frame and re-evaluate the cond.
		push(kont, { t = "while", cond = f.cond, body = f.body, code = f.code, pc = f.pc, env = f.env })
		return { focus = eval_focus(f.cond), env = f.env, kont = kont, fault = nil, final = nil }
	end
	if top.t == "ret" then
		local f = top
		-- pop frames until a KCall is found; that is the function-return movement.
		while #kont > 0 do
			local fr = kont[#kont] --: Kont | nil
			kont[#kont] = nil
			if fr ~= nil and fr.t == "call" then
				return { focus = vals_focus(vals), env = fr.env, kont = kont, fault = nil, final = nil }
			end
		end
		-- no enclosing call: program-level return — the tuple is the final result.
		return { focus = m.focus, env = f.env, kont = kont, fault = nil, final = vals }
	end
	return stuck(m, config.fault("unknown-kont", "no rule for this kont frame"))
end

-- resume_args: drive left-to-right evaluation of an expression list (call args or
-- a general value list). On each resume we append the produced value(s) and move
-- to the next element; at the end we either CALL (spread=false) or yield the
-- collected tuple (spread=true). Multi-value spread: only the LAST element keeps
-- all its values; earlier elements are adjusted to one.
--: (Profile, Store, Machine, KArgs, Value[]) -> Machine
function M.resume_args(profile, store, m, f, produced)
	local va = profile.va
	local kont = m.kont
	-- append produced values from the element we just finished (idx >= 1).
	if f.idx >= 1 then
		local n = #f.args
		if f.idx < n then
			-- not last: adjust to a single value
			local v = produced[1]
			f.acc[#f.acc + 1] = v ~= nil and v or va.nil_v
		else
			for j = 1, #produced do f.acc[#f.acc + 1] = produced[j] end
		end
	end
	if f.idx >= #f.args then
		-- all elements done.
		if f.spread then
			return { focus = vals_focus(f.acc), env = f.env, kont = kont, fault = nil, final = nil }
		end
		-- it's a call: f.fnv is the function value; build the activation.
		local fnv = f.fnv
		if fnv == nil then
			return stuck(m, config.fault(config.FAULT_CALL_NONFN, "missing callee"))
		end
		return M.enter_call(profile, store, m, fnv, f.acc, f.env)
	end
	-- focus the next element.
	local nextidx = f.idx + 1
	push(kont, { t = "args", fnv = f.fnv, args = f.args, idx = nextidx, acc = f.acc, env = f.env, spread = f.spread })
	return { focus = eval_focus(f.args[nextidx] --[[: Term]]), env = f.env, kont = kont, fault = nil, final = nil }
end

-- enter_call: parameter binding + vararg adjustment, then transfer control into
-- the callee body. A KCall frame marks the return point for KRet.
--: (Profile, Store, Machine, Value, Value[], Env) -> Machine
function M.enter_call(profile, store, m, fnv, args, caller_env)
	local va = profile.va
	if va.kind_of(fnv) ~= "closure" then
		return stuck(m, config.fault(config.FAULT_CALL_NONFN,
			"call of non-function (kind " .. va.kind_of(fnv) .. ")"))
	end
	local desc = prim.closure_desc(penv(profile, store), fnv) --: ClosureDesc | nil
	if desc == nil then
		return stuck(m, config.fault(config.FAULT_CALL_NONFN, "dangling closure reference"))
	end
	local slots = {} --[[: Value[] ]]
	for i = 1, #desc.env do slots[i] = desc.env[i] end
	for i = 1, desc.nparams do
		local a = args[i]
		slots[#desc.env + i] = a ~= nil and a or va.nil_v
	end
	local varargs = {} --[[: Value[] ]]
	if desc.vararg then
		for i = desc.nparams + 1, #args do
			local a = args[i]
			if a ~= nil then varargs[#varargs + 1] = a end
		end
	end
	local callee_env = { slots = slots, varargs = varargs }
	push(m.kont, { t = "call", fnv = fnv, env = caller_env })
	return { focus = { f = "exec", code = desc.body, pc = 1 }, env = callee_env, kont = m.kont, fault = nil, final = nil }
end

-- ── the relation ─────────────────────────────────────────────────────────────
--: (Profile, Store, Machine) -> Machine
function M.step(profile, store, m)
	if m.fault ~= nil then return m end
	if m.final ~= nil then return m end
	local focus = m.focus --: Focus
	if focus.f == "eval" then return step_eval(profile, store, m, focus) end
	if focus.f == "exec" then return step_exec(profile, store, m, focus) end
	return step_vals(profile, store, m, focus)
end

return M
