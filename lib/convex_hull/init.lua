if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Point = { x: number, y: number }

-- ========================
-- INTERNAL HELPERS
-- ========================

-- Cross product of vectors OA and OB (2D → scalar z-component)
-- Positive = CCW, Negative = CW, Zero = collinear
--: (Point, Point, Point) -> number
local function cross(o, a, b)
  return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
end

--: (Point, Point) -> number
local function dist2(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  return dx * dx + dy * dy
end

--: (Point, Point) -> number
local function dist(a, b)
  return math.sqrt(dist2(a, b))
end

-- ========================
-- CONVEX HULL — Graham scan O(n log n)
-- Returns hull vertices in CCW order, collinear points excluded
-- ========================

--: ({ [integer]: Point }) -> { [integer]: Point }
function M.convex_hull(points)
  local n = #points
  if n == 0 then return {} end
  if n == 1 then return { { x = points[1].x, y = points[1].y } } end

  -- Find pivot: lowest y, then leftmost x
  local pivot = points[1] --: Point
  for i = 2, n do
    local p = points[i] --[[:! Point]]
    if p.y < pivot.y or (p.y == pivot.y and p.x < pivot.x) then
      pivot = p
    end
  end

  -- Sort by polar angle with respect to pivot; ties broken by distance (closer first)
  local sorted = {} --: { [integer]: Point }
  for i = 1, n do
    local p = points[i] --[[:! Point]]
    if p ~= pivot then
      sorted[#sorted + 1] = p
    end
  end
  table.sort(sorted, function(a, b)
    local a_ = a --[[:! Point]]
    local b_ = b --[[:! Point]]
    local c = cross(pivot, a_, b_)
    if c ~= 0 then return c > 0 end
    return dist2(pivot, a_) < dist2(pivot, b_)
  end)

  -- Remove collinear points except the farthest from pivot
  local filtered = {} --: { [integer]: Point }
  local i = 1
  while i <= #sorted do
    local j = i
    while j + 1 <= #sorted and cross(pivot, sorted[j], sorted[j + 1]) == 0 do
      j = j + 1
    end
    -- Keep only the farthest in this collinear group
    filtered[#filtered + 1] = sorted[j]
    i = j + 1
  end

  if #filtered == 0 then return { { x = pivot.x, y = pivot.y } } end
  if #filtered == 1 then
    return { { x = pivot.x, y = pivot.y }, { x = filtered[1].x, y = filtered[1].y } }
  end

  local stack = { pivot, filtered[1], filtered[2] } --: { [integer]: Point }
  for k = 3, #filtered do
    while #stack >= 2 and cross(stack[#stack - 1], stack[#stack], filtered[k]) <= 0 do
      stack[#stack] = nil --[[: any]]
    end
    stack[#stack + 1] = filtered[k]
  end

  -- Copy to plain tables
  local hull = {}
  for _, p in ipairs(stack) do
    hull[#hull + 1] = { x = p.x, y = p.y }
  end
  return hull
end

-- ========================
-- QUICKHULL O(n log n) average
-- ========================

--: ({ [integer]: Point }, Point, Point, nil, { [integer]: Point }) -> nil
local function quickhull_rec(pts, a, b, hull_set, result)
  if #pts == 0 then return end

  -- Find point with max distance (cross product magnitude) from line a→b
  local max_cross = 0 --: number
  local farthest = nil --: Point | nil
  for _, p in ipairs(pts) do
    local p_ = p --[[:! Point]]
    local c = cross(a, b, p_)
    if c > max_cross then
      max_cross = c
      farthest = p_
    end
  end

  if not farthest then return end

  -- Partition: left of a→farthest and left of farthest→b
  local left1 = {} --: { [integer]: Point }
  local left2 = {} --: { [integer]: Point }
  for _, p in ipairs(pts) do
    local p_ = p --[[:! Point]]
    if p_ ~= farthest then
      if cross(a, farthest, p_) > 0 then
        left1[#left1 + 1] = p_
      elseif cross(farthest, b, p_) > 0 then
        left2[#left2 + 1] = p_
      end
    end
  end

  quickhull_rec(left1, a, farthest, hull_set, result)
  result[#result + 1] = farthest
  quickhull_rec(left2, farthest, b, hull_set, result)
end

--: ({ [integer]: Point }) -> { [integer]: Point }
function M.quickhull(points)
  local n = #points
  if n == 0 then return {} end
  if n == 1 then return { { x = points[1].x, y = points[1].y } } end

  -- Find leftmost and rightmost points
  local left_pt = points[1] --: Point
  local right_pt = points[1] --: Point
  for i = 2, n do
    local p = points[i] --[[:! Point]]
    if p.x < left_pt.x or (p.x == left_pt.x and p.y < left_pt.y) then left_pt = p end
    if p.x > right_pt.x or (p.x == right_pt.x and p.y > right_pt.y) then right_pt = p end
  end

  if left_pt == right_pt then
    return { { x = left_pt.x, y = left_pt.y } }
  end

  -- Partition points into upper (left of left→right) and lower (left of right→left)
  local upper = {} --: { [integer]: Point }
  local lower = {} --: { [integer]: Point }
  for _, p in ipairs(points) do
    local p_ = p --[[:! Point]]
    if p_ ~= left_pt and p_ ~= right_pt then
      if cross(left_pt, right_pt, p_) > 0 then
        upper[#upper + 1] = p_
      elseif cross(right_pt, left_pt, p_) > 0 then
        lower[#lower + 1] = p_
      end
    end
  end

  -- Build hull: left_pt → upper hull → right_pt → lower hull → back
  local result = {}
  result[#result + 1] = { x = left_pt.x, y = left_pt.y }
  quickhull_rec(upper, left_pt, right_pt, nil, result)
  result[#result + 1] = { x = right_pt.x, y = right_pt.y }
  quickhull_rec(lower, right_pt, left_pt, nil, result)

  return result
end

-- ========================
-- POINT IN HULL (convex polygon, binary search O(log n))
-- Hull must be CCW order
-- ========================

--: ({ [integer]: Point }, Point) -> boolean
function M.point_in_hull(hull, p)
  local n = #hull
  if n == 0 then return false end
  if n == 1 then return (hull[1].x == p.x and hull[1].y == p.y) and true or false end
  if n == 2 then
    -- Edge case: degenerate hull (line segment)
    local c = cross(hull[1], hull[2], p)
    if c ~= 0 then return false end
    local t = dist2(hull[1], hull[2])
    if t == 0 then return (hull[1].x == p.x and hull[1].y == p.y) and true or false end
    local dot = (p.x - hull[1].x) * (hull[2].x - hull[1].x) +
                (p.y - hull[1].y) * (hull[2].y - hull[1].y)
    return (dot >= 0 and dot <= t) and true or false
  end

  -- Use fan triangulation from hull[1]
  -- p must be left of or on every edge hull[1]→hull[i]
  local c1 = cross(hull[1], hull[2], p)
  if c1 < 0 then return false end
  local cn = cross(hull[1], hull[n], p)
  if cn > 0 then return false end

  -- Binary search for sector
  local lo, hi = 2, n
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if cross(hull[1], hull[mid], p) >= 0 then
      lo = mid
    else
      hi = mid
    end
  end

  return cross(hull[lo], hull[hi], p) >= 0
end

-- ========================
-- POINT IN POLYGON — winding number (works for concave polygons)
-- ========================

--: ({ [integer]: Point }, Point) -> boolean
function M.point_in_polygon(poly, p)
  local n = #poly
  if n < 3 then return false end
  local winding = 0
  local px, py = p.x, p.y
  for i = 1, n do
    local a = poly[i]
    local b = poly[i % n + 1]
    if a.y <= py then
      if b.y > py then
        -- Upward crossing
        if cross(a, b, p) > 0 then
          winding = winding + 1
        end
      end
    else
      if b.y <= py then
        -- Downward crossing
        if cross(a, b, p) < 0 then
          winding = winding - 1
        end
      end
    end
  end
  return winding ~= 0
end

-- ========================
-- POLYGON AREA — shoelace formula (signed)
-- Positive for CCW, negative for CW
-- ========================

--: ({ [integer]: Point }) -> number
function M.polygon_area(poly)
  local n = #poly
  if n < 3 then return 0 end
  local sum = 0 --: number
  for i = 1, n do
    local a = poly[i] --[[:! Point]]
    local b = poly[i % n + 1] --[[:! Point]]
    sum = sum + (a.x * b.y - b.x * a.y)
  end
  return math.abs(sum) * 0.5
end

-- ========================
-- POLYGON CENTROID
-- ========================

--: ({ [integer]: Point }) -> Point | nil
function M.polygon_centroid(poly)
  local n = #poly
  if n == 0 then return nil end
  if n == 1 then return { x = poly[1].x, y = poly[1].y } end
  if n == 2 then
    return { x = (poly[1].x + poly[2].x) * 0.5, y = (poly[1].y + poly[2].y) * 0.5 }
  end

  local cx = 0 --: number
  local cy = 0 --: number
  local area = 0 --: number
  for i = 1, n do
    local a = poly[i] --[[:! Point]]
    local b = poly[i % n + 1] --[[:! Point]]
    local cross_val = a.x * b.y - b.x * a.y
    area = area + cross_val
    cx = cx + (a.x + b.x) * cross_val
    cy = cy + (a.y + b.y) * cross_val
  end
  area = area * 0.5
  if area == 0 then
    -- Degenerate polygon — use arithmetic mean
    local sx = 0 --: number
    local sy = 0 --: number
    for _, p in ipairs(poly) do
      local p_ = p --[[:! Point]]
      sx = sx + p_.x; sy = sy + p_.y
    end
    return { x = sx / n, y = sy / n }
  end
  local inv = 1 / (6 * area)
  return { x = cx * inv, y = cy * inv }
end

-- ========================
-- POLYGON PERIMETER
-- ========================

--: ({ [integer]: Point }) -> number
function M.polygon_perimeter(poly)
  local n = #poly
  if n < 2 then return 0 end
  local sum = 0 --: number
  for i = 1, n do
    sum = sum + dist(poly[i] --[[:! Point]], poly[i % n + 1] --[[:! Point]])
  end
  return sum
end

-- ========================
-- IS CONVEX
-- Checks all cross products have the same sign (or zero)
-- ========================

--: ({ [integer]: Point }) -> boolean
function M.is_convex(poly)
  local n = #poly
  if n < 3 then return true end
  local sign = 0
  for i = 1, n do
    local a = poly[i]
    local b = poly[i % n + 1]
    local c = poly[(i + 1) % n + 1]
    local cp = cross(a, b, c)
    if cp ~= 0 then
      if sign == 0 then
        sign = cp > 0 and 1 or -1
      elseif (cp > 0 and sign < 0) or (cp < 0 and sign > 0) then
        return false
      end
    end
  end
  return true
end

-- ========================
-- RAMER-DOUGLAS-PEUCKER polyline simplification
-- ========================

--: ({ [integer]: Point }, integer, integer, number, { [integer]: Point }) -> nil
local function dp_rec(points, start, stop, epsilon, result)
  if stop <= start + 1 then
    return
  end
  -- Find point with max distance from line start→stop
  local a = points[start] --[[:! Point]]
  local b = points[stop] --[[:! Point]]
  local max_dist = 0 --: number
  local max_idx = start
  for i = start + 1, stop - 1 do
    local p = points[i] --[[:! Point]]
    -- Distance from p to segment a→b
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local d = 0 --: number
    if len2 == 0 then
      d = dist(p, a)
    else
      local t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
      if t < 0 then
        d = dist(p, a)
      elseif t > 1 then
        d = dist(p, b)
      else
        d = dist(p, { x = a.x + t * dx, y = a.y + t * dy })
      end
    end
    if d > max_dist then
      max_dist = d
      max_idx = i
    end
  end

  if max_dist > epsilon then
    dp_rec(points, start, max_idx, epsilon, result)
    result[#result + 1] = points[max_idx]
    dp_rec(points, max_idx, stop, epsilon, result)
  end
end

function M.douglas_peucker(points, epsilon)
  local n = #points
  if n <= 2 then
    local result = {}
    for _, p in ipairs(points) do result[#result + 1] = { x = p.x, y = p.y } end
    return result
  end
  local result = { { x = points[1].x, y = points[1].y } }
  dp_rec(points, 1, n, epsilon, result)
  result[#result + 1] = { x = points[n].x, y = points[n].y }
  return result
end

-- ========================
-- MINIMUM BOUNDING CIRCLE — Welzl's algorithm
-- ========================

--:: Circle = { cx: number, cy: number, r: number }

--: (Point) -> Circle
local function circle_from_1(p)
  return { cx = p.x, cy = p.y, r = 0 }
end

--: (Point, Point) -> Circle
local function circle_from_2(a, b)
  return {
    cx = (a.x + b.x) * 0.5,
    cy = (a.y + b.y) * 0.5,
    r = dist(a, b) * 0.5,
  }
end

--: (Point, Point, Point) -> Circle
local function circle_from_3(a, b, c)
  local ax, ay = b.x - a.x, b.y - a.y
  local bx, by = c.x - a.x, c.y - a.y
  local D = 2 * (ax * by - ay * bx)
  if math.abs(D) < 1e-10 then
    -- Collinear — circumcircle is degenerate, return diameter circle of farthest pair
    local d_ab = dist2(a, b)
    local d_bc = dist2(b, c)
    local d_ac = dist2(a, c)
    if d_ab >= d_bc and d_ab >= d_ac then return circle_from_2(a, b)
    elseif d_bc >= d_ac then return circle_from_2(b, c)
    else return circle_from_2(a, c)
    end
  end
  local ux = (by * (ax * ax + ay * ay) - ay * (bx * bx + by * by)) / D
  local uy = (ax * (bx * bx + by * by) - bx * (ax * ax + ay * ay)) / D
  local cx = a.x + ux
  local cy = a.y + uy
  return { cx = cx, cy = cy, r = dist(a, { x = cx, y = cy }) }
end

--: (Circle, Point) -> boolean
local function point_in_circle(c, p)
  local dx, dy = p.x - c.cx, p.y - c.cy
  return (dx * dx + dy * dy <= c.r * c.r + 1e-10) and true or false
end

--: ({ [integer]: Point }, { [integer]: Point }, integer) -> Circle
local function welzl(pts, R, n)
  if n == 0 or #R == 3 then
    if #R == 0 then return { cx = 0, cy = 0, r = 0 }
    elseif #R == 1 then return circle_from_1(R[1])
    elseif #R == 2 then return circle_from_2(R[1], R[2])
    else return circle_from_3(R[1], R[2], R[3])
    end
  end

  local p = pts[n] --[[:! Point]]
  local D = welzl(pts, R, n - 1)
  if point_in_circle(D, p) then return D end

  local R2 = {} --: { [integer]: Point }
  for _, r in ipairs(R) do R2[#R2 + 1] = r --[[:! Point]] end
  R2[#R2 + 1] = p
  return welzl(pts, R2, n - 1)
end

--: ({ [integer]: Point }) -> Circle
function M.min_bounding_circle(points)
  local n = #points
  if n == 0 then return { cx = 0, cy = 0, r = 0 } end
  if n == 1 then return circle_from_1(points[1]) end
  if n == 2 then return circle_from_2(points[1], points[2]) end

  -- Shuffle for expected O(n) — use a deterministic Fisher-Yates for reproducibility
  local pts = {} --: { [integer]: Point }
  for i, p in ipairs(points) do pts[i] = p --[[:! Point]] end
  -- simple seed-based shuffle
  local seed = 12345 --: number
  for i = n, 2, -1 do
    seed = (seed * 1103515245 + 12345) % (2 ^ 31)
    local j = math.floor(seed % i) + 1
    pts[i], pts[j] = pts[j], pts[i]
  end

  return welzl(pts, {}, n)
end

-- ========================
-- LINE / SEGMENT GEOMETRY
-- ========================

-- Sign of a number: -1, 0, or 1
local function sign(x)
  if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end
end

-- Returns true if point p is on segment [a, b] (assumes collinear)
--: (Point, Point, Point) -> boolean
local function on_segment(a, b, p)
  return (math.min(a.x, b.x) <= p.x and p.x <= math.max(a.x, b.x) and
         math.min(a.y, b.y) <= p.y and p.y <= math.max(a.y, b.y)) and true or false
end

-- Check if segments (a1,a2) and (b1,b2) intersect
--: (Point, Point, Point, Point) -> boolean
function M.segments_intersect(a1, a2, b1, b2)
  local d1 = cross(b1, b2, a1)
  local d2 = cross(b1, b2, a2)
  local d3 = cross(a1, a2, b1)
  local d4 = cross(a1, a2, b2)

  if sign(d1) ~= sign(d2) and sign(d3) ~= sign(d4) then
    return true
  end

  -- Collinear overlap checks
  if d1 == 0 and on_segment(b1, b2, a1) then return true end
  if d2 == 0 and on_segment(b1, b2, a2) then return true end
  if d3 == 0 and on_segment(a1, a2, b1) then return true end
  if d4 == 0 and on_segment(a1, a2, b2) then return true end

  return false
end

-- Compute intersection point of segments (a1,a2) and (b1,b2)
-- Returns {x, y} or nil if they don't intersect
--: (Point, Point, Point, Point) -> Point | nil
function M.segment_intersection(a1, a2, b1, b2)
  if not M.segments_intersect(a1, a2, b1, b2) then return nil end

  local dax, day = a2.x - a1.x, a2.y - a1.y
  local dbx, dby = b2.x - b1.x, b2.y - b1.y
  local denom = dax * dby - day * dbx

  if math.abs(denom) < 1e-12 then
    -- Collinear overlap — return one of the overlap endpoints
    -- Return the point from segment a that lies on segment b
    if on_segment(b1, b2, a1) then return { x = a1.x, y = a1.y } end
    if on_segment(b1, b2, a2) then return { x = a2.x, y = a2.y } end
    if on_segment(a1, a2, b1) then return { x = b1.x, y = b1.y } end
    return { x = b2.x, y = b2.y }
  end

  local t = ((b1.x - a1.x) * dby - (b1.y - a1.y) * dbx) / denom
  return { x = a1.x + t * dax, y = a1.y + t * day }
end

-- Distance from point p to line segment [a, b]
--: (Point, Point, Point) -> number
function M.point_to_segment_dist(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local len2 = dx * dx + dy * dy
  if len2 == 0 then return dist(p, a) end
  local t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
  if t < 0 then return dist(p, a) end
  if t > 1 then return dist(p, b) end
  return dist(p, { x = a.x + t * dx, y = a.y + t * dy })
end

-- ========================
-- EAR-CLIPPING TRIANGULATION
-- For simple (non-self-intersecting) polygons
-- Returns array of {a, b, c} where a/b/c are {x,y} tables
-- ========================

--: ({ [integer]: Point }, { [integer]: integer }, integer, integer) -> boolean
local function is_ear(poly, indices, i, n)
  local prev_i = indices[(i - 2 + n) % n + 1]
  local curr_i = indices[(i - 1 + n) % n + 1]
  local next_i = indices[(i) % n + 1]
  local a = poly[prev_i] --[[:! Point]]
  local b = poly[curr_i] --[[:! Point]]
  local c = poly[next_i] --[[:! Point]]

  -- The ear triangle must be CCW (positive area)
  if cross(a, b, c) <= 0 then return false end

  -- No other polygon vertex inside the triangle
  for j = 1, n do
    local idx = indices[j]
    if idx ~= prev_i and idx ~= curr_i and idx ~= next_i then
      local p = poly[idx] --[[:! Point]]
      -- Point in triangle test via cross products
      if cross(a, b, p) >= 0 and cross(b, c, p) >= 0 and cross(c, a, p) >= 0 then
        return false
      end
    end
  end
  return true
end

--: ({ [integer]: Point }) -> { [integer]: { a: Point, b: Point, c: Point } }
function M.triangulate(polygon)
  local n = #polygon
  if n < 3 then return {} end

  -- Work with indices
  local indices = {} --: { [integer]: integer }
  for i = 1, n do indices[i] = i end

  -- Ensure CCW orientation
  local area_signed = 0 --: number
  for i = 1, n do
    local a = polygon[i] --[[:! Point]]
    local b = polygon[i % n + 1] --[[:! Point]]
    area_signed = area_signed + (a.x * b.y - b.x * a.y)
  end
  if area_signed < 0 then
    -- Reverse to make CCW
    local rev = {}
    for i = 1, n do rev[i] = indices[n - i + 1] end
    indices = rev
  end

  local triangles = {}
  local remaining = n
  local max_iter = remaining * remaining + remaining + 1  -- prevent infinite loop

  local iter = 0
  while remaining > 3 do
    iter = iter + 1
    if iter > max_iter then break end  -- malformed polygon guard

    local found_ear = false
    for i = 1, remaining do
      if is_ear(polygon, indices, i, remaining) then
        local prev_i = indices[(i - 2 + remaining) % remaining + 1]
        local curr_i = indices[(i - 1 + remaining) % remaining + 1]
        local next_i = indices[(i) % remaining + 1]
        triangles[#triangles + 1] = {
          a = { x = polygon[prev_i].x, y = polygon[prev_i].y },
          b = { x = polygon[curr_i].x, y = polygon[curr_i].y },
          c = { x = polygon[next_i].x, y = polygon[next_i].y },
        }
        -- Remove the ear tip
        table.remove(indices, i)
        remaining = remaining - 1
        found_ear = true
        break
      end
    end

    if not found_ear then break end  -- not a simple polygon or degenerate
  end

  -- Last triangle
  if remaining == 3 then
    triangles[#triangles + 1] = {
      a = { x = polygon[indices[1]].x, y = polygon[indices[1]].y },
      b = { x = polygon[indices[2]].x, y = polygon[indices[2]].y },
      c = { x = polygon[indices[3]].x, y = polygon[indices[3]].y },
    }
  end

  return triangles
end

return M
