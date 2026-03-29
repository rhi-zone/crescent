-- lib/type/static/fuzz_arb.lua
-- Structured type AST generators with arb.lua integration.
--
-- Type AST nodes (plain tables):
--   { tag="base",     name="integer"|"number"|"string"|"boolean" }
--   { tag="nil" }
--   { tag="lit_int",  value=n }
--   { tag="lit_str",  value='"..."' }     -- value includes surrounding quotes
--   { tag="lit_bool", value=true|false }
--   { tag="union",    a=node, b=node }
--   { tag="inter",    a=node, b=node }
--   { tag="func",     params={node,...}, ret=node }   -- ret may be a tuple node
--   { tag="tuple",    types={node,...} }              -- multi-return, only in ret position
--   { tag="record",   fields={{name=str, type=node},...} }
--   { tag="indexer",  key="string"|"integer", val=node }
--
-- API:
--   M.type_to_string(node)           -> annotation string (precedence-correct)
--   M.arb_type                       -> arb generator for type AST nodes (with shrinking)
--   M.arb_base_type                  -> arb generator: one of the four base types
--   M.arb_type_leaf                  -> arb generator: base types + literals + nil
--   M.canonical_value(node)          -> a fixed Lua literal string matching the type
--   M.arb_value_for(node)            -> arb generator for Lua literal strings of that type
--   M.arb_distinct_base_types        -> arb generator: {A,B} where B is not <: A

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local arb = require("lib.test.arb")

local M = {}

-- ── Precedence-aware serializer ───────────────────────────────────────────────
-- Precedence values (lower = lower precedence = outermost in expression):
--   -> (func) = 10 < | (union) = 20 < & (inter) = 30 < atoms = ∞
--
-- A node needs parens when its precedence < the outer context's precedence.
-- This ensures (A) -> B used in a union becomes ((A) -> B) | C, and
-- (A | B) used in an intersection becomes (A | B) & C.

local PREC_FUNC  = 10
local PREC_UNION = 20
local PREC_INTER = 30

local function to_str(node, outer)
	outer = outer or 0
	local s, p

	if     node.tag == "base"     then return node.name
	elseif node.tag == "nil"      then return "nil"
	elseif node.tag == "never"    then return "never"
	elseif node.tag == "unknown"  then return "unknown"
	elseif node.tag == "lit_int"  then return tostring(node.value)
	elseif node.tag == "lit_str"  then return node.value   -- includes surrounding quotes
	elseif node.tag == "lit_bool" then return node.value and "true" or "false"
	elseif node.tag == "union" then
		p = PREC_UNION
		s = to_str(node.a, p) .. " | " .. to_str(node.b, p)
	elseif node.tag == "inter" then
		p = PREC_INTER
		s = to_str(node.a, p) .. " & " .. to_str(node.b, p)
	elseif node.tag == "func" then
		p = PREC_FUNC
		local parts = {}
		for _, param in ipairs(node.params) do
			parts[#parts + 1] = to_str(param, 0)
		end
		local ret_s
		if node.ret.tag == "tuple" then
			local rt = {}
			for _, r in ipairs(node.ret.types) do rt[#rt + 1] = to_str(r, 0) end
			ret_s = "(" .. table.concat(rt, ", ") .. ")"
		else
			ret_s = to_str(node.ret, 0)
		end
		s = "(" .. table.concat(parts, ", ") .. ") -> " .. ret_s
	elseif node.tag == "record" then
		local entries = {}
		for _, f in ipairs(node.fields) do
			entries[#entries + 1] = f.name .. ": " .. to_str(f.type, 0)
		end
		return "{ " .. table.concat(entries, ", ") .. " }"
	elseif node.tag == "indexer" then
		return "{ [" .. node.key .. "]: " .. to_str(node.val, 0) .. " }"
	else
		return "unknown"
	end

	if p and p < outer then return "(" .. s .. ")" end
	return s
end

M.type_to_string = to_str

-- ── Singleton constants ───────────────────────────────────────────────────────

M.T_INTEGER = { tag = "base",    name = "integer" }
M.T_NUMBER  = { tag = "base",    name = "number"  }
M.T_STRING  = { tag = "base",    name = "string"  }
M.T_BOOLEAN = { tag = "base",    name = "boolean" }
M.T_NIL     = { tag = "nil" }
M.T_NEVER   = { tag = "never" }
M.T_UNKNOWN = { tag = "unknown" }
M.T_TRUE    = { tag = "lit_bool", value = true  }
M.T_FALSE   = { tag = "lit_bool", value = false }

-- ── Pools ─────────────────────────────────────────────────────────────────────

local STRING_LITS = {
	'"hello"', '"world"', '"foo"', '"bar"', '"baz"',
	'"a"', '"test"', '"lua"', '"crescent"', '""',
	'"abc"', '"xyz"',
}

local FIELD_NAMES = { "x", "y", "z", "n", "s", "flag", "value", "name", "key", "data" }

-- ── arb_base_type ─────────────────────────────────────────────────────────────
-- Uniform over the four base types (integer, number, string, boolean).

M.arb_base_type = arb.one_of({
	arb.constant(M.T_INTEGER),
	arb.constant(M.T_NUMBER),
	arb.constant(M.T_STRING),
	arb.constant(M.T_BOOLEAN),
})

-- ── arb_type_leaf ─────────────────────────────────────────────────────────────
-- Atoms only: base types, literal types, nil. No recursion.

M.arb_type_leaf = arb.frequency({
	{ 4, arb.constant(M.T_INTEGER) },
	{ 4, arb.constant(M.T_NUMBER)  },
	{ 4, arb.constant(M.T_STRING)  },
	{ 4, arb.constant(M.T_BOOLEAN) },
	{ 1, arb.constant(M.T_NIL)     },
	{ 1, arb.constant(M.T_NEVER)   },
	{ 1, arb.constant(M.T_UNKNOWN) },
	{ 2, arb.map(arb.int(0, 99), function(n)
			return { tag = "lit_int", value = n }
		end) },
	{ 2, arb.map(arb.int(1, #STRING_LITS), function(i)
			return { tag = "lit_str", value = STRING_LITS[i] }
		end) },
	{ 1, arb.constant(M.T_TRUE)  },
	{ 1, arb.constant(M.T_FALSE) },
})

-- ── arb_type (recursive) ──────────────────────────────────────────────────────
-- Depth-limited via arb.sized. At size 0: only atoms. At size N: all forms.
-- Sub-types are generated at size N-1 to ensure termination.
--
-- Forward reference needed for self-recursion.

local arb_type       -- assigned below
local arb_type_lazy = {   -- thin proxy, resolved after assignment
	generate = function(rng, sz) return arb_type.generate(rng, sz) end,
	shrink   = function(v, c)   return arb_type.shrink(v, c) end,
}

-- arb_field_name: uniform over field name pool (shrinks toward index 1 = "x")
local arb_field_name = arb.map(
	arb.int(1, #FIELD_NAMES),
	function(i) return FIELD_NAMES[i] end
)

arb_type = arb.sized(function(size)
	if size <= 0 then return M.arb_type_leaf end

	-- Halve the size budget at each level so the total number of AST nodes grows
	-- as O(size) rather than O(branching^size).  With sub_size = size - 1 and
	-- branching factor up to 3, size=64 produces ~3^64 nodes (catastrophic).
	-- With halving, max depth = floor(log2(size)) ≈ 6 at size=64, and total
	-- nodes are bounded by 3^6 = 729.  Grammar-level tests must parse the type
	-- string, so string length must stay manageable.
	local sub_size = math.max(0, math.floor(size / 2))
	-- sub: delegates to arb_type_lazy at reduced size
	local sub = {
		generate = function(rng, _) return arb_type_lazy.generate(rng, sub_size) end,
		shrink   = arb_type_lazy.shrink,
	}

	-- Single-field record: { name: T }
	local arb_record1 = arb.map(
		arb.tuple({ arb_field_name, sub }),
		function(p)
			return { tag = "record", fields = { { name = p[1], type = p[2] } } }
		end
	)

	-- Two-field record: { name1: T1, name2: T2 } — collapses to one field if names collide
	local arb_record2 = arb.map(
		arb.tuple({ arb_field_name, sub, arb_field_name, sub }),
		function(q)
			if q[1] == q[3] then
				-- Colliding names: just use the first field
				return { tag = "record", fields = { { name = q[1], type = q[2] } } }
			end
			return { tag = "record", fields = {
				{ name = q[1], type = q[2] },
				{ name = q[3], type = q[4] },
			}}
		end
	)

	-- Indexer: [string|integer]: T
	local arb_indexer = arb.map(
		arb.tuple({ arb.bool, sub }),
		function(p)
			return { tag = "indexer", key = p[1] and "string" or "integer", val = p[2] }
		end
	)

	-- Single-return function: (P) -> R
	local arb_func1 = arb.map(
		arb.tuple({ sub, sub }),
		function(p) return { tag = "func", params = { p[1] }, ret = p[2] } end
	)

	-- Multi-return function: (P) -> (R1, R2)
	local arb_func2 = arb.map(
		arb.tuple({ sub, sub, sub }),
		function(t)
			return { tag = "func", params = { t[1] },
			         ret = { tag = "tuple", types = { t[2], t[3] } } }
		end
	)

	return arb.frequency({
		{ 10, M.arb_type_leaf },
		{  4, arb.map(arb.tuple({ sub, sub }),
				function(p) return { tag = "union", a = p[1], b = p[2] } end) },
		{  3, arb.map(arb.tuple({ sub, sub }),
				function(p) return { tag = "inter", a = p[1], b = p[2] } end) },
		{  4, arb_record1 },
		{  2, arb_record2 },
		{  2, arb_indexer },
		{  3, arb_func1   },
		{  1, arb_func2   },
	})
end)

M.arb_type = arb_type

-- ── arb_type_deep (algebra-level only) ────────────────────────────────────────
-- Like arb_type but uses sub_size = size - 1 to generate deeper type trees.
-- Safe ONLY for algebra-level tests (fuzz_alg.lua) where types are constructed
-- as IDs rather than parsed as strings — no exponential string blowup risk.
-- Capped at sub_size = min(size-1, 8) to bound node count (2^8 = 256 per trial).
-- Produces deeper intersection-of-union structures that arb_type under-tests.

local arb_type_deep       -- assigned below
local arb_type_deep_lazy = {
	generate = function(rng, sz) return arb_type_deep.generate(rng, sz) end,
	shrink   = function(v, c)   return arb_type_deep.shrink(v, c) end,
}

arb_type_deep = arb.sized(function(size)
	if size <= 0 then return M.arb_type_leaf end
	-- Use size-1 for deeper trees, but cap at 8 to prevent 2^N node blowup.
	local sub_size = math.max(0, math.min(size - 1, 8))
	local sub = {
		generate = function(rng, _) return arb_type_deep_lazy.generate(rng, sub_size) end,
		shrink   = arb_type_deep_lazy.shrink,
	}
	return arb.frequency({
		{  8, M.arb_type_leaf },
		{  5, arb.map(arb.tuple({ sub, sub }),
				function(p) return { tag = "union", a = p[1], b = p[2] } end) },
		{  4, arb.map(arb.tuple({ sub, sub }),
				function(p) return { tag = "inter", a = p[1], b = p[2] } end) },
		{  2, arb.map(arb.tuple({ sub, sub }),
				function(p) return { tag = "func", params = { p[1] }, ret = p[2] } end) },
	})
end)

M.arb_type_deep = arb_type_deep

-- ── Value generators ──────────────────────────────────────────────────────────

-- canonical_value: a fixed Lua literal for a leaf type node.
-- Returns "nil" for complex types (union, func, table) — callers should restrict
-- value-based invariants to base/literal types.
function M.canonical_value(node)
	if node.tag == "base" then
		local n = node.name
		if     n == "integer" then return "42"
		elseif n == "number"  then return "3.5"
		elseif n == "string"  then return '"hello"'
		elseif n == "boolean" then return "true"
		end
	elseif node.tag == "nil"      then return "nil"
	elseif node.tag == "lit_int"  then return tostring(node.value)
	elseif node.tag == "lit_str"  then return node.value
	elseif node.tag == "lit_bool" then return node.value and "true" or "false"
	end
	return "nil"
end

-- arb_value_for: arb generator for Lua literal strings matching a leaf type node.
-- For complex types, generates "nil" (conservative fallback).
function M.arb_value_for(node)
	if node.tag == "base" then
		local n = node.name
		if n == "integer" then
			return arb.map(arb.int(0, 100), function(v) return tostring(v) end)
		elseif n == "number" then
			return arb.map(arb.int(0, 99), function(v) return v .. ".5" end)
		elseif n == "string" then
			return arb.map(arb.int(1, #STRING_LITS), function(i) return STRING_LITS[i] end)
		elseif n == "boolean" then
			return arb.map(arb.bool, function(b) return b and "true" or "false" end)
		end
	elseif node.tag == "nil"      then return arb.constant("nil")
	elseif node.tag == "lit_int"  then return arb.constant(tostring(node.value))
	elseif node.tag == "lit_str"  then return arb.constant(node.value)
	elseif node.tag == "lit_bool" then
		return arb.constant(node.value and "true" or "false")
	end
	return arb.constant("nil")
end

-- ── Distinct types ────────────────────────────────────────────────────────────

-- is_subtype_base: true if B is a subtype of A among base types.
-- The only non-reflexive subtyping among bases: integer <: number.
local function is_subtype_base(B_node, A_node)
	if B_node.tag ~= "base" or A_node.tag ~= "base" then return false end
	local B, A = B_node.name, A_node.name
	if B == A then return true end
	if B == "integer" and A == "number" then return true end
	return false
end

-- arb_distinct_base_types: generates {A, B} pairs where B is NOT a subtype of A.
-- Used for "wrong arg rejected" invariants.
M.arb_distinct_base_types = arb.filter(
	arb.tuple({ M.arb_base_type, M.arb_base_type }),
	function(pair)
		return not is_subtype_base(pair[2], pair[1])
	end
)

return M
