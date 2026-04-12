if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local xml = require("lib.xml")
local T   = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- Entity helpers
-- ---------------------------------------------------------------------------
T.describe("escape / unescape", function()
  T.it("escapes all five special chars", function()
    T.eq(xml.escape("&"), "&amp;")
    T.eq(xml.escape("<"), "&lt;")
    T.eq(xml.escape(">"), "&gt;")
    T.eq(xml.escape('"'), "&quot;")
    T.eq(xml.escape("'"), "&apos;")
    T.eq(xml.escape("a&b<c>d\"e'f"), "a&amp;b&lt;c&gt;d&quot;e&apos;f")
  end)

  T.it("unescapes named entities", function()
    T.eq(xml.unescape("&amp;"),  "&")
    T.eq(xml.unescape("&lt;"),   "<")
    T.eq(xml.unescape("&gt;"),   ">")
    T.eq(xml.unescape("&quot;"), '"')
    T.eq(xml.unescape("&apos;"), "'")
  end)

  T.it("unescapes decimal numeric references", function()
    T.eq(xml.unescape("&#65;"),  "A")
    T.eq(xml.unescape("&#97;"),  "a")
    T.eq(xml.unescape("&#60;"),  "<")
  end)

  T.it("unescapes hex numeric references", function()
    T.eq(xml.unescape("&#x41;"), "A")
    T.eq(xml.unescape("&#x61;"), "a")
    T.eq(xml.unescape("&#x3C;"), "<")
  end)

  T.it("leaves unknown named entities intact", function()
    T.eq(xml.unescape("&unknown;"), "&unknown;")
  end)

  T.it("round-trips escape → unescape", function()
    local s = '<hello "world" & \'goodbye\'>'
    T.eq(xml.unescape(xml.escape(s)), s)
  end)
end)

-- ---------------------------------------------------------------------------
-- ns_split
-- ---------------------------------------------------------------------------
T.describe("ns_split", function()
  T.it("splits prefixed names", function()
    local p, l = xml.ns_split("ns:tag")
    T.eq(p, "ns")
    T.eq(l, "tag")
  end)

  T.it("returns empty prefix for unprefixed names", function()
    local p, l = xml.ns_split("tag")
    T.eq(p, "")
    T.eq(l, "tag")
  end)

  T.it("handles multiple colons — first colon is the split", function()
    local p, l = xml.ns_split("a:b:c")
    T.eq(p, "a")
    T.eq(l, "b:c")
  end)
end)

-- ---------------------------------------------------------------------------
-- SAX parser
-- ---------------------------------------------------------------------------
T.describe("sax", function()
  T.it("fires start_document / end_document", function()
    local events = {}
    xml.sax("<r/>", {
      start_document = function() events[#events+1] = "start_doc" end,
      end_document   = function() events[#events+1] = "end_doc"   end,
    })
    T.eq(events[1], "start_doc")
    T.eq(events[2], "end_doc")
  end)

  T.it("fires start_element and end_element for self-closing tag", function()
    local events = {}
    xml.sax("<foo/>", {
      start_element = function(n, _) events[#events+1] = "start:" .. n end,
      end_element   = function(n)   events[#events+1] = "end:" .. n   end,
    })
    T.eq(events[1], "start:foo")
    T.eq(events[2], "end:foo")
  end)

  T.it("fires events in correct order for nested elements", function()
    local events = {}
    local h = {
      start_element = function(n, _) events[#events+1] = "open:" .. n  end,
      end_element   = function(n)   events[#events+1] = "close:" .. n  end,
    }
    xml.sax("<a><b><c/></b></a>", h)
    T.eq(events[1], "open:a")
    T.eq(events[2], "open:b")
    T.eq(events[3], "open:c")
    T.eq(events[4], "close:c")
    T.eq(events[5], "close:b")
    T.eq(events[6], "close:a")
  end)

  T.it("passes attributes to start_element", function()
    local got_attrs
    xml.sax('<el x="1" y="hello"/>', {
      start_element = function(_, attrs) got_attrs = attrs end,
    })
    T.eq(got_attrs.x, "1")
    T.eq(got_attrs.y, "hello")
  end)

  T.it("fires text callback", function()
    local texts = {}
    xml.sax("<p>Hello world</p>", {
      text = function(t) texts[#texts+1] = t end,
    })
    T.eq(texts[1], "Hello world")
  end)

  T.it("fires comment callback", function()
    local comments = {}
    xml.sax("<!-- hello -->", {
      comment = function(t) comments[#comments+1] = t end,
    })
    T.eq(comments[1], " hello ")
  end)

  T.it("fires cdata callback", function()
    local cdatas = {}
    xml.sax("<![CDATA[<raw>&data</raw>]]>", {
      cdata = function(t) cdatas[#cdatas+1] = t end,
    })
    T.eq(cdatas[1], "<raw>&data</raw>")
  end)

  T.it("fires processing_instruction callback", function()
    local pi_target, pi_data
    xml.sax("<?target some data?>", {
      processing_instruction = function(t, d)
        pi_target = t; pi_data = d
      end,
    })
    T.eq(pi_target, "target")
    T.eq(pi_data,   "some data")
  end)

  T.it("does NOT fire PI callback for <?xml ...?> declaration", function()
    local fired = false
    xml.sax('<?xml version="1.0"?><r/>', {
      processing_instruction = function() fired = true end,
    })
    T.ok(not fired, "should not fire PI for XML declaration")
  end)

  T.it("unescapes attribute values", function()
    local got
    xml.sax('<el v="a&amp;b"/>', {
      start_element = function(_, attrs) got = attrs.v end,
    })
    T.eq(got, "a&b")
  end)

  T.it("returns true on success", function()
    local ok = xml.sax("<r/>", {})
    T.eq(ok, true)
  end)

  T.it("returns nil, errmsg on unclosed tag", function()
    local ok, err = xml.sax("<a>", {})
    T.eq(ok, nil)
    T.ok(err ~= nil, "should have error message")
    T.ok(err:find("unclosed") or err:find("tag"), "error mentions tag: " .. tostring(err))
  end)

  T.it("returns nil, errmsg on mismatched tags", function()
    local ok, err = xml.sax("<a></b>", {})
    T.eq(ok, nil)
    T.ok(err ~= nil)
    T.ok(err:find("mismatch") or err:find("expected"), "error mentions mismatch: " .. tostring(err))
  end)

  T.it("handles mixed text and elements", function()
    local events = {}
    xml.sax("<a>text<b/>more</a>", {
      start_element = function(n, _) events[#events+1] = "open:" .. n  end,
      end_element   = function(n)   events[#events+1] = "close:" .. n  end,
      text          = function(t)   events[#events+1] = "text:" .. t   end,
    })
    T.eq(events[1], "open:a")
    T.eq(events[2], "text:text")
    T.eq(events[3], "open:b")
    T.eq(events[4], "close:b")
    T.eq(events[5], "text:more")
    T.eq(events[6], "close:a")
  end)
end)

-- ---------------------------------------------------------------------------
-- DOM parser
-- ---------------------------------------------------------------------------
T.describe("dom parse", function()
  T.it("parses simple self-closing element", function()
    local doc, err = xml.parse("<foo/>")
    T.ok(doc ~= nil, tostring(err))
    T.eq(doc.type, "document")
    T.eq(#doc.children, 1)
    T.eq(doc.children[1].type, "element")
    T.eq(doc.children[1].tag, "foo")
  end)

  T.it("parses element with attributes", function()
    local doc = xml.parse('<a x="1" y="2"/>')
    local a = doc.children[1]
    T.eq(a.tag, "a")
    T.eq(a.attrs.x, "1")
    T.eq(a.attrs.y, "2")
  end)

  T.it("parses nested elements", function()
    local doc = xml.parse("<a><b><c/></b></a>")
    local a = doc.children[1]
    T.eq(a.tag, "a")
    local b = a.children[1]
    T.eq(b.tag, "b")
    local c = b.children[1]
    T.eq(c.tag, "c")
  end)

  T.it("parses text content", function()
    local doc = xml.parse("<p>Hello world</p>")
    local p = doc.children[1]
    T.eq(#p.children, 1)
    T.eq(p.children[1].type, "text")
    T.eq(p.children[1].text, "Hello world")
  end)

  T.it("parses CDATA section", function()
    local doc = xml.parse("<r><![CDATA[<raw>&data</raw>]]></r>")
    local r = doc.children[1]
    T.eq(r.children[1].type, "cdata")
    T.eq(r.children[1].text, "<raw>&data</raw>")
  end)

  T.it("parses comments", function()
    local doc = xml.parse("<!-- a comment --><r/>")
    -- comment is first child of document
    local comment = doc.children[1]
    T.eq(comment.type, "comment")
    T.eq(comment.text, " a comment ")
  end)

  T.it("sets parent references correctly", function()
    local doc = xml.parse("<a><b/></a>")
    local a = doc.children[1]
    local b = a.children[1]
    T.eq(b.parent, a)
    T.eq(a.parent, doc)
    T.eq(doc.parent, nil)
  end)

  T.it("returns nil, errmsg on malformed XML", function()
    local doc, err = xml.parse("<a>")
    T.eq(doc, nil)
    T.ok(err ~= nil)
  end)

  T.it("parses processing instruction into DOM", function()
    local doc = xml.parse("<?pi data?><r/>")
    local pi = doc.children[1]
    T.eq(pi.type, "processing_instruction")
    T.eq(pi.target, "pi")
    T.eq(pi.text, "data")
  end)
end)

-- ---------------------------------------------------------------------------
-- DOM navigation
-- ---------------------------------------------------------------------------
T.describe("dom navigation", function()
  local doc = xml.parse("<root><a id='1'/><b/><a id='2'/></root>")
  local root = doc.children[1]

  T.it("find returns first matching child", function()
    local a = xml.find(root, "a")
    T.ok(a ~= nil)
    T.eq(a.tag, "a")
    T.eq(a.attrs.id, "1")
  end)

  T.it("find returns nil when tag not found", function()
    T.eq(xml.find(root, "z"), nil)
  end)

  T.it("find_all returns all matching children", function()
    local as = xml.find_all(root, "a")
    T.eq(#as, 2)
    T.eq(as[1].attrs.id, "1")
    T.eq(as[2].attrs.id, "2")
  end)

  T.it("find_all returns empty table when none match", function()
    local zs = xml.find_all(root, "z")
    T.eq(#zs, 0)
  end)

  T.it("text_content concatenates text", function()
    local doc2 = xml.parse("<p>hello <b>world</b> end</p>")
    local p = doc2.children[1]
    T.eq(xml.text_content(p), "hello world end")
  end)

  T.it("text_content includes CDATA", function()
    local doc2 = xml.parse("<r>before<![CDATA[inside]]>after</r>")
    local r = doc2.children[1]
    T.eq(xml.text_content(r), "beforeinsideafter")
  end)

  T.it("attr returns attribute value", function()
    local doc2 = xml.parse('<el k="v"/>')
    local el = doc2.children[1]
    T.eq(xml.attr(el, "k"), "v")
  end)

  T.it("attr returns nil for missing attribute", function()
    local doc2 = xml.parse('<el k="v"/>')
    local el = doc2.children[1]
    T.eq(xml.attr(el, "missing"), nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- xpath_simple
-- ---------------------------------------------------------------------------
T.describe("xpath_simple", function()
  local doc = xml.parse(
    "<root><a><b><c id=\"1\"/></b><b><c id=\"2\"/></b></a></root>"
  )
  local root = doc.children[1]

  T.it("navigates simple path a/b", function()
    local bs = xml.xpath_simple(root, "a/b")
    T.eq(#bs, 2)
    T.eq(bs[1].tag, "b")
  end)

  T.it("navigates a/b/c", function()
    local cs = xml.xpath_simple(root, "a/b/c")
    T.eq(#cs, 2)
    T.eq(cs[1].attrs.id, "1")
    T.eq(cs[2].attrs.id, "2")
  end)

  T.it("//tag finds all descendants", function()
    local cs = xml.xpath_simple(root, "//c")
    T.eq(#cs, 2)
  end)

  T.it("a//c finds c under a recursively", function()
    local cs = xml.xpath_simple(root, "a//c")
    T.eq(#cs, 2)
  end)

  T.it("returns empty table for non-matching path", function()
    local zs = xml.xpath_simple(root, "z/y")
    T.eq(#zs, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Serializer
-- ---------------------------------------------------------------------------
T.describe("serialize", function()
  T.it("serializes self-closing element", function()
    local doc = xml.parse("<foo/>")
    local s = xml.serialize(doc)
    T.ok(s:find("<foo/>") ~= nil, "output: " .. s)
  end)

  T.it("serializes element with attributes (sorted)", function()
    local doc = xml.parse('<a z="2" a="1"/>')
    local s = xml.serialize(doc)
    -- a should come before z
    local ai = s:find('a="1"')
    local zi = s:find('z="2"')
    T.ok(ai ~= nil, "missing a attr")
    T.ok(zi ~= nil, "missing z attr")
    T.ok(ai < zi, "attributes not sorted")
  end)

  T.it("serializes text content", function()
    local doc = xml.parse("<p>Hello &amp; world</p>")
    local s = xml.serialize(doc)
    T.ok(s:find("<p>") ~= nil, "output: " .. s)
    T.ok(s:find("Hello &amp; world") ~= nil, "output: " .. s)
    T.ok(s:find("</p>") ~= nil, "output: " .. s)
  end)

  T.it("serializes CDATA", function()
    local doc = xml.parse("<r><![CDATA[<raw>]]></r>")
    local s = xml.serialize(doc)
    T.ok(s:find("<!%[CDATA%[") ~= nil, "output: " .. s)
    T.ok(s:find("<raw>") ~= nil, "output: " .. s)
  end)

  T.it("serializes comments", function()
    local doc = xml.parse("<!-- hi --><r/>")
    local s = xml.serialize(doc)
    T.ok(s:find("<!%-%-") ~= nil, "output: " .. s)
    T.ok(s:find(" hi ") ~= nil, "output: " .. s)
  end)

  T.it("adds XML declaration when declare=true", function()
    local doc = xml.parse("<r/>")
    local s = xml.serialize(doc, { declare = true })
    T.ok(s:find("<%?xml") ~= nil, "output: " .. s)
  end)

  T.it("round-trip: parse → serialize → parse produces same structure", function()
    local src = "<root><child id=\"x\">text</child></root>"
    local doc1 = xml.parse(src)
    local s    = xml.serialize(doc1)
    local doc2, err = xml.parse(s)
    T.ok(doc2 ~= nil, "re-parse failed: " .. tostring(err) .. " src=" .. s)
    local root2 = doc2.children[1]
    T.eq(root2.tag, "root")
    local child = root2.children[1]
    T.eq(child.tag, "child")
    T.eq(child.attrs.id, "x")
    T.eq(xml.text_content(child), "text")
  end)

  T.it("indented serialize produces readable output", function()
    local doc = xml.parse("<a><b><c/></b></a>")
    local s = xml.serialize(doc, { indent = 2 })
    T.ok(s:find("\n") ~= nil, "should contain newlines")
    T.ok(s:find("  ") ~= nil, "should contain indentation")
  end)
end)

-- ---------------------------------------------------------------------------
-- Builder API
-- ---------------------------------------------------------------------------
T.describe("builder", function()
  T.it("creates an element node", function()
    local el = xml.element("div", { class = "x" }, {
      xml.text_node("hello"),
    })
    T.eq(el.type, "element")
    T.eq(el.tag, "div")
    T.eq(el.attrs.class, "x")
    T.eq(#el.children, 1)
    T.eq(el.children[1].type, "text")
    T.eq(el.children[1].text, "hello")
  end)

  T.it("sets parent on children", function()
    local child = xml.text_node("x")
    local el = xml.element("p", {}, { child })
    T.eq(child.parent, el)
  end)

  T.it("creates a text node", function()
    local t = xml.text_node("hello")
    T.eq(t.type, "text")
    T.eq(t.text, "hello")
  end)

  T.it("creates a comment node", function()
    local c = xml.comment_node("note")
    T.eq(c.type, "comment")
    T.eq(c.text, "note")
  end)

  T.it("builder + serialize round-trip", function()
    local el = xml.element("root", {}, {
      xml.element("child", { id = "1" }, { xml.text_node("hello") }),
    })
    local s = xml.serialize(el)
    T.ok(s:find("<root>") ~= nil, "output: " .. s)
    T.ok(s:find("<child") ~= nil, "output: " .. s)
    T.ok(s:find("hello") ~= nil, "output: " .. s)
    -- re-parse
    local doc2, err = xml.parse(s)
    T.ok(doc2 ~= nil, tostring(err))
  end)
end)

-- ---------------------------------------------------------------------------
-- Error cases
-- ---------------------------------------------------------------------------
T.describe("error cases", function()
  T.it("unclosed tag returns error", function()
    local doc, err = xml.parse("<a><b>")
    T.eq(doc, nil)
    T.ok(err ~= nil)
  end)

  T.it("mismatched end tag returns error", function()
    local doc, err = xml.parse("<a></b>")
    T.eq(doc, nil)
    T.ok(err ~= nil)
    T.ok(err:find("mismatch") or err:find("expected"), err)
  end)

  T.it("unterminated comment returns error", function()
    local doc, err = xml.parse("<!-- oops")
    T.eq(doc, nil)
    T.ok(err ~= nil)
  end)

  T.it("unterminated CDATA returns error", function()
    local doc, err = xml.parse("<![CDATA[ oops")
    T.eq(doc, nil)
    T.ok(err ~= nil)
  end)

  T.it("missing attribute quote returns error", function()
    local doc, err = xml.parse("<el k=v/>")
    T.eq(doc, nil)
    T.ok(err ~= nil)
  end)
end)
