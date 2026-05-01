-- lib/graphql_parser/init.lua
-- GraphQL query and SDL parser with AST printer.
-- Parses GraphQL documents (queries, mutations, subscriptions, fragments,
-- schema definitions) into an AST table, and prints AST back to normalized text.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, sub, find, match, format = string.byte, string.sub, string.find, string.match, string.format
local concat, insert = table.concat, table.insert
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Lexer
-- ---------------------------------------------------------------------------

--:: Lexer = { src: string, pos: integer, line: integer, col: integer, len: integer }

--: (string) -> Lexer
local function new_lexer(src)
  return { src = src, pos = 1, line = 1, col = 1, len = #src }
end

--: (Lexer, string) -> (nil, string)
local function lex_err(lex, msg)
  return nil, format("GraphQL parse error at line %d col %d: %s", lex.line, lex.col, msg)
end

-- Advance position by n characters, tracking line/col
--: (Lexer, integer) -> ()
local function advance(lex, n)
  for _ = 1, n do
    if lex.pos > lex.len then break end
    if byte(lex.src, lex.pos) == 10 then -- newline
      lex.line = lex.line + 1
      lex.col = 1
    else
      lex.col = lex.col + 1
    end
    lex.pos = lex.pos + 1
  end
end

-- Skip whitespace, commas (insignificant in GraphQL), and comments
--: (Lexer) -> unknown
local function skip_ignored(lex)
  while lex.pos <= lex.len do
    local c = byte(lex.src, lex.pos)
    -- whitespace: space, tab, CR, LF, BOM, comma
    if c == 32 or c == 9 or c == 13 or c == 10 or c == 0xFEFF or c == 44 then
      advance(lex, 1)
    elseif c == 35 then -- '#' comment: skip to end of line
      while lex.pos <= lex.len and byte(lex.src, lex.pos) ~= 10 do
        lex.pos = lex.pos + 1
      end
    else
      break
    end
  end
end

-- Peek at current character without advancing
--: (Lexer) -> unknown
local function peek(lex)
  if lex.pos > lex.len then return nil end
  return byte(lex.src, lex.pos)
end

-- Read a name token (letters, digits, underscore; must start with letter or _)
--: (Lexer) -> unknown
local function read_name(lex)
  local start = lex.pos
  local c = byte(lex.src, start)
  if not c then return nil end
  if not (c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)) then
    return nil
  end
  local p = start + 1
  while p <= lex.len do
    c = byte(lex.src, p)
    if c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) then
      p = p + 1
    else
      break
    end
  end
  local name = sub(lex.src, start, p - 1)
  -- update col/line (names don't contain newlines)
  lex.col = lex.col + (p - start)
  lex.pos = p
  return name
end

-- Read a number token; returns kind ("IntValue"|"FloatValue") and string value
--: (Lexer) -> unknown
local function read_number(lex)
  local start = lex.pos
  local is_float = false
  local c = byte(lex.src, lex.pos)
  -- optional minus
  if c == 45 then lex.pos = lex.pos + 1 end
  -- integer part
  c = byte(lex.src, lex.pos)
  if c == 48 then -- leading zero: must be followed by non-digit
    lex.pos = lex.pos + 1
  elseif c and c >= 49 and c <= 57 then
    lex.pos = lex.pos + 1
    while lex.pos <= lex.len do
      c = byte(lex.src, lex.pos)
      if c >= 48 and c <= 57 then lex.pos = lex.pos + 1 else break end
    end
  else
    lex.pos = start
    return nil
  end
  -- fractional part
  c = byte(lex.src, lex.pos)
  if c == 46 then -- '.'
    is_float = true
    lex.pos = lex.pos + 1
    while lex.pos <= lex.len do
      c = byte(lex.src, lex.pos)
      if c >= 48 and c <= 57 then lex.pos = lex.pos + 1 else break end
    end
  end
  -- exponent
  c = byte(lex.src, lex.pos)
  if c == 101 or c == 69 then -- 'e' or 'E'
    is_float = true
    lex.pos = lex.pos + 1
    c = byte(lex.src, lex.pos)
    if c == 43 or c == 45 then lex.pos = lex.pos + 1 end
    while lex.pos <= lex.len do
      c = byte(lex.src, lex.pos)
      if c >= 48 and c <= 57 then lex.pos = lex.pos + 1 else break end
    end
  end
  local val = sub(lex.src, start, lex.pos - 1)
  lex.col = lex.col + (lex.pos - start)
  if is_float then
    return "FloatValue", val
  else
    return "IntValue", val
  end
end

-- Decode \uXXXX escape to UTF-8
local function unicode_escape(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(
      0xC0 + floor(code / 64),
      0x80 + (code % 64)
    )
  else
    return string.char(
      0xE0 + floor(code / 4096),
      0x80 + floor((code % 4096) / 64),
      0x80 + (code % 64)
    )
  end
end

-- Read a regular string (single-line, double-quoted)
-- Returns the string value (unescaped) or nil+err
--: (Lexer) -> unknown
local function read_string(lex)
  -- pos is at opening '"'
  lex.pos = lex.pos + 1 -- skip '"'
  lex.col = lex.col + 1
  local parts = {}
  while lex.pos <= lex.len do
    local c = byte(lex.src, lex.pos)
    if c == 34 then -- '"'
      lex.pos = lex.pos + 1
      lex.col = lex.col + 1
      return concat(parts)
    elseif c == 10 or c == 13 then
      return nil, "unterminated string (newline)"
    elseif c == 92 then -- '\'
      lex.pos = lex.pos + 1
      lex.col = lex.col + 1
      local esc = byte(lex.src, lex.pos)
      if esc == 34 then insert(parts, '"')
      elseif esc == 92 then insert(parts, '\\')
      elseif esc == 47 then insert(parts, '/')
      elseif esc == 98 then insert(parts, '\b')
      elseif esc == 102 then insert(parts, '\f')
      elseif esc == 110 then insert(parts, '\n')
      elseif esc == 114 then insert(parts, '\r')
      elseif esc == 116 then insert(parts, '\t')
      elseif esc == 117 then -- \uXXXX
        local hex = sub(lex.src, lex.pos + 1, lex.pos + 4)
        if #hex < 4 then return nil, "invalid unicode escape" end
        local code = tonumber(hex, 16)
        if not code then return nil, "invalid unicode escape" end
        insert(parts, unicode_escape(code))
        lex.pos = lex.pos + 4
        lex.col = lex.col + 4
      else
        return nil, "invalid escape character"
      end
      lex.pos = lex.pos + 1
      lex.col = lex.col + 1
    else
      insert(parts, string.char(c))
      if c == 10 then
        lex.line = lex.line + 1
        lex.col = 1
      else
        lex.col = lex.col + 1
      end
      lex.pos = lex.pos + 1
    end
  end
  return nil, "unterminated string"
end

-- Strip block-string indentation per GraphQL spec
--: (string) -> string
local function strip_block_string(raw)
  -- Split into lines
  --: { [integer]: string }
  local lines = {}
  local s = 1
  while true do
    local nl = find(raw, "\n", s, true)
    if nl then
      insert(lines, sub(raw, s, nl - 1))
      s = nl + 1
    else
      insert(lines, sub(raw, s))
      break
    end
  end
  -- Find common indent (skip first line and blank lines)
  local common = nil
  for i = 2, #lines do
    local line = lines[i]
    local indent = 0
    for j = 1, #line do
      local c = byte(line, j)
      if c == 32 or c == 9 then
        indent = indent + 1
      else
        break
      end
    end
    if indent < #line then -- non-blank
      if common == nil or indent < common then
        common = indent
      end
    end
  end
  common = common or 0
  -- Strip common indent from all lines except first
  for i = 2, #lines do
    if #lines[i] >= common then
      lines[i] = sub(lines[i], common + 1)
    end
  end
  -- Remove leading blank lines
  while #lines > 0 and match(lines[1], "^%s*$") do
    table.remove(lines, 1)
  end
  -- Remove trailing blank lines
  while #lines > 0 and match(lines[#lines], "^%s*$") do
    table.remove(lines)
  end
  return concat(lines, "\n")
end

-- Read a block string (triple-quoted """...""")
-- Returns the string value after indentation stripping, or nil+err
--: (Lexer) -> unknown
local function read_block_string(lex)
  -- pos is at first '"' of """
  lex.pos = lex.pos + 3 -- skip """
  lex.col = lex.col + 3
  local start = lex.pos
  -- Find closing """
  while lex.pos <= lex.len - 2 do
    if byte(lex.src, lex.pos) == 34
      and byte(lex.src, lex.pos + 1) == 34
      and byte(lex.src, lex.pos + 2) == 34 then
      -- Check for escaped \"""
      local raw = sub(lex.src, start, lex.pos - 1)
      -- Update line/col tracking through block content
      for i = start, lex.pos + 2 do
        if byte(lex.src, i) == 10 then
          lex.line = lex.line + 1
          lex.col = 1
        else
          lex.col = lex.col + 1
        end
      end
      lex.pos = lex.pos + 3
      -- Unescape \""" → """
      raw = raw:gsub('\\"""', '"""')
      return strip_block_string(raw)
    elseif byte(lex.src, lex.pos) == 10 then
      lex.pos = lex.pos + 1
    else
      lex.pos = lex.pos + 1
    end
  end
  return nil, "unterminated block string"
end

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

local parse_value  -- forward declaration
local parse_type   -- forward declaration

--: (Lexer) -> unknown
local function expect_name(lex)
  skip_ignored(lex)
  local name = read_name(lex)
  if not name then
    return nil, format("expected name at line %d col %d", lex.line, lex.col)
  end
  return { kind = "Name", value = name }
end

--: (Lexer, string) -> unknown
local function expect_char(lex, ch)
  skip_ignored(lex)
  if peek(lex) ~= byte(ch) then
    return false, format("expected '%s' at line %d col %d, got '%s'",
      ch, lex.line, lex.col,
      lex.pos <= lex.len and string.char(byte(lex.src, lex.pos)) or "EOF")
  end
  advance(lex, 1)
  return true
end

--: (Lexer, string) -> boolean
local function optional_char(lex, ch)
  skip_ignored(lex)
  if peek(lex) == byte(ch) then
    advance(lex, 1)
    return true
  end
  return false
end

--: (Lexer) -> unknown
local function parse_arguments(lex)
  skip_ignored(lex)
  if peek(lex) ~= byte("(") then return {} end
  advance(lex, 1) -- skip '('
  local args = {}
  while true do
    skip_ignored(lex)
    if peek(lex) == byte(")") then advance(lex, 1); break end
    if lex.pos > lex.len then
      return nil, "unterminated argument list"
    end
    local name, err = expect_name(lex)
    if not name then return nil, err end
    local ok
    ok, err = expect_char(lex, ":")
    if not ok then return nil, err end
    local val
    val, err = parse_value(lex)
    if not val then return nil, err end
    insert(args, { kind = "Argument", name = name, value = val })
  end
  return args
end

--: (Lexer) -> unknown
local function parse_directives(lex)
  local directives = {}
  while true do
    skip_ignored(lex)
    if peek(lex) ~= byte("@") then break end
    advance(lex, 1)
    local name, err = expect_name(lex)
    if not name then return nil, err end
    local args
    args, err = parse_arguments(lex)
    if not args then return nil, err end
    insert(directives, { kind = "Directive", name = name, arguments = args })
  end
  return directives
end

--: (Lexer) -> unknown
local function parse_selection_set(lex)
  local ok, err = expect_char(lex, "{")
  if not ok then return nil, err end
  local selections = {}
  while true do
    skip_ignored(lex)
    if peek(lex) == byte("}") then advance(lex, 1); break end
    if lex.pos > lex.len then return nil, "unterminated selection set" end
    local c = peek(lex)
    if c == byte(".") then
      -- spread or inline fragment
      advance(lex, 1)
      if peek(lex) ~= byte(".") then return nil, "expected '...' for spread" end
      advance(lex, 1)
      if peek(lex) ~= byte(".") then return nil, "expected '...' for spread" end
      advance(lex, 1)
      skip_ignored(lex)
      -- peek at name to determine inline vs named spread
      local saved_pos, saved_line, saved_col = lex.pos, lex.line, lex.col
      local name_val = read_name(lex)
      if name_val == "on" then
        -- inline fragment: on TypeCondition
        local type_name, terr = expect_name(lex)
        if not type_name then return nil, terr end
        local tc = { kind = "NamedType", name = type_name }
        local dirs
        dirs, err = parse_directives(lex)
        if not dirs then return nil, err end
        local ss
        ss, err = parse_selection_set(lex)
        if not ss then return nil, err end
        insert(selections, {
          kind = "InlineFragment",
          typeCondition = tc,
          directives = dirs,
          selectionSet = ss,
        })
      elseif name_val then
        -- named fragment spread
        local dirs
        dirs, err = parse_directives(lex)
        if not dirs then return nil, err end
        insert(selections, {
          kind = "FragmentSpread",
          name = { kind = "Name", value = name_val },
          directives = dirs,
        })
      else
        -- inline fragment without type condition
        lex.pos, lex.line, lex.col = saved_pos, saved_line, saved_col
        local dirs
        dirs, err = parse_directives(lex)
        if not dirs then return nil, err end
        local ss
        ss, err = parse_selection_set(lex)
        if not ss then return nil, err end
        insert(selections, {
          kind = "InlineFragment",
          typeCondition = nil,
          directives = dirs,
          selectionSet = ss,
        })
      end
    else
      -- field (possibly aliased)
      local first_name = read_name(lex)
      if not first_name then
        return nil, format("expected field name at line %d col %d", lex.line, lex.col)
      end
      skip_ignored(lex)
      local alias_node = nil
      local field_name = first_name
      if peek(lex) == byte(":") then
        advance(lex, 1)
        alias_node = { kind = "Name", value = first_name }
        local fn, ferr = expect_name(lex)
        if not fn then return nil, ferr end
        field_name = fn.value
      end
      local args
      args, err = parse_arguments(lex)
      if not args then return nil, err end
      local dirs
      dirs, err = parse_directives(lex)
      if not dirs then return nil, err end
      local ss = nil
      skip_ignored(lex)
      if peek(lex) == byte("{") then
        ss, err = parse_selection_set(lex)
        if not ss then return nil, err end
      end
      insert(selections, {
        kind = "Field",
        alias = alias_node,
        name = { kind = "Name", value = field_name },
        arguments = args,
        directives = dirs,
        selectionSet = ss,
      })
    end
  end
  return { kind = "SelectionSet", selections = selections }
end

-- Parse a value node
parse_value = function(lex)
  skip_ignored(lex)
  local c = peek(lex)
  if not c then return nil, "unexpected EOF in value" end

  -- Variable $name
  if c == byte("$") then
    advance(lex, 1)
    local name, err = expect_name(lex)
    if not name then return nil, err end
    return { kind = "Variable", name = name }
  end

  -- Int or Float
  if c == byte("-") or (c >= 48 and c <= 57) then
    local kind, val = read_number(lex)
    if kind then
      return { kind = kind, value = val }
    end
    return nil, format("invalid number at line %d col %d", lex.line, lex.col)
  end

  -- String (block or regular)
  if c == byte('"') then
    local d2 = byte(lex.src, lex.pos + 1)
    local d3 = byte(lex.src, lex.pos + 2)
    if d2 == 34 and d3 == 34 then
      local val, err = read_block_string(lex)
      if val == nil then return nil, err end
      return { kind = "StringValue", value = val, block = true }
    else
      local val, err = read_string(lex)
      if val == nil then return nil, err end
      return { kind = "StringValue", value = val, block = false }
    end
  end

  -- List value [...]
  if c == byte("[") then
    advance(lex, 1)
    local values = {}
    while true do
      skip_ignored(lex)
      if peek(lex) == byte("]") then advance(lex, 1); break end
      if lex.pos > lex.len then return nil, "unterminated list value" end
      local v, err = parse_value(lex)
      if not v then return nil, err end
      insert(values, v)
    end
    return { kind = "ListValue", values = values }
  end

  -- Object value {...}
  if c == byte("{") then
    advance(lex, 1)
    local fields = {}
    while true do
      skip_ignored(lex)
      if peek(lex) == byte("}") then advance(lex, 1); break end
      if lex.pos > lex.len then return nil, "unterminated object value" end
      local name, err = expect_name(lex)
      if not name then return nil, err end
      local ok
      ok, err = expect_char(lex, ":")
      if not ok then return nil, err end
      local val
      val, err = parse_value(lex)
      if not val then return nil, err end
      insert(fields, { kind = "ObjectField", name = name, value = val })
    end
    return { kind = "ObjectValue", fields = fields }
  end

  -- Named values: true, false, null, or enum
  local name = read_name(lex)
  if name then
    if name == "true" then return { kind = "BooleanValue", value = true }
    elseif name == "false" then return { kind = "BooleanValue", value = false }
    elseif name == "null" then return { kind = "NullValue" }
    else return { kind = "EnumValue", value = name }
    end
  end

  return nil, format("unexpected character '%s' at line %d col %d",
    string.char(c), lex.line, lex.col)
end

-- Parse a type reference: NamedType, [ListType], NonNullType!
parse_type = function(lex)
  skip_ignored(lex)
  local c = peek(lex)
  local t
  local err
  if c == byte("[") then
    advance(lex, 1)
    local inner
    inner, err = parse_type(lex)
    if not inner then return nil, err end
    local ok
    ok, err = expect_char(lex, "]")
    if not ok then return nil, err end
    t = { kind = "ListType", type = inner }
  else
    local name
    name, err = expect_name(lex)
    if not name then return nil, err end
    t = { kind = "NamedType", name = name }
  end
  skip_ignored(lex)
  if peek(lex) == byte("!") then
    advance(lex, 1)
    t = { kind = "NonNullType", type = t }
  end
  return t
end

--: (Lexer) -> unknown
local function parse_variable_definitions(lex)
  skip_ignored(lex)
  if peek(lex) ~= byte("(") then return {} end
  advance(lex, 1)
  local vars = {}
  while true do
    skip_ignored(lex)
    if peek(lex) == byte(")") then advance(lex, 1); break end
    if lex.pos > lex.len then return nil, "unterminated variable definitions" end
    local ok, err = expect_char(lex, "$")
    if not ok then return nil, err end
    local name
    name, err = expect_name(lex)
    if not name then return nil, err end
    ok, err = expect_char(lex, ":")
    if not ok then return nil, err end
    local typ
    typ, err = parse_type(lex)
    if not typ then return nil, err end
    -- optional default value
    local default = nil
    skip_ignored(lex)
    if peek(lex) == byte("=") then
      advance(lex, 1)
      default, err = parse_value(lex)
      if not default then return nil, err end
    end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    insert(vars, {
      kind = "VariableDefinition",
      variable = { kind = "Variable", name = name },
      type = typ,
      defaultValue = default,
      directives = dirs,
    })
  end
  return vars
end

-- Parse an optional description (string literal before a definition)
--: (Lexer) -> unknown
local function parse_description(lex)
  skip_ignored(lex)
  local c = peek(lex)
  if c ~= byte('"') then return nil end
  local d2 = byte(lex.src, lex.pos + 1)
  local d3 = byte(lex.src, lex.pos + 2)
  if d2 == 34 and d3 == 34 then
    local val, err = read_block_string(lex)
    if val == nil then return nil, err end
    return { kind = "StringValue", value = val, block = true }
  else
    local val, err = read_string(lex)
    if val == nil then return nil, err end
    return { kind = "StringValue", value = val, block = false }
  end
end

-- Parse input value definitions (used in field args and input types)
--: (Lexer, integer) -> unknown
local function parse_input_value_defs(lex, close_char)
  local defs = {}
  while true do
    skip_ignored(lex)
    if peek(lex) == byte(close_char) then advance(lex, 1); break end
    if lex.pos > lex.len then
      return nil, format("unterminated input value definitions (expected '%s')", close_char)
    end
    local desc = parse_description(lex)
    if desc == nil and type(desc) == "nil" then
      -- no description, that's fine
    end
    local name, err = expect_name(lex)
    if not name then return nil, err end
    local ok
    ok, err = expect_char(lex, ":")
    if not ok then return nil, err end
    local typ
    typ, err = parse_type(lex)
    if not typ then return nil, err end
    local default = nil
    skip_ignored(lex)
    if peek(lex) == byte("=") then
      advance(lex, 1)
      default, err = parse_value(lex)
      if not default then return nil, err end
    end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    insert(defs, {
      kind = "InputValueDefinition",
      description = desc,
      name = name,
      type = typ,
      defaultValue = default,
      directives = dirs,
    })
  end
  return defs
end

-- Parse field definitions (used in object/interface types)
--: (Lexer) -> unknown
local function parse_field_defs(lex)
  local ok, err = expect_char(lex, "{")
  if not ok then return nil, err end
  local fields = {}
  while true do
    skip_ignored(lex)
    if peek(lex) == byte("}") then advance(lex, 1); break end
    if lex.pos > lex.len then return nil, "unterminated field definitions" end
    local desc = parse_description(lex)
    if type(desc) == "string" then return nil, desc end -- error from parse_description
    local name
    name, err = expect_name(lex)
    if not name then return nil, err end
    -- optional arguments
    local args = {}
    skip_ignored(lex)
    if peek(lex) == byte("(") then
      advance(lex, 1)
      args, err = parse_input_value_defs(lex, ")")
      if not args then return nil, err end
    end
    local col_ok
    col_ok, err = expect_char(lex, ":")
    if not col_ok then return nil, err end
    local typ
    typ, err = parse_type(lex)
    if not typ then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    insert(fields, {
      kind = "FieldDefinition",
      description = desc,
      name = name,
      arguments = args,
      type = typ,
      directives = dirs,
    })
  end
  return fields
end

-- Parse a single top-level definition
--: (Lexer) -> unknown
local function parse_definition(lex)
  skip_ignored(lex)
  if lex.pos > lex.len then return nil end

  -- Possibly a description before SDL definition
  local desc_node = nil
  local c = peek(lex)
  if c == byte('"') then
    local d, err = parse_description(lex)
    if err then return nil, err end
    desc_node = d
    skip_ignored(lex)
  end

  local saved_pos, saved_line, saved_col = lex.pos, lex.line, lex.col
  local name = read_name(lex)
  if not name then
    if lex.pos > lex.len then return nil end
    c = peek(lex)
    if c == byte("{") then
      -- Shorthand query (anonymous)
      local ss, err = parse_selection_set(lex)
      if not ss then return nil, err end
      return {
        kind = "OperationDefinition",
        operation = "query",
        name = nil,
        variableDefinitions = {},
        directives = {},
        selectionSet = ss,
      }
    end
    return nil, format("unexpected character at line %d col %d", lex.line, lex.col)
  end

  -- Query language operations
  if name == "query" or name == "mutation" or name == "subscription" then
    local op = name
    skip_ignored(lex)
    local op_name = nil
    c = peek(lex)
    if c ~= byte("(") and c ~= byte("{") and c ~= byte("@") then
      local n, err = expect_name(lex)
      if not n then return nil, err end
      op_name = n
    end
    local vars, err = parse_variable_definitions(lex)
    if not vars then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local ss
    ss, err = parse_selection_set(lex)
    if not ss then return nil, err end
    return {
      kind = "OperationDefinition",
      operation = op,
      name = op_name,
      variableDefinitions = vars,
      directives = dirs,
      selectionSet = ss,
    }
  end

  if name == "fragment" then
    local frag_name, err = expect_name(lex)
    if not frag_name then return nil, err end
    -- "on" keyword
    skip_ignored(lex)
    local on_word = read_name(lex)
    if on_word ~= "on" then
      return nil, format("expected 'on' in fragment definition at line %d col %d", lex.line, lex.col)
    end
    local type_name
    type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local ss
    ss, err = parse_selection_set(lex)
    if not ss then return nil, err end
    return {
      kind = "FragmentDefinition",
      name = frag_name,
      typeCondition = { kind = "NamedType", name = type_name },
      directives = dirs,
      selectionSet = ss,
    }
  end

  -- SDL definitions
  if name == "schema" then
    local dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local ok
    ok, err = expect_char(lex, "{")
    if not ok then return nil, err end
    local op_types = {}
    while true do
      skip_ignored(lex)
      if peek(lex) == byte("}") then advance(lex, 1); break end
      if lex.pos > lex.len then return nil, "unterminated schema definition" end
      local op_name_node, nerr = expect_name(lex)
      if not op_name_node then return nil, nerr end
      local col_ok
      col_ok, err = expect_char(lex, ":")
      if not col_ok then return nil, err end
      local type_name
      type_name, err = expect_name(lex)
      if not type_name then return nil, err end
      insert(op_types, {
        kind = "OperationTypeDefinition",
        operation = op_name_node.value,
        type = { kind = "NamedType", name = type_name },
      })
    end
    return {
      kind = "SchemaDefinition",
      description = desc_node,
      directives = dirs,
      operationTypes = op_types,
    }
  end

  if name == "scalar" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    return {
      kind = "ScalarTypeDefinition",
      description = desc_node,
      name = type_name,
      directives = dirs,
    }
  end

  if name == "type" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    -- optional "implements"
    local interfaces = {}
    skip_ignored(lex)
    local saved2_pos, saved2_line, saved2_col = lex.pos, lex.line, lex.col
    local kw = read_name(lex)
    if kw == "implements" then
      optional_char(lex, "&") -- optional leading &
      while true do
        skip_ignored(lex)
        local iface_name
        iface_name, err = expect_name(lex)
        if not iface_name then return nil, err end
        insert(interfaces, { kind = "NamedType", name = iface_name })
        skip_ignored(lex)
        if peek(lex) ~= byte("&") then break end
        advance(lex, 1)
      end
    else
      lex.pos, lex.line, lex.col = saved2_pos, saved2_line, saved2_col
    end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local fields
    skip_ignored(lex)
    if peek(lex) == byte("{") then
      fields, err = parse_field_defs(lex)
      if not fields then return nil, err end
    else
      fields = {}
    end
    return {
      kind = "ObjectTypeDefinition",
      description = desc_node,
      name = type_name,
      interfaces = interfaces,
      directives = dirs,
      fields = fields,
    }
  end

  if name == "interface" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    -- optional "implements"
    local interfaces = {}
    skip_ignored(lex)
    local saved2_pos, saved2_line, saved2_col = lex.pos, lex.line, lex.col
    local kw = read_name(lex)
    if kw == "implements" then
      optional_char(lex, "&")
      while true do
        skip_ignored(lex)
        local iface_name
        iface_name, err = expect_name(lex)
        if not iface_name then return nil, err end
        insert(interfaces, { kind = "NamedType", name = iface_name })
        skip_ignored(lex)
        if peek(lex) ~= byte("&") then break end
        advance(lex, 1)
      end
    else
      lex.pos, lex.line, lex.col = saved2_pos, saved2_line, saved2_col
    end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local fields
    skip_ignored(lex)
    if peek(lex) == byte("{") then
      fields, err = parse_field_defs(lex)
      if not fields then return nil, err end
    else
      fields = {}
    end
    return {
      kind = "InterfaceTypeDefinition",
      description = desc_node,
      name = type_name,
      interfaces = interfaces,
      directives = dirs,
      fields = fields,
    }
  end

  if name == "union" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local types = {}
    skip_ignored(lex)
    if peek(lex) == byte("=") then
      advance(lex, 1)
      optional_char(lex, "|") -- optional leading |
      while true do
        skip_ignored(lex)
        local member_name
        member_name, err = expect_name(lex)
        if not member_name then return nil, err end
        insert(types, { kind = "NamedType", name = member_name })
        skip_ignored(lex)
        if peek(lex) ~= byte("|") then break end
        advance(lex, 1)
      end
    end
    return {
      kind = "UnionTypeDefinition",
      description = desc_node,
      name = type_name,
      directives = dirs,
      types = types,
    }
  end

  if name == "enum" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local ok
    ok, err = expect_char(lex, "{")
    if not ok then return nil, err end
    local values = {}
    while true do
      skip_ignored(lex)
      if peek(lex) == byte("}") then advance(lex, 1); break end
      if lex.pos > lex.len then return nil, "unterminated enum definition" end
      local edesc = parse_description(lex)
      if type(edesc) == "string" then return nil, edesc end
      local val_name
      val_name, err = expect_name(lex)
      if not val_name then return nil, err end
      local edirs
      edirs, err = parse_directives(lex)
      if not edirs then return nil, err end
      insert(values, {
        kind = "EnumValueDefinition",
        description = edesc,
        name = val_name,
        directives = edirs,
      })
    end
    return {
      kind = "EnumTypeDefinition",
      description = desc_node,
      name = type_name,
      directives = dirs,
      values = values,
    }
  end

  if name == "input" then
    local type_name, err = expect_name(lex)
    if not type_name then return nil, err end
    local dirs
    dirs, err = parse_directives(lex)
    if not dirs then return nil, err end
    local fields = {}
    skip_ignored(lex)
    if peek(lex) == byte("{") then
      advance(lex, 1)
      fields, err = parse_input_value_defs(lex, "}")
      if not fields then return nil, err end
    end
    return {
      kind = "InputObjectTypeDefinition",
      description = desc_node,
      name = type_name,
      directives = dirs,
      fields = fields,
    }
  end

  if name == "directive" then
    local ok, err = expect_char(lex, "@")
    if not ok then return nil, err end
    local dir_name
    dir_name, err = expect_name(lex)
    if not dir_name then return nil, err end
    local args = {}
    skip_ignored(lex)
    if peek(lex) == byte("(") then
      advance(lex, 1)
      args, err = parse_input_value_defs(lex, ")")
      if not args then return nil, err end
    end
    -- optional "repeatable"
    local repeatable = false
    skip_ignored(lex)
    local saved3_pos, saved3_line, saved3_col = lex.pos, lex.line, lex.col
    local kw3 = read_name(lex)
    if kw3 == "repeatable" then
      repeatable = true
    else
      lex.pos, lex.line, lex.col = saved3_pos, saved3_line, saved3_col
    end
    -- "on" keyword
    skip_ignored(lex)
    local on_kw = read_name(lex)
    if on_kw ~= "on" then
      return nil, format("expected 'on' in directive definition at line %d col %d", lex.line, lex.col)
    end
    optional_char(lex, "|")
    local locations = {}
    while true do
      skip_ignored(lex)
      local loc, lerr = expect_name(lex)
      if not loc then return nil, lerr end
      insert(locations, loc)
      skip_ignored(lex)
      if peek(lex) ~= byte("|") then break end
      advance(lex, 1)
    end
    return {
      kind = "DirectiveDefinition",
      description = desc_node,
      name = dir_name,
      arguments = args,
      repeatable = repeatable,
      locations = locations,
    }
  end

  -- SDL extension keywords: extend type/interface/union/enum/input/schema
  if name == "extend" then
    skip_ignored(lex)
    local ext_kw = read_name(lex)
    if not ext_kw then
      return nil, format("expected type keyword after 'extend' at line %d col %d", lex.line, lex.col)
    end
    -- Prepend "extend" prefix to kind
    local inner, err = parse_definition(lex)
    if inner == nil then
      -- Re-parse with restored state won't work well here, so handle inline
      return nil, err or format("invalid extend at line %d col %d", lex.line, lex.col)
    end
    -- wrap with extension kind
    inner.kind = inner.kind:gsub("Definition$", "Extension")
    return inner
  end

  -- If we have a description but no keyword, that's an error
  if desc_node then
    return nil, format("expected type definition keyword at line %d col %d", lex.line, lex.col)
  end

  -- Unrecognized — restore and check if it starts a shorthand query
  lex.pos, lex.line, lex.col = saved_pos, saved_line, saved_col
  c = peek(lex)
  if c == byte("{") then
    local ss, err = parse_selection_set(lex)
    if not ss then return nil, err end
    return {
      kind = "OperationDefinition",
      operation = "query",
      name = nil,
      variableDefinitions = {},
      directives = {},
      selectionSet = ss,
    }
  end

  return nil, format("unexpected token '%s' at line %d col %d",
    name, lex.line, lex.col)
end

-- ---------------------------------------------------------------------------
-- Public API: M.parse
-- ---------------------------------------------------------------------------

function M.parse(src)
  if type(src) ~= "string" then
    return nil, "expected string"
  end
  local lex = new_lexer(src)
  local defs = {}
  while true do
    skip_ignored(lex)
    if lex.pos > lex.len then break end
    local def, err = parse_definition(lex)
    if def == nil then
      if err then return nil, err end
      break
    end
    insert(defs, def)
  end
  return { kind = "Document", definitions = defs }
end

-- ---------------------------------------------------------------------------
-- Public API: M.get
-- ---------------------------------------------------------------------------

-- Simple path accessor: M.get(ast, "definitions[1].selectionSet.selections[1].name.value")
function M.get(ast, path)
  local node = ast
  for segment in path:gmatch("[^%.]+") do
    if node == nil then return nil end
    local key, idx = segment:match("^(.-)%[(%d+)%]$")
    if key and idx then
      node = node[key]
      if node == nil then return nil end
      node = node[tonumber(idx)]
    else
      node = node[segment]
    end
  end
  return node
end

-- ---------------------------------------------------------------------------
-- Public API: M.validate
-- ---------------------------------------------------------------------------

local function validate_node(node, errors)
  if type(node) ~= "table" then return end
  local kind = node.kind
  if not kind then
    insert(errors, "node missing 'kind' field")
    return
  end

  if kind == "Document" then
    if type(node.definitions) ~= "table" then
      insert(errors, "Document.definitions must be a table")
    else
      for _, def in ipairs(node.definitions) do
        validate_node(def, errors)
      end
    end

  elseif kind == "OperationDefinition" then
    if node.operation ~= "query" and node.operation ~= "mutation" and node.operation ~= "subscription" then
      insert(errors, "OperationDefinition.operation must be query/mutation/subscription")
    end
    if node.selectionSet == nil then
      insert(errors, "OperationDefinition missing selectionSet")
    else
      validate_node(node.selectionSet, errors)
    end

  elseif kind == "FragmentDefinition" then
    if node.name == nil then insert(errors, "FragmentDefinition missing name") end
    if node.typeCondition == nil then insert(errors, "FragmentDefinition missing typeCondition") end
    if node.selectionSet == nil then insert(errors, "FragmentDefinition missing selectionSet") end

  elseif kind == "SelectionSet" then
    if type(node.selections) ~= "table" then
      insert(errors, "SelectionSet.selections must be a table")
    elseif #node.selections == 0 then
      insert(errors, "SelectionSet must have at least one selection")
    end

  elseif kind == "Field" then
    if node.name == nil then insert(errors, "Field missing name") end

  elseif kind == "Argument" then
    if node.name == nil then insert(errors, "Argument missing name") end
    if node.value == nil then insert(errors, "Argument missing value") end

  elseif kind == "FragmentSpread" then
    if node.name == nil then insert(errors, "FragmentSpread missing name") end

  elseif kind == "VariableDefinition" then
    if node.variable == nil then insert(errors, "VariableDefinition missing variable") end
    if node.type == nil then insert(errors, "VariableDefinition missing type") end

  elseif kind == "ObjectTypeDefinition" or kind == "InterfaceTypeDefinition" then
    if node.name == nil then insert(errors, kind .. " missing name") end
    if node.fields == nil then insert(errors, kind .. " missing fields") end
  end
end

function M.validate(doc)
  local errors = {}
  validate_node(doc, errors)
  if #errors == 0 then
    return true, {}
  end
  return false, errors
end

-- ---------------------------------------------------------------------------
-- Public API: M.print
-- ---------------------------------------------------------------------------

local print_node  -- forward declaration

local function print_indent(indent)
  return string.rep("  ", indent)
end

local function print_string_value(node)
  if node.block then
    return '"""\n' .. node.value .. '\n"""'
  else
    -- Escape special characters
    local s = node.value
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return '"' .. s .. '"'
  end
end

local function print_type(t)
  if t.kind == "NamedType" then
    return t.name.value
  elseif t.kind == "ListType" then
    return "[" .. print_type(t.type) .. "]"
  elseif t.kind == "NonNullType" then
    return print_type(t.type) .. "!"
  end
  return "?"
end

local function print_value(node)
  local k = node.kind
  if k == "IntValue" or k == "FloatValue" then
    return node.value
  elseif k == "StringValue" then
    return print_string_value(node)
  elseif k == "BooleanValue" then
    return node.value and "true" or "false"
  elseif k == "NullValue" then
    return "null"
  elseif k == "EnumValue" then
    return node.value
  elseif k == "Variable" then
    return "$" .. node.name.value
  elseif k == "ListValue" then
    local parts = {}
    for _, v in ipairs(node.values) do
      insert(parts, print_value(v))
    end
    return "[" .. concat(parts, ", ") .. "]"
  elseif k == "ObjectValue" then
    local parts = {}
    for _, f in ipairs(node.fields) do
      insert(parts, f.name.value .. ": " .. print_value(f.value))
    end
    return "{" .. concat(parts, ", ") .. "}"
  end
  return "null"
end

local function print_arguments(args)
  if not args or #args == 0 then return "" end
  local parts = {}
  for _, arg in ipairs(args) do
    insert(parts, arg.name.value .. ": " .. print_value(arg.value))
  end
  return "(" .. concat(parts, ", ") .. ")"
end

--: (dirs: unknown) -> string
local function print_directives(dirs)
  if not dirs or #dirs == 0 then return "" end
  local parts = {}
  for _, d in ipairs(--[[:! { name: { value: string }, arguments: any }[] ]] dirs) do
    insert(parts, "@" .. d.name.value .. print_arguments(d.arguments))
  end
  return " " .. concat(parts, " ")
end

local function print_selection_set(ss, indent)
  if not ss then return "" end
  local lines = { " {" }
  for _, sel in ipairs(ss.selections) do
    local s = print_indent(indent + 1)
    local k = sel.kind
    if k == "Field" then
      if sel.alias then
        s = s .. sel.alias.value .. ": "
      end
      s = s .. sel.name.value
      s = s .. print_arguments(sel.arguments)
      s = s .. print_directives(sel.directives)
      if sel.selectionSet then
        s = s .. print_selection_set(sel.selectionSet, indent + 1)
      end
    elseif k == "FragmentSpread" then
      s = s .. "..." .. sel.name.value
      s = s .. print_directives(sel.directives)
    elseif k == "InlineFragment" then
      s = s .. "..."
      if sel.typeCondition then
        s = s .. " on " .. sel.typeCondition.name.value
      end
      s = s .. print_directives(sel.directives)
      s = s .. print_selection_set(sel.selectionSet, indent + 1)
    end
    insert(lines, s)
  end
  insert(lines, print_indent(indent) .. "}")
  return concat(lines, "\n")
end

local function print_variable_definitions(vars)
  if not vars or #vars == 0 then return "" end
  local parts = {}
  for _, vd in ipairs(vars) do
    local s = "$" .. vd.variable.name.value .. ": " .. print_type(vd.type)
    if vd.defaultValue then
      s = s .. " = " .. print_value(vd.defaultValue)
    end
    s = s .. print_directives(vd.directives)
    insert(parts, s)
  end
  return "(" .. concat(parts, ", ") .. ")"
end

local function print_description(desc, indent)
  if not desc then return "" end
  return print_indent(indent) .. print_string_value(desc) .. "\n"
end

local function print_input_value_defs(defs, indent)
  local parts = {}
  for _, d in ipairs(defs) do
    local s = print_indent(indent)
    if d.description then
      s = print_description(d.description, indent) .. s
    end
    s = s .. d.name.value .. ": " .. print_type(d.type)
    if d.defaultValue then
      s = s .. " = " .. print_value(d.defaultValue)
    end
    s = s .. print_directives(d.directives)
    insert(parts, s)
  end
  return concat(parts, "\n")
end

print_node = function(node, indent)
  indent = indent or 0
  local k = node.kind

  if k == "Document" then
    local parts = {}
    for _, def in ipairs(node.definitions) do
      insert(parts, print_node(def, 0))
    end
    return concat(parts, "\n\n")

  elseif k == "OperationDefinition" then
    -- Shorthand for anonymous queries
    if node.operation == "query" and node.name == nil
       and (#node.variableDefinitions == 0)
       and (#node.directives == 0) then
      return print_selection_set(node.selectionSet, 0):sub(2) -- strip leading space
    end
    local s = node.operation
    if node.name then s = s .. " " .. node.name.value end
    s = s .. print_variable_definitions(node.variableDefinitions)
    s = s .. print_directives(node.directives)
    s = s .. print_selection_set(node.selectionSet, 0)
    return s

  elseif k == "FragmentDefinition" then
    local s = "fragment " .. node.name.value
    s = s .. " on " .. node.typeCondition.name.value
    s = s .. print_directives(node.directives)
    s = s .. print_selection_set(node.selectionSet, 0)
    return s

  elseif k == "SchemaDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "schema"
    s = s .. print_directives(node.directives)
    s = s .. " {\n"
    for _, ot in ipairs(node.operationTypes) do
      s = s .. "  " .. ot.operation .. ": " .. ot.type.name.value .. "\n"
    end
    return s .. "}"

  elseif k == "ScalarTypeDefinition" then
    local s = print_description(node.description, 0)
    return s .. "scalar " .. node.name.value .. print_directives(node.directives)

  elseif k == "ObjectTypeDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "type " .. node.name.value
    if node.interfaces and #node.interfaces > 0 then
      local ifaces = {}
      for _, i in ipairs(node.interfaces) do insert(ifaces, i.name.value) end
      s = s .. " implements " .. concat(ifaces, " & ")
    end
    s = s .. print_directives(node.directives)
    if node.fields and #node.fields > 0 then
      s = s .. " {\n"
      for _, f in ipairs(node.fields) do
        if f.description then
          s = s .. print_description(f.description, 1)
        end
        s = s .. "  " .. f.name.value
        if f.arguments and #f.arguments > 0 then
          s = s .. "(\n"
          s = s .. print_input_value_defs(f.arguments, 2)
          s = s .. "\n  )"
        end
        s = s .. ": " .. print_type(f.type)
        s = s .. print_directives(f.directives)
        s = s .. "\n"
      end
      s = s .. "}"
    end
    return s

  elseif k == "InterfaceTypeDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "interface " .. node.name.value
    if node.interfaces and #node.interfaces > 0 then
      local ifaces = {}
      for _, i in ipairs(node.interfaces) do insert(ifaces, i.name.value) end
      s = s .. " implements " .. concat(ifaces, " & ")
    end
    s = s .. print_directives(node.directives)
    if node.fields and #node.fields > 0 then
      s = s .. " {\n"
      for _, f in ipairs(node.fields) do
        if f.description then
          s = s .. print_description(f.description, 1)
        end
        s = s .. "  " .. f.name.value
        if f.arguments and #f.arguments > 0 then
          s = s .. "(\n"
          s = s .. print_input_value_defs(f.arguments, 2)
          s = s .. "\n  )"
        end
        s = s .. ": " .. print_type(f.type)
        s = s .. print_directives(f.directives)
        s = s .. "\n"
      end
      s = s .. "}"
    end
    return s

  elseif k == "UnionTypeDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "union " .. node.name.value
    s = s .. print_directives(node.directives)
    if node.types and #node.types > 0 then
      local parts = {}
      for _, t in ipairs(node.types) do insert(parts, t.name.value) end
      s = s .. " = " .. concat(parts, " | ")
    end
    return s

  elseif k == "EnumTypeDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "enum " .. node.name.value
    s = s .. print_directives(node.directives)
    s = s .. " {\n"
    for _, v in ipairs(node.values) do
      if v.description then
        s = s .. print_description(v.description, 1)
      end
      s = s .. "  " .. v.name.value
      s = s .. print_directives(v.directives)
      s = s .. "\n"
    end
    return s .. "}"

  elseif k == "InputObjectTypeDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "input " .. node.name.value
    s = s .. print_directives(node.directives)
    if node.fields and #node.fields > 0 then
      s = s .. " {\n"
      s = s .. print_input_value_defs(node.fields, 1)
      s = s .. "\n}"
    end
    return s

  elseif k == "DirectiveDefinition" then
    local s = print_description(node.description, 0)
    s = s .. "directive @" .. node.name.value
    if node.arguments and #node.arguments > 0 then
      s = s .. "(\n"
      s = s .. print_input_value_defs(node.arguments, 1)
      s = s .. "\n)"
    end
    if node.repeatable then s = s .. " repeatable" end
    local locs = {}
    for _, l in ipairs(node.locations) do insert(locs, l.value) end
    s = s .. " on " .. concat(locs, " | ")
    return s

  end

  -- Extension kinds
  if k:find("Extension$") then
    local base_kind = k:gsub("Extension$", "Definition")
    local fake = {}
    for key, val in pairs(node) do fake[key] = val end
    fake.kind = base_kind
    local inner = print_node(fake, indent)
    -- Replace leading type keyword with "extend type ..."
    local first_word = inner:match("^(%S+)")
    if first_word then
      return "extend " .. inner
    end
    return inner
  end

  return "# unknown node: " .. tostring(k)
end

function M.print(ast)
  if type(ast) ~= "table" then return "" end
  return print_node(ast, 0)
end

return M
