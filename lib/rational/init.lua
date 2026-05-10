-- lib/rational/init.lua
-- Exact rational arithmetic over native Lua integers (exact range ~2^53).
-- GCD-normalized, denominator always positive.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Euclidean GCD (always returns non-negative integer)
--: (a: number, b: number) -> number
local function gcd(a, b)
  a = a < 0 and -a or a
  b = b < 0 and -b or b
  while b ~= 0 do
    local t = b
    b = a % b
    a = t
  end
  return a
end

-- Internal constructor — skips validation, used after arithmetic.
-- p, q must already be integers; q must be > 0; both divided by gcd.
local rat_mt  -- forward declaration

--: (p: number, q: number) -> { p: number, q: number }
local function make(p, q)
  local g = gcd(p, q)
  if g ~= 0 then
    p = p / g
    q = q / g
  end
  -- ensure denominator positive
  if q < 0 then p = -p; q = -q end
  return setmetatable({ p = p, q = q }, rat_mt)
end

-- Check that a value is an exact integer (fits in double integer range).
--: (x: unknown) -> x is number
local function is_int(x)
  if type(x) ~= "number" then return false end
  return math.floor(x) == x
end

-- Public constructor.
-- M.new(p)      -> p/1
-- M.new(p, q)   -> p/q normalized
-- M.new(r)      -> copy of rational r
-- Returns rational, or (nil, errmsg).
function M.new(p, q)
  -- copy / passthrough
  if type(p) == "table" then
    local pt = p --[[: { p: number | nil, q: number | nil, ... }]]
    local pp, pq = pt.p, pt.q
    if pp ~= nil and pq ~= nil then
      if q ~= nil then
        return nil, "rational.new: unexpected second argument when first is rational"
      end
      return make(pp, pq)
    end
  end
  if q == nil then q = 1 end
  if not is_int(p) then
    return nil, "rational.new: numerator must be an integer, got " .. tostring(p)
  end
  if not is_int(q) then
    return nil, "rational.new: denominator must be an integer, got " .. tostring(q)
  end
  if q == 0 then
    return nil, "rational.new: denominator cannot be zero"
  end
  return make(p, q)
end

-- Coerce a value to rational internals {p,q}; returns p, q or errors via
-- returning nil + message. Used internally so methods accept both rationals
-- and plain integers.
--: (x: unknown) -> (number | nil, number | string)
local function coerce(x)
  if type(x) == "table" then
    local xt = x --[[: { p: number, q: number, ... }]]
    if xt.p ~= nil and xt.q ~= nil then
      return xt.p, xt.q
    end
  end
  if type(x) == "number" and is_int(x) then
    return x, 1
  end
  return nil, "rational: expected rational or integer, got " .. tostring(x)
end

-- Arithmetic --

function M.add(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return nil, bq end
  -- a/aq + b/bq = (ap*bq + bp*aq) / (aq*bq)
  return make(ap * bq + bp * aq, aq * bq)
end

function M.sub(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return nil, bq end
  return make(ap * bq - bp * aq, aq * bq)
end

function M.mul(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return nil, bq end
  return make(ap * bp, aq * bq)
end

function M.div(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return nil, bq end
  if bp == 0 then
    return nil, "rational.div: division by zero"
  end
  -- a/aq / (bp/bq) = (ap*bq) / (aq*bp)
  return make(ap * bq, aq * bp)
end

function M.neg(a)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  return make(-ap, aq)
end

function M.abs(a)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  return make(ap < 0 and -ap or ap, aq)
end

function M.inv(a)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  if ap == 0 then
    return nil, "rational.inv: inversion of zero"
  end
  return make(aq, ap)
end

function M.pow(a, n)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return nil, aq end
  if not is_int(n) then
    return nil, "rational.pow: exponent must be an integer, got " .. tostring(n)
  end
  if n == 0 then
    return make(1, 1)
  end
  if n < 0 then
    if ap == 0 then
      return nil, "rational.pow: zero cannot be raised to a negative power"
    end
    -- (p/q)^-n = (q/p)^n
    ap, aq = aq, ap
    n = -n
  end
  -- integer exponentiation by squaring
  local rp = 1 --: number
  local rq = 1 --: number
  local bp2, bq2 = ap, aq
  while n > 0 do
    if n % 2 == 1 then
      rp = rp * bp2
      rq = rq * bq2
    end
    bp2 = bp2 * bp2
    bq2 = bq2 * bq2
    n = math.floor(n / 2)
  end
  return make(rp, rq)
end

-- Comparison --

function M.eq(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return false end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return false end
  -- already normalized, so p/q == r/s iff p==r and q==s
  return ap == bp and aq == bq
end

function M.lt(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return false end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return false end
  -- a/aq < b/bq  iff  ap*bq < bp*aq  (both denoms positive)
  return ap * bq < bp * aq
end

function M.le(a, b)
  local ap, aq = coerce(a)
  if ap == nil or type(aq) ~= "number" then return false end
  local bp, bq = coerce(b)
  if bp == nil or type(bq) ~= "number" then return false end
  return ap * bq <= bp * aq
end

-- Conversion --

function M.to_number(a)
  return a.p / a.q
end

function M.to_string(a)
  if a.q == 1 then
    return tostring(a.p)
  else
    return tostring(a.p) .. "/" .. tostring(a.q)
  end
end

-- Continued-fraction best-rational approximation (optional).
-- Returns the rational closest to x whose denominator <= max_denom.
function M.from_float(x, max_denom)
  if max_denom == nil then max_denom = 1000000 end
  if not (type(x) == "number") then
    return nil, "rational.from_float: expected number"
  end
  if max_denom < 1 or math.floor(max_denom) ~= max_denom then
    return nil, "rational.from_float: max_denom must be a positive integer"
  end
  local sign = x < 0 and -1 or 1
  x = x < 0 and -x or x
  -- Stern-Brocot / mediants
  local p0, q0 = math.floor(x), 1   -- lower bound
  local p1, q1 = math.floor(x) + 1, 1 -- upper bound
  if q0 >= max_denom then
    return make(sign * p0, 1)
  end
  while true do
    local mp = p0 + p1
    local mq = q0 + q1
    if mq > max_denom then
      -- pick whichever of p0/q0 or p1/q1 is closer
      local d0 = math.abs(x - p0/q0)
      local d1 = math.abs(x - p1/q1)
      if d0 <= d1 then
        return make(sign * p0, q0)
      else
        return make(sign * p1, q1)
      end
    end
    local mv = mp / mq
    if math.abs(mv - x) < 1e-15 then
      return make(sign * mp, mq)
    elseif mv < x then
      p0, q0 = mp, mq
    else
      p1, q1 = mp, mq
    end
  end
end

-- Methods on rational objects (also available as M.method(a, b)) --

rat_mt = {
  __index = {
    add        = M.add,
    sub        = M.sub,
    mul        = M.mul,
    div        = M.div,
    neg        = M.neg,
    abs        = M.abs,
    inv        = M.inv,
    pow        = M.pow,
    eq         = M.eq,
    lt         = M.lt,
    le         = M.le,
    to_number  = M.to_number,
    to_string  = M.to_string,
    is_integer = function(a) return a.q == 1 end,
  },
  __add      = M.add,
  __sub      = M.sub,
  __mul      = M.mul,
  __div      = M.div,
  __unm      = M.neg,
  __eq       = M.eq,
  __lt       = M.lt,
  __le       = M.le,
  __tostring = M.to_string,
}

return M
