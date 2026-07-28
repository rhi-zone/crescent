-- lib/type/v10_kernel/theories/algorithm_w.lua
-- Algorithm W, ported onto the ratified v10 core
-- (docs/decisions/typechecker-v10-core-design.md,
-- docs/decisions/typechecker-v10-core-charter.md). An UNTRUSTED PRODUCER:
-- it runs its own toy Hindley-Milner-style inference for a four-construct
-- lambda calculus (lit/var/abs/app/let) and emits a certificate the
-- replayer (lib/type/v10_kernel/replayer/) can replay purely structurally,
-- citing the hm.lua rule/axiom vocabulary. The replayer never runs this
-- code path and knows nothing about it.
--
-- DELIBERATE, DOCUMENTED WEAKNESS (carried over from the retired prototype,
-- unchanged): does NOT generalize let-bindings into type schemes. `let x =
-- e1 in e2` infers e1's type once and binds x to that concrete
-- (monomorphic) type for e2 — a type variable free in e1's type gets
-- unified against whatever the FIRST use in e2 requires and stays pinned
-- there; a second, differently-typed use of the same let-bound name is
-- rejected. See algorithm_w_test.lua's "known limitation" case. No occurs
-- check either, also carried over.
--
-- TWO-PASS CONSTRUCTION (the actual porting finding — see hm.lua's header
-- for the vocabulary/rule-shape findings): the retired prototype built
-- certificate nodes INLINE, one recursive descent, because its certificate
-- grammar's `conclusion`/hypothesis `payload` fields were fully OPAQUE
-- strings the kernel never checked — a hypothesis introduced for an
-- abs/let binder could carry a still-unresolved type variable's display
-- string at creation time, later becoming stale once further unification
-- elsewhere pinned it, and nothing ever noticed because nothing ever
-- looked. The new core's term_algebra has no analogous "fill in later"
-- placeholder: every certificate node's judgment must be a GROUND term the
-- moment it's built (a metavariable may never survive into a concluded
-- judgment or a hypothesis that must later match one structurally), and
-- there is no cross-node "same unification variable" identity spanning
-- separate certificate nodes the way a shared `subst` map provided. So
-- `certify` runs Algorithm W's real inference (fresh type variables +
-- global substitution map, exactly as before, entirely OUTSIDE
-- term_algebra) to completion FIRST, producing an annotated copy of the
-- term recording each binder's own (Lua-internal, not-yet-materialized)
-- `WType`; only THEN does a second, purely mechanical pass walk that
-- annotated tree and build actual term_algebra terms + certificate nodes,
-- with every type fully resolved (`deep_resolve`) by construction. This is
-- a required restructuring for any incremental/mutable-unification
-- algorithm targeting this certificate model, not a workaround for a gap —
-- see hm.lua's header, "Finding 3", for the flip side (the new core
-- catches consistency mistakes the old opaque-payload design structurally
-- could not).
--
-- BINDER REPRESENTATION: unchanged from the retired prototype — `var` terms
-- carry a de Bruijn INDEX (0 = nearest enclosing binder), not a source
-- name; the environment threaded through both passes is a depth-indexed
-- list, never looked up by name. `param`/`name` display strings remain
-- purely cosmetic (used only in error messages here — the new certificate
-- grammar has no field for them at all, unlike the retired prototype's
-- `locus`/cosmetic-name node fields, so they don't even ride along into the
-- certificate; this is a straightforward consequence of nodes carrying no
-- payload beyond what replay computes, not a loss of anything
-- semantically load-bearing, since the retired design never checked them
-- either).

local replayer = require("lib.type.v10_kernel.replayer")

local M = {}

M.THEORY = "algorithm_w"

--:: WTerm = { tag: "lit", base: string, value: unknown, locus: string } | { tag: "var", index: integer, name: string, locus: string } | { tag: "abs", param: string, body: WTerm, locus: string } | { tag: "app", fn: WTerm, arg: WTerm, locus: string } | { tag: "let", name: string, value: WTerm, body: WTerm, locus: string }
--:: WType = { tag: "con", base: string } | { tag: "var", id: string } | { tag: "fun", from: WType, to: WType }
--:: Subst = { [string]: WType }

local fresh_counter = 0
--: () -> WType
local function fresh_var()
	fresh_counter = fresh_counter + 1
	return { tag = "var", id = "t" .. fresh_counter }
end

--: (WType, Subst) -> WType
local function resolve(t, subst)
	while t.tag == "var" and subst[t.id] do t = subst[t.id] end
	return t
end

--: (WType, Subst) -> WType
local function deep_resolve(t, subst)
	t = resolve(t, subst)
	if t.tag == "fun" then
		return { tag = "fun", from = deep_resolve(t.from, subst), to = deep_resolve(t.to, subst) }
	end
	return t
end

--: (WType, WType, Subst) -> (boolean | nil, string | nil)
local function unify(a, b, subst)
	a = resolve(a, subst)
	b = resolve(b, subst)
	if a.tag == "var" then subst[a.id] = b; return true end
	if b.tag == "var" then subst[b.id] = a; return true end
	if a.tag == "con" and b.tag == "con" then
		if a.base ~= b.base then return nil, "cannot unify " .. a.base .. " with " .. b.base end
		return true
	end
	if a.tag == "fun" and b.tag == "fun" then
		local ok, err = unify(a.from, b.from, subst)
		if not ok then return nil, err end
		return unify(a.to, b.to, subst)
	end
	return nil, "cannot unify " .. tostring(a.tag) .. " with " .. tostring(b.tag)
end

-- ── Pass 1: type inference only (no term_algebra/replayer involvement) ──────

--:: WEnv = { [integer]: WType }

--: (WEnv, WType) -> WEnv
local function env_extend(env, t)
	local extended = { t }
	for i = 1, #env do extended[i + 1] = env[i] end
	return extended
end

--: (WTerm, WEnv, Subst) -> (WType | nil, string | nil)
local function infer_types(term, env, subst)
	if term.tag == "lit" then
		return { tag = "con", base = term.base }, nil
	elseif term.tag == "var" then
		local t = env[term.index + 1]
		if not t then
			return nil, "unbound de Bruijn index " .. term.index .. " (" .. term.name .. ") at " .. term.locus
		end
		return t, nil
	elseif term.tag == "abs" then
		local param_type = fresh_var()
		local body_type, err = infer_types(term.body, env_extend(env, param_type), subst)
		if not body_type then return nil, err end
		return { tag = "fun", from = param_type, to = body_type }, nil
	elseif term.tag == "app" then
		local fn_type, err1 = infer_types(term.fn, env, subst)
		if not fn_type then return nil, err1 end
		local arg_type, err2 = infer_types(term.arg, env, subst)
		if not arg_type then return nil, err2 end
		local result_type = fresh_var()
		local ok, uerr = unify(fn_type, { tag = "fun", from = arg_type, to = result_type }, subst)
		if not ok then return nil, "at " .. term.locus .. ": " .. (uerr or "unify failed") end
		return result_type, nil
	elseif term.tag == "let" then
		local value_type, err1 = infer_types(term.value, env, subst)
		if not value_type then return nil, err1 end
		-- DELIBERATE WEAKNESS: no generalization -- see module header.
		local body_type, err2 = infer_types(term.body, env_extend(env, value_type), subst)
		if not body_type then return nil, err2 end
		return body_type, nil
	end
	return nil, "unknown term tag " .. tostring(term.tag)
end

-- ── Pass 2: certificate construction over the resolved types ────────────────
--
-- Re-walks the SAME term (deterministic: no branching depends on anything
-- but term structure, so re-running the recursive descent visits binders in
-- the identical order pass 1 did) creating a FRESH `fresh_var()` per binder
-- purely as a key into `subst` (populated, complete, by pass 1) -- never
-- calling `unify` again. Builds hm.lua vocabulary citations with every type
-- fully ground via `deep_resolve` against pass 1's finished `subst`.

--:: CertBinding = { hyp_node: unknown, ty: unknown }
--:: CertEnv = { [integer]: CertBinding }
--:: Vocab = { signature: unknown, int_ty: unknown, bool_ty: unknown, H: (unknown) -> (unknown | nil, string | nil), Arrow: (unknown, unknown) -> (unknown | nil, string | nil), ax_lit: unknown, rule_abs: unknown, rule_app: unknown, rule_let: unknown }

--: (CertEnv, unknown, unknown) -> CertEnv
local function cert_env_extend(env, hyp_node, ty)
	local extended = { { hyp_node = hyp_node, ty = ty } } --[[: CertEnv ]]
	for i = 1, #env do extended[i + 1] = env[i] end
	return extended
end

local hyp_counter = 0
--: () -> string
local function fresh_hyp_id()
	hyp_counter = hyp_counter + 1
	return "h" .. hyp_counter
end

--: (WType, Subst, Vocab) -> (unknown | nil, string | nil)
local function to_ty(t, subst, vocab)
	t = deep_resolve(t, subst)
	if t.tag == "con" then
		if t.base == "integer" then return vocab.int_ty end
		if t.base == "boolean" then return vocab.bool_ty end
		return nil, "to_ty: unknown base type " .. t.base
	elseif t.tag == "fun" then
		local from_ty, ferr = to_ty(t.from, subst, vocab)
		if not from_ty then return nil, ferr end
		local to_ty_, terr = to_ty(t.to, subst, vocab)
		if not to_ty_ then return nil, terr end
		return vocab.Arrow(from_ty, to_ty_)
	elseif t.tag == "var" then
		return nil, "to_ty: unresolved type variable t" .. tostring(t.id)
	end
	return nil, "to_ty: unrecognized WType tag"
end

-- Returns (ty_term, cert_node, nil) on success -- ty_term is the fully
-- ground hm.lua `ty`-sort term_algebra term for `term`'s type (needed by
-- LET to build its own bound hypothesis's judgment from the value's
-- already-resolved type, and by ABS to build the arrow result -- see
-- module header's two-pass note).
--: (WTerm, CertEnv, Subst, Vocab) -> (unknown | nil, unknown | nil, string | nil)
local function build_cert(term, env, subst, vocab)
	if term.tag == "lit" then
		if term.base ~= "integer" and term.base ~= "boolean" then
			return nil, nil, "build_cert: unknown literal base " .. tostring(term.base) .. " at " .. term.locus
		end
		local ty_term = term.base == "integer" and vocab.int_ty or vocab.bool_ty
		local node, err = replayer.cite_axiom(vocab.ax_lit, { A = { term = ty_term, depth = 0 } })
		if not node then return nil, nil, err end
		return ty_term, node, nil
	elseif term.tag == "var" then
		local binding = env[term.index + 1]
		if not binding then
			return nil, nil, "unbound de Bruijn index " .. term.index .. " (" .. term.name .. ") at " .. term.locus
		end
		return binding.ty, binding.hyp_node, nil
	elseif term.tag == "abs" then
		local param_wtype = fresh_var()
		local param_ty, terr = to_ty(param_wtype, subst, vocab)
		if not param_ty then return nil, nil, terr end
		local hyp_id = fresh_hyp_id()
		local hyp_h, herr = vocab.H(param_ty)
		if not hyp_h then return nil, nil, herr end
		local hyp_node, hnerr = replayer.hypothesis(hyp_id, hyp_h)
		if not hyp_node then return nil, nil, hnerr end
		local body_ty, body_node, berr = build_cert(term.body, cert_env_extend(env, hyp_node, param_ty), subst, vocab)
		if not body_ty then return nil, nil, berr end
		local node, cerr = replayer.cite_rule(vocab.rule_abs, { hyp_node, body_node }, { { hyp_id } })
		if not node then return nil, nil, cerr end
		local arrow_ty, aerr = vocab.Arrow(param_ty, body_ty)
		if not arrow_ty then return nil, nil, aerr end
		return arrow_ty, node, nil
	elseif term.tag == "app" then
		local fn_ty, fn_node, err1 = build_cert(term.fn, env, subst, vocab)
		if not fn_ty then return nil, nil, err1 end
		local arg_ty, arg_node, err2 = build_cert(term.arg, env, subst, vocab)
		if not arg_ty then return nil, nil, err2 end
		local result_wtype = fresh_var()
		local result_ty, rerr = to_ty(result_wtype, subst, vocab)
		if not result_ty then return nil, nil, rerr end
		local node, cerr = replayer.cite_rule(vocab.rule_app, { fn_node, arg_node })
		if not node then return nil, nil, cerr end
		return result_ty, node, nil
	elseif term.tag == "let" then
		local value_ty, value_node, err1 = build_cert(term.value, env, subst, vocab)
		if not value_ty then return nil, nil, err1 end
		-- DELIBERATE WEAKNESS, matching pass 1: no generalization -- the
		-- let-bound hypothesis's type is exactly the value's own (already
		-- fully resolved) type, monomorphic, not a re-instantiated scheme.
		local hyp_id = fresh_hyp_id()
		local hyp_h, herr = vocab.H(value_ty)
		if not hyp_h then return nil, nil, herr end
		local hyp_node, hnerr = replayer.hypothesis(hyp_id, hyp_h)
		if not hyp_node then return nil, nil, hnerr end
		local body_ty, body_node, err2 = build_cert(term.body, cert_env_extend(env, hyp_node, value_ty), subst, vocab)
		if not body_ty then return nil, nil, err2 end
		local node, cerr = replayer.cite_rule(vocab.rule_let, { value_node, hyp_node, body_node }, { { hyp_id } })
		if not node then return nil, nil, cerr end
		return body_ty, node, nil
	end
	return nil, nil, "unknown term tag " .. tostring(term.tag)
end

-- Infer `term`'s type against the given vocabulary and emit a certificate
-- citing hm.lua's rule/axiom vocabulary. `vocab` is caps-first injected
-- (never ambient): the caller chooses the term_algebra tier and builds the
-- vocabulary once (`hm.declare_vocabulary(k)`), typically shared with
-- algorithm_j.lua's `certify` -- see hm.lua's header. Returns (root
-- certificate node, nil) on success, or (nil, errmsg) on an inference
-- failure (unify mismatch, unbound variable) -- never a thrown error.
--: (WTerm, Vocab) -> (unknown | nil, string | nil)
function M.certify(term, vocab)
	fresh_counter = 0
	hyp_counter = 0
	local subst = {} --[[: Subst ]]
	local root_type, err = infer_types(term, {}, subst)
	if not root_type then return nil, err end
	fresh_counter = 0
	local _, root_node, cerr = build_cert(term, {}, subst, vocab)
	if not root_node then return nil, cerr end
	return root_node, nil
end

return M
