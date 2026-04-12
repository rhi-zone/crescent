if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local IC = require("lib.interpolation_curves")

local abs = math.abs

local function near(a, b, tol)
  tol = tol or 1e-9
  return abs(a - b) <= tol
end

-- ---------------------------------------------------------------------------
-- cubic_spline
-- ---------------------------------------------------------------------------

T.describe("cubic_spline", function()
  local xs = {0, 1, 2, 3, 4}
  local ys = {0, 1, 0, 1, 0}
  local sp = IC.cubic_spline(xs, ys)

  T.it("passes through all data points", function()
    for i = 1, #xs do
      T.ok(near(sp:eval(xs[i]), ys[i], 1e-10), "eval at xs["..i.."]="..ys[i])
    end
  end)

  T.it("eval_all returns array matching individual evals", function()
    local qxs = {0.5, 1.5, 2.5, 3.5}
    local results = sp:eval_all(qxs)
    T.eq(#results, #qxs)
    for i = 1, #qxs do
      T.ok(near(results[i], sp:eval(qxs[i]), 1e-14))
    end
  end)

  T.it("natural boundary: second derivative = 0 at endpoints", function()
    T.ok(near(sp:deriv2(xs[1]), 0, 1e-10), "deriv2 at left endpoint")
    T.ok(near(sp:deriv2(xs[#xs]), 0, 1e-10), "deriv2 at right endpoint")
  end)

  T.it("deriv returns a number", function()
    local d = sp:deriv(1.5)
    T.ok(type(d) == "number")
  end)

  T.it("deriv2 returns a number", function()
    local d2 = sp:deriv2(1.5)
    T.ok(type(d2) == "number")
  end)

  T.it("integrate returns plausible value", function()
    local area = sp:integrate(0, 4)
    T.ok(type(area) == "number")
    -- Integral of the spline over [0,4]; must be finite and non-zero given data
    T.ok(area > 0 and area < 10, "area="..area)
  end)

  T.it("integrate is consistent: sum of parts = whole", function()
    local whole = sp:integrate(0, 4)
    local part1 = sp:integrate(0, 2)
    local part2 = sp:integrate(2, 4)
    T.ok(near(whole, part1 + part2, 1e-10))
  end)

  T.it("integrate reversed sign", function()
    local fwd = sp:integrate(1, 3)
    local rev = sp:integrate(3, 1)
    T.ok(near(fwd, -rev, 1e-10))
  end)

  T.it("continuity at interior knots", function()
    -- Eval from left and right of interior knot should match
    local eps = 1e-9
    for i = 2, #xs - 1 do
      local left  = sp:eval(xs[i] - eps)
      local right = sp:eval(xs[i] + eps)
      T.ok(near(left, right, 1e-5), "continuity at xs["..i.."]")
    end
  end)

  T.it("two-point spline: linear", function()
    local sp2 = IC.cubic_spline({0, 1}, {0, 2})
    T.ok(near(sp2:eval(0.5), 1.0, 1e-10))
    T.ok(near(sp2:eval(0), 0, 1e-10))
    T.ok(near(sp2:eval(1), 2, 1e-10))
  end)

  T.it("single interval deriv matches finite difference", function()
    local sp2 = IC.cubic_spline({0, 1, 2, 3}, {0, 1, 4, 9})
    local x = 1.5
    local h = 1e-5
    local fd = (sp2:eval(x + h) - sp2:eval(x - h)) / (2 * h)
    T.ok(near(sp2:deriv(x), fd, 1e-4), "deriv vs fd at x=1.5")
  end)
end)

-- ---------------------------------------------------------------------------
-- clamped_spline
-- ---------------------------------------------------------------------------

T.describe("clamped_spline", function()
  local xs = {0, 1, 2, 3}
  local ys = {0, 1, 0, 1}

  T.it("passes through data points", function()
    local sp = IC.clamped_spline(xs, ys, 0, 0)
    for i = 1, #xs do
      T.ok(near(sp:eval(xs[i]), ys[i], 1e-10))
    end
  end)

  T.it("respects left endpoint derivative", function()
    local dy0 = 2.0
    local sp = IC.clamped_spline(xs, ys, dy0, 0)
    local h = 1e-6
    local fd = (sp:eval(xs[1] + h) - sp:eval(xs[1])) / h
    T.ok(near(fd, dy0, 1e-4), "left deriv: fd="..fd.." expected="..dy0)
  end)

  T.it("respects right endpoint derivative", function()
    local dyn = -1.5
    local sp = IC.clamped_spline(xs, ys, 0, dyn)
    local h = 1e-6
    local fd = (sp:eval(xs[#xs]) - sp:eval(xs[#xs] - h)) / h
    T.ok(near(fd, dyn, 1e-4), "right deriv: fd="..fd.." expected="..dyn)
  end)

  T.it("eval_all works", function()
    local sp = IC.clamped_spline(xs, ys, 0, 0)
    local qxs = {0.5, 1.5, 2.5}
    local res = sp:eval_all(qxs)
    T.eq(#res, 3)
    for i = 1, 3 do T.ok(type(res[i]) == "number") end
  end)

  T.it("integrate returns number", function()
    local sp = IC.clamped_spline(xs, ys, 0, 0)
    T.ok(type(sp:integrate(0, 3)) == "number")
  end)
end)

-- ---------------------------------------------------------------------------
-- monotone_spline
-- ---------------------------------------------------------------------------

T.describe("monotone_spline", function()
  T.it("passes through data points", function()
    local xs = {0, 1, 2, 3, 4}
    local ys = {0, 1, 2, 3, 4}
    local sp = IC.monotone_spline(xs, ys)
    for i = 1, #xs do
      T.ok(near(sp:eval(xs[i]), ys[i], 1e-10))
    end
  end)

  T.it("monotone on strictly increasing data", function()
    local xs = {0, 1, 2, 3, 4}
    local ys = {0, 1, 3, 6, 10}
    local sp = IC.monotone_spline(xs, ys)
    local prev = sp:eval(0)
    for i = 1, 40 do
      local x = i * 0.1
      local val = sp:eval(x)
      T.ok(val >= prev - 1e-10, "monotone at x="..x.." val="..val.." prev="..prev)
      prev = val
    end
  end)

  T.it("no overshoot on step-like data", function()
    local xs = {0, 1, 2, 3, 4}
    local ys = {0, 0, 1, 1, 1}
    local sp = IC.monotone_spline(xs, ys)
    -- Values must stay in [0, 1]
    for i = 0, 40 do
      local x = i * 0.1
      local val = sp:eval(x)
      T.ok(val >= -1e-10 and val <= 1 + 1e-10, "val in [0,1] at x="..x)
    end
  end)

  T.it("deriv returns number", function()
    local sp = IC.monotone_spline({0, 1, 2}, {0, 1, 4})
    T.ok(type(sp:deriv(0.5)) == "number")
  end)

  T.it("deriv2 returns number", function()
    local sp = IC.monotone_spline({0, 1, 2}, {0, 1, 4})
    T.ok(type(sp:deriv2(0.5)) == "number")
  end)

  T.it("eval_all consistent with eval", function()
    local xs = {0, 1, 2, 3}
    local ys = {1, 2, 1, 3}
    local sp = IC.monotone_spline(xs, ys)
    local qxs = {0.3, 1.1, 2.7}
    local res = sp:eval_all(qxs)
    for i = 1, #qxs do
      T.ok(near(res[i], sp:eval(qxs[i]), 1e-14))
    end
  end)

  T.it("integrate returns plausible value", function()
    local xs = {0, 1, 2, 3}
    local ys = {0, 1, 2, 3}
    local sp = IC.monotone_spline(xs, ys)
    -- Integral of y=x from 0 to 3 = 4.5
    T.ok(near(sp:integrate(0, 3), 4.5, 1e-5))
  end)

  T.it("two-point monotone spline", function()
    local sp = IC.monotone_spline({0, 1}, {0, 1})
    T.ok(near(sp:eval(0.5), 0.5, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- akima_spline
-- ---------------------------------------------------------------------------

T.describe("akima_spline", function()
  local xs = {0, 1, 2, 3, 4, 5}
  local ys = {0, 1, 4, 9, 16, 25}  -- x^2

  T.it("passes through data points", function()
    local sp = IC.akima_spline(xs, ys)
    for i = 1, #xs do
      T.ok(near(sp:eval(xs[i]), ys[i], 1e-10))
    end
  end)

  T.it("eval_all consistent with eval", function()
    local sp = IC.akima_spline(xs, ys)
    local qxs = {0.5, 1.5, 2.5, 3.5, 4.5}
    local res = sp:eval_all(qxs)
    for i = 1, #qxs do
      T.ok(near(res[i], sp:eval(qxs[i]), 1e-14))
    end
  end)

  T.it("approximates x^2 well on interior", function()
    local sp = IC.akima_spline(xs, ys)
    for i = 1, 9 do
      local x = i * 0.5
      T.ok(near(sp:eval(x), x * x, 0.1), "akima x^2 at x="..x)
    end
  end)

  T.it("deriv returns number", function()
    local sp = IC.akima_spline(xs, ys)
    T.ok(type(sp:deriv(2.5)) == "number")
  end)

  T.it("deriv2 returns number", function()
    local sp = IC.akima_spline(xs, ys)
    T.ok(type(sp:deriv2(2.5)) == "number")
  end)

  T.it("integrate returns number", function()
    local sp = IC.akima_spline(xs, ys)
    T.ok(type(sp:integrate(0, 5)) == "number")
  end)

  T.it("two-point akima spline", function()
    local sp = IC.akima_spline({0, 1}, {0, 1})
    T.ok(near(sp:eval(0.5), 0.5, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- linear
-- ---------------------------------------------------------------------------

T.describe("linear", function()
  local xs = {0, 1, 2, 3}
  local ys = {0, 2, 1, 4}

  T.it("passes through data points", function()
    local interp = IC.linear(xs, ys)
    for i = 1, #xs do
      T.ok(near(interp:eval(xs[i]), ys[i], 1e-12))
    end
  end)

  T.it("linear between knots", function()
    local interp = IC.linear(xs, ys)
    -- Between (0,0) and (1,2): at x=0.5 expect y=1
    T.ok(near(interp:eval(0.5), 1.0, 1e-12))
    -- Between (2,1) and (3,4): at x=2.5 expect y=2.5
    T.ok(near(interp:eval(2.5), 2.5, 1e-12))
  end)

  T.it("eval_all consistent with eval", function()
    local interp = IC.linear(xs, ys)
    local qxs = {0.25, 1.75, 2.5}
    local res = interp:eval_all(qxs)
    for i = 1, #qxs do
      T.ok(near(res[i], interp:eval(qxs[i]), 1e-14))
    end
  end)

  T.it("extrapolation at bounds clamps to last segment", function()
    local interp = IC.linear(xs, ys)
    -- Out of left bound: clamps to first segment extrapolation
    local v_lo = interp:eval(-1)
    T.ok(type(v_lo) == "number")
    -- Out of right bound
    local v_hi = interp:eval(10)
    T.ok(type(v_hi) == "number")
  end)

  T.it("two-point linear", function()
    local interp = IC.linear({0, 1}, {3, 7})
    T.ok(near(interp:eval(0.5), 5.0, 1e-12))
  end)
end)

-- ---------------------------------------------------------------------------
-- polynomial_fit
-- ---------------------------------------------------------------------------

T.describe("polynomial_fit", function()
  T.it("degree=1 gives exact line through 2 points", function()
    local poly = IC.polynomial_fit({0, 1}, {1, 3}, 1)
    T.ok(near(poly:eval(0), 1, 1e-10))
    T.ok(near(poly:eval(1), 3, 1e-10))
    T.ok(near(poly:eval(0.5), 2, 1e-10))
    -- coefficients: a0=1, a1=2
    T.ok(near(poly.coefficients[1], 1, 1e-10))
    T.ok(near(poly.coefficients[2], 2, 1e-10))
    T.ok(near(poly.r_squared, 1.0, 1e-10))
  end)

  T.it("degree=2 gives exact parabola for 3 points on y=x^2", function()
    local poly = IC.polynomial_fit({-1, 0, 1}, {1, 0, 1}, 2)
    T.ok(near(poly:eval(-1), 1, 1e-8))
    T.ok(near(poly:eval(0),  0, 1e-8))
    T.ok(near(poly:eval(1),  1, 1e-8))
    -- a0=0, a1=0, a2=1
    T.ok(near(poly.coefficients[1], 0, 1e-8))
    T.ok(near(poly.coefficients[2], 0, 1e-8))
    T.ok(near(poly.coefficients[3], 1, 1e-8))
    T.ok(near(poly.r_squared, 1.0, 1e-8))
  end)

  T.it("r_squared close to 1 for good fit", function()
    -- Fit y = 2x + 1 with slight noise
    local xs = {1, 2, 3, 4, 5}
    local ys = {3.1, 4.9, 7.0, 9.1, 10.9}
    local poly = IC.polynomial_fit(xs, ys, 1)
    T.ok(poly.r_squared > 0.99, "r_squared="..poly.r_squared)
  end)

  T.it("degree=0 gives mean", function()
    local xs = {1, 2, 3, 4}
    local ys = {2, 2, 2, 2}
    local poly = IC.polynomial_fit(xs, ys, 0)
    T.ok(near(poly:eval(0), 2, 1e-10))
    T.ok(near(poly:eval(5), 2, 1e-10))
    T.ok(near(poly.r_squared, 1.0, 1e-10))
  end)

  T.it("coefficients length = degree + 1", function()
    local poly = IC.polynomial_fit({1, 2, 3, 4, 5}, {1, 4, 9, 16, 25}, 2)
    T.eq(#poly.coefficients, 3)
  end)

  T.it("degree=3 fits cubic exactly", function()
    -- y = x^3: points at x = -1, 0, 1, 2
    local poly = IC.polynomial_fit({-1, 0, 1, 2}, {-1, 0, 1, 8}, 3)
    T.ok(near(poly:eval(-1), -1, 1e-8))
    T.ok(near(poly:eval(0),   0, 1e-8))
    T.ok(near(poly:eval(1),   1, 1e-8))
    T.ok(near(poly:eval(2),   8, 1e-8))
    T.ok(near(poly.r_squared, 1.0, 1e-8))
  end)

  T.it("constant r_squared is 1 when ss_tot=0", function()
    local poly = IC.polynomial_fit({1, 2, 3}, {5, 5, 5}, 1)
    T.ok(near(poly.r_squared, 1.0, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- curve_2d
-- ---------------------------------------------------------------------------

T.describe("curve_2d", function()
  local points = {{0, 0}, {1, 1}, {2, 0}, {3, 1}}

  T.it("eval(0) returns first point", function()
    local c = IC.curve_2d(points)
    local pt = c:eval(0)
    T.ok(near(pt[1], 0, 1e-10))
    T.ok(near(pt[2], 0, 1e-10))
  end)

  T.it("eval(1) returns last point", function()
    local c = IC.curve_2d(points)
    local pt = c:eval(1)
    T.ok(near(pt[1], 3, 1e-10))
    T.ok(near(pt[2], 1, 1e-10))
  end)

  T.it("eval returns {x, y} table", function()
    local c = IC.curve_2d(points)
    local pt = c:eval(0.5)
    T.ok(type(pt) == "table")
    T.ok(type(pt[1]) == "number")
    T.ok(type(pt[2]) == "number")
  end)

  T.it("sample returns array of n points", function()
    local c = IC.curve_2d(points)
    local pts = c:sample(10)
    T.eq(#pts, 10)
    for i = 1, 10 do
      T.ok(type(pts[i][1]) == "number")
      T.ok(type(pts[i][2]) == "number")
    end
  end)

  T.it("sample first and last points match eval(0) and eval(1)", function()
    local c = IC.curve_2d(points)
    local pts = c:sample(5)
    T.ok(near(pts[1][1], c:eval(0)[1], 1e-10))
    T.ok(near(pts[1][2], c:eval(0)[2], 1e-10))
    T.ok(near(pts[5][1], c:eval(1)[1], 1e-10))
    T.ok(near(pts[5][2], c:eval(1)[2], 1e-10))
  end)

  T.it("length is positive", function()
    local c = IC.curve_2d(points)
    T.ok(c:length() > 0)
  end)

  T.it("length is approximately correct for straight line", function()
    -- Straight line from (0,0) to (3,0)
    local line = {{0,0},{1,0},{2,0},{3,0}}
    local c = IC.curve_2d(line)
    T.ok(near(c:length(), 3.0, 1e-10))
  end)

  T.it("out-of-range t clamped", function()
    local c = IC.curve_2d(points)
    local lo = c:eval(-0.5)
    local hi = c:eval(1.5)
    T.ok(near(lo[1], c:eval(0)[1], 1e-10))
    T.ok(near(hi[1], c:eval(1)[1], 1e-10))
  end)

  T.it("two-point curve works", function()
    local c = IC.curve_2d({{0, 0}, {1, 1}})
    local p0 = c:eval(0)
    local p1 = c:eval(1)
    T.ok(near(p0[1], 0, 1e-10))
    T.ok(near(p1[1], 1, 1e-10))
  end)

  T.it("linear type option", function()
    local c = IC.curve_2d(points, { type = "linear" })
    local p0 = c:eval(0)
    T.ok(near(p0[1], 0, 1e-10))
    T.ok(near(p0[2], 0, 1e-10))
  end)

  T.it("cubic_spline type option", function()
    local c = IC.curve_2d(points, { type = "cubic_spline" })
    local pt = c:eval(0.5)
    T.ok(type(pt[1]) == "number")
    T.ok(type(pt[2]) == "number")
  end)
end)

-- ---------------------------------------------------------------------------
-- resample
-- ---------------------------------------------------------------------------

T.describe("resample", function()
  T.it("interpolates at existing xs gives original ys", function()
    local xs = {0, 1, 2, 3, 4}
    local ys = {0, 1, 4, 9, 16}
    local res = IC.resample(xs, ys, xs)
    for i = 1, #xs do
      T.ok(near(res[i], ys[i], 1e-12))
    end
  end)

  T.it("interpolates midpoints linearly", function()
    local xs = {0, 2, 4}
    local ys = {0, 2, 4}  -- y=x
    local new_xs = {1, 3}
    local res = IC.resample(xs, ys, new_xs)
    T.ok(near(res[1], 1, 1e-12))
    T.ok(near(res[2], 3, 1e-12))
  end)

  T.it("returns correct length array", function()
    local xs = {0, 1, 2}
    local ys = {0, 1, 0}
    local new_xs = {0.1, 0.5, 0.9, 1.5, 1.9}
    local res = IC.resample(xs, ys, new_xs)
    T.eq(#res, 5)
  end)

  T.it("works with single new point", function()
    local res = IC.resample({0, 1}, {0, 10}, {0.5})
    T.ok(near(res[1], 5, 1e-12))
  end)
end)

-- ---------------------------------------------------------------------------
-- Edge cases
-- ---------------------------------------------------------------------------

T.describe("edge cases", function()
  T.it("cubic_spline: two points gives linear", function()
    local sp = IC.cubic_spline({0, 1}, {0, 2})
    T.ok(near(sp:eval(0), 0, 1e-10))
    T.ok(near(sp:eval(0.5), 1, 1e-10))
    T.ok(near(sp:eval(1), 2, 1e-10))
  end)

  T.it("cubic_spline out-of-bounds extrapolation returns number", function()
    local sp = IC.cubic_spline({0, 1, 2}, {0, 1, 0})
    T.ok(type(sp:eval(-1)) == "number")
    T.ok(type(sp:eval(5)) == "number")
  end)

  T.it("monotone_spline two-point", function()
    local sp = IC.monotone_spline({0, 1}, {0, 1})
    T.ok(near(sp:eval(0), 0, 1e-10))
    T.ok(near(sp:eval(1), 1, 1e-10))
  end)

  T.it("akima_spline two-point", function()
    local sp = IC.akima_spline({0, 1}, {3, 5})
    T.ok(near(sp:eval(0), 3, 1e-10))
    T.ok(near(sp:eval(1), 5, 1e-10))
  end)

  T.it("linear two-point", function()
    local interp = IC.linear({0, 1}, {0, 1})
    T.ok(near(interp:eval(0), 0, 1e-12))
    T.ok(near(interp:eval(1), 1, 1e-12))
    T.ok(near(interp:eval(0.5), 0.5, 1e-12))
  end)

  T.it("polynomial_fit: single point degree=0", function()
    local poly = IC.polynomial_fit({5}, {7}, 0)
    T.ok(near(poly:eval(5), 7, 1e-10))
  end)

  T.it("clamped_spline two-point", function()
    local sp = IC.clamped_spline({0, 1}, {0, 1}, 1, 1)
    T.ok(near(sp:eval(0), 0, 1e-10))
    T.ok(near(sp:eval(1), 1, 1e-10))
  end)

  T.it("curve_2d two-point", function()
    local c = IC.curve_2d({{0, 0}, {3, 4}})
    T.ok(near(c:eval(0)[1], 0, 1e-10))
    T.ok(near(c:eval(1)[1], 3, 1e-10))
    T.ok(near(c:length(), 5, 1e-10))
  end)
end)

-- ---------------------------------------------------------------------------
-- Numerical consistency checks
-- ---------------------------------------------------------------------------

T.describe("numerical consistency", function()
  T.it("cubic_spline deriv matches finite difference", function()
    local sp = IC.cubic_spline({0, 1, 2, 3, 4}, {0, 1, 0, 1, 0})
    local x = 2.3
    local h = 1e-5
    local fd = (sp:eval(x + h) - sp:eval(x - h)) / (2 * h)
    T.ok(near(sp:deriv(x), fd, 1e-4))
  end)

  T.it("cubic_spline integrate matches Gauss quadrature", function()
    -- Use Simpson's rule as reference
    local sp = IC.cubic_spline({0, 1, 2, 3, 4}, {0, 1, 0, 1, 0})
    local a, b = 0.5, 3.5
    local n = 1000
    local dx = (b - a) / n
    local sum = sp:eval(a) + sp:eval(b)
    for i = 1, n - 1 do
      local x = a + i * dx
      sum = sum + (i % 2 == 0 and 2 or 4) * sp:eval(x)
    end
    local simp = sum * dx / 3
    T.ok(near(sp:integrate(a, b), simp, 1e-5))
  end)

  T.it("monotone deriv matches finite difference", function()
    local sp = IC.monotone_spline({0, 1, 2, 3}, {0, 1, 3, 6})
    local x = 1.7
    local h = 1e-5
    local fd = (sp:eval(x + h) - sp:eval(x - h)) / (2 * h)
    T.ok(near(sp:deriv(x), fd, 1e-4))
  end)

  T.it("akima deriv matches finite difference", function()
    local sp = IC.akima_spline({0, 1, 2, 3, 4, 5}, {0, 1, 4, 9, 16, 25})
    local x = 2.3
    local h = 1e-5
    local fd = (sp:eval(x + h) - sp:eval(x - h)) / (2 * h)
    T.ok(near(sp:deriv(x), fd, 1e-4))
  end)

  T.it("clamped deriv matches finite difference", function()
    local sp = IC.clamped_spline({0, 1, 2, 3}, {0, 1, 0, 1}, 0.5, -0.5)
    local x = 1.5
    local h = 1e-5
    local fd = (sp:eval(x + h) - sp:eval(x - h)) / (2 * h)
    T.ok(near(sp:deriv(x), fd, 1e-4))
  end)
end)
