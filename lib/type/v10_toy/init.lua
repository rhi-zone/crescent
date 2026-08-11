-- v10_toy core kernel: terms, signatures, pattern matching, instantiation, replay.
-- EXPERIMENT — afternoon-test artifact, not canon. See README.md.
--
-- Trust boundary: everything in this file is the TRUSTED replay/kernel code.
-- w.lua's prover is UNTRUSTED; only what replay() checks here matters for soundness.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- A term is one of:
--   { tag = "var",  index = int,    sort = string }
--   { tag = "op",   op = string,    args = { term, ... } }
--   { tag = "meta", name = string,  sort = string }
--:: Term = { tag: "var", index: integer, sort: string } | { tag: "op", op: string, args: Term[] } | { tag: "meta", name: string, sort: string }

-- A signature declares operators: sig[name] = { result = sort, args = {
-- { sort = sort, binds = { sort, ... } }, ... } }. `binds` lists the sorts of
-- variables that argument position binds over its subtree.
--:: ArgDecl = { sort: string, binds: string[] }
--:: OpDecl = { result: string, args: ArgDecl[] }
--:: Sig = { [string]: OpDecl }

--:: Env = { [string]: Term }

-- ── term constructors ──────────────────────────────────────────────────────

--: (index: integer, sort: string) -> Term
function M.var(index, sort) return { tag = "var", index = index, sort = sort } end
--: (name: string, args: Term[]) -> Term
function M.op(name, args) return { tag = "op", op = name, args = args } end
--: (name: string, sort: string) -> Term
function M.meta(name, sort) return { tag = "meta", name = name, sort = sort } end

--: (term: Term, sig: Sig) -> string | nil
function M.sort_of(term, sig)
	if term.tag == "var" or term.tag == "meta" then return term.sort end
	local decl = sig[term.op]
	return decl and decl.result or nil
end

-- ── structural equality (de Bruijn indices make this alpha-equivalence-safe) ──

--: (a: Term, b: Term) -> boolean
local function deep_eq(a, b)
	if a == b then return true end
	if a.tag ~= b.tag then return false end
	if a.tag == "var" and b.tag == "var" then return a.index == b.index and a.sort == b.sort end
	if a.tag == "meta" and b.tag == "meta" then return a.name == b.name and a.sort == b.sort end
	if a.tag == "op" and b.tag == "op" then
		if a.op ~= b.op or #a.args ~= #b.args then return false end
		for i = 1, #a.args do
			if not deep_eq(a.args[i], b.args[i]) then return false end
		end
		return true
	end
	return false
end
M.deep_eq = deep_eq

--: (term: Term) -> boolean
function M.has_metavars(term)
	if term.tag == "meta" then return true end
	if term.tag == "op" then
		for _, a in ipairs(term.args) do
			if M.has_metavars(a) then return true end
		end
	end
	return false
end

-- A var node is free at `depth` iff its index reaches past `depth` enclosing
-- binders — depth must account for each ancestor operator argument's `binds`
-- (per its signature declaration), not just a flat tree scan, or a var
-- legitimately bound by an enclosing operator (e.g. var(0) inside abs(...))
-- would be misreported as free.
--: (term: Term, sig: Sig, depth: integer | nil) -> boolean
function M.has_free_vars(term, sig, depth)
	depth = depth or 0
	if term.tag == "var" then return term.index >= depth end
	if term.tag == "op" then
		local decl = sig[term.op]
		for i, a in ipairs(term.args) do
			local arg_decl = decl and decl.args[i]
			local extra = arg_decl and #arg_decl.binds or 0
			if M.has_free_vars(a, sig, depth + extra) then return true end
		end
	end
	return false
end

-- ── pattern matching ─────────────────────────────────────────────────────────
-- match(pattern, term, sig, env) -> env | nil, errmsg
-- STUMBLE: the concept says "matching a pattern against a metavariable-free
-- term". In this toy, the prover always emits fully-substituted derivations
-- (see w.lua design note), so targets are metavariable-free in practice; match
-- does not special-case a metavariable-bearing target — it will simply fail to
-- unify against a concrete var/op pattern, which is the correct behavior.

--: (pattern: Term, target: Term, sig: Sig, env: Env) -> Env | (nil, string)
function M.match(pattern, target, sig, env)
	if pattern.tag == "meta" then
		if M.sort_of(pattern, sig) ~= M.sort_of(target, sig) then
			return nil, "sort mismatch for metavariable " .. pattern.name
		end
		local existing = env[pattern.name]
		if existing then
			if deep_eq(existing, target) then return env end
			return nil, "metavariable " .. pattern.name .. " bound to inconsistent subterms"
		end
		env[pattern.name] = target
		return env
	elseif pattern.tag == "var" then
		if target.tag ~= "var" or target.index ~= pattern.index or target.sort ~= pattern.sort then
			return nil, "variable pattern mismatch"
		end
		return env
	elseif pattern.tag == "op" then
		if target.tag ~= "op" or target.op ~= pattern.op then
			local got = target.tag == "op" and target.op or target.tag
			return nil, "operator mismatch: expected " .. pattern.op .. " got " .. got
		end
		if #pattern.args ~= #target.args then
			return nil, "arity mismatch for " .. pattern.op
		end
		local e = env
		for i = 1, #pattern.args do
			local e2, err = M.match(pattern.args[i], target.args[i], sig, e)
			-- TYPECHECKER WORKAROUND: `if not e2 then` fails to narrow away
			-- the `(nil, string)` arm of this multi-return union type within
			-- the truthy branch below (confirmed via minimal repro; same
			-- class of gap as TODO.md's v10_kernel entries on positional
			-- multi-return unions). `type(e2) == "table"` narrows correctly.
			if type(e2) ~= "table" then return nil, err or "match failed" end
			e = e2
		end
		return e
	end
	return nil, "malformed pattern"
end

-- ── instantiation ─────────────────────────────────────────────────────────────
-- instantiate(pattern, env) -> term | nil, errmsg
-- STUMBLE: "crossing binders shifts indices" — see README STUMBLE LOG. This
-- toy's rules never place a metavariable at a binder-depth different from
-- where it was captured (the hypothesis+discharge mechanism carries object-
-- level context instead), so instantiate substitutes metavariables verbatim,
-- with no automatic index shift. var-pattern nodes are copied through as-is
-- (they denote a fixed structural binder position, not a hole).

--: (pattern: Term, env: Env) -> Term | (nil, string)
function M.instantiate(pattern, env)
	if pattern.tag == "var" then
		return { tag = "var", index = pattern.index, sort = pattern.sort }
	elseif pattern.tag == "meta" then
		local v = env[pattern.name]
		if not v then return nil, "unbound metavariable " .. pattern.name end
		return v
	elseif pattern.tag == "op" then
		local args = {} --[[: Term[] ]]
		for i, a in ipairs(pattern.args) do
			local t, err = M.instantiate(a, env)
			if type(t) ~= "table" then return nil, err or "instantiate failed" end
			args[i] = t
		end
		return { tag = "op", op = pattern.op, args = args }
	end
	return nil, "malformed pattern"
end

-- ── rules ──────────────────────────────────────────────────────────────────
-- An axiom is a rule with premises = {} whose conclusion is assumed. Naming
-- convention: axiom names carry an explicit version, e.g. "LitIntType@v1"
-- (per concept #4, "named and versioned"); ordinary rules are just named.
--:: DischargeSlot = { premise: integer, hyp: Term }
--:: Rule = { name: string, premises: Term[], conclusion: Term, discharge: DischargeSlot[] | nil }
--:: Rules = { [string]: Rule }

-- ── derivation nodes ─────────────────────────────────────────────────────────
-- hyp node:   { kind = "hyp", judgment = term }
--             the node TABLE ITSELF is its identity/id (no string ids: this
--             sidesteps id-collision bugs entirely — see README STUMBLE LOG).
-- axiom node: { kind = "axiom", rule = name, bindings = { [metaname] = term } }
-- rule node:  { kind = "rule", rule = name, premises = { node, ... },
--               bindings = { [metaname] = term } | nil,   -- see below
--               discharge = { [slotIndex] = { hypNode, ... } } | nil }
--
-- STUMBLE: `bindings` on rule/axiom nodes. Axiom citations need bindings by
-- construction (concept #5: "axiom citations (with bindings for the axiom's
-- metavariables)"). Ordinary rule citations are not given this in the concept
-- text, but this toy's InstantiateEndo rule needs to introduce a metavariable
-- that appears ONLY in the conclusion pattern, never in any premise pattern
-- (a fresh type at a polymorphic use site) — nothing in the concept's match/
-- instantiate primitives can conjure such a value from premises alone. We
-- extend rule nodes with an optional `bindings` field, used ONLY to pre-seed
-- metavariables not touched by any premise match; anything a premise DOES
-- bind is still independently recomputed and never trusted from the citation.
--:: Node = { kind: "hyp", judgment: Term }
--        | { kind: "axiom", rule: string, bindings: Env | nil }
--        | { kind: "rule", rule: string, premises: Node[], bindings: Env | nil, discharge: { [integer]: Node[] } | nil }

--:: Taint = { [string]: boolean }

-- TYPECHECKER WORKAROUND: the natural representation for a hypothesis-node
-- SET (open hyps, discharged ids, the replay memo) is a map keyed by node
-- TABLE IDENTITY — there is no primitive id to key by instead, and concept
-- #5 deliberately makes the node itself the identity (see README STUMBLE LOG
-- #6). `{ [Node]: V }` parses as a type but a `{}` literal cannot be assigned
-- to it ("missing field 'Node'" — confirmed via a minimal repro outside this
-- file: the checker's index-signature literal-assignability check only
-- special-cases `[string]`/`[integer]` keys, not an arbitrary key type alias).
-- This is the same class of gap already on record in TODO.md for
-- lib/type/v10_kernel's replayer (`[unknown]`-keyed memo maps). Worked around
-- here with array-of-pairs + linear scan instead of a hash map — table
-- identity via `==` still works fine as the comparison; only O(1) lookup is
-- lost, irrelevant at this toy's scale. TODO.md has a matching entry; revisit
-- if `{ [SomeAliasType]: V }` literal assignment is ever fixed.
--:: OpenEntry = { node: Node, judgment: Term }
--:: OpenSet = OpenEntry[]

--: (open: OpenSet, node: Node) -> Term | nil
local function open_get(open, node)
	for _, e in ipairs(open) do
		if e.node == node then return e.judgment end
	end
	return nil
end

--: (nodes: Node[], node: Node) -> boolean
local function node_list_has(nodes, node)
	for _, n in ipairs(nodes) do
		if n == node then return true end
	end
	return false
end

-- replay_node returns a discriminated-union result rather than overloading
-- Lua multi-return arity for the success/error cases: with (Term, Taint,
-- OpenSet) on success vs (nil, string) on error sharing return positions,
-- a checker has no sound way to narrow the 2nd/3rd positions' types together
-- with the 1st. A single tagged result makes every call site's narrowing
-- exact instead of positional-union guesswork.
--:: ReplayResult = { ok: true, conclusion: Term, taint: Taint, open: OpenSet } | { ok: false, err: string }
--:: MemoEntry = { node: Node, result: ReplayResult }
--:: Memo = MemoEntry[]

--: (memo: Memo, node: Node) -> ReplayResult | nil
local function memo_get(memo, node)
	for _, e in ipairs(memo) do
		if e.node == node then return e.result end
	end
	return nil
end

-- A single self-recursive function (Lua's `local function` scopes its own
-- name for its body, so this needs no forward declaration) rather than
-- separate mutually-recursive helpers: this checker cannot give a
-- forward-declared local a non-nilable function type before its assignment
-- runs, and self-recursion sidesteps that entirely.
--: (node: Node, sig: Sig, rules: Rules, memo: Memo) -> ReplayResult
local function replay_node(node, sig, rules, memo)
	local cached = memo_get(memo, node)
	if cached then return cached end

	-- TYPECHECKER WORKAROUND: an annotated-but-uninitialized local always
	-- requires its type to include `nil`, even though every branch below
	-- assigns before the final read — no definite-assignment analysis across
	-- branches. Given a real (overwritten-before-use) initializer instead of
	-- widening the type to `ReplayResult | nil`, which would just relocate the
	-- non-null obligation to the final `memo[...]=result; return result`
	-- instead of removing it. See TODO.md.
	local result = { ok = false, err = "unreachable" } --: ReplayResult

	if node.kind == "hyp" then
		result = { ok = true, conclusion = node.judgment, taint = {}, open = { { node = node, judgment = node.judgment } } }
	elseif node.kind == "axiom" then
		local rule = rules[node.rule]
		if not rule then
			result = { ok = false, err = "unknown rule/axiom: " .. tostring(node.rule) }
		elseif #rule.premises > 0 then
			result = { ok = false, err = rule.name .. " is not an axiom (has premises)" }
		else
			local env = {} --[[: Env ]]
			for k, v in pairs(node.bindings or {}) do env[k] = v end
			local concl, err = M.instantiate(rule.conclusion, env)
			if type(concl) == "table" then
				result = { ok = true, conclusion = concl, taint = { [rule.name] = true }, open = {} }
			else
				result = { ok = false, err = err or "instantiate failed" }
			end
		end
	elseif node.kind ~= "rule" then
		result = { ok = false, err = "malformed node: unknown kind" }
	else
		-- TYPECHECKER WORKAROUND: `node.premises`/`node.discharge` are typed
		-- `Node[]`/`{[integer]:Node[]}|nil` — Node's OWN "rule" variant
		-- referencing Node recursively. Reading either field directly after
		-- narrowing `node.kind == "rule"` infers `never` (confirmed via a
		-- 6-line minimal repro outside this file, independent of branch
		-- order/position — any read of a self-recursive union variant's own
		-- recursively-typed field narrows to `never`). A checked cast
		-- (sound: `never` is a subtype of everything) recovers the real type.
		-- See TODO.md.
		local node_premises = node.premises --[[: Node[] ]]
		local node_discharge = node.discharge --[[: { [integer]: Node[] } | nil ]]
		local rule = rules[node.rule]
		local n_expected = rule and #rule.premises or 0
		local n_given = #node_premises
		if not rule then
			result = { ok = false, err = "unknown rule/axiom: " .. tostring(node.rule) }
		elseif n_expected ~= n_given then
			result = { ok = false, err = rule.name .. ": expected " .. n_expected .. " premises, got " .. n_given }
		else
			-- Recompute every premise's conclusion, taint and open set
			-- bottom-up, matching each premise pattern into a shared env.
			local premise_open = {} --[[: { [integer]: OpenSet } ]]
			local taint = {} --[[: Taint ]]
			local env = {} --[[: Env ]]
			for k, v in pairs(node.bindings or {}) do env[k] = v end
			local premise_err = nil --: string | nil

			for i = 1, #rule.premises do
				if not premise_err then
					-- TYPECHECKER WORKAROUND: same ReplayResult narrowing gap
					-- as M.replay above, here on a recursive call's result
					-- instead of a top-level one. See TODO.md.
					local pr = replay_node(node_premises[i], sig, rules, memo)
					if pr.ok == true then
						local p_open = pr.open --[[: OpenSet ]]
						local p_taint = pr.taint --[[: Taint ]]
						local p_concl = pr.conclusion --[[: Term ]]
						premise_open[i] = p_open
						for name in pairs(p_taint) do taint[name] = true end
						local e2, err = M.match(rule.premises[i], p_concl, sig, env)
						if type(e2) == "table" then
							env = e2
						else
							premise_err = rule.name .. " premise " .. i .. ": " .. (err or "")
						end
					else
						local p_err = pr.err --[[: string ]]
						premise_err = p_err
					end
				end
			end

			if premise_err then
				result = { ok = false, err = premise_err }
			else
				-- Discharge: each slot closes a declared SET of hypothesis
				-- nodes that must be open in the referenced premise, and
				-- whose carried judgment must equal the slot's hypothesis
				-- pattern instantiated with the (possibly still-growing)
				-- shared bindings. STUMBLE: "equal" is read as "matches via
				-- the same match() procedure used for premises" (extending
				-- env), not a plain equality-of-already-closed-terms check —
				-- see README, required for AbsType's T1, bound by no
				-- premise, only by discharge.
				local discharged = {} --[[: Node[] ]]
				local discharge_err = nil --: string | nil
				for slot_idx, rule_slot in ipairs(rule.discharge or {}) do
					local ids = (node_discharge or {})[slot_idx] or {}
					for _, hyp_node in ipairs(ids) do
						if not discharge_err then
							local slot_open = premise_open[rule_slot.premise]
							local judgment = slot_open and open_get(slot_open, hyp_node)
							if not judgment then
								discharge_err = rule.name .. " discharge slot " .. slot_idx .. ": hypothesis not open in premise " .. rule_slot.premise
							else
								local e2, err = M.match(rule_slot.hyp, judgment, sig, env)
								if type(e2) == "table" then
									env = e2
									discharged[#discharged + 1] = hyp_node
								else
									discharge_err = rule.name .. " discharge slot " .. slot_idx .. ": " .. (err or "")
								end
							end
						end
					end
				end

				if discharge_err then
					result = { ok = false, err = discharge_err }
				else
					local concl, ierr = M.instantiate(rule.conclusion, env)
					if type(concl) ~= "table" then
						result = { ok = false, err = ierr or "instantiate failed" }
					else
						local open = {} --[[: OpenSet ]]
						for i = 1, #rule.premises do
							for _, e in ipairs(premise_open[i]) do
								if not node_list_has(discharged, e.node) then open[#open + 1] = e end
							end
						end
						result = { ok = true, conclusion = concl, taint = taint, open = open }
					end
				end
			end
		end
	end

	memo[#memo + 1] = { node = node, result = result }
	return result
end

--- Replay a derivation bottom-up, trusting nothing in it.
-- Returns (conclusion, taint) at an accepted root, or (nil, errmsg) if the
-- derivation is malformed/unsound/leaves metavariables, free variables, or
-- undischarged hypotheses at the root.
--: (node: Node, sig: Sig, rules: Rules) -> (Term, Taint) | (nil, string)
function M.replay(node, sig, rules)
	local memo = {} --[[: Memo ]]
	local r = replay_node(node, sig, rules, memo)
	-- TYPECHECKER WORKAROUND: `if r.ok then` (a boolean-literal discriminant
	-- check, the documented normally-working pattern) does not narrow away
	-- the `{ok:false,err:string}` arm here — confirmed via a 12-line minimal
	-- repro outside this file, independent of ReplayResult's use of the
	-- recursive Node type elsewhere (this repro used a plain, non-recursive
	-- union). Checked casts on each field recover the real type. See TODO.md.
	if r.ok == true then
		local conclusion = r.conclusion --[[: Term ]]
		local taint = r.taint --[[: Taint ]]
		local open = r.open --[[: OpenSet ]]
		if M.has_metavars(conclusion) then return nil, "root conclusion contains metavariables" end
		if M.has_free_vars(conclusion, sig) then return nil, "root conclusion contains free variables" end
		if #open > 0 then return nil, "root has " .. #open .. " undischarged hypothesis(es)" end
		return conclusion, taint
	end
	local err = r.err --[[: string ]]
	return nil, err
end

return M
