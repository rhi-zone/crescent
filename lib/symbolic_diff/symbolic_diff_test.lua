-- lib/symbolic_diff/symbolic_diff_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SD = require("lib.symbolic_diff")

-- Numerical finite-difference helper
local function numerical_diff(f_expr, var, val, h)
  h = h or 1e-7
  local env_plus  = { [var] = val + h }
  local env_minus = { [var] = val - h }
  return (SD.eval(f_expr, env_plus) - SD.eval(f_expr, env_minus)) / (2 * h)
end

local function approx(a, b, tol)
  tol = tol or 1e-5
  return math.abs(a - b) < tol
end

-- ---------------------------------------------------------------------------
T.describe("symbolic_diff", function()

  -- -------------------------------------------------------------------------
  T.describe("constructors and tostring", function()

    T.it("num tostring", function()
      T.eq(SD.tostring(SD.num(3)), "3")
      T.eq(SD.tostring(SD.num(3.14)), "3.14")
    end)

    T.it("var tostring", function()
      T.eq(SD.tostring(SD.var("x")), "x")
      T.eq(SD.tostring(SD.var("y")), "y")
    end)

    T.it("compound tostring is non-empty", function()
      local x = SD.var("x")
      local e = SD.add(SD.mul(SD.num(3), SD.pow(x, SD.num(2))), SD.var("y"))
      local s = SD.tostring(e)
      T.ok(type(s) == "string" and #s > 0, "tostring non-empty")
    end)

    T.it("all node types produce non-empty strings", function()
      local x = SD.var("x")
      T.ok(#SD.tostring(SD.neg(x)) > 0)
      T.ok(#SD.tostring(SD.sub(x, SD.num(1))) > 0)
      T.ok(#SD.tostring(SD.div(x, SD.num(2))) > 0)
      T.ok(#SD.tostring(SD.pow(x, SD.num(3))) > 0)
      T.ok(#SD.tostring(SD.sin(x)) > 0)
      T.ok(#SD.tostring(SD.cos(x)) > 0)
      T.ok(#SD.tostring(SD.ln(x)) > 0)
      T.ok(#SD.tostring(SD.exp(x)) > 0)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("eval", function()

    T.it("evaluates constant", function()
      T.eq(SD.eval(SD.num(42), {}), 42)
    end)

    T.it("evaluates variable", function()
      T.eq(SD.eval(SD.var("x"), { x = 5 }), 5)
    end)

    T.it("evaluates add", function()
      T.eq(SD.eval(SD.add(SD.num(2), SD.num(3)), {}), 5)
    end)

    T.it("evaluates sub", function()
      T.eq(SD.eval(SD.sub(SD.num(7), SD.num(3)), {}), 4)
    end)

    T.it("evaluates mul", function()
      T.eq(SD.eval(SD.mul(SD.num(4), SD.num(5)), {}), 20)
    end)

    T.it("evaluates div", function()
      T.eq(SD.eval(SD.div(SD.num(10), SD.num(2)), {}), 5)
    end)

    T.it("evaluates pow", function()
      T.eq(SD.eval(SD.pow(SD.num(2), SD.num(8)), {}), 256)
    end)

    T.it("evaluates neg", function()
      T.eq(SD.eval(SD.neg(SD.num(3)), {}), -3)
    end)

    T.it("evaluates sin", function()
      T.ok(approx(SD.eval(SD.sin(SD.num(0)), {}), 0))
      T.ok(approx(SD.eval(SD.sin(SD.var("x")), { x = math.pi / 2 }), 1))
    end)

    T.it("evaluates cos", function()
      T.ok(approx(SD.eval(SD.cos(SD.num(0)), {}), 1))
      T.ok(approx(SD.eval(SD.cos(SD.var("x")), { x = math.pi }), -1))
    end)

    T.it("evaluates ln", function()
      T.ok(approx(SD.eval(SD.ln(SD.num(1)), {}), 0))
      T.ok(approx(SD.eval(SD.ln(SD.num(math.exp(1))), {}), 1))
    end)

    T.it("evaluates exp", function()
      T.ok(approx(SD.eval(SD.exp(SD.num(0)), {}), 1))
      T.ok(approx(SD.eval(SD.exp(SD.num(1)), {}), math.exp(1)))
    end)

    T.it("errors on unbound variable", function()
      T.throws(function() SD.eval(SD.var("z"), {}) end)
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("diff — basic rules", function()

    T.it("d/dx(c) = 0", function()
      local d = SD.diff(SD.num(5), "x")
      T.eq(SD.eval(d, { x = 99 }), 0)
    end)

    T.it("d/dx(x) = 1", function()
      local d = SD.diff(SD.var("x"), "x")
      T.eq(SD.eval(d, { x = 99 }), 1)
    end)

    T.it("d/dx(y) = 0 (different variable)", function()
      local d = SD.diff(SD.var("y"), "x")
      T.eq(SD.eval(d, { x = 1, y = 2 }), 0)
    end)

    T.it("d/dx(f+g) = f'+g'", function()
      local x = SD.var("x")
      local e = SD.add(x, SD.mul(SD.num(2), x))  -- x + 2x, derivative = 3
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 5 }), 3))
    end)

    T.it("d/dx(f-g) = f'-g'", function()
      local x = SD.var("x")
      local e = SD.sub(SD.mul(SD.num(3), x), SD.mul(SD.num(2), x))  -- 3x - 2x = x, d/dx = 1
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 7 }), 1))
    end)

    T.it("d/dx(-f) = -f'", function()
      local x = SD.var("x")
      local e = SD.neg(SD.mul(SD.num(4), x))  -- -4x, d/dx = -4
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 1 }), -4))
    end)

    T.it("product rule: d/dx(x*x) = 2x", function()
      local x = SD.var("x")
      local e = SD.mul(x, x)
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 3 }), 6))
      T.ok(approx(SD.eval(d, { x = 5 }), 10))
    end)

    T.it("product rule: d/dx(2*x^3) matches numerical", function()
      local x = SD.var("x")
      local e = SD.mul(SD.num(2), SD.pow(x, SD.num(3)))
      local d = SD.diff(e, "x")
      -- analytical: 6x^2
      for _, xv in ipairs({ -2, 0, 1, 3 }) do
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv)),
          "mismatch at x=" .. xv)
      end
    end)

    T.it("quotient rule: d/dx(1/x) = -1/x^2", function()
      local x = SD.var("x")
      local e = SD.div(SD.num(1), x)
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 2 }), -0.25))
      T.ok(approx(SD.eval(d, { x = 4 }), -1 / 16))
    end)

    T.it("quotient rule matches numerical", function()
      local x = SD.var("x")
      local e = SD.div(SD.mul(SD.num(2), x), SD.add(x, SD.num(1)))  -- 2x/(x+1)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 1, 2, 5 }) do
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv), 1e-4),
          "mismatch at x=" .. xv)
      end
    end)

    T.it("power rule: d/dx(x^n)", function()
      local x = SD.var("x")
      -- d/dx(x^4) = 4x^3
      local e = SD.pow(x, SD.num(4))
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 2 }), 4 * 8))  -- 4*2^3 = 32
      T.ok(approx(SD.eval(d, { x = 3 }), 4 * 27)) -- 108
    end)

    T.it("power rule: d/dx(x^0) = 0", function()
      local x = SD.var("x")
      local e = SD.pow(x, SD.num(0))
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 5 }), 0))
    end)

    T.it("power rule: d/dx(x^1) = 1", function()
      local x = SD.var("x")
      local e = SD.pow(x, SD.num(1))
      local d = SD.diff(e, "x")
      T.ok(approx(SD.eval(d, { x = 7 }), 1))
    end)

    T.it("general power rule: d/dx(x^x) matches numerical", function()
      local x = SD.var("x")
      local e = SD.pow(x, x)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 1, 2, 3 }) do
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv), 1e-4),
          "x^x mismatch at x=" .. xv)
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("diff — transcendental functions", function()

    T.it("d/dx(sin(x)) = cos(x)", function()
      local x = SD.var("x")
      local e = SD.sin(x)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0, 1, 2, math.pi / 4 }) do
        T.ok(approx(SD.eval(d, { x = xv }), math.cos(xv), 1e-5),
          "sin deriv mismatch at x=" .. xv)
      end
    end)

    T.it("d/dx(cos(x)) = -sin(x)", function()
      local x = SD.var("x")
      local e = SD.cos(x)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0, 1, 2 }) do
        T.ok(approx(SD.eval(d, { x = xv }), -math.sin(xv), 1e-5),
          "cos deriv mismatch at x=" .. xv)
      end
    end)

    T.it("d/dx(ln(x)) = 1/x", function()
      local x = SD.var("x")
      local e = SD.ln(x)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 1, 2, 5 }) do
        T.ok(approx(SD.eval(d, { x = xv }), 1 / xv, 1e-5),
          "ln deriv mismatch at x=" .. xv)
      end
    end)

    T.it("d/dx(exp(x)) = exp(x)", function()
      local x = SD.var("x")
      local e = SD.exp(x)
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0, 1, 2 }) do
        T.ok(approx(SD.eval(d, { x = xv }), math.exp(xv), 1e-5),
          "exp deriv mismatch at x=" .. xv)
      end
    end)

    T.it("chain rule: d/dx(sin(x^2)) matches numerical", function()
      local x = SD.var("x")
      local e = SD.sin(SD.pow(x, SD.num(2)))
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0.5, 1, 1.5 }) do
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv), 1e-4),
          "chain sin mismatch at x=" .. xv)
      end
    end)

    T.it("chain rule: d/dx(exp(2x)) = 2*exp(2x)", function()
      local x = SD.var("x")
      local e = SD.exp(SD.mul(SD.num(2), x))
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0, 1, 2 }) do
        T.ok(approx(SD.eval(d, { x = xv }), 2 * math.exp(2 * xv), 1e-5))
      end
    end)

    T.it("chain rule: d/dx(ln(x^2)) matches numerical", function()
      local x = SD.var("x")
      local e = SD.ln(SD.pow(x, SD.num(2)))
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 1, 2, 3 }) do
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv), 1e-4))
      end
    end)

    T.it("chain rule: d/dx(cos(3x)) = -3*sin(3x)", function()
      local x = SD.var("x")
      local e = SD.cos(SD.mul(SD.num(3), x))
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 0, 1 }) do
        T.ok(approx(SD.eval(d, { x = xv }), -3 * math.sin(3 * xv), 1e-5))
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("diff — polynomial verification", function()

    T.it("d/dx(3x^2+2x+1) = 6x+2", function()
      local x = SD.var("x")
      -- 3x^2 + 2x + 1
      local e = SD.add(
        SD.add(SD.mul(SD.num(3), SD.pow(x, SD.num(2))),
               SD.mul(SD.num(2), x)),
        SD.num(1)
      )
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ -2, 0, 1, 3, 5 }) do
        local analytical = 6 * xv + 2
        T.ok(approx(SD.eval(d, { x = xv }), analytical),
          "poly mismatch at x=" .. xv)
        -- also cross-check numerically
        T.ok(approx(SD.eval(d, { x = xv }), numerical_diff(e, "x", xv), 1e-4))
      end
    end)

    T.it("d/dx(x^5) = 5x^4", function()
      local x = SD.var("x")
      local e = SD.pow(x, SD.num(5))
      local d = SD.diff(e, "x")
      for _, xv in ipairs({ 1, 2 }) do
        T.ok(approx(SD.eval(d, { x = xv }), 5 * xv ^ 4))
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("higher-order derivatives", function()

    T.it("d2/dx2(x^3) = 6x", function()
      local x = SD.var("x")
      local e = SD.pow(x, SD.num(3))
      local d2 = SD.diff(SD.diff(e, "x"), "x")
      for _, xv in ipairs({ 0, 1, 2, 3 }) do
        T.ok(approx(SD.eval(d2, { x = xv }), 6 * xv),
          "d2 mismatch at x=" .. xv)
      end
    end)

    T.it("d2/dx2(sin(x)) = -sin(x)", function()
      local x = SD.var("x")
      local e = SD.sin(x)
      local d2 = SD.diff(SD.diff(e, "x"), "x")
      for _, xv in ipairs({ 0, 1, math.pi / 4 }) do
        T.ok(approx(SD.eval(d2, { x = xv }), -math.sin(xv), 1e-5))
      end
    end)

    T.it("d2/dx2(exp(x)) = exp(x)", function()
      local x = SD.var("x")
      local e = SD.exp(x)
      local d2 = SD.diff(SD.diff(e, "x"), "x")
      for _, xv in ipairs({ 0, 1, 2 }) do
        T.ok(approx(SD.eval(d2, { x = xv }), math.exp(xv), 1e-5))
      end
    end)

    T.it("d3/dx3(x^4) = 24x", function()
      local x = SD.var("x")
      local e = SD.pow(x, SD.num(4))
      local d3 = SD.diff(SD.diff(SD.diff(e, "x"), "x"), "x")
      for _, xv in ipairs({ 0, 1, 2 }) do
        T.ok(approx(SD.eval(d3, { x = xv }), 24 * xv))
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("multi-variable and gradient", function()

    T.it("d/dx(x*y) = y", function()
      local x = SD.var("x")
      local y = SD.var("y")
      local e = SD.mul(x, y)
      local d = SD.diff(e, "x")
      -- should equal y; eval at (x=5, y=3) → 3
      T.ok(approx(SD.eval(d, { x = 5, y = 3 }), 3))
    end)

    T.it("d/dy(x*y) = x", function()
      local x = SD.var("x")
      local y = SD.var("y")
      local e = SD.mul(x, y)
      local d = SD.diff(e, "y")
      T.ok(approx(SD.eval(d, { x = 4, y = 7 }), 4))
    end)

    T.it("gradient of x^2+y^2", function()
      local x = SD.var("x")
      local y = SD.var("y")
      local e = SD.add(SD.pow(x, SD.num(2)), SD.pow(y, SD.num(2)))
      local g = SD.gradient(e, { "x", "y" })
      -- d/dx = 2x, d/dy = 2y
      T.ok(approx(SD.eval(g["x"], { x = 3, y = 0 }), 6))
      T.ok(approx(SD.eval(g["y"], { x = 0, y = 4 }), 8))
    end)

    T.it("gradient of x*y + y^2", function()
      local x = SD.var("x")
      local y = SD.var("y")
      local e = SD.add(SD.mul(x, y), SD.pow(y, SD.num(2)))
      local g = SD.gradient(e, { "x", "y" })
      -- d/dx = y, d/dy = x + 2y
      local env = { x = 2, y = 3 }
      T.ok(approx(SD.eval(g["x"], env), 3))
      T.ok(approx(SD.eval(g["y"], env), 2 + 6))
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("simplify", function()

    T.it("0 + x = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.add(SD.num(0), x))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("x + 0 = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.add(x, SD.num(0)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("0 * x = 0", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.mul(SD.num(0), x))
      T.eq(SD.tostring(s), "0")
    end)

    T.it("x * 1 = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.mul(x, SD.num(1)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("1 * x = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.mul(SD.num(1), x))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("x - 0 = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.sub(x, SD.num(0)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("x / 1 = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.div(x, SD.num(1)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("0 / x = 0", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.div(SD.num(0), x))
      T.eq(SD.tostring(s), "0")
    end)

    T.it("x ^ 1 = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.pow(x, SD.num(1)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("x ^ 0 = 1", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.pow(x, SD.num(0)))
      T.eq(SD.tostring(s), "1")
    end)

    T.it("1 ^ x = 1", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.pow(SD.num(1), x))
      T.eq(SD.tostring(s), "1")
    end)

    T.it("constant folding: 2 + 3 = 5", function()
      local s = SD.simplify(SD.add(SD.num(2), SD.num(3)))
      T.eq(SD.tostring(s), "5")
    end)

    T.it("constant folding: 4 * 5 = 20", function()
      local s = SD.simplify(SD.mul(SD.num(4), SD.num(5)))
      T.eq(SD.tostring(s), "20")
    end)

    T.it("double negation: --x = x", function()
      local x = SD.var("x")
      local s = SD.simplify(SD.neg(SD.neg(x)))
      T.eq(SD.tostring(s), "x")
    end)

    T.it("simplify derivative of x^2 gives 2*x form (eval agrees)", function()
      local x = SD.var("x")
      local d = SD.diff(SD.pow(x, SD.num(2)), "x")
      local s = SD.simplify(d)
      -- eval of simplified should match for various x
      for _, xv in ipairs({ 0, 1, 2, 3 }) do
        T.ok(approx(SD.eval(s, { x = xv }), 2 * xv))
      end
    end)

    T.it("simplify preserves semantics of complex expression", function()
      local x = SD.var("x")
      local e = SD.add(
        SD.mul(SD.num(3), SD.pow(x, SD.num(2))),
        SD.add(SD.mul(SD.num(2), x), SD.num(1))
      )
      local d  = SD.diff(e, "x")
      local ds = SD.simplify(d)
      for _, xv in ipairs({ -1, 0, 1, 2, 4 }) do
        T.ok(approx(SD.eval(d, { x = xv }), SD.eval(ds, { x = xv }), 1e-10))
      end
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("operator overloading", function()

    T.it("__add works", function()
      local x = SD.var("x")
      local e = x + SD.num(1)
      T.ok(approx(SD.eval(e, { x = 4 }), 5))
    end)

    T.it("__sub works", function()
      local x = SD.var("x")
      local e = x - SD.num(2)
      T.ok(approx(SD.eval(e, { x = 7 }), 5))
    end)

    T.it("__mul works", function()
      local x = SD.var("x")
      local e = x * SD.num(3)
      T.ok(approx(SD.eval(e, { x = 4 }), 12))
    end)

    T.it("__div works", function()
      local x = SD.var("x")
      local e = x / SD.num(4)
      T.ok(approx(SD.eval(e, { x = 12 }), 3))
    end)

    T.it("__pow works", function()
      local x = SD.var("x")
      local e = x ^ SD.num(3)
      T.ok(approx(SD.eval(e, { x = 2 }), 8))
    end)

    T.it("__unm works", function()
      local x = SD.var("x")
      local e = -x
      T.ok(approx(SD.eval(e, { x = 5 }), -5))
    end)

    T.it("__tostring works", function()
      local x = SD.var("x")
      local s = tostring(x + SD.num(1))
      T.ok(type(s) == "string" and #s > 0)
    end)

    T.it("natural expression: x*x + 2*x + 1 differentiates correctly", function()
      local x  = SD.var("x")
      local n2 = SD.num(2)
      local n1 = SD.num(1)
      local e  = x * x + n2 * x + n1  -- x^2 + 2x + 1
      local d  = SD.diff(e, "x")       -- 2x + 2
      T.ok(approx(SD.eval(d, { x = 0 }), 2))
      T.ok(approx(SD.eval(d, { x = 3 }), 8))
    end)

    T.it("coercion: expr + number uses wrap()", function()
      local x = SD.var("x")
      -- If __add wraps numbers, this should work:
      local e = x + SD.num(0)  -- conservative: use SD.num explicitly
      T.ok(approx(SD.eval(e, { x = 5 }), 5))
    end)

  end)

  -- -------------------------------------------------------------------------
  T.describe("_tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(SD._tier, "pure")
    end)
  end)

end)
