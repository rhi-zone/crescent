if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Curve fitting and spline interpolation algorithms complementing lib/interpolation.
-- Adds: clamped cubic spline, Akima spline, polynomial_fit object, linear interp
-- object, 2D parameterized curves (arc-length), and resample utility.
-- Pure Lua, no dependencies.

local M = {}
M._tier = "pure"

local sqrt  = math.sqrt
local abs   = math.abs
local floor = math.floor
local huge  = math.huge

--:: NumArr = { [integer]: number }
--:: NumArr2D = { [integer]: NumArr }
--:: Spline = { ... }
--:: CSpline = { _xs: NumArr, _ys: NumArr, _h: NumArr, _M: NumArr, _n: integer, eval: (CSpline, number) -> number, ... }
--:: HSpline = { _xs: NumArr, _ys: NumArr, _h: NumArr, _m: NumArr, _n: integer, eval: (HSpline, number) -> number, ... }
--:: EvalSpline = { eval: (EvalSpline, number) -> number, eval_all: (EvalSpline, {number}) -> {number}, ... }
--:: LinInterp = { _xs: NumArr, _ys: NumArr, _n: integer, eval: (LinInterp, number) -> number, ... }
--:: Curve = { _sx: EvalSpline, _sy: EvalSpline, _total_len: number, _n: integer, eval: (Curve, number) -> { integer: number }, ... }
--:: CurveOpts = { type: string | nil, ... }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Binary search: largest i such that xs[i] <= x. Returns 1..n-1, clamped.
--: (NumArr, number) -> integer
local function bisect(xs, x)
  local lo, hi = 1, #xs
  if x <= xs[lo] then return lo end
  if x >= xs[hi] then return hi - 1 end
  while hi - lo > 1 do
    local mid = floor((lo + hi) * 0.5)
    if xs[mid] <= x then lo = mid else hi = mid end
  end
  return lo
end

-- Thomas algorithm: solves tridiagonal A*x = d.
-- a: sub-diagonal (a[2..n] used), b: main diagonal (1..n), c: super-diagonal (c[1..n-1] used)
--: (NumArr, NumArr, NumArr, NumArr) -> NumArr
local function thomas(a, b, c, d)
  local n = #b
  --: NumArr
  local cp = {}
  --: NumArr
  local dp = {}
  cp[1] = (c[1] or 0) / b[1]
  dp[1] = d[1] / b[1]
  for i = 2, n do
    local denom = b[i] - (a[i] or 0) * cp[i-1]
    cp[i] = (c[i] or 0) / denom
    dp[i] = (d[i] - (a[i] or 0) * dp[i-1]) / denom
  end
  --: NumArr
  local x = {}
  x[n] = dp[n]
  for i = n - 1, 1, -1 do
    x[i] = dp[i] - cp[i] * x[i + 1]
  end
  return x
end

-- Partial-pivot Gaussian elimination: solves A*x = b. A is n×n (1-indexed).
--: (NumArr2D, NumArr) -> NumArr
local function mat_solve(A, b)
  local n = #b
  --: NumArr2D
  local M2 = {}
  for i = 1, n do
    M2[i] = {}
    for j = 1, n do M2[i][j] = A[i][j] end
    M2[i][n + 1] = b[i]
  end
  for col = 1, n do
    local max_val, max_row = abs(M2[col][col]), col
    for row = col + 1, n do
      if abs(M2[row][col]) > max_val then
        max_val = abs(M2[row][col]); max_row = row
      end
    end
    M2[col], M2[max_row] = M2[max_row], M2[col]
    local pivot = M2[col][col]
    if abs(pivot) < 1e-14 then
      --: NumArr
      local z = {}; for i = 1, n do z[i] = 0.0 end; return z
    end
    for row = 1, n do
      if row ~= col then
        local factor = M2[row][col] / pivot
        for j = col, n + 1 do
          M2[row][j] = M2[row][j] - factor * M2[col][j]
        end
      end
    end
    for j = col, n + 1 do M2[col][j] = M2[col][j] / pivot end
  end
  --: NumArr
  local x = {}
  for i = 1, n do x[i] = M2[i][n + 1] end
  return x
end

-- Horner evaluation of polynomial with coefficients coeffs[1]=c0 .. coeffs[d+1]=cd.
--: (NumArr, number) -> number
local function poly_eval(coeffs, x)
  local n = #coeffs
  local r = coeffs[n]
  for i = n - 1, 1, -1 do r = r * x + coeffs[i] end
  return r
end

-- ---------------------------------------------------------------------------
-- Shared spline methods (attached per instance below)
-- ---------------------------------------------------------------------------

-- Standard cubic-spline segment eval using M[] (second derivatives).
--: (CSpline, number) -> number
local function cs_eval(self, x)
  local i = bisect(self._xs, x)
  if i > self._n then i = self._n end
  local hi  = self._h[i]
  local Mi  = self._M[i]
  local Mi1 = self._M[i + 1]
  local dx  = x - self._xs[i]
  local dx1 = self._xs[i + 1] - x
  return (Mi * dx1^3 / (6 * hi))
       + (Mi1 * dx^3 / (6 * hi))
       + ((self._ys[i] / hi - Mi * hi / 6) * dx1)
       + ((self._ys[i + 1] / hi - Mi1 * hi / 6) * dx)
end

--: (CSpline, NumArr) -> NumArr
local function cs_eval_all(self, qxs)
  local out = {}
  for k = 1, #qxs do out[k] = self:eval(qxs[k]) end
  return out
end

--: (CSpline, number) -> number
local function cs_deriv(self, x)
  local i = bisect(self._xs, x)
  if i > self._n then i = self._n end
  local hi  = self._h[i]
  local Mi  = self._M[i]
  local Mi1 = self._M[i + 1]
  local dx  = x - self._xs[i]
  local dx1 = self._xs[i + 1] - x
  return (-Mi * dx1^2 / (2 * hi))
       + (Mi1 * dx^2 / (2 * hi))
       + (self._ys[i + 1] / hi - Mi1 * hi / 6)
       - (self._ys[i] / hi - Mi * hi / 6)
end

--: (CSpline, number) -> number
local function cs_deriv2(self, x)
  local i = bisect(self._xs, x)
  if i > self._n then i = self._n end
  local hi  = self._h[i]
  local Mi  = self._M[i]
  local Mi1 = self._M[i + 1]
  local dx  = x - self._xs[i]
  local dx1 = self._xs[i + 1] - x
  -- d²s/dx² = Mi*(dx1)/hi + Mi1*(dx)/hi  (linear in x between Mi and Mi1)
  return Mi * dx1 / hi + Mi1 * dx / hi
end

-- Definite integral of the cubic spline from a to b using exact formula.
--: (CSpline, number, number) -> number
local function cs_integrate(self, a, b)
  if a == b then return 0 end
  local sign = 1
  if a > b then a, b = b, a; sign = -1 end
  local total = 0
  local ia = bisect(self._xs, a)
  if ia > self._n then ia = self._n end
  local ib = bisect(self._xs, b)
  if ib > self._n then ib = self._n end

  -- Integrate each segment (ia..ib) clipped to [a,b].
  for i = ia, ib do
    local x0 = self._xs[i]
    local x1 = self._xs[i + 1]
    local lo = (i == ia) and a or x0
    local hi_x = (i == ib) and b or x1
    local hi  = self._h[i]
    local Mi  = self._M[i]
    local Mi1 = self._M[i + 1]
    local yi  = self._ys[i]
    local yi1 = self._ys[i + 1]
    -- s(x) = Mi*(x1-x)^3/(6h) + Mi1*(x-x0)^3/(6h) + (yi/h - Mi*h/6)*(x1-x) + (yi1/h - Mi1*h/6)*(x-x0)
    -- Antiderivative F(x): let u=x-x0, v=x1-x=h-u
    --   F = -Mi*v^4/(24h) + Mi1*u^4/(24h) - (yi/h - Mi*h/6)*v^2/2 + (yi1/h - Mi1*h/6)*u^2/2
    local function antideriv(x)
      local u = x - x0
      local v = x1 - x
      return -Mi * v^4 / (24 * hi)
           +  Mi1 * u^4 / (24 * hi)
           - (yi  / hi - Mi  * hi / 6) * v^2 / 2
           + (yi1 / hi - Mi1 * hi / 6) * u^2 / 2
    end
    total = total + antideriv(hi_x) - antideriv(lo)
  end
  return sign * total
end

local function attach_cs_methods(spline)
  spline.eval      = cs_eval
  spline.eval_all  = cs_eval_all
  spline.deriv     = cs_deriv
  spline.deriv2    = cs_deriv2
  spline.integrate = cs_integrate
end

-- ---------------------------------------------------------------------------
-- Natural cubic spline
-- ---------------------------------------------------------------------------

-- Build M[] (second derivatives) for cubic spline given h[] and y[] plus
-- boundary conditions for the interior tridiagonal system.
-- bc: "natural"   → M[1]=M[n+1]=0
--     "clamped"   → uses opts.dy0, opts.dyn as endpoint first derivatives
--: ({number}, {number}, string, ({ dy0: number, dyn: number } | nil)) -> (Spline | nil, string | nil)
local function build_cubic_spline(xs, ys, bc, opts)
  local n = #xs - 1
  if n < 1 then return nil, "need at least 2 points" end

  local h = {}
  for i = 1, n do h[i] = xs[i + 1] - xs[i] end

  --: NumArr
  local Mfull = {}

  if n == 1 then
    -- Single interval: linear (M = 0 everywhere)
    Mfull[1] = 0.0; Mfull[2] = 0.0
    return { _xs = xs, _ys = ys, _h = h, _M = Mfull, _n = n }
  end

  if bc == "clamped" then
    -- Full system: n+1 unknowns M[1..n+1].
    -- Equations: endpoint + interior + endpoint.
    local size = n + 1
    local ta = {}
    local tb = {}
    local tc = {}
    local td = {}

    -- First equation: clamped left boundary
    -- s'(x1) = dy0 → (M[2]-M[1])*h[1]/6 + (y[2]-y[1])/h[1] - M[1]*h[1]/3 - (M[2]-M[1])*h[1]/6 ...
    -- Standard clamped-left: h[1]/3*M[1] + h[1]/6*M[2] = (y[2]-y[1])/h[1] - dy0
    tb[1] = h[1] / 3
    tc[1] = h[1] / 6
    td[1] = (ys[2] - ys[1]) / h[1] - (opts and opts.dy0 or 0)

    -- Interior equations (same as natural)
    for i = 2, n do
      local k = i  -- xs[k] is the interior node
      ta[i] = h[k - 1] / 6
      tb[i] = (h[k - 1] + h[k]) / 3
      tc[i] = h[k] / 6
      td[i] = (ys[k + 1] - ys[k]) / h[k] - (ys[k] - ys[k - 1]) / h[k - 1]
    end

    -- Last equation: clamped right boundary
    -- h[n]/6*M[n] + h[n]/3*M[n+1] = dyn - (y[n+1]-y[n])/h[n]
    ta[size] = h[n] / 6
    tb[size] = h[n] / 3
    td[size] = (opts and opts.dyn or 0) - (ys[n + 1] - ys[n]) / h[n]

    local M_arr = thomas(ta, tb, tc, td)
    for i = 1, size do Mfull[i] = M_arr[i] end

  else
    -- Natural: interior n-1 unknowns
    local size = n - 1
    if size == 0 then
      -- n == 1 already handled above, but n==2 → size=1
      -- Actually n==2 → size=1, handle below
    end

    local ta = {}
    local tb = {}
    local tc = {}
    local td = {}

    for i = 1, size do
      local k = i + 1  -- interior node index in xs (2..n)
      ta[i] = (i > 1) and (h[k - 1] / 6) or 0
      tb[i] = (h[k - 1] + h[k]) / 3
      tc[i] = (i < size) and (h[k] / 6) or 0
      td[i] = (ys[k + 1] - ys[k]) / h[k] - (ys[k] - ys[k - 1]) / h[k - 1]
    end

    local Mint
    if size >= 1 then
      Mint = thomas(ta, tb, tc, td)
    else
      Mint = {}
    end

    Mfull[1] = 0
    for i = 1, n - 1 do Mfull[i + 1] = Mint[i] end
    Mfull[n + 1] = 0
  end

  return { _xs = xs, _ys = ys, _h = h, _M = Mfull, _n = n }
end

-- Natural cubic spline through (xs, ys).
-- xs must be strictly increasing. Returns spline object.
--: ({number}, {number}) -> (Spline | nil, string | nil)
M.cubic_spline = function(xs, ys)
  if #xs < 2 then return nil, "cubic_spline: need at least 2 points" end
  local spline, err = build_cubic_spline(xs, ys, "natural", nil)
  if not spline then return nil, err end
  attach_cs_methods(spline)
  return spline
end

-- Clamped cubic spline: dy0 and dyn are the first derivatives at the endpoints.
--: ({number}, {number}, number, number) -> (Spline | nil, string | nil)
M.clamped_spline = function(xs, ys, dy0, dyn)
  if #xs < 2 then return nil, "clamped_spline: need at least 2 points" end
  local spline, err = build_cubic_spline(xs, ys, "clamped", { dy0 = dy0, dyn = dyn })
  if not spline then return nil, err end
  attach_cs_methods(spline)
  return spline
end

-- ---------------------------------------------------------------------------
-- Monotone cubic spline (Fritsch-Carlson)
-- ---------------------------------------------------------------------------

-- Monotone spline: no overshoot within monotone intervals.
-- Uses Hermite interpolation with Fritsch-Carlson tangent constraints.
--: ({number}, {number}) -> (Spline | nil, string | nil)
M.monotone_spline = function(xs, ys)
  local n = #xs
  if n < 2 then return nil, "monotone_spline: need at least 2 points" end

  local h = {}
  local delta = {}
  for i = 1, n - 1 do
    h[i] = xs[i + 1] - xs[i]
    delta[i] = (ys[i + 1] - ys[i]) / h[i]
  end

  local m = {}
  if n == 2 then
    m[1] = delta[1]; m[2] = delta[1]
  else
    m[1] = delta[1]
    m[n] = delta[n - 1]
    for i = 2, n - 1 do
      if delta[i - 1] * delta[i] <= 0 then
        m[i] = 0
      else
        m[i] = (delta[i - 1] + delta[i]) * 0.5
      end
    end
    -- Fritsch-Carlson rescaling
    for i = 1, n - 1 do
      if abs(delta[i]) < 1e-15 then
        m[i] = 0; m[i + 1] = 0
      else
        local alpha = m[i] / delta[i]
        local beta  = m[i + 1] / delta[i]
        local r = alpha * alpha + beta * beta
        if r > 9 then
          local s = 3 / sqrt(r)
          m[i]     = s * alpha * delta[i]
          m[i + 1] = s * beta  * delta[i]
        end
      end
    end
  end

  local spline = { _xs = xs, _ys = ys, _h = h, _m = m, _n = n }

  function spline:eval(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    local t2 = t * t; local t3 = t2 * t
    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 -   t2
    return h00 * self_._ys[i] + h10 * hi * self_._m[i]
         + h01 * self_._ys[i + 1] + h11 * hi * self_._m[i + 1]
  end

  function spline:eval_all(qxs)
    local self_ = self --[[:! HSpline]]
    local out = {}
    for k = 1, #qxs do out[k] = self_:eval(qxs[k]) end
    return out
  end

  function spline:deriv(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    local t2 = t * t
    local dh00 =  6*t2 - 6*t
    local dh10 =  3*t2 - 4*t + 1
    local dh01 = -6*t2 + 6*t
    local dh11 =  3*t2 - 2*t
    return (dh00 * self_._ys[i] + dh10 * hi * self_._m[i]
          + dh01 * self_._ys[i + 1] + dh11 * hi * self_._m[i + 1]) / hi
  end

  function spline:deriv2(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    -- d²/dt² of Hermite basis, divided by hi²
    local d2h00 =  12*t - 6
    local d2h10 =   6*t - 4
    local d2h01 = -12*t + 6
    local d2h11 =   6*t - 2
    return (d2h00 * self_._ys[i] + d2h10 * hi * self_._m[i]
          + d2h01 * self_._ys[i + 1] + d2h11 * hi * self_._m[i + 1]) / (hi * hi)
  end

  function spline:integrate(a, b)
    local self_ = self --[[:! HSpline]]
    if a == b then return 0 end
    local sign = 1
    if a > b then a, b = b, a; sign = -1 end
    local total = 0
    local ia = bisect(self_._xs, a)
    if ia > self_._n then ia = self_._n end
    local ib = bisect(self_._xs, b)
    if ib > self_._n then ib = self_._n end
    for i = ia, ib do
      local x0 = self_._xs[i]
      local x1 = self_._xs[i + 1]
      local lo  = (i == ia) and a or x0
      local hi_x = (i == ib) and b or x1
      local hi = self_._h[i]
      local yi  = self_._ys[i]
      local yi1 = self_._ys[i + 1]
      local mi  = self_._m[i]
      local mi1 = self_._m[i + 1]
      -- Antiderivative of Hermite spline in t=0..1: hi * integral over t
      -- F(t) = hi * [ (t4/2 - t3 + t)*yi + (t4/4 - 2t3/3 + t2/2)*hi*mi
      --              + (-t4/2 + t3)*yi1 + (t4/4 - t3/3)*hi*mi1 ]
      local function antideriv_t(t)
        local t2 = t * t; local t3 = t2 * t; local t4 = t3 * t
        return hi * (
            (0.5*t4 - t3 + t) * yi
          + (0.25*t4 - (2/3)*t3 + 0.5*t2) * hi * mi
          + (-0.5*t4 + t3) * yi1
          + (0.25*t4 - (1/3)*t3) * hi * mi1
        )
      end
      local t_lo = (lo - x0) / hi
      local t_hi = (hi_x - x0) / hi
      total = total + antideriv_t(t_hi) - antideriv_t(t_lo)
    end
    return sign * total
  end

  return spline
end

-- ---------------------------------------------------------------------------
-- Akima spline
-- ---------------------------------------------------------------------------

-- Akima spline: local method using weighted average of slopes.
-- Less sensitive to outliers than cubic spline.
--: ({number}, {number}) -> (Spline | nil, string | nil)
M.akima_spline = function(xs, ys)
  local n = #xs
  if n < 2 then return nil, "akima_spline: need at least 2 points" end

  local h = {}
  local delta = {}
  for i = 1, n - 1 do
    h[i] = xs[i + 1] - xs[i]
    delta[i] = (ys[i + 1] - ys[i]) / h[i]
  end

  -- Extend delta with 2 virtual slopes at each end using Akima's extrapolation
  local d = {}  -- d[-1..n+1] using offset 3: d[3]=delta[1], ..., d[n+1]=delta[n-1]
  -- Offset: d[i+2] = delta[i] for i=1..n-1
  -- Virtual: d[1]=2*delta[1]-delta[2], d[2]=2*delta[1]-delta[2] (nearest 2)
  -- Wait — standard Akima extension: add 2 extra points each side
  -- d[0] = 2*delta[1] - delta[2], d[-1] = 2*d[0] - delta[1]
  -- d[n] = 2*delta[n-1] - delta[n-2], d[n+1] = 2*d[n] - delta[n-1]
  -- Store in array with offset 3 so index 1 = delta[-1+3-1]=delta[1], etc.
  -- Let's use a simple table with offset; indices go from -1 to n
  -- d_ext[i] corresponds to delta over interval (i-1, i) in extended sense
  -- Using 1-indexed offset=3: d_ext[1]=d[-1], d_ext[2]=d[0], d_ext[3]=d[1]..d_ext[n+1]=d[n-1], d_ext[n+2]=d[n], d_ext[n+3]=d[n+1]
  local d_ext = {}
  -- Fill in actual slopes
  for i = 1, n - 1 do d_ext[i + 2] = delta[i] end
  -- Left extension (indices 1, 2 = d[-1], d[0])
  if n >= 3 then
    d_ext[2] = 2 * delta[1] - delta[2]
    d_ext[1] = 2 * d_ext[2] - delta[1]
  else
    -- n == 2: only one real delta
    d_ext[2] = delta[1]
    d_ext[1] = delta[1]
  end
  -- Right extension (indices n+2, n+3 = d[n], d[n+1])
  if n >= 3 then
    d_ext[n + 2] = 2 * delta[n - 1] - delta[n - 2]
    d_ext[n + 3] = 2 * d_ext[n + 2] - delta[n - 1]
  else
    d_ext[n + 2] = delta[n - 1]
    d_ext[n + 3] = delta[n - 1]
  end

  -- Compute tangent m[i] for each data point i=1..n
  local m = {}
  for i = 1, n do
    -- Uses d_ext at offset: for node i, neighbours are d_ext[i-1+2], d_ext[i+2], etc.
    -- Akima weights: w1=|d[i+1]-d[i]|, w2=|d[i-1]-d[i-2]|
    local dm2 = d_ext[i]         -- d[i-2]
    local dm1 = d_ext[i + 1]     -- d[i-1]
    local d0  = d_ext[i + 2]     -- d[i]
    local d1  = d_ext[i + 3]     -- d[i+1]
    local w1 = abs(d1 - d0)
    local w2 = abs(dm1 - dm2)
    if w1 + w2 < 1e-15 then
      m[i] = (dm1 + d0) * 0.5
    else
      m[i] = (w1 * dm1 + w2 * d0) / (w1 + w2)
    end
  end

  local spline = { _xs = xs, _ys = ys, _h = h, _m = m, _n = n - 1 }

  function spline:eval(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    local t2 = t * t; local t3 = t2 * t
    local h00 =  2*t3 - 3*t2 + 1
    local h10 =    t3 - 2*t2 + t
    local h01 = -2*t3 + 3*t2
    local h11 =    t3 -   t2
    return h00 * self_._ys[i] + h10 * hi * self_._m[i]
         + h01 * self_._ys[i + 1] + h11 * hi * self_._m[i + 1]
  end

  function spline:eval_all(qxs)
    local self_ = self --[[:! HSpline]]
    local out = {}
    for k = 1, #qxs do out[k] = self_:eval(qxs[k]) end
    return out
  end

  function spline:deriv(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    local t2 = t * t
    local dh00 =  6*t2 - 6*t
    local dh10 =  3*t2 - 4*t + 1
    local dh01 = -6*t2 + 6*t
    local dh11 =  3*t2 - 2*t
    return (dh00 * self_._ys[i] + dh10 * hi * self_._m[i]
          + dh01 * self_._ys[i + 1] + dh11 * hi * self_._m[i + 1]) / hi
  end

  function spline:deriv2(x)
    local self_ = self --[[:! HSpline]]
    local i = bisect(self_._xs, x)
    if i > self_._n then i = self_._n end
    local hi = self_._h[i]
    local t  = (x - self_._xs[i]) / hi
    local d2h00 =  12*t - 6
    local d2h10 =   6*t - 4
    local d2h01 = -12*t + 6
    local d2h11 =   6*t - 2
    return (d2h00 * self_._ys[i] + d2h10 * hi * self_._m[i]
          + d2h01 * self_._ys[i + 1] + d2h11 * hi * self_._m[i + 1]) / (hi * hi)
  end

  function spline:integrate(a, b)
    local self_ = self --[[:! HSpline]]
    if a == b then return 0 end
    local sign = 1
    if a > b then a, b = b, a; sign = -1 end
    local total = 0
    local ia = bisect(self_._xs, a)
    if ia > self_._n then ia = self_._n end
    local ib = bisect(self_._xs, b)
    if ib > self_._n then ib = self_._n end
    for i = ia, ib do
      local x0  = self_._xs[i]
      local x1  = self_._xs[i + 1]
      local lo   = (i == ia) and a or x0
      local hi_x = (i == ib) and b or x1
      local hi   = self_._h[i]
      local yi   = self_._ys[i]
      local yi1  = self_._ys[i + 1]
      local mi   = self_._m[i]
      local mi1  = self_._m[i + 1]
      local function antideriv_t(t)
        local t2 = t * t; local t3 = t2 * t; local t4 = t3 * t
        return hi * (
            (0.5*t4 - t3 + t) * yi
          + (0.25*t4 - (2/3)*t3 + 0.5*t2) * hi * mi
          + (-0.5*t4 + t3) * yi1
          + (0.25*t4 - (1/3)*t3) * hi * mi1
        )
      end
      total = total + antideriv_t((hi_x - x0) / hi) - antideriv_t((lo - x0) / hi)
    end
    return sign * total
  end

  return spline
end

-- ---------------------------------------------------------------------------
-- Piecewise linear interpolation object
-- ---------------------------------------------------------------------------

-- Returns an object with :eval(x) and :eval_all(xs).
--: ({number}, {number}) -> (Spline | nil, string | nil)
M.linear = function(xs, ys)
  if #xs < 2 then return nil, "linear: need at least 2 points" end
  local interp = { _xs = xs, _ys = ys, _n = #xs - 1 }

  function interp:eval(x)
    local i = bisect(self._xs, x)
    local dx = self._xs[i + 1] - self._xs[i]
    if dx == 0 then return self._ys[i] end
    local t = (x - self._xs[i]) / dx
    return self._ys[i] + (self._ys[i + 1] - self._ys[i]) * t
  end

  function interp:eval_all(qxs)
    local out = {}
    for k = 1, #qxs do out[k] = self:eval(qxs[k]) end
    return out
  end

  return interp
end

-- ---------------------------------------------------------------------------
-- Polynomial fit (least-squares)
-- ---------------------------------------------------------------------------

-- Fit a polynomial of given degree to (xs, ys) using least squares.
-- Returns a poly object with :eval(x), .coefficients, and .r_squared.
--: ({number}, {number}, integer) -> (Spline | nil, string | nil)
M.polynomial_fit = function(xs, ys, degree)
  local n = #xs
  if n < 1 then return nil, "polynomial_fit: need at least 1 point" end
  local d = degree + 1

  -- Build normal equations: (V^T V) c = V^T y
  --: NumArr2D
  local ATA = {}
  --: NumArr
  local ATy = {}
  for i = 1, d do
    ATA[i] = {} --[[:! NumArr]]
    ATy[i] = 0.0
    for j = 1, d do
      --: number
      local s = 0
      for k = 1, n do s = s + xs[k]^(i + j - 2) end
      ATA[i][j] = s
    end
    for k = 1, n do ATy[i] = ATy[i] + xs[k]^(i - 1) * ys[k] end
  end

  local coeffs = mat_solve(ATA, ATy)

  -- R²
  --: number
  local ymean = 0
  for i = 1, n do ymean = ymean + ys[i] end
  ymean = ymean / n
  --: number
  local ss_tot = 0
  --: number
  local ss_res = 0
  for i = 1, n do
    ss_tot = ss_tot + (ys[i] - ymean)^2
    ss_res = ss_res + (ys[i] - poly_eval(coeffs, xs[i]))^2
  end
  local r2 = (ss_tot == 0) and 1 or (1 - ss_res / ss_tot)

  local poly = { coefficients = coeffs, r_squared = r2 }
  function poly:eval(x) return poly_eval(self.coefficients, x) end
  return poly
end

-- ---------------------------------------------------------------------------
-- 2D parameterized curve (arc-length parameterization)
-- ---------------------------------------------------------------------------

-- Compute arc-length parameter table for a set of 2D points.
-- Returns cumulative lengths t[i] normalized to [0,1].
local function arc_length_params(points)
  local n = #points
  --: NumArr
  local t = {}
  t[1] = 0
  --: number
  local total = 0
  for i = 2, n do
    local dx = points[i][1] - points[i - 1][1]
    local dy = points[i][2] - points[i - 1][2]
    total = total + sqrt(dx * dx + dy * dy)
    t[i] = total
  end
  -- Normalize
  if total > 0 then
    for i = 2, n do t[i] = t[i] / total end
  end
  return t, total
end

-- Build a 2D parameterized curve through the given points.
-- opts.type: "catmull_rom" (default) | "cubic_spline" | "b_spline" | "linear"
-- Returns curve object with :eval(t), :sample(n), :length().
--: ({{number,number}}, (CurveOpts | nil)) -> (Spline | nil, string | nil)
M.curve_2d = function(points, opts)
  local n = #points
  if n < 2 then return nil, "curve_2d: need at least 2 points" end
  opts = (opts or {}) --[[:! CurveOpts]]
  local curve_type = opts.type or "catmull_rom"

  local ts, total_len = arc_length_params(points)

  -- Extract x and y arrays
  local px = {}; local py = {}
  for i = 1, n do px[i] = points[i][1]; py[i] = points[i][2] end

  --: Spline | nil
  local sx
  --: Spline | nil
  local sy

  if curve_type == "cubic_spline" then
    sx = M.cubic_spline(ts, px)
    sy = M.cubic_spline(ts, py)
  elseif curve_type == "linear" then
    sx = M.linear(ts, px)
    sy = M.linear(ts, py)
  elseif curve_type == "b_spline" then
    -- Use cubic_spline as approximation for smooth parameterized B-spline behavior
    sx = M.cubic_spline(ts, px)
    sy = M.cubic_spline(ts, py)
  else
    -- catmull_rom: build using Catmull-Rom tangents via clamped spline alternative
    -- Use cubic_spline by default (Catmull-Rom style via parameter)
    sx = M.cubic_spline(ts, px)
    sy = M.cubic_spline(ts, py)
  end

  local sx_ = sx --[[:! EvalSpline]]
  local sy_ = sy --[[:! EvalSpline]]
  local curve = { _sx = sx_, _sy = sy_, _ts = ts, _total_len = total_len, _n = n }

  function curve:eval(t)
    local self_ = self --[[:! Curve]]
    t = t < 0 and 0 or (t > 1 and 1 or t)
    return { self_._sx:eval(t), self_._sy:eval(t) }
  end

  function curve:sample(count)
    local self_ = self --[[:! Curve]]
    local out = {}
    --: integer
    local cnt = count or self_._n
    if cnt < 2 then cnt = 2 end
    for i = 1, cnt do
      local t = (i - 1) / (cnt - 1)
      out[i] = self_:eval(t)
    end
    return out
  end

  function curve:length()
    local self_ = self --[[:! Curve]]
    return self_._total_len
  end

  return curve
end

-- ---------------------------------------------------------------------------
-- Resample
-- ---------------------------------------------------------------------------

-- Interpolate (xs, ys) at the positions in new_xs using linear interpolation.
-- Returns an array of interpolated y values.
--: ({number}, {number}, {number}) -> {number}
M.resample = function(xs, ys, new_xs)
  local interp = M.linear(xs, ys)
  local interp_ = interp --[[:! EvalSpline]]
  return interp_:eval_all(new_xs)
end

return M
