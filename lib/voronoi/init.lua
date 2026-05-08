if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Voronoi diagram and Delaunay triangulation library.
--
-- Delaunay: Bowyer-Watson incremental algorithm.
-- Voronoi: derived from Delaunay (circumcenters of adjacent triangles) + bounds clipping.
-- Queries: nearest_site, find_cell.
-- Relaxation: Lloyd's algorithm.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Math helpers
-- ---------------------------------------------------------------------------

local EPSILON = 1e-10

local function dist2(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return dx * dx + dy * dy
end

-- Circumcircle center and radius^2 for triangle (ax,ay),(bx,by),(cx,cy).
-- Returns cx, cy, r2 or nil if degenerate (collinear).
local function circumcircle(ax, ay, bx, by, cx, cy)
  local D = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
  if math.abs(D) < EPSILON then return nil end
  local ux = ((ax*ax + ay*ay) * (by - cy) + (bx*bx + by*by) * (cy - ay) + (cx*cx + cy*cy) * (ay - by)) / D
  local uy = ((ax*ax + ay*ay) * (cx - bx) + (bx*bx + by*by) * (ax - cx) + (cx*cx + cy*cy) * (bx - ax)) / D
  return ux, uy, dist2(ux, uy, ax, ay)
end

-- Returns true if point (px,py) is inside the circumcircle of triangle with given cc.
--: (number, number, number, number, number) -> boolean
local function in_circumcircle(px, py, ccx, ccy, r2)
  return dist2(px, py, ccx, ccy) < r2 - EPSILON
end

-- Cross product of (b-a) x (c-a). Positive = CCW.
local function cross2d(ax, ay, bx, by, cx, cy)
  return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
end

-- Point-in-convex-polygon (CCW vertices). Returns true if inside or on boundary.
local function point_in_polygon(px, py, verts)
  local n = #verts
  for i = 1, n do
    local a = verts[i]
    local b = verts[(i % n) + 1]
    if cross2d(a.x, a.y, b.x, b.y, px, py) < -EPSILON then
      return false
    end
  end
  return true
end

-- Polygon centroid.
local function polygon_centroid(verts)
  local n = #verts
  if n == 0 then return nil end
  local sx, sy = 0, 0
  for _, v in ipairs(verts) do sx = sx + v.x; sy = sy + v.y end
  return {x = sx / n, y = sy / n}
end

-- Sutherland-Hodgman clip polygon against a half-plane defined by edge (ax,ay)->(bx,by)
-- (keep points on left side / CCW interior).
--: ({ [integer]: { x: number, y: number }, ... }, number, number, number, number) -> { [integer]: { x: number, y: number }, ... }
local function clip_poly_half(verts, ax, ay, bx, by)
  local n = #verts
  if n == 0 then return verts end
  local out = {} --: { [integer]: { x: number, y: number }, ... }
  for i = 1, n do
    local s = verts[i]
    local e = verts[(i % n) + 1]
    local cs = cross2d(ax, ay, bx, by, s.x, s.y)
    local ce = cross2d(ax, ay, bx, by, e.x, e.y)
    if cs >= -EPSILON then
      out[#out + 1] = s
    end
    if (cs > EPSILON and ce < -EPSILON) or (cs < -EPSILON and ce > EPSILON) then
      -- intersection
      local t = cs / (cs - ce)
      out[#out + 1] = {x = s.x + t * (e.x - s.x), y = s.y + t * (e.y - s.y)}
    end
  end
  return out
end

-- Sutherland-Hodgman clip polygon to axis-aligned bounding box.
-- Each clipping edge is oriented so the interior point (box center) is on the LEFT.
-- left:   (x0,y1)->(x0,y0)  keeps x >= x0
-- right:  (x1,y0)->(x1,y1)  keeps x <= x1
-- bottom: (x0,y0)->(x1,y0)  keeps y >= y0
-- top:    (x1,y1)->(x0,y1)  keeps y <= y1
--: ({ [integer]: { x: number, y: number }, ... }, number, number, number, number) -> { [integer]: { x: number, y: number }, ... }
local function clip_poly_to_bounds(verts, bx, by, bw, bh)
  local x0, y0, x1, y1 = bx, by, bx + bw, by + bh
  verts = clip_poly_half(verts, x0, y1, x0, y0)  -- left
  verts = clip_poly_half(verts, x1, y0, x1, y1)  -- right
  verts = clip_poly_half(verts, x0, y0, x1, y0)  -- bottom
  verts = clip_poly_half(verts, x1, y1, x0, y1)  -- top
  return verts
end

-- Sort vertices CCW around their centroid.
--: ({ [integer]: { x: number, y: number }, ... }) -> { [integer]: { x: number, y: number }, ... }
local function sort_ccw(verts)
  if #verts < 3 then return verts end
  local cx = 0 --: number
  local cy = 0 --: number
  for _, v in ipairs(verts) do cx = cx + v.x; cy = cy + v.y end
  cx = cx / #verts; cy = cy / #verts
  local ccx = cx
  local ccy = cy
  --: ({ x: number, y: number }, { x: number, y: number }) -> boolean
  table.sort(verts, function(a, b)
    local aa = math.atan2(a.y - ccy, a.x - ccx)
    local ab = math.atan2(b.y - ccy, b.x - ccx)
    return aa < ab
  end)
  return verts
end

-- Deduplicate vertices (within epsilon).
local function dedup_verts(verts)
  local out = {} --: { [integer]: { x: number, y: number }, ... }
  for _, v in ipairs(verts) do
    local dup = false
    for _, u in ipairs(out) do
      if math.abs(v.x - u.x) < EPSILON and math.abs(v.y - u.y) < EPSILON then
        dup = true; break
      end
    end
    if not dup then out[#out + 1] = v end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Bowyer-Watson Delaunay triangulation
-- ---------------------------------------------------------------------------

-- Super-triangle that contains all points.
local function make_super_triangle(sites)
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, s in ipairs(sites) do
    if s.x < minx then minx = s.x end
    if s.y < miny then miny = s.y end
    if s.x > maxx then maxx = s.x end
    if s.y > maxy then maxy = s.y end
  end
  local dx = (maxx - minx)
  local dy = (maxy - miny)
  local delta = math.max(dx, dy) * 10 + 1
  -- Three vertices well outside the site cloud
  return {
    {x = minx - delta,       y = miny - delta},
    {x = minx + 2 * delta,   y = miny - delta},
    {x = minx,               y = miny + 2 * delta},
  }
end

-- Triangle representation: {a, b, c} = 1-based indices into a vertex array.
-- We also cache circumcircle.

--:: Tri = { a: integer, b: integer, c: integer, ccx: number | nil, ccy: number | nil, r2: number | nil }

local function make_tri(a, b, c, verts)
  local ccx, ccy, r2 = circumcircle(
    verts[a].x, verts[a].y,
    verts[b].x, verts[b].y,
    verts[c].x, verts[c].y
  )
  return {a = a, b = b, c = c, ccx = ccx, ccy = ccy, r2 = r2}
end

-- Check if triangle shares a vertex with the super-triangle (indices 1,2,3 of all_verts).
local function touches_super(tri)
  return tri.a <= 3 or tri.b <= 3 or tri.c <= 3
end

-- Bowyer-Watson: returns list of {a,b,c} triangles (1-indexed into sites).
-- sites is array of {x,y}.
function M.delaunay(sites)
  if not sites or #sites == 0 then
    return {triangles = {}, edges = {}}
  end
  if #sites == 1 then
    return {triangles = {}, edges = {}}
  end
  if #sites == 2 then
    return {triangles = {}, edges = {{1, 2}}}
  end

  -- Build vertex array: super-triangle verts first, then sites (offset = 3)
  local super = make_super_triangle(sites)
  local all_verts = {super[1], super[2], super[3]} --: { [integer]: { x: number, y: number }, ... }
  for _, s in ipairs(sites) do all_verts[#all_verts + 1] = s end

  -- Start with the super-triangle
  local triangles = {make_tri(1, 2, 3, all_verts)} --: { [integer]: Tri, ... }

  for pi = 4, #all_verts do
    local px, py = all_verts[pi].x, all_verts[pi].y

    -- Find all triangles whose circumcircle contains the new point
    local bad = {}
    for i, tri in ipairs(triangles) do
      if tri.ccx and in_circumcircle(px, py, tri.ccx --[[:! number]], tri.ccy --[[:! number]], tri.r2 --[[:! number]]) then
        bad[i] = true
      end
    end

    -- Find the boundary polygon of the bad triangles (edges not shared by two bad triangles)
    local boundary = {}
    for i, tri in ipairs(triangles) do
      if bad[i] then
        local edges = {{tri.a, tri.b}, {tri.b, tri.c}, {tri.c, tri.a}}
        for _, e in ipairs(edges) do
          -- Check if this edge is shared with another bad triangle
          local shared = false
          for j, tri2 in ipairs(triangles) do
            if bad[j] and j ~= i then
              local e2s = {{tri2.a, tri2.b}, {tri2.b, tri2.c}, {tri2.c, tri2.a}}
              for _, e2 in ipairs(e2s) do
                if (e[1] == e2[1] and e[2] == e2[2]) or (e[1] == e2[2] and e[2] == e2[1]) then
                  shared = true; break
                end
              end
            end
            if shared then break end
          end
          if not shared then
            boundary[#boundary + 1] = e
          end
        end
      end
    end

    -- Remove bad triangles
    local new_triangles = {} --: { [integer]: Tri, ... }
    for i, tri in ipairs(triangles) do
      if not bad[i] then new_triangles[#new_triangles + 1] = tri end
    end

    -- Re-triangulate from boundary to new point
    for _, e in ipairs(boundary) do
      new_triangles[#new_triangles + 1] = make_tri(e[1], e[2], pi, all_verts)
    end

    triangles = new_triangles
  end

  -- Remove triangles touching super-triangle vertices (indices 1,2,3)
  local final = {} --: { [integer]: Tri, ... }
  for _, tri in ipairs(triangles) do
    if not touches_super(tri) then
      final[#final + 1] = tri
    end
  end

  -- Convert to site indices (subtract 3 for super-triangle offset)
  local result_tris = {}
  for _, tri in ipairs(final) do
    result_tris[#result_tris + 1] = {tri.a - 3, tri.b - 3, tri.c - 3}
  end

  -- Build unique edge list
  local edge_set = {}
  local edges = {}
  for _, t in ipairs(result_tris) do
    local es = {{t[1], t[2]}, {t[2], t[3]}, {t[3], t[1]}}
    for _, e in ipairs(es) do
      local a, b = e[1], e[2]
      if a > b then a, b = b, a end
      local key = a * 100000 + b
      if not edge_set[key] then
        edge_set[key] = true
        edges[#edges + 1] = {a, b}
      end
    end
  end

  return {triangles = result_tris, edges = edges}
end

-- ---------------------------------------------------------------------------
-- Voronoi diagram from Delaunay
-- ---------------------------------------------------------------------------

-- Build adjacency: for each site, which triangles contain it?
-- For each edge between two sites, what triangles share it?
-- The Voronoi edge between two neighboring sites connects the circumcenters
-- of the two triangles sharing the Delaunay edge.

--:: VoronoiCell = { site: { x: number, y: number, ... }, vertices: { [integer]: { x: number, y: number }, ... }, neighbors: { [integer]: integer, ... } }
--:: VoronoiDiagram = { cells: { [integer]: VoronoiCell, ... } }

--: ({ [integer]: { x: number, y: number }, ... }, { x?: number, y?: number, w?: number, h?: number, width?: number, height?: number, ... }) -> VoronoiDiagram
function M.compute(sites, bounds)
  if not sites or #sites == 0 then
    return {cells = {}}
  end

  local bx = bounds.x or 0
  local by = bounds.y or 0
  local bw = bounds.w or bounds.width or 100
  local bh = bounds.h or bounds.height or 100

  -- Single site: whole bounding box
  if #sites == 1 then
    local verts = {
      {x = bx,      y = by},
      {x = bx + bw, y = by},
      {x = bx + bw, y = by + bh},
      {x = bx,      y = by + bh},
    }
    return {cells = {{site = sites[1], vertices = verts, neighbors = {}}}}
  end

  -- Two sites: bisecting half-planes
  if #sites == 2 then
    local s1, s2 = sites[1], sites[2]
    local mx = (s1.x + s2.x) / 2
    local my = (s1.y + s2.y) / 2
    local dx = s2.x - s1.x
    local dy = s2.y - s1.y
    -- Normal direction: (dy, -dx) and (-dy, dx)
    -- Generate a far point along the bisector perpendicular
    local len = math.sqrt(dx*dx + dy*dy)
    if len < EPSILON then
      -- coincident sites
      local verts = {
        {x = bx, y = by}, {x = bx+bw, y = by},
        {x = bx+bw, y = by+bh}, {x = bx, y = by+bh},
      }
      return {cells = {
        {site = s1, vertices = verts, neighbors = {2}},
        {site = s2, vertices = verts, neighbors = {1}},
      }}
    end
    -- Perpendicular direction (unit)
    local px, py = -dy / len, dx / len
    local far = math.max(bw, bh) * 10
    local p1 = {x = mx + px * far, y = my + py * far}
    local p2 = {x = mx - px * far, y = my - py * far}
    local full = {{x=bx,y=by},{x=bx+bw,y=by},{x=bx+bw,y=by+bh},{x=bx,y=by+bh}}
    -- Cell 1: side of s1 relative to midpoint line p2->p1
    local c1 = clip_poly_half(full, p2.x, p2.y, p1.x, p1.y)
    c1 = clip_poly_to_bounds(c1, bx, by --[[:! number]], bw, bh)
    -- Cell 2: opposite side
    local c2 = clip_poly_half(full, p1.x, p1.y, p2.x, p2.y)
    c2 = clip_poly_to_bounds(c2, bx, by --[[:! number]], bw, bh)
    return {cells = {
      {site = s1, vertices = sort_ccw(dedup_verts(c1)), neighbors = {2}},
      {site = s2, vertices = sort_ccw(dedup_verts(c2)), neighbors = {1}},
    }}
  end

  -- General case: use Bowyer-Watson then derive Voronoi cells

  -- Build extended vertex set for triangulation (same as delaunay but keep cc info)
  local super = make_super_triangle(sites)
  local all_verts = {super[1], super[2], super[3]} --: { [integer]: { x: number, y: number }, ... }
  for _, s in ipairs(sites) do all_verts[#all_verts + 1] = s end

  local triangles = {make_tri(1, 2, 3, all_verts)} --: { [integer]: Tri, ... }

  for pi = 4, #all_verts do
    local px, py = all_verts[pi].x, all_verts[pi].y
    local bad = {}
    for i, tri in ipairs(triangles) do
      if tri.ccx and in_circumcircle(px, py, tri.ccx --[[:! number]], tri.ccy --[[:! number]], tri.r2 --[[:! number]]) then
        bad[i] = true
      end
    end
    local boundary = {}
    for i, tri in ipairs(triangles) do
      if bad[i] then
        local edges = {{tri.a, tri.b}, {tri.b, tri.c}, {tri.c, tri.a}}
        for _, e in ipairs(edges) do
          local shared = false
          for j, tri2 in ipairs(triangles) do
            if bad[j] and j ~= i then
              local e2s = {{tri2.a, tri2.b}, {tri2.b, tri2.c}, {tri2.c, tri2.a}}
              for _, e2 in ipairs(e2s) do
                if (e[1] == e2[1] and e[2] == e2[2]) or (e[1] == e2[2] and e[2] == e2[1]) then
                  shared = true; break
                end
              end
            end
            if shared then break end
          end
          if not shared then boundary[#boundary + 1] = e end
        end
      end
    end
    local new_triangles = {} --: { [integer]: Tri, ... }
    for i, tri in ipairs(triangles) do
      if not bad[i] then new_triangles[#new_triangles + 1] = tri end
    end
    for _, e in ipairs(boundary) do
      new_triangles[#new_triangles + 1] = make_tri(e[1], e[2], pi, all_verts)
    end
    triangles = new_triangles
  end

  -- For each site (index offset by 3), collect circumcenters of triangles that
  -- contain it, forming the Voronoi cell polygon.
  -- Also track neighbors (other sites sharing a Delaunay edge).

  local n = #sites
  local cell_cc = {} --: { [integer]: { [integer]: { x: number, y: number }, ... }, ... }
  local neighbors = {} --: { [integer]: { [integer]: boolean, ... }, ... }
  for i = 1, n do
    cell_cc[i] = {}
    neighbors[i] = {}
  end

  for _, tri in ipairs(triangles) do
    if not (tri.ccx == nil) then
      -- Map all_verts indices back to site indices (subtract 3, filter super-tri)
      local va = tri.a <= 3 and 0 or (tri.a - 3)
      local vb = tri.b <= 3 and 0 or (tri.b - 3)
      local vc = tri.c <= 3 and 0 or (tri.c - 3)
      local cc = {x = tri.ccx --[[:! number]], y = tri.ccy --[[:! number]]}
      if va > 0 then cell_cc[va][#cell_cc[va] + 1] = cc end
      if vb > 0 then cell_cc[vb][#cell_cc[vb] + 1] = cc end
      if vc > 0 then cell_cc[vc][#cell_cc[vc] + 1] = cc end
      -- Track neighbors (pairs of real sites sharing this triangle)
      if va > 0 and vb > 0 then
        neighbors[va][vb] = true; neighbors[vb][va] = true
      end
      if vb > 0 and vc > 0 then
        neighbors[vb][vc] = true; neighbors[vc][vb] = true
      end
      if va > 0 and vc > 0 then
        neighbors[va][vc] = true; neighbors[vc][va] = true
      end
    end
  end

  -- Build bounding box polygon (CCW)
  local bbox_poly = {
    {x = bx,      y = by},
    {x = bx + bw, y = by},
    {x = bx + bw, y = by + bh},
    {x = bx,      y = by + bh},
  }

  local cells = {}
  for i = 1, n do
    -- Start with the circumcenters as cell polygon candidates,
    -- then clip to bounding box.
    -- Sort CCW first, then clip.
    local verts = dedup_verts(cell_cc[i])
    verts = sort_ccw(verts)

    -- If a site is on the convex hull of the input, its Voronoi cell is unbounded.
    -- We handle this by clipping the bounding-box polygon against the Voronoi half-planes.
    -- For cells with enough circumcenters, sort+clip suffices.
    -- For boundary sites (few circumcenters), we use half-plane intersection from neighbors.

    -- Use half-plane intersection approach for all cells to be robust:
    -- cell i = intersection of half-planes {p : dist(p, site_i) <= dist(p, site_j)} for each neighbor j,
    -- clipped to bounding box.
    local poly = { --: { [integer]: { x: number, y: number }, ... }
      {x = bx,      y = by},
      {x = bx + bw, y = by},
      {x = bx + bw, y = by + bh},
      {x = bx,      y = by + bh},
    }
    local si = sites[i]
    for j, _ in pairs(neighbors[i]) do
      local sj = sites[j]
      -- Perpendicular bisector of si-sj.
      -- Half-plane containing si: points p with dot(p - midpoint, sj - si) <= 0
      -- i.e., (sj.x - si.x)*(p.x - mx) + (sj.y - si.y)*(p.y - my) <= 0
      -- The CCW-kept side in clip_poly_half is the left side of edge a->b.
      -- We want to keep si's side.
      -- Midpoint:
      local mx = (si.x + sj.x) / 2
      local my = (si.y + sj.y) / 2
      -- Direction along bisector (perpendicular to si->sj):
      local dx = sj.x - si.x
      local dy = sj.y - si.y
      -- Left normal of bisector: (-dy, dx) points toward si side
      -- Edge for clip: go along bisector so si is on the left.
      -- si is on left of (a->b) if cross(b-a, si-a) > 0.
      -- Pick a = midpoint, b = midpoint + perpendicular direction
      -- perpendicular to (dx,dy) keeping si on left: use (-dy, dx)
      -- b = (mx - dy, my + dx) -> si is left of midpoint -> (mx - dy + dy, my + dx - dx) = midpoint? Let me redo.
      -- cross((b-a), (si-a)) = cross((-dy, dx), (si.x-mx, si.y-my))
      --   = (-dy)*(si.y-my) - (dx)*(si.x-mx)
      --   = -dy*si.y + dy*my - dx*si.x + dx*mx
      --   = -(dy*si.y + dx*si.x) + (dy*my + dx*mx)
      --   = -dot((dx,dy),(si.x,si.y)) + dot((dx,dy),(mx,my))
      --   = dot((dx,dy), (mx-si.x, my-si.y))
      --   = dx*(mx-si.x) + dy*(my-si.y)
      --   = dx*((sj.x-si.x)/2) + dy*((sj.y-si.y)/2)
      --   = (dx^2 + dy^2)/2 > 0   ✓  (si is on the left)
      local ax_c = mx
      local ay_c = my
      local bx_c = mx + (-dy)
      local by_c = my + dx
      poly = clip_poly_half(poly, ax_c, ay_c, bx_c, by_c)
    end

    -- Also clip to bounding box
    poly = clip_poly_to_bounds(poly, bx, by --[[:! number]], bw, bh)
    poly = dedup_verts(poly)
    poly = sort_ccw(poly)

    -- Convert neighbor set to list
    local nbr_list = {}
    for j, _ in pairs(neighbors[i]) do nbr_list[#nbr_list + 1] = j end

    cells[i] = {site = si, vertices = poly, neighbors = nbr_list}
  end

  return {cells = cells}
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- Returns the index of the nearest site to the given point.
function M.nearest_site(diagram, point)
  local best_idx, best_d2 = nil, math.huge
  for i, cell in ipairs(diagram.cells) do
    local d2 = dist2(point.x, --[[:! number]] point.y, cell.site.x, cell.site.y)
    if d2 < best_d2 then
      best_d2 = d2
      best_idx = i
    end
  end
  return best_idx
end

-- Returns the index of the cell that contains the given point, or nil if outside bounds.
function M.find_cell(diagram, point)
  for i, cell in ipairs(diagram.cells) do
    if #cell.vertices >= 3 and point_in_polygon(point.x, --[[:! number]] point.y, cell.vertices) then
      return i
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Lloyd relaxation
-- ---------------------------------------------------------------------------

-- Runs Lloyd's algorithm: iteratively move each site to the centroid of its
-- Voronoi cell, producing more evenly distributed sites.
function M.lloyd(sites, bounds, opts)
  opts = opts or {}
  local iterations = opts.iterations or 1
  local current = {}
  for i, s in ipairs(sites) do current[i] = {x = s.x, y = s.y} end

  for _ = 1, iterations do
    local diagram = M.compute(current, bounds)
    local next_sites = {}
    for i, cell in ipairs(diagram.cells) do
      if #cell.vertices > 0 then
        local c = polygon_centroid(cell.vertices)
        if c then
          next_sites[i] = {x = c.x, y = c.y}
        else
          next_sites[i] = {x = current[i].x, y = current[i].y}
        end
      else
        next_sites[i] = {x = current[i].x, y = current[i].y}
      end
    end
    current = next_sites
  end

  return current
end

return M
