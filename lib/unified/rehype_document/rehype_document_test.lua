-- lib/unified/rehype_document/rehype_document_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T      = require("lib.test.assert")
local doc    = require("lib.unified.rehype_document")
local rehype = require("lib.unified.rehype")

local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end
local function txt(v)
  return { type = "text", value = v }
end

local function run(root, opts)
  local p = rehype():use(doc, opts)
  return p:stringify(p:run(root))
end

T.describe("rehype_document: document skeleton", function()
  T.it("adds <!doctype html> at the start", function()
    local root = { type = "root", children = {} }
    local html = run(root, {})
    T.ok(html:find("<!doctype html>", 1, true), "doctype present")
    T.eq(html:sub(1, 15), "<!doctype html>", "doctype is first")
  end)

  T.it("adds <html>, <head>, <body>", function()
    local root = { type = "root", children = {} }
    local html = run(root, {})
    T.ok(html:find("<html>", 1, true) or html:find("<html ", 1, true), "html element")
    T.ok(html:find("<head>", 1, true), "head element")
    T.ok(html:find("<body>", 1, true), "body element")
  end)

  T.it("sets lang attribute on <html>", function()
    local root = { type = "root", children = {} }
    local html = run(root, { lang = "en" })
    T.ok(html:find('lang="en"', 1, true), "lang attr")
  end)

  T.it("sets page title", function()
    local root = { type = "root", children = {} }
    local html = run(root, { title = "Hello World" })
    T.ok(html:find("<title>Hello World</title>", 1, true), "title element")
  end)

  T.it("adds <link rel=stylesheet> for each CSS entry", function()
    local root = { type = "root", children = {} }
    local html = run(root, { css = { "a.css", "b.css" } })
    T.ok(html:find('href="a.css"', 1, true), "first css")
    T.ok(html:find('href="b.css"', 1, true), "second css")
    T.ok(html:find('rel="stylesheet"', 1, true), "rel=stylesheet")
  end)

  T.it("accepts css as a single string", function()
    local root = { type = "root", children = {} }
    local html = run(root, { css = "single.css" })
    T.ok(html:find('href="single.css"', 1, true), "single css")
  end)

  T.it("adds <script src> for each JS entry", function()
    local root = { type = "root", children = {} }
    local html = run(root, { js = { "app.js" } })
    T.ok(html:find('src="app.js"', 1, true), "script src")
    T.ok(html:find("<script", 1, true), "script tag")
  end)

  T.it("adds <meta> elements", function()
    local root = { type = "root", children = {} }
    local html = run(root, {
      meta = {
        { charset = "utf-8" },
        { name = "viewport", content = "width=device-width" },
      },
    })
    T.ok(html:find('charset="utf-8"', 1, true), "charset meta")
    T.ok(html:find('name="viewport"', 1, true), "viewport meta")
  end)

  T.it("places original content inside <body>", function()
    local root = {
      type = "root",
      children = {
        el("h1", {}, { txt("Title") }),
        el("p",  {}, { txt("Paragraph") }),
      },
    }
    local html = run(root, { title = "T" })
    local body_start = html:find("<body>", 1, true)
    local h1_pos     = html:find("<h1>", 1, true)
    local body_end   = html:find("</body>", 1, true)
    T.ok(body_start and h1_pos and body_end, "body, h1 and /body present")
    T.ok(body_start < h1_pos and h1_pos < body_end, "h1 is inside body")
  end)

  T.it("meta appears in head before title", function()
    local root = { type = "root", children = {} }
    local html = run(root, {
      title = "T",
      meta  = { { charset = "utf-8" } },
    })
    local meta_pos  = html:find("<meta", 1, true)
    local title_pos = html:find("<title>", 1, true)
    T.ok(meta_pos < title_pos, "meta before title")
  end)
end)
