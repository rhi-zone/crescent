-- lib/remark/remark_test.lua
-- Tests for the remark Markdown processing preset.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remark = require("lib.remark")

-- ── Factory ───────────────────────────────────────────────────────────────────

T.describe("remark factory", function()
  T.it("remark() returns a processor", function()
    local p = remark()
    T.ok(type(p) == "table", "processor is a table")
    T.ok(type(p.parse) == "function", "processor has :parse")
    T.ok(type(p.process) == "function", "processor has :process")
  end)

  T.it("module is callable as remark()", function()
    -- The module metatable __call mirrors M.new.
    local p = remark()
    T.ok(p ~= nil)
  end)

  T.it("returned processor is frozen", function()
    local p = remark()
    T.ok(p._frozen, "processor is frozen after remark()")
  end)
end)

-- ── parse() ───────────────────────────────────────────────────────────────────

T.describe("remark:parse", function()
  local p = remark()

  T.it("returns a root node", function()
    local ast = p:parse("# Hello\n\nWorld.")
    T.eq(ast.type, "root")
    T.ok(type(ast.children) == "table")
  end)

  T.it("parses heading correctly", function()
    local ast = p:parse("# Title")
    local h   = ast.children[1]
    T.eq(h.type, "heading")
    T.eq(h.depth, 1)
    T.eq(h.children[1].value, "Title")
  end)

  T.it("parses paragraph correctly", function()
    local ast = p:parse("Hello world")
    local par = ast.children[1]
    T.eq(par.type, "paragraph")
    T.eq(par.children[1].value, "Hello world")
  end)

  T.it("parses emphasis", function()
    local ast  = p:parse("*em*")
    local par  = ast.children[1]
    local node = par.children[1]
    T.eq(node.type, "emphasis")
    T.eq(node.children[1].value, "em")
  end)

  T.it("parses strong", function()
    local ast  = p:parse("**bold**")
    local par  = ast.children[1]
    local node = par.children[1]
    T.eq(node.type, "strong")
    T.eq(node.children[1].value, "bold")
  end)
end)

-- ── stringify (mdast_to_md) ───────────────────────────────────────────────────

T.describe("mdast_to_md", function()
  local to_md = remark.mdast_to_md

  T.it("heading", function()
    local ast = { type = "heading", depth = 2, children = { { type = "text", value = "Hi" } } }
    T.eq(to_md(ast), "## Hi")
  end)

  T.it("paragraph with text", function()
    local ast = { type = "paragraph", children = { { type = "text", value = "hello" } } }
    T.eq(to_md(ast), "hello")
  end)

  T.it("emphasis", function()
    local ast = { type = "emphasis", children = { { type = "text", value = "em" } } }
    T.eq(to_md(ast), "*em*")
  end)

  T.it("strong", function()
    local ast = { type = "strong", children = { { type = "text", value = "bold" } } }
    T.eq(to_md(ast), "**bold**")
  end)

  T.it("inlineCode", function()
    local ast = { type = "inlineCode", value = "x = 1" }
    T.eq(to_md(ast), "`x = 1`")
  end)

  T.it("code block with lang", function()
    local ast = { type = "code", lang = "lua", value = "return 42" }
    T.eq(to_md(ast), "```lua\nreturn 42\n```")
  end)

  T.it("code block without lang", function()
    local ast = { type = "code", lang = nil, value = "plain" }
    T.eq(to_md(ast), "```\nplain\n```")
  end)

  T.it("thematicBreak", function()
    T.eq(to_md({ type = "thematicBreak" }), "---")
  end)

  T.it("hardBreak", function()
    T.eq(to_md({ type = "hardBreak" }), "  \n")
  end)

  T.it("softBreak", function()
    T.eq(to_md({ type = "softBreak" }), "\n")
  end)

  T.it("link", function()
    local ast = {
      type = "link", url = "https://example.com", title = nil,
      children = { { type = "text", value = "click" } }
    }
    T.eq(to_md(ast), "[click](https://example.com)")
  end)

  T.it("link with title", function()
    local ast = {
      type = "link", url = "https://example.com", title = "Example",
      children = { { type = "text", value = "click" } }
    }
    T.eq(to_md(ast), '[click](https://example.com "Example")')
  end)

  T.it("image", function()
    local ast = {
      type = "image", url = "img.png", alt = "alt text", title = nil,
      children = {}
    }
    T.eq(to_md(ast), "![alt text](img.png)")
  end)

  T.it("blockquote", function()
    local ast = {
      type = "blockquote",
      children = {
        { type = "paragraph", children = { { type = "text", value = "quoted" } } }
      }
    }
    T.eq(to_md(ast), "> quoted")
  end)

  T.it("unordered list", function()
    local ast = {
      type = "list", ordered = false,
      children = {
        { type = "listItem", children = { { type = "paragraph", children = { { type = "text", value = "a" } } } } },
        { type = "listItem", children = { { type = "paragraph", children = { { type = "text", value = "b" } } } } },
      }
    }
    T.eq(to_md(ast), "- a\n- b")
  end)

  T.it("ordered list", function()
    local ast = {
      type = "list", ordered = true, start = 1,
      children = {
        { type = "listItem", children = { { type = "paragraph", children = { { type = "text", value = "first" } } } } },
        { type = "listItem", children = { { type = "paragraph", children = { { type = "text", value = "second" } } } } },
      }
    }
    T.eq(to_md(ast), "1. first\n2. second")
  end)

  T.it("root joins blocks with double newline", function()
    local ast = {
      type = "root",
      children = {
        { type = "heading", depth = 1, children = { { type = "text", value = "Title" } } },
        { type = "paragraph", children = { { type = "text", value = "Body." } } },
      }
    }
    T.eq(to_md(ast), "# Title\n\nBody.")
  end)

  T.it("unknown node type returns empty string", function()
    T.eq(to_md({ type = "unknownFutureThing" }), "")
  end)
end)

-- ── process() ────────────────────────────────────────────────────────────────

T.describe("remark:process", function()
  local p = remark()

  T.it("returns a string", function()
    local out, err = p:process("# Hello\n\nWorld.")
    T.eq(err, nil)
    T.ok(type(out) == "string", "process returns string")
  end)

  T.it("heading is preserved through round-trip", function()
    local out = p:process("# My Title")
    T.ok(out:find("# My Title"), "heading survives round-trip: " .. tostring(out))
  end)

  T.it("paragraph text is preserved", function()
    local out = p:process("Hello world.")
    T.ok(out:find("Hello world%."), "paragraph survives round-trip: " .. tostring(out))
  end)

  T.it("emphasis is preserved", function()
    local out = p:process("*italic*")
    T.ok(out:find("%*italic%*"), "emphasis survives round-trip: " .. tostring(out))
  end)

  T.it("strong is preserved", function()
    local out = p:process("**bold**")
    T.ok(out:find("%*%*bold%*%*"), "strong survives round-trip: " .. tostring(out))
  end)

  T.it("code block is preserved", function()
    local out = p:process("```lua\nreturn 42\n```")
    T.ok(out:find("return 42"), "code content survives round-trip")
    T.ok(out:find("```"), "fences survive round-trip")
  end)

  T.it("thematic break is preserved", function()
    local out = p:process("---")
    T.ok(out:find("%-%-%-"), "thematic break survives: " .. tostring(out))
  end)

  T.it("complex document round-trip", function()
    local src = "# Title\n\nParagraph with *em* and **strong**.\n\n- item a\n- item b"
    local out, err = p:process(src)
    T.eq(err, nil)
    T.ok(out:find("# Title"))
    T.ok(out:find("%*em%*"))
    T.ok(out:find("%*%*strong%*%*"))
    T.ok(out:find("item a"))
    T.ok(out:find("item b"))
  end)
end)

-- ── :use() on cloned processor ────────────────────────────────────────────────

T.describe("remark:use (transformer extension)", function()
  T.it("additional transformer can be added via :use on a frozen processor", function()
    local base = remark()
    -- :use on a frozen processor clones first, so base is unmodified.
    local uppercased = base:use(function(processor)
      processor:use_transformer(function(ast)
        -- Walk and uppercase all text node values.
        local function walk(node)
          if node.type == "text" then
            node.value = node.value:upper()
          end
          if node.children then
            for _, child in ipairs(node.children) do walk(child) end
          end
        end
        walk(ast)
        return ast
      end)
    end)

    local out, err = uppercased:process("hello world")
    T.eq(err, nil)
    T.ok(out:find("HELLO WORLD"), "transformer applied: " .. tostring(out))

    -- Base processor is unmodified.
    local base_out = base:process("hello world")
    T.ok(base_out:find("hello world"), "base processor unchanged: " .. tostring(base_out))
  end)

  T.it("multiple transformers run in registration order", function()
    local p = remark():use(function(processor)
      processor:use_transformer(function(ast)
        local function walk(node)
          if node.type == "text" then node.value = node.value .. "!" end
          if node.children then for _, c in ipairs(node.children) do walk(c) end end
        end
        walk(ast)
        return ast
      end)
    end):use(function(processor)
      processor:use_transformer(function(ast)
        local function walk(node)
          if node.type == "text" then node.value = node.value:upper() end
          if node.children then for _, c in ipairs(node.children) do walk(c) end end
        end
        walk(ast)
        return ast
      end)
    end)

    local out, err = p:process("hi")
    T.eq(err, nil)
    -- First transformer appends "!", second uppercases → "HI!"
    T.ok(out:find("HI!"), "transformers run in order: " .. tostring(out))
  end)
end)
