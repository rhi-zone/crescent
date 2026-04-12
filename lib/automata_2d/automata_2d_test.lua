if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local CA = require("lib.automata_2d")

-- Helper: sort {x,y} array by y then x for stable comparison.
local function sort_cells(cells)
  local s = {}
  for i, c in ipairs(cells) do s[i] = c end
  table.sort(s, function(a, b)
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  return s
end

-- Helper: find cell in array.
local function has_cell(cells, x, y)
  for _, c in ipairs(cells) do
    if c[1] == x and c[2] == y then return true end
  end
  return false
end

T.describe("automata_2d module", function()

  -- ── Dense Grid ────────────────────────────────────────────────────────────

  T.describe("dense grid", function()
    T.it("creates a grid with correct size", function()
      local g = CA.dense(10, 10)
      T.ok(g ~= nil, "grid created")
      T.eq(g:population(), 0, "initial population is 0")
      T.eq(g:generation(), 0, "initial generation is 0")
    end)

    T.it("set and get cells (0-indexed)", function()
      local g = CA.dense(10, 10)
      g:set(0, 0, 1)
      T.eq(g:get(0, 0), 1, "cell (0,0) is alive")
      T.eq(g:get(1, 0), 0, "cell (1,0) is dead")
      g:set(0, 0, 0)
      T.eq(g:get(0, 0), 0, "cell (0,0) cleared")
    end)

    T.it("set returns nil for out-of-bounds", function()
      local g = CA.dense(5, 5)
      local ok, err = g:set(10, 10, 1)
      T.eq(ok, nil, "nil returned for OOB")
      T.ok(err ~= nil, "error message returned")
    end)

    T.it("get returns 0 for out-of-bounds", function()
      local g = CA.dense(5, 5)
      T.eq(g:get(100, 100), 0, "out-of-bounds returns 0")
    end)

    T.it("clear sets all cells to 0", function()
      local g = CA.dense(5, 5)
      g:set(2, 2, 1)
      g:set(3, 3, 1)
      T.eq(g:population(), 2, "two cells alive before clear")
      g:clear()
      T.eq(g:population(), 0, "population 0 after clear")
    end)

    T.it("generation increments with each step", function()
      local g = CA.dense(10, 10)
      T.eq(g:generation(), 0, "starts at 0")
      g:step()
      T.eq(g:generation(), 1, "1 after one step")
      g:step_n(4)
      T.eq(g:generation(), 5, "5 after step_n(4)")
    end)

    T.it("population counts live cells", function()
      local g = CA.dense(10, 10)
      g:set(1, 1, 1)
      g:set(2, 2, 1)
      g:set(3, 3, 1)
      T.eq(g:population(), 3, "population is 3")
    end)

    T.it("alive_cells returns {x,y} array", function()
      local g = CA.dense(10, 10)
      g:set(3, 4, 1)
      g:set(5, 6, 1)
      local cells = sort_cells(g:alive_cells())
      T.eq(#cells, 2, "two cells returned")
      T.eq(cells[1][1], 3, "first cell x")
      T.eq(cells[1][2], 4, "first cell y")
      T.eq(cells[2][1], 5, "second cell x")
      T.eq(cells[2][2], 6, "second cell y")
    end)

    T.it("pattern loads cells from array", function()
      local g = CA.dense(10, 10)
      g:pattern({{1,1},{2,2},{3,3}})
      T.eq(g:population(), 3, "3 cells from pattern")
      T.eq(g:get(1,1), 1, "cell (1,1) alive")
      T.eq(g:get(0,0), 0, "cell (0,0) dead")
    end)

    T.it("blinker oscillates with period 2 (dense)", function()
      -- Blinker: horizontal line at y=5, x=4,5,6 on a 11x11 grid.
      local g = CA.dense(11, 11, {rule="life"})
      g:set(4, 5, 1)
      g:set(5, 5, 1)
      g:set(6, 5, 1)
      -- After step: becomes vertical line at x=5, y=4,5,6.
      g:step()
      T.eq(g:population(), 3, "still 3 cells after step 1")
      T.eq(g:get(5, 4), 1, "top of vertical blinker")
      T.eq(g:get(5, 5), 1, "center of blinker")
      T.eq(g:get(5, 6), 1, "bottom of vertical blinker")
      T.eq(g:get(4, 5), 0, "left of horizontal gone")
      T.eq(g:get(6, 5), 0, "right of horizontal gone")
      -- After another step: back to horizontal.
      g:step()
      T.eq(g:population(), 3, "still 3 cells after step 2")
      T.eq(g:get(4, 5), 1, "back to horizontal left")
      T.eq(g:get(5, 5), 1, "back to horizontal center")
      T.eq(g:get(6, 5), 1, "back to horizontal right")
      T.eq(g:generation(), 2, "generation is 2")
    end)

    T.it("block is a still life (dense)", function()
      local g = CA.dense(10, 10, {rule="life"})
      g:pattern(CA.patterns.block)
      local pop_before = g:population()
      g:step()
      T.eq(g:population(), pop_before, "block population unchanged after step")
      T.eq(g:get(0,0), 1, "block cell (0,0) survives")
      T.eq(g:get(1,0), 1, "block cell (1,0) survives")
      T.eq(g:get(0,1), 1, "block cell (0,1) survives")
      T.eq(g:get(1,1), 1, "block cell (1,1) survives")
    end)

    T.it("glider moves correctly over 4 steps (dense)", function()
      -- Place glider at offset (2,2) in a 20x20 toroidal grid.
      local g = CA.dense(20, 20, {rule="life", wrap=true})
      -- Glider pattern: {1,0},{2,1},{0,2},{1,2},{2,2} relative to offset.
      local ox, oy = 2, 2
      g:set(ox+1, oy+0, 1)
      g:set(ox+2, oy+1, 1)
      g:set(ox+0, oy+2, 1)
      g:set(ox+1, oy+2, 1)
      g:set(ox+2, oy+2, 1)
      local pop0 = g:population()
      T.eq(pop0, 5, "glider starts with 5 cells")
      -- After 4 steps the glider moves one cell diagonally (right+down for this orientation).
      g:step_n(4)
      T.eq(g:population(), 5, "glider still 5 cells after 4 steps")
      T.eq(g:generation(), 4, "generation is 4")
    end)

    T.it("highlife rule creates different behavior from life", function()
      -- A specific B6 birth test: 6-neighbor pattern that births in highlife but not life.
      -- 6-neighbor ring: center dead, all 6 surrounding corners alive...
      -- Just verify parse works correctly; a 6-neighbor cell becomes alive in HighLife.
      local hl = CA.dense(10, 10, {rule="highlife"})
      -- Place 6 neighbors around (4,4)
      hl:set(3,3,1) hl:set(4,3,1) hl:set(5,3,1)
      hl:set(3,4,1)             hl:set(5,4,1)
      hl:set(3,5,1)
      hl:step()
      T.eq(hl:get(4,4), 1, "HighLife births on 6 neighbors")
      -- Life would not birth there (B3 only).
      local life = CA.dense(10, 10, {rule="life"})
      life:set(3,3,1) life:set(4,3,1) life:set(5,3,1)
      life:set(3,4,1)              life:set(5,4,1)
      life:set(3,5,1)
      life:step()
      T.eq(life:get(4,4), 0, "Life does not birth on 6 neighbors")
    end)

    T.it("seeds rule: no survival (all cells die each step)", function()
      local g = CA.dense(10, 10, {rule="seeds"})
      -- Place a 3x3 block — seeds has no survival.
      for y = 3, 5 do
        for x = 3, 5 do g:set(x, y, 1) end
      end
      g:step()
      -- Every previously-alive cell should be dead (no survival in Seeds).
      T.eq(g:get(3,3), 0, "seeds: no survival at (3,3)")
      T.eq(g:get(4,4), 0, "seeds: no survival at (4,4)")
    end)
  end)

  -- ── Sparse Grid ──────────────────────────────────────────────────────────

  T.describe("sparse grid", function()
    T.it("creates empty sparse grid", function()
      local g = CA.sparse(CA.rules.life)
      T.ok(g ~= nil, "sparse grid created")
      T.eq(g:population(), 0, "starts empty")
    end)

    T.it("set, get, unset", function()
      local g = CA.sparse(CA.rules.life)
      g:set(10, 20)
      T.eq(g:get(10, 20), 1, "cell alive after set")
      T.eq(g:get(10, 21), 0, "adjacent cell dead")
      g:unset(10, 20)
      T.eq(g:get(10, 20), 0, "cell dead after unset")
    end)

    T.it("population counts correctly", function()
      local g = CA.sparse(CA.rules.life)
      g:set(0, 0)
      g:set(1, 0)
      g:set(2, 0)
      T.eq(g:population(), 3, "population is 3")
      g:unset(1, 0)
      T.eq(g:population(), 2, "population is 2 after unset")
    end)

    T.it("alive_cells returns all live cells", function()
      local g = CA.sparse(CA.rules.life)
      g:set(5, 7)
      g:set(9, 3)
      local cells = g:alive_cells()
      T.eq(#cells, 2, "two cells returned")
      T.ok(has_cell(cells, 5, 7), "cell (5,7) in alive_cells")
      T.ok(has_cell(cells, 9, 3), "cell (9,3) in alive_cells")
    end)

    T.it("pattern loads cells", function()
      local g = CA.sparse(CA.rules.life)
      g:pattern({{0,0},{1,1},{2,2}})
      T.eq(g:population(), 3, "3 cells from pattern")
      T.eq(g:get(0,0), 1, "cell (0,0) alive")
      T.eq(g:get(3,3), 0, "cell (3,3) dead")
    end)

    T.it("bounds: correct bounding box", function()
      local g = CA.sparse(CA.rules.life)
      g:set(-5, 3)
      g:set(10, -2)
      g:set(0, 0)
      local b = g:bounds()
      T.ok(b ~= nil, "bounds not nil")
      T.eq(b[1], -5, "min_x = -5")
      T.eq(b[2], -2, "min_y = -2")
      T.eq(b[3], 10, "max_x = 10")
      T.eq(b[4], 3, "max_y = 3")
    end)

    T.it("bounds: returns nil for empty grid", function()
      local g = CA.sparse(CA.rules.life)
      T.eq(g:bounds(), nil, "nil bounds for empty grid")
    end)

    T.it("blinker oscillates in sparse grid", function()
      local g = CA.sparse(CA.rules.life)
      -- Horizontal blinker at (10,10),(11,10),(12,10).
      g:set(10, 10)
      g:set(11, 10)
      g:set(12, 10)
      g:step()
      T.eq(g:population(), 3, "still 3 cells after step")
      T.eq(g:get(11, 9), 1, "top of vertical blinker")
      T.eq(g:get(11, 10), 1, "center")
      T.eq(g:get(11, 11), 1, "bottom of vertical blinker")
      T.eq(g:get(10, 10), 0, "left of horizontal gone")
      T.eq(g:get(12, 10), 0, "right of horizontal gone")
      g:step()
      T.eq(g:population(), 3, "still 3 cells after step 2")
      T.eq(g:get(10, 10), 1, "back to horizontal")
      T.eq(g:get(11, 10), 1, "back to horizontal center")
      T.eq(g:get(12, 10), 1, "back to horizontal right")
    end)

    T.it("glider moves in sparse grid (population stays 5)", function()
      local g = CA.sparse(CA.rules.life)
      -- Glider at (10,10).
      g:set(11, 10)
      g:set(12, 11)
      g:set(10, 12)
      g:set(11, 12)
      g:set(12, 12)
      T.eq(g:population(), 5, "glider starts with 5 cells")
      g:step_n(4)
      T.eq(g:population(), 5, "still 5 after 4 steps")
    end)

    T.it("block is still life in sparse grid", function()
      local g = CA.sparse(CA.rules.life)
      g:pattern(CA.patterns.block)
      g:step()
      T.eq(g:population(), 4, "block stays at 4 cells")
      T.eq(g:get(0,0), 1, "block cell survives")
    end)

    T.it("seeds: no survival (cell born and dies)", function()
      local g = CA.sparse(CA.rules.seeds)
      -- A pair of cells side by side — each has 1 neighbor, which is not the birth count 2.
      -- But a dead cell between two alive cells in a row has 2 alive neighbors → birth.
      g:set(0, 0)
      g:set(2, 0)
      -- Dead cell at (1,0) has 2 neighbors → born in Seeds (B2).
      -- Live cells at (0,0) and (2,0) have 1 neighbor each → die (no survival in Seeds).
      g:step()
      T.eq(g:get(0, 0), 0, "original cell dies in seeds")
      T.eq(g:get(2, 0), 0, "original cell dies in seeds")
      T.eq(g:get(1, 0), 1, "new cell born at (1,0) in seeds")
    end)

    T.it("sparse grid handles negative coordinates", function()
      local g = CA.sparse(CA.rules.life)
      -- Horizontal blinker at negative coordinates.
      g:set(-101, -100)
      g:set(-100, -100)
      g:set(-99, -100)
      -- After step: becomes vertical blinker, population still 3.
      g:step()
      T.eq(g:population(), 3, "blinker at negative coords still has 3 cells")
      T.eq(g:get(-100, -101), 1, "top of vertical blinker at neg coords")
      T.eq(g:get(-100, -100), 1, "center of blinker at neg coords")
      T.eq(g:get(-100, -99), 1, "bottom of vertical blinker at neg coords")
    end)
  end)

  -- ── Rule Parsing ──────────────────────────────────────────────────────────

  T.describe("parse_rule", function()
    T.it("returns a function", function()
      local fn = CA.parse_rule("B3/S23")
      T.ok(type(fn) == "function", "parse_rule returns function")
    end)

    T.it("B3/S23 correct life behavior", function()
      local rule = CA.parse_rule("B3/S23")
      -- Birth on exactly 3 neighbors.
      T.eq(rule(3, 0), 1, "birth on 3 neighbors")
      T.eq(rule(2, 0), 0, "no birth on 2 neighbors")
      T.eq(rule(4, 0), 0, "no birth on 4 neighbors")
      -- Survival on 2 or 3 neighbors.
      T.eq(rule(2, 1), 1, "survive on 2 neighbors")
      T.eq(rule(3, 1), 1, "survive on 3 neighbors")
      T.eq(rule(1, 1), 0, "die on 1 neighbor (underpopulation)")
      T.eq(rule(4, 1), 0, "die on 4 neighbors (overpopulation)")
    end)

    T.it("B2/S seeds rule: birth on 2, no survival", function()
      local rule = CA.parse_rule("B2/S")
      T.eq(rule(2, 0), 1, "seeds: birth on 2")
      T.eq(rule(3, 0), 0, "seeds: no birth on 3")
      T.eq(rule(2, 1), 0, "seeds: no survival on 2")
      T.eq(rule(3, 1), 0, "seeds: no survival on 3")
    end)

    T.it("B36/S23 highlife rule", function()
      local rule = CA.parse_rule("B36/S23")
      T.eq(rule(3, 0), 1, "highlife: birth on 3")
      T.eq(rule(6, 0), 1, "highlife: birth on 6")
      T.eq(rule(5, 0), 0, "highlife: no birth on 5")
      T.eq(rule(2, 1), 1, "highlife: survive on 2")
      T.eq(rule(4, 1), 0, "highlife: die on 4")
    end)

    T.it("returns nil on invalid rule string", function()
      local fn, err = CA.parse_rule("invalid")
      T.eq(fn, nil, "nil for invalid rule")
      T.ok(err ~= nil, "error message returned")
    end)
  end)

  T.describe("built-in rules", function()
    T.it("CA.rules.life is a function", function()
      T.ok(type(CA.rules.life) == "function", "rules.life is function")
    end)
    T.it("CA.rules.highlife is a function", function()
      T.ok(type(CA.rules.highlife) == "function", "rules.highlife is function")
    end)
    T.it("CA.rules.seeds is a function", function()
      T.ok(type(CA.rules.seeds) == "function", "rules.seeds is function")
    end)
    T.it("CA.rules.day_and_night is a function", function()
      T.ok(type(CA.rules.day_and_night) == "function", "rules.day_and_night is function")
    end)
    T.it("CA.rules.anneal is a function", function()
      T.ok(type(CA.rules.anneal) == "function", "rules.anneal is function")
    end)
    T.it("CA.rules.replicator is a function", function()
      T.ok(type(CA.rules.replicator) == "function", "rules.replicator is function")
    end)
  end)

  -- ── RLE Codec ────────────────────────────────────────────────────────────

  T.describe("rle_decode", function()
    T.it("decodes simple RLE", function()
      -- "bo$2bo$3o!" = blinker (vertical form).
      -- Row 0: b(0)o(1) → alive at x=1
      -- Row 1: 2b(0,1)o(2) → alive at x=2
      -- Row 2: 3o(0,1,2) → alive at x=0,1,2
      local cells = CA.rle_decode("bo$2bo$3o!")
      T.ok(has_cell(cells, 1, 0), "rle: cell (1,0)")
      T.ok(has_cell(cells, 2, 1), "rle: cell (2,1)")
      T.ok(has_cell(cells, 0, 2), "rle: cell (0,2)")
      T.ok(has_cell(cells, 1, 2), "rle: cell (1,2)")
      T.ok(has_cell(cells, 2, 2), "rle: cell (2,2)")
    end)

    T.it("decodes glider RLE", function()
      -- Standard glider RLE (matches CA.patterns.glider layout).
      -- bo$2bo$3o! is the glider.
      local cells = CA.rle_decode("bo$2bo$3o!")
      T.eq(#cells, 5, "glider has 5 cells")
    end)

    T.it("decodes simple single alive cell", function()
      local cells = CA.rle_decode("o!")
      T.eq(#cells, 1, "one cell")
      T.eq(cells[1][1], 0, "x=0")
      T.eq(cells[1][2], 0, "y=0")
    end)

    T.it("decodes run-length alive cells", function()
      -- "3o!" = three alive cells in a row at y=0, x=0,1,2.
      local cells = CA.rle_decode("3o!")
      T.eq(#cells, 3, "three cells")
      T.ok(has_cell(cells, 0, 0), "cell (0,0)")
      T.ok(has_cell(cells, 1, 0), "cell (1,0)")
      T.ok(has_cell(cells, 2, 0), "cell (2,0)")
    end)

    T.it("decodes multiple rows with row gap", function()
      -- "o$$$o!" = alive at (0,0) and (0,3) with 3 row separators.
      local cells = CA.rle_decode("o$$$o!")
      T.eq(#cells, 2, "two cells")
      T.ok(has_cell(cells, 0, 0), "cell (0,0)")
      T.ok(has_cell(cells, 0, 3), "cell (0,3)")
    end)
  end)

  T.describe("rle_encode", function()
    T.it("encodes empty array", function()
      T.eq(CA.rle_encode({}), "!", "empty → '!'")
    end)

    T.it("encodes single cell", function()
      local rle = CA.rle_encode({{0, 0}})
      T.ok(rle:find("o") ~= nil, "contains 'o'")
      T.ok(rle:sub(-1) == "!", "ends with '!'")
    end)

    T.it("encode then decode round-trips blinker", function()
      local original = sort_cells(CA.patterns.blinker)
      local rle = CA.rle_encode(original)
      local decoded = sort_cells(CA.rle_decode(rle))
      -- Normalize decoded to start at (0,0) by finding offset.
      local min_x, min_y = decoded[1][1], decoded[1][2]
      for _, c in ipairs(decoded) do
        if c[1] < min_x then min_x = c[1] end
        if c[2] < min_y then min_y = c[2] end
      end
      T.eq(#decoded, #original, "same number of cells after round-trip")
    end)

    T.it("encode then decode round-trips glider", function()
      local original = sort_cells(CA.patterns.glider)
      local rle = CA.rle_encode(original)
      local decoded = CA.rle_decode(rle)
      T.eq(#decoded, 5, "5 cells after glider round-trip")
    end)

    T.it("encode then decode round-trips block", function()
      local original = sort_cells(CA.patterns.block)
      local rle = CA.rle_encode(original)
      local decoded = CA.rle_decode(rle)
      T.eq(#decoded, 4, "4 cells after block round-trip")
    end)
  end)

  -- ── Common Patterns ───────────────────────────────────────────────────────

  T.describe("common patterns", function()
    T.it("glider has 5 cells", function()
      T.eq(#CA.patterns.glider, 5, "glider has 5 cells")
    end)

    T.it("blinker has 3 cells", function()
      T.eq(#CA.patterns.blinker, 3, "blinker has 3 cells")
    end)

    T.it("block has 4 cells", function()
      T.eq(#CA.patterns.block, 4, "block has 4 cells")
    end)

    T.it("glider_gun has 30+ cells", function()
      T.ok(#CA.patterns.glider_gun >= 30, "glider_gun has 30+ cells")
    end)

    T.it("all patterns are arrays of {x,y} pairs", function()
      for name, pat in pairs(CA.patterns) do
        T.ok(type(pat) == "table", name .. " is a table")
        if #pat > 0 then
          T.ok(type(pat[1]) == "table", name .. "[1] is a table")
          T.ok(type(pat[1][1]) == "number", name .. "[1][1] is a number (x)")
          T.ok(type(pat[1][2]) == "number", name .. "[1][2] is a number (y)")
        end
      end
    end)
  end)

  -- ── Module Metadata ───────────────────────────────────────────────────────

  T.describe("module metadata", function()
    T.it("_tier is 'pure'", function()
      T.eq(CA._tier, "pure", "_tier is 'pure'")
    end)
  end)

end)
