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
-- `subst` does NOT eagerly rebuild the substituted TERM. `mk_subst` forces
-- its `base` argument one level (so it always has a concrete node's exact
-- cached fields to read) and then: a var/meta base resolves or no-ops
-- immediately; an op base either short-circuits (target index provably
-- absent via the cached context — O(1)) or wraps in a `thunk` node
-- recording the deferred substitution. Building that thunk still computes
-- its sort/ctx/ground eagerly (see below) — genuinely deferred is only the
-- NODE GRAPH itself (no new op/var/meta nodes are built or interned until
-- something forces them). Work happens on demand via `force_head`, one
-- constructor level at a time, memoized on the thunk node so repeated
-- forcing is O(1) after the first — the standard technique (cf. explicit
-- substitution calculi, e.g. Abadi et al.'s lambda-sigma): match/equal/
-- instantiate only force the parts of a term they actually inspect, never
-- the whole tree.
--
-- Every thunk carries an exact sort/ctx/ground, computed at construction,
-- so `sort_of`/`is_ground`/`is_closed` are true O(1) even on an unforced
-- term (no semantics difference from the reference tier — these are the
-- same values the fully-forced term would report):
--   * `sort` is subst-invariant — copied directly from `base`, O(1).
--   * `ctx` is computed by `ctx_after_subst`, a dedicated recursion that
--     mirrors `subst`'s own structural walk but threads only context maps
--     (no node construction/interning) — genuinely lazy where it matters:
--     it short-circuits and skips any subtree that doesn't reference the
--     substituted index, exactly like the reference tier's own subst, and
--     only forces (one level at a time) the nodes actually on the "spine"
--     containing real occurrences.
--   * `ground` is an exact O(1) formula: `base.ground and u.ground` — valid
--     specifically because this is the "index occurs" branch (the only one
--     that reaches thunk construction): base.ground already excludes a
--     meta anywhere in base other than at the substituted position, so the
--     result contains a meta iff u does.
--   (Found via parity fuzzing, not by inspection: an earlier version of
--   this file gave thunks no ctx/ground at all, which crashed the moment
--   `force_head`'s own op-branch reconstruction — or a caller passing an
--   unforced term straight into `Inst.build` — handed a thunk to `mk_op`,
--   which unconditionally reads `a.term.ctx`/`a.term.ground` to validate
--   and merge. Fixed properly rather than special-cased around.)
--
-- MEASURED PERFORMANCE CAVEAT (docs/perf/log.md, 2026-07-28): computing
-- ctx/ground at thunk-construction time means `mk_subst` forces its `base`
-- one level at EVERY call — for a single substitution this is cheap and the
-- fast tier wins clearly (benchmarked), but for a CHAIN of substitutions
-- interleaved with re-inspection (each step's `base.ctx[k]` lookup requires
-- the previous step's thunk to already be forced), the per-node interning
-- overhead paid at every one of those forced steps compounds and measurably
-- LOSES to the reference tier (10x slower at 50 chained steps) — the
-- opposite of what a naive "lazy subst helps chains" reading of this file
-- would predict. Not a correctness gap (parity fuzzing confirms identical
-- results); a genuine, measured performance characteristic of the current
-- design, with candidate follow-ups recorded in TODO.md.
--
-- A sort mismatch inside a substitution that was never eagerly checked
-- (the rare case: substituting into an unforced thunk *base*, where forcing
-- one level to check might itself force further than a caller expects)
-- surfaces as a thrown error at force time rather than as `(nil, errmsg)`
-- at the original `subst` call — later, but never silently wrong. The
-- common case (substituting into an already-concrete term) is checked
-- eagerly via the cached context, exactly like the reference tier.
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
--:: ThunkTerm = { tag: "thunk", base: Term, k: integer, u: Term, sort: Sort, ctx: Ctx, ground: boolean, forced: Term | nil }
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
	-- mk_subst, force_head, and ctx_after_subst are mutually recursive:
	-- mk_subst forces its own `base` one level (so it always decides
	-- against a concrete node); force_head's op-branch reconstructs via
	-- mk_subst on each child; ctx_after_subst (see below) may need to force
	-- a child to compute an exact result. Pre-declared as locals so each
	-- can reference the others as upvalues.
	-- Not annotated here: an annotated `local x` with no initializer
	-- requires the type to admit `nil`, which would force every use of
	-- these three below to re-narrow away a spurious `| nil`. Left plain
	-- (matching the pre-declare-then-assign idiom in docs/lua-gotchas.md);
	-- each function's real signature is annotated at its assignment below.
	local mk_subst
	local force_head
	local ctx_after_subst

	--: (ctx: Ctx, d: integer) -> Ctx
	local function shift_ctx(ctx, d)
		local out = {} --[[: Ctx ]]
		for idx, s in pairs(ctx) do out[idx + d] = s end
		return out
	end

	-- Exact free-variable context of subst(t, k, u), computed WITHOUT
	-- materializing the substituted term (no new nodes, no interning) —
	-- mirrors reference.lua's subst recursion but only threads ctx maps.
	-- Precondition (established by every call site): k occurs in t (i.e.
	-- t's own ctx already reports it present) — this is only ever called
	-- on the branch of mk_subst/force_head that already checked that.
	-- Genuinely lazy where it matters: subtrees that don't reference k are
	-- never visited (the ctx short-circuit below skips them entirely, same
	-- as the reference tier's own subst); only the "spine" containing
	-- actual occurrences of k is walked, and forced one level at a time
	-- if a node on that spine happens to still be an unforced thunk.
	--: (t_in: Term, k: integer, u_ctx: Ctx) -> Ctx
	ctx_after_subst = function(t_in, k, u_ctx)
		local t = force_head(t_in)
		if t.tag == "var" then
			if t.index == k then return u_ctx end
			return t.ctx
		elseif t.tag == "meta" then
			return t.ctx
		else
			if t.ctx[k] == nil then return t.ctx end
			local merged = {} --[[: Ctx ]]
			for _, a in ipairs(t.args) do
				local sub = ctx_after_subst(a.term, k + a.bound_count, shift_ctx(u_ctx, a.bound_count))
				for idx, s in pairs(sub) do
					if idx >= a.bound_count then merged[idx - a.bound_count] = s end
				end
			end
			return merged
		end
	end

	-- Build a (possibly deferred) substitution node. Eager sort-check +
	-- short-circuit whenever the target index is provably absent (an O(1)
	-- exact check via the cached context — `base` is forced one level
	-- first specifically so this check, and the ctx/ground computation
	-- below, always have a concrete node's exact cached fields to read).
	-- When the index IS present, every field the thunk needs downstream
	-- (sort, ctx, ground) is computed now — sort is subst-invariant (O(1));
	-- ctx via ctx_after_subst (see above); ground via the exact O(1)
	-- formula base.ground AND u.ground (valid specifically because we are
	-- in the "k occurs" branch: a substitution introduces a meta into the
	-- result iff u itself has one, since base.ground already excludes any
	-- meta elsewhere in base). Only the substituted TERM (the full node
	-- graph) stays deferred, forced on demand by force_head.
	--: (base_in: Term, k: integer, u: Term) -> (Term | nil, string | nil)
	mk_subst = function(base_in, k, u)
		local base = force_head(base_in)
		if base.tag == "meta" then return base end
		if base.tag == "var" then
			if base.index ~= k then return base end
			if u.sort ~= base.sort then
				return nil, "subst: replacement sort " .. u.sort .. " does not match target sort " .. base.sort
			end
			return u
		end
		-- op
		local expected = base.ctx[k]
		if expected == nil then return base end
		if u.sort ~= expected then
			return nil, "subst: replacement sort " .. u.sort .. " does not match target sort " .. expected
		end
		local new_ctx = ctx_after_subst(base, k, u.ctx)
		return {
			tag = "thunk", base = base, k = k, u = u, sort = base.sort,
			ctx = new_ctx, ground = base.ground and u.ground, forced = nil,
		}
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
	force_head = function(t)
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

	-- ── Introspection ────────────────────────────────────────────────────────
	--
	-- All three are true O(1), including on an unforced thunk: sort is
	-- subst-invariant (copied at thunk construction); ctx and ground are
	-- computed exactly at thunk construction too (ctx_after_subst / the
	-- base.ground-and-u.ground formula in mk_subst above) — no forcing
	-- needed to answer either.

	--: (t: Term) -> Sort
	function Inst.sort_of(t) return t.sort end

	--: (t: Term) -> boolean
	function Inst.is_ground(t) return t.ground end

	--: (t: Term) -> boolean
	function Inst.is_closed(t) return next(t.ctx) == nil end

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
