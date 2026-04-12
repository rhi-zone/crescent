-- lib/symbolic_diff/init.lua
-- Symbolic differentiation of mathematical expressions.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Expression metatable — enables operator overloading
-- ---------------------------------------------------------------------------

local Expr = {}
Expr.__index = Expr

local function wrap(v)
  if type(v) == "number" then return M.num(v) end
  return v
end

Expr.__add = function(a, b) return M.add(wrap(a), wrap(b)) end
Expr.__sub = function(a, b) return M.sub(wrap(a), wrap(b)) end
Expr.__mul = function(a, b) return M.mul(wrap(a), wrap(b)) end
Expr.__div = function(a, b) return M.div(wrap(a), wrap(b)) end
Expr.__pow = function(a, b) return M.pow(wrap(a), wrap(b)) end
Expr.__unm = function(a)    return M.neg(a) end
Expr.__tostring = function(a) return M.tostring(a) end

local function node(t)
  return setmetatable(t, Expr)
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

function M.num(v)
  return node({ tag = "num", value = v })
end

function M.var(name)
  return node({ tag = "var", name = name })
end

function M.add(left, right)
  return node({ tag = "add", left = left, right = right })
end

function M.sub(left, right)
  return node({ tag = "sub", left = left, right = right })
end

function M.mul(left, right)
  return node({ tag = "mul", left = left, right = right })
end

function M.div(left, right)
  return node({ tag = "div", left = left, right = right })
end

function M.pow(base, exp)
  return node({ tag = "pow", base = base, exp = exp })
end

function M.neg(arg)
  return node({ tag = "neg", arg = arg })
end

function M.sin(arg)
  return node({ tag = "sin", arg = arg })
end

function M.cos(arg)
  return node({ tag = "cos", arg = arg })
end

function M.ln(arg)
  return node({ tag = "ln", arg = arg })
end

function M.exp(arg)
  return node({ tag = "exp", arg = arg })
end

-- ---------------------------------------------------------------------------
-- tostring
-- ---------------------------------------------------------------------------

local TOSTR  -- forward ref

TOSTR = function(e)
  local t = e.tag
  if t == "num" then
    -- display integers without decimal point
    local v = e.value
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return tostring(math.floor(v))
    end
    return tostring(v)
  elseif t == "var" then
    return e.name
  elseif t == "add" then
    return "(" .. TOSTR(e.left) .. " + " .. TOSTR(e.right) .. ")"
  elseif t == "sub" then
    return "(" .. TOSTR(e.left) .. " - " .. TOSTR(e.right) .. ")"
  elseif t == "mul" then
    return "(" .. TOSTR(e.left) .. " * " .. TOSTR(e.right) .. ")"
  elseif t == "div" then
    return "(" .. TOSTR(e.left) .. " / " .. TOSTR(e.right) .. ")"
  elseif t == "pow" then
    return "(" .. TOSTR(e.base) .. " ^ " .. TOSTR(e.exp) .. ")"
  elseif t == "neg" then
    return "(-" .. TOSTR(e.arg) .. ")"
  elseif t == "sin" then
    return "sin(" .. TOSTR(e.arg) .. ")"
  elseif t == "cos" then
    return "cos(" .. TOSTR(e.arg) .. ")"
  elseif t == "ln" then
    return "ln(" .. TOSTR(e.arg) .. ")"
  elseif t == "exp" then
    return "exp(" .. TOSTR(e.arg) .. ")"
  else
    return "?(" .. t .. ")"
  end
end

function M.tostring(e)
  return TOSTR(e)
end

-- ---------------------------------------------------------------------------
-- eval — substitute variables and evaluate to a number
-- ---------------------------------------------------------------------------

local EVAL  -- forward ref

EVAL = function(e, env)
  local t = e.tag
  if t == "num" then
    return e.value
  elseif t == "var" then
    local v = env[e.name]
    if v == nil then
      error("symbolic_diff.eval: unbound variable '" .. e.name .. "'")
    end
    return v
  elseif t == "add" then
    return EVAL(e.left, env) + EVAL(e.right, env)
  elseif t == "sub" then
    return EVAL(e.left, env) - EVAL(e.right, env)
  elseif t == "mul" then
    return EVAL(e.left, env) * EVAL(e.right, env)
  elseif t == "div" then
    return EVAL(e.left, env) / EVAL(e.right, env)
  elseif t == "pow" then
    return EVAL(e.base, env) ^ EVAL(e.exp, env)
  elseif t == "neg" then
    return -EVAL(e.arg, env)
  elseif t == "sin" then
    return math.sin(EVAL(e.arg, env))
  elseif t == "cos" then
    return math.cos(EVAL(e.arg, env))
  elseif t == "ln" then
    return math.log(EVAL(e.arg, env))
  elseif t == "exp" then
    return math.exp(EVAL(e.arg, env))
  else
    error("symbolic_diff.eval: unknown tag '" .. t .. "'")
  end
end

function M.eval(e, env)
  return EVAL(e, env or {})
end

-- ---------------------------------------------------------------------------
-- simplify — basic algebraic simplification
-- ---------------------------------------------------------------------------

local SIMP  -- forward ref

local function is_num(e)       return e.tag == "num" end
local function is_zero(e)      return e.tag == "num" and e.value == 0 end
local function is_one(e)       return e.tag == "num" and e.value == 1 end
local function num_val(e)      return e.value end

SIMP = function(e)
  local t = e.tag

  if t == "num" or t == "var" then
    return e

  elseif t == "neg" then
    local a = SIMP(e.arg)
    -- --x = x
    if a.tag == "neg" then return a.arg end
    -- -(num) → num
    if is_num(a) then return M.num(-a.value) end
    return M.neg(a)

  elseif t == "add" then
    local l = SIMP(e.left)
    local r = SIMP(e.right)
    if is_num(l) and is_num(r) then return M.num(l.value + r.value) end
    if is_zero(l) then return r end
    if is_zero(r) then return l end
    return M.add(l, r)

  elseif t == "sub" then
    local l = SIMP(e.left)
    local r = SIMP(e.right)
    if is_num(l) and is_num(r) then return M.num(l.value - r.value) end
    if is_zero(r) then return l end
    if is_zero(l) then return SIMP(M.neg(r)) end
    return M.sub(l, r)

  elseif t == "mul" then
    local l = SIMP(e.left)
    local r = SIMP(e.right)
    if is_num(l) and is_num(r) then return M.num(l.value * r.value) end
    if is_zero(l) or is_zero(r) then return M.num(0) end
    if is_one(l) then return r end
    if is_one(r) then return l end
    return M.mul(l, r)

  elseif t == "div" then
    local l = SIMP(e.left)
    local r = SIMP(e.right)
    if is_num(l) and is_num(r) then return M.num(l.value / r.value) end
    if is_zero(l) then return M.num(0) end
    if is_one(r) then return l end
    return M.div(l, r)

  elseif t == "pow" then
    local b = SIMP(e.base)
    local x = SIMP(e.exp)
    if is_num(b) and is_num(x) then return M.num(b.value ^ x.value) end
    if is_zero(x) then return M.num(1) end
    if is_one(x)  then return b end
    if is_one(b)  then return M.num(1) end
    return M.pow(b, x)

  elseif t == "sin" then
    local a = SIMP(e.arg)
    if is_num(a) then return M.num(math.sin(a.value)) end
    return M.sin(a)

  elseif t == "cos" then
    local a = SIMP(e.arg)
    if is_num(a) then return M.num(math.cos(a.value)) end
    return M.cos(a)

  elseif t == "ln" then
    local a = SIMP(e.arg)
    if is_num(a) then return M.num(math.log(a.value)) end
    return M.ln(a)

  elseif t == "exp" then
    local a = SIMP(e.arg)
    if is_num(a) then return M.num(math.exp(a.value)) end
    return M.exp(a)

  else
    return e
  end
end

function M.simplify(e)
  -- iterate simplification to fixpoint (max 20 passes)
  local prev = nil
  local cur  = e
  for _ = 1, 20 do
    cur = SIMP(cur)
    local s = TOSTR(cur)
    if s == prev then break end
    prev = s
  end
  return cur
end

-- ---------------------------------------------------------------------------
-- diff — symbolic differentiation with respect to variable name
-- ---------------------------------------------------------------------------

local DIFF  -- forward ref

local ZERO = M.num(0)
local ONE  = M.num(1)

DIFF = function(e, v)
  local t = e.tag

  if t == "num" then
    -- d/dx(c) = 0
    return ZERO

  elseif t == "var" then
    -- d/dx(x) = 1, d/dx(y) = 0
    return e.name == v and ONE or ZERO

  elseif t == "neg" then
    -- d/dx(-f) = -f'
    return M.neg(DIFF(e.arg, v))

  elseif t == "add" then
    -- (f + g)' = f' + g'
    return M.add(DIFF(e.left, v), DIFF(e.right, v))

  elseif t == "sub" then
    -- (f - g)' = f' - g'
    return M.sub(DIFF(e.left, v), DIFF(e.right, v))

  elseif t == "mul" then
    -- product rule: (f*g)' = f'*g + f*g'
    local f, g = e.left, e.right
    return M.add(
      M.mul(DIFF(f, v), g),
      M.mul(f, DIFF(g, v))
    )

  elseif t == "div" then
    -- quotient rule: (f/g)' = (f'*g - f*g') / g^2
    local f, g = e.left, e.right
    return M.div(
      M.sub(
        M.mul(DIFF(f, v), g),
        M.mul(f, DIFF(g, v))
      ),
      M.pow(g, M.num(2))
    )

  elseif t == "pow" then
    local f, g = e.base, e.exp
    -- Check if exponent is a numeric constant → simple power rule
    if g.tag == "num" then
      -- d/dx(f^n) = n * f^(n-1) * f'
      local n = g.value
      return M.mul(
        M.mul(M.num(n), M.pow(f, M.num(n - 1))),
        DIFF(f, v)
      )
    else
      -- General case: d/dx(f^g) = f^g * (g'*ln(f) + g*f'/f)
      return M.mul(
        M.pow(f, g),
        M.add(
          M.mul(DIFF(g, v), M.ln(f)),
          M.mul(g, M.div(DIFF(f, v), f))
        )
      )
    end

  elseif t == "sin" then
    -- d/dx(sin(f)) = cos(f)*f'
    return M.mul(M.cos(e.arg), DIFF(e.arg, v))

  elseif t == "cos" then
    -- d/dx(cos(f)) = -sin(f)*f'
    return M.mul(M.neg(M.sin(e.arg)), DIFF(e.arg, v))

  elseif t == "ln" then
    -- d/dx(ln(f)) = f'/f
    return M.div(DIFF(e.arg, v), e.arg)

  elseif t == "exp" then
    -- d/dx(exp(f)) = exp(f)*f'
    return M.mul(M.exp(e.arg), DIFF(e.arg, v))

  else
    error("symbolic_diff.diff: unknown tag '" .. t .. "'")
  end
end

function M.diff(e, v)
  return DIFF(e, v)
end

-- ---------------------------------------------------------------------------
-- gradient — partial derivatives for a list of variable names
-- ---------------------------------------------------------------------------

function M.gradient(e, vars)
  local grad = {}
  for i = 1, #vars do
    local name = vars[i]
    grad[name] = M.diff(e, name)
  end
  return grad
end

return M
