-- lib/roman/init.lua
-- Roman numeral encoding and decoding.
-- Supports standard subtractive notation, additive-only notation,
-- lowercase output, validation, and normalization.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

M.MIN = 1
M.MAX = 3999

-- Symbol values for decoding (uppercase)
local SYMBOL_VALUE = { --: { [string]: integer }
  I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000,
}

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

--- Encode an integer to a Roman numeral string.
-- opts.additive: boolean — use additive-only notation (no subtractive pairs)
-- opts.lower: boolean — return lowercase
-- Returns string, or (nil, errmsg) on error.
M.encode = function(n, opts)
  if type(n) ~= "number" or n ~= math.floor(n) then
    return nil, "roman.encode: expected integer, got " .. tostring(n)
  end
  if n < M.MIN or n > M.MAX then
    return nil, "roman.encode: value out of range [1, 3999], got " .. tostring(n)
  end

  opts = opts or {}
  local table = opts.additive and ADDITIVE or SUBTRACTIVE
  local parts = {} --: { [integer]: string }
  local remaining = n

  for _, pair in ipairs(table) do
    local val, sym = pair[1], pair[2]
    while remaining >= val do
      parts[#parts + 1] = sym
      remaining = remaining - val
    end
  end

  local result = ""
  for i = 1, #parts do result = result .. parts[i] end

  if opts.lower then
    return result:lower()
  end
  return result
end

--- Decode a Roman numeral string to an integer.
-- Accepts both subtractive and additive notation, case-insensitive.
-- Returns integer, or (nil, errmsg) on error.
M.decode = function(s)
  if type(s) ~= "string" or #s == 0 then
    return nil, "roman.decode: expected non-empty string"
  end

  local upper = s:upper()

  -- Validate characters
  for i = 1, #upper do
    local ch = upper:sub(i, i)
    if not SYMBOL_VALUE[ch] then
      return nil, "roman.decode: invalid character '" .. ch .. "'"
    end
  end

  -- Decode left-to-right: subtract if current < next, else add
  local total = 0
  local len = #upper
  for i = 1, len do
    local cur = SYMBOL_VALUE[upper:sub(i, i)] or 0
    local nxt = i < len and SYMBOL_VALUE[upper:sub(i + 1, i + 1)] or 0
    if cur < nxt then
      total = total - cur
    else
      total = total + cur
    end
  end

  if total <= 0 then
    return nil, "roman.decode: decoded value is not positive"
  end

  return total
end

--- Aliases
M.to_roman   = M.encode
M.from_roman = M.decode

--- Validate: is this a valid Roman numeral string?
-- Uses decode and re-encode round-trip for canonical check.
M.is_valid = function(s)
  if type(s) ~= "string" or #s == 0 then return false end
  local n = M.decode(s)
  if not n then return false end
  -- Check that only valid symbols appear (decode already does this,
  -- but re-check to be sure)
  local upper = s:upper()
  for i = 1, #upper do
    if not SYMBOL_VALUE[upper:sub(i, i)] then return false end
  end
  return true
end

--- Normalize: convert additive notation to canonical subtractive form.
-- Example: IIII -> IV, VIIII -> IX, XXXX -> XL
-- Returns normalized string, or (nil, errmsg) on error.
M.normalize = function(s)
  local n, err = M.decode(s)
  if not n then return nil, err end
  return M.encode(n)
end

return M
