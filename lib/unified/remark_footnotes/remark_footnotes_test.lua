-- lib/unified/remark_footnotes/remark_footnotes_test.lua
-- Tests for the remark_footnotes plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local remark    = require("lib.unified.remark")
local footnotes = require("lib.unified.remark_footnotes")

-- Parse helper: parse then run transformers.
local function parse(processor, src)
  local ast = processor:parse(src)
  return processor:run(ast)
end

-- ── Footnote references ───────────────────────────────────────────────────────

T.describe("remark_footnotes: references", function()
  local processor = remark():use(footnotes)

  T.it("[^label] inside a paragraph becomes a footnoteReference node", function()
    local ast = parse(processor, "Hello[^1] world.")
    local p = ast.children[1]
    T.eq(p.type, "paragraph")
    -- children: text "Hello", footnoteReference, text " world."
    T.eq(#p.children, 3)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].value, "Hello")
    T.eq(p.children[2].type, "footnoteReference")
    T.eq(p.children[2].identifier, "1")
    T.eq(p.children[2].label, "1")
    T.eq(p.children[3].type, "text")
    T.eq(p.children[3].value, " world.")
  end)

  T.it("footnoteReference at start of paragraph", function()
    local ast = parse(processor, "[^note] is first.")
    local p = ast.children[1]
    T.eq(p.children[1].type, "footnoteReference")
    T.eq(p.children[1].identifier, "note")
  end)

  T.it("footnoteReference at end of paragraph", function()
    local ast = parse(processor, "See note[^ref]")
    local p = ast.children[1]
    local last = p.children[#p.children]
    T.eq(last.type, "footnoteReference")
    T.eq(last.identifier, "ref")
  end)

  T.it("multiple footnote references in one paragraph", function()
    local ast = parse(processor, "First[^a] and second[^b].")
    local p = ast.children[1]
    local refs = {}
    for i = 1, #p.children do
      if p.children[i].type == "footnoteReference" then
        refs[#refs + 1] = p.children[i]
      end
    end
    T.eq(#refs, 2)
    T.eq(refs[1].identifier, "a")
    T.eq(refs[2].identifier, "b")
  end)

  T.it("text with no footnote references is unchanged", function()
    local ast = parse(processor, "No footnotes here.")
    local p = ast.children[1]
    T.eq(#p.children, 1)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].value, "No footnotes here.")
  end)

  T.it("alphanumeric label", function()
    local ast = parse(processor, "Reference[^myNote].")
    local p = ast.children[1]
    -- Find the ref node.
    local ref
    for i = 1, #p.children do
      if p.children[i].type == "footnoteReference" then ref = p.children[i] end
    end
    T.ok(ref ~= nil, "footnoteReference found")
    T.eq(ref.identifier, "myNote")
  end)
end)

-- ── Footnote definitions ──────────────────────────────────────────────────────

T.describe("remark_footnotes: definitions", function()
  local processor = remark():use(footnotes)

  T.it("[^label]: text produces a footnoteDefinition node", function()
    local ast = parse(processor, "[^1]: This is the footnote.")
    -- The definition is appended after parsed children.
    local def
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then def = ast.children[i] end
    end
    T.ok(def ~= nil, "footnoteDefinition found")
    T.eq(def.identifier, "1")
    T.eq(def.label, "1")
  end)

  T.it("footnoteDefinition has a paragraph child with the content", function()
    local ast = parse(processor, "[^note]: Footnote content here.")
    local def
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then def = ast.children[i] end
    end
    T.ok(def ~= nil, "footnoteDefinition found")
    T.eq(#def.children, 1)
    local inner = def.children[1]
    T.eq(inner.type, "paragraph")
    T.eq(inner.children[1].type, "text")
    T.eq(inner.children[1].value, "Footnote content here.")
  end)

  T.it("definition with hyphenated label", function()
    local ast = parse(processor, "[^my-note]: Content.")
    local def
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then def = ast.children[i] end
    end
    T.ok(def ~= nil, "footnoteDefinition found")
    T.eq(def.identifier, "my-note")
  end)

  T.it("reference and definition coexist in same document", function()
    local ast = parse(processor, "See note[^1].\n\n[^1]: The note text.")
    -- First non-definition child is the paragraph with reference.
    local p = ast.children[1]
    T.eq(p.type, "paragraph")
    local ref
    for i = 1, #p.children do
      if p.children[i].type == "footnoteReference" then ref = p.children[i] end
    end
    T.ok(ref ~= nil, "reference found")
    T.eq(ref.identifier, "1")

    -- Definition is in the children.
    local def
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then def = ast.children[i] end
    end
    T.ok(def ~= nil, "definition found")
    T.eq(def.identifier, "1")
  end)

  T.it("multiple definitions", function()
    local ast = parse(processor, "[^a]: First.\n\n[^b]: Second.")
    local defs = {}
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then
        defs[#defs + 1] = ast.children[i]
      end
    end
    T.eq(#defs, 2)
    T.eq(defs[1].identifier, "a")
    T.eq(defs[2].identifier, "b")
  end)

  T.it("paragraph not starting with [^ is not a definition", function()
    local ast = parse(processor, "Just a paragraph.")
    T.eq(ast.children[1].type, "paragraph")
  end)
end)

-- ── Integration ───────────────────────────────────────────────────────────────

T.describe("remark_footnotes: integration", function()
  local processor = remark():use(footnotes)

  T.it("full document with references and definitions", function()
    local src = "Text with footnote[^1] and another[^two].\n\n[^1]: First note.\n\n[^two]: Second note."
    local ast = parse(processor, src)

    -- Paragraph with references.
    T.eq(ast.children[1].type, "paragraph")

    -- Find definitions.
    local defs = {}
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then
        defs[#defs + 1] = ast.children[i]
      end
    end
    T.eq(#defs, 2)
    T.eq(defs[1].identifier, "1")
    T.eq(defs[2].identifier, "two")
  end)
end)

-- ── Module callable ───────────────────────────────────────────────────────────

T.describe("remark_footnotes: module callable", function()
  T.it("module is callable as a plugin directly", function()
    local p = remark():use(footnotes)
    local ast = parse(p, "See[^1].")
    local ref
    local children = ast.children[1].children
    for i = 1, #children do
      if children[i].type == "footnoteReference" then ref = children[i] end
    end
    T.ok(ref ~= nil, "ref found")
    T.eq(ref.identifier, "1")
  end)

  T.it("M.plugin alias works", function()
    local p = remark():use(footnotes.plugin)
    local ast = parse(p, "[^x]: Content.")
    local def
    for i = 1, #ast.children do
      if ast.children[i].type == "footnoteDefinition" then def = ast.children[i] end
    end
    T.ok(def ~= nil, "def found")
    T.eq(def.identifier, "x")
  end)
end)
