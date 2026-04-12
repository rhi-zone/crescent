if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local B = require("lib.bezier")

local function near(a, b, eps)
  eps = eps or 1e-9
  return math.abs(a - b) < eps
end

local function pt_near(a, b, eps)
  eps = eps or 1e-9
  return near(a.x, b.x, eps) and near(a.y, b.y, eps)
end

-- ---------------------------------------------------------------------------
-- Quadratic Bézier
-- ---------------------------------------------------------------------------

T.describe("quadratic bezier", function()
  local p0 = { x = 0, y = 0 }
  local p1 = { x = 1, y = 2 }
  local p2 = { x = 2, y = 0 }
  local q = B.quadratic(p0, p1, p2)

  T.it("point(0) == p0", function()
    local pt = q:point(0)
    T.ok(near(pt.x, 0), "x")
    T.ok(near(pt.y, 0), "y")
  end)

  T.it("point(1) == p2", function()
    local pt = q:point(1)
    T.ok(near(pt.x, 2), "x")
    T.ok(near(pt.y, 0), "y")
  end)

  T.it("point(0.5) is midpoint formula", function()
    -- (1-t)^2*p0 + 2(1-t)t*p1 + t^2*p2 at t=0.5
    -- = 0.25*p0 + 0.5*p1 + 0.25*p2 = {0+0.5+0.5, 0+1+0} = {1, 1}
    local pt = q:point(0.5)
    T.ok(near(pt.x, 1), "x at midpoint")
    T.ok(near(pt.y, 1), "y at midpoint")
  end)

  T.it("tangent(0) proportional to p1-p0", function()
    local tg = q:tangent(0)
    -- tangent at 0 = 2*(p1-p0) = {2, 4}
    T.ok(near(tg.x, 2), "tangent x at t=0")
    T.ok(near(tg.y, 4), "tangent y at t=0")
  end)

  T.it("tangent(1) proportional to p2-p1", function()
    local tg = q:tangent(1)
    -- tangent at 1 = 2*(p2-p1) = {2, -4}
    T.ok(near(tg.x, 2), "tangent x at t=1")
    T.ok(near(tg.y, -4), "tangent y at t=1")
  end)

  T.it("normal is perpendicular to tangent", function()
    local tg = q:tangent(0.5)
    local nm = q:normal(0.5)
    local dot = tg.x * nm.x + tg.y * nm.y
    T.ok(near(dot, 0, 1e-9), "dot product = 0")
  end)

  T.it("to_points returns n+1 points", function()
    local pts = q:to_points(10)
    T.eq(#pts, 11)
  end)

  T.it("to_points(4) starts and ends at endpoints", function()
    local pts = q:to_points(4)
    T.eq(#pts, 5)
    T.ok(near(pts[1].x, 0), "start x")
    T.ok(near(pts[1].y, 0), "start y")
    T.ok(near(pts[5].x, 2), "end x")
    T.ok(near(pts[5].y, 0), "end y")
  end)

  T.it("split: endpoint continuity", function()
    local q1, q2 = q:split(0.5)
    -- q1 ends where q2 starts
    local q1_end = q1:point(1)
    local q2_start = q2:point(0)
    T.ok(near(q1_end.x, q2_start.x, 1e-10), "split x continuity")
    T.ok(near(q1_end.y, q2_start.y, 1e-10), "split y continuity")
  end)

  T.it("split: q1 starts at p0", function()
    local q1, _ = q:split(0.5)
    local pt = q1:point(0)
    T.ok(near(pt.x, p0.x, 1e-10), "start x")
    T.ok(near(pt.y, p0.y, 1e-10), "start y")
  end)

  T.it("split: q2 ends at p2", function()
    local _, q2 = q:split(0.5)
    local pt = q2:point(1)
    T.ok(near(pt.x, p2.x, 1e-10), "end x")
    T.ok(near(pt.y, p2.y, 1e-10), "end y")
  end)

  T.it("split: midpoint consistent with original curve", function()
    local q1, _ = q:split(0.5)
    local mid = q1:point(1)  -- end of first half
    local orig = q:point(0.5)
    T.ok(near(mid.x, orig.x, 1e-10), "mid x")
    T.ok(near(mid.y, orig.y, 1e-10), "mid y")
  end)

  T.it("length of line-like quadratic approx euclidean", function()
    -- p1 on the line from p0 to p2 => curve is a line
    local pa = { x = 0, y = 0 }
    local pb = { x = 1, y = 0 }  -- midpoint on line
    local pc = { x = 2, y = 0 }
    local ql = B.quadratic(pa, pb, pc)
    local len = ql:length(200)
    T.ok(near(len, 2, 1e-3), "line length approx 2")
  end)

  T.it("bounding_box contains endpoints", function()
    local bb = q:bounding_box()
    T.ok(bb[1] <= 0, "min_x <= p0.x")
    T.ok(bb[3] >= 2, "max_x >= p2.x")
    T.ok(bb[2] <= 0, "min_y <= 0")
    T.ok(bb[4] >= 0, "max_y >= 0")
  end)

  T.it("bounding_box max_y includes control point influence", function()
    local bb = q:bounding_box()
    -- p1.y = 2, so the curve bulges up to at least 1
    T.ok(bb[4] >= 0.9, "max_y accounts for bulge")
  end)
end)

-- ---------------------------------------------------------------------------
-- Cubic Bézier
-- ---------------------------------------------------------------------------

T.describe("cubic bezier", function()
  local p0 = { x = 0, y = 0 }
  local p1 = { x = 1, y = 3 }
  local p2 = { x = 2, y = 3 }
  local p3 = { x = 3, y = 0 }
  local c = B.cubic(p0, p1, p2, p3)

  T.it("point(0) == p0", function()
    local pt = c:point(0)
    T.ok(near(pt.x, 0), "x")
    T.ok(near(pt.y, 0), "y")
  end)

  T.it("point(1) == p3", function()
    local pt = c:point(1)
    T.ok(near(pt.x, 3), "x")
    T.ok(near(pt.y, 0), "y")
  end)

  T.it("point(0.5) is symmetric midpoint", function()
    -- symmetric curve: midpoint x = 1.5
    local pt = c:point(0.5)
    T.ok(near(pt.x, 1.5), "x midpoint symmetric")
  end)

  T.it("tangent(0) proportional to p1-p0", function()
    local tg = c:tangent(0)
    -- 3*(p1-p0) = {3, 9}
    T.ok(near(tg.x, 3), "tangent x at t=0")
    T.ok(near(tg.y, 9), "tangent y at t=0")
  end)

  T.it("tangent(1) proportional to p3-p2", function()
    local tg = c:tangent(1)
    -- 3*(p3-p2) = {3, -9}
    T.ok(near(tg.x, 3), "tangent x at t=1")
    T.ok(near(tg.y, -9), "tangent y at t=1")
  end)

  T.it("normal perpendicular to tangent", function()
    local tg = c:tangent(0.5)
    local nm = c:normal(0.5)
    local dot = tg.x * nm.x + tg.y * nm.y
    T.ok(near(dot, 0, 1e-9), "dot = 0")
  end)

  T.it("to_points returns n+1 points", function()
    local pts = c:to_points(20)
    T.eq(#pts, 21)
  end)

  T.it("split at t=0.5: C0 continuity", function()
    local c1, c2 = c:split(0.5)
    local c1e = c1:point(1)
    local c2s = c2:point(0)
    T.ok(near(c1e.x, c2s.x, 1e-10), "x continuity")
    T.ok(near(c1e.y, c2s.y, 1e-10), "y continuity")
  end)

  T.it("split: c1 starts at p0", function()
    local c1, _ = c:split(0.5)
    local pt = c1:point(0)
    T.ok(near(pt.x, p0.x, 1e-10))
    T.ok(near(pt.y, p0.y, 1e-10))
  end)

  T.it("split: c2 ends at p3", function()
    local _, c2 = c:split(0.5)
    local pt = c2:point(1)
    T.ok(near(pt.x, p3.x, 1e-10))
    T.ok(near(pt.y, p3.y, 1e-10))
  end)

  T.it("split: C1 continuity (tangent match)", function()
    local c1, c2 = c:split(0.5)
    local tg1 = c1:tangent(1)
    local tg2 = c2:tangent(0)
    -- tangents should be proportional (same direction)
    T.ok(near(tg1.x, tg2.x, 1e-8), "tangent x continuity")
    T.ok(near(tg1.y, tg2.y, 1e-8), "tangent y continuity")
  end)

  T.it("to_svg_path format", function()
    local simple = B.cubic(
      { x=0, y=0 }, { x=1, y=1 }, { x=2, y=1 }, { x=3, y=0 })
    local svg = simple:to_svg_path()
    T.ok(svg:find("^M "), "starts with M")
    T.ok(svg:find(" C "), "contains C")
  end)

  T.it("to_svg_path contains all 4 points", function()
    local simple = B.cubic(
      { x=0, y=0 }, { x=1, y=1 }, { x=2, y=1 }, { x=3, y=0 })
    local svg = simple:to_svg_path()
    -- "M 0,0 C 1,1 2,1 3,0"
    T.ok(svg:find("0,0"), "p0 in svg")
    T.ok(svg:find("3,0"), "p3 in svg")
  end)

  T.it("length of line-like cubic approx euclidean", function()
    local la = { x = 0, y = 0 }
    local lb = { x = 1, y = 0 }
    local lc = { x = 2, y = 0 }
    local ld = { x = 3, y = 0 }
    local cl = B.cubic(la, lb, lc, ld)
    local len = cl:length(200)
    T.ok(near(len, 3, 1e-3), "line length approx 3")
  end)

  T.it("bounding_box contains endpoints", function()
    local bb = c:bounding_box()
    T.ok(bb[1] <= 0)
    T.ok(bb[3] >= 3)
    T.ok(bb[2] <= 0)
    T.ok(bb[4] >= 0)
  end)

  T.it("inflections returns table", function()
    local inf = c:inflections()
    T.ok(type(inf) == "table", "returns table")
  end)

  T.it("inflections of a line is empty", function()
    local line = B.cubic(
      { x=0,y=0 }, { x=1,y=0 }, { x=2,y=0 }, { x=3,y=0 })
    local inf = line:inflections()
    T.eq(#inf, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- 3D cubic
-- ---------------------------------------------------------------------------

T.describe("cubic bezier 3D", function()
  local p0 = { x = 0, y = 0, z = 0 }
  local p1 = { x = 1, y = 1, z = 1 }
  local p2 = { x = 2, y = 1, z = 2 }
  local p3 = { x = 3, y = 0, z = 0 }
  local c = B.cubic(p0, p1, p2, p3)

  T.it("point(0) == p0 in 3D", function()
    local pt = c:point(0)
    T.ok(near(pt.x, 0))
    T.ok(near(pt.y, 0))
    T.ok(near(pt.z, 0))
  end)

  T.it("point(1) == p3 in 3D", function()
    local pt = c:point(1)
    T.ok(near(pt.x, 3))
    T.ok(near(pt.y, 0))
    T.ok(near(pt.z, 0))
  end)
end)

-- ---------------------------------------------------------------------------
-- General Bézier curve
-- ---------------------------------------------------------------------------

T.describe("general bezier curve", function()
  T.it("degree = #points - 1", function()
    local pts = { {x=0,y=0}, {x=1,y=1}, {x=2,y=0}, {x=3,y=1}, {x=4,y=0} }
    local g = B.curve(pts)
    T.eq(g:degree(), 4)
  end)

  T.it("degree 1 is linear interpolation", function()
    local g = B.curve({ {x=0,y=0}, {x=4,y=2} })
    local pt = g:point(0.5)
    T.ok(near(pt.x, 2))
    T.ok(near(pt.y, 1))
  end)

  T.it("point(0) == first control point", function()
    local pts = { {x=1,y=2}, {x=3,y=4}, {x=5,y=6} }
    local g = B.curve(pts)
    local pt = g:point(0)
    T.ok(near(pt.x, 1))
    T.ok(near(pt.y, 2))
  end)

  T.it("point(1) == last control point", function()
    local pts = { {x=1,y=2}, {x=3,y=4}, {x=5,y=6} }
    local g = B.curve(pts)
    local pt = g:point(1)
    T.ok(near(pt.x, 5))
    T.ok(near(pt.y, 6))
  end)

  T.it("matches cubic explicit formula", function()
    local pts = { {x=0,y=0}, {x=1,y=3}, {x=2,y=3}, {x=3,y=0} }
    local g = B.curve(pts)
    local c = B.cubic(pts[1], pts[2], pts[3], pts[4])
    for _, t in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
      local gp = g:point(t)
      local cp = c:point(t)
      T.ok(near(gp.x, cp.x, 1e-10), "x at t="..t)
      T.ok(near(gp.y, cp.y, 1e-10), "y at t="..t)
    end
  end)

  T.it("derivative has degree n-1", function()
    local pts = { {x=0,y=0}, {x=1,y=3}, {x=2,y=3}, {x=3,y=0} }
    local g = B.curve(pts)
    local d = g:derivative()
    T.eq(d:degree(), 2)
  end)

  T.it("derivative direction matches cubic tangent", function()
    local pts = { {x=0,y=0}, {x=1,y=3}, {x=2,y=3}, {x=3,y=0} }
    local g = B.curve(pts)
    local d = g:derivative()
    local c = B.cubic(pts[1], pts[2], pts[3], pts[4])
    -- derivative curve evaluated at t should be proportional to tangent
    local dp = d:point(0.5)
    local tg = c:tangent(0.5)
    -- derivative is unnormalized tangent (same direction)
    T.ok(near(dp.x, tg.x, 1e-8), "derivative x matches tangent")
    T.ok(near(dp.y, tg.y, 1e-8), "derivative y matches tangent")
  end)

  T.it("elevate returns degree+1", function()
    local pts = { {x=0,y=0}, {x=1,y=2}, {x=2,y=0} }
    local g = B.curve(pts)
    local e = g:elevate()
    T.eq(e:degree(), 3)
  end)

  T.it("elevate preserves same shape", function()
    local pts = { {x=0,y=0}, {x=1,y=2}, {x=2,y=0} }
    local g = B.curve(pts)
    local e = g:elevate()
    for _, t in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
      local gp = g:point(t)
      local ep = e:point(t)
      T.ok(near(gp.x, ep.x, 1e-9), "elevate x at t="..t)
      T.ok(near(gp.y, ep.y, 1e-9), "elevate y at t="..t)
    end
  end)

  T.it("to_points returns n+1 points", function()
    local pts = { {x=0,y=0}, {x=1,y=2}, {x=2,y=0} }
    local g = B.curve(pts)
    local ps = g:to_points(8)
    T.eq(#ps, 9)
  end)
end)

-- ---------------------------------------------------------------------------
-- Spline
-- ---------------------------------------------------------------------------

T.describe("catmull-rom spline", function()
  local points = {
    { x = 0, y = 0 },
    { x = 1, y = 2 },
    { x = 3, y = 1 },
    { x = 4, y = 3 },
  }
  local s = B.spline(points)

  T.it("passes through first point at t=0", function()
    local pt = s:point(0)
    T.ok(near(pt.x, 0, 1e-9))
    T.ok(near(pt.y, 0, 1e-9))
  end)

  T.it("passes through second point at t=1", function()
    local pt = s:point(1)
    T.ok(near(pt.x, 1, 1e-9))
    T.ok(near(pt.y, 2, 1e-9))
  end)

  T.it("passes through third point at t=2", function()
    local pt = s:point(2)
    T.ok(near(pt.x, 3, 1e-9))
    T.ok(near(pt.y, 1, 1e-9))
  end)

  T.it("passes through last point at t=3", function()
    local pt = s:point(3)
    T.ok(near(pt.x, 4, 1e-9))
    T.ok(near(pt.y, 3, 1e-9))
  end)

  T.it("segment(1) is a cubic", function()
    local seg = s:segment(1)
    T.ok(seg ~= nil, "segment exists")
    -- can call point on it
    local pt = seg:point(0)
    T.ok(type(pt.x) == "number")
  end)

  T.it("to_points returns correct count", function()
    local pts = s:to_points(30)
    T.eq(#pts, 31)
  end)

  T.it("C1 continuity at interior join (t=1)", function()
    -- at t=1, left segment (seg 1 at t=1) and right segment (seg 2 at t=0)
    -- tangents should match
    local seg1 = s:segment(1)
    local seg2 = s:segment(2)
    local tg1 = seg1:tangent(1)
    local tg2 = seg2:tangent(0)
    -- Catmull-Rom guarantees C1 at interior points
    T.ok(near(tg1.x, tg2.x, 1e-8), "C1 tangent x at join")
    T.ok(near(tg1.y, tg2.y, 1e-8), "C1 tangent y at join")
  end)
end)

-- ---------------------------------------------------------------------------
-- Hermite curve
-- ---------------------------------------------------------------------------

T.describe("hermite curve", function()
  local p0 = { x = 0, y = 0 }
  local m0 = { x = 2, y = 0 }
  local p1 = { x = 1, y = 0 }
  local m1 = { x = 2, y = 0 }
  local h = B.hermite(p0, m0, p1, m1)

  T.it("point(0) == p0", function()
    local pt = h:point(0)
    T.ok(near(pt.x, 0))
    T.ok(near(pt.y, 0))
  end)

  T.it("point(1) == p1", function()
    local pt = h:point(1)
    T.ok(near(pt.x, 1))
    T.ok(near(pt.y, 0))
  end)

  T.it("to_cubic: point(0) == p0", function()
    local c = h:to_cubic()
    local pt = c:point(0)
    T.ok(near(pt.x, 0, 1e-10))
    T.ok(near(pt.y, 0, 1e-10))
  end)

  T.it("to_cubic: point(1) == p1", function()
    local c = h:to_cubic()
    local pt = c:point(1)
    T.ok(near(pt.x, 1, 1e-10))
    T.ok(near(pt.y, 0, 1e-10))
  end)

  T.it("to_cubic matches hermite at midpoint", function()
    local h2 = B.hermite(
      { x=0, y=0 }, { x=3, y=1 },
      { x=2, y=1 }, { x=1, y=3 })
    local c = h2:to_cubic()
    for _, t in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
      local hp = h2:point(t)
      local cp = c:point(t)
      T.ok(near(hp.x, cp.x, 1e-9), "x at t="..t)
      T.ok(near(hp.y, cp.y, 1e-9), "y at t="..t)
    end
  end)

  T.it("tangent at t=0 equals m0", function()
    -- Hermite basis: h'(0) = m0
    -- numerically verify via finite difference
    local dt = 1e-7
    local pt0 = h:point(0)
    local pt1 = h:point(dt)
    local approx_dx = (pt1.x - pt0.x) / dt
    local approx_dy = (pt1.y - pt0.y) / dt
    T.ok(near(approx_dx, m0.x, 1e-4), "tangent x at t=0")
    T.ok(near(approx_dy, m0.y, 1e-4), "tangent y at t=0")
  end)
end)

-- ---------------------------------------------------------------------------
-- Arc length accuracy
-- ---------------------------------------------------------------------------

T.describe("arc length", function()
  T.it("line segment length equals euclidean distance", function()
    -- Cubic Bézier along x-axis
    local c = B.cubic(
      { x=0, y=0 }, { x=1, y=0 }, { x=2, y=0 }, { x=5, y=0 })
    local len = c:length(500)
    T.ok(near(len, 5, 1e-2), "line length = 5")
  end)

  T.it("quarter circle arc length ≈ pi/2", function()
    -- Approximate quarter circle with cubic Bézier (standard approximation)
    -- Control points: (1,0), (1, 0.5523), (0.5523, 1), (0, 1)
    local k = 0.5522847498
    local c = B.cubic(
      { x=1, y=0 }, { x=1, y=k }, { x=k, y=1 }, { x=0, y=1 })
    local len = c:length(1000)
    local expected = math.pi / 2
    T.ok(near(len, expected, 0.002), "quarter circle ~ pi/2")
  end)

  T.it("quadratic line length equals euclidean", function()
    local q = B.quadratic({ x=0,y=0 }, { x=2,y=0 }, { x=4,y=0 })
    local len = q:length(500)
    T.ok(near(len, 4, 1e-2), "line length = 4")
  end)
end)

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

T.describe("module", function()
  T.it("_tier is pure", function()
    T.eq(B._tier, "pure")
  end)
end)
