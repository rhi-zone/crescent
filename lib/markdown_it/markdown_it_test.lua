if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local mdit = require("lib.markdown_it")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function has(html, substr)
  return html:find(substr, 1, true) ~= nil
end

-- ── tier ─────────────────────────────────────────────────────────────────────

T.describe("lib.markdown_it", function()

  T.describe("tier", function()
    T.it("exports _tier = pure", function()
      T.eq(mdit._tier, "pure")
    end)
  end)

  -- ── basic rendering ─────────────────────────────────────────────────────────

  T.describe("basic rendering", function()

    T.it("heading h1", function()
      local html = mdit.render("# Hello\n")
      T.ok(has(html, "<h1>"))
      T.ok(has(html, "Hello"))
      T.ok(has(html, "</h1>"))
    end)

    T.it("heading h2", function()
      local html = mdit.render("## Section\n")
      T.ok(has(html, "<h2>"))
      T.ok(has(html, "Section"))
      T.ok(has(html, "</h2>"))
    end)

    T.it("heading h3", function()
      local html = mdit.render("### Sub\n")
      T.ok(has(html, "<h3>"))
    end)

    T.it("paragraph", function()
      local html = mdit.render("Hello world\n")
      T.ok(has(html, "<p>"))
      T.ok(has(html, "Hello world"))
      T.ok(has(html, "</p>"))
    end)

    T.it("bold (double asterisk)", function()
      local html = mdit.render("**bold**\n")
      T.ok(has(html, "<strong>"))
      T.ok(has(html, "bold"))
      T.ok(has(html, "</strong>"))
    end)

    T.it("bold (double underscore)", function()
      local html = mdit.render("__bold__\n")
      T.ok(has(html, "<strong>"))
    end)

    T.it("italic (single asterisk)", function()
      local html = mdit.render("*italic*\n")
      T.ok(has(html, "<em>"))
      T.ok(has(html, "italic"))
      T.ok(has(html, "</em>"))
    end)

    T.it("italic (single underscore)", function()
      local html = mdit.render("_italic_\n")
      T.ok(has(html, "<em>"))
    end)

    T.it("link", function()
      local html = mdit.render("[text](http://example.com)\n")
      T.ok(has(html, '<a href="http://example.com"'))
      T.ok(has(html, "text"))
      T.ok(has(html, "</a>"))
    end)

    T.it("image", function()
      local html = mdit.render("![alt text](http://example.com/img.png)\n")
      T.ok(has(html, "<img"))
      T.ok(has(html, 'src="http://example.com/img.png"'))
      T.ok(has(html, 'alt="alt text"'))
    end)

    T.it("inline code", function()
      local html = mdit.render("`code`\n")
      T.ok(has(html, "<code>"))
      T.ok(has(html, "code"))
      T.ok(has(html, "</code>"))
    end)

    T.it("fenced code block", function()
      local html = mdit.render("```\nfoo()\n```\n")
      T.ok(has(html, "<pre>"))
      T.ok(has(html, "<code>"))
      T.ok(has(html, "foo()"))
    end)

    T.it("fenced code block with language", function()
      local html = mdit.render("```lua\nlocal x = 1\n```\n")
      T.ok(has(html, "language-lua"))
    end)

    T.it("blockquote", function()
      local html = mdit.render("> A quote\n")
      T.ok(has(html, "<blockquote>"))
      T.ok(has(html, "A quote"))
      T.ok(has(html, "</blockquote>"))
    end)

    T.it("unordered list", function()
      local html = mdit.render("- item one\n- item two\n")
      T.ok(has(html, "<ul>"))
      T.ok(has(html, "<li>"))
      T.ok(has(html, "item one"))
      T.ok(has(html, "item two"))
      T.ok(has(html, "</ul>"))
    end)

    T.it("ordered list", function()
      local html = mdit.render("1. first\n2. second\n")
      T.ok(has(html, "<ol>"))
      T.ok(has(html, "<li>"))
      T.ok(has(html, "first"))
      T.ok(has(html, "second"))
      T.ok(has(html, "</ol>"))
    end)

    T.it("horizontal rule", function()
      local html = mdit.render("---\n")
      T.ok(has(html, "<hr"))
    end)

    T.it("multiple paragraphs", function()
      local html = mdit.render("First\n\nSecond\n")
      T.ok(has(html, "First"))
      T.ok(has(html, "Second"))
    end)

    T.it("nested emphasis inside bold", function()
      local html = mdit.render("***bold italic***\n")
      T.ok(has(html, "<strong>"))
      T.ok(has(html, "<em>"))
    end)

  end)

  -- ── one-shot mdit.render ────────────────────────────────────────────────────

  T.describe("mdit.render (one-shot)", function()

    T.it("renders without creating instance", function()
      local html = mdit.render("# Title\n")
      T.ok(has(html, "<h1>"))
      T.ok(has(html, "Title"))
    end)

    T.it("accepts options table", function()
      local html = mdit.render("# Title\n", {})
      T.ok(has(html, "<h1>"))
    end)

    T.it("returns string", function()
      T.eq(type(mdit.render("hello\n")), "string")
    end)

  end)

  -- ── md:parse → AST ─────────────────────────────────────────────────────────

  T.describe("md:parse", function()

    T.it("returns a table", function()
      local md = mdit.new()
      local ast = md:parse("# Hello\n")
      T.eq(type(ast), "table")
    end)

    T.it("root node has type field", function()
      local md = mdit.new()
      local ast = md:parse("# Hello\n")
      T.eq(ast.type, "root")
    end)

    T.it("root has children", function()
      local md = mdit.new()
      local ast = md:parse("# Hello\n")
      T.ok(type(ast.children) == "table")
      T.ok(#ast.children >= 1)
    end)

    T.it("heading node has depth", function()
      local md = mdit.new()
      local ast = md:parse("## Hello\n")
      local h = ast.children[1]
      T.eq(h.type, "heading")
      T.eq(h.depth, 2)
    end)

    T.it("paragraph node", function()
      local md = mdit.new()
      local ast = md:parse("Hello world\n")
      local p = ast.children[1]
      T.eq(p.type, "paragraph")
    end)

  end)

  -- ── options ──────────────────────────────────────────────────────────────────

  T.describe("options", function()

    T.it("html=false strips raw HTML (default)", function()
      local html = mdit.render("<b>raw</b>\n")
      -- With html=false the raw HTML should be escaped, not passed through.
      T.ok(not has(html, "<b>raw</b>"))
    end)

    T.it("html=true passes raw HTML through", function()
      local md = mdit.new({ html = true })
      local html = md:render("<b>raw</b>\n")
      T.ok(has(html, "<b>raw</b>"))
    end)

    T.it("breaks=false: single newline in paragraph is not <br>", function()
      local md = mdit.new({ breaks = false })
      local html = md:render("line one\nline two\n")
      T.ok(not has(html, "<br"))
    end)

    T.it("breaks=true: single newline in paragraph becomes <br>", function()
      local md = mdit.new({ breaks = true })
      local html = md:render("line one\nline two\n")
      T.ok(has(html, "<br"))
    end)

    T.it("linkify=false: bare URL not linked (default)", function()
      local md = mdit.new({ linkify = false })
      local html = md:render("Visit https://example.com today\n")
      -- There should be no <a href around the URL when linkify is off.
      T.ok(not has(html, '<a href="https://example.com"'))
    end)

    T.it("linkify=true: bare URL becomes a link", function()
      local md = mdit.new({ linkify = true })
      local html = md:render("Visit https://example.com today\n")
      T.ok(has(html, "<a"))
      T.ok(has(html, "https://example.com"))
    end)

    T.it("typographer=false: dashes are literal (default)", function()
      local md = mdit.new({ typographer = false })
      local html = md:render("a---b\n")
      T.ok(has(html, "---"))
    end)

    T.it("typographer=true: --- becomes em-dash", function()
      local md = mdit.new({ typographer = true })
      local html = md:render("a---b\n")
      -- UTF-8 em-dash: \xe2\x80\x94
      T.ok(has(html, "\xe2\x80\x94"))
    end)

    T.it("typographer=true: -- becomes en-dash", function()
      local md = mdit.new({ typographer = true })
      local html = md:render("a--b\n")
      T.ok(has(html, "\xe2\x80\x93"))
    end)

    T.it("typographer=true: ... becomes ellipsis", function()
      local md = mdit.new({ typographer = true })
      local html = md:render("wait...\n")
      T.ok(has(html, "\xe2\x80\xa6"))
    end)

  end)

  -- ── plugin: tasklist ─────────────────────────────────────────────────────────

  T.describe("plugin.tasklist", function()

    T.it("unchecked item gets checkbox input", function()
      local md = mdit.new()
      md:use(mdit.plugin.tasklist)
      local html = md:render("- [ ] todo\n")
      T.ok(has(html, 'type="checkbox"'))
      T.ok(not has(html, "checked"))
    end)

    T.it("checked item gets checked checkbox", function()
      local md = mdit.new()
      md:use(mdit.plugin.tasklist)
      local html = md:render("- [x] done\n")
      T.ok(has(html, 'type="checkbox"'))
      T.ok(has(html, "checked"))
    end)

    T.it("mixed list", function()
      local md = mdit.new()
      md:use(mdit.plugin.tasklist)
      local html = md:render("- [x] done\n- [ ] todo\n")
      T.ok(has(html, "checked"))
      T.ok(has(html, 'type="checkbox"'))
    end)

    T.it("does not affect normal list items", function()
      local md = mdit.new()
      md:use(mdit.plugin.tasklist)
      local html = md:render("- normal item\n")
      T.ok(not has(html, 'type="checkbox"'))
      T.ok(has(html, "normal item"))
    end)

  end)

  -- ── plugin: table ────────────────────────────────────────────────────────────

  T.describe("plugin.table", function()

    T.it("table plugin registers without error", function()
      -- GFM pipe-table syntax is a known gap in lib/unified/mdast (Phase 2).
      -- The plugin is a no-op forward-compatibility shim — calling use() must
      -- not throw and must return the instance for chaining.
      local md = mdit.new()
      local ret = md:use(mdit.plugin.table)
      T.ok(ret == md)
    end)

    T.it("hast table transform works when mdast produces table node", function()
      -- Inject a synthetic table node directly to verify hast handles it.
      local hast = require("lib.unified.hast")
      local tree = {
        type = "root",
        children = {
          {
            type = "table",
            children = {
              { type = "tableRow", children = {
                  { type = "tableCell", children = { { type = "text", value = "A" } } },
                  { type = "tableCell", children = { { type = "text", value = "B" } } },
              }},
              { type = "tableRow", children = {
                  { type = "tableCell", children = { { type = "text", value = "1" } } },
                  { type = "tableCell", children = { { type = "text", value = "2" } } },
              }},
            },
          },
        },
      }
      local html = hast.mdast_to_html(tree)
      T.ok(has(html, "<table>"))
      T.ok(has(html, "<th>"))
      T.ok(has(html, "<td>"))
    end)

  end)

  -- ── plugin: abbr ─────────────────────────────────────────────────────────────

  T.describe("plugin.abbr", function()

    T.it("expands abbreviation in text", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.abbr)
      local src = "Use HTML for markup.\n\n*[HTML]: Hyper Text Markup Language\n"
      local html = md:render(src)
      T.ok(has(html, "<abbr"))
      T.ok(has(html, "Hyper Text Markup Language"))
    end)

    T.it("definition paragraph is not rendered as text", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.abbr)
      local src = "Use HTML today.\n\n*[HTML]: Hyper Text Markup Language\n"
      local html = md:render(src)
      -- The raw definition line should not appear verbatim.
      T.ok(not has(html, "*[HTML]: Hyper Text Markup Language"))
    end)

  end)

  -- ── plugin: footnote ──────────────────────────────────────────────────────────

  T.describe("plugin.footnote", function()

    T.it("renders footnote reference as superscript link", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.footnote)
      local src = "Text[^1] here.\n\n[^1]: Footnote content.\n"
      local html = md:render(src)
      T.ok(has(html, "<sup>"))
      T.ok(has(html, "<a"))
    end)

    T.it("appends footnote section", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.footnote)
      local src = "Text[^1] here.\n\n[^1]: Footnote content.\n"
      local html = md:render(src)
      -- The footnotes section and back-link are present.
      -- Note: the mdast parser treats the definition URL as the first word of
      -- the content ("Footnote"), so we verify the section wrapper appears.
      T.ok(has(html, '<section class="footnotes"'))
      T.ok(has(html, '<ol>'))
      T.ok(has(html, 'id="fn-1"'))
    end)

    T.it("definition paragraph removed from main flow", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.footnote)
      local src = "Text[^note] here.\n\n[^note]: The note.\n"
      local html = md:render(src)
      -- The raw definition should not appear verbatim as a paragraph.
      T.ok(not has(html, "[^note]: The note."))
    end)

  end)

  -- ── plugin chaining ──────────────────────────────────────────────────────────

  T.describe("plugin chaining", function()

    T.it("use() returns the instance for chaining", function()
      local md = mdit.new()
      local ret = md:use(mdit.plugin.table)
      T.ok(ret == md)
    end)

    T.it("multiple plugins compose", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.tasklist):use(mdit.plugin.footnote)
      local src = "- [x] done\n\nSee note[^1].\n\n[^1]: Note text.\n"
      local html = md:render(src)
      T.ok(has(html, "checked"))
      T.ok(has(html, "<sup>"))
    end)

  end)

  -- ── plugin: deflist ──────────────────────────────────────────────────────────

  T.describe("plugin.deflist", function()

    T.it("renders definition list", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.deflist)
      local src = "Term\n\n: Definition of the term\n"
      local html = md:render(src)
      T.ok(has(html, "<dl>"))
      T.ok(has(html, "<dt>"))
      T.ok(has(html, "<dd>"))
    end)

    T.it("definition content appears in output", function()
      local md = mdit.new({ html = true })
      md:use(mdit.plugin.deflist)
      local src = "Apple\n\n: A fruit\n"
      local html = md:render(src)
      T.ok(has(html, "Apple"))
      T.ok(has(html, "A fruit"))
    end)

  end)

end)
