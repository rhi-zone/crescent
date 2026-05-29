-- lib/type/experiments/v5_perf/constraint.lua
-- Constraint ADT + provenance.  Minimal subset for the perf prototype:
--   CEq(a, b)                   - type equality
--   CSub(a, b)                  - a is a subtype of b
--   CTableOpen(tv)              - tv is an open row variable
--   CTableSet(tv, key, ty)      - tv must have field key : ty
--   CTableSeal(tv, mu)          - seal tv with metatable mu (mu may be nil)
--   CMethodCall(tv, key, ret)   - tv:key(...) returns ret tvar (synthesised)
--   CRowExtend(record_ty, key, field_ty) - record's row contains key with given field type
--   CRowLacks(record_ty, key)   - record's row does NOT contain key
--   CRowClose(record_ty)        - record's row variable becomes closed (no further extension)
--
-- Each constraint carries provenance: { file, line, kind } where kind is
-- one of "declared" | "inferred" | "synthesized".  Cheap to construct,
-- ignored by the solver hot path; only consulted for error reporting.

local types_mod = require("lib.type.experiments.v5_perf.types")

local M = {}

-- ────────────────────────────────────────────────────────────────────────────
-- Intersection canonical form (Phase 4)
-- ────────────────────────────────────────────────────────────────────────────
--
-- Phase 4 introduces TIntersection into the constraint system.  Both
-- interpreters MUST use the SAME canonicalize helper so equality and
-- subset reasoning agree on shape.  Canonical form:
--   1. Flatten nested TIntersection (A & (B & C) -> [A, B, C]).
--   2. Sort parts by a stable structural key.
--   3. Dedupe identical parts.

-- Stable structural key for sorting/deduping intersection parts.  Mirrors
-- types_mod.equal: two parts that are .equal must produce equal keys.
-- Uses manual string concatenation (no table.concat) to keep the value type
-- pure-string and avoid index-signature mismatches with `[number]`.
--: (V5Type) -> string
local function key_of(t)
	if t.tag == "uvar" then return "U:" .. tostring(t.id) end
	if t.tag == "var" then return "V:" .. tostring(t.i) end
	if t.tag == "const" then return "C:" .. t.name end
	if t.tag == "rowvar" then return "R:" .. tostring(t.id) end
	if t.tag == "app" then return "A(" .. key_of(t.f) .. "," .. key_of(t.a) .. ")" end
	if t.tag == "lambda" then return "L:" .. t.k .. "(" .. key_of(t.b) .. ")" end
	if t.tag == "record" then
		local ks = {} --[[: string[] ]]
		for k, _ in pairs(t.fields) do ks[#ks + 1] = k end
		for i = 2, #ks do
			local cur = ks[i]
			local j = i - 1
			while j >= 1 and cur ~= nil and ks[j] ~= nil and ks[j] > cur do
				ks[j + 1] = ks[j]; j = j - 1
			end
			if cur ~= nil then ks[j + 1] = cur end
		end
		local s = "Rec{"
		for i = 1, #ks do
			local k = ks[i]
			if k ~= nil then
				local fv = t.fields[k]
				if fv ~= nil then
					if i > 1 then s = s .. "," end
					s = s .. k .. "=" .. key_of(fv)
				end
			end
		end
		if t.row ~= nil then s = s .. ";rv:" .. tostring(t.row.id) end
		return s .. "}"
	end
	if t.tag == "pack" then
		local s = "Pk("
		for i = 1, #t.items do
			local v = t.items[i]
			if v ~= nil then
				if i > 1 then s = s .. "," end
				s = s .. key_of(v)
			end
		end
		if t.rest ~= nil then s = s .. ";pv:" .. tostring(t.rest.id) end
		return s .. ")"
	end
	if t.tag == "arrow" then
		return "Ar(" .. key_of(t.args) .. ")->" .. key_of(t.ret)
	end
	if t.tag == "union" then
		local s = "Un["
		for i = 1, #t.xs do
			local v = t.xs[i]
			if v ~= nil then
				if i > 1 then s = s .. "," end
				s = s .. key_of(v)
			end
		end
		return s .. "]"
	end
	if t.tag == "intersection" then
		local s = "In["
		for i = 1, #t.parts do
			local v = t.parts[i]
			if v ~= nil then
				if i > 1 then s = s .. "," end
				s = s .. key_of(v)
			end
		end
		return s .. "]"
	end
	return "?:" .. tostring(t.tag)
end

M.key_of = key_of

-- Flatten + sort + dedupe a list of intersection parts.  Nested
-- TIntersections within the list are flattened recursively.  Returns a
-- fresh sorted/deduped part list.  Callers with a TIntersection in hand
-- pass `t.parts` (the part list field), not the TIntersection itself.
--: (V5Type[]) -> V5Type[]
function M.flatten_parts(parts)
	local raw = {} --[[: V5Type[] ]]
	--: (V5Type) -> nil
	local function walk(t)
		if t.tag == "intersection" then
			for i = 1, #t.parts do
				local v = t.parts[i]
				if v ~= nil then walk(v) end
			end
		else
			raw[#raw + 1] = t
		end
	end
	for i = 1, #parts do
		local v = parts[i]
		if v ~= nil then walk(v) end
	end
	-- Sort by key.
	for i = 2, #raw do
		local cur = raw[i]
		local cur_k = cur and key_of(cur) or ""
		local j = i - 1
		while j >= 1 and raw[j] ~= nil and cur ~= nil and key_of(raw[j]) > cur_k do
			raw[j + 1] = raw[j]; j = j - 1
		end
		if cur ~= nil then raw[j + 1] = cur end
	end
	-- Dedupe (sorted, so identical keys are adjacent).
	local out = {} --[[: V5Type[] ]]
	local prev_k = nil --[[: string | nil ]]
	for i = 1, #raw do
		local v = raw[i]
		if v ~= nil then
			local k = key_of(v)
			if k ~= prev_k then
				out[#out + 1] = v
				prev_k = k
			end
		end
	end
	return out
end

-- Returns true iff two part lists (already canonicalized) are part-wise
-- equal under types_mod.equal.
--: (V5Type[], V5Type[]) -> boolean
function M.parts_equal(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		local av = a[i]; local bv = b[i]
		if av == nil or bv == nil then return false end
		if not types_mod.equal(av, bv) then return false end
	end
	return true
end

-- Returns true iff every part in `sub` appears (under types_mod.equal) in
-- `super`.  Both lists assumed canonicalized.
--: (V5Type[], V5Type[]) -> boolean
function M.parts_subset(sub, super)
	for i = 1, #sub do
		local s = sub[i]
		if s == nil then return false end
		local found = false
		for j = 1, #super do
			local p = super[j]
			if p ~= nil and types_mod.equal(s, p) then found = true; break end
		end
		if not found then return false end
	end
	return true
end

--:: Provenance = { file: string, line: integer, col: integer, kind: string }
--:: ConstraintEq         = { id: integer, tag: "ceq", a: V5Type, b: V5Type, prov: Provenance }
--:: ConstraintSub        = { id: integer, tag: "csub", a: V5Type, b: V5Type, prov: Provenance }
--:: ConstraintTableOpen  = { id: integer, tag: "topen", tv: integer, prov: Provenance }
--:: ConstraintTableSet   = { id: integer, tag: "tset", tv: integer, key: string, ty: V5Type, prov: Provenance }
--:: ConstraintTableSeal  = { id: integer, tag: "tseal", tv: integer, mu: integer | nil, prov: Provenance }
--:: ConstraintMethodCall = { id: integer, tag: "mcall", tv: integer, key: string, ret: integer, prov: Provenance }
--:: ConstraintRowExtend  = { id: integer, tag: "crow_extend", record_ty: V5Type, key: string, field_ty: V5Type, prov: Provenance }
--:: ConstraintRowLacks   = { id: integer, tag: "crow_lacks", record_ty: V5Type, key: string, prov: Provenance }
--:: ConstraintRowClose   = { id: integer, tag: "crow_close", record_ty: V5Type, prov: Provenance }
--:: ConstraintIntEq      = { id: integer, tag: "cint_eq", parts_a: V5Type[], parts_b: V5Type[], prov: Provenance }
--:: ConstraintIntSub     = { id: integer, tag: "cint_sub", parts_sub: V5Type[], parts_super: V5Type[], prov: Provenance }
--:: ConstraintIntMember  = { id: integer, tag: "cint_member", ty: V5Type, part: V5Type, prov: Provenance }
--:: V5Constraint = ConstraintEq | ConstraintSub | ConstraintTableOpen | ConstraintTableSet | ConstraintTableSeal | ConstraintMethodCall | ConstraintRowExtend | ConstraintRowLacks | ConstraintRowClose | ConstraintIntEq | ConstraintIntSub | ConstraintIntMember

local _next_id = 1 --[[: integer ]]

--: () -> integer
local function fresh_id()
	local i = _next_id
	_next_id = i + 1
	return i
end

-- Reset id counter (per benchmark run, to keep ids dense).
--: () -> nil
function M.reset_ids() _next_id = 1 end

--: (V5Type, V5Type, Provenance) -> V5Constraint
function M.eq(a, b, prov)
	return { id = fresh_id(), tag = "ceq", a = a, b = b, prov = prov }
end
--: (V5Type, V5Type, Provenance) -> V5Constraint
function M.sub(a, b, prov)
	return { id = fresh_id(), tag = "csub", a = a, b = b, prov = prov }
end
--: (integer, Provenance) -> V5Constraint
function M.table_open(tv, prov)
	return { id = fresh_id(), tag = "topen", tv = tv, prov = prov }
end
--: (integer, string, V5Type, Provenance) -> V5Constraint
function M.table_set(tv, key, ty, prov)
	return { id = fresh_id(), tag = "tset", tv = tv, key = key, ty = ty, prov = prov }
end
--: (integer, integer | nil, Provenance) -> V5Constraint
function M.table_seal(tv, mu, prov)
	return { id = fresh_id(), tag = "tseal", tv = tv, mu = mu, prov = prov }
end
--: (integer, string, integer, Provenance) -> V5Constraint
function M.method_call(tv, key, ret, prov)
	return { id = fresh_id(), tag = "mcall", tv = tv, key = key, ret = ret, prov = prov }
end

-- CRowExtend: record's row contains key with given field type.
--: (V5Type, string, V5Type, Provenance) -> V5Constraint
function M.row_extend(record_ty, key, field_ty, prov)
	return { id = fresh_id(), tag = "crow_extend", record_ty = record_ty, key = key, field_ty = field_ty, prov = prov }
end

-- CRowLacks: record's row does NOT contain key.
-- Parks while row var is unbound; errors at quiescence if still unbound.
--: (V5Type, string, Provenance) -> V5Constraint
function M.row_lacks(record_ty, key, prov)
	return { id = fresh_id(), tag = "crow_lacks", record_ty = record_ty, key = key, prov = prov }
end

-- CRowClose: record's row variable becomes closed (no further extension).
--: (V5Type, Provenance) -> V5Constraint
function M.row_close(record_ty, prov)
	return { id = fresh_id(), tag = "crow_close", record_ty = record_ty, prov = prov }
end

-- CIntersectionEq: set-equality of two intersection part lists.
--: (V5Type[], V5Type[], Provenance) -> V5Constraint
function M.intersection_eq(parts_a, parts_b, prov)
	return { id = fresh_id(), tag = "cint_eq", parts_a = parts_a, parts_b = parts_b, prov = prov }
end

-- CIntersectionSub: subset/subtype direction on intersection part lists.
--: (V5Type[], V5Type[], Provenance) -> V5Constraint
function M.intersection_sub(parts_sub, parts_super, prov)
	return { id = fresh_id(), tag = "cint_sub", parts_sub = parts_sub, parts_super = parts_super, prov = prov }
end

-- CIntersectionMember: does ty contain `part` among its intersection parts?
--: (V5Type, V5Type, Provenance) -> V5Constraint
function M.intersection_member(ty, part, prov)
	return { id = fresh_id(), tag = "cint_member", ty = ty, part = part, prov = prov }
end

--: (string, integer, integer, string) -> Provenance
function M.prov(file, line, col, kind)
	return { file = file, line = line, col = col, kind = kind }
end

return M
