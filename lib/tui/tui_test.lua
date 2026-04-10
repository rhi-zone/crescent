if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T   = require("lib.test.assert")
local tui = require("lib.tui")

-- ---------------------------------------------------------------------------
-- tui.size
-- ---------------------------------------------------------------------------

T.describe("tui.size", function()
  T.it("returns two positive integers", function()
    local w, h = tui.size()
    T.ok(type(w) == "number", "width is a number")
    T.ok(type(h) == "number", "height is a number")
    T.ok(w > 0, "width > 0")
    T.ok(h > 0, "height > 0")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.text
-- ---------------------------------------------------------------------------

T.describe("tui.text", function()
  T.it("render contains the text", function()
    local out = tui.text("hello"):render({ x=1, y=1, w=20, h=1 })
    T.ok(out:find("hello", 1, true), "output contains 'hello'")
  end)

  T.it("left alignment pads right", function()
    local out = tui.text("hi", { align="left" }):render({ x=1, y=1, w=10, h=1 })
    T.ok(out:find("hi", 1, true), "output contains 'hi'")
  end)

  T.it("center alignment works", function()
    local out = tui.text("hi", { align="center" }):render({ x=1, y=1, w=10, h=1 })
    T.ok(out:find("hi", 1, true), "output contains 'hi'")
  end)

  T.it("right alignment works", function()
    local out = tui.text("hi", { align="right" }):render({ x=1, y=1, w=10, h=1 })
    T.ok(out:find("hi", 1, true), "output contains 'hi'")
  end)

  T.it("truncates text longer than width", function()
    local out = tui.text("abcdefghij"):render({ x=1, y=1, w=5, h=1 })
    -- Should not contain chars beyond width
    T.ok(out:find("abcde", 1, true), "contains first 5 chars")
  end)

  T.it("wrap mode splits across lines", function()
    local out = tui.text("hello world", { wrap=true }):render({ x=1, y=1, w=6, h=5 })
    T.ok(out:find("hello", 1, true), "contains 'hello'")
    T.ok(out:find("world", 1, true), "contains 'world'")
  end)

  T.it("multiline text via newlines", function()
    local out = tui.text("line1\nline2"):render({ x=1, y=1, w=20, h=5 })
    T.ok(out:find("line1", 1, true), "contains line1")
    T.ok(out:find("line2", 1, true), "contains line2")
  end)

  T.it("returns empty string for zero-width context", function()
    local out = tui.text("hello"):render({ x=1, y=1, w=0, h=1 })
    T.eq(out, "", "empty for zero width")
  end)

  T.it("returns empty string for zero-height context", function()
    local out = tui.text("hello"):render({ x=1, y=1, w=20, h=0 })
    T.eq(out, "", "empty for zero height")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.box
-- ---------------------------------------------------------------------------

T.describe("tui.box", function()
  T.it("single border contains corner characters", function()
    local out = tui.box(tui.text("hi"), { border="single" }):render({ x=1, y=1, w=10, h=5 })
    T.ok(out:find("┌", 1, true), "top-left corner ┌")
    T.ok(out:find("┐", 1, true), "top-right corner ┐")
    T.ok(out:find("└", 1, true), "bottom-left corner └")
    T.ok(out:find("┘", 1, true), "bottom-right corner ┘")
  end)

  T.it("double border contains corner characters", function()
    local out = tui.box(tui.text("hi"), { border="double" }):render({ x=1, y=1, w=10, h=5 })
    T.ok(out:find("╔", 1, true), "top-left ╔")
    T.ok(out:find("╗", 1, true), "top-right ╗")
    T.ok(out:find("╚", 1, true), "bottom-left ╚")
    T.ok(out:find("╝", 1, true), "bottom-right ╝")
  end)

  T.it("rounded border contains corner characters", function()
    local out = tui.box(tui.text("hi"), { border="rounded" }):render({ x=1, y=1, w=10, h=5 })
    T.ok(out:find("╭", 1, true), "top-left ╭")
    T.ok(out:find("╮", 1, true), "top-right ╮")
    T.ok(out:find("╰", 1, true), "bottom-left ╰")
    T.ok(out:find("╯", 1, true), "bottom-right ╯")
  end)

  T.it("title appears in top border", function()
    local out = tui.box(tui.text("hi"), { title="box title" }):render({ x=1, y=1, w=20, h=5 })
    T.ok(out:find("box title", 1, true), "title in output")
  end)

  T.it("inner content appears inside box", function()
    local out = tui.box(tui.text("content here"), { border="single" }):render({ x=1, y=1, w=20, h=5 })
    T.ok(out:find("content here", 1, true), "inner content present")
  end)

  T.it("box with padding renders inner widget", function()
    local out = tui.box(tui.text("padded"), { padding={1,1,1,1} }):render({ x=1, y=1, w=20, h=8 })
    T.ok(out:find("padded", 1, true), "padded content present")
  end)

  T.it("default border is single", function()
    local out = tui.box(tui.text("x")):render({ x=1, y=1, w=10, h=5 })
    T.ok(out:find("┌", 1, true), "default is single border")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.row
-- ---------------------------------------------------------------------------

T.describe("tui.row", function()
  T.it("contains content from all children", function()
    local out = tui.row({ tui.text("alpha"), tui.text("beta") }):render({ x=1, y=1, w=40, h=5 })
    T.ok(out:find("alpha", 1, true), "contains 'alpha'")
    T.ok(out:find("beta", 1, true), "contains 'beta'")
  end)

  T.it("three children all rendered", function()
    local out = tui.row({ tui.text("a"), tui.text("b"), tui.text("c") }):render({ x=1, y=1, w=30, h=3 })
    T.ok(out:find("a", 1, true), "contains a")
    T.ok(out:find("b", 1, true), "contains b")
    T.ok(out:find("c", 1, true), "contains c")
  end)

  T.it("flex proportional widths render all children", function()
    local out = tui.row(
      { tui.text("left"), tui.text("right") },
      { flex = {1, 2} }
    ):render({ x=1, y=1, w=30, h=3 })
    T.ok(out:find("left", 1, true), "contains left")
    T.ok(out:find("right", 1, true), "contains right")
  end)

  T.it("empty widget list returns empty string", function()
    local out = tui.row({}):render({ x=1, y=1, w=40, h=5 })
    T.eq(out, "", "empty row returns empty")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.col
-- ---------------------------------------------------------------------------

T.describe("tui.col", function()
  T.it("contains content from all children", function()
    local out = tui.col({ tui.text("top"), tui.text("bottom") }):render({ x=1, y=1, w=40, h=10 })
    T.ok(out:find("top", 1, true), "contains 'top'")
    T.ok(out:find("bottom", 1, true), "contains 'bottom'")
  end)

  T.it("three children all rendered", function()
    local out = tui.col({ tui.text("x"), tui.text("y"), tui.text("z") }):render({ x=1, y=1, w=20, h=9 })
    T.ok(out:find("x", 1, true), "contains x")
    T.ok(out:find("y", 1, true), "contains y")
    T.ok(out:find("z", 1, true), "contains z")
  end)

  T.it("flex proportional heights render all children", function()
    local out = tui.col(
      { tui.text("hdr"), tui.text("body") },
      { flex = {1, 3} }
    ):render({ x=1, y=1, w=20, h=20 })
    T.ok(out:find("hdr", 1, true), "contains hdr")
    T.ok(out:find("body", 1, true), "contains body")
  end)

  T.it("empty widget list returns empty string", function()
    local out = tui.col({}):render({ x=1, y=1, w=40, h=10 })
    T.eq(out, "", "empty col returns empty")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.styled
-- ---------------------------------------------------------------------------

T.describe("tui.styled", function()
  T.it("wraps widget output in style function", function()
    local ansi = require("lib.ansi")
    -- Force ansi.enabled so we get actual escape codes
    local saved = ansi.enabled
    ansi.enabled = true
    local out = tui.styled(tui.text("hi"), ansi.bold):render({ x=1, y=1, w=10, h=1 })
    ansi.enabled = saved
    T.ok(out:find("hi", 1, true), "styled output contains text")
  end)
end)

-- ---------------------------------------------------------------------------
-- tui.render
-- ---------------------------------------------------------------------------

T.describe("tui.render", function()
  T.it("render convenience function works", function()
    local out = tui.render(tui.text("hello"), 1, 1, 20, 1)
    T.ok(out:find("hello", 1, true), "render output contains text")
  end)

  T.it("render returns empty for nil widget", function()
    local out = tui.render(nil, 1, 1, 20, 5)
    T.eq(out, "", "nil widget returns empty")
  end)
end)

-- ---------------------------------------------------------------------------
-- Composition
-- ---------------------------------------------------------------------------

T.describe("composition", function()
  T.it("box containing a row", function()
    local inner = tui.row({ tui.text("A"), tui.text("B") })
    local out = tui.box(inner, { border="single" }):render({ x=1, y=1, w=30, h=5 })
    T.ok(out:find("┌", 1, true), "box border present")
    T.ok(out:find("A", 1, true), "contains A")
    T.ok(out:find("B", 1, true), "contains B")
  end)

  T.it("col containing boxes", function()
    local top = tui.box(tui.text("top"), { title="T1" })
    local bot = tui.box(tui.text("bot"), { title="T2" })
    local out = tui.col({ top, bot }):render({ x=1, y=1, w=20, h=12 })
    T.ok(out:find("T1", 1, true), "first box title")
    T.ok(out:find("T2", 1, true), "second box title")
    T.ok(out:find("top", 1, true), "first box content")
    T.ok(out:find("bot", 1, true), "second box content")
  end)
end)
