-- lib/unified/remark_breaks/remark_breaks_test.lua
-- Tests for the remark_breaks plugin.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remark = require("lib.unified.remark")
local breaks = require("lib.unified.remark_breaks")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local proc = remark():use(breaks)

local function parse_and_run(src)
  local ast, err = proc:parse(src)
  assert(ast, err)
  return proc:run(ast)
end

-- Recursively collect all node types from the tree.
local function collect_types(node, out)
  out = out or {}
  out[#out + 1] = node.type
  local children = node.children
  if children then
    for i = 1, #children do
      collect_types(children[i], out)
    end
  end
  return out
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("remark_breaks: soft → hard break conversion", function()
  T.it("softBreak node becomes hardBreak after transform", function()
    -- Build a minimal AST containing a softBreak directly.
    local ast = {
      type = "root",
      children = {
        {
          type = "paragraph",
          children = {
            { type = "text", value = "line one" },
            { type = "softBreak" },
            { type = "text", value = "line two" },
          },
        },
      },
    }
    -- Run the transformer directly via a fresh processor.
    local p = remark():use(breaks)
    local result = p:run(ast)
    local para = result.children[1]
    T.eq(para.children[2].type, "hardBreak")
  end)

  T.it("no softBreak remains after transform", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "paragraph",
          children = {
            { type = "text",      value = "a" },
            { type = "softBreak" },
            { type = "text",      value = "b" },
            { type = "softBreak" },
            { type = "text",      value = "c" },
          },
        },
      },
    }
    local p = remark():use(breaks)
    local result = p:run(ast)
    local types = collect_types(result)
    for i = 1, #types do
      T.ok(types[i] ~= "softBreak", "no softBreak in transformed tree")
    end
  end)

  T.it("hardBreak nodes are unchanged", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "paragraph",
          children = {
            { type = "text",      value = "x" },
            { type = "hardBreak" },
            { type = "text",      value = "y" },
          },
        },
      },
    }
    local p = remark():use(breaks)
    local result = p:run(ast)
    local para = result.children[1]
    T.eq(para.children[2].type, "hardBreak")
    T.eq(para.children[1].value, "x")
    T.eq(para.children[3].value, "y")
  end)

  T.it("text and other node types are not affected", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "paragraph",
          children = {
            { type = "text",       value = "hello" },
            { type = "inlineCode", value = "world" },
          },
        },
      },
    }
    local p = remark():use(breaks)
    local result = p:run(ast)
    local para = result.children[1]
    T.eq(para.children[1].type, "text")
    T.eq(para.children[1].value, "hello")
    T.eq(para.children[2].type, "inlineCode")
    T.eq(para.children[2].value, "world")
  end)

  T.it("nested nodes are walked (softBreak inside blockquote paragraph)", function()
    local ast = {
      type = "root",
      children = {
        {
          type = "blockquote",
          children = {
            {
              type = "paragraph",
              children = {
                { type = "text",      value = "q" },
                { type = "softBreak" },
                { type = "text",      value = "r" },
              },
            },
          },
        },
      },
    }
    local p = remark():use(breaks)
    local result = p:run(ast)
    local inner = result.children[1].children[1]
    T.eq(inner.children[2].type, "hardBreak")
  end)
end)
