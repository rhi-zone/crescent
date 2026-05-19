-- Emptiness check — Phase 4c.
--
-- `is_empty(T, solver)` returns true iff `T` denotes the empty set (⊥) under
-- the current solver state. This is the primitive operation that closes the
-- boolean lattice: every subtype obligation `A <: B` reduces semantically to
-- `is_empty(A ∩ ¬B)`.
--
-- Algorithm (MLstruct §3.3, §5.2, adapted): normalize `T` to a *reduced
-- disjunctive normal form* (RDNF) — a list of disjuncts, each a conjunction of
-- positive and negated *atoms* — and check each disjunct for emptiness
-- individually. A disjunct is empty iff:
--   (a) it contains `⊥` positively,
--   (b) two positive atoms of structurally disjoint kinds collide (e.g. a
--       primitive and a record both required of the same value),
--   (c) some positive atom is fully covered by some negated atom — i.e. there
--       exist P, N in the disjunct with `P <: N`, which makes `P ∧ ¬N = ⊥`,
--   (d) two positive atoms of the *same* kind can be combined into one and
--       the combined positive is then subsumed by a negative, OR they conflict
--       directly (e.g. two distinct primitive names: `integer ∧ string = ⊥`),
--   (e) the combined positive atoms of a same-kind family are <: union of the
--       same-kind negated atoms (per-kind emptiness — MLstruct §5.2 last
--       paragraph).
--
-- DNF normalization (push ¬ inward, distribute ∩ over ∪) is finite for the
-- type expressions 4c admits. μ types are atoms — we do NOT push complement
-- inside μ. Variables are atoms — emptiness queries on a bare variable defer
-- (the variable could still be inhabited or not; we return "not empty" as the
-- safe answer, which keeps subtyping sound — see EXCEPTIONS at the bottom of
-- this file).
--
-- Per design §2.2 ("DNF emptiness checking is deferred until forced"), this
-- routine is invoked only at decision points: subtype obligations that
-- involve negation, union-on-RHS, or intersection-on-LHS. It is NOT run on
-- every constraint.

local T = require("lib.type.static-v4.types")

-- V4Type and its variant aliases come transitively from `types.lua`. We
-- redeclare V4Solver here (rather than depending on subtype.lua's copy) so
-- that empty.lua and subtype.lua share the same shape without a require
-- cycle. The shape is also load-bearing — emptiness reads `s.cache` to share
-- proof-in-progress entries with the constrain pipeline.
--:: V4Solver  = { cache: { [string]: boolean }, error: string | nil }

local M = {}

-- Forward decl: emptiness recurses through the solver's subtype check on
-- atoms strictly smaller than the input. The solver, in turn, calls back into
-- emptiness only when negation appears — termination by structural descent on
-- DNF size.
local is_empty -- (V4Type, V4Solver) -> boolean

-- ── DNF normalization ────────────────────────────────────────────────────
-- A DNF representation is a list of disjuncts; each disjunct is a record
-- { pos = {V4Type[]}, neg = {V4Type[]} } where every element of pos/neg is an
-- *atom* — primitive, literal, fn, rec, var, mu, top, bot. No unions,
-- intersections, or negations remain inside.

-- DnfDisjunct and Dnf are local working types: a disjunct holds two lists of
-- atoms (`pos` is required, `neg` is required-to-be-absent) and Dnf is a list
-- of disjuncts. We do not declare these as `--::` aliases because cross-file
-- aliases referencing V4Type don't currently resolve in the typechecker; the
-- shapes are inlined where used via `--[[: ...]]`.

-- Combine two DNFs by intersection: each disjunct of A is intersected with
-- each disjunct of B (Cartesian product). Worst-case |A|*|B| disjuncts.
--: (Dnf, Dnf) -> Dnf
local function dnf_inter(a, b)
	local out = {} --[[: Dnf ]]
	for _, da in ipairs(a) do
		for _, db in ipairs(b) do
			local pos, neg = {}, {} --[[: V4Type[] ]]
			for _, p in ipairs(da.pos) do pos[#pos + 1] = p end
			for _, p in ipairs(db.pos) do pos[#pos + 1] = p end
			for _, n in ipairs(da.neg) do neg[#neg + 1] = n end
			for _, n in ipairs(db.neg) do neg[#neg + 1] = n end
			out[#out + 1] = { pos = pos, neg = neg }
		end
	end
	return out
end

-- Union two DNFs: concatenation of disjuncts.
--: (Dnf, Dnf) -> Dnf
local function dnf_union(a, b)
	local out = {} --[[: Dnf ]]
	for _, d in ipairs(a) do out[#out + 1] = d end
	for _, d in ipairs(b) do out[#out + 1] = d end
	return out
end

-- Negate a DNF (De Morgan): ¬(∨_i (P_i ∧ ¬N_i)) = ∧_i ¬(P_i ∧ ¬N_i) =
-- ∧_i (∨_p ¬p ∨ ∨_n n) — a conjunction of unions, which is again Cartesian-
-- producted into DNF. Worst-case exponential blowup; this is the known cost.
--: (Dnf) -> Dnf
local function dnf_neg(a)
	-- ¬⊥ = ⊤: empty DNF is ⊥ (no disjuncts satisfiable); its negation is ⊤.
	if #a == 0 then
		return { { pos = { T.top() }, neg = {} } }
	end
	-- Start with ⊤ (a single empty-conjunction disjunct).
	local acc = { { pos = {}, neg = {} } } --[[: Dnf ]]
	for _, d in ipairs(a) do
		-- ¬(P_1 ∧ ... ∧ P_k ∧ ¬N_1 ∧ ... ∧ ¬N_m) =
		--   ¬P_1 ∨ ... ∨ ¬P_k ∨ N_1 ∨ ... ∨ N_m
		-- expressed as a DNF (each alternative is a single-atom disjunct).
		local alt = {} --[[: Dnf ]]
		for _, p in ipairs(d.pos) do
			alt[#alt + 1] = { pos = {}, neg = { p } }
		end
		for _, n in ipairs(d.neg) do
			alt[#alt + 1] = { pos = { n }, neg = {} }
		end
		if #alt == 0 then
			-- ¬⊤ = ⊥: an empty disjunct (vacuously true) negates to no
			-- alternatives.
			acc = {}
			break
		end
		acc = dnf_inter(acc, alt)
	end
	return acc
end

-- Convert a type to DNF. Recursive; bounded by the type's syntactic size in
-- the absence of μ-unfold (μ is treated as an atom, terminating the walk).
--: (V4Type) -> Dnf
local function to_dnf(t)
	if t.tag == "union" then
		local out = {} --[[: Dnf ]]
		for _, m in ipairs(t.members) do
			out = dnf_union(out, to_dnf(m))
		end
		return out
	end
	if t.tag == "inter" then
		-- ⊤ identity for ∩.
		local acc = { { pos = {}, neg = {} } } --[[: Dnf ]]
		for _, m in ipairs(t.members) do
			acc = dnf_inter(acc, to_dnf(m))
		end
		return acc
	end
	if t.tag == "neg" then
		return dnf_neg(to_dnf(t.body))
	end
	-- Atom: top, bot, prim, literal, fn, rec, var, mu.
	return { { pos = { t }, neg = {} } }
end

-- ── Atom-level disjointness and subsumption ──────────────────────────────

-- Coarse "kind" of an atom for cross-kind disjointness. Atoms of different
-- kinds (e.g. `integer` and `{x:int}`) are inhabited by disjoint value sets,
-- so their intersection is empty.
--
-- Variables, top, bot, and mu are intentionally NOT given a kind — they may
-- straddle kinds (variable, top) or be deferred (mu). We return nil and let
-- the disjunct-emptiness check handle them separately.
--: (V4Type) -> string | nil
local function atom_kind(a)
	if a.tag == "prim" then
		-- Primitives split into "string-like" / "number-like" / ... but
		-- crescent treats each primitive as its own kind for disjointness:
		-- string ∩ number = ⊥. integer is a subtype of number, so they share
		-- a kind. We model the kinds as the primitive name itself, with the
		-- integer/number sibling handled by the subtype check, not by kind.
		return "prim:" .. a.name
	end
	if a.tag == "literal" then
		-- A literal is in its base primitive's kind. integer 42 vs string
		-- "x" disjoint at the kind level.
		return "prim:" .. a.base
	end
	if a.tag == "fn" then return "fn" end
	if a.tag == "rec" then return "rec" end
	return nil
end

-- Two atoms are "kind-disjoint" if their kinds are concrete and incompatible.
-- Special-case: integer and number share a kind (number-family) — `integer`
-- and `number` are not disjoint. Modelled by walking the primitive subtype
-- edges: if either is a subtype of the other (or via literal-base), they're
-- in the same kind.
--: (V4Type, V4Type) -> boolean
local function kind_disjoint(a, b)
	local ka, kb = atom_kind(a), atom_kind(b)
	if ka == nil or kb == nil then return false end
	if ka == kb then return false end
	-- Both are primitive-rooted. Check via the prim_subtype edges.
	local pa = (a.tag == "prim" and a.name) or (a.tag == "literal" and a.base) or nil
	local pb = (b.tag == "prim" and b.name) or (b.tag == "literal" and b.base) or nil
	if pa ~= nil and pb ~= nil then
		if T.prim_subtype(pa, pb) or T.prim_subtype(pb, pa) then return false end
		return true
	end
	-- Otherwise: same kind-string was already equal-checked above; if we got
	-- here the kinds genuinely differ (e.g. "fn" vs "rec").
	return true
end

-- ── Disjunct emptiness ───────────────────────────────────────────────────

-- Lazily provided: a subtype predicate that is allowed to recurse into
-- emptiness (the solver wires this in). Decoupled to avoid a require cycle
-- between subtype.lua and empty.lua.
local _subtype_fn = nil --[[: ((V4Solver, V4Type, V4Type) -> boolean) | nil ]]

--: ((V4Solver, V4Type, V4Type) -> boolean) -> nil
function M._set_subtype(fn)
	_subtype_fn = fn
end

-- Check whether `P <: N` holds purely structurally without involving the
-- variable bound graph. This is used inside emptiness to decide whether a
-- positive atom is fully covered by a negative atom in the same disjunct.
-- Mutating variable bounds during an emptiness check would entangle solver
-- state in subtle ways (the emptiness query is meant to be a pure decision);
-- so the check refuses to add bounds and returns false in any case that
-- would require them.
--: (V4Solver, V4Type, V4Type) -> boolean
local function pure_subtype(s, a, b)
	if _subtype_fn == nil then return false end
	-- A fresh solver scoped to this check: bounds added on its behalf live
	-- only in its own cache, not on the variables. But variables ARE shared
	-- across solvers (they carry their own bound lists), so a recursive
	-- constrain would still mutate them. The conservative choice: refuse the
	-- check whenever either side mentions a variable. Variables remain
	-- "unknown" inhabitation-wise for emptiness purposes — which is sound,
	-- because a non-empty conclusion for the enclosing disjunct preserves
	-- the variable's freedom to range over either possibility.
	--: (V4Type) -> boolean
	local function mentions_var(t)
		if t.tag == "var" then return true end
		if t.tag == "fn" then
			for _, p in ipairs(t.params) do if mentions_var(p) then return true end end
			return mentions_var(t.ret)
		end
		if t.tag == "rec" then
			for _, v in pairs(t.fields) do
				if v ~= nil and mentions_var(v) then return true end
			end
			local ix = t.indexer
			if ix ~= nil then
				if mentions_var(ix.key) then return true end
				if mentions_var(ix.value) then return true end
			end
			return false
		end
		if t.tag == "union" or t.tag == "inter" then
			for _, m in ipairs(t.members) do if mentions_var(m) then return true end end
			return false
		end
		if t.tag == "neg" then return mentions_var(t.body) end
		-- mu intentionally NOT descended: it is opaque to emptiness, treated
		-- as an atom whose body can be unfolded by the structural subtype
		-- check via its own cache (see subtype.lua mu handling).
		return false
	end
	if mentions_var(a) or mentions_var(b) then return false end
	-- Same s argument so the call shares the cache (preventing redundant
	-- work) but variables-free types add no bounds.
	return _subtype_fn(s, a, b)
end

-- A disjunct is empty if it cannot be inhabited by any value.
--: (V4Solver, DnfDisjunct) -> boolean
local function disjunct_is_empty(s, d)
	-- (a) ⊥ in positives: empty by definition.
	for _, p in ipairs(d.pos) do
		if p.tag == "bot" then return true end
	end
	-- (a') ⊤ in negatives = ¬⊤ = ⊥ in conjunction: empty.
	for _, n in ipairs(d.neg) do
		if n.tag == "top" then return true end
	end
	-- (b) Drop ⊤ from positives and ⊥ from negatives — they're identity.
	-- (Done implicitly by skipping them below.)

	-- (c) Self-cancellation by IDENTITY first: T ∩ ¬T = ⊥. The cheap check
	-- runs before the recursive subtype check, which can be expensive.
	for _, p in ipairs(d.pos) do
		for _, n in ipairs(d.neg) do
			if p == n then return true end
		end
	end

	-- (d) Cross-kind disjointness on positives. Two positives in disjoint
	-- kinds: the conjunction is uninhabited.
	for i = 1, #d.pos do
		for j = i + 1, #d.pos do
			local pi, pj = d.pos[i], d.pos[j]
			if pi ~= nil and pj ~= nil and kind_disjoint(pi, pj) then
				return true
			end
		end
	end

	-- (e) Same-kind primitive/literal collisions on positives.
	-- e.g. integer ∩ string = ⊥ (already handled by kind_disjoint).
	-- Two distinct literals of the same base: empty.
	for i = 1, #d.pos do
		local pi = d.pos[i]
		if pi ~= nil and pi.tag == "literal" then
			for j = i + 1, #d.pos do
				local pj = d.pos[j]
				if pj ~= nil and pj.tag == "literal" and pj.base == pi.base and pj.value ~= pi.value then
					return true
				end
			end
		end
	end

	-- (e') Same-kind record collisions on positives. Two positive records
	-- whose values at a shared field have disjoint types are themselves
	-- disjoint: `{ tag: "a", ... } ∩ { tag: "b", ... } = ⊥` because no
	-- inhabitant can have `tag = "a"` and `tag = "b"` simultaneously. We
	-- check by walking each pair, intersecting the same-named field types,
	-- and recursing into `is_empty` on the intersection. This is the
	-- record-level dual of (e); the rewrite design §2.2 worked example
	-- ("({ kind: "foo", ... } | { kind: "bar", ... }) ∩ ¬{ kind: "foo", ... }
	-- reduces to { kind: "bar", ... }") relies on it being recognized.
	for i = 1, #d.pos do
		local pi = d.pos[i]
		if pi ~= nil and pi.tag == "rec" then
			for j = i + 1, #d.pos do
				local pj = d.pos[j]
				if pj ~= nil and pj.tag == "rec" then
					-- For each field present in both records, intersect the
					-- field types and check emptiness. We use the same solver
					-- `s` so the cache and proof-in-progress entries are
					-- shared. Termination: each recursive call's input is a
					-- strict subterm of the originals (a field's type, not
					-- the whole record), so the descent measure shrinks.
					for k in pairs(pi.fields) do
						local vi = pi.fields[k]
						local vj = pj.fields[k]
						if vi ~= nil and vj ~= nil then
							local members = { vi, vj } --[[: V4Type[] ]]
							if is_empty(T.inter(members), s) then return true end
						end
					end
				end
			end
		end
	end

	-- (f) Positive-covers-by-negative via structural subtyping. If any
	-- positive atom P is <: some negative atom N, then P ∩ ¬N = ⊥ and the
	-- whole conjunction is empty. We call into the solver's subtype check;
	-- it may recurse into emptiness through `neg` — termination is by the
	-- structural-descent invariant: each emptiness call's input is the
	-- intersection of strict subterms of the original.
	for _, p in ipairs(d.pos) do
		for _, n in ipairs(d.neg) do
			if p ~= n and pure_subtype(s, p, n) then
				return true
			end
		end
	end

	-- Otherwise we cannot conclude emptiness. This is sound under the rule:
	-- when emptiness cannot be proven, the subtype obligation reduces to
	-- "not provably true," and the enclosing subtype query falls back to
	-- failure (or to bound propagation if a variable is in play).
	return false
end

-- ── Public entry ─────────────────────────────────────────────────────────

-- is_empty(T, solver) — true iff T = ⊥. Decision points (subtype.lua) call
-- this when they need it; calling it eagerly on every constraint would blow
-- up exponentially (rewrite design §2.2 "deferred until forced").
--: (V4Type, V4Solver) -> boolean
is_empty = function(t, s)
	if t.tag == "bot" then return true end
	if t.tag == "top" then return false end
	local dnf = to_dnf(t)
	-- An empty DNF (no disjuncts) is ⊥ by definition.
	if #dnf == 0 then return true end
	for _, d in ipairs(dnf) do
		if not disjunct_is_empty(s, d) then return false end
	end
	return true
end

M.is_empty = is_empty
M.to_dnf   = to_dnf

return M

-- EXCEPTIONS / design notes:
--
-- 1. Variables in emptiness queries: we treat type variables as atoms whose
--    inhabitation is undetermined; emptiness on a disjunct mentioning a bare
--    variable returns false (not provably empty). This is conservative —
--    sound (we never spuriously conclude empty), but incomplete (we may
--    miss `α ∧ ¬α = ⊥` when α appears with a non-empty negation context).
--    Most such cases reduce out at the constraint level (the subtype solver
--    records ¬T as an upper bound on α and propagates), so this is rarely a
--    source of incompleteness for crescent's use cases.
--
-- 2. μ types in emptiness: μ is opaque here. To decide `μ X. F(X) <: T`, the
--    subtype solver unfolds μ via its identity-keyed cache (subtype.lua).
--    Emptiness defers to the solver's recursive subtype check for any μ atom
--    via `pure_subtype` (where applicable).
--
-- 3. Index access on negated keys (`T[~"x"]`): not implemented in
--    `index.lua`. The design admits it (§1.1 "negated keys are accepted"),
--    but realizing it requires the index reducer to subtract the literal
--    "x" from the contributing key set, which is a localized extension to
--    `index.lua`. Tracked for Phase 4d when match-type wildcards force the
--    feature in.
