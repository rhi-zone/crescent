-- lib/rehype_slug/rehype_slug_test.lua
-- Tests for lib/rehype_slug.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T          = require("lib.test.assert")
local unified    = require("lib.unified")
local rehypeSlug = require("lib.unified.rehype_slug")

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

-- Build a minimal processor with just the slug transformer.
local function make_processor()
  local p = unified.new()
  p:use(rehypeSlug)
  return p
end

-- Run the slug transformer on a hast tree (no parse/stringify needed).
local function run(tree)
  local result, err = make_processor():run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_slug", function()

  T.it("adds id to h1", function()
    local tree = root({ el("h1", {}, { text("Hello World") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "hello-world")
  end)

  T.it("adds id to h2", function()
    local tree = root({ el("h2", {}, { text("My Section") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "my-section")
  end)

  T.it("adds id to h3 through h6", function()
    for depth = 3, 6 do
      local tag  = "h" .. depth
      local tree = root({ el(tag, {}, { text("Heading " .. depth) }) })
      local out  = run(tree)
      T.ok(out.children[1].props.id ~= nil, tag .. " should have id")
    end
  end)

  T.it("does not add id to non-heading elements", function()
    local tree = root({ el("p", {}, { text("Plain paragraph") }) })
    local out  = run(tree)
    local id   = out.children[1].props and out.children[1].props.id
    T.eq(id, nil)
  end)

  T.it("lowercases the slug", function()
    local tree = root({ el("h1", {}, { text("UPPERCASE") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "uppercase")
  end)

  T.it("replaces spaces with hyphens", function()
    local tree = root({ el("h1", {}, { text("hello world") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "hello-world")
  end)

  T.it("replaces non-alphanumeric chars with hyphens", function()
    local tree = root({ el("h1", {}, { text("foo & bar: baz!") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "foo-bar-baz")
  end)

  T.it("strips leading and trailing hyphens", function()
    local tree = root({ el("h1", {}, { text("...hello...") }) })
    local out  = run(tree)
    T.eq(out.children[1].props.id, "hello")
  end)

  T.it("concatenates text from nested children", function()
    local tree = root({
      el("h1", {}, {
        text("Hello "),
        el("strong", {}, { text("World") }),
      }),
    })
    local out = run(tree)
    T.eq(out.children[1].props.id, "hello-world")
  end)

  T.it("suffixes duplicate ids with -1, -2, etc.", function()
    local tree = root({
      el("h1", {}, { text("Intro") }),
      el("h2", {}, { text("Intro") }),
      el("h3", {}, { text("Intro") }),
    })
    local out = run(tree)
    T.eq(out.children[1].props.id, "intro")
    T.eq(out.children[2].props.id, "intro-1")
    T.eq(out.children[3].props.id, "intro-2")
  end)

  T.it("resets duplicate tracking between process() calls", function()
    local p = make_processor()
    -- First run.
    local tree1 = root({
      el("h1", {}, { text("Foo") }),
      el("h2", {}, { text("Foo") }),
    })
    local out1 = p:run(tree1)
    T.eq(out1.children[1].props.id, "foo")
    T.eq(out1.children[2].props.id, "foo-1")

    -- Second run (fresh tree, duplicate counter must reset).
    local tree2 = root({
      el("h1", {}, { text("Foo") }),
    })
    local out2 = p:run(tree2)
    T.eq(out2.children[1].props.id, "foo")
  end)

  T.it("skips headings with empty text content", function()
    local tree = root({ el("h1", {}, {}) })
    local out  = run(tree)
    local id   = out.children[1].props and out.children[1].props.id
    T.eq(id, nil)
  end)

end)
