-- lib/type/v10_kernel/theories/algorithm_j.lua
-- Algorithm J, ported onto the canonical v10 core (lib/type/v10_cleanroom/),
-- mirroring algorithm_w.lua's port structure (see that file's header for
-- the shared two-pass rationale, the canonical certificate grammar — plain
-- tables, F8 node-identity hypotheses, F12 plain-term axiom bindings — and
-- hm.lua's header for the vocabulary/rule-shape findings). Same tiny lambda
-- calculus (lit/var/abs/app/let), same Damas-Milner typing judgment, same
-- non-generalizing let — but a structurally different PRODUCER: Algorithm
-- W's functional-substitution-map unification is replaced here by the
-- classic imperative reformulation (a type variable IS a mutable ref cell;
-- unifying a variable with something means MUTATING its cell in place,
-- union-find style via `prune`). J is an UNTRUSTED PRODUCER exactly like W:
-- the replayer never runs this code path.
--
-- GENERICITY FINDING (still true under the canon swap, unchanged): this
-- theory declares ZERO new vocabulary. It takes the SAME
-- `hm.declare_vocabulary(registry)` result W uses (a caller builds one
-- vocabulary per registry and passes it to both `algorithm_w.certify` and
-- `algorithm_j.certify`) — rule/axiom identity is the declared object
-- itself; sharing a rule is holding a reference to the same object.
--
-- SAME DELIBERATE WEAKNESS as algorithm_w.lua: does not generalize
-- let-bindings (see the two test files' "known limitation" case, run on the
-- identical term both files use). No occurs check.
--
-- TWO-PASS CONSTRUCTION, J's specific shape: same requirement and reason as
-- algorithm_w.lua's header (terms must be ground the moment they're built;
-- there is no cross-node "same unification variable" identity a certificate
-- node can defer to). Unlike W (whose "final resolved type" lookup is a
-- plain `subst` table keyed by id, valid regardless of which JType object
-- queries it), J's resolution lives in MUTABLE CELLS attached to the
-- specific var OBJECTS `unify` mutated — a fresh cell created later, even
-- with a matching id, was never mutated and would prune to itself. So pass
-- 1 THREADS a `created`-by-id side table through its own recursion
-- (populated at the exact point each fresh var is made, before any
-- mutation), and only AFTER `infer_types` fully returns (every reachable
-- `unify` call has run) does `certify` walk that table and `deep_prune`
-- each ORIGINAL var object — capturing pass 1's actual mutation result.
-- Pass 2 then creates its OWN fresh (never mutated) vars purely to advance
-- the id counter in lockstep with pass 1's deterministic traversal order,
-- and looks up the recorded resolved type by id rather than pruning its
-- own, unrelated cell.

-- Required for the type vocabulary this module consumes (Term/CertNode
-- from the canonical core, Vocab from hm.lua); certificate nodes
-- themselves are plain tables, so there is no runtime constructor call
-- into either module.
local ta = require("lib.type.v10_cleanroom.term_algebra")
local replayer = require("lib.type.v10_cleanroom.replayer")
local hm = require("lib.type.v10_kernel.theories.hm")

local M = {}

M.THEORY = "algorithm_j"

--:: JTerm = { tag: "lit", base: string, value: unknown, locus: string } | { tag: "var", index: integer, name: string, locus: string } | { tag: "abs", param: string, body: JTerm, locus: string } | { tag: "app", fn: JTerm, arg: JTerm, locus: string } | { tag: "let", name: string, value: JTerm, body: JTerm, locus: string }
--:: Cell = { bound: JType | nil }
--:: JType = { tag: "con", base: string } | { tag: "var", id: string, cell: Cell } | { tag: "fun", from: JType, to: JType }
--:: JVar = { tag: "var", id: string, cell: Cell }
--:: Resolved = { tag: "con", base: string } | { tag: "fun", from: Resolved, to: Resolved }
--:: ResolvedById = { [string]: Resolved }
--:: CreatedById = { [string]: JType }

local fresh_counter = 0
-- `created`, when given, records the freshly-made var (BEFORE any
-- mutation) keyed by its own id -- pass 1 threads a table here; pass 2
-- passes nothing (it only needs the deterministic id sequence).
--: (CreatedById | nil) -> JVar
local function fresh_var(created)
	fresh_counter = fresh_counter + 1
	local v = { tag = "var", id = "t" .. fresh_counter, cell = { bound = nil } } --[[: JVar ]]
	if created then created[v.id] = v end
	return v
end

local prune --[[: ((JType) -> JType) | nil ]]
--: (JType) -> JType
prune = function(t)
	if t.tag ~= "var" then return t end
	local bound = t.cell.bound
	if bound == nil then return t end
	local root = prune(bound)
	t.cell.bound = root
	return root
end

--: (JType) -> Resolved
local function deep_prune(t)
	t = prune(t)
	if t.tag == "fun" then
		return { tag = "fun", from = deep_prune(t.from), to = deep_prune(t.to) }
	elseif t.tag == "con" then
		return { tag = "con", base = t.base }
	elseif t.tag == "var" then
		error("deep_prune: unresolved type variable t" .. t.id .. " survived to a resolved read")
	end
	error("deep_prune: unrecognized JType tag")
end

--: (JType, JType) -> (boolean | nil, string | nil)
local function unify(a, b)
	a = prune(a)
	b = prune(b)
	if a.tag == "var" then a.cell.bound = b; return true end
	if b.tag == "var" then b.cell.bound = a; return true end
	if a.tag == "con" and b.tag == "con" then
		if a.base ~= b.base then return nil, "cannot unify " .. a.base .. " with " .. b.base end
		return true
	end
	if a.tag == "fun" and b.tag == "fun" then
		local ok, err = unify(a.from, b.from)
		if not ok then return nil, err end
		return unify(a.to, b.to)
	end
	return nil, "cannot unify " .. tostring(a.tag) .. " with " .. tostring(b.tag)
end

-- ── Pass 1: type inference, recording every fresh var's identity by id ──────

--:: JEnv = { [integer]: JType }

--: (JEnv, JType) -> JEnv
local function env_extend(env, t)
	local extended = { t }
	for i = 1, #env do extended[i + 1] = env[i] end
	return extended
end

--: (JTerm, JEnv, CreatedById) -> (JType | nil, string | nil)
local function infer_types(term, env, created)
	if term.tag == "lit" then
		return { tag = "con", base = term.base }, nil
	elseif term.tag == "var" then
		local t = env[term.index + 1]
		if not t then
			return nil, "unbound de Bruijn index " .. term.index .. " (" .. term.name .. ") at " .. term.locus
		end
		return t, nil
	elseif term.tag == "abs" then
		local param_type = fresh_var(created)
		local body_type, err = infer_types(term.body, env_extend(env, param_type), created)
		if not body_type then return nil, err end
		return { tag = "fun", from = param_type, to = body_type }, nil
	elseif term.tag == "app" then
		local fn_type, err1 = infer_types(term.fn, env, created)
		if not fn_type then return nil, err1 end
		local arg_type, err2 = infer_types(term.arg, env, created)
		if not arg_type then return nil, err2 end
		local result_type = fresh_var(created)
		local ok, uerr = unify(fn_type, { tag = "fun", from = arg_type, to = result_type })
		if not ok then return nil, "at " .. term.locus .. ": " .. (uerr or "unify failed") end
		return result_type, nil
	elseif term.tag == "let" then
		local value_type, err1 = infer_types(term.value, env, created)
		if not value_type then return nil, err1 end
		-- DELIBERATE WEAKNESS: no generalization -- see module header.
		local body_type, err2 = infer_types(term.body, env_extend(env, value_type), created)
		if not body_type then return nil, err2 end
		return body_type, nil
	end
	return nil, "unknown term tag " .. tostring(term.tag)
end

-- ── Pass 2: certificate construction over the resolved types ────────────────

--:: CertBinding = { hyp_node: CertNode, ty: Term }
--:: CertEnv = { [integer]: CertBinding }

--: (CertEnv, CertNode, Term) -> CertEnv
local function cert_env_extend(env, hyp_node, ty)
	local extended = { { hyp_node = hyp_node, ty = ty } } --[[: CertEnv ]]
	for i = 1, #env do extended[i + 1] = env[i] end
	return extended
end

-- Hypothesis leaf builder (a plain table per the canonical certificate
-- grammar; its object identity IS the hypothesis id -- F8).
--: (j: Term) -> CertNode
local function hyp_node_of(j)
	return { kind = "hypothesis", judgment = j }
end

--: (Resolved, Vocab) -> (Term | nil, string | nil)
local function to_ty(t, vocab)
	if t.tag == "con" then
		if t.base == "integer" then return vocab.int_ty end
		if t.base == "boolean" then return vocab.bool_ty end
		return nil, "to_ty: unknown base type " .. t.base
	end
	local from_ty, ferr = to_ty(t.from, vocab)
	if not from_ty then return nil, ferr end
	local to_ty_, terr = to_ty(t.to, vocab)
	if not to_ty_ then return nil, terr end
	return vocab.Arrow(from_ty, to_ty_)
end

-- `resolved`: pass 1's completed side table (fresh-var id -> its final
-- deep-pruned resolved type, captured from pass 1's OWN cell objects right
-- after pass 1 finished -- see module header). Pass 2 creates fresh (never
-- mutated) vars solely to keep `fresh_counter` advancing in the same
-- deterministic order pass 1 used, then looks the resulting id up here.
--: (JTerm, CertEnv, ResolvedById, Vocab) -> (Term | nil, CertNode | nil, string | nil)
local function build_cert(term, env, resolved, vocab)
	if term.tag == "lit" then
		if term.base ~= "integer" and term.base ~= "boolean" then
			return nil, nil, "build_cert: unknown literal base " .. tostring(term.base) .. " at " .. term.locus
		end
		local ty_term = term.base == "integer" and vocab.int_ty or vocab.bool_ty
		local node = { kind = "axiom", axiom = vocab.ax_lit, bindings = { A = ty_term } } --[[: CertNode ]]
		return ty_term, node, nil
	elseif term.tag == "var" then
		local binding = env[term.index + 1]
		if not binding then
			return nil, nil, "unbound de Bruijn index " .. term.index .. " (" .. term.name .. ") at " .. term.locus
		end
		return binding.ty, binding.hyp_node, nil
	elseif term.tag == "abs" then
		local param_var = fresh_var(nil)
		local param_resolved = resolved[param_var.id]
		if not param_resolved then return nil, nil, "build_cert: no resolved type recorded for t" .. param_var.id end
		local param_ty, terr = to_ty(param_resolved, vocab)
		if not param_ty then return nil, nil, terr end
		local hyp_h, herr = vocab.H(param_ty)
		if not hyp_h then return nil, nil, herr end
		local hyp_node = hyp_node_of(hyp_h)
		local body_ty, body_node, berr = build_cert(term.body, cert_env_extend(env, hyp_node, param_ty), resolved, vocab)
		if not body_ty then return nil, nil, berr end
		local node = {
			kind = "rule", rule = vocab.rule_abs,
			premises = { hyp_node, body_node },
			discharge = { [1] = { hyp_node } },
		} --[[: CertNode ]]
		local arrow_ty, aerr = vocab.Arrow(param_ty, body_ty)
		if not arrow_ty then return nil, nil, aerr end
		return arrow_ty, node, nil
	elseif term.tag == "app" then
		local fn_ty, fn_node, err1 = build_cert(term.fn, env, resolved, vocab)
		if not fn_ty then return nil, nil, err1 end
		local arg_ty, arg_node, err2 = build_cert(term.arg, env, resolved, vocab)
		if not arg_ty then return nil, nil, err2 end
		local result_var = fresh_var(nil)
		local result_resolved = resolved[result_var.id]
		if not result_resolved then return nil, nil, "build_cert: no resolved type recorded for t" .. result_var.id end
		local result_ty, rerr = to_ty(result_resolved, vocab)
		if not result_ty then return nil, nil, rerr end
		local node = { kind = "rule", rule = vocab.rule_app, premises = { fn_node, arg_node } } --[[: CertNode ]]
		return result_ty, node, nil
	elseif term.tag == "let" then
		local value_ty, value_node, err1 = build_cert(term.value, env, resolved, vocab)
		if not value_ty then return nil, nil, err1 end
		-- DELIBERATE WEAKNESS, matching pass 1: no generalization -- the
		-- let-bound hypothesis's type is exactly the value's own (already
		-- fully resolved) type, monomorphic, not a re-instantiated scheme.
		local hyp_h, herr = vocab.H(value_ty)
		if not hyp_h then return nil, nil, herr end
		local hyp_node = hyp_node_of(hyp_h)
		local body_ty, body_node, err2 = build_cert(term.body, cert_env_extend(env, hyp_node, value_ty), resolved, vocab)
		if not body_ty then return nil, nil, err2 end
		local node = {
			kind = "rule", rule = vocab.rule_let,
			premises = { value_node, hyp_node, body_node },
			discharge = { [1] = { hyp_node } },
		} --[[: CertNode ]]
		return body_ty, node, nil
	end
	return nil, nil, "unknown term tag " .. tostring(term.tag)
end

-- Infer `term`'s type against the given vocabulary and emit a certificate
-- citing hm.lua's rule/axiom vocabulary (shared with algorithm_w.lua's
-- `certify` -- see module header's genericity finding). Returns (root
-- certificate node, nil) on success, or (nil, errmsg) on an inference
-- failure -- never a thrown error.
--: (JTerm, Vocab) -> (CertNode | nil, string | nil)
function M.certify(term, vocab)
	fresh_counter = 0

	local created = {} --[[: CreatedById ]]
	local root_type, err = infer_types(term, {}, created)
	if not root_type then return nil, err end

	-- Pass 1 is fully complete here: every `unify` call reachable from
	-- `term` has already run, so pruning each ORIGINAL created var now
	-- (not a fresh one) captures the final result.
	local resolved = {} --[[: ResolvedById ]]
	for id, v in pairs(created) do
		resolved[id] = deep_prune(v)
	end

	fresh_counter = 0
	local _, root_node, cerr = build_cert(term, {}, resolved, vocab)
	if not root_node then return nil, cerr end
	return root_node, nil
end

return M
