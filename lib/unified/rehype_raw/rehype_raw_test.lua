-- lib/rehype_raw/rehype_raw_test.lua
-- Tests for lib/unified/rehype_raw.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T         = require("lib.test.assert")
local unified   = require("lib.unified")
local rehypeRaw = require("lib.unified.rehype_raw")

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

local function raw(value)
  return { type = "raw", value = value }
end

local function html(value)
  return { type = "html", value = value }
end

local function run(tree)
  local p = unified.new()
  p:use(rehypeRaw)
  local result, err = p:run(tree)
  if not result then error(err) end
  return result
end

-- ── Tokenizer unit tests ──────────────────────────────────────────────────────

T.describe("rehype_raw tokenizer", function()

  T.it("tokenizes open tag", function()
    local tokens = rehypeRaw._tokenize("<div>")
    T.eq(tokens[1].type, "open")
    T.eq(tokens[1].tag, "div")
  end)

  T.it("tokenizes close tag", function()
    local tokens = rehypeRaw._tokenize("</div>")
    T.eq(tokens[1].type, "close")
    T.eq(tokens[1].tag, "div")
  end)

  T.it("tokenizes text", function()
    local tokens = rehypeRaw._tokenize("hello")
    T.eq(tokens[1].type, "text")
    T.eq(tokens[1].value, "hello")
  end)

  T.it("tokenizes attributes with double quotes", function()
    local tokens = rehypeRaw._tokenize('<div class="foo">')
    T.eq(tokens[1].attrs.class, "foo")
  end)

  T.it("tokenizes attributes with single quotes", function()
    local tokens = rehypeRaw._tokenize("<div class='bar'>")
    T.eq(tokens[1].attrs.class, "bar")
  end)

  T.it("tokenizes boolean attributes", function()
    local tokens = rehypeRaw._tokenize("<input disabled>")
    T.eq(tokens[1].attrs.disabled, true)
  end)

  T.it("tokenizes void elements as open+close pair", function()
    local tokens = rehypeRaw._tokenize("<br>")
    T.eq(#tokens, 2)
    T.eq(tokens[1].type, "open")
    T.eq(tokens[2].type, "close")
  end)

  T.it("tokenizes self-closing syntax as void", function()
    local tokens = rehypeRaw._tokenize("<br/>")
    T.eq(#tokens, 2)
    T.eq(tokens[1].type, "open")
    T.eq(tokens[1].void, true)
  end)

  T.it("tokenizes HTML comments", function()
    local tokens = rehypeRaw._tokenize("<!-- hello -->")
    T.eq(tokens[1].type, "comment")
    T.eq(tokens[1].value, " hello ")
  end)

end)

-- ── Parser unit tests ─────────────────────────────────────────────────────────

T.describe("rehype_raw parser", function()

  T.it("parses a simple element", function()
    local nodes = rehypeRaw._parse_html("<div></div>")
    T.eq(#nodes, 1)
    T.eq(nodes[1].type, "element")
    T.eq(nodes[1].tag, "div")
  end)

  T.it("parses element with class attribute", function()
    local nodes = rehypeRaw._parse_html('<div class="note"></div>')
    T.eq(nodes[1].props.class, "note")
  end)

  T.it("parses element with text content", function()
    local nodes = rehypeRaw._parse_html("<p>Hello</p>")
    T.eq(nodes[1].children[1].type, "text")
    T.eq(nodes[1].children[1].value, "Hello")
  end)

  T.it("parses nested elements", function()
    local nodes = rehypeRaw._parse_html("<div><p>Inner</p></div>")
    local div = nodes[1]
    T.eq(div.tag, "div")
    local p = div.children[1]
    T.eq(p.tag, "p")
    T.eq(p.children[1].value, "Inner")
  end)

  T.it("parses void elements without children", function()
    local nodes = rehypeRaw._parse_html("<br>")
    T.eq(nodes[1].tag, "br")
    T.eq(#nodes[1].children, 0)
  end)

  T.it("parses multiple sibling elements", function()
    local nodes = rehypeRaw._parse_html("<p>A</p><p>B</p>")
    T.eq(#nodes, 2)
    T.eq(nodes[1].children[1].value, "A")
    T.eq(nodes[2].children[1].value, "B")
  end)

  T.it("returns empty list for empty string", function()
    local nodes = rehypeRaw._parse_html("")
    T.eq(#nodes, 0)
  end)

end)

-- ── Plugin integration tests ──────────────────────────────────────────────────

T.describe("rehype_raw plugin", function()

  T.it("replaces html node with parsed element", function()
    local tree = root({ html('<div class="note">Hello</div>') })
    local out = run(tree)
    local node = out.children[1]
    T.eq(node.type, "element")
    T.eq(node.tag, "div")
    T.eq(node.props.class, "note")
  end)

  T.it("replaces raw node with parsed element", function()
    local tree = root({ raw('<span id="x">text</span>') })
    local out = run(tree)
    local node = out.children[1]
    T.eq(node.type, "element")
    T.eq(node.tag, "span")
    T.eq(node.props.id, "x")
  end)

  T.it("leaves regular element nodes untouched", function()
    local tree = root({ el("p", {}, { text("plain") }) })
    local out = run(tree)
    T.eq(out.children[1].tag, "p")
    T.eq(out.children[1].children[1].value, "plain")
  end)

  T.it("splices multiple top-level nodes from a single raw node", function()
    local tree = root({ html("<p>A</p><p>B</p>") })
    local out = run(tree)
    T.eq(#out.children, 2)
    T.eq(out.children[1].tag, "p")
    T.eq(out.children[2].tag, "p")
  end)

  T.it("processes raw nodes nested inside elements", function()
    local tree = root({
      el("section", {}, {
        html('<p class="inner">Nested</p>')
      })
    })
    local out = run(tree)
    local section = out.children[1]
    local p = section.children[1]
    T.eq(p.type, "element")
    T.eq(p.tag, "p")
    T.eq(p.props.class, "inner")
  end)

  T.it("drops empty raw nodes", function()
    local tree = root({ html("") })
    local out = run(tree)
    T.eq(#out.children, 0)
  end)

  T.it("preserves HTML comments as raw nodes", function()
    local tree = root({ html("<!-- a comment -->") })
    local out = run(tree)
    T.eq(out.children[1].type, "raw")
    T.ok(out.children[1].value:find("comment"), "comment text preserved")
  end)

  T.it("mixes raw and existing nodes correctly", function()
    local tree = root({
      el("h1", {}, { text("Title") }),
      html('<div class="note">Note</div>'),
      el("p", {}, { text("After") }),
    })
    local out = run(tree)
    T.eq(#out.children, 3)
    T.eq(out.children[1].tag, "h1")
    T.eq(out.children[2].tag, "div")
    T.eq(out.children[3].tag, "p")
  end)

end)
