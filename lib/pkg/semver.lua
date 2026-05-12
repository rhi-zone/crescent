if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Pure-Lua semver parser for the crescent package manager.
-- Implements semver 2.0.0 subset: parse, compare, constraint satisfaction.

local M = {}

--:: PreId = integer | string
--:: Version = { major: integer, minor: integer, patch: integer, pre: (PreId[]) | nil }
--:: PartialVersion = { major: integer, minor: integer | nil, patch: integer | nil }
--:: Constraint = { op: string, version: Version | nil }

-- Parse a pre-release identifier list from a string like "alpha.1".
-- Each identifier is either an integer or a string.
--: (string | nil) -> (PreId[]) | nil
local function parse_pre(s)
	if not s or s == "" then return nil end
	local ids = {}
	for part in (s .. "."):gmatch("([^.]+)%.") do
		local n = tonumber(part)
		if n and math.floor(n) == n and part:match("^%d+$") then
			ids[#ids + 1] = n
		else
			ids[#ids + 1] = part
		end
	end
	if #ids == 0 then return nil end
	return ids
end

--- Parse a version string into {major, minor, patch, pre}.
-- pre is nil or a list of identifiers (string or integer).
-- Returns nil, err on failure.
--: (string) -> ({ major: integer, minor: integer, patch: integer, pre: ({ [number]: integer | string }) | nil } | nil, string | nil)
function M.parse(str)
	if type(str) ~= "string" then
		return nil, "expected string, got " .. type(str)
	end
	-- Strip leading 'v'
	local s = str:match("^v?(.+)$") or str
	-- Split build metadata off (we ignore it per semver spec)
	s = s:gsub("%+[^+]*$", "")
	-- Split pre-release
	local core, pre_str = s:match("^([^%-]+)%-?(.*)$")
	if not core then
		return nil, "invalid version: " .. str
	end
	local major, minor, patch = core:match("^(%d+)%.(%d+)%.(%d+)$")
	if not major then
		-- Allow "1.2" or "1" as shorthand? Only for internal use; for strict semver require all three.
		return nil, "invalid version (expected MAJOR.MINOR.PATCH): " .. str
	end
	local major_n = tonumber(major) --[[:! integer]]
	local minor_n = tonumber(minor) --[[:! integer]]
	local patch_n = tonumber(patch) --[[:! integer]]
	local pre = (pre_str ~= "") and parse_pre(pre_str) or nil
	return { major = major_n, minor = minor_n, patch = patch_n, pre = pre }
end

-- Compare two pre-release identifier lists.
-- nil (release) > any pre-release list (semver §11.4)
--: ((PreId[]) | nil, (PreId[]) | nil) -> integer
local function cmp_pre(a, b)
	if a == nil and b == nil then return 0 end
	if a == nil then return 1 end   -- release > pre-release
	if b == nil then return -1 end  -- pre-release < release
	local n = math.max(#a, #b)
	for i = 1, n do
		local ai, bi = a[i], b[i]
		if ai == nil then return -1 end  -- shorter < longer
		if bi == nil then return 1 end
		if type(ai) == "number" and type(bi) == "number" then
			if ai < bi then return -1 end
			if ai > bi then return 1 end
		elseif type(ai) == "number" then
			return -1  -- numeric < string identifiers
		elseif type(bi) == "number" then
			return 1
		elseif type(ai) == "string" and type(bi) == "string" then
			if ai < bi then return -1 end
			if ai > bi then return 1 end
		end
	end
	return 0
end

--- Compare two parsed versions. Returns -1, 0, or 1.
--: (Version, Version) -> integer
function M.cmp(a, b)
	if a.major ~= b.major then
		return a.major < b.major and -1 or 1
	end
	if a.minor ~= b.minor then
		return a.minor < b.minor and -1 or 1
	end
	if a.patch ~= b.patch then
		return a.patch < b.patch and -1 or 1
	end
	return cmp_pre(a.pre, b.pre)
end

-- Parse a bare version string used inside a constraint (may be partial for ~ operator).
-- Returns major, minor, patch (any may be nil for wildcards).
--: (string) -> (integer | nil, integer | nil, integer | nil)
local function parse_partial(s)
	local maj, min, pat = s:match("^(%d+)%.(%d+)%.(%d+)$")
	if maj then
		return tonumber(maj) --[[:! integer]], tonumber(min) --[[:! integer]], tonumber(pat) --[[:! integer]]
	end
	maj, min = s:match("^(%d+)%.(%d+)$")
	if maj then
		return tonumber(maj) --[[:! integer]], tonumber(min) --[[:! integer]], nil
	end
	maj = s:match("^(%d+)$")
	if maj then
		return tonumber(maj) --[[:! integer]], nil, nil
	end
	return nil, nil, nil
end

-- Build a version with pre=nil (release) for boundary comparisons.
--: (integer, integer, integer) -> Version
local function v(maj, min, pat)
	return { major = maj, minor = min, patch = pat, pre = nil }
end

--- Parse a constraint string into a structured form.
-- Returns a constraint table or nil, err.
-- Constraint table: { op = "^"|"~"|">="|">"|"<="|"<"|"="|"*", version = parsed }
-- For "^" and "~" the version field contains the anchor, and op encodes the rule.
--: (string) -> (Constraint | nil, string | nil)
function M.parse_constraint(str)
	if type(str) ~= "string" then
		return nil, "expected string"
	end
	local s = str:match("^%s*(.-)%s*$")  -- trim whitespace
	if s == "" or s == "*" then
		return { op = "*", version = nil }
	end
	-- Caret
	local rest = s:match("^%^(.+)$")
	if rest then
		local ver, err = M.parse(rest)
		if not ver then return nil, err end
		return { op = "^", version = ver }
	end
	-- Tilde
	rest = s:match("^~(.+)$")
	if rest then
		local maj, min, pat = parse_partial(rest)
		if maj == nil then return nil, "invalid constraint version: " .. rest end
		-- Store partial version; minor/patch may be nil for "~1" or "~1.2" forms.
		-- Stored as Version with zeros for unspecified fields; the satisfies() logic
		-- re-reads via PartialVersion cast to check which were originally nil.
		local pv = { major = maj, minor = min, patch = pat } --[[:! Version]]
		return { op = "~", version = pv }
	end
	-- >=, <=, >, <
	for _, op in ipairs({ ">=", "<=", ">", "<" }) do
		local op_pat = op:gsub("[<>]", function(c) return "%" .. c end)
		rest = s:match("^" .. op_pat .. "(.+)$")
		if rest then
			local ver, err = M.parse(rest)
			if not ver then return nil, err end
			return { op = op, version = ver }
		end
	end
	-- Exact (optional leading =)
	rest = s:match("^=(.+)$") or s
	local ver, err = M.parse(rest)
	if not ver then return nil, "invalid constraint: " .. str .. ": " .. (err or "") end
	return { op = "=", version = ver }
end

--- Check if a parsed version satisfies a constraint string.
-- Returns bool. Errors in constraint parsing return false.
--: (Version, string) -> boolean
function M.satisfies(version, constraint_str)
	local c, err = M.parse_constraint(constraint_str)
	if not c then return false end
	local op = c.op

	if op == "*" then
		return true
	end
	local cv = c.version
	if cv == nil then return false end

	if op == "=" then
		return M.cmp(version, cv) == 0
	end

	if op == ">=" then
		return M.cmp(version, cv) >= 0
	end

	if op == ">" then
		return M.cmp(version, cv) > 0
	end

	if op == "<=" then
		return M.cmp(version, cv) <= 0
	end

	if op == "<" then
		return M.cmp(version, cv) < 0
	end

	if op == "^" then
		-- >= cv and < upper bound based on first nonzero component
		-- cv is always a full Version here (produced by M.parse in parse_constraint)
		if M.cmp(version, cv) < 0 then return false end
		local upper
		if cv.major ~= 0 then
			upper = v(cv.major + 1, 0, 0)
		elseif cv.minor ~= 0 then
			upper = v(0, cv.minor + 1, 0)
		else
			upper = v(0, 0, cv.patch + 1)
		end
		-- upper bound is exclusive and pre-release of a release version does NOT satisfy <upper
		-- (pre-releases of the upper boundary itself are excluded)
		return M.cmp(version, upper) < 0
	end

	if op == "~" then
		-- ~1.2.3 → >=1.2.3 <1.3.0
		-- ~1.2   → >=1.2.0 <1.3.0
		-- ~1     → >=1.0.0 <2.0.0
		-- cv was stored as PartialVersion (minor/patch may be nil)
		local pcv = cv --[[:! PartialVersion]]
		local maj = pcv.major
		local min = pcv.minor
		local pat = pcv.patch
		local lower, upper
		if pat ~= nil then
			-- ~1.2.3
			lower = v(maj, min ~= nil and min or 0, pat)
			upper = v(maj, (min ~= nil and min or 0) + 1, 0)
		elseif min ~= nil then
			-- ~1.2
			lower = v(maj, min, 0)
			upper = v(maj, min + 1, 0)
		else
			-- ~1
			lower = v(maj, 0, 0)
			upper = v(maj + 1, 0, 0)
		end
		if M.cmp(version, lower) < 0 then return false end
		if M.cmp(version, upper) >= 0 then return false end
		return true
	end

	return false
end

return M
