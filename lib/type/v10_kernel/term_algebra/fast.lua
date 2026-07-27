-- lib/type/v10_kernel/term_algebra/fast.lua
--
-- Fast tier of the v10 kernel term algebra: an optimization claim over
-- reference.lua, checked against it by parity tests and parity fuzzing
-- (term_algebra_parity_test.lua), never trusted on its own — per
-- docs/decisions/typechecker-v10-core-design.md, each fast-tier primitive's
-- soundness is a named, versioned registry axiom, assumed until proven:
--
--   kernel-interner-sound-v1     — hash-consed interning + pointer equality
--   kernel-lazy-subst-sound-v1   — explicit/lazy substitution
--
-- ── Interning (kernel-interner-sound-v1) ────────────────────────────────────
-- Every concrete node (var/meta/op) built through one `M.new()` instance is
-- hash-consed: a structural key maps to a canonical table, so two
-- structurally-equal concrete terms ARE the same Lua table. `equal` on two
-- concrete terms is therefore `a == b` (O(1)) in the common case. The key
-- for an op node is built from its *children's already-canonical identity*
-- (tostring of each already-interned child), not a full structural
-- serialization — O(arity) per node, not O(subtree size).
--
-- ── Lazy substitution (kernel-lazy-subst-sound-v1) ──────────────────────────
-- `subst` does NOT eagerly rebuild the substituted term. It returns
-- immediately (O(1), or O(1) plus a cached-context lookup): a concrete
-- var/meta node resolves or no-ops immediately (no work to defer); a
-- concrete op node either short-circuits (target index provably absent,
-- via its cached context — an O(1) exact check) or wraps in a `thunk` node
-- recording the deferred substitution; a thunk base defers unconditionally
-- (its context isn't known without forcing). Work happens on demand via
-- `force_head`, one constructor level at a time, memoized on the thunk node
-- so repeated forcing is O(1) after the first — the standard technique
-- (cf. explicit substitution calculi, e.g. Abadi et al.'s lambda-sigma):
-- match/equal/instantiate only force the parts of a term they actually
-- inspect, never the whole tree.
--
-- Two honest, documented complexity-profile consequences of laziness (NOT
-- semantics differences — parity holds exactly once both sides are fully
-- forced, which is what the parity tests do):
--   * `sort_of` stays truly O(1) even on an unforced thunk (substitution
--     never changes a term's own top-level sort — `thunk.sort` is copied
--     directly from its base at construction, no forcing needed).
--   * `is_ground`/`is_closed` are NOT O(1) on an unforced thunk: reading a
--     whole-term property that depends on potentially-unforced parts
--     necessarily requires looking at those parts, so both fully force
--     (`force_deep`) before answering. This is a deliberate, narrow scope
--     choice (is_ground/is_closed have no O(1) requirement in the ratified
--     primitive spec the way sort_of does) rather than a semantics gap.
--   * A sort mismatch inside a substitution that was never eagerly checked
--     (the rare case: substituting into an unforced thunk *base*, where the
--     base's context isn't known) surfaces as a thrown error at force time
--     rather than as `(nil, errmsg)` at the original `subst` call — later,
--     but never silently wrong. The common case (substituting into an
--     already-concrete term) is checked eagerly via the cached context,
--     exactly like the reference tier.
--
-- `shift` is NOT lazy (the ratified axiom is specifically named for subst,
-- not shift): it forces a thunk fully, then shifts structurally like the
-- reference tier, still through this instance's interning.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local shared = require("lib.type.v10_kernel.term_algebra.shared")

local M = {}

--:: Sort = string
--:: Ctx = { [integer]: Sort }
--:: OpArgDecl = { sort: Sort, binds: Sort[], bound_count: integer }
--:: OpDecl = { name: string, sig_name: string, sig_version: integer, result: Sort, args: OpArgDecl[], arity: integer }
--:: OpArg = { bound_count: integer, term: Term }
--:: VarTerm = { tag: "var", index: integer, sort: Sort, ctx: Ctx, ground: boolean }
--:: MetaTerm = { tag: "meta", id: string, sort: Sort, ctx: Ctx, ground: boolean }
--:: OpTerm = { tag: "op", decl: OpDecl, args: OpArg[], sort: Sort, ctx: Ctx, ground: boolean }
--:: Concrete = VarTerm | MetaTerm | OpTerm
--:: ThunkTerm = { tag: "thunk", base: Term, k: integer, u: Term, sort: Sort, forced: Term | nil }
--:: Term = Concrete | ThunkTerm
--:: Binding = { term: Term, depth: integer }
--:: Bindings = { [string]: Binding }

--:: Instance = {
--::   build_var: (index: integer, sort: Sort) -> (VarTerm | nil, string | nil),
--::   build_meta: (id: string, sort: Sort) -> (MetaTerm | nil, string | nil),
--::   build: (decl: OpDecl, args: Term[]) -> (OpTerm | nil, string | nil),
--::   sort_of: (t: Term) -> Sort,
--::   is_ground: (t: Term) -> boolean,
--::   is_closed: (t: Term) -> boolean,
--::   equal: (a: Term, b: Term) -> boolean,
--::   shift: (t: Term, d: integer, cutoff: integer) -> (Term | nil, string | nil),
--::   subst: (t: Term, k: integer, u: Term) -> (Term | nil, string | nil),
--::   match: (pattern: Term, term: Term) -> (Bindings | nil, string | nil),
--::   instantiate: (pattern: Term, bindings: Bindings) -> (Term | nil, string | nil),
--:: }

--: () -> Instance
function M.new()
	local var_intern = {} --[[: { [string]: VarTerm } ]]
	local meta_intern = {} --[[: { [string]: MetaTerm } ]]
	local op_intern = {} --[[: { [string]: OpTerm } ]]

	local Inst = {}

	--: (index: integer, sort: Sort) -> (VarTerm | nil, string | nil)
	function Inst.build_var(index, sort)
		if type(index) ~= "number" then return nil, "build_var: index must be a non-negative integer" end
		if index < 0 then return nil, "build_var: index must be a non-negative integer" end
		local idx = math.floor(index)
		if idx ~= index then return nil, "build_var: index must be a non-negative integer" end
		if type(sort) ~= "string" then return nil, "build_var: sort must be a string" end
		local key = "v:" .. idx .. ":" .. sort
		local existing = var_intern[key]
		if existing then return existing end
		local node = { tag = "var", index = idx, sort = sort, ctx = { [idx] = sort }, ground = true } --[[: VarTerm ]]
		var_intern[key] = node
		return node
	end

	--: (id: string, sort: Sort) -> (MetaTerm | nil, string | nil)
	function Inst.build_meta(id, sort)
		if type(id) ~= "string" then return nil, "build_meta: id must be a string" end
		if type(sort) ~= "string" then return nil, "build_meta: sort must be a string" end
		local key = "m:" .. id .. ":" .. sort
		local existing = meta_intern[key]
		if existing then return existing end
		local node = { tag = "meta", id = id, sort = sort, ctx = {}, ground = false } --[[: MetaTerm ]]
		meta_intern[key] = node
		return node
	end

	-- Internal, trusted op constructor: no re-validation (callers of this
	-- local already validated sorts/contexts, or are reconstructing a term
	-- that was already valid before substitution/shift — both provably
	-- sort/context-preserving), but ctx/ground/interning still computed.
	--: (decl: OpDecl, args: OpArg[]) -> (OpTerm | nil, string | nil)
	local function mk_op(decl, args)
		local child_ctxs = {} --[[: Ctx[] ]]
		local ground = true
		local key = "o:" .. tostring(decl)
		for i = 1, decl.arity do
			local a = args[i]
			local outer_ctx, err = shared.discharge_arg_ctx(a.term.ctx, decl.args[i].binds)
			if not outer_ctx then return nil, err end
			child_ctxs[i] = outer_ctx
			if not a.term.ground then ground = false end
			key = key .. ":" .. tostring(a.term)
		end
		local ctx, merge_err = shared.merge_ctxs(child_ctxs)
		if not ctx then return nil, merge_err end
		local existing = op_intern[key]
		if existing then return existing end
		local node = { tag = "op", decl = decl, args = args, sort = decl.result, ctx = ctx, ground = ground }
		op_intern[key] = node
		return node
	end

	--: (decl: OpDecl, args: Term[]) -> (OpTerm | nil, string | nil)
	function Inst.build(decl, args)
		if #args ~= decl.arity then
			return nil, "build: " .. decl.name .. " expects " .. decl.arity .. " args, got " .. #args
		end
		local out_args = {} --[[: OpArg[] ]]
		for i = 1, decl.arity do
			local term = args[i]
			if term.sort ~= decl.args[i].sort then
				return nil, "build: " .. decl.name .. " arg " .. i .. " expected sort " .. decl.args[i].sort
					.. ", got " .. term.sort
			end
			out_args[i] = { bound_count = decl.args[i].bound_count, term = term }
		end
		local node, err = mk_op(decl, out_args)
		if not node then return nil, "build: " .. decl.name .. ": " .. (err or "sort mismatch under binder") end
		return node
	end

	-- ── Forcing ────────────────────────────────────────────────────────────
	--
	-- Build a (possibly deferred) substitution node. See module header:
	-- eager sort-check + short-circuit whenever the base is concrete (its
	-- context is exact), deferred (wrapped in a thunk) otherwise. Defined
	-- before force_head (which calls it) — mk_subst itself never forces, so
	-- there is no actual mutual recursion needing a forward declaration.
	--: (base: Term, k: integer, u: Term) -> (Term | nil, string | nil)
	local function mk_subst(base, k, u)
		if base.tag == "meta" then return base end
		if base.tag == "var" then
			if base.index ~= k then return base end
			if u.sort ~= base.sort then
				return nil, "subst: replacement sort " .. u.sort .. " does not match target sort " .. base.sort
			end
			return u
		end
		if base.tag == "op" then
			local expected = base.ctx[k]
			if expected == nil then return base end
			if u.sort ~= expected then
				return nil, "subst: replacement sort " .. u.sort .. " does not match target sort " .. expected
			end
		end
		return { tag = "thunk", base = base, k = k, u = u, sort = base.sort, forced = nil }
	end

	-- TYPECHECKER WORKAROUND: `force_head`'s self-recursive calls
	-- (`force_head(t.base)`, `force_head(u)`, `force_head(t.forced)`) lose
	-- their declared `Concrete` return type when the result is assigned to
	-- a local and then tag-narrowed, specifically when combined with the
	-- negated `if t.tag ~= "thunk" then return t end` guard above —
	-- confirmed via minimal repro (a 3-concrete-variant recursive tagged
	-- union, same shape as here): the assigned local's type falls back to
	-- `any` and every subsequent `.tag` narrowing on it also falls back to
	-- `any`, in turn making `.tag`-guarded return arms reject `nil` return
	-- values. A checked cast restating the function's own already-declared
	-- return type (`--[[: Concrete]]`, not a force cast) fixes it. See
	-- TODO.md. Revert the casts below once self-recursive return-type
	-- narrowing is fixed.
	--: (t: Term) -> Concrete
	local function force_head(t)
		if t.tag ~= "thunk" then return t end
		if t.forced then return force_head(t.forced) end
		local base = force_head(t.base) --[[: Concrete]]
		local k, u = t.k, t.u
		if base.tag == "var" then
			if base.index == k then
				assert(u.sort == base.sort, "subst: replacement sort does not match target sort")
				local result = force_head(u) --[[: Concrete]]
				t.forced = result
				return result
			else
				t.forced = base
				return base
			end
		elseif base.tag == "meta" then
			t.forced = base
			return base
		else
			local new_args = {} --[[: OpArg[] ]]
			for i, a in ipairs(base.args) do
				local shifted_u, serr = Inst.shift(u, a.bound_count, 0)
				if not shifted_u then error("force: " .. (serr or "shift failed"), 0) end
				local child, cerr = mk_subst(a.term, k + a.bound_count, shifted_u)
				if not child then error("force: " .. (cerr or "subst failed"), 0) end
				new_args[i] = { bound_count = a.bound_count, term = child }
			end
			local node, merr = mk_op(base.decl, new_args)
			if not node then error("force: " .. (merr or "build failed"), 0) end
			t.forced = node
			return node
		end
	end

	--: (t: Term) -> Concrete
	local function force_deep(t)
		local h = force_head(t)
		if h.tag == "op" then
			for _, a in ipairs(h.args) do force_deep(a.term) end
		end
		return h
	end

	-- ── Introspection ────────────────────────────────────────────────────────

	--: (t: Term) -> Sort
	function Inst.sort_of(t) return t.sort end

	--: (t: Term) -> boolean
	function Inst.is_ground(t) return force_deep(t).ground end

	--: (t: Term) -> boolean
	function Inst.is_closed(t) return next(force_deep(t).ctx) == nil end

	-- ── Equality ─────────────────────────────────────────────────────────────
	-- Pointer-eq first (the common case, O(1) for fully-forced/concrete
	-- terms thanks to interning); falls back to forcing + structural
	-- comparison only when the fast path doesn't immediately resolve it
	-- (unforced thunks on one or both sides).

	--: (a: Term, b: Term) -> boolean
	function Inst.equal(a, b)
		if a == b then return true end
		local fa = force_head(a)
		local fb = force_head(b)
		if fa == fb then return true end
		if fa.tag ~= fb.tag then return false end
		if fa.tag == "var" then
			if fb.tag ~= "var" then return false end
			return fa.index == fb.index and fa.sort == fb.sort
		elseif fa.tag == "meta" then
			if fb.tag ~= "meta" then return false end
			return fa.id == fb.id and fa.sort == fb.sort
		else
			if fb.tag ~= "op" then return false end
			if fa.decl ~= fb.decl then return false end
			for i, aa in ipairs(fa.args) do
				if not Inst.equal(aa.term, fb.args[i].term) then return false end
			end
			return true
		end
	end

	-- ── Shift (not lazy — see module header) ────────────────────────────────

	--: (t: Term, d: integer, cutoff: integer) -> (Term | nil, string | nil)
	function Inst.shift(t, d, cutoff)
		local h = force_head(t)
		if h.tag == "var" then
			if h.index < cutoff then return h end
			local new_index = h.index + d
			if new_index < 0 then return nil, "shift: index underflow" end
			return Inst.build_var(new_index, h.sort)
		elseif h.tag == "meta" then
			return h
		else
			local new_args = {} --[[: Term[] ]]
			for i, a in ipairs(h.args) do
				local shifted, err = Inst.shift(a.term, d, cutoff + a.bound_count)
				if not shifted then return nil, err end
				new_args[i] = shifted
			end
			return Inst.build(h.decl, new_args)
		end
	end

	-- ── Substitution (lazy — see module header) ─────────────────────────────

	--: (t: Term, k: integer, u: Term) -> (Term | nil, string | nil)
	function Inst.subst(t, k, u)
		return mk_subst(t, k, u)
	end

	-- ── Match ────────────────────────────────────────────────────────────────

	--: (pattern: Term, term: Term, depth: integer, bindings: Bindings) -> (Bindings | nil, string | nil)
	local function match_at(pattern, term, depth, bindings)
		local p = force_head(pattern)
		if p.tag == "meta" then
			local ft = force_head(term)
			if ft.sort ~= p.sort then
				return nil, "match: sort mismatch for metavariable " .. p.id
			end
			local existing = bindings[p.id]
			if not existing then
				bindings[p.id] = { term = ft, depth = depth }
				return bindings
			end
			local expected, err = Inst.shift(existing.term, depth - existing.depth, 0)
			if not expected then
				return nil, "match: non-linear metavariable " .. p.id .. " conflict: " .. (err or "shift failed")
			end
			if not Inst.equal(expected, ft) then
				return nil, "match: non-linear metavariable " .. p.id .. " conflict"
			end
			return bindings
		elseif p.tag == "var" then
			local ft = force_head(term)
			if ft.tag ~= "var" or ft.index ~= p.index or ft.sort ~= p.sort then
				return nil, "match: structural mismatch (var)"
			end
			return bindings
		else -- op
			local ft = force_head(term)
			if ft.tag ~= "op" or ft.decl ~= p.decl then
				return nil, "match: structural mismatch (operator)"
			end
			for i, pa in ipairs(p.args) do
				local ok, err = match_at(pa.term, ft.args[i].term, depth + pa.bound_count, bindings)
				if not ok then return nil, err end
			end
			return bindings
		end
	end

	--: (pattern: Term, term: Term) -> (Bindings | nil, string | nil)
	function Inst.match(pattern, term)
		return match_at(pattern, term, 0, {})
	end

	-- ── Instantiate ──────────────────────────────────────────────────────────

	--: (pattern: Term, bindings: Bindings, depth: integer) -> (Term | nil, string | nil)
	local function instantiate_at(pattern, bindings, depth)
		local p = force_head(pattern)
		if p.tag == "meta" then
			local b = bindings[p.id]
			if not b then return nil, "instantiate: unbound metavariable " .. p.id end
			local shifted, err = Inst.shift(b.term, depth - b.depth, 0)
			if not shifted then
				return nil, "instantiate: metavariable " .. p.id .. ": " .. (err or "shift failed")
			end
			if shifted.sort ~= p.sort then
				return nil, "instantiate: metavariable " .. p.id .. " sort mismatch"
			end
			return shifted
		elseif p.tag == "var" then
			return p
		else -- op
			local new_args = {} --[[: Term[] ]]
			for i, a in ipairs(p.args) do
				local sub, err = instantiate_at(a.term, bindings, depth + a.bound_count)
				if not sub then return nil, err end
				new_args[i] = sub
			end
			return Inst.build(p.decl, new_args)
		end
	end

	--: (pattern: Term, bindings: Bindings) -> (Term | nil, string | nil)
	function Inst.instantiate(pattern, bindings)
		return instantiate_at(pattern, bindings, 0)
	end

	return Inst
end

return M
