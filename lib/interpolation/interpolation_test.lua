if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local I   = require("lib.interpolation")

local abs = math.abs

local function near(a, b, eps)
  eps = eps or 1e-9
  return abs(a - b) <= eps
end

-- ---------------------------------------------------------------------------
T.describe("lerp", function()
  T.it("midpoint", function()
    T.ok(near(I.lerp(0, 1, 0.5), 0.5))
  end)
  T.it("start", function()
    T.eq(I.lerp(0, 1, 0), 0)
  end)
  T.it("end", function()
    T.eq(I.lerp(0, 1, 1), 1)
  end)
  T.it("arbitrary range", function()
    T.ok(near(I.lerp(2, 8, 0.25), 3.5))
  end)
  T.it("negative values", function()
    T.ok(near(I.lerp(-10, 10, 0.5), 0))
  end)
  T.it("t > 1 extrapolates", function()
    T.ok(near(I.lerp(0, 10, 1.5), 15))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("inv_lerp", function()
  T.it("inverse of lerp", function()
    local t = I.inv_lerp(2, 8, 5)
    T.ok(near(I.lerp(2, 8, t), 5))
  end)
  T.it("at start", function()
    T.ok(near(I.inv_lerp(0, 10, 0), 0))
  end)
  T.it("at end", function()
    T.ok(near(I.inv_lerp(0, 10, 10), 1))
  end)
  T.it("midpoint", function()
    T.ok(near(I.inv_lerp(4, 8, 6), 0.5))
  end)
  T.it("equal endpoints returns 0", function()
    T.eq(I.inv_lerp(5, 5, 5), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("clamp", function()
  T.it("within range", function()
    T.eq(I.clamp(5, 0, 10), 5)
  end)
  T.it("below min", function()
    T.eq(I.clamp(-3, 0, 10), 0)
  end)
  T.it("above max", function()
    T.eq(I.clamp(15, 0, 10), 10)
  end)
  T.it("at boundary lo", function()
    T.eq(I.clamp(0, 0, 10), 0)
  end)
  T.it("at boundary hi", function()
    T.eq(I.clamp(10, 0, 10), 10)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("remap", function()
  T.it("midpoint", function()
    T.ok(near(I.remap(5, 0, 10, 0, 100), 50))
  end)
  T.it("start", function()
    T.ok(near(I.remap(0, 0, 10, 20, 30), 20))
  end)
  T.it("end", function()
    T.ok(near(I.remap(10, 0, 10, 20, 30), 30))
  end)
  T.it("reversed output range", function()
    T.ok(near(I.remap(0, 0, 1, 1, 0), 1))
    T.ok(near(I.remap(1, 0, 1, 1, 0), 0))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("smoothstep", function()
  T.it("at a returns 0", function()
    T.ok(near(I.smoothstep(0, 1, 0), 0))
  end)
  T.it("at b returns 1", function()
    T.ok(near(I.smoothstep(0, 1, 1), 1))
  end)
  T.it("midpoint = 0.5", function()
    T.ok(near(I.smoothstep(0, 1, 0.5), 0.5))
  end)
  T.it("symmetric", function()
    local v1 = I.smoothstep(0, 1, 0.25)
    local v2 = I.smoothstep(0, 1, 0.75)
    T.ok(near(v1 + v2, 1, 1e-9))
  end)
  T.it("below a clamps to 0", function()
    T.ok(near(I.smoothstep(0, 1, -0.5), 0))
  end)
  T.it("above b clamps to 1", function()
    T.ok(near(I.smoothstep(0, 1, 1.5), 1))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("smootherstep", function()
  T.it("at a returns 0", function()
    T.ok(near(I.smootherstep(0, 1, 0), 0))
  end)
  T.it("at b returns 1", function()
    T.ok(near(I.smootherstep(0, 1, 1), 1))
  end)
  T.it("midpoint = 0.5", function()
    T.ok(near(I.smootherstep(0, 1, 0.5), 0.5))
  end)
  T.it("symmetric", function()
    local v1 = I.smootherstep(0, 1, 0.3)
    local v2 = I.smootherstep(0, 1, 0.7)
    T.ok(near(v1 + v2, 1, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("piecewise_linear", function()
  local xs = {0, 1, 3, 6}
  local ys = {0, 2, 4, 10}

  T.it("at first endpoint", function()
    T.ok(near(I.piecewise_linear(xs, ys, 0), 0))
  end)
  T.it("at last endpoint", function()
    T.ok(near(I.piecewise_linear(xs, ys, 6), 10))
  end)
  T.it("at interior knot", function()
    T.ok(near(I.piecewise_linear(xs, ys, 1), 2))
  end)
  T.it("between two knots", function()
    -- Between x=1 (y=2) and x=3 (y=4): at x=2 → y=3
    T.ok(near(I.piecewise_linear(xs, ys, 2), 3))
  end)
  T.it("single interval", function()
    T.ok(near(I.piecewise_linear({0,1},{0,5}, 0.4), 2))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("cubic_spline passes through control points", function()
  local xs = {0, 1, 2, 3, 4}
  local ys = {0, 1, 0, 1, 0}
  local sp = I.cubic_spline(xs, ys)

  for k = 1, #xs do
    T.it("passes through point "..k, function()
      T.ok(near(sp:eval(xs[k]), ys[k], 1e-8))
    end)
  end

  T.it("eval_array returns correct length", function()
    local out = sp:eval_array({0, 0.5, 1, 2})
    T.eq(#out, 4)
    T.ok(near(out[1], 0, 1e-8))
    T.ok(near(out[3], 1, 1e-8))
  end)

  T.it("deriv is finite", function()
    local d = sp:deriv(1.5)
    T.ok(d == d)  -- not NaN
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("catmull_rom passes through control points", function()
  local xs = {0, 1, 2, 3, 4}
  local ys = {0, 1, 4, 9, 16}
  local sp = I.catmull_rom(xs, ys)

  for k = 1, #xs do
    T.it("passes through point "..k, function()
      T.ok(near(sp:eval(xs[k]), ys[k], 1e-9))
    end)
  end

  T.it("eval at interior is smooth", function()
    local v = sp:eval(1.5)
    T.ok(v > ys[2] and v < ys[3])  -- between y[2]=1 and y[3]=4
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("monotone_cubic preserves monotonicity", function()
  local xs = {0, 1, 2, 3, 4, 5}
  local ys = {0, 1, 2, 3, 4, 5}  -- strictly increasing
  local sp = I.monotone_cubic(xs, ys)

  T.it("passes through control points", function()
    for k = 1, #xs do
      T.ok(near(sp:eval(xs[k]), ys[k], 1e-9))
    end
  end)

  T.it("monotone at sampled interior points", function()
    local prev = sp:eval(0)
    for t = 1, 40 do
      local v = sp:eval(t * 0.125)
      T.ok(v >= prev - 1e-9)
      prev = v
    end
  end)

  T.it("non-monotone: flat region produces flat output", function()
    local xs2 = {0, 1, 2, 3}
    local ys2 = {0, 1, 1, 2}
    local sp2 = I.monotone_cubic(xs2, ys2)
    -- At the flat region midpoint the value should be ~1
    local v = sp2:eval(1.5)
    T.ok(v >= 0.99 and v <= 1.01)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("lagrange", function()
  T.it("two points → linear", function()
    T.ok(near(I.lagrange({0,2},{0,4}, 1), 2))
  end)
  T.it("three points → quadratic (x²)", function()
    -- f(x)=x²: (0,0),(1,1),(2,4)
    T.ok(near(I.lagrange({0,1,2},{0,1,4}, 1.5), 2.25, 1e-10))
  end)
  T.it("at control points", function()
    local xs = {0,1,2}; local ys = {3,5,7}
    for k = 1, #xs do
      T.ok(near(I.lagrange(xs, ys, xs[k]), ys[k], 1e-10))
    end
  end)
  T.it("degree-3 exact", function()
    -- f(x) = x³ - x: (−1,0),(0,0),(1,0),(2,6)
    local xs = {-1, 0, 1, 2}
    local ys = {0, 0, 0, 6}
    T.ok(near(I.lagrange(xs, ys, 1.5), 1.875, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("newton_interp / newton_eval", function()
  T.it("linear data", function()
    local xs = {0, 1, 2}
    local ys = {1, 3, 5}  -- y = 2x+1
    local c = I.newton_interp(xs, ys)
    T.ok(near(I.newton_eval(c, xs, 1.5), 4, 1e-9))
  end)

  T.it("quadratic data", function()
    -- y = x²: xs={0,1,2,3}
    local xs = {0, 1, 2, 3}
    local ys = {0, 1, 4, 9}
    local c = I.newton_interp(xs, ys)
    T.ok(near(I.newton_eval(c, xs, 2.5), 6.25, 1e-9))
  end)

  T.it("reproduces input points", function()
    local xs = {1, 2, 4, 7}
    local ys = {3, 6, 2, 8}
    local c = I.newton_interp(xs, ys)
    for k = 1, #xs do
      T.ok(near(I.newton_eval(c, xs, xs[k]), ys[k], 1e-8))
    end
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("bezier", function()
  T.it("2-point curve = lerp", function()
    local pts = {{0,0},{4,8}}
    local x, y = I.bezier(pts, 0.5)
    T.ok(near(x, 2, 1e-12))
    T.ok(near(y, 4, 1e-12))
  end)
  T.it("2-point at t=0", function()
    local pts = {{1,2},{5,6}}
    local x, y = I.bezier(pts, 0)
    T.ok(near(x, 1)); T.ok(near(y, 2))
  end)
  T.it("2-point at t=1", function()
    local pts = {{1,2},{5,6}}
    local x, y = I.bezier(pts, 1)
    T.ok(near(x, 5)); T.ok(near(y, 6))
  end)
  T.it("3-point quadratic midpoint", function()
    -- Control pts: (0,0),(0.5,1),(1,0); midpoint at t=0.5 is (0.5,0.5)
    local pts = {{0,0},{0.5,1},{1,0}}
    local x, y = I.bezier(pts, 0.5)
    T.ok(near(x, 0.5, 1e-12))
    T.ok(near(y, 0.5, 1e-12))
  end)
  T.it("4-point cubic at t=0 and t=1 match endpoints", function()
    local pts = {{0,0},{1,2},{2,-1},{3,0}}
    local x0, y0 = I.bezier(pts, 0)
    local x1, y1 = I.bezier(pts, 1)
    T.ok(near(x0, 0)); T.ok(near(y0, 0))
    T.ok(near(x1, 3)); T.ok(near(y1, 0))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("bspline", function()
  T.it("linear b-spline through endpoints at t=0 and t=1", function()
    -- Degree-1 b-spline with clamped knots
    local pts = {{0,0},{1,1},{2,0},{3,1}}
    local n = #pts  -- 4
    local d = 1
    -- Clamped knot vector: d+1 zeros, n-d-1 interior, d+1 ones (for 0..1 range)
    -- For n=4, d=1: knots length = n+d+1 = 6: {0,0,1/3,2/3,1,1}
    local knots = {0, 0, 1/3, 2/3, 1, 1}
    local x0, y0 = I.bspline(pts, knots, d, 0)
    local x1, y1 = I.bspline(pts, knots, d, 0.999)
    T.ok(near(x0, pts[1][1], 1e-6))
    T.ok(near(y0, pts[1][2], 1e-6))
    -- Near endpoint
    T.ok(near(x1, pts[n][1], 0.1))
  end)
  T.it("quadratic bspline stays within control point hull y range", function()
    local pts = {{0,0},{1,2},{2,0},{3,2},{4,0}}
    local knots = {0,0,0,0.25,0.5,0.75,1,1,1}
    local d = 2
    for ti = 0, 9 do
      local t = ti * 0.1
      local _x, y = I.bspline(pts, knots, d, t)
      T.ok(y >= -0.1 and y <= 2.1)
    end
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("linear_regression", function()
  T.it("exact two-point fit", function()
    local a, b, r2 = I.linear_regression({0, 1}, {0, 2})
    T.ok(near(a, 2, 1e-9))
    T.ok(near(b, 0, 1e-9))
    T.ok(near(r2, 1, 1e-9))
  end)
  T.it("r_squared = 1 for perfectly linear data", function()
    local xs = {1, 2, 3, 4, 5}
    local ys = {3, 5, 7, 9, 11}  -- y = 2x+1
    local a, b, r2 = I.linear_regression(xs, ys)
    T.ok(near(a, 2, 1e-9))
    T.ok(near(b, 1, 1e-9))
    T.ok(near(r2, 1, 1e-9))
  end)
  T.it("r_squared < 1 for noisy data", function()
    local xs = {1, 2, 3, 4, 5}
    local ys = {2, 2.5, 4.1, 4.5, 5}
    local _a, _b, r2 = I.linear_regression(xs, ys)
    T.ok(r2 < 1 and r2 > 0.9)
  end)
  T.it("predicts values near truth", function()
    local xs = {0, 1, 2, 3}
    local ys = {1, 3, 5, 7}  -- y = 2x + 1
    local a, b = I.linear_regression(xs, ys)
    T.ok(near(a * 1.5 + b, 4, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("poly_eval", function()
  T.it("constant polynomial", function()
    T.ok(near(I.poly_eval({5}, 3), 5))
  end)
  T.it("linear polynomial 2x+1", function()
    T.ok(near(I.poly_eval({1, 2}, 3), 7))
  end)
  T.it("quadratic x²+2x+1=(x+1)²", function()
    T.ok(near(I.poly_eval({1, 2, 1}, 4), 25))
  end)
  T.it("at x=0 returns c0", function()
    T.ok(near(I.poly_eval({7, 3, 1}, 0), 7))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("poly_regression", function()
  T.it("degree-2 fit for quadratic data y=x²", function()
    local xs = {-2, -1, 0, 1, 2, 3}
    local ys = {4,   1, 0, 1, 4, 9}
    local c, r2 = I.poly_regression(xs, ys, 2)
    T.ok(near(r2, 1, 1e-6))
    -- coefficients should be [0, 0, 1] (c0=0, c1=0, c2=1)
    T.ok(near(c[1], 0, 1e-6))
    T.ok(near(c[2], 0, 1e-6))
    T.ok(near(c[3], 1, 1e-6))
  end)
  T.it("degree-1 fit matches linear_regression", function()
    local xs = {1, 2, 3, 4}
    local ys = {2, 4, 6, 8}  -- y = 2x
    local c, r2 = I.poly_regression(xs, ys, 1)
    T.ok(near(r2, 1, 1e-9))
    T.ok(near(c[2], 2, 1e-8))  -- slope
  end)
  T.it("evaluates fitted polynomial correctly", function()
    local xs = {0, 1, 2, 3, 4}
    local ys = {1, 4, 9, 16, 25}  -- y = (x+1)²
    local c = I.poly_regression(xs, ys, 2)
    -- Should reconstruct (x+1)² = x²+2x+1
    T.ok(near(I.poly_eval(c, 5), 36, 1e-4))
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("nearest", function()
  local xs = {0, 1, 2, 4, 8}
  local ys = {10, 20, 30, 40, 50}

  T.it("exact match", function()
    T.ok(near(I.nearest(xs, ys, 2), 30))
  end)
  T.it("closer to left", function()
    T.ok(near(I.nearest(xs, ys, 0.3), 10))
  end)
  T.it("closer to right", function()
    T.ok(near(I.nearest(xs, ys, 0.7), 20))
  end)
  T.it("below range", function()
    T.ok(near(I.nearest(xs, ys, -5), 10))
  end)
  T.it("above range", function()
    T.ok(near(I.nearest(xs, ys, 100), 50))
  end)
  T.it("between large gap — closer to 4", function()
    T.ok(near(I.nearest(xs, ys, 5), 40))
  end)
end)
