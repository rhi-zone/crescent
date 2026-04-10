-- lib/unified/xast/xast_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local xast = require("lib.unified.xast")

T.describe("xast constructors", function()
  T.it("root", function()
    local n = xast.root({})
    T.eq(n.type, "root")
    T.eq(#n.children, 0)
  end)

  T.it("element with attributes and children", function()
    local n = xast.element("item", { id = "1" }, { xast.text("hello") })
    T.eq(n.type, "element")
    T.eq(n.name, "item")
    T.eq(n.attributes.id, "1")
    T.eq(#n.children, 1)
  end)

  T.it("text", function()
    local n = xast.text("hello")
    T.eq(n.type, "text")
    T.eq(n.value, "hello")
  end)

  T.it("comment", function()
    local n = xast.comment("note")
    T.eq(n.type, "comment")
    T.eq(n.value, "note")
  end)

  T.it("doctype minimal", function()
    local n = xast.doctype("html", nil, nil)
    T.eq(n.type, "doctype")
    T.eq(n.name, "html")
    T.eq(n.public, nil)
    T.eq(n.system, nil)
  end)

  T.it("instruction", function()
    local n = xast.instruction("xml", 'version="1.0"')
    T.eq(n.type, "instruction")
    T.eq(n.name, "xml")
    T.eq(n.value, 'version="1.0"')
  end)

  T.it("cdata", function()
    local n = xast.cdata("<raw>")
    T.eq(n.type, "cdata")
    T.eq(n.value, "<raw>")
  end)
end)

T.describe("xast.to_xml", function()
  T.it("text escaping", function()
    local s = xast.to_xml(xast.text([[a < b & c > d]]))
    T.eq(s, "a &lt; b &amp; c &gt; d")
  end)

  T.it("comment", function()
    local s = xast.to_xml(xast.comment("hello"))
    T.eq(s, "<!--hello-->")
  end)

  T.it("instruction", function()
    local s = xast.to_xml(xast.instruction("xml", 'version="1.0"'))
    T.eq(s, '<?xml version="1.0"?>')
  end)

  T.it("cdata", function()
    local s = xast.to_xml(xast.cdata("x & y"))
    T.eq(s, "<![CDATA[x & y]]>")
  end)

  T.it("doctype no system or public", function()
    local s = xast.to_xml(xast.doctype("html", nil, nil))
    T.eq(s, "<!DOCTYPE html>")
  end)

  T.it("doctype with system", function()
    local s = xast.to_xml(xast.doctype("html", nil, "about:legacy-compat"))
    T.eq(s, '<!DOCTYPE html SYSTEM "about:legacy-compat">')
  end)

  T.it("doctype with public and system", function()
    local s = xast.to_xml(xast.doctype("html",
      "-//W3C//DTD XHTML 1.0 Strict//EN",
      "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"))
    T.eq(s, '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">')
  end)

  T.it("self-closing element with no children", function()
    local s = xast.to_xml(xast.element("br", {}, {}))
    T.eq(s, "<br/>")
  end)

  T.it("element with children", function()
    local s = xast.to_xml(xast.element("p", {}, { xast.text("hello") }))
    T.eq(s, "<p>hello</p>")
  end)

  T.it("element attributes sorted alphabetically", function()
    local s = xast.to_xml(xast.element("a", { href = "x", class = "y" }, {}))
    T.eq(s, '<a class="y" href="x"/>')
  end)

  T.it("attribute value escaping", function()
    local s = xast.to_xml(xast.element("a", { href = 'a"b&c' }, {}))
    T.eq(s, '<a href="a&quot;b&amp;c"/>')
  end)

  T.it("root serializes children", function()
    local s = xast.to_xml(xast.root({
      xast.element("a", {}, { xast.text("1") }),
      xast.element("b", {}, { xast.text("2") }),
    }))
    T.eq(s, "<a>1</a><b>2</b>")
  end)

  T.it("nested elements", function()
    local s = xast.to_xml(xast.element("root", {}, {
      xast.element("child", { n = "1" }, { xast.text("hello") }),
      xast.comment("mid"),
      xast.element("child", { n = "2" }, { xast.cdata("raw") }),
    }))
    T.eq(s, '<root><child n="1">hello</child><!--mid--><child n="2"><![CDATA[raw]]></child></root>')
  end)
end)
