if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Semantic Versioning 2.0.0 parser, comparator, and constraint solver.
-- Pure Lua, no dependencies. See https://semver.org/

local M = {}

--:: Version = { major: integer, minor: integer, patch: integer, prerelease: string | nil, build: string | nil, ... }

local Version = {}
Version.__index = Version

-- Format a version as a string.
--: (self: Version) -> string
function Version:__tostring()
	local self = self --[[:! Version]]
	local s = self.major .. "." .. self.minor .. "." .. self.patch
	if self.prerelease then
		s = s .. "-" .. self.prerelease
	end
	if self.build then
		s = s .. "+" .. self.build
	end
	return s
end

function Version:__eq(other)
	local self = self --[[:! Version]]
	return self:cmp(other) == 0
end

function Version:__lt(other)
	local self = self --[[:! Version]]
	return self:cmp(other) < 0
end

function Version:__le(other)
	local self = self --[[:! Version]]
	return self:cmp(other) <= 0
end

-- Parse prerelease identifiers into a list of string|integer.
--: (string | nil) -> { [integer]: string | number } | nil
local function parse_prerelease_ids(s)
	if not s or s == "" then return nil end
	local ids = {}
	for part in (s .. "."):gmatch("([^.]+)%.") do
		local n = tonumber(part)
		if n and part:match("^%d+$") and math.floor(n) == n then
			ids[#ids + 1] = n
		else
			ids[#ids + 1] = part
		end
	end
	return ids
end

-- Compare two prerelease identifier lists per SemVer 2.0.0 section 11.
-- nil (release) > any prerelease list.
--: ({ [integer]: string | number } | nil, { [integer]: string | number } | nil) -> integer
local function cmp_prerelease(a_ids, b_ids)
	if a_ids == nil and b_ids == nil then return 0 end
	if a_ids == nil then return 1 end
	if b_ids == nil then return -1 end
	local n = math.max(#a_ids, #b_ids)
	for i = 1, n do
		local ai, bi = a_ids[i], b_ids[i]
		if ai == nil then return -1 end -- shorter < longer
		if bi == nil then return 1 end
		if type(ai) == "number" and type(bi) == "number" then
			if ai < bi then return -1 end
			if ai > bi then return 1 end
		elseif type(ai) == "number" then
			return -1 -- numeric < string
		elseif type(bi) == "number" then
			return 1
		else
			if ai < bi then return -1 end
			if ai > bi then return 1 end
		end
	end
	return 0
end

-- Compare this version to another. Returns -1, 0, or 1.
-- Build metadata is ignored per SemVer 2.0.0.
function Version:cmp(other)
	local self = self --[[:! Version]]
	local other = other --[[:! Version]]
	if self.major ~= other.major then
		return self.major < other.major and -1 or 1
	end
	if self.minor ~= other.minor then
		return self.minor < other.minor and -1 or 1
	end
	if self.patch ~= other.patch then
		return self.patch < other.patch and -1 or 1
	end
	local a_ids = parse_prerelease_ids(self.prerelease --[[:! string | nil]])
	local b_ids = parse_prerelease_ids(other.prerelease --[[:! string | nil]])
	return cmp_prerelease(a_ids, b_ids)
end

function Version:eq(other)
	local self = self --[[:! Version]]
	return self:cmp(other) == 0
end
function Version:lt(other)
	local self = self --[[:! Version]]
	return self:cmp(other) < 0
end
function Version:le(other)
	local self = self --[[:! Version]]
	return self:cmp(other) <= 0
end
function Version:gt(other)
	local self = self --[[:! Version]]
	return self:cmp(other) > 0
end
function Version:ge(other)
	local self = self --[[:! Version]]
	return self:cmp(other) >= 0
end

-- Return a new version with major incremented, minor/patch reset, prerelease/build cleared.
function Version:inc_major()
	local self = self --[[:! Version]]
	return M.new(self.major + 1, 0, 0, nil, nil)
end

-- Return a new version with minor incremented, patch reset, prerelease/build cleared.
function Version:inc_minor()
	local self = self --[[:! Version]]
	local maj = self.major --[[:! integer]]
	local min = self.minor --[[:! integer]]
	return M.new(maj, min + 1, 0, nil, nil)
end

-- Return a new version with patch incremented, prerelease/build cleared.
function Version:inc_patch()
	local self = self --[[:! Version]]
	local maj = self.major --[[:! integer]]
	local min = self.minor --[[:! integer]]
	local pat = self.patch --[[:! integer]]
	return M.new(maj, min, pat + 1, nil, nil)
end

-- Create a version object from components.
--: (integer, integer, integer, string | nil, string | nil) -> Version
function M.new(major, minor, patch, prerelease, build)
	local v = setmetatable({
		major = major,
		minor = minor,
		patch = patch,
		prerelease = prerelease,
		build = build,
	}, Version)
	return v
end

-- Validate that a prerelease string contains only valid identifiers.
-- Each dot-separated identifier must be non-empty and:
--   numeric identifiers must not have leading zeros.
--   alphanumeric identifiers must match [0-9A-Za-z-]+.
local function validate_prerelease(s)
	if not s or s == "" then return nil, "empty prerelease" end
	for part in (s .. "."):gmatch("([^.]+)%.") do
		if part == "" then
			return nil, "empty prerelease identifier"
		end
		if not part:match("^[0-9A-Za-z%-]+$") then
			return nil, "invalid character in prerelease identifier: " .. part
		end
		-- Numeric identifiers must not have leading zeros
		if part:match("^%d+$") and #part > 1 and part:sub(1, 1) == "0" then
			return nil, "numeric prerelease identifier with leading zero: " .. part
		end
	end
	return true
end

-- Validate build metadata string.
local function validate_build(s)
	if not s or s == "" then return nil, "empty build" end
	for part in (s .. "."):gmatch("([^.]+)%.") do
		if part == "" then
			return nil, "empty build identifier"
		end
		if not part:match("^[0-9A-Za-z%-]+$") then
			return nil, "invalid character in build identifier: " .. part
		end
	end
	return true
end

--- Parse a version string into a Version object.
-- Returns Version or (nil, errmsg).
function M.parse(str)
	if type(str) ~= "string" then
		return nil, "expected string, got " .. type(str)
	end
	if str == "" then
		return nil, "empty version string"
	end

	-- Extract build metadata
	local build_str
	local plus = str:find("+", 1, true)
	local core = plus and str:sub(1, plus - 1) or str
	if plus then
		build_str = str:sub(plus + 1)
		if build_str == "" then
			return nil, "invalid version: empty build metadata: " .. str
		end
		local ok, err = validate_build(build_str)
		if not ok then
			return nil, "invalid version: " .. (err or "") .. ": " .. str
		end
	end

	-- Extract prerelease
	local pre_str
	local dash = core:find("-", 1, true)
	local pre_core = dash and core:sub(1, dash - 1) or core
	if dash then
		pre_str = core:sub(dash + 1)
		if pre_str == "" then
			return nil, "invalid version: empty prerelease: " .. str
		end
		local ok, err = validate_prerelease(pre_str)
		if not ok then
			return nil, "invalid version: " .. (err or "") .. ": " .. str
		end
	end

	-- Parse core version
	local maj_s, min_s, pat_s = pre_core:match("^(%d+)%.(%d+)%.(%d+)$")
	if not maj_s then
		return nil, "invalid version (expected MAJOR.MINOR.PATCH): " .. str
	end

	-- Reject leading zeros in numeric components
	if (#maj_s > 1 and maj_s:sub(1, 1) == "0") or
	   (#min_s > 1 and min_s:sub(1, 1) == "0") or
	   (#pat_s > 1 and pat_s:sub(1, 1) == "0") then
		return nil, "invalid version: leading zeros not allowed: " .. str
	end

	return M.new(tonumber(maj_s) --[[:! integer]], tonumber(min_s) --[[:! integer]], tonumber(pat_s) --[[:! integer]], pre_str, build_str)
end

--- Check if a string is a valid semver version.
function M.is_valid(str)
	local v, _ = M.parse(str)
	return v ~= nil
end

--- Sort a list of Version objects in place, ascending.
function M.sort(list)
	table.sort(list, function(a, b) return a:cmp(b) < 0 end)
	return list
end

--- Return the maximum version from a list.
function M.max(list)
	if #list == 0 then return nil end
	local best = list[1]
	for i = 2, #list do
		if list[i]:cmp(best) > 0 then
			best = list[i]
		end
	end
	return best
end

--- Return the minimum version from a list.
function M.min(list)
	if #list == 0 then return nil end
	local best = list[1]
	for i = 2, #list do
		if list[i]:cmp(best) < 0 then
			best = list[i]
		end
	end
	return best
end

-- Constraint implementation

local Constraint = {}
Constraint.__index = Constraint

-- Internal: create a version for boundary comparison (no prerelease/build).
--: (integer, integer, integer) -> Version
local function ver(maj, min, pat)
	return M.new(maj, min, pat, nil, nil)
end

-- Parse a partial version used in wildcard/tilde constraints.
-- Returns major, minor, patch (any may be nil), has_wildcard.
--: (string) -> (integer | nil, integer | nil, integer | nil, boolean)
local function parse_partial(s)
	-- x/X/* wildcards
	local maj_s, min_s, pat_s = s:match("^(%d+)%.(%d+)%.([xX%*])$")
	if maj_s then
		return tonumber(maj_s) --[[:! integer]], tonumber(min_s) --[[:! integer]], nil, true
	end
	maj_s, min_s = s:match("^(%d+)%.([xX%*])$")
	if maj_s then
		return tonumber(maj_s) --[[:! integer]], nil, nil, true
	end
	if s:match("^[xX%*]$") then
		return nil, nil, nil, true
	end
	-- Full version
	maj_s, min_s, pat_s = s:match("^(%d+)%.(%d+)%.(%d+)$")
	if maj_s then
		return tonumber(maj_s) --[[:! integer]], tonumber(min_s) --[[:! integer]], tonumber(pat_s) --[[:! integer]], false
	end
	-- Two-part
	maj_s, min_s = s:match("^(%d+)%.(%d+)$")
	if maj_s then
		return tonumber(maj_s) --[[:! integer]], tonumber(min_s) --[[:! integer]], nil, false
	end
	-- One-part
	maj_s = s:match("^(%d+)$")
	if maj_s then
		return tonumber(maj_s) --[[:! integer]], nil, nil, false
	end
	return nil, nil, nil, false
end

-- Parse a single constraint token into a list of {op, version} bounds.
-- Returns list of {op, version} or nil, err.
local function parse_single_constraint(s)
	local st = s:match("^%s*(.-)%s*$") or s
	if st == "" or st == "*" or st == "x" or st == "X" then
		return {{ op = "*" }}
	end

	-- Caret range: ^M.m.p
	local rest = st:match("^%^(.+)$")
	if rest then
		local maj, min, pat = parse_partial(rest)
		if maj == nil then return nil, "invalid caret constraint: " .. st end
		local imin = min or 0
		local ipat = pat or 0
		local lower = ver(maj, imin, ipat)
		local upper
		if maj ~= 0 then
			upper = ver(maj + 1, 0, 0)
		elseif imin ~= 0 then
			upper = ver(0, imin + 1, 0)
		else
			upper = ver(0, 0, ipat + 1)
		end
		return {{ op = ">=", version = lower }, { op = "<", version = upper }}
	end

	-- Tilde range: ~M.m.p
	rest = st:match("^~(.+)$")
	if rest then
		local maj, min, pat = parse_partial(rest)
		if maj == nil then return nil, "invalid tilde constraint: " .. st end
		local lower, upper
		if pat ~= nil and min ~= nil then
			lower = ver(maj, min, pat)
			upper = ver(maj, min + 1, 0)
		elseif min ~= nil then
			lower = ver(maj, min, 0)
			upper = ver(maj, min + 1, 0)
		else
			lower = ver(maj, 0, 0)
			upper = ver(maj + 1, 0, 0)
		end
		return {{ op = ">=", version = lower }, { op = "<", version = upper }}
	end

	-- Wildcard ranges: 1.2.x, 1.x, 1.x.x, etc.
	local maj, min, pat, has_wildcard = parse_partial(st)
	if has_wildcard then
		if maj == nil then
			return {{ op = "*" }}
		elseif min == nil then
			local imaj = maj --[[:! integer]]
			return {{ op = ">=", version = ver(imaj, 0, 0) }, { op = "<", version = ver(imaj + 1, 0, 0) }}
		else
			local imaj = maj --[[:! integer]]
			local imin = min --[[:! integer]]
			return {{ op = ">=", version = ver(imaj, imin, 0) }, { op = "<", version = ver(imaj, imin + 1, 0) }}
		end
	end

	-- Comparison operators: >=, <=, >, <, =
	for _, op in ipairs({ ">=", "<=", ">", "<", "=" }) do
		local escaped = (op:gsub("[<>=]", function(c) return "%" .. c end))
		local pat_str = "^" .. escaped .. "(.+)$"
		rest = st:match(pat_str)
		if rest then
			local v, err = M.parse(rest)
			if not v then return nil, err end
			return {{ op = op, version = v }}
		end
	end

	-- Bare version = exact match
	local v, err = M.parse(st)
	if not v then return nil, "invalid constraint: " .. st .. ": " .. (err or "") end
	return {{ op = "=", version = v }}
end

-- Check if a version satisfies a single bound.
local function check_bound(version, bound)
	local op = bound.op
	if op == "*" then return true end
	local c = version:cmp(bound.version)
	if op == "=" then return c == 0 end
	if op == ">=" then return c >= 0 end
	if op == ">" then return c > 0 end
	if op == "<=" then return c <= 0 end
	if op == "<" then return c < 0 end
	return false
end

--- Parse a constraint string.
-- Supports: >=, <=, >, <, =, ^, ~, x/X/* wildcards, compound (space-separated = AND).
-- Returns a Constraint object or (nil, errmsg).
function M.constraint(str)
	if type(str) ~= "string" then
		return nil, "expected string, got " .. type(str)
	end
	local s = str:match("^%s*(.-)%s*$")
	if s == "" then
		return nil, "empty constraint"
	end

	-- Split on whitespace for AND constraints (e.g. ">=1.0.0 <2.0.0")
	local bounds = {}
	for token in s:gmatch("%S+") do
		local parsed, err = parse_single_constraint(token)
		if not parsed then return nil, err end
		for _, b in ipairs(parsed) do
			bounds[#bounds + 1] = b
		end
	end

	return setmetatable({ _bounds = bounds, _source = str }, Constraint)
end

--- Check if a version matches this constraint.
function Constraint:matches(version)
	for _, bound in ipairs(self._bounds) do
		if not check_bound(version, bound) then
			return false
		end
	end
	return true
end

function Constraint:__tostring()
	return self._source
end

return M
