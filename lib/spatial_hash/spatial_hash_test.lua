if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local SH = require("lib.spatial_hash")

-- helper: check if value is in array
local function has(t, v)
  for _, x in ipairs(t) do
    if x == v then return true end
  end
  return false
end

T.describe("spatial_hash", function()

  T.describe("module", function()
    T.it("has _tier = pure", function()
      T.eq(SH._tier, "pure")
    end)

    T.it("new returns a grid", function()
      local g = SH.new(64)
      T.ok(g ~= nil)
      T.eq(type(g), "table")
    end)

    T.it("default cell_size is 64", function()
      local g = SH.new()
      T.eq(g._cs, 64)
    end)
  end)

  T.describe("insert / query_point (point objects)", function()
    T.it("point found at exact location", function()
      local g = SH.new(64)
      g:insert("a", 10, 20)
      local r = g:query_point(10, 20)
      T.ok(has(r, "a"), "point should be found at its own location")
    end)

    T.it("point found anywhere in same cell", function()
      local g = SH.new(64)
      g:insert("a", 10, 20)
      -- 63, 63 is still in cell (0,0) along with (10,20)
      local r = g:query_point(63, 63)
      T.ok(has(r, "a"))
    end)

    T.it("point NOT found far away (different cell)", function()
      local g = SH.new(64)
      g:insert("a", 10, 20)
      local r = g:query_point(200, 200)
      T.ok(not has(r, "a"), "point should not be found in a distant cell")
    end)

    T.it("multiple points in same cell all returned", function()
      local g = SH.new(64)
      g:insert("a", 5, 5)
      g:insert("b", 10, 10)
      g:insert("c", 300, 300)
      local r = g:query_point(5, 5)
      T.ok(has(r, "a"))
      T.ok(has(r, "b"))
      T.ok(not has(r, "c"))
    end)

    T.it("second insert replaces first for same id", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("a", 300, 300)  -- replaces
      T.eq(g:count(), 1)
      local r1 = g:query_point(10, 10)
      local r2 = g:query_point(300, 300)
      T.ok(not has(r1, "a"), "old position should be gone")
      T.ok(has(r2, "a"), "new position should be found")
    end)
  end)

  T.describe("insert_rect / query_rect", function()
    T.it("rect found when query rect overlaps it", function()
      local g = SH.new(64)
      g:insert_rect("box", 100, 100, 50, 50)
      -- query overlaps the rect
      local r = g:query_rect(110, 110, 10, 10)
      T.ok(has(r, "box"))
    end)

    T.it("rect NOT found when query rect does not overlap", function()
      local g = SH.new(64)
      g:insert_rect("box", 100, 100, 50, 50)
      -- query far away
      local r = g:query_rect(500, 500, 10, 10)
      T.ok(not has(r, "box"))
    end)

    T.it("large rect spans multiple cells and is found from any", function()
      local g = SH.new(64)
      -- rect spans 4 cells horizontally and vertically
      g:insert_rect("big", 0, 0, 200, 200)
      local r1 = g:query_rect(0, 0, 1, 1)
      local r2 = g:query_rect(190, 190, 5, 5)
      T.ok(has(r1, "big"))
      T.ok(has(r2, "big"))
    end)

    T.it("rect found exactly once in deduplication", function()
      local g = SH.new(64)
      g:insert_rect("box", 0, 0, 200, 200)
      local r = g:query_rect(0, 0, 200, 200)
      local count = 0
      for _, id in ipairs(r) do
        if id == "box" then count = count + 1 end
      end
      T.eq(count, 1)
    end)
  end)

  T.describe("insert_rect / query_point (point inside rect)", function()
    T.it("point inside rect is found", function()
      local g = SH.new(64)
      g:insert_rect("box", 50, 50, 100, 100)
      -- query the point at center of rect
      local r = g:query_point(100, 100)
      T.ok(has(r, "box"), "point inside rect should find the rect")
    end)

    T.it("point outside rect bounds not found even if same cell", function()
      local g = SH.new(64)
      -- small rect in bottom-left of a cell
      g:insert_rect("box", 0, 0, 10, 10)
      -- query a point in the same cell but outside the rect
      local r = g:query_point(50, 50)
      T.ok(not has(r, "box"), "point outside rect AABB should not match")
    end)
  end)

  T.describe("query_radius", function()
    T.it("point within radius is found", function()
      local g = SH.new(64)
      g:insert("a", 100, 100)
      local r = g:query_radius(100, 100, 10)
      T.ok(has(r, "a"))
    end)

    T.it("point exactly on circle boundary is found", function()
      local g = SH.new(64)
      g:insert("a", 110, 100)  -- exactly 10 units from (100,100)
      local r = g:query_radius(100, 100, 10)
      T.ok(has(r, "a"))
    end)

    T.it("point outside radius is NOT found", function()
      local g = SH.new(64)
      g:insert("a", 200, 200)
      local r = g:query_radius(100, 100, 10)
      T.ok(not has(r, "a"))
    end)

    T.it("point just outside radius is NOT found (exact check)", function()
      local g = SH.new(64)
      -- distance = sqrt(2) * 8 ≈ 11.31, radius = 10
      g:insert("a", 108, 108)
      local r = g:query_radius(100, 100, 10)
      T.ok(not has(r, "a"), "point just outside radius should be excluded")
    end)

    T.it("multiple objects: only those within radius returned", function()
      local g = SH.new(64)
      g:insert("close", 105, 100)   -- distance 5
      g:insert("far",   200, 200)   -- distance ~141
      local r = g:query_radius(100, 100, 20)
      T.ok(has(r, "close"))
      T.ok(not has(r, "far"))
    end)
  end)

  T.describe("remove", function()
    T.it("returns true when object existed", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      T.ok(g:remove("a") == true)
    end)

    T.it("returns false when object not in grid", function()
      local g = SH.new(64)
      T.ok(g:remove("missing") == false)
    end)

    T.it("removed object not returned by query", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:remove("a")
      local r = g:query_point(10, 10)
      T.ok(not has(r, "a"))
    end)

    T.it("count decreases after remove", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("b", 20, 20)
      T.eq(g:count(), 2)
      g:remove("a")
      T.eq(g:count(), 1)
    end)

    T.it("removed rect not returned by query_rect", function()
      local g = SH.new(64)
      g:insert_rect("box", 100, 100, 50, 50)
      g:remove("box")
      local r = g:query_rect(110, 110, 10, 10)
      T.ok(not has(r, "box"))
    end)
  end)

  T.describe("move", function()
    T.it("point found at new position", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:move("a", 300, 300)
      local r = g:query_point(300, 300)
      T.ok(has(r, "a"))
    end)

    T.it("point NOT found at old position after move", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:move("a", 300, 300)
      local r = g:query_point(10, 10)
      T.ok(not has(r, "a"))
    end)

    T.it("count unchanged after move", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:move("a", 300, 300)
      T.eq(g:count(), 1)
    end)

    T.it("get returns new position", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:move("a", 300, 400)
      local x, y = g:get("a")
      T.eq(x, 300)
      T.eq(y, 400)
    end)

    T.it("move_rect: found at new rect, not at old", function()
      local g = SH.new(64)
      g:insert_rect("box", 0, 0, 10, 10)
      g:move_rect("box", 500, 500, 20, 20)
      local r_old = g:query_rect(0, 0, 5, 5)
      local r_new = g:query_rect(505, 505, 5, 5)
      T.ok(not has(r_old, "box"))
      T.ok(has(r_new, "box"))
    end)

    T.it("get returns new rect position and size", function()
      local g = SH.new(64)
      g:insert_rect("box", 0, 0, 10, 10)
      g:move_rect("box", 50, 60, 30, 40)
      local x, y, w, h = g:get("box")
      T.eq(x, 50)
      T.eq(y, 60)
      T.eq(w, 30)
      T.eq(h, 40)
    end)
  end)

  T.describe("get", function()
    T.it("returns nil for unknown id", function()
      local g = SH.new(64)
      T.ok(g:get("nope") == nil)
    end)

    T.it("returns x, y for point", function()
      local g = SH.new(64)
      g:insert("a", 42, 99)
      local x, y = g:get("a")
      T.eq(x, 42)
      T.eq(y, 99)
    end)

    T.it("returns x, y, w, h for rect", function()
      local g = SH.new(64)
      g:insert_rect("r", 1, 2, 3, 4)
      local x, y, w, h = g:get("r")
      T.eq(x, 1)
      T.eq(y, 2)
      T.eq(w, 3)
      T.eq(h, 4)
    end)
  end)

  T.describe("nearest", function()
    T.it("returns closest object first", function()
      local g = SH.new(64)
      g:insert(1, 100, 100)
      g:insert(2, 105, 100)  -- closer
      g:insert(3, 200, 200)  -- farther
      local r = g:nearest(100, 100, 2)
      T.eq(r[1], 1)   -- self (distance 0)
      T.eq(r[2], 2)
    end)

    T.it("returns at most n results", function()
      local g = SH.new(64)
      for i = 1, 10 do
        g:insert(i, i * 10, 0)
      end
      local r = g:nearest(0, 0, 3)
      T.eq(#r, 3)
    end)

    T.it("returns all if fewer than n objects", function()
      local g = SH.new(64)
      g:insert("a", 10, 0)
      g:insert("b", 20, 0)
      local r = g:nearest(0, 0, 5)
      T.eq(#r, 2)
    end)

    T.it("nearest order is correct across cells", function()
      local g = SH.new(64)
      g:insert("near", 110, 100)   -- distance 10
      g:insert("far",  200, 100)   -- distance 100
      local r = g:nearest(100, 100, 2)
      T.eq(r[1], "near")
      T.eq(r[2], "far")
    end)
  end)

  T.describe("count", function()
    T.it("starts at 0", function()
      local g = SH.new(64)
      T.eq(g:count(), 0)
    end)

    T.it("increases on insert", function()
      local g = SH.new(64)
      g:insert("a", 1, 1)
      T.eq(g:count(), 1)
      g:insert("b", 2, 2)
      T.eq(g:count(), 2)
    end)

    T.it("unchanged when reinserting same id", function()
      local g = SH.new(64)
      g:insert("a", 1, 1)
      g:insert("a", 2, 2)
      T.eq(g:count(), 1)
    end)

    T.it("decreases on remove", function()
      local g = SH.new(64)
      g:insert("a", 1, 1)
      g:insert("b", 2, 2)
      g:remove("a")
      T.eq(g:count(), 1)
    end)
  end)

  T.describe("clear", function()
    T.it("count becomes 0", function()
      local g = SH.new(64)
      g:insert("a", 1, 1)
      g:insert("b", 2, 2)
      g:insert_rect("r", 100, 100, 50, 50)
      g:clear()
      T.eq(g:count(), 0)
    end)

    T.it("objects not returned by query after clear", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:clear()
      local r = g:query_point(10, 10)
      T.ok(not has(r, "a"))
    end)

    T.it("can insert after clear", function()
      local g = SH.new(64)
      g:insert("a", 1, 1)
      g:clear()
      g:insert("b", 10, 10)
      T.eq(g:count(), 1)
      local r = g:query_point(10, 10)
      T.ok(has(r, "b"))
    end)
  end)

  T.describe("each", function()
    T.it("visits all objects", function()
      local g = SH.new(64)
      g:insert("a", 1, 2)
      g:insert("b", 3, 4)
      g:insert_rect("r", 10, 20, 5, 6)
      local seen = {}
      g:each(function(id) seen[id] = true end)
      T.ok(seen["a"])
      T.ok(seen["b"])
      T.ok(seen["r"])
    end)

    T.it("passes correct coords for point", function()
      local g = SH.new(64)
      g:insert("a", 42, 99)
      local got_x, got_y
      g:each(function(id, x, y) if id == "a" then got_x, got_y = x, y end end)
      T.eq(got_x, 42)
      T.eq(got_y, 99)
    end)

    T.it("passes correct coords for rect", function()
      local g = SH.new(64)
      g:insert_rect("r", 1, 2, 3, 4)
      local gx, gy, gw, gh
      g:each(function(id, x, y, w, h)
        if id == "r" then gx, gy, gw, gh = x, y, w, h end
      end)
      T.eq(gx, 1); T.eq(gy, 2); T.eq(gw, 3); T.eq(gh, 4)
    end)
  end)

  T.describe("pairs", function()
    T.it("two objects in same cell are reported", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("b", 20, 20)
      local found = false
      g:pairs(function(id1, id2)
        if (id1 == "a" and id2 == "b") or (id1 == "b" and id2 == "a") then
          found = true
        end
      end)
      T.ok(found)
    end)

    T.it("objects in different cells are NOT reported", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("b", 1000, 1000)
      local count = 0
      g:pairs(function() count = count + 1 end)
      T.eq(count, 0)
    end)

    T.it("each pair reported at most once", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("b", 20, 20)
      g:insert("c", 30, 30)
      local counts = {}
      g:pairs(function(id1, id2)
        local key = id1 .. "|" .. id2
        counts[key] = (counts[key] or 0) + 1
      end)
      for _, v in pairs(counts) do
        T.ok(v == 1, "pair should be reported exactly once")
      end
    end)

    T.it("rect and point in same cell are reported", function()
      local g = SH.new(64)
      g:insert("pt", 10, 10)
      g:insert_rect("rect", 0, 0, 50, 50)
      local found = false
      g:pairs(function(a, b)
        if (a == "pt" and b == "rect") or (a == "rect" and b == "pt") then
          found = true
        end
      end)
      T.ok(found)
    end)
  end)

  T.describe("stats", function()
    T.it("returns table with required fields", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      local s = g:stats()
      T.ok(type(s) == "table")
      T.ok(s.cells ~= nil)
      T.ok(s.objects ~= nil)
      T.ok(s.avg_per_cell ~= nil)
    end)

    T.it("objects count matches grid count", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      g:insert("b", 20, 20)
      local s = g:stats()
      T.eq(s.objects, 2)
    end)

    T.it("cells is non-zero after insert", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      local s = g:stats()
      T.ok(s.cells >= 1)
    end)

    T.it("avg_per_cell is positive after insert", function()
      local g = SH.new(64)
      g:insert("a", 10, 10)
      local s = g:stats()
      T.ok(s.avg_per_cell > 0)
    end)

    T.it("cells=0 and avg_per_cell=0 for empty grid", function()
      local g = SH.new(64)
      local s = g:stats()
      T.eq(s.cells, 0)
      T.eq(s.objects, 0)
      T.eq(s.avg_per_cell, 0)
    end)
  end)

  T.describe("large scale", function()
    T.it("insert 100 point objects, query returns correct subset", function()
      local g = SH.new(64)
      -- insert 100 objects spread out in a 10x10 grid of cells
      for i = 0, 9 do
        for j = 0, 9 do
          g:insert(i * 10 + j, i * 100, j * 100)
        end
      end
      T.eq(g:count(), 100)

      -- query a small region: only objects in cells near (0,0)
      local r = g:query_point(0, 0)
      -- only object at exactly (0,0) is id=0
      T.ok(has(r, 0))
      -- object at (100, 0) is in a different cell
      T.ok(not has(r, 1), "object in different cell should not appear")
    end)

    T.it("query_radius on 100 objects returns only those within radius", function()
      local g = SH.new(64)
      for i = 1, 100 do
        g:insert(i, i * 5, 0)  -- at x=5,10,15,...,500
      end
      -- radius 25 around origin: objects at x=5,10,15,20,25 (ids 1..5)
      local r = g:query_radius(0, 0, 25)
      for _, id in ipairs(r) do
        local x = id * 5
        T.ok(x <= 25, "object outside radius should not be in result")
      end
      T.ok(has(r, 1))
      T.ok(has(r, 5))
      T.ok(not has(r, 6))
    end)

    T.it("100 rects: query_rect finds correct ones", function()
      local g = SH.new(128)
      -- 10x10 grid of 20x20 rects with 10-unit gaps
      for i = 0, 9 do
        for j = 0, 9 do
          local id = i * 10 + j
          g:insert_rect(id, i * 30, j * 30, 20, 20)
        end
      end
      T.eq(g:count(), 100)
      -- query region around first rect
      local r = g:query_rect(0, 0, 19, 19)
      T.ok(has(r, 0))
    end)
  end)

end)
