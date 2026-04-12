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

-- ---------------------------------------------------------------------------
-- Metatable
-- ---------------------------------------------------------------------------

local mt = {}
mt.__index = mt

-- ---------------------------------------------------------------------------
-- Internal constructor (no coercion)
-- ---------------------------------------------------------------------------

local function _new(re, im)
  return setmetatable({ re = re, im = im }, mt)
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
local function coerce(v)
  if type(v) == "number" then return _new(v, 0) end
  return v
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

function mt.__add(a, b)
  a, b = coerce(a), coerce(b)
  return _new(a.re + b.re, a.im + b.im)
end

function mt.__sub(a, b)
  a, b = coerce(a), coerce(b)
  return _new(a.re - b.re, a.im - b.im)
end

-- (a+bi)(c+di) = (ac-bd) + (ad+bc)i
function mt.__mul(a, b)
  a, b = coerce(a), coerce(b)
  return _new(a.re * b.re - a.im * b.im,
              a.re * b.im + a.im * b.re)
end

-- (a+bi)/(c+di) = ((ac+bd) + (bc-ad)i) / (c^2+d^2)
function mt.__div(a, b)
  a, b = coerce(a), coerce(b)
  local denom = b.re * b.re + b.im * b.im
  if denom == 0 then return nil, "division by zero" end
  return _new((a.re * b.re + a.im * b.im) / denom,
              (a.im * b.re - a.re * b.im) / denom)
end

-- z^w = exp(w * log(z))
function mt.__pow(a, b)
  a, b = coerce(a), coerce(b)
  return M.pow(a, b)
end

function mt.__unm(a)
  return _new(-a.re, -a.im)
end

function mt.__eq(a, b)
  return a.re == b.re and a.im == b.im
end

-- Format: "3+4i", "3-4i", "3", "4i", "0"
function mt.__tostring(z)
  local re, im = z.re, z.im
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
function mt:abs()
  return sqrt(self.re * self.re + self.im * self.im)
end

-- Argument (angle) of z in radians, in (-π, π].
function mt:arg()
  return atan2(self.im, self.re)
end

-- Complex conjugate: re - im*i.
function mt:conj()
  return _new(self.re, -self.im)
end

-- Square: z * z.
function mt:sq()
  return _new(self.re * self.re - self.im * self.im,
              2 * self.re * self.im)
end

-- Return (r, theta) polar decomposition.
function mt:polar()
  return self:abs(), self:arg()
end

-- True when imaginary part is zero.
function mt:is_real()
  return self.im == 0
end

-- True when both parts are zero.
function mt:is_zero()
  return self.re == 0 and self.im == 0
end

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- Principal square root of z.
-- sqrt(z) = sqrt(r) * e^(i*theta/2), theta = arg(z).
function M.sqrt(z)
  z = coerce(z)
  local r = z:abs()
  if r == 0 then return M.zero end
  local theta = z:arg()
  return M.from_polar(sqrt(r), theta / 2)
end

-- e^z = e^re * (cos(im) + i*sin(im)).
function M.exp(z)
  z = coerce(z)
  local e_re = exp(z.re)
  return _new(e_re * cos(z.im), e_re * sin(z.im))
end

-- Natural logarithm: log(z) = log|z| + i*arg(z).
-- Returns nil, errmsg for z == 0.
function M.log(z)
  z = coerce(z)
  local r = z:abs()
  if r == 0 then return nil, "log of zero" end
  return _new(log(r), z:arg())
end

-- Complex sine: sin(z) = sin(re)*cosh(im) + i*cos(re)*sinh(im).
function M.sin(z)
  z = coerce(z)
  local re, im = z.re, z.im
  local cosh_im = (exp(im) + exp(-im)) / 2
  local sinh_im = (exp(im) - exp(-im)) / 2
  return _new(sin(re) * cosh_im, cos(re) * sinh_im)
end

-- Complex cosine: cos(z) = cos(re)*cosh(im) - i*sin(re)*sinh(im).
function M.cos(z)
  z = coerce(z)
  local re, im = z.re, z.im
  local cosh_im = (exp(im) + exp(-im)) / 2
  local sinh_im = (exp(im) - exp(-im)) / 2
  return _new(cos(re) * cosh_im, -sin(re) * sinh_im)
end

-- Complex tangent: tan(z) = sin(z) / cos(z).
function M.tan(z)
  z = coerce(z)
  return M.sin(z) / M.cos(z)
end

-- z^w = exp(w * log(z)).
-- Returns nil, errmsg when z == 0 and w has non-positive real part.
function M.pow(z, w)
  z, w = coerce(z), coerce(w)
  -- Special case: z == 0
  if z:is_zero() then
    if w.re > 0 then return M.zero end
    return nil, "0^w undefined for non-positive real part of w"
  end
  local lz, err = M.log(z)
  if not lz then return nil, err end
  return M.exp(w * lz)
end

-- All n-th roots of z: z^(1/n) * e^(2πik/n) for k=0..n-1.
-- Returns array of n complex numbers.
function M.roots(z, n)
  z = coerce(z)
  local r = z:abs()
  local theta = z:arg()
  local r_n = r ^ (1 / n)
  local result = {}
  for k = 0, n - 1 do
    result[k + 1] = M.from_polar(r_n, (theta + 2 * math.pi * k) / n)
  end
  return result
end

return M
