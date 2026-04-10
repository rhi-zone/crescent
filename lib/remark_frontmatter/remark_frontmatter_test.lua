-- lib/remark_frontmatter/remark_frontmatter_test.lua
-- Tests for the remark_frontmatter plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local remark      = require("lib.remark")
local frontmatter = require("lib.remark_frontmatter")

-- ── YAML frontmatter (default) ────────────────────────────────────────────────

T.describe("remark_frontmatter: YAML", function()
  local processor = remark():use(frontmatter)

  T.it("strips YAML frontmatter and exposes it as a yaml node", function()
    local ast = processor:parse("---\ntitle: Hello\nauthor: World\n---\n\n# Hello")
    T.eq(ast.type, "root")
    local fm = ast.children[1]
    T.eq(fm.type, "yaml")
    T.eq(fm.value, "title: Hello\nauthor: World")
  end)

  T.it("rest of document parsed normally (heading follows frontmatter)", function()
    local ast = processor:parse("---\ntitle: Hello\n---\n\n# Hello")
    local h = ast.children[2]
    T.eq(h.type, "heading")
    T.eq(h.depth, 1)
    T.eq(h.children[1].value, "Hello")
  end)

  T.it("rest of document parsed normally (paragraph follows frontmatter)", function()
    local ast = processor:parse("---\nkey: value\n---\n\nJust a paragraph.")
    local p = ast.children[2]
    T.eq(p.type, "paragraph")
    T.eq(p.children[1].value, "Just a paragraph.")
  end)

  T.it("frontmatter-only document: root has just the yaml node", function()
    local ast = processor:parse("---\nonly: this\n---\n")
    T.eq(#ast.children, 1)
    local fm = ast.children[1]
    T.eq(fm.type, "yaml")
    T.eq(fm.value, "only: this")
  end)

  T.it("empty frontmatter produces yaml node with empty value", function()
    local ast = processor:parse("---\n---\n\n# After")
    local fm = ast.children[1]
    T.eq(fm.type, "yaml")
    T.eq(fm.value, "")
  end)

  T.it("no frontmatter: document unchanged (first child is not yaml)", function()
    local ast = processor:parse("# Title\n\nParagraph.")
    T.eq(ast.children[1].type, "heading")
  end)

  T.it("frontmatter not at start of file: treated as normal content", function()
    local ast = processor:parse("\n---\ntitle: Late\n---\n\n# Hello")
    -- First child must NOT be a yaml node.
    local first = ast.children[1]
    T.ok(first.type ~= "yaml", "leading blank line prevents extraction")
  end)

  T.it("opening fence with trailing content is not recognised", function()
    local ast = processor:parse("--- extra\ntitle: Hi\n---\n\n# Hello")
    local first = ast.children[1]
    T.ok(first.type ~= "yaml", "fence with trailing content is not a frontmatter fence")
  end)

  T.it("handles CRLF line endings in frontmatter", function()
    local ast = processor:parse("---\r\ntitle: Hello\r\n---\r\n\r\n# Hello")
    local fm = ast.children[1]
    T.eq(fm.type, "yaml")
    T.eq(fm.value, "title: Hello")
  end)
end)

-- ── TOML frontmatter ──────────────────────────────────────────────────────────

T.describe("remark_frontmatter: TOML", function()
  local processor = remark():use(frontmatter, { types = { "toml" } })

  T.it("strips TOML frontmatter and exposes it as a toml node", function()
    local ast = processor:parse("+++\ntitle = \"Hello\"\n+++\n\n# Hello")
    local fm = ast.children[1]
    T.eq(fm.type, "toml")
    T.eq(fm.value, "title = \"Hello\"")
  end)

  T.it("rest of document parsed normally after TOML frontmatter", function()
    local ast = processor:parse("+++\nkey = \"v\"\n+++\n\n# Title")
    local h = ast.children[2]
    T.eq(h.type, "heading")
    T.eq(h.depth, 1)
  end)

  T.it("YAML fence ignored when only toml type active", function()
    local ast = processor:parse("---\ntitle: Hello\n---\n\n# Hello")
    -- No extraction; first child is not a toml node (it's a thematic break or
    -- heading depending on mdast parse of the dashes, but definitely not toml).
    local first = ast.children[1]
    T.ok(first.type ~= "toml", "yaml fence not recognised when only toml active")
  end)
end)

-- ── Both types active ─────────────────────────────────────────────────────────

T.describe("remark_frontmatter: yaml + toml", function()
  local processor = remark():use(frontmatter, { types = { "yaml", "toml" } })

  T.it("extracts YAML when both types enabled", function()
    local ast = processor:parse("---\ntitle: Hello\n---\n\n# Hi")
    T.eq(ast.children[1].type, "yaml")
  end)

  T.it("extracts TOML when both types enabled", function()
    local ast = processor:parse("+++\ntitle = \"Hi\"\n+++\n\n# Hi")
    T.eq(ast.children[1].type, "toml")
  end)
end)

-- ── Plugin callable as module ─────────────────────────────────────────────────

T.describe("remark_frontmatter: module callable", function()
  T.it("module is callable as a plugin directly", function()
    local p = remark():use(frontmatter)
    local ast = p:parse("---\nfoo: bar\n---\n")
    T.eq(ast.children[1].type, "yaml")
  end)

  T.it("M.plugin alias works", function()
    local p = remark():use(frontmatter.plugin)
    local ast = p:parse("---\nfoo: bar\n---\n")
    T.eq(ast.children[1].type, "yaml")
  end)
end)
