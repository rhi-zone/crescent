-- lib/unified/remark_abbr/remark_abbr_test.lua
-- Tests for the remark_abbr plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remark = require("lib.unified.remark")
local abbr   = require("lib.unified.remark_abbr")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_proc(opts)
  return remark():use(abbr, opts)
end

local function parse_and_run(src, opts)
  local proc = make_proc(opts)
  local ast, err = proc:parse(src)
  assert(ast, err)
  return proc:run(ast)
end

-- Depth-first collect all nodes of a given type.
local function collect_type(node, typ, out)
  out = out or {}
  if node.type == typ then out[#out + 1] = node end
  if node.children then
    for _, c in ipairs(node.children) do collect_type(c, typ, out) end
  end
  return out
end

-- ── Definition extraction ─────────────────────────────────────────────────────

T.describe("remark_abbr: definition extraction", function()
  T.it("definition paragraph is removed from the tree", function()
    local src = "*[HTML]: Hypertext Markup Language\n\nSome text."
    local ast = parse_and_run(src)
    -- Only one paragraph should remain (the "Some text." one).
    T.eq(#ast.children, 1)
    T.eq(ast.children[1].type, "paragraph")
  end)

  T.it("multiple definitions in one paragraph are all extracted", function()
    local src = "*[HTML]: Hypertext Markup Language\n*[CSS]: Cascading Style Sheets\n\nHTML and CSS."
    local ast = parse_and_run(src)
    -- Definition block gone; one content paragraph remains.
    T.eq(#ast.children, 1)
    local abbrs = collect_type(ast, "abbr")
    T.eq(#abbrs, 2)
  end)

  T.it("non-definition paragraph is preserved", function()
    local src = "Normal paragraph.\n\n*[HTML]: Hypertext Markup Language\n\nAnother."
    local ast = parse_and_run(src)
    -- Two content paragraphs; definition removed.
    T.eq(#ast.children, 2)
  end)
end)

-- ── Abbreviation wrapping ─────────────────────────────────────────────────────

T.describe("remark_abbr: abbreviation wrapping in text", function()
  T.it("occurrence of defined abbreviation is wrapped in abbr node", function()
    local src = "*[HTML]: Hypertext Markup Language\n\nHTML is great."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    T.eq(#abbrs, 1)
    T.eq(abbrs[1].title, "Hypertext Markup Language")
    T.eq(abbrs[1].children[1].value, "HTML")
  end)

  T.it("multiple occurrences all wrapped", function()
    local src = "*[HTML]: Hypertext Markup Language\n\nHTML and more HTML."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    T.eq(#abbrs, 2)
  end)

  T.it("text around abbreviation preserved as text nodes", function()
    local src = "*[CSS]: Cascading Style Sheets\n\nI love CSS a lot."
    local ast = parse_and_run(src)
    local para = ast.children[1]
    -- Should have: text "I love ", abbr "CSS", text " a lot."
    local texts = {}
    for _, c in ipairs(para.children or {}) do
      if c.type == "text" then texts[#texts + 1] = c.value end
    end
    T.ok(#texts >= 2, "surrounding text nodes present")
  end)

  T.it("whole-word match: 'HTML' matches but 'xHTML' does not", function()
    local src = "*[HTML]: Hypertext Markup Language\n\nxHTML is not HTML."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    -- Only the standalone "HTML" at the end should match.
    T.eq(#abbrs, 1)
    -- Verify it's the right one by checking surrounding context.
    T.eq(abbrs[1].children[1].value, "HTML")
  end)

  T.it("abbreviations are case-sensitive", function()
    local src = "*[HTML]: Hypertext Markup Language\n\nhtml is not HTML."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    -- Only uppercase "HTML" should match.
    T.eq(#abbrs, 1)
  end)

  T.it("no match when abbreviation not present in text", function()
    local src = "*[CSS]: Cascading Style Sheets\n\nJavaScript is cool."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    T.eq(#abbrs, 0)
  end)

  T.it("multiple distinct abbreviations both wrapped", function()
    local src = "*[HTML]: Hypertext Markup Language\n*[CSS]: Cascading Style Sheets\n\nHTML and CSS are awesome."
    local ast = parse_and_run(src)
    local abbrs = collect_type(ast, "abbr")
    T.eq(#abbrs, 2)
    -- Collect titles to verify both definitions applied.
    local titles = {}
    for _, a in ipairs(abbrs) do titles[a.title] = true end
    T.ok(titles["Hypertext Markup Language"], "HTML definition applied")
    T.ok(titles["Cascading Style Sheets"], "CSS definition applied")
  end)
end)
