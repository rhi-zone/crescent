-- lib/unified/rehype_format/rehype_format_test.lua
-- Tests for rehype_format plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T            = require("lib.test.assert")
local unified      = require("lib.unified")
local rehypeFormat = require("lib.unified.rehype_format")

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
  p:use(rehypeFormat, opts)
  return p
end

local function run(tree, opts)
  local result, err = make_processor(opts):run(tree)
  if not result then error(err) end
  return result
end

-- Collect all text node values from a node tree into a flat list.
local function collect_texts(node, out)
  out = out or {}
  if node.type == "text" then
    out[#out + 1] = node.value
  end
  if node.children then
    for _, child in ipairs(node.children) do
      collect_texts(child, out)
    end
  end
  return out
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_format", function()

  T.it("adds newline and indent before children of block element", function()
    local tree = root({ el("div", {}, { el("p", {}, { text("Hello") }) }) })
    local out  = run(tree)
    -- div should now have 3 children: leading text, p, trailing text
    local div = out.children[1]
    T.eq(div.tag, "div")
    T.ok(#div.children >= 3, "div should have at least 3 children after formatting")
    -- First child is a whitespace text node containing a newline.
    T.eq(div.children[1].type, "text")
    T.ok(div.children[1].value:find("\n") ~= nil, "first child should contain newline")
  end)

  T.it("adds trailing newline before closing tag of block element", function()
    local tree = root({ el("div", {}, { text("content") }) })
    local out  = run(tree)
    local div  = out.children[1]
    local last = div.children[#div.children]
    T.eq(last.type, "text")
    T.ok(last.value:find("\n") ~= nil, "last child should contain newline")
  end)

  T.it("indents nested block elements", function()
    local tree = root({
      el("div", {}, {
        el("p", {}, { text("Hello") }),
      }),
    })
    local out  = run(tree)
    local div  = out.children[1]
    -- Find the p element inside div.
    local p_node = nil
    for _, ch in ipairs(div.children) do
      if ch.type == "element" and ch.tag == "p" then
        p_node = ch
        break
      end
    end
    T.ok(p_node ~= nil, "p element should exist inside div")
    -- p should also be formatted: its children should include indent text nodes.
    T.ok(#p_node.children >= 3, "p should have leading/trailing indent nodes")
  end)

  T.it("uses two-space indent by default", function()
    local tree = root({ el("div", {}, { el("p", {}, { text("x") }) }) })
    local out  = run(tree)
    local div  = out.children[1]
    -- Leading text node inside div should be "\n  " (newline + 2 spaces).
    T.eq(div.children[1].value, "\n  ")
  end)

  T.it("respects custom indent option", function()
    local tree = root({ el("div", {}, { el("p", {}, { text("x") }) }) })
    local out  = run(tree, { indent = "\t" })
    local div  = out.children[1]
    T.eq(div.children[1].value, "\n\t")
  end)

  T.it("does not add whitespace around inline elements", function()
    -- <p> is block; <strong> inside it is inline.
    local tree = root({
      el("p", {}, {
        text("Hello "),
        el("strong", {}, { text("world") }),
      }),
    })
    local out = run(tree)
    local p   = out.children[1]
    -- strong should NOT have indent nodes injected inside it.
    local strong = nil
    for _, ch in ipairs(p.children) do
      if ch.type == "element" and ch.tag == "strong" then
        strong = ch
        break
      end
    end
    T.ok(strong ~= nil, "strong should exist")
    -- strong's children should still be just the text node.
    T.eq(#strong.children, 1)
    T.eq(strong.children[1].value, "world")
  end)

  T.it("preserves pre content verbatim", function()
    local pre_text = "  line1\n  line2\n"
    local tree = root({
      el("pre", {}, {
        el("code", {}, { text(pre_text) }),
      }),
    })
    local out  = run(tree)
    local pre  = out.children[1]
    -- pre itself gets formatted (it's a block), but code inside is inline
    -- and its text content must not be altered.
    local code = nil
    for _, ch in ipairs(pre.children) do
      if ch.type == "element" and ch.tag == "code" then
        code = ch
        break
      end
    end
    T.ok(code ~= nil, "code element should exist")
    T.eq(#code.children, 1)
    T.eq(code.children[1].value, pre_text)
  end)

  T.it("increases indent with nesting depth", function()
    -- div > ul > li — three levels deep.
    local tree = root({
      el("div", {}, {
        el("ul", {}, {
          el("li", {}, { text("item") }),
        }),
      }),
    })
    local out = run(tree)
    -- Collect all indent text values.
    local texts = collect_texts(out)
    -- Should include "\n    " (4 spaces) somewhere for li level.
    local found_deep = false
    for _, v in ipairs(texts) do
      if v == "\n    " then
        found_deep = true
        break
      end
    end
    T.ok(found_deep, "should have 4-space indent at 2 levels deep inside root")
  end)

  T.it("h1-h6 are treated as block elements", function()
    for _, tag in ipairs({ "h1", "h2", "h3", "h4", "h5", "h6" }) do
      local tree = root({ el(tag, {}, { text("Title") }) })
      local out  = run(tree)
      local heading = out.children[1]
      T.ok(#heading.children >= 3,
        tag .. " should have leading/trailing indent nodes")
    end
  end)

end)
