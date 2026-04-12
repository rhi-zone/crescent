if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Bézier curves and splines for 2D/3D graphics and animation.
-- Quadratic, cubic, general degree (de Casteljau), Catmull-Rom splines,
-- and Hermite curves. Pure Lua, no dependencies.

local M = {}

M._tier = "pure"

local sqrt = math.sqrt
local abs  = math.abs
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Point helpers (2D and 3D, {x, y} or {x, y, z})
-- ---------------------------------------------------------------------------

local function pt_lerp(a, b, t)
  local p = { x = a.x + t * (b.x - a.x), y = a.y + t * (b.y - a.y) }
  if a.z ~= nil or b.z ~= nil then
    p.z = (a.z or 0) + t * ((b.z or 0) - (a.z or 0))
  end
  return p
end

local function pt_len(v)
  local z = v.z or 0
  return sqrt(v.x * v.x + v.y * v.y + z * z)
end

local function pt_scale(v, s)
  local p = { x = v.x * s, y = v.y * s }
  if v.z ~= nil then p.z = v.z * s end
  return p
end

local function pt_add(a, b)
  local p = { x = a.x + b.x, y = a.y + b.y }
  if a.z ~= nil or b.z ~= nil then
    p.z = (a.z or 0) + (b.z or 0)
  end
  return p
end

local function pt_sub(a, b)
  local p = { x = a.x - b.x, y = a.y - b.y }
  if a.z ~= nil or b.z ~= nil then
    p.z = (a.z or 0) - (b.z or 0)
  end
  return p
end

local function pt_copy(p)
  return { x = p.x, y = p.y, z = p.z }
end

local function copy_points(pts)
  local out = {}
  for i = 1, #pts do out[i] = pt_copy(pts[i]) end
  return out
end

-- ---------------------------------------------------------------------------
-- De Casteljau general algorithm
-- ---------------------------------------------------------------------------

local function de_casteljau(points, t)
  local pts = copy_points(points)
  local n = #pts
  for r = 1, n - 1 do
    for i = 1, n - r do
      pts[i] = pt_lerp(pts[i], pts[i + 1], t)
    end
  end
  return pts[1]
end

-- De Casteljau split: returns left and right control point arrays
local function de_casteljau_split(points, t)
  local n = #points
  local pyramid = {}
  pyramid[1] = copy_points(points)
  for r = 2, n do
    pyramid[r] = {}
    for i = 1, n - r + 1 do
      pyramid[r][i] = pt_lerp(pyramid[r-1][i], pyramid[r-1][i+1], t)
    end
  end
  local left = {}
  local right = {}
  for r = 1, n do
    left[r]  = pyramid[r][1]
    right[r] = pyramid[n - r + 1][r]
  end
  return left, right
end

-- ---------------------------------------------------------------------------
-- Bounding box helper (2D only)
-- ---------------------------------------------------------------------------

-- Find extrema of cubic polynomial: derivative roots in (0,1)
local function quad_roots(a, b, c)
  -- solves a*t^2 + b*t + c = 0, returns roots in (0,1)
  local roots = {}
  if abs(a) < 1e-12 then
    if abs(b) > 1e-12 then
      local t = -c / b
      if t > 0 and t < 1 then roots[#roots+1] = t end
    end
    return roots
  end
  local disc = b * b - 4 * a * c
  if disc < 0 then return roots end
  local sq = sqrt(disc)
  local t1 = (-b - sq) / (2 * a)
  local t2 = (-b + sq) / (2 * a)
  if t1 > 0 and t1 < 1 then roots[#roots+1] = t1 end
  if t2 > 0 and t2 < 1 then roots[#roots+1] = t2 end
  return roots
end

-- ---------------------------------------------------------------------------
-- Quadratic Bézier
-- ---------------------------------------------------------------------------

local Quadratic = {}
Quadratic.__index = Quadratic

--: ({x:number,y:number}, {x:number,y:number}, {x:number,y:number}) -> table
M.quadratic = function(p0, p1, p2)
  return setmetatable({ p0 = p0, p1 = p1, p2 = p2 }, Quadratic)
end

--: (number) -> {x:number,y:number}
Quadratic.point = function(self, t)
  local u = 1 - t
  local b0 = u * u
  local b1 = 2 * u * t
  local b2 = t * t
  local p = { x = b0*self.p0.x + b1*self.p1.x + b2*self.p2.x,
              y = b0*self.p0.y + b1*self.p1.y + b2*self.p2.y }
  if self.p0.z ~= nil then
    p.z = b0*(self.p0.z or 0) + b1*(self.p1.z or 0) + b2*(self.p2.z or 0)
  end
  return p
end

--: (number) -> {x:number,y:number}
Quadratic.tangent = function(self, t)
  -- derivative: 2*((1-t)*(p1-p0) + t*(p2-p1))
  local u = 1 - t
  local d0 = pt_sub(self.p1, self.p0)
  local d1 = pt_sub(self.p2, self.p1)
  local v = pt_add(pt_scale(d0, 2*u), pt_scale(d1, 2*t))
  return v
end

--: (number) -> {x:number,y:number}
Quadratic.normal = function(self, t)
  local tg = self:tangent(t)
  return { x = -tg.y, y = tg.x }
end

--: (number?) -> number
Quadratic.length = function(self, n)
  n = n or 100
  local total = 0
  local prev = self:point(0)
  for i = 1, n do
    local cur = self:point(i / n)
    total = total + pt_len(pt_sub(cur, prev))
    prev = cur
  end
  return total
end

--: (number) -> table, table
Quadratic.split = function(self, t)
  local left, right = de_casteljau_split({ self.p0, self.p1, self.p2 }, t)
  return M.quadratic(left[1], left[2], left[3]),
         M.quadratic(right[1], right[2], right[3])
end

--: (number?) -> {table}
Quadratic.to_points = function(self, n)
  n = n or 10
  local pts = {}
  for i = 0, n do
    pts[i+1] = self:point(i / n)
  end
  return pts
end

--: () -> {number}
Quadratic.bounding_box = function(self)
  local p0, p1, p2 = self.p0, self.p1, self.p2
  -- derivative coefficients per axis: 2*(p1-p0)*(1-t) + 2*(p2-p1)*t = 0
  -- => t = (p0-p1) / (p0 - 2p1 + p2)
  local function axis_extrema(a0, a1, a2)
    local denom = a0 - 2*a1 + a2
    local ts = {}
    if abs(denom) > 1e-12 then
      local t = (a0 - a1) / denom
      if t > 0 and t < 1 then ts[#ts+1] = t end
    end
    return ts
  end
  local txs = axis_extrema(p0.x, p1.x, p2.x)
  local tys = axis_extrema(p0.y, p1.y, p2.y)
  local min_x, max_x = math.min(p0.x, p2.x), math.max(p0.x, p2.x)
  local min_y, max_y = math.min(p0.y, p2.y), math.max(p0.y, p2.y)
  for _, t in ipairs(txs) do
    local v = self:point(t).x
    if v < min_x then min_x = v end
    if v > max_x then max_x = v end
  end
  for _, t in ipairs(tys) do
    local v = self:point(t).y
    if v < min_y then min_y = v end
    if v > max_y then max_y = v end
  end
  return { min_x, min_y, max_x, max_y }
end

-- ---------------------------------------------------------------------------
-- Cubic Bézier
-- ---------------------------------------------------------------------------

local Cubic = {}
Cubic.__index = Cubic

--: (table, table, table, table) -> table
M.cubic = function(p0, p1, p2, p3)
  return setmetatable({ p0 = p0, p1 = p1, p2 = p2, p3 = p3 }, Cubic)
end

--: (number) -> {x:number,y:number}
Cubic.point = function(self, t)
  local u = 1 - t
  local b0 = u * u * u
  local b1 = 3 * u * u * t
  local b2 = 3 * u * t * t
  local b3 = t * t * t
  local p = { x = b0*self.p0.x + b1*self.p1.x + b2*self.p2.x + b3*self.p3.x,
              y = b0*self.p0.y + b1*self.p1.y + b2*self.p2.y + b3*self.p3.y }
  if self.p0.z ~= nil then
    p.z = b0*(self.p0.z or 0) + b1*(self.p1.z or 0)
        + b2*(self.p2.z or 0) + b3*(self.p3.z or 0)
  end
  return p
end

--: (number) -> {x:number,y:number}
Cubic.tangent = function(self, t)
  -- derivative: 3*((1-t)^2*(p1-p0) + 2(1-t)t*(p2-p1) + t^2*(p3-p2))
  local u = 1 - t
  local d0 = pt_sub(self.p1, self.p0)
  local d1 = pt_sub(self.p2, self.p1)
  local d2 = pt_sub(self.p3, self.p2)
  local v = pt_add(
    pt_add(pt_scale(d0, 3*u*u), pt_scale(d1, 6*u*t)),
    pt_scale(d2, 3*t*t)
  )
  return v
end

--: (number) -> {x:number,y:number}
Cubic.normal = function(self, t)
  local tg = self:tangent(t)
  return { x = -tg.y, y = tg.x }
end

--: (number?) -> number
Cubic.length = function(self, n)
  n = n or 100
  local total = 0
  local prev = self:point(0)
  for i = 1, n do
    local cur = self:point(i / n)
    total = total + pt_len(pt_sub(cur, prev))
    prev = cur
  end
  return total
end

--: (number) -> table, table
Cubic.split = function(self, t)
  local left, right = de_casteljau_split(
    { self.p0, self.p1, self.p2, self.p3 }, t)
  return M.cubic(left[1], left[2], left[3], left[4]),
         M.cubic(right[1], right[2], right[3], right[4])
end

--: (number?) -> {table}
Cubic.to_points = function(self, n)
  n = n or 10
  local pts = {}
  for i = 0, n do
    pts[i+1] = self:point(i / n)
  end
  return pts
end

--: () -> string
Cubic.to_svg_path = function(self)
  local p0, p1, p2, p3 = self.p0, self.p1, self.p2, self.p3
  return string.format("M %g,%g C %g,%g %g,%g %g,%g",
    p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
end

--: () -> {number}
Cubic.bounding_box = function(self)
  local p0, p1, p2, p3 = self.p0, self.p1, self.p2, self.p3
  -- derivative is quadratic: coefficients per axis
  -- d/dt B(t) = 3*(-p0+3p1-3p2+p3)*t^2 + 6*(p0-2p1+p2)*t + 3*(-p0+p1)
  local function axis_extrema(a0, a1, a2, a3)
    local A = 3 * (-a0 + 3*a1 - 3*a2 + a3)
    local B = 6 * (a0 - 2*a1 + a2)
    local C = 3 * (-a0 + a1)
    return quad_roots(A, B, C)
  end
  local txs = axis_extrema(p0.x, p1.x, p2.x, p3.x)
  local tys = axis_extrema(p0.y, p1.y, p2.y, p3.y)
  local min_x = math.min(p0.x, p3.x)
  local max_x = math.max(p0.x, p3.x)
  local min_y = math.min(p0.y, p3.y)
  local max_y = math.max(p0.y, p3.y)
  for _, t in ipairs(txs) do
    local v = self:point(t).x
    if v < min_x then min_x = v end
    if v > max_x then max_x = v end
  end
  for _, t in ipairs(tys) do
    local v = self:point(t).y
    if v < min_y then min_y = v end
    if v > max_y then max_y = v end
  end
  return { min_x, min_y, max_x, max_y }
end

--: () -> {number}
Cubic.inflections = function(self)
  -- Curvature sign change: solve x'(t)*y''(t) - y'(t)*x''(t) = 0
  -- first derivative coefficients (quadratic):
  --   x'(t) = ax*t^2 + bx*t + cx   (similar for y')
  -- second derivative (linear):
  --   x''(t) = 2*ax*t + bx_lin
  local p0, p1, p2, p3 = self.p0, self.p1, self.p2, self.p3
  -- x'(t): cubic derivative = 3[(-p0+3p1-3p2+p3)t^2 + 2(p0-2p1+p2)t + (-p0+p1)]
  local ax = -p0.x + 3*p1.x - 3*p2.x + p3.x
  local bx = 2*(p0.x - 2*p1.x + p2.x)
  local cx = -p0.x + p1.x
  local ay = -p0.y + 3*p1.y - 3*p2.y + p3.y
  local by = 2*(p0.y - 2*p1.y + p2.y)
  local cy = -p0.y + p1.y
  -- x''(t) = 2*ax*t + bx (divided by 3)
  -- x'*y'' - y'*x'' = 0 gives a cubic in t; substitute quadratic x',y' and linear x'',y''
  -- = (ax*t^2+bx*t+cx)*(2*ay*t+by) - (ay*t^2+by*t+cy)*(2*ax*t+bx) = 0
  -- Expand and collect:
  -- t^3: ax*2*ay - ay*2*ax = 0
  -- t^2: ax*by + bx*2*ay - ay*bx - by*2*ax = ax*by + 2*ay*bx - ay*bx - 2*ax*by
  --     = bx*ay - ax*by
  -- t^1: cx*2*ay + bx*by - cy*2*ax - by*bx = 2*ay*cx - 2*ax*cy
  -- t^0: cx*by - cy*bx
  local A2 = bx*ay - ax*by
  local A1 = 2*(ay*cx - ax*cy)
  local A0 = cx*by - cy*bx
  local roots = quad_roots(A2, A1, A0)
  return roots
end

-- ---------------------------------------------------------------------------
-- General Bézier curve (de Casteljau)
-- ---------------------------------------------------------------------------

local Curve = {}
Curve.__index = Curve

--: ({table}) -> table
M.curve = function(points)
  return setmetatable({ points = copy_points(points) }, Curve)
end

--: () -> number
Curve.degree = function(self)
  return #self.points - 1
end

--: (number) -> {x:number,y:number}
Curve.point = function(self, t)
  return de_casteljau(self.points, t)
end

--: (number?) -> {table}
Curve.to_points = function(self, n)
  n = n or 10
  local pts = {}
  for i = 0, n do
    pts[i+1] = self:point(i / n)
  end
  return pts
end

-- Derivative Bézier curve: degree n-1
--: () -> table
Curve.derivative = function(self)
  local pts = self.points
  local n = #pts
  if n <= 1 then return M.curve({ { x=0, y=0 } }) end
  local d = self:degree()
  local deriv = {}
  for i = 1, n - 1 do
    deriv[i] = pt_scale(pt_sub(pts[i+1], pts[i]), d)
  end
  return M.curve(deriv)
end

-- Degree elevation: same shape, degree+1 control points
--: () -> table
Curve.elevate = function(self)
  local pts = self.points
  local n = #pts  -- n = degree+1 control points
  local new_pts = {}
  new_pts[1] = pt_copy(pts[1])
  for i = 2, n do
    local alpha = (i - 1) / n
    new_pts[i] = pt_add(pt_scale(pts[i-1], alpha), pt_scale(pts[i], 1 - alpha))
  end
  new_pts[n+1] = pt_copy(pts[n])
  return M.curve(new_pts)
end

-- ---------------------------------------------------------------------------
-- Catmull-Rom cubic spline through given points
-- ---------------------------------------------------------------------------

local Spline = {}
Spline.__index = Spline

--: ({table}, table?) -> table
M.spline = function(points, opts)
  opts = opts or {}
  local tension = opts.tension or 0
  local closed  = opts.closed or false
  local alpha   = (1 - tension) / 6  -- Catmull-Rom weight factor

  local n = #points
  -- Build cubic segments from through-points using Catmull-Rom formula
  local segments = {}

  local function get_pt(i)
    if closed then
      -- wrap around
      return points[((i - 1) % n) + 1]
    else
      -- clamp
      if i < 1 then return points[1] end
      if i > n then return points[n] end
      return points[i]
    end
  end

  local seg_count = closed and n or (n - 1)
  for i = 1, seg_count do
    local pm1 = get_pt(i - 1)
    local p0  = get_pt(i)
    local p1  = get_pt(i + 1)
    local p2  = get_pt(i + 2)
    -- Control points: Catmull-Rom
    local cp1 = pt_add(p0, pt_scale(pt_sub(p1, pm1), alpha))
    local cp2 = pt_sub(p1, pt_scale(pt_sub(p2, p0),  alpha))
    segments[i] = M.cubic(p0, cp1, cp2, p1)
  end

  return setmetatable({
    points   = points,
    segments = segments,
    closed   = closed,
  }, Spline)
end

-- t ∈ [0, n-1] where n = #points
--: (number) -> {x:number,y:number}
Spline.point = function(self, t)
  local segs = self.segments
  local n = #segs
  if t <= 0 then return segs[1]:point(0) end
  if t >= n then return segs[n]:point(1) end
  local idx = floor(t)
  if idx >= n then idx = n - 1 end
  local local_t = t - idx
  return segs[idx + 1]:point(local_t)
end

--: (number) -> table
Spline.segment = function(self, i)
  return self.segments[i]
end

--: (number?) -> {table}
Spline.to_points = function(self, n)
  n = n or 100
  local pts = {}
  local seg_count = #self.segments
  for i = 0, n do
    pts[i+1] = self:point(i / n * seg_count)
  end
  return pts
end

-- ---------------------------------------------------------------------------
-- Hermite curve (point + tangent at each endpoint)
-- ---------------------------------------------------------------------------

local Hermite = {}
Hermite.__index = Hermite

--: (table, table, table, table) -> table
M.hermite = function(p0, m0, p1, m1)
  return setmetatable({ p0 = p0, m0 = m0, p1 = p1, m1 = m1 }, Hermite)
end

--: (number) -> {x:number,y:number}
Hermite.point = function(self, t)
  local t2 = t * t
  local t3 = t2 * t
  -- Cubic Hermite basis functions
  local h00 = 2*t3 - 3*t2 + 1
  local h10 = t3 - 2*t2 + t
  local h01 = -2*t3 + 3*t2
  local h11 = t3 - t2
  local function axis(a, da, b, db)
    return h00*a + h10*da + h01*b + h11*db
  end
  local p = {
    x = axis(self.p0.x, self.m0.x, self.p1.x, self.m1.x),
    y = axis(self.p0.y, self.m0.y, self.p1.y, self.m1.y),
  }
  if self.p0.z ~= nil then
    p.z = axis(self.p0.z or 0, self.m0.z or 0, self.p1.z or 0, self.m1.z or 0)
  end
  return p
end

-- Convert Hermite to equivalent cubic Bézier:
-- cp1 = p0 + m0/3,  cp2 = p1 - m1/3
--: () -> table
Hermite.to_cubic = function(self)
  local cp1 = pt_add(self.p0, pt_scale(self.m0, 1/3))
  local cp2 = pt_sub(self.p1, pt_scale(self.m1, 1/3))
  return M.cubic(self.p0, cp1, cp2, self.p1)
end

return M
