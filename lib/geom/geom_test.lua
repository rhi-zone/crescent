if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local geom = require("lib.geom")

local eps = 1e-9

local function near(a, b, e)
  e = e or eps
  return math.abs(a - b) <= e
end

local function point_near(p, x, y, e)
  e = e or eps
  return near(p.x, x, e) and near(p.y, y, e)
end

-- ---------------------------------------------------------------------------
-- Angle utilities
-- ---------------------------------------------------------------------------
T.describe("angle utilities", function()
  T.it("deg_to_rad / rad_to_deg round-trip", function()
    T.ok(near(geom.deg_to_rad(180), math.pi))
    T.ok(near(geom.deg_to_rad(90), math.pi / 2))
    T.ok(near(geom.rad_to_deg(math.pi), 180))
    T.ok(near(geom.rad_to_deg(0), 0))
  end)

  T.it("angle_normalize clamps to [0, 2π)", function()
    T.ok(near(geom.angle_normalize(0), 0))
    T.ok(near(geom.angle_normalize(2 * math.pi), 0))
    T.ok(near(geom.angle_normalize(-math.pi / 2), 3 * math.pi / 2, 1e-9))
    T.ok(near(geom.angle_normalize(3 * math.pi), math.pi, 1e-9))
  end)

  T.it("angle_diff shortest path", function()
    T.ok(near(geom.angle_diff(0, math.pi / 2), math.pi / 2))
    T.ok(near(geom.angle_diff(0, -math.pi / 2), -math.pi / 2))
    -- Wraps around: 350° → 10° = +20°
    local a = geom.deg_to_rad(350)
    local b = geom.deg_to_rad(10)
    T.ok(near(geom.angle_diff(a, b), geom.deg_to_rad(20), 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
-- 2D Vectors
-- ---------------------------------------------------------------------------
T.describe("2D vectors", function()
  T.it("point and vec constructors", function()
    local p = geom.point(3, 4)
    T.eq(p.x, 3)
    T.eq(p.y, 4)
    local v = geom.vec(1, 2)
    T.eq(v.x, 1)
    T.eq(v.y, 2)
  end)

  T.it("vec_add / vec_sub / vec_scale", function()
    local a = geom.vec(1, 2)
    local b = geom.vec(3, 5)
    local s = geom.vec_add(a, b)
    T.eq(s.x, 4) T.eq(s.y, 7)
    local d = geom.vec_sub(b, a)
    T.eq(d.x, 2) T.eq(d.y, 3)
    local sc = geom.vec_scale(a, 3)
    T.eq(sc.x, 3) T.eq(sc.y, 6)
  end)

  T.it("vec_dot", function()
    local a = geom.vec(1, 0)
    local b = geom.vec(0, 1)
    T.eq(geom.vec_dot(a, b), 0)
    T.eq(geom.vec_dot(geom.vec(3, 4), geom.vec(2, -1)), 2)
  end)

  T.it("vec_cross (2D scalar)", function()
    local a = geom.vec(1, 0)
    local b = geom.vec(0, 1)
    T.eq(geom.vec_cross(a, b), 1)
    T.eq(geom.vec_cross(b, a), -1)
    T.eq(geom.vec_cross(geom.vec(2, 0), geom.vec(0, 3)), 6)
  end)

  T.it("vec_len", function()
    T.ok(near(geom.vec_len(geom.vec(3, 4)), 5))
    T.ok(near(geom.vec_len(geom.vec(0, 0)), 0))
    T.ok(near(geom.vec_len(geom.vec(1, 0)), 1))
  end)

  T.it("vec_normalize", function()
    local n = geom.vec_normalize(geom.vec(3, 4))
    T.ok(near(n.x, 0.6))
    T.ok(near(n.y, 0.8))
    T.ok(near(geom.vec_len(n), 1))
    -- zero vector returns zero
    local z = geom.vec_normalize(geom.vec(0, 0))
    T.eq(z.x, 0) T.eq(z.y, 0)
  end)

  T.it("vec_angle", function()
    T.ok(near(geom.vec_angle(geom.vec(1, 0)), 0))
    T.ok(near(geom.vec_angle(geom.vec(0, 1)), math.pi / 2))
    T.ok(near(geom.vec_angle(geom.vec(-1, 0)), math.pi))
  end)

  T.it("vec_rotate", function()
    local v = geom.vec(1, 0)
    local r = geom.vec_rotate(v, math.pi / 2)
    T.ok(near(r.x, 0, 1e-9))
    T.ok(near(r.y, 1, 1e-9))
    local r2 = geom.vec_rotate(v, math.pi)
    T.ok(near(r2.x, -1, 1e-9))
    T.ok(near(r2.y, 0, 1e-9))
  end)

  T.it("vec_perp", function()
    local p = geom.vec_perp(geom.vec(1, 0))
    T.eq(p.x, 0) T.eq(p.y, 1)
    local p2 = geom.vec_perp(geom.vec(3, 4))
    T.eq(p2.x, -4) T.eq(p2.y, 3)
    -- perp is perpendicular: dot = 0
    local v = geom.vec(2, 5)
    T.ok(near(geom.vec_dot(v, geom.vec_perp(v)), 0))
  end)
end)

-- ---------------------------------------------------------------------------
-- Distance functions
-- ---------------------------------------------------------------------------
T.describe("distance", function()
  T.it("distance and distance_sq", function()
    local a = geom.point(0, 0)
    local b = geom.point(3, 4)
    T.ok(near(geom.distance(a, b), 5))
    T.ok(near(geom.distance_sq(a, b), 25))
    T.ok(near(geom.distance(a, a), 0))
  end)

  T.it("midpoint", function()
    local m = geom.midpoint(geom.point(0, 0), geom.point(4, 6))
    T.eq(m.x, 2) T.eq(m.y, 3)
  end)

  T.it("lerp_point", function()
    local a = geom.point(0, 0)
    local b = geom.point(10, 20)
    local m = geom.lerp_point(a, b, 0.5)
    T.eq(m.x, 5) T.eq(m.y, 10)
    local start = geom.lerp_point(a, b, 0)
    T.eq(start.x, 0) T.eq(start.y, 0)
    local finish = geom.lerp_point(a, b, 1)
    T.eq(finish.x, 10) T.eq(finish.y, 20)
  end)
end)

-- ---------------------------------------------------------------------------
-- Orientation
-- ---------------------------------------------------------------------------
T.describe("orientation", function()
  T.it("CCW / CW / collinear", function()
    local a = geom.point(0, 0)
    local b = geom.point(1, 0)
    local c = geom.point(0, 1)
    T.eq(geom.orientation(a, b, c), 1)    -- CCW
    T.eq(geom.orientation(a, c, b), -1)   -- CW
    local d = geom.point(2, 0)
    T.eq(geom.orientation(a, b, d), 0)    -- collinear
  end)
end)

-- ---------------------------------------------------------------------------
-- Segments
-- ---------------------------------------------------------------------------
T.describe("segments", function()
  T.it("segment_length and midpoint", function()
    local seg = geom.segment(geom.point(0, 0), geom.point(6, 8))
    T.ok(near(geom.segment_length(seg), 10))
    local m = geom.segment_midpoint(seg)
    T.eq(m.x, 3) T.eq(m.y, 4)
  end)

  T.it("closest_point_on_segment — interior", function()
    local seg = geom.segment(geom.point(0, 0), geom.point(10, 0))
    local cp = geom.closest_point_on_segment(geom.point(5, 3), seg)
    T.ok(near(cp.x, 5)) T.ok(near(cp.y, 0))
  end)

  T.it("closest_point_on_segment — clamp to endpoints", function()
    local seg = geom.segment(geom.point(0, 0), geom.point(10, 0))
    local cp1 = geom.closest_point_on_segment(geom.point(-3, 0), seg)
    T.ok(near(cp1.x, 0)) T.ok(near(cp1.y, 0))
    local cp2 = geom.closest_point_on_segment(geom.point(15, 0), seg)
    T.ok(near(cp2.x, 10)) T.ok(near(cp2.y, 0))
  end)

  T.it("point_on_segment", function()
    local seg = geom.segment(geom.point(0, 0), geom.point(4, 0))
    T.ok(geom.point_on_segment(geom.point(2, 0), seg))
    T.ok(geom.point_on_segment(geom.point(0, 0), seg))    -- endpoint
    T.ok(geom.point_on_segment(geom.point(4, 0), seg))    -- endpoint
    T.fail(geom.point_on_segment(geom.point(5, 0), seg))  -- outside
    T.fail(geom.point_on_segment(geom.point(2, 1), seg))  -- off line
  end)

  T.it("segment_intersects — crossing", function()
    local s1 = geom.segment(geom.point(-1, 0), geom.point(1, 0))
    local s2 = geom.segment(geom.point(0, -1), geom.point(0, 1))
    T.ok(geom.segment_intersects(s1, s2))
  end)

  T.it("segment_intersects — parallel, no overlap", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(2, 0))
    local s2 = geom.segment(geom.point(0, 1), geom.point(2, 1))
    T.fail(geom.segment_intersects(s1, s2))
  end)

  T.it("segment_intersects — collinear, no overlap", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(1, 0))
    local s2 = geom.segment(geom.point(2, 0), geom.point(3, 0))
    T.fail(geom.segment_intersects(s1, s2))
  end)

  T.it("segment_intersects — T-intersection at endpoint", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(2, 0))
    local s2 = geom.segment(geom.point(1, 0), geom.point(1, 2))
    T.ok(geom.segment_intersects(s1, s2))
  end)

  T.it("segment_intersects — non-crossing (miss)", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(1, 1))
    local s2 = geom.segment(geom.point(2, 0), geom.point(3, 1))
    T.fail(geom.segment_intersects(s1, s2))
  end)

  T.it("segment_intersection returns correct point", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(2, 2))
    local s2 = geom.segment(geom.point(0, 2), geom.point(2, 0))
    local pt = geom.segment_intersection(s1, s2)
    T.ok(pt ~= nil)
    T.ok(near(pt.x, 1, 1e-9))
    T.ok(near(pt.y, 1, 1e-9))
  end)

  T.it("segment_intersection returns nil for parallel", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(1, 0))
    local s2 = geom.segment(geom.point(0, 1), geom.point(1, 1))
    T.eq(geom.segment_intersection(s1, s2), nil)
  end)

  T.it("segment_intersection returns nil for non-crossing", function()
    local s1 = geom.segment(geom.point(0, 0), geom.point(1, 0))
    local s2 = geom.segment(geom.point(2, -1), geom.point(2, 1))
    T.eq(geom.segment_intersection(s1, s2), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Infinite lines
-- ---------------------------------------------------------------------------
T.describe("infinite lines", function()
  T.it("line_from_points — horizontal", function()
    local l = geom.line_from_points(geom.point(0, 3), geom.point(5, 3))
    -- y=3 plane: distance from point on the line should be 0
    local d = geom.line_distance(l, geom.point(0, 3))
    T.ok(near(d, 0))
    -- Points 2 units above and below have |distance| = 2 with opposite signs
    local d2 = geom.line_distance(l, geom.point(0, 5))
    local d3 = geom.line_distance(l, geom.point(0, 1))
    T.ok(near(math.abs(d2), 2))
    T.ok(near(math.abs(d3), 2))
    T.ok(d2 * d3 < 0)  -- opposite sides → opposite signs
  end)

  T.it("line_distance signed distance (positive / negative sides)", function()
    local p1 = geom.point(0, 0)
    local p2 = geom.point(1, 0)
    local l = geom.line_from_points(p1, p2)
    -- Points above and below the x-axis
    local above = geom.line_distance(l, geom.point(0, 3))
    local below = geom.line_distance(l, geom.point(0, -3))
    T.ok(near(math.abs(above), 3))
    T.ok(near(math.abs(below), 3))
    -- Opposite signs
    T.ok(above * below < 0)
  end)

  T.it("line_from_point_dir", function()
    local l = geom.line_from_point_dir(geom.point(0, 0), geom.vec(1, 0))
    -- horizontal line through origin → y=0
    T.ok(near(geom.line_distance(l, geom.point(5, 0)), 0))
    T.ok(near(math.abs(geom.line_distance(l, geom.point(0, 2))), 2))
  end)

  T.it("lines_intersection", function()
    local l1 = geom.line_from_points(geom.point(0, 0), geom.point(1, 1))
    local l2 = geom.line_from_points(geom.point(0, 1), geom.point(1, 0))
    local pt = geom.lines_intersection(l1, l2)
    T.ok(pt ~= nil)
    T.ok(near(pt.x, 0.5, 1e-9))
    T.ok(near(pt.y, 0.5, 1e-9))
  end)

  T.it("lines_intersection — parallel returns nil", function()
    local l1 = geom.line_from_points(geom.point(0, 0), geom.point(1, 0))
    local l2 = geom.line_from_points(geom.point(0, 1), geom.point(1, 1))
    T.eq(geom.lines_intersection(l1, l2), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Circles
-- ---------------------------------------------------------------------------
T.describe("circles", function()
  T.it("circle_contains", function()
    local c = geom.circle(0, 0, 5)
    T.ok(geom.circle_contains(c, geom.point(0, 0)))    -- center
    T.ok(geom.circle_contains(c, geom.point(3, 4)))    -- on boundary (25 == 25)
    T.ok(geom.circle_contains(c, geom.point(1, 1)))    -- interior
    T.fail(geom.circle_contains(c, geom.point(4, 4)))  -- outside (32 > 25)
  end)

  T.it("circles_intersect", function()
    local c1 = geom.circle(0, 0, 3)
    local c2 = geom.circle(4, 0, 2)  -- dist=4, r1+r2=5, |r1-r2|=1 → intersect
    T.ok(geom.circles_intersect(c1, c2))
    local c3 = geom.circle(10, 0, 1)  -- too far
    T.fail(geom.circles_intersect(c1, c3))
    local c4 = geom.circle(1, 0, 1)   -- fully inside c1
    T.fail(geom.circles_intersect(c1, c4))
  end)

  T.it("circle_segment_intersect", function()
    local c = geom.circle(0, 0, 2)
    -- Segment through center
    local s1 = geom.segment(geom.point(-5, 0), geom.point(5, 0))
    T.ok(geom.circle_segment_intersect(c, s1))
    -- Segment entirely outside
    local s2 = geom.segment(geom.point(3, 3), geom.point(5, 5))
    T.fail(geom.circle_segment_intersect(c, s2))
    -- Segment tangent (closest point exactly on boundary)
    local s3 = geom.segment(geom.point(-5, 2), geom.point(5, 2))
    T.ok(geom.circle_segment_intersect(c, s3))  -- r=2, closest dist=2
  end)
end)

-- ---------------------------------------------------------------------------
-- AABB
-- ---------------------------------------------------------------------------
T.describe("AABB", function()
  T.it("aabb_contains_point", function()
    local a = geom.aabb(0, 0, 4, 4)
    T.ok(geom.aabb_contains_point(a, geom.point(2, 2)))
    T.ok(geom.aabb_contains_point(a, geom.point(0, 0)))  -- corner
    T.ok(geom.aabb_contains_point(a, geom.point(4, 4)))  -- corner
    T.fail(geom.aabb_contains_point(a, geom.point(5, 2)))
    T.fail(geom.aabb_contains_point(a, geom.point(-1, 2)))
  end)

  T.it("aabb_intersects", function()
    local a1 = geom.aabb(0, 0, 4, 4)
    local a2 = geom.aabb(2, 2, 4, 4)
    T.ok(geom.aabb_intersects(a1, a2))
    local a3 = geom.aabb(5, 5, 2, 2)
    T.fail(geom.aabb_intersects(a1, a3))
    -- Touching edge
    local a4 = geom.aabb(4, 0, 2, 4)
    T.ok(geom.aabb_intersects(a1, a4))
  end)

  T.it("aabb_union", function()
    local a1 = geom.aabb(0, 0, 2, 2)
    local a2 = geom.aabb(1, 1, 4, 4)
    local u = geom.aabb_union(a1, a2)
    T.eq(u.x, 0) T.eq(u.y, 0)
    T.eq(u.w, 5) T.eq(u.h, 5)
  end)

  T.it("aabb_expand", function()
    local a = geom.aabb(2, 2, 4, 4)
    local e = geom.aabb_expand(a, 1)
    T.eq(e.x, 1) T.eq(e.y, 1)
    T.eq(e.w, 6) T.eq(e.h, 6)
  end)

  T.it("aabb_from_points", function()
    local pts = {
      geom.point(1, 5),
      geom.point(3, 2),
      geom.point(-1, 4),
      geom.point(2, 7),
    }
    local a = geom.aabb_from_points(pts)
    T.eq(a.x, -1) T.eq(a.y, 2)
    T.eq(a.w, 4)  T.eq(a.h, 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- Triangles
-- ---------------------------------------------------------------------------
T.describe("triangles", function()
  T.it("triangle_area positive (CCW)", function()
    local a = geom.point(0, 0)
    local b = geom.point(4, 0)
    local c = geom.point(0, 3)
    T.ok(near(geom.triangle_area(a, b, c), 6))
  end)

  T.it("triangle_area negative (CW)", function()
    local a = geom.point(0, 0)
    local b = geom.point(0, 3)
    local c = geom.point(4, 0)
    T.ok(near(geom.triangle_area(a, b, c), -6))
  end)

  T.it("triangle_contains — inside", function()
    local a = geom.point(0, 0)
    local b = geom.point(4, 0)
    local c = geom.point(0, 4)
    T.ok(geom.triangle_contains(a, b, c, geom.point(1, 1)))
  end)

  T.it("triangle_contains — outside", function()
    local a = geom.point(0, 0)
    local b = geom.point(4, 0)
    local c = geom.point(0, 4)
    T.fail(geom.triangle_contains(a, b, c, geom.point(3, 3)))
  end)

  T.it("triangle_contains — on edge counts as inside", function()
    local a = geom.point(0, 0)
    local b = geom.point(4, 0)
    local c = geom.point(0, 4)
    -- On the hypotenuse edge: cross products = 0 → passes has_neg/has_pos test
    T.ok(geom.triangle_contains(a, b, c, geom.point(2, 2)))
  end)

  T.it("triangle_centroid", function()
    local a = geom.point(0, 0)
    local b = geom.point(6, 0)
    local c = geom.point(0, 6)
    local ct = geom.triangle_centroid(a, b, c)
    T.ok(near(ct.x, 2)) T.ok(near(ct.y, 2))
  end)

  T.it("triangle_circumcircle — equilateral", function()
    -- Equilateral triangle centered at (0,0)
    local r = 2
    local a = geom.point(r * math.cos(math.pi / 2),       r * math.sin(math.pi / 2))
    local b = geom.point(r * math.cos(math.pi / 2 + 2*math.pi/3), r * math.sin(math.pi / 2 + 2*math.pi/3))
    local c = geom.point(r * math.cos(math.pi / 2 - 2*math.pi/3), r * math.sin(math.pi / 2 - 2*math.pi/3))
    local cc = geom.triangle_circumcircle(a, b, c)
    T.ok(cc ~= nil)
    T.ok(near(cc.x, 0, 1e-9))
    T.ok(near(cc.y, 0, 1e-9))
    T.ok(near(cc.r, r, 1e-9))
  end)

  T.it("triangle_circumcircle — right triangle", function()
    local a = geom.point(0, 0)
    local b = geom.point(4, 0)
    local c = geom.point(0, 3)
    local cc = geom.triangle_circumcircle(a, b, c)
    T.ok(cc ~= nil)
    -- All vertices should be on the circumcircle
    T.ok(near(geom.distance(cc, a), cc.r, 1e-9))
    T.ok(near(geom.distance(cc, b), cc.r, 1e-9))
    T.ok(near(geom.distance(cc, c), cc.r, 1e-9))
  end)

  T.it("triangle_circumcircle — degenerate collinear returns nil", function()
    local a = geom.point(0, 0)
    local b = geom.point(1, 0)
    local c = geom.point(2, 0)
    T.eq(geom.triangle_circumcircle(a, b, c), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Polygons
-- ---------------------------------------------------------------------------
T.describe("polygons", function()
  -- Unit square (CCW)
  local sq = {
    geom.point(0, 0),
    geom.point(1, 0),
    geom.point(1, 1),
    geom.point(0, 1),
  }

  T.it("polygon_area — square CCW", function()
    T.ok(near(geom.polygon_area(sq), 1))
  end)

  T.it("polygon_area — square CW (negative)", function()
    local cw = { sq[4], sq[3], sq[2], sq[1] }
    T.ok(near(geom.polygon_area(cw), -1))
  end)

  T.it("polygon_area — triangle matches triangle_area", function()
    local pts = { geom.point(0,0), geom.point(4,0), geom.point(0,3) }
    T.ok(near(geom.polygon_area(pts), geom.triangle_area(pts[1], pts[2], pts[3])))
  end)

  T.it("polygon_centroid — square", function()
    local ct = geom.polygon_centroid(sq)
    T.ok(near(ct.x, 0.5)) T.ok(near(ct.y, 0.5))
  end)

  T.it("polygon_is_convex — square is convex", function()
    T.ok(geom.polygon_is_convex(sq))
  end)

  T.it("polygon_is_convex — concave polygon", function()
    -- L-shape (concave)
    local l_shape = {
      geom.point(0, 0), geom.point(2, 0), geom.point(2, 1),
      geom.point(1, 1), geom.point(1, 2), geom.point(0, 2),
    }
    T.fail(geom.polygon_is_convex(l_shape))
  end)

  T.it("polygon_contains — point inside square", function()
    T.ok(geom.polygon_contains(sq, geom.point(0.5, 0.5)))
  end)

  T.it("polygon_contains — point outside square", function()
    T.fail(geom.polygon_contains(sq, geom.point(2, 2)))
    T.fail(geom.polygon_contains(sq, geom.point(-0.1, 0.5)))
  end)

  T.it("polygon_contains — concave polygon (point in pocket)", function()
    -- "C" shape — concave
    local c_shape = {
      geom.point(0, 0), geom.point(3, 0), geom.point(3, 1),
      geom.point(1, 1), geom.point(1, 2), geom.point(3, 2),
      geom.point(3, 3), geom.point(0, 3),
    }
    -- Point in the notch (outside the polygon)
    T.fail(geom.polygon_contains(c_shape, geom.point(2, 1.5)))
    -- Point clearly inside
    T.ok(geom.polygon_contains(c_shape, geom.point(0.5, 1.5)))
  end)

  T.it("convex_hull — simple square", function()
    local pts = {
      geom.point(0, 0), geom.point(1, 0),
      geom.point(1, 1), geom.point(0, 1),
      geom.point(0.5, 0.5),  -- interior point should not be in hull
    }
    local hull = geom.convex_hull(pts)
    T.eq(#hull, 4)
    T.ok(geom.polygon_is_convex(hull))
  end)

  T.it("convex_hull — triangle", function()
    local pts = { geom.point(0, 0), geom.point(4, 0), geom.point(2, 3) }
    local hull = geom.convex_hull(pts)
    T.eq(#hull, 3)
    T.ok(geom.polygon_is_convex(hull))
  end)

  T.it("convex_hull — result is convex (many points)", function()
    local pts = {}
    for i = 1, 20 do
      local angle = (i - 1) * 2 * math.pi / 10
      pts[i] = geom.point(math.cos(angle), math.sin(angle))
    end
    -- Add some interior points
    for i = 21, 30 do
      pts[i] = geom.point((i-25)*0.05, (i-25)*0.05)
    end
    local hull = geom.convex_hull(pts)
    T.ok(#hull >= 3)
    T.ok(geom.polygon_is_convex(hull))
  end)

  T.it("convex_hull — single point", function()
    local hull = geom.convex_hull({ geom.point(1, 2) })
    T.eq(#hull, 1)
  end)

  T.it("convex_hull — empty", function()
    local hull = geom.convex_hull({})
    T.eq(#hull, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 3D Vectors
-- ---------------------------------------------------------------------------
T.describe("3D vectors", function()
  T.it("vec3 constructor", function()
    local v = geom.vec3(1, 2, 3)
    T.eq(v.x, 1) T.eq(v.y, 2) T.eq(v.z, 3)
  end)

  T.it("vec3_add / vec3_sub / vec3_scale", function()
    local a = geom.vec3(1, 2, 3)
    local b = geom.vec3(4, 5, 6)
    local s = geom.vec3_add(a, b)
    T.eq(s.x, 5) T.eq(s.y, 7) T.eq(s.z, 9)
    local d = geom.vec3_sub(b, a)
    T.eq(d.x, 3) T.eq(d.y, 3) T.eq(d.z, 3)
    local sc = geom.vec3_scale(a, 2)
    T.eq(sc.x, 2) T.eq(sc.y, 4) T.eq(sc.z, 6)
  end)

  T.it("vec3_dot", function()
    local a = geom.vec3(1, 0, 0)
    local b = geom.vec3(0, 1, 0)
    T.eq(geom.vec3_dot(a, b), 0)
    T.eq(geom.vec3_dot(a, a), 1)
    T.eq(geom.vec3_dot(geom.vec3(1, 2, 3), geom.vec3(4, 5, 6)), 32)
  end)

  T.it("vec3_cross", function()
    local x = geom.vec3(1, 0, 0)
    local y = geom.vec3(0, 1, 0)
    local z = geom.vec3_cross(x, y)
    T.ok(near(z.x, 0)) T.ok(near(z.y, 0)) T.ok(near(z.z, 1))
    -- Anti-commutative
    local nz = geom.vec3_cross(y, x)
    T.ok(near(nz.z, -1))
    -- Cross product is perpendicular to both inputs
    local a = geom.vec3(1, 2, 3)
    local b = geom.vec3(4, 5, 6)
    local c = geom.vec3_cross(a, b)
    T.ok(near(geom.vec3_dot(a, c), 0, 1e-9))
    T.ok(near(geom.vec3_dot(b, c), 0, 1e-9))
  end)

  T.it("vec3_len", function()
    T.ok(near(geom.vec3_len(geom.vec3(1, 0, 0)), 1))
    T.ok(near(geom.vec3_len(geom.vec3(1, 2, 2)), 3))
    T.ok(near(geom.vec3_len(geom.vec3(0, 0, 0)), 0))
  end)

  T.it("vec3_normalize", function()
    local n = geom.vec3_normalize(geom.vec3(1, 2, 2))
    T.ok(near(geom.vec3_len(n), 1, 1e-9))
    T.ok(near(n.x, 1/3, 1e-9))
    -- zero vector
    local z = geom.vec3_normalize(geom.vec3(0, 0, 0))
    T.eq(z.x, 0) T.eq(z.y, 0) T.eq(z.z, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Planes
-- ---------------------------------------------------------------------------
T.describe("planes", function()
  T.it("plane_from_normal_point — XY plane", function()
    local normal = geom.vec3(0, 0, 1)
    local origin = geom.vec3(0, 0, 0)
    local pl = geom.plane_from_normal_point(normal, origin)
    -- z=0 plane
    T.ok(near(geom.plane_distance(pl, geom.vec3(5, 3, 0)), 0))
    T.ok(near(geom.plane_distance(pl, geom.vec3(0, 0, 4)), 4))
    T.ok(near(geom.plane_distance(pl, geom.vec3(0, 0, -2)), -2))
  end)

  T.it("plane_distance sign (above and below)", function()
    local normal = geom.vec3(0, 1, 0)  -- Y normal
    local pt     = geom.vec3(0, 3, 0)
    local pl = geom.plane_from_normal_point(normal, pt)
    local above = geom.plane_distance(pl, geom.vec3(0, 6, 0))
    local below = geom.plane_distance(pl, geom.vec3(0, 0, 0))
    T.ok(near(above, 3, 1e-9))
    T.ok(near(below, -3, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
-- Tier marker
-- ---------------------------------------------------------------------------
T.it("_tier is pure", function()
  T.eq(geom._tier, "pure")
end)
