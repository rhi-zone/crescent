-- lib/finite_field: Finite field (Galois field) arithmetic
-- Supports GF(p) prime fields and GF(2^n) binary extension fields,
-- plus polynomial arithmetic over any field.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}

M._tier = "pure"

-- ─── helpers ────────────────────────────────────────────────────────────────

-- Reduce v into [0, p-1]
local function mod_pos(v, p)
  return ((v % p) + p) % p
end

-- Extended Euclidean algorithm: returns (g, x, y) s.t. a*x + b*y = g
local function egcd(a, b)
  if b == 0 then return a, 1, 0 end
  local g, x, y = egcd(b, a % b)
  return g, y, x - math.floor(a / b) * y
end

-- Modular inverse of a mod p (p prime). Returns nil if a == 0.
local function modinv(a, p)
  a = mod_pos(a, p)
  if a == 0 then return nil end
  local _, x = egcd(a, p)
  return mod_pos(x, p)
end

-- Fast modular exponentiation: base^exp mod m  (exp may be negative)
local function modpow(base, exp, m)
  if exp < 0 then
    local inv = modinv(base, m)
    if not inv then return nil, "base has no inverse" end
    base = inv
    exp = -exp
  end
  base = mod_pos(base, m)
  local result = 1
  while exp > 0 do
    if exp % 2 == 1 then result = (result * base) % m end
    base = (base * base) % m
    exp = math.floor(exp / 2)
  end
  return result
end

-- ─── GF(p) prime field ──────────────────────────────────────────────────────

--:: PrimeElem = { val: () -> integer, add: (PrimeElem) -> PrimeElem, sub: (PrimeElem) -> PrimeElem, mul: (PrimeElem) -> PrimeElem, div: (PrimeElem) -> PrimeElem | (nil, string), inv: () -> PrimeElem | nil, neg: () -> PrimeElem, pow: (integer) -> PrimeElem | (nil, string), eq: (PrimeElem) -> boolean }

function M.prime(p)
  assert(type(p) == "number" and p >= 2, "p must be an integer >= 2")

  local field = {}

  local elem_mt = {}
  elem_mt.__index = elem_mt

  local function new_elem(v)
    return setmetatable({ _v = mod_pos(v, p) }, elem_mt)
  end

  function field.new(v)
    return new_elem(v)
  end

  function elem_mt:val()
    return self._v
  end

  function elem_mt:add(b)
    return new_elem(self._v + b._v)
  end

  function elem_mt:sub(b)
    return new_elem(self._v - b._v)
  end

  function elem_mt:mul(b)
    return new_elem(self._v * b._v)
  end

  function elem_mt:neg()
    return new_elem(-self._v)
  end

  function elem_mt:inv()
    if self._v == 0 then return nil end
    return new_elem(modinv(self._v, p))
  end

  function elem_mt:div(b)
    if b._v == 0 then return nil, "division by zero in GF(" .. p .. ")" end
    local inv = modinv(b._v, p)
    return new_elem(self._v * inv)
  end

  function elem_mt:pow(n)
    local v, err = modpow(self._v, n, p)
    if v == nil then return nil, err end
    return new_elem(v)
  end

  function elem_mt:eq(b)
    return self._v == b._v
  end

  -- metamethods
  elem_mt.__add = function(a, b) return a:add(b) end
  elem_mt.__sub = function(a, b) return a:sub(b) end
  elem_mt.__mul = function(a, b) return a:mul(b) end
  elem_mt.__div = function(a, b) return a:div(b) end
  elem_mt.__unm = function(a)    return a:neg()  end
  elem_mt.__eq  = function(a, b) return a:eq(b)  end
  elem_mt.__tostring = function(a)
    return "GF(" .. p .. ")(" .. a._v .. ")"
  end

  field._p = p
  return field
end

-- ─── GF(2^n) binary extension field ─────────────────────────────────────────

-- Carryless (XOR) multiply of polynomials a and b over GF(2).
local function clmul(a, b)
  local result = 0
  while b > 0 do
    if bit.band(b, 1) == 1 then result = bit.bxor(result, a) end
    a = bit.lshift(a, 1)
    b = bit.rshift(b, 1)
  end
  return result
end

-- Reduce polynomial a modulo irreducible polynomial poly of degree n.
local function polyreduce(a, poly, n)
  local degree_mask = bit.lshift(1, n)  -- 2^n (the leading bit of poly)
  -- We reduce bit by bit from the top
  for i = 2 * n - 2, n - 1, -1 do
    if bit.band(a, bit.lshift(1, i)) ~= 0 then
      -- shift poly to align with bit i
      a = bit.bxor(a, bit.lshift(poly, i - n))
    end
  end
  -- mask to n bits
  return bit.band(a, bit.lshift(degree_mask, 0) - 1)
end

-- Build exp and log tables for GF(2^n) with generator g and irreducible poly.
local function build_tables(n, poly, g)
  local size = bit.lshift(1, n)  -- 2^n
  local exp = {}
  local log = {}
  local x = 1
  for i = 0, size - 2 do
    exp[i] = x
    log[x] = i
    -- multiply x by g (carryless, then reduce)
    x = polyreduce(clmul(x, g), poly, n)
  end
  exp[size - 1] = 1  -- wrap-around convenience (exp[255] = exp[0] = 1)
  return exp, log
end

--:: GF2nElem = { val: () -> integer, add: (GF2nElem) -> GF2nElem, sub: (GF2nElem) -> GF2nElem, mul: (GF2nElem) -> GF2nElem, div: (GF2nElem) -> GF2nElem | (nil, string), inv: () -> GF2nElem | nil, pow: (integer) -> GF2nElem, eq: (GF2nElem) -> boolean }

function M.gf2n(n, poly, g)
  assert(type(n) == "number" and n >= 1, "n must be >= 1")
  assert(type(poly) == "number", "poly must be an integer")
  g = g or 2  -- default generator (primitive element)

  local size = bit.lshift(1, n)
  local mask = size - 1

  local exp, log = build_tables(n, poly, g)

  local field = {}

  local elem_mt = {}
  elem_mt.__index = elem_mt

  local function new_elem(v)
    return setmetatable({ _v = bit.band(v, mask) }, elem_mt)
  end

  function field.new(v)
    return new_elem(v)
  end

  function field._exp() return exp end
  function field._log() return log end

  function elem_mt:val()
    return self._v
  end

  function elem_mt:add(b)
    return new_elem(bit.bxor(self._v, b._v))
  end

  -- In GF(2^n), subtraction = addition (XOR)
  function elem_mt:sub(b)
    return new_elem(bit.bxor(self._v, b._v))
  end

  function elem_mt:mul(b)
    local av, bv = self._v, b._v
    if av == 0 or bv == 0 then return new_elem(0) end
    return new_elem(exp[(log[av] + log[bv]) % (size - 1)])
  end

  function elem_mt:inv()
    if self._v == 0 then return nil end
    return new_elem(exp[(size - 1 - log[self._v]) % (size - 1)])
  end

  function elem_mt:div(b)
    if b._v == 0 then return nil, "division by zero in GF(2^" .. n .. ")" end
    if self._v == 0 then return new_elem(0) end
    return new_elem(exp[(log[self._v] - log[b._v] + size - 1) % (size - 1)])
  end

  function elem_mt:pow(k)
    if self._v == 0 then
      if k == 0 then return new_elem(1) end
      if k < 0 then return nil, "zero has no inverse" end
      return new_elem(0)
    end
    if k == 0 then return new_elem(1) end
    local lv = log[self._v]
    if k < 0 then
      -- a^k = (a^{-1})^{-k}
      lv = (size - 1 - lv) % (size - 1)
      k = -k
    end
    return new_elem(exp[(lv * k) % (size - 1)])
  end

  function elem_mt:eq(b)
    return self._v == b._v
  end

  elem_mt.__add = function(a, b) return a:add(b) end
  elem_mt.__sub = function(a, b) return a:sub(b) end
  elem_mt.__mul = function(a, b) return a:mul(b) end
  elem_mt.__div = function(a, b) return a:div(b) end
  elem_mt.__unm = function(a)    return a end  -- in GF(2^n), -a = a
  elem_mt.__eq  = function(a, b) return a:eq(b) end
  elem_mt.__tostring = function(a)
    return "GF(2^" .. n .. ")(" .. a._v .. ")"
  end

  field._n = n
  field._poly = poly
  field._size = size
  return field
end

-- Prebuilt common fields
M.GF256 = M.gf2n(8, 0x11B, 3)  -- AES field, generator 0x03
M.GF16  = M.gf2n(4, 0x13, 2)   -- GF(2^4), x^4+x+1

-- ─── Polynomial arithmetic over a field ─────────────────────────────────────

-- poly: array of field elements (index 1 = constant term a_0)
-- e.g. {F.new(1), F.new(0), F.new(1)} represents 1 + 0*x + 1*x^2

function M.poly(field, coeffs)
  -- coeffs is an array of plain integers or field elements
  local elems = {}
  for i = 1, #coeffs do
    local c = coeffs[i]
    if type(c) == "number" then
      elems[i] = field.new(c)
    else
      elems[i] = c
    end
  end

  -- Trim trailing zeros
  local function trim(cs)
    local n = #cs
    while n > 1 and cs[n]:val() == 0 do n = n - 1 end
    local out = {}
    for i = 1, n do out[i] = cs[i] end
    return out
  end

  elems = trim(elems)

  local poly_mt = {}
  poly_mt.__index = poly_mt

  local function new_poly(cs)
    return setmetatable({ _coeffs = trim(cs), _field = field }, poly_mt)
  end

  function poly_mt:degree()
    return #self._coeffs - 1
  end

  function poly_mt:coeffs()
    local out = {}
    for i = 1, #self._coeffs do out[i] = self._coeffs[i] end
    return out
  end

  -- Evaluate polynomial at field element x using Horner's method
  function poly_mt:eval(x)
    local cs = self._coeffs
    local n = #cs
    local result = cs[n]
    for i = n - 1, 1, -1 do
      result = result:mul(x):add(cs[i])
    end
    return result
  end

  function poly_mt:add(other)
    local as, bs = self._coeffs, other._coeffs
    local len = math.max(#as, #bs)
    local out = {}
    for i = 1, len do
      local a = as[i] or field.new(0)
      local b = bs[i] or field.new(0)
      out[i] = a:add(b)
    end
    return new_poly(out)
  end

  function poly_mt:mul(other)
    local as, bs = self._coeffs, other._coeffs
    local out = {}
    for i = 1, #as + #bs - 1 do out[i] = field.new(0) end
    for i = 1, #as do
      for j = 1, #bs do
        out[i + j - 1] = out[i + j - 1]:add(as[i]:mul(bs[j]))
      end
    end
    return new_poly(out)
  end

  poly_mt.__tostring = function(p)
    local parts = {}
    local cs = p._coeffs
    for i = #cs, 1, -1 do
      local v = cs[i]:val()
      if v ~= 0 or #cs == 1 then
        local term
        if i == 1 then
          term = tostring(v)
        elseif i == 2 then
          term = v == 1 and "x" or (tostring(v) .. "x")
        else
          term = v == 1 and ("x^" .. (i-1)) or (tostring(v) .. "x^" .. (i-1))
        end
        parts[#parts + 1] = term
      end
    end
    return #parts > 0 and table.concat(parts, " + ") or "0"
  end

  return new_poly(elems)
end

return M
