-- lib/type/analysis/slice_subtype.lua
--
-- THE subtype relation for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §3).
--
-- A single pure, total, cycle-guarded coinductive function:
--
--   M.is_subtype(a, b)         -> boolean
--   M.subtype(a, b)            -> (boolean, Counterexample | nil)   [witness variant]
--
-- The kernel ratifies ONE subtype relation (kernel-recommendation.md §3.3);
-- this is it, restricted to the v1 fragment of the rewrite-design lattice:
-- primitives + `integer <: number`, literal singletons, structural records /
-- indexers / open-rows, functions (contravariant params, covariant multi-return
-- tuple + vararg spread), union, intersection, and equirecursive μ via the
-- hash-consed interner in `slice_ty.lua`.
--
-- Termination is by the cycle guard (§3.3): a single assumption stack of
-- tid-pairs. Reflexivity is `tid(A) == tid(B)` (interning); the coinductive
-- hypothesis returns `true` when a pair recurs. Because tids are finite and each
-- pair is pushed at most once per path, the relation is total — a non-terminating
-- query would be a soundness bug (CLAUDE.md timeout-30), never a slow case.
--
-- The deferral fence (kernel §3) holds: NO complement, match types, RDNF,
-- parametric polymorphism, HKT, or effects appear here. Every rule is exactly
-- the rewrite-design rule with the `~T` cases elided (§3.4).

local G = require("lib.type.analysis.slice_ty")

local M = {}

-- `Ty`, `Field`, `Params`, `Rows` are the grammar aliases declared in
-- slice_ty.lua and made visible here by requiring it (the same cross-module
-- alias visibility stlc_test relies on for `StTerm`). The module value is `G`,
-- so the `Ty` type name is free — and types flow into the `slice_ty` constructors
-- (`G.unfold`, `G.lit_str`, …) and out of `is_subtype` without nominal mismatch.
--:: Counterexample = { kind: string, a: Ty, b: Ty, detail?: string }

-- ── Field/member accessors (definite, force-cast-free) ───────────────────────

--: (Ty) -> Params
local function params_of(t) return t.params or ({ fixed = {} } --[[: Params ]]) end
--: (Ty) -> Params
local function ret_of(t) return t.ret or ({ fixed = {} } --[[: Params ]]) end
--: (Ty) -> Field[]
local function fields_of(t) return t.fields or {} end
--: (Ty) -> Ty[]
local function members_of(t) return t.members or {} end

-- Look up a field by key in a record's field list (sorted, but linear scan is
-- fine at v1 record widths).
--: (Field[], string) -> (Field | nil)
local function find_field(fields, key)
	for i = 1, #fields do
		if fields[i].key == key then return fields[i] end
	end
	return nil
end

-- ── The relation ─────────────────────────────────────────────────────────────

-- Cycle-guard stack: maps "tidA:tidB" -> true for pairs currently being decided.
-- Held in a closure-free module local reset at each top-level call so the
-- relation stays pure w.r.t. its arguments (no state leaks between calls).

-- subtype of A against B, given the assumption set `seen` (a cycle-guard stack
-- keyed on tid-pairs) and a per-query result `memo` (audit round 1, finding 4).
--
-- MEMOIZATION (finding 4): without it, rec/union/fn descent re-explores shared
-- interned subterms — O(2^n) on shared-subterm DAGs (`{a: child, b: child}`
-- chains), >120s at depth 30. The `seen` stack only covers μ-unfold pairs, so it
-- did not stop the blow-up. The `memo` caches the FINAL verdict of every fully
-- decided `(tidA, tidB)` pair; an interned tid-pair is a trivial, sound key
-- (structural identity ⇒ tid identity). Coinductive correctness is preserved: a
-- pair currently ON the `seen` stack is revisited via the coinductive-hypothesis
-- short-circuit (returns true) BEFORE reaching the decision/cache code, so a
-- provisional coinductive `true` is NEVER written to the memo. Only the outermost
-- computation of a pair — after its μ assumption is discharged consistently —
-- writes its definite verdict. Non-μ descents never touch `seen`, so caching
-- their shared-subterm results is unconditionally sound. The contravariant-
-- recursion / memo-poisoning tests guard this argument.
local sub --[[: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean ]]
local decide --[[: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean ]]

-- Memoizing wrapper: reflexivity, the coinductive-hypothesis short-circuit, then
-- the per-query memo, then `decide`. The verdict is cached after `decide` returns
-- (a definite, non-provisional result — see the header on finding 4).
--: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean
sub = function(a, b, seen, memo)
	-- (1) reflexivity by interning.
	if a.tid == b.tid then return true end

	-- (2) coinductive hypothesis: pair already on the assumption stack. (Must come
	-- before the memo lookup: an in-progress μ pair is provisionally true and must
	-- not be served — or cached — as a definite verdict.)
	local pair = a.tid .. ":" .. b.tid
	if seen[pair] then return true end

	-- (3) memoized definite verdict for this pair (this query). Sound because only
	-- fully-decided, non-provisional results are stored.
	local cached = memo[pair]
	if cached ~= nil then return cached end

	local r = decide(a, b, seen, memo) --: boolean
	memo[pair] = r
	return r
end

-- The structural decision per constructor pair (§3.2). Recurses via `sub` (which
-- memoizes). The μ branch pushes/pops the `(a,b)` pair on `seen` for the
-- coinductive hypothesis; that pair's verdict is cached by the wrapper after the
-- pop, never during a provisional revisit.
--: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean
decide = function(a, b, seen, memo)
	local pair = a.tid .. ":" .. b.tid
	local bk = b.kind
	local ak = a.kind

	-- ALWAYS-TRUE top/bottom laws (§3.2). These are sound regardless of A/B shape.
	if bk == "unknown" then return true end   -- B = unknown (top)
	if ak == "never"   then return true end   -- A = never (bottom)

	-- (μ unfold — push the pair, then decide on the unfolding. §3.2 / §3.3.)
	-- Done before the always-FALSE bottom/top laws because a μ may unfold to a
	-- bottom/empty type (e.g. `μX. never`): such a μ IS never, so `μX.never <: never`
	-- must reach the unfold, not be cut off by the `bk==never → false` shortcut.
	if ak == "mu" or bk == "mu" then
		seen[pair] = true
		local ua = ak == "mu" and G.unfold(a) or a
		local ub = bk == "mu" and G.unfold(b) or b
		local r = sub(ua, ub, seen, memo)
		seen[pair] = nil
		return r
	end

	-- Lattice-connective decomposition. The "for-all" rules (A=union, B=inter) are
	-- decided BEFORE the "exists" rules (B=union, A=inter): when both sides are
	-- connectives (e.g. union <: union), decomposing the left union first is the
	-- sound order — `(a|b) <: c` reduces to `a<:c ∧ b<:c`, not to `(a|b) <: ci`
	-- for some ci. Checking B=union first here would wrongly ask `(a|b) <: ci`.
	-- (§3.2: "Both together handle union <: union".)
	--
	-- (A = union: every member <: B.)
	if ak == "union" then
		local ms = members_of(a)
		for i = 1, #ms do
			if not sub(ms[i], b, seen, memo) then return false end
		end
		return true
	end
	-- (B = inter: A <: every member.)
	if bk == "inter" then
		local ms = members_of(b)
		for i = 1, #ms do
			if not sub(a, ms[i], seen, memo) then return false end
		end
		return true
	end
	-- The two "exists" rules (B=union, A=inter) must BOTH be tried when both hold
	-- (the inter-<:-union case): `(a∩b) <: (c∪d)` succeeds via the A=inter rule
	-- (some intersected member is below B) even when no single union member of B
	-- dominates the whole intersection. So neither rule returns false early; a
	-- false from one falls through to the other.
	--
	-- (B = union: A <: some member.)
	if bk == "union" then
		local ms = members_of(b)
		for i = 1, #ms do
			if sub(a, ms[i], seen, memo) then return true end
		end
		-- fall through: if A is also an inter, the A=inter rule may still hold.
	end
	-- (A = inter: some member <: B.)
	if ak == "inter" then
		local ms = members_of(a)
		for i = 1, #ms do
			if sub(ms[i], b, seen, memo) then return true end
		end
		return false
	end
	-- B=union exhausted with no inter fallback available.
	if bk == "union" then return false end

	-- ALWAYS-FALSE top/bottom laws (§3.2). Safe here: A and B are now neither μ
	-- nor a connective, so no decomposition could rescue them.
	if ak == "unknown" then return false end  -- unknown </: anything but unknown
	if bk == "never"   then return false end  -- nothing </: never but never

	-- (Primitives and the one hard-wired edge integer <: number. §3.2.)
	if ak == "integer" and bk == "number" then return true end
	-- (Literal singletons <: their base and themselves.)
	if ak == "lit_int" then
		if bk == "integer" or bk == "number" then return true end
		return false
	end
	if ak == "lit_num" then
		if bk == "number" then return true end
		return false
	end
	if ak == "lit_str" then
		if bk == "string" then return true end
		return false
	end
	if ak == "lit_bool" then
		if bk == "boolean" then return true end
		return false
	end

	-- (Functions: contravariant params, covariant multi-return tuple. §3.2.)
	if ak == "fn" and bk == "fn" then
		local pa, pb = params_of(a), params_of(b)
		local ra, rb = ret_of(a), ret_of(b)
		-- params: contravariant. B's i-th fixed param <: A's i-th fixed param.
		-- A may accept fewer fixed params than B only if A has a vararg covering
		-- the rest; A may require no more fixed params than B can supply.
		local nb = #pb.fixed
		for i = 1, nb do
			local a_param --[[: Ty | nil ]]
			if i <= #pa.fixed then a_param = pa.fixed[i] else a_param = pa.vararg end
			if a_param == nil then return false end  -- A demands a param B won't supply
			if not sub(pb.fixed[i], a_param, seen, memo) then return false end
		end
		-- A's extra fixed params (beyond B) make A unsatisfiable by a B-caller.
		if #pa.fixed > nb then return false end
		-- varargs: contravariant on the tail element when both present.
		local pbv, pav = pb.vararg, pa.vararg
		if pbv ~= nil and pav ~= nil then
			if not sub(pbv, pav, seen, memo) then return false end
		end
		-- return: covariant, pointwise on the return tuple. A may return MORE than
		-- B needs (extra returns are droppable), so A's tuple is <: a shorter prefix.
		for i = 1, #rb.fixed do
			if i > #ra.fixed then return false end  -- A returns fewer than B promises
			if not sub(ra.fixed[i], rb.fixed[i], seen, memo) then return false end
		end
		local rbv, rav = rb.vararg, ra.vararg
		if rbv ~= nil and rav ~= nil then
			if not sub(rav, rbv, seen, memo) then return false end
		end
		return true
	end
	-- (A = a specific fn shape <: the untyped function top.)
	if ak == "fn" and bk == "function" then return true end

	-- (Records: width + depth + optional + open-row. §3.2.)
	if (ak == "rec" or ak == "rec_with_indexer") and (bk == "rec" or bk == "rec_with_indexer") then
		if not M._rec_sub(a, b, seen, memo) then return false end
		-- rec_with_indexer decomposes to its rec part AND its indexer part.
		if bk == "rec_with_indexer" then
			-- B has an index signature: A must satisfy it. Only A's *listed* fields
			-- are checked against B's indexer (A is not an indexer itself unless it
			-- is rec_with_indexer — the `...`-vs-indexer distinction, §3.2).
			if not M._indexer_obligation(a, b, seen, memo) then return false end
		end
		return true
	end

	-- (Indexers: contravariant key, covariant value. §3.2.)
	if ak == "indexer" and bk == "indexer" then
		local ka, va = a.key, a.val
		local kb, vb = b.key, b.val
		if ka == nil or va == nil or kb == nil or vb == nil then return false end
		if not sub(kb, ka, seen, memo) then return false end
		return sub(va, vb, seen, memo)
	end

	-- (A = rec/rwi with integer-literal fields (a tuple) <: indexer(integer, V).
	--  §3.2: a tuple is <: an indexer iff every field type <: V. An OPEN-row rec
	--  is NOT automatically an indexer — the `...`-vs-indexer distinction.)
	if (ak == "rec" or ak == "rec_with_indexer") and bk == "indexer" then
		if a.rows == "open" then return false end  -- open tail ≠ index signature
		local kb, vb = b.key, b.val
		if kb == nil or vb == nil then return false end
		local fs = fields_of(a)
		for i = 1, #fs do
			-- the field's key, as a singleton, must be <: the indexer key, and the
			-- field's value <: the indexer value.
			local key_ty = G.lit_str(fs[i].key)
			if not sub(key_ty --[[: Ty ]], kb, seen, memo) then return false end
			if not sub(fs[i].ty, vb, seen, memo) then return false end
		end
		if ak == "rec_with_indexer" then
			local ka2, va2 = a.key, a.val
			if ka2 == nil or va2 == nil then return false end
			if not (sub(kb, ka2, seen, memo) and sub(va2, vb, seen, memo)) then return false end
		end
		return true
	end

	-- No constructor-pair rule matched → not a subtype.
	return false
end

-- Record width/depth/optional/open-row rule (§3.2). A <: B for records.
--: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean
function M._rec_sub(a, b, seen, memo)
	local fa, fb = fields_of(a), fields_of(b)
	-- open-row A is NOT <: a closed B (the open tail could violate closedness),
	-- and an open A is conservatively not <: ANY B beyond what its listed fields
	-- cover. The reference rule: an open A against a closed B → false.
	if a.rows == "open" and b.rows == "closed" then return false end

	for i = 1, #fb do
		local bf = fb[i]
		local af = find_field(fa, bf.key)
		if af == nil then
			-- B requires a field A does not list.
			if bf.optional then
				-- optional B field may be absent in A — OK.
			elseif a.rows == "open" then
				-- A is open: an unlisted field reads as `unknown`, which is not
				-- <: a required concrete B field (unless B's field is `unknown`).
				if (bf.ty.kind ~= "unknown") then return false end
			else
				return false  -- required B field absent in closed A.
			end
		else
			-- depth: covariant field type (v1 treats fields covariantly; the
			-- mutable-field-invariance gap is recorded in §9.2).
			if bf.optional then
				-- A's field may be `<: (B.ty | nil)`; build that union once.
				local bopt = G.union({ bf.ty --[[: Ty ]], G.nil_() })
				if not sub(af.ty, bopt --[[: Ty ]], seen, memo) then return false end
			else
				-- required B field: A's must be present, non-optional, and <:.
				if af.optional then return false end
				if not sub(af.ty, bf.ty, seen, memo) then return false end
			end
		end
	end
	return true
end

-- B is rec_with_indexer: A's listed fields must satisfy B's index signature
-- (key contravariance, value covariance). §3.2 decomposition.
--: (Ty, Ty, { [string]: boolean | nil }, { [string]: boolean | nil }) -> boolean
function M._indexer_obligation(a, b, seen, memo)
	local kb, vb = b.key, b.val
	if kb == nil or vb == nil then return false end
	local b_named = fields_of(b)
	local fa = fields_of(a)
	for i = 1, #fa do
		-- A field that B *also names* is governed by B's named-field type (already
		-- checked by the rec part), NOT by B's index signature: the indexer applies
		-- only to keys not covered by a named field. Skip B-named keys here.
		if find_field(b_named, fa[i].key) == nil then
			local key_ty = G.lit_str(fa[i].key)
			-- if this field's key is admitted by the indexer key, its value must be <: vb.
			if sub(key_ty, kb, seen, memo) then
				if not sub(fa[i].ty, vb, seen, memo) then return false end
			end
		end
	end
	-- if A is itself rec_with_indexer, its indexer must refine B's.
	if a.kind == "rec_with_indexer" then
		local ka2, va2 = a.key, a.val
		if ka2 == nil or va2 == nil then return false end
		if not (sub(kb, ka2, seen, memo) and sub(va2, vb, seen, memo)) then return false end
	end
	return true
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- Pure, total boolean verdict.
--: (Ty, Ty) -> boolean
function M.is_subtype(a, b)
	return sub(a, b, {}, {})
end

-- Witness variant: returns (verdict, counterexample-or-nil). On rejection the
-- counterexample names the offending constructor pair — the data that populates
-- RejectedClaim.counterevidence downstream (§6.4). In v1 the witness is the
-- top-level pair; deeper localization is a later-pass refinement.
--: (Ty, Ty) -> (boolean, Counterexample | nil)
function M.subtype(a, b)
	local ok = sub(a, b, {}, {})
	if ok then return true, nil end
	return false, { kind = "not_subtype", a = a, b = b }
end

return M
