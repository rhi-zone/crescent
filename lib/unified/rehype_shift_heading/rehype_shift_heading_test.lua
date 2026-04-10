-- lib/unified/rehype_shift_heading/rehype_shift_heading_test.lua
-- Tests for rehype_shift_heading plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T                 = require("lib.test.assert")
local unified           = require("lib.unified")
local rehypeShiftHeading = require("lib.unified.rehype_shift_heading")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

local function text(value)
  return { type = "text", value = value }
end

local function root(children)
  return { type = "root", children = children }
end

local function make_processor(opts)
  local p = unified.new()
  p:use(rehypeShiftHeading, opts)
  return p
end

local function run(tree, opts)
  local result, err = make_processor(opts):run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_shift_heading", function()

  T.it("shifts h1 down by 2 to h3", function()
    local tree = root({ el("h1", {}, { text("Title") }) })
    local out  = run(tree, { shift = 2 })
    T.eq(out.children[1].tag, "h3")
  end)

  T.it("shifts h5 down by 2 and clamps to h6", function()
    local tree = root({ el("h5", {}, { text("Title") }) })
    local out  = run(tree, { shift = 2 })
    T.eq(out.children[1].tag, "h6")
  end)

  T.it("shifts h6 down by 1 and clamps to h6", function()
    local tree = root({ el("h6", {}, { text("Title") }) })
    local out  = run(tree, { shift = 1 })
    T.eq(out.children[1].tag, "h6")
  end)

  T.it("shifts h2 up by 1 to h1", function()
    local tree = root({ el("h2", {}, { text("Title") }) })
    local out  = run(tree, { shift = -1 })
    T.eq(out.children[1].tag, "h1")
  end)

  T.it("shifts h1 up by 1 and clamps to h1", function()
    local tree = root({ el("h1", {}, { text("Title") }) })
    local out  = run(tree, { shift = -1 })
    T.eq(out.children[1].tag, "h1")
  end)

  T.it("shifts h3 up by 2 to h1", function()
    local tree = root({ el("h3", {}, { text("Title") }) })
    local out  = run(tree, { shift = -2 })
    T.eq(out.children[1].tag, "h1")
  end)

  T.it("does not change non-heading elements", function()
    local tree = root({
      el("p",   {}, { text("paragraph") }),
      el("div", {}, { text("block") }),
      el("span",{}, { text("inline") }),
    })
    local out = run(tree, { shift = 2 })
    T.eq(out.children[1].tag, "p")
    T.eq(out.children[2].tag, "div")
    T.eq(out.children[3].tag, "span")
  end)

  T.it("uses default shift of 1 when no opts given", function()
    local tree = root({ el("h2", {}, { text("Title") }) })
    local out  = run(tree)
    T.eq(out.children[1].tag, "h3")
  end)

  T.it("shifts headings nested inside other elements", function()
    local tree = root({
      el("div", {}, {
        el("h2", {}, { text("Nested") }),
      }),
    })
    local out = run(tree, { shift = 1 })
    T.eq(out.children[1].children[1].tag, "h3")
  end)

  T.it("shifts all heading levels independently", function()
    local tree = root({
      el("h1", {}, { text("one") }),
      el("h2", {}, { text("two") }),
      el("h3", {}, { text("three") }),
      el("h4", {}, { text("four") }),
      el("h5", {}, { text("five") }),
      el("h6", {}, { text("six") }),
    })
    local out      = run(tree, { shift = 1 })
    local expected = { "h2", "h3", "h4", "h5", "h6", "h6" }
    for i, exp in ipairs(expected) do
      T.eq(out.children[i].tag, exp)
    end
  end)

end)
