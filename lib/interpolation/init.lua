if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Numerical interpolation: 1D lerp/remap, piecewise linear, natural cubic
-- spline, Catmull-Rom, monotone cubic (Fritsch-Carlson), Lagrange polynomial,
-- Newton divided differences, Bezier (de Casteljau), B-spline, linear and
-- polynomial least-squares regression, nearest-neighbor.
-- Pure Lua, no dependencies.

local M = {}

M._tier = "pure"

--:: Spline = { eval: (self: Spline, x: number) -> number, eval_array: (self: Spline, qxs: { [integer]: number }) -> { [integer]: number }, deriv: (self: Spline, x: number) -> number, ... }

local sqrt = math.sqrt
local floor = math.floor
local abs   = math.abs
local huge  = math.huge

-- ---------------------------------------------------------------------------
-- 1D helpers
-- ---------------------------------------------------------------------------

--: (number, number, number) -> number
M.lerp = function(a, b, t)
  return a + (b - a) * t
end

--: (number, number, number) -> number
M.inv_lerp = function(a, b, v)
  if a == b then return 0 end
  return (v - a) / (b - a)
end

--: (number, number, number) -> number
M.clamp = function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

--: (number, number, number, number, number) -> number
M.remap = function(v, in_lo, in_hi, out_lo, out_hi)
  local t = M.inv_lerp(in_lo, in_hi, v)
  return M.lerp(out_lo, out_hi, t)
end

-- Cubic Hermite smooth step (3t² - 2t³); t clamped to [0,1]
--: (number, number, number) -> number
M.smoothstep = function(a, b, t)
  t = M.clamp(M.inv_lerp(a, b, t), 0, 1)
  return t * t * (3 - 2 * t)
end

-- Quintic smoother step (6t⁵ - 15t⁴ + 10t³); t clamped to [0,1]
--: (number, number, number) -> number
M.smootherstep = function(a, b, t)
  t = M.clamp(M.inv_lerp(a, b, t), 0, 1)
  return t * t * t * (t * (t * 6 - 15) + 10)
end

-- ---------------------------------------------------------------------------
-- Piecewise linear
-- ---------------------------------------------------------------------------

-- Binary search: returns index i such that xs[i] <= x < xs[i+1].
-- Returns 1 if x <= xs[1], n-1 if x >= xs[n].
--: (xs: { [integer]: number }, x: number) -> integer
local function bisect(xs, x)
  local lo, hi = 1, #xs
  if x <= xs[lo] then return lo end
  if x >= xs[hi] then return hi - 1 end
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if xs[mid] <= x then lo = mid else hi = mid end
  end
  return lo
end

--: (xs: { [integer]: number }, ys: { [integer]: number }, x: number) -> number
M.piecewise_linear = function(xs, ys, x)
  local i = bisect(xs, x)
  local dx = xs[i+1] - xs[i]
  if dx == 0 then return ys[i] end
  local t = (x - xs[i]) / dx
  return ys[i] + (ys[i+1] - ys[i]) * t
end

-- ---------------------------------------------------------------------------
-- Natural cubic spline
-- ---------------------------------------------------------------------------

-- Solve tridiagonal system Ax = d using Thomas algorithm.
-- a: sub-diagonal (a[2..n]), b: main diagonal, c: super-diagonal (c[1..n-1])
-- All arrays 1-indexed, length n.
local function thomas(a, b, c, d)
  local n = #b
  local cp = {}   -- modified super-diagonal
  local dp = {}   -- modified rhs
  cp[1] = c[1] / b[1]
  dp[1] = d[1] / b[1]
  for i = 2, n do
    local denom = b[i] - a[i] * cp[i-1]
    cp[i] = (c[i] or 0) / denom
    dp[i] = (d[i] - a[i] * dp[i-1]) / denom
  end
  local x = {}
  x[n] = dp[n]
  for i = n-1, 1, -1 do
    x[i] = dp[i] - cp[i] * x[i+1]
  end
  return x
end

-- Returns a spline object with :eval(x), :eval_array(xs), :deriv(x).
--: (xs: { [integer]: number }, ys: { [integer]: number }) -> Spline
M.cubic_spline = function(xs, ys)
  local n = #xs - 1  -- number of intervals
  assert(n >= 1, "cubic_spline: need at least 2 points")

  -- h[i] = xs[i+1] - xs[i]
  local h = {}
  for i = 1, n do h[i] = xs[i+1] - xs[i] end

  if n == 1 then
    -- Degenerate: single interval — linear
    local spline = {}
    function spline:eval(x)
      local t = (x - xs[1]) / h[1]
      return ys[1] + (ys[2] - ys[1]) * t
    end
    function spline:eval_array(qxs)
      local out = {}
      for i = 1, #qxs do out[i] = self:eval(qxs[i]) end
      return out
    end
    function spline:deriv(_x)
      return (ys[2] - ys[1]) / h[1]
    end
    return spline
  end

  -- Build tridiagonal system for second derivatives M[1..n+1]
  -- Natural BCs: M[1] = M[n+1] = 0 → interior equations only (n-1 unknowns)
  local size = n - 1
  local a_diag = {}  -- main diagonal
  local b_sub  = {}  -- sub-diagonal (index 2..size)
  local c_sup  = {}  -- super-diagonal (index 1..size-1)
  local rhs    = {}

  for i = 1, size do
    local k = i + 1  -- corresponds to xs[k]
    a_diag[i] = 2 * (h[k-1] + h[k])
    b_sub[i]  = h[k]       -- a[i] in Thomas = sub-diag coefficient
    c_sup[i]  = h[k-1]     -- c[i] in Thomas = super-diag coefficient
    rhs[i]    = 6 * ((ys[k+1] - ys[k]) / h[k] - (ys[k] - ys[k-1]) / h[k-1])
  end

  -- Thomas: a=sub, b=main, c=super
  -- Repack: sub-diagonal for Thomas is b_sub[2..size], super is c_sup[1..size-1]
  local ta = {}
  local tb = {}
  local tc = {}
  local td = {}
  for i = 1, size do
    ta[i] = (i > 1) and h[i] or 0      -- sub-diag (h[i] = h[interval index])
    tb[i] = a_diag[i]
    tc[i] = (i < size) and h[i+1] or 0 -- super-diag
    td[i] = rhs[i]
  end

  local Mint = thomas(ta, tb, tc, td)

  -- Full M array: M[1]=0, M[2..n]=Mint[1..n-1], M[n+1]=0
  local Mfull = {}
  Mfull[1] = 0
  for i = 1, n-1 do Mfull[i+1] = Mint[i] end
  Mfull[n+1] = 0

  local spline = { _xs = xs, _ys = ys, _h = h, _M = Mfull, _n = n }

  function spline:_segment(x)
    local i = bisect(self._xs --[[:! { [integer]: number }]], x)
    local n_ = self._n --[[:! integer]]
    if i > n_ then i = n_ end
    return i
  end

  function spline:eval(x)
    local i = self:_segment(x)
    local hi = self._h[i]
    local Mi = self._M[i]
    local Mi1 = self._M[i+1]
    local dx = x - self._xs[i]
    local dx1 = self._xs[i+1] - x
    -- Standard cubic spline formula
    return (Mi * dx1^3 / (6*hi))
         + (Mi1 * dx^3 / (6*hi))
         + ((self._ys[i]/hi - Mi*hi/6) * dx1)
         + ((self._ys[i+1]/hi - Mi1*hi/6) * dx)
  end

  function spline:eval_array(qxs)
    local out = {}
    for i = 1, #qxs do out[i] = self:eval(qxs[i]) end
    return out
  end

  function spline:deriv(x)
    local i = self:_segment(x)
    local hi = self._h[i]
    local Mi = self._M[i]
    local Mi1 = self._M[i+1]
    local dx = x - self._xs[i]
    local dx1 = self._xs[i+1] - x
    return (-Mi * dx1^2 / (2*hi))
         + (Mi1 * dx^2 / (2*hi))
         + (self._ys[i+1]/hi - Mi1*hi/6)
         - (self._ys[i]/hi - Mi*hi/6)
  end

  return spline
end

-- ---------------------------------------------------------------------------
-- Catmull-Rom spline
-- ---------------------------------------------------------------------------

-- Returns a spline that passes through all (xs, ys) control points.
-- Uses centripetal parameterization with uniform spacing (standard Catmull-Rom).
--: (xs: { [integer]: number }, ys: { [integer]: number }) -> Spline
M.catmull_rom = function(xs, ys)
  local n = #xs
  assert(n >= 2, "catmull_rom: need at least 2 points")

  -- Extend endpoints with phantom points for boundary tangents
  local ex = {}
  local ey = {}
  ex[1] = 2*xs[1] - xs[2];     ey[1] = 2*ys[1] - ys[2]
  for i = 1, n do ex[i+1] = xs[i]; ey[i+1] = ys[i] end
  ex[n+2] = 2*xs[n] - xs[n-1]; ey[n+2] = 2*ys[n] - ys[n-1]
  -- Now ex/ey has n+2 points; segment i (1..n-1) uses ex[i..i+3], ey[i..i+3]
  -- But we need to map x → segment. Original xs are ex[2..n+1].

  local spline = { _xs = xs, _ys = ys, _ex = ex, _ey = ey, _n = n }

  function spline:eval(x)
    local i = bisect(self._xs, x)
    -- Segment i uses extended points i, i+1, i+2, i+3
    local p0x, p0y = self._ex[i],   self._ey[i]
    local p1x, p1y = self._ex[i+1], self._ey[i+1]
    local p2x, p2y = self._ex[i+2], self._ey[i+2]
    local p3x, p3y = self._ex[i+3], self._ey[i+3]
    local dx = self._xs[i+1] - self._xs[i]
    local t = (dx == 0) and 0 or (x - self._xs[i]) / dx
    -- Catmull-Rom basis
    local t2 = t * t
    local t3 = t2 * t
    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 -   t2
    -- tangents scaled by 0.5*(p[i+2] - p[i]) etc.
    local m1y = 0.5 * (p2y - p0y)
    local m2y = 0.5 * (p3y - p1y)
    return h00*p1y + h10*m1y + h01*p2y + h11*m2y
  end

  function spline:eval_array(qxs)
    local out = {}
    for i = 1, #qxs do out[i] = self:eval(qxs[i]) end
    return out
  end

  function spline:deriv(x)
    local i = bisect(self._xs, x)
    local p0y = self._ey[i]
    local p1y = self._ey[i+1]
    local p2y = self._ey[i+2]
    local p3y = self._ey[i+3]
    local dx = self._xs[i+1] - self._xs[i]
    local t = (dx == 0) and 0 or (x - self._xs[i]) / dx
    local t2 = t * t
    -- d/dt of Catmull-Rom basis, then divide by dx for d/dx
    local dh00 =  6*t2 - 6*t
    local dh10 =  3*t2 - 4*t + 1
    local dh01 = -6*t2 + 6*t
    local dh11 =  3*t2 - 2*t
    local m1y = 0.5 * (p2y - p0y)
    local m2y = 0.5 * (p3y - p1y)
    local dval = dh00*p1y + dh10*m1y + dh01*p2y + dh11*m2y
    return (dx == 0) and 0 or dval / dx
  end

  return spline
end

-- ---------------------------------------------------------------------------
-- Monotone cubic spline (Fritsch-Carlson)
-- ---------------------------------------------------------------------------

--: (xs: { [integer]: number }, ys: { [integer]: number }) -> Spline
M.monotone_cubic = function(xs, ys)
  local n = #xs
  assert(n >= 2, "monotone_cubic: need at least 2 points")

  local h = {}
  local delta = {}
  for i = 1, n-1 do
    h[i] = xs[i+1] - xs[i]
    delta[i] = (ys[i+1] - ys[i]) / h[i]
  end

  -- Compute tangents m using Fritsch-Carlson method
  local m = {}
  if n == 2 then
    m[1] = delta[1]; m[2] = delta[1]
  else
    -- Endpoint tangents: one-sided
    m[1] = delta[1]
    m[n] = delta[n-1]
    -- Interior: average of adjacent slopes, but zero if signs differ
    for i = 2, n-1 do
      if delta[i-1] * delta[i] <= 0 then
        m[i] = 0
      else
        m[i] = (delta[i-1] + delta[i]) / 2
      end
    end
    -- Fritsch-Carlson monotonicity fix
    for i = 1, n-1 do
      if abs(delta[i]) < 1e-15 then
        m[i] = 0; m[i+1] = 0
      else
        local alpha = m[i] / delta[i]
        local beta  = m[i+1] / delta[i]
        local r = alpha^2 + beta^2
        if r > 9 then
          local s = 3 / sqrt(r)
          m[i]   = s * alpha * delta[i]
          m[i+1] = s * beta  * delta[i]
        end
      end
    end
  end

  local spline = { _xs = xs, _ys = ys, _h = h, _m = m, _n = n }

  function spline:eval(x)
    local i = bisect(self._xs, x)
    local hi = self._h[i]
    local t = (x - self._xs[i]) / hi
    local t2 = t * t; local t3 = t2 * t
    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 -   t2
    return h00*self._ys[i] + h10*hi*self._m[i]
         + h01*self._ys[i+1] + h11*hi*self._m[i+1]
  end

  function spline:eval_array(qxs)
    local out = {}
    for i = 1, #qxs do out[i] = self:eval(qxs[i]) end
    return out
  end

  function spline:deriv(x)
    local i = bisect(self._xs, x)
    local hi = self._h[i]
    local t = (x - self._xs[i]) / hi
    local t2 = t * t
    local dh00 =  6*t2 - 6*t
    local dh10 =  3*t2 - 4*t + 1
    local dh01 = -6*t2 + 6*t
    local dh11 =  3*t2 - 2*t
    return (dh00*self._ys[i] + dh10*hi*self._m[i]
          + dh01*self._ys[i+1] + dh11*hi*self._m[i+1]) / hi
  end

  return spline
end

-- ---------------------------------------------------------------------------
-- Lagrange interpolation
-- ---------------------------------------------------------------------------

--: (xs: { [integer]: number }, ys: { [integer]: number }, x: number) -> number
M.lagrange = function(xs, ys, x)
  local n = #xs
  --: number
  local result = 0.0
  for i = 1, n do
    --: number
    local basis = 1.0
    for j = 1, n do
      if j ~= i then
        basis = basis * (x - xs[j]) / (xs[i] - xs[j])
      end
    end
    result = result + ys[i] * basis
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Newton divided differences
-- ---------------------------------------------------------------------------

-- Returns divided-difference table (only the first row, i.e. coefficients).
--: (xs: { [integer]: number }, ys: { [integer]: number }) -> { [integer]: number }
M.newton_interp = function(xs, ys)
  local n = #xs
  local dd = {}
  for i = 1, n do dd[i] = ys[i] end
  -- In-place divided differences
  for j = 2, n do
    for i = n, j, -1 do
      dd[i] = (dd[i] - dd[i-1]) / (xs[i] - xs[i-j+1])
    end
  end
  return dd  -- dd[1]=f[x1], dd[2]=f[x1,x2], ... (Newton forward coefficients)
end

--: (coeffs: { [integer]: number }, xs: { [integer]: number }, x: number) -> number
M.newton_eval = function(coeffs, xs, x)
  local n = #coeffs
  local result = coeffs[n]
  for i = n-1, 1, -1 do
    result = result * (x - xs[i]) + coeffs[i]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Bezier (de Casteljau)
-- ---------------------------------------------------------------------------

--: (pts: { [integer]: { [integer]: number } }, t: number) -> (number, number)
M.bezier = function(pts, t)
  -- Work on a local copy (flat pairs)
  local n = #pts
  local wx = {}
  local wy = {}
  for i = 1, n do wx[i] = pts[i][1]; wy[i] = pts[i][2] end
  local u = 1 - t
  for r = 1, n-1 do
    for i = 1, n-r do
      wx[i] = wx[i] * u + wx[i+1] * t
      wy[i] = wy[i] * u + wy[i+1] * t
    end
  end
  return wx[1], wy[1]
end

-- ---------------------------------------------------------------------------
-- B-spline (Cox-de Boor)
-- ---------------------------------------------------------------------------

-- Evaluate B-spline basis function N_{i,p}(t) recursively.
local function bspline_basis(knots, i, p, t)
  if p == 0 then
    -- last interval: closed on right
    if knots[i] <= t and t < knots[i+1] then return 1 end
    return 0
  end
  local left, right = 0, 0
  local d1 = knots[i+p] - knots[i]
  local d2 = knots[i+p+1] - knots[i+1]
  if d1 ~= 0 then left  = (t - knots[i]) / d1 * bspline_basis(knots, i, p-1, t) end
  if d2 ~= 0 then right = (knots[i+p+1] - t) / d2 * bspline_basis(knots, i+1, p-1, t) end
  return left + right
end

--: (control_points: { [integer]: { [integer]: number } }, knots: { [integer]: number }, degree: number, t: number) -> (number, number)
M.bspline = function(control_points, knots, degree, t)
  local n = #control_points
  -- Clamp t to valid domain
  local t_lo = knots[degree+1]
  local t_hi = knots[n+1]  -- knots[n + degree + 1] if 1-indexed with m+1 knots
  -- Use last valid parameter if at upper boundary
  if t >= t_hi then t = t_hi - 1e-10 end
  if t < t_lo  then t = t_lo end

  --: number
  local rx = 0.0
  --: number
  local ry = 0.0
  for i = 1, n do
    local b = bspline_basis(knots, i, degree, t)
    local cp = control_points[i] --[[:! { [integer]: number }]]
    rx = rx + cp[1] * b
    ry = ry + cp[2] * b
  end
  return rx, ry
end

-- ---------------------------------------------------------------------------
-- Linear regression
-- ---------------------------------------------------------------------------

--: (xs: { [integer]: number }, ys: { [integer]: number }) -> (number, number, number)
M.linear_regression = function(xs, ys)
  local n = #xs
  --: number
  local sx = 0.0
  --: number
  local sy = 0.0
  --: number
  local sxx = 0.0
  --: number
  local sxy = 0.0
  for i = 1, n do
    sx  = sx  + xs[i]
    sy  = sy  + ys[i]
    sxx = sxx + xs[i] * xs[i]
    sxy = sxy + xs[i] * ys[i]
  end
  local denom = n * sxx - sx * sx
  --: number
  local a = 0.0
  --: number
  local b = 0.0
  if denom == 0 then
    a = 0.0; b = sy / n
  else
    a = (n * sxy - sx * sy) / denom
    b = (sy - a * sx) / n
  end
  -- R²
  local ymean = sy / n
  --: number
  local ss_tot = 0.0
  --: number
  local ss_res = 0.0
  for i = 1, n do
    ss_tot = ss_tot + (ys[i] - ymean)^2
    local yhat = a * xs[i] + b
    ss_res = ss_res + (ys[i] - yhat)^2
  end
  local r2 = (ss_tot == 0) and 1 or (1 - ss_res / ss_tot)
  return a, b, r2
end

-- ---------------------------------------------------------------------------
-- Polynomial evaluation
-- ---------------------------------------------------------------------------

--: (coeffs: { [integer]: number }, x: number) -> number
M.poly_eval = function(coeffs, x)
  -- Horner's method; coeffs[1]=c0, coeffs[d+1]=cd
  local n = #coeffs
  local result = coeffs[n]
  for i = n-1, 1, -1 do
    result = result * x + coeffs[i]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Polynomial least-squares regression (Vandermonde / normal equations)
-- ---------------------------------------------------------------------------

-- Solve lower-triangular system (actually we use a direct approach via
-- normal equations with Gaussian elimination).
--: (A: { [integer]: { [integer]: number } }, b: { [integer]: number }) -> { [integer]: number }
local function mat_solve(A, b)
  -- A is n×n (1-indexed rows and cols), b is n-vector
  -- Returns solution x via partial-pivot Gaussian elimination
  local n = #b
  -- Augmented matrix (any to allow 2D unknown indexing)
  local M2 = {} --[[: any]]
  for i = 1, n do
    M2[i] = {}
    for j = 1, n do M2[i][j] = A[i][j] end
    M2[i][n+1] = b[i]
  end
  for col = 1, n do
    -- Pivot
    local max_val, max_row = abs(M2[col][col] --[[: number]]), col
    for row = col+1, n do
      if abs(M2[row][col] --[[: number]]) > max_val then
        max_val = abs(M2[row][col] --[[: number]]); max_row = row
      end
    end
    M2[col], M2[max_row] = M2[max_row], M2[col]
    local pivot = M2[col][col] --[[: number]]
    if abs(pivot) < 1e-14 then
      -- Singular — return zeros
      local x = {} --[[: { [integer]: number }]]
      for i = 1, n do x[i] = 0.0 end
      return x
    end
    for row = 1, n do
      if row ~= col then
        local factor = M2[row][col] --[[: number]] / pivot
        for j = col, n+1 do
          M2[row][j] = M2[row][j] --[[: number]] - factor * (M2[col][j] --[[: number]])
        end
      end
    end
    -- Normalize pivot row
    for j = col, n+1 do M2[col][j] = M2[col][j] --[[: number]] / pivot end
  end
  local x = {}
  for i = 1, n do x[i] = M2[i][n+1] end
  return x
end

--: (xs: { [integer]: number }, ys: { [integer]: number }, degree: number) -> ({ [integer]: number }, number)
M.poly_regression = function(xs, ys, degree)
  local n = #xs
  local d = degree + 1  -- number of coefficients

  -- Build Vandermonde-based normal equations: (V^T V) c = V^T y
  -- ATA[i][j] = sum_k x_k^(i+j-2)
  local ATA = {} --: { [integer]: { [integer]: number } }
  local ATy = {} --: { [integer]: number }
  for i = 1, d do
    ATA[i] = {}
    ATy[i] = 0.0
    for j = 1, d do
      --: number
      local s = 0.0
      for k = 1, n do s = s + xs[k]^(i+j-2) end
      ATA[i][j] = s
    end
    for k = 1, n do ATy[i] = ATy[i] + xs[k]^(i-1) * ys[k] end
  end

  local coeffs = mat_solve(ATA, ATy)

  -- R²
  --: number
  local ymean = 0.0
  for i = 1, n do ymean = ymean + ys[i] end
  ymean = ymean / n
  --: number
  local ss_tot = 0.0
  --: number
  local ss_res = 0.0
  for i = 1, n do
    ss_tot = ss_tot + (ys[i] - ymean)^2
    local yhat = M.poly_eval(coeffs, xs[i])
    ss_res = ss_res + (ys[i] - yhat)^2
  end
  local r2 = (ss_tot == 0) and 1 or (1 - ss_res / ss_tot)
  return coeffs, r2
end

-- ---------------------------------------------------------------------------
-- Nearest neighbor
-- ---------------------------------------------------------------------------

--: (xs: { [integer]: number }, ys: { [integer]: number }, x: number) -> number
M.nearest = function(xs, ys, x)
  local n = #xs
  local best_i = 1
  local best_d = abs(x - xs[1])
  for i = 2, n do
    local d = abs(x - xs[i])
    if d < best_d then best_d = d; best_i = i end
  end
  return ys[best_i]
end

return M
