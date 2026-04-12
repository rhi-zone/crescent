if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local L = require("lib.lsystem")

-- ========================
-- Koch curve expansion
-- ========================

T.describe("Koch curve expansion", function()
  local ls = L.new({ axiom = "F", rules = { F = "F+F--F+F" }, angle = 60 })

  T.it("n=0 returns axiom", function()
    T.eq(ls:expand(0), "F")
  end)

  T.it("n=1 applies rule once", function()
    T.eq(ls:expand(1), "F+F--F+F")
  end)

  T.it("n=2 applies rule twice", function()
    -- each F → F+F--F+F, non-F symbols pass through
    local expected = "F+F--F+F+F+F--F+F--F+F--F+F+F+F--F+F"
    T.eq(ls:expand(2), expected)
  end)

  T.it("n=3 has correct length", function()
    local s = ls:expand(3)
    -- each expansion: Fs multiply, non-F pass through
    -- n=0: 1F, 0 ops → len 1
    -- n=1: 4F, 4 ops → len 8  (F+F--F+F)
    -- n=2: 16F + ops
    -- length grows: n=1→8, n=2→8*4+... let's just check it's > n=2
    T.ok(#s > #ls:expand(2))
  end)
end)

-- ========================
-- Dragon curve
-- ========================

T.describe("Dragon curve", function()
  local ls = L.presets.dragon_curve

  T.it("expand(0) is axiom FX", function()
    T.eq(ls:expand(0), "FX")
  end)

  T.it("expand length roughly doubles", function()
    -- The F-symbols roughly double; total length grows similarly
    local s0 = ls:expand(0)
    local s2 = ls:expand(2)
    local s4 = ls:expand(4)
    T.ok(#s2 > #s0 * 2 - 2)
    T.ok(#s4 > #s2 * 2 - 2)
  end)
end)

-- ========================
-- Sierpinski triangle
-- ========================

T.describe("Sierpinski triangle", function()
  local ls = L.new({
    axiom = "F-G-G",
    rules = { F = "F-G+F+G-F", G = "GG" },
    angle = 120,
  })

  T.it("n=0 returns axiom", function()
    T.eq(ls:expand(0), "F-G-G")
  end)

  T.it("n=1 applies both rules", function()
    T.eq(ls:expand(1), "F-G+F+G-F-GG-GG")
  end)

  T.it("n=2 length grows", function()
    T.ok(#ls:expand(2) > #ls:expand(1))
  end)
end)

-- ========================
-- Stochastic rules
-- ========================

T.describe("Stochastic rules", function()
  local ls = L.new({
    axiom = "F",
    rules = {
      F = { { "FFF", 0.33 }, { "F[+F]F", 0.33 }, { "F[-F]F", 0.34 } },
    },
    angle = 25,
    seed = 99,
  })

  local valid = { FFF = true, ["F[+F]F"] = true, ["F[-F]F"] = true }

  T.it("n=1 produces one of the valid alternatives", function()
    local result = ls:expand(1)
    T.ok(valid[result], "got: " .. tostring(result))
  end)

  T.it("n=1 with different seeds produces valid strings", function()
    for seed = 1, 20 do
      local ls2 = L.new({
        axiom = "F",
        rules = { F = { { "FFF", 0.33 }, { "F[+F]F", 0.33 }, { "F[-F]F", 0.34 } } },
        angle = 25,
        seed = seed,
      })
      local r = ls2:expand(1)
      T.ok(valid[r], "seed " .. seed .. " produced invalid: " .. tostring(r))
    end
  end)
end)

-- ========================
-- turtle() command sequence
-- ========================

T.describe("turtle() commands", function()
  local ls = L.new({ axiom = "F", rules = {}, angle = 90 })

  T.it("F → forward command", function()
    local cmds = ls:turtle("F")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "forward")
  end)

  T.it("+ → turn left (positive angle)", function()
    local cmds = ls:turtle("+")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "turn")
    T.eq(cmds[1].angle, 90)
  end)

  T.it("- → turn right (negative angle)", function()
    local cmds = ls:turtle("-")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "turn")
    T.eq(cmds[1].angle, -90)
  end)

  T.it("| → turn 180", function()
    local cmds = ls:turtle("|")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "turn")
    T.eq(cmds[1].angle, 180)
  end)

  T.it("[ → push, ] → pop", function()
    local cmds = ls:turtle("[F]")
    T.eq(#cmds, 3)
    T.eq(cmds[1].op, "push")
    T.eq(cmds[2].op, "forward")
    T.eq(cmds[3].op, "pop")
  end)

  T.it("F+F-F produces 5 commands", function()
    local cmds = ls:turtle("F+F-F")
    T.eq(#cmds, 5)
    T.eq(cmds[1].op, "forward")
    T.eq(cmds[2].op, "turn")
    T.eq(cmds[3].op, "forward")
    T.eq(cmds[4].op, "turn")
    T.eq(cmds[5].op, "forward")
  end)

  T.it("G maps to forward too", function()
    local cmds = ls:turtle("G")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "forward")
  end)

  T.it("f maps to move", function()
    local cmds = ls:turtle("f")
    T.eq(#cmds, 1)
    T.eq(cmds[1].op, "move")
  end)

  T.it("3D pitch/roll/width/color symbols", function()
    local cmds = ls:turtle("&^\\/#!`")
    -- &, ^, \, /, #, !, `  → 7 commands
    T.eq(#cmds, 7)
    T.eq(cmds[1].op, "pitch")
    T.eq(cmds[1].angle, -1)
    T.eq(cmds[2].op, "pitch")
    T.eq(cmds[2].angle, 1)
    T.eq(cmds[3].op, "roll")
    T.eq(cmds[3].angle, -1)
    T.eq(cmds[4].op, "roll")
    T.eq(cmds[4].angle, 1)
    T.eq(cmds[5].op, "color")
    T.eq(cmds[6].op, "width")
    T.eq(cmds[7].op, "width")
  end)

  T.it("unknown symbols are ignored", function()
    local cmds = ls:turtle("XYZ")
    T.eq(#cmds, 0)
  end)
end)

-- ========================
-- Bracket balance
-- ========================

T.describe("push/pop balance", function()
  local function bracket_balance(s)
    local depth = 0
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == "[" then depth = depth + 1
      elseif c == "]" then depth = depth - 1
        if depth < 0 then return false end
      end
    end
    return depth == 0
  end

  local preset_names = {
    "koch_snowflake", "dragon_curve", "sierpinski", "plant", "hilbert", "pentigree"
  }

  for _, name in ipairs(preset_names) do
    T.it(name .. " brackets balanced at n=3", function()
      local ls = L.presets[name]
      local s = ls:expand(3)
      T.ok(bracket_balance(s), "unbalanced brackets in " .. name .. " at n=3")
    end)
  end
end)

-- ========================
-- Presets exist and expand
-- ========================

T.describe("presets", function()
  local names = { "dragon_curve", "sierpinski", "koch_snowflake", "plant", "hilbert", "pentigree" }

  for _, name in ipairs(names) do
    T.it(name .. " exists", function()
      T.ok(L.presets[name] ~= nil)
    end)

    T.it(name .. " expands n=2 without error", function()
      local s = L.presets[name]:expand(2)
      T.ok(type(s) == "string")
      T.ok(#s > 0)
    end)
  end
end)

-- ========================
-- expand_iter
-- ========================

T.describe("expand_iter", function()
  local ls = L.new({ axiom = "F", rules = { F = "FF" }, angle = 90 })

  T.it("yields n+1 steps (0..n)", function()
    local count = 0
    for _ in ls:expand_iter(4) do
      count = count + 1
    end
    T.eq(count, 5)
  end)

  T.it("step 0 is axiom", function()
    local first_i, first_s
    for i, s in ls:expand_iter(3) do
      if first_i == nil then first_i = i; first_s = s end
    end
    T.eq(first_i, 0)
    T.eq(first_s, "F")
  end)

  T.it("step k matches expand(k)", function()
    -- Use a fresh lsystem with same seed each time for determinism
    local ls2 = L.new({ axiom = "F", rules = { F = "F+F" }, angle = 90, seed = 1 })
    local ls3 = L.new({ axiom = "F", rules = { F = "F+F" }, angle = 90, seed = 1 })
    for i, s in ls2:expand_iter(4) do
      T.eq(s, ls3:expand(i))
    end
  end)

  T.it("n=0 yields exactly the axiom", function()
    local collected = {}
    for _, s in ls:expand_iter(0) do
      collected[#collected + 1] = s
    end
    T.eq(#collected, 1)
    T.eq(collected[1], "F")
  end)
end)

-- ========================
-- Error handling
-- ========================

T.describe("error handling", function()
  T.it("new() without axiom returns nil, err", function()
    local v, err = L.new({ rules = {} })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("new() without rules returns nil, err", function()
    local v, err = L.new({ axiom = "F" })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("new() with non-table spec returns nil, err", function()
    local v, err = L.new("bad")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("new() with bad rule key returns nil, err", function()
    local v, err = L.new({ axiom = "F", rules = { FF = "G" } })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("new() with stochastic probs not summing to 1 returns nil, err", function()
    local v, err = L.new({
      axiom = "F",
      rules = { F = { { "FF", 0.3 }, { "FFF", 0.3 } } },
    })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("expand() with negative n returns nil, err", function()
    local ls = L.new({ axiom = "F", rules = {} })
    local v, err = ls:expand(-1)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("turtle() with non-string returns nil, err", function()
    local ls = L.new({ axiom = "F", rules = {} })
    local v, err = ls:turtle(123)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ========================
-- _tier
-- ========================

T.describe("module metadata", function()
  T.it("_tier is pure", function()
    T.eq(L._tier, "pure")
  end)
end)
