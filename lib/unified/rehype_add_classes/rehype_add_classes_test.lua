-- lib/unified/rehype_add_classes/rehype_add_classes_test.lua
-- Tests for rehype_add_classes plugin.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T               = require("lib.test.assert")
local unified         = require("lib.unified")
local rehypeAddClasses = require("lib.unified.rehype_add_classes")

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
  p:use(rehypeAddClasses, opts)
  return p
end

local function run(tree, opts)
  local result, err = make_processor(opts):run(tree)
  if not result then error(err) end
  return result
end

-- Split a class string into a sorted list for order-independent comparison.
local function classes(node)
  local cls = (node.props or {})["class"] or ""
  local parts = {}
  for c in cls:gmatch("%S+") do
    parts[#parts + 1] = c
  end
  table.sort(parts)
  return parts
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_add_classes", function()

  T.it("adds a class to a matching element", function()
    local tree = root({ el("p", {}, { text("hello") }) })
    local out  = run(tree, { p = "prose" })
    T.eq((out.children[1].props or {})["class"], "prose")
  end)

  T.it("does not add class to non-matching element", function()
    local tree = root({ el("div", {}, { text("hello") }) })
    local out  = run(tree, { p = "prose" })
    local cls  = (out.children[1].props or {})["class"]
    T.eq(cls, nil)
  end)

  T.it("preserves existing class and appends new one", function()
    local tree = root({ el("p", { ["class"] = "existing" }, { text("hello") }) })
    local out  = run(tree, { p = "prose" })
    local cls  = (out.children[1].props or {})["class"]
    T.ok(cls:find("existing") ~= nil, "should keep existing class")
    T.ok(cls:find("prose") ~= nil, "should add prose class")
  end)

  T.it("does not duplicate classes already on the element", function()
    local tree = root({ el("p", { ["class"] = "prose" }, { text("hello") }) })
    local out  = run(tree, { p = "prose" })
    local cls  = (out.children[1].props or {})["class"]
    -- "prose" should appear only once.
    local count = 0
    for _ in cls:gmatch("prose") do count = count + 1 end
    T.eq(count, 1)
  end)

  T.it("comma-separated selector matches multiple tag types", function()
    local tree = root({
      el("h1", {}, { text("a") }),
      el("h2", {}, { text("b") }),
      el("h3", {}, { text("c") }),
      el("p",  {}, { text("d") }),
    })
    local out = run(tree, { ["h1,h2,h3"] = "heading" })
    T.ok((out.children[1].props or {})["class"]:find("heading") ~= nil, "h1 matches")
    T.ok((out.children[2].props or {})["class"]:find("heading") ~= nil, "h2 matches")
    T.ok((out.children[3].props or {})["class"]:find("heading") ~= nil, "h3 matches")
    T.eq((out.children[4].props or {})["class"], nil)
  end)

  T.it("multiple selector rules can apply to the same element", function()
    local tree = root({ el("h1", {}, { text("top") }) })
    local out  = run(tree, {
      h1          = "title",
      ["h1,h2,h3"] = "heading",
    })
    local sorted = classes(out.children[1])
    -- Both "title" and "heading" should be present.
    local has_title   = false
    local has_heading = false
    for _, c in ipairs(sorted) do
      if c == "title"   then has_title   = true end
      if c == "heading" then has_heading = true end
    end
    T.ok(has_title,   "should have title class")
    T.ok(has_heading, "should have heading class")
  end)

  T.it("adds multiple space-separated classes from a single rule", function()
    local tree = root({ el("h1", {}, { text("top") }) })
    local out  = run(tree, { h1 = "title large bold" })
    local sorted = classes(out.children[1])
    T.eq(#sorted, 3)
  end)

  T.it("works on elements nested inside other elements", function()
    local tree = root({
      el("div", {}, {
        el("p", {}, { text("nested") }),
      }),
    })
    local out = run(tree, { p = "prose" })
    local p   = out.children[1].children[1]
    T.eq((p.props or {})["class"], "prose")
  end)

  T.it("trims whitespace around tag names in comma-separated selectors", function()
    local tree = root({
      el("h1", {}, { text("a") }),
      el("h2", {}, { text("b") }),
    })
    -- Spaces around comma and tag names.
    local out = run(tree, { [" h1 , h2 "] = "heading" })
    T.ok((out.children[1].props or {})["class"]:find("heading") ~= nil, "h1 matches")
    T.ok((out.children[2].props or {})["class"]:find("heading") ~= nil, "h2 matches")
  end)

end)
