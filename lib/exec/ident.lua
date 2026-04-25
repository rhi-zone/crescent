-- lib/exec/ident.lua
-- Normalize CLI flag/subcommand names to valid Lua identifiers.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Lua 5.1/LuaJIT reserved words.
local RESERVED = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
	["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
	["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true, ["while"] = true,
}

-- Returns true if s is a valid Lua identifier.
--: (string) -> boolean
function M.is_valid_ident(s)
	if s == "" then return false end
	if not s:match("^[%a_][%w_]*$") then return false end
	-- Reserved words are not valid identifiers for our purposes (caller cannot
	-- use them as field names without quoting).
	if RESERVED[s] then return false end
	return true
end

-- Normalize a single name. Index is the 1-based position in the original
-- list, used as fallback for empty results. Pass 1 if calling standalone.
--: (string, integer) -> string
function M.normalize_one(name, index)
	-- Step 1: strip leading -- or -
	--: string
	local stripped = name:match("^%-%-(.*)$") or name:match("^%-(.*)$") or name

	-- Remember whether original (stripped) starts/ends with underscore,
	-- to decide whether to strip synthetic leading/trailing underscores later.
	local starts_with_underscore = stripped:sub(1, 1) == "_"
	local ends_with_underscore   = stripped:sub(-1) == "_"

	-- Step 2: escape existing underscores (replace _ with __)
	--: string
	local s1 = stripped:gsub("_", "__")

	-- Step 3: replace runs of non-alphanumeric non-underscore chars with single _
	--: string
	local s2 = s1:gsub("[^%w_]+", "_")

	-- Step 4: lowercase
	--: string
	local s3 = s2:lower()

	-- Step 5a: strip synthetic leading single underscore.
	-- A leading _ was injected by step 3 only if the original (after prefix
	-- strip) did NOT start with _. Escaped originals produce __ so they are safe.
	--: string
	local s4 = s3
	if not starts_with_underscore then
		--: string
		local t = s3:gsub("^_([^_])", "%1")
		if t == "_" then t = "" end
		s4 = t
	end

	-- Step 5b: strip synthetic trailing single underscore.
	--: string
	local s5 = s4
	if not ends_with_underscore then
		--: string
		local t = s4:gsub("([^_])_$", "%1")
		if t == "_" then t = "" end
		s5 = t
	end

	-- Step 6: empty result fallback
	if s5 == "" then
		return "_" .. tostring(index)
	end

	-- Step 7: digit start → prefix _
	--: string
	local s6 = s5
	if s5:match("^%d") then
		s6 = "_" .. s5
	end

	-- Step 8: reserved word → append _
	if RESERVED[s6] then
		return s6 .. "_"
	end

	return s6
end

-- Normalize a list of raw CLI names to valid Lua identifiers.
-- Returns a table mapping each raw name to its normalized identifier.
-- Guaranteed: all values are valid Lua identifiers, all values are distinct.
--: (string[]) -> { [string]: string }
function M.normalize(names)
	-- Step 1: deduplicate, keeping first occurrence and recording original index.
	local seen_raw   = {}  -- raw -> true
	local unique     = {}  -- list of {raw, index} in first-seen order
	for i, name in ipairs(names) do
		if not seen_raw[name] then
			seen_raw[name] = true
			unique[#unique + 1] = { raw = name, index = i }
		end
	end

	-- Step 2: per-name normalization
	-- Also build groups: normalized -> list of raw names that map to it.
	local norm_of    = {}  -- raw -> normalized (pre-collision)
	local groups     = {}  -- normalized -> list of raw names (sorted alpha later)
	for _, entry in ipairs(unique) do
		local raw  = entry.raw
		local norm = M.normalize_one(raw, entry.index)
		norm_of[raw] = norm
		if not groups[norm] then
			groups[norm] = {}
		end
		local g = groups[norm]
		g[#g + 1] = raw
	end

	-- Step 3: collision resolution
	-- Collect the full set of already-assigned identifiers so we can detect
	-- when a suffixed name clashes with an independently assigned one.
	local result     = {}  -- raw -> final identifier
	local assigned   = {}  -- identifier -> true (all identifiers in use)

	-- First pass: assign identifiers for non-colliding names immediately.
	for norm, group in pairs(groups) do
		if #group == 1 then
			local raw = group[1]
			result[raw]     = norm
			assigned[norm]  = true
		end
	end

	-- Second pass: resolve collisions.
	for norm, group in pairs(groups) do
		if #group > 1 then
			-- Sort colliding raws alphabetically.
			table.sort(group)
			-- First (alphabetically) keeps the base identifier (but may need
			-- to bump if already claimed by a non-colliding assignment).
			for pos, raw in ipairs(group) do
				local candidate
				if pos == 1 then
					-- Keep base if free, otherwise treat like pos=2.
					if not assigned[norm] then
						candidate = norm
					else
						-- Base is taken by another group's assignment; start at _2.
						local n = 2
						candidate = norm .. "_" .. tostring(n)
						while assigned[candidate] do
							n = n + 1
							candidate = norm .. "_" .. tostring(n)
						end
					end
				else
					-- pos=2 → _2, pos=3 → _3, etc.
					--: integer
					local n = pos
					candidate = norm .. "_" .. tostring(n)
					while assigned[candidate] do
						n = n + 1
						candidate = norm .. "_" .. tostring(n)
					end
				end
				result[raw]         = candidate
				assigned[candidate] = true
			end
		end
	end

	return result
end

return M
