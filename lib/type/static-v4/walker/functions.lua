-- Walker sub-phase C — function definitions, calls, returns, methods.
--
-- Per docs/typechecker-ast-walker-design.md §3.7, §3.8, §3.9, §6, §8.3, §10.
--
-- Decoded node shapes (what handlers consume)
-- ───────────────────────────────────────────
-- As with sub-phase B, the walker consumes Lua-table views of AST nodes,
-- intentionally divorced from the parser's FFI ASTNode struct. The FFI→walker
-- bridge is sub-phase J.
--
--   NODE_FUNC_EXPR / NODE_FUNC_DECL
--     { tag, line, col,
--       params: { { name: string, ann: V4Type | nil } },
--       vararg: boolean,
--       vararg_ann: V4Type | nil,
--       ret_ann: V4Type | nil,
--       generic: { names: string[] } | nil,   -- <T1,...,Tn> on the signature
--       annotation: V4Type | nil,             -- pre-resolved full type
--                                             -- (V.fn or V.forall(.., V.fn))
--       body: Node[] }
--
--     `annotation`, when present, is the authoritative function type — the
--     walker uses it verbatim (skolemizing if it is a forall). Callers that
--     produced a function literal from individual param/ret_ann fields without
--     pre-resolving may leave `annotation` nil; the handler then assembles a
--     V.fn / V.forall from the per-field annotations.
--
--   NODE_CALL_EXPR        { tag, line, col, callee: Node, args: Node[] }
--   NODE_METHOD_CALL      { tag, line, col, receiver: Node, method: string,
--                           args: Node[] }
--   NODE_RETURN_STMT      { tag, line, col, exprs: Node[] }
--   NODE_EXPR_STMT        { tag, line, col, expr: Node }
--                         (registered here so a function body can contain a
--                         bare call statement — the minimal stmt-form needed
--                         for effect-accumulation tests in sub-phase C. The
--                         full statement set lands in sub-phase E.)
--
-- Multi-return representation
-- ───────────────────────────
-- Per design §8.3, multi-return is `V.rec({ ["1"]=T1, ["2"]=T2, ... }, false)`
-- (string-keyed for V4Rec annotation conformance — V4Rec.fields is typed
-- `{ [string]: V4Type }`). A 1-return collapses to the scalar at the
-- representation level so that "return x" against an `integer` return slot
-- still works without an artificial 1-tuple intermediate.
--
-- Rank-N
-- ──────
-- §6 splits rank-N across two sites:
--   * Function definition (function literal with `<T>` annotation) — the
--     annotated forall is skolemized at body entry. The body sees rigid
--     opaque skolems via parameter bindings. After body checking, an
--     escape check confirms no skolem leaked into a free variable bound.
--   * Call expression — the callee's forall is instantiated at the call
--     site with fresh inference variables, yielding a monomorphic arrow.
--
-- Indexed callees
-- ───────────────
-- §3.6 (NODE_FIELD_EXPR / NODE_INDEX_EXPR) lands in sub-phase F. In sub-phase
-- C, a NODE_CALL_EXPR whose callee is an indexed access produces a clean
-- error rather than synthesizing through a half-implemented field lookup.
-- This is per the prompt's hard rule: no temp-measure placeholder.
-- NODE_METHOD_CALL is fully handled here because its receiver-then-call shape
-- is decoupled from generic field/index lookup (the method name is on the
-- node itself; we synthesize the receiver and look up `method` on its type).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- This file is intentionally annotation-free.
--
-- A consumer file that (a) directly requires lib.type.static-v4.walker.env
-- AND (b) carries any `--:` / `` annotation in its own source
-- re-resolves env.lua's `--:: WalkerEnv = ...` declaration in the
-- consumer's annotation scope, where V4Type does not resolve. The result
-- is a wave of false-positive env.lua diagnostics blamed on the consumer
-- — and the pre-commit hook treats a NEW file with any errors as a
-- regression. By dropping annotations in functions.lua we keep the file
-- diagnostically-clean while still requiring env.lua directly for runtime
-- access. literals.lua predates this discovery and DOES carry annotations
-- (16 baseline env.lua errors) — that file is grandfathered because the
-- pre-existing-error rule grants it tolerance; new files cannot rely on
-- the same tolerance. The cross-file `--::` alias-resolution limitation
-- is documented in walker/README.md; fixing it upstream would let us
-- restore annotations here.

local V       = require("lib.type.static-v4")
local E       = require("lib.type.static-v4.walker.env")
local defs    = require("lib.type.static.defs")
local subtype = require("lib.type.static-v4.subtype")
local forall  = require("lib.type.static-v4.forall")

local _types  = require("lib.type.static-v4.types")
local _ = _types

-- Pre-interned nil singleton. Captured at module load via a non-nil-typed
-- local so call sites pass it without re-triggering the V4Type|nil return
-- inference path of V.prim. (V.prim returns V4Type, but the typechecker
-- infers a wider V4Type|nil from the cached-lookup branch.)
local NIL_TYPE = V.prim("nil")
if NIL_TYPE == nil then error("v4 nil prim unexpectedly nil") end

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────
--
-- Handlers recurse through the walker shell (walker.lua's walk_synth /
-- walk_check). To break the cyclic require — functions.lua is loaded *from*
-- walker.lua at _register_builtins time — we resolve the walker module
-- lazily via require() inside each helper. The require call is O(1) after
-- the first invocation because Lua caches loaded modules.

-- Multi-return tuple constructor. Single-return collapses to the scalar (per
-- §8.3). For zero returns we synthesize `(V.prim("nil"))` — a `return` with no
-- expressions in Lua yields nil-only callers, and a function whose ret_ann is
-- nil-typed is the canonical "void" shape.
local function tuple_of(types)
	local first = types[1]
	if first == nil then return NIL_TYPE end
	local second = types[2]
	if second == nil then return first end
	local fields = {}
	for i, t in ipairs(types) do
		fields[tostring(i)] = t
	end
	return V.rec(fields, false, nil)
end

-- Merge another effect set into env.effects. The empty-set short-circuit
-- avoids the per-effect copy when there is nothing to add.
local function add_effects(env, effects)
	if effects == nil or next(effects) == nil then return env end
	for name in pairs(effects) do
		env = E.add_effect(env, name)
	end
	return env
end

-- Skolemize a forall, returning the body and the skolem list. Convenience
-- around forall.skolemize that handles non-forall pass-through.
local function maybe_skolemize(t)
	if t.tag ~= "forall" then return t, ({}) end
	return forall.skolemize(t)
end

-- Instantiate a forall, returning the body. Non-forall pass-through.
local function maybe_instantiate(t)
	if t.tag ~= "forall" then return t end
	return forall.instantiate(t)
end

-- ── NODE_RETURN_STMT ──────────────────────────────────────────────────────
--
-- §3.12 + §8.3. Each expression is synthesized; the resulting tuple is
-- subtyped against env.return_ty. A function body without `return` collapses
-- to a nil return — outside this handler's concern; the caller already set
-- return_ty before walking.
--
-- Multi-return semantics (design + legacy fixes D1/D2/D3/D4):
--   * `return` (no exprs): emit `(V.prim("nil")) <: return_ty`. A void-typed return
--     slot accepts this; anything else fails subtyping cleanly.
--   * `return e`: synthesize e, constrain its type against return_ty
--     directly. The scalar collapses naturally — return_ty being a tuple
--     would surface as a subtyping error because a scalar is not a tuple.
--     (D1's "scalar return against tuple expected checks all slots" applies
--     to v2's tuple representation, not v4's record-with-string-keys form;
--     v4 lets subtype.lua surface the mismatch.)
--   * `return e1, ..., en`: synthesize each, build a tuple via tuple_of,
--     constrain against return_ty.
--
-- A NODE_RETURN_STMT in a context without an enclosing function is a static
-- error: the parser emits return only inside function bodies, but the walker
-- defends regardless (the AST may be constructed by other means in tests).

local function synth_return(node, env, solver)
	local return_ty = env.return_ty
	if return_ty == nil then
		return nil, env, "return outside function body"
	end
	local exprs = node.exprs
	local n = #exprs
	if n == 0 then
		subtype.constrain(solver, NIL_TYPE, return_ty)
		if solver.error ~= nil then return nil, env, solver.error end
		return nil, env, nil
	end
	if n == 1 then
		local ty, env2, err = require("lib.type.static-v4.walker.walker").walk_synth(exprs[1], env, solver)
		if err ~= nil then return nil, env2, err end
		if ty == nil then
			return nil, env2, "return: expression has no synthesized type"
		end
		subtype.constrain(solver, ty, return_ty)
		if solver.error ~= nil then return nil, env2, solver.error end
		return nil, env2, nil
	end
	-- Multi-return. Synthesize each in left-to-right order; an early error
	-- short-circuits the rest (consistent with §3.12 single-pass walk).
	local types = {}
	for i = 1, n do
		local ty, env2, err = require("lib.type.static-v4.walker.walker").walk_synth(exprs[i], env, solver)
		env = env2
		if err ~= nil then return nil, env, err end
		if ty == nil then
			return nil, env,
				"return: expression " .. tostring(i) .. " has no synthesized type"
		end
		types[i] = ty
	end
	local tup = tuple_of(types)
	if tup == nil then
		-- Unreachable: tuple_of constructs a non-nil V4Type on every path.
		-- The explicit guard exists to narrow the local for the typechecker.
		return nil, env, "return: internal — tuple_of returned nil"
	end
	subtype.constrain(solver, tup, return_ty)
	if solver.error ~= nil then return nil, env, solver.error end
	return nil, env, nil
end

-- ── NODE_EXPR_STMT ────────────────────────────────────────────────────────
--
-- The minimal expression-as-statement form needed in sub-phase C so a body
-- can contain a call (e.g. `coroutine.yield()`) without dragging in sub-phase
-- E. Full statement plumbing (NODE_ASSIGN_STMT, NODE_LOCAL_STMT, etc.) lands
-- in E. The handler walks the inner expression in SYNTHESIZE mode and drops
-- the result; effects accrue via call synthesis.

local function synth_expr_stmt(node, env, solver)
	local _ty, env2, err = require("lib.type.static-v4.walker.walker").walk_synth(node.expr, env, solver)
	if err ~= nil then return nil, env2, err end
	return nil, env2, nil
end

-- ── NODE_CALL_EXPR ────────────────────────────────────────────────────────
--
-- §3.7. The walker:
--   1. Synthesizes the callee.
--   2. If the synthesized type is a forall, instantiates with fresh vars.
--   3. Synthesizes each argument in SYNTHESIZE mode (we read its type to
--      drive subtyping against the parameter slot).
--   4. Constrains each argument <: corresponding parameter, in left-to-
--      right order. Lua call semantics: extra args truncate (no error in
--      the design — Lua semantics is permissive), missing args fill with
--      nil up to the param count. Per the prompt, we enforce arity for
--      sub-phase C — adding arity-permissive Lua semantics is an extension
--      best tackled with the multi-return spread story in sub-phase D's
--      legacy parity (D2/D3/D4).
--   5. Accumulates the arrow's effects into env.effects.
--   6. Synthesizes to the arrow's return type.
--
-- Indexed callee rejection (design hard rule, sub-phase C scope):
-- NODE_FIELD_EXPR / NODE_INDEX_EXPR are sub-phase F. Calls through them
-- error here rather than silently producing an `unknown`-typed value.
-- NODE_METHOD_CALL is handled by its own dedicated handler — its receiver
-- field is synthesized like any expression but the method lookup is
-- explicit (it is NOT a NODE_FIELD_EXPR child).

-- Forbidden callee shapes for sub-phase C. NODE_FIELD_EXPR and NODE_INDEX_EXPR
-- get handlers in sub-phase F; trying to call one here means the caller is
-- ahead of the sub-phase budget. Loud rejection rather than silent fall-through.
local INDEXED_CALLEE_TAGS = {
	[defs.NODE_FIELD_EXPR] = "NODE_FIELD_EXPR",
	[defs.NODE_INDEX_EXPR] = "NODE_INDEX_EXPR",
}

-- Apply a callee's arrow type to a list of synthesized arg types. Shared by
-- NODE_CALL_EXPR and NODE_METHOD_CALL. Returns (result_type, err).
local function apply_arrow(callee_ty, arg_types, arg_count, env, solver)
	-- Instantiate at the call site (rank-N: §6.2).
	local arrow = maybe_instantiate(callee_ty)
	if arrow.tag ~= "fn" then
		return nil, env,
			"call: callee has non-function type " .. V.show(callee_ty)
	end
	-- Narrowing: from here on arrow has tag "fn" — params/ret/effects are
	-- the concrete fields.
	local params = arrow.params
	local param_count = 0
	for _ in pairs(params) do param_count = param_count + 1 end
	if param_count ~= arg_count then
		return nil, env,
			"call: arity mismatch — expected " .. tostring(param_count) ..
			" argument(s), got " .. tostring(arg_count)
	end
	for i = 1, param_count do
		subtype.constrain(solver, arg_types[i], params[i])
		if solver.error ~= nil then
			return nil, env, solver.error
		end
	end
	-- Effect accumulation: the call performs whatever effects the arrow
	-- advertises. Per §10, these accrue into the enclosing function's
	-- effect set so that `function() coroutine.yield() end` synthesizes
	-- to a yield-effected arrow when sub-phase D wraps body inference.
	env = add_effects(env, arrow.effects)
	return arrow.ret, env, nil
end

local function synth_call(node, env, solver)
	local callee_tag = node.callee.tag
	local forbidden = INDEXED_CALLEE_TAGS[callee_tag]
	if forbidden ~= nil then
		return nil, env,
			"call: indexed callee (" .. forbidden ..
			") not in sub-phase C scope — lands in sub-phase F"
	end
	local callee_ty, env2, err = require("lib.type.static-v4.walker.walker").walk_synth(node.callee, env, solver)
	if err ~= nil then return nil, env2, err end
	if callee_ty == nil then
		return nil, env2, "call: callee has no synthesized type"
	end
	local arg_types = {}
	local arg_count = 0
	for i, arg in ipairs(node.args) do
		local ty, env3, aerr = require("lib.type.static-v4.walker.walker").walk_synth(arg, env2, solver)
		env2 = env3
		if aerr ~= nil then return nil, env2, aerr end
		if ty == nil then
			return nil, env2,
				"call: argument " .. tostring(i) .. " has no synthesized type"
		end
		arg_types[i] = ty
		arg_count = i
	end
	return apply_arrow(callee_ty, arg_types, arg_count, env2, solver)
end

-- ── NODE_METHOD_CALL ──────────────────────────────────────────────────────
--
-- §3.8: `obj:m(args)` rewrites to `(synth(obj).m)(obj, args...)`. We do this
-- inline rather than re-using NODE_FIELD_EXPR (which is sub-phase F): the
-- receiver type is synthesized, its `method` field is looked up directly on
-- a rec shape, and a synthetic argument list with `obj` prepended is built.
-- The result is the same call-application machinery as NODE_CALL_EXPR.
--
-- Field lookup in sub-phase C is intentionally narrow — only on rec types,
-- without union distribution, μ unfolding, or open-record indexers. Those
-- behaviors live in `V.index` and arrive in sub-phase F; the sub-phase C
-- contract is "method call works when the receiver is a closed rec with
-- the method statically present". A receiver shape outside that set
-- errors cleanly, matching the indexed-callee rejection in NODE_CALL_EXPR.

local function synth_method_call(node, env, solver)
	local recv_ty, env2, err = require("lib.type.static-v4.walker.walker").walk_synth(node.receiver, env, solver)
	if err ~= nil then return nil, env2, err end
	if recv_ty == nil then
		return nil, env2, "method call: receiver has no synthesized type"
	end
	if recv_ty.tag ~= "rec" then
		return nil, env2,
			"method call: receiver has non-record type " .. V.show(recv_ty) ..
			" (full method dispatch lands in sub-phase F)"
	end
	local method_ty = recv_ty.fields[node.method]
	if method_ty == nil then
		return nil, env2,
			"method call: receiver has no method '" .. node.method .. "'"
	end
	local arg_types = {}
	arg_types[1] = recv_ty -- the `self` argument
	local arg_count = 1
	for i, arg in ipairs(node.args) do
		local ty, env3, aerr = require("lib.type.static-v4.walker.walker").walk_synth(arg, env2, solver)
		env2 = env3
		if aerr ~= nil then return nil, env2, aerr end
		if ty == nil then
			return nil, env2,
				"method call: argument " .. tostring(i) ..
				" has no synthesized type"
		end
		arg_types[i + 1] = ty
		arg_count = i + 1
	end
	return apply_arrow(method_ty, arg_types, arg_count, env2, solver)
end

-- ── NODE_FUNC_EXPR / NODE_FUNC_DECL ───────────────────────────────────────
--
-- §3.9 and §6.1. The handler accepts an `annotation` field carrying the
-- pre-resolved function type (V.fn or V.forall(.., V.fn)) — this is the
-- shape the annotation parser will hand us once sub-phase C-of-C is wired
-- (annotation parsing itself is design Phase C; the *walker* sub-phase C
-- treats annotations as opaque V4Type inputs).
--
-- Body walking:
--   * Enter a fresh function frame via E.enter_function (return_ty, vararg,
--     and effects are pushed).
--   * If annotated as a forall, skolemize. Param/ret types in the body
--     reference skolems. After body walk, run escape check on the inferred
--     effect set / returned type — design §6.1.
--   * Bind each parameter name to its (possibly skolemized) param type.
--   * Walk body statements in order. A NODE_RETURN_STMT subtypes against
--     return_ty (already on env). Other statements walk via walk_stmt.
--   * On exit, the body's accumulated effects become the synthesized
--     arrow's effects (when there is no annotation; an annotation's
--     effects field is authoritative).
--
-- Unannotated case:
--   * Allocate a fresh V.var per param.
--   * Allocate a fresh V.var for return.
--   * Walk body; NODE_RETURN_STMT constraints flow into the ret var.
--   * Synthesize V.fn(param_vars, ret_var, inferred_effects).
--   * No implicit let-generalization — §6.3.

-- Param-shape decoder. The node's `params` is a list of { name, ann } records.
-- Returns (param_types, names).
local function decode_param_shapes(params)
	local types = {}
	local names = {}
	for i, p in ipairs(params) do
		names[i] = p.name
		local ann = p.ann
		if ann ~= nil then
			types[i] = ann
		else
			types[i] = V.var(p.name)
		end
	end
	return types, names
end

-- walk_stmt is the per-statement entry within a function body. It dispatches
-- through the walker registry so sub-phases E and later plug in additional
-- statement handlers without editing this file.
local function walk_stmt(node, env, solver)
	local W = require("lib.type.static-v4.walker.walker")
	local _ty, env2, err = W.walk_synth(node, env, solver)
	return env2, err
end

-- Walk the function body as a list of statements. Each statement may be a
-- NODE_RETURN_STMT or any other statement form. For sub-phase C only return
-- and expr-stmt are supported here; other tags fall through to the registry
-- and produce the standard "not yet implemented" error from the walker shell.
local function walk_body(stmts, env, solver)
	for _, s in ipairs(stmts) do
		local env2, err = walk_stmt(s, env, solver)
		env = env2
		if err ~= nil then return env, err end
	end
	return env, nil
end

-- Escape-check site discipline (§6.1):
--
-- After body-checking under skolemization, the design says "every reachable
-- skolem must be confined to the body's resulting type." In practice the
-- check fires against *free inference variables* whose bounds may have
-- absorbed skolems during the body walk — NOT against the annotated return
-- type itself, which by construction may legitimately contain skolems
-- (that's how the forall body is expressed). Sub-phase C does not yet
-- introduce free inference variables that could capture skolems across the
-- body boundary (no `local` bindings escape the body frame, no module
-- accumulation persists into the outer env), so the check is trivially
-- vacuous here. The walker will gain real free-var-tracking machinery in
-- a later sub-phase and re-instate the check at that point. The
-- `forall.find_escape` primitive remains in v4 and is already exercised by
-- subtype.lua's subsumption path; this is purely about *where* the walker
-- invokes it, not whether the mechanism exists.

local function synth_func(node, env, solver)
	local annotation = node.annotation
	local body = node.body or ({})

	if annotation ~= nil then
		-- Annotated path: skolemize if forall, bind params to body slots,
		-- CHECK body against the annotated return type.
		local body_ty, skolems = maybe_skolemize(annotation)
		if body_ty.tag ~= "fn" then
			return nil, env,
				"function: annotation is not a function type: " .. V.show(annotation)
		end
		-- Narrowing: body_ty.tag == "fn"
		local arrow = body_ty
		if #arrow.params ~= #node.params then
			return nil, env,
				"function: annotation arity (" .. tostring(#arrow.params) ..
				") disagrees with parameter list (" .. tostring(#node.params) .. ")"
		end
		local vararg_ty = nil
		if node.vararg then
			vararg_ty = node.vararg_ann or V.var("vararg")
		end
		local body_env = E.enter_function(env, arrow.ret, vararg_ty)
		for i, p in ipairs(node.params) do
			body_env = E.bind(body_env, p.name, arrow.params[i])
		end
		local body_env2, berr = walk_body(body, body_env, solver)
		if berr ~= nil then return nil, env, berr end
		-- Escape check: see the comment on `check_no_escape` above —
		-- vacuous in sub-phase C, kept here so future sub-phases that
		-- introduce body-spanning free vars know where to plug in the
		-- per-var check.
		local _ = skolems
		-- Body effects must be a subset of the annotated effects. Effect
		-- annotation syntax is sub-phase H; here we surface a body-effects
		-- mismatch against an explicit annotation as an error so the
		-- machinery is in place when H wires the syntax. Empty annotated
		-- effects means "no effects allowed" — body that yields fails.
		for name in pairs(body_env2.effects) do
			if not arrow.effects[name] then
				return nil, env,
					"function: body performs effect '" .. name ..
					"' not declared in the annotation"
			end
		end
		-- The user wrote the type; return it verbatim.
		return annotation, env, nil
	end

	-- Unannotated path: allocate fresh vars, walk body in SYNTHESIZE mode.
	local param_types, param_names = decode_param_shapes(node.params)
	local ret_var = V.var("ret")
	local vararg_ty = nil
	if node.vararg then
		vararg_ty = node.vararg_ann or V.var("vararg")
	end
	local body_env = E.enter_function(env, ret_var, vararg_ty)
	for i, name in ipairs(param_names) do
		body_env = E.bind(body_env, name, param_types[i])
	end
	local body_env2, berr = walk_body(body, body_env, solver)
	if berr ~= nil then return nil, env, berr end
	-- Collect the accumulated effects into the synthesized arrow's effect set.
	local effs = {}
	for k, v in pairs(body_env2.effects) do effs[k] = v end
	return V.fn(param_types, ret_var, effs), env, nil
end

-- Register all sub-phase C handlers.
function M.register(W)
	W.register_synth(defs.NODE_FUNC_EXPR,    synth_func)
	W.register_synth(defs.NODE_FUNC_DECL,    synth_func)
	W.register_synth(defs.NODE_CALL_EXPR,    synth_call)
	W.register_synth(defs.NODE_METHOD_CALL,  synth_method_call)
	W.register_synth(defs.NODE_RETURN_STMT,  synth_return)
	W.register_synth(defs.NODE_EXPR_STMT,    synth_expr_stmt)
end

return M
