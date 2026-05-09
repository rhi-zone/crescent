if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- XPath 1.0 evaluator for lib/xml DOM nodes.
-- Pure Lua implementation — no external dependencies.
--
-- DOM conventions (from lib/xml):
--   document: { type="document", children={...}, parent=nil }
--   element:  { type="element",  tag="name", attrs={}, children={...}, parent=... }
--   text:     { type="text",     text="...", parent=... }
--   comment:  { type="comment",  text="...", parent=... }
--   cdata:    { type="cdata",    text="...", parent=... }

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Tokenizer
-- ---------------------------------------------------------------------------

-- Token types
local T_NAME     = "NAME"
local T_NUMBER   = "NUMBER"
local T_STRING   = "STRING"
local T_OP       = "OP"    -- single/multi-char operators and punctuation
local T_EOF      = "EOF"

--:: XPathToken = { type: string, value: string | number | nil }
--: (string) -> ({ [integer]: XPathToken } | nil, string | nil)
local function tokenize(src)
  local tokens = {} --: { [integer]: XPathToken }
  local pos = 1
  local len = #src
  while pos <= len do
    -- skip whitespace
    local ws = src:match("^%s+", pos)
    if ws then pos = pos + #ws end
    if pos > len then break end

    local c = src:sub(pos, pos)

    -- Numbers
    if c:match("%d") or (c == "." and src:sub(pos+1,pos+1):match("%d")) then
      local num = src:match("^%d+%.?%d*", pos) or src:match("^%.%d+", pos)
      tokens[#tokens+1] = { type = T_NUMBER, value = tonumber(num) }
      pos = pos + #num

    -- Strings
    elseif c == '"' or c == "'" then
      local q = c
      local s, e = src:find(q, pos+1, true)
      if not s then return nil, "unterminated string at " .. pos end
      tokens[#tokens+1] = { type = T_STRING, value = src:sub(pos+1, s-1) }
      pos = s + 1

    -- Multi-char operators
    elseif src:sub(pos, pos+1) == "//" then
      tokens[#tokens+1] = { type = T_OP, value = "//" }
      pos = pos + 2
    elseif src:sub(pos, pos+1) == "::" then
      tokens[#tokens+1] = { type = T_OP, value = "::" }
      pos = pos + 2
    elseif src:sub(pos, pos+1) == ".." then
      tokens[#tokens+1] = { type = T_OP, value = ".." }
      pos = pos + 2
    elseif src:sub(pos, pos+1) == "<=" then
      tokens[#tokens+1] = { type = T_OP, value = "<=" }
      pos = pos + 2
    elseif src:sub(pos, pos+1) == ">=" then
      tokens[#tokens+1] = { type = T_OP, value = ">=" }
      pos = pos + 2
    elseif src:sub(pos, pos+1) == "!=" then
      tokens[#tokens+1] = { type = T_OP, value = "!=" }
      pos = pos + 2

    -- Single-char operators/punctuation
    elseif c:match("[/%.%@%*%[%]%(%)%|%+%-%<%>%=,%!]") then
      tokens[#tokens+1] = { type = T_OP, value = c }
      pos = pos + 1

    -- Names (including axis names, function names, node types)
    elseif c:match("[%a_]") then
      local name = src:match("^[%w_:%-%.]+", pos)
      -- Split trailing :: later in parser; keep as name for now
      -- but don't consume the :: here
      -- Actually we need to consume the name only (no : consumed into name
      -- unless it's the full axis:: pattern handled by :: token above)
      -- Re-match: names may contain colons (ns:local) but :: is tokenized separately
      name = src:match("^[%w_%-]+", pos)
      tokens[#tokens+1] = { type = T_NAME, value = name }
      pos = pos + #(name --[[:! string]])

    else
      return nil, "unexpected character '" .. c .. "' at position " .. pos
    end
  end
  tokens[#tokens+1] = { type = T_EOF, value = nil }
  return tokens
end

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------
-- Builds an AST from token stream.
-- AST node types:
--   { kind="path", steps={...}, absolute=bool }
--   { kind="step", axis=string, test=..., predicates={...} }
--   { kind="union", left=..., right=... }
--   { kind="func", name=string, args={...} }
--   { kind="binop", op=string, left=..., right=... }
--   { kind="unop", op=string, operand=... }
--   { kind="literal", value=string|number }
--   { kind="number", value=number }

--:: Token = { type: string, value: any }
--:: AstNode = { kind: string, ... }
--:: Parser = { tokens: { [integer]: Token }, pos: integer, peek: (self: Parser) -> Token, consume: (self: Parser) -> Token, expect: (self: Parser, type_: string, value: any) -> any, match: (self: Parser, type_: string, value: any) -> Token | nil, parse_expr: (self: Parser) -> any, parse_or_expr: (self: Parser) -> any, parse_and_expr: (self: Parser) -> any, parse_equality_expr: (self: Parser) -> any, parse_relational_expr: (self: Parser) -> any, parse_additive_expr: (self: Parser) -> any, parse_multiplicative_expr: (self: Parser) -> any, parse_unary_expr: (self: Parser) -> any, parse_path_expr: (self: Parser) -> any, parse_primary_then_filter: (self: Parser) -> any, parse_primary_expr: (self: Parser) -> any, parse_function_call: (self: Parser) -> any, parse_location_path: (self: Parser) -> any, parse_relative_path_steps: (self: Parser, steps: any) -> any, parse_step: (self: Parser, steps: any) -> any, parse_node_test: (self: Parser) -> any, parse_predicates: (self: Parser, predicates: any) -> any, ... }

local Parser = {}
Parser.__index = Parser

--: (tokens: { [integer]: Token }) -> Parser
local function new_parser(tokens)
  return setmetatable({ tokens = tokens, pos = 1 }, Parser)
end

--: (self: Parser) -> Token
function Parser:peek()
  return self.tokens[self.pos]
end

--: (self: Parser) -> Token
function Parser:consume()
  local t = self.tokens[self.pos]
  self.pos = self.pos + 1
  return t
end

--: (self: Parser, type_: string, value: any) -> any
function Parser:expect(type_, value)
  local t = self:consume()
  if t.type ~= type_ or (value and t.value ~= value) then
    return nil, "expected " .. (value or type_) .. " but got " .. tostring(t.value)
  end
  return t
end

--: (self: Parser, type_: string, value: any) -> Token | nil
function Parser:match(type_, value)
  local t = self:peek()
  if t.type == type_ and (value == nil or t.value == value) then
    self.pos = self.pos + 1
    return t
  end
  return nil
end

-- expr = or_expr ('|' or_expr)*
--: (self: Parser) -> any
function Parser:parse_expr()
  local left, err = self:parse_or_expr()
  if not left then return nil, err end
  while self:peek().value == "|" do
    self:consume()
    local right
    right, err = self:parse_or_expr()
    if not right then return nil, err end
    left = { kind = "union", left = left, right = right }
  end
  return left
end

-- or_expr = and_expr ('or' and_expr)*
--: (self: Parser) -> any
function Parser:parse_or_expr()
  local left, err = self:parse_and_expr()
  if not left then return nil, err end
  while self:peek().type == T_NAME and self:peek().value == "or" do
    self:consume()
    local right
    right, err = self:parse_and_expr()
    if not right then return nil, err end
    left = { kind = "binop", op = "or", left = left, right = right }
  end
  return left
end

-- and_expr = equality_expr ('and' equality_expr)*
--: (self: Parser) -> any
function Parser:parse_and_expr()
  local left, err = self:parse_equality_expr()
  if not left then return nil, err end
  while self:peek().type == T_NAME and self:peek().value == "and" do
    self:consume()
    local right
    right, err = self:parse_equality_expr()
    if not right then return nil, err end
    left = { kind = "binop", op = "and", left = left, right = right }
  end
  return left
end

-- equality_expr = relational_expr (('='|'!=') relational_expr)*
--: (self: Parser) -> any
function Parser:parse_equality_expr()
  local left, err = self:parse_relational_expr()
  if not left then return nil, err end
  while true do
    local op = self:peek().value
    if op == "=" or op == "!=" then
      self:consume()
      local right
      right, err = self:parse_relational_expr()
      if not right then return nil, err end
      left = { kind = "binop", op = op, left = left, right = right }
    else
      break
    end
  end
  return left
end

-- relational_expr = additive_expr (('<'|'>'|'<='|'>=') additive_expr)*
--: (self: Parser) -> any
function Parser:parse_relational_expr()
  local left, err = self:parse_additive_expr()
  if not left then return nil, err end
  while true do
    local op = self:peek().value
    if op == "<" or op == ">" or op == "<=" or op == ">=" then
      self:consume()
      local right
      right, err = self:parse_additive_expr()
      if not right then return nil, err end
      left = { kind = "binop", op = op, left = left, right = right }
    else
      break
    end
  end
  return left
end

-- additive_expr = multiplicative_expr (('+' | '-') multiplicative_expr)*
--: (self: Parser) -> any
function Parser:parse_additive_expr()
  local left, err = self:parse_multiplicative_expr()
  if not left then return nil, err end
  while true do
    local op = self:peek().value
    if op == "+" or op == "-" then
      self:consume()
      local right
      right, err = self:parse_multiplicative_expr()
      if not right then return nil, err end
      left = { kind = "binop", op = op, left = left, right = right }
    else
      break
    end
  end
  return left
end

-- multiplicative_expr = unary_expr (('*' | 'div' | 'mod') unary_expr)*
--: (self: Parser) -> any
function Parser:parse_multiplicative_expr()
  local left, err = self:parse_unary_expr()
  if not left then return nil, err end
  while true do
    local t = self:peek()
    local op = t.value
    if op == "*" and t.type == T_OP then
      self:consume()
      local right
      right, err = self:parse_unary_expr()
      if not right then return nil, err end
      left = { kind = "binop", op = op, left = left, right = right }
    elseif t.type == T_NAME and (op == "div" or op == "mod") then
      self:consume()
      local right
      right, err = self:parse_unary_expr()
      if not right then return nil, err end
      left = { kind = "binop", op = op, left = left, right = right }
    else
      break
    end
  end
  return left
end

-- unary_expr = '-' unary_expr | union_expr
--: (self: Parser) -> any
function Parser:parse_unary_expr()
  if self:peek().value == "-" then
    self:consume()
    local operand, err = self:parse_unary_expr()
    if not operand then return nil, err end
    return { kind = "unop", op = "-", operand = operand }
  end
  return self:parse_path_expr()
end

-- path_expr = location_path | primary_expr ('/' relative_path | '//' relative_path)?
--: (self: Parser) -> any
function Parser:parse_path_expr()
  local t = self:peek()
  -- Absolute path starts with / or //
  if t.value == "/" or t.value == "//" then
    return self:parse_location_path()
  end
  -- Check if next token is a name followed by :: (axis) or name followed by (
  -- to determine if it's a step or a primary expr
  if t.type == T_NAME then
    local t2 = self.tokens[self.pos + 1]
    -- axis::
    if t2 and t2.value == "::" then
      return self:parse_location_path()
    end
    -- node type tests: text(), node(), comment(), processing-instruction()
    if (t.value == "text" or t.value == "node" or t.value == "comment" or
        t.value == "processing-instruction") and t2 and t2.value == "(" then
      return self:parse_location_path()
    end
    -- function call
    if t2 and t2.value == "(" then
      return self:parse_primary_then_filter()
    end
    -- bare name = location path step (e.g. "title" inside predicate)
    return self:parse_location_path()
  end
  if t.value == "@" or t.value == ".." then
    return self:parse_location_path()
  end
  if t.value == "." then
    -- could be . or ./... relative path
    local t2 = self.tokens[self.pos + 1]
    if t2 and (t2.value == "/" or t2.value == "//") then
      return self:parse_location_path()
    end
    return self:parse_location_path()
  end
  -- * = wildcard child step
  if t.value == "*" and t.type == T_OP then
    return self:parse_location_path()
  end
  return self:parse_primary_then_filter()
end

--: (self: Parser) -> any
function Parser:parse_primary_then_filter()
  local primary, err = self:parse_primary_expr()
  if not primary then return nil, err end
  -- filter expressions with predicates
  while self:peek().value == "[" do
    self:consume()
    local pred
    pred, err = self:parse_expr()
    if not pred then return nil, err end
    local _, e = self:expect(T_OP, "]")
    if e then return nil, e end
    primary = { kind = "filter", expr = primary, predicate = pred }
  end
  -- path continuation
  if self:peek().value == "/" or self:peek().value == "//" then
    local steps = {}
    local relative, rerr = self:parse_relative_path_steps(steps)
    if not relative then return nil, rerr end
    return { kind = "filter_path", filter = primary, steps = steps }
  end
  return primary
end

-- parse_primary_expr: number, string, (expr), or function call
--: (self: Parser) -> any
function Parser:parse_primary_expr()
  local t = self:peek()
  if t.type == T_NUMBER then
    self:consume()
    return { kind = "number", value = t.value }
  end
  if t.type == T_STRING then
    self:consume()
    return { kind = "literal", value = t.value }
  end
  if t.value == "(" then
    self:consume()
    local e, err = self:parse_expr()
    if not e then return nil, err end
    local _, ex = self:expect(T_OP, ")")
    if ex then return nil, ex end
    return e
  end
  if t.type == T_NAME then
    local t2 = self.tokens[self.pos + 1]
    if t2 and t2.value == "(" then
      return self:parse_function_call()
    end
  end
  return nil, "unexpected token '" .. tostring(t.value) .. "' in expression"
end

--: (self: Parser) -> any
function Parser:parse_function_call()
  local name_tok = self:consume() -- function name
  self:consume() -- '('
  local args = {}
  while self:peek().value ~= ")" and self:peek().type ~= T_EOF do
    if #args > 0 then
      local _, err = self:expect(T_OP, ",")
      if err then return nil, err end
    end
    local arg, err = self:parse_expr()
    if not arg then return nil, err end
    args[#args+1] = arg
  end
  local _, err = self:expect(T_OP, ")")
  if err then return nil, err end
  return { kind = "func", name = name_tok.value, args = args }
end

-- parse_location_path: absolute or relative
--: (self: Parser) -> any
function Parser:parse_location_path()
  local steps = {}
  local absolute = false

  if self:peek().value == "//" then
    self:consume()
    absolute = true
    -- // at start = /descendant-or-self::node()/
    steps[#steps+1] = { axis = "descendant-or-self", test = { kind = "node_type", name = "node" }, predicates = {} }
    -- must be followed by a relative step
    local ok, err = self:parse_step(steps)
    if not ok then return nil, err end
  elseif self:peek().value == "/" then
    self:consume()
    absolute = true
    -- / alone is valid (root)
    if self:peek().type == T_EOF or self:peek().value == "]" or self:peek().value == ")" or self:peek().value == "|" then
      return { kind = "path", steps = steps, absolute = true }
    end
    if self:peek().value == "/" then
      -- shouldn't happen since // is a single token
    end
    -- parse optional relative steps
    local ok, err = self:parse_step(steps)
    if not ok then return nil, err end
  else
    -- relative path
    local ok, err = self:parse_step(steps)
    if not ok then return nil, err end
  end

  -- continue: ('/' | '//') step ...
  local _, err = self:parse_relative_path_steps(steps)
  if err then return nil, err end

  return { kind = "path", steps = steps, absolute = absolute }
end

--: (self: Parser, steps: any) -> any
function Parser:parse_relative_path_steps(steps)
  while self:peek().value == "/" or self:peek().value == "//" do
    local sep = self:consume().value
    if sep == "//" then
      steps[#steps+1] = { axis = "descendant-or-self", test = { kind = "node_type", name = "node" }, predicates = {} }
    end
    if self:peek().type == T_EOF or self:peek().value == "]" or self:peek().value == ")" or self:peek().value == "|" then
      break
    end
    local ok, err = self:parse_step(steps)
    if not ok then return nil, err end
  end
  return true
end

-- parse a single step and append to steps
--: (self: Parser, steps: any) -> any
function Parser:parse_step(steps)
  local t = self:peek()

  -- '..'
  if t.value == ".." then
    self:consume()
    local step = { axis = "parent", test = { kind = "node_type", name = "node" }, predicates = {} }
    steps[#steps+1] = step
    return true
  end

  -- '.'
  if t.value == "." then
    self:consume()
    local step = { axis = "self", test = { kind = "node_type", name = "node" }, predicates = {} }
    steps[#steps+1] = step
    return true
  end

  -- '@' = attribute axis shorthand
  if t.value == "@" then
    self:consume()
    local test, err = self:parse_node_test()
    if not test then return nil, err end
    local step = { axis = "attribute", test = test, predicates = {} }
    local perr = self:parse_predicates(step.predicates)
    if perr then return nil, perr end
    steps[#steps+1] = step
    return true
  end

  -- Check for axis name followed by '::'
  if t.type == T_NAME then
    local t2 = self.tokens[self.pos + 1]
    if t2 and t2.value == "::" then
      local axis_name = t.value
      self:consume() -- axis name
      self:consume() -- ::
      local test, err = self:parse_node_test()
      if not test then return nil, err end
      local step = { axis = axis_name, test = test, predicates = {} }
      local perr = self:parse_predicates(step.predicates)
      if perr then return nil, perr end
      steps[#steps+1] = step
      return true
    end
    -- node type function: text(), node(), comment()
    local t3 = self.tokens[self.pos + 1]
    if (t.value == "text" or t.value == "node" or t.value == "comment" or
        t.value == "processing-instruction") and t3 and t3.value == "(" then
      local test, err = self:parse_node_test()
      if not test then return nil, err end
      local step = { axis = "child", test = test, predicates = {} }
      local perr = self:parse_predicates(step.predicates)
      if perr then return nil, perr end
      steps[#steps+1] = step
      return true
    end
  end

  -- Default: child axis
  local test, err = self:parse_node_test()
  if not test then return nil, err end
  local step = { axis = "child", test = test, predicates = {} }
  local perr = self:parse_predicates(step.predicates)
  if perr then return nil, perr end
  steps[#steps+1] = step
  return true
end

--: (self: Parser) -> any
function Parser:parse_node_test()
  local t = self:peek()

  -- '*' wildcard
  if t.value == "*" and t.type == T_OP then
    self:consume()
    return { kind = "wildcard" }
  end

  -- node type functions: text(), node(), comment(), processing-instruction()
  if t.type == T_NAME then
    local nt = t.value
    if nt == "text" or nt == "node" or nt == "comment" or nt == "processing-instruction" then
      local t2 = self.tokens[self.pos + 1]
      if t2 and t2.value == "(" then
        self:consume() -- name
        self:consume() -- (
        -- processing-instruction may have a string arg
        local arg = nil
        if self:peek().type == T_STRING then
          arg = self:consume().value
        end
        local _, err = self:expect(T_OP, ")")
        if err then return nil, err end
        return { kind = "node_type", name = nt, arg = arg }
      end
    end
    -- name test
    self:consume()
    return { kind = "name", name = t.value }
  end

  return nil, "expected node test, got '" .. tostring(t.value) .. "'"
end

--: (self: Parser, predicates: any) -> any
function Parser:parse_predicates(predicates)
  while self:peek().value == "[" do
    self:consume()
    local pred, err = self:parse_expr()
    if not pred then return err end
    local _, e = self:expect(T_OP, "]")
    if e then return e end
    predicates[#predicates+1] = pred
  end
  return nil
end

-- Parse an XPath expression, return AST or (nil, errmsg)
local function parse(src)
  local tokens, err = tokenize(src)
  if not tokens then return nil, err end
  local p = new_parser(tokens)
  local ast, perr = p:parse_expr()
  if not ast then return nil, perr end
  if p:peek().type ~= T_EOF then
    return nil, "unexpected token '" .. tostring(p:peek().value) .. "' after expression"
  end
  return ast
end

-- ---------------------------------------------------------------------------
-- Document-order index
-- ---------------------------------------------------------------------------
-- Assigns a numeric index to each node in pre-order for sorting/dedup.
local function build_doc_order(root)
  local order = {}
  local counter = 0
  local function walk(n)
    counter = counter + 1
    order[n] = counter
    if n.children then
      for i = 1, #n.children do
        walk(n.children[i])
      end
    end
  end
  -- Walk from doc root
  local doc = root
  while doc.parent do doc = doc.parent end
  walk(doc)
  return order
end

-- Sort node-set by document order (deduplicate too)
local function sort_nodeset(ns, order)
  -- dedup
  local seen = {}
  local result = {}
  for i = 1, #ns do
    local n = ns[i]
    if not seen[n] then
      seen[n] = true
      result[#result+1] = n
    end
  end
  table.sort(result, function(a, b)
    local oa = order[a] or 0
    local ob = order[b] or 0
    return oa < ob
  end)
  return result
end

-- ---------------------------------------------------------------------------
-- String value of a node
-- ---------------------------------------------------------------------------
local function string_value(node)
  if node.type == "attribute" then
    return node.value or ""
  elseif node.type == "text" or node.type == "cdata" then
    return node.text or ""
  elseif node.type == "element" or node.type == "document" then
    -- concatenate all descendant text
    local parts = {}
    local collect
    --: ({ type: string, text?: string, children?: { [integer]: unknown, ... }, ... }) -> nil
    collect = function(n)
      if n.type == "text" or n.type == "cdata" then
        parts[#parts+1] = n.text or ""
      elseif n.children then
        local ch = n.children --[[:! { [integer]: { type: string, text?: string, children?: { [integer]: unknown, ... }, ... }, ... }]]
        for i = 1, #ch do collect(ch[i]) end
      end
    end
    collect(node)
    return table.concat(parts)
  elseif node.type == "comment" or node.type == "processing_instruction" then
    return node.text or ""
  end
  return ""
end

-- ---------------------------------------------------------------------------
-- XPath value coercions
-- ---------------------------------------------------------------------------
--: (unknown) -> string
local function to_string(v)
  if type(v) == "table" then
    -- node-set: string value of first node in doc order, or ""
    local vt = v --[[:! { [integer]: unknown, ... }]]
    if #vt == 0 then return "" end
    return string_value(vt[1] --[[:! { type: string, ... }]])
  elseif type(v) == "boolean" then
    local vb = v --[[:! boolean]]
    return vb and "true" or "false"
  elseif type(v) == "number" then
    local vn = v --[[:! number]]
    if vn ~= vn then return "NaN" end
    if vn == math.huge then return "Infinity" end
    if vn == -math.huge then return "-Infinity" end
    -- XPath number formatting: no trailing .0 for integers
    if vn == math.floor(vn) and math.abs(vn) < 1e15 then
      return tostring(math.floor(vn))
    end
    return tostring(vn)
  else
    return tostring(v or "")
  end
end

--: (unknown) -> number
local function to_number(v)
  if type(v) == "number" then return v --[[:! number]] end
  if type(v) == "boolean" then return (v --[[:! boolean]]) and 1 or 0 end
  if type(v) == "table" then
    return tonumber(to_string(v)) or (0/0)
  end
  return tonumber(tostring(v)) or (0/0)
end

--: (unknown) -> boolean
local function to_boolean(v)
  if type(v) == "boolean" then return v --[[:! boolean]] end
  if type(v) == "number" then local vn = v --[[:! number]]; return (vn ~= 0 and vn == vn) --[[:! boolean]] end
  if type(v) == "table" then local vt = v --[[:! { [integer]: unknown, ... }]]; return #vt > 0 end
  return (v ~= nil and v ~= "") --[[:! boolean]]
end

-- ---------------------------------------------------------------------------
-- Axis traversal
-- ---------------------------------------------------------------------------

local function axis_child(ctx_node)
  if not ctx_node.children then return {} end
  local result = {}
  for i = 1, #ctx_node.children do
    result[#result+1] = ctx_node.children[i]
  end
  return result
end

local function axis_attribute(ctx_node)
  if ctx_node.type ~= "element" then return {} end
  local result = {}
  if ctx_node.attrs then
    for k, v in pairs(ctx_node.attrs) do
      -- synthesize attribute nodes
      result[#result+1] = { type = "attribute", name = k, value = v, parent = ctx_node }
    end
  end
  return result
end

local function axis_descendant(ctx_node, include_self)
  local result = {}
  local function walk(n)
    result[#result+1] = n
    if n.children then
      for i = 1, #n.children do walk(n.children[i]) end
    end
  end
  if include_self then
    walk(ctx_node)
  elseif ctx_node.children then
    for i = 1, #ctx_node.children do walk(ctx_node.children[i]) end
  end
  return result
end

local function axis_ancestor(ctx_node, include_self)
  local result = {}
  local n = include_self and ctx_node or ctx_node.parent
  while n do
    result[#result+1] = n
    n = n.parent
  end
  return result
end

local function axis_following_sibling(ctx_node)
  local parent = ctx_node.parent
  if not parent or not parent.children then return {} end
  local result = {}
  local found = false
  for i = 1, #parent.children do
    local c = parent.children[i]
    if found then result[#result+1] = c
    elseif c == ctx_node then found = true end
  end
  return result
end

local function axis_preceding_sibling(ctx_node)
  local parent = ctx_node.parent
  if not parent or not parent.children then return {} end
  local result = {}
  for i = 1, #parent.children do
    local c = parent.children[i]
    if c == ctx_node then break end
    result[#result+1] = c
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Node test matching
-- ---------------------------------------------------------------------------
local function matches_node_test(node, test, axis)
  if test.kind == "wildcard" then
    if axis == "attribute" then return node.type == "attribute" end
    return node.type == "element"
  elseif test.kind == "name" then
    if axis == "attribute" then
      return node.type == "attribute" and node.name == test.name
    end
    return node.type == "element" and node.tag == test.name
  elseif test.kind == "node_type" then
    local nt = test.name
    if nt == "node" then return true end
    if nt == "text" then return node.type == "text" or node.type == "cdata" end
    if nt == "comment" then return node.type == "comment" end
    if nt == "processing-instruction" then
      if node.type ~= "processing_instruction" then return false end
      if test.arg then return node.target == test.arg end
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

-- Context: { node, position, size, order, vars }
local eval_expr  -- forward declaration

local function eval_step_axis(axis, ctx_node)
  if axis == "child" then return axis_child(ctx_node)
  elseif axis == "attribute" then return axis_attribute(ctx_node)
  elseif axis == "descendant" then return axis_descendant(ctx_node, false)
  elseif axis == "descendant-or-self" then return axis_descendant(ctx_node, true)
  elseif axis == "ancestor" then return axis_ancestor(ctx_node, false)
  elseif axis == "ancestor-or-self" then return axis_ancestor(ctx_node, true)
  elseif axis == "parent" then
    if ctx_node.parent then return { ctx_node.parent } else return {} end
  elseif axis == "self" then return { ctx_node }
  elseif axis == "following-sibling" then return axis_following_sibling(ctx_node)
  elseif axis == "preceding-sibling" then return axis_preceding_sibling(ctx_node)
  elseif axis == "following" then
    -- all nodes after ctx_node in doc order that are not ancestors
    local root = ctx_node
    while root.parent do root = root.parent end
    local all = axis_descendant(root, true)
    local order = {}
    for i = 1, #all do order[all[i]] = i end
    local ctx_ord = order[ctx_node] or 0
    local ancs = {}
    local n = ctx_node
    while n do ancs[n] = true; n = n.parent end
    local result = {}
    for i = 1, #all do
      if order[all[i]] > ctx_ord and not ancs[all[i]] then
        result[#result+1] = all[i]
      end
    end
    return result
  elseif axis == "preceding" then
    local root = ctx_node
    while root.parent do root = root.parent end
    local all = axis_descendant(root, true)
    local order = {}
    for i = 1, #all do order[all[i]] = i end
    local ctx_ord = order[ctx_node] or 0
    local ancs = {}
    local n = ctx_node
    while n do ancs[n] = true; n = n.parent end
    local result = {}
    for i = 1, #all do
      if order[all[i]] < ctx_ord and not ancs[all[i]] then
        result[#result+1] = all[i]
      end
    end
    return result
  end
  return {}
end

local function eval_predicate(pred_node, nodes, ctx)
  -- Apply predicate to a node-set, return filtered list
  local result = {}
  local size = #nodes
  for i = 1, size do
    local n = nodes[i]
    local pred_ctx = { node = n, position = i, size = size, order = ctx.order }
    local v = eval_expr(pred_node, pred_ctx)
    local keep
    if type(v) == "number" then
      keep = (i == v)
    else
      keep = to_boolean(v)
    end
    if keep then result[#result+1] = n end
  end
  return result
end

--: (AstNode, { node: { parent: unknown, ... }, position: integer, size: integer, order: unknown, ... }) -> { [integer]: { parent: unknown, ... }, ... }
local function eval_path(ast, ctx)
  local steps = ast.steps --[[:! { [integer]: { axis: string, test: { kind: string, ... }, predicates: { [integer]: AstNode, ... } }, ... }]]
  local current = {} --: { [integer]: { parent: unknown, ... }, ... }

  if ast.absolute then
    -- Start from document root
    local root = ctx.node
    while root.parent do root = root.parent end
    current = { root }
  else
    current = { ctx.node }
  end

  for si = 1, #steps do
    local step = steps[si]
    local axis = step.axis
    local test = step.test
    local predicates = step.predicates

    local next_nodes = {} --: { [integer]: { parent: unknown, ... }, ... }
    for ni = 1, #current do
      local candidates = eval_step_axis(axis, current[ni]) --[[:! { [integer]: unknown, ... }]]
      for ci = 1, #candidates do
        local c = candidates[ci] --[[:! { parent: unknown, ... }]]
        if matches_node_test(c, test, axis) then
          next_nodes[#next_nodes+1] = c
        end
      end
    end

    -- Apply predicates
    for pi = 1, #predicates do
      next_nodes = eval_predicate(predicates[pi], next_nodes, ctx)
    end

    current = next_nodes
  end

  -- Sort and dedup by document order
  if ctx.order then
    current = sort_nodeset(current, ctx.order)
  end
  return current
end

-- XPath built-in functions
--:: XPathFn = (args: { [integer]: unknown, ... }, ctx: { node: unknown, position: integer, size: integer, order: unknown, ... }) -> unknown
local FUNCTIONS = {}

FUNCTIONS["count"] = function(args, ctx)
  local ns = eval_expr(args[1], ctx)
  if type(ns) ~= "table" then return 0 end
  return #ns
end

FUNCTIONS["last"] = function(_args, ctx)
  return ctx.size or 1
end

FUNCTIONS["position"] = function(_args, ctx)
  return ctx.position or 1
end

FUNCTIONS["string"] = function(args, ctx)
  if #args == 0 then return string_value(ctx.node) end
  return to_string(eval_expr(args[1], ctx))
end

FUNCTIONS["number"] = function(args, ctx)
  if #args == 0 then return to_number(string_value(ctx.node)) end
  return to_number(eval_expr(args[1], ctx))
end

FUNCTIONS["boolean"] = function(args, ctx)
  return to_boolean(eval_expr(args[1], ctx))
end

FUNCTIONS["not"] = function(args, ctx)
  return not to_boolean(eval_expr(args[1], ctx))
end

FUNCTIONS["true"] = function(_args, _ctx)
  return true
end

FUNCTIONS["false"] = function(_args, _ctx)
  return false
end

FUNCTIONS["contains"] = function(args, ctx)
  local s = to_string(eval_expr(args[1], ctx))
  local sub = to_string(eval_expr(args[2], ctx))
  return s:find(sub, 1, true) ~= nil
end

FUNCTIONS["starts-with"] = function(args, ctx)
  local s = to_string(eval_expr(args[1], ctx))
  local prefix = to_string(eval_expr(args[2], ctx))
  return s:sub(1, #prefix) == prefix
end

FUNCTIONS["ends-with"] = function(args, ctx)
  local s = to_string(eval_expr(args[1], ctx))
  local suffix = to_string(eval_expr(args[2], ctx))
  if #suffix == 0 then return true end
  return s:sub(- #suffix) == suffix
end

FUNCTIONS["string-length"] = function(args, ctx)
  local s
  if #args == 0 then s = string_value(ctx.node)
  else s = to_string(eval_expr(args[1], ctx)) end
  return #s
end

FUNCTIONS["normalize-space"] = function(args, ctx)
  local raw = (#args == 0) and string_value(ctx.node) or to_string(eval_expr(args[1], ctx)) --: string
  local trimmed = raw:match("^%s*(.-)%s*$") --[[:! string]]
  return trimmed:gsub("%s+", " ")
end

FUNCTIONS["translate"] = function(args, ctx)
  local s    = to_string(eval_expr(args[1], ctx))
  local from = to_string(eval_expr(args[2], ctx))
  local to   = to_string(eval_expr(args[3], ctx))
  local result = {}
  for i = 1, #s do
    local c = s:sub(i, i)
    local idx = from:find(c, 1, true)
    if idx then
      local repl = to:sub(idx, idx)
      if repl ~= "" then result[#result+1] = repl end
    else
      result[#result+1] = c
    end
  end
  return table.concat(result)
end

FUNCTIONS["substring"] = function(args, ctx)
  local s   = to_string(eval_expr(args[1], ctx))
  local pos2 = math.floor(to_number(eval_expr(args[2], ctx)) + 0.5) --[[:! integer]]
  local len_arg = args[3] and math.floor(to_number(eval_expr(args[3], ctx)) + 0.5)
  -- XPath 1-indexed
  local start = pos2 --: integer
  local finish = (len_arg and (start + (len_arg --[[:! integer]]) - 1) or #s) --[[:! integer]]
  if start < 1 then start = 1 end
  return s:sub(start, finish)
end

FUNCTIONS["concat"] = function(args, ctx)
  local parts = {}
  for i = 1, #args do
    parts[#parts+1] = to_string(eval_expr(args[i], ctx))
  end
  return table.concat(parts)
end

FUNCTIONS["name"] = function(args, ctx)
  local n = #args > 0 and eval_expr(args[1], ctx) or ctx.node
  if type(n) == "table" and n[1] then n = n[1] end
  if type(n) == "table" then
    if n.type == "element" then return n.tag or "" end
    if n.type == "attribute" then return n.name or "" end
  end
  return ""
end

FUNCTIONS["local-name"] = function(args, ctx)
  local n = #args > 0 and eval_expr(args[1], ctx) or ctx.node
  if type(n) == "table" and n[1] then n = n[1] end
  if type(n) == "table" then
    if n.type == "element" then
      local tag = n.tag or ""
      return tag:match(":(.+)$") or tag
    end
    if n.type == "attribute" then
      local nm = n.name or ""
      return nm:match(":(.+)$") or nm
    end
  end
  return ""
end

FUNCTIONS["sum"] = function(args, ctx)
  local ns = eval_expr(args[1], ctx)
  if type(ns) ~= "table" then return to_number(ns) end
  local total = 0 --: number
  for i = 1, #ns do total = total + to_number(string_value(ns[i])) end
  return total
end

FUNCTIONS["floor"] = function(args, ctx)
  return math.floor(to_number(eval_expr(args[1], ctx)))
end

FUNCTIONS["ceiling"] = function(args, ctx)
  return math.ceil(to_number(eval_expr(args[1], ctx)))
end

FUNCTIONS["round"] = function(args, ctx)
  local n = to_number(eval_expr(args[1], ctx))
  return math.floor(n + 0.5)
end

-- Evaluate an AST node in a context
eval_expr = function(ast, ctx)
  if ast.kind == "number" then
    return ast.value
  elseif ast.kind == "literal" then
    return ast.value
  elseif ast.kind == "path" then
    return eval_path(ast, ctx)
  elseif ast.kind == "union" then
    local left = eval_expr(ast.left, ctx)
    local right = eval_expr(ast.right, ctx)
    local merged = {} --: { [integer]: { parent: unknown, ... }, ... }
    if type(left) == "table" then for i=1,#left do merged[#merged+1]=left[i] end end
    if type(right) == "table" then for i=1,#right do merged[#merged+1]=right[i] end end
    if ctx.order then merged = sort_nodeset(merged, ctx.order) end
    return merged
  elseif ast.kind == "func" then
    local fn = FUNCTIONS[ast.name --[[:! string]]] --[[:! XPathFn | nil]]
    if not fn then
      -- return nil/error representation as empty string
      return ""
    end
    return fn(ast.args --[[:! { [integer]: unknown, ... }]], ctx)
  elseif ast.kind == "filter" then
    local base = eval_expr(ast.filter, ctx)
    if type(base) ~= "table" then return base end
    return eval_predicate(ast.predicate --[[:! AstNode]], base, ctx)
  elseif ast.kind == "filter_path" then
    local base = eval_expr(ast.filter, ctx)
    if type(base) ~= "table" then return {} end
    -- evaluate path steps relative to each node in base
    local result = {} --: { [integer]: { parent: unknown, ... }, ... }
    for i = 1, #base do
      local sub_ctx = { node = base[i], position = i, size = #base, order = ctx.order }
      local step_ast = { kind = "path", steps = ast.steps, absolute = false }
      local sub = eval_path(step_ast, sub_ctx)
      for j = 1, #sub do result[#result+1] = sub[j] end
    end
    if ctx.order then result = sort_nodeset(result, ctx.order) end
    return result
  elseif ast.kind == "binop" then
    local op = ast.op
    if op == "or" then
      return to_boolean(eval_expr(ast.left, ctx)) or to_boolean(eval_expr(ast.right, ctx))
    elseif op == "and" then
      return to_boolean(eval_expr(ast.left, ctx)) and to_boolean(eval_expr(ast.right, ctx))
    end
    local lv = eval_expr(ast.left, ctx)
    local rv = eval_expr(ast.right, ctx)
    if op == "=" then
      -- node-set comparisons
      if type(lv) == "table" and type(rv) == "table" then
        for _, ln in ipairs(lv) do
          for _, rn in ipairs(rv) do
            if string_value(ln) == string_value(rn) then return true end
          end
        end
        return false
      elseif type(lv) == "table" then
        local rs = to_string(rv)
        for _, n in ipairs(lv) do
          if string_value(n) == rs then return true end
        end
        return false
      elseif type(rv) == "table" then
        local ls = to_string(lv)
        for _, n in ipairs(rv) do
          if string_value(n) == ls then return true end
        end
        return false
      end
      return to_string(lv) == to_string(rv)
    elseif op == "!=" then
      if type(lv) == "table" and type(rv) == "table" then
        for _, ln in ipairs(lv) do
          for _, rn in ipairs(rv) do
            if string_value(ln) ~= string_value(rn) then return true end
          end
        end
        return false
      elseif type(lv) == "table" then
        local rs = to_string(rv)
        for _, n in ipairs(lv) do
          if string_value(n) ~= rs then return true end
        end
        return false
      elseif type(rv) == "table" then
        local ls = to_string(lv)
        for _, n in ipairs(rv) do
          if string_value(n) ~= ls then return true end
        end
        return false
      end
      return to_string(lv) ~= to_string(rv)
    elseif op == "<" then return to_number(lv) < to_number(rv)
    elseif op == ">" then return to_number(lv) > to_number(rv)
    elseif op == "<=" then return to_number(lv) <= to_number(rv)
    elseif op == ">=" then return to_number(lv) >= to_number(rv)
    elseif op == "+" then return to_number(lv) + to_number(rv)
    elseif op == "-" then return to_number(lv) - to_number(rv)
    elseif op == "*" then return to_number(lv) * to_number(rv)
    elseif op == "div" then return to_number(lv) / to_number(rv)
    elseif op == "mod" then return to_number(lv) % to_number(rv)
    end
  elseif ast.kind == "unop" then
    if ast.op == "-" then return -to_number(eval_expr(ast.operand, ctx)) end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Evaluate an XPath expression against a context node.
--- Returns XPath value (node-set table, string, number, or boolean), or (nil, errmsg).
--: ({ ... }, string) -> (unknown | nil, string)
function M.eval(node, expr)
  local ast, err = parse(expr)
  if not ast then return nil, err end
  local order = build_doc_order(node)
  local ctx = { node = node, position = 1, size = 1, order = order }
  local ok, result = pcall(eval_expr, ast, ctx)
  if not ok then return nil, tostring(result) end
  return result
end

--- Alias for eval — returns a node-set.
--: ({ ... }, string) -> ({ ... } | nil, string)
function M.select(node, expr)
  local result, err = M.eval(node, expr)
  if result == nil then return nil, err end
  if type(result) ~= "table" then return {} end
  return result
end

--- Return the first matching node, or nil.
--: ({ ... }, string) -> { ... } | nil
function M.first(node, expr)
  local result = M.eval(node, expr)
  if type(result) == "table" then return result[1] end
  return nil
end

--- Return the string value of an XPath expression.
--: ({ ... }, string) -> string
function M.string(node, expr)
  local result, _ = M.eval(node, expr)
  return to_string(result)
end

--- Return the numeric value of an XPath expression.
--: ({ ... }, string) -> number
function M.number(node, expr)
  local result, _ = M.eval(node, expr)
  return to_number(result)
end

--- Return the boolean value of an XPath expression.
--: ({ ... }, string) -> boolean
function M.boolean(node, expr)
  local result, _ = M.eval(node, expr)
  return to_boolean(result)
end

--- Compile an XPath expression for reuse.
--- Returns compiled object with :eval(node) method, or (nil, errmsg).
--: (string) -> ({ ... } | nil, string)
function M.compile(expr)
  local ast, err = parse(expr)
  if not ast then return nil, err end
  local compiled = {}
  function compiled:eval(node)
    local order = build_doc_order(node)
    local ctx = { node = node, position = 1, size = 1, order = order }
    local ok, result = pcall(eval_expr, ast, ctx)
    if not ok then return nil, tostring(result) end
    return result
  end
  return compiled
end

return M
