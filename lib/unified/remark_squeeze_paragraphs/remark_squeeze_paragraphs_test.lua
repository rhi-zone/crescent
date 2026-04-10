-- lib/unified/remark_squeeze_paragraphs/remark_squeeze_paragraphs_test.lua
-- Tests for the remark_squeeze_paragraphs plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local remark  = require("lib.unified.remark")
local squeeze = require("lib.unified.remark_squeeze_paragraphs")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function make_para(children)
  return { type = "paragraph", children = children or {} }
end

local function make_text(v)
  return { type = "text", value = v }
end

local function run(ast)
  local p = remark():use(squeeze)
  return p:run(ast)
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("remark_squeeze_paragraphs: empty paragraph removal", function()
  T.it("paragraph with no children is removed", function()
    local ast = {
      type = "root",
      children = {
        make_para({}),
        { type = "heading", depth = 1, children = { make_text("Title") } },
      },
    }
    local result = run(ast)
    T.eq(#result.children, 1)
    T.eq(result.children[1].type, "heading")
  end)

  T.it("paragraph with only whitespace text is removed", function()
    local ast = {
      type = "root",
      children = {
        make_para({ make_text("   \t\n  ") }),
        make_para({ make_text("Hello") }),
      },
    }
    local result = run(ast)
    T.eq(#result.children, 1)
    T.eq(result.children[1].children[1].value, "Hello")
  end)

  T.it("non-empty paragraph is kept", function()
    local ast = {
      type = "root",
      children = {
        make_para({ make_text("Keep me.") }),
      },
    }
    local result = run(ast)
    T.eq(#result.children, 1)
    T.eq(result.children[1].type, "paragraph")
  end)

  T.it("multiple empty paragraphs all removed", function()
    local ast = {
      type = "root",
      children = {
        make_para({}),
        make_para({ make_text("") }),
        make_para({ make_text("  ") }),
        make_para({ make_text("real content") }),
        make_para({}),
      },
    }
    local result = run(ast)
    T.eq(#result.children, 1)
    T.eq(result.children[1].children[1].value, "real content")
  end)

  T.it("paragraph with non-text child is not removed", function()
    local ast = {
      type = "root",
      children = {
        make_para({ { type = "inlineCode", value = "x" } }),
      },
    }
    local result = run(ast)
    T.eq(#result.children, 1)
    T.eq(result.children[1].type, "paragraph")
  end)
end)

T.describe("remark_squeeze_paragraphs: nested containers", function()
  T.it("empty paragraph inside blockquote is removed", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "blockquote",
          children = {
            make_para({}),
            make_para({ make_text("quoted text") }),
          },
        },
      },
    }
    local result = run(ast)
    local bq = result.children[1]
    T.eq(bq.type, "blockquote")
    T.eq(#bq.children, 1)
    T.eq(bq.children[1].children[1].value, "quoted text")
  end)

  T.it("empty paragraph inside listItem is removed", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "list",
          ordered = false,
          children = {
            {
              type = "listItem",
              children = {
                make_para({}),
                make_para({ make_text("item text") }),
              },
            },
          },
        },
      },
    }
    local result = run(ast)
    local item = result.children[1].children[1]
    T.eq(item.type, "listItem")
    T.eq(#item.children, 1)
    T.eq(item.children[1].children[1].value, "item text")
  end)

  T.it("root with only empty paragraphs ends up with no children", function()
    local ast = {
      type = "root",
      children = {
        make_para({}),
        make_para({ make_text("") }),
      },
    }
    local result = run(ast)
    T.eq(#result.children, 0)
  end)
end)
