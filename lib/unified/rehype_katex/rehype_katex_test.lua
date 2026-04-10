-- lib/rehype_katex/rehype_katex_test.lua
-- Tests for lib/unified/rehype_katex.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T       = require("lib.test.assert")
local unified = require("lib.unified")
local katex   = require("lib.unified.rehype_katex")

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

local function run(tree, opts)
  local p = unified.new()
  p:use(katex, opts)
  local result, err = p:run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_katex", function()

  T.it("transforms inlineMath to span.math.math-inline", function()
    local tree = root({
      { type = "inlineMath", value = "E=mc^2" }
    })
    local out = run(tree)
    local node = out.children[1]
    T.eq(node.type, "element")
    T.eq(node.tag, "span")
    T.eq(node.props.class, "math math-inline")
  end)

  T.it("inlineMath contains code child with raw LaTeX", function()
    local tree = root({
      { type = "inlineMath", value = "E=mc^2" }
    })
    local out = run(tree)
    local span = out.children[1]
    local code = span.children[1]
    T.eq(code.type, "element")
    T.eq(code.tag, "code")
    T.eq(code.children[1].value, "E=mc^2")
  end)

  T.it("transforms display math (type=math) to div.math.math-display", function()
    local tree = root({
      { type = "math", value = "\\frac{1}{2}" }
    })
    local out = run(tree)
    local node = out.children[1]
    T.eq(node.type, "element")
    T.eq(node.tag, "div")
    T.eq(node.props.class, "math math-display")
  end)

  T.it("display math contains code child with raw LaTeX", function()
    local tree = root({
      { type = "math", value = "\\frac{1}{2}" }
    })
    local out = run(tree)
    local div = out.children[1]
    local code = div.children[1]
    T.eq(code.tag, "code")
    T.eq(code.children[1].value, "\\frac{1}{2}")
  end)

  T.it("respects custom class_names for inline math", function()
    local tree = root({
      { type = "inlineMath", value = "x" }
    })
    local out = run(tree, { class_names = { inline = "my-inline-math" } })
    T.eq(out.children[1].props.class, "my-inline-math")
  end)

  T.it("respects custom class_names for display math", function()
    local tree = root({
      { type = "math", value = "x" }
    })
    local out = run(tree, { class_names = { display = "my-display-math" } })
    T.eq(out.children[1].props.class, "my-display-math")
  end)

  T.it("leaves non-math nodes untouched", function()
    local tree = root({
      el("p", {}, { text("Plain text") })
    })
    local out = run(tree)
    local node = out.children[1]
    T.eq(node.type, "element")
    T.eq(node.tag, "p")
  end)

  T.it("transforms math nodes nested inside paragraphs", function()
    local tree = root({
      el("p", {}, {
        text("The formula "),
        { type = "inlineMath", value = "a^2 + b^2 = c^2" },
        text(" is Pythagoras."),
      })
    })
    local out = run(tree)
    local p = out.children[1]
    T.eq(p.tag, "p")
    local math_node = p.children[2]
    T.eq(math_node.tag, "span")
    T.eq(math_node.props.class, "math math-inline")
  end)

  T.it("handles empty math value", function()
    local tree = root({
      { type = "inlineMath", value = "" }
    })
    local out = run(tree)
    local span = out.children[1]
    T.eq(span.tag, "span")
    T.eq(span.children[1].children[1].value, "")
  end)

  T.it("output option defaults to html", function()
    -- Just verify it doesn't error with output = "html".
    local tree = root({ { type = "math", value = "x" } })
    local ok = pcall(run, tree, { output = "html" })
    T.eq(ok, true)
  end)

end)
