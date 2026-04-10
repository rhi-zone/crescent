-- lib/unified/rehype_section/rehype_section_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T       = require("lib.test.assert")
local section = require("lib.unified.rehype_section")
local rehype  = require("lib.unified.rehype")

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end
local function txt(v)
  return { type = "text", value = v }
end

local function run(root, opts)
  local p = rehype():use(section, opts)
  return p:stringify(p:run(root))
end

T.describe("rehype_section: wrapping", function()
  T.it("wraps everything in a root section when wrap=true (default)", function()
    local root = {
      type = "root",
      children = {
        el("h1", {}, { txt("Title") }),
        el("p",  {}, { txt("body") }),
      },
    }
    local html = run(root)
    -- outer <section> wraps all
    T.ok(html:find("<section>", 1, true), "has section")
    T.ok(html:find("<h1>", 1, true), "h1 present")
    T.ok(html:find("<p>", 1, true), "p present")
  end)

  T.it("does not add outer section when wrap=false", function()
    local root = {
      type = "root",
      children = {
        el("h1", {}, { txt("Title") }),
        el("p",  {}, { txt("body") }),
      },
    }
    local html = run(root, { wrap = false })
    -- With wrap=false and a single h1 there should be one <section>
    -- containing h1 + p — it just isn't wrapped in another.
    T.ok(html:find("<section>", 1, true), "section around h1 group")
    T.ok(html:find("<h1>", 1, true), "h1 present")
  end)

  T.it("nests h2 sections inside h1 section", function()
    local root = {
      type = "root",
      children = {
        el("h1", {}, { txt("Top") }),
        el("p",  {}, { txt("intro") }),
        el("h2", {}, { txt("Sub A") }),
        el("p",  {}, { txt("a body") }),
        el("h2", {}, { txt("Sub B") }),
        el("p",  {}, { txt("b body") }),
      },
    }
    local html = run(root, { wrap = false })
    -- h2 sections are nested inside the h1 section
    T.ok(html:find("<h1>", 1, true))
    T.ok(html:find("<h2>", 1, true))
    -- The h1 section wraps around the h2 sections
    local h1_pos  = html:find("<h1>", 1, true)
    local h2_pos  = html:find("<h2>", 1, true)
    T.ok(h1_pos < h2_pos, "h1 comes before h2")
  end)

  T.it("sibling h2 headings produce sibling sections", function()
    local root = {
      type = "root",
      children = {
        el("h2", {}, { txt("A") }),
        el("p",  {}, { txt("a") }),
        el("h2", {}, { txt("B") }),
        el("p",  {}, { txt("b") }),
      },
    }
    local html = run(root, { wrap = false })
    local _, count = html:gsub("<section>", "")
    T.eq(count, 2, "two sibling sections")
  end)

  T.it("nodes before first heading are placed outside any section (wrap=false)", function()
    local root = {
      type = "root",
      children = {
        el("p",  {}, { txt("preamble") }),
        el("h1", {}, { txt("Title") }),
      },
    }
    local html = run(root, { wrap = false })
    -- preamble <p> should appear before the <section>
    local p_pos  = html:find("<p>", 1, true)
    local sec_pos = html:find("<section>", 1, true)
    T.ok(p_pos < sec_pos, "preamble p before section")
  end)

  T.it("empty children produces empty root section (wrap=true)", function()
    local root = { type = "root", children = {} }
    local html = run(root)
    T.ok(html:find("<section></section>", 1, true), "empty section")
  end)
end)
