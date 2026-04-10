-- lib/remark_rehype/remark_rehype_test.lua

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T           = require("lib.test.assert")
local remark      = require("lib.unified.remark")
local remarkRehype = require("lib.unified.remark_rehype")

-- ── Helper ────────────────────────────────────────────────────────────────────

local function pipeline()
  return remark():use(remarkRehype)
end

-- ── Full Markdown→HTML pipeline ───────────────────────────────────────────────

T.describe("remark_rehype: heading", function()
  T.it("h1", function()
    local html = pipeline():process("# Hello")
    T.eq(html, "<h1>Hello</h1>")
  end)

  T.it("h2", function()
    local html = pipeline():process("## Section")
    T.eq(html, "<h2>Section</h2>")
  end)

  T.it("h3", function()
    local html = pipeline():process("### Sub")
    T.eq(html, "<h3>Sub</h3>")
  end)
end)

T.describe("remark_rehype: paragraph", function()
  T.it("simple paragraph", function()
    local html = pipeline():process("Hello world.")
    T.eq(html, "<p>Hello world.</p>")
  end)

  T.it("multiple paragraphs", function()
    local html = pipeline():process("First.\n\nSecond.")
    T.eq(html, "<p>First.</p><p>Second.</p>")
  end)
end)

T.describe("remark_rehype: inline formatting", function()
  T.it("bold", function()
    local html = pipeline():process("**bold**")
    T.eq(html, "<p><strong>bold</strong></p>")
  end)

  T.it("italic", function()
    local html = pipeline():process("*italic*")
    T.eq(html, "<p><em>italic</em></p>")
  end)

  T.it("inline code", function()
    local html = pipeline():process("`code`")
    T.eq(html, "<p><code>code</code></p>")
  end)
end)

T.describe("remark_rehype: links", function()
  T.it("bare link", function()
    local html = pipeline():process("[Click](https://example.com)")
    T.eq(html, '<p><a href="https://example.com">Click</a></p>')
  end)

  T.it("link with title", function()
    local html = pipeline():process('[Click](https://example.com "My title")')
    T.eq(html, '<p><a href="https://example.com" title="My title">Click</a></p>')
  end)
end)

T.describe("remark_rehype: lists", function()
  T.it("unordered list", function()
    local html = pipeline():process("- one\n- two\n- three")
    T.eq(html, "<ul><li><p>one</p></li><li><p>two</p></li><li><p>three</p></li></ul>")
  end)

  T.it("ordered list", function()
    local html = pipeline():process("1. first\n2. second")
    T.eq(html, "<ol><li><p>first</p></li><li><p>second</p></li></ol>")
  end)
end)

T.describe("remark_rehype: code blocks", function()
  T.it("fenced code block with lang", function()
    local html = pipeline():process("```lua\nreturn 1\n```")
    T.eq(html, '<pre><code class="language-lua">return 1</code></pre>')
  end)

  T.it("fenced code block without lang", function()
    local html = pipeline():process("```\nhello\n```")
    T.eq(html, "<pre><code>hello</code></pre>")
  end)
end)

-- ── Transformer output is hast ────────────────────────────────────────────────

T.describe("remark_rehype: hast tree shape", function()
  T.it("transformer produces hast root", function()
    local proc = remark():use(remarkRehype, { no_stringify = true })
    -- With no_stringify the compiler is the remark one (mdast→md); we only
    -- want to inspect the intermediate tree so we use parse+run directly.
    local ast = proc:parse("# Hi")
    local hast_tree = proc:run(ast)
    T.eq(hast_tree.type, "root")
  end)

  T.it("children are hast elements with type='element'", function()
    local proc = remark():use(remarkRehype, { no_stringify = true })
    local ast = proc:parse("# Hi")
    local hast_tree = proc:run(ast)
    T.ok(hast_tree.children and #hast_tree.children >= 1, "has children")
    T.eq(hast_tree.children[1].type, "element")
  end)

  T.it("heading maps to correct tag", function()
    local proc = remark():use(remarkRehype, { no_stringify = true })
    local ast = proc:parse("## Section")
    local hast_tree = proc:run(ast)
    T.eq(hast_tree.children[1].tag, "h2")
  end)
end)

-- ── Additional rehype transformers compose ────────────────────────────────────

T.describe("remark_rehype: composability", function()
  T.it("rehype transformers run after the bridge", function()
    -- Add a transformer that wraps the root's children in a <div>.
    local proc = remark()
      :use(remarkRehype, { no_stringify = true })
      :use(function(processor)
        processor:use_transformer(function(tree)
          -- Wrap every top-level element in a <div class="wrap">.
          local wrapped = {}
          for i, child in ipairs(tree.children or {}) do
            wrapped[i] = { type = "element", tag = "div",
                           props = { class = "wrap" }, children = { child } }
          end
          tree.children = wrapped
          return tree
        end)
        -- Re-register a compiler so process() works.
        local hast = require("lib.unified.hast")
        processor:compiler(function(ast)
          return hast.to_html(ast)
        end)
      end)

    local html = proc:process("# Hello")
    T.eq(html, '<div class="wrap"><h1>Hello</h1></div>')
  end)

  T.it("stringify_plugin can be used as a separate plugin", function()
    local proc = remark()
      :use(remarkRehype, { no_stringify = true })
      :use(remarkRehype.stringify_plugin)
    local html = proc:process("World")
    T.eq(html, "<p>World</p>")
  end)
end)

-- ── Module is callable as a plugin directly ───────────────────────────────────

T.describe("remark_rehype: module callable", function()
  T.it("remarkRehype used directly via :use() works", function()
    -- remarkRehype module is callable, so :use(remarkRehype) should work.
    local proc = remark():use(remarkRehype)
    local html = proc:process("**bold**")
    T.eq(html, "<p><strong>bold</strong></p>")
  end)
end)
