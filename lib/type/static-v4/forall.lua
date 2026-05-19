-- Universal quantification — Phase 4e.
--
-- Implements the API surface for rank-N polymorphism (rewrite design §6):
--
--   * `M.instantiate(forall)` — substitute each bound var with a fresh free
--     variable. Used when the LHS of a subsumption is a forall (or when a
--     polymorphic value is used at a call site).
--   * `M.skolemize(forall)`   — substitute each bound var with a fresh skolem
--     constant. Used when the RHS of a subsumption is a forall (the LHS must
--     work for an *arbitrary* choice of the bound vars, so we replace them
--     with opaque rigid tags and check the body, then verify the skolems do
--     not escape).
--   * `M.substitute(t, subst)` — pure substitution of a `{ [var_id]: V4Type }`
--     map. Shared with `match.lua`'s capture freshening, lifted to a single
--     implementation that handles every tag in the lattice (including the new
--     `forall` and `skolem` tags introduced by 4e).
--   * `M.contains_skolem(t, set, free_var_visited)` — escape-check primitive.
--     Walks `t` and every reachable variable bound list, returning true if any
--     skolem in `set` appears. Used after subsuming `T <: U[skolems/X]` to
--     verify the skolems did not flow back into T's free variables' bounds.
--
-- The substitution does NOT descend into `mu` bodies (cyclic Lua tables —
-- naive descent would not terminate; bound vars cannot legitimately live
-- inside a μ body because μ's binder shadows nothing) and does NOT descend
-- into nested `forall` bodies whose `vars` shadow an outer name (capture-
-- avoiding substitution: the inner forall's bound names are out of scope for
-- the outer substitution).

local T = require("lib.type.static-v4.types")

local M = {}

-- Substitute according to `subst` (id → replacement type). Returns a new term
-- or the original when no substitution applies (cheap structural sharing).
-- Capture-avoiding: an inner `forall` whose vars overlap with `subst` keys
-- shadows those substitutions for its body.
local substitute -- (V4Type, { [integer]: V4Type }) -> V4Type
--: (V4Type, { [integer]: V4Type }) -> V4Type
substitute = function(t, subst)
	if t.tag == "var" then
		local v = subst[t.id]
		if v ~= nil then return v end
		return t
	elseif t.tag == "top" or t.tag == "bot" or t.tag == "prim" or t.tag == "literal"
		or t.tag == "skolem" or t.tag == "mu" then
		-- mu: cyclic; skolem/top/bot/prim/literal: no inner type variables.
		return t
	elseif t.tag == "fn" then
		local ps = {} --[[: V4Type[] ]]
		for i, p in ipairs(t.params) do ps[i] = substitute(p, subst) end
		return T.fn(ps, substitute(t.ret, subst), t.effects)
	elseif t.tag == "rec" then
		local fs = {} --[[: { [string]: V4Type } ]]
		for k, v in pairs(t.fields) do
			if v ~= nil then fs[k] = substitute(v, subst) end
		end
		local ix = t.indexer
		local new_ix = nil --[[: V4Indexer | nil ]]
		if ix ~= nil then
			new_ix = T.indexer(substitute(ix.key, subst), substitute(ix.value, subst))
		end
		return T.rec(fs, t.open, new_ix)
	elseif t.tag == "union" then
		local ms = {} --[[: V4Type[] ]]
		for i, m in ipairs(t.members) do ms[i] = substitute(m, subst) end
		return T.union(ms)
	elseif t.tag == "inter" then
		local ms = {} --[[: V4Type[] ]]
		for i, m in ipairs(t.members) do ms[i] = substitute(m, subst) end
		return T.inter(ms)
	elseif t.tag == "neg" then
		return T.neg(substitute(t.body, subst))
	else
		-- t.tag == "forall". Capture-avoiding: remove shadowed ids from subst.
		local inner = {} --[[: { [integer]: V4Type } ]]
		local shadowed = {} --[[: { [integer]: boolean } ]]
		for _, v in ipairs(t.vars) do
			if v.tag == "var" then shadowed[v.id] = true end
		end
		local any = false
		for id, repl in pairs(subst) do
			if not shadowed[id] then inner[id] = repl; any = true end
		end
		if not any then return t end
		return T.forall_raw(t.vars, substitute(t.body, inner))
	end
end

M.substitute = substitute

-- Instantiate a forall: replace each bound var with a fresh free variable and
-- return the substituted body. Each call produces independent fresh vars so
-- two uses of the same polymorphic value at different concrete types do not
-- entangle.
--: (V4Type) -> V4Type
function M.instantiate(forall)
	if forall.tag ~= "forall" then return forall end
	-- Narrowing: from here on `forall` has tag "forall" and the fields below.
	local body = forall.body
	local vars = forall.vars
	local subst = {} --[[: { [integer]: V4Type } ]]
	for _, v in ipairs(vars) do
		if v.tag == "var" then
			local nv = T.var(v.name) --[[: V4Type]]
			subst[v.id] = nv
		end
	end
	return substitute(body, subst)
end

-- Skolemize a forall: replace each bound var with a fresh skolem and return
-- (body, skolems). The skolems are the rigid opaque tags used by the escape
-- check; the caller (subtype.lua) holds them until the subsumption succeeds,
-- then walks the surviving free vars in the LHS to ensure no skolem escaped.
--: (V4Type) -> (V4Type, V4Type[])
function M.skolemize(forall)
	if forall.tag ~= "forall" then return forall, ({} --[[: V4Type[] ]]) end
	local body = forall.body
	local vars = forall.vars
	local subst = {} --[[: { [integer]: V4Type } ]]
	local skolems = {} --[[: V4Type[] ]]
	for _, v in ipairs(vars) do
		if v.tag == "var" then
			local sk = T.skolem(v.name) --[[: V4Type]]
			subst[v.id] = sk
			skolems[#skolems + 1] = sk
		end
	end
	return substitute(body, subst), skolems
end

-- ── Escape check ──────────────────────────────────────────────────────────
--
-- After subsuming `T <: U[skolems/X]`, none of the introduced skolems may
-- appear in T or in the bounds (transitive closure) of any free variable in
-- T. If a skolem escapes, the subsumption is unsound — the conclusion
-- `T <: ∀X. U` depends on a specific choice of X, contradicting universality.
--
-- The check walks `t` and, when it encounters a variable, recursively descends
-- into the variable's lower/upper bound lists (and linked variables). The
-- `seen` set tracks visited variable ids to terminate on cyclic bound graphs.

local contains_skolem -- (V4Type, { [integer]: boolean }, { [integer]: boolean }) -> V4Type | nil
--: (V4Type, { [integer]: boolean }, { [integer]: boolean }) -> V4Type | nil
contains_skolem = function(t, skolem_ids, seen)
	if t.tag == "skolem" then
		if skolem_ids[t.id] then return t end
		return nil
	elseif t.tag == "top" or t.tag == "bot" or t.tag == "prim" or t.tag == "literal" then
		return nil
	elseif t.tag == "fn" then
		for _, p in ipairs(t.params) do
			local found = contains_skolem(p, skolem_ids, seen)
			if found ~= nil then return found end
		end
		return contains_skolem(t.ret, skolem_ids, seen)
	elseif t.tag == "rec" then
		for _, v in pairs(t.fields) do
			if v ~= nil then
				local found = contains_skolem(v, skolem_ids, seen)
				if found ~= nil then return found end
			end
		end
		local ix = t.indexer
		if ix ~= nil then
			local found = contains_skolem(ix.key, skolem_ids, seen)
			if found ~= nil then return found end
			found = contains_skolem(ix.value, skolem_ids, seen)
			if found ~= nil then return found end
		end
		return nil
	elseif t.tag == "union" or t.tag == "inter" then
		for _, m in ipairs(t.members) do
			local found = contains_skolem(m, skolem_ids, seen)
			if found ~= nil then return found end
		end
		return nil
	elseif t.tag == "neg" then
		return contains_skolem(t.body, skolem_ids, seen)
	elseif t.tag == "mu" then
		-- mu bodies are cyclic; descend with a seen-set keyed by mu id. We
		-- piggyback on `seen` using negative keys so they don't collide with
		-- variable ids. Skipping mu entirely is unsound (a skolem could be
		-- referenced from inside a recursive type built during subsumption).
		-- No cleanup on exit: the walk is a one-shot search; marking a node
		-- visited prevents re-entry across sibling branches without harming
		-- correctness (any second visit would have produced the same answer).
		local key = -t.id
		if seen[key] then return nil end
		seen[key] = true
		return contains_skolem(t.body, skolem_ids, seen)
	elseif t.tag == "forall" then
		-- Skolems from an outer scope can still appear inside an inner forall's
		-- body — the forall's binder shadows variable names, not skolem ids.
		return contains_skolem(t.body, skolem_ids, seen)
	else
		-- t.tag == "var"
		if seen[t.id] then return nil end
		seen[t.id] = true
		for _, b in ipairs(t.lower) do
			local found = contains_skolem(b, skolem_ids, seen)
			if found ~= nil then return found end
		end
		for _, b in ipairs(t.upper) do
			local found = contains_skolem(b, skolem_ids, seen)
			if found ~= nil then return found end
		end
		for _, vp in pairs(t.lower_vars) do
			local found = contains_skolem(vp, skolem_ids, seen)
			if found ~= nil then return found end
		end
		for _, vp in pairs(t.upper_vars) do
			local found = contains_skolem(vp, skolem_ids, seen)
			if found ~= nil then return found end
		end
		return nil
	end
end

-- Returns the offending skolem type (or nil if none escape). The id-set is
-- built from the `skolems` list returned by `skolemize`.
--: (V4Type, V4Type[]) -> V4Type | nil
function M.find_escape(t, skolems)
	if #skolems == 0 then return nil end
	local ids = {} --[[: { [integer]: boolean } ]]
	for _, s in ipairs(skolems) do
		if s.tag == "skolem" then ids[s.id] = true end
	end
	return contains_skolem(t, ids, {} --[[: { [integer]: boolean } ]])
end

return M
