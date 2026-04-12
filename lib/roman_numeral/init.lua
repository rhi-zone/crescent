-- lib/roman_numeral/init.lua
-- Roman numeral conversion with full Unicode and extended forms support.
-- Supports standard subtractive notation, additive notation, vinculum
-- (parenthesis) large numbers, Unicode precomposed characters, and ordinal forms.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

M.MIN = 1
M.MAX = 3999

-- ---------------------------------------------------------------------------
-- Internal tables
-- ---------------------------------------------------------------------------

-- Subtractive encoding table: descending order of value
local SUBTRACTIVE = {
  { 1000, "M"  },
  {  900, "CM" },
  {  500, "D"  },
  {  400, "CD" },
  {  100, "C"  },
  {   90, "XC" },
  {   50, "L"  },
  {   40, "XL" },
  {   10, "X"  },
  {    9, "IX" },
  {    5, "V"  },
  {    4, "IV" },
  {    1, "I"  },
}

-- Additive encoding table: descending order of value
local ADDITIVE = {
  { 1000, "M" },
  {  500, "D" },
  {  100, "C" },
  {   50, "L" },
  {   10, "X" },
  {    5, "V" },
  {    1, "I" },
}

-- Symbol values for decoding (uppercase)
local SYMBOL_VALUE = {
  I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000,
}

-- ---------------------------------------------------------------------------
-- to_roman / from_roman (standard, 1-3999)
-- ---------------------------------------------------------------------------

--- Encode an integer (1-3999) to a standard Roman numeral string.
-- Returns string, or (nil, errmsg) on error.
M.to_roman = function(n)
  if type(n) ~= "number" or n ~= math.floor(n) then
    return nil, "roman_numeral.to_roman: expected integer, got " .. tostring(n)
  end
  if n < 1 or n > 3999 then
    return nil, "roman_numeral.to_roman: value out of range [1, 3999], got " .. tostring(n)
  end
  local parts = {}
  local remaining = n
  for _, pair in ipairs(SUBTRACTIVE) do
    local val, sym = pair[1], pair[2]
    while remaining >= val do
      parts[#parts + 1] = sym
      remaining = remaining - val
    end
  end
  local result = ""
  for i = 1, #parts do result = result .. parts[i] end
  return result
end

--- Decode a Roman numeral string to an integer.
-- Accepts both subtractive and additive notation, case-insensitive.
-- Returns integer, or (nil, errmsg) on error.
M.from_roman = function(s)
  if type(s) ~= "string" or #s == 0 then
    return nil, "roman_numeral.from_roman: expected non-empty string"
  end
  local upper = s:upper()
  for i = 1, #upper do
    local ch = upper:sub(i, i)
    if not SYMBOL_VALUE[ch] then
      return nil, "roman_numeral.from_roman: invalid character '" .. ch .. "'"
    end
  end
  local total = 0
  local len = #upper
  for i = 1, len do
    local cur = SYMBOL_VALUE[upper:sub(i, i)]
    local nxt = i < len and SYMBOL_VALUE[upper:sub(i + 1, i + 1)] or 0
    if cur < nxt then
      total = total - cur
    else
      total = total + cur
    end
  end
  if total <= 0 then
    return nil, "roman_numeral.from_roman: decoded value is not positive"
  end
  return total
end

-- ---------------------------------------------------------------------------
-- valid (strict canonical subtractive form only)
-- ---------------------------------------------------------------------------

--- Return true if s is a valid, canonical Roman numeral in subtractive form.
-- IIII, IIX, etc. are false. Case-insensitive.
M.valid = function(s)
  if type(s) ~= "string" or #s == 0 then return false end
  local n, _ = M.from_roman(s)
  if not n then return false end
  -- Re-encode and compare canonically
  local canonical = M.to_roman(n)
  if not canonical then return false end
  return s:upper() == canonical
end

-- ---------------------------------------------------------------------------
-- to_roman_additive (historical additive form)
-- ---------------------------------------------------------------------------

--- Encode an integer (1-3999) using additive (non-subtractive) notation.
-- E.g. 4 -> "IIII", 9 -> "VIIII"
M.to_roman_additive = function(n)
  if type(n) ~= "number" or n ~= math.floor(n) then
    return nil, "roman_numeral.to_roman_additive: expected integer, got " .. tostring(n)
  end
  if n < 1 or n > 3999 then
    return nil, "roman_numeral.to_roman_additive: value out of range [1, 3999], got " .. tostring(n)
  end
  local parts = {}
  local remaining = n
  for _, pair in ipairs(ADDITIVE) do
    local val, sym = pair[1], pair[2]
    while remaining >= val do
      parts[#parts + 1] = sym
      remaining = remaining - val
    end
  end
  local result = ""
  for i = 1, #parts do result = result .. parts[i] end
  return result
end

-- ---------------------------------------------------------------------------
-- Vinculum / large numbers via parenthesis notation
-- (V) = 5000, (X) = 10000, (L) = 50000, (C) = 100000, (D) = 500000, (M) = 1000000
-- General rule: any Roman numeral in parentheses is multiplied by 1000.
-- ---------------------------------------------------------------------------

-- Vinculum subtractive table (values / 1000, represented as the inner numerals)
-- The vinculum part covers 1000-3999999 by encoding the high (thousands) part
-- using the same subtractive rules but with the symbols multiplied by 1000.

local VINCULUM_SUBTRACTIVE = {
  { 1000000, "M"  },
  {  900000, "CM" },
  {  500000, "D"  },
  {  400000, "CD" },
  {  100000, "C"  },
  {   90000, "XC" },
  {   50000, "L"  },
  {   40000, "XL" },
  {   10000, "X"  },
  {    9000, "IX" },
  {    5000, "V"  },
  {    4000, "IV" },
}

--- Encode an integer to Roman numerals with vinculum (parenthesis) for values >= 4000.
-- The part >= 4000 is expressed as parenthesized Roman numerals (each = *1000),
-- followed by the standard Roman numeral for the remainder (1-3999).
-- Values 1-3999 are encoded the same as to_roman.
-- Returns string, or (nil, errmsg) on error.
M.to_roman_large = function(n)
  if type(n) ~= "number" or n ~= math.floor(n) then
    return nil, "roman_numeral.to_roman_large: expected integer, got " .. tostring(n)
  end
  if n < 1 then
    return nil, "roman_numeral.to_roman_large: value must be >= 1, got " .. tostring(n)
  end
  -- Max supportable: (MMMCMXCIX)CMXCIX = 3999*1000 + 999 = 3999999
  if n > 3999999 then
    return nil, "roman_numeral.to_roman_large: value out of range [1, 3999999], got " .. tostring(n)
  end

  if n <= 3999 then
    return M.to_roman(n)
  end

  -- Extract the thousands part (vinculum) and the remainder
  local parts = {}
  local remaining = n

  -- Encode the vinculum portion
  local vinculum_parts = {}
  for _, pair in ipairs(VINCULUM_SUBTRACTIVE) do
    local val, sym = pair[1], pair[2]
    while remaining >= val do
      vinculum_parts[#vinculum_parts + 1] = sym
      remaining = remaining - val
    end
  end

  -- Build vinculum string
  local vinculum_str = ""
  for i = 1, #vinculum_parts do vinculum_str = vinculum_str .. vinculum_parts[i] end
  parts[#parts + 1] = "(" .. vinculum_str .. ")"

  -- Encode the remainder (0-3999)
  if remaining > 0 then
    local rem_str, err = M.to_roman(remaining)
    if not rem_str then return nil, err end
    parts[#parts + 1] = rem_str
  end

  local result = ""
  for i = 1, #parts do result = result .. parts[i] end
  return result
end

-- Vinculum symbol values (uppercase, inside parens)
local VINCULUM_SYMBOL_VALUE = {
  I = 1000, V = 5000, X = 10000, L = 50000, C = 100000, D = 500000, M = 1000000,
}

--- Decode a Roman numeral string with vinculum (parenthesis) notation.
-- Parenthesized portions are decoded with each symbol multiplied by 1000.
-- Returns integer, or (nil, errmsg) on error.
M.from_roman_large = function(s)
  if type(s) ~= "string" or #s == 0 then
    return nil, "roman_numeral.from_roman_large: expected non-empty string"
  end

  local total = 0
  local i = 1
  local len = #s

  -- Parse optional leading vinculum group: (...)
  if s:sub(i, i) == "(" then
    local close = s:find(")", i + 1, true)
    if not close then
      return nil, "roman_numeral.from_roman_large: unclosed '(' in vinculum"
    end
    local inner = s:sub(i + 1, close - 1):upper()
    if #inner == 0 then
      return nil, "roman_numeral.from_roman_large: empty vinculum group"
    end
    -- Validate and decode inner using vinculum symbol values
    for j = 1, #inner do
      local ch = inner:sub(j, j)
      if not VINCULUM_SYMBOL_VALUE[ch] then
        return nil, "roman_numeral.from_roman_large: invalid vinculum character '" .. ch .. "'"
      end
    end
    local ilen = #inner
    for j = 1, ilen do
      local cur = VINCULUM_SYMBOL_VALUE[inner:sub(j, j)]
      local nxt = j < ilen and VINCULUM_SYMBOL_VALUE[inner:sub(j + 1, j + 1)] or 0
      if cur < nxt then
        total = total - cur
      else
        total = total + cur
      end
    end
    i = close + 1
  end

  -- Parse optional trailing standard Roman numeral
  if i <= len then
    local tail = s:sub(i)
    local n, err = M.from_roman(tail)
    if not n then return nil, err end
    total = total + n
  end

  if total <= 0 then
    return nil, "roman_numeral.from_roman_large: decoded value is not positive"
  end

  return total
end

-- ---------------------------------------------------------------------------
-- to_ordinal
-- ---------------------------------------------------------------------------

-- Ordinal suffixes based on the trailing Roman numeral value (mod 10, mod 100 context)
-- Rules mirroring English ordinals:
--   1st (Ist), 2nd (IInd), 3rd (IIIrd), 4th+ (IVth, Vth, ...)
--   11th, 12th, 13th are special (like English)
-- We use the numeric value mod 10 / mod 100 to pick suffix.

--- Return the ordinal form of a Roman numeral: "Ist", "IInd", "IIIrd", "IVth", etc.
-- Returns string, or (nil, errmsg) on error.
M.to_ordinal = function(n)
  local roman, err = M.to_roman(n)
  if not roman then return nil, err end
  local mod100 = n % 100
  local mod10  = n % 10
  local suffix
  if mod100 >= 11 and mod100 <= 13 then
    suffix = "th"
  elseif mod10 == 1 then
    suffix = "st"
  elseif mod10 == 2 then
    suffix = "nd"
  elseif mod10 == 3 then
    suffix = "rd"
  else
    suffix = "th"
  end
  return roman .. suffix
end

-- ---------------------------------------------------------------------------
-- Unicode Roman numeral characters (U+2160..U+2188)
-- ---------------------------------------------------------------------------

-- Precomposed Unicode Roman numeral codepoints
-- U+2160 Ⅰ=1, U+2161 Ⅱ=2, U+2162 Ⅲ=3, U+2163 Ⅳ=4, U+2164 Ⅴ=5,
-- U+2165 Ⅵ=6, U+2166 Ⅶ=7, U+2167 Ⅷ=8, U+2168 Ⅸ=9, U+2169 Ⅹ=10,
-- U+216A Ⅺ=11, U+216B Ⅻ=12, U+216C Ⅼ=50, U+216D Ⅽ=100, U+216E Ⅾ=500,
-- U+216F Ⅿ=1000
-- U+2170..U+217F: lowercase forms (same values)
-- U+2180 ↀ=1000 (alternative), U+2181 ↁ=5000, U+2182 ↂ=10000
-- U+2183 Ↄ=100 (Claudian), U+2184 ↄ=6 (small), U+2185 ↅ=6, U+2186 ↆ=50
-- U+2187 ↇ=50000, U+2188 ↈ=100000
-- We support the standard block U+2160-U+216F (1-12, 50, 100, 500, 1000)

-- UTF-8 encoding of a Unicode codepoint
local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor((cp % 0x1000) / 0x40),
      0x80 + (cp % 0x40)
    )
  else
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor((cp % 0x40000) / 0x1000),
      0x80 + math.floor((cp % 0x1000) / 0x40),
      0x80 + (cp % 0x40)
    )
  end
end

-- Map from integer value to UTF-8 Unicode Roman numeral (uppercase, U+2160-U+216F)
local UNICODE_FROM_INT = {
  [1]    = utf8_char(0x2160),  -- Ⅰ
  [2]    = utf8_char(0x2161),  -- Ⅱ
  [3]    = utf8_char(0x2162),  -- Ⅲ
  [4]    = utf8_char(0x2163),  -- Ⅳ
  [5]    = utf8_char(0x2164),  -- Ⅴ
  [6]    = utf8_char(0x2165),  -- Ⅵ
  [7]    = utf8_char(0x2166),  -- Ⅶ
  [8]    = utf8_char(0x2167),  -- Ⅷ
  [9]    = utf8_char(0x2168),  -- Ⅸ
  [10]   = utf8_char(0x2169),  -- Ⅹ
  [11]   = utf8_char(0x216A),  -- Ⅺ
  [12]   = utf8_char(0x216B),  -- Ⅻ
  [50]   = utf8_char(0x216C),  -- Ⅼ
  [100]  = utf8_char(0x216D),  -- Ⅽ
  [500]  = utf8_char(0x216E),  -- Ⅾ
  [1000] = utf8_char(0x216F),  -- Ⅿ
}

-- Reverse map: UTF-8 string -> integer value
-- Covers both uppercase (U+2160-U+216F) and lowercase (U+2170-U+217F)
local UNICODE_TO_INT = {}
for v, u in pairs(UNICODE_FROM_INT) do
  UNICODE_TO_INT[u] = v
end
-- Lowercase forms (U+2170..U+217B = 1..12, U+217C=50, U+217D=100, U+217E=500, U+217F=1000)
local LOWERCASE_CODEPOINTS = {
  [0x2170]=1,[0x2171]=2,[0x2172]=3,[0x2173]=4,[0x2174]=5,[0x2175]=6,
  [0x2176]=7,[0x2177]=8,[0x2178]=9,[0x2179]=10,[0x217A]=11,[0x217B]=12,
  [0x217C]=50,[0x217D]=100,[0x217E]=500,[0x217F]=1000,
}
for cp, v in pairs(LOWERCASE_CODEPOINTS) do
  UNICODE_TO_INT[utf8_char(cp)] = v
end

--- Return the Unicode precomposed Roman numeral character for n.
-- Only values with a precomposed Unicode form are supported:
-- 1-12, 50, 100, 500, 1000.
-- Returns UTF-8 string, or nil if no precomposed form exists.
M.to_unicode = function(n)
  if type(n) ~= "number" then return nil end
  return UNICODE_FROM_INT[n]
end

--- Decode a Unicode precomposed Roman numeral character to an integer.
-- Accepts both uppercase (U+2160-U+216F) and lowercase (U+2170-U+217F) forms.
-- Returns integer, or nil if unrecognized.
M.from_unicode = function(s)
  if type(s) ~= "string" then return nil end
  return UNICODE_TO_INT[s]
end

-- ---------------------------------------------------------------------------
-- format
-- ---------------------------------------------------------------------------

--- Format n as a Roman numeral with options.
-- opts.style  = "standard" | "additive" | "unicode" | "large"  (default "standard")
-- opts.case   = "upper" | "lower"  (default "upper")
-- opts.ordinal = true/false  (default false; append ordinal suffix)
-- Returns string, or (nil, errmsg) on error.
M.format = function(n, opts)
  opts = opts or {}
  local style   = opts.style   or "standard"
  local case    = opts.case    or "upper"
  local ordinal = opts.ordinal or false

  local result, err

  if style == "standard" then
    result, err = M.to_roman(n)
  elseif style == "additive" then
    result, err = M.to_roman_additive(n)
  elseif style == "unicode" then
    result = M.to_unicode(n)
    if not result then
      return nil, "roman_numeral.format: no Unicode precomposed form for " .. tostring(n)
    end
    -- Unicode forms don't support case transformation meaningfully; return as-is
    if ordinal then
      -- Append ordinal suffix based on numeric value
      local suffix_n = n % 100
      local suffix_mod10 = n % 10
      local suffix
      if suffix_n >= 11 and suffix_n <= 13 then
        suffix = "th"
      elseif suffix_mod10 == 1 then
        suffix = "st"
      elseif suffix_mod10 == 2 then
        suffix = "nd"
      elseif suffix_mod10 == 3 then
        suffix = "rd"
      else
        suffix = "th"
      end
      result = result .. suffix
    end
    return result
  elseif style == "large" then
    result, err = M.to_roman_large(n)
  else
    return nil, "roman_numeral.format: unknown style '" .. tostring(style) .. "'"
  end

  if not result then return nil, err end

  if ordinal and style ~= "unicode" then
    -- Append ordinal suffix
    local mod100 = n % 100
    local mod10  = n % 10
    local suffix
    if mod100 >= 11 and mod100 <= 13 then
      suffix = "th"
    elseif mod10 == 1 then
      suffix = "st"
    elseif mod10 == 2 then
      suffix = "nd"
    elseif mod10 == 3 then
      suffix = "rd"
    else
      suffix = "th"
    end
    result = result .. suffix
  end

  if case == "lower" then
    result = result:lower()
  end

  return result
end

return M
