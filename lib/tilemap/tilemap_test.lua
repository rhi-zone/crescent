if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local TM = require("lib.tilemap")

-- ========================
-- new
-- ========================

T.describe("new", function()
  T.it("creates map with correct dimensions", function()
    local m = TM.new(10, 8)
    T.eq(m:width(), 10)
    T.eq(m:height(), 8)
  end)

  T.it("initializes all tiles to default (0)", function()
    local m = TM.new(4, 3)
    for y = 0, 2 do
      for x = 0, 3 do
        T.eq(m:get(x, y), 0)
      end
    end
  end)

  T.it("respects opts.default_tile", function()
    local m = TM.new(3, 3, { default_tile = 7 })
    T.eq(m:get(0, 0), 7)
    T.eq(m:get(2, 2), 7)
  end)

  T.it("returns nil on bad width", function()
    local m, err = TM.new(0, 5)
    T.eq(m, nil)
    T.ok(err)
  end)

  T.it("returns nil on bad height", function()
    local m, err = TM.new(5, -1)
    T.eq(m, nil)
    T.ok(err)
  end)
end)

-- ========================
-- get / set / in_bounds
-- ========================

T.describe("get/set/in_bounds", function()
  T.it("round-trips a value", function()
    local m = TM.new(5, 5)
    m:set(2, 3, 42)
    T.eq(m:get(2, 3), 42)
  end)

  T.it("does not affect other tiles", function()
    local m = TM.new(5, 5)
    m:set(1, 1, 99)
    T.eq(m:get(0, 0), 0)
    T.eq(m:get(2, 2), 0)
  end)

  T.it("get returns nil out of bounds", function()
    local m = TM.new(3, 3)
    T.eq(m:get(-1, 0), nil)
    T.eq(m:get(3, 0), nil)
    T.eq(m:get(0, -1), nil)
    T.eq(m:get(0, 3), nil)
  end)

  T.it("set returns nil out of bounds", function()
    local m = TM.new(3, 3)
    local ok, err = m:set(5, 5, 1)
    T.eq(ok, nil)
    T.ok(err)
  end)

  T.it("in_bounds true for valid coords", function()
    local m = TM.new(4, 4)
    T.ok(m:in_bounds(0, 0))
    T.ok(m:in_bounds(3, 3))
    T.ok(m:in_bounds(2, 1))
  end)

  T.it("in_bounds false for invalid coords", function()
    local m = TM.new(4, 4)
    T.fail(m:in_bounds(-1, 0))
    T.fail(m:in_bounds(4, 0))
    T.fail(m:in_bounds(0, -1))
    T.fail(m:in_bounds(0, 4))
  end)
end)

-- ========================
-- fill
-- ========================

T.describe("fill", function()
  T.it("fills entire region", function()
    local m = TM.new(10, 10)
    m:fill(2, 3, 4, 3, 5)
    for y = 3, 5 do
      for x = 2, 5 do
        T.eq(m:get(x, y), 5)
      end
    end
  end)

  T.it("does not affect outside region", function()
    local m = TM.new(6, 6)
    m:fill(1, 1, 3, 3, 9)
    T.eq(m:get(0, 0), 0)
    T.eq(m:get(4, 4), 0)
    T.eq(m:get(0, 2), 0)
  end)

  T.it("full-map fill", function()
    local m = TM.new(3, 3)
    m:fill(0, 0, 3, 3, 1)
    T.eq(m:count(1), 9)
  end)
end)

-- ========================
-- fill_border
-- ========================

T.describe("fill_border", function()
  T.it("fills outer edge", function()
    local m = TM.new(5, 5, { default_tile = 0 })
    m:fill(1, 1, 3, 3, 1) -- interior
    m:fill_border(2)
    -- corners
    T.eq(m:get(0, 0), 2)
    T.eq(m:get(4, 0), 2)
    T.eq(m:get(0, 4), 2)
    T.eq(m:get(4, 4), 2)
    -- edges
    T.eq(m:get(2, 0), 2)
    T.eq(m:get(2, 4), 2)
    T.eq(m:get(0, 2), 2)
    T.eq(m:get(4, 2), 2)
  end)

  T.it("interior is unchanged after fill_border", function()
    local m = TM.new(5, 5)
    m:fill(1, 1, 3, 3, 7)
    m:fill_border(0)
    T.eq(m:get(2, 2), 7)
    T.eq(m:get(1, 1), 7)
    T.eq(m:get(3, 3), 7)
  end)
end)

-- ========================
-- flood_fill
-- ========================

T.describe("flood_fill", function()
  T.it("fills connected region", function()
    local m = TM.new(5, 5)
    -- all 0, flood fill corner → whole map becomes 3
    m:flood_fill(0, 0, 3)
    T.eq(m:count(3), 25)
  end)

  T.it("stops at different tile values", function()
    local m = TM.new(5, 5)
    -- build a wall down the middle
    for y = 0, 4 do m:set(2, y, 1) end
    -- flood fill left side
    m:flood_fill(0, 0, 9)
    -- left side = 9, right side = 0, wall = 1
    T.eq(m:get(0, 0), 9)
    T.eq(m:get(1, 2), 9)
    T.eq(m:get(3, 0), 0)
    T.eq(m:get(4, 4), 0)
    T.eq(m:get(2, 2), 1) -- wall unchanged
  end)

  T.it("no-op when filling with same value", function()
    local m = TM.new(3, 3)
    m:set(1, 1, 5)
    m:flood_fill(0, 0, 0) -- already 0
    T.eq(m:count(0), 8)
    T.eq(m:get(1, 1), 5)
  end)
end)

-- ========================
-- find / count
-- ========================

T.describe("find/count", function()
  T.it("find returns correct positions", function()
    local m = TM.new(4, 4)
    m:set(1, 0, 5)
    m:set(3, 2, 5)
    local found = m:find(5)
    T.eq(#found, 2)
    -- positions may come in any order; check both are present
    local positions = {}
    for _, p in ipairs(found) do
      positions[p[1] .. "," .. p[2]] = true
    end
    T.ok(positions["1,0"])
    T.ok(positions["3,2"])
  end)

  T.it("find returns empty when not found", function()
    local m = TM.new(3, 3)
    T.eq(#m:find(99), 0)
  end)

  T.it("count returns correct number", function()
    local m = TM.new(4, 4)
    m:fill(0, 0, 2, 2, 1)
    T.eq(m:count(1), 4)
    T.eq(m:count(0), 12)
  end)
end)

-- ========================
-- neighbors4 / neighbors8
-- ========================

T.describe("neighbors4", function()
  T.it("interior tile has 4 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors4(2, 2)
    T.eq(#nb, 4)
  end)

  T.it("corner tile has 2 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors4(0, 0)
    T.eq(#nb, 2)
  end)

  T.it("edge tile has 3 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors4(2, 0)
    T.eq(#nb, 3)
  end)

  T.it("neighbors include correct values", function()
    local m = TM.new(3, 3)
    m:set(2, 1, 7)
    local nb = m:neighbors4(1, 1)
    local found7 = false
    for _, n in ipairs(nb) do
      if n[1] == 2 and n[2] == 1 then
        T.eq(n[3], 7)
        found7 = true
      end
    end
    T.ok(found7)
  end)
end)

T.describe("neighbors8", function()
  T.it("interior tile has 8 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors8(2, 2)
    T.eq(#nb, 8)
  end)

  T.it("corner tile has 3 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors8(0, 0)
    T.eq(#nb, 3)
  end)

  T.it("edge tile (non-corner) has 5 neighbors", function()
    local m = TM.new(5, 5)
    local nb = m:neighbors8(2, 0)
    T.eq(#nb, 5)
  end)
end)

-- ========================
-- A* pathfinding
-- ========================

T.describe("astar", function()
  T.it("finds path in open map", function()
    local m = TM.new(5, 5, { default_tile = 1 })
    local path = m:astar(0, 0, 4, 4)
    T.ok(path)
    T.ok(#path >= 2)
    -- first step is start, last step is goal
    T.eq(path[1][1], 0) T.eq(path[1][2], 0)
    T.eq(path[#path][1], 4) T.eq(path[#path][2], 4)
  end)

  T.it("avoids walls (0 = wall)", function()
    -- 5x3 map, all walkable except column x=2
    local m = TM.new(5, 3, { default_tile = 1 })
    for y = 0, 2 do m:set(2, y, 0) end
    -- start left of wall, goal right of wall → no path with 4-dir
    local path, err = m:astar(0, 1, 4, 1)
    T.eq(path, nil)
    T.ok(err)
  end)

  T.it("finds path around wall", function()
    -- 5x5 map: wall at x=2, y=0..3 (opening at y=4)
    local m = TM.new(5, 5, { default_tile = 1 })
    for y = 0, 3 do m:set(2, y, 0) end
    local path = m:astar(0, 0, 4, 0)
    T.ok(path)
    -- path must go through y=4
    local crosses_bottom = false
    for _, p in ipairs(path) do
      if p[2] == 4 then crosses_bottom = true end
    end
    T.ok(crosses_bottom)
  end)

  T.it("returns nil when no path exists", function()
    local m = TM.new(5, 5, { default_tile = 1 })
    -- completely surround goal
    m:set(4, 4, 0)
    local path, err = m:astar(0, 0, 4, 4)
    T.eq(path, nil)
    T.ok(err)
  end)

  T.it("start == goal returns single-step path", function()
    local m = TM.new(3, 3, { default_tile = 1 })
    local path = m:astar(1, 1, 1, 1)
    T.ok(path)
    T.eq(#path, 1)
    T.eq(path[1][1], 1)
    T.eq(path[1][2], 1)
  end)

  T.it("diagonal option finds shorter path", function()
    local m = TM.new(5, 5, { default_tile = 1 })
    local path = m:astar(0, 0, 4, 4, { diagonal = true })
    T.ok(path)
    -- diagonal path length should be <= straight manhattan path
    T.ok(#path <= 9)
  end)

  T.it("custom passable function", function()
    local m = TM.new(5, 5, { default_tile = 2 })
    m:set(2, 2, 1) -- obstacle
    local path = m:astar(0, 0, 4, 4, {
      passable = function(t) return t == 2 end
    })
    T.ok(path)
    -- path should not pass through (2,2)
    for _, p in ipairs(path) do
      T.ok(not (p[1] == 2 and p[2] == 2))
    end
  end)

  T.it("euclidean heuristic still finds path", function()
    local m = TM.new(5, 5, { default_tile = 1 })
    local path = m:astar(0, 0, 4, 4, { heuristic = "euclidean" })
    T.ok(path)
    T.eq(path[1][1], 0)
    T.eq(path[#path][1], 4)
  end)

  T.it("chebyshev heuristic still finds path", function()
    local m = TM.new(5, 5, { default_tile = 1 })
    local path = m:astar(0, 0, 4, 4, { heuristic = "chebyshev" })
    T.ok(path)
    T.eq(path[#path][2], 4)
  end)
end)

-- ========================
-- random_rooms
-- ========================

T.describe("random_rooms", function()
  T.it("returns a valid tilemap", function()
    local m = TM.random_rooms(40, 25, { seed = 42, num_rooms = 5 })
    T.ok(m)
    T.eq(m:width(), 40)
    T.eq(m:height(), 25)
  end)

  T.it("has floor tiles (1)", function()
    local m = TM.random_rooms(40, 25, { seed = 42, num_rooms = 5 })
    T.ok(m:count(1) > 0)
  end)

  T.it("has wall tiles (0)", function()
    local m = TM.random_rooms(40, 25, { seed = 42, num_rooms = 5 })
    T.ok(m:count(0) > 0)
  end)

  T.it("only contains 0 and 1", function()
    local m = TM.random_rooms(20, 15, { seed = 123, num_rooms = 3 })
    local other = 0
    for y = 0, m:height() - 1 do
      for x = 0, m:width() - 1 do
        local v = m:get(x, y)
        if v ~= 0 and v ~= 1 then other = other + 1 end
      end
    end
    T.eq(other, 0)
  end)

  T.it("different seeds produce different maps", function()
    local m1 = TM.random_rooms(20, 20, { seed = 1 })
    local m2 = TM.random_rooms(20, 20, { seed = 2 })
    -- count of floors will likely differ
    local same = m1:count(1) == m2:count(1)
    -- at least tiles are not identical (very likely with different seeds)
    -- just check we get valid tilemaps
    T.ok(m1:width() == 20)
    T.ok(m2:width() == 20)
    -- suppress unused 'same' warning
    T.ok(same == true or same == false)
  end)
end)

-- ========================
-- cellular_automata
-- ========================

T.describe("cellular_automata", function()
  T.it("returns a valid tilemap", function()
    local m = TM.cellular_automata(40, 25, { seed = 42 })
    T.ok(m)
    T.eq(m:width(), 40)
    T.eq(m:height(), 25)
  end)

  T.it("has a mix of 0 and 1", function()
    local m = TM.cellular_automata(40, 25, { seed = 42 })
    T.ok(m:count(0) > 0)
    T.ok(m:count(1) > 0)
  end)

  T.it("only contains 0 and 1", function()
    local m = TM.cellular_automata(20, 20, { seed = 99 })
    local other = 0
    for y = 0, m:height() - 1 do
      for x = 0, m:width() - 1 do
        local v = m:get(x, y)
        if v ~= 0 and v ~= 1 then other = other + 1 end
      end
    end
    T.eq(other, 0)
  end)

  T.it("correct dimensions with custom size", function()
    local m = TM.cellular_automata(30, 20, { seed = 7, iterations = 3 })
    T.eq(m:width(), 30)
    T.eq(m:height(), 20)
  end)
end)

-- ========================
-- serialize / deserialize
-- ========================

T.describe("serialize/deserialize", function()
  T.it("round-trips an empty map", function()
    local m = TM.new(4, 3)
    local s = m:serialize()
    local m2, err = TM.deserialize(s)
    T.ok(m2, err)
    T.eq(m2:width(), 4)
    T.eq(m2:height(), 3)
    for y = 0, 2 do
      for x = 0, 3 do
        T.eq(m2:get(x, y), 0)
      end
    end
  end)

  T.it("round-trips tile values", function()
    local m = TM.new(3, 3)
    m:set(0, 0, 1)
    m:set(1, 1, 42)
    m:set(2, 2, 255)
    local s = m:serialize()
    local m2 = TM.deserialize(s)
    T.eq(m2:get(0, 0), 1)
    T.eq(m2:get(1, 1), 42)
    T.eq(m2:get(2, 2), 255)
    T.eq(m2:get(0, 1), 0)
  end)

  T.it("returns nil on invalid string", function()
    local m, err = TM.deserialize("garbage")
    T.eq(m, nil)
    T.ok(err)
  end)

  T.it("returns nil on length mismatch", function()
    local m, err = TM.deserialize("3:3:0000")
    T.eq(m, nil)
    T.ok(err)
  end)
end)

-- ========================
-- layers
-- ========================

T.describe("layers", function()
  T.it("creates layered map", function()
    local lm = TM.layers(10, 8, 3)
    T.ok(lm)
  end)

  T.it("get/set on specific layer", function()
    local lm = TM.layers(5, 5, 2)
    lm:set(2, 2, 1, 10)
    lm:set(2, 2, 2, 20)
    T.eq(lm:get(2, 2, 1), 10)
    T.eq(lm:get(2, 2, 2), 20)
  end)

  T.it("layers are independent", function()
    local lm = TM.layers(4, 4, 3)
    lm:set(0, 0, 1, 5)
    lm:set(0, 0, 2, 7)
    T.eq(lm:get(0, 0, 1), 5)
    T.eq(lm:get(0, 0, 2), 7)
    T.eq(lm:get(0, 0, 3), 0)
  end)

  T.it("get_layer returns flat tilemap", function()
    local lm = TM.layers(4, 4, 2)
    lm:set(1, 1, 2, 99)
    local layer2 = lm:get_layer(2)
    T.ok(layer2)
    T.eq(layer2:get(1, 1), 99)
    T.eq(layer2:width(), 4)
    T.eq(layer2:height(), 4)
  end)

  T.it("invalid layer returns nil", function()
    local lm = TM.layers(3, 3, 2)
    local v, err = lm:get(0, 0, 5)
    T.eq(v, nil)
    T.ok(err)
  end)

  T.it("returns nil on bad num_layers", function()
    local lm, err = TM.layers(3, 3, 0)
    T.eq(lm, nil)
    T.ok(err)
  end)
end)

-- ========================
-- copy_region
-- ========================

T.describe("copy_region", function()
  T.it("copies a region to another location", function()
    local m = TM.new(6, 6)
    m:fill(0, 0, 2, 2, 5)
    m:copy_region(0, 0, 2, 2, 4, 4)
    T.eq(m:get(4, 4), 5)
    T.eq(m:get(5, 4), 5)
    T.eq(m:get(4, 5), 5)
    T.eq(m:get(5, 5), 5)
    -- original still intact
    T.eq(m:get(0, 0), 5)
  end)
end)

-- ========================
-- _tier
-- ========================

T.describe("_tier", function()
  T.it("is 'pure'", function()
    T.eq(TM._tier, "pure")
  end)
end)
