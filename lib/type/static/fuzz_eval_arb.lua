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
--: ({ float: () -> number, ... }, { [integer]: string, ... }) -> string
local function pick(rng, t)
	return t[math.floor(rng:float() * #t) + 1] --[[:! string]]
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
		local name    = names[i] --[[:! string]]
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

-- arb_union_base: generate a union of two distinct base types.
-- Returns { lhs, rhs, type_str } where lhs and rhs are distinct base type strings
-- and type_str is "A | B". Never generates `any`.
function M.arb_union_base(rng, size)
	local bases = { "integer", "number", "string", "boolean" }
	local i = math.floor(rng:float() * 4) + 1
	local j
	repeat j = math.floor(rng:float() * 4) + 1 until j ~= i
	return {
		lhs = bases[i] --[[:! string]],
		rhs = bases[j] --[[:! string]],
		type_str = (bases[i] --[[:! string]]) .. " | " .. (bases[j] --[[:! string]])
	}
end

-- arb_function_parts: generate a function type broken into parts.
-- Returns a table: { params = string[], ret = string, type_str = string }
-- 0–3 params (all base types), return type is a base type.
-- Never generates `any`.
function M.arb_function_parts(rng, size)
	local n_params = math.floor(rng:float() * math.min(4, (size or 3) + 1))  -- 0 to 3
	local params = {}
	for i = 1, n_params do
		params[i] = M.arb_base_type(rng)
	end
	local ret = M.arb_base_type(rng)
	local type_str
	if n_params == 0 then
		type_str = "() -> " .. ret
	else
		type_str = "(" .. table.concat(params, ", ") .. ") -> " .. ret
	end
	return { params = params, ret = ret, type_str = type_str }
end

-- arb_function_type: generate a function type annotation string: "(A, B) -> C".
-- 0–3 params (all base types), return type is a base type.
-- Never generates `any`.
function M.arb_function_type(rng, size)
	return M.arb_function_parts(rng, size).type_str
end

-- arb_base_type_quad: pick all 4 base types in a random order.
-- Returns { a, b, c, d } — all four of integer/number/string/boolean, all distinct.
-- Used to build match arms with no ambiguity (each arm key is unique).
function M.arb_base_type_quad(rng)
	local bases = { "integer", "number", "string", "boolean" }
	-- Fisher-Yates shuffle
	for i = 4, 2, -1 do
		local j = math.floor(rng:float() * i) + 1
		bases[i], bases[j] = bases[j], bases[i]
	end
	return { a = bases[1], b = bases[2], c = bases[3], d = bases[4] }
end

return M
