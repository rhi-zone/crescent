-- lib/type/static/fuzz_eval_arb.lua
-- Eval-tier generators: produce annotation strings for simple closed table types.
-- Used by fuzz_eval.lua to test type-level computation contracts.
--
-- Key constraint: NEVER generate `any` — any <: T and T <: any for all T,
-- making bidirectional equivalence assertions trivially true/meaningless.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Field name and base type pools (no `any` ever).
local FIELD_NAMES = { "x", "y", "z", "n", "s" }
local BASE_TYPES  = { "integer", "string", "boolean", "number" }

-- Pick a random element from a table using rng:float().
local function pick(rng, t)
	return t[math.floor(rng:float() * #t) + 1]
end

-- arb_base_type: generate a random base type string (never `any`).
function M.arb_base_type(rng)
	return pick(rng, BASE_TYPES)
end

-- arb_table_type: generate a random closed table type annotation string.
-- Produces 1–3 fields with distinct names.
-- Each field has a 20% chance of being optional (adds "?") and a 10% chance
-- of being readonly (prepends "readonly ").
-- Returns the annotation string, e.g. '{ x: integer, y?: string }'.
function M.arb_table_type(rng, size)
	size = size or 3
	local max_fields = math.max(1, math.min(3, size))
	local n = math.floor(rng:float() * max_fields) + 1  -- 1..max_fields

	-- Shuffle field names pool so we get distinct names
	local names = {}
	for i = 1, #FIELD_NAMES do names[i] = FIELD_NAMES[i] end
	for i = #names, 2, -1 do
		local j = math.floor(rng:float() * i) + 1
		names[i], names[j] = names[j], names[i]
	end

	local fields = {}
	for i = 1, n do
		local name    = names[i]
		local base    = pick(rng, BASE_TYPES)
		local optional = rng:float() < 0.20
		local readonly = rng:float() < 0.10
		local opt_str  = optional and "?" or ""
		local ro_str   = readonly and "readonly " or ""
		fields[i] = ro_str .. name .. opt_str .. ": " .. base
	end
	return "{ " .. table.concat(fields, ", ") .. " }"
end

-- arb_union_table: generate a union of two table type strings.
-- Returns e.g. '{ x: integer } | { y: string }'.
function M.arb_union_table(rng, size)
	local t1 = M.arb_table_type(rng, size)
	local t2 = M.arb_table_type(rng, size)
	return t1 .. " | " .. t2
end

return M
