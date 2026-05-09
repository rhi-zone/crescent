if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Point2 = { x: number, y: number }
--:: Vec2 = { x: number, y: number }
--:: Circle = { x: number, y: number, r: number }
--:: Aabb = { x: number, y: number, w: number, h: number }
--:: Segment = { p1: Point2, p2: Point2 }
--:: Line2 = { a: number, b: number, c: number }
--:: Vec3 = { x: number, y: number, z: number }
--:: Plane = { a: number, b: number, c: number, d: number }

local sqrt = math.sqrt
local abs  = math.abs
local atan2 = math.atan2
local cos  = math.cos
local sin  = math.sin
local pi   = math.pi
local huge = math.huge
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Angle utilities
-- ---------------------------------------------------------------------------

M.deg_to_rad = function(deg) return deg * (pi / 180) end
M.rad_to_deg = function(rad) return rad * (180 / pi) end

-- Normalize angle to [0, 2π)
M.angle_normalize = function(a)
  local two_pi = 2 * pi
  a = a % two_pi
  if a < 0 then a = a + two_pi end
  return a
end

-- Shortest signed angular difference (result in (-π, π])
M.angle_diff = function(a, b)
  local d = (b - a) % (2 * pi)
  if d > pi then d = d - 2 * pi end
  return d
end

-- ---------------------------------------------------------------------------
-- 2D Points / Vectors
-- ---------------------------------------------------------------------------

--: (number, number) -> Point2
M.point = function(x, y) return { x = x, y = y } end
M.vec   = M.point

--: ({ x: number, y: number, ... }, { x: number, y: number, ... }) -> number
M.distance_sq = function(p1, p2)
  local dx = p2.x - p1.x
  local dy = p2.y - p1.y
  return dx * dx + dy * dy
end

--: ({ x: number, y: number, ... }, { x: number, y: number, ... }) -> number
M.distance = function(p1, p2) return sqrt(M.distance_sq(p1, p2)) end

--: (Point2, Point2) -> Point2
M.midpoint = function(p1, p2)
  return { x = (p1.x + p2.x) * 0.5, y = (p1.y + p2.y) * 0.5 }
end

--: (Point2, Point2, number) -> Point2
M.lerp_point = function(p1, p2, t)
  return { x = p1.x + (p2.x - p1.x) * t, y = p1.y + (p2.y - p1.y) * t }
end

--: (Vec2, Vec2) -> Vec2
M.vec_add   = function(v1, v2) return { x = v1.x + v2.x, y = v1.y + v2.y } end
--: (Vec2, Vec2) -> Vec2
M.vec_sub   = function(v1, v2) return { x = v1.x - v2.x, y = v1.y - v2.y } end
--: (Vec2, number) -> Vec2
M.vec_scale = function(v, s)   return { x = v.x * s,     y = v.y * s     } end

--: (Vec2, Vec2) -> number
M.vec_dot   = function(v1, v2) return v1.x * v2.x + v1.y * v2.y end
-- 2D cross product (scalar z-component of the 3D cross): returns scalar
--: (Vec2, Vec2) -> number
M.vec_cross = function(v1, v2) return v1.x * v2.y - v1.y * v2.x end

--: (Vec2) -> number
M.vec_len   = function(v) return sqrt(v.x * v.x + v.y * v.y) end

--: (Vec2) -> Vec2
M.vec_normalize = function(v)
  local l = M.vec_len(v)
  if l == 0 then return { x = 0, y = 0 } end
  return { x = v.x / l, y = v.y / l }
end

--: (Vec2) -> number
M.vec_angle  = function(v) return atan2(v.y, v.x) end

--: (Vec2, number) -> Vec2
M.vec_rotate = function(v, angle)
  local c = cos(angle)
  local s_ = sin(angle)
  return { x = v.x * c - v.y * s_, y = v.x * s_ + v.y * c }
end

-- Perpendicular vector (rotated 90° CCW): (-y, x)
--: (Vec2) -> Vec2
M.vec_perp = function(v) return { x = -v.y, y = v.x } end

-- ---------------------------------------------------------------------------
-- Orientation
-- ---------------------------------------------------------------------------

-- Returns 1 (CCW), -1 (CW), 0 (collinear)
--: (Point2, Point2, Point2) -> integer
M.orientation = function(p1, p2, p3)
  local cross = (p2.x - p1.x) * (p3.y - p1.y) - (p2.y - p1.y) * (p3.x - p1.x)
  if cross > 0 then return 1 elseif cross < 0 then return -1 else return 0 end
end

-- ---------------------------------------------------------------------------
-- Line segments
-- ---------------------------------------------------------------------------

--: (Point2, Point2) -> Segment
M.segment = function(p1, p2) return { p1 = p1, p2 = p2 } end

--: (Segment) -> number
M.segment_length = function(seg) return M.distance(seg.p1, seg.p2) end

--: (Segment) -> Point2
M.segment_midpoint = function(seg) return M.midpoint(seg.p1, seg.p2) end

-- Closest point on segment to the given point
--: ({ x: number, y: number, ... }, Segment) -> Point2
M.closest_point_on_segment = function(point, seg)
  local dx = seg.p2.x - seg.p1.x
  local dy = seg.p2.y - seg.p1.y
  local len_sq = dx * dx + dy * dy
  if len_sq == 0 then return { x = seg.p1.x, y = seg.p1.y } end
  local t = ((point.x - seg.p1.x) * dx + (point.y - seg.p1.y) * dy) / len_sq
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return { x = seg.p1.x + t * dx, y = seg.p1.y + t * dy }
end

-- Test if point lies on segment (within epsilon tolerance)
--: (Point2, Segment, number | nil) -> boolean
M.point_on_segment = function(p, seg, eps)
  eps = eps or 1e-9
  -- Must satisfy: distance(p, p1) + distance(p, p2) ≈ distance(p1, p2)
  local d = M.distance(seg.p1, seg.p2)
  local d1 = M.distance(p, seg.p1)
  local d2 = M.distance(p, seg.p2)
  return abs(d1 + d2 - d) <= eps
end

-- Shared helper: compute intersection parameter for seg1 p1→p2
-- Returns t, u where intersection = p1 + t*(p2-p1) = p3 + u*(p4-p3)
-- Returns nil, nil if parallel
--: (Point2, Point2, Point2, Point2) -> (number | nil, number | nil)
local function _seg_intersect_params(p1, p2, p3, p4)
  local dx1 = p2.x - p1.x
  local dy1 = p2.y - p1.y
  local dx2 = p4.x - p3.x
  local dy2 = p4.y - p3.y
  local denom = dx1 * dy2 - dy1 * dx2
  if denom == 0 then return nil, nil end  -- parallel
  local dx3 = p3.x - p1.x
  local dy3 = p3.y - p1.y
  local t = (dx3 * dy2 - dy3 * dx2) / denom
  local u = (dx3 * dy1 - dy3 * dx1) / denom
  return t, u
end

--: (Segment, Segment) -> boolean
M.segment_intersects = function(seg1, seg2)
  local t, u = _seg_intersect_params(seg1.p1, seg1.p2, seg2.p1, seg2.p2)
  if t == nil or u == nil then return false end
  return not not (t >= 0 and t <= 1 and u >= 0 and u <= 1)
end

-- Returns intersection point or nil (parallel or non-intersecting)
--: (Segment, Segment) -> Point2 | nil
M.segment_intersection = function(seg1, seg2)
  local t, u = _seg_intersect_params(seg1.p1, seg1.p2, seg2.p1, seg2.p2)
  if t == nil or u == nil then return nil end
  if t < 0 or t > 1 or u < 0 or u > 1 then return nil end
  return {
    x = seg1.p1.x + t * (seg1.p2.x - seg1.p1.x),
    y = seg1.p1.y + t * (seg1.p2.y - seg1.p1.y),
  }
end

-- ---------------------------------------------------------------------------
-- Infinite lines  ax + by + c = 0
-- ---------------------------------------------------------------------------

-- Compute line coefficients from two points
--: (Point2, Point2) -> Line2
M.line_from_points = function(p1, p2)
  local a = p2.y - p1.y
  local b = p1.x - p2.x
  local c = -(a * p1.x + b * p1.y)
  return { a = a, b = b, c = c }
end

--: (Point2, Vec2) -> Line2
M.line_from_point_dir = function(p, dir)
  -- direction vector (dx, dy) → normal is (-dy, dx), so a=-dy, b=dx
  local a = -dir.y
  local b = dir.x
  local c = -(a * p.x + b * p.y)
  return { a = a, b = b, c = c }
end

-- Signed distance from point to line ax+by+c=0 (positive on normal side)
--: (Line2, Point2) -> number
M.line_distance = function(line, point)
  local norm = sqrt(line.a * line.a + line.b * line.b)
  if norm == 0 then return 0 end
  return (line.a * point.x + line.b * point.y + line.c) / norm
end

-- Intersection of two infinite lines; returns nil if parallel
--: (Line2, Line2) -> Point2 | nil
M.lines_intersection = function(l1, l2)
  local denom = l1.a * l2.b - l2.a * l1.b
  if denom == 0 then return nil end
  local x = (l1.b * l2.c - l2.b * l1.c) / (-denom)  -- Cramer's rule
  -- Actually solve directly:
  -- l1.a*x + l1.b*y = -l1.c
  -- l2.a*x + l2.b*y = -l2.c
  local det = l1.a * l2.b - l2.a * l1.b
  if det == 0 then return nil end
  x = (-l1.c * l2.b + l2.c * l1.b) / det
  local y = (-l1.a * l2.c + l2.a * l1.c) / det
  return { x = x, y = y }
end

-- ---------------------------------------------------------------------------
-- Circles
-- ---------------------------------------------------------------------------

--: (number, number, number) -> Circle
M.circle = function(cx, cy, r) return { x = cx, y = cy, r = r } end

--: (Circle, Point2) -> boolean
M.circle_contains = function(circle, point)
  return M.distance_sq(circle, point) <= circle.r * circle.r
end

--: (Circle, Circle) -> boolean
M.circles_intersect = function(c1, c2)
  local d_sq = M.distance_sq(c1, c2)
  local r_sum = c1.r + c2.r
  local r_diff = abs(c1.r - c2.r)
  return not not (d_sq <= r_sum * r_sum and d_sq >= r_diff * r_diff)
end

-- Does segment intersect (or lie inside) circle?
--: (Circle, Segment) -> boolean
M.circle_segment_intersect = function(circle, seg)
  local closest = M.closest_point_on_segment(circle, seg)
  return M.distance_sq(circle, closest) <= circle.r * circle.r
end

-- ---------------------------------------------------------------------------
-- Axis-aligned bounding boxes
-- ---------------------------------------------------------------------------

--: (number, number, number, number) -> Aabb
M.aabb = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end

--: (Point2[]) -> Aabb | nil
M.aabb_from_points = function(points)
  if not points[1] then return nil end
  local min_x, min_y = points[1].x, points[1].y
  local max_x, max_y = min_x, min_y
  for i = 2, #points do
    local p = points[i]
    if p.x < min_x then min_x = p.x end
    if p.y < min_y then min_y = p.y end
    if p.x > max_x then max_x = p.x end
    if p.y > max_y then max_y = p.y end
  end
  return { x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
end

--: (Aabb, Point2) -> boolean
M.aabb_contains_point = function(aabb, p)
  return not not (p.x >= aabb.x and p.x <= aabb.x + aabb.w
     and p.y >= aabb.y and p.y <= aabb.y + aabb.h)
end

--: (Aabb, Aabb) -> boolean
M.aabb_intersects = function(a1, a2)
  return not not (a1.x <= a2.x + a2.w and a1.x + a1.w >= a2.x
     and a1.y <= a2.y + a2.h and a1.y + a1.h >= a2.y)
end

--: (Aabb, Aabb) -> Aabb
M.aabb_union = function(a1, a2)
  local x = a1.x < a2.x and a1.x or a2.x
  local y = a1.y < a2.y and a1.y or a2.y
  local max_x = (a1.x + a1.w) > (a2.x + a2.w) and (a1.x + a1.w) or (a2.x + a2.w)
  local max_y = (a1.y + a1.h) > (a2.y + a2.h) and (a1.y + a1.h) or (a2.y + a2.h)
  return { x = x, y = y, w = max_x - x, h = max_y - y }
end

--: (Aabb, number) -> Aabb
M.aabb_expand = function(aabb, amount)
  return {
    x = aabb.x - amount,
    y = aabb.y - amount,
    w = aabb.w + 2 * amount,
    h = aabb.h + 2 * amount,
  }
end

-- ---------------------------------------------------------------------------
-- Triangles
-- ---------------------------------------------------------------------------

--:: Triangle = { p1: Point2, p2: Point2, p3: Point2 }

--: (Point2, Point2, Point2) -> Triangle
M.triangle = function(p1, p2, p3) return { p1 = p1, p2 = p2, p3 = p3 } end

-- Signed area: positive = CCW, negative = CW
--: (Point2, Point2, Point2) -> number
M.triangle_area = function(p1, p2, p3)
  return 0.5 * ((p2.x - p1.x) * (p3.y - p1.y) - (p3.x - p1.x) * (p2.y - p1.y))
end

-- Point-in-triangle via barycentric coords (works for both windings)
--: (Point2, Point2, Point2, Point2) -> boolean
M.triangle_contains = function(p1, p2, p3, point)
  local d1 = M.vec_cross(M.vec_sub(p2, p1), M.vec_sub(point, p1))
  local d2 = M.vec_cross(M.vec_sub(p3, p2), M.vec_sub(point, p2))
  local d3 = M.vec_cross(M.vec_sub(p1, p3), M.vec_sub(point, p3))
  local has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
  local has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
  return not (has_neg and has_pos)
end

-- Circumcircle of triangle; returns nil for degenerate (collinear) triangle
--: (Point2, Point2, Point2) -> Circle | nil
M.triangle_circumcircle = function(p1, p2, p3)
  local ax, ay = p1.x, p1.y
  local bx, by = p2.x, p2.y
  local cx, cy = p3.x, p3.y
  local D = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
  if abs(D) < 1e-10 then return nil end
  local ux = ((ax*ax + ay*ay) * (by - cy) + (bx*bx + by*by) * (cy - ay) + (cx*cx + cy*cy) * (ay - by)) / D
  local uy = ((ax*ax + ay*ay) * (cx - bx) + (bx*bx + by*by) * (ax - cx) + (cx*cx + cy*cy) * (bx - ax)) / D
  local center = { x = ux, y = uy }
  local r = M.distance(center, p1)
  return M.circle(ux, uy, r)
end

--: (Point2, Point2, Point2) -> Point2
M.triangle_centroid = function(p1, p2, p3)
  return { x = (p1.x + p2.x + p3.x) / 3, y = (p1.y + p2.y + p3.y) / 3 }
end

-- ---------------------------------------------------------------------------
-- Polygons
-- ---------------------------------------------------------------------------

-- Shoelace formula — returns signed area (positive = CCW)
--: (Point2[]) -> number
M.polygon_area = function(points)
  local n = #points
  local area = 0 --: number
  for i = 1, n do
    local j = (i % n) + 1
    area = area + points[i].x * points[j].y
    area = area - points[j].x * points[i].y
  end
  return area * 0.5
end

--: (Point2[]) -> Point2
M.polygon_centroid = function(points)
  local n = #points
  local area = 0 --: number
  local cx = 0 --: number
  local cy = 0 --: number
  for i = 1, n do
    local j = (i % n) + 1
    local cross = points[i].x * points[j].y - points[j].x * points[i].y
    area  = area + cross
    cx    = cx   + (points[i].x + points[j].x) * cross
    cy    = cy   + (points[i].y + points[j].y) * cross
  end
  area = area * 0.5
  if area == 0 then return M.point(0, 0) end
  local factor = 1 / (6 * area)
  return { x = cx * factor, y = cy * factor }
end

-- Returns true if polygon vertices are all convex (same winding for every triple)
--: (Point2[]) -> boolean
M.polygon_is_convex = function(points)
  local n = #points
  if n < 3 then return false end
  local sign = 0
  for i = 1, n do
    local a = points[i]
    local b = points[(i % n) + 1]
    local c = points[((i + 1) % n) + 1]
    local cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    if cross ~= 0 then
      if sign == 0 then
        sign = cross > 0 and 1 or -1
      elseif (cross > 0 and sign < 0) or (cross < 0 and sign > 0) then
        return false
      end
    end
  end
  return true
end

-- Ray-casting point-in-polygon
--: (Point2[], Point2) -> boolean
M.polygon_contains = function(points, point)
  local n = #points
  local inside = false
  local px, py = point.x, point.y
  local j = n
  for i = 1, n do
    local xi, yi = points[i].x, points[i].y
    local xj, yj = points[j].x, points[j].y
    if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
      inside = not inside
    end
    j = i
  end
  return inside
end

-- Graham scan convex hull — returns CCW ordered hull points
-- Handles degenerate inputs (< 3 points, collinear) gracefully
--: (Point2[]) -> Point2[]
M.convex_hull = function(points)
  local n = #points
  if n == 0 then return {} end
  if n == 1 then return { { x = points[1].x, y = points[1].y } } end

  -- Find bottom-most (then left-most) point as pivot
  local pivot = 1
  for i = 2, n do
    if points[i].y < points[pivot].y
      or (points[i].y == points[pivot].y and points[i].x < points[pivot].x) then
      pivot = i
    end
  end

  -- Copy, put pivot first
  local pts = {} --: { [integer]: Point2 }
  for i = 1, n do pts[i] = points[i] end
  pts[1], pts[pivot] = pts[pivot], pts[1]
  local ox, oy = pts[1].x, pts[1].y

  -- Sort by polar angle relative to pivot
  --: (Point2, Point2) -> boolean
  table.sort(pts, function(a, b)
    if a == pts[1] then return true end
    if b == pts[1] then return false end
    local cross = (a.x - ox) * (b.y - oy) - (a.y - oy) * (b.x - ox)
    if cross ~= 0 then return cross > 0 end
    -- Collinear: closer point first
    local da = (a.x - ox)^2 + (a.y - oy)^2
    local db = (b.x - ox)^2 + (b.y - oy)^2
    return da < db
  end)

  -- Build hull
  local hull = {} --: { [integer]: Point2 }
  for _, p in ipairs(pts) do
    while #hull >= 2 do
      local cross = (hull[#hull].x - hull[#hull-1].x) * (p.y - hull[#hull-1].y)
                  - (hull[#hull].y - hull[#hull-1].y) * (p.x - hull[#hull-1].x)
      if cross <= 0 then
        table.remove(hull)
      else
        break
      end
    end
    hull[#hull + 1] = p
  end

  return hull
end

-- ---------------------------------------------------------------------------
-- 3D Vectors
-- ---------------------------------------------------------------------------

--: (number, number, number) -> Vec3
M.vec3 = function(x, y, z) return { x = x, y = y, z = z } end

--: (Vec3, Vec3) -> Vec3
M.vec3_add   = function(v1, v2) return { x = v1.x+v2.x, y = v1.y+v2.y, z = v1.z+v2.z } end
--: (Vec3, Vec3) -> Vec3
M.vec3_sub   = function(v1, v2) return { x = v1.x-v2.x, y = v1.y-v2.y, z = v1.z-v2.z } end
--: (Vec3, number) -> Vec3
M.vec3_scale = function(v, s)   return { x = v.x*s,     y = v.y*s,     z = v.z*s     } end

--: (Vec3, Vec3) -> number
M.vec3_dot = function(v1, v2)
  return v1.x * v2.x + v1.y * v2.y + v1.z * v2.z
end

--: (Vec3, Vec3) -> Vec3
M.vec3_cross = function(v1, v2)
  return {
    x = v1.y * v2.z - v1.z * v2.y,
    y = v1.z * v2.x - v1.x * v2.z,
    z = v1.x * v2.y - v1.y * v2.x,
  }
end

--: (Vec3) -> number
M.vec3_len = function(v)
  return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

--: (Vec3) -> Vec3
M.vec3_normalize = function(v)
  local l = M.vec3_len(v)
  if l == 0 then return { x = 0, y = 0, z = 0 } end
  return { x = v.x / l, y = v.y / l, z = v.z / l }
end

-- ---------------------------------------------------------------------------
-- Planes   ax + by + cz + d = 0
-- ---------------------------------------------------------------------------

-- normal should be a unit vector for meaningful distance queries
--: (Vec3, Vec3) -> Plane
M.plane_from_normal_point = function(normal, point)
  local d = -(normal.x * point.x + normal.y * point.y + normal.z * point.z)
  return { a = normal.x, b = normal.y, c = normal.z, d = d }
end

-- Signed distance from point to plane (assumes |normal| = 1)
--: (Plane, Vec3) -> number
M.plane_distance = function(plane, point)
  local norm = sqrt(plane.a*plane.a + plane.b*plane.b + plane.c*plane.c)
  if norm == 0 then return 0 end
  return (plane.a * point.x + plane.b * point.y + plane.c * point.z + plane.d) / norm
end

-- ---------------------------------------------------------------------------

M._tier = "pure"

return M
