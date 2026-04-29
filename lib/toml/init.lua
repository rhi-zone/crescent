if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- byte constants
local BYTE_NL    = 10  -- \n
local BYTE_CR    = 13  -- \r
local BYTE_TAB   = 9   -- \t
local BYTE_SPACE = 32
local BYTE_HASH  = 35  -- #
local BYTE_QUOTE = 34  -- "
local BYTE_APOS  = 39  -- '
local BYTE_LBRACK = 91  -- [
local BYTE_RBRACK = 93  -- ]
local BYTE_LBRACE = 123 -- {
local BYTE_RBRACE = 125 -- }
local BYTE_EQ     = 61  -- =
local BYTE_DOT    = 46  -- .
local BYTE_COMMA  = 44  -- ,
local BYTE_BSLASH = 92  -- \
local BYTE_PLUS   = 43  -- +
local BYTE_MINUS  = 45  -- -
local BYTE_0      = 48
local BYTE_9      = 57
local BYTE_A      = 65
local BYTE_F      = 70
local BYTE_Z      = 90
local BYTE_a      = 97
local BYTE_f      = 102
local BYTE_z      = 122
local BYTE_UNDER  = 95  -- _

local byte = string.byte
local sub = string.sub
local find = string.find
local format = string.format
local concat = table.concat
local floor = math.floor
local huge = math.huge

-- ============================================================================
-- Parser
-- ============================================================================

--: (number) -> boolean
local function is_ws(b)
  return b == BYTE_SPACE or b == BYTE_TAB
end

--: (number) -> boolean
local function is_newline(b)
  return b == BYTE_NL or b == BYTE_CR
end

--: (number) -> boolean
local function is_bare_key_char(b)
  return (b >= BYTE_a and b <= BYTE_z)
      or (b >= BYTE_A and b <= BYTE_Z)
      or (b >= BYTE_0 and b <= BYTE_9)
      or b == BYTE_MINUS or b == BYTE_UNDER
end

--: (number) -> boolean
local function is_digit(b)
  return b >= BYTE_0 and b <= BYTE_9
end

--: (number) -> boolean
local function is_hex(b)
  return (b >= BYTE_0 and b <= BYTE_9)
      or (b >= BYTE_a and b <= BYTE_f)
      or (b >= BYTE_A and b <= BYTE_F)
end

-- Parser state: { s, pos, len, line }

--: (table) -> nil
local function skip_ws(st)
  local s, pos, len = st.s, st.pos, st.len
  while pos <= len do
    local b = byte(s, pos)
    if not is_ws(b) then break end
    pos = pos + 1
  end
  st.pos = pos
end

--: (table) -> nil
local function skip_ws_and_newlines(st)
  local s, pos, len = st.s, st.pos, st.len
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_NL then
      st.line = st.line + 1
      pos = pos + 1
    elseif b == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_NL then
        pos = pos + 1
      end
      st.line = st.line + 1
    elseif b == BYTE_HASH then
      -- skip comment to end of line
      while pos <= len and byte(s, pos) ~= BYTE_NL and byte(s, pos) ~= BYTE_CR do
        pos = pos + 1
      end
    elseif is_ws(b) then
      pos = pos + 1
    else
      break
    end
  end
  st.pos = pos
end

--: (table) -> nil
local function skip_to_newline(st)
  local s, pos, len = st.s, st.pos, st.len
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_NL or b == BYTE_CR then break end
    if b == BYTE_HASH then
      while pos <= len and byte(s, pos) ~= BYTE_NL and byte(s, pos) ~= BYTE_CR do
        pos = pos + 1
      end
      break
    end
    if not is_ws(b) then
      st.pos = pos
      return nil, "line " .. st.line .. ": unexpected character '" .. sub(s, pos, pos) .. "'"
    end
    pos = pos + 1
  end
  st.pos = pos
  return true
end

--: (table) -> nil
local function skip_newline(st)
  local s, pos, len = st.s, st.pos, st.len
  if pos > len then return end
  local b = byte(s, pos)
  if b == BYTE_NL then
    st.line = st.line + 1
    st.pos = pos + 1
  elseif b == BYTE_CR then
    st.pos = pos + 1
    if st.pos <= len and byte(s, st.pos) == BYTE_NL then
      st.pos = st.pos + 1
    end
    st.line = st.line + 1
  end
end

-- unicode codepoint to UTF-8
--: (number) -> (string | nil, string)
local function utf8_char(cp)
  if cp < 0 then return nil, "invalid codepoint" end
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + floor(cp / 64),
      0x80 + cp % 64
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + floor(cp / 4096),
      0x80 + floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  elseif cp <= 0x10FFFF then
    return string.char(
      0xF0 + floor(cp / 262144),
      0x80 + floor(cp / 4096) % 64,
      0x80 + floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return nil, "codepoint out of range"
end

-- escape map for basic strings
local escape_map = {
  [byte("b")] = "\b",
  [byte("t")] = "\t",
  [byte("n")] = "\n",
  [byte("f")] = "\f",
  [byte("r")] = "\r",
  [BYTE_QUOTE] = "\"",
  [BYTE_BSLASH] = "\\",
}

-- Forward declarations
local parse_value

-- Parse a basic (double-quoted) string
--: (table) -> (string | nil, string)
local function parse_basic_string(st)
  local s, len = st.s, st.len
  local pos = st.pos + 1  -- skip opening "
  local parts = {}
  local n = 0
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_QUOTE then
      st.pos = pos + 1
      return concat(parts)
    elseif b == BYTE_BSLASH then
      pos = pos + 1
      if pos > len then return nil, "line " .. st.line .. ": unexpected end of string" end
      b = byte(s, pos)
      local esc = escape_map[b]
      if esc then
        n = n + 1; parts[n] = esc
        pos = pos + 1
      elseif b == byte("u") or b == byte("U") then
        local ndig = b == byte("u") and 4 or 8
        pos = pos + 1
        if pos + ndig - 1 > len then
          return nil, "line " .. st.line .. ": incomplete unicode escape"
        end
        local hex = sub(s, pos, pos + ndig - 1)
        local cp = tonumber(hex, 16)
        if not cp then
          return nil, "line " .. st.line .. ": invalid unicode escape"
        end
        local ch, err = utf8_char(cp)
        if not ch then return nil, "line " .. st.line .. ": " .. err end
        n = n + 1; parts[n] = ch
        pos = pos + ndig
      else
        return nil, "line " .. st.line .. ": invalid escape sequence '\\" .. string.char(b) .. "'"
      end
    elseif b == BYTE_NL or b == BYTE_CR then
      return nil, "line " .. st.line .. ": newline in basic string"
    else
      -- fast scan for unescaped content
      local start = pos
      pos = pos + 1
      while pos <= len do
        b = byte(s, pos)
        if b == BYTE_QUOTE or b == BYTE_BSLASH or b == BYTE_NL or b == BYTE_CR then break end
        pos = pos + 1
      end
      n = n + 1; parts[n] = sub(s, start, pos - 1)
    end
  end
  return nil, "line " .. st.line .. ": unterminated string"
end

-- Parse a multiline basic string (""")
--: (table) -> (string | nil, string)
local function parse_ml_basic_string(st)
  local s, len = st.s, st.len
  local pos = st.pos + 3  -- skip """
  -- trim first newline
  if pos <= len then
    local b = byte(s, pos)
    if b == BYTE_NL then
      st.line = st.line + 1
      pos = pos + 1
    elseif b == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
      st.line = st.line + 1
    end
  end
  local parts = {}
  local n = 0
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_QUOTE and pos + 2 <= len and byte(s, pos + 1) == BYTE_QUOTE and byte(s, pos + 2) == BYTE_QUOTE then
      -- allow up to two extra quotes before closing
      pos = pos + 3
      -- TOML allows up to 2 extra " before closing """
      local extra = 0
      while extra < 2 and pos <= len and byte(s, pos) == BYTE_QUOTE do
        extra = extra + 1
        pos = pos + 1
      end
      if extra > 0 then
        n = n + 1; parts[n] = string.rep("\"", extra)
      end
      st.pos = pos
      return concat(parts)
    elseif b == BYTE_BSLASH then
      pos = pos + 1
      if pos > len then return nil, "line " .. st.line .. ": unexpected end of string" end
      b = byte(s, pos)
      -- line-ending backslash: trim whitespace+newlines
      if b == BYTE_NL or b == BYTE_CR or is_ws(b) then
        -- skip whitespace before newline
        while pos <= len and is_ws(byte(s, pos)) do pos = pos + 1 end
        if pos <= len then
          b = byte(s, pos)
          if b == BYTE_NL then
            st.line = st.line + 1
            pos = pos + 1
          elseif b == BYTE_CR then
            pos = pos + 1
            if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
            st.line = st.line + 1
          end
        end
        -- skip further whitespace and newlines
        while pos <= len do
          b = byte(s, pos)
          if b == BYTE_NL then
            st.line = st.line + 1
            pos = pos + 1
          elseif b == BYTE_CR then
            pos = pos + 1
            if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
            st.line = st.line + 1
          elseif is_ws(b) then
            pos = pos + 1
          else
            break
          end
        end
      else
        local esc = escape_map[b]
        if esc then
          n = n + 1; parts[n] = esc
          pos = pos + 1
        elseif b == byte("u") or b == byte("U") then
          local ndig = b == byte("u") and 4 or 8
          pos = pos + 1
          if pos + ndig - 1 > len then
            return nil, "line " .. st.line .. ": incomplete unicode escape"
          end
          local hex = sub(s, pos, pos + ndig - 1)
          local cp = tonumber(hex, 16)
          if not cp then return nil, "line " .. st.line .. ": invalid unicode escape" end
          local ch, err = utf8_char(cp)
          if not ch then return nil, "line " .. st.line .. ": " .. err end
          n = n + 1; parts[n] = ch
          pos = pos + ndig
        else
          return nil, "line " .. st.line .. ": invalid escape '\\" .. string.char(b) .. "'"
        end
      end
    elseif b == BYTE_NL then
      n = n + 1; parts[n] = "\n"
      st.line = st.line + 1
      pos = pos + 1
    elseif b == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
      n = n + 1; parts[n] = "\n"
      st.line = st.line + 1
    else
      local start = pos
      pos = pos + 1
      while pos <= len do
        b = byte(s, pos)
        if b == BYTE_QUOTE or b == BYTE_BSLASH or b == BYTE_NL or b == BYTE_CR then break end
        pos = pos + 1
      end
      n = n + 1; parts[n] = sub(s, start, pos - 1)
    end
  end
  return nil, "line " .. st.line .. ": unterminated multiline string"
end

-- Parse a literal (single-quoted) string
--: (table) -> (string | nil, string)
local function parse_literal_string(st)
  local s, len = st.s, st.len
  local pos = st.pos + 1  -- skip '
  local start = pos
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_APOS then
      st.pos = pos + 1
      return sub(s, start, pos - 1)
    elseif b == BYTE_NL or b == BYTE_CR then
      return nil, "line " .. st.line .. ": newline in literal string"
    end
    pos = pos + 1
  end
  return nil, "line " .. st.line .. ": unterminated literal string"
end

-- Parse a multiline literal string (''')
--: (table) -> (string | nil, string)
local function parse_ml_literal_string(st)
  local s, len = st.s, st.len
  local pos = st.pos + 3  -- skip '''
  -- trim first newline
  if pos <= len then
    local b = byte(s, pos)
    if b == BYTE_NL then
      st.line = st.line + 1
      pos = pos + 1
    elseif b == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
      st.line = st.line + 1
    end
  end
  local parts = {}
  local n = 0
  while pos <= len do
    local b = byte(s, pos)
    if b == BYTE_APOS and pos + 2 <= len and byte(s, pos + 1) == BYTE_APOS and byte(s, pos + 2) == BYTE_APOS then
      pos = pos + 3
      local extra = 0
      while extra < 2 and pos <= len and byte(s, pos) == BYTE_APOS do
        extra = extra + 1
        pos = pos + 1
      end
      if extra > 0 then
        n = n + 1; parts[n] = string.rep("'", extra)
      end
      st.pos = pos
      return concat(parts)
    elseif b == BYTE_NL then
      n = n + 1; parts[n] = "\n"
      st.line = st.line + 1
      pos = pos + 1
    elseif b == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_NL then pos = pos + 1 end
      n = n + 1; parts[n] = "\n"
      st.line = st.line + 1
    else
      local start = pos
      pos = pos + 1
      while pos <= len do
        b = byte(s, pos)
        if b == BYTE_APOS or b == BYTE_NL or b == BYTE_CR then break end
        pos = pos + 1
      end
      n = n + 1; parts[n] = sub(s, start, pos - 1)
    end
  end
  return nil, "line " .. st.line .. ": unterminated multiline literal string"
end

-- Parse a string value (dispatches on quote type)
--: (table) -> (string | nil, string)
local function parse_string(st)
  local s, pos, len = st.s, st.pos, st.len
  local b = byte(s, pos)
  if b == BYTE_QUOTE then
    if pos + 2 <= len and byte(s, pos + 1) == BYTE_QUOTE and byte(s, pos + 2) == BYTE_QUOTE then
      return parse_ml_basic_string(st)
    end
    return parse_basic_string(st)
  elseif b == BYTE_APOS then
    if pos + 2 <= len and byte(s, pos + 1) == BYTE_APOS and byte(s, pos + 2) == BYTE_APOS then
      return parse_ml_literal_string(st)
    end
    return parse_literal_string(st)
  end
  return nil, "line " .. st.line .. ": expected string"
end

-- Strip underscores from a numeric string (validates no leading/trailing/double underscores)
--: (string, number) -> (string | nil, string)
local function strip_underscores(raw, line)
  if byte(raw, 1) == BYTE_UNDER or byte(raw, #raw) == BYTE_UNDER then
    return nil, "line " .. line .. ": underscore at boundary in number"
  end
  if find(raw, "__", 1, true) then
    return nil, "line " .. line .. ": consecutive underscores in number"
  end
  return (raw:gsub("_", ""))
end

-- Parse a number or date/time
--: (table) -> (number | table | nil, string)
local function parse_number_or_date(st)
  local s, pos, len = st.s, st.pos, st.len
  local start = pos
  local b = byte(s, pos)

  -- sign
  local sign = 1
  if b == BYTE_PLUS or b == BYTE_MINUS then
    if b == BYTE_MINUS then sign = -1 end
    pos = pos + 1
    if pos > len then return nil, "line " .. st.line .. ": unexpected end after sign" end
    b = byte(s, pos)
  end

  -- inf / nan
  if pos + 2 <= len then
    local word = sub(s, pos, pos + 2)
    if word == "inf" then
      st.pos = pos + 3
      return sign * huge
    elseif word == "nan" then
      st.pos = pos + 3
      return 0/0
    end
  end

  -- 0x, 0o, 0b prefixes
  if b == BYTE_0 and pos + 1 <= len then
    local next_b = byte(s, pos + 1)
    if next_b == byte("x") or next_b == byte("X") then
      pos = pos + 2
      local nstart = pos
      while pos <= len and (is_hex(byte(s, pos)) or byte(s, pos) == BYTE_UNDER) do
        pos = pos + 1
      end
      if pos == nstart then return nil, "line " .. st.line .. ": expected hex digits" end
      st.pos = pos
      local raw, err = strip_underscores(sub(s, nstart, pos - 1), st.line)
      if not raw then return nil, err end
      return sign * tonumber(raw, 16)
    elseif next_b == byte("o") or next_b == byte("O") then
      pos = pos + 2
      local nstart = pos
      while pos <= len and ((byte(s, pos) >= BYTE_0 and byte(s, pos) <= byte("7")) or byte(s, pos) == BYTE_UNDER) do
        pos = pos + 1
      end
      if pos == nstart then return nil, "line " .. st.line .. ": expected octal digits" end
      st.pos = pos
      local raw, err = strip_underscores(sub(s, nstart, pos - 1), st.line)
      if not raw then return nil, err end
      return sign * tonumber(raw, 8)
    elseif next_b == byte("b") or next_b == byte("B") then
      pos = pos + 2
      local nstart = pos
      while pos <= len and (byte(s, pos) == BYTE_0 or byte(s, pos) == byte("1") or byte(s, pos) == BYTE_UNDER) do
        pos = pos + 1
      end
      if pos == nstart then return nil, "line " .. st.line .. ": expected binary digits" end
      st.pos = pos
      local raw, err = strip_underscores(sub(s, nstart, pos - 1), st.line)
      if not raw then return nil, err end
      return sign * tonumber(raw, 2)
    end
  end

  -- decimal integer or float, or date/time
  -- scan digits
  local has_sign = (byte(s, start) == BYTE_PLUS or byte(s, start) == BYTE_MINUS)
  local dstart = pos
  while pos <= len and (is_digit(byte(s, pos)) or byte(s, pos) == BYTE_UNDER) do
    pos = pos + 1
  end

  -- check for date: YYYY-MM-DD pattern (4 digits then -)
  if not has_sign and (pos - dstart) == 4 and pos <= len and byte(s, pos) == BYTE_MINUS then
    -- likely a date
    return parse_datetime(st)
  end

  -- check for time: HH:MM pattern (2 digits then :) with no sign
  if not has_sign and (pos - dstart) == 2 and pos <= len and byte(s, pos) == byte(":") then
    return parse_datetime(st)
  end

  -- float: dot
  local is_float = false
  if pos <= len and byte(s, pos) == BYTE_DOT then
    is_float = true
    pos = pos + 1
    if pos > len or not is_digit(byte(s, pos)) then
      return nil, "line " .. st.line .. ": expected digit after decimal point"
    end
    while pos <= len and (is_digit(byte(s, pos)) or byte(s, pos) == BYTE_UNDER) do
      pos = pos + 1
    end
  end

  -- float: exponent
  if pos <= len and (byte(s, pos) == byte("e") or byte(s, pos) == byte("E")) then
    is_float = true
    pos = pos + 1
    if pos <= len and (byte(s, pos) == BYTE_PLUS or byte(s, pos) == BYTE_MINUS) then
      pos = pos + 1
    end
    if pos > len or not is_digit(byte(s, pos)) then
      return nil, "line " .. st.line .. ": expected digit in exponent"
    end
    while pos <= len and (is_digit(byte(s, pos)) or byte(s, pos) == BYTE_UNDER) do
      pos = pos + 1
    end
  end

  st.pos = pos
  local raw = sub(s, start, pos - 1)
  local cleaned, err = strip_underscores(raw, st.line)
  if not cleaned then return nil, err end

  local num = tonumber(cleaned)
  if not num then return nil, "line " .. st.line .. ": invalid number '" .. raw .. "'" end
  return num
end

-- Parse datetime/date/time
--: (table) -> (table | nil, string)
local function _parse_datetime(st)
  local s, pos, len = st.s, st.pos, st.len
  local start = pos

  -- scan the full token (digits, -, :, ., T, t, Z, z, +)
  while pos <= len do
    local b = byte(s, pos)
    if is_digit(b) or b == BYTE_MINUS or b == byte(":") or b == BYTE_DOT
       or b == byte("T") or b == byte("t") or b == byte("Z") or b == byte("z")
       or b == BYTE_PLUS or b == BYTE_SPACE then
      -- space only valid between date and time
      if b == BYTE_SPACE then
        -- check if next char is a digit (time part)
        if pos + 1 <= len and is_digit(byte(s, pos + 1)) then
          pos = pos + 1
        else
          break
        end
      else
        pos = pos + 1
      end
    else
      break
    end
  end

  st.pos = pos
  local raw = sub(s, start, pos - 1)

  -- try to parse: offset datetime, local datetime, local date, local time
  local year, month, day, hour, min, sec, frac, tz

  -- date patterns
  local d = find(raw, "^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if d then
    year = tonumber(sub(raw, 1, 4))
    month = tonumber(sub(raw, 6, 7))
    day = tonumber(sub(raw, 9, 10))

    -- check for time part
    local sep_pos = 11
    if #raw >= 11 and (sub(raw, 11, 11) == "T" or sub(raw, 11, 11) == "t" or sub(raw, 11, 11) == " ") then
      local time_part = sub(raw, 12)
      hour, min, sec, frac, tz = _parse_time_part(time_part, st.line)
      if not hour then return nil, min end  -- min is errmsg

      if tz then
        return { __toml_type = "datetime", year = year, month = month, day = day,
                 hour = hour, min = min, sec = sec, frac = frac, tz = tz }
      else
        return { __toml_type = "datetime-local", year = year, month = month, day = day,
                 hour = hour, min = min, sec = sec, frac = frac }
      end
    end

    -- just a date
    return { __toml_type = "date-local", year = year, month = month, day = day }
  end

  -- try time only
  hour, min, sec, frac, tz = _parse_time_part(raw, st.line)
  if hour then
    return { __toml_type = "time-local", hour = hour, min = min, sec = sec, frac = frac }
  end

  return nil, "line " .. st.line .. ": invalid date/time '" .. raw .. "'"
end

-- Parse the time portion: HH:MM:SS[.frac][Z|+HH:MM|-HH:MM]
--: (string, number) -> (number, number, number, number|nil, string|nil | nil, string)
local function _parse_time_part_impl(time_str, line)
  local h, m, s
  if #time_str < 8 then
    -- might be HH:MM:SS minimum
    if #time_str < 5 then return nil, "line " .. line .. ": invalid time" end
  end
  h = tonumber(sub(time_str, 1, 2))
  if sub(time_str, 3, 3) ~= ":" then return nil, "line " .. line .. ": expected ':' in time" end
  m = tonumber(sub(time_str, 4, 5))
  if #time_str == 5 then
    return h, m, 0, nil, nil
  end
  if sub(time_str, 6, 6) ~= ":" then return nil, "line " .. line .. ": expected ':' in time" end
  s = tonumber(sub(time_str, 7, 8))

  local frac_val = nil
  local rest_pos = 9
  if rest_pos <= #time_str and sub(time_str, rest_pos, rest_pos) == "." then
    rest_pos = rest_pos + 1
    local frac_start = rest_pos
    while rest_pos <= #time_str and is_digit(byte(time_str, rest_pos)) do
      rest_pos = rest_pos + 1
    end
    if rest_pos > frac_start then
      frac_val = tonumber("0." .. sub(time_str, frac_start, rest_pos - 1))
    end
  end

  local tz_val = nil
  if rest_pos <= #time_str then
    local tz_char = sub(time_str, rest_pos, rest_pos)
    if tz_char == "Z" or tz_char == "z" then
      tz_val = "Z"
    elseif tz_char == "+" or tz_char == "-" then
      tz_val = sub(time_str, rest_pos)
    end
  end

  return h, m, s, frac_val, tz_val
end

-- Make these accessible for forward reference
_parse_time_part = _parse_time_part_impl
parse_datetime = _parse_datetime

-- Parse a key (bare or quoted)
--: (table) -> (string | nil, string)
local function parse_simple_key(st)
  local s, pos, len = st.s, st.pos, st.len
  if pos > len then return nil, "line " .. st.line .. ": expected key" end
  local b = byte(s, pos)
  if b == BYTE_QUOTE or b == BYTE_APOS then
    return parse_string(st)
  end
  -- bare key
  if not is_bare_key_char(b) then
    return nil, "line " .. st.line .. ": expected key, got '" .. sub(s, pos, pos) .. "'"
  end
  local start = pos
  while pos <= len and is_bare_key_char(byte(s, pos)) do
    pos = pos + 1
  end
  st.pos = pos
  return sub(s, start, pos - 1)
end

-- Parse a dotted key into a list of key segments
--: (table) -> (table | nil, string)
local function parse_key(st)
  local keys = {}
  local n = 0
  local k, err = parse_simple_key(st)
  if not k then return nil, err end
  n = n + 1; keys[n] = k
  while st.pos <= st.len and byte(st.s, st.pos) == BYTE_DOT do
    st.pos = st.pos + 1  -- skip dot
    skip_ws(st)
    k, err = parse_simple_key(st)
    if not k then return nil, err end
    n = n + 1; keys[n] = k
  end
  return keys
end

-- Navigate/create nested tables for a key path
-- implicit_tables tracks tables created implicitly (can be extended but not redefined)
-- defined_tables tracks explicitly defined [table] headers
-- array_tables tracks [[array]] paths
--: (table, table, number, table, table, table, number) -> (table | nil, string)
local function traverse_key(root, keys, depth, implicit, defined, array_tables, line)
  local cur = root
  for i = 1, depth do
    local k = keys[i]
    local v = cur[k]
    if v == nil then
      local new_t = {}
      cur[k] = new_t
      implicit[new_t] = true
      cur = new_t
    elseif type(v) == "table" and v.__toml_type == nil then
      -- check if it's an array-of-tables — descend into last element
      if array_tables[v] then
        cur = v[#v]
      else
        cur = v
      end
    else
      return nil, "line " .. line .. ": key '" .. k .. "' already exists as a non-table"
    end
  end
  return cur
end

-- Parse an inline table
--: (table, table) -> (table | nil, string)
local function parse_inline_table(st, array_tables)
  st.pos = st.pos + 1  -- skip {
  local tbl = {}
  skip_ws(st)
  if st.pos <= st.len and byte(st.s, st.pos) == BYTE_RBRACE then
    st.pos = st.pos + 1
    return tbl
  end
  while true do
    skip_ws(st)
    local keys, err = parse_key(st)
    if not keys then return nil, err end
    skip_ws(st)
    if st.pos > st.len or byte(st.s, st.pos) ~= BYTE_EQ then
      return nil, "line " .. st.line .. ": expected '=' in inline table"
    end
    st.pos = st.pos + 1  -- skip =
    skip_ws(st)
    local val
    val, err = parse_value(st, array_tables)
    if val == nil and err then return nil, err end
    -- set nested key
    local cur = tbl
    for i = 1, #keys - 1 do
      local k = keys[i]
      if cur[k] == nil then
        cur[k] = {}
      elseif type(cur[k]) ~= "table" then
        return nil, "line " .. st.line .. ": key conflict in inline table"
      end
      cur = cur[k]
    end
    local last_key = keys[#keys]
    if cur[last_key] ~= nil then
      return nil, "line " .. st.line .. ": duplicate key '" .. last_key .. "'"
    end
    cur[last_key] = val
    skip_ws(st)
    if st.pos > st.len then return nil, "line " .. st.line .. ": unterminated inline table" end
    local b = byte(st.s, st.pos)
    if b == BYTE_RBRACE then
      st.pos = st.pos + 1
      return tbl
    elseif b == BYTE_COMMA then
      st.pos = st.pos + 1
    else
      return nil, "line " .. st.line .. ": expected ',' or '}' in inline table"
    end
  end
end

-- Parse an array value
--: (table, table) -> (table | nil, string)
local function parse_array(st, array_tables)
  st.pos = st.pos + 1  -- skip [
  local arr = {}
  local n = 0
  skip_ws_and_newlines(st)
  if st.pos <= st.len and byte(st.s, st.pos) == BYTE_RBRACK then
    st.pos = st.pos + 1
    return arr
  end
  while true do
    skip_ws_and_newlines(st)
    local val, err = parse_value(st, array_tables)
    if val == nil and err then return nil, err end
    n = n + 1; arr[n] = val
    skip_ws_and_newlines(st)
    if st.pos > st.len then return nil, "line " .. st.line .. ": unterminated array" end
    local b = byte(st.s, st.pos)
    if b == BYTE_RBRACK then
      st.pos = st.pos + 1
      return arr
    elseif b == BYTE_COMMA then
      st.pos = st.pos + 1
      -- allow trailing comma
      skip_ws_and_newlines(st)
      if st.pos <= st.len and byte(st.s, st.pos) == BYTE_RBRACK then
        st.pos = st.pos + 1
        return arr
      end
    else
      return nil, "line " .. st.line .. ": expected ',' or ']' in array"
    end
  end
end

-- Parse a value
--: (table, table) -> (any | nil, string)
parse_value = function(st, array_tables)
  if st.pos > st.len then return nil, "line " .. st.line .. ": expected value" end
  local b = byte(st.s, st.pos)

  -- string
  if b == BYTE_QUOTE or b == BYTE_APOS then
    return parse_string(st)
  end

  -- boolean
  if b == byte("t") and sub(st.s, st.pos, st.pos + 3) == "true" then
    local after = st.pos + 4
    if after > st.len or not is_bare_key_char(byte(st.s, after)) then
      st.pos = after
      return true
    end
  end
  if b == byte("f") and sub(st.s, st.pos, st.pos + 4) == "false" then
    local after = st.pos + 5
    if after > st.len or not is_bare_key_char(byte(st.s, after)) then
      st.pos = after
      return false
    end
  end

  -- inline table
  if b == BYTE_LBRACE then
    return parse_inline_table(st, array_tables)
  end

  -- array
  if b == BYTE_LBRACK then
    return parse_array(st, array_tables)
  end

  -- number, date, or special values (inf, nan)
  if is_digit(b) or b == BYTE_PLUS or b == BYTE_MINUS then
    return parse_number_or_date(st)
  end

  -- inf/nan without sign
  if b == byte("i") and sub(st.s, st.pos, st.pos + 2) == "inf" then
    st.pos = st.pos + 3
    return huge
  end
  if b == byte("n") and sub(st.s, st.pos, st.pos + 2) == "nan" then
    st.pos = st.pos + 3
    return 0/0
  end

  return nil, "line " .. st.line .. ": unexpected character '" .. sub(st.s, st.pos, st.pos) .. "'"
end

-- Main decode function
--: (string) -> (table | nil, string)
local function decode(s)
  if type(s) ~= "string" then
    return nil, "expected string input"
  end
  local st = { s = s, pos = 1, len = #s, line = 1 }
  local root = {}
  local current_table = root
  local implicit_tables = {}     -- tables created by dotted key traversal
  local defined_tables = {}      -- tables from [header]
  local array_tables = {}        -- tables that are arrays of tables
  local defined_keys = {}        -- track leaf keys: defined_keys[table][key] = true

  defined_keys[root] = {}

  skip_ws_and_newlines(st)

  while st.pos <= st.len do
    local b = byte(st.s, st.pos)

    if b == BYTE_LBRACK then
      -- table header or array of tables
      st.pos = st.pos + 1
      local is_array = false
      if st.pos <= st.len and byte(st.s, st.pos) == BYTE_LBRACK then
        is_array = true
        st.pos = st.pos + 1
      end
      skip_ws(st)
      local keys, err = parse_key(st)
      if not keys then return nil, err end
      skip_ws(st)
      if is_array then
        if st.pos + 1 > st.len or byte(st.s, st.pos) ~= BYTE_RBRACK or byte(st.s, st.pos + 1) ~= BYTE_RBRACK then
          return nil, "line " .. st.line .. ": expected ']]'"
        end
        st.pos = st.pos + 2
      else
        if st.pos > st.len or byte(st.s, st.pos) ~= BYTE_RBRACK then
          return nil, "line " .. st.line .. ": expected ']'"
        end
        st.pos = st.pos + 1
      end

      -- rest of line must be ws/comment
      local ok2, err2 = skip_to_newline(st)
      if not ok2 then return nil, err2 end
      skip_newline(st)

      if is_array then
        -- array of tables
        local parent = root
        for i = 1, #keys - 1 do
          local k = keys[i]
          local v = parent[k]
          if v == nil then
            v = {}
            parent[k] = v
            implicit_tables[v] = true
            defined_keys[v] = {}
          elseif type(v) == "table" and array_tables[v] then
            v = v[#v]
          elseif type(v) ~= "table" or v.__toml_type then
            return nil, "line " .. st.line .. ": key '" .. k .. "' conflict"
          end
          parent = v
        end
        local last = keys[#keys]
        local arr = parent[last]
        if arr == nil then
          arr = {}
          parent[last] = arr
          array_tables[arr] = true
        elseif not array_tables[arr] then
          return nil, "line " .. st.line .. ": key '" .. last .. "' is not an array of tables"
        end
        local new_tbl = {}
        arr[#arr + 1] = new_tbl
        current_table = new_tbl
        defined_keys[new_tbl] = {}
      else
        -- standard table
        local parent = root
        for i = 1, #keys - 1 do
          local k = keys[i]
          local v = parent[k]
          if v == nil then
            v = {}
            parent[k] = v
            implicit_tables[v] = true
            defined_keys[v] = {}
          elseif type(v) == "table" and array_tables[v] then
            v = v[#v]
          elseif type(v) ~= "table" or v.__toml_type then
            return nil, "line " .. st.line .. ": key '" .. k .. "' conflict"
          end
          parent = v
        end
        local last = keys[#keys]
        local v = parent[last]
        if v == nil then
          v = {}
          parent[last] = v
          defined_keys[v] = {}
        elseif type(v) == "table" and implicit_tables[v] and not defined_tables[v] then
          -- implicit table can be explicitly defined once
        elseif type(v) == "table" and array_tables[v] then
          return nil, "line " .. st.line .. ": cannot define [" .. last .. "] — it is an array of tables"
        else
          if defined_tables[v] then
            return nil, "line " .. st.line .. ": duplicate table '" .. last .. "'"
          end
          return nil, "line " .. st.line .. ": key '" .. last .. "' already defined"
        end
        defined_tables[v] = true
        implicit_tables[v] = nil
        current_table = v
        if not defined_keys[v] then defined_keys[v] = {} end
      end
    else
      -- key = value
      skip_ws(st)
      if st.pos > st.len then break end
      b = byte(st.s, st.pos)
      if b == BYTE_NL or b == BYTE_CR then
        skip_newline(st)
        skip_ws_and_newlines(st)
        goto continue
      end
      if b == BYTE_HASH then
        skip_to_newline(st)
        skip_newline(st)
        skip_ws_and_newlines(st)
        goto continue
      end

      local keys, err = parse_key(st)
      if not keys then return nil, err end
      skip_ws(st)
      if st.pos > st.len or byte(st.s, st.pos) ~= BYTE_EQ then
        return nil, "line " .. st.line .. ": expected '='"
      end
      st.pos = st.pos + 1  -- skip =
      skip_ws(st)
      local val
      val, err = parse_value(st, array_tables)
      if val == nil and err then return nil, err end

      -- navigate to target table
      local target = current_table
      for i = 1, #keys - 1 do
        local k = keys[i]
        local v = target[k]
        if v == nil then
          v = {}
          target[k] = v
          implicit_tables[v] = true
          defined_keys[v] = {}
        elseif type(v) ~= "table" or v.__toml_type then
          return nil, "line " .. st.line .. ": key '" .. k .. "' is not a table"
        end
        target = v
      end
      local last_key = keys[#keys]
      if not defined_keys[target] then defined_keys[target] = {} end
      if defined_keys[target][last_key] then
        return nil, "line " .. st.line .. ": duplicate key '" .. last_key .. "'"
      end
      if target[last_key] ~= nil then
        return nil, "line " .. st.line .. ": duplicate key '" .. last_key .. "'"
      end
      target[last_key] = val
      defined_keys[target][last_key] = true

      -- rest of line
      local ok2, err2 = skip_to_newline(st)
      if not ok2 then return nil, err2 end
      skip_newline(st)
    end

    skip_ws_and_newlines(st)
    ::continue::
  end

  return root
end

-- ============================================================================
-- Encoder
-- ============================================================================

-- Check if a string needs quoting
--: (string) -> boolean
local function needs_basic_quote(s)
  for i = 1, #s do
    local b = byte(s, i)
    if not is_bare_key_char(b) then return true end
  end
  return false
end

-- Escape a string for basic (double-quoted) TOML output
--: (string) -> string
local function escape_basic_string(s)
  local parts = {}
  local n = 0
  local i = 1
  local len = #s
  while i <= len do
    local b = byte(s, i)
    if b == BYTE_QUOTE then
      n = n + 1; parts[n] = '\\"'
    elseif b == BYTE_BSLASH then
      n = n + 1; parts[n] = '\\\\'
    elseif b == BYTE_NL then
      n = n + 1; parts[n] = '\\n'
    elseif b == BYTE_CR then
      n = n + 1; parts[n] = '\\r'
    elseif b == BYTE_TAB then
      n = n + 1; parts[n] = '\\t'
    elseif b == 8 then  -- \b
      n = n + 1; parts[n] = '\\b'
    elseif b == 12 then  -- \f
      n = n + 1; parts[n] = '\\f'
    elseif b < 0x20 and b ~= BYTE_TAB then
      n = n + 1; parts[n] = format('\\u%04X', b)
    else
      -- fast scan unescaped
      local start = i
      i = i + 1
      while i <= len do
        b = byte(s, i)
        if b == BYTE_QUOTE or b == BYTE_BSLASH or b == BYTE_NL or b == BYTE_CR
           or b == BYTE_TAB or b == 8 or b == 12 or (b < 0x20 and b ~= BYTE_TAB) then
          break
        end
        i = i + 1
      end
      n = n + 1; parts[n] = sub(s, start, i - 1)
      goto continue
    end
    i = i + 1
    ::continue::
  end
  return concat(parts)
end

-- Quote a key for TOML output
--: (string) -> string
local function quote_key(k)
  if #k == 0 then return '""' end
  if needs_basic_quote(k) then
    -- check if literal would work (no ' or control chars)
    local can_literal = true
    for i = 1, #k do
      local b = byte(k, i)
      if b == BYTE_APOS or b < 0x20 then
        can_literal = false
        break
      end
    end
    if can_literal then
      return "'" .. k .. "'"
    end
    return '"' .. escape_basic_string(k) .. '"'
  end
  return k
end

-- Check if a value is a "simple" table (no nested tables or arrays of tables)
--: (any) -> boolean
local function is_simple_value(v)
  if type(v) ~= "table" then return true end
  if v.__toml_type then return true end
  -- check array
  if #v > 0 then
    for i = 1, #v do
      if type(v[i]) == "table" and not v[i].__toml_type then
        return false
      end
    end
    return true
  end
  -- check table — inline if all values are simple
  for _, val in pairs(v) do
    if type(val) == "table" and not val.__toml_type then
      return false
    end
  end
  return true
end

-- Format a datetime table to TOML string
--: (table) -> string
local function format_datetime(dt)
  local t = dt.__toml_type
  if t == "datetime" then
    local s = format("%04d-%02d-%02dT%02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
    if dt.frac then
      s = s .. format("%.6f", dt.frac):sub(2):gsub("0+$", "")
      if s:sub(-1) == "." then s = s .. "0" end
    end
    s = s .. (dt.tz or "Z")
    return s
  elseif t == "datetime-local" then
    local s = format("%04d-%02d-%02dT%02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
    if dt.frac then
      s = s .. format("%.6f", dt.frac):sub(2):gsub("0+$", "")
      if s:sub(-1) == "." then s = s .. "0" end
    end
    return s
  elseif t == "date-local" then
    return format("%04d-%02d-%02d", dt.year, dt.month, dt.day)
  elseif t == "time-local" then
    local s = format("%02d:%02d:%02d", dt.hour, dt.min, dt.sec)
    if dt.frac then
      s = s .. format("%.6f", dt.frac):sub(2):gsub("0+$", "")
      if s:sub(-1) == "." then s = s .. "0" end
    end
    return s
  end
  return tostring(dt)
end

-- Encode a value inline (for arrays and inline tables)
--: (any) -> (string | nil, string)
local function encode_inline(v)
  local vtype = type(v)
  if vtype == "string" then
    return '"' .. escape_basic_string(v) .. '"'
  elseif vtype == "number" then
    if v ~= v then return "nan" end
    if v == huge then return "inf" end
    if v == -huge then return "-inf" end
    -- integer check
    if v == floor(v) and v >= -2^53 and v <= 2^53 then
      return format("%d", v)
    end
    return tostring(v)
  elseif vtype == "boolean" then
    return v and "true" or "false"
  elseif vtype == "table" then
    if v.__toml_type then
      return format_datetime(v)
    end
    -- array
    if #v > 0 or next(v) == nil then
      -- treat as array if sequential keys or empty
      local is_arr = true
      local count = 0
      for _ in pairs(v) do count = count + 1 end
      if count ~= #v then is_arr = false end
      if is_arr then
        local parts = {}
        for i = 1, #v do
          local enc, err = encode_inline(v[i])
          if not enc then return nil, err end
          parts[i] = enc
        end
        return "[" .. concat(parts, ", ") .. "]"
      end
    end
    -- inline table
    local parts = {}
    local n = 0
    -- sort keys for deterministic output
    local keys = {}
    local kn = 0
    for k in pairs(v) do kn = kn + 1; keys[kn] = k end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    for i = 1, kn do
      local k = keys[i]
      local enc, err = encode_inline(v[k])
      if not enc then return nil, err end
      n = n + 1
      parts[n] = quote_key(tostring(k)) .. " = " .. enc
    end
    return "{" .. concat(parts, ", ") .. "}"
  end
  return nil, "unsupported type: " .. vtype
end

-- Main encode function
--: (table) -> (string | nil, string)
local function encode(tbl)
  if type(tbl) ~= "table" then
    return nil, "expected table input"
  end

  local out = {}
  local n = 0

  -- Collect keys into: simple values, sub-tables, array-of-tables
  local function write_table(t, prefix)
    -- sort keys
    local simple_keys = {}
    local table_keys = {}
    local array_table_keys = {}
    local sn, tn, an = 0, 0, 0

    local all_keys = {}
    local akn = 0
    for k in pairs(t) do akn = akn + 1; all_keys[akn] = k end
    table.sort(all_keys, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for i = 1, akn do
      local k = all_keys[i]
      local v = t[k]
      if type(v) == "table" and not v.__toml_type then
        -- check if it's an array of tables
        if #v > 0 then
          local all_tables = true
          local count = 0
          for _ in pairs(v) do count = count + 1 end
          if count == #v then
            -- sequential array
            for j = 1, #v do
              if type(v[j]) ~= "table" or v[j].__toml_type then
                all_tables = false
                break
              end
            end
            if all_tables then
              an = an + 1; array_table_keys[an] = k
            else
              -- array of non-tables — encode inline as simple value
              sn = sn + 1; simple_keys[sn] = k
            end
          else
            -- mixed table (has both array and hash parts) — use section
            tn = tn + 1; table_keys[tn] = k
          end
        else
          -- non-array table — always use section headers
          tn = tn + 1; table_keys[tn] = k
        end
      else
        sn = sn + 1; simple_keys[sn] = k
      end
    end

    -- write simple key-value pairs
    for i = 1, sn do
      local k = simple_keys[i]
      local enc, err = encode_inline(t[k])
      if not enc then return nil, err end
      n = n + 1; out[n] = quote_key(tostring(k)) .. " = " .. enc
    end

    -- write sub-tables
    for i = 1, tn do
      local k = table_keys[i]
      local full = prefix and (prefix .. "." .. quote_key(tostring(k))) or quote_key(tostring(k))
      n = n + 1; out[n] = ""
      n = n + 1; out[n] = "[" .. full .. "]"
      local err = write_table(t[k], full)
      if err then return err end
    end

    -- write arrays of tables
    for i = 1, an do
      local k = array_table_keys[i]
      local full = prefix and (prefix .. "." .. quote_key(tostring(k))) or quote_key(tostring(k))
      local arr = t[k]
      for j = 1, #arr do
        n = n + 1; out[n] = ""
        n = n + 1; out[n] = "[[" .. full .. "]]"
        local err = write_table(arr[j], full)
        if err then return err end
      end
    end
  end

  write_table(tbl, nil)

  -- trim leading empty line
  if n > 0 and out[1] == "" then
    table.remove(out, 1)
    n = n - 1
  end

  return concat(out, "\n") .. "\n"
end

-- Public API
M.decode = decode
M.encode = encode
M.string_to_toml = decode
M.toml_to_string = encode

return M
