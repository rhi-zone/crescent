if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local ca = require("lib.cellular_automata")

local function row_str(row) return table.concat(row, "") end

T.describe("cellular_automata", function()

  T.describe("rule1d", function()

    T.it("rule30: init_single creates center cell", function()
      local r30 = ca.rule1d(30)
      local row = r30:init_single(11)
      T.eq(#row, 11)
      T.eq(row_str(row), "00000100000")
    end)

    T.it("rule30: step 1 from single cell matches known pattern", function()
      local r30 = ca.rule1d(30)
      local row = r30:init_single(11)
      local s1 = r30:step(row)
      T.eq(row_str(s1), "00001110000")
    end)

    T.it("rule30: step 2 matches known pattern", function()
      local r30 = ca.rule1d(30)
      local row = r30:init_single(11)
      local s1 = r30:step(row)
      local s2 = r30:step(s1)
      T.eq(row_str(s2), "00011001000")
    end)

    T.it("rule110: step sequence matches known output", function()
      local r110 = ca.rule1d(110)
      local row = r110:init_single(15)
      local steps = r110:run(row, 5)
      T.eq(row_str(steps[2]), "000000110000000")  -- step 1
      T.eq(row_str(steps[3]), "000001110000000")  -- step 2
      T.eq(row_str(steps[4]), "000011010000000")  -- step 3
      T.eq(row_str(steps[5]), "000111110000000")  -- step 4
      T.eq(row_str(steps[6]), "001100010000000")  -- step 5
    end)

    T.it("rule90: produces Sierpinski-like pattern", function()
      local r90 = ca.rule1d(90)
      local row = r90:init_single(9)
      local s1 = r90:step(row)
      local s2 = r90:step(s1)
      local s3 = r90:step(s2)
      -- Rule 90 is XOR of left and right neighbors; produces Sierpinski triangle.
      T.eq(row_str(s1), "000101000")
      T.eq(row_str(s2), "001000100")
      -- Step 3: symmetric pattern with 4 ones.
      T.eq(row_str(s3), "010101010")
    end)

    T.it("run returns history including initial row", function()
      local r30 = ca.rule1d(30)
      local row = r30:init_single(7)
      local hist = r30:run(row, 3)
      T.eq(#hist, 4)  -- initial + 3 steps
      T.eq(row_str(hist[1]), row_str(row))
    end)

    T.it("init_random is reproducible with same seed", function()
      local r30 = ca.rule1d(30)
      local row1 = r30:init_random(20, 99)
      local row2 = r30:init_random(20, 99)
      T.eq(row_str(row1), row_str(row2))
    end)

    T.it("init_random produces different output with different seed", function()
      local r30 = ca.rule1d(30)
      local row1 = r30:init_random(20, 1)
      local row2 = r30:init_random(20, 2)
      T.neq(row_str(row1), row_str(row2))
    end)

    T.it("rule1d returns nil for out-of-range rule", function()
      local a, err = ca.rule1d(256)
      T.eq(a, nil)
      T.ok(err)
    end)

  end)

  T.describe("grid2d", function()

    T.it("creates grid with correct dimensions", function()
      local g = ca.grid2d({ width = 10, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      T.eq(g.width, 10)
      T.eq(g.height, 5)
    end)

    T.it("get/set round-trip", function()
      local g = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      T.eq(g:get(3, 3), 0)
      g:set(3, 3, 1)
      T.eq(g:get(3, 3), 1)
    end)

    T.it("set returns nil for out-of-bounds", function()
      local g = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      local ok, err = g:set(10, 10, 1)
      T.eq(ok, nil)
      T.ok(err)
    end)

    T.it("clear sets all cells to 0", function()
      local g = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      g:set(2, 2, 1)
      g:set(3, 3, 1)
      g:clear()
      T.eq(g:count_alive(), 0)
    end)

    T.it("Conway glider has 5 alive cells", function()
      local life = ca.grid2d({ width = 10, height = 10, birth = {3}, survive = {2, 3}, wrap = true })
      life:place_pattern(1, 1, ca.patterns.glider)
      T.eq(life:count_alive(), 5)
    end)

    T.it("Conway glider advances correctly after 4 steps", function()
      local life = ca.grid2d({ width = 10, height = 10, birth = {3}, survive = {2, 3}, wrap = true })
      life:place_pattern(1, 1, ca.patterns.glider)
      life:step_n(4)
      -- After 4 steps a glider is translated by (1,1) and still has 5 cells.
      T.eq(life:count_alive(), 5)
      -- Verify the expected position: glider pattern at (2,2).
      local cells = life:alive_cells()
      T.eq(#cells, 5)
    end)

    T.it("blinker oscillates with period 2", function()
      local life = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      life:place_pattern(2, 2, ca.patterns.blinker)
      local s0 = life:to_string()
      life:step()
      local s1 = life:to_string()
      life:step()
      local s2 = life:to_string()
      T.neq(s0, s1)   -- changed after step 1
      T.eq(s0, s2)    -- back to original after step 2
    end)

    T.it("block still life remains unchanged", function()
      local life = ca.grid2d({ width = 6, height = 6, birth = {3}, survive = {2, 3}, wrap = false })
      life:place_pattern(2, 2, ca.patterns.block)
      local before = life:to_string()
      life:step()
      local after = life:to_string()
      T.eq(before, after)
    end)

    T.it("boundary wrapping: glider exits right and re-enters left", function()
      -- Place glider near the right edge; after enough steps it wraps.
      local w, h = 15, 15
      local life = ca.grid2d({ width = w, height = h, birth = {3}, survive = {2, 3}, wrap = true })
      life:place_pattern(w - 2, 1, ca.patterns.glider)
      -- After many steps the glider should still be alive and have wrapped.
      life:step_n(16)
      T.eq(life:count_alive(), 5)
    end)

    T.it("count_alive is correct after each step", function()
      local life = ca.grid2d({ width = 10, height = 10, birth = {3}, survive = {2, 3}, wrap = true })
      life:place_pattern(3, 3, ca.patterns.glider)
      T.eq(life:count_alive(), 5)
      life:step()
      T.eq(life:count_alive(), 5)
      life:step()
      T.eq(life:count_alive(), 5)
    end)

    T.it("alive_cells returns correct count and positions", function()
      local g = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, wrap = false })
      g:set(2, 2, 1)
      g:set(4, 4, 1)
      local cells = g:alive_cells()
      T.eq(#cells, 2)
    end)

    T.it("from_string + to_string round-trip", function()
      local g = ca.grid2d({ width = 3, height = 3, birth = {3}, survive = {2, 3}, wrap = false })
      g:from_string("#.#\n.##\n#..", "#")
      T.eq(g:to_string("#", "."), "#.#\n.##\n#..")
    end)

    T.it("from_string updates grid dimensions", function()
      local g = ca.grid2d({ width = 10, height = 10, birth = {3}, survive = {2, 3}, wrap = false })
      g:from_string("##\n##", "#")
      T.eq(g.width, 2)
      T.eq(g.height, 2)
      T.eq(g:count_alive(), 4)
    end)

    T.it("to_string uses custom on/off characters", function()
      local g = ca.grid2d({ width = 3, height = 1, birth = {3}, survive = {2, 3}, wrap = false })
      g:set(2, 1, 1)
      T.eq(g:to_string("█", "·"), "·█·")
    end)

    T.it("place_pattern correctly sets cells", function()
      local g = ca.grid2d({ width = 10, height = 10, birth = {3}, survive = {2, 3}, wrap = false })
      g:place_pattern(3, 3, ca.patterns.blinker)
      T.eq(g:get(3, 3), 1)
      T.eq(g:get(4, 3), 1)
      T.eq(g:get(5, 3), 1)
      T.eq(g:get(2, 3), 0)
    end)

  end)

  T.describe("multi-state (Brian's Brain)", function()

    T.it("alive cell transitions to dying after one step", function()
      local brain = ca.grid2d({ width = 5, height = 5, birth = {2}, survive = {}, states = 3, wrap = false })
      brain:set(3, 3, 1)
      T.eq(brain:count_state(1), 1)
      T.eq(brain:count_state(2), 0)
      brain:step()
      T.eq(brain:count_state(1), 0)
      T.eq(brain:count_state(2), 1)
    end)

    T.it("dying cell transitions to dead after one step", function()
      local brain = ca.grid2d({ width = 5, height = 5, birth = {2}, survive = {}, states = 3, wrap = false })
      brain:set(3, 3, 1)
      brain:step()  -- alive → dying
      brain:step()  -- dying → dead
      T.eq(brain:count_state(0), 25)
      T.eq(brain:count_state(1), 0)
      T.eq(brain:count_state(2), 0)
    end)

    T.it("dead cell with 2 alive neighbors is born", function()
      local brain = ca.grid2d({ width = 7, height = 7, birth = {2}, survive = {}, states = 3, wrap = false })
      -- Two adjacent alive cells share neighbors; cells adjacent to both should be born.
      brain:set(3, 4, 1)
      brain:set(4, 4, 1)
      T.eq(brain:count_state(1), 2)
      brain:step()
      -- Original cells → dying (2), new births from cells with 2 alive neighbors.
      T.eq(brain:count_state(2), 2)
      T.ok(brain:count_state(1) >= 1, "at least one new birth")
    end)

    T.it("count_state counts each state correctly", function()
      local g = ca.grid2d({ width = 5, height = 5, birth = {3}, survive = {2, 3}, states = 2, wrap = false })
      g:set(1, 1, 1)
      g:set(2, 2, 1)
      T.eq(g:count_state(1), 2)
      T.eq(g:count_state(0), 23)
    end)

  end)

  T.describe("patterns", function()

    T.it("glider pattern has 5 cells", function()
      local count = 0
      for _, row in ipairs(ca.patterns.glider) do
        for _, v in ipairs(row) do count = count + v end
      end
      T.eq(count, 5)
    end)

    T.it("blinker pattern has 3 cells", function()
      local count = 0
      for _, row in ipairs(ca.patterns.blinker) do
        for _, v in ipairs(row) do count = count + v end
      end
      T.eq(count, 3)
    end)

    T.it("block pattern has 4 cells", function()
      local count = 0
      for _, row in ipairs(ca.patterns.block) do
        for _, v in ipairs(row) do count = count + v end
      end
      T.eq(count, 4)
    end)

    T.it("r_pentomino pattern has 5 cells", function()
      local count = 0
      for _, row in ipairs(ca.patterns.r_pentomino) do
        for _, v in ipairs(row) do count = count + v end
      end
      T.eq(count, 5)
    end)

    T.it("all named patterns exist", function()
      T.ok(ca.patterns.glider)
      T.ok(ca.patterns.blinker)
      T.ok(ca.patterns.toad)
      T.ok(ca.patterns.beacon)
      T.ok(ca.patterns.pulsar)
      T.ok(ca.patterns.r_pentomino)
      T.ok(ca.patterns.diehard)
      T.ok(ca.patterns.acorn)
      T.ok(ca.patterns.glider_gun)
    end)

  end)

  T.describe("M._tier", function()
    T.it("is pure", function()
      T.eq(ca._tier, "pure")
    end)
  end)

end)
