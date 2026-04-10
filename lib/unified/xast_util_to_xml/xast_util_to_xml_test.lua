-- lib/unified/xast_util_to_xml/xast_util_to_xml_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local to_xml = require("lib.unified.xast_util_to_xml")
local xast   = require("lib.unified.xast")

T.describe("xast_util_to_xml defaults", function()
  T.it("self-closing by default", function()
    local s = to_xml.to_xml(xast.element("br", {}, {}))
    T.eq(s, "<br/>")
  end)

  T.it("double-quote by default", function()
    local s = to_xml.to_xml(xast.element("a", { href = "x" }, {}))
    T.eq(s, '<a href="x"/>')
  end)

  T.it("no xml declaration by default", function()
    local s = to_xml.to_xml(xast.root({ xast.text("hi") }))
    T.eq(s, "hi")
  end)
end)

T.describe("xast_util_to_xml opts.quote", function()
  T.it("single-quote attributes", function()
    local s = to_xml.to_xml(xast.element("a", { href = "x" }, {}), { quote = "'" })
    T.eq(s, "<a href='x'/>")
  end)

  T.it("single-quote escapes apostrophe", function()
    local s = to_xml.to_xml(xast.element("a", { title = "it's" }, {}), { quote = "'" })
    T.eq(s, "<a title='it&apos;s'/>")
  end)

  T.it("double-quote escapes quote", function()
    local s = to_xml.to_xml(xast.element("a", { title = 'say "hi"' }, {}))
    T.eq(s, '<a title="say &quot;hi&quot;"/>')
  end)
end)

T.describe("xast_util_to_xml opts.close_self_closing", function()
  T.it("false → no slash", function()
    local s = to_xml.to_xml(xast.element("br", {}, {}), { close_self_closing = false })
    T.eq(s, "<br>")
  end)

  T.it("true (explicit) → slash", function()
    local s = to_xml.to_xml(xast.element("br", {}, {}), { close_self_closing = true })
    T.eq(s, "<br/>")
  end)
end)

T.describe("xast_util_to_xml opts.xml_declaration", function()
  T.it("prepends declaration when true", function()
    local s = to_xml.to_xml(xast.root({ xast.text("x") }), { xml_declaration = true })
    T.eq(s, '<?xml version="1.0" encoding="UTF-8"?>x')
  end)

  T.it("no declaration when false", function()
    local s = to_xml.to_xml(xast.root({ xast.text("x") }), { xml_declaration = false })
    T.eq(s, "x")
  end)
end)

T.describe("xast_util_to_xml re-exports constructors", function()
  T.it("element constructor", function()
    local n = to_xml.element("x", { a = "1" }, {})
    T.eq(n.type, "element")
    T.eq(n.name, "x")
  end)

  T.it("text constructor", function()
    local n = to_xml.text("hello")
    T.eq(n.type, "text")
  end)
end)

T.describe("xast_util_to_xml round-trip", function()
  T.it("full document", function()
    local doc = to_xml.root({
      to_xml.instruction("xml", 'version="1.0" encoding="UTF-8"'),
      to_xml.doctype("root"),
      to_xml.element("root", { version = "1.0" }, {
        to_xml.element("item", { id = "1" }, { to_xml.text("hello") }),
        to_xml.comment("separator"),
        to_xml.element("item", { id = "2" }, { to_xml.cdata("<raw>") }),
      }),
    })
    local s = to_xml.to_xml(doc)
    T.eq(s, '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE root><root version="1.0"><item id="1">hello</item><!--separator--><item id="2"><![CDATA[<raw>]]></item></root>')
  end)
end)
