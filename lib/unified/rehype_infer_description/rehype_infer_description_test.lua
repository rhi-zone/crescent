-- lib/rehype_infer_description/rehype_infer_description_test.lua
-- Tests for lib/unified/rehype_infer_description.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T       = require("lib.test.assert")
local unified = require("lib.unified")
local inferDesc = require("lib.unified.rehype_infer_description")

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
  p:use(inferDesc, opts)
  local result, err = p:run(tree)
  if not result then error(err) end
  return result
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("rehype_infer_description", function()

  T.it("uses first <p> after first heading", function()
    local tree = root({
      el("h1", {}, { text("Title") }),
      el("p", {}, { text("First paragraph.") }),
      el("p", {}, { text("Second paragraph.") }),
    })
    local out = run(tree)
    T.eq(out.data.description, "First paragraph.")
  end)

  T.it("uses first <p> when no heading exists", function()
    local tree = root({
      el("p", {}, { text("No heading here.") })
    })
    local out = run(tree)
    T.eq(out.data.description, "No heading here.")
  end)

  T.it("skips <p> before first heading", function()
    local tree = root({
      el("p", {}, { text("Pre-heading paragraph.") }),
      el("h1", {}, { text("Title") }),
      el("p", {}, { text("Post-heading paragraph.") }),
    })
    local out = run(tree)
    T.eq(out.data.description, "Post-heading paragraph.")
  end)

  T.it("does not set description when no <p> exists", function()
    local tree = root({
      el("h1", {}, { text("Only a heading") })
    })
    local out = run(tree)
    T.eq(out.data, nil)
  end)

  T.it("concatenates text from nested children in <p>", function()
    local tree = root({
      el("h1", {}, { text("Title") }),
      el("p", {}, {
        text("Hello "),
        el("strong", {}, { text("world") }),
        text("."),
      }),
    })
    local out = run(tree)
    T.eq(out.data.description, "Hello world.")
  end)

  T.it("truncates at max_words", function()
    local words = {}
    for i = 1, 60 do words[i] = "word" .. i end
    local long_text = table.concat(words, " ")
    local tree = root({
      el("h1", {}, { text("Title") }),
      el("p", {}, { text(long_text) }),
    })
    local out = run(tree, { max_words = 5, truncate_size = 10000 })
    -- Should have truncated and ends with ellipsis.
    T.ok(out.data.description ~= nil, "description set")
    T.ok(out.data.description:find("\xe2\x80\xa6"), "ends with ellipsis")
    -- Should contain word1 through word5 but not word6.
    T.ok(out.data.description:find("word5"), "word5 present")
    T.ok(not out.data.description:find("word6"), "word6 absent")
  end)

  T.it("truncates at truncate_size characters", function()
    local tree = root({
      el("h1", {}, { text("Title") }),
      el("p", {}, { text(("x"):rep(400)) }),
    })
    local out = run(tree, { max_words = 1000, truncate_size = 10 })
    T.ok(out.data.description ~= nil, "description set")
    T.ok(#out.data.description <= 10 + 3, "truncated to ~10 chars + ellipsis")
  end)

  T.it("preserves existing root.data fields", function()
    local tree = root({
      el("h1", {}, { text("Title") }),
      el("p", {}, { text("Desc.") }),
    })
    tree.data = { title = "Title" }
    local out = run(tree)
    T.eq(out.data.title, "Title")
    T.eq(out.data.description, "Desc.")
  end)

  T.it("normalizes whitespace in description", function()
    local tree = root({
      el("p", {}, { text("  hello   world  ") })
    })
    local out = run(tree)
    T.eq(out.data.description, "hello world")
  end)

  T.it("short text is not truncated", function()
    local tree = root({
      el("p", {}, { text("Short text.") })
    })
    local out = run(tree)
    T.eq(out.data.description, "Short text.")
  end)

end)
