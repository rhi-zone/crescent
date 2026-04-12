if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local C = require("lib.complex")

local eps = 1e-12

-- Approximate equality helpers for floating-point comparisons.
local function near(a, b, e)
  e = e or eps
  return math.abs(a - b) < e
end

local function cnear(z, re, im, e)
  e = e or eps
  return near(z.re, re, e) and near(z.im, im, e)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

T.describe("C.new", function()
  T.it("re and im fields", function()
    local z = C.new(3, 4)
    T.eq(z.re, 3)
    T.eq(z.im, 4)
  end)

  T.it("im defaults to 0", function()
    local z = C.new(2)
    T.eq(z.re, 2)
    T.eq(z.im, 0)
  end)

  T.it("constants i, zero, one", function()
    T.eq(C.i.re, 0)
    T.eq(C.i.im, 1)
    T.eq(C.zero.re, 0)
    T.eq(C.zero.im, 0)
    T.eq(C.one.re, 1)
    T.eq(C.one.im, 0)
  end)
end)

T.describe("C.from_polar", function()
  T.it("r=5 theta=0 gives (5,0)", function()
    local z = C.from_polar(5, 0)
    T.ok(cnear(z, 5, 0))
  end)

  T.it("r=1 theta=pi/2 gives (0,1)", function()
    local z = C.from_polar(1, math.pi / 2)
    T.ok(cnear(z, 0, 1, 1e-10))
  end)

  T.it("r=5 theta=pi/4 correct re/im", function()
    local z = C.from_polar(5, math.pi / 4)
    local expected = 5 / math.sqrt(2)
    T.ok(cnear(z, expected, expected, 1e-10))
  end)

  T.it("polar round-trip", function()
    local z = C.new(3, 4)
    local r, theta = z:polar()
    local z2 = C.from_polar(r, theta)
    T.ok(cnear(z2, z.re, z.im, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- Arithmetic operators
-- ---------------------------------------------------------------------------

T.describe("addition", function()
  T.it("complex + complex", function()
    local z = C.new(1, 2) + C.new(3, 4)
    T.eq(z.re, 4)
    T.eq(z.im, 6)
  end)

  T.it("complex + number", function()
    local z = C.new(3, 4) + 2
    T.eq(z.re, 5)
    T.eq(z.im, 4)
  end)

  T.it("number + complex", function()
    local z = 2 + C.new(3, 4)
    T.eq(z.re, 5)
    T.eq(z.im, 4)
  end)
end)

T.describe("subtraction", function()
  T.it("complex - complex", function()
    local z = C.new(5, 6) - C.new(1, 2)
    T.eq(z.re, 4)
    T.eq(z.im, 4)
  end)

  T.it("complex - number", function()
    local z = C.new(3, 4) - 1
    T.eq(z.re, 2)
    T.eq(z.im, 4)
  end)

  T.it("number - complex", function()
    local z = 10 - C.new(3, 4)
    T.eq(z.re, 7)
    T.eq(z.im, -4)
  end)
end)

T.describe("multiplication", function()
  T.it("complex * complex", function()
    -- (1+2i)(3+4i) = 3+4i+6i+8i^2 = (3-8)+(4+6)i = -5+10i
    local z = C.new(1, 2) * C.new(3, 4)
    T.eq(z.re, -5)
    T.eq(z.im, 10)
  end)

  T.it("complex * number", function()
    local z = C.new(3, 4) * 2
    T.eq(z.re, 6)
    T.eq(z.im, 8)
  end)

  T.it("number * complex", function()
    local z = 3 * C.new(1, 2)
    T.eq(z.re, 3)
    T.eq(z.im, 6)
  end)

  T.it("i * i = -1", function()
    local z = C.i * C.i
    T.eq(z.re, -1)
    T.eq(z.im, 0)
  end)
end)

T.describe("division", function()
  T.it("complex / complex", function()
    -- (3+4i)/(1+2i) = ((3+8)+(4-6)i)/(1+4) = 11/5 - 2/5 i
    local z = C.new(3, 4) / C.new(1, 2)
    T.ok(cnear(z, 11/5, -2/5))
  end)

  T.it("complex / number", function()
    local z = C.new(4, 6) / 2
    T.ok(cnear(z, 2, 3))
  end)

  T.it("number / complex", function()
    local z = 1 / C.new(0, 1)   -- 1/i = -i
    T.ok(cnear(z, 0, -1))
  end)
end)

T.describe("unary negation", function()
  T.it("-(3+4i) = -3-4i", function()
    local z = -C.new(3, 4)
    T.eq(z.re, -3)
    T.eq(z.im, -4)
  end)
end)

-- ---------------------------------------------------------------------------
-- Equality
-- ---------------------------------------------------------------------------

T.describe("__eq", function()
  T.it("same value equal", function()
    T.ok(C.new(3, 4) == C.new(3, 4))
  end)

  T.it("different values not equal", function()
    T.ok(not (C.new(3, 4) == C.new(3, 5)))
  end)
end)

-- ---------------------------------------------------------------------------
-- __tostring
-- ---------------------------------------------------------------------------

T.describe("__tostring", function()
  T.it("general 3+4i", function()
    T.eq(tostring(C.new(3, 4)), "3+4i")
  end)

  T.it("3-4i with negative imaginary", function()
    T.eq(tostring(C.new(3, -4)), "3-4i")
  end)

  T.it("pure real", function()
    T.eq(tostring(C.new(5, 0)), "5")
  end)

  T.it("pure imaginary", function()
    T.eq(tostring(C.new(0, 2)), "2i")
  end)

  T.it("unit imaginary", function()
    T.eq(tostring(C.i), "i")
  end)

  T.it("negative unit imaginary", function()
    T.eq(tostring(-C.i), "-i")
  end)

  T.it("zero", function()
    T.eq(tostring(C.zero), "0")
  end)
end)

-- ---------------------------------------------------------------------------
-- Methods
-- ---------------------------------------------------------------------------

T.describe("abs", function()
  T.it("|3+4i| = 5", function()
    T.ok(near(C.new(3, 4):abs(), 5))
  end)

  T.it("|1+0i| = 1", function()
    T.ok(near(C.new(1, 0):abs(), 1))
  end)
end)

T.describe("arg", function()
  T.it("arg(1) = 0", function()
    T.ok(near(C.one:arg(), 0))
  end)

  T.it("arg(i) = pi/2", function()
    T.ok(near(C.i:arg(), math.pi / 2))
  end)

  T.it("arg(-1) = pi", function()
    T.ok(near(C.new(-1, 0):arg(), math.pi))
  end)
end)

T.describe("conj", function()
  T.it("conj(3+4i) = 3-4i", function()
    local z = C.new(3, 4):conj()
    T.eq(z.re, 3)
    T.eq(z.im, -4)
  end)
end)

T.describe("sq", function()
  T.it("(3+4i)^2 = -7+24i", function()
    -- (3+4i)^2 = 9+24i+16i^2 = 9-16+24i = -7+24i
    local z = C.new(3, 4):sq()
    T.eq(z.re, -7)
    T.eq(z.im, 24)
  end)
end)

T.describe("is_real / is_zero", function()
  T.it("is_real when im==0", function()
    T.ok(C.new(3, 0):is_real())
    T.ok(not C.new(3, 1):is_real())
  end)

  T.it("is_zero when both 0", function()
    T.ok(C.zero:is_zero())
    T.ok(not C.one:is_zero())
    T.ok(not C.new(0, 1):is_zero())
  end)
end)

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

T.describe("C.sqrt", function()
  T.it("sqrt(-1) = i", function()
    local z = C.sqrt(C.new(-1, 0))
    T.ok(cnear(z, 0, 1, 1e-10))
  end)

  T.it("sqrt(4) = 2", function()
    local z = C.sqrt(C.new(4, 0))
    T.ok(cnear(z, 2, 0, 1e-10))
  end)

  T.it("sqrt(0) = 0", function()
    local z = C.sqrt(C.zero)
    T.ok(cnear(z, 0, 0))
  end)
end)

T.describe("C.exp / Euler's identity", function()
  T.it("exp(i*pi) ≈ -1", function()
    local z = C.exp(C.i * math.pi)
    T.ok(cnear(z, -1, 0, 1e-10))
  end)

  T.it("exp(0) = 1", function()
    local z = C.exp(C.zero)
    T.ok(cnear(z, 1, 0))
  end)
end)

T.describe("C.log", function()
  T.it("log(exp(z)) ≈ z (round-trip)", function()
    local z = C.new(2, 3)
    local ez = C.exp(z)
    local lz = C.log(ez)
    T.ok(cnear(lz, z.re, z.im, 1e-10))
  end)

  T.it("log(1) = 0", function()
    local z = C.log(C.one)
    T.ok(cnear(z, 0, 0, 1e-10))
  end)

  T.it("log(0) returns nil", function()
    local z, err = C.log(C.zero)
    T.eq(z, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("C.sin and C.cos", function()
  T.it("sin²(z) + cos²(z) = 1", function()
    local z = C.new(2, 3)
    local s = C.sin(z)
    local c = C.cos(z)
    -- sin^2 + cos^2: compute s*s + c*c
    local sum = s:sq() + c:sq()
    T.ok(cnear(sum, 1, 0, 1e-10))
  end)

  T.it("sin(0) = 0", function()
    local z = C.sin(C.zero)
    T.ok(cnear(z, 0, 0, 1e-10))
  end)

  T.it("cos(0) = 1", function()
    local z = C.cos(C.zero)
    T.ok(cnear(z, 1, 0, 1e-10))
  end)
end)

T.describe("C.pow and __pow", function()
  T.it("pow(2, 3) = 8", function()
    local z = C.pow(C.new(2, 0), C.new(3, 0))
    T.ok(cnear(z, 8, 0, 1e-10))
  end)

  T.it("z^2 via __pow matches sq()", function()
    local z = C.new(3, 4)
    local p = z ^ C.new(2, 0)
    local s = z:sq()
    T.ok(cnear(p, s.re, s.im, 1e-10))
  end)

  T.it("i^2 = -1", function()
    local z = C.i ^ C.new(2, 0)
    T.ok(cnear(z, -1, 0, 1e-10))
  end)
end)

T.describe("C.roots", function()
  T.it("cube roots of 8 multiply back to 8", function()
    local rs = C.roots(C.new(8, 0), 3)
    T.eq(#rs, 3)
    for _, r in ipairs(rs) do
      local p = r:sq() * r  -- r^3
      T.ok(cnear(p, 8, 0, 1e-8))
    end
  end)

  T.it("square roots of -1 are ±i", function()
    local rs = C.roots(C.new(-1, 0), 2)
    T.eq(#rs, 2)
    -- Both should satisfy r^2 = -1
    for _, r in ipairs(rs) do
      local p = r:sq()
      T.ok(cnear(p, -1, 0, 1e-10))
    end
  end)
end)
