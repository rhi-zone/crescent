-- lib/unified/rehype_xast/rehype_xast_test.lua
local T           = require("lib.test.assert")
local rehype_xast = require("lib.unified.rehype_xast")

T.describe("rehype_xast.to_xast", function()
  T.it("converts root node", function()
    local hast = { type = "root", children = {} }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "root")
    T.ok(type(x.children) == "table")
  end)

  T.it("converts element node", function()
    local hast = {
      type = "element", tag = "div",
      props = { class = "foo", id = "bar" },
      children = {},
    }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "element")
    T.eq(x.name, "div")
    T.eq(x.attributes["class"], "foo")
    T.eq(x.attributes["id"], "bar")
  end)

  T.it("converts text node", function()
    local hast = { type = "text", value = "hello" }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "text")
    T.eq(x.value, "hello")
  end)

  T.it("converts comment node", function()
    local hast = { type = "comment", value = "a comment" }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "comment")
    T.eq(x.value, "a comment")
  end)

  T.it("converts doctype node", function()
    local hast = { type = "doctype" }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "doctype")
    T.eq(x.name, "html")
  end)

  T.it("converts raw node to text", function()
    local hast = { type = "raw", value = "<em>raw</em>" }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "text")
    T.eq(x.value, "<em>raw</em>")
  end)

  T.it("converts nested tree recursively", function()
    local hast = {
      type = "root",
      children = {
        {
          type = "element", tag = "p", props = {},
          children = {
            { type = "text", value = "Hello" },
            { type = "comment", value = "note" },
          },
        },
      },
    }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.type, "root")
    T.eq(#x.children, 1)
    local p = x.children[1]
    T.eq(p.type, "element")
    T.eq(p.name, "p")
    T.eq(#p.children, 2)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[2].type, "comment")
  end)

  T.it("boolean props serialise as name=name", function()
    local hast = {
      type = "element", tag = "input",
      props = { disabled = true },
      children = {},
    }
    local x = rehype_xast.to_xast(hast)
    T.eq(x.attributes["disabled"], "disabled")
  end)
end)

T.describe("rehype_xast plugin", function()
  T.it("integrates with rehype processor", function()
    local rehype = require("lib.unified.rehype")
    local proc   = rehype():use(rehype_xast.plugin)
    local hast = {
      type = "root",
      children = {
        { type = "element", tag = "span", props = {}, children = {
            { type = "text", value = "hi" },
          }
        },
      },
    }
    local x = proc:run(hast)
    T.eq(x.type, "root")
    T.eq(x.children[1].type, "element")
    T.eq(x.children[1].name, "span")
  end)
end)
