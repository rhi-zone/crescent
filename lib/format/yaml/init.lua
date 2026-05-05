if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- YAML 1.2 Core Schema parser and encoder.
-- Supports: scalars, block/flow collections, multi-line strings,
-- anchors/aliases, merge key, multiple documents.
-- NOT supported: tags, complex mapping keys, %YAML directive.

local M = {}

local byte = string.byte
local sub = string.sub
local find = string.find
local gsub = string.gsub
local format = string.format
local rep = string.rep
local concat = table.concat
local sort = table.sort
local type = type
local tonumber = tonumber
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local huge = math.huge

-- ── Decoder ──────────────────────────────────────────────────────────────────

--:: Parser = { s: string, pos: integer, len: integer, anchors: { [string]: unknown } }

--: (string) -> Parser
local function make_parser(str)
  local p = {
    s = str,
    pos = 1,
    len = #str,
    anchors = {},
  } --[[:! Parser]]
  return p
end

--: (Parser) -> integer | nil
local function peek(p)
  if p.pos > p.len then return nil end
  local b = byte(p.s, p.pos)
  return b
end

--: (Parser, integer) -> integer | nil
local function peek_at(p, offset)
  local i = p.pos + offset
  if i > p.len then return nil end
  local b = byte(p.s, i)
  return b
end

--: (Parser, integer | nil) -> ()
local function advance(p, n)
  p.pos = p.pos + (n or 1)
end

--: (Parser) -> boolean
local function at_end(p)
  return p.pos > p.len
end

--: (Parser) -> string | nil
local function current_char(p)
  if p.pos > p.len then return nil end
  return sub(p.s, p.pos, p.pos)
end

--: (Parser) -> unknown
local function rest_of_line(p)
  local nl = find(p.s, "\n", p.pos, true)
  if nl then
    local line = sub(p.s, p.pos, nl - 1)
    return line
  end
  return sub(p.s, p.pos)
end

--: (Parser) -> unknown
local function skip_spaces(p)
  while p.pos <= p.len do
    local c = byte(p.s, p.pos)
    if c == 0x20 or c == 0x09 then
      p.pos = p.pos + 1
    else
      break
    end
  end
end

--: (Parser) -> unknown
local function skip_whitespace_and_comments(p)
  while p.pos <= p.len do
    local c = byte(p.s, p.pos)
    if c == 0x20 or c == 0x09 then
      p.pos = p.pos + 1
    elseif c == 0x23 then -- #
      -- skip to end of line
      local nl = find(p.s, "\n", p.pos, true)
      if nl then
        p.pos = nl
      else
        p.pos = p.len + 1
      end
      break
    else
      break
    end
  end
end

--: (Parser) -> unknown
local function skip_blank_lines(p)
  while p.pos <= p.len do
    local saved = p.pos
    skip_spaces(p)
    local c = peek(p)
    if c == 0x0A then -- newline
      p.pos = p.pos + 1
    elseif c == 0x0D then -- CR
      p.pos = p.pos + 1
      if peek(p) == 0x0A then p.pos = p.pos + 1 end
    elseif c == 0x23 then -- comment
      local nl = find(p.s, "\n", p.pos, true)
      if nl then
        p.pos = nl + 1
      else
        p.pos = p.len + 1
      end
    else
      p.pos = saved
      return
    end
  end
end

--: (Parser) -> unknown
local function expect_newline_or_end(p)
  skip_whitespace_and_comments(p)
  if at_end(p) then return true end
  local c = peek(p)
  if c == 0x0A then
    p.pos = p.pos + 1
    return true
  elseif c == 0x0D then
    p.pos = p.pos + 1
    if peek(p) == 0x0A then p.pos = p.pos + 1 end
    return true
  end
  return false
end

--: (Parser) -> unknown
local function get_indent(p)
  local col = 0
  local i = p.pos
  while i <= p.len do
    local c = byte(p.s, i)
    if c == 0x20 then
      col = col + 1
      i = i + 1
    else
      break
    end
  end
  return col
end

-- Double-quoted string escape sequences
local DOUBLE_ESCAPES = {
  ["\\"] = "\\",
  ['"'] = '"',
  ["0"] = "\0",
  a = "\a",
  b = "\b",
  t = "\t",
  n = "\n",
  v = "\v",
  f = "\f",
  r = "\r",
  e = "\27",
  [" "] = " ",
  ["/"] = "/",
  N = "\194\133",     -- Unicode NEL
  _ = "\194\160",     -- Unicode NBSP
  L = "\226\128\168", -- Unicode LS
  P = "\226\128\169", -- Unicode PS
}

--: (Parser, integer) -> (string | nil, string | nil)
local function parse_hex_escape(p, n)
  local hex = sub(p.s, p.pos, p.pos + n - 1)
  if #hex ~= n or not hex:match("^%x+$") then
    return nil, format("invalid hex escape at position %d", p.pos)
  end
  p.pos = p.pos + n
  local code = tonumber(hex, 16)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(
      0xC0 + math.floor(code / 64),
      0x80 + code % 64
    )
  elseif code < 0x10000 then
    return string.char(
      0xE0 + math.floor(code / 4096),
      0x80 + math.floor(code / 64) % 64,
      0x80 + code % 64
    )
  else
    return string.char(
      0xF0 + math.floor(code / 262144),
      0x80 + math.floor(code / 4096) % 64,
      0x80 + math.floor(code / 64) % 64,
      0x80 + code % 64
    )
  end
end

--: (Parser) -> unknown
local function parse_double_quoted(p)
  p.pos = p.pos + 1 -- skip opening "
  local parts = {}
  while p.pos <= p.len do
    local c = byte(p.s, p.pos)
    if c == 0x22 then -- "
      p.pos = p.pos + 1
      return concat(parts)
    elseif c == 0x5C then -- backslash
      p.pos = p.pos + 1
      if p.pos > p.len then
        return nil, "unexpected end of string"
      end
      local esc_char = sub(p.s, p.pos, p.pos)
      if esc_char == "x" then
        p.pos = p.pos + 1
        local ch, err = parse_hex_escape(p, 2)
        if not ch then return nil, err end
        parts[#parts + 1] = ch
      elseif esc_char == "u" then
        p.pos = p.pos + 1
        local ch, err = parse_hex_escape(p, 4)
        if not ch then return nil, err end
        parts[#parts + 1] = ch
      elseif esc_char == "U" then
        p.pos = p.pos + 1
        local ch, err = parse_hex_escape(p, 8)
        if not ch then return nil, err end
        parts[#parts + 1] = ch
      elseif DOUBLE_ESCAPES[esc_char] then
        parts[#parts + 1] = DOUBLE_ESCAPES[esc_char]
        p.pos = p.pos + 1
      elseif esc_char == "\n" or esc_char == "\r" then
        -- line continuation: skip newline and leading whitespace
        if esc_char == "\r" and peek_at(p, 1) == 0x0A then
          p.pos = p.pos + 1
        end
        p.pos = p.pos + 1
        skip_spaces(p)
      else
        return nil, format("unknown escape '\\%s' at position %d", esc_char, p.pos)
      end
    else
      parts[#parts + 1] = sub(p.s, p.pos, p.pos)
      p.pos = p.pos + 1
    end
  end
  return nil, "unterminated double-quoted string"
end

--: (Parser) -> unknown
local function parse_single_quoted(p)
  p.pos = p.pos + 1 -- skip opening '
  local parts = {}
  while p.pos <= p.len do
    local c = byte(p.s, p.pos)
    if c == 0x27 then -- '
      if peek_at(p, 1) == 0x27 then
        -- escaped single quote
        parts[#parts + 1] = "'"
        p.pos = p.pos + 2
      else
        p.pos = p.pos + 1
        return concat(parts)
      end
    else
      parts[#parts + 1] = sub(p.s, p.pos, p.pos)
      p.pos = p.pos + 1
    end
  end
  return nil, "unterminated single-quoted string"
end

-- Parse a plain scalar (unquoted), stopping at flow indicators in flow context
--: (Parser, boolean) -> unknown
local function parse_plain_scalar(p, in_flow)
  local start = p.pos
  local last_non_space = p.pos - 1
  while p.pos <= p.len do
    local c = byte(p.s, p.pos)
    if c == 0x0A or c == 0x0D then
      break
    end
    if c == 0x23 and p.pos > start then -- #
      local prev = byte(p.s, p.pos - 1)
      if prev == 0x20 or prev == 0x09 then
        break
      end
    end
    if c == 0x3A then -- :
      local next_c = peek_at(p, 1)
      if next_c == nil or next_c == 0x20 or next_c == 0x09 or next_c == 0x0A or next_c == 0x0D then
        if in_flow then
          break
        end
        -- in block context, colon followed by space ends the key
        break
      end
      if in_flow and (next_c == 0x2C or next_c == 0x5D or next_c == 0x7D) then
        break
      end
    end
    if in_flow and (c == 0x2C or c == 0x5D or c == 0x7D or c == 0x5B or c == 0x7B) then
      break
    end
    if c ~= 0x20 and c ~= 0x09 then
      last_non_space = p.pos
    end
    p.pos = p.pos + 1
  end
  if last_non_space < start then
    return ""
  end
  return sub(p.s, start, last_non_space)
end

-- Resolve a plain scalar to its typed value
local function resolve_scalar(s)
  if s == "" or s == "~" or s == "null" or s == "Null" or s == "NULL" then
    return nil
  end
  if s == "true" or s == "True" or s == "TRUE" then
    return true
  end
  if s == "false" or s == "False" or s == "FALSE" then
    return false
  end
  if s == ".inf" or s == ".Inf" or s == ".INF" then
    return huge
  end
  if s == "-.inf" or s == "-.Inf" or s == "-.INF" then
    return -huge
  end
  if s == "+.inf" or s == "+.Inf" or s == "+.INF" then
    return huge
  end
  if s == ".nan" or s == ".NaN" or s == ".NAN" then
    return 0/0
  end
  -- hex integer
  if find(s, "^0x%x+$") or find(s, "^-0x%x+$") or find(s, "^%+0x%x+$") then
    return tonumber(s)
  end
  -- octal integer
  local oct_match = s:match("^(%-?)0o([0-7]+)$") or s:match("^(%+?)0o([0-7]+)$")
  if oct_match then
    local sign, digits = s:match("^([%-%+]?)0o([0-7]+)$")
    local val = tonumber(digits, 8)
    if sign == "-" then val = -val end
    return val
  end
  -- integer (no dots, no e/E unless hex)
  if find(s, "^[%-%+]?%d+$") then
    return tonumber(s)
  end
  -- float
  if find(s, "^[%-%+]?%d*%.?%d+$") or find(s, "^[%-%+]?%d*%.?%d+[eE][%-%+]?%d+$") then
    return tonumber(s)
  end
  -- return as string
  return s
end

local parse_value -- forward declaration

--: (Parser, integer) -> unknown
local function parse_block_scalar(p, min_indent)
  local indicator = sub(p.s, p.pos, p.pos)
  local is_literal = (indicator == "|")
  p.pos = p.pos + 1

  -- Parse chomping indicator and explicit indent
  local chomp = "clip"
  local explicit_indent = nil

  while p.pos <= p.len do
    local c = byte(p.s, p.pos) or 0
    if c == 0x2B then -- +
      chomp = "keep"
      p.pos = p.pos + 1
    elseif c == 0x2D then -- -
      chomp = "strip"
      p.pos = p.pos + 1
    elseif c >= 0x31 and c <= 0x39 then -- 1-9
      explicit_indent = c - 0x30
      p.pos = p.pos + 1
    else
      break
    end
  end

  -- Skip rest of line (and comment)
  skip_whitespace_and_comments(p)
  if not at_end(p) then
    local c = peek(p)
    if c == 0x0A then
      p.pos = p.pos + 1
    elseif c == 0x0D then
      p.pos = p.pos + 1
      if peek(p) == 0x0A then p.pos = p.pos + 1 end
    end
  end

  -- Collect content lines
  local lines = {}
  local content_indent = nil

  while p.pos <= p.len do
    -- Check if this line is blank
    local line_start = p.pos
    local indent = 0
    while p.pos <= p.len and byte(p.s, p.pos) == 0x20 do
      indent = indent + 1
      p.pos = p.pos + 1
    end

    local c = peek(p)
    if c == nil or c == 0x0A or c == 0x0D then
      -- blank line
      lines[#lines + 1] = ""
      if c == 0x0D then
        p.pos = p.pos + 1
        if peek(p) == 0x0A then p.pos = p.pos + 1 end
      elseif c == 0x0A then
        p.pos = p.pos + 1
      end
    else
      -- Determine content indent from first non-blank line
      if not content_indent then
        if explicit_indent then
          content_indent = min_indent + explicit_indent
        else
          content_indent = indent
        end
      end

      if indent < content_indent then
        -- This line is less indented than content - end of block scalar
        p.pos = line_start
        break
      end

      -- Read the rest of the line
      local nl = find(p.s, "\n", p.pos, true)
      local line_end
      if nl then
        line_end = nl - 1
        if line_end >= p.pos and byte(p.s, line_end) == 0x0D then
          line_end = line_end - 1
        end
      else
        line_end = p.len
      end

      local line_content = rep(" ", indent - content_indent) .. sub(p.s, p.pos, line_end)
      lines[#lines + 1] = line_content

      if nl then
        p.pos = nl + 1
      else
        p.pos = p.len + 1
      end
    end
  end

  -- Remove trailing blank lines for chomp processing
  local trailing_newlines = 0
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
    trailing_newlines = trailing_newlines + 1
  end

  local result
  if is_literal then
    result = concat(lines, "\n")
  else
    -- Folded: replace single newlines (between non-blank lines) with spaces
    local folded = {}
    for i = 1, #lines do
      if lines[i] == "" then
        folded[#folded + 1] = "\n"
      else
        if i > 1 and lines[i - 1] ~= "" and folded[#folded] then
          -- Check if the previous line started with extra indent
          local prev_has_indent = (lines[i - 1]:sub(1, 1) == " ")
          local curr_has_indent = (lines[i]:sub(1, 1) == " ")
          if prev_has_indent or curr_has_indent then
            folded[#folded + 1] = "\n" .. lines[i]
          else
            folded[#folded] = folded[#folded] .. " " .. lines[i]
          end
        else
          folded[#folded + 1] = lines[i]
        end
      end
    end
    result = concat(folded, "\n")
  end

  -- Apply chomping
  if chomp == "strip" then
    -- no trailing newline
  elseif chomp == "clip" then
    result = result .. "\n"
  elseif chomp == "keep" then
    result = result .. "\n" .. rep("\n", trailing_newlines)
  end

  return result
end

--: (Parser) -> unknown
local function parse_flow_sequence(p)
  p.pos = p.pos + 1 -- skip [
  local result = {}
  skip_spaces(p)

  -- Skip newlines inside flow collections
  while not at_end(p) do
    skip_blank_lines(p)
    skip_spaces(p)
    if peek(p) == 0x5D then -- ]
      p.pos = p.pos + 1
      return result
    end

    local val, err = parse_value(p, 0, true)
    if err then return nil, err end
    result[#result + 1] = val

    skip_spaces(p)
    skip_blank_lines(p)
    skip_spaces(p)
    if peek(p) == 0x2C then -- ,
      p.pos = p.pos + 1
      skip_spaces(p)
    end
  end
  return nil, "unterminated flow sequence"
end

--: (Parser) -> unknown
local function parse_flow_mapping(p)
  p.pos = p.pos + 1 -- skip {
  local result = {}
  skip_spaces(p)

  while not at_end(p) do
    skip_blank_lines(p)
    skip_spaces(p)
    if peek(p) == 0x7D then -- }
      p.pos = p.pos + 1
      return result
    end

    -- Parse key
    local key
    local c = peek(p)
    if c == 0x22 then
      local k, err = parse_double_quoted(p)
      if not k and err then return nil, err end
      key = k
    elseif c == 0x27 then
      local k, err = parse_single_quoted(p)
      if not k and err then return nil, err end
      key = k
    else
      key = parse_plain_scalar(p, true)
      key = resolve_scalar(key)
    end

    skip_spaces(p)
    if peek(p) == 0x3A then -- :
      p.pos = p.pos + 1
      skip_spaces(p)
    else
      return nil, format("expected ':' in flow mapping at position %d", p.pos)
    end

    -- Parse value
    local val
    c = peek(p)
    if c == 0x7D or c == 0x2C then
      -- empty value
      val = nil
    else
      local err
      val, err = parse_value(p, 0, true)
      if err then return nil, err end
    end

    -- Handle merge key
    if key == "<<" then
      if type(val) == "table" then
        -- Check if it's an array of tables or a single mapping
        if val[1] then
          -- Array of mappings - merge in order
          for _, merge_tbl in ipairs(val) do
            if type(merge_tbl) == "table" then
              for mk, mv in pairs(merge_tbl) do
                if result[mk] == nil then
                  result[mk] = mv
                end
              end
            end
          end
        else
          -- Single mapping
          for mk, mv in pairs(val) do
            if result[mk] == nil then
              result[mk] = mv
            end
          end
        end
      end
    else
      result[key] = val
    end

    skip_spaces(p)
    skip_blank_lines(p)
    skip_spaces(p)
    if peek(p) == 0x2C then -- ,
      p.pos = p.pos + 1
      skip_spaces(p)
    end
  end
  return nil, "unterminated flow mapping"
end

--: (Parser, integer) -> unknown
local function parse_block_sequence(p, indent)
  local result = {}
  while not at_end(p) do
    skip_blank_lines(p)
    if at_end(p) then break end

    local cur_indent = get_indent(p)
    if cur_indent ~= indent then
      break
    end

    local saved = p.pos
    p.pos = p.pos + cur_indent
    if peek(p) ~= 0x2D then -- -
      p.pos = saved
      break
    end

    local after_dash = peek_at(p, 1)
    if after_dash and after_dash ~= 0x20 and after_dash ~= 0x0A and after_dash ~= 0x0D then
      -- Not a sequence indicator (e.g., negative number in mapping)
      p.pos = saved
      break
    end

    p.pos = p.pos + 1 -- skip -
    skip_spaces(p)

    local c = peek(p)
    if c == nil or c == 0x0A or c == 0x0D then
      -- value on next line
      if c == 0x0D then
        p.pos = p.pos + 1
        if peek(p) == 0x0A then p.pos = p.pos + 1 end
      elseif c == 0x0A then
        p.pos = p.pos + 1
      end
      skip_blank_lines(p)
      if not at_end(p) then
        local child_indent = get_indent(p)
        if child_indent > indent then
          local val, err = parse_value(p, child_indent, false)
          if err then return nil, err end
          result[#result + 1] = val
        else
          result[#result + 1] = nil -- null implicit
        end
      end
    else
      local val, err = parse_value(p, indent + 1, false)
      if err then return nil, err end
      result[#result + 1] = val
      -- consume trailing newline if present
      if not at_end(p) then
        local cc = peek(p)
        if cc == 0x0A then
          p.pos = p.pos + 1
        elseif cc == 0x0D then
          p.pos = p.pos + 1
          if peek(p) == 0x0A then p.pos = p.pos + 1 end
        end
      end
    end
  end
  return result
end

-- first_at_pos: when true, the first key is already at p.pos (past leading spaces).
-- Used when parsing inline mappings after "- ".
--: (Parser, integer, boolean | nil) -> unknown
local function parse_block_mapping(p, indent, first_at_pos)
  local result = {}
  local first = first_at_pos
  while not at_end(p) do
    local saved, cur_indent
    if first then
      first = false
      saved = p.pos
      cur_indent = 0
    else
      skip_blank_lines(p)
      if at_end(p) then break end

      cur_indent = get_indent(p)
      if cur_indent ~= indent then
        break
      end

      saved = p.pos
      p.pos = p.pos + cur_indent

      -- Check for sequence indicator at this indent
      if peek(p) == 0x2D and (peek_at(p, 1) == 0x20 or peek_at(p, 1) == 0x0A or peek_at(p, 1) == 0x0D or peek_at(p, 1) == nil) then
        p.pos = saved
        break
      end

      -- Check for document markers
      if cur_indent == 0 then
        local line = sub(p.s, p.pos, p.pos + 2)
        if line == "---" or line == "..." then
          local after = peek_at(p, 3)
          if after == nil or after == 0x20 or after == 0x0A or after == 0x0D then
            p.pos = saved
            break
          end
        end
      end
    end

    -- Parse key
    local key
    local c = peek(p)
    if c == 0x22 then
      local k, err = parse_double_quoted(p)
      if not k and err then return nil, err end
      key = k
    elseif c == 0x27 then
      local k, err = parse_single_quoted(p)
      if not k and err then return nil, err end
      key = k
    elseif c == 0x3F and (peek_at(p, 1) == 0x20 or peek_at(p, 1) == 0x0A) then
      -- Explicit key indicator
      p.pos = p.pos + 1
      skip_spaces(p)
      key = parse_plain_scalar(p, false)
      key = resolve_scalar(key)
      expect_newline_or_end(p)
      skip_blank_lines(p)
      -- Now expect the value
      local val_indent = get_indent(p)
      if val_indent >= indent then
        p.pos = p.pos + val_indent
        skip_spaces(p)
      end
    else
      -- Handle anchor on key line
      key = parse_plain_scalar(p, false)
      -- The key includes everything up to ": " so we need to find the colon
      local colon_pos = find(key, ": ", 1, true)
      if colon_pos then
        local real_key = sub(key, 1, colon_pos - 1)
        -- Rewind to after the key
        p.pos = saved + cur_indent + colon_pos + 1
        key = resolve_scalar(real_key)
      else
        key = resolve_scalar(key)
      end
    end

    skip_spaces(p)

    -- Expect colon
    if peek(p) == 0x3A then
      p.pos = p.pos + 1
      local after_colon = peek(p)
      if after_colon and after_colon ~= 0x20 and after_colon ~= 0x09 and after_colon ~= 0x0A and after_colon ~= 0x0D then
        return nil, format("expected space after ':' at position %d", p.pos)
      end
      skip_spaces(p)
    else
      -- Maybe the key: value was already split by parse_plain_scalar
      -- Check if we already consumed past the colon
      -- If not, error
      p.pos = saved
      break
    end

    -- Parse value
    local val
    c = peek(p)
    if c == nil or c == 0x0A or c == 0x0D then
      -- value on next line(s)
      if c == 0x0D then
        p.pos = p.pos + 1
        if peek(p) == 0x0A then p.pos = p.pos + 1 end
      elseif c == 0x0A then
        p.pos = p.pos + 1
      end
      skip_blank_lines(p)
      if not at_end(p) then
        local child_indent = get_indent(p)
        if child_indent > indent then
          local err
          val, err = parse_value(p, child_indent, false)
          if err then return nil, err end
        end
      end
    else
      local err
      val, err = parse_value(p, indent + 1, false)
      if err then return nil, err end
      -- consume trailing newline
      if not at_end(p) then
        local cc = peek(p)
        if cc == 0x0A then
          p.pos = p.pos + 1
        elseif cc == 0x0D then
          p.pos = p.pos + 1
          if peek(p) == 0x0A then p.pos = p.pos + 1 end
        end
      end
    end

    -- Handle merge key
    if key == "<<" then
      if type(val) == "table" then
        if val[1] then
          for _, merge_tbl in ipairs(val) do
            if type(merge_tbl) == "table" then
              for mk, mv in pairs(merge_tbl) do
                if result[mk] == nil then
                  result[mk] = mv
                end
              end
            end
          end
        else
          for mk, mv in pairs(val) do
            if result[mk] == nil then
              result[mk] = mv
            end
          end
        end
      end
    else
      result[key] = val
    end
  end
  return result
end

-- Main value parser
parse_value = function(p, min_indent, in_flow)
  skip_spaces(p)
  if at_end(p) then return nil end

  local c = peek(p)

  -- Anchor
  local anchor_name
  if c == 0x26 then -- &
    p.pos = p.pos + 1
    local anchor_start = p.pos
    while p.pos <= p.len do
      local ac = byte(p.s, p.pos)
      if ac == 0x20 or ac == 0x09 or ac == 0x0A or ac == 0x0D or ac == 0x2C or ac == 0x5D or ac == 0x7D then
        break
      end
      p.pos = p.pos + 1
    end
    anchor_name = sub(p.s, anchor_start, p.pos - 1)
    skip_spaces(p)
    c = peek(p)
  end

  -- Alias
  if c == 0x2A then -- *
    p.pos = p.pos + 1
    local alias_start = p.pos
    while p.pos <= p.len do
      local ac = byte(p.s, p.pos)
      if ac == 0x20 or ac == 0x09 or ac == 0x0A or ac == 0x0D or ac == 0x2C or ac == 0x5D or ac == 0x7D then
        break
      end
      p.pos = p.pos + 1
    end
    local alias_name = sub(p.s, alias_start, p.pos - 1)
    local val = p.anchors[alias_name]
    if val == nil then
      return nil, format("unknown alias '*%s'", alias_name)
    end
    return val
  end

  local val, err

  if c == 0x22 then -- double quote
    val, err = parse_double_quoted(p)
    if err then return nil, err end
  elseif c == 0x27 then -- single quote
    val, err = parse_single_quoted(p)
    if err then return nil, err end
  elseif c == 0x5B then -- [
    val, err = parse_flow_sequence(p)
    if err then return nil, err end
  elseif c == 0x7B then -- {
    val, err = parse_flow_mapping(p)
    if err then return nil, err end
  elseif c == 0x7C or c == 0x3E then -- | or >
    val = parse_block_scalar(p, min_indent)
  elseif c == 0x2D and not in_flow then -- -
    local after_dash = peek_at(p, 1)
    if after_dash == 0x20 or after_dash == 0x0A or after_dash == 0x0D or after_dash == nil then
      -- Block sequence
      -- Rewind to line start only if all chars before us are spaces
      -- (new-line value, not inline after `- ` or `: `)
      local line_start = p.pos
      while line_start > 1 and byte(p.s, line_start - 1) ~= 0x0A do
        line_start = line_start - 1
      end
      local abs_indent = p.pos - line_start
      local all_spaces = true
      for i = line_start, p.pos - 1 do
        if byte(p.s, i) ~= 0x20 then all_spaces = false; break end
      end
      if all_spaces and line_start < p.pos then p.pos = line_start end
      val, err = parse_block_sequence(p, abs_indent)
      if err then return nil, err end
    else
      -- Plain scalar starting with -
      local raw = parse_plain_scalar(p, in_flow)
      val = resolve_scalar(raw)
    end
  else
    -- Could be a block mapping or a plain scalar
    -- Check if this looks like a mapping key (has ": " pattern)
    if not in_flow then
      local line = rest_of_line(p)
      -- Check for mapping pattern: key: value or key:$ (key with newline after colon)
      local is_mapping = false
      -- Walk line to find un-quoted ": " or ":\n" or ":$"
      local i = 1
      local in_dq = false
      local in_sq = false
      while i <= #line do
        local lc = byte(line, i)
        if lc == 0x22 and not in_sq then in_dq = not in_dq
        elseif lc == 0x27 and not in_dq then in_sq = not in_sq
        elseif not in_dq and not in_sq and lc == 0x3A then -- :
          local next_lc = byte(line, i + 1)
          if next_lc == nil or next_lc == 0x20 or next_lc == 0x09 then
            is_mapping = true
            break
          end
        end
        i = i + 1
      end

      if is_mapping then
        local line_start = p.pos
        while line_start > 1 and byte(p.s, line_start - 1) ~= 0x0A do
          line_start = line_start - 1
        end
        local abs_indent = p.pos - line_start
        local all_spaces_m = true
        for i = line_start, p.pos - 1 do
          if byte(p.s, i) ~= 0x20 then all_spaces_m = false; break end
        end
        if all_spaces_m and line_start < p.pos then
          p.pos = line_start
          val, err = parse_block_mapping(p, abs_indent)
        else
          -- p.pos is already past indent (e.g. after "- "); first key is inline
          val, err = parse_block_mapping(p, abs_indent, true)
        end
        if err then return nil, err end
      else
        local raw = parse_plain_scalar(p, in_flow)
        val = resolve_scalar(raw)
      end
    else
      local raw = parse_plain_scalar(p, in_flow)
      val = resolve_scalar(raw)
    end
  end

  if anchor_name then
    p.anchors[anchor_name] = val
  end

  return val
end

--: (Parser) -> unknown
local function parse_document(p)
  skip_blank_lines(p)
  if at_end(p) then return nil end

  -- Skip document start marker
  if p.pos + 2 <= p.len then
    local marker = sub(p.s, p.pos, p.pos + 2)
    if marker == "---" then
      local after = peek_at(p, 3)
      if after == nil or after == 0x20 or after == 0x09 or after == 0x0A or after == 0x0D then
        p.pos = p.pos + 3
        skip_spaces(p)
        local c = peek(p)
        if c == 0x0A then
          p.pos = p.pos + 1
        elseif c == 0x0D then
          p.pos = p.pos + 1
          if peek(p) == 0x0A then p.pos = p.pos + 1 end
        end
      end
    end
  end

  skip_blank_lines(p)
  if at_end(p) then return nil end

  -- Check for document end or another document start
  if p.pos + 2 <= p.len then
    local marker = sub(p.s, p.pos, p.pos + 2)
    if marker == "..." then
      local after = peek_at(p, 3)
      if after == nil or after == 0x20 or after == 0x09 or after == 0x0A or after == 0x0D then
        p.pos = p.pos + 3
        expect_newline_or_end(p)
        return nil
      end
    end
  end

  local indent = get_indent(p)
  local val, err = parse_value(p, indent, false)
  if err then return nil, err end

  -- Skip trailing content
  skip_blank_lines(p)

  -- Check for document end marker
  if p.pos + 2 <= p.len then
    local marker = sub(p.s, p.pos, p.pos + 2)
    if marker == "..." then
      local after = peek_at(p, 3)
      if after == nil or after == 0x20 or after == 0x09 or after == 0x0A or after == 0x0D then
        p.pos = p.pos + 3
        expect_newline_or_end(p)
      end
    end
  end

  return val
end

--: (s: string) -> (unknown, (string | nil))
function M.decode(s)
  if type(s) ~= "string" then
    return nil, "expected string"
  end
  if s == "" then return nil end
  local p = make_parser(s)
  local val, err = parse_document(p)
  if err then return nil, err end
  return val
end

--: (s: string) -> ({ [number]: unknown }, (string | nil))
function M.decode_all(s)
  if type(s) ~= "string" then
    return nil, "expected string"
  end
  if s == "" then return {} end
  local p = make_parser(s)
  local docs = {}
  while not at_end(p) do
    skip_blank_lines(p)
    if at_end(p) then break end
    local val, err = parse_document(p)
    if err then return nil, err end
    docs[#docs + 1] = val
  end
  return docs
end

-- ── Encoder ──────────────────────────────────────────────────────────────────

local encode_value -- forward declaration

local function is_sequence(t)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  if count == 0 then return true end
  for i = 1, count do
    if t[i] == nil then return false end
  end
  return true
end

local function needs_quoting(s)
  if s == "" then return true end
  if s == "~" or s == "null" or s == "Null" or s == "NULL" then return true end
  if s == "true" or s == "True" or s == "TRUE" then return true end
  if s == "false" or s == "False" or s == "FALSE" then return true end
  if s == ".inf" or s == ".Inf" or s == ".INF" then return true end
  if s == "-.inf" or s == "-.Inf" or s == "-.INF" then return true end
  if s == "+.inf" or s == "+.Inf" or s == "+.INF" then return true end
  if s == ".nan" or s == ".NaN" or s == ".NAN" then return true end
  -- Starts with special chars
  local first = byte(s, 1)
  if first == 0x26 or first == 0x2A or first == 0x21 or first == 0x7C or
     first == 0x3E or first == 0x27 or first == 0x22 or first == 0x25 or
     first == 0x40 or first == 0x60 or first == 0x2C or first == 0x5B or
     first == 0x5D or first == 0x7B or first == 0x7D or first == 0x23 or
     first == 0x3F then
    return true
  end
  -- Contains characters that need quoting
  if find(s, "[\n\r\t]") then return true end
  if find(s, ": ") or find(s, " #") then return true end
  if sub(s, -1) == ":" then return true end
  -- Looks like a number
  if tonumber(s) then return true end
  return false
end

local function quote_string(s)
  local result = gsub(s, '[\\"\n\r\t\0]', function(c)
    if c == "\\" then return "\\\\"
    elseif c == '"' then return '\\"'
    elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r"
    elseif c == "\t" then return "\\t"
    elseif c == "\0" then return "\\0"
    end
    return c
  end)
  return '"' .. result .. '"'
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return keys
end

local function encode_flow_value(val)
  local t = type(val)
  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return ".nan" end
    if val == huge then return ".inf" end
    if val == -huge then return "-.inf" end
    if val == math.floor(val) and val > -1e15 and val < 1e15 then
      return format("%d", val)
    end
    return tostring(val)
  elseif t == "string" then
    if needs_quoting(val) then
      return quote_string(val)
    end
    return val
  elseif t == "table" then
    if is_sequence(val) then
      local items = {}
      for i = 1, #val do
        items[i] = encode_flow_value(val[i])
      end
      return "[" .. concat(items, ", ") .. "]"
    else
      local items = {}
      local keys = sorted_keys(val)
      for _, k in ipairs(keys) do
        local ks = tostring(k)
        if needs_quoting(ks) then ks = quote_string(ks) end
        items[#items + 1] = ks .. ": " .. encode_flow_value(val[k])
      end
      return "{" .. concat(items, ", ") .. "}"
    end
  end
  return tostring(val)
end

encode_value = function(val, indent_str, depth, opts)
  local t = type(val)
  local flow_level = opts and opts.flow_level

  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return ".nan" end
    if val == huge then return ".inf" end
    if val == -huge then return "-.inf" end
    if val == math.floor(val) and val > -1e15 and val < 1e15 then
      return format("%d", val)
    end
    return tostring(val)
  elseif t == "string" then
    if needs_quoting(val) then
      return quote_string(val)
    end
    return val
  elseif t == "table" then
    if flow_level and depth >= flow_level then
      return encode_flow_value(val)
    end

    local indent_size = (opts and opts.indent) or 2
    local child_prefix = indent_str .. rep(" ", indent_size)

    if is_sequence(val) then
      if #val == 0 then return "[]" end
      local lines = {}
      for i = 1, #val do
        local v = val[i]
        if type(v) == "table" and not (flow_level and depth + 1 >= flow_level) then
          local child = encode_value(v, child_prefix, depth + 1, opts)
          -- For nested structures, put on next line
          if is_sequence(v) and #v > 0 then
            lines[#lines + 1] = indent_str .. "-\n" .. child
          elseif not is_sequence(v) then
            -- Mapping as sequence item: first key on same line as -
            local first_nl = find(child, "\n", 1, true)
            if first_nl then
              local first_line = sub(child, #child_prefix + 1, first_nl - 1)
              local rest = sub(child, first_nl)
              lines[#lines + 1] = indent_str .. "- " .. first_line .. rest
            else
              lines[#lines + 1] = indent_str .. "- " .. sub(child, #child_prefix + 1)
            end
          else
            lines[#lines + 1] = indent_str .. "- " .. encode_value(v, child_prefix, depth + 1, opts)
          end
        else
          lines[#lines + 1] = indent_str .. "- " .. encode_value(v, child_prefix, depth + 1, opts)
        end
      end
      return concat(lines, "\n")
    else
      local keys = sorted_keys(val)
      if #keys == 0 then return "{}" end
      local lines = {}
      for _, k in ipairs(keys) do
        local ks = tostring(k)
        if needs_quoting(ks) then ks = quote_string(ks) end
        local v = val[k]
        if type(v) == "table" and not (flow_level and depth + 1 >= flow_level) then
          local child = encode_value(v, child_prefix, depth + 1, opts)
          if is_sequence(v) and #v > 0 then
            lines[#lines + 1] = indent_str .. ks .. ":\n" .. child
          elseif not is_sequence(v) then
            local kkeys = sorted_keys(v)
            if #kkeys > 0 then
              lines[#lines + 1] = indent_str .. ks .. ":\n" .. child
            else
              lines[#lines + 1] = indent_str .. ks .. ": {}"
            end
          else
            lines[#lines + 1] = indent_str .. ks .. ": " .. encode_value(v, child_prefix, depth + 1, opts)
          end
        else
          lines[#lines + 1] = indent_str .. ks .. ": " .. encode_value(v, child_prefix, depth + 1, opts)
        end
      end
      return concat(lines, "\n")
    end
  end
  return tostring(val)
end

--: (val: unknown, opts: ({ indent: (number | nil), flow_level: (number | nil) } | nil)) -> string
function M.encode(val, opts)
  return encode_value(val, "", 0, opts) .. "\n"
end

-- ── Aliases (codec convention) ───────────────────────────────────────────────

M.string_to_table = M.decode
M.table_to_string = M.encode

return M
