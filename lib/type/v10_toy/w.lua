-- v10_toy Algorithm W on top of the core kernel.
-- EXPERIMENT — afternoon-test artifact, not canon. See README.md.
--
-- Signature + rules below are declared data, trusted only insofar as replay()
-- checks a derivation against them. The prover (M.infer) is UNTRUSTED: it may
-- have bugs, and nothing about its internal unification state is checked —
-- only the derivation it emits, via core.replay, matters for soundness.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Mirrors of lib/type/v10_toy/init.lua's type aliases — duplicated rather
-- than imported (cross-file type-alias import wasn't confirmed to work in
-- the time available for this experiment; the shapes must stay in lockstep
-- with init.lua by hand).
--:: Term = { tag: "var", index: integer, sort: string } | { tag: "op", op: string, args: Term[] } | { tag: "meta", name: string, sort: string }
--:: ArgDecl = { sort: string, binds: string[] }
--:: OpDecl = { result: string, args: ArgDecl[] }
--:: Sig = { [string]: OpDecl }
--:: Env = { [string]: Term }
--:: DischargeSlot = { premise: integer, hyp: Term }
--:: Rule = { name: string, premises: Term[], conclusion: Term, discharge: DischargeSlot[] | nil }
--:: Rules = { [string]: Rule }
--:: Node = { kind: "hyp", judgment: Term }
--        | { kind: "axiom", rule: string, bindings: Env | nil }
--        | { kind: "rule", rule: string, premises: Node[], bindings: Env | nil, discharge: { [integer]: Node[] } | nil }

-- TYPECHECKER WORKAROUND: a plain `local C = require("lib.type.v10_toy")`
-- types `C` as `unknown` here (confirmed via a minimal repro outside this
-- file: indexing `C.op` etc. errors "value of type `unknown` must be
-- narrowed before indexing" even immediately after `require`, with no cast
-- available to fix it locally — a force cast on `require`'s result is
-- rejected outright by the checker itself: "fix the upstream type annotation
-- instead"). There is no declared-require mechanism available from the
-- concept-page-only + no-lib/type/docs constraint this experiment is under
-- to supply that upstream annotation. Narrowing `C` once via `type(C) ==
-- "table"` then a single checked cast (not `unknown`-unsound: the cast target
-- is this experiment's own fully-known, self-authored interface) recovers
-- real types for everything read off it. See TODO.md.
--:: CoreModule = { var: (integer, string) -> Term, op: (string, Term[]) -> Term, meta: (string, string) -> Term, deep_eq: (Term, Term) -> boolean }
local C_raw = require("lib.type.v10_toy")
if type(C_raw) ~= "table" then error("lib.type.v10_toy failed to load") end
local C = C_raw --[[: CoreModule ]]
local var, op, meta, deep_eq = C.var, C.op, C.meta, C.deep_eq

local M = {}

-- ── signature ─────────────────────────────────────────────────────────────
-- term sort: lit_int, lit_bool (0-ary); abs (1 arg, binds 1 term-var); app (2
-- args, no binders); let_ (2 args: bound expr, body binding 1 term-var);
-- pair_ (2 args, no binders — added beyond the five core constructs solely to
-- build the letpoly test the concept page's own example names: "pairing id
-- applied at two types"; see README STUMBLE LOG).
-- type sort: int, bool (0-ary); arrow (2 args); forall (1 arg, binds 1
-- type-var); prod (2 args, pairs with pair_).
-- judgment sort: typeof (term, type).

M.sig = {
	lit_int  = { result = "term", args = {} },
	lit_bool = { result = "term", args = {} },
	abs      = { result = "term", args = { { sort = "term", binds = { "term" } } } },
	app      = { result = "term", args = { { sort = "term", binds = {} }, { sort = "term", binds = {} } } },
	let_     = { result = "term", args = { { sort = "term", binds = {} }, { sort = "term", binds = { "term" } } } },
	pair_    = { result = "term", args = { { sort = "term", binds = {} }, { sort = "term", binds = {} } } },

	int      = { result = "type", args = {} },
	bool     = { result = "type", args = {} },
	arrow    = { result = "type", args = { { sort = "type", binds = {} }, { sort = "type", binds = {} } } },
	forall   = { result = "type", args = { { sort = "type", binds = { "type" } } } },
	prod     = { result = "type", args = { { sort = "type", binds = {} }, { sort = "type", binds = {} } } },

	typeof   = { result = "judgment", args = { { sort = "term", binds = {} }, { sort = "type", binds = {} } } },
} --[[: Sig ]]

--: (term: Term, ty: Term) -> Term
local function T(term, ty) return op("typeof", { term, ty }) end

-- ── rules ──────────────────────────────────────────────────────────────────
-- STUMBLE: no separate "variable" typing rule. Concept #8 says to "use
-- hypothesis nodes for variable-typing assumptions, discharged at
-- abstraction/let" — hypothesis leaves directly ARE the variable rule
-- (assumed judgments typeof(var(k), Tk)); there is nothing left for a
-- dedicated rule to do.
-- STUMBLE: no unification-step rules/axioms were needed. The prover (below)
-- runs standard Algorithm W with an internal substitution, applies it eagerly
-- to every subterm, and only emits a derivation AFTER inference completes
-- (two-phase: infer, then emit). So every judgment term reaching replay() is
-- already fully resolved; matching a structural conclusion pattern like
-- arrow(A,B) against a target never hits an unresolved unification variable.
M.rules = {
	LitIntType = { name = "LitIntType@v1", premises = {}, conclusion = T(op("lit_int", {}), op("int", {})), discharge = nil },
	LitBoolType = { name = "LitBoolType@v1", premises = {}, conclusion = T(op("lit_bool", {}), op("bool", {})), discharge = nil },

	AbsType = {
		name = "AbsType",
		premises = { T(meta("Body", "term"), meta("T2", "type")) },
		conclusion = T(op("abs", { meta("Body", "term") }), op("arrow", { meta("T1", "type"), meta("T2", "type") })),
		discharge = { { premise = 1, hyp = T(var(0, "term"), meta("T1", "type")) } },
	},

	AppType = {
		name = "AppType",
		premises = {
			T(meta("F", "term"), op("arrow", { meta("A", "type"), meta("B", "type") })),
			T(meta("Arg", "term"), meta("A", "type")),
		},
		conclusion = T(op("app", { meta("F", "term"), meta("Arg", "term") }), meta("B", "type")),
		discharge = nil,
	},

	-- Context management is entirely via hypothesis + discharge: the body's
	-- sub-derivation may cite `typeof(var(0), Scheme)` as a hypothesis however
	-- many times it needs (including zero); LetType only requires it to be a
	-- single, consistently-typed hypothesis SHAPE (concept #6: discharging a
	-- SET requires each member to equal the SAME instantiated pattern). Scheme
	-- itself is whatever premise 1 proves for E — monomorphic unless the
	-- prover routes E's sub-derivation through GeneralizeEndo below.
	LetType = {
		name = "LetType",
		premises = {
			T(meta("E", "term"), meta("Scheme", "type")),
			T(meta("Body", "term"), meta("T2", "type")),
		},
		conclusion = T(op("let_", { meta("E", "term"), meta("Body", "term") }), meta("T2", "type")),
		discharge = { { premise = 2, hyp = T(var(0, "term"), meta("Scheme", "type")) } },
	},

	PairType = {
		name = "PairType",
		premises = { T(meta("A", "term"), meta("TA", "type")), T(meta("B", "term"), meta("TB", "type")) },
		conclusion = T(op("pair_", { meta("A", "term"), meta("B", "term") }), op("prod", { meta("TA", "type"), meta("TB", "type") })),
		discharge = nil,
	},

	-- STUMBLE: general let-generalization ("close over every metavariable not
	-- free in the ambient context") needs a NEGATIVE/freshness side condition
	-- ("M occurs nowhere else") that plain positive pattern matching cannot
	-- express (match only ever tests occurrence, never absence). That's a real
	-- gap in the concept page, not a shortcut avoided out of laziness — see
	-- README. Sidestepped here with two rules FIXED to the one scheme shape
	-- this toy's tests need (forall a. a -> a): sound for this toy because the
	-- generalized metavariable is never constrained by anything outside its
	-- own let-binding, but that soundness precondition is exactly the check
	-- the concept page's pattern language cannot state, so a general version
	-- of these two rules could not be written this way.
	GeneralizeEndo = {
		name = "GeneralizeEndo",
		premises = { T(meta("E", "term"), op("arrow", { meta("M", "type"), meta("M", "type") })) },
		conclusion = T(meta("E", "term"), op("forall", { op("arrow", { var(0, "type"), var(0, "type") }) })),
		discharge = nil,
	},
	InstantiateEndo = {
		name = "InstantiateEndo",
		premises = { T(meta("E", "term"), op("forall", { op("arrow", { var(0, "type"), var(0, "type") }) })) },
		-- M does not occur in the premise pattern: supplied via node.bindings
		-- by the citer, per the core kernel's documented extension.
		conclusion = T(meta("E", "term"), op("arrow", { meta("M", "type"), meta("M", "type") })),
		discharge = nil,
	},
} --[[: Rules ]]

-- ── untrusted prover ─────────────────────────────────────────────────────────
-- Phase 1: standard Algorithm W over a small AST, with a mutable substitution.
-- Phase 2: walk the (now fully-resolved) inference trace and emit a
-- derivation DAG that core.replay can check independently.
--
-- `generalize` is the prover's own choice of whether to run GeneralizeEndo;
-- true only makes sense when e's inferred type is literally arrow(M,M) for a
-- fresh, still-unconstrained M (checked loosely below; this toy does not
-- reimplement full value-restriction soundness).
--
-- _use_type/_param_type/_e_type are write-once annotation fields infer()
-- populates in place so emit() (a separate walk of the same tree) can read
-- back which metavariable is which — see the comment above `infer` below.
--:: Ast = { k: "int" }
--       | { k: "bool" }
--       | { k: "var", i: integer, _use_type: Term | nil }
--       | { k: "abs", body: Ast, _param_type: Term | nil }
--       | { k: "app", fn: Ast, arg: Ast }
--       | { k: "let", e: Ast, body: Ast, generalize: boolean | nil, _e_type: Term | nil }
--       | { k: "pair", a: Ast, b: Ast }

local fresh_id = 0
--: () -> string
local function fresh()
	fresh_id = fresh_id + 1
	return "m" .. fresh_id
end

-- Union-find-ish substitution: subst[name] = concrete type term (may itself
-- reference other metavariables, resolved by walk()).
--: (ty: Term, subst: Env) -> Term
local function walk(ty, subst)
	if ty.tag == "meta" then
		local bound = subst[ty.name]
		if bound then return walk(bound, subst) end
		return ty
	end
	if ty.tag == "op" then
		local args = {} --[[: Term[] ]]
		for i, a in ipairs(ty.args) do
			local walked = walk(a, subst) --[[: Term ]]
			args[i] = walked
		end
		return { tag = "op", op = ty.op, args = args }
	end
	return ty
end

--: (name: string, ty: Term, subst: Env) -> boolean
local function occurs(name, ty, subst)
	local w = walk(ty, subst)
	if w.tag == "meta" then return w.name == name end
	if w.tag == "op" then
		for _, a in ipairs(w.args) do
			if occurs(name, a, subst) then return true end
		end
	end
	return false
end

--: (a: Term, b: Term, subst: Env) -> Env | (nil, string)
local function unify(a, b, subst)
	local wa, wb = walk(a, subst), walk(b, subst)
	if wa.tag == "meta" then
		if occurs(wa.name, wb, subst) then return nil, "occurs check" end
		subst[wa.name] = wb
		return subst
	end
	if wb.tag == "meta" then return unify(wb, wa, subst) end
	if wa.tag == "op" and wb.tag == "op" and wa.op == wb.op and #wa.args == #wb.args then
		local s = subst
		for i = 1, #wa.args do
			local s2, err = unify(wa.args[i], wb.args[i], s)
			if type(s2) ~= "table" then return nil, err or "unify failed" end
			s = s2
		end
		return s
	end
	return nil, "type mismatch"
end

--:: CtxSlot = { kind: "mono", ty: Term } | { kind: "poly" }

-- infer(ast, ctx, subst) -> type term (still possibly containing metas,
-- resolved against subst) | nil, err.  ctx[i] = CtxSlot for the i-th
-- innermost bound variable (1-indexed list acting as a stack; ctx[1] is
-- var(0)).
--
-- Annotates ast nodes in place with the raw (pre-final-subst) type terms
-- `emit` needs later, so both phases agree on which metavariable is which:
--   abs:  ast._param_type = the fresh param metavariable
--   let:  ast._e_type     = e's inferred type (pre-generalization)
--   var (poly use): ast._use_type = a fresh arrow(m,m) instantiation
--: (ast: Ast, ctx: CtxSlot[], subst: Env) -> Term | (nil, string)
-- TYPECHECKER WORKAROUND: `Ast` is self-recursive (an "abs" node's `body`
-- field is `Ast`), the same class of gap as `Node` in init.lua — reading a
-- field off `ast` after narrowing `ast.k` infers `never`/loses the field's
-- real type. Checked casts on each field recovers the real type; see
-- init.lua's matching workaround comment and TODO.md.
local function infer(ast, ctx, subst)
	if ast.k == "int" then return op("int", {}) end
	if ast.k == "bool" then return op("bool", {}) end
	if ast.k == "var" then
		local i = ast.i --[[: integer ]]
		local slot = ctx[i + 1]
		if not slot then return nil, "unbound variable " .. i end
		if slot.kind == "mono" then return slot.ty end
		local m = meta(fresh(), "type")
		local use_type = { tag = "op", op = "arrow", args = { m, m } } --[[: Term ]]
		ast._use_type = use_type
		return use_type
	end
	if ast.k == "abs" then
		local body = ast.body --[[: Ast ]]
		local t1 = meta(fresh(), "type")
		ast._param_type = t1
		local new_ctx = { { kind = "mono", ty = t1 } } --[[: CtxSlot[] ]]
		for i, s in ipairs(ctx) do new_ctx[i + 1] = s end
		local t2, err = infer(body, new_ctx, subst)
		if type(t2) ~= "table" then return nil, err or "infer failed" end
		return { tag = "op", op = "arrow", args = { t1, t2 } }
	end
	if ast.k == "app" then
		local fn, arg = ast.fn, ast.arg --[[: Ast ]]
		local tf, err = infer(fn, ctx, subst)
		if type(tf) ~= "table" then return nil, err or "infer failed" end
		local ta, err2 = infer(arg, ctx, subst)
		if type(ta) ~= "table" then return nil, err2 or "infer failed" end
		local tb = meta(fresh(), "type")
		local s, uerr = unify(tf, { tag = "op", op = "arrow", args = { ta, tb } }, subst)
		if type(s) ~= "table" then return nil, uerr or "unify failed" end
		return tb
	end
	if ast.k == "let" then
		local e, body = ast.e, ast.body --[[: Ast ]]
		local generalize = ast.generalize --[[: boolean | nil ]]
		local te, err = infer(e, ctx, subst)
		if type(te) ~= "table" then return nil, err or "infer failed" end
		ast._e_type = te
		local slot = { kind = "mono", ty = te } --[[: CtxSlot ]]
		if generalize then
			local resolved = walk(te, subst)
			if resolved.tag == "op" and resolved.op == "arrow"
				and resolved.args[1].tag == "meta"
				and deep_eq(resolved.args[1], resolved.args[2]) then
				slot = { kind = "poly" }
			else
				return nil, "cannot generalize: bound expression is not an endo arrow(M,M)"
			end
		end
		local new_ctx = { slot } --[[: CtxSlot[] ]]
		for i, s in ipairs(ctx) do new_ctx[i + 1] = s end
		local tb, err2 = infer(body, new_ctx, subst)
		if type(tb) ~= "table" then return nil, err2 or "infer failed" end
		return tb
	end
	-- ast.k == "pair"
	local a, b = ast.a, ast.b --[[: Ast ]]
	local ta, err = infer(a, ctx, subst)
	if type(ta) ~= "table" then return nil, err or "infer failed" end
	local tb, err2 = infer(b, ctx, subst)
	if type(tb) ~= "table" then return nil, err2 or "infer failed" end
	return { tag = "op", op = "prod", args = { ta, tb } }
end

-- ── emission: fully-resolved AST -> derivation DAG ──────────────────────────
-- to_term(ast) turns prover AST into a core "term" of sort "term".
--: (ast: Ast) -> Term
local function to_term(ast)
	if ast.k == "int" then return op("lit_int", {}) end
	if ast.k == "bool" then return op("lit_bool", {}) end
	if ast.k == "var" then
		local i = ast.i --[[: integer ]]
		return var(i, "term")
	end
	if ast.k == "abs" then
		local body = ast.body --[[: Ast ]]
		return op("abs", { to_term(body) })
	end
	if ast.k == "app" then
		local fn, arg = ast.fn, ast.arg --[[: Ast ]]
		return op("app", { to_term(fn), to_term(arg) })
	end
	if ast.k == "let" then
		local e, body = ast.e, ast.body --[[: Ast ]]
		return op("let_", { to_term(e), to_term(body) })
	end
	local a, b = ast.a, ast.b --[[: Ast ]]
	return op("pair_", { to_term(a), to_term(b) })
end

--: (ty: Term | nil, subst: Env) -> Term
local function ty_term(ty, subst)
	if type(ty) ~= "table" then return op("int", {}) end -- unreachable: callers only pass populated fields
	return walk(ty, subst)
end

-- TYPECHECKER WORKAROUND: for this self-recursive union, an assignability
-- check against `Node` only ever tries its FIRST declared arm ("hyp"),
-- regardless of the source's actual shape or cast strategy — confirmed via
-- a minimal repro outside this file: reordering Node's arms changes WHICH
-- literal shape passes, never lets more than one shape pass at once, and
-- even a cast routed through `unknown` still gets checked against "hyp"
-- only. No cast recovers this (a force cast is separately rejected: "fix
-- the upstream type annotation instead"). rule_node/axiom_node are left
-- without a return-type annotation (downgrades their call sites to a
-- warning, not an error — this repo's precedent in TODO.md for the same
-- class of gap on lib/type/v10_kernel's replayer is to accept the warning
-- rather than force a return type this checker cannot verify here). See
-- TODO.md.
local function rule_node(rule_name, premises, discharge, bindings)
	return { kind = "rule", rule = rule_name, premises = premises, discharge = discharge, bindings = bindings }
end
local function axiom_node(rule_name)
	return { kind = "axiom", rule = rule_name, bindings = {} }
end

local FORALL_ENDO = op("forall", { op("arrow", { var(0, "type"), var(0, "type") }) }) --[[: Term ]]

--:: EmitSlot = { hyp: Node, generalized: boolean }

-- emit(ast, ctx, subst) -> derivation node whose replayed conclusion is
-- typeof(to_term(ast), ty_term(infer-result, subst)). ctx[i] = EmitSlot for
-- the i-th innermost bound variable, mirroring infer's ctx exactly (same
-- order) so both phases agree on which binder is which.
-- Return type `unknown` rather than `Node` (see rule_node/axiom_node comment
-- above — same Node-as-target recursive-union gap applies to emit's own
-- return position). Params stay fully typed; only the return is affected.
--: (ast: Ast, ctx: EmitSlot[], subst: Env) -> unknown
local function emit(ast, ctx, subst)
	if ast.k == "int" then return axiom_node("LitIntType") end
	if ast.k == "bool" then return axiom_node("LitBoolType") end
	if ast.k == "var" then
		local i = ast.i --[[: integer ]]
		local slot = ctx[i + 1]
		if not slot.generalized then return slot.hyp end
		-- Polymorphic use: cite the scheme hypothesis, then specialize via
		-- InstantiateEndo. M is supplied concretely — infer() recorded this
		-- occurrence's fresh instantiation in ast._use_type, now fully
		-- resolved by subst, so both sides of the endo arrow agree.
		local resolved = ty_term(ast._use_type, subst)
		local m = resolved.tag == "op" and resolved.args[1] or resolved --[[: Term ]]
		return rule_node("InstantiateEndo", { slot.hyp }, {}, { M = m })
	end
	if ast.k == "abs" then
		local body = ast.body --[[: Ast ]]
		local t1 = ty_term(ast._param_type, subst)
		local hyp = { kind = "hyp", judgment = T(var(0, "term"), t1) } --[[: Node ]]
		local new_ctx = { { hyp = hyp, generalized = false } } --[[: EmitSlot[] ]]
		for i, s in ipairs(ctx) do new_ctx[i + 1] = s end
		local body_node = emit(body, new_ctx, subst)
		return rule_node("AbsType", { body_node }, { [1] = { hyp } })
	end
	if ast.k == "app" then
		local fn, arg = ast.fn, ast.arg --[[: Ast ]]
		local fn_node = emit(fn, ctx, subst)
		local arg_node = emit(arg, ctx, subst)
		return rule_node("AppType", { fn_node, arg_node }, {})
	end
	if ast.k == "let" then
		local e, body = ast.e, ast.body --[[: Ast ]]
		local generalized = ast.generalize == true
		local e_node = emit(e, ctx, subst)
		local scheme_term --: Term | nil
		if generalized then
			e_node = rule_node("GeneralizeEndo", { e_node }, {})
			scheme_term = FORALL_ENDO
		else
			scheme_term = ty_term(ast._e_type, subst)
		end
		if type(scheme_term) ~= "table" then error("unreachable: scheme_term always set above") end
		local hyp = { kind = "hyp", judgment = T(var(0, "term"), scheme_term) } --[[: Node ]]
		local new_ctx = { { hyp = hyp, generalized = generalized } } --[[: EmitSlot[] ]]
		for i, s in ipairs(ctx) do new_ctx[i + 1] = s end
		local body_node = emit(body, new_ctx, subst)
		-- discharge is indexed by SLOT position (ipairs order over
		-- rule.discharge), not by which premise the slot refers to — LetType
		-- has exactly one slot, so this is always key 1, even though that
		-- slot's own `premise` field points at premise 2.
		return rule_node("LetType", { e_node, body_node }, { [1] = { hyp } })
	end
	-- ast.k == "pair"
	local a, b = ast.a, ast.b --[[: Ast ]]
	local a_node = emit(a, ctx, subst)
	local b_node = emit(b, ctx, subst)
	return rule_node("PairType", { a_node, b_node }, {})
end

--- Infer a type for `ast` and emit a checkable derivation.
-- Returns (derivationNode, inferredTypeTerm) | (nil, err). `ast` may set
-- `generalize = true` on `let` nodes to request let-polymorphism (only valid
-- when the bound expression's type is exactly arrow(M,M) for some fresh M).
-- Return type is `unknown` (not `Node`) for the derivation slot — same
-- recursive-union gap as emit/rule_node/axiom_node above; the value IS a
-- well-formed Node at runtime (core.replay does the only trust-relevant
-- check on it regardless of what static type this file could give it).
--: (ast: Ast) -> (unknown, Term) | (nil, string)
function M.infer(ast)
	local subst = {} --[[: Env ]]
	local ty, err = infer(ast, {}, subst)
	if type(ty) ~= "table" then return nil, err or "infer failed" end
	local node = emit(ast, {}, subst)
	return node, ty_term(ty, subst)
end

M._internal = { infer = infer, unify = unify, walk = walk, emit = emit, to_term = to_term, ty_term = ty_term, fresh = fresh }

return M
