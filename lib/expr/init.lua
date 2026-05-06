if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Mathematical expression parser and evaluator with symbolic differentiation.
-- Pure Lua, no dependencies.
--
-- Supported:
--   Operators: + - * / ^ % unary-minus
--   Functions: sin cos tan asin acos atan atan2 sqrt exp log log2 log10 abs floor ceil round
--   Constants: pi e
--   Comparisons: < <= > >= == != → 0 or 1
--   Ternary: x > 0 ? x : -x
--   Comma for multi-arg functions: atan2(y, x)
--
-- AST node format:
--   {op="num",  value=5}
--   {op="var",  name="x"}
--   {op="call", name="sin", args={...}}
--   {op="add",  left=..., right=...}   (same for sub mul div pow mod)
--   {op="neg",  arg=...}
--   {op="cmp",  cmp="<", left=..., right=...}
--   {op="ternary", cond=..., then_=..., else_=...}
--
-- Power associativity: right-associative (2^3^2 = 2^(3^2) = 512).

local M = {}
M._tier = "pure"

-- ─── built-in functions ────────────────────────────────────────────────────

local FUNS = {
  sin   = math.sin,
  cos   = math.cos,
  tan   = math.tan,
  asin  = math.asin,
  acos  = math.acos,
  atan  = math.atan,
  atan2 = math.atan2,
  sqrt  = math.sqrt,
  exp   = math.exp,
  log   = math.log,
  log2  = function(x) return math.log(x) / math.log(2) end,
  log10 = math.log10,
  abs   = math.abs,
  floor = math.floor,
  ceil  = math.ceil,
  round = function(x) return math.floor(x + 0.5) end,
}

local CONSTS = { pi = math.pi, e = math.exp(1) } --: { [string]: number }

-- ─── lexer ─────────────────────────────────────────────────────────────────

-- Token types: "num", "ident", "op", "lparen", "rparen", "comma", "eof"
-- Each token: {type, value, pos}

--:: Token = { type: string, value: unknown, pos: integer }
--:: Expr = { op: string, ... }

local function lex(src)
  local tokens = --[[:! Token[] ]] {}
  local i = 1
  local n = #src

  while i <= n do
    local c = src:sub(i, i)

    -- skip whitespace
    if c:match("%s") then
      i = i + 1

    -- number literal (including scientific notation)
    elseif c:match("[%d]") or (c == "." and src:sub(i+1,i+1):match("%d")) then
      local j = i
      -- integer part
      while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      -- decimal part
      if j <= n and src:sub(j,j) == "." then
        j = j + 1
        while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      end
      -- exponent part
      if j <= n and src:sub(j,j):match("[eE]") then
        j = j + 1
        if j <= n and src:sub(j,j):match("[+%-]") then j = j + 1 end
        while j <= n and src:sub(j,j):match("%d") do j = j + 1 end
      end
      tokens[#tokens+1] = {type="num", value=tonumber(src:sub(i, j-1)), pos=i}
      i = j

    -- identifier or keyword
    elseif c:match("[%a_]") then
      local j = i
      while j <= n and src:sub(j,j):match("[%w_]") do j = j + 1 end
      tokens[#tokens+1] = {type="ident", value=src:sub(i, j-1), pos=i}
      i = j

    -- two-char operators
    elseif src:sub(i,i+1) == "<=" then
      tokens[#tokens+1] = {type="op", value="<=", pos=i}; i = i + 2
    elseif src:sub(i,i+1) == ">=" then
      tokens[#tokens+1] = {type="op", value=">=", pos=i}; i = i + 2
    elseif src:sub(i,i+1) == "==" then
      tokens[#tokens+1] = {type="op", value="==", pos=i}; i = i + 2
    elseif src:sub(i,i+1) == "!=" then
      tokens[#tokens+1] = {type="op", value="!=", pos=i}; i = i + 2

    -- single-char operators
    elseif c == "+" or c == "-" or c == "*" or c == "/" or
           c == "^" or c == "%" or c == "<" or c == ">" or
           c == "?" or c == ":" then
      tokens[#tokens+1] = {type="op", value=c, pos=i}; i = i + 1
    elseif c == "(" then
      tokens[#tokens+1] = {type="lparen", value="(", pos=i}; i = i + 1
    elseif c == ")" then
      tokens[#tokens+1] = {type="rparen", value=")", pos=i}; i = i + 1
    elseif c == "," then
      tokens[#tokens+1] = {type="comma", value=",", pos=i}; i = i + 1
    else
      return nil, "unexpected character '" .. c .. "' at position " .. i
    end
  end

  tokens[#tokens+1] = {type="eof", value="", pos=n+1}
  return tokens
end

-- ─── parser ────────────────────────────────────────────────────────────────
-- Recursive-descent; precedence levels:
--   ternary (? :)  →  comparison (< <= > >= == !=)  →
--   add/sub  →  mul/div/mod  →  unary minus  →  power (right)  →  primary

local function parse_tokens(tokens)
  local pos = 1

  local function peek() return tokens[pos] end
  local function advance() local t = tokens[pos]; pos = pos + 1; return t end

  local function expect_type(ty)
    local t = peek()
    if t.type ~= ty then
      return nil, "expected " .. ty .. " at position " .. t.pos .. ", got " .. t.type .. " (" .. tostring(t.value) .. ")"
    end
    return advance()
  end

  -- forward declaration
  local parse_expr

  local function parse_primary()
    local t = peek()

    if t.type == "num" then
      advance()
      return {op="num", value=t.value}

    elseif t.type == "ident" then
      -- check for function call
      if tokens[pos+1] and tokens[pos+1].type == "lparen" then
        local name = t.value
        advance() -- name
        advance() -- (
        local args = {}
        if peek().type ~= "rparen" then
          local a, err = parse_expr()
          if not a then return nil, err end
          args[1] = a
          while peek().type == "comma" do
            advance()
            a, err = parse_expr()
            if not a then return nil, err end
            args[#args+1] = a
          end
        end
        local rp, err = expect_type("rparen")
        if not rp then return nil, err end
        if not FUNS[name] then
          return nil, "unknown function '" .. name .. "'"
        end
        return {op="call", name=name, args=args}
      else
        advance()
        return {op="var", name=t.value}
      end

    elseif t.type == "lparen" then
      advance()
      local e, err = parse_expr()
      if not e then return nil, err end
      local rp, rerr = expect_type("rparen")
      if not rp then return nil, rerr end
      return e

    elseif t.type == "op" and t.value == "-" then
      advance()
      local e, err = parse_primary()
      if not e then return nil, err end
      -- constant folding for unary minus on literals
      if e.op == "num" then return {op="num", value=-e.value} end
      return {op="neg", arg=e}

    else
      return nil, "unexpected token " .. t.type .. " ('" .. tostring(t.value) .. "') at position " .. t.pos
    end
  end

  -- right-associative power
  local function parse_power()
    local base, err = parse_primary()
    if not base then return nil, err end
    if peek().type == "op" and peek().value == "^" then
      advance()
      local exp_, err2 = parse_power() -- right-recursion for right-assoc
      if not exp_ then return nil, err2 end
      return {op="pow", left=base, right=exp_}
    end
    return base
  end

  -- unary minus applied after primary (handles --x = x, not needed but keep simple)
  -- Actually parse_primary handles leading minus; parse_power is fine.

  local function parse_muldiv()
    local left, err = parse_power()
    if not left then return nil, err end
    while true do
      local t = peek()
      if t.type == "op" and (t.value == "*" or t.value == "/" or t.value == "%") then
        local op = t.value
        advance()
        local right, rerr = parse_power()
        if not right then return nil, rerr end
        local opname = op == "*" and "mul" or op == "/" and "div" or "mod"
        left = {op=opname, left=left, right=right}
      else
        break
      end
    end
    return left
  end

  local function parse_addsub()
    local left, err = parse_muldiv()
    if not left then return nil, err end
    while true do
      local t = peek()
      if t.type == "op" and (t.value == "+" or t.value == "-") then
        local op = t.value
        advance()
        local right, rerr = parse_muldiv()
        if not right then return nil, rerr end
        local opname = op == "+" and "add" or "sub"
        left = {op=opname, left=left, right=right}
      else
        break
      end
    end
    return left
  end

  local function parse_cmp()
    local left, err = parse_addsub()
    if not left then return nil, err end
    local t = peek()
    if t.type == "op" and (t.value == "<" or t.value == "<=" or
        t.value == ">" or t.value == ">=" or
        t.value == "==" or t.value == "!=") then
      local cmp = t.value
      advance()
      local right, rerr = parse_addsub()
      if not right then return nil, rerr end
      return {op="cmp", cmp=cmp, left=left, right=right}
    end
    return left
  end

  -- ternary: cond ? then : else
  local function parse_ternary()
    local cond, err = parse_cmp()
    if not cond then return nil, err end
    if peek().type == "op" and peek().value == "?" then
      advance()
      local then_, err2 = parse_cmp()
      if not then_ then return nil, err2 end
      local t = peek()
      if t.type ~= "op" or t.value ~= ":" then
        return nil, "expected ':' in ternary at position " .. t.pos
      end
      advance()
      local else_, err3 = parse_cmp()
      if not else_ then return nil, err3 end
      return {op="ternary", cond=cond, then_=then_, else_=else_}
    end
    return cond
  end

  parse_expr = parse_ternary

  local ast, err = parse_expr()
  if not ast then return nil, err end
  if peek().type ~= "eof" then
    local t = peek()
    return nil, "unexpected token '" .. tostring(t.value) .. "' at position " .. t.pos
  end
  return ast
end

-- ─── evaluator ─────────────────────────────────────────────────────────────

--: (Expr, { [string]: number } | nil) -> (number | nil, string | nil)
local function eval_ast(ast, env)
  local op = ast.op
  if op == "num" then
    return ast.value --[[:! number]]
  elseif op == "var" then
    local name = ast.name --[[:! string]]
    local cv = CONSTS[name] --: number | nil
    if cv then return cv end
    if env then
      local ev = env[name]
      if ev ~= nil then return ev end
    end
    return nil, "undefined variable '" .. name .. "'"
  elseif op == "call" then
    local fn = FUNS[ast.name --[[:! string]]]
    if not fn then return nil, "unknown function '" .. (ast.name --[[:! string]]) .. "'" end
    local vals = {} --: { [integer]: number }
    local args = ast.args --[[:! { [integer]: Expr }]]
    for i, a in ipairs(args) do
      local v, err = eval_ast(a, env)
      if v == nil then return nil, err end
      vals[i] = v --[[:! number]]
    end
    local fn_ = fn --[[:! (...number) -> number]]
    return fn_(unpack(vals))
  elseif op == "neg" then
    local v, err = eval_ast(ast.arg --[[:! Expr]], env)
    if v == nil then return nil, err end
    local v_ = v --[[:! number]]
    return -v_
  elseif op == "add" or op == "sub" or op == "mul" or op == "div" or
         op == "pow" or op == "mod" then
    local l, err = eval_ast(ast.left --[[:! Expr]], env)
    if l == nil then return nil, err end
    local l_ = l --[[:! number]]
    local r, rerr = eval_ast(ast.right --[[:! Expr]], env)
    if r == nil then return nil, rerr end
    local r_ = r --[[:! number]]
    if op == "add" then return l_ + r_
    elseif op == "sub" then return l_ - r_
    elseif op == "mul" then return l_ * r_
    elseif op == "div" then return l_ / r_
    elseif op == "pow" then return l_ ^ r_
    elseif op == "mod" then return l_ % r_
    end
  elseif op == "cmp" then
    local l, err = eval_ast(ast.left --[[:! Expr]], env)
    if l == nil then return nil, err end
    local l_ = l --[[:! number]]
    local r, rerr = eval_ast(ast.right --[[:! Expr]], env)
    if r == nil then return nil, rerr end
    local r_ = r --[[:! number]]
    local cmp = ast.cmp --[[:! string]]
    local result --: boolean | nil
    if cmp == "<"  then result = l_ < r_
    elseif cmp == "<=" then result = l_ <= r_
    elseif cmp == ">"  then result = l_ > r_
    elseif cmp == ">=" then result = l_ >= r_
    elseif cmp == "==" then result = l_ == r_
    elseif cmp == "!=" then result = l_ ~= r_
    end
    return result and 1 or 0
  elseif op == "ternary" then
    local c, err = eval_ast(ast.cond --[[:! Expr]], env)
    if c == nil then return nil, err end
    if c ~= 0 then
      return eval_ast(ast.then_ --[[:! Expr]], env)
    else
      return eval_ast(ast.else_ --[[:! Expr]], env)
    end
  end
  return nil, "unknown AST op '" .. tostring(op) .. "'"
end

-- ─── to_string ─────────────────────────────────────────────────────────────

-- Operator precedence for parenthesisation
local PREC = { --: { [string]: integer }
  ternary = 1,
  cmp     = 2,
  add     = 3, sub = 3,
  mul     = 4, div = 4, mod = 4,
  pow     = 6,
  neg     = 5,
  num     = 10, var = 10, call = 10,
}

--: (Expr, integer, boolean) -> string
local function to_string(ast, parent_prec, is_right)
  local op = ast.op
  if op == "num" then
    local v = ast.value --[[:! number]]
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return tostring(math.floor(v))
    end
    return tostring(v)
  elseif op == "var" then
    return ast.name --[[:! string]]
  elseif op == "call" then
    local args_ = ast.args --[[:! { [integer]: Expr }]]
    local args = {} --: { [integer]: string }
    for _, a in ipairs(args_) do table.insert(args, to_string(a, 0, false)) end
    return (ast.name --[[:! string]]) .. "(" .. table.concat(args, ", ") .. ")"
  elseif op == "neg" then
    local arg_ = ast.arg --[[:! Expr]]
    local inner = to_string(arg_, PREC.neg, false)
    -- wrap if inner has lower precedence
    local arg_prec = PREC[arg_.op] --: integer | nil
    if arg_prec and arg_prec < PREC.neg then
      inner = "(" .. inner .. ")"
    end
    return "-" .. inner
  elseif op == "add" or op == "sub" or op == "mul" or op == "div" or
         op == "mod" or op == "pow" then
    local syms = {add="+", sub="-", mul="*", div="/", mod="%", pow="^"}
    local prec = PREC[op] --[[:! integer]]
    local left_ = ast.left --[[:! Expr]]
    local right_ = ast.right --[[:! Expr]]
    local ls = to_string(left_,  prec, false)
    local rs = to_string(right_, prec, true)
    -- parenthesise left if strictly lower precedence
    local lprec = PREC[left_.op] --: integer | nil
    if lprec and lprec < prec then
      ls = "(" .. ls .. ")"
    end
    -- parenthesise right if:
    --   lower precedence, OR same prec and left-assoc op on right of left-assoc
    local rprec = PREC[right_.op] --: integer | nil
    if rprec then
      local need_paren = rprec < prec
      -- for left-assoc ops, same-prec right child needs parens (e.g. a-(b+c))
      if op ~= "pow" and rprec == prec then need_paren = true end
      if need_paren then rs = "(" .. rs .. ")" end
    end
    local sym = syms[op] --[[:! string]]
    return ls .. " " .. sym .. " " .. rs
  elseif op == "cmp" then
    local l = to_string(ast.left --[[:! Expr]],  PREC.cmp, false)
    local r = to_string(ast.right --[[:! Expr]], PREC.cmp, true)
    return l .. " " .. (ast.cmp --[[:! string]]) .. " " .. r
  elseif op == "ternary" then
    local c = to_string(ast.cond --[[:! Expr]],  PREC.ternary, false)
    local t = to_string(ast.then_ --[[:! Expr]], PREC.ternary, false)
    local e = to_string(ast.else_ --[[:! Expr]], PREC.ternary, true)
    return c .. " ? " .. t .. " : " .. e
  end
  return "<?>"
end

-- ─── symbolic helpers (used by simplify and diff) ─────────────────────────

--: (number) -> Expr
local function make_num(v) return --[[:! Expr]] {op="num", value=v} end
local ZERO = make_num(0)
local ONE  = make_num(1)

--: (Expr, Expr) -> Expr
local function make_add(a, b) return --[[:! Expr]] {op="add", left=a, right=b} end
--: (Expr, Expr) -> Expr
local function make_sub(a, b) return --[[:! Expr]] {op="sub", left=a, right=b} end
--: (Expr, Expr) -> Expr
local function make_mul(a, b) return --[[:! Expr]] {op="mul", left=a, right=b} end
--: (Expr, Expr) -> Expr
local function make_div(a, b) return --[[:! Expr]] {op="div", left=a, right=b} end
--: (Expr, Expr) -> Expr
local function make_pow(a, b) return --[[:! Expr]] {op="pow", left=a, right=b} end
--: (Expr) -> Expr
local function make_neg(a)    return --[[:! Expr]] {op="neg", arg=a} end
--: (string, { [integer]: Expr }) -> Expr
local function make_call(name, args) return --[[:! Expr]] {op="call", name=name, args=args} end

-- ─── simplify ──────────────────────────────────────────────────────────────
-- Constant folding: if all children evaluate to numbers, replace with num node.

--: (Expr) -> Expr
local function simplify(ast)
  local op = ast.op
  if op == "num" or op == "var" then return ast end

  if op == "neg" then
    local a = simplify(ast.arg --[[:! Expr]])
    if a.op == "num" then return make_num(-(a.value --[[:! number]])) end
    return make_neg(a)
  elseif op == "call" then
    local ast_args = ast.args --[[:! { [integer]: Expr }]]
    local args = {} --: { [integer]: Expr }
    local all_num = true
    local nargs = 0
    for _, a in ipairs(ast_args) do
      nargs = nargs + 1
      local sa = simplify(a)
      rawset(args, nargs, sa)
      if sa.op ~= "num" then all_num = false end
    end
    if all_num then
      local fn = FUNS[ast.name --[[:! string]]]
      if fn then
        local vals = {} --: { [integer]: number }
        for i, a in ipairs(args) do vals[i] = a.value --[[:! number]] end
        local fn_ = fn --[[:! (...number) -> number]]
        local v = fn_(unpack(vals))
        return make_num(v)
      end
    end
    return make_call(ast.name --[[:! string]], args)
  elseif op == "add" or op == "sub" or op == "mul" or op == "div" or
         op == "pow" or op == "mod" then
    local l = simplify(ast.left --[[:! Expr]])
    local r = simplify(ast.right --[[:! Expr]])
    if l.op == "num" and r.op == "num" then
      local lv = l.value --[[:! number]]
      local rv = r.value --[[:! number]]
      local v = 0 --: number
      if op == "add" then v = lv + rv
      elseif op == "sub" then v = lv - rv
      elseif op == "mul" then v = lv * rv
      elseif op == "div" then v = lv / rv
      elseif op == "pow" then v = lv ^ rv
      elseif op == "mod" then v = lv % rv
      end
      return make_num(v)
    end
    -- algebraic identities
    local lnum = l.op == "num" and (l.value --[[:! number]]) or nil --: number | nil
    local rnum = r.op == "num" and (r.value --[[:! number]]) or nil --: number | nil
    if op == "mul" then
      if lnum == 0 or rnum == 0 then return make_num(0) end
      if lnum == 1 then return r end
      if rnum == 1 then return l end
    elseif op == "add" then
      if lnum == 0 then return r end
      if rnum == 0 then return l end
    elseif op == "sub" then
      if rnum == 0 then return l end
    elseif op == "div" then
      if rnum == 1 then return l end
    elseif op == "pow" then
      if rnum == 0 then return make_num(1) end
      if rnum == 1 then return l end
      if lnum == 1 then return make_num(1) end
    end
    return --[[:! Expr]] {op=op, left=l, right=r}
  elseif op == "cmp" then
    local l = simplify(ast.left --[[:! Expr]])
    local r = simplify(ast.right --[[:! Expr]])
    if l.op == "num" and r.op == "num" then
      local lv = l.value --[[:! number]]
      local rv = r.value --[[:! number]]
      local cmp = ast.cmp --[[:! string]]
      local result --: boolean | nil
      if cmp == "<"  then result = lv < rv
      elseif cmp == "<=" then result = lv <= rv
      elseif cmp == ">"  then result = lv > rv
      elseif cmp == ">=" then result = lv >= rv
      elseif cmp == "==" then result = lv == rv
      elseif cmp == "!=" then result = lv ~= rv
      end
      return make_num(result and 1 or 0)
    end
    return --[[:! Expr]] {op="cmp", cmp=ast.cmp --[[:! string]], left=l, right=r}
  elseif op == "ternary" then
    local c = simplify(ast.cond --[[:! Expr]])
    local t = simplify(ast.then_ --[[:! Expr]])
    local e = simplify(ast.else_ --[[:! Expr]])
    if c.op == "num" then
      return (c.value --[[:! number]]) ~= 0 and t or e
    end
    return --[[:! Expr]] {op="ternary", cond=c, then_=t, else_=e}
  end
  return ast
end

-- ─── symbolic differentiation ─────────────────────────────────────────────

local diff  -- forward declaration

--: (Expr, string) -> Expr
diff = function(ast, var)
  local op = ast.op
  if op == "num" then
    return ZERO
  elseif op == "var" then
    return (ast.name --[[:! string]]) == var and ONE or ZERO
  elseif op == "neg" then
    return make_neg(diff(ast.arg --[[:! Expr]], var))
  elseif op == "add" then
    return make_add(diff(ast.left --[[:! Expr]], var), diff(ast.right --[[:! Expr]], var))
  elseif op == "sub" then
    return make_sub(diff(ast.left --[[:! Expr]], var), diff(ast.right --[[:! Expr]], var))
  elseif op == "mul" then
    -- product rule: u'v + uv'
    local left = ast.left --[[:! Expr]]
    local right = ast.right --[[:! Expr]]
    return make_add(
      make_mul(diff(left, var), right),
      make_mul(left, diff(right, var))
    )
  elseif op == "div" then
    -- quotient rule: (u'v - uv') / v^2
    local left = ast.left --[[:! Expr]]
    local right = ast.right --[[:! Expr]]
    return make_div(
      make_sub(
        make_mul(diff(left, var), right),
        make_mul(left, diff(right, var))
      ),
      make_pow(right, make_num(2))
    )
  elseif op == "pow" then
    local base = ast.left --[[:! Expr]]
    local exp_ = ast.right --[[:! Expr]]
    -- check if exponent is a constant
    if exp_.op == "num" then
      -- d/dx(u^n) = n * u^(n-1) * u'
      local n = exp_.value --[[:! number]]
      return simplify(make_mul(
        make_mul(make_num(n), make_pow(base, make_num(n-1))),
        diff(base, var)
      ))
    elseif base.op == "num" then
      -- d/dx(a^v) = a^v * ln(a) * v'
      local bv = base.value --[[:! number]]
      return simplify(make_mul(
        make_mul(ast, make_num(math.log(bv))),
        diff(exp_, var)
      ))
    else
      -- general: d/dx(u^v) = u^v * (v'*ln(u) + v*u'/u)
      return simplify(make_mul(
        ast,
        make_add(
          make_mul(diff(exp_, var), make_call("log", {base})),
          make_mul(exp_, make_div(diff(base, var), base))
        )
      ))
    end
  elseif op == "mod" then
    -- d/dx(u % v) treated as u - v*floor(u/v)
    -- derivative of floor = 0 a.e., so approx: u'
    return diff(ast.left --[[:! Expr]], var)
  elseif op == "call" then
    local name = ast.name --[[:! string]]
    local args = ast.args --[[:! { [integer]: Expr }]]
    local x = args[1]
    if name == "sin" then
      -- d/dx sin(u) = cos(u) * u'
      return simplify(make_mul(make_call("cos", {x}), diff(x, var)))
    elseif name == "cos" then
      -- d/dx cos(u) = -sin(u) * u'
      return simplify(make_mul(make_neg(make_call("sin", {x})), diff(x, var)))
    elseif name == "tan" then
      -- d/dx tan(u) = u' / cos^2(u)
      return simplify(make_div(diff(x, var), make_pow(make_call("cos", {x}), make_num(2))))
    elseif name == "sqrt" then
      -- d/dx sqrt(u) = u' / (2*sqrt(u))
      return simplify(make_div(diff(x, var), make_mul(make_num(2), make_call("sqrt", {x}))))
    elseif name == "exp" then
      -- d/dx exp(u) = exp(u) * u'
      return simplify(make_mul(ast, diff(x, var)))
    elseif name == "log" then
      -- d/dx log(u) = u'/u
      return simplify(make_div(diff(x, var), x))
    elseif name == "log2" then
      -- d/dx log2(u) = u' / (u * ln(2))
      return simplify(make_div(diff(x, var), make_mul(x, make_num(math.log(2)))))
    elseif name == "log10" then
      return simplify(make_div(diff(x, var), make_mul(x, make_num(math.log(10)))))
    elseif name == "asin" then
      -- d/dx asin(u) = u' / sqrt(1 - u^2)
      return simplify(make_div(diff(x, var),
        make_call("sqrt", {make_sub(make_num(1), make_pow(x, make_num(2)))})))
    elseif name == "acos" then
      -- d/dx acos(u) = -u' / sqrt(1 - u^2)
      return simplify(make_neg(make_div(diff(x, var),
        make_call("sqrt", {make_sub(make_num(1), make_pow(x, make_num(2)))}))))
    elseif name == "atan" then
      -- d/dx atan(u) = u' / (1 + u^2)
      return simplify(make_div(diff(x, var),
        make_add(make_num(1), make_pow(x, make_num(2)))))
    elseif name == "abs" then
      -- d/dx |u| = u' * sign(u)  (undefined at 0, return as-is in symbolic form)
      -- represent as u / abs(u) * u'
      return simplify(make_mul(make_div(x, ast), diff(x, var)))
    elseif name == "floor" or name == "ceil" or name == "round" then
      -- derivative is 0 almost everywhere
      return ZERO
    elseif name == "atan2" then
      -- atan2(y, x): treat as atan(y/x) for single-variable diff
      -- d/dx atan2(y,x) = (x*y' - y*x') / (x^2 + y^2)
      local y_arg = args[1]
      local x_arg = args[2]
      return simplify(make_div(
        make_sub(
          make_mul(x_arg, diff(y_arg, var)),
          make_mul(y_arg, diff(x_arg, var))
        ),
        make_add(make_pow(x_arg, make_num(2)), make_pow(y_arg, make_num(2)))
      ))
    end
    -- fallback: treat as constant w.r.t. var
    return ZERO
  elseif op == "cmp" or op == "ternary" then
    -- not differentiable in general
    return ZERO
  end
  return ZERO
end

-- ─── vars ──────────────────────────────────────────────────────────────────

--: (Expr, { [string]: boolean } | nil) -> { [string]: boolean }
local function vars(ast, out)
  out = out or {}
  local op = ast.op
  if op == "var" then
    local name = ast.name --[[:! string]]
    if not CONSTS[name] then
      out[name] = true
    end
  elseif op == "neg" then
    vars(ast.arg --[[:! Expr]], out)
  elseif op == "call" then
    for _, a in ipairs(ast.args --[[:! { [integer]: Expr }]]) do vars(a, out) end
  elseif op == "add" or op == "sub" or op == "mul" or op == "div" or
         op == "pow" or op == "mod" then
    vars(ast.left --[[:! Expr]], out)
    vars(ast.right --[[:! Expr]], out)
  elseif op == "cmp" then
    vars(ast.left --[[:! Expr]], out)
    vars(ast.right --[[:! Expr]], out)
  elseif op == "ternary" then
    vars(ast.cond --[[:! Expr]], out)
    vars(ast.then_ --[[:! Expr]], out)
    vars(ast.else_ --[[:! Expr]], out)
  end
  return out
end

-- ─── public API ────────────────────────────────────────────────────────────

M.parse = function(str)
  local tokens, err = lex(str)
  if not tokens then return nil, err end
  return parse_tokens(tokens)
end

M.eval_ast = eval_ast

M.eval = function(str, env)
  local ast, err = M.parse(str)
  if not ast then return nil, err end
  return eval_ast(ast, env)
end

M.compile = function(str)
  local ast, err = M.parse(str)
  if not ast then return nil, err end
  local fn = function(env)
    return eval_ast(ast, env)
  end
  return fn
end

M.to_string = function(ast)
  return to_string(ast, 0, false)
end

M.simplify = simplify

M.diff = diff

M.vars = vars

return M
