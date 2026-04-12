if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local cg = require("lib.convex_hull")

local function approx(a, b, eps)
  eps = eps or 1e-9
  return math.abs(a - b) < eps
end

local function approx_pt(a, b, eps)
  return approx(a.x, b.x, eps) and approx(a.y, b.y, eps)
end

-- ========================
-- CONVEX HULL — Graham scan
-- ========================

T.describe("convex_hull (Graham scan)", function()
  T.it("square hull contains interior points, rejects exterior", function()
    local pts = {
      {x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1},
      {x=0.5,y=0.5},  -- interior
    }
    local hull = cg.convex_hull(pts)
    T.ok(#hull == 4, "square hull has 4 vertices, got " .. #hull)
    T.ok(cg.point_in_hull(hull, {x=0.5,y=0.5}), "interior point is in hull")
    T.ok(not cg.point_in_hull(hull, {x=2,y=2}), "exterior point not in hull")
  end)

  T.it("collinear points: hull excludes interior collinear points", function()
    -- All on y=0 from 0..4, plus some above
    local pts = {
      {x=0,y=0},{x=1,y=0},{x=2,y=0},{x=3,y=0},{x=4,y=0},
      {x=0,y=2},{x=4,y=2},
    }
    local hull = cg.convex_hull(pts)
    -- Hull should be the rectangle corners: (0,0),(4,0),(4,2),(0,2)
    T.ok(#hull == 4, "collinear hull has 4 vertices, got " .. #hull)
  end)

  T.it("empty and single-point inputs", function()
    T.ok(#cg.convex_hull({}) == 0, "empty input gives empty hull")
    local h1 = cg.convex_hull({{x=3,y=5}})
    T.ok(#h1 == 1, "single point hull has 1 vertex")
  end)
end)

-- ========================
-- QUICKHULL
-- ========================

T.describe("quickhull", function()
  T.it("quickhull agrees with Graham scan on random-ish points", function()
    local pts = {
      {x=0,y=0},{x=10,y=0},{x=10,y=10},{x=0,y=10},
      {x=3,y=3},{x=7,y=5},{x=2,y=8},{x=9,y=1},{x=5,y=5},
    }
    local hull_g = cg.convex_hull(pts)
    local hull_q = cg.quickhull(pts)
    -- Both should have the same number of hull points and same bounding area
    T.eq(#hull_g, #hull_q, "hull vertex count matches")
    local area_g = cg.polygon_area(hull_g)
    local area_q = cg.polygon_area(hull_q)
    T.ok(approx(area_g, area_q, 1e-6), "hull areas match")
  end)

  T.it("quickhull handles triangle input", function()
    local pts = {{x=0,y=0},{x=4,y=0},{x=2,y=3}}
    local hull = cg.quickhull(pts)
    T.ok(#hull == 3, "triangle hull has 3 points, got " .. #hull)
  end)
end)

-- ========================
-- POLYGON AREA
-- ========================

T.describe("polygon_area", function()
  T.it("unit square area = 1", function()
    local sq = {{x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1}}
    T.ok(approx(cg.polygon_area(sq), 1.0), "unit square area is 1")
  end)

  T.it("right triangle with base=1, height=1 area = 0.5", function()
    local tri = {{x=0,y=0},{x=1,y=0},{x=0,y=1}}
    T.ok(approx(cg.polygon_area(tri), 0.5), "triangle area is 0.5")
  end)

  T.it("2x3 rectangle area = 6", function()
    local rect = {{x=0,y=0},{x=2,y=0},{x=2,y=3},{x=0,y=3}}
    T.ok(approx(cg.polygon_area(rect), 6.0), "2x3 rectangle area is 6")
  end)
end)

-- ========================
-- POLYGON CENTROID
-- ========================

T.describe("polygon_centroid", function()
  T.it("unit square centroid is (0.5, 0.5)", function()
    local sq = {{x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1}}
    local c = cg.polygon_centroid(sq)
    T.ok(approx(c.x, 0.5) and approx(c.y, 0.5), "square centroid at (0.5,0.5)")
  end)

  T.it("right triangle centroid is (1/3, 1/3)", function()
    local tri = {{x=0,y=0},{x=1,y=0},{x=0,y=1}}
    local c = cg.polygon_centroid(tri)
    T.ok(approx(c.x, 1/3, 1e-6) and approx(c.y, 1/3, 1e-6),
      "triangle centroid at (1/3,1/3), got (" .. c.x .. "," .. c.y .. ")")
  end)
end)

-- ========================
-- POLYGON PERIMETER
-- ========================

T.describe("polygon_perimeter", function()
  T.it("unit square perimeter = 4", function()
    local sq = {{x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1}}
    T.ok(approx(cg.polygon_perimeter(sq), 4.0), "unit square perimeter is 4")
  end)
end)

-- ========================
-- IS CONVEX
-- ========================

T.describe("is_convex", function()
  T.it("unit square is convex", function()
    local sq = {{x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1}}
    T.ok(cg.is_convex(sq), "square is convex")
  end)

  T.it("L-shape is not convex", function()
    -- L-shape: concave polygon
    local l = {
      {x=0,y=0},{x=2,y=0},{x=2,y=1},
      {x=1,y=1},{x=1,y=2},{x=0,y=2},
    }
    T.ok(not cg.is_convex(l), "L-shape is not convex")
  end)

  T.it("equilateral-ish triangle is convex", function()
    local tri = {{x=0,y=0},{x=4,y=0},{x=2,y=3}}
    T.ok(cg.is_convex(tri), "triangle is convex")
  end)
end)

-- ========================
-- SEGMENT INTERSECTION
-- ========================

T.describe("segments_intersect", function()
  T.it("crossing segments intersect", function()
    local a1,a2 = {x=0,y=0},{x=2,y=2}
    local b1,b2 = {x=0,y=2},{x=2,y=0}
    T.ok(cg.segments_intersect(a1,a2,b1,b2), "crossing X segments intersect")
  end)

  T.it("parallel segments do not intersect", function()
    local a1,a2 = {x=0,y=0},{x=2,y=0}
    local b1,b2 = {x=0,y=1},{x=2,y=1}
    T.ok(not cg.segments_intersect(a1,a2,b1,b2), "parallel segments don't intersect")
  end)

  T.it("T-junction: endpoint on segment is an intersection", function()
    local a1,a2 = {x=0,y=1},{x=2,y=1}
    local b1,b2 = {x=1,y=0},{x=1,y=1}
    T.ok(cg.segments_intersect(a1,a2,b1,b2), "T-junction intersects")
  end)

  T.it("non-intersecting segments that share no region", function()
    local a1,a2 = {x=0,y=0},{x=1,y=0}
    local b1,b2 = {x=3,y=0},{x=4,y=0}
    T.ok(not cg.segments_intersect(a1,a2,b1,b2), "disjoint collinear segments don't intersect")
  end)
end)

-- ========================
-- SEGMENT INTERSECTION POINT
-- ========================

T.describe("segment_intersection", function()
  T.it("X intersection at (1,1)", function()
    local a1,a2 = {x=0,y=0},{x=2,y=2}
    local b1,b2 = {x=0,y=2},{x=2,y=0}
    local pt = cg.segment_intersection(a1,a2,b1,b2)
    T.ok(pt ~= nil, "intersection point exists")
    T.ok(approx_pt(pt, {x=1,y=1}, 1e-6), "intersection at (1,1), got (" .. pt.x .. "," .. pt.y .. ")")
  end)

  T.it("non-intersecting segments return nil", function()
    local a1,a2 = {x=0,y=0},{x=1,y=0}
    local b1,b2 = {x=3,y=0},{x=4,y=0}
    T.ok(cg.segment_intersection(a1,a2,b1,b2) == nil, "no intersection returns nil")
  end)
end)

-- ========================
-- POINT TO SEGMENT DISTANCE
-- ========================

T.describe("point_to_segment_dist", function()
  T.it("point above midpoint of horizontal segment", function()
    local p = {x=1,y=1}
    local a,b = {x=0,y=0},{x=2,y=0}
    T.ok(approx(cg.point_to_segment_dist(p,a,b), 1.0), "distance to midpoint is 1")
  end)

  T.it("point beyond endpoint", function()
    local p = {x=3,y=0}
    local a,b = {x=0,y=0},{x=2,y=0}
    T.ok(approx(cg.point_to_segment_dist(p,a,b), 1.0), "distance to endpoint b is 1")
  end)
end)

-- ========================
-- DOUGLAS-PEUCKER
-- ========================

T.describe("douglas_peucker", function()
  T.it("reduces point count while preserving endpoints", function()
    -- A slightly bumpy line along y=0
    local pts = {}
    for i = 0, 20 do
      pts[#pts+1] = {x=i, y=(i==10 and 0.01 or 0)}
    end
    local simplified = cg.douglas_peucker(pts, 0.05)
    T.ok(#simplified < #pts, "point count reduced")
    T.ok(approx_pt(simplified[1], pts[1], 1e-9), "start point preserved")
    T.ok(approx_pt(simplified[#simplified], pts[#pts], 1e-9), "end point preserved")
  end)

  T.it("preserves key shape vertices", function()
    -- A zigzag: large deviations should be kept
    local pts = {
      {x=0,y=0},{x=1,y=5},{x=2,y=0},{x=3,y=5},{x=4,y=0}
    }
    local simplified = cg.douglas_peucker(pts, 0.1)
    T.eq(#simplified, 5, "zigzag: all 5 points preserved with tight epsilon")
  end)

  T.it("collapses nearly-straight line to 2 points", function()
    local pts = {}
    for i = 0, 10 do
      pts[#pts+1] = {x=i, y=0}
    end
    local simplified = cg.douglas_peucker(pts, 0.001)
    T.eq(#simplified, 2, "straight line collapses to 2 points")
  end)
end)

-- ========================
-- MIN BOUNDING CIRCLE
-- ========================

T.describe("min_bounding_circle", function()
  T.it("all points are within the bounding circle", function()
    local pts = {
      {x=0,y=0},{x=10,y=0},{x=10,y=10},{x=0,y=10},
      {x=5,y=5},{x=3,y=7},{x=8,y=2},
    }
    local c = cg.min_bounding_circle(pts)
    for i, p in ipairs(pts) do
      local dx,dy = p.x-c.cx, p.y-c.cy
      T.ok(dx*dx+dy*dy <= c.r*c.r + 1e-6,
        "point " .. i .. " is within bounding circle")
    end
  end)

  T.it("circle is tight (at least one point on boundary)", function()
    local pts = {{x=0,y=0},{x=4,y=0},{x=2,y=3}}
    local c = cg.min_bounding_circle(pts)
    local on_boundary = false
    local eps = 1e-4
    for _, p in ipairs(pts) do
      local dx,dy = p.x-c.cx, p.y-c.cy
      if math.abs(math.sqrt(dx*dx+dy*dy) - c.r) < eps then
        on_boundary = true
        break
      end
    end
    T.ok(on_boundary, "at least one point on bounding circle boundary")
  end)

  T.it("two-point circle: diameter", function()
    local pts = {{x=0,y=0},{x=4,y=0}}
    local c = cg.min_bounding_circle(pts)
    T.ok(approx(c.cx, 2, 1e-6) and approx(c.cy, 0, 1e-6), "center at midpoint")
    T.ok(approx(c.r, 2, 1e-6), "radius is half distance")
  end)
end)

-- ========================
-- TRIANGULATE
-- ========================

T.describe("triangulate", function()
  T.it("square triangulates into 2 triangles", function()
    local sq = {{x=0,y=0},{x=1,y=0},{x=1,y=1},{x=0,y=1}}
    local tris = cg.triangulate(sq)
    T.eq(#tris, 2, "square has 2 triangles")
  end)

  T.it("pentagon triangulates into 3 triangles", function()
    -- Regular-ish pentagon
    local pent = {}
    for i = 0, 4 do
      pent[#pent+1] = {x = math.cos(2*math.pi*i/5), y = math.sin(2*math.pi*i/5)}
    end
    local tris = cg.triangulate(pent)
    T.eq(#tris, 3, "pentagon has 3 triangles (n-2)")
  end)

  T.it("triangulated area equals polygon area", function()
    local sq = {{x=0,y=0},{x=2,y=0},{x=2,y=2},{x=0,y=2}}
    local expected_area = cg.polygon_area(sq)
    local tris = cg.triangulate(sq)
    local tri_area = 0
    for _, t in ipairs(tris) do
      local poly_tri = {t.a, t.b, t.c}
      tri_area = tri_area + cg.polygon_area(poly_tri)
    end
    T.ok(approx(tri_area, expected_area, 1e-6),
      "triangulated area equals polygon area")
  end)

  T.it("n-gon has n-2 triangles", function()
    local poly = {}
    local n = 7
    for i = 0, n-1 do
      poly[#poly+1] = {x = math.cos(2*math.pi*i/n), y = math.sin(2*math.pi*i/n)}
    end
    local tris = cg.triangulate(poly)
    T.eq(#tris, n-2, n .. "-gon has " .. (n-2) .. " triangles")
  end)
end)

-- ========================
-- POINT IN POLYGON — winding rule
-- ========================

T.describe("point_in_polygon", function()
  T.it("simple square: interior and exterior", function()
    local sq = {{x=0,y=0},{x=4,y=0},{x=4,y=4},{x=0,y=4}}
    T.ok(cg.point_in_polygon(sq, {x=2,y=2}), "center is inside square")
    T.ok(not cg.point_in_polygon(sq, {x=5,y=2}), "point outside square is outside")
  end)

  T.it("concave polygon (L-shape)", function()
    local l = {
      {x=0,y=0},{x=2,y=0},{x=2,y=1},
      {x=1,y=1},{x=1,y=2},{x=0,y=2},
    }
    T.ok(cg.point_in_polygon(l, {x=0.5,y=0.5}), "lower-left of L is inside")
    T.ok(not cg.point_in_polygon(l, {x=1.5,y=1.5}), "upper-right notch is outside")
  end)

  T.it("star-like polygon with winding rule", function()
    -- Simple non-convex (arrow) polygon
    local arrow = {
      {x=2,y=0},{x=4,y=2},{x=3,y=2},
      {x=3,y=4},{x=1,y=4},{x=1,y=2},{x=0,y=2},
    }
    T.ok(cg.point_in_polygon(arrow, {x=2,y=3}), "center of arrow body is inside")
    T.ok(not cg.point_in_polygon(arrow, {x=3.5,y=3}), "outside the arrow is outside")
  end)
end)
