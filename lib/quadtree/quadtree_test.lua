-- lib/quadtree/quadtree_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local qt = require("lib.quadtree")

-- ---------------------------------------------------------------------------
-- Deterministic point generator
-- ---------------------------------------------------------------------------

local function gen_points(n, seed)
  local pts = {}
  local x, y = seed or 42, 7
  for i = 1, n do
    x = (x * 1664525 + 1013904223) % (2^32)
    y = (y * 1664525 + 1013904223) % (2^32)
    pts[i] = { (x % 1000) / 10, (y % 1000) / 10 }  -- 0..100 range
  end
  return pts
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local BOUNDS = { x = 0, y = 0, w = 100, h = 100 }

local function make_tree(n, seed, capacity)
  local tree = qt.new(BOUNDS, capacity or 4)
  local pts  = gen_points(n, seed)
  for i = 1, n do
    tree:insert(pts[i][1], pts[i][2], i)
  end
  return tree, pts
end

local function dist2d(ax, ay, bx, by)
  local dx = ax - bx
  local dy = ay - by
  return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("quadtree basic", function()

  T.it("inserts 100 points and count() == 100", function()
    local tree = make_tree(100)
    T.eq(tree:count(), 100)
  end)

  T.it("out-of-bounds insert returns false", function()
    local tree = qt.new(BOUNDS)
    T.eq(tree:insert(200, 200, "oob"), false)
    T.eq(tree:insert(-1, 50, "neg"), false)
    T.eq(tree:count(), 0)
  end)

  T.it("in-bounds insert returns true", function()
    local tree = qt.new(BOUNDS)
    T.eq(tree:insert(50, 50, "ok"), true)
    T.eq(tree:count(), 1)
  end)

  T.it("count() is 0 on empty tree", function()
    local tree = qt.new(BOUNDS)
    T.eq(tree:count(), 0)
  end)

  T.it("clear() empties the tree", function()
    local tree = make_tree(50)
    tree:clear()
    T.eq(tree:count(), 0)
  end)

end)

T.describe("quadtree query_rect", function()

  T.it("returns all points inside the rect", function()
    local tree, pts = make_tree(100)
    local rx, ry, rw, rh = 20, 20, 40, 40
    local results = tree:query_rect(rx, ry, rw, rh)
    -- Verify every returned point is indeed inside the rect
    for _, p in ipairs(results) do
      T.ok(p[1] >= rx and p[1] <= rx + rw, "x in rect")
      T.ok(p[2] >= ry and p[2] <= ry + rh, "y in rect")
    end
    -- Count expected manually
    local expected = 0
    for _, p in ipairs(pts) do
      if p[1] >= rx and p[1] <= rx + rw and p[2] >= ry and p[2] <= ry + rh then
        expected = expected + 1
      end
    end
    T.eq(#results, expected)
  end)

  T.it("returns no points when rect is outside all points", function()
    local tree = make_tree(50)
    -- tree bounds are 0..100; query outside
    local results = tree:query_rect(200, 200, 10, 10)
    T.eq(#results, 0)
  end)

  T.it("returns empty table for empty tree", function()
    local tree = qt.new(BOUNDS)
    T.eq(#tree:query_rect(0, 0, 100, 100), 0)
  end)

  T.it("whole-bounds rect returns all points", function()
    local tree = make_tree(60)
    local results = tree:query_rect(0, 0, 100, 100)
    T.eq(#results, 60)
  end)

  T.it("single-point rect returns at most that point", function()
    local tree = qt.new(BOUNDS)
    tree:insert(50.5, 50.5, "A")
    tree:insert(30.0, 30.0, "B")
    local results = tree:query_rect(50.5, 50.5, 0, 0)
    T.eq(#results, 1)
    T.eq(results[1][3], "A")
  end)

end)

T.describe("quadtree query_circle", function()

  T.it("all returned points are within radius", function()
    local tree = make_tree(100)
    local cx, cy, r = 50, 50, 25
    local results = tree:query_circle(cx, cy, r)
    for _, p in ipairs(results) do
      T.ok(p[4] <= r + 1e-9, "dist <= r")
      T.ok(math.abs(p[4] - dist2d(p[1], p[2], cx, cy)) < 1e-9, "dist consistent")
    end
  end)

  T.it("returns correct count (matches brute force)", function()
    local tree, pts = make_tree(100)
    local cx, cy, r = 40, 60, 20
    local results = tree:query_circle(cx, cy, r)
    local expected = 0
    for _, p in ipairs(pts) do
      if dist2d(p[1], p[2], cx, cy) <= r then expected = expected + 1 end
    end
    T.eq(#results, expected)
  end)

  T.it("results are sorted by distance ascending", function()
    local tree = make_tree(80)
    local results = tree:query_circle(50, 50, 50)
    for i = 2, #results do
      T.ok(results[i][4] >= results[i-1][4], "sorted")
    end
  end)

  T.it("returns empty for empty tree", function()
    local tree = qt.new(BOUNDS)
    T.eq(#tree:query_circle(50, 50, 100), 0)
  end)

end)

T.describe("quadtree nearest", function()

  T.it("returns nil for empty tree", function()
    local tree = qt.new(BOUNDS)
    local x = tree:nearest(50, 50)
    T.eq(x, nil)
  end)

  T.it("returns the actual closest point (brute-force check)", function()
    local tree, pts = make_tree(100)
    local cx, cy = 35, 72
    -- brute-force closest
    local best_d = math.huge
    local best_p = nil
    for _, p in ipairs(pts) do
      local d = dist2d(p[1], p[2], cx, cy)
      if d < best_d then best_d = d; best_p = p end
    end
    local nx, ny, _, nd = tree:nearest(cx, cy)
    T.ok(math.abs(nd - best_d) < 1e-9, "distance matches brute force")
    T.ok(math.abs(nx - best_p[1]) < 1e-9 and math.abs(ny - best_p[2]) < 1e-9, "coords match")
  end)

  T.it("nearest of a single inserted point is that point", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 20, "only")
    local nx, ny, data, nd = tree:nearest(50, 50)
    T.eq(nx, 10)
    T.eq(ny, 20)
    T.eq(data, "only")
    T.ok(math.abs(nd - dist2d(10, 20, 50, 50)) < 1e-9, "dist correct")
  end)

  T.it("nearest to an exact point returns dist 0", function()
    local tree = qt.new(BOUNDS)
    tree:insert(33, 44, "exact")
    local _, _, _, nd = tree:nearest(33, 44)
    T.ok(nd < 1e-12, "dist nearly 0")
  end)

end)

T.describe("quadtree knn", function()

  T.it("returns k neighbors", function()
    local tree = make_tree(100)
    local results = tree:knn(50, 50, 5)
    T.eq(#results, 5)
  end)

  T.it("knn results are sorted by distance ascending", function()
    local tree = make_tree(100)
    local results = tree:knn(50, 50, 10)
    for i = 2, #results do
      T.ok(results[i][4] >= results[i-1][4], "sorted")
    end
  end)

  T.it("knn matches brute-force top-k distances", function()
    local tree, pts = make_tree(100)
    local cx, cy, k = 25, 75, 7
    -- brute-force
    local dists = {}
    for i, p in ipairs(pts) do
      dists[i] = { dist2d(p[1], p[2], cx, cy), p[1], p[2] }
    end
    table.sort(dists, function(a, b) return a[1] < b[1] end)
    local results = tree:knn(cx, cy, k)
    T.eq(#results, k)
    for i = 1, k do
      T.ok(math.abs(results[i][4] - dists[i][1]) < 1e-9,
           "knn dist[" .. i .. "] matches brute force")
    end
  end)

  T.it("knn with k=0 returns empty", function()
    local tree = make_tree(20)
    T.eq(#tree:knn(50, 50, 0), 0)
  end)

  T.it("knn with k > n returns all n points", function()
    local tree = make_tree(10)
    local results = tree:knn(50, 50, 100)
    T.eq(#results, 10)
  end)

end)

T.describe("quadtree remove", function()

  T.it("remove returns true when point exists", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 20, "A")
    T.eq(tree:remove(10, 20), true)
  end)

  T.it("remove decrements count", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 20, "A")
    tree:insert(30, 40, "B")
    tree:remove(10, 20)
    T.eq(tree:count(), 1)
  end)

  T.it("removed point not found by query_rect", function()
    local tree = qt.new(BOUNDS)
    tree:insert(50, 50, "gone")
    tree:remove(50, 50)
    local results = tree:query_rect(0, 0, 100, 100)
    T.eq(#results, 0)
  end)

  T.it("remove returns false for missing point", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 20, "A")
    T.eq(tree:remove(99, 99), false)
  end)

  T.it("remove works correctly after subdivision", function()
    -- Use capacity 2 to force subdivision
    local tree = qt.new(BOUNDS, 2)
    tree:insert(10, 10, "a")
    tree:insert(80, 80, "b")
    tree:insert(10, 80, "c")
    -- Tree should have subdivided; now remove one
    T.eq(tree:remove(10, 10), true)
    T.eq(tree:count(), 2)
  end)

end)

T.describe("quadtree each", function()

  T.it("each visits exactly count() points", function()
    local tree = make_tree(50)
    local visited = 0
    tree:each(function() visited = visited + 1 end)
    T.eq(visited, 50)
  end)

  T.it("each collects all data values", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 10, "a")
    tree:insert(20, 20, "b")
    tree:insert(30, 30, "c")
    local collected = {}
    tree:each(function(x, y, d) collected[#collected+1] = d end)
    table.sort(collected)
    T.eq(collected[1], "a")
    T.eq(collected[2], "b")
    T.eq(collected[3], "c")
  end)

end)

T.describe("quadtree depth", function()

  T.it("depth is 1 for empty tree", function()
    local tree = qt.new(BOUNDS)
    T.eq(tree:depth(), 1)
  end)

  T.it("depth > 1 after many inserts (tree subdivides)", function()
    local tree = make_tree(100, 42, 4)
    T.ok(tree:depth() > 1, "tree should have subdivided")
  end)

  T.it("depth is 1 when all points in same leaf", function()
    local tree = qt.new(BOUNDS, 1000)
    for i = 1, 10 do
      tree:insert(i, i, i)
    end
    T.eq(tree:depth(), 1)
  end)

end)

T.describe("quadtree bbox", function()

  T.it("bbox returns nil for empty tree", function()
    local tree = qt.new(BOUNDS)
    local x = tree:bbox()
    T.eq(x, nil)
  end)

  T.it("bbox of single point", function()
    local tree = qt.new(BOUNDS)
    tree:insert(33, 77, "p")
    local x1, y1, x2, y2 = tree:bbox()
    T.eq(x1, 33)
    T.eq(y1, 77)
    T.eq(x2, 33)
    T.eq(y2, 77)
  end)

  T.it("bbox encloses all inserted points", function()
    local tree, pts = make_tree(100)
    local x1, y1, x2, y2 = tree:bbox()
    for _, p in ipairs(pts) do
      T.ok(p[1] >= x1 and p[1] <= x2, "x in bbox")
      T.ok(p[2] >= y1 and p[2] <= y2, "y in bbox")
    end
  end)

  T.it("bbox matches brute-force min/max", function()
    local tree, pts = make_tree(100)
    local mx, my, Mx, My = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(pts) do
      if p[1] < mx then mx = p[1] end
      if p[2] < my then my = p[2] end
      if p[1] > Mx then Mx = p[1] end
      if p[2] > My then My = p[2] end
    end
    local x1, y1, x2, y2 = tree:bbox()
    T.ok(math.abs(x1 - mx) < 1e-9, "x_min matches")
    T.ok(math.abs(y1 - my) < 1e-9, "y_min matches")
    T.ok(math.abs(x2 - Mx) < 1e-9, "x_max matches")
    T.ok(math.abs(y2 - My) < 1e-9, "y_max matches")
  end)

end)

T.describe("quadtree move", function()

  T.it("move updates point position", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 10, "m")
    T.eq(tree:move(10, 10, 80, 80), true)
    local r1 = tree:query_rect(8, 8, 4, 4)
    T.eq(#r1, 0)
    local r2 = tree:query_rect(78, 78, 4, 4)
    T.eq(#r2, 1)
    T.eq(r2[1][3], "m")
  end)

  T.it("move returns false for missing source", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 10, "x")
    T.eq(tree:move(99, 99, 50, 50), false)
  end)

  T.it("move returns false when destination is out of bounds", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 10, "x")
    T.eq(tree:move(10, 10, 999, 999), false)
  end)

  T.it("move keeps count the same", function()
    local tree = qt.new(BOUNDS)
    tree:insert(10, 10, "a")
    tree:insert(20, 20, "b")
    tree:move(10, 10, 50, 50)
    T.eq(tree:count(), 2)
  end)

end)

T.describe("quadtree rebuild", function()

  T.it("rebuild preserves all points", function()
    local tree = make_tree(50)
    tree:rebuild()
    T.eq(tree:count(), 50)
  end)

  T.it("rebuild after removes preserves remaining points", function()
    local tree = qt.new(BOUNDS, 2)
    tree:insert(10, 10, "a")
    tree:insert(20, 20, "b")
    tree:insert(30, 30, "c")
    tree:remove(20, 20)
    tree:rebuild()
    T.eq(tree:count(), 2)
    -- The two remaining points are still queryable
    local r = tree:query_rect(0, 0, 100, 100)
    T.eq(#r, 2)
  end)

end)

T.describe("quadtree data association", function()

  T.it("data is preserved through insert and query", function()
    local tree = qt.new(BOUNDS)
    tree:insert(11, 22, { name = "foo", val = 42 })
    local results = tree:query_rect(10, 20, 4, 4)
    T.eq(#results, 1)
    T.eq(results[1][3].name, "foo")
    T.eq(results[1][3].val, 42)
  end)

  T.it("nil data is valid", function()
    local tree = qt.new(BOUNDS)
    tree:insert(50, 50)
    T.eq(tree:count(), 1)
    local x, y, data, d = tree:nearest(50, 50)
    T.eq(x, 50)
    T.eq(y, 50)
    T.eq(data, nil)
  end)

end)
