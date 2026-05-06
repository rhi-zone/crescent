if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- TOML v1.0 parser.
-- Returns { decode = function(str) -> table | nil, err }

local M = {}

local byte = string.byte
local sub = string.sub
local find = string.find
local format = string.format
local tonumber = tonumber
local type = type

-- Character constants
local NEWLINE    = byte("\n") --[[:! integer]]
local CR         = byte("\r") --[[:! integer]]
local SPACE      = byte(" ")  --[[:! integer]]
local TAB        = byte("\t") --[[:! integer]]
local HASH       = byte("#")  --[[:! integer]]
local EQUALS     = byte("=")  --[[:! integer]]
local DOT        = byte(".")  --[[:! integer]]
local COMMA      = byte(",")  --[[:! integer]]
local LBRACKET   = byte("[")  --[[:! integer]]
local RBRACKET   = byte("]")  --[[:! integer]]
local LBRACE     = byte("{")  --[[:! integer]]
local RBRACE     = byte("}")  --[[:! integer]]
local DQUOTE     = byte('"')  --[[:! integer]]
local SQUOTE     = byte("'")  --[[:! integer]]
local BACKSLASH  = byte("\\") --[[:! integer]]
local PLUS       = byte("+")  --[[:! integer]]
local MINUS      = byte("-")  --[[:! integer]]
local UNDERSCORE = byte("_")  --[[:! integer]]
local COLON      = byte(":")  --[[:! integer]]
local CHAR_T     = byte("T")  --[[:! integer]]
local CHAR_t     = byte("t")  --[[:! integer]]
local CHAR_Z     = byte("Z")  --[[:! integer]]
local CHAR_z     = byte("z")  --[[:! integer]]
local CHAR_0     = byte("0")  --[[:! integer]]
local CHAR_9     = byte("9")  --[[:! integer]]
local CHAR_a     = byte("a")  --[[:! integer]]
local CHAR_f     = byte("f")  --[[:! integer]]
local CHAR_A     = byte("A")  --[[:! integer]]
local CHAR_F     = byte("F")  --[[:! integer]]

--: (integer | nil) -> boolean
local function is_digit(c)
  if not c then return false end
  if c >= CHAR_0 and c <= CHAR_9 then return true end
  return false
end

--: (integer | nil) -> boolean
local function is_hex(c)
  if not c then return false end
  if c >= CHAR_0 and c <= CHAR_9 then return true end
  if c >= CHAR_a and c <= CHAR_f then return true end
  if c >= CHAR_A and c <= CHAR_F then return true end
  return false
end

--: (integer | nil) -> boolean
local function is_ws(c)
  return c == SPACE or c == TAB
end

--: (integer | nil) -> boolean
local function is_bare_key_char(c)
  if not c then return false end
  if c >= CHAR_0 and c <= CHAR_9 then return true end
  if c >= CHAR_A and c <= CHAR_Z then return true end
  if c >= CHAR_a and c <= CHAR_z then return true end
  if c == MINUS or c == UNDERSCORE then return true end
  return false
end

-- Escape sequences for basic strings
local ESCAPES = {
  [byte("b")]  = "\b",
  [byte("t")]  = "\t",
  [byte("n")]  = "\n",
  [byte("f")]  = "\f",
  [byte("r")]  = "\r",
  [DQUOTE]     = '"',
  [BACKSLASH]  = "\\",
}

--:: Parser = { str: string, pos: integer, len: integer, line: integer }

-- Parser state
--: (string) -> Parser
local function new_parser(str)
  return {
    str = str,
    pos = 1,
    len = #str,
    line = 1,
  }
end

--: (Parser, string) -> (nil, string)
local function err(p, msg)
  return nil, format("line %d: %s", p.line, msg)
end

--: (Parser) -> integer | nil
local function peek(p)
  if p.pos > p.len then return nil end
  local b = byte(p.str, p.pos)
  return b
end

--: (Parser) -> integer | nil
local function advance(p)
  local c = byte(p.str, p.pos)
  if c == NEWLINE then p.line = p.line + 1 end
  p.pos = p.pos + 1
  return c
end

--: (Parser) -> ()
local function skip_ws(p)
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if not is_ws(c) then break end
    p.pos = p.pos + 1
  end
end

--: (Parser) -> ()
local function skip_ws_and_newlines(p)
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
    elseif is_ws(c) then
      p.pos = p.pos + 1
    else
      break
    end
  end
end

--: (Parser) -> ()
local function skip_comment(p)
  if p.pos <= p.len and byte(p.str, p.pos) == HASH then
    while p.pos <= p.len do
      local c = byte(p.str, p.pos)
      if c == NEWLINE or c == CR then break end
      p.pos = p.pos + 1
    end
  end
end

--: (Parser) -> ()
local function skip_ws_comment_newlines(p)
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if is_ws(c) then
      p.pos = p.pos + 1
    elseif c == HASH then
      skip_comment(p)
    elseif c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
    else
      break
    end
  end
end

--: (Parser, integer) -> (boolean | nil, string | nil)
local function expect(p, ch)
  if p.pos > p.len or byte(p.str, p.pos) ~= ch then
    return err(p, format("expected '%s'", string.char(ch)))
  end
  advance(p)
  return true
end

-- Parse a unicode escape (\uXXXX or \UXXXXXXXX) and return UTF-8 string
--: (integer) -> string | nil
local function unicode_to_utf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 64),
      0x80 + cp % 64
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  elseif cp < 0x110000 then
    return string.char(
      0xF0 + math.floor(cp / 262144),
      0x80 + math.floor(cp / 4096) % 64,
      0x80 + math.floor(cp / 64) % 64,
      0x80 + cp % 64
    )
  end
  return nil
end

-- Forward declarations
local parse_value

-- Parse basic (double-quoted) string
--: (Parser) -> (string | nil, string | nil)
local function parse_basic_string(p)
  advance(p) -- skip opening "
  local parts = {} --: { [integer]: string }
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if c == DQUOTE then
      advance(p)
      return table.concat(parts)
    elseif c == BACKSLASH then
      p.pos = p.pos + 1
      if p.pos > p.len then return err(p, "unexpected end of string") end
      local ec = byte(p.str, p.pos)
      local esc = ESCAPES[ec]
      if esc then
        parts[#parts + 1] = esc
        p.pos = p.pos + 1
      elseif ec == byte("u") then
        p.pos = p.pos + 1
        local hex = sub(p.str, p.pos, p.pos + 3)
        if #hex ~= 4 or not hex:match("^%x+$") then
          return err(p, "invalid \\u escape")
        end
        local cp = tonumber(hex, 16) --[[:! integer]]
        local u = unicode_to_utf8(cp)
        if not u then return err(p, "invalid unicode codepoint") end
        parts[#parts + 1] = u
        p.pos = p.pos + 4
      elseif ec == byte("U") then
        p.pos = p.pos + 1
        local hex = sub(p.str, p.pos, p.pos + 7)
        if #hex ~= 8 or not hex:match("^%x+$") then
          return err(p, "invalid \\U escape")
        end
        local cp = tonumber(hex, 16) --[[:! integer]]
        local u = unicode_to_utf8(cp)
        if not u then return err(p, "invalid unicode codepoint") end
        parts[#parts + 1] = u
        p.pos = p.pos + 8
      else
        return err(p, format("invalid escape '\\%s'", string.char(ec)))
      end
    elseif c == NEWLINE or c == CR then
      return err(p, "newline in basic string")
    else
      -- Scan forward for a run of plain characters
      local start = p.pos
      p.pos = p.pos + 1
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if cc == DQUOTE or cc == BACKSLASH or cc == NEWLINE or cc == CR then break end
        p.pos = p.pos + 1
      end
      parts[#parts + 1] = sub(p.str, start, p.pos - 1)
    end
  end
  return err(p, "unterminated basic string")
end

-- Parse multiline basic string
--: (Parser) -> (string | nil, string | nil)
local function parse_ml_basic_string(p)
  -- skip opening """
  p.pos = p.pos + 3
  -- skip immediate newline after opening
  if p.pos <= p.len then
    local c = byte(p.str, p.pos)
    if c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
    end
  end
  local parts = {} --: { [integer]: string }
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if c == DQUOTE then
      -- Check for """ (closing), allowing up to 5 quotes total (2 extra become content)
      local qcount = 0
      local qpos = p.pos
      while qpos <= p.len and byte(p.str, qpos) == DQUOTE do
        qcount = qcount + 1
        qpos = qpos + 1
      end
      if qcount >= 3 then
        -- Extra quotes (beyond 3) are content
        local extra = qcount - 3
        if extra > 0 then
          parts[#parts + 1] = string.rep('"', extra)
        end
        p.pos = qpos
        return table.concat(parts)
      else
        -- fewer than 3 quotes, they are content
        parts[#parts + 1] = sub(p.str, p.pos, p.pos + qcount - 1)
        p.pos = p.pos + qcount
      end
    elseif c == BACKSLASH then
      p.pos = p.pos + 1
      if p.pos > p.len then return err(p, "unexpected end of string") end
      local ec = byte(p.str, p.pos)
      -- Line-ending backslash (trim)
      if ec == NEWLINE or ec == CR or is_ws(ec) then
        -- Skip backslash + whitespace + newline + more whitespace
        skip_ws(p)
        if p.pos <= p.len then
          local nc = byte(p.str, p.pos)
          if nc == NEWLINE then
            p.line = p.line + 1
            p.pos = p.pos + 1
          elseif nc == CR then
            p.pos = p.pos + 1
            if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
              p.line = p.line + 1
              p.pos = p.pos + 1
            end
          end
        end
        skip_ws_and_newlines(p)
      else
        local esc = ESCAPES[ec]
        if esc then
          parts[#parts + 1] = esc
          p.pos = p.pos + 1
        elseif ec == byte("u") then
          p.pos = p.pos + 1
          local hex = sub(p.str, p.pos, p.pos + 3)
          if #hex ~= 4 or not hex:match("^%x+$") then
            return err(p, "invalid \\u escape")
          end
          local cp4 = tonumber(hex, 16) --[[:! integer]]
          local uu = unicode_to_utf8(cp4)
          if not uu then return err(p, "invalid unicode codepoint") end
          parts[#parts + 1] = uu
          p.pos = p.pos + 4
        elseif ec == byte("U") then
          p.pos = p.pos + 1
          local hex = sub(p.str, p.pos, p.pos + 7)
          if #hex ~= 8 or not hex:match("^%x+$") then
            return err(p, "invalid \\U escape")
          end
          local cp8 = tonumber(hex, 16) --[[:! integer]]
          local uu = unicode_to_utf8(cp8)
          if not uu then return err(p, "invalid unicode codepoint") end
          parts[#parts + 1] = uu
          p.pos = p.pos + 8
        else
          return err(p, format("invalid escape '\\%s'", string.char(ec)))
        end
      end
    elseif c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
      parts[#parts + 1] = "\n"
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
      parts[#parts + 1] = "\n"
    else
      local start = p.pos
      p.pos = p.pos + 1
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if cc == DQUOTE or cc == BACKSLASH or cc == NEWLINE or cc == CR then break end
        p.pos = p.pos + 1
      end
      parts[#parts + 1] = sub(p.str, start, p.pos - 1)
    end
  end
  return err(p, "unterminated multiline basic string")
end

-- Parse literal (single-quoted) string
--: (Parser) -> (string | nil, string | nil)
local function parse_literal_string(p)
  advance(p) -- skip opening '
  local start = p.pos
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if c == SQUOTE then
      local s = sub(p.str, start, p.pos - 1)
      advance(p)
      return s
    elseif c == NEWLINE or c == CR then
      return err(p, "newline in literal string")
    end
    p.pos = p.pos + 1
  end
  return err(p, "unterminated literal string")
end

-- Parse multiline literal string
--: (Parser) -> (string | nil, string | nil)
local function parse_ml_literal_string(p)
  p.pos = p.pos + 3 -- skip opening '''
  -- skip immediate newline
  if p.pos <= p.len then
    local c = byte(p.str, p.pos)
    if c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
    end
  end
  local parts = {} --: { [integer]: string }
  while p.pos <= p.len do
    local c = byte(p.str, p.pos)
    if c == SQUOTE then
      local qcount = 0
      local qpos = p.pos
      while qpos <= p.len and byte(p.str, qpos) == SQUOTE do
        qcount = qcount + 1
        qpos = qpos + 1
      end
      if qcount >= 3 then
        local extra = qcount - 3
        if extra > 0 then
          parts[#parts + 1] = string.rep("'", extra)
        end
        p.pos = qpos
        return table.concat(parts)
      else
        parts[#parts + 1] = sub(p.str, p.pos, p.pos + qcount - 1)
        p.pos = p.pos + qcount
      end
    elseif c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
      parts[#parts + 1] = "\n"
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
      parts[#parts + 1] = "\n"
    else
      local start = p.pos
      p.pos = p.pos + 1
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if cc == SQUOTE or cc == NEWLINE or cc == CR then break end
        p.pos = p.pos + 1
      end
      parts[#parts + 1] = sub(p.str, start, p.pos - 1)
    end
  end
  return err(p, "unterminated multiline literal string")
end

-- Parse any string type
--: (Parser) -> (string | nil, string | nil)
local function parse_string(p)
  local c1 = byte(p.str, p.pos)
  if c1 == DQUOTE then
    -- Check for multiline
    if p.pos + 2 <= p.len and byte(p.str, p.pos + 1) == DQUOTE and byte(p.str, p.pos + 2) == DQUOTE then
      return parse_ml_basic_string(p)
    end
    return parse_basic_string(p)
  elseif c1 == SQUOTE then
    if p.pos + 2 <= p.len and byte(p.str, p.pos + 1) == SQUOTE and byte(p.str, p.pos + 2) == SQUOTE then
      return parse_ml_literal_string(p)
    end
    return parse_literal_string(p)
  end
  return err(p, "expected string")
end

-- Parse a bare key
--: (Parser) -> (string | nil, string | nil)
local function parse_bare_key(p)
  local start = p.pos
  while p.pos <= p.len and is_bare_key_char(byte(p.str, p.pos)) do
    p.pos = p.pos + 1
  end
  if p.pos == start then
    return err(p, "expected key")
  end
  return sub(p.str, start, p.pos - 1)
end

-- Parse a simple key (bare or quoted)
--: (Parser) -> (string | nil, string | nil)
local function parse_simple_key(p)
  local c = peek(p)
  if c == DQUOTE then
    -- Must not be multiline
    if p.pos + 2 <= p.len and byte(p.str, p.pos + 1) == DQUOTE and byte(p.str, p.pos + 2) == DQUOTE then
      return err(p, "multiline strings not allowed as keys")
    end
    return parse_basic_string(p)
  elseif c == SQUOTE then
    if p.pos + 2 <= p.len and byte(p.str, p.pos + 1) == SQUOTE and byte(p.str, p.pos + 2) == SQUOTE then
      return err(p, "multiline strings not allowed as keys")
    end
    return parse_literal_string(p)
  else
    return parse_bare_key(p)
  end
end

-- Parse a dotted key, returns list of key parts
--: (Parser) -> ({ [integer]: string } | nil, string | nil)
local function parse_key(p)
  local keys = {}
  local k, e = parse_simple_key(p)
  if not k then return nil, e end
  keys[1] = k
  while p.pos <= p.len and byte(p.str, p.pos) == DOT do
    p.pos = p.pos + 1 -- skip dot
    skip_ws(p)
    k, e = parse_simple_key(p)
    if not k then return nil, e end
    keys[#keys + 1] = k
    skip_ws(p)
  end
  return keys
end

-- Parse integer (decimal, hex, octal, binary)
-- Returns number or nil, err
--: (Parser) -> (unknown, string | nil)
local function parse_number(p)
  local start = p.pos
  local c = byte(p.str, p.pos)

  -- Sign
  local sign = 1
  if c == PLUS or c == MINUS then
    if c == MINUS then sign = -1 end
    p.pos = p.pos + 1
    c = byte(p.str, p.pos)
  end

  -- Special float values: inf, nan
  if p.pos + 2 <= p.len then
    local word = sub(p.str, p.pos, p.pos + 2)
    if word == "inf" then
      p.pos = p.pos + 3
      return sign * math.huge
    elseif word == "nan" then
      p.pos = p.pos + 3
      return 0/0
    end
  end

  if not is_digit(c) then
    return err(p, "expected number")
  end

  -- Check for 0x, 0o, 0b prefixes
  if c == CHAR_0 and p.pos + 1 <= p.len then
    local c2 = byte(p.str, p.pos + 1)
    if c2 == byte("x") or c2 == byte("X") then
      p.pos = p.pos + 2
      local hex_start = p.pos
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if is_hex(cc) then
          p.pos = p.pos + 1
        elseif cc == UNDERSCORE then
          p.pos = p.pos + 1
        else
          break
        end
      end
      local raw = sub(p.str, hex_start, p.pos - 1):gsub("_", "")
      if #raw == 0 then return err(p, "invalid hex integer") end
      return sign * (tonumber(raw, 16) --[[:! number]])
    elseif c2 == byte("o") or c2 == byte("O") then
      p.pos = p.pos + 2
      local oct_start = p.pos
      local CHAR_7 = byte("7") --[[:! integer]]
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos) or 0
        if cc >= CHAR_0 and cc <= CHAR_7 then
          p.pos = p.pos + 1
        elseif cc == UNDERSCORE then
          p.pos = p.pos + 1
        else
          break
        end
      end
      local raw = sub(p.str, oct_start, p.pos - 1):gsub("_", "")
      if #raw == 0 then return err(p, "invalid octal integer") end
      return sign * (tonumber(raw, 8) --[[:! number]])
    elseif c2 == byte("b") or c2 == byte("B") then
      p.pos = p.pos + 2
      local bin_start = p.pos
      local CHAR_1 = byte("1") --[[:! integer]]
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos) or 0
        if cc == CHAR_0 or cc == CHAR_1 then
          p.pos = p.pos + 1
        elseif cc == UNDERSCORE then
          p.pos = p.pos + 1
        else
          break
        end
      end
      local raw = sub(p.str, bin_start, p.pos - 1):gsub("_", "")
      if #raw == 0 then return err(p, "invalid binary integer") end
      return sign * (tonumber(raw, 2) --[[:! number]])
    end
  end

  -- Decimal integer or float
  local num_start = p.pos
  while p.pos <= p.len do
    local cc = byte(p.str, p.pos)
    if is_digit(cc) or cc == UNDERSCORE then
      p.pos = p.pos + 1
    else
      break
    end
  end

  local is_float = false
  -- Check for decimal point (but not ".." which could be something else)
  if p.pos <= p.len and byte(p.str, p.pos) == DOT then
    -- Must be followed by a digit for it to be a float
    if p.pos + 1 <= p.len and is_digit(byte(p.str, p.pos + 1)) then
      is_float = true
      p.pos = p.pos + 1 -- skip dot
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if is_digit(cc) or cc == UNDERSCORE then
          p.pos = p.pos + 1
        else
          break
        end
      end
    end
  end

  -- Check for exponent
  if p.pos <= p.len then
    local ec = byte(p.str, p.pos)
    if ec == byte("e") or ec == byte("E") then
      is_float = true
      p.pos = p.pos + 1
      if p.pos <= p.len then
        local sc = byte(p.str, p.pos)
        if sc == PLUS or sc == MINUS then
          p.pos = p.pos + 1
        end
      end
      while p.pos <= p.len do
        local cc = byte(p.str, p.pos)
        if is_digit(cc) or cc == UNDERSCORE then
          p.pos = p.pos + 1
        else
          break
        end
      end
    end
  end

  local raw = sub(p.str, num_start, p.pos - 1):gsub("_", "")
  local n = tonumber(raw)
  if not n then
    return err(p, "invalid number: " .. sub(p.str, start, p.pos - 1))
  end
  return sign * n
end

-- Try to parse a datetime / date / time value starting at pos.
-- TOML datetime formats:
--   offset datetime: 1979-05-27T07:32:00Z or 1979-05-27T07:32:00+00:00
--   local datetime:  1979-05-27T07:32:00
--   local date:      1979-05-27
--   local time:      07:32:00
-- Returns table with __toml_type or nil (not a datetime, caller should try number)
--: (Parser) -> (unknown, string | nil)
local function try_parse_datetime(p)
  local s = p.str
  local pos = p.pos

  -- Try date: YYYY-MM-DD
  local date_match = false
  local year, month, day
  if pos + 9 <= p.len
    and is_digit(byte(s, pos))
    and is_digit(byte(s, pos+1))
    and is_digit(byte(s, pos+2))
    and is_digit(byte(s, pos+3))
    and byte(s, pos+4) == MINUS
    and is_digit(byte(s, pos+5))
    and is_digit(byte(s, pos+6))
    and byte(s, pos+7) == MINUS
    and is_digit(byte(s, pos+8))
    and is_digit(byte(s, pos+9))
  then
    year = tonumber(sub(s, pos, pos+3))
    month = tonumber(sub(s, pos+5, pos+6))
    day = tonumber(sub(s, pos+8, pos+9))
    date_match = true
  end

  -- Try time without date: HH:MM:SS
  if not date_match then
    if pos + 7 <= p.len
      and is_digit(byte(s, pos))
      and is_digit(byte(s, pos+1))
      and byte(s, pos+2) == COLON
      and is_digit(byte(s, pos+3))
      and is_digit(byte(s, pos+4))
      and byte(s, pos+5) == COLON
      and is_digit(byte(s, pos+6))
      and is_digit(byte(s, pos+7))
    then
      local hour = tonumber(sub(s, pos, pos+1))
      local min = tonumber(sub(s, pos+3, pos+4))
      local sec_str = sub(s, pos+6, pos+7)
      p.pos = pos + 8
      -- fractional seconds
      if p.pos <= p.len and byte(s, p.pos) == DOT then
        p.pos = p.pos + 1
        local frac_start = p.pos
        while p.pos <= p.len and is_digit(byte(s, p.pos)) do
          p.pos = p.pos + 1
        end
        sec_str = sec_str .. "." .. sub(s, frac_start, p.pos - 1)
      end
      return { hour = hour, min = min, sec = tonumber(sec_str), __toml_type = "time" }
    end
    return nil -- not a datetime
  end

  -- We have a date. Check for time separator (T or space or t)
  local tpos = pos + 10
  if tpos <= p.len then
    local sep = byte(s, tpos)
    if sep == CHAR_T or sep == CHAR_t or sep == SPACE then
      -- Check for time: HH:MM:SS
      local tp = tpos + 1
      if tp + 7 <= p.len
        and is_digit(byte(s, tp))
        and is_digit(byte(s, tp+1))
        and byte(s, tp+2) == COLON
        and is_digit(byte(s, tp+3))
        and is_digit(byte(s, tp+4))
        and byte(s, tp+5) == COLON
        and is_digit(byte(s, tp+6))
        and is_digit(byte(s, tp+7))
      then
        local hour = tonumber(sub(s, tp, tp+1))
        local min = tonumber(sub(s, tp+3, tp+4))
        local sec_str = sub(s, tp+6, tp+7)
        p.pos = tp + 8
        -- fractional seconds
        if p.pos <= p.len and byte(s, p.pos) == DOT then
          p.pos = p.pos + 1
          local frac_start = p.pos
          while p.pos <= p.len and is_digit(byte(s, p.pos)) do
            p.pos = p.pos + 1
          end
          sec_str = sec_str .. "." .. sub(s, frac_start, p.pos - 1)
        end
        -- Check for offset
        local offset = nil
        if p.pos <= p.len then
          local oc = byte(s, p.pos)
          if oc == CHAR_Z or oc == CHAR_z then
            offset = "Z"
            p.pos = p.pos + 1
          elseif oc == PLUS or oc == MINUS then
            local ostart = p.pos
            p.pos = p.pos + 1
            -- HH:MM
            if p.pos + 4 <= p.len
              and is_digit(byte(s, p.pos))
              and is_digit(byte(s, p.pos+1))
              and byte(s, p.pos+2) == COLON
              and is_digit(byte(s, p.pos+3))
              and is_digit(byte(s, p.pos+4))
            then
              p.pos = p.pos + 5
              offset = sub(s, ostart, p.pos - 1)
            end
          end
        end
        if offset then
          return { year = year, month = month, day = day,
                   hour = hour, min = min, sec = tonumber(sec_str),
                   offset = offset, __toml_type = "datetime" }
        else
          return { year = year, month = month, day = day,
                   hour = hour, min = min, sec = tonumber(sec_str),
                   __toml_type = "datetime-local" }
        end
      end
    end
  end

  -- Date only
  p.pos = pos + 10
  return { year = year, month = month, day = day, __toml_type = "date" }
end

-- Parse inline table
--: (Parser) -> (unknown, string | nil)
local function parse_inline_table(p)
  advance(p) -- skip {
  local tbl = {}
  skip_ws(p)
  if peek(p) == RBRACE then
    advance(p)
    return tbl
  end
  while true do
    skip_ws(p)
    local keys, e = parse_key(p)
    if not keys then return nil, e end
    skip_ws(p)
    local ok2, e2 = expect(p, EQUALS)
    if not ok2 then return nil, e2 end
    skip_ws(p)
    local val, e3 = parse_value(p)
    if val == nil and e3 then return nil, e3 end

    -- Set value at dotted key path
    local target = tbl
    for i = 1, #keys - 1 do
      local k = keys[i]
      if target[k] == nil then
        target[k] = {}
      elseif type(target[k]) ~= "table" then
        return err(p, format("key '%s' already exists as non-table", k))
      end
      target = target[k]
    end
    local final_key = keys[#keys]
    if target[final_key] ~= nil then
      return err(p, format("duplicate key '%s'", final_key))
    end
    target[final_key] = val

    skip_ws(p)
    local c = peek(p)
    if c == COMMA then
      advance(p)
    elseif c == RBRACE then
      advance(p)
      return tbl
    else
      return err(p, "expected ',' or '}' in inline table")
    end
  end
end

-- Parse array
--: (Parser) -> (unknown, string | nil)
local function parse_array(p)
  advance(p) -- skip [
  local arr = {}
  skip_ws_comment_newlines(p)
  if peek(p) == RBRACKET then
    advance(p)
    return arr
  end
  while true do
    skip_ws_comment_newlines(p)
    local val, e = parse_value(p)
    if val == nil and e then return nil, e end
    arr[#arr + 1] = val
    skip_ws_comment_newlines(p)
    local c = peek(p)
    if c == COMMA then
      advance(p)
      skip_ws_comment_newlines(p)
      -- Allow trailing comma
      if peek(p) == RBRACKET then
        advance(p)
        return arr
      end
    elseif c == RBRACKET then
      advance(p)
      return arr
    else
      return err(p, "expected ',' or ']' in array")
    end
  end
end

-- Parse a value
parse_value = function(p)
  skip_ws(p)
  local c = peek(p)
  if not c then return err(p, "unexpected end of input") end

  -- Strings
  if c == DQUOTE or c == SQUOTE then
    return parse_string(p)
  end

  -- Arrays
  if c == LBRACKET then
    return parse_array(p)
  end

  -- Inline tables
  if c == LBRACE then
    return parse_inline_table(p)
  end

  -- Booleans
  if c == byte("t") and sub(p.str, p.pos, p.pos + 3) == "true" then
    -- Make sure it's not part of a bare key
    local after = byte(p.str, p.pos + 4)
    if not after or not is_bare_key_char(after) then
      p.pos = p.pos + 4
      return true
    end
  end
  if c == byte("f") and sub(p.str, p.pos, p.pos + 4) == "false" then
    local after = byte(p.str, p.pos + 5)
    if not after or not is_bare_key_char(after) then
      p.pos = p.pos + 5
      return false
    end
  end

  -- Try datetime first (before number, since dates start with digits)
  local save_pos = p.pos
  local save_line = p.line
  local dt = try_parse_datetime(p)
  if dt then return dt end
  p.pos = save_pos
  p.line = save_line

  -- Numbers (including inf, nan with signs)
  if is_digit(c) or c == PLUS or c == MINUS then
    return parse_number(p)
  end

  -- inf/nan without sign
  if c == byte("i") and sub(p.str, p.pos, p.pos + 2) == "inf" then
    p.pos = p.pos + 3
    return math.huge
  end
  if c == byte("n") and sub(p.str, p.pos, p.pos + 2) == "nan" then
    p.pos = p.pos + 3
    return 0/0
  end

  return err(p, format("unexpected character '%s'", string.char(c)))
end

-- Track defined tables to prevent redefinition
-- defined[path_string] = "table" | "array" | "implicit"
-- "implicit" means created by a dotted key or super-table reference

local function path_to_string(keys)
  local parts = {}
  for i = 1, #keys do
    parts[i] = keys[i]:gsub("\\", "\\\\"):gsub("\0", "\\0")
  end
  return table.concat(parts, "\0")
end

--: (string) -> (table | nil, string | nil)
--- Decode a TOML string into a Lua table.
-- @param str string: TOML input
-- @return table|nil: parsed result, or nil on error
-- @return string|nil: error message on failure
function M.decode(str)
  if type(str) ~= "string" then
    return nil, "expected string input"
  end

  local p = new_parser(str)
  local root = {} --: { [string]: unknown }
  local current = root  --: { [string]: unknown }
  local current_path = {} --: { [integer]: string }
  local defined = {} --: { [string]: string }

  while p.pos <= p.len do
    skip_ws(p)
    skip_comment(p)

    local c = peek(p)
    if not c then break end

    if c == NEWLINE then
      p.line = p.line + 1
      p.pos = p.pos + 1
    elseif c == CR then
      p.pos = p.pos + 1
      if p.pos <= p.len and byte(p.str, p.pos) == NEWLINE then
        p.line = p.line + 1
        p.pos = p.pos + 1
      end
    elseif c == LBRACKET then
      -- Table header or array of tables
      p.pos = p.pos + 1
      local is_aot = false
      if peek(p) == LBRACKET then
        is_aot = true
        p.pos = p.pos + 1
      end
      skip_ws(p)
      local keys, e = parse_key(p)
      if not keys then return nil, e end
      skip_ws(p)

      if is_aot then
        local ok2, e2 = expect(p, RBRACKET)
        if not ok2 then return nil, e2 end
        local ok3, e3 = expect(p, RBRACKET)
        if not ok3 then return nil, e3 end
      else
        local ok2, e2 = expect(p, RBRACKET)
        if not ok2 then return nil, e2 end
      end

      skip_ws(p)
      skip_comment(p)

      -- Navigate to the table
      local target = root
      local path = {}
      for i = 1, #keys - 1 do
        path[#path + 1] = keys[i]
        local k = keys[i]
        if target[k] == nil then
          target[k] = {}
          local ps = path_to_string(path)
          if not defined[ps] then
            defined[ps] = "implicit"
          end
        elseif type(target[k]) ~= "table" then
          return err(p, format("key '%s' already exists as non-table", k))
        end
        local v = target[k] --[[:! { [string]: unknown }]]
        -- If it's an array of tables, navigate to the last element
        if #v > 0 and type(v[1]) == "table" and defined[path_to_string(path)] == "array" then
          target = v[#v] --[[:! { [string]: unknown }]]
        else
          target = v
        end
      end

      local final_key = keys[#keys]
      path[#path + 1] = final_key
      local ps = path_to_string(path)

      if is_aot then
        -- Array of tables
        if target[final_key] == nil then
          target[final_key] = {}
          defined[ps] = "array"
        elseif defined[ps] == "array" then
          -- ok, append
        elseif defined[ps] == "table" then
          return err(p, format("cannot define array of tables '%s', already defined as table", final_key))
        else
          return err(p, format("key '%s' already exists", final_key))
        end
        local new_tbl = {}
        local aot = target[final_key] --[[:! { [integer]: { [string]: unknown } }]]
        aot[#aot + 1] = new_tbl
        current = new_tbl
        current_path = path
      else
        -- Standard table
        if defined[ps] == "table" then
          return err(p, format("table '%s' already defined", final_key))
        elseif defined[ps] == "array" then
          return err(p, format("cannot define table '%s', already defined as array", final_key))
        end
        if target[final_key] == nil then
          target[final_key] = {}
        elseif type(target[final_key]) ~= "table" then
          return err(p, format("key '%s' already exists as non-table", final_key))
        end
        defined[ps] = "table"
        current = target[final_key] --[[:! { [string]: unknown }]]
        current_path = path
      end

    elseif c == HASH then
      skip_comment(p)
    elseif is_bare_key_char(c) or c == DQUOTE or c == SQUOTE then
      -- Key/value pair
      local keys, e = parse_key(p)
      if not keys then return nil, e end
      skip_ws(p)
      local ok2, e2 = expect(p, EQUALS)
      if not ok2 then return nil, e2 end
      skip_ws(p)
      local val, e3 = parse_value(p)
      if val == nil and e3 then return nil, e3 end

      -- Set value at dotted key path within current table
      local target = current
      for i = 1, #keys - 1 do
        local k = keys[i]
        if target[k] == nil then
          target[k] = {}
          -- Mark as implicitly defined
          local imp_path = {}
          for j = 1, #current_path do imp_path[j] = current_path[j] end
          for j = 1, i do imp_path[#imp_path + 1] = keys[j] end
          defined[path_to_string(imp_path)] = "implicit"
        elseif type(target[k]) ~= "table" then
          return err(p, format("key '%s' already exists as non-table", k))
        end
        target = target[k] --[[:! { [string]: unknown }]]
      end
      local final_key = keys[#keys]
      if target[final_key] ~= nil then
        return err(p, format("duplicate key '%s'", final_key))
      end
      target[final_key] = val

      skip_ws(p)
      skip_comment(p)
    else
      return err(p, format("unexpected character '%s'", string.char(c)))
    end
  end

  return root
end

return M
