-- lib/unified/rehype_minify/rehype_minify_test.lua
-- Tests for rehype_minify plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T            = require("lib.test.assert")
local unified      = require("lib.unified")
local rehypeMinify = require("lib.unified.rehype_minify")

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
  p:use(rehypeMinify, opts)
  return p
end

local function run(tree, opts)
  local result, err = make_processor(opts):run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_minify", function()

  T.it("collapses multiple spaces in text node to single space", function()
    local tree = root({ el("p", {}, { text("hello   world") }) })
    local out  = run(tree)
    T.eq(out.children[1].children[1].value, "hello world")
  end)

  T.it("collapses tabs and spaces to single space", function()
    local tree = root({ el("p", {}, { text("a\t\t b") }) })
    local out  = run(tree)
    T.eq(out.children[1].children[1].value, "a b")
  end)

  T.it("collapses newlines to single space by default", function()
    local tree = root({ el("p", {}, { text("a\n\nb") }) })
    local out  = run(tree)
    T.eq(out.children[1].children[1].value, "a b")
  end)

  T.it("trims leading whitespace in block element children", function()
    local tree = root({ el("div", {}, { text("  hello") }) })
    local out  = run(tree)
    T.eq(out.children[1].children[1].value, "hello")
  end)

  T.it("trims trailing whitespace in block element children", function()
    local tree = root({ el("div", {}, { text("hello   ") }) })
    local out  = run(tree)
    T.eq(out.children[1].children[1].value, "hello")
  end)

  T.it("removes whitespace-only text nodes between block elements", function()
    local tree = root({
      el("div", {}, {
        el("p", {}, { text("a") }),
        text("   \n   "),
        el("p", {}, { text("b") }),
      }),
    })
    local out = run(tree)
    local div = out.children[1]
    -- whitespace-only text node should be removed; only 2 children remain.
    T.eq(#div.children, 2)
    T.eq(div.children[1].tag, "p")
    T.eq(div.children[2].tag, "p")
  end)

  T.it("does not remove non-empty text nodes between block elements", function()
    local tree = root({
      el("div", {}, {
        el("p", {}, { text("a") }),
        text(" and "),
        el("p", {}, { text("b") }),
      }),
    })
    local out = run(tree)
    local div = out.children[1]
    T.eq(#div.children, 3)
  end)

  T.it("preserves pre content verbatim", function()
    local pre_text = "  line1\n  line2\n   spaced"
    local tree = root({
      el("pre", {}, {
        el("code", {}, { text(pre_text) }),
      }),
    })
    local out  = run(tree)
    -- Walk into pre > code > text.
    local pre  = out.children[1]
    local code = pre.children[1]
    T.eq(code.children[1].value, pre_text)
  end)

  T.it("does not collapse whitespace in inline element inside pre", function()
    local inner = "  spaced  content  "
    local tree = root({
      el("pre", {}, {
        el("span", {}, { text(inner) }),
      }),
    })
    local out  = run(tree)
    local span = out.children[1].children[1]
    T.eq(span.children[1].value, inner)
  end)

  T.it("preserves newlines when opts.newlines is false", function()
    local tree = root({ el("p", {}, { text("a\n\nb") }) })
    local out  = run(tree, { newlines = false })
    -- newlines should NOT be collapsed, but spaces within lines may be.
    T.ok(out.children[1].children[1].value:find("\n") ~= nil,
      "newlines should be preserved when opts.newlines=false")
  end)

  T.it("does not alter inline element whitespace (not a block)", function()
    -- <span> is inline; its text children should be collapsed but not trimmed.
    local tree = root({
      el("span", {}, { text("  hello  world  ") }),
    })
    local out  = run(tree)
    -- collapsed but NOT trimmed (span is not a block).
    T.eq(out.children[1].children[1].value, " hello world ")
  end)

end)
