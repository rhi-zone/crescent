if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Exact decimal arithmetic for crescent.
-- Represents decimals as {coeff=integer, exp=integer}, value = coeff * 10^exp.
-- Safe for financial/display math up to ~2^53 coefficient magnitude.
-- Pure Lua, no dependencies.

local M = {}
M._tier = "pure"

local floor  = math.floor
local abs    = math.abs
local max    = math.max
local min    = math.min
local huge   = math.huge

--:: Decimal = { coeff: number, exp: number }

-- ── Internal helpers ──────────────────────────────────────────────────────────

-- Remove trailing zeros from coefficient, adjust exponent accordingly.
-- Special case: zero always normalizes to {0, 0}.
--: (number, number) -> (number, number)
local function normalize(coeff, exp)
  if coeff == 0 then return 0, 0 end
  while coeff % 10 == 0 do
    coeff = coeff / 10
    exp   = exp + 1
  end
  return coeff, exp
end

-- Construct a decimal table (internal, skips normalization).
--: (number, number) -> Decimal
local function make(coeff, exp)
  return { coeff = coeff, exp = exp }
end

-- Align two decimals to the same exponent for add/sub/cmp.
-- Returns ac, bc, common_exp.
--: (Decimal, Decimal) -> (number, number, number)
local function align(a, b)
  if a.exp == b.exp then return a.coeff, b.coeff, a.exp end
  if a.exp > b.exp then
    local diff   = a.exp - b.exp
    local factor = 10 ^ diff
    return a.coeff * factor, b.coeff, b.exp
  else
    local diff   = b.exp - a.exp
    local factor = 10 ^ diff
    return a.coeff, b.coeff * factor, a.exp
  end
end

-- Round a raw integer coefficient that sits at `exp` to `places` decimal places.
-- Returns new_coeff, new_exp.
--: (number, number, number, string | nil) -> (number, number)
local function round_coeff(coeff, exp, places, mode)
  local target_exp = -places
  if exp >= target_exp then
    -- Already at or coarser than target precision; scale up if needed.
    if exp > target_exp then
      local factor = 10 ^ (exp - target_exp)
      return coeff * factor, target_exp
    end
    return coeff, exp
  end
  -- Need to drop (exp - target_exp) extra digits, i.e. shift = target_exp - exp.
  local shift   = target_exp - exp
  local factor  = 10 ^ shift
  local sign    = coeff < 0 and -1 or 1
  local acoeff  = abs(coeff)
  local truncated = floor(acoeff / factor)
  local remainder = acoeff - truncated * factor
  local half      = factor / 2

  mode = mode or "half_up"

  local round_up = false
  if mode == "half_up" then
    round_up = remainder * 2 >= factor
  elseif mode == "half_down" then
    round_up = remainder * 2 > factor
  elseif mode == "half_even" then
    if remainder * 2 > factor then
      round_up = true
    elseif remainder * 2 == factor then
      round_up = (truncated % 2) ~= 0
    end
  elseif mode == "floor" then
    round_up = (sign < 0 and remainder ~= 0) and true or false
  elseif mode == "ceil" then
    round_up = (sign > 0 and remainder ~= 0) and true or false
  elseif mode == "truncate" then
    round_up = false
  else
    error("decimal: unknown rounding mode: " .. tostring(mode))
  end

  if round_up then truncated = truncated + 1 end
  return sign * truncated, target_exp
end

-- ── Constructor ───────────────────────────────────────────────────────────────

--- Parse a decimal value from a number, string, or integer.
-- @param value  number | string | integer
-- @param scale  optional: explicit decimal places (rounds/pads result)
-- @return decimal
function M.new(value, scale)
  local coeff, exp

  local t = type(value)
  if t == "number" then
    -- Convert float to string to get exact decimal representation,
    -- then parse that string. This avoids double-rounding from float literals.
    value = tostring(value)
    t = "string"
  end

  if t == "string" then
    local value_str = value --[[:! string]]
    -- Handle scientific notation: [sign][digits][.digits][e[+-]digits]
    local sign_str, int_part, frac_part, e_sign, e_digits =
      value_str:match("^([+-]?)(%d+)%.?(%d*)[eE]([+-]?)(%d+)$")

    if sign_str then
      -- Scientific notation
      local frac_part_ = frac_part --[[:! string]]
      local int_part_  = int_part  --[[:! string]]
      local e_digits_  = e_digits  --[[:! string]]
      local e_sign_    = e_sign    --[[:! string]]
      local mantissa_exp = -(#frac_part_)
      local digits_str   = int_part_ .. frac_part_
      coeff = tonumber(digits_str) or 0
      local e_num = tonumber(e_digits_) or 0
      exp   = mantissa_exp + (e_sign_ == "-" and -1 or 1) * e_num
      if sign_str == "-" then coeff = -coeff end
    else
      -- Plain decimal: [sign][digits][.digits]
      local s, i, f = value_str:match("^([+-]?)(%d+)%.?(%d*)$")
      if not s then
        return nil, "decimal.new: cannot parse '" .. tostring(value) .. "'"
      end
      local s_ = s --[[:! string]]
      local i_ = i --[[:! string]]
      local f_ = f --[[:! string]]
      frac_part = f_ or ""
      coeff = tonumber(i_ .. frac_part) or 0
      exp   = -(#frac_part)
      if s_ == "-" then coeff = -coeff end
    end
  else
    return nil, "decimal.new: unsupported type " .. t
  end

  local coeff_ = (coeff or 0)
  local exp_   = (exp or 0)
  coeff_, exp_ = normalize(coeff_, exp_)
  local d = make(coeff_, exp_)

  if scale then
    local nc, ne = round_coeff(coeff_, exp_, scale, "half_up")
    d = make(nc, ne)
  end

  return d
end

--- Strict parse — returns nil, err if unparseable.
function M.parse(s)
  if type(s) ~= "string" then
    return nil, "decimal.parse: expected string, got " .. type(s)
  end
  return M.new(s)
end

-- ── Arithmetic ────────────────────────────────────────────────────────────────

local decimal_mt  -- forward declaration; set at bottom

local function wrap(coeff, exp)
  local c, e = normalize(coeff, exp)
  local d = make(c, e)
  setmetatable(d, decimal_mt)
  return d
end

--- Add two decimals.
function M.add(a, b)
  local a_ = a --[[:! Decimal]]
  local b_ = b --[[:! Decimal]]
  local ac, bc, e = align(a_, b_)
  return wrap(ac + bc, e)
end

--- Subtract b from a.
function M.sub(a, b)
  local a_ = a --[[:! Decimal]]
  local b_ = b --[[:! Decimal]]
  local ac, bc, e = align(a_, b_)
  return wrap(ac - bc, e)
end

--- Multiply two decimals.
function M.mul(a, b)
  local a_ = a --[[:! Decimal]]
  local b_ = b --[[:! Decimal]]
  return wrap(a_.coeff * b_.coeff, a_.exp + b_.exp)
end

--- Divide a by b, result has `scale` decimal places (default 10).
--: (Decimal, Decimal, integer | nil) -> (Decimal | nil, string | nil)
function M.div(a, b, scale)
  local a_ = a --[[:! Decimal]]
  local b_ = b --[[:! Decimal]]
  if b_.coeff == 0 then
    return nil, "decimal.div: division by zero"
  else
  scale = scale or 10
  -- We want result = a / b with `scale` fractional digits.
  -- value(a) = a.coeff * 10^a.exp,  value(b) = b.coeff * 10^b.exp
  -- result = value(a)/value(b) = (a.coeff/b.coeff) * 10^(a.exp - b.exp)
  -- We want result_coeff * 10^(-scale) = result, so:
  --   result_coeff = a.coeff * 10^(a.exp - b.exp + scale) / b.coeff
  local extra = a_.exp - b_.exp + scale   -- may be negative
  local scaled_a
  if extra >= 0 then
    scaled_a = a_.coeff * (10 ^ extra)
  else
    scaled_a = a_.coeff / (10 ^ (-extra))
  end
  -- Perform rounding at the last digit (half_up).
  local raw       = scaled_a / b_.coeff
  local sign_r    = raw < 0 and -1 or 1
  local araw      = abs(raw)
  local int_part  = floor(araw)
  local frac_part = araw - int_part
  local result_coeff
  if frac_part * 2 >= 1 then
    result_coeff = sign_r * (int_part + 1)
  else
    result_coeff = sign_r * int_part
  end
  return wrap(result_coeff, -scale)
  end
end

--- Negate a decimal.
function M.neg(a)
  local a_ = a --[[:! Decimal]]
  return wrap(-a_.coeff, a_.exp)
end

--- Absolute value.
function M.abs_val(a)
  local a_ = a --[[:! Decimal]]
  return wrap(abs(a_.coeff), a_.exp)
end

-- ── Rounding ──────────────────────────────────────────────────────────────────

--- Round to `places` decimal places using `mode`.
function M.round(a, places, mode)
  local a_ = a --[[:! Decimal]]
  places = places or 0
  local nc, ne = round_coeff(a_.coeff, a_.exp, places, mode or "half_up")
  return wrap(nc, ne)
end

-- ── Comparison ────────────────────────────────────────────────────────────────

--- Compare two decimals. Returns -1, 0, or 1.
function M.cmp(a, b)
  local a_ = a --[[:! Decimal]]
  local b_ = b --[[:! Decimal]]
  local ac, bc, _ = align(a_, b_)
  if ac < bc then return -1
  elseif ac > bc then return 1
  else return 0
  end
end

function M.eq(a, b)  return M.cmp(a, b) == 0  end
function M.lt(a, b)  return M.cmp(a, b) <  0  end
function M.le(a, b)  return M.cmp(a, b) <= 0  end

-- ── Conversion ────────────────────────────────────────────────────────────────

--- Convert to string representation (e.g. "1.23", "100", "-0.05").
function M.to_string(a)
  local a_ = a --[[:! Decimal]]
  local coeff = a_.coeff
  local exp   = a_.exp

  if exp == 0 then
    return tostring(coeff)
  end

  local sign_str = ""
  local acoeff   = coeff
  if coeff < 0 then
    sign_str = "-"
    acoeff   = -coeff
  end

  local s = tostring(acoeff)

  if exp > 0 then
    -- Positive exponent: append zeros
    return sign_str .. s .. string.rep("0", math.floor(exp))
  else
    -- Negative exponent: insert decimal point
    local dec_pos = #s + exp   -- position of decimal point from left
    if dec_pos <= 0 then
      -- Need leading zeros after "0."
      return sign_str .. "0." .. string.rep("0", math.floor(-dec_pos)) .. s
    elseif dec_pos >= #s then
      -- No fractional part (shouldn't happen after normalize, but defensive)
      return sign_str .. s
    else
      local dp = math.floor(dec_pos)
      return sign_str .. s:sub(1, dp) .. "." .. s:sub(dp + 1)
    end
  end
end

--- Convert to Lua number (may lose precision).
function M.to_number(a)
  local a_ = a --[[:! Decimal]]
  return a_.coeff * (10 ^ a_.exp)
end

--- Convert to integer (truncates fractional part).
function M.to_integer(a)
  return floor(M.to_number(a))
end

--- Number of decimal places (positive = fractional digits).
function M.scale(a)
  local a_ = a --[[:! Decimal]]
  if a_.exp >= 0 then return 0 end
  return -a_.exp
end

-- ── Properties ────────────────────────────────────────────────────────────────

function M.is_zero(a)     local a_ = a --[[:! Decimal]]; return a_.coeff == 0          end
function M.is_negative(a) local a_ = a --[[:! Decimal]]; return a_.coeff < 0            end
function M.sign(a)
  local a_ = a --[[:! Decimal]]
  if a_.coeff > 0 then return 1
  elseif a_.coeff < 0 then return -1
  else return 0
  end
end

-- ── Utility ───────────────────────────────────────────────────────────────────

function M.max(a, b) return M.cmp(a, b) >= 0 and a or b end
function M.min(a, b) return M.cmp(a, b) <= 0 and a or b end

function M.sum(decimals)
  local acc = M.ZERO  -- forward reference; set after ZERO is defined below
  -- Can't use M.ZERO here (not yet defined), so start with nil check pattern.
  -- We overwrite this function after ZERO is set.
  for i = 1, #decimals do
    acc = M.add(acc, decimals[i])
  end
  return acc
end

function M.average(decimals)
  if #decimals == 0 then
    return nil, "decimal.average: empty list"
  end
  local s = make(0, 0)
  setmetatable(s, decimal_mt)
  for i = 1, #decimals do
    s = M.add(s, decimals[i])
  end
  return M.div(s --[[:! Decimal]], M.new(#decimals) --[[:! Decimal]], 10)
end

-- ── Metamethods ───────────────────────────────────────────────────────────────

decimal_mt = {
  __add      = function(a, b) return M.add(a, b) end,
  __sub      = function(a, b) return M.sub(a, b) end,
  __mul      = function(a, b) return M.mul(a, b) end,
  __div      = function(a, b) return M.div(a, b) end,
  __unm      = function(a)    return M.neg(a) end,
  __eq       = function(a, b) return M.eq(a, b) end,
  __lt       = function(a, b) return M.lt(a, b) end,
  __le       = function(a, b) return M.le(a, b) end,
  __tostring = function(a)    return M.to_string(a) end,

  -- Method-style access: d:add(b), d:round(2), etc.
  __index = function(self, key)
    local M_ = M --[[: unknown]]
    local fn = M_[key]
    if fn then
      return function(s, ...) return fn(s, ...) end
    end
  end,
}

-- Wrap the internal `make` so all public decimals carry the metatable.
--: (number, number) -> Decimal
local function new_decimal(coeff, exp)
  local d = make(coeff, exp)
  setmetatable(d, decimal_mt)
  return d
end

-- Re-implement wrap with metatable.
wrap = function(coeff, exp)
  local c, e = normalize(coeff, exp)
  return new_decimal(c, e)
end

-- ── Constants ─────────────────────────────────────────────────────────────────

M.ZERO = new_decimal(0, 0)
M.ONE  = new_decimal(1, 0)

-- Fix sum to use the now-defined ZERO.
function M.sum(decimals)
  local acc = M.ZERO
  for i = 1, #decimals do
    acc = M.add(acc, decimals[i])
  end
  return acc
end

-- ── Public M.new wraps result with metatable ──────────────────────────────────

local _new_inner = M.new
function M.new(value, scale)
  local d, err = _new_inner(value, scale)
  if not d then return nil, err end
  setmetatable(d, decimal_mt)
  return d
end

-- Also wrap M.parse.
local _parse_inner = M.parse
function M.parse(s)
  local d, err = _parse_inner(s)
  if not d then return nil, err end
  setmetatable(d, decimal_mt)
  return d
end

return M
