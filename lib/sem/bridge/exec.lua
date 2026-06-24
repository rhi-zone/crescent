-- lib/sem/bridge/exec.lua
-- REALITY BRIDGE — the OPERATIONAL / EXECUTION axis. The prior bridges
-- (atom.lua, rec.lua, fun.lua) validate the VALUE-MEMBERSHIP axis: a model
-- value inhabits a model type, faithfully against real LuaJIT. This module
-- validates the REDUCTION axis: a WELL-TYPED TERM, executed on REAL LuaJIT,
-- produces a value INHABITING its INFERRED type — the checker's soundness claim
-- (synth + progress/preservation) tested against the real interpreter. See
-- docs/reality-bridge.md §"Operational-semantics axis".
--
-- THE PIPELINE (per battery term):
--   1. the proof's CLOSED term (a faithful port of `tm`, proof/typing.v) is
--      translated to runnable Lua SOURCE (`term_to_lua`);
--   2. it is executed on real LuaJIT (the popen-injected cap, in exec_test.lua),
--      and the RESULT value + its observable shape are captured;
--   3. the INFERRED type is `synth [] term` (computed in Coq — see
--      proof/bridge_exec_oracle.v — and pinned per-term here as `infer`);
--   4. the result is asserted to INHABIT the inferred type, reusing the
--      value-membership bridge (atom.lua's real predicates / rec.lua).
--
-- THE TRANSLATION (de Bruijn → Lua). Variables are de Bruijn indices into a
-- context; we translate by carrying a STACK of fresh names — index 0 is the
-- innermost (top of stack). Each binder pushes a fresh `v<N>`; `tvar i` reads
-- `stack[#stack - i]`. Lua has no expression-level `if`, no `let`, and no
-- references, so:
--   * tif c a b   → an IIFE `(function() if <c> then return <a> else return <b> end end)()`
--                   (Lua truthiness: `if` already tests truthy/falsy, matching
--                   the proof's value-conditioned tif on a Bool condition);
--   * tlet e1 e2  → an IIFE `(function() local v = <e1>; return <e2> end)()`;
--   * REFERENCES (Lua has none) → a single-field mutable CELL, a table `{v=...}`:
--       talloc e   → `{ v = (<e>) }`        (a fresh one-field table);
--       tderef r   → `((<r>).v)`            (read the cell);
--       tassign r v→ IIFE `(function() (<r>).v = (<v>); return nil end)()`
--                    (write the cell, yield nil = the proof's unit);
--   * tseq a b    → IIFE `(function() local _ = (<a>); return (<b>) end)()`
--                   (run a for effect, discard, run b) — matches
--                   `tseq a b := tlet a (lift 1 0 b)` (the binder is unused);
--   * twhile c body → a real `while` loop inside an IIFE returning nil — the
--                   proof's `twhile := tfix Tunit (tif c (tseq body (tvar 0))
--                   (tlit LNil))` is a recursive unfold; the FINITE-execution
--                   image of that is a `while` loop. (We translate the surface
--                   `twhile` form directly rather than the fix-unfold encoding —
--                   same operational behaviour for terminating loops, which is
--                   the bridge's scope.)
-- Arithmetic/comparison primops map to the Lua binary operators directly
-- (PAdd→`+`, …, PEq→`==`). Records → table constructors; tproj → `.k` field
-- access. Lambdas → `function(v) … end`; application → a call.
--
-- SCOPE (honest, the FINITE-EXECUTION fragment): terminating closed terms that
-- reduce to a value. Flow-narrowing forms (tifn / ttypetest) and higher-order /
-- divergent programs are NOT in the battery (noted in the doc). `tfix` is
-- exercised only through the `twhile` encoding (a terminating counter loop), not
-- as open-ended recursion.
--
-- CAPS-FIRST: this module is PURE (source generation + a shape classifier only);
-- the real interpreter is reached solely through injected caps in exec_test.lua,
-- which SKIPS the real legs if the vendored LuaJIT cannot be probed (bare-clone
-- safe). DO NOT add I/O here.

local M = {}

-- ── term constructors (a faithful port of proof/typing.v `tm`) ───────────────
-- Each term is a tagged table mirroring a `tm` constructor. de Bruijn indices
-- are plain integers (0 = innermost binder), exactly as the proof.
--:: TLit  = { tag: "lit", lit: Lit }
--:: Lit   = { k: "int", n: integer } | { k: "bool", b: boolean } | { k: "nil" }
--:: TVar  = { tag: "var", i: integer }
--:: TPrim = { tag: "prim", op: PrimOp, a: Term, b: Term }
--:: PrimOp = "PAdd" | "PSub" | "PMul" | "PDiv" | "PLt" | "PLe" | "PEq"
--:: TLam  = { tag: "lam", body: Term }
--:: TApp  = { tag: "app", f: Term, a: Term }
--:: TLet  = { tag: "let", e1: Term, e2: Term }
--:: TRec  = { tag: "rec", fields: RecFieldTerm[] }
--:: RecFieldTerm = { k: string, e: Term }
--:: TProj = { tag: "proj", e: Term, k: string }
--:: TIf   = { tag: "if", c: Term, e1: Term, e2: Term }
--:: TAlloc  = { tag: "alloc", e: Term }
--:: TDeref  = { tag: "deref", e: Term }
--:: TAssign = { tag: "assign", r: Term, e: Term }
--:: TSeq   = { tag: "seq", a: Term, b: Term }
--:: TWhile = { tag: "while", c: Term, body: Term }
--:: Term = TLit | TVar | TPrim | TLam | TApp | TLet | TRec | TProj | TIf | TAlloc | TDeref | TAssign | TSeq | TWhile

-- The number literal carries NO magnitude (numbers are type-CLASSES; the "types,
-- not magnitudes" refactor). It renders to a FIXED integer-valued representative.
--: () -> Term
function M.lit_int() return { tag = "lit", lit = { k = "int" } } end
--: (boolean) -> Term
function M.lit_bool(b) return { tag = "lit", lit = { k = "bool", b = b } } end
--: () -> Term
function M.lit_nil() return { tag = "lit", lit = { k = "nil" } } end
--: (integer) -> Term
function M.var(i) return { tag = "var", i = i } end
--: (PrimOp, Term, Term) -> Term
function M.prim(op, a, b) return { tag = "prim", op = op, a = a, b = b } end
--: (Term) -> Term
function M.lam(body) return { tag = "lam", body = body } end
--: (Term, Term) -> Term
function M.app(f, a) return { tag = "app", f = f, a = a } end
--: (Term, Term) -> Term
function M.let_(e1, e2) return { tag = "let", e1 = e1, e2 = e2 } end
--: (RecFieldTerm[]) -> Term
function M.rec(fields) return { tag = "rec", fields = fields } end
--: (Term, string) -> Term
function M.proj(e, k) return { tag = "proj", e = e, k = k } end
--: (Term, Term, Term) -> Term
function M.if_(c, e1, e2) return { tag = "if", c = c, e1 = e1, e2 = e2 } end
--: (Term) -> Term
function M.alloc(e) return { tag = "alloc", e = e } end
--: (Term) -> Term
function M.deref(e) return { tag = "deref", e = e } end
--: (Term, Term) -> Term
function M.assign(r, e) return { tag = "assign", r = r, e = e } end
--: (Term, Term) -> Term
function M.seq(a, b) return { tag = "seq", a = a, b = b } end
--: (Term, Term) -> Term
function M.while_(c, body) return { tag = "while", c = c, body = body } end

-- ── primop → Lua binary operator ─────────────────────────────────────────────
-- The arithmetic ops map to Lua `+ - * /`; comparisons to `< <= ==`. The model's
-- arithmetic is now ABSTRACT (numbers are type-CLASSES with no magnitude; the
-- "types, not magnitudes" refactor), so there is NO model-computed value to
-- compare against — the former PDiv nat-div-vs-float faithfulness gap is moot by
-- construction. What the bridge validates is purely the TYPE claim: a well-typed
-- term, run on real LuaJIT, yields a value INHABITING its inferred type. We
-- translate each primop to the honest real-interpreter operator.
local PRIMOP_LUA = {
	PAdd = "+", PSub = "-", PMul = "*", PDiv = "/",
	PLt = "<", PLe = "<=", PEq = "==",
} --[[: { [string]: string } ]]

-- ── a fresh-name allocator threaded through the translation ──────────────────
--:: NameGen = { n: integer }
--: () -> NameGen
local function new_namegen() return { n = 0 } end
--: (NameGen) -> string
local function fresh(ng)
	ng.n = ng.n + 1
	return "v" .. ng.n
end

-- ── the translator: Term × (de-Bruijn name stack) × namegen → Lua source ─────
-- `stack` holds the in-scope binder NAMES, innermost LAST (so `tvar 0` is
-- `stack[#stack]`). Every emitted fragment is a self-contained Lua EXPRESSION
-- (IIFEs wrap the statement-shaped forms), so terms compose by nesting.
--: (Term, string[], NameGen) -> string
local function tr(t, stack, ng)
	if t.tag == "lit" then
		local l = t.lit
		if l.k == "int" then return "0" end
		if l.k == "bool" then return l.b and "true" or "false" end
		if l.k == "nil" then return "nil" end
		error("exec: unknown lit kind " .. tostring(l.k))
	elseif t.tag == "var" then
		-- de Bruijn i ↦ the (i+1)-th name from the TOP of the stack.
		local idx = #stack - t.i
		if idx < 1 or idx > #stack then
			error("exec: unbound de Bruijn index " .. tostring(t.i)
				.. " (stack depth " .. #stack .. ")")
		end
		return stack[idx]
	elseif t.tag == "prim" then
		local lop = PRIMOP_LUA[t.op]
		if lop == nil then error("exec: unknown primop " .. tostring(t.op)) end
		local a = tr(t.a, stack, ng)
		local b = tr(t.b, stack, ng)
		return "((" .. a .. ") " .. lop .. " (" .. b .. "))"
	elseif t.tag == "lam" then
		local name = fresh(ng)
		local body_stack = {} --[[: { [integer]: string } ]]
		for i = 1, #stack do body_stack[i] = stack[i] end
		body_stack[#body_stack + 1] = name -- push the binder (innermost)
		local body = tr(t.body, body_stack, ng)
		return "(function(" .. name .. ") return (" .. body .. ") end)"
	elseif t.tag == "app" then
		local f = tr(t.f, stack, ng)
		local a = tr(t.a, stack, ng)
		return "((" .. f .. ")(" .. a .. "))"
	elseif t.tag == "let" then
		local name = fresh(ng)
		local e1 = tr(t.e1, stack, ng)
		local body_stack = {} --[[: { [integer]: string } ]]
		for i = 1, #stack do body_stack[i] = stack[i] end
		body_stack[#body_stack + 1] = name
		local e2 = tr(t.e2, body_stack, ng)
		return "(function() local " .. name .. " = (" .. e1 .. "); return ("
			.. e2 .. ") end)()"
	elseif t.tag == "rec" then
		local parts = {} --[[: { [integer]: string } ]]
		for i = 1, #t.fields do
			local fld = t.fields[i]
			local key = ("[%q]"):format(fld.k)
			parts[#parts + 1] = key .. " = (" .. tr(fld.e, stack, ng) .. ")"
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	elseif t.tag == "proj" then
		local e = tr(t.e, stack, ng)
		return "((" .. e .. ")[" .. ("%q"):format(t.k) .. "])"
	elseif t.tag == "if" then
		-- Lua has no if-EXPRESSION: wrap in an IIFE. Lua `if` tests truthiness,
		-- matching the proof's value-conditioned tif (a Bool condition here).
		local c = tr(t.c, stack, ng)
		local e1 = tr(t.e1, stack, ng)
		local e2 = tr(t.e2, stack, ng)
		return "(function() if (" .. c .. ") then return (" .. e1
			.. ") else return (" .. e2 .. ") end end)()"
	elseif t.tag == "alloc" then
		-- a reference cell = a single-field mutable table `{ v = <e> }`.
		local e = tr(t.e, stack, ng)
		return "{ v = (" .. e .. ") }"
	elseif t.tag == "deref" then
		local e = tr(t.e, stack, ng)
		return "((" .. e .. ").v)"
	elseif t.tag == "assign" then
		-- write the cell, yield nil (the proof's unit value for assign).
		local r = tr(t.r, stack, ng)
		local e = tr(t.e, stack, ng)
		return "(function() local _r = (" .. r .. "); _r.v = (" .. e
			.. "); return nil end)()"
	elseif t.tag == "seq" then
		-- run a for effect, discard, run b. Mirrors tseq = tlet a (lift 1 0 b)
		-- (the discard binder is unused).
		local a = tr(t.a, stack, ng)
		local b = tr(t.b, stack, ng)
		return "(function() local _ = (" .. a .. "); return (" .. b .. ") end)()"
	elseif t.tag == "while" then
		-- the FINITE-execution image of `tfix Tunit (tif c (tseq body (tvar 0))
		-- (tlit LNil))`: a real `while` loop, returning nil (the unit value).
		-- The condition + body share the SAME de Bruijn scope (no fresh binder —
		-- the surface form is translated directly, not the fix-self-ref binder).
		local c = tr(t.c, stack, ng)
		local body = tr(t.body, stack, ng)
		return "(function() while (" .. c .. ") do local _ = (" .. body
			.. ") end return nil end)()"
	end
	error("exec: unknown term tag " .. tostring(t.tag))
end

-- ── public translator: a CLOSED term → a runnable Lua EXPRESSION ─────────────
--: (Term) -> string
function M.term_to_lua(t)
	return tr(t, {}, new_namegen())
end

-- ── a full runnable PROGRAM that prints the result's observable shape ────────
-- Emit a complete Lua chunk that evaluates the term and writes a single line
-- encoding the result's RUNTIME SHAPE so the host can reconstruct membership:
--   "number|<tostring>"    (e.g. number|3.5)
--   "boolean|<true|false>"
--   "nil|"
--   "string|<literal>"
--   "table|<json-ish>"   — for records: the field names/values' shapes
-- The host (exec_test.lua) parses this and checks inhabitance via the value
-- bridge's REAL predicates. We keep the encoding LINE-ORIENTED and minimal.
--: (Term) -> string
function M.program_for_shape(t)
	local expr = M.term_to_lua(t)
	-- classify the result with a small helper; records are emitted as
	-- `table|k1=<shape>;k2=<shape>` (one level — the battery records are flat).
	local lines = {
		"local __r = (" .. expr .. ")",
		"local function shp(x)",
		"  local ty = type(x)",
		"  if ty == 'number' then return 'number|' .. tostring(x) end",
		"  if ty == 'boolean' then return 'boolean|' .. tostring(x) end",
		"  if ty == 'nil' then return 'nil|' end",
		"  if ty == 'string' then return 'string|' .. x end",
		"  if ty == 'table' then",
		"    local ks = {}",
		"    for k in pairs(x) do ks[#ks+1] = k end",
		"    table.sort(ks)",
		"    local fs = {}",
		"    for _, k in ipairs(ks) do",
		"      local v = x[k]",
		"      fs[#fs+1] = tostring(k) .. '=' .. type(v) .. ':' .. tostring(v)",
		"    end",
		"    return 'table|' .. table.concat(fs, ';')",
		"  end",
		"  return ty .. '|' .. tostring(x)",
		"end",
		"io.write(shp(__r))",
	} --[[: { [integer]: string } ]]
	return table.concat(lines, "\n") .. "\n"
end

return M
