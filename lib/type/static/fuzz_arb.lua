-- lib/type/static/fuzz_arb.lua
-- String-level Lua source fragment generators for typechecker fuzz testing.
--
-- These generators produce Lua source strings (or type annotation strings),
-- not AST nodes. They are used by fuzz_test.lua to construct random programs
-- and check type system invariants.
--
-- API:
--   arb_base_type(rng)              -> type string: "integer"|"number"|"string"|"boolean"
--   arb_type(rng, depth)            -> type annotation string (recursive, depth controls size)
--   arb_value_of_type(rng, T)       -> Lua literal string matching type T
--   arb_distinct_types(rng)         -> A, B  where a value of B is NOT assignable where A is expected
--   arb_table_type(rng, depth)      -> a table type string (record or indexer)

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

-- ── String/value pools ────────────────────────────────────────────────────────

-- Small pool of string literals that are valid Lua (no special escapes needed).
local STRING_LITERALS = {
	[["hello"]], [["world"]], [["foo"]], [["bar"]], [["baz"]],
	[["a"]], [["test"]], [["lua"]], [["crescent"]], [[""]],
	[["abc"]], [["xyz"]], [["one"]], [["two"]], [["three"]],
}

-- Field names for generated table records.
local FIELD_NAMES = { "x", "y", "z", "n", "s", "flag", "value", "name", "key", "data" }

-- ── Recursive type generator ──────────────────────────────────────────────────

-- arb_table_type: generate a table type string (record or string/integer indexer).
-- Used internally and exported for arb_distinct_types.
local function arb_table_type(rng, depth)
	local kind = rng:int(1, 3)
	if kind == 1 then
		-- Single-field record
		local field = FIELD_NAMES[rng:int(1, #FIELD_NAMES)]
		local vtype = M.arb_type(rng, depth - 1)
		return "{ " .. field .. ": " .. vtype .. " }"
	elseif kind == 2 then
		-- Two-field record
		local f1 = FIELD_NAMES[rng:int(1, #FIELD_NAMES)]
		-- Pick a second field name different from f1
		local f2
		repeat f2 = FIELD_NAMES[rng:int(1, #FIELD_NAMES)] until f2 ~= f1
		local t1 = M.arb_type(rng, depth - 1)
		local t2 = M.arb_type(rng, depth - 1)
		return "{ " .. f1 .. ": " .. t1 .. ", " .. f2 .. ": " .. t2 .. " }"
	else
		-- Indexer: [string]: T or [integer]: T
		local key = rng:bool() and "string" or "integer"
		local vtype = M.arb_type(rng, depth - 1)
		return "{ [" .. key .. "]: " .. vtype .. " }"
	end
end

M.arb_table_type = arb_table_type

-- arb_type: generate a random type annotation string.
-- depth starts at 3; at depth <= 0 always emits a base type.
-- Weighting: ~40% base types, ~60% complex types (when depth > 0).
function M.arb_type(rng, depth)
	if depth == nil then depth = 3 end

	-- At depth 0, only emit base types or literal types (no recursion).
	if depth <= 0 then
		local pick = rng:int(1, 8)
		if pick <= 3 then
			return BASE_TYPES[rng:int(1, #BASE_TYPES)]
		elseif pick == 4 then
			return "nil"
		elseif pick == 5 then
			return tostring(rng:int(0, 99))
		elseif pick == 6 then
			return STRING_LITERALS[rng:int(1, #STRING_LITERALS)]
		elseif pick == 7 then
			return "true"
		else
			return "false"
		end
	end

	-- Weighted choice: roll 1–10.
	-- 1–4 → base type kinds (40%)
	-- 5–10 → complex type kinds (60%)
	local roll = rng:int(1, 10)

	-- Base type (40%)
	if roll <= 3 then
		return BASE_TYPES[rng:int(1, #BASE_TYPES)]
	elseif roll == 4 then
		-- Literal types: integer literal, string literal, boolean literal, nil
		local lkind = rng:int(1, 4)
		if lkind == 1 then
			return tostring(rng:int(0, 99))
		elseif lkind == 2 then
			return STRING_LITERALS[rng:int(1, #STRING_LITERALS)]
		elseif lkind == 3 then
			return "true"
		else
			return "false"
		end

	-- Union (15%)
	elseif roll == 5 then
		local A = M.arb_type(rng, depth - 1)
		local B = M.arb_type(rng, depth - 1)
		return A .. " | " .. B

	-- Optional: T? (10%)
	elseif roll == 6 then
		local T = M.arb_type(rng, depth - 1)
		return T .. "?"

	-- Table (record or indexer) (15%)
	elseif roll == 7 then
		return arb_table_type(rng, depth)

	-- Function single-return (10%)
	elseif roll == 8 then
		local param = M.arb_type(rng, depth - 1)
		local ret   = M.arb_type(rng, depth - 1)
		return "(" .. param .. ") -> " .. ret

	-- Function multi-return (5%)
	elseif roll == 9 then
		local param = M.arb_type(rng, depth - 1)
		local r1    = M.arb_type(rng, depth - 1)
		local r2    = M.arb_type(rng, depth - 1)
		return "(" .. param .. ") -> (" .. r1 .. ", " .. r2 .. ")"

	-- Intersection of two table types (5%)
	else
		local A = arb_table_type(rng, depth - 1)
		local B = arb_table_type(rng, depth - 1)
		return A .. " & " .. B
	end
end

-- ── Value generator ───────────────────────────────────────────────────────────

-- Forward declaration for recursive calls.
local arb_value_of_type

-- Extract the return type from a function type string like "(A) -> B" or "(A) -> (B, C)".
-- Returns a simple type string to generate a value for, or nil on failure.
local function extract_ret_type(T)
	-- Find the last occurrence of " -> " to handle nested function types.
	local arrow_pos = nil
	local search_from = 1
	while true do
		local pos = T:find(" %-> ", search_from, false)
		if not pos then break end
		arrow_pos = pos
		search_from = pos + 1
	end
	if not arrow_pos then return nil end

	local ret_str = T:sub(arrow_pos + 4)  -- skip " -> "
	ret_str = ret_str:match("^%s*(.-)%s*$")  -- trim

	-- Multi-return wrapped in parens: (A, B) — take first return type.
	local inner = ret_str:match("^%((.-)%)$")
	if inner then
		-- Take just the first type before the comma.
		local first = inner:match("^([^,]+)")
		if first then
			return first:match("^%s*(.-)%s*$")
		end
		return inner
	end

	return ret_str
end

-- Parse a union "A | B" splitting at the top-level pipe (not inside parens/braces).
-- Returns A, B or nil if not a union.
local function split_union(T)
	local depth = 0
	for i = 1, #T do
		local c = T:sub(i, i)
		if c == "(" or c == "{" or c == "<" then
			depth = depth + 1
		elseif c == ")" or c == "}" or c == ">" then
			depth = depth - 1
		elseif c == "|" and depth == 0 then
			-- Check it's " | " (with spaces).
			if T:sub(i - 1, i - 1) == " " and T:sub(i + 1, i + 1) == " " then
				local A = T:sub(1, i - 2):match("^%s*(.-)%s*$")
				local B = T:sub(i + 2):match("^%s*(.-)%s*$")
				return A, B
			end
		end
	end
	return nil
end

-- arb_value_of_type: produce a Lua literal string whose type matches T.
-- Returns "nil" as fallback for unrecognized types.
arb_value_of_type = function(rng, T)
	if T == nil then return "nil" end

	-- Base types
	if T == "integer" then
		return tostring(rng:int(0, 100))
	elseif T == "number" then
		local n = rng:int(0, 99)
		return n .. ".5"
	elseif T == "string" then
		return STRING_LITERALS[rng:int(1, #STRING_LITERALS)]
	elseif T == "boolean" then
		return rng:bool() and "true" or "false"
	elseif T == "nil" then
		return "nil"
	end

	-- Boolean literals
	if T == "true" or T == "false" then
		return T
	end

	-- Integer literal (matches optional minus sign then digits only)
	if T:match("^%-?%d+$") then
		return T
	end

	-- String literal (starts with a double-quote)
	if T:match('^"') then
		return T
	end

	-- Optional: "T?" — strip the trailing ? to get T, then 50% nil, 50% value of T
	local opt_inner = T:match("^(.+)%?$")
	if opt_inner then
		if rng:bool() then
			return "nil"
		else
			return arb_value_of_type(rng, opt_inner)
		end
	end

	-- Union: "A | B" — pick one arm and generate a value for it.
	-- Handle " | nil" as a special optional form first.
	if T:find(" | nil", 1, true) then
		local base = T:gsub(" | nil", ""):match("^%s*(.-)%s*$")
		if rng:bool() then
			return "nil"
		else
			return arb_value_of_type(rng, base)
		end
	end
	if T:find("nil | ", 1, true) then
		local base = T:gsub("nil | ", ""):match("^%s*(.-)%s*$")
		if rng:bool() then
			return "nil"
		else
			return arb_value_of_type(rng, base)
		end
	end

	local union_A, union_B = split_union(T)
	if union_A and union_B then
		if rng:bool() then
			return arb_value_of_type(rng, union_A)
		else
			return arb_value_of_type(rng, union_B)
		end
	end

	-- Intersection: "A & B" — must be two table types; produce a merged table literal.
	-- We detect & at top level (outside parens/braces).
	local inter_A, inter_B
	do
		local depth = 0
		for i = 1, #T do
			local c = T:sub(i, i)
			if c == "(" or c == "{" or c == "<" then
				depth = depth + 1
			elseif c == ")" or c == "}" or c == ">" then
				depth = depth - 1
			elseif c == "&" and depth == 0 then
				if T:sub(i - 1, i - 1) == " " and T:sub(i + 1, i + 1) == " " then
					inter_A = T:sub(1, i - 2):match("^%s*(.-)%s*$")
					inter_B = T:sub(i + 2):match("^%s*(.-)%s*$")
					break
				end
			end
		end
	end
	if inter_A and inter_B then
		-- Simple strategy: produce a table literal that merges fields of both.
		-- Extract fields from each arm (look for "field: type" patterns inside braces).
		local function extract_field_pairs(tbl_str)
			local inner = tbl_str:match("^%{%s*(.-)%s*%}$")
			if not inner then return {} end
			local pairs_list = {}
			-- Match "name: type" entries (simple single-field tables only).
			for fname, ftype in inner:gmatch("(%a[%w_]*):%s*([^,}]+)") do
				pairs_list[#pairs_list + 1] = { fname, ftype:match("^%s*(.-)%s*$") }
			end
			return pairs_list
		end
		local fields_A = extract_field_pairs(inter_A)
		local fields_B = extract_field_pairs(inter_B)
		-- Merge fields, deduplicating by name.
		local seen = {}
		local entries = {}
		for _, fp in ipairs(fields_A) do
			if not seen[fp[1]] then
				seen[fp[1]] = true
				entries[#entries + 1] = fp[1] .. " = " .. arb_value_of_type(rng, fp[2])
			end
		end
		for _, fp in ipairs(fields_B) do
			if not seen[fp[1]] then
				seen[fp[1]] = true
				entries[#entries + 1] = fp[1] .. " = " .. arb_value_of_type(rng, fp[2])
			end
		end
		if #entries == 0 then
			-- Fallback: both may be indexers; produce a simple table
			return "{ }"
		end
		return "{ " .. table.concat(entries, ", ") .. " }"
	end

	-- Table record: "{ field: T }" or "{ f1: T1, f2: T2 }"
	local tbl_inner = T:match("^%{%s*(.-)%s*%}$")
	if tbl_inner then
		-- Check for indexer: [key]: value
		local key_type, val_type_str = tbl_inner:match("^%[(%a+)%]:%s*(.+)$")
		if key_type and val_type_str then
			val_type_str = val_type_str:match("^%s*(.-)%s*$")
			local val = arb_value_of_type(rng, val_type_str)
			if key_type == "string" then
				return '{ ["k"] = ' .. val .. " }"
			else
				-- integer indexer
				return "{ " .. val .. " }"
			end
		end

		-- Named fields: collect "name: type" pairs.
		local field_entries = {}
		for fname, ftype in tbl_inner:gmatch("(%a[%w_]*):%s*([^,}]+)") do
			ftype = ftype:match("^%s*(.-)%s*$")
			field_entries[#field_entries + 1] = fname .. " = " .. arb_value_of_type(rng, ftype)
		end
		if #field_entries > 0 then
			return "{ " .. table.concat(field_entries, ", ") .. " }"
		end
		-- Empty or unrecognized table shape
		return "{ }"
	end

	-- Function type: any "(…) -> …" pattern.
	-- Generate a function literal that returns a value of the return type.
	if T:find(" -> ", 1, true) or T:match("^%(.*%)") then
		local ret_type = extract_ret_type(T)
		local ret_val
		if ret_type then
			ret_val = arb_value_of_type(rng, ret_type)
		else
			ret_val = "nil"
		end
		return "function() return " .. ret_val .. " end"
	end

	-- Fallback: nil (useful signal that generator encountered an unknown shape)
	return "nil"
end

M.arb_value_of_type = arb_value_of_type

-- ── Distinct types ────────────────────────────────────────────────────────────

-- Categories of types with no subtyping between categories.
-- integer ⊆ number so they share a category; we never pair within a category.
--
-- Categories:
--   1 = numeric  (integer, number, integer-literal)
--   2 = string   (string, string-literal)
--   3 = boolean  (boolean, true, false)
--   4 = table-record
--   5 = table-indexer
--   6 = function-type

local CATEGORY_COUNT = 6

local function arb_type_in_category(rng, cat, depth)
	if cat == 1 then
		local pick = rng:int(1, 3)
		if pick == 1 then return "integer"
		elseif pick == 2 then return "number"
		else return tostring(rng:int(0, 49))
		end
	elseif cat == 2 then
		if rng:bool() then
			return "string"
		else
			return STRING_LITERALS[rng:int(1, #STRING_LITERALS)]
		end
	elseif cat == 3 then
		local pick = rng:int(1, 3)
		if pick == 1 then return "boolean"
		elseif pick == 2 then return "true"
		else return "false"
		end
	elseif cat == 4 then
		-- Table record
		local field = FIELD_NAMES[rng:int(1, #FIELD_NAMES)]
		local vtype = BASE_TYPES[rng:int(1, #BASE_TYPES)]
		return "{ " .. field .. ": " .. vtype .. " }"
	elseif cat == 5 then
		-- Table indexer
		local key = rng:bool() and "string" or "integer"
		local vtype = BASE_TYPES[rng:int(1, #BASE_TYPES)]
		return "{ [" .. key .. "]: " .. vtype .. " }"
	else
		-- Function type
		local param = BASE_TYPES[rng:int(1, #BASE_TYPES)]
		local ret   = BASE_TYPES[rng:int(1, #BASE_TYPES)]
		return "(" .. param .. ") -> " .. ret
	end
end

-- arb_distinct_types: pick two types A, B from DIFFERENT structural categories.
-- A value of type B is definitely NOT assignable where A is expected.
function M.arb_distinct_types(rng)
	local cat_A = rng:int(1, CATEGORY_COUNT)
	local cat_B
	repeat cat_B = rng:int(1, CATEGORY_COUNT) until cat_B ~= cat_A
	local A = arb_type_in_category(rng, cat_A, 2)
	local B = arb_type_in_category(rng, cat_B, 2)
	return A, B
end

return M
