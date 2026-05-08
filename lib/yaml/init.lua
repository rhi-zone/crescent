if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- YAML 1.2 parser and serializer (pure Lua, subset sufficient for 99% of real files).
-- Supports: scalars, block/flow sequences and mappings, multi-line blocks,
-- comments, anchors/aliases, document markers.
-- Does NOT support: multiple documents, tags (!!str etc), merge keys (<<:).
local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local byte    = string.byte
local sub     = string.sub
local find    = string.find
local format  = string.format
local char    = string.char

local BOOL_TRUE  = { ["true"]=true,  ["yes"]=true,  ["on"]=true  }
local BOOL_FALSE = { ["false"]=true, ["no"]=true,   ["off"]=true }
local NULL_VAL   = { ["null"]=true,  ["~"]=true,    [""]=true    }

--: (s: string) -> boolean
local function is_integer(s)
  return s:match("^%-?[0-9]+$") ~= nil
end

--: (s: string) -> boolean
local function is_float(s)
  if s == ".inf" or s == "-.inf" or s == ".nan" then return true end
  -- Use find to avoid capture-group return-nil issue
  if find(s, "^%-?[0-9]*%.[0-9]+$") then return true end
  if find(s, "^%-?[0-9]*%.[0-9]+[eE][+-]?[0-9]+$") then return true end
  if find(s, "^%-?[0-9]+[eE][+-]?[0-9]+$") then return true end
  return false
end

--: (s: string) -> string | number | boolean | nil
local function parse_scalar(s)
  local lower = s:lower()
  if BOOL_TRUE[lower]  then return true  end
  if BOOL_FALSE[lower] then return false end
  if NULL_VAL[lower]   then return nil   end
  if is_integer(s)     then return tonumber(s) end
  if is_float(s)       then
    if s == ".inf"  then return  math.huge end
    if s == "-.inf" then return -math.huge end
    if s == ".nan"  then return  0/0       end
    return tonumber(s)
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Parser state
-- ---------------------------------------------------------------------------

--:: YState = { s: string, pos: integer, len: integer, line: integer, col: integer, anchors: { [string]: any } }

--: (str: string) -> YState
local function new_state(str)
  return {
    s       = str,
    pos     = 1,
    len     = #str,
    line    = 1,
    col     = 1,
    anchors = {},
  }
end

--: (st: YState) -> integer
local function cur(st)
  local b = byte(st.s, st.pos)
  return b or 0
end

--: (st: YState, offset: integer | nil) -> integer
local function peek(st, offset)
  local b = byte(st.s, st.pos + (offset or 1))
  return b or 0
end

--: (st: YState, n: integer | nil) -> nil
local function advance(st, n)
  n = n or 1
  for _ = 1, n do
    if st.pos > st.len then break end
    if byte(st.s, st.pos) == 10 then -- newline
      st.line = st.line + 1
      st.col  = 1
    else
      st.col = st.col + 1
    end
    st.pos = st.pos + 1
  end
end

--: (st: YState) -> nil
local function skip_spaces(st)
  while st.pos <= st.len do
    local c = cur(st)
    if c == 32 or c == 9 then -- space or tab
      advance(st)
    else
      break
    end
  end
end

--: (st: YState) -> nil
local function skip_to_eol(st)
  while st.pos <= st.len do
    local c = cur(st)
    if c == 10 or c == 13 then break end
    advance(st)
  end
end

--: (st: YState) -> nil
local function skip_comment(st)
  if cur(st) == 35 then -- '#'
    skip_to_eol(st)
  end
end

--: (st: YState) -> nil
local function skip_spaces_and_comments(st)
  skip_spaces(st)
  skip_comment(st)
end

--: (st: YState) -> nil
local function skip_newline(st)
  local c = cur(st)
  if c == 13 then -- CR
    advance(st)
    if cur(st) == 10 then advance(st) end
  elseif c == 10 then -- LF
    advance(st)
  end
end

-- Skip blank/comment lines; leaves st positioned at first non-space char of
-- next content line and returns its 0-based indent.
--: (st: YState) -> integer
local function skip_empty_lines(st)
  while st.pos <= st.len do
    local saved = st.pos
    skip_spaces(st)
    local c = cur(st)
    if c == 35 then -- comment
      skip_to_eol(st)
      skip_newline(st)
    elseif c == 10 or c == 13 then -- blank line
      skip_newline(st)
    else
      -- Non-empty line: st.pos has consumed leading spaces; col reflects that.
      _ = saved -- suppress unused
      return st.col - 1
    end
  end
  return 0
end

-- Return current column (0-based indent level).
--: (st: YState) -> integer
local function current_indent(st)
  return st.col - 1
end

-- ---------------------------------------------------------------------------
-- String parsing helpers
-- ---------------------------------------------------------------------------

local ESC = {
  ["\\"] = "\\", ['"'] = '"',  ["'"] = "'",
  ["n"]  = "\n", ["r"] = "\r", ["t"] = "\t",
  ["b"]  = "\b", ["f"] = "\f", ["a"] = "\a",
  ["v"]  = "\v", ["0"] = "\0", ["e"] = "\27",
  ["/"]  = "/",
}

--: (st: YState) -> string
local function parse_double_quoted(st)
  advance(st) -- skip opening "
  local parts = {} --: { [integer]: string }
  while st.pos <= st.len do
    local c = cur(st)
    if c == 34 then -- closing "
      advance(st)
      break
    elseif c == 92 then -- backslash
      advance(st)
      local ec = cur(st)
      local esc_ch = char(ec)
      local mapped = ESC[esc_ch]
      if mapped then
        parts[#parts+1] = mapped
        advance(st)
      elseif esc_ch == "u" then
        advance(st)
        local hex = sub(st.s, st.pos, st.pos+3)
        advance(st, 4)
        local code = tonumber(hex, 16) or 0
        if code < 0x80 then
          parts[#parts+1] = char(code) or ""
        elseif code < 0x800 then
          parts[#parts+1] = char(0xC0 + math.floor(code/64), 0x80 + (code%64)) or ""
        else
          parts[#parts+1] = char(0xE0 + math.floor(code/4096),
                                 0x80 + math.floor((code%4096)/64),
                                 0x80 + (code%64)) or ""
        end
      elseif esc_ch == "x" then
        advance(st)
        local hex = sub(st.s, st.pos, st.pos+1)
        advance(st, 2)
        parts[#parts+1] = char(tonumber(hex, 16) or 0) or ""
      elseif ec == 10 or ec == 13 then
        skip_newline(st)
        skip_spaces(st)
      else
        parts[#parts+1] = esc_ch
        advance(st)
      end
    elseif c == 10 or c == 13 then
      -- newline in double-quoted: fold to space
      skip_newline(st)
      skip_spaces(st)
      parts[#parts+1] = " "
    else
      parts[#parts+1] = char(c) or ""
      advance(st)
    end
  end
  return table.concat(parts)
end

--: (st: YState) -> string
local function parse_single_quoted(st)
  advance(st) -- skip opening '
  local parts = {} --: { [integer]: string }
  while st.pos <= st.len do
    local c = cur(st)
    if c == 39 then -- single quote
      advance(st)
      if cur(st) == 39 then -- escaped '' => literal '
        parts[#parts+1] = "'"
        advance(st)
      else
        break
      end
    elseif c == 10 or c == 13 then
      skip_newline(st)
      skip_spaces(st)
      parts[#parts+1] = " "
    else
      parts[#parts+1] = char(c) or ""
      advance(st)
    end
  end
  return table.concat(parts)
end

-- Returns true if the line starting at st.pos (already past leading spaces)
-- begins a new block item (sequence dash or mapping key).
--: (st: YState) -> boolean
local function is_block_line(st)
  local c = cur(st)
  if c == nil then return true end
  -- "- " or "-\n" or "-\r" = sequence item
  if c == 45 then
    local n = peek(st)
    if n == 32 or n == 10 or n == 13 or n == nil then return true end
  end
  -- check for mapping key: scan for ': ' or ':\n' on this line
  local pos2 = st.pos
  while pos2 <= st.len do
    local b = byte(st.s, pos2)
    if b == 10 or b == 13 then break end
    if b == 58 then -- ':'
      local nb = byte(st.s, pos2 + 1)
      if nb == 32 or nb == 10 or nb == 13 or nb == nil then return true end
    end
    pos2 = pos2 + 1
  end
  return false
end

-- Parse a plain (unquoted) scalar stopping at flow indicators, newlines, ': ', ' #'
--: (st: YState, in_flow: boolean) -> string
local function parse_plain_scalar(st, in_flow)
  local parts = {} --: { [integer]: string }
  local line_buf = {} --: { [integer]: string }

  local function flush_line()
    local s = table.concat(line_buf)
    -- rtrim
    s = s:match("^(.-)%s*$") or s
    if s ~= "" then
      if #parts > 0 then parts[#parts+1] = " " end
      parts[#parts+1] = s
    end
    line_buf = {}
  end

  while st.pos <= st.len do
    local c = cur(st)
    -- stop at flow indicators when in flow context
    if in_flow and (c == 44 or c == 93 or c == 125) then -- , ] }
      break
    end
    -- stop at newline
    if c == 10 or c == 13 then
      flush_line()
      -- save state in case we need to rewind
      local saved_pos  = st.pos
      local saved_line = st.line
      local saved_col  = st.col
      skip_newline(st)
      -- skip empty/comment lines to see what comes next
      skip_empty_lines(st)
      if st.pos > st.len then break end
      -- if next content is a block construct, stop scalar here
      if is_block_line(st) then
        st.pos  = saved_pos
        st.line = saved_line
        st.col  = saved_col
        break
      end
      -- otherwise fold: continue reading the next line's content
      -- (no chars added yet; next loop iteration reads the continuation)
    -- stop at inline comment
    elseif c == 35 and (st.col == 1 or byte(st.s, st.pos-1) == 32) then
      break
    -- stop at ': ' or ':' at eol (mapping value indicator)
    elseif c == 58 then -- ':'
      local nc = peek(st)
      if nc == 32 or nc == 10 or nc == 13 or nc == nil then
        break
      end
      line_buf[#line_buf+1] = char(c) or ""
      advance(st)
    else
      line_buf[#line_buf+1] = char(c) or ""
      advance(st)
    end
  end
  flush_line()
  return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Block scalar (literal | and folded >)
-- ---------------------------------------------------------------------------

--: (st: YState, indent: integer) -> string
local function parse_block_scalar(st, indent)
  local c = cur(st)
  local is_literal = (c == 124) -- '|'
  advance(st) -- skip | or >

  -- parse optional chomp indicator and explicit indent
  local chomp = "clip" -- default: clip (keep single trailing newline)
  local explicit_indent = nil
  while st.pos <= st.len do
    local cc = cur(st)
    if cc == 43 then chomp = "keep"; advance(st)     -- '+'
    elseif cc == 45 then chomp = "strip"; advance(st) -- '-'
    elseif cc >= 49 and cc <= 57 then                  -- '1'-'9'
      explicit_indent = cc - 48
      advance(st)
    elseif cc == 32 or cc == 9 then
      advance(st)
    else
      break
    end
  end
  skip_comment(st)
  skip_newline(st)

  -- determine block indentation from first non-empty line
  local block_indent = explicit_indent
  if not block_indent then
    local saved_pos  = st.pos
    local saved_line = st.line
    local saved_col  = st.col
    while st.pos <= st.len do
      local cc = cur(st)
      if cc == 10 or cc == 13 then
        skip_newline(st)
      elseif cc == 32 or cc == 9 then
        advance(st)
      else
        block_indent = st.col - 1
        break
      end
    end
    st.pos = saved_pos; st.line = saved_line; st.col = saved_col
    if not block_indent then block_indent = indent + 2 end
  end
  local block_indent_ = block_indent --[[:! integer]]

  local lines = {}
  local trailing_empty = 0

  while st.pos <= st.len do
    -- count leading spaces
    local line_start = st.pos
    local spaces = 0
    while cur(st) == 32 do advance(st); spaces = spaces + 1 end
    local cc = cur(st)

    if cc == 10 or cc == 13 then
      -- empty or all-spaces line
      lines[#lines+1] = false -- marker for empty line
      trailing_empty = trailing_empty + 1
      skip_newline(st)
    elseif cc == nil then
      -- EOF treated as empty line
      lines[#lines+1] = false
      trailing_empty = trailing_empty + 1
      break
    elseif spaces < block_indent_ then
      -- dedented: end of block scalar; restore to line start
      st.pos = line_start
      -- restore col: line_start is beginning of this line (col=1)
      st.col = 1
      break
    else
      -- content line
      trailing_empty = 0
      -- backfill false → "" for empty lines
      for i = 1, #lines do
        if lines[i] == false then lines[i] = "" end
      end
      local extra_indent = string.rep(" ", spaces - block_indent_)
      local rest_start = st.pos
      skip_to_eol(st)
      local rest = sub(st.s, rest_start, st.pos - 1)
      lines[#lines+1] = extra_indent .. rest
      skip_newline(st)
    end
  end

  -- remove trailing empty lines based on chomp
  if chomp == "strip" then
    while #lines > 0 and (lines[#lines] == false or lines[#lines] == "") do
      lines[#lines] = nil
    end
  elseif chomp == "clip" then
    while trailing_empty > 1 do
      lines[#lines] = nil
      trailing_empty = trailing_empty - 1
    end
  end
  -- chomp == "keep": keep all trailing empties

  -- build result
  if is_literal then
    local result_parts = {}
    for _, line in ipairs(lines) do
      result_parts[#result_parts+1] = (line == false) and "" or line
    end
    local result = table.concat(result_parts, "\n")
    if chomp ~= "strip" then result = result .. "\n" end
    return result
  else
    -- folded: join within paragraph, separate paragraphs with newline
    local result_parts = {}
    local para = {}
    for _, line in ipairs(lines) do
      if line == false or line == "" then
        if #para > 0 then
          result_parts[#result_parts+1] = table.concat(para, " ")
          para = {}
        end
        result_parts[#result_parts+1] = ""
      else
        -- line with extra indent keeps own newline
        if line:sub(1,1) == " " then
          if #para > 0 then
            result_parts[#result_parts+1] = table.concat(para, " ")
            para = {}
          end
          result_parts[#result_parts+1] = line
        else
          para[#para+1] = line
        end
      end
    end
    if #para > 0 then
      result_parts[#result_parts+1] = table.concat(para, " ")
    end
    local result = table.concat(result_parts, "\n")
    if chomp ~= "strip" then result = result .. "\n" end
    return result
  end
end

-- ---------------------------------------------------------------------------
-- Forward declarations
-- ---------------------------------------------------------------------------

--: (st: YState, min_indent: integer, in_flow: boolean) -> unknown
local parse_value = function(_st, _min_indent, _in_flow) return nil end
--: (st: YState, seq_indent: integer) -> { [integer]: unknown }
local parse_block_sequence = function(_st, _seq_indent) return {} end
--: (st: YState, map_indent: integer) -> { [string]: unknown }
local parse_block_mapping = function(_st, _map_indent) return {} end
--: (st: YState) -> { [integer]: unknown }
local parse_flow_sequence = function(_st) return {} end
--: (st: YState) -> { [string]: unknown }
local parse_flow_mapping = function(_st) return {} end

-- ---------------------------------------------------------------------------
-- Flow sequences and mappings
-- ---------------------------------------------------------------------------

--: (st: YState) -> { [integer]: unknown }
parse_flow_sequence = function(st)
  advance(st) -- skip '['
  local result = {}
  skip_spaces_and_comments(st)
  if cur(st) == 93 then -- ']'
    advance(st)
    return result
  end
  while st.pos <= st.len do
    skip_spaces_and_comments(st)
    local c2 = cur(st)
    if c2 == 93 or c2 == nil then break end
    local val = parse_value(st, 0, true)
    result[#result+1] = val
    skip_spaces_and_comments(st)
    if cur(st) == 44 then     -- ','
      advance(st)
    elseif cur(st) == 93 then -- ']'
      break
    end
  end
  if cur(st) == 93 then advance(st) end
  return result
end

--: (st: YState) -> { [string]: unknown }
parse_flow_mapping = function(st)
  advance(st) -- skip '{'
  local result = {}
  skip_spaces_and_comments(st)
  if cur(st) == 125 then -- '}'
    advance(st)
    return result
  end
  while st.pos <= st.len do
    skip_spaces_and_comments(st)
    local c2 = cur(st)
    if c2 == 125 or c2 == nil then break end
    -- parse key
    local key
    if c2 == 34 then
      key = parse_double_quoted(st)
    elseif c2 == 39 then
      key = parse_single_quoted(st)
    else
      key = parse_plain_scalar(st, true)
    end
    skip_spaces_and_comments(st)
    if cur(st) == 58 then advance(st) end -- ':'
    skip_spaces_and_comments(st)
    local val = parse_value(st, 0, true)
    result[key] = val
    skip_spaces_and_comments(st)
    if cur(st) == 44 then      -- ','
      advance(st)
    elseif cur(st) == 125 then -- '}'
      break
    end
  end
  if cur(st) == 125 then advance(st) end
  return result
end

-- ---------------------------------------------------------------------------
-- Anchor / alias
-- ---------------------------------------------------------------------------

--: (st: YState) -> string
local function parse_anchor_name(st)
  local start = st.pos
  while st.pos <= st.len do
    local c = cur(st)
    if c == 32 or c == 9 or c == 10 or c == 13 or
       c == 44 or c == 93 or c == 125 then
      break
    end
    advance(st)
  end
  return sub(st.s, start, st.pos - 1)
end

-- ---------------------------------------------------------------------------
-- Main value parser
-- ---------------------------------------------------------------------------

--: (st: YState, min_indent: integer, in_flow: boolean) -> unknown
parse_value = function(st, min_indent, in_flow)
  skip_spaces_and_comments(st)
  if st.pos > st.len then return nil end

  local c = cur(st)

  -- anchor
  local anchor_name = nil
  if c == 38 then -- '&'
    advance(st)
    anchor_name = parse_anchor_name(st)
    skip_spaces(st)
    c = cur(st) --[[:! integer]]
    -- If anchor is alone on its line, the value follows on the next line(s).
    -- Skip the newline and any empty lines, then re-parse from that indent.
    if c == 10 or c == 13 or c == 35 then
      skip_comment(st)
      skip_newline(st)
      local val_indent = skip_empty_lines(st)
      if st.pos <= st.len then
        local v2 = parse_value(st, val_indent, in_flow)
        if anchor_name then st.anchors[anchor_name] = v2 end
        return v2
      end
      if anchor_name then st.anchors[anchor_name] = nil end
      return nil
    end
  end

  -- alias
  if c == 42 then -- '*'
    advance(st)
    local alias = parse_anchor_name(st)
    return st.anchors[alias]
  end

  local val

  if c == 123 then -- '{'
    val = parse_flow_mapping(st)
  elseif c == 91 then -- '['
    val = parse_flow_sequence(st)
  elseif c == 34 then -- '"'
    val = parse_double_quoted(st)
  elseif c == 39 then -- "'"
    val = parse_single_quoted(st)
  elseif c == 124 or c == 62 then -- '|' or '>'
    val = parse_block_scalar(st, min_indent)
  elseif c == 45 and (peek(st) == 32 or peek(st) == 10 or peek(st) == 13) then
    val = parse_block_sequence(st, current_indent(st))
  elseif c == 10 or c == 13 then
    val = nil
  else
    -- Could be a plain scalar or the first key of a block mapping.
    -- Peek ahead for ': ' on this line to decide.
    local saved_pos  = st.pos
    local saved_line = st.line
    local saved_col  = st.col

    local scalar = parse_plain_scalar(st, in_flow)
    skip_spaces(st)

    if not in_flow and cur(st) == 58 then -- ':'
      local nc = peek(st)
      if nc == 32 or nc == 10 or nc == 13 or nc == nil then
        -- This plain scalar was a mapping key — restart as block mapping.
        st.pos  = saved_pos
        st.line = saved_line
        st.col  = saved_col
        val = parse_block_mapping(st, current_indent(st))
      else
        val = parse_scalar(scalar)
      end
    else
      val = parse_scalar(scalar)
    end
  end

  if anchor_name then
    st.anchors[anchor_name] = val
  end

  return val
end

-- ---------------------------------------------------------------------------
-- Block collections
-- ---------------------------------------------------------------------------

--: (st: YState, seq_indent: integer) -> { [integer]: unknown }
parse_block_sequence = function(st, seq_indent)
  local result = {}
  local n = 0  -- explicit counter so nil items occupy correct slots
  while st.pos <= st.len do
    local saved     = st.pos
    local saved_col = st.col
    skip_spaces(st)
    local c = cur(st)

    if c == 35 then -- comment line
      skip_to_eol(st)
      skip_newline(st)
    elseif c == 10 or c == 13 then -- blank line
      skip_newline(st)
    elseif c == 45 and (peek(st) == 32 or peek(st) == 10 or peek(st) == 13) then
      local this_indent = st.col - 1
      if this_indent < seq_indent or this_indent > seq_indent then
        st.pos = saved; st.col = saved_col; break
      end
      advance(st) -- skip '-'
      if cur(st) == 32 then advance(st) end  -- optional space

      skip_spaces(st)
      local nc = cur(st)

      n = n + 1
      if nc == 10 or nc == 13 then
        -- value on next line
        skip_newline(st)
        local item_indent = skip_empty_lines(st)
        if st.pos <= st.len then
          result[n] = parse_value(st, item_indent, false)
        end
        -- else result[n] stays nil (slot exists conceptually)
      else
        result[n] = parse_value(st, seq_indent + 2, false)
        skip_spaces_and_comments(st)
        if cur(st) == 10 or cur(st) == 13 then skip_newline(st) end
      end
    else
      st.pos = saved; st.col = saved_col; break
    end
  end
  return result
end

--: (st: YState, map_indent: integer) -> { [string]: unknown }
parse_block_mapping = function(st, map_indent)
  local result = {}

  while st.pos <= st.len do
    local saved     = st.pos
    local saved_col = st.col
    skip_spaces(st)
    local c = cur(st)

    if c == 35 then -- comment line
      skip_to_eol(st)
      skip_newline(st)
    elseif c == 10 or c == 13 then -- blank line
      skip_newline(st)
    elseif c == 46 and peek(st) == 46 and peek(st,2) == 46 then -- '...'
      st.pos = saved; st.col = saved_col
      break
    elseif c == 45 and peek(st) == 45 and peek(st,2) == 45 then -- '---'
      st.pos = saved; st.col = saved_col
      break
    else
      local this_indent = st.col - 1
      if this_indent < map_indent then
        st.pos = saved; st.col = saved_col
        break
      end
      if this_indent > map_indent then
        st.pos = saved; st.col = saved_col
        break
      end

      -- parse key
      local key
      if c == 34 then
        key = parse_double_quoted(st)
      elseif c == 39 then
        key = parse_single_quoted(st)
      elseif c == 63 then -- explicit '?' key
        advance(st)
        skip_spaces(st)
        key = parse_plain_scalar(st, false)
      else
        key = parse_plain_scalar(st, false)
      end

      skip_spaces(st)

      if cur(st) ~= 58 then
        -- not a mapping key line — bail
        st.pos = saved; st.col = saved_col
        break
      end
      advance(st) -- skip ':'

      local val
      skip_spaces(st)
      local nc = cur(st)

      if nc == 10 or nc == 13 or nc == 35 then
        -- value on next line
        skip_comment(st)
        skip_newline(st)
        local val_indent = skip_empty_lines(st)
        if st.pos > st.len then
          val = nil
        elseif val_indent <= map_indent then
          val = nil
        else
          val = parse_value(st, val_indent, false)
        end
      else
        val = parse_value(st, map_indent + 1, false)
        skip_spaces_and_comments(st)
        if cur(st) == 10 or cur(st) == 13 then skip_newline(st) end
      end

      result[key] = val
    end
  end

  return result
end

-- ---------------------------------------------------------------------------
-- Top-level parse
-- ---------------------------------------------------------------------------

--: (st: YState) -> unknown
local function parse_document(st)
  -- skip leading directives, comments, blank lines
  while st.pos <= st.len do
    skip_spaces(st)
    local c = cur(st)
    if c == 35 then -- comment
      skip_to_eol(st)
      skip_newline(st)
    elseif c == 10 or c == 13 then -- blank line
      skip_newline(st)
    elseif c == 37 then -- '%' directive, skip line
      skip_to_eol(st)
      skip_newline(st)
    elseif c == 45 and peek(st) == 45 and peek(st,2) == 45 then -- '---'
      advance(st, 3)
      skip_newline(st)
      break
    else
      break
    end
  end

  if st.pos > st.len then return nil end

  local c     = cur(st)
  local indent = current_indent(st)

  -- sequence
  if c == 45 and (peek(st) == 32 or peek(st) == 10 or peek(st) == 13) then
    return parse_block_sequence(st, indent)
  end

  -- flow collections — dispatch directly to parse_value
  if c == 123 or c == 91 then -- '{' or '['
    return parse_value(st, indent, false)
  end

  -- block mapping: peek at first line for "key: " or "key:\n"
  -- includes quoted-key mappings like '"key with spaces": value'
  local line_end = find(st.s, "\n", st.pos, true) or st.len + 1
  local first_line = sub(st.s, st.pos, line_end - 1)
  -- plain key
  if first_line:match("^[^#\n{%[|>\"']+: ") or
     first_line:match("^[^#\n{%[|>\"']+:$") then
    return parse_block_mapping(st, indent)
  end
  -- double-quoted key: "..." : value
  if first_line:match('^"[^"]*":%s') or first_line:match('^"[^"]*":$') then
    return parse_block_mapping(st, indent)
  end
  -- single-quoted key: '...' : value
  if first_line:match("^'[^']*':%s") or first_line:match("^'[^']*':$") then
    return parse_block_mapping(st, indent)
  end

  -- single value
  return parse_value(st, indent, false)
end

-- ---------------------------------------------------------------------------
-- Public decode
-- ---------------------------------------------------------------------------

function M.decode(str)
  if type(str) ~= "string" then
    return nil, "yaml.decode: expected string, got " .. type(str)
  end
  local ok, result = pcall(function()
    local st = new_state(str)
    return parse_document(st)
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

M.parse = M.decode

-- ---------------------------------------------------------------------------
-- Serializer
-- ---------------------------------------------------------------------------

-- Returns true if this string must be quoted when used as a plain scalar.
--: (s: string) -> boolean
local function needs_quoting(s)
  if s == "" then return true end
  local lower = s:lower()
  if BOOL_TRUE[lower] or BOOL_FALSE[lower] or NULL_VAL[lower] then return true end
  if is_integer(s) or is_float(s) then return true end
  -- leading chars that have special YAML meaning
  if s:match("^[%-%:%>%|%#%&%*%!%,%{%}%[%]%@%`]") then return true end
  -- embedded ': ' or ' #' require quoting
  if s:find(": ", 1, true) or s:find(" #", 1, true) then return true end
  -- newlines always require quoting (or block scalar, but we keep it simple)
  if s:find("\n", 1, true) or s:find("\r", 1, true) then return true end
  -- control characters
  for i = 1, #s do
    local b = byte(s, i) or 0
    if b < 32 or b == 127 then return true end
  end
  return false
end

--: (s: string) -> string
local function quote_string(s)
  local escaped = s
    :gsub("\\", "\\\\")
    :gsub('"',  '\\"')
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
  -- replace remaining control chars
  escaped = escaped:gsub(".", function(ch)
    local b = byte(ch --[[:! string]], 1) or 0
    if b < 32 or b == 127 then
      return format("\\x%02x", b)
    end
    return ch
  end)
  return '"' .. escaped .. '"'
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  local count = 0
  for k, _ in pairs(t --[[:! { [any]: unknown }]]) do
    count = count + 1
    local kn = tonumber(k --[[: any]]) or -1
    if type(k) ~= "number" or kn ~= math.floor(kn) or kn < 1 then return false end
    if kn > n then n = kn --[[:! integer]] end
  end
  return n == count
end

--: (val: unknown, indent_level: integer, indent_str: string, sort_keys: boolean) -> string
local function encode_value(val, indent_level, indent_str, sort_keys)
  local t = type(val)

  if val == nil then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    local valn = val --[[:! number]]
    if valn ~= valn          then return ".nan"  end
    if valn ==  math.huge   then return ".inf"  end
    if valn == -math.huge   then return "-.inf" end
    if valn == math.floor(valn) and math.abs(valn) < 1e15 then
      return format("%d", valn)
    end
    return format("%g", valn)
  elseif t == "string" then
    local val_ = val --[[:! string]]
    if needs_quoting(val_) then
      return quote_string(val_)
    end
    return val_
  elseif t == "table" then
    local indent       = string.rep(indent_str, indent_level)
    local child_indent = string.rep(indent_str, indent_level + 1)
    local val_t = val --[[:! { [string]: unknown }]]

    if next(val_t) == nil then
      return "{}"
    end

    if is_array(val_t) then
      local n = #val_t
      if n == 0 then return "[]" end
      local parts = {} --: { [integer]: string }
      for i = 1, n do
        local item = encode_value(val_t[i], indent_level + 1, indent_str, sort_keys)
        if item:find("\n", 1, true) then
          -- multi-line: put value indented on next line after '-'
          parts[#parts+1] = "-\n" .. child_indent .. item
        else
          parts[#parts+1] = "- " .. item
        end
      end
      return table.concat(parts, "\n" .. indent)
    else
      -- mapping
      local keys = {} --: { [integer]: unknown }
      for k in pairs(val_t) do keys[#keys+1] = k end
      if sort_keys then
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      end
      local parts = {} --: { [integer]: string }
      for _, k in ipairs(keys) do
        local ks    = tostring(k)
        local kstr  = needs_quoting(ks) and quote_string(ks) or ks
        local v_val = val_t[k]
        local venc  = encode_value(v_val, indent_level + 1, indent_str, sort_keys)
        -- nested tables always go on the next line (block style)
        if type(v_val) == "table" and next(v_val --[[:! { [string]: unknown }]]) ~= nil then
          parts[#parts+1] = kstr .. ":\n" .. child_indent .. venc
        elseif venc:find("\n", 1, true) then
          parts[#parts+1] = kstr .. ":\n" .. child_indent .. venc
        else
          parts[#parts+1] = kstr .. ": " .. venc
        end
      end
      return table.concat(parts, "\n" .. indent)
    end
  else
    return quote_string(tostring(val))
  end
end

function M.encode(val, opts)
  local opts_ = (opts or {}) --[[:! { indent: integer | nil, sort_keys: boolean | nil }]]
  local indent_size = opts_.indent    or 2
  local sort_keys   = opts_.sort_keys or false
  local indent_str  = string.rep(" ", indent_size)

  local ok, result = pcall(function()
    return encode_value(val, 0, indent_str, sort_keys)
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

M.stringify = M.encode

return M
