-- lib/css_parser/init.lua
-- CSS tokenizer, selector parser, declaration parser, and stylesheet parser.
-- Implements a simplified CSS Syntax Level 3 tokenizer and CSS Selectors Level 3 parser.
-- Pure Lua, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find, match, gmatch, gsub = string.byte, string.char, string.sub, string.find, string.match, string.gmatch, string.gsub
local concat, insert = table.concat, table.insert
local floor, abs = math.floor, math.abs
local type, tostring, pairs, ipairs, next = type, tostring, pairs, ipairs, next

-- ── Tokenizer ────────────────────────────────────────────────────────────────

-- Character predicates
local function is_ident_start(c)
  return c == "_" or c == "-" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (byte(c, 1) or 0) > 127
end

local function is_ident_char(c)
  return c == "_" or c == "-" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or (byte(c, 1) or 0) > 127
end

local function is_digit(c)
  return c >= "0" and c <= "9"
end

local function is_whitespace(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f"
end

-- Read an identifier starting at position i (assumes first char already valid)
--: (string, integer, integer) -> (string, integer)
local function read_ident(s, i, n)
  local start = i
  -- handle leading '-'
  if i <= n and sub(s, i, i) == "-" then
    i = i + 1
    if i > n then return "-", i end
    local c = sub(s, i, i)
    if not (is_ident_start(c)) then
      return "-", i
    end
    i = i + 1
  else
    i = i + 1
  end
  while i <= n and is_ident_char(sub(s, i, i)) do
    i = i + 1
  end
  return sub(s, start, i - 1), i
end

-- Read a string starting after the opening quote (quote is char q)
--: (string, integer, integer, string) -> (string, integer)
local function read_string(s, i, n, q)
  local parts = {}
  while i <= n do
    local c = sub(s, i, i)
    if c == q then
      return concat(parts), i + 1
    elseif c == "\\" then
      i = i + 1
      if i > n then break end
      local esc = sub(s, i, i)
      if esc == "n" then
        insert(parts, "\n")
      elseif esc == "t" then
        insert(parts, "\t")
      elseif esc == "\n" or esc == "\r" then
        -- escaped newline = ignored
      else
        insert(parts, esc)
      end
      i = i + 1
    elseif c == "\n" or c == "\r" then
      -- unterminated string
      break
    else
      insert(parts, c)
      i = i + 1
    end
  end
  return concat(parts), i
end

-- Read a number, return value (as string), integer flag, and new position
--: (string, integer, integer) -> (string, integer)
local function read_number(s, i, n)
  local start = i
  if i <= n and (sub(s, i, i) == "+" or sub(s, i, i) == "-") then
    i = i + 1
  end
  while i <= n and is_digit(sub(s, i, i)) do i = i + 1 end
  if i <= n and sub(s, i, i) == "." and i + 1 <= n and is_digit(sub(s, i + 1, i + 1)) then
    i = i + 1 -- consume "."
    while i <= n and is_digit(sub(s, i, i)) do i = i + 1 end
  end
  -- optional exponent
  if i <= n and (sub(s, i, i) == "e" or sub(s, i, i) == "E") then
    local j = i + 1
    if j <= n and (sub(s, j, j) == "+" or sub(s, j, j) == "-") then j = j + 1 end
    if j <= n and is_digit(sub(s, j, j)) then
      i = j
      while i <= n and is_digit(sub(s, i, i)) do i = i + 1 end
    end
  end
  return sub(s, start, i - 1), i
end

-- Read url() contents (after the opening paren)
--: (string, integer, integer) -> (string, integer)
local function read_url(s, i, n)
  -- skip whitespace
  while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
  if i > n then return "", i end
  local c = sub(s, i, i)
  if c == '"' or c == "'" then
    local val, ni = read_string(s, i + 1, n, c)
    i = ni
    -- skip whitespace
    while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
    -- expect closing paren
    if i <= n and sub(s, i, i) == ")" then i = i + 1 end
    return val, i
  else
    -- unquoted url
    local start = i
    while i <= n do
      local cc = sub(s, i, i)
      if cc == ")" or is_whitespace(cc) then break end
      i = i + 1
    end
    local val = sub(s, start, i - 1)
    while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
    if i <= n and sub(s, i, i) == ")" then i = i + 1 end
    return val, i
  end
end

-- Tokenize CSS source string
-- Returns array of token tables: {type, value, [unit], [flag]}
function M.tokenize(css)
  local tokens = {}
  local s = css
  local n = #s
  local i = 1

  while i <= n do
    local c = sub(s, i, i)

    -- whitespace
    if is_whitespace(c) then
      local start = i
      while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
      insert(tokens, { type = "whitespace", value = sub(s, start, i - 1) })

    -- comment
    elseif c == "/" and i + 1 <= n and sub(s, i + 1, i + 1) == "*" then
      i = i + 2
      while i + 1 <= n do
        if sub(s, i, i + 1) == "*/" then
          i = i + 2
          break
        end
        i = i + 1
      end
      -- comments are skipped (not emitted)

    -- string double-quote
    elseif c == '"' then
      local val, ni = read_string(s, i + 1, n, '"')
      insert(tokens, { type = "string", value = val })
      i = ni

    -- string single-quote
    elseif c == "'" then
      local val, ni = read_string(s, i + 1, n, "'")
      insert(tokens, { type = "string", value = val })
      i = ni

    -- hash
    elseif c == "#" then
      i = i + 1
      local start = i
      while i <= n and is_ident_char(sub(s, i, i)) do i = i + 1 end
      insert(tokens, { type = "hash", value = sub(s, start, i - 1) })

    -- at-keyword
    elseif c == "@" then
      i = i + 1
      if i <= n and is_ident_start(sub(s, i, i)) then
        local name, ni = read_ident(s, i, n)
        insert(tokens, { type = "at_keyword", value = name })
        i = ni
      else
        insert(tokens, { type = "delim", value = "@" })
      end

    -- number, dimension, percentage
    elseif is_digit(c) or (c == "." and i + 1 <= n and is_digit(sub(s, i + 1, i + 1)))
        or ((c == "+" or c == "-") and i + 1 <= n and (is_digit(sub(s, i + 1, i + 1))
            or (sub(s, i + 1, i + 1) == "." and i + 2 <= n and is_digit(sub(s, i + 2, i + 2))))) then
      local numstr, ni = read_number(s, i, n)
      i = ni
      -- check for % or unit
      if i <= n and sub(s, i, i) == "%" then
        insert(tokens, { type = "percentage", value = numstr })
        i = i + 1
      elseif i <= n and is_ident_start(sub(s, i, i)) then
        local unit, ni2 = read_ident(s, i, n)
        insert(tokens, { type = "dimension", value = numstr, unit = unit })
        i = ni2
      else
        insert(tokens, { type = "number", value = numstr })
      end

    -- ident, function, url
    elseif is_ident_start(c) then
      local name, ni = read_ident(s, i, n)
      i = ni
      if i <= n and sub(s, i, i) == "(" then
        if name:lower() == "url" then
          local urlval, ni2 = read_url(s, i + 1, n)
          insert(tokens, { type = "url", value = urlval })
          i = ni2
        else
          insert(tokens, { type = "function", value = name })
          i = i + 1
        end
      else
        insert(tokens, { type = "ident", value = name })
      end

    -- CDO/CDC
    elseif c == "<" and sub(s, i, i + 3) == "<!--" then
      insert(tokens, { type = "cdo", value = "<!--" })
      i = i + 4
    elseif c == "-" and sub(s, i, i + 2) == "-->" then
      insert(tokens, { type = "cdc", value = "-->" })
      i = i + 3

    -- single character tokens
    elseif c == ":" then
      insert(tokens, { type = "colon", value = ":" })
      i = i + 1
    elseif c == ";" then
      insert(tokens, { type = "semicolon", value = ";" })
      i = i + 1
    elseif c == "," then
      insert(tokens, { type = "comma", value = "," })
      i = i + 1
    elseif c == "(" then
      insert(tokens, { type = "open_paren", value = "(" })
      i = i + 1
    elseif c == ")" then
      insert(tokens, { type = "close_paren", value = ")" })
      i = i + 1
    elseif c == "[" then
      insert(tokens, { type = "open_bracket", value = "[" })
      i = i + 1
    elseif c == "]" then
      insert(tokens, { type = "close_bracket", value = "]" })
      i = i + 1
    elseif c == "{" then
      insert(tokens, { type = "open_brace", value = "{" })
      i = i + 1
    elseif c == "}" then
      insert(tokens, { type = "close_brace", value = "}" })
      i = i + 1
    else
      insert(tokens, { type = "delim", value = c })
      i = i + 1
    end
  end

  insert(tokens, { type = "eof", value = "" })
  return tokens
end

-- ── Declaration Parser ────────────────────────────────────────────────────────

-- Trim leading/trailing whitespace from a string
local function trim(s)
  return match(s, "^%s*(.-)%s*$")
end

-- Parse a CSS declaration block into an array of {property, value, important}
function M.parse_declarations(text)
  local decls = {}
  -- split on semicolons
  for decl in gmatch(text .. ";", "([^;]*);") do
    decl = trim(decl)
    if decl ~= "" then
      -- find first colon
      local colon = find(decl, ":", 1, true)
      if colon then
        local prop = trim(sub(decl, 1, colon - 1))
        local val = trim(sub(decl, colon + 1))
        if prop ~= "" then
          local important = false
          -- check for !important (case-insensitive)
          local v2 = val:lower()
          local imp_start = find(v2, "!%s*important%s*$")
          if imp_start then
            important = true
            val = trim(sub(val, 1, imp_start - 1))
          end
          if val ~= "" then
            insert(decls, { property = prop, value = val, important = important })
          end
        end
      end
    end
  end
  return decls
end

-- ── Selector Parser ───────────────────────────────────────────────────────────

-- Selector token stream helper
--:: CssToken = { type: string, value: string | nil, name: string | nil, op: string | nil, element: boolean | nil, arg: string | nil, neg: boolean | nil, ... }
--:: SelParser = { tokens: { [integer]: CssToken }, pos: number, peek: (SelParser) -> CssToken, consume: (SelParser) -> CssToken, skip_ws: (SelParser) -> nil }
local SelectorParser = {}
SelectorParser.__index = SelectorParser

local function new_selector_parser(s)
  local tokens = {}
  -- lightweight token extraction for selectors
  local n = #s
  local i = 1
  while i <= n do
    local c = sub(s, i, i)
    if is_whitespace(c) then
      -- collapse whitespace to single token
      while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
      insert(tokens, { type = "ws" })
    elseif c == ">" or c == "+" or c == "~" then
      insert(tokens, { type = "combinator", value = c })
      i = i + 1
    elseif c == "," then
      insert(tokens, { type = "comma" })
      i = i + 1
    elseif c == "." then
      i = i + 1
      if i <= n and is_ident_start(sub(s, i, i)) then
        local name, ni = read_ident(s, i, n)
        insert(tokens, { type = "class", value = name })
        i = ni
      end
    elseif c == "#" then
      i = i + 1
      if i <= n and is_ident_start(sub(s, i, i)) then
        local name, ni = read_ident(s, i, n)
        insert(tokens, { type = "id", value = name })
        i = ni
      end
    elseif c == "*" then
      insert(tokens, { type = "universal" })
      i = i + 1
    elseif c == "[" then
      -- attribute selector
      i = i + 1
      -- skip ws
      while i <= n and is_whitespace(sub(s, i, i)) do i = i + 1 end
      local attr_name = ""
      if i <= n and is_ident_start(sub(s, i, i)) then
        local an_, ai_ = read_ident(s, i, n)
        attr_name = an_
        i = ai_
      end
      local i2 = i
      local op = nil
      local attr_val = nil
      if i2 <= n and sub(s, i2, i2) ~= "]" then
        -- read operator
        if sub(s, i2, i2 + 1):find("^[~|^$*]=$") or sub(s, i2, i2) == "=" then
          if sub(s, i2, i2 + 1):find("^[~|^$*]=$") then
            op = sub(s, i2, i2 + 1)
            i2 = i2 + 2
          else
            op = "="
            i2 = i2 + 1
          end
          -- skip ws
          while i2 <= n and is_whitespace(sub(s, i2, i2)) do i2 = i2 + 1 end
          -- read value
          if i2 <= n and (sub(s, i2, i2) == '"' or sub(s, i2, i2) == "'") then
            local q = sub(s, i2, i2)
            local av_, ni_ = read_string(s, i2 + 1, n, q)
            attr_val = av_
            i2 = ni_
          elseif i2 <= n then
            local vs = i2
            while i2 <= n and sub(s, i2, i2) ~= "]" and not is_whitespace(sub(s, i2, i2)) do i2 = i2 + 1 end
            attr_val = sub(s, vs, i2 - 1)
          end
        end
      end
      -- skip to closing bracket
      while i2 <= n and sub(s, i2, i2) ~= "]" do i2 = i2 + 1 end
      if i2 <= n then i2 = i2 + 1 end -- consume "]"
      i = i2
      insert(tokens, { type = "attr", name = attr_name, op = op, value = attr_val })
    elseif c == ":" then
      i = i + 1
      local is_element = false
      if i <= n and sub(s, i, i) == ":" then
        is_element = true
        i = i + 1
      end
      local i3 = i
      if i3 <= n and is_ident_start(sub(s, i3, i3)) then
        local name, ni = read_ident(s, i3, n)
        i3 = ni
        -- check for functional pseudo
        if i3 <= n and sub(s, i3, i3) == "(" then
          i3 = i3 + 1
          -- read argument (simple: balanced parens not supported, just read until ")")
          local arg_start = i3
          local depth = 1 --: integer
          while i3 <= n and depth > 0 do
            if sub(s, i3, i3) == "(" then depth = depth + 1
            elseif sub(s, i3, i3) == ")" then depth = depth - 1 end
            if depth > 0 then i3 = i3 + 1 else break end
          end
          local arg = trim(sub(s, arg_start, i3 - 1))
          if i3 <= n then i3 = i3 + 1 end -- consume ")"
          insert(tokens, { type = "pseudo_fn", name = name, arg = arg, element = is_element })
        else
          insert(tokens, { type = "pseudo", name = name, element = is_element })
        end
      end
      i = i3
    elseif is_ident_start(c) then
      local name, ni = read_ident(s, i, n)
      insert(tokens, { type = "ident", value = name })
      i = ni
    else
      i = i + 1 -- skip unknown
    end
  end
  insert(tokens, { type = "eof" })
  local p_ = setmetatable({ tokens = tokens, pos = 1 }, SelectorParser) --[[: unknown]]
  return p_ --[[:! SelParser]]
end

--: (SelParser) -> CssToken
function SelectorParser:peek()
  return self.tokens[self.pos]
end

--: (SelParser) -> CssToken
function SelectorParser:consume()
  local t = self.tokens[self.pos]
  self.pos = self.pos + 1
  return t
end

--: (SelParser) -> nil
function SelectorParser:skip_ws()
  while self.tokens[self.pos] and self.tokens[self.pos].type == "ws" do
    self.pos = self.pos + 1
  end
end

-- Parse a compound selector (type_sel? simples*)
-- Returns compound_selector table or nil
--: (SelParser) -> CssCompound | nil
local function parse_compound(p)
  local compound = {
    type_selector = nil --[[: string | nil]],
    id = nil --[[: string | nil]],
    classes = {},
    attributes = {},
    pseudos = {},
    combinator = nil --[[: string | nil]],
  }
  local found = false

  local t = p:peek()

  -- type selector or universal
  if t.type == "ident" then
    compound.type_selector = t.value
    p:consume()
    found = true
    t = p:peek()
  elseif t.type == "universal" then
    compound.type_selector = "*"
    p:consume()
    found = true
    t = p:peek()
  end

  -- simple selectors
  while true do
    t = p:peek()
    if t.type == "id" then
      compound.id = t.value
      p:consume()
      found = true
    elseif t.type == "class" then
      insert(compound.classes, t.value)
      p:consume()
      found = true
    elseif t.type == "attr" then
      insert(compound.attributes, { name = t.name, op = t.op, value = t.value })
      p:consume()
      found = true
    elseif t.type == "pseudo" then
      insert(compound.pseudos, { name = t.name, element = t.element })
      p:consume()
      found = true
    elseif t.type == "pseudo_fn" then
      insert(compound.pseudos, { name = t.name, arg = t.arg, element = t.element, functional = true })
      p:consume()
      found = true
    else
      break
    end
  end

  if not found then return nil end
  return compound
end

-- Parse a complex selector (compound (combinator compound)*)
--: (SelParser) -> { [integer]: unknown } | nil
local function parse_complex(p)
  local complex = {}

  local compound = parse_compound(p)
  if not compound then return nil end
  insert(complex, compound)

  while true do
    local t = p:peek()
    local combinator = nil

    if t.type == "combinator" then
      combinator = t.value
      p:consume()
      p:skip_ws()
    elseif t.type == "ws" then
      -- peek ahead: if next non-ws is a compound start, it's a descendant combinator
      local saved_pos = p.pos
      p:skip_ws()
      local nt = p:peek()
      if nt.type == "ident" or nt.type == "universal" or nt.type == "id"
          or nt.type == "class" or nt.type == "attr" or nt.type == "colon"
          or nt.type == "pseudo" or nt.type == "pseudo_fn" then
        combinator = " "
      elseif nt.type == "combinator" then
        combinator = nt.value
        p:consume()
        p:skip_ws()
      else
        -- not a combinator, stop
        break
      end
    else
      break
    end

    local next_compound = parse_compound(p)
    if not next_compound then break end
    next_compound.combinator = combinator
    insert(complex, next_compound)
  end

  return complex
end

-- Parse a selector list (complex ("," complex)*)
--: (SelParser) -> { [integer]: unknown }
local function parse_selector_list(p)
  local list = {}

  p:skip_ws()
  local complex = parse_complex(p)
  if complex then insert(list, complex) end

  while true do
    local t = p:peek()
    if t.type == "comma" then
      p:consume()
      p:skip_ws()
      local c = parse_complex(p)
      if c then insert(list, c) end
    else
      break
    end
  end

  return list
end

-- Parse a selector string into a selector_list AST
function M.parse_selector(selector_str)
  local p = new_selector_parser(selector_str)
  return parse_selector_list(p)
end

-- ── Stylesheet Parser ─────────────────────────────────────────────────────────

-- Token stream helper for stylesheet parsing
--:: CssStyleToken = { type: string, value: string | nil, unit: string | nil, flag: string | nil, ... }
--:: TokStream = { tokens: { [integer]: CssStyleToken }, pos: number, peek: (TokStream) -> CssStyleToken, consume: (TokStream) -> CssStyleToken, skip_ws: (TokStream) -> nil, peek_nonws: (TokStream) -> CssStyleToken }
local TokenStream = {}
TokenStream.__index = TokenStream

--: ({ [integer]: CssStyleToken }) -> TokStream
local function new_token_stream(tokens)
  local s_ = setmetatable({ tokens = tokens, pos = 1 }, TokenStream) --[[: unknown]]
  return s_ --[[:! TokStream]]
end

--: (TokStream) -> CssStyleToken
function TokenStream:peek()
  return self.tokens[self.pos]
end

--: (TokStream) -> CssStyleToken
function TokenStream:consume()
  local t = self.tokens[self.pos]
  self.pos = self.pos + 1
  return t
end

--: (TokStream) -> nil
function TokenStream:skip_ws()
  while self.tokens[self.pos] and self.tokens[self.pos].type == "whitespace" do
    self.pos = self.pos + 1
  end
end

--: (TokStream) -> CssStyleToken
function TokenStream:peek_nonws()
  local j = self.pos
  while self.tokens[j] and self.tokens[j].type == "whitespace" do j = j + 1 end
  return self.tokens[j]
end

-- Read tokens into a string until a given token type is found (not consumed)
local function collect_until(stream, stop_types)
  local stream_ = stream --[[:! TokStream]]
  local parts = {}
  while true do
    local t = stream_:peek()
    if not t or t.type == "eof" then break end
    for _, st in ipairs(stop_types) do
      if t.type == st then return concat(parts) end
    end
    insert(parts, t.value or "")
    stream_:consume()
  end
  return concat(parts)
end

-- Parse a block { ... } and return inner tokens
local function parse_block(stream)
  local stream_ = stream --[[:! TokStream]]
  -- consume open_brace
  stream_:consume()
  local depth = 1
  local inner = {}
  while true do
    local t = stream_:peek()
    if not t or t.type == "eof" then break end
    if t.type == "open_brace" then
      depth = depth + 1
      insert(inner, stream_:consume())
    elseif t.type == "close_brace" then
      depth = depth - 1
      if depth == 0 then
        stream_:consume()
        break
      else
        insert(inner, stream_:consume())
      end
    else
      insert(inner, stream_:consume())
    end
  end
  return inner
end

-- Tokens-to-string for prelude/selector text
local function tokens_to_string(toks)
  local parts = {}
  for _, t in ipairs(toks) do
    insert(parts, t.value or "")
  end
  return trim(concat(parts))
end

-- Parse at-rule starting after @name token has been consumed
local function parse_at_rule(stream, name)
  local stream_ = stream --[[:! TokStream]]
  -- collect prelude tokens until { or ;
  local prelude_toks = {}
  local rules = nil
  while true do
    local t = stream_:peek()
    if not t or t.type == "eof" then break end
    if t.type == "semicolon" then
      stream_:consume()
      break
    elseif t.type == "open_brace" then
      -- nested block
      local block_toks = parse_block(stream_)
      -- for @media/@supports etc, parse inner rules
      local inner_stream = new_token_stream(block_toks --[[: unknown]] --[[:! { [integer]: CssStyleToken }]])
      -- append eof
      insert(block_toks, { type = "eof", value = "" } --[[: unknown]])
      rules = {}
      -- parse inner rules (simplified: only style rules)
      while true do
        inner_stream:skip_ws()
        local it = inner_stream:peek()
        if not it or it.type == "eof" then break end
        -- try to parse a style rule
        local sel_toks = {}
        while true do
          local jt = inner_stream:peek()
          if not jt or jt.type == "eof" or jt.type == "open_brace" then break end
          insert(sel_toks, inner_stream:consume())
        end
        local sel_str = tokens_to_string(sel_toks)
        if inner_stream:peek() and inner_stream:peek().type == "open_brace" then
          local body_toks = parse_block(inner_stream)
          -- join body tokens to string
          local body_str = tokens_to_string(body_toks)
          local sel_list = M.parse_selector(sel_str)
          local decls = M.parse_declarations(body_str)
          if sel_str ~= "" then
            insert(rules, { type = "style_rule", selector = sel_list, declarations = decls })
          end
        end
      end
      break
    else
      insert(prelude_toks, stream_:consume())
    end
  end
  local prelude = tokens_to_string(prelude_toks)
  local rule = { type = "at_rule", name = name, prelude = prelude }
  if rules then rule.rules = rules end
  return rule
end

-- Parse a CSS stylesheet string into an array of rules
function M.parse(css)
  local tokens = M.tokenize(css)
  local stream = new_token_stream(tokens)
  local rules = {}

  while true do
    stream:skip_ws()
    local t = stream:peek()
    if not t or t.type == "eof" then break end

    if t.type == "at_keyword" then
      local name = t.value
      stream:consume()
      stream:skip_ws()
      local rule = parse_at_rule(stream, name)
      insert(rules, rule)

    elseif t.type == "cdo" or t.type == "cdc" then
      stream:consume()

    else
      -- style rule: collect selector tokens until open_brace
      local sel_toks = {}
      while true do
        local jt = stream:peek()
        if not jt or jt.type == "eof" or jt.type == "open_brace" then break end
        insert(sel_toks, stream:consume())
      end
      local sel_str = tokens_to_string(sel_toks)
      if stream:peek() and stream:peek().type == "open_brace" then
        local body_toks = parse_block(stream)
        local body_str = tokens_to_string(body_toks)
        local sel_list = M.parse_selector(sel_str)
        local decls = M.parse_declarations(body_str)
        insert(rules, { type = "style_rule", selector = sel_list, declarations = decls })
      else
        -- malformed, skip
      end
    end
  end

  return rules
end

-- ── Selector Matching ─────────────────────────────────────────────────────────

-- Split a space-separated class string into a set
local function class_set(class_str)
  local set = {}
  if class_str then
    for cls in gmatch(class_str, "%S+") do
      set[cls] = true
    end
  end
  return set
end

--:: CssCompound = { type_selector: string | nil, id: string | nil, classes: { [integer]: string }, attributes: { [integer]: { name: string, op: string | nil, value: string | nil } }, pseudos: { [integer]: { name: string, element: boolean | nil, arg: string | nil, functional: boolean | nil } }, combinator: string | nil }
--:: CssElement = { tag: string | nil, id: string | nil, class: string | nil, attrs: { [string]: string } | nil, parent: CssElement | nil, prev: CssElement | nil, ... }
-- Match a compound selector against an element
--: (CssCompound, CssElement) -> boolean
local function match_compound(compound, element)
  -- type selector
  if compound.type_selector and compound.type_selector ~= "*" then
    if element.tag ~= compound.type_selector then return false end
  end

  -- id
  if compound.id then
    if element.id ~= compound.id then return false end
  end

  -- classes
  if #compound.classes > 0 then
    local cset = class_set(element.class)
    for _, cls in ipairs(compound.classes) do
      if not cset[cls] then return false end
    end
  end

  -- attributes
  if #compound.attributes > 0 then
    local attrs = element.attrs or {}
    for _, attr in ipairs(compound.attributes) do
      local av = attrs[attr.name]
      if attr.op == nil then
        if av == nil then return false end
      elseif attr.op == "=" then
        if av ~= attr.value then return false end
      elseif attr.op == "~=" then
        -- word match
        local found = false
        for w in gmatch(av or "", "%S+") do
          if w == attr.value then found = true; break end
        end
        if not found then return false end
      elseif attr.op == "|=" then
        local av_ = attr.value or ""
        if av ~= av_ and not (av and find(av, av_ .. "-", 1, true) == 1) then
          return false
        end
      elseif attr.op == "^=" then
        local av_ = attr.value or ""
        if not av or find(av, av_, 1, true) ~= 1 then return false end
      elseif attr.op == "$=" then
        local av_ = attr.value or ""
        if not av or sub(av, -#av_) ~= av_ then return false end
      elseif attr.op == "*=" then
        local av_ = attr.value or ""
        if not av or not find(av, av_, 1, true) then return false end
      end
    end
  end

  -- pseudos (simple: :hover, :first-child, :nth-child ignored for match purposes)
  -- pseudo-classes that require DOM context are treated as always-false here
  -- except for :not()
  for _, pseudo in ipairs(compound.pseudos) do
    if pseudo.functional and pseudo.name:lower() == "not" then
      local not_sel = M.parse_selector(pseudo.arg or "")
      if not_sel and #not_sel > 0 then
        if M.matches_complex(not_sel[1], element) then return false end
      end
    end
    -- other pseudos: skip (no DOM context)
  end

  return true
end

-- Match a complex selector (array of compounds with combinators) against an element
function M.matches_complex(complex, element)
  -- Work right to left through the compound selectors
  -- The last compound matches the target element
  local idx = #complex
  local el = element --[[:! CssElement]]

  -- match last compound
  if not match_compound(complex[idx], el) then return false end

  idx = idx - 1

  while idx >= 1 do
    local compound = complex[idx]
    local combinator = complex[idx + 1].combinator

    if combinator == ">" then
      -- parent must match
      if not el.parent then return false end
      el = el.parent --[[:! CssElement]]
      if not match_compound(compound, el) then return false end
    elseif combinator == " " then
      -- ancestor must match
      if not el.parent then return false end
      el = el.parent --[[:! CssElement]]
      local found = false
      local anc --: CssElement | nil
      anc = el
      while anc do
        local anc_ = anc --[[:! CssElement]]
        if match_compound(compound, anc_) then found = true; break end
        anc = anc_.parent
      end
      if not found then return false end
    elseif combinator == "+" then
      -- immediately preceding sibling
      if not el.prev then return false end
      el = el.prev --[[:! CssElement]]
      if not match_compound(compound, el) then return false end
    elseif combinator == "~" then
      -- preceding sibling
      if not el.prev then return false end
      el = el.prev --[[:! CssElement]]
      local found = false
      local sib --: CssElement | nil
      sib = el
      while sib do
        local sib_ = sib --[[:! CssElement]]
        if match_compound(compound, sib_) then found = true; break end
        sib = sib_.prev
      end
      if not found then return false end
    else
      return false
    end

    idx = idx - 1
  end

  return true
end

-- Check if element matches a selector string
function M.matches(selector_str, element)
  local sel_list = M.parse_selector(selector_str)
  for _, complex in ipairs(sel_list) do
    local complex_ = complex --[[:! { [integer]: CssCompound }]]
    if M.matches_complex(complex_, element) then return true end
  end
  return false
end

-- ── Specificity ───────────────────────────────────────────────────────────────

-- Calculate specificity for a complex selector (array of compounds)
local function complex_specificity(complex)
  local a, b, c = 0, 0, 0
  for _, compound in ipairs(complex) do
    -- type selector
    if compound.type_selector and compound.type_selector ~= "*" then
      c = c + 1
    end
    -- id
    if compound.id then a = a + 1 end
    -- classes
    b = b + #compound.classes
    -- attributes
    b = b + #compound.attributes
    -- pseudos
    for _, pseudo in ipairs(compound.pseudos) do
      if pseudo.element then
        c = c + 1 -- pseudo-element
      else
        b = b + 1 -- pseudo-class
      end
    end
  end
  return { a = a, b = b, c = c }
end

-- Return specificity {a, b, c} for the first selector in the selector string
function M.specificity(selector_str)
  local sel_list = M.parse_selector(selector_str)
  if not sel_list or #sel_list == 0 then
    return { a = 0, b = 0, c = 0 }
  end
  return complex_specificity(sel_list[1])
end

-- Compare two specificity tables: returns true if s1 > s2
function M.specificity_gt(s1, s2)
  if s1.a ~= s2.a then return s1.a > s2.a end
  if s1.b ~= s2.b then return s1.b > s2.b end
  return s1.c > s2.c
end

-- ── Stringify ────────────────────────────────────────────────────────────────

-- Stringify a compound selector
--: (CssCompound) -> string
local function stringify_compound(compound)
  local parts = {}
  if compound.type_selector then
    insert(parts, compound.type_selector)
  end
  if compound.id then
    insert(parts, "#" .. compound.id)
  end
  for _, cls in ipairs(compound.classes) do
    insert(parts, "." .. cls)
  end
  for _, attr in ipairs(compound.attributes) do
    if attr.op then
      local op_ = attr.op --[[:! string]]
      insert(parts, "[" .. attr.name .. op_ .. '"' .. (attr.value or "") .. '"]')
    else
      insert(parts, "[" .. attr.name .. "]")
    end
  end
  for _, pseudo in ipairs(compound.pseudos) do
    local prefix = pseudo.element and "::" or ":"
    if pseudo.functional then
      insert(parts, prefix .. pseudo.name .. "(" .. (pseudo.arg or "") .. ")")
    else
      insert(parts, prefix .. pseudo.name)
    end
  end
  return concat(parts)
end

-- Stringify a complex selector
local function stringify_complex(complex)
  local parts = {}
  for i, compound in ipairs(complex) do
    if i > 1 then
      local comb = compound.combinator or " "
      if comb == " " then
        insert(parts, " ")
      else
        insert(parts, " " .. comb .. " ")
      end
    end
    insert(parts, stringify_compound(compound))
  end
  return concat(parts)
end

-- Stringify a selector list
local function stringify_selector_list(sel_list)
  local parts = {}
  for _, complex in ipairs(sel_list) do
    insert(parts, stringify_complex(complex))
  end
  return concat(parts, ", ")
end

-- Stringify declarations
local function stringify_declarations(decls)
  local parts = {}
  for _, decl in ipairs(decls) do
    local s = decl.property .. ": " .. decl.value
    if decl.important then s = s .. " !important" end
    insert(parts, s)
  end
  return concat(parts, "; ")
end

-- Stringify a parsed stylesheet
function M.stringify(stylesheet)
  local parts = {}
  for _, rule in ipairs(stylesheet) do
    if rule.type == "style_rule" then
      local sel_str = stringify_selector_list(rule.selector)
      local body = stringify_declarations(rule.declarations)
      insert(parts, sel_str .. " { " .. body .. " }")
    elseif rule.type == "at_rule" then
      if rule.rules then
        -- block at-rule
        local inner_parts = {}
        for _, inner_rule in ipairs(rule.rules) do
          if inner_rule.type == "style_rule" then
            local sel_str = stringify_selector_list(inner_rule.selector)
            local body = stringify_declarations(inner_rule.declarations)
            insert(inner_parts, "  " .. sel_str .. " { " .. body .. " }")
          end
        end
        insert(parts, "@" .. rule.name .. " " .. rule.prelude .. " {\n" .. concat(inner_parts, "\n") .. "\n}")
      else
        insert(parts, "@" .. rule.name .. " " .. rule.prelude .. ";")
      end
    end
  end
  return concat(parts, "\n")
end

return M
