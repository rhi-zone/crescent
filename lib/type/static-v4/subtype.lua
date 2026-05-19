-- Subtyping algorithm: simple-sub style constraint solver.
--
-- Reference: Parreaux 2020 (ICFP, "The Simple Essence of Algebraic
-- Subtyping"); MLstruct §3.2 (Parreaux & Chau OOPSLA 2022) for the polar
-- bounds construction.
--
-- The single primitive operation is `constrain(lhs, rhs)` which checks the
-- obligation `lhs <: rhs` against a mutable solver state. The state owns:
--   * a cache of (lhs, rhs) pairs currently being processed — guarantees
--     termination on cyclic variable graphs (which arise as soon as a
--     variable's bound mentions itself).
--   * the type variables themselves: constrain may add bounds to variables on
--     either side, and those new bounds are themselves propagated as further
--     constraints (the transitive-closure invariant of MLstruct §3.2).
--
-- This module does NOT implement: complement, recursion fixed points,
-- quantifier subsumption, match-type evaluation, indexed access, effects, or
-- coalescing. Each lands in a later phase.

local T = require("lib.type.static-v4.types")

-- V4Type and its variant aliases (V4Var, V4Top, V4Prim, ...) are imported
-- transitively from types.lua via the require above — the crescent typechecker
-- resolves `--::` aliases across files following the require graph. Solver
-- state is local to this module.
--:: V4Solver  = { cache: { [string]: boolean }, error: string | nil }

local M = {}

-- ── Solver state ──────────────────────────────────────────────────────────

local Solver = {}
Solver.__index = Solver

--: () -> V4Solver
function M.new_solver()
	-- All shape-defining fields go in the literal (CLAUDE.md).
	local s = {
		cache = {},  -- [cache_key] = true   in-progress / proved subtype pairs
		error = nil, -- first error encountered; subsequent constraints short-circuit
	}
	return setmetatable(s, Solver)
end

-- Cache key for a constraint pair. We key on identity (tostring of the table
-- address) for tables and on (tag,value) for value-equal scalars. Types built
-- via the M.* constructors are NOT hash-consed in 4a — two structurally
-- identical record literals are distinct tables — so identity is an
-- under-approximation of structural equality. That is correct for termination
-- (the cache may admit a constraint that has been seen before in a different
-- arena entry, but the algorithm will then re-prove it; it never proves an
-- obligation by appealing to itself, which is the termination concern).
--: (V4Type) -> string
local function key_of(t)
	return tostring(t)
end
--: (V4Type, V4Type) -> string
local function cache_key(a, b)
	return key_of(a) .. "<:" .. key_of(b)
end

-- ── Error helpers ─────────────────────────────────────────────────────────

--: (V4Solver, string) -> boolean
local function fail(s, msg)
	if s.error == nil then s.error = msg end
	return false
end

--: (V4Solver, V4Type, V4Type, string | nil) -> boolean
local function mismatch(s, a, b, why)
	local suffix = ""
	if why ~= nil then suffix = " (" .. why .. ")" end
	return fail(s, "type error: " .. T.show(a) .. " is not a subtype of " .. T.show(b) .. suffix)
end

-- ── Variable bounds ───────────────────────────────────────────────────────

-- Forward declaration: constrain calls into itself recursively (via the
-- bound-propagation paths), and the variable helpers below also recurse.
local constrain

-- Record T as a new lower bound of variable v, then propagate: every existing
-- upper bound u of v must satisfy T <: u, and every variable v' with v <: v'
-- must also receive T as a lower bound (transitive closure).
--: (V4Solver, V4Var, V4Type) -> nil
local function add_lower(s, v, t)
	-- Deduplicate exact-identity bounds; the cache subsumes structural dups.
	for _, existing in ipairs(v.lower) do
		if existing == t then return end
	end
	v.lower[#v.lower + 1] = t
	-- Propagate to existing upper bounds of v.
	for _, u in ipairs(v.upper) do
		constrain(s, t, u)
		if s.error then return end
	end
	-- Propagate to variables v <: v'.
	for _, vp in pairs(v.upper_vars) do
		constrain(s, t, vp)
		if s.error then return end
	end
end

--: (V4Solver, V4Var, V4Type) -> nil
local function add_upper(s, v, t)
	for _, existing in ipairs(v.upper) do
		if existing == t then return end
	end
	v.upper[#v.upper + 1] = t
	for _, l in ipairs(v.lower) do
		constrain(s, l, t)
		if s.error then return end
	end
	for _, vp in pairs(v.lower_vars) do
		constrain(s, vp, t)
		if s.error then return end
	end
end

-- v1 <: v2. Link the two variables and propagate bounds across the link.
--: (V4Solver, V4Var, V4Var) -> nil
local function link_vars(s, v1, v2)
	if v1 == v2 then return end
	if v1.upper_vars[v2.id] then return end -- already linked
	v1.upper_vars[v2.id] = v2
	v2.lower_vars[v1.id] = v1
	-- Every existing lower bound of v1 flows into v2.
	for _, l in ipairs(v1.lower) do
		constrain(s, l, v2)
		if s.error then return end
	end
	-- Every existing upper bound of v2 flows back to v1.
	for _, u in ipairs(v2.upper) do
		constrain(s, v1, u)
		if s.error then return end
	end
end

-- ── Structural decomposition ──────────────────────────────────────────────

-- All decomposition rules. Called only when both sides are non-variable.
--: (V4Solver, V4Type, V4Type) -> boolean
local function decompose(s, a, b)
	-- Top/bottom shortcuts: A <: unknown and never <: B always hold.
	if b.tag == "top" then return true end
	if a.tag == "bot" then return true end

	-- Union/intersection rules. These apply BEFORE per-constructor rules
	-- because A | B <: C must decompose regardless of A and B's tags.
	if a.tag == "union" then
		for _, m in ipairs(a.members) do
			if not constrain(s, m, b) then return false end
		end
		return true
	end
	if b.tag == "inter" then
		for _, m in ipairs(b.members) do
			if not constrain(s, a, m) then return false end
		end
		return true
	end

	-- A <: B | C and A & B <: C: the principled rule is MLstruct's
	-- negation-based rewrite (`A ∧ ¬B <: C` iff `A <: B | C`), which
	-- requires complement (`~T`) in the lattice. Phase 4a does not yet have
	-- complement — that lands in Phase 4c. A "try each disjunct with cache
	-- rollback" stopgap was rejected: it is sound only on ground inputs and
	-- silently loses principal types when variables appear, exactly the
	-- shape of bug future sessions would pattern-match as the intended
	-- design (CLAUDE.md's "temporary measures are context poisoning"). The
	-- correct move until 4c lands is to fail loudly so the missing
	-- mechanism is visible at the call site.
	if b.tag == "union" then
		return mismatch(s, a, b, "union on the right requires complement (Phase 4c); unsupported in 4a")
	end
	if a.tag == "inter" then
		return mismatch(s, a, b, "intersection on the left requires complement (Phase 4c); unsupported in 4a")
	end

	-- ── Same-shape constructor rules ─────────────────────────────────

	if a.tag == "prim" and b.tag == "prim" then
		if T.prim_subtype(a.name, b.name) then return true end
		return mismatch(s, a, b)
	end

	if a.tag == "literal" and b.tag == "literal" then
		if a.base == b.base and a.value == b.value then return true end
		return mismatch(s, a, b)
	end

	-- Literal on the left, primitive on the right: literal <: its base, and
	-- transitively to any supertype of the base (integer literal <: number).
	if a.tag == "literal" and b.tag == "prim" then
		if T.prim_subtype(a.base, b.name) then return true end
		return mismatch(s, a, b)
	end

	-- Primitive on the left, literal on the right: never holds (a primitive
	-- has multiple inhabitants; a literal type is a singleton).
	if a.tag == "prim" and b.tag == "literal" then
		return mismatch(s, a, b, "primitive is wider than literal")
	end

	if a.tag == "fn" and b.tag == "fn" then
		if #a.params ~= #b.params then
			return mismatch(s, a, b, "arity mismatch")
		end
		-- Contravariant parameters, covariant return.
		for i = 1, #a.params do
			local ap, bp = a.params[i], b.params[i]
			if ap ~= nil and bp ~= nil then
				if not constrain(s, bp, ap) then return false end
			end
		end
		return constrain(s, a.ret, b.ret)
	end

	if a.tag == "rec" and b.tag == "rec" then
		-- Width subtyping: A <: B requires A to have every field B requires.
		-- If B is closed, A must not have extras unless A is also open and
		-- those extras are part of A's row but not B's — in 4a we model
		-- "closed" as "exactly this field set", so A having more fields than
		-- a closed B is rejected.
		for k, bt in pairs(b.fields) do
			local at = a.fields[k]
			if at == nil then
				if a.open then
					-- The required field could exist in the open row; but
					-- without a row variable that we can constrain, we have
					-- to reject. Refining this requires row polymorphism,
					-- which is a later phase. For 4a, open-record-on-LHS
					-- means "at least these fields", so a missing required
					-- field is still a real missing field.
					return mismatch(s, a, b, "missing field '" .. k .. "'")
				end
				return mismatch(s, a, b, "missing field '" .. k .. "'")
			end
			-- Depth subtyping: field types are covariant.
			if not constrain(s, at, bt) then return false end
		end
		-- Width check on the supertype side: if B is closed, A must not have
		-- extra fields. Open B accepts extras.
		if not b.open then
			for k in pairs(a.fields) do
				if b.fields[k] == nil then
					return mismatch(s, a, b, "extra field '" .. k .. "' on a closed record")
				end
			end
			-- An open A flowing into a closed B is rejected: the row could
			-- carry unknown extras that B forbids.
			if a.open then
				return mismatch(s, a, b, "open record cannot flow into closed record")
			end
		end
		return true
	end

	-- Mismatched constructors at this point: error.
	return mismatch(s, a, b)
end

-- ── The constraint primitive ──────────────────────────────────────────────

--: (V4Solver, V4Type, V4Type) -> boolean
constrain = function(s, a, b)
	if s.error then return false end

	-- Identity / cache.
	if a == b then return true end
	local k = cache_key(a, b)
	if s.cache[k] then return true end
	s.cache[k] = true

	-- Equi-recursive types: unfold one step. The cache entry above guarantees
	-- termination — when the unfolded body reaches the same (mu, other) pair,
	-- we short-circuit. This is the Amadio-Cardelli (1993) equi-recursive
	-- algorithm: μX.T <: U iff T[μX.T/X] <: U, with cycle detection on the
	-- subtype obligation, not on the structural depth.
	--
	-- We unfold mu BEFORE the variable rules: if both sides are mus we want
	-- the cache to short-circuit on the (mu, mu) identity check above; if
	-- only one side is mu, unfolding exposes the structure the other side
	-- needs to match. The body of a mu is the type itself with self-refs
	-- pointing back; in Lua the cyclic table means we never substitute
	-- explicitly — reading `mu.body` already gives the unfolded form.
	if a.tag == "mu" then
		return constrain(s, a.body, b)
	end
	if b.tag == "mu" then
		return constrain(s, a, b.body)
	end

	-- Variable on the right.
	if b.tag == "var" then
		if a.tag == "var" then
			link_vars(s, a, b)
		else
			add_lower(s, b, a)
		end
		if s.error then return false end
		return true
	end

	-- Variable on the left (RHS is concrete; b's tag is not "var").
	if a.tag == "var" then
		add_upper(s, a, b)
		if s.error then return false end
		return true
	end

	return decompose(s, a, b)
end

M.constrain = constrain

-- Convenience top-level predicate: does A <: B hold on a fresh solver?
-- Returns (ok, errmsg). The solver is discarded; bounds added to variables
-- during the call persist on the variables themselves (this is intentional —
-- callers reusing variables across queries observe the accumulated bounds).
--: (V4Type, V4Type) -> (boolean, string | nil)
function M.subtype(a, b)
	local s = M.new_solver()
	local ok = constrain(s, a, b)
	return ok, s.error
end

return M
