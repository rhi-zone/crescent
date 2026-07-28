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
-- MEASURED PERFORMANCE CAVEAT (docs/perf/log.md, 2026-07-28, revised same
-- day after a design-level review + replay-shaped benchmarks): computing
-- ctx/ground at thunk-construction time means `mk_subst` forces its `base`
-- one level at EVERY call, UNCONDITIONALLY — independent of whether any
-- caller ever inspects the result. For a SINGLE substitution this is cheap
-- and the fast tier wins clearly (benchmarked, ~7-8x). For a workload that
-- CHAINS many substitutions on a term shaped like `var(i)` sitting `i`
-- levels deep (so the "index provably absent" short-circuit never fires),
-- this per-call forcing compounds across the chain and measurably LOSES to
-- the reference tier — confirmed to be ~9-12x slower at 50 chained steps
-- REGARDLESS of whether the caller ever inspects an intermediate result
-- (a "compose N substitutions, then do ONE small rule-sized match" bench
-- loses by essentially the same margin as "compose N, then fully force" —
-- see docs/perf/log.md's 2026-07-28 replay-shaped-benchmarks entry). This
-- is NOT the "lazy subst helps chains" premise failing on an adversarial,
-- never-occurring access pattern — chaining several substitutions before
-- using the result is a plausible workload, not a strawman. What DOES
-- strongly validate the design (same entry, 33-46x fast-tier win,
-- consistent across repeated runs): the workload the ratified replay hot
-- path actually predicts dominates — MANY INDEPENDENT small `match`-then-
-- `instantiate` rule applications, never chaining substitutions on one
-- growing term. The fast tier's justification is therefore workload-
-- dependent, confirmed by measurement, not assumed: strong for
-- match/instantiate-heavy replay, weak for substitution-chaining. Closing
-- the chaining weakness would require allowing a thunk to wrap ANOTHER
-- unforced thunk (deferring collapse-to-Concrete across multiple composed
-- substitutions, not just one) instead of always storing a fully-forced
-- Concrete `.base` — a representation change, not an implementation
-- tweak; open design question recorded in TODO.md. Not a correctness gap
-- either way (parity fuzzing confirms identical results across all of
-- this).
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

--:: SortName = string
--:: SortDecl = { name: string, sig_name: string, sig_version: integer }
--:: Ctx = { [integer]: SortDecl }
--:: OpArgDecl = { sort: SortDecl, binds: SortDecl[], bound_count: integer }
--:: OpDecl = { name: string, sig_name: string, sig_version: integer, result: SortDecl, args: OpArgDecl[], arity: integer }
--:: OpArg = { bound_count: integer, term: Term }
--:: VarTerm = { tag: "var", index: integer, sort: SortDecl, ctx: Ctx, ground: boolean, iid: integer }
--:: MetaTerm = { tag: "meta", id: string, sort: SortDecl, ctx: Ctx, ground: boolean, iid: integer }
--:: OpTerm = { tag: "op", decl: OpDecl, args: OpArg[], sort: SortDecl, ctx: Ctx, ground: boolean, iid: integer }
--:: Concrete = VarTerm | MetaTerm | OpTerm
--:: ThunkTerm = { tag: "thunk", base: Term, k: integer, u: Term, sort: SortDecl, ctx: Ctx, ground: boolean, forced: Term | nil, iid: integer }
--:: Term = Concrete | ThunkTerm
--:: Binding = { term: Term, depth: integer }
--:: Bindings = { [string]: Binding }

--:: Instance = {
--::   build_var: (index: integer, sort: SortDecl) -> (VarTerm | nil, string | nil),
--::   build_meta: (id: string, sort: SortDecl) -> (MetaTerm | nil, string | nil),
--::   build: (decl: OpDecl, args: Term[]) -> (OpTerm | nil, string | nil),
--::   sort_of: (t: Term) -> SortDecl,
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

	-- Per-instance monotonic node id, assigned once at construction to every
	-- var/meta/op/thunk node built through this Inst. Exists ONLY so
	-- `mk_op`'s intern key (below) can reference a child by a cheap integer
	-- instead of `tostring(child)` (a pointer-format string built fresh on
	-- every call) — see the PERFORMANCE NOTE on `mk_op` and TODO.md's
	-- chained-subst perf follow-up. Not observable outside this file: no
	-- public accessor exposes `iid`, and it plays no role in equality,
	-- sorting, or context bookkeeping.
	local next_iid = 0
	--: () -> integer
	local function fresh_iid()
		next_iid = next_iid + 1
		return next_iid
	end

	-- Per-decl id, assigned the first time this Inst sees a given decl
	-- OBJECT (table identity as the key — Lua tables hash/compare by
	-- reference, which is exactly the "operator identity = declared-object
	-- identity" invariant shared.lua's `declare_signature` establishes: two
	-- signatures declaring the same-named op at the same version produce
	-- two DIFFERENT decl tables and must intern as different operators).
	-- Deliberately NOT `decl.sig_name/.sig_version/.name` — those are
	-- content, not identity, and using them as the key collapsed two
	-- distinct decls into one op_intern bucket (caught by
	-- term_algebra_test.lua's "different signatures are different
	-- operators" case). This table is the fix: identity-keyed, still O(1)
	-- table lookup, still avoids `tostring(decl)`'s per-call pointer
	-- formatting (paid once per decl instead of once per mk_op call).
	local decl_iid = {} --[[: { [unknown]: integer } ]]
	--: (decl: OpDecl) -> integer
	local function decl_id(decl)
		local existing = decl_iid[decl --[[: unknown ]]] --[[: integer | nil ]]
		if existing then return existing end
		local fresh = fresh_iid()
		decl_iid[decl] = fresh
		return fresh
	end

	-- Per-sort-object id, exactly the same identity-keyed pattern as decl_id
	-- above (table identity as the key), applied to SortDecl objects instead
	-- of OpDecl objects. NOT content-derived (sig_name/sig_version/name would
	-- collapse two independently-declared same-named sorts into one
	-- var_intern/meta_intern bucket, silently reintroducing the exact string-
	-- comparison-by-a-different-route bug sort identity-by-declaration
	-- exists to close) and NOT `tostring(sort)` (pointer-format string built
	-- fresh per call — the same measured cost decl_id's own header note
	-- already flags for decls).
	local sort_iid = {} --[[: { [unknown]: integer } ]]
	--: (sort: SortDecl) -> integer
	local function sort_id(sort)
		local existing = sort_iid[sort --[[: unknown ]]] --[[: integer | nil ]]
		if existing then return existing end
		local fresh = fresh_iid()
		sort_iid[sort] = fresh
		return fresh
	end

	local Inst = {}

	--: (index: integer, sort: SortDecl) -> (VarTerm | nil, string | nil)
	function Inst.build_var(index, sort)
		if type(index) ~= "number" then return nil, "build_var: index must be a non-negative integer" end
		if index < 0 then return nil, "build_var: index must be a non-negative integer" end
		local idx = math.floor(index)
		if idx ~= index then return nil, "build_var: index must be a non-negative integer" end
		if not shared.is_sort_decl(sort) then return nil, "build_var: sort must be a declared sort object" end
		local key = "v:" .. idx .. ":" .. sort_id(sort)
		local existing = var_intern[key]
		if existing then return existing end
		local node = { tag = "var", index = idx, sort = sort, ctx = { [idx] = sort }, ground = true, iid = fresh_iid() } --[[: VarTerm ]]
		var_intern[key] = node
		return node
	end

	--: (id: string, sort: SortDecl) -> (MetaTerm | nil, string | nil)
	function Inst.build_meta(id, sort)
		if type(id) ~= "string" then return nil, "build_meta: id must be a string" end
		if not shared.is_sort_decl(sort) then return nil, "build_meta: sort must be a declared sort object" end
		local key = "m:" .. id .. ":" .. sort_id(sort)
		local existing = meta_intern[key]
		if existing then return existing end
		local node = { tag = "meta", id = id, sort = sort, ctx = {}, ground = false, iid = fresh_iid() } --[[: MetaTerm ]]
		meta_intern[key] = node
		return node
	end

	-- Internal, trusted op constructor: no re-validation (callers of this
	-- local already validated sorts/contexts, or are reconstructing a term
	-- that was already valid before substitution/shift — both provably
	-- sort/context-preserving), but ctx/ground/interning still computed.
	--
	-- PERFORMANCE NOTE (docs/perf/log.md, 2026-07-28 chained-subst
	-- follow-up): the intern key used to be `"o:" .. tostring(decl) .. ":"
	-- .. tostring(child)` per argument — `tostring()` on a table formats a
	-- pointer string on every call, a real per-node cost that dominates on
	-- a long chain of interleaved subst+inspect (each step forces and
	-- reconstructs through `mk_op`). Replaced with `decl_id(decl)` (an
	-- identity-keyed per-decl id, see above — NOT content-derived, so the
	-- "two signatures declaring the same-named op are different operators"
	-- invariant still holds) and each child's own `iid` (assigned once at
	-- construction, above) instead of `tostring(a.term)`. Same key SPACE,
	-- just built from cheap integers instead of formatting pointers.
	--: (decl: OpDecl, args: OpArg[]) -> (OpTerm | nil, string | nil)
	local function mk_op(decl, args)
		local child_ctxs = {} --[[: Ctx[] ]]
		local ground = true
		local key = "o:" .. decl_id(decl)
		for i = 1, decl.arity do
			local a = args[i]
			local outer_ctx, err = shared.discharge_arg_ctx(a.term.ctx, decl.args[i].binds)
			if not outer_ctx then return nil, err end
			child_ctxs[i] = outer_ctx
			if not a.term.ground then ground = false end
			key = key .. ":" .. a.term.iid
		end
		local ctx, merge_err = shared.merge_ctxs(child_ctxs)
		if not ctx then return nil, merge_err end
		local existing = op_intern[key]
		if existing then return existing end
		local node = { tag = "op", decl = decl, args = args, sort = decl.result, ctx = ctx, ground = ground, iid = fresh_iid() }
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
				return nil, "build: " .. decl.name .. " arg " .. i .. " expected sort " .. decl.args[i].sort.name
					.. ", got " .. term.sort.name
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
				return nil, "subst: replacement sort " .. u.sort.name .. " does not match target sort " .. base.sort.name
			end
			return u
		end
		-- op
		local expected = base.ctx[k]
		if expected == nil then return base end
		if u.sort ~= expected then
			return nil, "subst: replacement sort " .. u.sort.name .. " does not match target sort " .. expected.name
		end
		local new_ctx = ctx_after_subst(base, k, u.ctx)
		return {
			tag = "thunk", base = base, k = k, u = u, sort = base.sort,
			ctx = new_ctx, ground = base.ground and u.ground, forced = nil, iid = fresh_iid(),
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
				-- PERFORMANCE NOTE (docs/perf/log.md, 2026-07-28
				-- chained-subst follow-up): when this argument has no
				-- binders (bound_count == 0), `Inst.shift(u, 0, 0)` would
				-- — per its own documented full-forcing contract — force
				-- `u` and rebuild it structurally through
				-- `mk_op`/interning, only to produce something
				-- structurally identical to `u` (shift by 0 is always the
				-- identity — see the REJECTED OPTIMIZATION note on
				-- `Inst.shift` itself for why that fact can't be used to
				-- change shift's own public behavior). Here, at THIS call
				-- site, bound_count is already known statically, so the
				-- no-op case is skipped directly — `Inst.shift`'s public
				-- contract (and every other caller's view of it) is
				-- completely unchanged; this only avoids a redundant call
				-- this one caller can prove in advance is unnecessary.
				local shifted_u = u
				if a.bound_count ~= 0 then
					local su, serr = Inst.shift(u, a.bound_count, 0)
					if not su then error("force: " .. (serr or "shift failed"), 0) end
					shifted_u = su
				end
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

	--: (t: Term) -> SortDecl
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
		-- REJECTED OPTIMIZATION (docs/perf/log.md, 2026-07-28 chained-subst
		-- follow-up): shift by 0 is mathematically the identity for every
		-- cutoff, and a `if d == 0 then return t end` short-circuit here
		-- (skipping force_head entirely) was tried and measured — see the
		-- perf log for the commit hash. Rejected: it silently changes
		-- `shift`'s OBSERVABLE contract. This module's own header
		-- documents "`shift` is NOT lazy... it forces a thunk fully, then
		-- shifts structurally"; term_algebra_parity_test.lua's
		-- `make_forcer` relies on exactly that ("shift by 0 at cutoff 0
		-- always forces-and-rebuilds structurally in both tiers") as the
		-- ratified-primitive-only way to force a possibly-unforced fast-
		-- tier term to Concrete for comparison. A `d == 0` shortcut that
		-- returns `t` unforced breaks that immediately (confirmed: parity
		-- fuzz crashed with "unrecognized term tag: thunk" the moment a
		-- forced-via-shift(_,0,0) result was fed to a Concrete-only
		-- walker). Not an implementation-level tweak — it would require
		-- ratifying "shift may return an unforced term" as new fast-tier
		-- semantics and updating every caller (in and out of this
		-- cleanroom boundary) that currently relies on shift-forces-fully.
		-- Left un-shortcut; see the module header's caveat and TODO.md for
		-- where this was reported instead of forced through.
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
			-- PERFORMANCE NOTE (docs/perf/log.md, 2026-07-28 replay-shaped
			-- follow-up): the ratified spec (typechecker-v10-core-design.md)
			-- requires `equal(candidate, shift(stored, d'-d))` here — but
			-- when `d' == d` (the common case: a non-linear metavariable's
			-- second occurrence at the SAME binder depth as its first),
			-- `shift(t, 0, 0)` is the identity, and calling it anyway pays
			-- `Inst.shift`'s full force-and-rebuild-through-`Inst.build`
			-- cost (see the REJECTED OPTIMIZATION note on `Inst.shift`
			-- itself for why that cost can't be removed from `shift`'s own
			-- contract). Skipped here at the call site instead, exactly
			-- the same caller-side pattern already used in `force_head`:
			-- `Inst.shift`'s public behavior is untouched, and
			-- `Inst.equal` below already forces whatever it's given as
			-- needed, so passing the unshifted (possibly still-unforced)
			-- `existing.term` through when the offset is provably 0 is
			-- observably identical, just without the redundant rebuild.
			local expected = existing.term
			if depth ~= existing.depth then
				local shifted, err = Inst.shift(existing.term, depth - existing.depth, 0)
				if not shifted then
					return nil, "match: non-linear metavariable " .. p.id .. " conflict: " .. (err or "shift failed")
				end
				expected = shifted
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
			-- PERFORMANCE NOTE (docs/perf/log.md, 2026-07-28 replay-shaped
			-- follow-up): same call-site skip as `match_at`'s non-linear
			-- check, above — pasting a metavariable's binding at the SAME
			-- depth it was captured (`depth == b.depth`) is the common
			-- case for a great many rule applications, and `shift(t,0,0)`
			-- is the identity, so the call (and its full
			-- force-and-rebuild-through-`Inst.build` cost) is skipped
			-- here rather than paid unconditionally. `Inst.shift`'s own
			-- contract is untouched; `b.term` may be passed through
			-- unforced (its `.sort` is O(1)-cached regardless, and every
			-- downstream consumer — `Inst.build`'s validation, `mk_op`'s
			-- ctx/ground reads — already handles unforced thunk args
			-- correctly, the same invariant `force_head`'s own
			-- reconstruction already relies on).
			local shifted = b.term
			if depth ~= b.depth then
				local su, serr = Inst.shift(b.term, depth - b.depth, 0)
				if not su then
					return nil, "instantiate: metavariable " .. p.id .. ": " .. (serr or "shift failed")
				end
				shifted = su
			end
			if shifted.sort ~= p.sort then
				return nil, "instantiate: metavariable " .. p.id .. " sort mismatch (expected "
					.. p.sort.name .. ", got " .. shifted.sort.name .. ")"
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
