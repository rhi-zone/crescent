if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Built-in functions available in all evaluations
local BUILTINS = {
  abs   = math.abs,
  floor = math.floor,
  ceil  = math.ceil,
  sqrt  = math.sqrt,
  max   = math.max,
  min   = math.min,
  round = function(x) return math.floor(x + 0.5) end,
  log   = math.log,
  exp   = math.exp,
  sin   = math.sin,
  cos   = math.cos,
  tan   = math.tan,
  len   = function(s)
    if type(s) ~= "string" then
      error("len() expects a string, got " .. type(s))
    end
    return #s
  end,
}

-- Lexer token types
local TK_NUMBER  = "number"
local TK_STRING  = "string"
local TK_IDENT   = "ident"
local TK_OP      = "op"
local TK_LPAREN  = "("
local TK_RPAREN  = ")"
local TK_COMMA   = ","
local TK_EOF     = "eof"

--:: Token = { kind: string, val: unknown, pos: integer }

-- Tokenize the expression string into a list of tokens
local function lex(src)
  local tokens = {} --: { [integer]: Token }
  local i = 1
  local n = #src

  while i <= n do
    local c = src:sub(i, i)

    -- Skip whitespace
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      i = i + 1

    -- Numbers (integer or float, including scientific notation)
    elseif c:match("%d") or (c == "." and src:sub(i+1,i+1):match("%d")) then
      local j = i
      -- digits
      while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      -- optional decimal part
      if j <= n and src:sub(j,j) == "." then
        j = j + 1
        while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      end
      -- optional exponent
      if j <= n and (src:sub(j,j) == "e" or src:sub(j,j) == "E") then
        j = j + 1
        if j <= n and (src:sub(j,j) == "+" or src:sub(j,j) == "-") then
          j = j + 1
        end
        while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      end
      tokens[#tokens+1] = { kind = TK_NUMBER, val = tonumber(src:sub(i, j-1)), pos = i }
      i = j

    -- String literals (single or double quotes)
    elseif c == '"' or c == "'" then
      local q = c
      local j = i + 1
      local buf = {}
      while j <= n do
        local ch = src:sub(j, j)
        if ch == q then
          j = j + 1
          break
        elseif ch == "\\" then
          j = j + 1
          local esc = src:sub(j, j)
          if esc == "n" then buf[#buf+1] = "\n"
          elseif esc == "t" then buf[#buf+1] = "\t"
          elseif esc == "r" then buf[#buf+1] = "\r"
          elseif esc == "\\" then buf[#buf+1] = "\\"
          elseif esc == "'" then buf[#buf+1] = "'"
          elseif esc == '"' then buf[#buf+1] = '"'
          else buf[#buf+1] = esc end
          j = j + 1
        else
          buf[#buf+1] = ch
          j = j + 1
        end
      end
      tokens[#tokens+1] = { kind = TK_STRING, val = table.concat(buf), pos = i }
      i = j

    -- Identifiers and keywords
    elseif c:match("[%a_]") then
      local j = i
      while j <= n and src:sub(j,j):match("[%w_]") do j = j + 1 end
      local word = src:sub(i, j-1)
      tokens[#tokens+1] = { kind = TK_IDENT, val = word, pos = i }
      i = j

    -- Two-character operators
    elseif c == "=" and src:sub(i+1,i+1) == "=" then
      tokens[#tokens+1] = { kind = TK_OP, val = "==", pos = i }; i = i + 2
    elseif c == "!" and src:sub(i+1,i+1) == "=" then
      tokens[#tokens+1] = { kind = TK_OP, val = "!=", pos = i }; i = i + 2
    elseif c == "<" and src:sub(i+1,i+1) == "=" then
      tokens[#tokens+1] = { kind = TK_OP, val = "<=", pos = i }; i = i + 2
    elseif c == ">" and src:sub(i+1,i+1) == "=" then
      tokens[#tokens+1] = { kind = TK_OP, val = ">=", pos = i }; i = i + 2
    elseif c == "." and src:sub(i+1,i+1) == "." then
      tokens[#tokens+1] = { kind = TK_OP, val = "..", pos = i }; i = i + 2

    -- Single-character operators and punctuation
    elseif c == "(" then tokens[#tokens+1] = { kind = TK_LPAREN, val = c, pos = i }; i = i + 1
    elseif c == ")" then tokens[#tokens+1] = { kind = TK_RPAREN, val = c, pos = i }; i = i + 1
    elseif c == "," then tokens[#tokens+1] = { kind = TK_COMMA,  val = c, pos = i }; i = i + 1
    elseif c == "+" or c == "-" or c == "*" or c == "/" or c == "%" or c == "^"
        or c == "<" or c == ">" then
      tokens[#tokens+1] = { kind = TK_OP, val = c, pos = i }; i = i + 1
    else
      return nil, "unexpected character '" .. c .. "' at position " .. i
    end
  end

  tokens[#tokens+1] = { kind = TK_EOF, val = "", pos = n+1 }
  return tokens
end

-- Parser: produces an AST from a token list
-- Node types: {type="num", val=n}, {type="str", val=s}, {type="bool", val=b},
--             {type="nil"}, {type="var", name=s}, {type="call", name=s, args={...}},
--             {type="unop", op=s, arg=node}, {type="binop", op=s, left=node, right=node}

local function parse(tokens)
  local pos = 1

  local function peek() return tokens[pos] end
  local function advance() local t = tokens[pos]; pos = pos + 1; return t end

  local function expect(kind, val)
    local t = peek()
    if t.kind ~= kind then
      return nil, "parse error: expected " .. kind .. " but got '" .. t.val .. "' at position " .. t.pos
    end
    if val and t.val ~= val then
      return nil, "parse error: expected '" .. val .. "' but got '" .. t.val .. "' at position " .. t.pos
    end
    return advance()
  end

  local parse_expr  -- forward declaration
  local parse_logic_or
  local parse_unary -- forward declaration (parse_power needs it)

  local function parse_primary()
    local t = peek()

    if t.kind == TK_NUMBER then
      advance()
      return { type = "num", val = t.val }

    elseif t.kind == TK_STRING then
      advance()
      return { type = "str", val = t.val }

    elseif t.kind == TK_IDENT then
      if t.val == "true" then
        advance()
        return { type = "bool", val = true }
      elseif t.val == "false" then
        advance()
        return { type = "bool", val = false }
      elseif t.val == "nil" then
        advance()
        return { type = "nil" }
      else
        advance()
        -- Check for function call
        if peek().kind == TK_LPAREN then
          advance() -- consume '('
          local args = {}
          if peek().kind ~= TK_RPAREN then
            local arg, err = parse_expr()
            if not arg then return nil, err end
            args[#args+1] = arg
            while peek().kind == TK_COMMA do
              advance()
              arg, err = parse_expr()
              if not arg then return nil, err end
              args[#args+1] = arg
            end
          end
          local _, err = expect(TK_RPAREN)
          if err then return nil, err end
          return { type = "call", name = t.val, args = args }
        end
        return { type = "var", name = t.val }
      end

    elseif t.kind == TK_LPAREN then
      advance()
      local node, err = parse_expr()
      if not node then return nil, err end
      local _, perr = expect(TK_RPAREN)
      if perr then return nil, perr end
      return node

    else
      return nil, "parse error: unexpected token '" .. t.val .. "' at position " .. t.pos
    end
  end

  -- power: right-associative (primary ^ unary)
  -- The exponent is parsed as unary so that e.g. 2^-1 works.
  local function parse_power()
    local base, err = parse_primary()
    if not base then return nil, err end
    if peek().kind == TK_OP and peek().val == "^" then
      advance()
      local exp, err2 = parse_unary() -- unary so 2^-1 works
      if not exp then return nil, err2 end
      return { type = "binop", op = "^", left = base, right = exp }
    end
    return base
  end

  -- unary: 'not' unary | '-' unary | power
  parse_unary = function()
    local t = peek()
    if t.kind == TK_IDENT and t.val == "not" then
      advance()
      local arg, err = parse_unary()
      if not arg then return nil, err end
      return { type = "unop", op = "not", arg = arg }
    elseif t.kind == TK_OP and t.val == "-" then
      advance()
      local arg, err = parse_unary()
      if not arg then return nil, err end
      return { type = "unop", op = "-", arg = arg }
    end
    return parse_power()
  end

  -- term: unary (('*' | '/' | '%') unary)*
  local function parse_term()
    local node, err = parse_unary()
    if not node then return nil, err end
    while peek().kind == TK_OP and
          (peek().val == "*" or peek().val == "/" or peek().val == "%") do
      local op = advance().val
      local right, err2 = parse_unary()
      if not right then return nil, err2 end
      node = { type = "binop", op = op, left = node, right = right }
    end
    return node
  end

  -- addition: term (('+' | '-' | '..') term)*
  local function parse_addition()
    local node, err = parse_term()
    if not node then return nil, err end
    while peek().kind == TK_OP and
          (peek().val == "+" or peek().val == "-" or peek().val == "..") do
      local op = advance().val
      local right, err2 = parse_term()
      if not right then return nil, err2 end
      node = { type = "binop", op = op, left = node, right = right }
    end
    return node
  end

  -- comparison: addition (('==' | '!=' | '<' | '>' | '<=' | '>=') addition)?
  local function parse_comparison()
    local node, err = parse_addition()
    if not node then return nil, err end
    local t = peek()
    if t.kind == TK_OP and
       (t.val == "==" or t.val == "!=" or t.val == "<" or t.val == ">"
        or t.val == "<=" or t.val == ">=") then
      local op = advance().val
      local right, err2 = parse_addition()
      if not right then return nil, err2 end
      node = { type = "binop", op = op, left = node, right = right }
    end
    return node
  end

  -- logic_and: comparison ('and' comparison)*
  local function parse_logic_and()
    local node, err = parse_comparison()
    if not node then return nil, err end
    while peek().kind == TK_IDENT and peek().val == "and" do
      advance()
      local right, err2 = parse_comparison()
      if not right then return nil, err2 end
      node = { type = "binop", op = "and", left = node, right = right }
    end
    return node
  end

  -- logic_or: logic_and ('or' logic_and)*
  parse_logic_or = function()
    local node, err = parse_logic_and()
    if not node then return nil, err end
    while peek().kind == TK_IDENT and peek().val == "or" do
      advance()
      local right, err2 = parse_logic_and()
      if not right then return nil, err2 end
      node = { type = "binop", op = "or", left = node, right = right }
    end
    return node
  end

  parse_expr = parse_logic_or

  local ast, err = parse_expr()
  if not ast then return nil, err end

  -- Make sure we consumed all tokens
  if peek().kind ~= TK_EOF then
    local t = peek()
    return nil, "parse error: unexpected token '" .. t.val .. "' at position " .. t.pos
  end

  return ast
end

-- Evaluator: walks the AST with an environment
local function eval_ast(node, env)
  local nt = node.type

  if nt == "num" then
    return node.val

  elseif nt == "str" then
    return node.val

  elseif nt == "bool" then
    return node.val

  elseif nt == "nil" then
    return nil

  elseif nt == "var" then
    local name = node.name --[[:! string]]
    -- Check user env first, then builtins
    if env and env[name] ~= nil then
      return env[name]
    end
    if BUILTINS[name] ~= nil then
      return BUILTINS[name]
    end
    return nil, "undefined variable: " .. name

  elseif nt == "call" then
    local name = node.name --[[:! string]]
    local fn
    if env and type(env[name]) == "function" then
      fn = env[name]
    elseif BUILTINS[name] then
      fn = BUILTINS[name]
    else
      return nil, "undefined function: " .. name
    end
    -- Evaluate arguments
    local args = {}
    local node_args = node.args --[[:! { [integer]: unknown }]]
    for i = 1, #node_args do
      local v, err = eval_ast(node_args[i] --[[:! { type: string, ... }]], env)
      if v == nil and err then return nil, err end
      args[i] = v
    end
    local ok, result = pcall(fn, unpack(args))
    if not ok then
      return nil, "runtime error in " .. name .. "(): " .. tostring(result)
    end
    return result

  elseif nt == "unop" then
    local op = node.op
    if op == "-" then
      local v, err = eval_ast(node.arg, env)
      if v == nil and err then return nil, err end
      if type(v) ~= "number" then
        return nil, "unary minus requires a number, got " .. type(v)
      end
      return -v
    elseif op == "not" then
      local v, err = eval_ast(node.arg, env)
      if err then return nil, err end
      return not v
    end

  elseif nt == "binop" then
    local op = node.op

    -- Short-circuit operators
    if op == "and" then
      local lv, lerr = eval_ast(node.left, env)
      if lerr then return nil, lerr end
      if not lv then return lv end
      return eval_ast(node.right, env)
    elseif op == "or" then
      local lv, lerr = eval_ast(node.left, env)
      if lerr then return nil, lerr end
      if lv then return lv end
      return eval_ast(node.right, env)
    end

    local lv, lerr = eval_ast(node.left, env)
    if lv == nil and lerr then return nil, lerr end
    local rv, rerr = eval_ast(node.right, env)
    if rv == nil and rerr then return nil, rerr end

    if op == "+" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'+' requires numbers"
      end
      return lv + rv
    elseif op == "-" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'-' requires numbers"
      end
      return lv - rv
    elseif op == "*" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'*' requires numbers"
      end
      return lv * rv
    elseif op == "/" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'/' requires numbers"
      end
      return lv / rv
    elseif op == "%" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'%%' requires numbers"
      end
      return lv % rv
    elseif op == "^" then
      if type(lv) ~= "number" or type(rv) ~= "number" then
        return nil, "'^' requires numbers"
      end
      return lv ^ rv
    elseif op == ".." then
      return tostring(lv) .. tostring(rv)
    elseif op == "==" then
      return lv == rv
    elseif op == "!=" then
      return lv ~= rv
    elseif op == "<" then
      return lv < rv
    elseif op == ">" then
      return lv > rv
    elseif op == "<=" then
      return lv <= rv
    elseif op == ">=" then
      return lv >= rv
    end
  end

  return nil, "internal error: unknown node type " .. tostring(nt)
end

-- Parse an expression string into an AST, returning (ast, nil) or (nil, errmsg)
function M.parse(src)
  local tokens, err = lex(src)
  if not tokens then return nil, err end
  return parse(tokens)
end

-- Evaluate an expression string with an optional variable environment
-- Returns (result, nil) on success, (nil, errmsg) on error
function M.eval(src, env)
  local ast, err = M.parse(src)
  if not ast then return nil, err end
  local result, err2 = eval_ast(ast, env)
  if result == nil and err2 then return nil, err2 end
  return result
end

-- Compile an expression into a reusable callable
-- Returns a function(env) -> result, or throws on parse error
-- Compile errors use (nil, errmsg) pattern on the returned function
function M.compile(src)
  local ast, parse_err = M.parse(src)
  return function(env)
    if not ast then return nil, parse_err end
    local result, err = eval_ast(ast, env)
    if result == nil and err then return nil, err end
    return result
  end
end

return M
