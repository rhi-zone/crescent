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

local _types = require("lib.type.experiments.v5_perf.types")
local _ = _types -- silence unused-import linter; the require pulls V5Type alias

local M = {}

--:: Provenance = { file: string, line: integer, kind: string }
--:: ConstraintEq         = { id: integer, tag: "ceq", a: V5Type, b: V5Type, prov: Provenance }
--:: ConstraintSub        = { id: integer, tag: "csub", a: V5Type, b: V5Type, prov: Provenance }
--:: ConstraintTableOpen  = { id: integer, tag: "topen", tv: integer, prov: Provenance }
--:: ConstraintTableSet   = { id: integer, tag: "tset", tv: integer, key: string, ty: V5Type, prov: Provenance }
--:: ConstraintTableSeal  = { id: integer, tag: "tseal", tv: integer, mu: integer | nil, prov: Provenance }
--:: ConstraintMethodCall = { id: integer, tag: "mcall", tv: integer, key: string, ret: integer, prov: Provenance }
--:: ConstraintRowExtend  = { id: integer, tag: "crow_extend", record_ty: V5Type, key: string, field_ty: V5Type, prov: Provenance }
--:: ConstraintRowLacks   = { id: integer, tag: "crow_lacks", record_ty: V5Type, key: string, prov: Provenance }
--:: ConstraintRowClose   = { id: integer, tag: "crow_close", record_ty: V5Type, prov: Provenance }
--:: V5Constraint = ConstraintEq | ConstraintSub | ConstraintTableOpen | ConstraintTableSet | ConstraintTableSeal | ConstraintMethodCall | ConstraintRowExtend | ConstraintRowLacks | ConstraintRowClose

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

--: (string, integer, string) -> Provenance
function M.prov(file, line, kind)
	return { file = file, line = line, kind = kind }
end

return M
