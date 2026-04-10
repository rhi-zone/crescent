-- lib/rehype/rehype_test.lua
if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T      = require("lib.test.assert")
local rehype = require("lib.rehype")

T.describe("rehype.md_to_html", function()
  T.it("converts a simple paragraph", function()
    local html = rehype.md_to_html("Hello world")
    T.ok(html:find("<p>", 1, true), "expected <p> tag")
    T.ok(html:find("Hello world", 1, true), "expected text content")
    T.ok(html:find("</p>", 1, true), "expected closing </p>")
  end)

  T.it("converts bold (strong)", function()
    local html = rehype.md_to_html("**bold**")
    T.ok(html:find("<strong>", 1, true), "expected <strong>")
    T.ok(html:find("bold", 1, true), "expected bold text")
    T.ok(html:find("</strong>", 1, true), "expected </strong>")
  end)

  T.it("converts italic (emphasis)", function()
    local html = rehype.md_to_html("_italic_")
    T.ok(html:find("<em>", 1, true), "expected <em>")
    T.ok(html:find("italic", 1, true), "expected italic text")
  end)

  T.it("converts headings", function()
    local html = rehype.md_to_html("# Title")
    T.ok(html:find("<h1>", 1, true), "expected <h1>")
    T.ok(html:find("Title", 1, true), "expected heading text")
  end)

  T.it("converts inline code", function()
    local html = rehype.md_to_html("`code`")
    T.ok(html:find("<code>", 1, true), "expected <code>")
    T.ok(html:find("code", 1, true), "expected code text")
  end)

  T.it("converts unordered lists", function()
    local html = rehype.md_to_html("- item one\n- item two")
    T.ok(html:find("<ul>", 1, true), "expected <ul>")
    T.ok(html:find("<li>", 1, true), "expected <li>")
    T.ok(html:find("item one", 1, true), "expected first item text")
  end)

  T.it("converts links", function()
    local html = rehype.md_to_html("[click](https://example.com)")
    T.ok(html:find('<a ', 1, true), "expected <a> tag")
    T.ok(html:find("https://example.com", 1, true), "expected href")
    T.ok(html:find("click", 1, true), "expected link text")
  end)
end)

T.describe("rehype().stringify", function()
  T.it("serializes a hand-constructed hast element", function()
    local processor = rehype()
    local ast = {
      type = "element",
      tag  = "p",
      props = {},
      children = {
        { type = "text", value = "Hello " },
        {
          type = "element",
          tag  = "strong",
          props = {},
          children = { { type = "text", value = "world" } },
        },
      },
    }
    local html = processor:stringify(ast)
    T.eq(html, "<p>Hello <strong>world</strong></p>")
  end)

  T.it("serializes a root node with multiple children", function()
    local processor = rehype()
    local ast = {
      type = "root",
      children = {
        { type = "element", tag = "h1", props = {}, children = {
          { type = "text", value = "Title" },
        }},
        { type = "element", tag = "p", props = {}, children = {
          { type = "text", value = "Body" },
        }},
      },
    }
    local html = processor:stringify(ast)
    T.eq(html, "<h1>Title</h1><p>Body</p>")
  end)

  T.it("serializes void elements correctly", function()
    local processor = rehype()
    local ast = {
      type = "element",
      tag  = "img",
      props = { src = "cat.png", alt = "a cat" },
      children = {},
    }
    local html = processor:stringify(ast)
    -- alt comes before src (sorted keys)
    T.eq(html, '<img alt="a cat" src="cat.png">')
  end)

  T.it("escapes text content", function()
    local processor = rehype()
    local ast = {
      type = "element",
      tag  = "p",
      props = {},
      children = { { type = "text", value = "<script>alert('xss')</script>" } },
    }
    local html = processor:stringify(ast)
    T.ok(not html:find("<script>", 1, true), "raw <script> must not appear")
    T.ok(html:find("&lt;script&gt;", 1, true), "must be escaped")
  end)

  T.it("parse stub returns a root node without error", function()
    local processor = rehype()
    local ast = processor:parse("<p>Hello</p>")
    T.ok(ast ~= nil, "parse should not return nil")
    T.eq(ast.type, "root")
    T.eq(ast.raw, "<p>Hello</p>")
  end)
end)

T.describe("rehype transformer plugins via :use()", function()
  T.it("transformer can modify the hast tree before stringify", function()
    -- rehype() is frozen, so :use() returns a new unfrozen clone.
    local processor = rehype():use(function(proc)
      proc:use_transformer(function(ast)
        -- Wrap everything in a <div class="wrapper">.
        return {
          type     = "element",
          tag      = "div",
          props    = { class = "wrapper" },
          children = { ast },
        }
      end)
    end)

    local inner = {
      type = "element",
      tag  = "p",
      props = {},
      children = { { type = "text", value = "hi" } },
    }
    -- :process() calls parse+run+stringify; for a pre-built AST use run+stringify.
    local ran = processor:run(inner)
    local out = processor:stringify(ran)
    T.ok(out:find('<div class="wrapper">', 1, true), "expected wrapper div")
    T.ok(out:find("<p>hi</p>", 1, true), "expected inner paragraph")
  end)

  T.it(":use() on frozen processor returns a new processor", function()
    local base  = rehype()
    local clone = base:use(function(_proc) end)
    T.ok(base ~= clone, "use() on frozen should return a new processor")
    T.ok(not clone._frozen, "clone starts unfrozen")
  end)
end)
