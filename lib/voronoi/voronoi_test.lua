if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local voronoi = require("lib.voronoi")

local EPSILON = 1e-6

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

local function approx_eq(a, b, eps)
  return math.abs(a - b) < (eps or EPSILON)
end

-- ---------------------------------------------------------------------------
-- Delaunay tests
-- ---------------------------------------------------------------------------

T.describe("delaunay - 3 sites", function()
  T.it("produces exactly 1 triangle", function()
    local sites = {{x=0,y=0},{x=10,y=0},{x=5,y=10}}
    local tri = voronoi.delaunay(sites)
    T.eq(#tri.triangles, 1)
  end)

  T.it("triangle contains all 3 site indices", function()
    local sites = {{x=0,y=0},{x=10,y=0},{x=5,y=10}}
    local tri = voronoi.delaunay(sites)
    local t = tri.triangles[1]
    local s = {}; for _, v in ipairs(t) do s[v] = true end
    T.ok(s[1] and s[2] and s[3], "all site indices in triangle")
  end)
end)

T.describe("delaunay - 4 sites (square)", function()
  T.it("produces 2 triangles", function()
    -- Square corners: Bowyer-Watson should give 2 triangles
    local sites = {{x=0,y=0},{x=10,y=0},{x=10,y=10},{x=0,y=10}}
    local tri = voronoi.delaunay(sites)
    T.eq(#tri.triangles, 2)
  end)

  T.it("produces 5 unique edges", function()
    local sites = {{x=0,y=0},{x=10,y=0},{x=10,y=10},{x=0,y=10}}
    local tri = voronoi.delaunay(sites)
    T.eq(#tri.edges, 5)
  end)
end)

T.describe("delaunay - circumcircle property", function()
  T.it("no site lies strictly inside any triangle's circumcircle", function()
    local sites = {
      {x=0,y=0},{x=20,y=0},{x=10,y=15},{x=5,y=8},{x=15,y=5}
    }
    local tri = voronoi.delaunay(sites)

    local function circumcircle(ax,ay,bx,by,cx,cy)
      local D = 2*(ax*(by-cy)+bx*(cy-ay)+cx*(ay-by))
      if math.abs(D) < 1e-10 then return nil end
      local ux = ((ax*ax+ay*ay)*(by-cy)+(bx*bx+by*by)*(cy-ay)+(cx*cx+cy*cy)*(ay-by))/D
      local uy = ((ax*ax+ay*ay)*(cx-bx)+(bx*bx+by*by)*(ax-cx)+(cx*cx+cy*cy)*(bx-ax))/D
      return ux, uy, dist2(ux,uy,ax,ay)
    end

    for _, t in ipairs(tri.triangles) do
      local a, b, c = sites[t[1]], sites[t[2]], sites[t[3]]
      local ccx, ccy, r2 = circumcircle(a.x,a.y, b.x,b.y, c.x,c.y)
      if ccx then
        for k, s in ipairs(sites) do
          if k ~= t[1] and k ~= t[2] and k ~= t[3] then
            local d2 = dist2(s.x, s.y, ccx, ccy)
            T.ok(d2 >= r2 - 1e-6, "site " .. k .. " inside circumcircle of triangle")
          end
        end
      end
    end
  end)
end)

T.describe("delaunay - collinear sites", function()
  T.it("handles collinear sites without crash", function()
    local sites = {{x=0,y=0},{x=5,y=0},{x=10,y=0}}
    local ok, err = pcall(function() return voronoi.delaunay(sites) end)
    T.ok(ok, "no crash on collinear: " .. tostring(err))
  end)
end)

T.describe("delaunay - single site", function()
  T.it("returns empty triangulation", function()
    local tri = voronoi.delaunay({{x=5,y=5}})
    T.eq(#tri.triangles, 0)
    T.eq(#tri.edges, 0)
  end)
end)

T.describe("delaunay - two sites", function()
  T.it("returns one edge, no triangles", function()
    local tri = voronoi.delaunay({{x=0,y=0},{x=10,y=0}})
    T.eq(#tri.triangles, 0)
    T.eq(#tri.edges, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Voronoi tests
-- ---------------------------------------------------------------------------

T.describe("voronoi - single site", function()
  T.it("one cell = entire bounding box", function()
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute({{x=50,y=50}}, bounds)
    T.eq(#diagram.cells, 1)
    local cell = diagram.cells[1]
    T.ok(#cell.vertices >= 4, "cell has at least 4 vertices (box)")
    -- All 4 corners should be present
    local function has_corner(verts, cx, cy)
      for _, v in ipairs(verts) do
        if approx_eq(v.x, cx, 0.1) and approx_eq(v.y, cy, 0.1) then return true end
      end
      return false
    end
    T.ok(has_corner(cell.vertices, 0, 0), "has corner (0,0)")
    T.ok(has_corner(cell.vertices, 100, 0), "has corner (100,0)")
    T.ok(has_corner(cell.vertices, 100, 100), "has corner (100,100)")
    T.ok(has_corner(cell.vertices, 0, 100), "has corner (0,100)")
  end)
end)

T.describe("voronoi - two sites", function()
  local bounds = {x=0,y=0,w=100,h=100}
  local s1 = {x=25,y=50}
  local s2 = {x=75,y=50}
  local diagram = voronoi.compute({s1, s2}, bounds)

  T.it("two cells", function()
    T.eq(#diagram.cells, 2)
  end)

  T.it("each cell contains its site", function()
    local function point_in_poly(px, py, verts)
      local n = #verts
      for i = 1, n do
        local a = verts[i]
        local b = verts[(i % n) + 1]
        local cross = (b.x-a.x)*(py-a.y) - (b.y-a.y)*(px-a.x)
        if cross < -1e-6 then return false end
      end
      return true
    end
    T.ok(point_in_poly(s1.x, s1.y, diagram.cells[1].vertices), "cell 1 contains site 1")
    T.ok(point_in_poly(s2.x, s2.y, diagram.cells[2].vertices), "cell 2 contains site 2")
  end)

  T.it("cells are neighbors of each other", function()
    local n1 = diagram.cells[1].neighbors
    local n2 = diagram.cells[2].neighbors
    local has2 = false; for _, v in ipairs(n1) do if v == 2 then has2 = true end end
    local has1 = false; for _, v in ipairs(n2) do if v == 1 then has1 = true end end
    T.ok(has2, "cell 1 has cell 2 as neighbor")
    T.ok(has1, "cell 2 has cell 1 as neighbor")
  end)
end)

T.describe("voronoi - cell vertices equidistant from site and neighbors", function()
  T.it("shared vertices lie on perpendicular bisectors", function()
    local sites = {{x=10,y=50},{x=50,y=20},{x=90,y=50},{x=50,y=80}}
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute(sites, bounds)

    -- For each pair of neighboring cells, find shared vertices
    -- A shared vertex (circumcenter) should be equidistant from both sites
    for i, cell in ipairs(diagram.cells) do
      for _, j in ipairs(cell.neighbors) do
        if j > i then
          local si = cell.site
          local sj = diagram.cells[j].site
          -- Find vertices in both cells (within epsilon)
          for _, vi in ipairs(cell.vertices) do
            for _, vj in ipairs(diagram.cells[j].vertices) do
              if approx_eq(vi.x, vj.x, 0.5) and approx_eq(vi.y, vj.y, 0.5) then
                -- This shared vertex should be equidistant from si and sj
                local di = math.sqrt(dist2(vi.x, vi.y, si.x, si.y))
                local dj = math.sqrt(dist2(vi.x, vi.y, sj.x, sj.y))
                T.ok(approx_eq(di, dj, 0.5), string.format(
                  "shared vertex (%.2f,%.2f) equidistant from sites %d and %d: %.3f vs %.3f",
                  vi.x, vi.y, i, j, di, dj))
              end
            end
          end
        end
      end
    end
  end)
end)

T.describe("voronoi - cells cover bounding box", function()
  T.it("interior test points are in exactly one cell", function()
    local sites = {{x=20,y=20},{x=80,y=20},{x=50,y=70}}
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute(sites, bounds)

    -- Test a grid of interior points
    local uncovered = 0
    local test_pts = {
      {x=15,y=15},{x=85,y=15},{x=50,y=80},
      {x=50,y=30},{x=30,y=60},{x=70,y=60},
    }
    for _, pt in ipairs(test_pts) do
      local idx = voronoi.find_cell(diagram, pt)
      if idx == nil then uncovered = uncovered + 1 end
    end
    T.eq(uncovered, 0, "all interior test points are in a cell")
  end)
end)

-- ---------------------------------------------------------------------------
-- Query tests
-- ---------------------------------------------------------------------------

T.describe("nearest_site", function()
  T.it("returns correct index for point clearly in one cell", function()
    local sites = {{x=10,y=50},{x=50,y=50},{x=90,y=50}}
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute(sites, bounds)
    -- Point near site 1
    T.eq(voronoi.nearest_site(diagram, {x=12,y=50}), 1)
    -- Point near site 3
    T.eq(voronoi.nearest_site(diagram, {x=88,y=50}), 3)
    -- Point near site 2
    T.eq(voronoi.nearest_site(diagram, {x=50,y=50}), 2)
  end)
end)

T.describe("find_cell", function()
  T.it("returns correct cell index", function()
    local sites = {{x=25,y=50},{x=75,y=50}}
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute(sites, bounds)
    -- Point deep in left cell
    T.eq(voronoi.find_cell(diagram, {x=10,y=50}), 1)
    -- Point deep in right cell
    T.eq(voronoi.find_cell(diagram, {x=90,y=50}), 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Lloyd relaxation tests
-- ---------------------------------------------------------------------------

T.describe("lloyd relaxation", function()
  T.it("sites move toward cell centroids", function()
    -- Start with skewed sites; after relaxation they should be more centered
    local sites = {{x=5,y=5},{x=10,y=5},{x=50,y=50}}
    local bounds = {x=0,y=0,w=100,h=100}
    local relaxed = voronoi.lloyd(sites, bounds, {iterations=3})
    T.eq(#relaxed, 3)
    -- The two close sites should have moved apart
    local d_before = math.sqrt(dist2(sites[1].x, sites[1].y, sites[2].x, sites[2].y))
    local d_after  = math.sqrt(dist2(relaxed[1].x, relaxed[1].y, relaxed[2].x, relaxed[2].y))
    T.ok(d_after > d_before, "close sites moved apart after relaxation")
  end)

  T.it("centroid property: relaxed site is at cell centroid", function()
    -- After 1 iteration, each site should be at the centroid of its previous cell
    local sites = {{x=20,y=20},{x=80,y=20},{x=50,y=80}}
    local bounds = {x=0,y=0,w=100,h=100}
    local diagram = voronoi.compute(sites, bounds)
    local relaxed = voronoi.lloyd(sites, bounds, {iterations=1})
    -- Compute expected centroids
    for i, cell in ipairs(diagram.cells) do
      local n = #cell.vertices
      if n > 0 then
        local cx, cy = 0, 0
        for _, v in ipairs(cell.vertices) do cx = cx + v.x; cy = cy + v.y end
        cx = cx / n; cy = cy / n
        T.ok(approx_eq(relaxed[i].x, cx, 0.5) and approx_eq(relaxed[i].y, cy, 0.5),
          string.format("site %d moved to centroid: expected (%.2f,%.2f) got (%.2f,%.2f)",
            i, cx, cy, relaxed[i].x, relaxed[i].y))
      end
    end
  end)
end)
