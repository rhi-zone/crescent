if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local mustache = require("lib.mustache")

T.describe("mustache", function()

  T.describe("variables", function()
    T.it("simple interpolation", function()
      T.eq(mustache.render("Hello {{name}}!", { name = "world" }), "Hello world!")
    end)

    T.it("HTML escaping", function()
      T.eq(mustache.render("{{name}}", { name = "<b>bold</b>" }), "&lt;b&gt;bold&lt;/b&gt;")
    end)

    T.it("unescaped triple mustache", function()
      T.eq(mustache.render("{{{name}}}", { name = "<b>bold</b>" }), "<b>bold</b>")
    end)

    T.it("unescaped ampersand", function()
      T.eq(mustache.render("{{&name}}", { name = "<b>bold</b>" }), "<b>bold</b>")
    end)

    T.it("missing variable renders empty", function()
      T.eq(mustache.render("{{missing}}", {}), "")
    end)

    T.it("number values", function()
      T.eq(mustache.render("{{count}}", { count = 42 }), "42")
    end)

    T.it("boolean false renders empty", function()
      T.eq(mustache.render("{{val}}", { val = false }), "")
    end)

    T.it("escapes ampersand", function()
      T.eq(mustache.render("{{x}}", { x = 'a&b"c' }), 'a&amp;b&quot;c')
    end)
  end)

  T.describe("sections", function()
    T.it("truthy value renders block", function()
      T.eq(mustache.render("{{#show}}yes{{/show}}", { show = true }), "yes")
    end)

    T.it("falsy value skips block", function()
      T.eq(mustache.render("{{#show}}yes{{/show}}", { show = false }), "")
    end)

    T.it("nil value skips block", function()
      T.eq(mustache.render("{{#show}}yes{{/show}}", {}), "")
    end)

    T.it("iterates array", function()
      T.eq(mustache.render("{{#items}}{{.}} {{/items}}", { items = { "a", "b", "c" } }), "a b c ")
    end)

    T.it("object context", function()
      T.eq(mustache.render("{{#person}}{{name}}{{/person}}", { person = { name = "Alice" } }), "Alice")
    end)

    T.it("nested sections", function()
      local tmpl = "{{#a}}{{#b}}{{val}}{{/b}}{{/a}}"
      local data = { a = { b = { val = "deep" } } }
      T.eq(mustache.render(tmpl, data), "deep")
    end)

    T.it("empty string is truthy", function()
      T.eq(mustache.render("{{#val}}yes{{/val}}", { val = "" }), "yes")
    end)
  end)

  T.describe("inverted sections", function()
    T.it("renders when falsy", function()
      T.eq(mustache.render("{{^items}}empty{{/items}}", { items = {} }), "empty")
    end)

    T.it("renders when nil", function()
      T.eq(mustache.render("{{^thing}}nope{{/thing}}", {}), "nope")
    end)

    T.it("not rendered when truthy", function()
      T.eq(mustache.render("{{^items}}empty{{/items}}", { items = { 1 } }), "")
    end)
  end)

  T.describe("comments", function()
    T.it("comments are ignored", function()
      T.eq(mustache.render("a{{! this is ignored}}b", {}), "ab")
    end)
  end)

  T.describe("dot notation", function()
    T.it("nested property access", function()
      T.eq(mustache.render("{{person.name}}", { person = { name = "Alice" } }), "Alice")
    end)

    T.it("deeply nested", function()
      T.eq(mustache.render("{{a.b.c}}", { a = { b = { c = "val" } } }), "val")
    end)
  end)

  T.describe("implicit iterator", function()
    T.it("dot in array section", function()
      T.eq(mustache.render("{{#list}}[{{.}}]{{/list}}", { list = { 1, 2, 3 } }), "[1][2][3]")
    end)
  end)

  T.describe("partials", function()
    T.it("basic partial", function()
      local result = mustache.render("{{> header}}", {}, { header = "Hello" })
      T.eq(result, "Hello")
    end)

    T.it("partial with indentation", function()
      local result = mustache.render("  {{> item}}\n", {}, { item = "line1\nline2\n" })
      -- The partial should have its lines indented
      T.ok(result:find("  line1"), "first line indented")
      T.ok(result:find("  line2"), "second line indented")
    end)

    T.it("partial with data", function()
      local result = mustache.render("{{> greeting}}", { name = "Bob" }, { greeting = "Hi {{name}}" })
      T.eq(result, "Hi Bob")
    end)
  end)

  T.describe("set delimiter", function()
    T.it("changes delimiters", function()
      local tmpl = "{{=<% %>=}}<%name%>"
      T.eq(mustache.render(tmpl, { name = "world" }), "world")
    end)

    T.it("old delimiters no longer work after change", function()
      local tmpl = "{{=<% %>=}}{{name}}"
      T.eq(mustache.render(tmpl, { name = "world" }), "{{name}}")
    end)
  end)

  T.describe("standalone lines", function()
    T.it("section tags alone on line dont produce blank lines", function()
      local tmpl = "begin\n{{#show}}\ncontent\n{{/show}}\nend"
      T.eq(mustache.render(tmpl, { show = true }), "begin\ncontent\nend")
    end)

    T.it("inverted standalone", function()
      local tmpl = "begin\n{{^show}}\nmissing\n{{/show}}\nend"
      T.eq(mustache.render(tmpl, { show = false }), "begin\nmissing\nend")
    end)
  end)

  T.describe("lambdas", function()
    T.it("section lambda receives raw text", function()
      local data = {
        wrapped = function(text)
          return "<b>" .. text .. "</b>"
        end
      }
      T.eq(mustache.render("{{#wrapped}}inner{{/wrapped}}", data), "<b>inner</b>")
    end)

    T.it("lambda result is rendered", function()
      local data = {
        name = "world",
        greeting = function(text)
          return text .. " {{name}}"
        end
      }
      T.eq(mustache.render("{{#greeting}}Hello{{/greeting}}", data), "Hello world")
    end)
  end)

  T.describe("compile and reuse", function()
    T.it("compiled template can be reused", function()
      local compiled = mustache.compile("Hello {{name}}!")
      T.ok(compiled)
      T.eq(compiled:render({ name = "Alice" }), "Hello Alice!")
      T.eq(compiled:render({ name = "Bob" }), "Hello Bob!")
    end)
  end)

  T.describe("edge cases", function()
    T.it("empty template", function()
      T.eq(mustache.render("", {}), "")
    end)

    T.it("unclosed section returns error", function()
      local result, err = mustache.compile("{{#open}}stuff")
      T.eq(result, nil)
      T.ok(err)
      T.ok(err:find("unclosed"), "error mentions unclosed")
    end)

    T.it("mismatched section close returns error", function()
      local result, err = mustache.compile("{{#a}}stuff{{/b}}")
      T.eq(result, nil)
      T.ok(err)
      T.ok(err:find("mismatched"), "error mentions mismatched")
    end)

    T.it("context stack: inner shadows outer, falls back for missing", function()
      local tmpl = "{{#inner}}{{name}} {{outer_val}}{{/inner}}"
      local data = {
        outer_val = "from_outer",
        inner = { name = "from_inner" },
      }
      T.eq(mustache.render(tmpl, data), "from_inner from_outer")
    end)
  end)

end)
