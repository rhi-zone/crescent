if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local layout = require("lib.layout")

local function approx(a, b, eps)
  eps = eps or 0.001
  return math.abs(a - b) < eps
end

local function rect_approx(r, x, y, w, h)
  T.ok(approx(r.x, x),     "x: expected " .. x .. " got " .. r.x)
  T.ok(approx(r.y, y),     "y: expected " .. y .. " got " .. r.y)
  T.ok(approx(r.width, w), "w: expected " .. w .. " got " .. r.width)
  T.ok(approx(r.height, h),"h: expected " .. h .. " got " .. r.height)
end

-- ---------------------------------------------------------------------------
-- Row: two fixed children side by side
-- ---------------------------------------------------------------------------
T.describe("row", function()
  T.it("two fixed children side by side", function()
    local root = layout.box({
      width = 400, height = 100,
      direction = "row",
      children = {
        layout.box({ id = "a", width = 100, height = 100 }),
        layout.box({ id = "b", width = 200, height = 100 }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("a"), 0,   0, 100, 100)
    rect_approx(r:get("b"), 100, 0, 200, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- Col: fixed + flex + fixed = total height
-- ---------------------------------------------------------------------------
T.describe("col", function()
  T.it("fixed + flex + fixed = total height", function()
    local root = layout.box({
      width = 100, height = 300,
      direction = "col",
      children = {
        layout.box({ id = "top",    width = 100, height = 50 }),
        layout.box({ id = "middle", width = 100, flex = 1 }),
        layout.box({ id = "bottom", width = 100, height = 50 }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("top"),    0,   0, 100,  50)
    rect_approx(r:get("middle"), 0,  50, 100, 200)
    rect_approx(r:get("bottom"), 0, 250, 100,  50)
  end)
end)

-- ---------------------------------------------------------------------------
-- Flex: remaining space distributed proportionally
-- ---------------------------------------------------------------------------
T.describe("flex", function()
  T.it("remaining space distributed proportionally (1:2)", function()
    local root = layout.box({
      width = 300, height = 100,
      direction = "row",
      children = {
        layout.box({ id = "a", flex = 1 }),
        layout.box({ id = "b", flex = 2 }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("a"),   0, 0, 100, 100)
    rect_approx(r:get("b"), 100, 0, 200, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- Padding: reduces child area
-- ---------------------------------------------------------------------------
T.describe("padding", function()
  T.it("padding reduces child area", function()
    local root = layout.box({
      width = 200, height = 200,
      direction = "row",
      padding = 20,
      children = {
        layout.box({ id = "child", flex = 1, height = "fill" }),
      }
    })
    local r = layout.compute(root)
    -- inner = 200-40 = 160 wide, 160 tall; child starts at (20,20)
    rect_approx(r:get("child"), 20, 20, 160, 160)
  end)
end)

-- ---------------------------------------------------------------------------
-- Gap: space between children
-- ---------------------------------------------------------------------------
T.describe("gap", function()
  T.it("gap between children", function()
    local root = layout.box({
      width = 310, height = 100,
      direction = "row",
      gap = 10,
      children = {
        layout.box({ id = "a", width = 100, height = 100 }),
        layout.box({ id = "b", width = 100, height = 100 }),
        layout.box({ id = "c", width = 100, height = 100 }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("a"),   0, 0, 100, 100)
    rect_approx(r:get("b"), 110, 0, 100, 100)
    rect_approx(r:get("c"), 220, 0, 100, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- Nested: row inside col at correct position
-- ---------------------------------------------------------------------------
T.describe("nested", function()
  T.it("row inside col at correct position", function()
    local root = layout.box({
      width = 200, height = 200,
      direction = "col",
      children = {
        layout.box({ id = "top", width = 200, height = 50 }),
        layout.box({
          id = "row", flex = 1,
          direction = "row",
          children = {
            layout.box({ id = "left",  width = 80,  height = "fill" }),
            layout.box({ id = "right", flex = 1, height = "fill" }),
          }
        }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("top"),   0,   0, 200,  50)
    rect_approx(r:get("row"),   0,  50, 200, 150)
    rect_approx(r:get("left"),  0,  50,  80, 150)
    rect_approx(r:get("right"), 80, 50, 120, 150)
  end)
end)

-- ---------------------------------------------------------------------------
-- align_items center: children centered on cross axis
-- ---------------------------------------------------------------------------
T.describe("align_items", function()
  T.it("center: children centered on cross axis", function()
    local root = layout.box({
      width = 200, height = 100,
      direction = "row",
      align_items = "center",
      children = {
        layout.box({ id = "a", width = 50, height = 40 }),
      }
    })
    local r = layout.compute(root)
    -- cross-axis = height; child h=40 in 100 -> offset = (100-40)/2 = 30
    rect_approx(r:get("a"), 0, 30, 50, 40)
  end)
end)

-- ---------------------------------------------------------------------------
-- justify_content space_between: equal gaps between children
-- ---------------------------------------------------------------------------
T.describe("justify_content", function()
  T.it("space_between: equal gaps", function()
    local root = layout.box({
      width = 300, height = 50,
      direction = "row",
      justify_content = "space_between",
      children = {
        layout.box({ id = "a", width = 50, height = 50 }),
        layout.box({ id = "b", width = 50, height = 50 }),
        layout.box({ id = "c", width = 50, height = 50 }),
      }
    })
    local r = layout.compute(root)
    -- 300 - 3*50 = 150 remaining; 2 gaps -> 75 each
    rect_approx(r:get("a"),   0, 0, 50, 50)
    rect_approx(r:get("b"), 125, 0, 50, 50)
    rect_approx(r:get("c"), 250, 0, 50, 50)
  end)
end)

-- ---------------------------------------------------------------------------
-- Absolute positioned: at exact coordinates
-- ---------------------------------------------------------------------------
T.describe("absolute", function()
  T.it("absolute positioned at exact coordinates", function()
    local root = layout.box({
      width = 400, height = 400,
      children = {
        layout.box({ id = "abs", position = "absolute", x = 10, y = 20, width = 100, height = 50 }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("abs"), 10, 20, 100, 50)
  end)
end)

-- ---------------------------------------------------------------------------
-- Aspect ratio: height computed from width
-- ---------------------------------------------------------------------------
T.describe("aspect_ratio", function()
  T.it("height computed from width", function()
    local root = layout.box({
      width = 400, height = 400,
      direction = "row",
      children = {
        layout.box({ id = "video", width = 320, aspect_ratio = 16/9 }),
      }
    })
    local r = layout.compute(root)
    local v = r:get("video")
    T.ok(approx(v.width,  320), "width should be 320")
    T.ok(approx(v.height, 180), "height should be 180")
  end)
end)

-- ---------------------------------------------------------------------------
-- Min/max constraints: constrained correctly
-- ---------------------------------------------------------------------------
T.describe("min_max", function()
  T.it("min_width enforced", function()
    local root = layout.box({
      width = 200, height = 100,
      direction = "row",
      children = {
        layout.box({ id = "a", flex = 1, min_width = 150 }),
      }
    })
    local r = layout.compute(root)
    T.ok(r:get("a").width >= 150, "min_width enforced")
  end)

  T.it("max_width enforced", function()
    local root = layout.box({
      width = 500, height = 100,
      direction = "row",
      children = {
        layout.box({ id = "a", flex = 1, max_width = 100 }),
      }
    })
    local r = layout.compute(root)
    T.ok(r:get("a").width <= 100, "max_width enforced")
  end)

  T.it("min_height enforced", function()
    local root = layout.box({
      width = 100, height = 200,
      direction = "col",
      children = {
        layout.box({ id = "a", flex = 1, min_height = 150 }),
      }
    })
    local r = layout.compute(root)
    T.ok(r:get("a").height >= 150, "min_height enforced")
  end)
end)

-- ---------------------------------------------------------------------------
-- Grid: fixed column widths
-- ---------------------------------------------------------------------------
T.describe("grid", function()
  T.it("fixed column widths", function()
    local g = layout.grid({
      id = "root",
      width = 300, height = 100,
      columns = {100, 100, 100},
      rows    = {100},
      gap     = 0,
      children = {
        layout.cell({ id = "c1", col = 1, row = 1 }),
        layout.cell({ id = "c2", col = 2, row = 1 }),
        layout.cell({ id = "c3", col = 3, row = 1 }),
      }
    })
    local r = layout.compute(g)
    rect_approx(r:get("c1"),   0, 0, 100, 100)
    rect_approx(r:get("c2"), 100, 0, 100, 100)
    rect_approx(r:get("c3"), 200, 0, 100, 100)
  end)

  -- Grid: fractional columns divide remaining space
  T.it("fractional columns divide remaining space", function()
    local g = layout.grid({
      width = 900, height = 100,
      columns = {"1fr", "2fr", "3fr"},
      rows    = {100},
      gap     = 0,
      children = {
        layout.cell({ id = "c1", col = 1, row = 1 }),
        layout.cell({ id = "c2", col = 2, row = 1 }),
        layout.cell({ id = "c3", col = 3, row = 1 }),
      }
    })
    local r = layout.compute(g)
    rect_approx(r:get("c1"),   0, 0, 150, 100)
    rect_approx(r:get("c2"), 150, 0, 300, 100)
    rect_approx(r:get("c3"), 450, 0, 450, 100)
  end)

  -- col_span: element spans multiple columns
  T.it("col_span spans multiple columns", function()
    local g = layout.grid({
      width = 300, height = 100,
      columns = {100, 100, 100},
      rows    = {100},
      gap     = 0,
      children = {
        layout.cell({ id = "wide", col = 1, row = 1, col_span = 2 }),
        layout.cell({ id = "last", col = 3, row = 1 }),
      }
    })
    local r = layout.compute(g)
    rect_approx(r:get("wide"), 0,   0, 200, 100)
    rect_approx(r:get("last"), 200, 0, 100, 100)
  end)
end)

-- ---------------------------------------------------------------------------
-- fill height: takes parent height
-- ---------------------------------------------------------------------------
T.describe("fill", function()
  T.it("fill height takes parent height", function()
    local root = layout.box({
      width = 200, height = 150,
      direction = "row",
      children = {
        layout.box({ id = "sidebar", width = 50, height = "fill" }),
      }
    })
    local r = layout.compute(root)
    rect_approx(r:get("sidebar"), 0, 0, 50, 150)
  end)
end)

-- ---------------------------------------------------------------------------
-- Root without explicit width/height uses children
-- ---------------------------------------------------------------------------
T.describe("root sizing", function()
  T.it("root with explicit width/height records itself", function()
    local root = layout.box({
      id = "root",
      width = 100, height = 200,
    })
    local r = layout.compute(root)
    rect_approx(r:get("root"), 0, 0, 100, 200)
  end)
end)
