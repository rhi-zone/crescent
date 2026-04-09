-- lib/mdast/mdast_test.lua
-- Tests for the mdast Markdown parser.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T    = require("lib.test.assert")
local mdast = require("lib.mdast")

-- Helper: extract the first block child of the root.
local function first(tree) return tree.children[1] end
local function child(node, ...)
  local n = node
  for _, k in ipairs({...}) do n = n.children[k] end
  return n
end

-- ── ATX Headings ─────────────────────────────────────────────────────────────

T.describe("ATX headings", function()
  T.it("h1", function()
    local t = mdast.parse("# Hello")
    T.eq(first(t).type, "heading")
    T.eq(first(t).depth, 1)
    T.eq(first(t).children[1].value, "Hello")
  end)

  T.it("h2", function()
    local t = mdast.parse("## World")
    T.eq(first(t).depth, 2)
    T.eq(first(t).children[1].value, "World")
  end)

  T.it("h3 through h6", function()
    for depth = 3, 6 do
      local t = mdast.parse(string.rep("#", depth) .. " X")
      T.eq(first(t).depth, depth)
    end
  end)

  T.it("trailing hashes stripped", function()
    local t = mdast.parse("## Title ##")
    T.eq(first(t).children[1].value, "Title")
  end)

  T.it("empty heading", function()
    local t = mdast.parse("# ")
    T.eq(first(t).type, "heading")
    T.eq(first(t).depth, 1)
    T.eq(#first(t).children, 0)
  end)
end)

-- ── Paragraphs ────────────────────────────────────────────────────────────────

T.describe("paragraphs", function()
  T.it("single paragraph", function()
    local t = mdast.parse("Hello world")
    T.eq(first(t).type, "paragraph")
    T.eq(first(t).children[1].value, "Hello world")
  end)

  T.it("two paragraphs separated by blank line", function()
    local t = mdast.parse("First\n\nSecond")
    T.eq(#t.children, 2)
    T.eq(t.children[1].type, "paragraph")
    T.eq(t.children[2].type, "paragraph")
    T.eq(t.children[1].children[1].value, "First")
    T.eq(t.children[2].children[1].value, "Second")
  end)

  T.it("paragraph with multiple lines merged", function()
    local t = mdast.parse("Line one\nLine two")
    T.eq(first(t).type, "paragraph")
    -- The two lines are joined (soft break becomes space).
    local inline = first(t).children
    -- May be "Line one" + softbreak(space) + "Line two" or merged text.
    local text = ""
    for _, n in ipairs(inline) do
      text = text .. (n.value or "")
    end
    T.ok(text:find("Line one") ~= nil)
    T.ok(text:find("Line two") ~= nil)
  end)
end)

-- ── Fenced code blocks ────────────────────────────────────────────────────────

T.describe("fenced code blocks", function()
  T.it("basic fenced block no lang", function()
    local t = mdast.parse("```\nhello\n```")
    T.eq(first(t).type, "code")
    T.eq(first(t).lang, nil)
    T.eq(first(t).value, "hello")
  end)

  T.it("fenced block with lang", function()
    local t = mdast.parse("```lua\nreturn 1\n```")
    T.eq(first(t).lang, "lua")
    T.eq(first(t).value, "return 1")
  end)

  T.it("tilde fenced block", function()
    local t = mdast.parse("~~~\nfoo\n~~~")
    T.eq(first(t).type, "code")
    T.eq(first(t).value, "foo")
  end)

  T.it("multi-line code content", function()
    local t = mdast.parse("```\nline1\nline2\nline3\n```")
    T.eq(first(t).value, "line1\nline2\nline3")
  end)

  T.it("code block followed by paragraph", function()
    local t = mdast.parse("```\ncode\n```\n\npara")
    T.eq(#t.children, 2)
    T.eq(t.children[1].type, "code")
    T.eq(t.children[2].type, "paragraph")
  end)
end)

-- ── Indented code blocks ──────────────────────────────────────────────────────

T.describe("indented code blocks", function()
  T.it("four spaces indentation", function()
    local t = mdast.parse("    code here")
    T.eq(first(t).type, "code")
    T.eq(first(t).value, "code here")
  end)

  T.it("multi-line indented", function()
    local t = mdast.parse("    line1\n    line2")
    T.eq(first(t).type, "code")
    T.eq(first(t).value, "line1\nline2")
  end)
end)

-- ── Thematic breaks ───────────────────────────────────────────────────────────

T.describe("thematic breaks", function()
  T.it("dashes", function()
    T.eq(first(mdast.parse("---")).type, "thematicBreak")
  end)

  T.it("asterisks", function()
    T.eq(first(mdast.parse("***")).type, "thematicBreak")
  end)

  T.it("underscores", function()
    T.eq(first(mdast.parse("___")).type, "thematicBreak")
  end)

  T.it("with spaces", function()
    T.eq(first(mdast.parse("- - -")).type, "thematicBreak")
  end)
end)

-- ── Blockquotes ───────────────────────────────────────────────────────────────

T.describe("blockquotes", function()
  T.it("simple blockquote", function()
    local t = mdast.parse("> hello")
    T.eq(first(t).type, "blockquote")
    local inner = first(t).children[1]
    T.eq(inner.type, "paragraph")
    T.eq(inner.children[1].value, "hello")
  end)

  T.it("multi-line blockquote", function()
    local t = mdast.parse("> line1\n> line2")
    T.eq(first(t).type, "blockquote")
  end)
end)

-- ── Unordered lists ───────────────────────────────────────────────────────────

T.describe("unordered lists", function()
  T.it("simple bullet list with -", function()
    local t = mdast.parse("- foo\n- bar\n- baz")
    T.eq(first(t).type, "list")
    T.eq(first(t).ordered, false)
    T.eq(#first(t).children, 3)
    T.eq(first(t).children[1].type, "listItem")
  end)

  T.it("bullet list with *", function()
    local t = mdast.parse("* one\n* two")
    T.eq(first(t).type, "list")
    T.eq(#first(t).children, 2)
  end)

  T.it("list item content is paragraph", function()
    local t = mdast.parse("- hello")
    local item = first(t).children[1]
    T.eq(item.type, "listItem")
    T.eq(item.children[1].type, "paragraph")
    T.eq(item.children[1].children[1].value, "hello")
  end)
end)

-- ── Ordered lists ─────────────────────────────────────────────────────────────

T.describe("ordered lists", function()
  T.it("simple ordered list", function()
    local t = mdast.parse("1. first\n2. second\n3. third")
    T.eq(first(t).type, "list")
    T.eq(first(t).ordered, true)
    T.eq(first(t).start, 1)
    T.eq(#first(t).children, 3)
  end)

  T.it("start number preserved", function()
    local t = mdast.parse("3. first\n4. second")
    T.eq(first(t).start, 3)
  end)
end)

-- ── Emphasis ─────────────────────────────────────────────────────────────────

T.describe("emphasis", function()
  T.it("asterisk emphasis", function()
    local t = mdast.parse("*hello*")
    local em = first(t).children[1]
    T.eq(em.type, "emphasis")
    T.eq(em.children[1].value, "hello")
  end)

  T.it("underscore emphasis", function()
    local t = mdast.parse("_world_")
    local em = first(t).children[1]
    T.eq(em.type, "emphasis")
    T.eq(em.children[1].value, "world")
  end)

  T.it("strong asterisk", function()
    local t = mdast.parse("**bold**")
    local s = first(t).children[1]
    T.eq(s.type, "strong")
    T.eq(s.children[1].value, "bold")
  end)

  T.it("strong underscore", function()
    local t = mdast.parse("__bold__")
    local s = first(t).children[1]
    T.eq(s.type, "strong")
    T.eq(s.children[1].value, "bold")
  end)

  T.it("emphasis inside paragraph", function()
    local t = mdast.parse("text *em* more")
    local children = first(t).children
    T.eq(children[1].type, "text")
    T.eq(children[2].type, "emphasis")
    T.eq(children[3].type, "text")
  end)
end)

-- ── Inline code ───────────────────────────────────────────────────────────────

T.describe("inline code", function()
  T.it("single backtick", function()
    local t = mdast.parse("`code`")
    local ic = first(t).children[1]
    T.eq(ic.type, "inlineCode")
    T.eq(ic.value, "code")
  end)

  T.it("double backtick allows single inside", function()
    local t = mdast.parse("`` a`b ``")
    local ic = first(t).children[1]
    T.eq(ic.type, "inlineCode")
    T.ok(ic.value:find("a`b") ~= nil)
  end)

  T.it("inline code in sentence", function()
    local t = mdast.parse("use `foo()` here")
    local children = first(t).children
    T.eq(children[1].value, "use ")
    T.eq(children[2].type, "inlineCode")
    T.eq(children[3].value, " here")
  end)
end)

-- ── Links ────────────────────────────────────────────────────────────────────

T.describe("links", function()
  T.it("basic link", function()
    local t = mdast.parse("[text](http://example.com)")
    local link = first(t).children[1]
    T.eq(link.type, "link")
    T.eq(link.url, "http://example.com")
    T.eq(link.children[1].value, "text")
  end)

  T.it("link with title", function()
    local t = mdast.parse('[text](http://example.com "My Title")')
    local link = first(t).children[1]
    T.eq(link.type, "link")
    T.eq(link.title, "My Title")
  end)

  T.it("link with empty title is nil", function()
    local t = mdast.parse("[text](http://example.com)")
    T.eq(first(t).children[1].title, nil)
  end)
end)

-- ── Images ───────────────────────────────────────────────────────────────────

T.describe("images", function()
  T.it("basic image", function()
    local t = mdast.parse("![alt](http://example.com/img.png)")
    local img = first(t).children[1]
    T.eq(img.type, "image")
    T.eq(img.url, "http://example.com/img.png")
    T.eq(img.children[1].value, "alt")
  end)

  T.it("image with title", function()
    local t = mdast.parse('![alt](url "title")')
    local img = first(t).children[1]
    T.eq(img.title, "title")
  end)
end)

-- ── Hard line breaks ──────────────────────────────────────────────────────────

T.describe("hard line breaks", function()
  T.it("backslash hard break", function()
    local t = mdast.parse("foo\\\nbar")
    local children = first(t).children
    -- Should have text "foo", break node, text "bar".
    local found_break = false
    for _, n in ipairs(children) do
      if n.type == "break" then found_break = true end
    end
    T.ok(found_break, "expected a break node")
  end)

  T.it("two spaces hard break", function()
    local t = mdast.parse("foo  \nbar")
    local children = first(t).children
    local found_break = false
    for _, n in ipairs(children) do
      if n.type == "break" then found_break = true end
    end
    T.ok(found_break, "expected a break node from trailing spaces")
  end)
end)

-- ── Nested structures ─────────────────────────────────────────────────────────

T.describe("nested structures", function()
  T.it("blockquote containing a list", function()
    local t = mdast.parse("> - item1\n> - item2")
    local bq = first(t)
    T.eq(bq.type, "blockquote")
    local list = bq.children[1]
    T.eq(list.type, "list")
    T.eq(#list.children, 2)
  end)

  T.it("list containing heading", function()
    local t = mdast.parse("- # heading\n- para")
    local list = first(t)
    T.eq(list.type, "list")
    -- First item child is a heading.
    local item1_children = list.children[1].children
    T.eq(item1_children[1].type, "heading")
  end)

  T.it("mixed blocks", function()
    local src = "# Title\n\nA paragraph.\n\n---\n\n- one\n- two\n\n```lua\ncode\n```"
    local t = mdast.parse(src)
    T.eq(t.children[1].type, "heading")
    T.eq(t.children[2].type, "paragraph")
    T.eq(t.children[3].type, "thematicBreak")
    T.eq(t.children[4].type, "list")
    T.eq(t.children[5].type, "code")
  end)
end)

-- ── Root node ─────────────────────────────────────────────────────────────────

T.describe("root", function()
  T.it("empty string returns root with no children", function()
    local t = mdast.parse("")
    T.eq(t.type, "root")
    T.eq(#t.children, 0)
  end)

  T.it("root type is always 'root'", function()
    local t = mdast.parse("anything")
    T.eq(t.type, "root")
  end)
end)

-- ── Stringify ─────────────────────────────────────────────────────────────────

T.describe("stringify", function()
  T.it("heading round-trip", function()
    local t = mdast.parse("# Hello")
    local s = mdast.stringify(t)
    T.ok(s:find("# Hello") ~= nil, "expected heading in output, got: " .. s)
  end)

  T.it("code block round-trip", function()
    local t = mdast.parse("```lua\ncode\n```")
    local s = mdast.stringify(t)
    T.ok(s:find("```lua") ~= nil)
    T.ok(s:find("code") ~= nil)
  end)

  T.it("thematic break round-trip", function()
    local t = mdast.parse("---")
    local s = mdast.stringify(t)
    T.ok(s:find("---") ~= nil)
  end)
end)
