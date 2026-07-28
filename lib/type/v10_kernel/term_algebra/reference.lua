-- lib/type/v10_kernel/term_algebra/reference.lua
--
-- Reference tier of the v10 kernel term algebra: this tier IS the semantic
-- definition (docs/decisions/typechecker-v10-core-design.md, "Kernel
-- primitive tiers and trust"). Structural equality by full recursive walk;
-- eager de Bruijn substitution (Pierce, TAPL 6.2.1: replace the exact index
-- match, leave every other index untouched, bump the target index and
-- shift the substituted term by one when descending under one binder —
-- generalized here to the n-ary valences the signature format allows).
--
-- The fast tier (fast.lua) is checked against this one by parity tests and
-- parity fuzzing (term_algebra_parity_test.lua), never the reverse.
--
-- Term grammar (exactly three node forms, per the ratified design), each
-- its own tagged shape (a distinct hidden class per LuaJIT construction
-- guidance, not one bloated shape with filler nil fields):
--   var(index, sort)   — de Bruijn index; carries its own sort (ratified:
--                         "intrinsically-sorted nodes" — sort_of must be
--                         O(1) and total over every term, including a
--                         free-floating var built on its own).
--   op(decl, args)      — operator node; args[i] = { bound_count, term }
--                         where bound_count is STAMPED by `build` from the
--                         operator's declared valence (#binds) — callers
--                         never pass it.
--   meta(id, sort)      — metavariable; legal in pattern positions only.
--
-- Every node also carries, computed once at construction (`build`):
--   .sort   — O(1) sort_of.
--   .ctx    — free-variable context: map from every de Bruijn index free in
--             the term (relative to the term's own root) to its sort.
--             var(k,s) has ctx={[k]=s}; meta has ctx={} (a metavariable is
--             a distinguished leaf, not a bound-variable reference). An
--             op's ctx is computed by discharging each argument's locally-
--             bound indices against the operator's declared `binds` (see
--             shared.discharge_arg_ctx) and merging across arguments (see
--             shared.merge_ctxs), which is exactly how `build` validates
--             that "ill-sorted terms are unrepresentable" for bound
--             variables: a var node's self-declared sort must agree with
--             the binder that actually scopes it, checked positionally
--             (index 0 matches binds[1], ..., index n-1 matches binds[n]).
--   .ground — no meta node anywhere in the term (is_ground, cached).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local shared = require("lib.type.v10_kernel.term_algebra.shared")

local M = {}

--:: SortName = string
--:: SortDecl = { name: string, sig_name: string, sig_version: integer }
--:: Ctx = { [integer]: SortDecl }
--:: OpArgDecl = { sort: SortDecl, binds: SortDecl[], bound_count: integer }
--:: OpDecl = { name: string, sig_name: string, sig_version: integer, result: SortDecl, args: OpArgDecl[], arity: integer }
--:: OpArg = { bound_count: integer, term: Term }
--:: VarTerm = { tag: "var", index: integer, sort: SortDecl, ctx: Ctx, ground: boolean }
--:: MetaTerm = { tag: "meta", id: string, sort: SortDecl, ctx: Ctx, ground: boolean }
--:: OpTerm = { tag: "op", decl: OpDecl, args: OpArg[], sort: SortDecl, ctx: Ctx, ground: boolean }
--:: Term = VarTerm | MetaTerm | OpTerm
--:: Binding = { term: Term, depth: integer }
--:: Bindings = { [string]: Binding }

-- ── Construction (build family — the only way to construct a term) ──────────
--
-- `sort` is a declared SortDecl object (identity-by-declaration — see
-- shared.lua's "Sort identity" section), never a bare string: sort equality
-- throughout this file is Lua object identity (`==`/`~=`), not name
-- equality.

--: (index: integer, sort: SortDecl) -> (VarTerm | nil, string | nil)
function M.build_var(index, sort)
	if type(index) ~= "number" then return nil, "build_var: index must be a non-negative integer" end
	if index < 0 then return nil, "build_var: index must be a non-negative integer" end
	local idx = math.floor(index)
	if idx ~= index then return nil, "build_var: index must be a non-negative integer" end
	if not shared.is_sort_decl(sort) then return nil, "build_var: sort must be a declared sort object" end
	return { tag = "var", index = idx, sort = sort, ctx = { [idx] = sort }, ground = true }
end

--: (id: string, sort: SortDecl) -> (MetaTerm | nil, string | nil)
function M.build_meta(id, sort)
	if type(id) ~= "string" then return nil, "build_meta: id must be a string" end
	if not shared.is_sort_decl(sort) then return nil, "build_meta: sort must be a declared sort object" end
	return { tag = "meta", id = id, sort = sort, ctx = {}, ground = false }
end

--: (decl: OpDecl, args: Term[]) -> (OpTerm | nil, string | nil)
function M.build(decl, args)
	if #args ~= decl.arity then
		return nil, "build: " .. decl.name .. " expects " .. decl.arity .. " args, got " .. #args
	end

	local out_args = {} --[[: OpArg[] ]]
	local child_ctxs = {} --[[: Ctx[] ]]
	local ground = true
	for i = 1, decl.arity do
		local argdecl = decl.args[i]
		local term = args[i]
		if term.sort ~= argdecl.sort then
			return nil, "build: " .. decl.name .. " arg " .. i .. " expected sort " .. argdecl.sort.name
				.. ", got " .. term.sort.name
		end
		local outer_ctx, err = shared.discharge_arg_ctx(term.ctx, argdecl.binds)
		if not outer_ctx then
			return nil, "build: " .. decl.name .. " arg " .. i .. ": " .. (err or "sort mismatch under binder")
		end
		out_args[i] = { bound_count = argdecl.bound_count, term = term }
		child_ctxs[i] = outer_ctx
		if not term.ground then ground = false end
	end

	local ctx, merge_err = shared.merge_ctxs(child_ctxs)
	if not ctx then
		return nil, "build: " .. decl.name .. ": " .. (merge_err or "context merge conflict")
	end

	return { tag = "op", decl = decl, args = out_args, sort = decl.result, ctx = ctx, ground = ground }
end

-- ── Introspection ────────────────────────────────────────────────────────────

--: (t: Term) -> SortDecl
function M.sort_of(t) return t.sort end

--: (t: Term) -> boolean
function M.is_ground(t) return t.ground end

--: (t: Term) -> boolean
function M.is_closed(t) return next(t.ctx) == nil end

-- ── Structural equality ──────────────────────────────────────────────────────

--: (a: Term, b: Term) -> boolean
function M.equal(a, b)
	if a == b then return true end
	if a.tag ~= b.tag then return false end
	if a.tag == "var" then
		if b.tag ~= "var" then return false end
		return a.index == b.index and a.sort == b.sort
	elseif a.tag == "meta" then
		if b.tag ~= "meta" then return false end
		return a.id == b.id and a.sort == b.sort
	else
		if b.tag ~= "op" then return false end
		if a.decl ~= b.decl then return false end
		for i, aa in ipairs(a.args) do
			if not M.equal(aa.term, b.args[i].term) then return false end
		end
		return true
	end
end

-- ── Shift ────────────────────────────────────────────────────────────────────

--: (t: Term, d: integer, cutoff: integer) -> (Term | nil, string | nil)
function M.shift(t, d, cutoff)
	if t.tag == "var" then
		if t.index < cutoff then return t end
		local new_index = t.index + d
		if new_index < 0 then return nil, "shift: index underflow" end
		return M.build_var(new_index, t.sort)
	elseif t.tag == "meta" then
		return t
	else
		local new_args = {} --[[: Term[] ]]
		for i, a in ipairs(t.args) do
			local shifted, err = M.shift(a.term, d, cutoff + a.bound_count)
			if not shifted then return nil, err end
			new_args[i] = shifted
		end
		return M.build(t.decl, new_args)
	end
end

-- ── Substitution ─────────────────────────────────────────────────────────────
--
-- subst(t, k, u): replace var(k) with u throughout t. Sort-safe: u's sort
-- must match the target var's declared sort (checked via t's own cached ctx
-- when possible — O(1) — else at the point of substitution). Capture-
-- avoiding by construction (Pierce TAPL 6.2.1): descending under a binder of
-- bound_count n bumps the target index by n and shifts u by n.

--: (t: Term, k: integer, u: Term) -> (Term | nil, string | nil)
function M.subst(t, k, u)
	if t.tag == "var" then
		if t.index ~= k then return t end
		if u.sort ~= t.sort then
			return nil, "subst: replacement sort " .. u.sort.name .. " does not match target sort " .. t.sort.name
		end
		return u
	elseif t.tag == "meta" then
		return t
	else
		-- Fast path: if k does not occur free in t, nothing changes — t.ctx
		-- is exactly the free-variable set, so this is a sound O(1) skip.
		if t.ctx[k] == nil then return t end
		local new_args = {} --[[: Term[] ]]
		for i, a in ipairs(t.args) do
			local shifted_u, serr = M.shift(u, a.bound_count, 0)
			if not shifted_u then return nil, serr end
			local sub, err = M.subst(a.term, k + a.bound_count, shifted_u)
			if not sub then return nil, err end
			new_args[i] = sub
		end
		return M.build(t.decl, new_args)
	end
end

-- ── Match ────────────────────────────────────────────────────────────────────
--
-- First-order, deterministic, no search. Non-linear patterns allowed: a
-- metavariable's first occurrence binds (recording the term found AND the
-- binder depth at which it was found); each later occurrence is checked via
-- `equal` against the first-bound term SHIFTED to the later occurrence's own
-- depth (ratified: "a binding stores (term, depth of first occurrence); a
-- later occurrence at depth d' is checked with equal(candidate, shift(stored,
-- d' - d))" — this keeps match and instantiate exact inverses; a candidate
-- referencing a binder strictly between the two depths fails the shift
-- (index underflow) and hence the match, which is the correct semantics: no
-- consistent binding exists).

--: (pattern: Term, term: Term, depth: integer, bindings: Bindings) -> (Bindings | nil, string | nil)
local function match_at(pattern, term, depth, bindings)
	if pattern.tag == "meta" then
		if term.sort ~= pattern.sort then
			return nil, "match: sort mismatch for metavariable " .. pattern.id
		end
		local existing = bindings[pattern.id]
		if not existing then
			bindings[pattern.id] = { term = term, depth = depth }
			return bindings
		end
		local expected, err = M.shift(existing.term, depth - existing.depth, 0)
		if not expected then
			return nil, "match: non-linear metavariable " .. pattern.id .. " conflict: " .. (err or "shift failed")
		end
		if not M.equal(expected, term) then
			return nil, "match: non-linear metavariable " .. pattern.id .. " conflict"
		end
		return bindings
	elseif pattern.tag == "var" then
		if term.tag ~= "var" or term.index ~= pattern.index or term.sort ~= pattern.sort then
			return nil, "match: structural mismatch (var)"
		end
		return bindings
	else -- op
		if term.tag ~= "op" or term.decl ~= pattern.decl then
			return nil, "match: structural mismatch (operator)"
		end
		for i, pa in ipairs(pattern.args) do
			local ok, err = match_at(pa.term, term.args[i].term, depth + pa.bound_count, bindings)
			if not ok then return nil, err end
		end
		return bindings
	end
end

--: (pattern: Term, term: Term) -> (Bindings | nil, string | nil)
function M.match(pattern, term)
	return match_at(pattern, term, 0, {})
end

-- ── Instantiate ──────────────────────────────────────────────────────────────
--
-- Replaces every metavariable in `pattern` with its binding, shifted from
-- the binding's recorded depth to the metavariable occurrence's own depth
-- (the exact inverse of match's non-linear shift-adjustment). Unbound
-- metavariable is an error.

--: (pattern: Term, bindings: Bindings, depth: integer) -> (Term | nil, string | nil)
local function instantiate_at(pattern, bindings, depth)
	if pattern.tag == "meta" then
		local b = bindings[pattern.id]
		if not b then return nil, "instantiate: unbound metavariable " .. pattern.id end
		local shifted, err = M.shift(b.term, depth - b.depth, 0)
		if not shifted then
			return nil, "instantiate: metavariable " .. pattern.id .. ": " .. (err or "shift failed")
		end
		if shifted.sort ~= pattern.sort then
			return nil, "instantiate: metavariable " .. pattern.id .. " sort mismatch (expected "
				.. pattern.sort.name .. ", got " .. shifted.sort.name .. ")"
		end
		return shifted
	elseif pattern.tag == "var" then
		return pattern
	else -- op
		local new_args = {} --[[: Term[] ]]
		for i, a in ipairs(pattern.args) do
			local sub, err = instantiate_at(a.term, bindings, depth + a.bound_count)
			if not sub then return nil, err end
			new_args[i] = sub
		end
		return M.build(pattern.decl, new_args)
	end
end

--: (pattern: Term, bindings: Bindings) -> (Term | nil, string | nil)
function M.instantiate(pattern, bindings)
	return instantiate_at(pattern, bindings, 0)
end

return M
