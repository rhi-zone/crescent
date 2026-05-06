-- lib/spreadsheet/init.lua
-- Spreadsheet grid with formula evaluation, dependency tracking, and auto-recalculation.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Error sentinel values
-- ---------------------------------------------------------------------------

local ERR_DIV0   = "#DIV/0!"
local ERR_REF    = "#REF!"
local ERR_NAME   = "#NAME?"
local ERR_VALUE  = "#VALUE!"
local ERR_CIRC   = "#CIRC!"
local ERR_NA     = "#N/A"

local function is_error(v)
  return type(v) == "string" and v:sub(1,1) == "#"
end

-- ---------------------------------------------------------------------------
-- Cell reference parsing
-- ---------------------------------------------------------------------------

-- Parse a cell reference like "A1", "$A$1", "$A1", "A$1"
-- Returns col_letter (uppercase), row_num (integer), abs_col (bool), abs_row (bool)
local function parse_cell_ref(s)
  local abs_col, col_str, abs_row, row_str =
    s:match("^(%$?)([A-Za-z]+)(%$?)(%d+)$")
  if not col_str then return nil end
  return col_str:upper(), tonumber(row_str), abs_col == "$", abs_row == "$"
end

-- Convert column letter(s) to 1-based integer (A=1, Z=26, AA=27, ...)
local function col_to_num(col_str)
  local n = 0
  for i = 1, #col_str do
    n = n * 26 + (col_str:byte(i) - 64) -- 'A' is 65, so -64 gives 1
  end
  return n
end

-- Convert 1-based column number to letter(s)
local function num_to_col(n)
  local s = ""
  while n > 0 do
    local r = (n - 1) % 26
    s = string.char(65 + r) .. s
    n = math.floor((n - 1) / 26)
  end
  return s
end

-- Canonical cell key: "A1" style (uppercase col, row as string)
--: (string, integer) -> string
local function cell_key(col_str, row_num)
  return col_str:upper() .. tostring(row_num)
end

-- Parse a ref string into {col (1-based num), row (1-based num), abs_col, abs_row}
-- Returns nil if invalid
local function parse_ref(s)
  local col_str, row_num, abs_col, abs_row = parse_cell_ref(s)
  if not col_str then return nil end
  local col_num = col_to_num(col_str)
  return { col = col_num, row = row_num, abs_col = abs_col, abs_row = abs_row,
           col_str = col_str }
end

-- Parse a range like "A1:B3" → {r1, c1, r2, c2} (1-based)
local function parse_range(s)
  local a, b = s:match("^([^:]+):([^:]+)$")
  if not a then return nil end
  local ra = parse_ref(a)
  local rb = parse_ref(b)
  if not ra or not rb then return nil end
  local r1 = math.min(ra.row, rb.row)
  local r2 = math.max(ra.row, rb.row)
  local c1 = math.min(ra.col, rb.col)
  local c2 = math.max(ra.col, rb.col)
  return { r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
end

-- ---------------------------------------------------------------------------
-- Lexer
-- ---------------------------------------------------------------------------

local TK = {
  NUM    = "NUM",
  STR    = "STR",
  REF    = "REF",     -- cell ref or range
  NAME   = "NAME",    -- function name / identifier
  OP     = "OP",
  LPAREN = "LPAREN",
  RPAREN = "RPAREN",
  COMMA  = "COMMA",
  COLON  = "COLON",
  EOF    = "EOF",
}

--:: SpreadToken = { type: string, value?: any, is_range?: boolean, ... }
--:: SpreadNode = { type: string, op?: string, value?: any, left?: SpreadNode, right?: SpreadNode, operand?: SpreadNode, name?: string, args?: { [integer]: SpreadNode }, ... }
--:: ParserState = { tokens: { [integer]: SpreadToken }, pos: integer, peek: (ParserState) -> SpreadToken, consume: (ParserState) -> SpreadToken, expect: (ParserState, string) -> SpreadToken, expr: (ParserState) -> SpreadNode, comparison: (ParserState) -> SpreadNode, concat: (ParserState) -> SpreadNode, additive: (ParserState) -> SpreadNode, multiplicative: (ParserState) -> SpreadNode, power: (ParserState) -> SpreadNode, unary: (ParserState) -> SpreadNode, primary: (ParserState) -> SpreadNode }

--: (string) -> { [integer]: SpreadToken }
local function lex(src)
  --: { [integer]: SpreadToken }
  local tokens = {}
  --: integer
  local i = 1
  local n = #src

  local function peek() return src:sub(i, i) --[[:! string]] end
  local function advance() i = i + 1 end
  local function cur() return src:sub(i, i) --[[:! string]] end

  while i <= n do
    local c = cur()
    -- Skip whitespace
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      advance()
    -- String literal
    elseif c == '"' then
      advance()
      local start = i
      while i <= n and cur() ~= '"' do
        advance()
      end
      local s = src:sub(start, i - 1)
      advance() -- consume closing "
      tokens[#tokens+1] = { type = TK.STR, value = s }
    -- Number
    elseif c:match("%d") or (c == "-" and i < n and src:sub(i+1,i+1):match("%d") and #tokens == 0) then
      local start = i
      if c == "-" then advance() end
      while i <= n and cur():match("[%d%.eE%+%-]") do
        -- be careful: stop at operators that aren't part of number
        local nc = cur()
        if (nc == "+" or nc == "-") and i > start+1 then
          local prev = src:sub(i-1,i-1):lower()
          if prev ~= "e" then break end
        end
        advance()
      end
      local numstr = src:sub(start, i-1)
      tokens[#tokens+1] = { type = TK.NUM, value = tonumber(numstr) }
    -- Operators (two-char first)
    elseif c == "<" or c == ">" or c == "!" then
      local two = src:sub(i, i+1)
      if two == "<=" or two == ">=" or two == "<>" then
        tokens[#tokens+1] = { type = TK.OP, value = two }
        i = i + 2
      else
        tokens[#tokens+1] = { type = TK.OP, value = c }
        advance()
      end
    elseif c == "=" then
      tokens[#tokens+1] = { type = TK.OP, value = "=" }
      advance()
    elseif c == "+" or c == "-" or c == "*" or c == "/" or c == "^" or c == "&" then
      tokens[#tokens+1] = { type = TK.OP, value = c }
      advance()
    elseif c == "(" then
      tokens[#tokens+1] = { type = TK.LPAREN }
      advance()
    elseif c == ")" then
      tokens[#tokens+1] = { type = TK.RPAREN }
      advance()
    elseif c == "," then
      tokens[#tokens+1] = { type = TK.COMMA }
      advance()
    elseif c == ":" then
      tokens[#tokens+1] = { type = TK.COLON }
      advance()
    -- Cell ref or function name: starts with $ or letter
    elseif c == "$" or c:match("[A-Za-z]") then
      local start = i
      -- collect $? letters $? digits pattern
      if cur() == "$" then advance() end
      while i <= n and cur():match("[A-Za-z]") do advance() end
      if cur() == "$" then advance() end
      local has_digit = cur():match("%d")
      while i <= n and cur():match("%d") do advance() end
      local word = src:sub(start, i-1)
      -- Check if it looks like a cell ref
      if has_digit then
        -- Could be a cell ref; check for range colon after
        if i <= n and cur() == ":" then
          -- peek ahead to see if followed by another ref
          local j = i + 1
          if j <= n and (src:sub(j,j) == "$" or src:sub(j,j):match("[A-Za-z]")) then
            -- consume range
            j = j + 0
            if src:sub(j,j) == "$" then j = j + 1 end
            while j <= n and src:sub(j,j):match("[A-Za-z]") do j = j + 1 end
            if src:sub(j,j) == "$" then j = j + 1 end
            while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
            local range_str = src:sub(start, j-1)
            tokens[#tokens+1] = { type = TK.REF, value = range_str, is_range = true }
            i = j
          else
            tokens[#tokens+1] = { type = TK.REF, value = word, is_range = false }
          end
        else
          tokens[#tokens+1] = { type = TK.REF, value = word, is_range = false }
        end
      else
        -- It's a function name / keyword
        tokens[#tokens+1] = { type = TK.NAME, value = word:upper() }
      end
    else
      -- unknown char, skip
      advance()
    end
  end
  tokens[#tokens+1] = { type = TK.EOF }
  return tokens
end

-- ---------------------------------------------------------------------------
-- Parser → AST
-- ---------------------------------------------------------------------------

-- Node types
local NT = {
  NUM    = "NUM",
  STR    = "STR",
  REF    = "REF",
  RANGE  = "RANGE",
  BINOP  = "BINOP",
  UNOP   = "UNOP",
  CALL   = "CALL",
}

--: ({ [integer]: SpreadToken }) -> ParserState
local function Parser(tokens)
  local p = { tokens = tokens, pos = 1 } --[[: any]]

  --: (ParserState) -> SpreadToken
  function p:peek()
    return self.tokens[self.pos]
  end

  --: (ParserState) -> SpreadToken
  function p:consume()
    local t = self.tokens[self.pos]
    self.pos = self.pos + 1
    return t
  end

  --: (ParserState, string) -> SpreadToken
  function p:expect(typ)
    local t = self:consume()
    if t.type ~= typ then
      error("expected " .. typ .. " got " .. t.type)
    end
    return t
  end

  -- expr → comparison
  --: (ParserState) -> SpreadNode
  function p:expr()
    return self:comparison()
  end

  -- comparison → concat ((<|>|<=|>=|=|<>) concat)*
  --: (ParserState) -> SpreadNode
  function p:comparison()
    local left = self:concat()
    local tk = self:peek()
    while tk.type == TK.OP and
          (tk.value == "<" or tk.value == ">" or tk.value == "<=" or
           tk.value == ">=" or tk.value == "=" or tk.value == "<>") do
      self:consume()
      local right = self:concat()
      left = { type = NT.BINOP, op = (tk.value --[[:! string]]), left = left, right = right }
      tk = self:peek()
    end
    return left
  end

  -- concat → additive (& additive)*
  --: (ParserState) -> SpreadNode
  function p:concat()
    local left = self:additive()
    while self:peek().type == TK.OP and self:peek().value == "&" do
      self:consume()
      local right = self:additive()
      left = { type = NT.BINOP, op = "&", left = left, right = right }
    end
    return left
  end

  -- additive → multiplicative ((+|-) multiplicative)*
  --: (ParserState) -> SpreadNode
  function p:additive()
    local left = self:multiplicative()
    local tk = self:peek()
    while tk.type == TK.OP and (tk.value == "+" or tk.value == "-") do
      self:consume()
      local right = self:multiplicative()
      left = { type = NT.BINOP, op = (tk.value --[[:! string]]), left = left, right = right }
      tk = self:peek()
    end
    return left
  end

  -- multiplicative → power ((*|/) power)*
  --: (ParserState) -> SpreadNode
  function p:multiplicative()
    local left = self:power()
    local tk = self:peek()
    while tk.type == TK.OP and (tk.value == "*" or tk.value == "/") do
      self:consume()
      local right = self:power()
      left = { type = NT.BINOP, op = (tk.value --[[:! string]]), left = left, right = right }
      tk = self:peek()
    end
    return left
  end

  -- power → unary (^ unary)*  (right-assoc)
  --: (ParserState) -> SpreadNode
  function p:power()
    local base = self:unary()
    if self:peek().type == TK.OP and self:peek().value == "^" then
      self:consume()
      local exp = self:power() -- right-recursive
      return { type = NT.BINOP, op = "^", left = base, right = exp }
    end
    return base
  end

  -- unary → -? primary
  --: (ParserState) -> SpreadNode
  function p:unary()
    if self:peek().type == TK.OP and self:peek().value == "-" then
      self:consume()
      local operand = self:primary()
      return { type = NT.UNOP, op = "-", operand = operand }
    end
    return self:primary()
  end

  -- primary → NUM | STR | REF(range) | NAME(args) | ( expr )
  --: (ParserState) -> SpreadNode
  function p:primary()
    local tk = self:peek()
    if tk.type == TK.NUM then
      self:consume()
      return { type = NT.NUM, value = tk.value }
    elseif tk.type == TK.STR then
      self:consume()
      return { type = NT.STR, value = tk.value }
    elseif tk.type == TK.REF then
      self:consume()
      if tk.is_range then
        return { type = NT.RANGE, value = tk.value }
      else
        return { type = NT.REF, value = tk.value }
      end
    elseif tk.type == TK.NAME then
      -- Could be TRUE/FALSE literals or a function call
      self:consume()
      if tk.value == "TRUE" then
        return { type = NT.NUM, value = true }
      elseif tk.value == "FALSE" then
        return { type = NT.NUM, value = false }
      end
      -- function call
      self:expect(TK.LPAREN)
      local args = {}
      if self:peek().type ~= TK.RPAREN then
        args[#args+1] = self:expr()
        while self:peek().type == TK.COMMA do
          self:consume()
          args[#args+1] = self:expr()
        end
      end
      self:expect(TK.RPAREN)
      return { type = NT.CALL, name = tk.value, args = args }
    elseif tk.type == TK.LPAREN then
      self:consume()
      local e = self:expr()
      self:expect(TK.RPAREN)
      return e
    else
      error("unexpected token: " .. tk.type .. " " .. tostring(tk.value))
    end
  end

  return p --[[:! ParserState]]
end

local function parse_formula(src)
  -- src should not include leading "="
  local tokens = lex(src)
  local p = Parser(tokens)
  local ast = p:expr()
  return ast
end

-- ---------------------------------------------------------------------------
-- Built-in functions
-- ---------------------------------------------------------------------------

--: (any) -> (number | nil, string | nil)
local function num_coerce(v)
  if type(v) == "number" then return v end
  if type(v) == "boolean" then return v and 1 or 0 end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
    return nil, ERR_VALUE
  end
  return nil, ERR_VALUE
end

-- Flatten a mix of values and arrays (from range evaluation)
local function flatten(args)
  local out = {}
  for _, a in ipairs(args) do
    if type(a) == "table" and a.__range then
      for _, v in ipairs(a.values) do
        out[#out+1] = v
      end
    else
      out[#out+1] = a
    end
  end
  return out
end

local BUILTINS = {}

BUILTINS.SUM = function(args)
  local vals = flatten(args)
  local s = 0 --: number
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "number" then s = s + v
    elseif type(v) == "boolean" then s = s + (v and 1 or 0)
    end
    -- strings in ranges are ignored for SUM (like Excel)
  end
  return s
end

BUILTINS.AVERAGE = function(args)
  local vals = flatten(args)
  local s = 0 --: number
  local cnt = 0 --: number
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "number" then s = s + v; cnt = cnt + 1
    elseif type(v) == "boolean" then s = s + (v and 1 or 0); cnt = cnt + 1
    end
  end
  if cnt == 0 then return ERR_DIV0 end
  return s / cnt
end

BUILTINS.MIN = function(args)
  local vals = flatten(args)
  local m = nil
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "number" then
      if m == nil or v < m then m = v end
    end
  end
  if m == nil then return 0 end
  return m
end

BUILTINS.MAX = function(args)
  local vals = flatten(args)
  local m = nil
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "number" then
      if m == nil or v > m then m = v end
    end
  end
  if m == nil then return 0 end
  return m
end

BUILTINS.COUNT = function(args)
  local vals = flatten(args)
  local cnt = 0
  for _, v in ipairs(vals) do
    if type(v) == "number" then cnt = cnt + 1 end
  end
  return cnt
end

BUILTINS.COUNTA = function(args)
  local vals = flatten(args)
  local cnt = 0
  for _, v in ipairs(vals) do
    if v ~= nil and v ~= "" then cnt = cnt + 1 end
  end
  return cnt
end

BUILTINS.ABS = function(args)
  if #args ~= 1 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return v end
  local n, e = num_coerce(v)
  if e then return e end
  local n_ = n --[[:! number]]
  return math.abs(n_)
end

BUILTINS.ROUND = function(args)
  if #args < 1 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return v end
  local n, e = num_coerce(v)
  if e then return e end
  local n_ = n --[[:! number]]
  local digits = 0
  if args[2] ~= nil then
    local d, de = num_coerce(args[2])
    if de then return de end
    digits = math.floor(d --[[:! number]])
  end
  local factor = 10 ^ digits
  return math.floor(n_ * factor + 0.5) / factor
end

BUILTINS.FLOOR = function(args)
  if #args < 1 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return v end
  local n, e = num_coerce(v)
  if e then return e end
  return math.floor(n --[[:! number]])
end

BUILTINS.CEILING = function(args)
  if #args < 1 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return v end
  local n, e = num_coerce(v)
  if e then return e end
  return math.ceil(n --[[:! number]])
end

BUILTINS.MOD = function(args)
  if #args ~= 2 then return ERR_VALUE end
  local a, ea = num_coerce(args[1])
  if ea then return ea end
  local a_ = a --[[:! number]]
  local b, eb = num_coerce(args[2])
  if eb then return eb end
  local b_ = b --[[:! number]]
  if b_ == 0 then return ERR_DIV0 end
  return a_ % b_
end

BUILTINS.POWER = function(args)
  if #args ~= 2 then return ERR_VALUE end
  local a, ea = num_coerce(args[1])
  if ea then return ea end
  local b, eb = num_coerce(args[2])
  if eb then return eb end
  return (a --[[:! number]]) ^ (b --[[:! number]])
end

BUILTINS.SQRT = function(args)
  if #args ~= 1 then return ERR_VALUE end
  local n, e = num_coerce(args[1])
  if e then return e end
  local n_ = n --[[:! number]]
  if n_ < 0 then return ERR_VALUE end
  return math.sqrt(n_)
end

BUILTINS.LOG = function(args)
  if #args < 1 then return ERR_VALUE end
  local n, e = num_coerce(args[1])
  if e then return e end
  local n_ = n --[[:! number]]
  if n_ <= 0 then return ERR_VALUE end
  if args[2] ~= nil then
    local b, be = num_coerce(args[2])
    if be then return be end
    return math.log(n_) / math.log(b --[[:! number]])
  end
  return math.log(n_) / math.log(10)
end

BUILTINS.IF = function(args)
  if #args < 2 then return ERR_VALUE end
  local cond = args[1]
  if is_error(cond) then return cond end
  local truthy
  if type(cond) == "boolean" then truthy = cond
  elseif type(cond) == "number" then truthy = cond ~= 0
  else truthy = cond ~= nil and cond ~= "" and cond ~= false
  end
  if truthy then
    return args[2]
  else
    return args[3]  -- nil if not provided → returns false/0
  end
end

BUILTINS.AND = function(args)
  local vals = flatten(args)
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "boolean" and not v then return false end
    if type(v) == "number" and v == 0 then return false end
  end
  return true
end

BUILTINS.OR = function(args)
  local vals = flatten(args)
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    if type(v) == "boolean" and v then return true end
    if type(v) == "number" and v ~= 0 then return true end
  end
  return false
end

BUILTINS.NOT = function(args)
  if #args ~= 1 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return v end
  if type(v) == "boolean" then return not v end
  if type(v) == "number" then return v == 0 end
  return false
end

BUILTINS.IFERROR = function(args)
  if #args ~= 2 then return ERR_VALUE end
  local v = args[1]
  if is_error(v) then return args[2] end
  return v
end

BUILTINS.CONCAT = function(args)
  local vals = flatten(args)
  local parts = {}
  for _, v in ipairs(vals) do
    if is_error(v) then return v end
    parts[#parts+1] = tostring(v)
  end
  return table.concat(parts)
end

BUILTINS.LEFT = function(args)
  if #args < 1 then return ERR_VALUE end
  local s = tostring(args[1])
  local n = math.floor(tonumber(args[2]) or 1) --[[:! integer]]
  return s:sub(1, n)
end

BUILTINS.RIGHT = function(args)
  if #args < 1 then return ERR_VALUE end
  local s = tostring(args[1])
  local n = math.floor(tonumber(args[2]) or 1) --[[:! integer]]
  return s:sub(-n)
end

BUILTINS.MID = function(args)
  if #args < 3 then return ERR_VALUE end
  local s = tostring(args[1])
  local start = math.floor(tonumber(args[2]) or 1) --[[:! integer]]
  local len = math.floor(tonumber(args[3]) or 0) --[[:! integer]]
  return s:sub(start, start + len - 1)
end

BUILTINS.LEN = function(args)
  if #args ~= 1 then return ERR_VALUE end
  return #tostring(args[1])
end

BUILTINS.UPPER = function(args)
  if #args ~= 1 then return ERR_VALUE end
  return tostring(args[1]):upper()
end

BUILTINS.LOWER = function(args)
  if #args ~= 1 then return ERR_VALUE end
  return tostring(args[1]):lower()
end

BUILTINS.TRIM = function(args)
  if #args ~= 1 then return ERR_VALUE end
  local s = tostring(args[1])
  -- trim leading/trailing whitespace, collapse internal runs
  s = s:match("^%s*(.-)%s*$")
  s = s:gsub("%s+", " ")
  return s
end

BUILTINS.TEXT = function(args)
  if #args < 1 then return ERR_VALUE end
  -- basic: just convert to string
  return tostring(args[1])
end

-- VLOOKUP(lookup_value, range, col_index, [exact_match])
BUILTINS.VLOOKUP = function(args)
  if #args < 3 then return ERR_VALUE end
  local lookup = args[1]
  local range_arg = args[2]
  local col_idx = math.floor(tonumber(args[3]) or 1) --[[:! integer]]
  local exact = args[4]
  if exact == nil then exact = true end
  if type(exact) == "number" then exact = exact ~= 0 end

  if not (type(range_arg) == "table" and (range_arg --[[:! { __range: any, ... }]]).__range) then
    return ERR_VALUE
  end
  local range_arg_ = range_arg --[[:! { range: { r1: integer, c1: integer, r2: integer, c2: integer }, sheet: { get: (any, string) -> any, ... }, values: { [integer]: any } }]]

  local rng = range_arg_.range
  local sheet = range_arg_.sheet

  -- Build rows: each row is values from c1..c2 for a given row
  for r = rng.r1, rng.r2 do
    local first_key = cell_key(num_to_col(rng.c1), r)
    local first_val = sheet:get(first_key)
    local match = false
    if exact then
      match = first_val == lookup
    else
      -- approximate: find last row where first_val <= lookup (assumes sorted)
      -- simplified: just find exact or closest
      if type(first_val) == "number" and type(lookup) == "number" then
        match = first_val <= lookup
      else
        match = first_val == lookup
      end
    end
    if match then
      local target_col = rng.c1 + col_idx - 1
      if target_col > rng.c2 then return ERR_REF end
      local target_key = cell_key(num_to_col(target_col), r)
      return sheet:get(target_key)  -- luacheck: ignore
    end
  end
  return ERR_NA
end

-- INDEX(range, row, [col])
BUILTINS.INDEX = function(args)
  if #args < 2 then return ERR_VALUE end
  local range_arg = args[1]
  if not (type(range_arg) == "table" and (range_arg --[[:! { __range: any, ... }]]).__range) then
    return ERR_VALUE
  end
  local range_arg_ = range_arg --[[:! { range: { r1: integer, c1: integer, r2: integer, c2: integer }, sheet: { get: (any, string) -> any, ... }, values: { [integer]: any } }]]
  local rng = range_arg_.range
  local sheet = range_arg_.sheet
  local row_idx = math.floor(tonumber(args[2]) or 1) --[[:! integer]]
  local col_idx = math.floor(tonumber(args[3]) or 1) --[[:! integer]]
  local r = rng.r1 + row_idx - 1 --[[:! integer]]
  local c = rng.c1 + col_idx - 1 --[[:! integer]]
  if r > rng.r2 or c > rng.c2 then return ERR_REF end
  return sheet:get(cell_key(num_to_col(c), r))
end

-- MATCH(lookup, range, [match_type])
BUILTINS.MATCH = function(args)
  if #args < 2 then return ERR_VALUE end
  local lookup = args[1]
  local range_arg = args[2]
  if not (type(range_arg) == "table" and (range_arg --[[:! { __range: any, ... }]]).__range) then
    return ERR_VALUE
  end
  local range_arg_ = range_arg --[[:! { range: { r1: integer, c1: integer, r2: integer, c2: integer }, sheet: { get: (any, string) -> any, ... }, values: { [integer]: any } }]]
  local rng = range_arg_.range
  local vals = range_arg_.values
  for i, v in ipairs(vals) do
    if v == lookup then return i end
  end
  return ERR_NA
end

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

-- Evaluate an AST node given a sheet context
-- Returns a value or an error string
--: (SpreadNode, any, { [string]: boolean } | nil) -> any
local function eval_node(node, sheet, visiting)
  local sheet_ = sheet --[[:! { _max_rows: integer, _max_cols: integer, _get_computed: (any, string, any) -> any, ... }]]
  if node.type == NT.NUM then
    return node.value
  elseif node.type == NT.STR then
    return node.value
  elseif node.type == NT.REF then
    local ref_str = (node.value --[[:! string]])
    -- Strip $ signs to get canonical ref
    local clean = ref_str:gsub("%$", "")
    local col_str, row_num = clean:match("^([A-Za-z]+)(%d+)$")
    if not col_str then return ERR_REF end
    col_str = col_str:upper()
    row_num = tonumber(row_num --[[:! string]]) --[[:! integer]]
    -- bounds check
    if row_num < 1 or row_num > sheet_._max_rows then return ERR_REF end
    local c = col_to_num(col_str)
    if c < 1 or c > sheet_._max_cols then return ERR_REF end
    local key = cell_key(col_str, row_num)
    return sheet_:_get_computed(key, visiting)
  elseif node.type == NT.RANGE then
    local rng = parse_range(node.value --[[:! string]])
    if not rng then return ERR_REF end
    -- bounds check
    if rng.r1 < 1 or rng.r2 > sheet_._max_rows or
       rng.c1 < 1 or rng.c2 > sheet_._max_cols then
      return ERR_REF
    end
    local vals = {}
    for r = rng.r1, rng.r2 do
      for c = rng.c1, rng.c2 do
        local key = cell_key(num_to_col(c), r)
        local v = sheet_:_get_computed(key, visiting)
        vals[#vals+1] = v
      end
    end
    return { __range = true, values = vals, range = rng, sheet = sheet }
  elseif node.type == NT.UNOP then
    local v = eval_node(node.operand --[[:! SpreadNode]], sheet, visiting)
    if is_error(v) then return v end
    if node.op == "-" then
      local n, e = num_coerce(v)
      if e then return e end
      return -(n --[[:! number]])
    end
    return v
  elseif node.type == NT.BINOP then
    local op = node.op --[[:! string]]
    local lv = eval_node(node.left --[[:! SpreadNode]], sheet, visiting)
    local rv = eval_node(node.right --[[:! SpreadNode]], sheet, visiting)
    -- ranges aren't valid in binary ops (except &)
    if type(lv) == "table" and (lv --[[:! { __range: any, ... }]]).__range then lv = ERR_VALUE end
    if type(rv) == "table" and (rv --[[:! { __range: any, ... }]]).__range then rv = ERR_VALUE end

    if op == "&" then
      if is_error(lv) then return lv end
      if is_error(rv) then return rv end
      return tostring(lv) .. tostring(rv)
    end
    if is_error(lv) then return lv end
    if is_error(rv) then return rv end

    if op == "+" then
      local a, ea = num_coerce(lv)
      if ea then return ea end
      local b, eb = num_coerce(rv)
      if eb then return eb end
      return (a --[[:! number]]) + (b --[[:! number]])
    elseif op == "-" then
      local a, ea = num_coerce(lv)
      if ea then return ea end
      local b, eb = num_coerce(rv)
      if eb then return eb end
      return (a --[[:! number]]) - (b --[[:! number]])
    elseif op == "*" then
      local a, ea = num_coerce(lv)
      if ea then return ea end
      local b, eb = num_coerce(rv)
      if eb then return eb end
      return (a --[[:! number]]) * (b --[[:! number]])
    elseif op == "/" then
      local a, ea = num_coerce(lv)
      if ea then return ea end
      local b, eb = num_coerce(rv)
      if eb then return eb end
      local b_ = b --[[:! number]]
      if b_ == 0 then return ERR_DIV0 end
      return (a --[[:! number]]) / b_
    elseif op == "^" then
      local a, ea = num_coerce(lv)
      if ea then return ea end
      local b, eb = num_coerce(rv)
      if eb then return eb end
      return (a --[[:! number]]) ^ (b --[[:! number]])
    elseif op == "=" then
      return lv == rv
    elseif op == "<>" then
      return lv ~= rv
    elseif op == "<" then
      return (lv --[[: any]]) < (rv --[[: any]])
    elseif op == ">" then
      return (lv --[[: any]]) > (rv --[[: any]])
    elseif op == "<=" then
      return (lv --[[: any]]) <= (rv --[[: any]])
    elseif op == ">=" then
      return (lv --[[: any]]) >= (rv --[[: any]])
    end
    return ERR_VALUE
  elseif node.type == NT.CALL then
    local fn = BUILTINS[node.name --[[:! string]]]
    if not fn then return ERR_NAME end
    -- evaluate args
    local evaled = {}
    for _, arg in ipairs(node.args --[[:! { [integer]: SpreadNode }]]) do
      local v = eval_node(arg, sheet, visiting)
      evaled[#evaled+1] = v
    end
    local ok, result = pcall(fn, evaled)
    if not ok then return ERR_VALUE end
    return result
  end
  return ERR_VALUE
end

-- ---------------------------------------------------------------------------
-- Dependency tracking
-- ---------------------------------------------------------------------------

-- Collect all cell references (not ranges) and ranges from an AST
--: (SpreadNode, { [string]: boolean }) -> ()
local function collect_deps(node, deps)
  if node.type == NT.REF then
    local clean = (node.value --[[:! string]]):gsub("%$", ""):upper()
    deps[clean] = true
  elseif node.type == NT.RANGE then
    local rng = parse_range((node.value --[[:! string]]):gsub("%$", ""):upper())
    if rng then
      for r = rng.r1, rng.r2 do
        for c = rng.c1, rng.c2 do
          local key = cell_key(num_to_col(c), r)
          deps[key] = true
        end
      end
    end
  elseif node.type == NT.BINOP then
    collect_deps(node.left --[[:! SpreadNode]], deps)
    collect_deps(node.right --[[:! SpreadNode]], deps)
  elseif node.type == NT.UNOP then
    collect_deps(node.operand --[[:! SpreadNode]], deps)
  elseif node.type == NT.CALL then
    for _, arg in ipairs(node.args --[[:! { [integer]: SpreadNode }]]) do
      collect_deps(arg, deps)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Sheet object
-- ---------------------------------------------------------------------------

--:: SheetType = { _cells: { [string]: any }, _dependents: { [string]: { [string]: boolean } }, _max_rows: integer, _max_cols: integer, _invalidate: (SheetType, string, { [string]: boolean } | nil) -> (), _get_computed: (SheetType, string, { [string]: boolean } | nil) -> any, set: (SheetType, string, any) -> (boolean | nil, string | nil), get: (SheetType, string) -> any, range: (SheetType, string) -> any, set_range: (SheetType, string, any) -> any, to_csv: (SheetType) -> string, from_csv: (SheetType, string) -> any, ... }

local Sheet = {}
Sheet.__index = Sheet

--: (SheetType, string, { [string]: boolean } | nil) -> ()
function Sheet:_invalidate(key, seen)
  seen = seen or {}
  if seen[key] then return end
  seen[key] = true
  -- Mark this cell's cached value as dirty
  local cell = self._cells[key]
  if cell then (cell --[[:! { dirty: boolean, ... }]]).dirty = true end
  -- Propagate to dependents
  local dependents = self._dependents[key]
  if dependents then
    for dep_key in pairs(dependents) do
      self:_invalidate(dep_key --[[:! string]], seen)
    end
  end
end

function Sheet:_get_computed(key, visiting)
  visiting = visiting or {}
  -- Circular reference detection
  if visiting[key] then
    return ERR_CIRC
  end
  local cell = self._cells[key]
  if not cell then return nil end  -- empty cell → nil → treated as 0 in math
  if not cell.formula then
    return cell.value
  end
  -- Has formula
  if not cell.dirty then
    return cell.cached
  end
  -- Recompute
  visiting[key] = true
  local result = eval_node(cell.ast --[[:! SpreadNode]], self, visiting)
  visiting[key] = nil
  cell.cached = result
  cell.dirty = false
  return result
end

--: (any, string, any) -> (boolean | nil, string | nil)
function Sheet:set(ref, value)
  -- Normalize ref (strip $ for key)
  local clean = ref:gsub("%$", ""):upper()
  -- Validate
  local col_str, row_num = clean:match("^([A-Za-z]+)(%d+)$")
  if not col_str then return nil, "invalid cell reference: " .. ref end
  row_num = tonumber(row_num --[[:! string]]) --[[:! integer]]
  local col_num = col_to_num(col_str)
  if row_num < 1 or row_num > self._max_rows then return nil, ERR_REF end
  if col_num < 1 or col_num > self._max_cols then return nil, ERR_REF end

  local key = cell_key(col_str, row_num)

  -- Remove old dependency registrations
  local old_cell = self._cells[key]
  if old_cell and old_cell.formula then
    for dep_key in pairs(old_cell.deps) do
      local s = self._dependents[dep_key]
      if s then s[key] = nil end
    end
  end

  -- Create cell
  local cell
  if type(value) == "string" and value:sub(1,1) == "=" then
    -- Formula
    local formula_src = value:sub(2)
    local ok, ast = pcall(parse_formula, formula_src)
    if not ok then
      cell = { formula = formula_src, ast = nil, deps = {}, dirty = true,
               cached = ERR_NAME, parse_err = true }
    else
      local deps = {}
      collect_deps(ast --[[:! SpreadNode]], deps)
      cell = { formula = formula_src, ast = ast, deps = deps, dirty = true, cached = nil }
    end
  else
    cell = { value = value, formula = nil }
  end

  self._cells[key] = cell

  -- Register as dependent on each dep
  if cell.formula then
    for dep_key in pairs(cell.deps) do
      if not self._dependents[dep_key] then
        self._dependents[dep_key] = {}
      end
      self._dependents[dep_key][key] = true
    end
  end

  -- Invalidate this cell and its dependents
  self:_invalidate(key)

  return true
end

function Sheet:get(ref)
  local clean = ref:gsub("%$", ""):upper()
  local col_str, row_num = clean:match("^([A-Za-z]+)(%d+)$")
  if not col_str then return nil end
  row_num = tonumber(row_num --[[:! string]])
  if not row_num then return nil end
  local key = cell_key(col_str, row_num --[[:! integer]])
  return self:_get_computed(key)
end

--: (any, string) -> ({ [integer]: { row: integer, col: integer, value: any } } | nil, string | nil)
function Sheet:range(ref_range)
  local rng = parse_range(ref_range:gsub("%$", ""):upper())
  if not rng then return nil, "invalid range: " .. ref_range end
  local out = {}
  for r = rng.r1, rng.r2 do
    for c = rng.c1, rng.c2 do
      local key = cell_key(num_to_col(c), r)
      local val = self:_get_computed(key)
      out[#out+1] = { row = r, col = c, value = val }
    end
  end
  return out
end

--: (any, string, { [integer]: any }) -> (boolean | nil, string | nil)
function Sheet:set_range(ref_range, values_array)
  local rng = parse_range(ref_range:gsub("%$", ""):upper())
  if not rng then return nil, "invalid range: " .. ref_range end
  local idx = 1
  for r = rng.r1, rng.r2 do
    for c = rng.c1, rng.c2 do
      if idx > #values_array then break end
      local key = cell_key(num_to_col(c), r)
      self:set(key, values_array[idx])
      idx = idx + 1
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- CSV export / import
-- ---------------------------------------------------------------------------

local function csv_escape(v)
  if v == nil then return "" end
  local s = tostring(v)
  if s:find('[,"\n\r]') then
    s = '"' .. (s:gsub('"', '""') --[[: string]]) .. '"'
  end
  return s
end

--: (string) -> { [integer]: string }
local function csv_parse_row(line)
  local fields = {}
  local i = 1
  local n = #line
  while i <= n do
    if line:sub(i,i) == '"' then
      i = i + 1
      local val = {}
      while i <= n do
        local c = line:sub(i,i)
        if c == '"' then
          if line:sub(i+1,i+1) == '"' then
            val[#val+1] = '"'
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          val[#val+1] = c
          i = i + 1
        end
      end
      fields[#fields+1] = table.concat(val)
      if i <= n and line:sub(i,i) == "," then i = i + 1 end
    else
      local j = line:find(",", i, true)
      if j then
        fields[#fields+1] = line:sub(i, j-1)
        i = j + 1
      else
        fields[#fields+1] = line:sub(i)
        break
      end
    end
  end
  return fields
end

--: (SheetType) -> string
function Sheet:to_csv()
  -- Find used extents
  local max_row = 0
  local max_col = 0
  for key in pairs(self._cells) do
    local col_str, row_num = key:match("^([A-Za-z]+)(%d+)$")
    if col_str then
      local r = tonumber(row_num --[[:! string]]) --[[:! integer]]
      local c = col_to_num(col_str)
      if r > max_row then max_row = r end
      if c > max_col then max_col = c end
    end
  end
  if max_row == 0 then return "" end
  local lines = {}
  for r = 1, max_row do
    local row = {}
    for c = 1, max_col do
      local key = cell_key(num_to_col(c), r)
      local val = self:_get_computed(key)
      row[#row+1] = csv_escape(val)
    end
    lines[#lines+1] = table.concat(row, ",")
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local sheet = setmetatable({
    _cells      = {},
    _dependents = {},
    _max_rows   = opts.rows or 1000,
    _max_cols   = opts.cols or 26,
  }, Sheet)
  return sheet
end

function M.from_csv(str)
  local sheet = M.new()
  if not str or str == "" then return sheet end
  local row = 1
  for line in (str .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      local fields = csv_parse_row(line)
      for c, val in ipairs(fields) do
        if val ~= "" then
          local key = cell_key(num_to_col(c), row)
          -- Try to convert to number
          local n = tonumber(val)
          if n then
            sheet:set(key, n)
          else
            sheet:set(key, val)
          end
        end
      end
      row = row + 1
    end
  end
  return sheet
end

return M
