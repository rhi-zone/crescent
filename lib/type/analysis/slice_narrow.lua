-- lib/type/analysis/slice_narrow.lua
--
-- The flow-narrowing CORE for `crescent.slice.v1`
-- (docs/agnostic-static-analysis-crescent-slice.md §4). Pass 3 of the slice
-- mechanization (§8): the pure, self-contained refinement function that the
-- `narrow_guard` evidence method (crescent_slice.lua) discharges. Like
-- slice_subtype.lua, this is a pure function over interned `Ty`; it imports
-- slice_ty + slice_subtype only, NOT the substrate (init.lua). The substrate
-- learns nothing — refinements become `narrows` CLAIMS with `narrow_guard`
-- evidence and visible dependency edges, never checker-internal mutable state.
--
-- A Guard is a recognized v1 discriminator over a target variable. The adapter
-- (crescent_slice_parse.lua) recognizes the five v1 forms in an if/elseif test
-- and emits a Guard tree; `refine(guard, x, T)` computes the (T_true, T_false)
-- refinement of variable `x` whose pre-guard synthesized type is `T`.
--
-- The v1 deferral fence (kernel §3.5) is honored: NO complement. Truthy branches
-- narrow EXACTLY by the positive decomposition (drop non-matching union members /
-- pick the positive atom — a positive operation needing no `~T`); falsy branches
-- are the SOUND WIDER approximation `T` (unrefined), EXCEPT the nil-guard, whose
-- complementary branch is itself a positive member (drop-nil / the nil member).
--
--   Guard =
--     { g="truthy",  var }                       -- if x
--     { g="nil_eq",  var, eq=boolean }           -- x == nil (eq) / x ~= nil (not eq)
--     { g="type_eq", var, tyname=string }        -- type(x) == "string"
--     { g="lit_eq",  var, lit=Ty }               -- x == "GET" / x == 42 / x == true
--     { g="tag_eq",  var, field=string, lit=Ty } -- x.tag == "leaf"
--     { g="not",     inner=Guard }               -- not g
--     { g="and",     left=Guard, right=Guard }   -- g1 and g2
--     { g="or",      left=Guard, right=Guard }   -- g1 or g2

local G = require("lib.type.analysis.slice_ty")
local SUB = require("lib.type.analysis.slice_subtype")

local M = {}

-- A decoded Guard: the recognized-and-decoded refinement tree the refinement
-- function consumes. `lit` fields are interned `Ty` (decoded by the caller before
-- `refine` runs); composite guards carry `inner`/`left`/`right` sub-guards.
--:: Guard = { g: string, var?: string, eq?: boolean, tyname?: string, field?: string, lit?: Ty, inner?: Guard, left?: Guard, right?: Guard }

-- ── Union helpers (positive decomposition primitives) ────────────────────────

-- The members of `T` as a list. A non-union is a singleton list (itself).
--: (Ty) -> Ty[]
local function members_of(ty)
	if ty.kind == "union" then return ty.members or {} end
	return { ty }
end

-- Keep exactly the union members of `T` for which `pred(member)` holds, re-unioned
-- (G.union normalizes: empty ⇒ never, singleton ⇒ the member). A positive
-- operation — dropping non-matching members needs no complement.
--: (Ty, (Ty) -> boolean) -> Ty
local function keep_members(ty, pred)
	local kept = {} --[[: Ty[] ]]
	local ms = members_of(ty)
	for i = 1, #ms do
		if pred(ms[i]) then kept[#kept + 1] = ms[i] end
	end
	return G.union(kept)
end

-- Is `m` a falsy-only member (nil, false, or lit_bool(false))? These are the
-- members truthiness drops on the truthy branch.
--: (Ty) -> boolean
local function is_falsy_member(m)
	if m.kind == "nil" then return true end
	if m.kind == "lit_bool" then return m.b == false end
	return false
end

-- Is `m` a member that is exactly `nil`?
--: (Ty) -> boolean
local function is_nil_member(m) return m.kind == "nil" end

-- ── Primitive-kind matching for type(x) == "<name>" ──────────────────────────
--
-- A member `m` MATCHES the runtime type tag `tyname` iff every value of `m` has
-- that Lua `type()` result. `boolean`/`lit_bool`, `number`/`integer`/`lit_int`/
-- `lit_num`, `string`/`lit_str`, `function`/`fn`, and the table family all map to
-- their `type()` string. A `union` member never reaches here (members_of flattens
-- one level; nested unions are already normalized away by the interner). `unknown`
-- is NOT matched (it could be any kind — keeping it would be unsound-narrow), and
-- it is NOT dropped either: the conservative truthy result for a bare `unknown`
-- target is handled by the caller (it cannot be refined positively, so it stays).

--: (Ty, string) -> boolean
local function member_matches_typename(m, tyname)
	local k = m.kind
	if tyname == "nil" then return k == "nil" end
	if tyname == "boolean" then return k == "boolean" or k == "lit_bool" end
	if tyname == "number" then
		return k == "number" or k == "integer" or k == "lit_int" or k == "lit_num"
	end
	if tyname == "string" then return k == "string" or k == "lit_str" end
	if tyname == "function" then return k == "function" or k == "fn" end
	if tyname == "table" then
		return k == "rec" or k == "rec_with_indexer" or k == "indexer"
	end
	return false
end

M.member_matches_typename = member_matches_typename

-- ── tag-field discriminant (union-of-recs idiom) ─────────────────────────────
--
-- `x.tag == lit`: keep the union members whose `tag` field ADMITS the literal —
-- i.e. members that are records with a `tag` field whose type accepts `lit`
-- (`lit <: field_type`). A μ member is unfolded once before inspection (the
-- discriminated-union / hamt idiom). This is the union-of-recs selection (§4.1,
-- requirement 3): `x.tag == "leaf"` selects the members admitting `"leaf"`.

--: (Ty, string, Ty) -> boolean
local function member_admits_tag(m, field, lit)
	local mm = m
	if mm.kind == "mu" then mm = G.unfold(mm) end
	-- a union member that is itself a union (post-unfold) — distribute: admits iff
	-- ANY of its sub-members admits (the value could be any of them).
	if mm.kind == "union" then
		local subs = mm.members or {}
		for i = 1, #subs do
			if member_admits_tag(subs[i], field, lit) then return true end
		end
		return false
	end
	if mm.kind ~= "rec" and mm.kind ~= "rec_with_indexer" then return false end
	local fields = mm.fields or {}
	for i = 1, #fields do
		if fields[i].key == field then
			-- the field admits the literal iff lit <: fieldType (a lit_str tag field
			-- `"leaf"` admits lit_str("leaf"); a plain `string` tag field admits any).
			return SUB.is_subtype(lit, fields[i].ty)
		end
	end
	return false
end

M.member_admits_tag = member_admits_tag

-- ── Per-form refinement ──────────────────────────────────────────────────────
--
-- Each returns (T_true, T_false) for the target variable `x` of pre-guard type
-- `T`. Truthy is exact (positive); falsy is sound-wider `T` except the nil-guard.

-- truthy `if x`: truthy drops falsy members (nil, false); falsy is T (sound wider).
--: (Ty) -> (Ty, Ty)
local function refine_truthy(t)
	--: (Ty) -> boolean
	local function keep(m) return not is_falsy_member(m) end
	local t_true = keep_members(t, keep)
	return t_true, t
end

-- `x == nil` (eq=true): the truthy (x IS nil) branch is the nil member alone (a
-- POSITIVE member, sound); falsy (x is not nil) drops nil. `x ~= nil` (eq=false)
-- is the swap. The nil-guard is the one form whose complementary branch is itself
-- positive, so BOTH branches are exact here (§4.1, §4.2).
--: (Ty, boolean) -> (Ty, Ty)
local function refine_nil_eq(t, eq)
	--: (Ty) -> boolean
	local function not_nil(m) return not is_nil_member(m) end
	local only_nil = keep_members(t, is_nil_member)
	local drop_nil = keep_members(t, not_nil)
	if eq then return only_nil, drop_nil end -- x == nil
	return drop_nil, only_nil                -- x ~= nil
end

-- `type(x) == tyname`: truthy keeps members matching the runtime type; falsy is T.
--: (Ty, string) -> (Ty, Ty)
local function refine_type_eq(t, tyname)
	--: (Ty) -> boolean
	local function matches(m) return member_matches_typename(m, tyname) end
	local t_true = keep_members(t, matches)
	return t_true, t
end

-- `x == lit`: truthy is the singleton `lit` (the literal value), provided `lit` is
-- a possible value of T (lit <: T); otherwise the truthy branch is unreachable
-- (never). Falsy is T (sound wider). v1 narrows to the singleton, per §4.1.
--: (Ty, Ty) -> (Ty, Ty)
local function refine_lit_eq(t, lit)
	if SUB.is_subtype(lit, t) then return lit, t end
	return G.never(), t
end

-- `x.tag == lit`: truthy keeps the union members admitting the tag literal; falsy
-- is T. The union-of-recs discriminant (§4.1, requirement 3).
--: (Ty, string, Ty) -> (Ty, Ty)
local function refine_tag_eq(t, field, lit)
	--: (Ty) -> boolean
	local function admits(m) return member_admits_tag(m, field, lit) end
	local t_true = keep_members(t, admits)
	return t_true, t
end

-- ── Does a guard mention the target variable? ────────────────────────────────
--
-- A composite guard refines `x` only through sub-guards that name `x`; a conjunct
-- that does not mention `x` contributes no refinement for it (x stays T there).

local guard_mentions --[[: (Guard, string) -> boolean ]]

--: (Guard, string) -> boolean
guard_mentions = function(guard, x)
	local g = guard.g
	local inner = guard.inner
	if g == "not" and inner then return guard_mentions(inner, x) end
	local l, r = guard.left, guard.right
	if (g == "and" or g == "or") and l and r then
		return guard_mentions(l, x) or guard_mentions(r, x)
	end
	return guard.var == x
end

M.guard_mentions = guard_mentions

-- ── The refinement entry point ───────────────────────────────────────────────
--
-- `refine(guard, x, T)` -> (T_true, T_false) for variable `x` of pre-guard type
-- `T`. Returns nil if the guard is malformed. For a guard that does NOT mention
-- `x`, both branches are `T` (no information about x).

local refine --[[: (Guard, string, Ty) -> (Ty | nil, Ty | nil) ]]

--: (Guard, string, Ty) -> (Ty | nil, Ty | nil)
refine = function(guard, x, t)
	local g = guard.g

	if g == "not" then
		-- swap the truthy/falsy refinements of the inner guard (§4.1).
		local inner = guard.inner
		if not inner then return nil, nil end
		local it, ifa = refine(inner, x, t)
		if not it or not ifa then return nil, nil end
		return ifa, it
	end

	if g == "and" then
		-- truthy: apply BOTH truthy refinements (intersection — both must hold).
		-- Composition via the positive decomposition: each conjunct narrows the
		-- ALREADY-narrowed type, so chaining their truthy refinements is the
		-- intersection. falsy: T (sound wider — no complement, §4.1).
		local l, r = guard.left, guard.right
		if not l or not r then return nil, nil end
		local lt = refine(l, x, t)
		if lt == nil then return nil, nil end
		local rt = refine(r, x, lt)
		if rt == nil then return nil, nil end
		return rt, t
	end

	if g == "or" then
		-- truthy: union of the two truthy refinements (either may hold). falsy: T.
		local l, r = guard.left, guard.right
		if not l or not r then return nil, nil end
		local lt = refine(l, x, t)
		if lt == nil then return nil, nil end
		local rt = refine(r, x, t)
		if rt == nil then return nil, nil end
		return G.union({ lt, rt }), t
	end

	-- atomic guards: a guard naming a different variable gives no info about x.
	if guard.var ~= x then return t, t end

	if g == "truthy" then return refine_truthy(t) end
	if g == "nil_eq" then return refine_nil_eq(t, guard.eq == true) end
	if g == "type_eq" then
		local tn = guard.tyname
		if type(tn) ~= "string" then return nil, nil end
		return refine_type_eq(t, tn)
	end
	if g == "lit_eq" then
		local lit = guard.lit
		if not lit then return nil, nil end
		return refine_lit_eq(t, lit)
	end
	if g == "tag_eq" then
		local field = guard.field
		local lit = guard.lit
		if type(field) ~= "string" or not lit then return nil, nil end
		return refine_tag_eq(t, field, lit)
	end
	return nil, nil
end

M.refine = refine

return M
