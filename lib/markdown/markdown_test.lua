if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.markdown")

-- ---------------------------------------------------------------------------
-- Headings
-- ---------------------------------------------------------------------------

T.describe("headings", function()
  T.it("ATX h1", function()
    T.eq(M.to_html("# Hello"), "<h1>Hello</h1>\n")
  end)

  T.it("ATX h2", function()
    T.ok(M.to_html("## World"):find("<h2>World</h2>"))
  end)

  T.it("ATX h3", function()
    T.ok(M.to_html("### Three"):find("<h3>Three</h3>"))
  end)

  T.it("ATX h4", function()
    T.ok(M.to_html("#### Four"):find("<h4>Four</h4>"))
  end)

  T.it("ATX heading strips trailing hashes", function()
    T.eq(M.to_html("## Hello ##"), "<h2>Hello</h2>\n")
  end)

  T.it("setext h1 with ===", function()
    local html = M.to_html("Hello\n=====")
    T.ok(html:find("<h1>Hello</h1>"))
  end)

  T.it("setext h2 with ---", function()
    local html = M.to_html("World\n-----")
    T.ok(html:find("<h2>World</h2>"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Inline elements
-- ---------------------------------------------------------------------------

T.describe("inline", function()
  T.it("bold **text**", function()
    T.ok(M.to_html("**bold**"):find("<strong>bold</strong>"))
  end)

  T.it("bold __text__", function()
    T.ok(M.to_html("__bold__"):find("<strong>bold</strong>"))
  end)

  T.it("italic *text*", function()
    T.ok(M.to_html("*italic*"):find("<em>italic</em>"))
  end)

  T.it("italic _text_", function()
    T.ok(M.to_html("_italic_"):find("<em>italic</em>"))
  end)

  T.it("bold+italic ***text***", function()
    T.ok(M.to_html("***bold italic***"):find("<strong><em>bold italic</em></strong>"))
  end)

  T.it("inline code `code`", function()
    T.ok(M.to_html("`code`"):find("<code>code</code>"))
  end)

  T.it("link [text](url)", function()
    T.ok(M.to_html("[text](url)"):find('<a href="url">text</a>'))
  end)

  T.it("image ![alt](url)", function()
    T.ok(M.to_html("![alt text](img.png)"):find('<img src="img.png" alt="alt text" />'))
  end)

  T.it("auto-link http", function()
    T.ok(M.to_html("<http://example.com>"):find('<a href="http://example.com">'))
  end)

  T.it("auto-link https", function()
    T.ok(M.to_html("<https://example.com>"):find('<a href="https://example.com">'))
  end)

  T.it("HTML escape < in text", function()
    T.ok(M.to_html("a < b"):find("a &lt; b"))
  end)

  T.it("HTML escape > in text", function()
    T.ok(M.to_html("a > b"):find("a &gt; b"))
  end)

  T.it("HTML escape & in text", function()
    T.ok(M.to_html("a & b"):find("a &amp; b"))
  end)

  T.it("HTML escape \" in text", function()
    T.ok(M.to_html('a "b"'):find('a &quot;b&quot;'))
  end)

  T.it("hard line break: two trailing spaces", function()
    T.ok(M.to_html("line one  \nline two"):find("<br />"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Paragraphs
-- ---------------------------------------------------------------------------

T.describe("paragraphs", function()
  T.it("single line paragraph", function()
    T.eq(M.to_html("Hello world"), "<p>Hello world</p>\n")
  end)

  T.it("multi-line paragraph", function()
    local html = M.to_html("line one\nline two")
    T.ok(html:find("<p>"))
    T.ok(html:find("line one"))
    T.ok(html:find("line two"))
  end)

  T.it("two paragraphs separated by blank line", function()
    local html = M.to_html("first\n\nsecond")
    local p1, p2 = html:find("<p>first</p>"), html:find("<p>second</p>")
    T.ok(p1)
    T.ok(p2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Code blocks
-- ---------------------------------------------------------------------------

T.describe("code blocks", function()
  T.it("fenced code block with backticks", function()
    local html = M.to_html("```\nhello world\n```")
    T.ok(html:find("<pre>"))
    T.ok(html:find("<code>"))
    T.ok(html:find("hello world"))
  end)

  T.it("fenced code block with tildes", function()
    local html = M.to_html("~~~\nhello\n~~~")
    T.ok(html:find("<pre>"))
    T.ok(html:find("hello"))
  end)

  T.it("fenced code block language hint stripped from output text, kept in class", function()
    local html = M.to_html("```lua\nlocal x = 1\n```")
    T.ok(html:find('class="language%-lua"'))
    T.ok(html:find("local x = 1"))
  end)

  T.it("indented code block (4 spaces)", function()
    local html = M.to_html("    code here")
    T.ok(html:find("<pre>"))
    T.ok(html:find("code here"))
  end)

  T.it("fenced code escapes HTML entities", function()
    local html = M.to_html("```\n<script>\n```")
    T.ok(html:find("&lt;script&gt;"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------

T.describe("lists", function()
  T.it("unordered list with -", function()
    local html = M.to_html("- item1\n- item2")
    T.ok(html:find("<ul>"))
    T.ok(html:find("<li>"))
    T.ok(html:find("item1"))
    T.ok(html:find("item2"))
    T.ok(html:find("</ul>"))
  end)

  T.it("unordered list with *", function()
    local html = M.to_html("* one\n* two")
    T.ok(html:find("<ul>"))
    T.ok(html:find("one"))
  end)

  T.it("unordered list with +", function()
    local html = M.to_html("+ a\n+ b")
    T.ok(html:find("<ul>"))
    T.ok(html:find("<li>a</li>"))
  end)

  T.it("ordered list", function()
    local html = M.to_html("1. first\n2. second")
    T.ok(html:find("<ol>"))
    T.ok(html:find("<li>first</li>"))
    T.ok(html:find("<li>second</li>"))
    T.ok(html:find("</ol>"))
  end)

  T.it("ordered list preserves start number other than 1", function()
    local html = M.to_html("3. third\n4. fourth")
    T.ok(html:find('start="3"'))
  end)

  T.it("list items can contain inline formatting", function()
    local html = M.to_html("- **bold item**")
    T.ok(html:find("<strong>bold item</strong>"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Blockquotes
-- ---------------------------------------------------------------------------

T.describe("blockquotes", function()
  T.it("simple blockquote", function()
    local html = M.to_html("> quoted text")
    T.ok(html:find("<blockquote>"))
    T.ok(html:find("quoted text"))
    T.ok(html:find("</blockquote>"))
  end)

  T.it("blockquote renders inner paragraph", function()
    local html = M.to_html("> paragraph text")
    T.ok(html:find("<p>"))
    T.ok(html:find("paragraph text"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Thematic breaks
-- ---------------------------------------------------------------------------

T.describe("thematic breaks", function()
  T.it("three dashes ---", function()
    T.ok(M.to_html("---"):find("<hr />"))
  end)

  T.it("three asterisks ***", function()
    T.ok(M.to_html("***"):find("<hr />"))
  end)

  T.it("three underscores ___", function()
    T.ok(M.to_html("___"):find("<hr />"))
  end)
end)

-- ---------------------------------------------------------------------------
-- HTML passthrough
-- ---------------------------------------------------------------------------

T.describe("raw html", function()
  T.it("raw HTML block is passed through", function()
    local html = M.to_html("<div class=\"foo\">bar</div>")
    T.ok(html:find('<div class="foo">bar</div>'))
  end)
end)

-- ---------------------------------------------------------------------------
-- to_text
-- ---------------------------------------------------------------------------

T.describe("to_text", function()
  T.it("strips # heading markers", function()
    T.ok(not M.to_text("# Hello"):find("#"))
    T.ok(M.to_text("# Hello"):find("Hello"))
  end)

  T.it("h1 underline with =", function()
    local text = M.to_text("# Title")
    T.ok(text:find("==="))
  end)

  T.it("h2 underline with -", function()
    local text = M.to_text("## Sub")
    T.ok(text:find("---"))
  end)

  T.it("strips ** bold markers", function()
    T.ok(not M.to_text("**bold**"):find("%*%*"))
    T.ok(M.to_text("**bold**"):find("bold"))
  end)

  T.it("strips * italic markers", function()
    T.ok(not M.to_text("*italic*"):find("%*"))
    T.ok(M.to_text("*italic**"):find("italic"))
  end)

  T.it("strips _ italic markers", function()
    T.ok(not M.to_text("_italic_"):find("_"))
    T.ok(M.to_text("_italic_"):find("italic"))
  end)

  T.it("inline code content preserved", function()
    T.ok(M.to_text("`code`"):find("code"))
  end)

  T.it("link renders as text (url)", function()
    local text = M.to_text("[click here](http://example.com)")
    T.ok(text:find("click here"))
    T.ok(text:find("http://example.com"))
  end)

  T.it("image renders as alt text", function()
    T.ok(M.to_text("![an image](img.png)"):find("an image"))
  end)

  T.it("unordered list uses - prefix", function()
    local text = M.to_text("- apple\n- banana")
    T.ok(text:find("- apple"))
    T.ok(text:find("- banana"))
  end)

  T.it("ordered list uses numbers", function()
    local text = M.to_text("1. first\n2. second")
    T.ok(text:find("1%. first"))
    T.ok(text:find("2%. second"))
  end)

  T.it("fenced code block content preserved", function()
    local text = M.to_text("```\nsome code\n```")
    T.ok(text:find("some code"))
  end)

  T.it("thematic break renders as ---", function()
    T.eq(M.to_text("---"), "---\n")
  end)

  T.it("setext h1 heading text preserved, no = underline marker in source", function()
    local text = M.to_text("My Title\n========")
    T.ok(text:find("My Title"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Aliases
-- ---------------------------------------------------------------------------

T.describe("aliases", function()
  T.it("M.encode is M.to_html", function()
    T.eq(M.encode("# Hi"), M.to_html("# Hi"))
  end)

  T.it("M.render is M.to_html", function()
    T.eq(M.render("**x**"), M.to_html("**x**"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Module metadata
-- ---------------------------------------------------------------------------

T.describe("module", function()
  T.it("M._tier is pure", function()
    T.eq(M._tier, "pure")
  end)
end)
