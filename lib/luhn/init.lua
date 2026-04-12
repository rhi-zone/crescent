-- lib/luhn/init.lua
-- Luhn algorithm for credit card and ID number validation.
-- Includes check digit computation, number generation, card type detection,
-- and display formatting.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, gsub, rep = string.byte, string.char, string.sub, string.gsub, string.rep
local floor, concat = math.floor, table.concat

-- ── Normalization ──────────────────────────────────────────────────────────────

--- Strip spaces and dashes from a card number string.
--- Returns nil if any non-digit, non-space, non-dash characters remain.
local function normalize(s)
	if type(s) ~= "string" then return nil end
	local r = gsub(s, "[ -]", "")
	if r:find("[^%d]") then return nil end
	return r
end

-- ── Core Luhn ─────────────────────────────────────────────────────────────────

--- Compute the Luhn sum over all digits in the string `s` (digits only, no spaces).
--- `with_check` — if true, the rightmost digit is treated as the check digit
---                (sum must be divisible by 10 for a valid number).
--- If false (computing check digit), the rightmost digit in `s` is the last
--- payload digit — we double every second digit from the right.
local function luhn_sum(s)
	local n = #s
	local sum = 0
	for i = 1, n do
		local d = byte(s, i) - 48  -- '0' == 48
		-- Position from the right: (n - i + 1). Double when position is even.
		-- With check digit included: double positions 2, 4, 6, ... from right.
		local pos = n - i + 1
		if pos % 2 == 0 then
			d = d * 2
			if d > 9 then d = d - 9 end
		end
		sum = sum + d
	end
	return sum
end

--- Validate a Luhn number. Accepts spaces and dashes as separators.
--- Returns false for empty strings or strings with non-digit characters (besides spaces/dashes).
function M.valid(s)
	local n = normalize(s)
	if not n or #n == 0 then return false end
	return luhn_sum(n) % 10 == 0
end

--- Compute the Luhn check digit for a payload string (without check digit).
--- Returns the check digit as an integer (0–9).
--- Returns nil, errmsg on invalid input.
function M.check_digit(s)
	local n = normalize(s)
	if not n then return nil, "invalid input: non-digit characters" end
	if #n == 0 then return nil, "invalid input: empty string" end
	-- Append a 0 and compute sum; the check digit makes the total divisible by 10.
	local sum = luhn_sum(n .. "0")
	return (10 - (sum % 10)) % 10
end

--- Generate a valid Luhn number with the given prefix and total length.
--- Returns nil, errmsg on invalid input.
function M.generate(prefix, length)
	if type(prefix) ~= "string" then return nil, "prefix must be a string" end
	if type(length) ~= "number" or length < 1 then return nil, "length must be a positive integer" end
	local p = normalize(prefix)
	if not p then return nil, "prefix contains non-digit characters" end
	if #p >= length then return nil, "prefix length must be less than total length" end
	-- Fill remaining digits (except check digit) with zeros, then compute check digit.
	local payload = p .. rep("0", length - #p - 1)
	local cd = M.check_digit(payload)
	return payload .. tostring(cd)
end

-- ── Card type definitions ─────────────────────────────────────────────────────

--:: CardInfo = { name: string, prefixes: { [number]: string }, lengths: { [number]: number } }

-- Each entry: { id, name, prefixes, lengths }
-- Prefix matching is done longest-first to avoid ambiguity.
local CARD_DEFS = {
	{
		id = "visa",
		name = "Visa",
		lengths = { 13, 16 },
		-- Match function returns true if a prefix of the number matches.
		match = function(n)
			return sub(n, 1, 1) == "4"
		end,
	},
	{
		id = "mastercard",
		name = "Mastercard",
		lengths = { 16 },
		match = function(n)
			-- 51–55
			local p2 = tonumber(sub(n, 1, 2))
			if p2 and p2 >= 51 and p2 <= 55 then return true end
			-- 2221–2720
			local p4 = tonumber(sub(n, 1, 4))
			if p4 and p4 >= 2221 and p4 <= 2720 then return true end
			return false
		end,
	},
	{
		id = "amex",
		name = "American Express",
		lengths = { 15 },
		match = function(n)
			local p2 = sub(n, 1, 2)
			return p2 == "34" or p2 == "37"
		end,
	},
	{
		id = "discover",
		name = "Discover",
		lengths = { 16, 19 },
		match = function(n)
			-- 6011
			if sub(n, 1, 4) == "6011" then return true end
			-- 622126–622925
			local p6 = tonumber(sub(n, 1, 6))
			if p6 and p6 >= 622126 and p6 <= 622925 then return true end
			-- 644–649
			local p3 = tonumber(sub(n, 1, 3))
			if p3 and p3 >= 644 and p3 <= 649 then return true end
			-- 65
			if sub(n, 1, 2) == "65" then return true end
			return false
		end,
	},
	{
		id = "jcb",
		name = "JCB",
		lengths = { 16, 17, 18, 19 },
		match = function(n)
			local p4 = tonumber(sub(n, 1, 4))
			return p4 and p4 >= 3528 and p4 <= 3589
		end,
	},
	{
		id = "diners",
		name = "Diners Club",
		lengths = { 14 },
		match = function(n)
			local p3 = tonumber(sub(n, 1, 3))
			if p3 and p3 >= 300 and p3 <= 305 then return true end
			local p2 = sub(n, 1, 2)
			if p2 == "36" or p2 == "38" then return true end
			return false
		end,
	},
	{
		id = "unionpay",
		name = "UnionPay",
		lengths = { 16, 17, 18, 19 },
		match = function(n)
			return sub(n, 1, 2) == "62"
		end,
	},
}

-- Build a map for card_info lookups.
local CARD_MAP = {}
for _, def in ipairs(CARD_DEFS) do
	CARD_MAP[def.id] = def
end

--- Detect the card type from a number string.
--- Returns the card type id (e.g. "visa") or nil if unknown.
function M.card_type(s)
	local n = normalize(s)
	if not n or #n == 0 then return nil end
	for _, def in ipairs(CARD_DEFS) do
		if def.match(n) then
			-- Also check length is in the allowed set.
			local len = #n
			for _, l in ipairs(def.lengths) do
				if l == len then return def.id end
			end
		end
	end
	return nil
end

--- Return info table for a card type id.
--- Returns nil, errmsg for unknown types.
function M.card_info(id)
	local def = CARD_MAP[id]
	if not def then return nil, "unknown card type: " .. tostring(id) end
	return { name = def.name, lengths = def.lengths }
end

--- Return array of all known card type ids.
function M.card_types()
	local out = {}
	for i, def in ipairs(CARD_DEFS) do
		out[i] = def.id
	end
	return out
end

-- ── Formatting ────────────────────────────────────────────────────────────────

-- Grouping patterns per card type (by total length).
-- Format: array of group sizes.
local FORMAT_GROUPS = {
	amex    = { 15, { 4, 6, 5 } },
	diners  = { 14, { 4, 6, 4 } },
}

local function group_string(s, groups)
	local parts = {}
	local pos = 1
	for _, g in ipairs(groups) do
		local chunk = sub(s, pos, pos + g - 1)
		if #chunk > 0 then
			parts[#parts + 1] = chunk
		end
		pos = pos + g
	end
	-- Any remainder (shouldn't happen for well-formed inputs).
	if pos <= #s then
		parts[#parts + 1] = sub(s, pos)
	end
	return concat(parts, " ")
end

--- Format a number string for display with standard space groupings.
--- Uses card-type-specific grouping; unknown or non-standard lengths fall back to groups of 4.
function M.format(s)
	local n = normalize(s)
	if not n then return s end  -- return as-is if we can't normalize
	local ct = M.card_type(n)
	-- Amex: 4-6-5
	if ct == "amex" then
		return group_string(n, { 4, 6, 5 })
	end
	-- Diners: 4-6-4
	if ct == "diners" then
		return group_string(n, { 4, 6, 4 })
	end
	-- All others (Visa, Mastercard, Discover, JCB, UnionPay, unknown): group by 4
	return group_string(n, { 4, 4, 4, 4, 4, 4 })
end

return M
