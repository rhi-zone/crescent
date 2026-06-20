-- lib/sem/config.lua
-- The configuration ADT for the small-step machine, plus the control-term ADT
-- and the fault constructors (faults-as-stuck-primitive).
--
-- A configuration is `{ store, control }`:
--   * store   — the mutable heap: table cells and closure descriptors, keyed by
--               integer address. Values (value.lua) hold addresses INTO this
--               store; the store holds the actual mutable state.
--   * control — the CEK control state: a focused term/value list plus a
--               continuation stack (frames). step.lua advances it.
--
-- FAULTS-AS-STUCK-PRIMITIVE: a fault is a configuration the step relation has
-- no rule for. step returns a `fault` record (class + message); run.lua maps it
-- to a fault-class observation. The fault is NOT a Lua error — it is a normal
-- return value, so soundness reasoning stays inside the relation.
--
-- This module is data-only (constructors + the store interface). It performs no
-- evaluation; step.lua owns the relation.

--:: require "lib.sem.value"

local M = {}

-- ── Control-term ADT (the desugared, semantics-free intermediate) ───────────
-- The lowering (lang/lua/lower.lua) produces these from the surface AST. They
-- carry NO semantic content beyond syntactic structure: step.lua + prim.lua
-- assign all meaning.
--
-- Expression terms (Term):
--::   ELit     = { k: "lit", v: Value }
--::   EVar     = { k: "var", slot: integer }
--::   EVararg  = { k: "vararg" }
--::   EBinop   = { k: "binop", op: string, a: Term, b: Term }
--::   ETable   = { k: "table", items: Term[] }
--::   EIndex   = { k: "index", obj: Term, key: Term }
--::   EClosure = { k: "closure", nparams: integer, vararg: boolean, body: Stmt[], nslots: integer }
--::   ECall    = { k: "call", fn: Term, args: Term[] }
--:: Term = ELit | EVar | EVararg | EBinop | ETable | EIndex | EClosure | ECall
--
-- Statement terms (Stmt):
--::   SLocal   = { k: "local", slots: integer[], exprs: Term[] }
--::   SAssign  = { k: "assign", slot: integer, expr: Term }
--::   SSetIndex= { k: "setindex", obj: Term, key: Term, val: Term }
--::   SExpr    = { k: "exprstmt", expr: Term }
--::   SIf      = { k: "if", cond: Term, then_body: Stmt[], else_body: Stmt[] }
--::   SWhile   = { k: "while", cond: Term, body: Stmt[] }
--::   SReturn  = { k: "return", exprs: Term[] }
--:: Stmt = SLocal | SAssign | SSetIndex | SExpr | SIf | SWhile | SReturn

-- ── Store ───────────────────────────────────────────────────────────────────
-- A table cell: an array part + a hash part, both keyed by Value-derived keys.
-- We store entries as { key: Value, val: Value } pairs in a list, plus a parallel
-- hash for O(1) scalar lookup. Keys compare by value equality (value.equal).
--
--:: TableCell = { entries: { key: Value, val: Value }[] }
--:: ClosureDesc = { nparams: integer, vararg: boolean, body: Stmt[], nslots: integer, env: Value[] }
--:: StoreObj = TableCell | ClosureDesc
--:: Store = { objs: { [integer]: StoreObj }, next_addr: integer }

--: () -> Store
function M.new_store()
	return { objs = {}, next_addr = 1 }
end

-- ── Configuration ────────────────────────────────────────────────────────────
--:: Config = { store: Store, control: unknown }

--: (Store, unknown) -> Config
function M.config(store, control)
	return { store = store, control = control }
end

-- ── Fault constructors (faults-as-stuck) ─────────────────────────────────────
--:: Fault = { fault: boolean, class: string, msg: string }

--: (string, string) -> Fault
function M.fault(class, msg)
	return { fault = true, class = class, msg = msg }
end

--: (unknown) -> boolean
function M.is_fault(x)
	if type(x) ~= "table" then return false end
	local t = x --[[: { fault?: boolean }]]
	return t.fault == true
end

-- Convenience fault classes (the per-primitive stuck conditions).
M.FAULT_ARITH = "arith-on-non-number"
M.FAULT_CONCAT = "concat-on-non-concatable"
M.FAULT_INDEX_NIL = "index-non-table"
M.FAULT_CALL_NONFN = "call-non-function"
M.FAULT_COMPARE = "compare-incompatible"
M.FAULT_KEY_NIL = "table-key-nil"

return M
