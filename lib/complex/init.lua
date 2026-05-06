if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Complex number arithmetic library.
-- Pure Lua implementation with operator overloading via metatables.
-- Represents complex numbers as { re: number, im: number }.

local M = {}
M._tier = "pure"

local sqrt  = math.sqrt
local atan2 = math.atan2
local cos   = math.cos
local sin   = math.sin
local exp   = math.exp
local log   = math.log
local abs   = math.abs
local floor = math.floor
local format = string.format

--:: Complex = { re: number, im: number, abs: (Complex) -> number, arg: (Complex) -> number, conj: (Complex) -> Complex, sq: (Complex) -> Complex, polar: (Complex) -> (number, number), is_real: (Complex) -> boolean, is_zero: (Complex) -> boolean, ... }

-- ---------------------------------------------------------------------------
-- Metatable
-- ---------------------------------------------------------------------------

local mt = {}
mt.__index = mt

-- ---------------------------------------------------------------------------
-- Internal constructor (no coercion)
-- ---------------------------------------------------------------------------

--: (number, number) -> Complex
local function _new(re, im)
  return (setmetatable({ re = re, im = im }, mt) --[[: any]]) --[[:! Complex]]
end

-- ---------------------------------------------------------------------------
-- Public constructors
-- ---------------------------------------------------------------------------

-- Create a complex number from real and imaginary parts.
-- im defaults to 0.
function M.new(re, im)
  return _new(re, im or 0)
end

-- Create a complex number from polar form r * e^(i*theta).
function M.from_polar(r, theta)
  return _new(r * cos(theta), r * sin(theta))
end

-- Coerce a value to complex; pass through if already complex.
--: (Complex | number) -> Complex
local function coerce(v)
  if type(v) == "number" then return _new(v --[[:! number]], 0) end
  return v --[[:! Complex]]
end

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

M.i    = _new(0, 1)
M.zero = _new(0, 0)
M.one  = _new(1, 0)

-- ---------------------------------------------------------------------------
-- Arithmetic metamethods
-- ---------------------------------------------------------------------------

--: (Complex | number, Complex | number) -> Complex
function mt.__add(a, b)
  local a_ = coerce(a) --[[:! Complex]]
  local b_ = coerce(b) --[[:! Complex]]
  return _new(a_.re + b_.re, a_.im + b_.im)
end

--: (Complex | number, Complex | number) -> Complex
function mt.__sub(a, b)
  local a_ = coerce(a) --[[:! Complex]]
  local b_ = coerce(b) --[[:! Complex]]
  return _new(a_.re - b_.re, a_.im - b_.im)
end

-- (a+bi)(c+di) = (ac-bd) + (ad+bc)i
--: (Complex | number, Complex | number) -> Complex
function mt.__mul(a, b)
  local a_ = coerce(a) --[[:! Complex]]
  local b_ = coerce(b) --[[:! Complex]]
  return _new(a_.re * b_.re - a_.im * b_.im,
              a_.re * b_.im + a_.im * b_.re)
end

-- (a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c^2+d^2)
--: (Complex | number, Complex | number) -> (Complex | nil, string | nil)
function mt.__div(a, b)
  local a_ = coerce(a) --[[:! Complex]]
  local b_ = coerce(b) --[[:! Complex]]
  local denom = b_.re * b_.re + b_.im * b_.im
  if denom == 0 then return nil, "division by zero" end
  return _new((a_.re * b_.re + a_.im * b_.im) / denom,
              (a_.im * b_.re - a_.re * b_.im) / denom)
end

-- z^w = exp(w * log(z))
--: (Complex | number, Complex | number) -> (Complex | nil, string | nil)
function mt.__pow(a, b)
  local a_ = coerce(a) --[[:! Complex]]
  local b_ = coerce(b) --[[:! Complex]]
  return M.pow(a_, b_)
end

--: (Complex) -> Complex
function mt.__unm(a)
  local a_ = a --[[:! Complex]]
  return _new(-a_.re, -a_.im)
end

--: (Complex, Complex) -> boolean
function mt.__eq(a, b)
  local a_ = a --[[:! Complex]]
  local b_ = b --[[:! Complex]]
  return (a_.re == b_.re and a_.im == b_.im) and true or false
end

-- Format: "3+4i", "3-4i", "3", "4i", "0"
--: (Complex) -> string
function mt.__tostring(z)
  local z_ = z --[[:! Complex]]
  local re, im = z_.re, z_.im
  -- Pure real
  if im == 0 then
    -- format integer-valued reals without decimal point
    if re == floor(re) then
      return format("%g", re)
    end
    return format("%g", re)
  end
  -- Pure imaginary
  if re == 0 then
    if im == 1  then return "i"  end
    if im == -1 then return "-i" end
    return format("%gi", im)
  end
  -- General case
  local re_s = format("%g", re)
  local im_s
  if im == 1 then
    im_s = "+i"
  elseif im == -1 then
    im_s = "-i"
  elseif im < 0 then
    im_s = format("%gi", im)
  else
    im_s = format("+%gi", im)
  end
  return re_s .. im_s
end

-- ---------------------------------------------------------------------------
-- Methods
-- ---------------------------------------------------------------------------

-- Magnitude |z| = sqrt(re^2 + im^2).
--: (Complex) -> number
function mt:abs()
  return sqrt(self.re * self.re + self.im * self.im)
end

-- Argument (angle) of z in radians, in (-π, π].
--: (Complex) -> number
function mt:arg()
  return atan2(self.im, self.re)
end

-- Complex conjugate: re - im*i.
--: (Complex) -> Complex
function mt:conj()
  return _new(self.re, -self.im)
end

-- Square: z * z.
--: (Complex) -> Complex
function mt:sq()
  return _new(self.re * self.re - self.im * self.im,
              2 * self.re * self.im)
end

-- Return (r, theta) polar decomposition.
--: (Complex) -> (number, number)
function mt:polar()
  return self:abs(), self:arg()
end

-- True when imaginary part is zero.
--: (Complex) -> boolean
function mt:is_real()
  return self.im == 0
end

-- True when both parts are zero.
--: (Complex) -> boolean
function mt:is_zero()
  return (self.re == 0 and self.im == 0) and true or false
end

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- Principal square root of z.
-- sqrt(z) = sqrt(r) * e^(i*theta/2), theta = arg(z).
--: (Complex | number) -> Complex
function M.sqrt(z)
  local z_ = coerce(z)
  local r = z_:abs()
  if r == 0 then return M.zero end
  local theta = z_:arg()
  return M.from_polar(sqrt(r), theta / 2)
end

-- e^z = e^re * (cos(im) + i*sin(im)).
--: (Complex | number) -> Complex
function M.exp(z)
  local z_ = coerce(z)
  local e_re = exp(z_.re)
  return _new(e_re * cos(z_.im), e_re * sin(z_.im))
end

-- Natural logarithm: log(z) = log|z| + i*arg(z).
-- Returns nil, errmsg for z == 0.
--: (Complex | number) -> (Complex | nil, string | nil)
function M.log(z)
  local z_ = coerce(z)
  local r = z_:abs()
  if r == 0 then return nil, "log of zero" end
  return _new(log(r), z_:arg())
end

-- Complex sine: sin(z) = sin(re)*cosh(im) + i*cos(re)*sinh(im).
--: (Complex | number) -> Complex
function M.sin(z)
  local z_ = coerce(z)
  local re, im = z_.re, z_.im
  local cosh_im = (exp(im) + exp(-im)) / 2
  local sinh_im = (exp(im) - exp(-im)) / 2
  return _new(sin(re) * cosh_im, cos(re) * sinh_im)
end

-- Complex cosine: cos(z) = cos(re)*cosh(im) - i*sin(re)*sinh(im).
--: (Complex | number) -> Complex
function M.cos(z)
  local z_ = coerce(z)
  local re, im = z_.re, z_.im
  local cosh_im = (exp(im) + exp(-im)) / 2
  local sinh_im = (exp(im) - exp(-im)) / 2
  return _new(cos(re) * cosh_im, -sin(re) * sinh_im)
end

-- Complex tangent: tan(z) = sin(z) / cos(z).
--: (Complex | number) -> (Complex | nil, string | nil)
function M.tan(z)
  local z_ = coerce(z)
  local s = M.sin(z_)
  local c = M.cos(z_)
  return mt.__div(s, c)
end

-- z^w = exp(w * log(z)).
-- Returns nil, errmsg when z == 0 and w has non-positive real part.
--: (Complex | number, Complex | number) -> (Complex | nil, string | nil)
function M.pow(z, w)
  local z_ = coerce(z)
  local w_ = coerce(w)
  -- Special case: z == 0
  if z_:is_zero() then
    if w_.re > 0 then return M.zero end
    return nil, "0^w undefined for non-positive real part of w"
  end
  local lz, err = M.log(z_)
  if not lz then return nil, err end
  return M.exp(mt.__mul(w_, lz --[[:! Complex]]))
end

-- All n-th roots of z: z^(1/n) * e^(2πik/n) for k=0..n-1.
-- Returns array of n complex numbers.
--: (Complex | number, number) -> { [integer]: Complex }
function M.roots(z, n)
  local z_ = coerce(z)
  local r = z_:abs()
  local theta = z_:arg()
  local r_n = r ^ (1 / n) --: number
  local result = {}
  for k = 0, n - 1 do
    result[k + 1] = M.from_polar(r_n, (theta + 2 * math.pi * k) / n)
  end
  return result
end

return M
