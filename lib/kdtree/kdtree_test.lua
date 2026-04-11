-- lib/kdtree/kdtree_test.lua
-- Tests for the k-d tree spatial index.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local kdtree = require("lib.kdtree")

local sqrt = math.sqrt

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Brute-force nearest neighbor for verification.
local function brute_nearest(points, query)
  local best_d2 = math.huge
  local best_pt = nil
  for _, pt in ipairs(points) do
    local d2 = 0
    for i = 1, #query do
      local d = pt[i] - query[i]
      d2 = d2 + d * d
    end
    if d2 < best_d2 then
      best_d2 = d2
      best_pt = pt
    end
  end
  return best_pt, sqrt(best_d2)
end

-- Brute-force range search.
local function brute_range(points, query, r)
  local results = {}
  for _, pt in ipairs(points) do
    local d2 = 0
    for i = 1, #query do
      local d = pt[i] - query[i]
      d2 = d2 + d * d
    end
    if d2 <= r * r then
      results[#results + 1] = pt
    end
  end
  return results
end

-- Round a float to n decimal places for approximate equality.
local function round(x, n)
  local f = 10 ^ n
  return math.floor(x * f + 0.5) / f
end

-- ---------------------------------------------------------------------------
-- Build + size
-- ---------------------------------------------------------------------------

T.describe("kdtree.build", function()
  T.it("builds from plain 2D points", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3}}
    local tree = kdtree.build(pts)
    T.ok(tree, "tree created")
    T.eq(tree:size(), 5, "size is 5")
  end)

  T.it("builds from {point, data} pairs", function()
    local pts = {
      {point={1,2}, data="A"},
      {point={3,4}, data="B"},
      {point={5,6}, data="C"},
    }
    local tree = kdtree.build(pts)
    T.ok(tree, "tree created")
    T.eq(tree:size(), 3, "size is 3")
  end)

  T.it("builds empty tree", function()
    local tree = kdtree.build({})
    T.ok(tree, "empty tree created")
    T.eq(tree:size(), 0, "size is 0")
  end)

  T.it("builds single-point tree", function()
    local tree = kdtree.build({{42, 7}})
    T.ok(tree, "single-point tree created")
    T.eq(tree:size(), 1, "size is 1")
  end)

  T.it("returns nil, errmsg for non-table input", function()
    local t, err = kdtree.build("oops")
    T.fail(t, "should fail")
    T.ok(err, "has error message")
  end)

  T.it("builds 3D tree", function()
    local pts = {{1,2,3},{4,5,6},{7,8,9}}
    local tree = kdtree.build(pts)
    T.ok(tree, "3D tree created")
    T.eq(tree:size(), 3, "size is 3")
  end)

  T.it("builds 1D tree", function()
    local tree = kdtree.build({{1},{5},{3},{2},{4}})
    T.ok(tree, "1D tree created")
    T.eq(tree:size(), 5, "size is 5")
  end)
end)

-- ---------------------------------------------------------------------------
-- nearest()
-- ---------------------------------------------------------------------------

T.describe("tree:nearest", function()
  T.it("returns nil for empty tree", function()
    local tree = kdtree.build({})
    T.fail(tree:nearest({1,2}), "nil for empty tree")
  end)

  T.it("returns the only point for single-element tree", function()
    local tree = kdtree.build({{3,4}})
    local r = tree:nearest({0,0})
    T.ok(r, "result exists")
    T.eq(r.point[1], 3, "x")
    T.eq(r.point[2], 4, "y")
    T.eq(round(r.dist, 4), round(sqrt(9+16), 4), "distance is 5")
  end)

  T.it("finds exact match (distance 0)", function()
    local pts = {{1,2},{3,4},{5,6}}
    local tree = kdtree.build(pts)
    local r = tree:nearest({3,4})
    T.ok(r, "result exists")
    T.eq(r.point[1], 3, "x")
    T.eq(r.point[2], 4, "y")
    T.eq(r.dist, 0, "distance is 0")
  end)

  T.it("returns correct nearest against brute force (2D, 10 points)", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3},{4,5},{6,7},{8,9},{1,8},{5,2}}
    local tree = kdtree.build(pts)
    local queries = {{3,3},{0,0},{6,6},{9,9},{1,1}}
    for _, q in ipairs(queries) do
      local r = tree:nearest(q)
      local _bp, bd = brute_nearest(pts, q)
      T.ok(r, "result exists for query " .. q[1] .. "," .. q[2])
      -- Distance must match the brute-force minimum (ties are fine — any equidistant point is valid)
      T.eq(round(r.dist, 6), round(bd, 6), "dist matches brute force minimum")
    end
  end)

  T.it("returns correct nearest for 3D points", function()
    local pts = {{1,2,3},{4,5,6},{7,8,9},{2,1,3}}
    local tree = kdtree.build(pts)
    local q = {2,3,4}
    local r = tree:nearest(q)
    local bp, bd = brute_nearest(pts, q)
    T.ok(r, "result exists")
    T.eq(round(r.dist, 6), round(bd, 6), "dist matches brute force")
    T.eq(r.point[1], bp[1], "x")
    T.eq(r.point[2], bp[2], "y")
    T.eq(r.point[3], bp[3], "z")
  end)

  T.it("preserves data field in nearest result", function()
    local pts = {
      {point={1,2}, data="A"},
      {point={3,4}, data="B"},
      {point={5,6}, data="C"},
    }
    local tree = kdtree.build(pts)
    local r = tree:nearest({3,4})
    T.eq(r.data, "B", "data is B")
  end)

  T.it("handles collinear points", function()
    -- All points on x-axis
    local pts = {{1,0},{2,0},{3,0},{4,0},{5,0}}
    local tree = kdtree.build(pts)
    local r = tree:nearest({2.4, 0})
    T.ok(r, "result exists")
    -- Closest should be {2,0} or {3,0} — dist to {2,0} = 0.4, to {3,0} = 0.6
    T.eq(r.point[1], 2, "closest is x=2")
    T.eq(round(r.dist, 4), 0.4, "dist is 0.4")
  end)
end)

-- ---------------------------------------------------------------------------
-- knn()
-- ---------------------------------------------------------------------------

T.describe("tree:knn", function()
  T.it("returns empty array for empty tree", function()
    local tree = kdtree.build({})
    local r = tree:knn({1,2}, 3)
    T.eq(#r, 0, "empty result")
  end)

  T.it("returns all points when k >= tree size", function()
    local pts = {{1,2},{3,4},{5,6}}
    local tree = kdtree.build(pts)
    local r = tree:knn({3,4}, 10)
    T.eq(#r, 3, "returns all 3 points")
  end)

  T.it("returns k=1 same as nearest", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3}}
    local tree = kdtree.build(pts)
    local q = {3,3}
    local nn  = tree:nearest(q)
    local knn = tree:knn(q, 1)
    T.eq(#knn, 1, "one result")
    T.eq(round(knn[1].dist, 8), round(nn.dist, 8), "same distance as nearest")
    T.eq(knn[1].point[1], nn.point[1], "same x as nearest")
    T.eq(knn[1].point[2], nn.point[2], "same y as nearest")
  end)

  T.it("returns results sorted by distance ascending", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3},{4,5},{6,7},{8,9},{1,8},{5,2}}
    local tree = kdtree.build(pts)
    local r = tree:knn({4,4}, 5)
    T.eq(#r, 5, "5 results")
    for i = 2, #r do
      T.ok(r[i].dist >= r[i-1].dist, "results sorted by dist")
    end
  end)

  T.it("knn distances match brute force top-3", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3},{4,5},{6,7},{8,9},{1,8},{5,2}}
    local tree = kdtree.build(pts)
    local q = {3,3}
    local r = tree:knn(q, 3)
    T.eq(#r, 3, "3 results")
    -- Brute-force: compute all distances, sort, take top 3
    local all = {}
    for _, pt in ipairs(pts) do
      local d = 0
      for i = 1, #q do local dd = pt[i]-q[i]; d = d + dd*dd end
      all[#all+1] = {sqrt(d), pt}
    end
    table.sort(all, function(a,b) return a[1] < b[1] end)
    for i = 1, 3 do
      T.eq(round(r[i].dist, 6), round(all[i][1], 6), "dist " .. i .. " matches brute force")
    end
  end)

  T.it("preserves data in knn results", function()
    local pts = {
      {point={1,2}, data="A"},
      {point={3,4}, data="B"},
      {point={5,6}, data="C"},
    }
    local tree = kdtree.build(pts)
    local r = tree:knn({1,2}, 2)
    T.eq(#r, 2, "2 results")
    -- Closest to {1,2}: {1,2}=0, {3,4}=sqrt(8)
    T.eq(r[1].data, "A", "first result is A")
    T.eq(r[2].data, "B", "second result is B")
  end)
end)

-- ---------------------------------------------------------------------------
-- range()
-- ---------------------------------------------------------------------------

T.describe("tree:range", function()
  T.it("returns empty for empty tree", function()
    local tree = kdtree.build({})
    T.eq(#tree:range({0,0}, 5), 0, "empty")
  end)

  T.it("returns all points within radius", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3}}
    local tree = kdtree.build(pts)
    local r = tree:range({3,3}, 2.0)
    T.ok(#r >= 2, "at least 2 points within radius 2")
    -- Verify all returned points are actually within radius
    for _, item in ipairs(r) do
      T.ok(item.dist <= 2.0 + 1e-9, "point within radius")
    end
  end)

  T.it("returns no points outside radius", function()
    local pts = {{10,10},{20,20},{30,30}}
    local tree = kdtree.build(pts)
    local r = tree:range({0,0}, 5.0)
    T.eq(#r, 0, "no points within radius 5 of origin")
  end)

  T.it("includes point exactly on radius boundary", function()
    -- Point at distance exactly 5 from origin
    local pts = {{3,4},{10,10}}
    local tree = kdtree.build(pts)
    local r = tree:range({0,0}, 5.0)
    T.eq(#r, 1, "point at exact radius included")
    T.eq(r[1].point[1], 3, "x")
    T.eq(r[1].point[2], 4, "y")
  end)

  T.it("range results match brute force", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3},{4,5},{6,7},{8,9},{1,8},{5,2}}
    local tree = kdtree.build(pts)
    local q, r_val = {5,5}, 3.0
    local got    = tree:range(q, r_val)
    local expect = brute_range(pts, q, r_val)
    T.eq(#got, #expect, "same count as brute force")
    -- Verify each returned point is from brute-force set
    for _, item in ipairs(got) do
      local found = false
      for _, ep in ipairs(expect) do
        if ep[1] == item.point[1] and ep[2] == item.point[2] then
          found = true; break
        end
      end
      T.ok(found, "range result in brute-force set")
    end
  end)

  T.it("returns distances in range results", function()
    local pts = {{3,4},{0,0}}
    local tree = kdtree.build(pts)
    local r = tree:range({0,0}, 6.0)
    T.eq(#r, 2, "both points returned")
    local has_zero = false
    for _, item in ipairs(r) do
      if item.dist == 0 then has_zero = true end
    end
    T.ok(has_zero, "origin point has dist 0")
  end)

  T.it("3D range search", function()
    local pts = {{1,1,1},{5,5,5},{2,2,2},{9,9,9}}
    local tree = kdtree.build(pts)
    local r = tree:range({2,2,2}, 2.0)
    T.ok(#r >= 2, "at least {1,1,1} and {2,2,2}")
    for _, item in ipairs(r) do
      T.ok(item.dist <= 2.0 + 1e-9, "within radius 2")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- box()
-- ---------------------------------------------------------------------------

T.describe("tree:box", function()
  T.it("returns empty for empty tree", function()
    local tree = kdtree.build({})
    T.eq(#tree:box({min={0,0},max={10,10}}), 0, "empty")
  end)

  T.it("finds points inside box", function()
    local pts = {{1,2},{3,4},{5,6},{7,8},{2,3}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={1,1},max={5,5}})
    -- Should contain: {1,2},{3,4},{2,3} — not {5,6} (6>5), not {7,8}
    T.eq(#r, 3, "3 points inside box")
  end)

  T.it("finds no points outside box", function()
    local pts = {{10,10},{20,20}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={0,0},max={5,5}})
    T.eq(#r, 0, "no points in box")
  end)

  T.it("includes points on box boundary", function()
    local pts = {{1,1},{5,5},{3,3}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={1,1},max={5,5}})
    T.eq(#r, 3, "all 3 on/inside boundary")
  end)

  T.it("box corners", function()
    local pts = {{0,0},{10,0},{0,10},{10,10},{5,5}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={0,0},max={10,10}})
    T.eq(#r, 5, "all 5 inside box")
  end)

  T.it("box excludes exact-boundary outside", function()
    -- Point at {11,5} — outside box by x
    local pts = {{5,5},{11,5},{5,11}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={0,0},max={10,10}})
    T.eq(#r, 1, "only {5,5} inside")
    T.eq(r[1].point[1], 5)
    T.eq(r[1].point[2], 5)
  end)

  T.it("3D box search", function()
    local pts = {{1,1,1},{2,2,2},{5,5,5},{3,3,3}}
    local tree = kdtree.build(pts)
    local r = tree:box({min={1,1,1},max={3,3,3}})
    T.eq(#r, 3, "{1,1,1},{2,2,2},{3,3,3} inside")
  end)

  T.it("data preserved in box results", function()
    local pts = {
      {point={1,1}, data="X"},
      {point={5,5}, data="Y"},
      {point={9,9}, data="Z"},
    }
    local tree = kdtree.build(pts)
    local r = tree:box({min={0,0},max={6,6}})
    T.eq(#r, 2, "2 inside box")
    local datas = {}
    for _, item in ipairs(r) do datas[item.data] = true end
    T.ok(datas["X"], "X inside")
    T.ok(datas["Y"], "Y inside")
    T.fail(datas["Z"], "Z outside")
  end)
end)

-- ---------------------------------------------------------------------------
-- insert() and rebuild()
-- ---------------------------------------------------------------------------

T.describe("tree:insert", function()
  T.it("size increases after insert", function()
    local tree = kdtree.build({{1,2},{3,4}})
    T.eq(tree:size(), 2, "size 2 before insert")
    tree:insert({5,6})
    T.eq(tree:size(), 3, "size 3 after insert")
  end)

  T.it("nearest finds inserted point", function()
    local tree = kdtree.build({{1,2},{3,4},{5,6}})
    tree:insert({10, 10})
    local r = tree:nearest({9, 9})
    T.ok(r, "result exists")
    T.eq(r.point[1], 10, "x=10")
    T.eq(r.point[2], 10, "y=10")
  end)

  T.it("inserted point appears in range search", function()
    local tree = kdtree.build({{100,100},{200,200}})
    tree:insert({5,5})
    local r = tree:range({4,4}, 3.0)
    T.ok(#r >= 1, "finds inserted point in range")
    local found = false
    for _, item in ipairs(r) do
      if item.point[1] == 5 and item.point[2] == 5 then found = true end
    end
    T.ok(found, "inserted point at {5,5} in range results")
  end)

  T.it("insert into empty tree", function()
    local tree = kdtree.build({})
    tree:insert({3,3})
    T.eq(tree:size(), 1, "size is 1")
    local r = tree:nearest({3,3})
    T.ok(r, "nearest found")
    T.eq(r.dist, 0, "distance 0")
  end)

  T.it("insert with data", function()
    local tree = kdtree.build({{1,2},{3,4}})
    tree:insert({10,10}, "new point")
    local r = tree:nearest({10,10})
    T.eq(r.data, "new point", "data preserved")
  end)
end)

T.describe("tree:rebuild", function()
  T.it("preserves all points after rebuild", function()
    local pts = {{1,2},{3,4},{5,6},{7,8}}
    local tree = kdtree.build(pts)
    tree:insert({9,10})
    tree:insert({11,12})
    local sz_before = tree:size()
    tree:rebuild()
    T.eq(tree:size(), sz_before, "same number of points after rebuild")
  end)

  T.it("nearest still correct after rebuild", function()
    local pts = {{1,2},{3,4},{5,6}}
    local tree = kdtree.build(pts)
    tree:insert({100,100})
    tree:insert({101,101})
    tree:insert({102,102})
    tree:rebuild()
    local r = tree:nearest({3,4})
    T.eq(round(r.dist, 8), 0, "exact match after rebuild")
    T.eq(r.point[1], 3)
    T.eq(r.point[2], 4)
  end)

  T.it("rebuild empty tree is safe", function()
    local tree = kdtree.build({})
    tree:rebuild()
    T.eq(tree:size(), 0, "still empty")
  end)
end)

-- ---------------------------------------------------------------------------
-- Large random set: nearest matches brute force
-- ---------------------------------------------------------------------------

T.describe("large random set", function()
  T.it("100 random 2D points: nearest matches brute force on 10 queries", function()
    math.randomseed(42)
    local pts = {}
    for i = 1, 100 do
      pts[i] = {math.random() * 100, math.random() * 100}
    end
    local tree = kdtree.build(pts)
    T.eq(tree:size(), 100, "100 points in tree")
    for _ = 1, 10 do
      local q = {math.random() * 100, math.random() * 100}
      local r  = tree:nearest(q)
      local bp, bd = brute_nearest(pts, q)
      T.ok(r, "result exists")
      T.eq(round(r.dist, 4), round(bd, 4), "dist matches brute force")
      T.eq(r.point[1], bp[1], "x matches brute force")
      T.eq(r.point[2], bp[2], "y matches brute force")
    end
  end)

  T.it("100 random 2D points: range matches brute force on 5 queries", function()
    math.randomseed(99)
    local pts = {}
    for i = 1, 100 do
      pts[i] = {math.random() * 100, math.random() * 100}
    end
    local tree = kdtree.build(pts)
    for _ = 1, 5 do
      local q = {math.random() * 100, math.random() * 100}
      local rad = 15.0
      local got    = tree:range(q, rad)
      local expect = brute_range(pts, q, rad)
      T.eq(#got, #expect, "range count matches brute force")
    end
  end)

  T.it("50 random 3D points: nearest matches brute force on 5 queries", function()
    math.randomseed(777)
    local pts = {}
    for i = 1, 50 do
      pts[i] = {math.random()*50, math.random()*50, math.random()*50}
    end
    local tree = kdtree.build(pts)
    for _ = 1, 5 do
      local q = {math.random()*50, math.random()*50, math.random()*50}
      local r  = tree:nearest(q)
      local bp, bd = brute_nearest(pts, q)
      T.ok(r, "result exists")
      T.eq(round(r.dist, 4), round(bd, 4), "3D dist matches brute force")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

local summary = T._summary()
local total = summary.pass + summary.fail
print(string.format("\n%d/%d assertions passed", summary.pass, total))
if summary.fail > 0 then
  print("FAILED TESTS:")
  for _, t in ipairs(summary.tests) do
    if not t.ok then
      print("  FAIL: " .. t.name)
      if t.err then print("    " .. t.err) end
    end
  end
  os.exit(1)
else
  print("All tests passed.")
end
