-- lib/unified/rehype_meta/rehype_meta_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local rehype_meta = require("lib.unified.rehype_meta")
local rehype      = require("lib.unified.rehype")
local hast        = require("lib.unified.hast")

-- Helper: build a simple hast root with a bare <head>.
local function bare_head_tree()
  return {
    type = "root",
    children = {
      { type = "element", tag = "head", props = {}, children = {} },
    },
  }
end

-- Helper: find first descendant element with given tag.
local function find_el(children, tag)
  if not children then return nil end
  for _, c in ipairs(children) do
    if c.type == "element" and c.tag == tag then return c end
  end
  return nil
end

-- Helper: find meta by name attribute in a children list.
local function find_meta(children, name)
  for _, c in ipairs(children) do
    if c.type == "element" and c.tag == "meta" and c.props.name == name then
      return c
    end
  end
  return nil
end

-- Helper: find meta by property attribute.
local function find_og(children, property)
  for _, c in ipairs(children) do
    if c.type == "element" and c.tag == "meta" and c.props.property == property then
      return c
    end
  end
  return nil
end

T.describe("rehype_meta: basic metadata", function()
  T.it("adds <title>", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { title = "My Page" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    T.ok(head ~= nil)
    local title = find_el(head.children, "title")
    T.ok(title ~= nil)
    T.eq(title.children[1].value, "My Page")
  end)

  T.it("adds description meta", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { description = "A page" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local m = find_meta(head.children, "description")
    T.ok(m ~= nil)
    T.eq(m.props.content, "A page")
  end)

  T.it("adds keywords meta joined by comma", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { keywords = { "lua", "unified", "ast" } })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local m = find_meta(head.children, "keywords")
    T.ok(m ~= nil)
    T.eq(m.props.content, "lua, unified, ast")
  end)

  T.it("adds author meta", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { author = "Alice" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local m = find_meta(head.children, "author")
    T.ok(m ~= nil)
    T.eq(m.props.content, "Alice")
  end)

  T.it("adds theme-color meta", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { color = "#336791" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local m = find_meta(head.children, "theme-color")
    T.ok(m ~= nil)
    T.eq(m.props.content, "#336791")
  end)

  T.it("adds canonical link", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { canonical = "https://example.com/page" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local link = find_el(head.children, "link")
    T.ok(link ~= nil)
    T.eq(link.props.rel, "canonical")
    T.eq(link.props.href, "https://example.com/page")
  end)
end)

T.describe("rehype_meta: Open Graph tags", function()
  T.it("og:title and og:description when og=true", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, {
      title       = "My Page",
      description = "A page",
      og          = true,
    })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local og_title = find_og(head.children, "og:title")
    T.ok(og_title ~= nil)
    T.eq(og_title.props.content, "My Page")
    local og_desc = find_og(head.children, "og:description")
    T.ok(og_desc ~= nil)
    T.eq(og_desc.props.content, "A page")
  end)

  T.it("og:type defaults to website", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { og = true })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local og_type = find_og(head.children, "og:type")
    T.ok(og_type ~= nil)
    T.eq(og_type.props.content, "website")
  end)

  T.it("og:type uses opts.og_type", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { og = true, og_type = "article" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local og_type = find_og(head.children, "og:type")
    T.eq(og_type.props.content, "article")
  end)

  T.it("og:image when og_image provided", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { og = true, og_image = "https://example.com/img.png" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local og_img = find_og(head.children, "og:image")
    T.ok(og_img ~= nil)
    T.eq(og_img.props.content, "https://example.com/img.png")
  end)

  T.it("no og tags when og=false", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { title = "X", og = false })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local og_title = find_og(head.children, "og:title")
    T.eq(og_title, nil)
  end)
end)

T.describe("rehype_meta: Twitter card tags", function()
  T.it("adds twitter:card summary", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, { twitter = true })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local m = find_meta(head.children, "twitter:card")
    T.ok(m ~= nil)
    T.eq(m.props.content, "summary")
  end)

  T.it("adds twitter:title and twitter:description", function()
    local tree = bare_head_tree()
    local p = rehype():use(rehype_meta, {
      title       = "T",
      description = "D",
      twitter     = true,
    })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    local mt = find_meta(head.children, "twitter:title")
    T.ok(mt ~= nil)
    T.eq(mt.props.content, "T")
    local md = find_meta(head.children, "twitter:description")
    T.ok(md ~= nil)
    T.eq(md.props.content, "D")
  end)
end)

T.describe("rehype_meta: head creation", function()
  T.it("creates head when none exists", function()
    local tree = { type = "root", children = {} }
    local p = rehype():use(rehype_meta, { title = "X" })
    tree = p:run(tree)
    local head = find_el(tree.children, "head")
    T.ok(head ~= nil)
    local title = find_el(head.children, "title")
    T.ok(title ~= nil)
  end)

  T.it("finds head inside <html>", function()
    local tree = {
      type = "root",
      children = {
        {
          type = "element", tag = "html", props = {}, children = {
            { type = "element", tag = "head", props = {}, children = {} },
            { type = "element", tag = "body", props = {}, children = {} },
          },
        },
      },
    }
    local p = rehype():use(rehype_meta, { title = "Hello" })
    tree = p:run(tree)
    local html_el = find_el(tree.children, "html")
    local head = find_el(html_el.children, "head")
    local title = find_el(head.children, "title")
    T.ok(title ~= nil)
    T.eq(title.children[1].value, "Hello")
  end)
end)
