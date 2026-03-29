-- lib/type/static/fuzz_arb.lua
-- String-level Lua source fragment generators for typechecker fuzz testing.
--
-- These generators produce Lua source strings (or type annotation strings),
-- not AST nodes. They are used by fuzz_test.lua to construct random programs
-- and check type system invariants.
--
-- API:
--   arb_base_type(rng)         -> type string: "integer"|"number"|"string"|"boolean"
--   arb_value_of_type(rng, T)  -> Lua literal string matching type T
--   arb_distinct_types(rng)    -> A, B  where A ~= B (both base types)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Base types ────────────────────────────────────────────────────────────────

local BASE_TYPES = { "integer", "number", "string", "boolean" }

-- arb_base_type: pick one of the four base types uniformly.
-- Returns a type annotation string.
function M.arb_base_type(rng)
	return BASE_TYPES[rng:int(1, #BASE_TYPES)]
end

-- Pairs of types with no subtyping relationship in either direction.
-- integer ⊆ number (integer is assignable to number), so that pair is excluded.
-- All other cross-kind pairs are mutually incompatible.
local INCOMPATIBLE_PAIRS = {
	{ "string",  "integer" },
	{ "string",  "number"  },
	{ "string",  "boolean" },
	{ "boolean", "integer" },
	{ "boolean", "number"  },
	{ "integer", "boolean" },
	{ "number",  "boolean" },
	{ "integer", "string"  },
	{ "number",  "string"  },
	{ "boolean", "string"  },
}

-- arb_distinct_types: pick two base types A, B with no subtyping relation.
-- Returns A, B.  Neither A nor B is any/unknown.
-- Invariant: a value of type B is NOT assignable where A is expected.
function M.arb_distinct_types(rng)
	local pair = INCOMPATIBLE_PAIRS[rng:int(1, #INCOMPATIBLE_PAIRS)]
	return pair[1], pair[2]
end

-- ── Value generators ──────────────────────────────────────────────────────────

-- Small pool of string literals that are valid Lua (no special escapes needed).
local STRING_LITERALS = {
	[["hello"]], [["world"]], [["foo"]], [["bar"]], [["baz"]],
	[["a"]], [["test"]], [["lua"]], [["crescent"]], [[""]],
	[["abc"]], [["xyz"]], [["1"]], [["true"]], [["nil"]],
}

-- arb_value_of_type: produce a Lua literal string whose type matches T.
-- T must be a base type string ("integer", "number", "string", "boolean").
function M.arb_value_of_type(rng, T)
	if T == "integer" then
		-- Random integer in [0, 100]; avoid negative literals for simplicity
		-- (unary minus may affect parsing in some annotation contexts).
		return tostring(rng:int(0, 100))
	elseif T == "number" then
		-- Floating-point literal — always non-integer so it stays TAG_NUMBER.
		-- We use a fixed fractional part to keep things simple.
		local n = rng:int(0, 99)
		return n .. ".5"
	elseif T == "string" then
		return STRING_LITERALS[rng:int(1, #STRING_LITERALS)]
	elseif T == "boolean" then
		return rng:bool() and "true" or "false"
	else
		error("arb_value_of_type: unknown type " .. tostring(T))
	end
end

return M
