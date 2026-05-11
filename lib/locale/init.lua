if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- locale: internationalization (i18n) and localization (l10n) library.
-- Message catalogs, plural forms, number/date/currency formatting per locale,
-- and string translation with interpolation.
--
-- All pure Lua — no external dependencies, vendorable.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal data tables
-- ---------------------------------------------------------------------------

-- Number format descriptors: { decimal, group, group_size }
--:: NumFmt = { decimal: string, group: string, group_size: integer }
local NUMBER_FORMATS = {
  ["en"] = { decimal = ".", group = ",", group_size = 3 },
  ["en-US"] = { decimal = ".", group = ",", group_size = 3 },
  ["en-GB"] = { decimal = ".", group = ",", group_size = 3 },
  ["de"] = { decimal = ",", group = ".", group_size = 3 },
  ["de-DE"] = { decimal = ",", group = ".", group_size = 3 },
  ["fr"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 }, -- narrow no-break space U+202F approximated as nbsp
  ["fr-FR"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 },
  ["ja"] = { decimal = ".", group = ",", group_size = 3 },
  ["ja-JP"] = { decimal = ".", group = ",", group_size = 3 },
  ["zh"] = { decimal = ".", group = ",", group_size = 3 },
  ["zh-CN"] = { decimal = ".", group = ",", group_size = 3 },
  ["ko"] = { decimal = ".", group = ",", group_size = 3 },
  ["ko-KR"] = { decimal = ".", group = ",", group_size = 3 },
  ["ar"] = { decimal = ".", group = ",", group_size = 3 },
  ["ar-SA"] = { decimal = ".", group = ",", group_size = 3 },
  ["ru"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 },
  ["ru-RU"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 },
  ["es"] = { decimal = ",", group = ".", group_size = 3 },
  ["es-ES"] = { decimal = ",", group = ".", group_size = 3 },
  ["pt"] = { decimal = ",", group = ".", group_size = 3 },
  ["pt-BR"] = { decimal = ",", group = ".", group_size = 3 },
  ["it"] = { decimal = ",", group = ".", group_size = 3 },
  ["it-IT"] = { decimal = ",", group = ".", group_size = 3 },
  ["pl"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 },
  ["pl-PL"] = { decimal = ",", group = "\xc2\xa0", group_size = 3 },
  ["tr"] = { decimal = ",", group = ".", group_size = 3 },
  ["tr-TR"] = { decimal = ",", group = ".", group_size = 3 },
}

-- Currency data: { symbol, position } where position is "prefix" or "suffix"
-- position is per-locale; here we store the default/en position.
local CURRENCY_DATA = {
  USD = { symbol = "$",  position = "prefix" },
  EUR = { symbol = "\xe2\x82\xac", position = "prefix" },  -- €
  GBP = { symbol = "\xc2\xa3", position = "prefix" },      -- £
  JPY = { symbol = "\xc2\xa5", position = "prefix" },      -- ¥
  CNY = { symbol = "\xc2\xa5", position = "prefix" },      -- ¥
  INR = { symbol = "\xe2\x82\xb9", position = "prefix" },  -- ₹
  CAD = { symbol = "CA$", position = "prefix" },
  AUD = { symbol = "A$",  position = "prefix" },
  CHF = { symbol = "CHF ", position = "prefix" },
  KRW = { symbol = "\xe2\x82\xa9", position = "prefix" },  -- ₩
  MXN = { symbol = "MX$", position = "prefix" },
  BRL = { symbol = "R$",  position = "prefix" },
  SEK = { symbol = "kr",  position = "suffix" },
  NOK = { symbol = "kr",  position = "suffix" },
  DKK = { symbol = "kr.",  position = "suffix" },
  RUB = { symbol = "\xe2\x82\xbd", position = "suffix" },  -- ₽
  TRY = { symbol = "\xe2\x82\xba", position = "prefix" },  -- ₺
  PLN = { symbol = "z\xc5\x82", position = "suffix" },     -- zł
  SGD = { symbol = "S$",  position = "prefix" },
  HKD = { symbol = "HK$", position = "prefix" },
  NZD = { symbol = "NZ$", position = "prefix" },
  ZAR = { symbol = "R",   position = "prefix" },
  THB = { symbol = "\xe0\xb8\xbf", position = "prefix" },  -- ฿
  SAR = { symbol = "\xd8\xb1.\xd8\xb3", position = "suffix" },
  AED = { symbol = "\xd8\xaf.\xd8\xa5", position = "suffix" },
}

-- Currency position overrides by locale: locale -> { currency -> position }
local CURRENCY_POSITION_OVERRIDES = {
  ["de-DE"] = { EUR = "suffix" },
  ["de"]    = { EUR = "suffix" },
  ["fr-FR"] = { EUR = "suffix" },
  ["fr"]    = { EUR = "suffix" },
}

-- Relative time thresholds (in seconds)
local REL_THRESHOLDS = {
  { limit = 45,        unit = "second",  factor = 1 },
  { limit = 45 * 60,   unit = "minute",  factor = 60 },
  { limit = 22 * 3600, unit = "hour",    factor = 3600 },
  { limit = 26 * 86400, unit = "day",   factor = 86400 },
  { limit = 320 * 86400, unit = "month", factor = 30 * 86400 },
  { limit = math.huge,  unit = "year",   factor = 365 * 86400 },
}

-- Relative time templates: locale -> { past_singular, past_plural, future_singular, future_plural, just_now }
-- where {n} is replaced with the count.
local REL_TEMPLATES = {
  ["en"] = {
    just_now = "just now",
    past = function(n, unit)
      if unit == "second" then return n == 1 and "1 second ago" or n.." seconds ago"
      elseif unit == "minute" then return n == 1 and "1 minute ago" or n.." minutes ago"
      elseif unit == "hour" then return n == 1 and "1 hour ago" or n.." hours ago"
      elseif unit == "day" then return n == 1 and "yesterday" or n.." days ago"
      elseif unit == "month" then return n == 1 and "last month" or n.." months ago"
      else return n == 1 and "last year" or n.." years ago" end
    end,
    future = function(n, unit)
      if unit == "second" then return n == 1 and "in 1 second" or "in "..n.." seconds"
      elseif unit == "minute" then return n == 1 and "in 1 minute" or "in "..n.." minutes"
      elseif unit == "hour" then return n == 1 and "in 1 hour" or "in "..n.." hours"
      elseif unit == "day" then return n == 1 and "tomorrow" or "in "..n.." days"
      elseif unit == "month" then return n == 1 and "next month" or "in "..n.." months"
      else return n == 1 and "next year" or "in "..n.." years" end
    end,
  },
  ["fr"] = {
    just_now = "à l'instant",
    past = function(n, unit)
      local units = { second="seconde", minute="minute", hour="heure", day="jour", month="mois", year="an" }
      local u = units[unit] or unit
      if unit == "day" and n == 1 then return "hier"
      elseif unit == "month" and n == 1 then return "le mois dernier"
      elseif unit == "year" and n == 1 then return "l'année dernière"
      else return "il y a "..n.." "..u..(n > 1 and unit ~= "mois" and "s" or "") end
    end,
    future = function(n, unit)
      local units = { second="seconde", minute="minute", hour="heure", day="jour", month="mois", year="an" }
      local u = units[unit] or unit
      if unit == "day" and n == 1 then return "demain"
      elseif unit == "month" and n == 1 then return "le mois prochain"
      elseif unit == "year" and n == 1 then return "l'année prochaine"
      else return "dans "..n.." "..u..(n > 1 and unit ~= "mois" and "s" or "") end
    end,
  },
  ["de"] = {
    just_now = "gerade eben",
    past = function(n, unit)
      local units = { second="Sekunde", minute="Minute", hour="Stunde", day="Tag", month="Monat", year="Jahr" }
      local u = units[unit] or unit
      local plurals = { second="Sekunden", minute="Minuten", hour="Stunden", day="Tagen", month="Monaten", year="Jahren" }
      if unit == "day" and n == 1 then return "gestern"
      elseif n == 1 then return "vor einer "..u
      else return "vor "..n.." "..(plurals[unit] or u) end
    end,
    future = function(n, unit)
      local units = { second="Sekunde", minute="Minute", hour="Stunde", day="Tag", month="Monat", year="Jahr" }
      local u = units[unit] or unit
      local plurals = { second="Sekunden", minute="Minuten", hour="Stunden", day="Tagen", month="Monaten", year="Jahren" }
      if unit == "day" and n == 1 then return "morgen"
      elseif n == 1 then return "in einer "..u
      else return "in "..n.." "..(plurals[unit] or u) end
    end,
  },
}

-- Month/weekday names for date formatting (en default)
local MONTH_NAMES = {
  en = {
    full  = {"January","February","March","April","May","June","July","August","September","October","November","December"},
    short = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"},
  },
  de = {
    full  = {"Januar","Februar","März","April","Mai","Juni","Juli","August","September","Oktober","November","Dezember"},
    short = {"Jan","Feb","Mär","Apr","Mai","Jun","Jul","Aug","Sep","Okt","Nov","Dez"},
  },
  fr = {
    full  = {"janvier","février","mars","avril","mai","juin","juillet","août","septembre","octobre","novembre","décembre"},
    short = {"janv.","févr.","mars","avr.","mai","juin","juil.","août","sept.","oct.","nov.","déc."},
  },
}
local WEEKDAY_NAMES = {
  en = {
    full  = {"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"},
    short = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"},
  },
  de = {
    full  = {"Sonntag","Montag","Dienstag","Mittwoch","Donnerstag","Freitag","Samstag"},
    short = {"So","Mo","Di","Mi","Do","Fr","Sa"},
  },
  fr = {
    full  = {"dimanche","lundi","mardi","mercredi","jeudi","vendredi","samedi"},
    short = {"dim.","lun.","mar.","mer.","jeu.","ven.","sam."},
  },
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Resolve a locale string to (language, region, script) parts.
local function parse_locale_string(s)
  if type(s) ~= "string" then return nil, "locale must be a string" end
  local lang, script, region
  -- Patterns: ll, ll-RR, ll-Ssss, ll-Ssss-RR
  local a, b, c = s:match("^([a-zA-Z]+)%-([a-zA-Z]+)%-([a-zA-Z]+)$")
  if a and b and c then
    local sa = a --[[:! string]]
    local sb = b --[[:! string]]
    local sc = c --[[:! string]]
    lang = sa:lower()
    if #sb == 4 then script = sb:sub(1,1):upper()..sb:sub(2):lower(); region = sc:upper()
    else region = sb:upper(); script = nil end -- unusual, treat b as region
  else
    local p, q = s:match("^([a-zA-Z]+)%-([a-zA-Z]+)$")
    if p and q then
      local sp = p --[[:! string]]
      local sq = q --[[:! string]]
      lang = sp:lower()
      if #sq == 4 then script = sq:sub(1,1):upper()..sq:sub(2):lower()
      else region = sq:upper() end
    else
      lang = s:lower()
    end
  end
  if not lang or #lang == 0 then return nil, "invalid locale: "..s end
  return lang, region, script
end

-- Return the number format descriptor for a locale, falling back to "en".
--: (locale_str: string) -> NumFmt
local function get_number_format(locale_str)
  local nf = NUMBER_FORMATS --[[: { [string]: NumFmt }]]
  return nf[locale_str]
    or nf[locale_str:match("^([^%-]+)") or ""]
    or nf["en"]
end

-- Insert group separators into an integer string (left of decimal).
--: (int_str: string, sep: string, group_size: integer) -> string
local function insert_groups(int_str, sep, group_size)
  local result = {}
  local len = #int_str
  local first_group = len % group_size
  if first_group == 0 then first_group = group_size end
  result[#result+1] = int_str:sub(1, first_group)
  local pos = first_group + 1
  while pos <= len do
    result[#result+1] = sep
    result[#result+1] = int_str:sub(pos, pos + group_size - 1)
    pos = pos + group_size
  end
  return table.concat(result)
end

-- Interpolate {name} placeholders in a template string.
local function interpolate(template, params)
  if not params then return template end
  return (template:gsub("{([^}]+)}", function(key)
    local v = params[key]
    if v == nil then return "{"..key.."}" end
    return tostring(v)
  end))
end

-- Get the language tag from a locale object or string.
local function locale_lang(loc)
  if type(loc) == "table" then return loc.language or "en" end
  return (tostring(loc):match("^([^%-]+)") or "en"):lower()
end

-- Get locale string (full tag) for lookups.
local function locale_tag(loc)
  if type(loc) == "string" then return loc end
  if type(loc) ~= "table" then return "en" end
  local loc_ = loc --[[:! { language: unknown, script: unknown, region: unknown, ... }]]
  local s = loc_.language --[[:! string | nil]] or "en"
  if loc_.script then s = s.."-"..(loc_.script --[[:! string]]) end
  if loc_.region then s = s.."-"..(loc_.region --[[:! string]]) end
  return s
end

-- ---------------------------------------------------------------------------
-- Locale descriptor
-- ---------------------------------------------------------------------------

-- M.locale(locale_string) -> locale_obj | (nil, errmsg)
--: (string) -> ({ language: string, region: string | nil, script: string | nil } | nil, string)
function M.locale(s)
  local lang, region, script = parse_locale_string(s)
  if not lang then return nil, region end -- region carries errmsg here
  return { language = lang, region = region, script = script }
end

-- ---------------------------------------------------------------------------
-- Plural rules
-- ---------------------------------------------------------------------------

-- CLDR plural rules for common languages.
-- Returns a function: (n: number) -> "zero"|"one"|"two"|"few"|"many"|"other"

local PLURAL_RULES = {}

-- English: 1 → "one", else "other"
PLURAL_RULES["en"] = function(n)
  return n == 1 and "one" or "other"
end

-- French: 0 and 1 → "one", else "other"
PLURAL_RULES["fr"] = function(n)
  return (n == 0 or n == 1) and "one" or "other"
end

-- German, Dutch: 1 → "one", else "other"
PLURAL_RULES["de"] = PLURAL_RULES["en"]
PLURAL_RULES["nl"] = PLURAL_RULES["en"]

-- Spanish, Italian, Portuguese: 1 → "one", else "other"
PLURAL_RULES["es"] = PLURAL_RULES["en"]
PLURAL_RULES["it"] = PLURAL_RULES["en"]
PLURAL_RULES["pt"] = PLURAL_RULES["en"]

-- Turkish, Japanese, Chinese, Korean: always "other"
PLURAL_RULES["tr"] = function(_n) return "other" end
PLURAL_RULES["ja"] = PLURAL_RULES["tr"]
PLURAL_RULES["zh"] = PLURAL_RULES["tr"]
PLURAL_RULES["ko"] = PLURAL_RULES["tr"]

-- Russian / Ukrainian: complex CLDR rule
-- one: n%10=1 and n%100≠11
-- few: n%10∈{2,3,4} and n%100∉{12,13,14}
-- many: n%10=0 or n%10∈{5-9} or n%100∈{11,12,13,14}
-- other: fractional
PLURAL_RULES["ru"] = function(n)
  local m10  = n % 10
  local m100 = n % 100
  if m10 == 1 and m100 ~= 11 then return "one" end
  if m10 >= 2 and m10 <= 4 and (m100 < 10 or m100 > 14) then return "few" end
  if m10 == 0 or (m10 >= 5 and m10 <= 9) or (m100 >= 11 and m100 <= 14) then return "many" end
  return "other"
end
PLURAL_RULES["uk"] = PLURAL_RULES["ru"]

-- Polish: one=1; few=n%10∈{2,3,4} and n%100∉{12,13,14}; many=rest
PLURAL_RULES["pl"] = function(n)
  local m10  = n % 10
  local m100 = n % 100
  if n == 1 then return "one" end
  if m10 >= 2 and m10 <= 4 and (m100 < 10 or m100 > 14) then return "few" end
  return "many"
end

-- Arabic: zero/one/two/few/many/other
PLURAL_RULES["ar"] = function(n)
  local m100 = n % 100
  if n == 0 then return "zero" end
  if n == 1 then return "one" end
  if n == 2 then return "two" end
  if m100 >= 3 and m100 <= 10 then return "few" end
  if m100 >= 11 and m100 <= 99 then return "many" end
  return "other"
end

-- M.plural_rule(locale_string) -> fn(n) -> category
--: (string) -> (number) -> string
function M.plural_rule(locale_str)
  local lang = (locale_str:match("^([^%-]+)") or locale_str):lower()
  return PLURAL_RULES[lang] or PLURAL_RULES["en"]
end

-- ---------------------------------------------------------------------------
-- Message catalog
-- ---------------------------------------------------------------------------

--:: CatalogObj = { _messages: { [string]: string }, _plurals: { [string]: { [string]: string } }, _locale: unknown, _plural_fn: (n: number) -> string }
local catalog_mt = {}
catalog_mt.__index = catalog_mt

-- catalog:add(key, template) -> catalog
--: (self: CatalogObj, key: string, template: string) -> CatalogObj
function catalog_mt:add(key, template)
  self._messages[key] = template
  return self
end

-- catalog:add_plural(key, forms) -> catalog
-- forms: { one="...", other="...", few="...", ... }
--: (self: CatalogObj, key: string, forms: { [string]: string }) -> CatalogObj
function catalog_mt:add_plural(key, forms)
  self._plurals[key] = forms
  return self
end

-- catalog:add_all(messages) -> catalog
--: (self: CatalogObj, messages: { [string]: string }) -> CatalogObj
function catalog_mt:add_all(messages)
  for k, v in pairs(messages) do
    self._messages[k] = v
  end
  return self
end

-- catalog:t(key, params?) -> string
--: (self: CatalogObj, key: string, params: { [string]: unknown } | nil) -> string
function catalog_mt:t(key, params)
  local template = self._messages[key]
  if not template then return key end
  return interpolate(template, params)
end

-- catalog:tn(key, n, params?) -> string
--: (self: CatalogObj, key: string, n: number, params: { [string]: unknown } | nil) -> string
function catalog_mt:tn(key, n, params)
  local forms = self._plurals[key]
  if not forms then return key end
  local category = self._plural_fn(n)
  local template = forms[category] or forms["other"] or key
  local p = params or {}
  p.n = p.n or n
  return interpolate(template, p)
end

-- M.catalog(locale_obj_or_string) -> catalog
--: (string | { language: string, region: string | nil, script: string | nil }) -> unknown
function M.catalog(loc)
  local lang = locale_lang(loc)
  local obj = setmetatable({
    _messages  = {},
    _plurals   = {},
    _locale    = loc,
    _plural_fn = PLURAL_RULES[lang] or PLURAL_RULES["en"],
  }, catalog_mt)
  return obj
end

-- ---------------------------------------------------------------------------
-- Number formatting
-- ---------------------------------------------------------------------------

-- Format an integer-part string with group separators.
-- Returns formatted string.
--: (int_str: string, fmt: NumFmt, use_group: boolean) -> string
local function format_integer_part(int_str, fmt, use_group)
  if use_group and #int_str > fmt.group_size then
    return insert_groups(int_str, fmt.group, fmt.group_size)
  end
  return int_str
end

-- M.format_number(n, locale, opts) -> string | (nil, errmsg)
-- opts: { decimals, min_decimals, max_decimals, group_sep }
--: (number, string | { language: string, region: string | nil, script: string | nil }, { decimals: number | nil, min_decimals: number | nil, max_decimals: number | nil, group_sep: boolean | nil } | nil) -> (string | nil, string)
function M.format_number(n, locale, opts)
  if type(n) ~= "number" then return nil, "n must be a number" end
  local o = opts or { decimals = nil, min_decimals = nil, max_decimals = nil, group_sep = nil }
  local loc_tag = locale_tag(locale)
  local fmt = get_number_format(loc_tag)
  local use_group = o.group_sep ~= false -- default true

  local neg = n < 0
  local abs_n = neg and -n or n

  -- Determine decimal places
  local decimals = o.decimals
  local min_dec  = o.min_decimals or decimals or 0
  local max_dec  = o.max_decimals or decimals

  local int_part = "" --: string
  local frac_part = "" --: string
  if max_dec ~= nil then
    local formatted = string.format("%."..max_dec.."f", abs_n)
    local ip, fp = formatted:match("^(%d+)%.?(%d*)$")
    int_part = ip or ""
    frac_part = fp or ""
  else
    -- auto: show fractional digits if present
    local s = string.format("%.10g", abs_n)
    local ip, fp = s:match("^(%d+)%.(%d+)$")
    if ip and fp then
      int_part, frac_part = ip, fp
    else
      int_part = s:match("^(%d+)$") or "0"
      frac_part = ""
    end
  end

  -- Enforce min_decimals
  if #frac_part < min_dec then
    frac_part = frac_part .. string.rep("0", math.floor(min_dec - #frac_part))
  end

  local result = format_integer_part(int_part, fmt, use_group)
  if #frac_part > 0 then
    result = result .. fmt.decimal .. frac_part
  end
  if neg then result = "-" .. result end
  return result
end

-- M.parse_number(str, locale) -> number | nil
--: (string, string | { language: string, region: string | nil, script: string | nil }) -> number | nil
function M.parse_number(str, locale)
  if type(str) ~= "string" then return nil end
  local loc_tag = locale_tag(locale)
  local fmt = get_number_format(loc_tag)
  -- Escape a string for use as a Lua pattern literal
  --: (s: string) -> string
  local function esc(s)
    local r, _ = s:gsub("([%.%+%-%*%?%[%^%$%(%)%%])", "%%%1")
    return r
  end
  -- Remove group separators, replace decimal with "."
  local s = str:gsub(esc(fmt.group), "")
  if fmt.decimal ~= "." then
    s = s:gsub(esc(fmt.decimal), ".", 1)
  end
  local n = tonumber(s)
  return n
end

-- M.format_currency(n, currency, locale, opts) -> string | (nil, errmsg)
--: (number, string, string | { language: string, region: string | nil, script: string | nil }, { decimals: number | nil, group_sep: boolean | nil } | nil) -> (string | nil, string)
function M.format_currency(n, currency, locale, opts)
  currency = currency:upper()
  local cd_table = CURRENCY_DATA --[[: { [string]: { symbol: string, position: string } }]]
  local cd = cd_table[currency]
  if not cd then return nil, "unknown currency: "..currency end

  local loc_tag = locale_tag(locale)
  local num_opts --: { decimals: number | nil, min_decimals: number | nil, max_decimals: number | nil, group_sep: boolean | nil } | nil
  if opts then
    num_opts = { decimals = opts.decimals or 2, group_sep = opts.group_sep, min_decimals = nil, max_decimals = nil }
  else
    num_opts = { decimals = 2, group_sep = nil, min_decimals = nil, max_decimals = nil }
  end

  local num_str, err = M.format_number(n, locale, num_opts)
  if not num_str then return nil, err end

  -- Determine position: check locale override first, then default
  local position = cd.position
  local ov_table = CURRENCY_POSITION_OVERRIDES --[[: { [string]: { [string]: string } }]]
  local overrides = ov_table[loc_tag] or ov_table[locale_lang(locale)]
  if overrides and overrides[currency] then
    position = overrides[currency]
  end

  if position == "prefix" then
    return cd.symbol .. num_str
  else
    return num_str .. "\xc2\xa0" .. cd.symbol -- narrow no-break before suffix symbol
  end
end

-- ---------------------------------------------------------------------------
-- Date/time formatting
-- ---------------------------------------------------------------------------

-- Simple os.date-based implementation.
-- timestamp: Unix timestamp (number) or nil for current time.
-- opts: { style="full"|"long"|"medium"|"short", date=true, time=false }

-- M.format_date(timestamp, locale, opts) -> string
-- opts.date_fn: function compatible with os.date (required)
--: (number | nil, string | { language: string, region: string | nil, script: string | nil }, { style: string | nil, date: boolean | nil, time: boolean | nil, date_fn: (string, (number | nil)) -> unknown }) -> string
function M.format_date(timestamp, locale, opts)
  local style = opts.style or "medium"
  local show_date = opts.date ~= false  -- default true
  local show_time = opts.time == true   -- default false
  local t_raw = opts.date_fn("*t", timestamp)
  if type(t_raw) ~= "table" then return "" end
  local t = t_raw --[[: { [string]: integer }]]
  local lang = locale_lang(locale)
  local months = (MONTH_NAMES[lang] or MONTH_NAMES["en"])
  local wdays  = (WEEKDAY_NAMES[lang] or WEEKDAY_NAMES["en"])

  local parts = {}

  if show_date then
    if style == "full" then
      -- "Monday, January 1, 2024"
      local wday_name = wdays.full[t.wday] or ""
      local month_name = months.full[t.month] or ""
      if lang == "de" then
        parts[#parts+1] = string.format("%s, %d. %s %d", wday_name, t.day, month_name, t.year)
      elseif lang == "fr" then
        parts[#parts+1] = string.format("%s %d %s %d", wday_name, t.day, month_name, t.year)
      else
        parts[#parts+1] = string.format("%s, %s %d, %d", wday_name, month_name, t.day, t.year)
      end
    elseif style == "long" then
      local month_name = months.full[t.month] or ""
      if lang == "de" then
        parts[#parts+1] = string.format("%d. %s %d", t.day, month_name, t.year)
      elseif lang == "fr" then
        parts[#parts+1] = string.format("%d %s %d", t.day, month_name, t.year)
      else
        parts[#parts+1] = string.format("%s %d, %d", month_name, t.day, t.year)
      end
    elseif style == "medium" then
      local month_short = months.short[t.month] or ""
      if lang == "de" then
        parts[#parts+1] = string.format("%d. %s %d", t.day, month_short, t.year)
      elseif lang == "fr" then
        parts[#parts+1] = string.format("%d %s %d", t.day, month_short, t.year)
      else
        parts[#parts+1] = string.format("%s %d, %d", month_short, t.day, t.year)
      end
    else -- short
      if lang == "de" then
        parts[#parts+1] = string.format("%d.%02d.%d", t.day, t.month, t.year)
      elseif lang == "fr" then
        parts[#parts+1] = string.format("%02d/%02d/%d", t.day, t.month, t.year)
      else
        parts[#parts+1] = string.format("%d/%d/%d", t.month, t.day, t.year)
      end
    end
  end

  if show_time then
    parts[#parts+1] = string.format("%02d:%02d:%02d", t.hour, t.min, t.sec)
  end

  return table.concat(parts, ", ")
end

-- M.format_relative(seconds_diff, locale) -> string
-- seconds_diff: positive = future, negative = past
--: (number, string | { language: string, region: string | nil, script: string | nil }) -> string
function M.format_relative(seconds_diff, locale)
  local lang = locale_lang(locale)
  local rt = REL_TEMPLATES --[[: { [string]: { just_now: string, past: (integer, string) -> string, future: (integer, string) -> string } }]]
  local tmpl = rt[lang] or rt["en"]
  local abs_diff = seconds_diff < 0 and -seconds_diff or seconds_diff
  local is_past  = seconds_diff <= 0

  -- "just now" threshold: within 15 seconds
  if abs_diff < 15 then return tmpl.just_now end

  local chosen_unit  = "second"
  local chosen_factor = 1
  for _, entry in ipairs(REL_THRESHOLDS) do
    if abs_diff < entry.limit then
      chosen_unit   = entry.unit
      chosen_factor = entry.factor
      break
    end
  end

  local n = math.floor(abs_diff / chosen_factor + 0.5)
  if is_past then
    return tmpl.past(n, chosen_unit)
  else
    return tmpl.future(n, chosen_unit)
  end
end

-- ---------------------------------------------------------------------------
-- Text utilities
-- ---------------------------------------------------------------------------

-- M.collate(strings, locale) -> sorted table (new copy)
-- Locale-aware sort. In pure Lua we use a simple Unicode code-point comparison;
-- for production use, callers can swap in a locale-specific comparator.
-- German: ä/ö/ü treated as base letters for sort (approximate).
--: ({ string }, string | { language: string, region: string | nil, script: string | nil }) -> { string }
function M.collate(strings, locale)
  local lang = locale_lang(locale)
  local result = {}
  for i, s in ipairs(strings) do result[i] = s end

  -- Locale-specific normalization for sort key (pure, approximate)
  local function sort_key(s)
    if lang == "de" then
      -- German: replace umlauts with base+e for sort
      s = s:gsub("\xc3\xa4", "ae"):gsub("\xc3\xb6", "oe"):gsub("\xc3\xbc", "ue")
            :gsub("\xc3\x84", "Ae"):gsub("\xc3\x96", "Oe"):gsub("\xc3\x9c", "Ue")
            :gsub("\xc3\x9f", "ss")
    elseif lang == "fr" then
      -- French: strip diacritics for sort (approximate)
      s = s:gsub("\xc3\xa0", "a"):gsub("\xc3\xa2", "a"):gsub("\xc3\xa9", "e")
            :gsub("\xc3\xa8", "e"):gsub("\xc3\xaa", "e"):gsub("\xc3\xab", "e")
            :gsub("\xc3\xae", "i"):gsub("\xc3\xaf", "i"):gsub("\xc3\xb4", "o")
            :gsub("\xc3\xb9", "u"):gsub("\xc3\xbb", "u"):gsub("\xc3\xbc", "u")
            :gsub("\xc3\xa7", "c")
    end
    return s:lower()
  end

  table.sort(result, function(a, b)
    return sort_key(a) < sort_key(b)
  end)
  return result
end

-- M.to_upper(str, locale) -> string
--: (string, string | { language: string, region: string | nil, script: string | nil }) -> string
function M.to_upper(str, locale)
  local lang = locale_lang(locale)
  local s = str:upper()
  if lang == "tr" or lang == "az" then
    -- Turkish: lowercase i → İ (dotted capital I), not I
    s = str:gsub("i", "\xc4\xb0"):gsub("I", "I") -- best-effort in pure Lua
    s = s:upper()
    -- Revert "I" to dotted where needed (approximation)
  end
  return s
end

-- M.to_lower(str, locale) -> string
--: (string, string | { language: string, region: string | nil, script: string | nil }) -> string
function M.to_lower(str, locale)
  local lang = locale_lang(locale)
  local s = str:lower()
  if lang == "tr" or lang == "az" then
    -- Turkish: uppercase I → ı (dotless), İ → i
    s = str:gsub("\xc4\xb0", "i"):lower()
  end
  return s
end

-- M.word_count(text) -> integer
-- Count words split by whitespace.
--: (string) -> number
function M.word_count(text)
  local count = 0
  for _ in text:gmatch("%S+") do count = count + 1 end
  return count
end

-- M.truncate(text, max_chars, ellipsis?) -> string
-- Character-aware truncation (counts UTF-8 codepoints, not bytes).
-- ellipsis defaults to "…" (U+2026).
--: (string, number, string | nil) -> string
function M.truncate(text, max_chars, ellipsis)
  ellipsis = ellipsis or "\xe2\x80\xa6" -- …

  -- Count UTF-8 codepoints
  local function utf8_len(s)
    local n = 0
    local i = 1
    while i <= #s do
      local b = string.byte(s, i)
      if b < 0x80 then i = i + 1
      elseif b < 0xE0 then i = i + 2
      elseif b < 0xF0 then i = i + 3
      else i = i + 4 end
      n = n + 1
    end
    return n
  end

  -- Advance by n codepoints, return byte position after them
  local function utf8_advance(s, n)
    local i = 1
    local count = 0
    while i <= #s and count < n do
      local b = string.byte(s, i)
      if b < 0x80 then i = i + 1
      elseif b < 0xE0 then i = i + 2
      elseif b < 0xF0 then i = i + 3
      else i = i + 4 end
      count = count + 1
    end
    return i
  end

  local ell_len = utf8_len(ellipsis)
  local text_len = utf8_len(text)
  if text_len <= max_chars then return text end

  -- Truncate to max_chars - ell_len codepoints, then append ellipsis
  local keep = max_chars - ell_len
  if keep <= 0 then
    -- ellipsis itself may be too long; just return first max_chars codepoints
    local pos = utf8_advance(text, max_chars)
    return text:sub(1, pos - 1)
  end

  local pos = utf8_advance(text, keep)
  return text:sub(1, pos - 1) .. ellipsis
end

return M
