-- lib/hast/hast_test.lua
-- Tests for the hast HTML AST transformer and serializer.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local hast = require("lib.hast")

-- ── Headings ──────────────────────────────────────────────────────────────────

T.describe("headings", function()
  T.it("h1", function()
    local html = hast.md_to_html("# Hello")
    T.ok(html:find("<h1>"), "h1 open tag")
    T.ok(html:find("</h1>"), "h1 close tag")
    T.ok(html:find("Hello"), "heading text")
  end)

  T.it("h2 through h6", function()
    for depth = 2, 6 do
      local src = string.rep("#", depth) .. " X"
      local html = hast.md_to_html(src)
      T.ok(html:find("<h" .. depth .. ">"), "h" .. depth .. " open")
      T.ok(html:find("</h" .. depth .. ">"), "h" .. depth .. " close")
    end
  end)

  T.it("heading with inline content", function()
    local html = hast.md_to_html("## Hello *world*")
    T.ok(html:find("<h2>"), "h2")
    T.ok(html:find("<em>world</em>"), "em inside heading")
  end)
end)

-- ── Paragraphs ────────────────────────────────────────────────────────────────

T.describe("paragraphs", function()
  T.it("simple paragraph", function()
    local html = hast.md_to_html("Hello world")
    T.ok(html:find("<p>Hello world</p>"), "paragraph")
  end)

  T.it("two paragraphs", function()
    local html = hast.md_to_html("First\n\nSecond")
    T.ok(html:find("<p>First</p>"), "first para")
    T.ok(html:find("<p>Second</p>"), "second para")
  end)
end)

-- ── Emphasis and strong ───────────────────────────────────────────────────────

T.describe("inline formatting", function()
  T.it("emphasis", function()
    local html = hast.md_to_html("*em*")
    T.ok(html:find("<em>em</em>"), "em")
  end)

  T.it("strong", function()
    local html = hast.md_to_html("**strong**")
    T.ok(html:find("<strong>strong</strong>"), "strong")
  end)

  T.it("inline code", function()
    local html = hast.md_to_html("`code`")
    T.ok(html:find("<code>code</code>"), "inline code")
  end)

  T.it("emphasis and strong together", function()
    local html = hast.md_to_html("*em* **strong**")
    T.ok(html:find("<em>em</em>"), "em present")
    T.ok(html:find("<strong>strong</strong>"), "strong present")
  end)
end)

-- ── Code blocks ───────────────────────────────────────────────────────────────

T.describe("code blocks", function()
  T.it("fenced code no lang", function()
    local html = hast.md_to_html("```\nhello\n```")
    T.ok(html:find("<pre>"), "pre")
    T.ok(html:find("<code>"), "code")
    T.ok(html:find("hello"), "content")
  end)

  T.it("fenced code with lang", function()
    local html = hast.md_to_html("```lua\nreturn 1\n```")
    T.ok(html:find('<code class="language%-lua"'), "class attr")
    T.ok(html:find("return 1"), "content")
  end)

  T.it("no class on unlanguaged code", function()
    local html = hast.md_to_html("```\ncode\n```")
    T.fail(html:find('class='), "no class attr")
  end)
end)

-- ── Links ─────────────────────────────────────────────────────────────────────

T.describe("links", function()
  T.it("basic link", function()
    local html = hast.md_to_html("[text](http://example.com)")
    T.ok(html:find('href="http://example.com"'), "href attr")
    T.ok(html:find(">text<"), "link text")
  end)

  T.it("link with title", function()
    local html = hast.md_to_html('[text](http://example.com "My Title")')
    T.ok(html:find('href="http://example.com"'), "href")
    T.ok(html:find('title="My Title"'), "title")
  end)
end)

-- ── Images ────────────────────────────────────────────────────────────────────

T.describe("images", function()
  T.it("basic image", function()
    local html = hast.md_to_html("![alt](http://example.com/img.png)")
    T.ok(html:find("<img"), "img tag")
    T.ok(html:find('src="http://example.com/img.png"'), "src attr")
    T.ok(html:find('alt="alt"'), "alt attr")
    -- img is void: no closing tag
    T.fail(html:find("</img>"), "no closing img tag")
  end)
end)

-- ── Thematic break ────────────────────────────────────────────────────────────

T.describe("thematic break", function()
  T.it("renders as hr", function()
    local html = hast.md_to_html("---")
    T.ok(html:find("<hr>"), "hr tag")
    T.fail(html:find("</hr>"), "no closing hr")
  end)
end)

-- ── Blockquote ───────────────────────────────────────────────────────────────

T.describe("blockquote", function()
  T.it("renders blockquote", function()
    local html = hast.md_to_html("> hello")
    T.ok(html:find("<blockquote>"), "blockquote open")
    T.ok(html:find("</blockquote>"), "blockquote close")
    T.ok(html:find("hello"), "content")
  end)
end)

-- ── Lists ─────────────────────────────────────────────────────────────────────

T.describe("lists", function()
  T.it("unordered list", function()
    local html = hast.md_to_html("- a\n- b\n- c")
    T.ok(html:find("<ul>"), "ul")
    T.ok(html:find("</ul>"), "ul close")
    T.ok(html:find("<li>"), "li")
  end)

  T.it("ordered list", function()
    local html = hast.md_to_html("1. first\n2. second\n3. third")
    T.ok(html:find("<ol>"), "ol")
    T.ok(html:find("</ol>"), "ol close")
    T.ok(html:find("<li>"), "li")
  end)

  T.it("ordered list with start != 1 has start attr", function()
    local html = hast.md_to_html("3. third\n4. fourth")
    T.ok(html:find('start="3"'), "start attr")
  end)

  T.it("ordered list starting at 1 has no start attr", function()
    local html = hast.md_to_html("1. one\n2. two")
    T.fail(html:find('start='), "no start attr for default")
  end)
end)

-- ── HTML escaping ─────────────────────────────────────────────────────────────

T.describe("HTML escaping", function()
  T.it("escapes < in text", function()
    local html = hast.md_to_html("a < b")
    T.ok(html:find("&lt;"), "lt escaped")
  end)

  T.it("escapes > in text", function()
    local html = hast.md_to_html("a > b")
    T.ok(html:find("&gt;"), "gt escaped")
  end)

  T.it("escapes & in text", function()
    local html = hast.md_to_html("a & b")
    T.ok(html:find("&amp;"), "amp escaped")
  end)

  T.it("escapes quotes in attr values", function()
    local html = hast.md_to_html('[text](http://example.com/a?b=1&c=2)')
    T.ok(html:find("&amp;"), "amp in href")
  end)
end)

-- ── Raw HTML passthrough ──────────────────────────────────────────────────────

T.describe("raw HTML", function()
  T.it("passes through raw HTML nodes", function()
    local mdast = require("lib.mdast")
    local tree = mdast.parse("<div>raw</div>")
    local html = hast.mdast_to_html(tree)
    T.ok(html:find("<div>raw</div>"), "raw passthrough")
  end)
end)

-- ── to_html directly ─────────────────────────────────────────────────────────

T.describe("to_html direct", function()
  T.it("element with children", function()
    local node = { type = "element", tag = "p", props = {}, children = {
      { type = "text", value = "hello" }
    }}
    T.eq(hast.to_html(node), "<p>hello</p>")
  end)

  T.it("void element", function()
    local node = { type = "element", tag = "br", props = {}, children = {} }
    T.eq(hast.to_html(node), "<br>")
  end)

  T.it("element with props", function()
    local node = { type = "element", tag = "a", props = { href = "http://x.com" }, children = {
      { type = "text", value = "link" }
    }}
    T.eq(hast.to_html(node), '<a href="http://x.com">link</a>')
  end)

  T.it("text node escapes", function()
    local node = { type = "text", value = "<b>&</b>" }
    T.eq(hast.to_html(node), "&lt;b&gt;&amp;&lt;/b&gt;")
  end)

  T.it("raw node passes through verbatim", function()
    local node = { type = "raw", value = "<div>raw &amp; stuff</div>" }
    T.eq(hast.to_html(node), "<div>raw &amp; stuff</div>")
  end)
end)

-- ── from_mdast ────────────────────────────────────────────────────────────────

T.describe("from_mdast", function()
  T.it("produces root node", function()
    local mdast = require("lib.mdast")
    local tree = mdast.parse("# Hello")
    local htree = hast.from_mdast(tree)
    T.eq(htree.type, "root")
    T.ok(#htree.children > 0, "has children")
    T.eq(htree.children[1].type, "element")
    T.eq(htree.children[1].tag, "h1")
  end)

  T.it("code block produces pre > code", function()
    local mdast = require("lib.mdast")
    local tree = mdast.parse("```\ncode\n```")
    local htree = hast.from_mdast(tree)
    local pre = htree.children[1]
    T.eq(pre.tag, "pre")
    T.eq(pre.children[1].tag, "code")
  end)
end)
