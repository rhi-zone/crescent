-- lib/unified/remark_directive/remark_directive_test.lua
-- Tests for the remark_directive plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local remark    = require("lib.unified.remark")
local directive = require("lib.unified.remark_directive")

-- Parse helper: parse then run transformers.
local function parse(processor, src)
  local ast = processor:parse(src)
  return processor:run(ast)
end

-- ── Text directives ───────────────────────────────────────────────────────────

T.describe("remark_directive: text directive", function()
  local processor = remark():use(directive)

  T.it("bare :name produces a textDirective with no children", function()
    local ast = parse(processor, ":tip")
    local p = ast.children[1]
    T.eq(p.type, "paragraph")
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.name, "tip")
    T.eq(#node.children, 0)
  end)

  T.it(":name[label] produces textDirective with label as text child", function()
    local ast = parse(processor, ":abbr[HTML]")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.name, "abbr")
    T.eq(#node.children, 1)
    T.eq(node.children[1].value, "HTML")
  end)

  T.it(":name{key=val} parses attributes", function()
    local ast = parse(processor, ":icon{name=star}")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.name, "icon")
    T.eq(node.attributes["name"], "star")
  end)

  T.it(":name[label]{key=val} parses both", function()
    local ast = parse(processor, ":link[click here]{href=https://example.com}")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.name, "link")
    T.eq(node.children[1].value, "click here")
    T.eq(node.attributes["href"], "https://example.com")
  end)

  T.it("text directive embedded in surrounding text", function()
    local ast = parse(processor, "Hello :world and more.")
    local p = ast.children[1]
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].value, "Hello ")
    T.eq(p.children[2].type, "textDirective")
    T.eq(p.children[2].name, "world")
  end)

  T.it("multiple text directives in one paragraph", function()
    local ast = parse(processor, ":a and :b")
    local p = ast.children[1]
    local directives = {}
    for i = 1, #p.children do
      if p.children[i].type == "textDirective" then
        directives[#directives + 1] = p.children[i]
      end
    end
    T.eq(#directives, 2)
    T.eq(directives[1].name, "a")
    T.eq(directives[2].name, "b")
  end)

  T.it("quoted attribute value", function()
    local ast = parse(processor, ':span{class="my class"}')
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.attributes["class"], "my class")
  end)
end)

-- ── Leaf directives ───────────────────────────────────────────────────────────

T.describe("remark_directive: leaf directive", function()
  local processor = remark():use(directive)

  T.it("::name paragraph becomes a leafDirective", function()
    local ast = parse(processor, "::youtube")
    T.eq(#ast.children, 1)
    local node = ast.children[1]
    T.eq(node.type, "leafDirective")
    T.eq(node.name, "youtube")
    T.eq(#node.children, 0)
  end)

  T.it("::name[label] leaf directive with label", function()
    local ast = parse(processor, "::video[My Video]")
    local node = ast.children[1]
    T.eq(node.type, "leafDirective")
    T.eq(node.name, "video")
    T.eq(node.children[1].value, "My Video")
  end)

  T.it("::name{key=val} leaf directive with attributes", function()
    local ast = parse(processor, "::youtube{id=abc123}")
    local node = ast.children[1]
    T.eq(node.type, "leafDirective")
    T.eq(node.name, "youtube")
    T.eq(node.attributes["id"], "abc123")
  end)

  T.it("leaf directive surrounded by other blocks", function()
    local ast = parse(processor, "Before.\n\n::hr\n\nAfter.")
    T.eq(#ast.children, 3)
    T.eq(ast.children[1].type, "paragraph")
    T.eq(ast.children[2].type, "leafDirective")
    T.eq(ast.children[2].name, "hr")
    T.eq(ast.children[3].type, "paragraph")
  end)
end)

-- ── Container directives ──────────────────────────────────────────────────────
-- Containers require blank lines between the fence and content so that mdast
-- produces separate paragraph nodes (loose form).
-- Tight form (no blank lines) collapses everything into one paragraph with
-- softBreaks — both forms are tested.

T.describe("remark_directive: container directive (loose)", function()
  local processor = remark():use(directive)

  T.it(":::name\\n\\nContent.\\n\\n::: wraps children in containerDirective", function()
    local ast = parse(processor, ":::note\n\nContent here.\n\n:::")
    T.eq(#ast.children, 1)
    local node = ast.children[1]
    T.eq(node.type, "containerDirective")
    T.eq(node.name, "note")
  end)

  T.it("container directive with label (loose)", function()
    local ast = parse(processor, ":::tip[Important]\n\nContent.\n\n:::")
    local node = ast.children[1]
    T.eq(node.type, "containerDirective")
    T.eq(node.name, "tip")
  end)

  T.it("container directive with attributes (loose)", function()
    local ast = parse(processor, ":::aside{class=warning}\n\nContent.\n\n:::")
    local node = ast.children[1]
    T.eq(node.type, "containerDirective")
    T.eq(node.name, "aside")
    T.eq(node.attributes["class"], "warning")
  end)

  T.it("container directive surrounded by other blocks", function()
    local ast = parse(processor, "Before.\n\n:::box\n\nInside.\n\n:::\n\nAfter.")
    T.eq(#ast.children, 3)
    T.eq(ast.children[1].type, "paragraph")
    T.eq(ast.children[2].type, "containerDirective")
    T.eq(ast.children[3].type, "paragraph")
  end)
end)

T.describe("remark_directive: container directive (tight)", function()
  local processor = remark():use(directive)

  T.it(":::name\\nContent.\\n::: (tight) becomes containerDirective", function()
    -- No blank lines: mdast collapses to one paragraph with softBreaks.
    local ast = parse(processor, ":::note\nContent here.\n:::")
    T.eq(#ast.children, 1)
    local node = ast.children[1]
    T.eq(node.type, "containerDirective")
    T.eq(node.name, "note")
  end)
end)

-- ── Attribute parsing edge cases ──────────────────────────────────────────────

T.describe("remark_directive: attribute parsing", function()
  local processor = remark():use(directive)

  T.it("boolean attribute (no value)", function()
    local ast = parse(processor, ":icon{spin}")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.attributes["spin"], true)
  end)

  T.it("multiple attributes", function()
    local ast = parse(processor, ":img{src=foo.png alt=image}")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.attributes["src"], "foo.png")
    T.eq(node.attributes["alt"], "image")
  end)

  T.it("empty attributes {}", function()
    local ast = parse(processor, ":name{}")
    local p = ast.children[1]
    local node = p.children[1]
    T.eq(node.type, "textDirective")
    T.eq(node.name, "name")
  end)
end)

-- ── Module callable ───────────────────────────────────────────────────────────

T.describe("remark_directive: module callable", function()
  T.it("module is callable as a plugin directly", function()
    local p = remark():use(directive)
    local ast = parse(p, ":foo")
    T.eq(ast.children[1].children[1].type, "textDirective")
  end)

  T.it("M.plugin alias works", function()
    local p = remark():use(directive.plugin)
    local ast = parse(p, "::bar")
    T.eq(ast.children[1].type, "leafDirective")
  end)
end)
