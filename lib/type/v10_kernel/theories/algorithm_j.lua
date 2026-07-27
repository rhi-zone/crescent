-- lib/type/v10_kernel/theories/algorithm_j.lua
-- Algorithm J, dinner-sized: the v10 kernel's SECOND theory-registry entry.
--
-- Same tiny lambda calculus as algorithm_w.lua (lit/var/abs/app/let), same
-- Damas-Milner typing judgment, same non-generalizing let (see below) — but
-- a structurally different PRODUCER. Algorithm W (algorithm_w.lua) is
-- Milner's original formulation: unification builds a substitution map and
-- every intermediate type gets explicitly `resolve`d/`deep_resolve`d
-- through it. Algorithm J is the classic imperative reformulation: a type
-- variable IS a mutable ref cell (`{ bound = <type> | nil }`); unifying a
-- variable with something means MUTATING its cell in place, union-find
-- style (`prune` walks/shortens bound chains instead of consulting a
-- substitution table, and there is no substitution composition anywhere in
-- this file). J is an UNTRUSTED PRODUCER exactly like W: the kernel never
-- runs this code path, only replays the certificate it emits.
--
-- FINDING (registry genericity — the actual point of this file): this
-- theory registers ZERO new rule schemas. It reuses algorithm_w.lua's
-- exported `M.RULES` table VERBATIM (same five schema objects: W-Lit,
-- W-Var, W-Abs, W-App, W-Let — see algorithm_w.lua) into its own,
-- separately-scoped registry (`registry_mod.new(M.THEORY)`, theory =
-- "algorithm_j"). This is possible with ZERO changes to kernel.lua or
-- registry.lua: registry.lua already scopes schemas per registry instance
-- (one Registry per theory), and kernel.lua only ever compares a
-- certificate's node citations against the ONE registry passed to
-- `M.replay` — it has no idea, and does not care, that the same schema
-- table object is also registered under a different theory name elsewhere.
-- That is the "domain-blind kernel + shape-only registry" design working
-- as advertised: the evidence grammar (RuleSchema: judgment/arity/assumes/
-- discharges) describes the JUDGMENT, not the algorithm that derives it,
-- so two producers implementing the same judgment can cite the same
-- schemas without the kernel or registry needing to know that.
--
-- NAMING TRADEOFF this reuse implies (recorded plainly, not silently):
-- because the schemas are reused verbatim, J's certificates cite rules
-- literally named "W-Lit", "W-Var", etc. — the "W-" prefix, a leftover of
-- W registering first, no longer means "this rule is specific to Algorithm
-- W." It reads a little oddly for a J-emitted certificate to cite "W-Abs".
-- Renaming the schemas to algorithm-neutral names (e.g. "HM-Abs") would fix
-- the cosmetic mismatch but touches algorithm_w.lua's already-committed
-- rule names and kernel_test.lua's existing lookups by name — judged out of
-- scope for this entry (see README.md's "choices made" list). Tracked in
-- TODO.md.
--
-- DELIBERATE, DOCUMENTED WEAKNESS (matches algorithm_w.lua on purpose, so W
-- and J are genuinely comparable, not just superficially similar): this
-- implementation does NOT generalize let-bindings into type schemes either.
-- `let x = e1 in e2` infers e1's type once and binds x to that concrete
-- type for e2. A type variable free in e1's type gets its cell bound
-- (mutated) by the FIRST use in e2 and stays pinned there — see
-- algorithm_j_test.lua's "known limitation" case, which demonstrates the
-- identical rejection algorithm_w.lua's own test demonstrates, on the same
-- term.
--
-- Also omitted, on purpose, for dinner-sized scope (mirrors algorithm_w.lua):
-- no occurs check, no alpha-equivalence/binder-identity machinery beyond
-- plain string names in a chained environment table.

local registry_mod = require("lib.type.v10_kernel.registry")
local w = require("lib.type.v10_kernel.theories.algorithm_w")

--:: require "lib.type.v10_kernel.registry"

local M = {}

M.THEORY = "algorithm_j"

--:: JTerm = { tag: "lit", base: string, value: unknown, locus: string } | { tag: "var", name: string, locus: string } | { tag: "abs", param: string, body: JTerm, locus: string } | { tag: "app", fn: JTerm, arg: JTerm, locus: string } | { tag: "let", name: string, value: JTerm, body: JTerm, locus: string }
--:: Cell = { bound: JType | nil }
--:: JType = { tag: "con", name: string } | { tag: "var", id: string, cell: Cell } | { tag: "fun", from: JType, to: JType }
--:: JNode = { id: string, rule: string, judgment: string, locus: string, conclusion: unknown, premises: { [integer]: string }, assumes?: { [integer]: string }, discharges?: { [integer]: string } }
--:: JHypothesis = { id: string, judgment: string, payload: unknown }
--:: JCert = { theory: string, nodes: { [string]: JNode }, hypotheses: { [string]: JHypothesis }, root: string }

-- ---- rule schemas -------------------------------------------------------

-- Reuse algorithm_w.lua's schemas verbatim — see the file header finding.
-- Registered into THIS theory's own registry instance (a different table
-- from W's registry), so there is no name collision with W's registration.
--: (Registry) -> (boolean | nil, string | nil)
function M.register_rules(registry)
	for _, schema in ipairs(w.RULES) do
		local ok, err = registry_mod.register(registry, schema)
		if not ok then return nil, err end
	end
	return true
end

-- ---- types, mutable ref cells, union-find-style unification -------------

local fresh_counter = 0
--: () -> JType
local function fresh_var()
	fresh_counter = fresh_counter + 1
	return { tag = "var", id = "t" .. fresh_counter, cell = { bound = nil } }
end

--: (string) -> JType
local function con(name)
	return { tag = "con", name = name }
end

-- Walk a chain of bound ref cells to the current representative, with path
-- compression (classic union-find "find"): every cell visited along the way
-- gets its `bound` rewritten straight to the final representative, so a
-- later walk through the same cell is O(1). No substitution TABLE is
-- consulted anywhere — the binding lives in the cell itself.
local prune
--: (JType) -> JType
prune = function(t)
	if t.tag ~= "var" then return t end
	local bound = t.cell.bound
	if bound == nil then return t end
	local root = prune(bound)
	t.cell.bound = root
	return root
end

--: (JType) -> JType
local function deep_prune(t)
	t = prune(t)
	if t.tag == "fun" then
		return { tag = "fun", from = deep_prune(t.from), to = deep_prune(t.to) }
	end
	return t
end

-- Unify by MUTATING a var's cell in place (`t.cell.bound = other`) rather
-- than recording the binding in a substitution table returned to the
-- caller — this is J's defining structural difference from W's `unify`.
--: (JType, JType) -> (boolean | nil, string | nil)
local function unify(a, b)
	a = prune(a)
	b = prune(b)
	if a.tag == "var" then
		a.cell.bound = b
		return true
	end
	if b.tag == "var" then
		b.cell.bound = a
		return true
	end
	if a.tag == "con" and b.tag == "con" then
		if a.name ~= b.name then return nil, "cannot unify " .. a.name .. " with " .. b.name end
		return true
	end
	if a.tag == "fun" and b.tag == "fun" then
		local ok, err = unify(a.from, b.from)
		if not ok then return nil, err end
		return unify(a.to, b.to)
	end
	return nil, "cannot unify " .. tostring(a.tag) .. " with " .. tostring(b.tag)
end

--: (JType) -> string
local function show_type(t)
	if t.tag == "con" then return t.name end
	if t.tag == "var" then return "'" .. t.id end
	if t.tag == "fun" then return "(" .. show_type(t.from) .. " -> " .. show_type(t.to) .. ")" end
	return "?"
end

-- ---- certificate construction -------------------------------------------

--:: Builder = { nodes: { [string]: JNode }, hypotheses: { [string]: JHypothesis }, node_counter: integer, hyp_counter: integer }

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

--: (Builder, string, JType) -> string
local function add_hyp(b, name, jtype)
	b.hyp_counter = b.hyp_counter + 1
	local id = "h" .. b.hyp_counter
	b.hypotheses[id] = { id = id, judgment = "has_type", payload = { name = name, type_str = show_type(jtype) } }
	return id
end

--:: JEnvEntry = { hyp_id: string, type: JType }
--:: JEnv = { [string]: JEnvEntry }

-- No `subst` parameter threaded through, unlike algorithm_w.lua's `infer` —
-- unification mutates cells reachable from any type already handed out, so
-- there is nothing to thread. This is the whole point of J's style.
--: (JTerm, JEnv, Builder) -> (JType | nil, string | nil, string | nil)
local function infer(term, env, b)
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
			conclusion = { term = term.locus, type_str = show_type(prune(binding.type)) },
			premises = {},
			assumes = { binding.hyp_id },
		})
		return binding.type, node_id, nil
	elseif term.tag == "abs" then
		local param_type = fresh_var()
		local hyp_id = add_hyp(b, term.param, param_type)
		local inner_env = setmetatable({ [term.param] = { hyp_id = hyp_id, type = param_type } }, { __index = env })
		local body_type, body_node, err = infer(term.body, inner_env, b)
		if not body_type then return nil, nil, err end
		local t = { tag = "fun", from = param_type, to = body_type }
		local node_id = add_node(b, {
			rule = "W-Abs", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_prune(t)) },
			premises = { body_node },
			discharges = { hyp_id },
		})
		return t, node_id, nil
	elseif term.tag == "app" then
		local fn_type, fn_node, err1 = infer(term.fn, env, b)
		if not fn_type then return nil, nil, err1 end
		local arg_type, arg_node, err2 = infer(term.arg, env, b)
		if not arg_type then return nil, nil, err2 end
		local result_type = fresh_var()
		local ok, uerr = unify(fn_type, { tag = "fun", from = arg_type, to = result_type })
		if not ok then return nil, nil, "at " .. term.locus .. ": " .. (uerr or "unify failed") end
		local node_id = add_node(b, {
			rule = "W-App", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_prune(result_type)) },
			premises = { fn_node, arg_node },
		})
		return result_type, node_id, nil
	elseif term.tag == "let" then
		local value_type, value_node, err1 = infer(term.value, env, b)
		if not value_type then return nil, nil, err1 end
		-- DELIBERATE WEAKNESS, matching algorithm_w.lua: no generalization —
		-- see module header. `name` is bound directly to value_type
		-- (monomorphic), not to a re-instantiated forall-scheme.
		local hyp_id = add_hyp(b, term.name, value_type)
		local inner_env = setmetatable({ [term.name] = { hyp_id = hyp_id, type = value_type } }, { __index = env })
		local body_type, body_node, err2 = infer(term.body, inner_env, b)
		if not body_type then return nil, nil, err2 end
		local node_id = add_node(b, {
			rule = "W-Let", judgment = "has_type", locus = term.locus,
			conclusion = { term = term.locus, type_str = show_type(deep_prune(body_type)) },
			premises = { value_node, body_node },
			discharges = { hyp_id },
		})
		return body_type, node_id, nil
	end
	return nil, nil, "unknown term tag " .. tostring(term.tag)
end

-- Infer `term`'s type and emit a certificate citing (W's, reused) rule
-- schemas. Returns (certificate, nil) on success, or (nil, errmsg) on an
-- inference failure (unify mismatch, unbound variable) — never a thrown
-- error.
--: (JTerm) -> (JCert | nil, string | nil)
function M.certify(term)
	local b = new_builder()
	local _, root_node, err = infer(term, {}, b)
	if not root_node then return nil, err end
	return { theory = M.THEORY, nodes = b.nodes, hypotheses = b.hypotheses, root = root_node }, nil
end

return M
