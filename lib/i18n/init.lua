if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: PluralRule = (count: number) -> string
--:: I = { _translations: { [string]: { [string]: unknown } }, _locale: string | nil, _fallback: string | nil, _plural_rules: { [string]: PluralRule }, load: (self: I, string, { [string]: unknown }) -> nil, set_locale: (self: I, string) -> nil, set_fallback: (self: I, string) -> nil, set_plural_rule: (self: I, string, PluralRule) -> nil, _get_plural_rule: (self: I, string) -> PluralRule, t: (self: I, string, { [string]: unknown } | nil, string | nil) -> string, has: (self: I, string) -> boolean, locales: (self: I) -> string[] }

-- Default plural rules for common locales
--: { [string]: PluralRule }
local default_plural_rules = {
	en = function(count) return count == 1 and "one" or "other" end,
	es = function(count) return count == 1 and "one" or "other" end,
	fr = function(count) return (count == 0 or count == 1) and "one" or "other" end,
	de = function(count) return count == 1 and "one" or "other" end,
	ja = function(_) return "other" end,
	zh = function(_) return "other" end,
	ar = function(count)
		if count == 0 then return "zero"
		elseif count == 1 then return "one"
		elseif count == 2 then return "two"
		elseif count >= 3 and count <= 10 then return "few"
		elseif count >= 11 and count <= 99 then return "many"
		else return "other" end
	end,
}

-- Resolve a dotted key path in a table.
-- Returns the value or nil if any segment is missing.
--: ({ [string]: unknown }, string) -> unknown
local function resolve_key(tbl, key)
	if tbl[key] ~= nil then return tbl[key] end
	local pos = 1
	--: { [string]: unknown }
	local current = tbl
	while true do
		local dot = key:find(".", pos, true)
		if not dot then
			return current[key:sub(pos)]
		end
		local segment = key:sub(pos, dot - 1)
		local next_val = current[segment]
		if type(next_val) ~= "table" then return nil end
		current = next_val --[[:! { [string]: unknown }]]
		pos = dot + 1
	end
end

-- Replace {{var}} placeholders with values from the data table.
--: (string, { [string]: unknown } | nil) -> string
local function interpolate(str, data)
	if not data then return str end
	local result, _ = str:gsub("{{(.-)}}", function(var)
		local v = data[var]
		if v == nil then return "{{" .. var .. "}}" end
		return tostring(v)
	end)
	return result
end

local I = {}
I.__index = I

--: () -> I
function M.new()
	local self = setmetatable({
		_translations = {},
		_locale = nil,
		_fallback = nil,
		_plural_rules = {},
	}, I) --[[:! I]]
	return self
end

-- Load translations for a locale. Merges with any existing translations.
--: (self: I, locale: string, translations: { [string]: unknown }) -> nil
function I:load(locale, translations)
	if not self._translations[locale] then
		self._translations[locale] = {}
	end
	local dst = self._translations[locale]
	for k, v in pairs(translations) do
		dst[k] = v
	end
end

-- Set the current locale.
--: (self: I, locale: string) -> nil
function I:set_locale(locale)
	self._locale = locale
end

-- Set the fallback locale used when a key is missing in the current locale.
--: (self: I, locale: string) -> nil
function I:set_fallback(locale)
	self._fallback = locale
end

-- Set a custom plural rule for a locale.
--: (self: I, locale: string, rule: PluralRule) -> nil
function I:set_plural_rule(locale, rule)
	self._plural_rules[locale] = rule
end

-- Get the plural rule for a locale: custom > default > English fallback.
--: (self: I, locale: string) -> PluralRule
function I:_get_plural_rule(locale)
	return self._plural_rules[locale]
		or default_plural_rules[locale]
		or default_plural_rules.en
end

-- Translate a key with optional interpolation data and locale override.
-- Returns the key itself if no translation is found.
--: (self: I, key: string, data: { [string]: unknown } | nil, locale: string | nil) -> string
function I:t(key, data, locale)
	local loc = locale or self._locale
	local value = nil
	-- Try the requested locale
	if loc and self._translations[loc] then
		value = resolve_key(self._translations[loc], key)
	end
	-- Try the fallback locale
	if value == nil and self._fallback and self._fallback ~= loc and self._translations[self._fallback] then
		value = resolve_key(self._translations[self._fallback], key)
		-- Use fallback locale for plural rule if value came from fallback
		if value ~= nil then loc = self._fallback end
	end
	if value == nil then return key end
	-- Handle plural tables
	if type(value) == "table" then
		local value_tbl = value --[[:! { [string]: unknown }]]
		local count_raw = data and data.count
		if count_raw ~= nil then
			local count = (count_raw --[[:! number]])
			--: string
			local loc_eff = (loc or "en") --[[:! string]]
			local rule = self:_get_plural_rule(loc_eff)
			local form = rule(count)
			local plural_val = value_tbl[form] or value_tbl["other"]
			if plural_val == nil then return key end
			value = plural_val
		else
			-- Table but no count - can't resolve, return key
			return key
		end
	end
	if type(value) ~= "string" then return key end
	return interpolate(value --[[:! string]], data)
end

-- Check whether a key exists in the current locale or fallback.
--: (self: I, key: string) -> boolean
function I:has(key)
	if self._locale and self._translations[self._locale] then
		if resolve_key(self._translations[self._locale], key) ~= nil then
			return true
		end
	end
	if self._fallback and self._translations[self._fallback] then
		if resolve_key(self._translations[self._fallback], key) ~= nil then
			return true
		end
	end
	return false
end

-- Return a sorted list of loaded locale names.
--: (self: I) -> string[]
function I:locales()
	local result = {}
	for k in pairs(self._translations) do
		result[#result + 1] = k
	end
	table.sort(result)
	return result
end

return M
