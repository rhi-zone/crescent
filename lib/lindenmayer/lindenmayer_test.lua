if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local L = require("lib.lindenmayer")

-- ========================
-- Basic string generation
-- ========================

T.describe("Koch curve generation", function()
  local sys = L.new({ axiom = "F", rules = { F = "F+F--F+F" }, angle = 60 })

  T.it("n=0 returns axiom", function()
    T.eq(sys:generate(0), "F")
  end)

  T.it("n=1 returns one expansion", function()
    T.eq(sys:generate(1), "F+F--F+F")
  end)

  T.it("n=2 returns correct string", function()
    local expected = "F+F--F+F+F+F--F+F--F+F--F+F+F+F--F+F"
    T.eq(sys:generate(2), expected)
  end)

  T.it("n=3 length is 4^3 = 64 F chars + symbols", function()
    local s = sys:generate(3)
    -- count F's: should be 4^3 = 64
    local fcount = 0
    for _ in s:gmatch("F") do fcount = fcount + 1 end
    T.eq(fcount, 64)
  end)

  T.it("length grows from n=2 to n=3", function()
    T.ok(#sys:generate(3) > #sys:generate(2))
  end)
end)

-- ========================
-- Identity: no-rule chars
-- ========================

T.describe("identity symbols", function()
  local sys = L.new({ axiom = "F+F-F", rules = { F = "FF" }, angle = 90 })

  T.it("+ and - pass through unchanged", function()
    local s = sys:generate(1)
    -- F→FF, + stays, - stays: "FF+FF-FF"
    T.eq(s, "FF+FF-FF")
  end)

  T.it("symbols without rules are unchanged", function()
    local sys2 = L.new({ axiom = "XFY", rules = { F = "FF" }, angle = 90 })
    T.eq(sys2:generate(1), "XFFY")
  end)
end)

-- ========================
-- Multi-rule expansion
-- ========================

T.describe("multiple rules", function()
  local sys = L.new({
    axiom = "AB",
    rules = { A = "AB", B = "A" },
    angle = 90,
  })

  T.it("n=0 is axiom", function()
    T.eq(sys:generate(0), "AB")
  end)

  T.it("n=1: A→AB, B→A", function()
    T.eq(sys:generate(1), "ABA")
  end)

  T.it("n=2: Fibonacci-like growth", function()
    T.eq(sys:generate(2), "ABAAB")
  end)

  T.it("n=3", function()
    T.eq(sys:generate(3), "ABAABABA")
  end)
end)

-- ========================
-- Stochastic rules
-- ========================

T.describe("stochastic rules", function()
  T.it("n=1 produces one of the valid alternatives (seed=42)", function()
    local sys = L.new({
      axiom = "F",
      rules = {
        F = {
          { prob = 0.5, rule = "F+F" },
          { prob = 0.5, rule = "F-F" },
        },
      },
      angle = 90,
      seed = 42,
    })
    local result = sys:generate(1)
    T.ok(result == "F+F" or result == "F-F", "got: " .. tostring(result))
  end)

  T.it("all seeds 1-20 produce valid strings", function()
    local valid = { ["F+F"] = true, ["F-F"] = true }
    for seed = 1, 20 do
      local sys = L.new({
        axiom = "F",
        rules = {
          F = { { prob = 0.5, rule = "F+F" }, { prob = 0.5, rule = "F-F" } },
        },
        angle = 90,
        seed = seed,
      })
      local r = sys:generate(1)
      T.ok(valid[r], "seed " .. seed .. " invalid: " .. tostring(r))
    end
  end)

  T.it("three-way stochastic with sum=1 works", function()
    local sys = L.new({
      axiom = "F",
      rules = {
        F = {
          { prob = 0.33, rule = "FFF" },
          { prob = 0.33, rule = "F[+F]F" },
          { prob = 0.34, rule = "F[-F]F" },
        },
      },
      angle = 25,
      seed = 7,
    })
    local r = sys:generate(1)
    local valid = { FFF = true, ["F[+F]F"] = true, ["F[-F]F"] = true }
    T.ok(valid[r], "got: " .. tostring(r))
  end)

  T.it("stochastic sum != 1 returns error", function()
    local v, err = L.new({
      axiom = "F",
      rules = { F = { { prob = 0.3, rule = "F+F" }, { prob = 0.3, rule = "F-F" } } },
    })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ========================
-- Context-sensitive rules
-- ========================

T.describe("context-sensitive rules", function()
  T.it("left context A<B: B preceded by A → replacement", function()
    local sys = L.new({
      axiom = "ABC",
      rules = { ["A<B"] = "b" },
      angle = 90,
    })
    -- A stays (no rule), B→b (preceded by A), C stays
    T.eq(sys:generate(1), "AbC")
  end)

  T.it("right context B>C: B followed by C → replacement", function()
    local sys = L.new({
      axiom = "ABC",
      rules = { ["B>C"] = "x" },
      angle = 90,
    })
    -- A stays, B→x (followed by C), C stays
    T.eq(sys:generate(1), "AxC")
  end)

  T.it("context rule doesn't fire when context not met", function()
    local sys = L.new({
      axiom = "DBC",
      rules = { ["A<B"] = "b" },
      angle = 90,
    })
    -- B not preceded by A, so B stays
    T.eq(sys:generate(1), "DBC")
  end)

  T.it("context at start of string does not fire left context", function()
    local sys = L.new({
      axiom = "BC",
      rules = { ["A<B"] = "b" },
      angle = 90,
    })
    T.eq(sys:generate(1), "BC")
  end)
end)

-- ========================
-- Parametric rules
-- ========================

T.describe("parametric rules", function()
  T.it("A(1) → A(0) countdown", function()
    local sys = L.new({
      axiom = "A(3)",
      rules = {
        ["A(x)"] = function(params)
          local x = tonumber(params[1])
          if x > 0 then return "A(" .. (x - 1) .. ")" end
          return "F"
        end,
      },
      angle = 90,
    })
    T.eq(sys:generate(1), "A(2)")
    -- re-create to reset
    local sys2 = L.new({
      axiom = "A(1)",
      rules = {
        ["A(x)"] = function(params)
          local x = tonumber(params[1])
          if x > 0 then return "A(" .. (x - 1) .. ")" end
          return "F"
        end,
      },
      angle = 90,
    })
    T.eq(sys2:generate(1), "A(0)")
    T.eq(sys2:generate(2), "F")
  end)
end)

-- ========================
-- Turtle: F moves forward
-- ========================

T.describe("turtle interpret - forward motion", function()
  local sys = L.new({ axiom = "F", rules = {}, angle = 90 })

  T.it("F with start_angle=90 moves upward (y increases)", function()
    local cmds = sys:interpret("F", { step = 10, start_angle = 90, start_x = 0, start_y = 0 })
    T.eq(#cmds, 1)
    T.eq(cmds[1].type, "line")
    T.eq(cmds[1].x1, 0)
    T.eq(cmds[1].y1, 0)
    -- cos(90°) ≈ 0, sin(90°) ≈ 1 → (0, 10)
    T.ok(math.abs(cmds[1].x2) < 1e-9)
    T.ok(math.abs(cmds[1].y2 - 10) < 1e-9)
  end)

  T.it("F with start_angle=0 moves right (x increases)", function()
    local cmds = sys:interpret("F", { step = 5, start_angle = 0, start_x = 0, start_y = 0 })
    T.eq(#cmds, 1)
    T.ok(math.abs(cmds[1].x2 - 5) < 1e-9)
    T.ok(math.abs(cmds[1].y2) < 1e-9)
  end)

  T.it("f produces move command, not line", function()
    local cmds = sys:interpret("f", { step = 10, start_angle = 0 })
    T.eq(#cmds, 1)
    T.eq(cmds[1].type, "move")
  end)

  T.it("two F produce two line segments end-to-end", function()
    local cmds = sys:interpret("FF", { step = 10, start_angle = 0, start_x = 0, start_y = 0 })
    T.eq(#cmds, 2)
    -- second line starts where first ended
    T.ok(math.abs(cmds[2].x1 - cmds[1].x2) < 1e-9)
    T.ok(math.abs(cmds[2].y1 - cmds[1].y2) < 1e-9)
  end)
end)

-- ========================
-- Turtle: turning
-- ========================

T.describe("turtle interpret - turning", function()
  local sys = L.new({ axiom = "F", rules = {}, angle = 90 })

  T.it("+ turns left (angle increases)", function()
    -- start facing 0° (right), + turns to 90° (up)
    local cmds = sys:interpret("F+F", { step = 10, start_angle = 0 })
    T.eq(#cmds, 2)
    -- first F: rightward
    T.ok(cmds[1].x2 - cmds[1].x1 > 0)
    T.ok(math.abs(cmds[1].y2 - cmds[1].y1) < 1e-9)
    -- second F: upward (after +90 turn)
    T.ok(math.abs(cmds[2].x2 - cmds[2].x1) < 1e-9)
    T.ok(cmds[2].y2 - cmds[2].y1 > 0)
  end)

  T.it("- turns right (angle decreases)", function()
    local cmds = sys:interpret("F-F", { step = 10, start_angle = 90 })
    -- first F: upward
    T.ok(cmds[1].y2 > cmds[1].y1)
    -- second F: rightward after -90 → 0°
    T.ok(cmds[2].x2 > cmds[2].x1)
  end)

  T.it("| turns 180 degrees", function()
    local cmds = sys:interpret("F|F", { step = 10, start_angle = 0 })
    -- first F: rightward (positive x)
    T.ok(cmds[1].x2 > cmds[1].x1)
    -- after |, facing 180°: leftward (negative x)
    T.ok(cmds[2].x2 < cmds[2].x1)
  end)
end)

-- ========================
-- Turtle: push/pop
-- ========================

T.describe("turtle interpret - push/pop", function()
  local sys = L.new({ axiom = "F", rules = {}, angle = 90 })

  T.it("[ emits push with position", function()
    local cmds = sys:interpret("[", { start_x = 3, start_y = 4, start_angle = 45 })
    T.eq(#cmds, 1)
    T.eq(cmds[1].type, "push")
    T.eq(cmds[1].x, 3)
    T.eq(cmds[1].y, 4)
    T.eq(cmds[1].angle, 45)
  end)

  T.it("] emits pop and restores position", function()
    local cmds = sys:interpret("F[F]F", { step = 10, start_angle = 0, start_x = 0, start_y = 0 })
    -- cmds: line(0→10), push(10,0,0°), line(10→20), pop(10,0,0°), line(10→20)
    T.ok(#cmds >= 5)
    T.eq(cmds[1].type, "line")
    T.eq(cmds[2].type, "push")
    T.eq(cmds[3].type, "line")
    T.eq(cmds[4].type, "pop")
    -- pop restores x=10
    T.ok(math.abs(cmds[4].x - 10) < 1e-9)
    -- last line starts from restored x=10
    T.ok(math.abs(cmds[5].x1 - 10) < 1e-9)
  end)

  T.it("F[+F]F branches then continues straight", function()
    local cmds = sys:interpret("F[+F]F", { step = 10, start_angle = 0 })
    -- main trunk: F at 0°, branch: +F at 90°, resume: F at 0°
    local lines = {}
    for _, c in ipairs(cmds) do
      if c.type == "line" then lines[#lines + 1] = c end
    end
    T.eq(#lines, 3)
  end)
end)

-- ========================
-- Bounds
-- ========================

T.describe("bounds", function()
  local sys = L.new({ axiom = "F", rules = {}, angle = 90 })

  T.it("single F at angle 0 gives correct bbox", function()
    local cmds = sys:interpret("F", { step = 10, start_angle = 0, start_x = 0, start_y = 0 })
    local bbox = sys:bounds(cmds)
    T.ok(math.abs(bbox.min_x) < 1e-9)
    T.ok(math.abs(bbox.min_y) < 1e-9)
    T.ok(math.abs(bbox.max_x - 10) < 1e-9)
    T.ok(math.abs(bbox.width - 10) < 1e-9)
  end)

  T.it("F+F (90° square corner) has correct extents", function()
    local cmds = sys:interpret("F+F", { step = 10, start_angle = 0, start_x = 0, start_y = 0 })
    local bbox = sys:bounds(cmds)
    T.ok(math.abs(bbox.max_x - 10) < 1e-9)
    T.ok(math.abs(bbox.max_y - 10) < 1e-9)
    T.ok(math.abs(bbox.width - 10) < 1e-9)
    T.ok(math.abs(bbox.height - 10) < 1e-9)
  end)

  T.it("empty command list gives zero bbox", function()
    local bbox = sys:bounds({})
    T.eq(bbox.width, 0)
    T.eq(bbox.height, 0)
  end)

  T.it("min_x <= max_x and min_y <= max_y", function()
    local sys2 = L.new({ axiom = "F", rules = { F = "F+F--F+F" }, angle = 60 })
    local s = sys2:generate(3)
    local cmds = sys2:interpret(s)
    local bbox = sys2:bounds(cmds)
    T.ok(bbox.min_x <= bbox.max_x)
    T.ok(bbox.min_y <= bbox.max_y)
    T.ok(bbox.width >= 0)
    T.ok(bbox.height >= 0)
  end)
end)

-- ========================
-- SVG output
-- ========================

T.describe("to_svg", function()
  local sys = L.new({ axiom = "F", rules = { F = "F+F--F+F" }, angle = 60 })

  T.it("contains <svg tag", function()
    local svg = sys:to_svg(sys:generate(2))
    T.ok(svg:find("<svg") ~= nil)
  end)

  T.it("contains <line tags for lines", function()
    local svg = sys:to_svg(sys:generate(2))
    T.ok(svg:find("<line") ~= nil)
  end)

  T.it("contains closing </svg>", function()
    local svg = sys:to_svg(sys:generate(2))
    T.ok(svg:find("</svg>") ~= nil)
  end)

  T.it("custom width/height reflected in output", function()
    local svg = sys:to_svg(sys:generate(1), { width = 800, height = 600 })
    T.ok(svg:find('width="800"') ~= nil)
    T.ok(svg:find('height="600"') ~= nil)
  end)

  T.it("custom stroke color in output", function()
    local svg = sys:to_svg(sys:generate(1), { stroke = "red" })
    T.ok(svg:find('stroke="red"') ~= nil)
  end)

  T.it("background rect present when bg set", function()
    local svg = sys:to_svg(sys:generate(1), { bg = "white" })
    T.ok(svg:find("<rect") ~= nil)
  end)
end)

-- ========================
-- Presets
-- ========================

T.describe("presets", function()
  T.it("SIERPINSKI_TRIANGLE is a table with axiom/rules/angle", function()
    T.ok(type(L.SIERPINSKI_TRIANGLE) == "table")
    T.ok(L.SIERPINSKI_TRIANGLE.axiom ~= nil)
    T.ok(L.SIERPINSKI_TRIANGLE.rules ~= nil)
    T.ok(L.SIERPINSKI_TRIANGLE.angle ~= nil)
  end)

  T.it("DRAGON_CURVE preset generate n=4 is non-empty", function()
    local sys = L.new(L.DRAGON_CURVE)
    local s = sys:generate(4)
    T.ok(type(s) == "string")
    T.ok(#s > 0)
  end)

  T.it("KOCH_SNOWFLAKE preset generate n=2 starts with F", function()
    local sys = L.new(L.KOCH_SNOWFLAKE)
    local s = sys:generate(1)
    T.ok(s:sub(1, 1) == "F")
  end)

  T.it("FERN preset generate n=3 non-empty", function()
    local sys = L.new(L.FERN)
    local s = sys:generate(3)
    T.ok(#s > 0)
  end)

  T.it("BINARY_TREE preset generate n=2 non-empty", function()
    local sys = L.new(L.BINARY_TREE)
    local s = sys:generate(2)
    T.ok(#s > 0)
  end)

  T.it("SIERPINSKI_TRIANGLE generate n=3 without error", function()
    local sys = L.new(L.SIERPINSKI_TRIANGLE)
    local s = sys:generate(3)
    T.ok(type(s) == "string")
    T.ok(#s > 10)
  end)

  T.it("all presets can be interpreted without error", function()
    local names = { "SIERPINSKI_TRIANGLE", "DRAGON_CURVE", "KOCH_SNOWFLAKE", "FERN", "BINARY_TREE" }
    for _, name in ipairs(names) do
      local sys = L.new(L[name])
      local s = sys:generate(2)
      local cmds = sys:interpret(s)
      T.ok(type(cmds) == "table", name .. " interpret should return table")
    end
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

  T.it("generate() with negative n returns nil, err", function()
    local sys = L.new({ axiom = "F", rules = {} })
    local v, err = sys:generate(-1)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("generate() with float n returns nil, err", function()
    local sys = L.new({ axiom = "F", rules = {} })
    local v, err = sys:generate(1.5)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("interpret() with non-string returns nil, err", function()
    local sys = L.new({ axiom = "F", rules = {} })
    local v, err = sys:interpret(123)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("bounds() with non-table returns nil, err", function()
    local sys = L.new({ axiom = "F", rules = {} })
    local v, err = sys:bounds("bad")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ========================
-- Module metadata
-- ========================

T.describe("module metadata", function()
  T.it("_tier is pure", function()
    T.eq(L._tier, "pure")
  end)
end)
