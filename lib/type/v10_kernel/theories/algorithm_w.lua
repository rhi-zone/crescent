-- lib/type/v10_kernel/w.lua
-- Algorithm W, dinner-sized: the v10 kernel's founding theory-registry entry.
--
-- A toy Hindley-Milner-style inferencer for a four-construct lambda calculus
-- (lit, var, abs, app, let). It is an UNTRUSTED PRODUCER: it runs its own
-- inference algorithm — the kernel never runs this code path and knows
-- nothing about it — and emits a certificate the kernel can replay purely
-- structurally, by citing the rule schemas `M.register_rules` registers.
--
-- DELIBERATE, DOCUMENTED WEAKNESS: this implementation does NOT generalize
-- let-bindings into type schemes. `let x = e1 in e2` infers e1's type once
-- and binds x to that concrete (monomorphic) type for e2 — it never
-- produces a forall-quantified scheme re-instantiated fresh at each use.
-- A type variable free in e1's type therefore gets unified (mutated in
-- place, via `subst`) against whatever the FIRST use in e2 requires, and
-- stays pinned there: a second, differently-but-compatibly-typed use of the
-- same let-bound name is rejected. This is the classic v1 "online
-- unification" failure mode documented in
-- docs/decisions/typechecker-version-history.md ("v1 — original
-- online-unification checker"), reproduced here on purpose as the founding
-- entry's known limitation, not a bug to fix — see kernel_test.lua's
-- "known limitation" case, which demonstrates it and does not attempt to
-- work around it.
--
-- Also omitted, on purpose, for dinner-sized scope: an occurs check (no
-- protection against constructing an infinite type), and any notion of
-- alpha-equivalence or binder identity beyond plain string names —
-- shadowing works because the environment is an ordinary Lua table chain
-- threaded recursively, not because the certificate grammar tracks binder
-- identity (see kernel.lua's stated discharge simplification).

local registry_mod = require("lib.type.v10_kernel.registry")

--:: require "lib.type.v10_kernel.registry"

local M = {}

M.THEORY = "algorithm_w"

--:: WTerm = { tag: "lit", base: string, value: unknown, locus: string } | { tag: "var", name: string, locus: string } | { tag: "abs", param: string, body: WTerm, locus: string } | { tag: "app", fn: WTerm, arg: WTerm, locus: string } | { tag: "let", name: string, value: WTerm, body: WTerm, locus: string }
--:: WType = { tag: "con", name: string } | { tag: "var", id: string } | { tag: "fun", from: WType, to: WType }
--:: WNode = { id: string, rule: string, judgment: string, locus: string, conclusion: unknown, premises: { [integer]: string }, assumes?: { [integer]: string }, discharges?: { [integer]: string } }
--:: WHypothesis = { id: string, judgment: string, payload: unknown }
--:: WCert = { theory: string, nodes: { [string]: WNode }, hypotheses: { [string]: WHypothesis }, root: string }

-- ---- rule schemas -------------------------------------------------------

-- Exposed as M.RULES (not just a local) because these five schemas state a
-- judgment shape (has_type; lit/var/abs/app/let arities and assumes/
-- discharges flags), not anything specific to W's functional-substitution
-- implementation style. theories/algorithm_j.lua — the same Damas-Milner
-- algorithm in its imperative, mutable-ref-cell reformulation — registers
-- these exact schema objects into its own (separately-scoped) registry
-- rather than re-declaring identical ones, since the underlying judgment is
-- provably the same one. See algorithm_j.lua's header for the citation-
-- naming tradeoff that choice implies.
local RULES = {
	{ name = "W-Lit", judgment = "has_type", arity = 0 },
	{ name = "W-Var", judgment = "has_type", arity = 0, assumes = true },
	{ name = "W-Abs", judgment = "has_type", arity = 1, discharges = true },
	{ name = "W-App", judgment = "has_type", arity = 2 },
	{ name = "W-Let", judgment = "has_type", arity = 2, discharges = true },
}
M.RULES = RULES

-- Register every W rule schema into `registry`. Call once before certifying
-- against it.
--: (Registry) -> (boolean | nil, string | nil)
function M.register_rules(registry)
	for _, schema in ipairs(RULES) do
		local ok, err = registry_mod.register(registry, schema)
		if not ok then return nil, err end
	end
	return true
end

-- ---- types, substitution, unification -----------------------------------

local fresh_counter = 0
--: () -> WType
local function fresh_var()
	fresh_counter = fresh_counter + 1
	return { tag = "var", id = "t" .. fresh_counter }
end

--: (string) -> WType
local function con(name)
	return { tag = "con", name = name }
end

--: (WType, { [string]: WType, ... }) -> WType
local function resolve(t, subst)
	while t.tag == "var" and subst[t.id] do
		t = subst[t.id]
	end
	return t
end

--: (WType, { [string]: WType, ... }) -> WType
local function deep_resolve(t, subst)
	t = resolve(t, subst)
	if t.tag == "fun" then
		return { tag = "fun", from = deep_resolve(t.from, subst), to = deep_resolve(t.to, subst) }
	end
	return t
end

--: (WType, WType, { [string]: WType, ... }) -> (boolean | nil, string | nil)
local function unify(a, b, subst)
	a = resolve(a, subst)
	b = resolve(b, subst)
	if a.tag == "var" then
		subst[a.id] = b
		return true
	end
	if b.tag == "var" then
		subst[b.id] = a
		return true
	end
	if a.tag == "con" and b.tag == "con" then
		if a.name ~= b.name then return nil, "cannot unify " .. a.name .. " with " .. b.name end
		return true
	end
	if a.tag == "fun" and b.tag == "fun" then
		local ok, err = unify(a.from, b.from, subst)
		if not ok then return nil, err end
		return unify(a.to, b.to, subst)
	end
	return nil, "cannot unify " .. tostring(a.tag) .. " with " .. tostring(b.tag)
end

--: (WType) -> string
local function show_type(t)
	if t.tag == "con" then return t.name end
	if t.tag == "var" then return "'" .. t.id end
	if t.tag == "fun" then return "(" .. show_type(t.from) .. " -> " .. show_type(t.to) .. ")" end
	return "?"
end

-- ---- certificate construction -------------------------------------------

--:: Builder = { nodes: { [string]: WNode }, hypotheses: { [string]: WHypothesis }, node_counter: integer, hyp_counter: integer }

--: () -> Builder
local function new_builder()
	return { nodes = {}, hypotheses = {}, node_counter = 0, hyp_counter = 0 }
end

--: (Builder, unknown) -> string
local function add_node(b, node)
	b.node_counter = b.node_counter + 1
	local id = "n" .. b.node_counter
	node.id = id
	b.nodes[id] = node
	return id
end

--: (Builder, string, WType) -> string
local function add_hyp(b, name, wtype)
	b.hyp_counter = b.hyp_counter + 1
	local id = "h" .. b.hyp_counter
	b.hypotheses[id] = { id = id, judgment = "has_type", payload = { name = name, type_str = show_type(wtype) } }
	return id
end

--:: WEnvEntry = { hyp_id: string, type: WType }
--:: WEnv = { [string]: WEnvEntry }

--: (WTerm, WEnv, { [string]: WType, ... }, Builder) -> (WType | nil, string | nil, string | nil)
local function infer(term, env, subst, b)
	if term.tag == "lit" then
		local t = con(term.base)
		local node_id = add_node(b, {
			rule = "W-Lit", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(t) },
			premises = {},
		})
		return t, node_id, nil
	elseif term.tag == "var" then
		local binding = env[term.name]
		if not binding then return nil, nil, "unbound variable " .. term.name .. " at " .. term.locus end
		local node_id = add_node(b, {
			rule = "W-Var", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(resolve(binding.type, subst)) },
			premises = {},
			assumes = { binding.hyp_id },
		})
		return binding.type, node_id, nil
	elseif term.tag == "abs" then
		local param_type = fresh_var()
		local hyp_id = add_hyp(b, term.param, param_type)
		local inner_env = setmetatable({ [term.param] = { hyp_id = hyp_id, type = param_type } }, { __index = env })
		local body_type, body_node, err = infer(term.body, inner_env, subst, b)
		if not body_type then return nil, nil, err end
		local t = { tag = "fun", from = param_type, to = body_type }
		local node_id = add_node(b, {
			rule = "W-Abs", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_resolve(t, subst)) },
			premises = { body_node },
			discharges = { hyp_id },
		})
		return t, node_id, nil
	elseif term.tag == "app" then
		local fn_type, fn_node, err1 = infer(term.fn, env, subst, b)
		if not fn_type then return nil, nil, err1 end
		local arg_type, arg_node, err2 = infer(term.arg, env, subst, b)
		if not arg_type then return nil, nil, err2 end
		local result_type = fresh_var()
		local ok, uerr = unify(fn_type, { tag = "fun", from = arg_type, to = result_type }, subst)
		if not ok then return nil, nil, "at " .. term.locus .. ": " .. (uerr or "unify failed") end
		local node_id = add_node(b, {
			rule = "W-App", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_resolve(result_type, subst)) },
			premises = { fn_node, arg_node },
		})
		return result_type, node_id, nil
	elseif term.tag == "let" then
		local value_type, value_node, err1 = infer(term.value, env, subst, b)
		if not value_type then return nil, nil, err1 end
		-- DELIBERATE WEAKNESS: no generalization — see module header. `name`
		-- is bound directly to value_type (monomorphic), not to a
		-- re-instantiated forall-scheme.
		local hyp_id = add_hyp(b, term.name, value_type)
		local inner_env = setmetatable({ [term.name] = { hyp_id = hyp_id, type = value_type } }, { __index = env })
		local body_type, body_node, err2 = infer(term.body, inner_env, subst, b)
		if not body_type then return nil, nil, err2 end
		local node_id = add_node(b, {
			rule = "W-Let", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_resolve(body_type, subst)) },
			premises = { value_node, body_node },
			discharges = { hyp_id },
		})
		return body_type, node_id, nil
	end
	return nil, nil, "unknown term tag " .. tostring(term.tag)
end

-- Infer `term`'s type and emit a certificate citing the W rule schemas.
-- Returns (certificate, nil) on success, or (nil, errmsg) on an inference
-- failure (unify mismatch, unbound variable) — never a thrown error.
--: (WTerm) -> (WCert | nil, string | nil)
function M.certify(term)
	local b = new_builder()
	local subst = {}
	local _, root_node, err = infer(term, {}, subst, b)
	if not root_node then return nil, err end
	return { theory = M.THEORY, nodes = b.nodes, hypotheses = b.hypotheses, root = root_node }, nil
end

return M
