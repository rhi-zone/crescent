-- lib/rehype_infer_title/rehype_infer_title_test.lua
-- Tests for lib/unified/rehype_infer_title.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T          = require("lib.test.assert")
local unified    = require("lib.unified")
local inferTitle = require("lib.unified.rehype_infer_title")

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

local function run(tree)
  local p = unified.new()
  p:use(inferTitle)
  local result, err = p:run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_infer_title", function()

  T.it("infers title from first h1", function()
    local tree = root({ el("h1", {}, { text("Hello World") }) })
    local out = run(tree)
    T.eq(out.data.title, "Hello World")
  end)

  T.it("infers title from h2 when no h1 exists", function()
    local tree = root({ el("h2", {}, { text("Section One") }) })
    local out = run(tree)
    T.eq(out.data.title, "Section One")
  end)

  T.it("uses the first heading when multiple exist", function()
    local tree = root({
      el("h2", {}, { text("First") }),
      el("h1", {}, { text("Second") }),
    })
    local out = run(tree)
    T.eq(out.data.title, "First")
  end)

  T.it("concatenates text from nested children", function()
    local tree = root({
      el("h1", {}, {
        text("Hello "),
        el("em", {}, { text("World") }),
      })
    })
    local out = run(tree)
    T.eq(out.data.title, "Hello World")
  end)

  T.it("does not set title when no headings exist", function()
    local tree = root({
      el("p", {}, { text("Just a paragraph") })
    })
    local out = run(tree)
    T.eq(out.data, nil)
  end)

  T.it("does not set title when heading text is empty", function()
    local tree = root({ el("h1", {}, {}) })
    local out = run(tree)
    T.eq(out.data, nil)
  end)

  T.it("preserves existing root.data fields", function()
    local tree = root({ el("h1", {}, { text("My Title") }) })
    tree.data = { existing = "value" }
    local out = run(tree)
    T.eq(out.data.title, "My Title")
    T.eq(out.data.existing, "value")
  end)

  T.it("finds heading nested inside other elements", function()
    local tree = root({
      el("header", {}, {
        el("h1", {}, { text("Nested Title") })
      })
    })
    local out = run(tree)
    T.eq(out.data.title, "Nested Title")
  end)

  T.it("handles all heading levels h1-h6", function()
    for depth = 1, 6 do
      local tag = "h" .. depth
      local tree = root({ el(tag, {}, { text("Heading " .. depth) }) })
      local out = run(tree)
      T.eq(out.data.title, "Heading " .. depth)
    end
  end)

end)
