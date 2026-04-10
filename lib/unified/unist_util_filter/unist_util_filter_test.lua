-- lib/unified/unist_util_filter/unist_util_filter_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local filter = require("lib.unified.unist_util_filter")

-- Sample tree:
--   root
--     paragraph
--       text("keep")
--       comment("remove me")
--       emphasis
--         text("also keep")
--     comment("top-level comment")

local function make_tree()
  return {
    type = "root",
    children = {
      {
        type = "paragraph",
        children = {
          { type = "text", value = "keep" },
          { type = "comment", value = "remove me" },
          {
            type = "emphasis",
            children = {
              { type = "text", value = "also keep" },
            },
          },
        },
      },
      { type = "comment", value = "top-level comment" },
    },
  }
end

T.describe("unist_util_filter", function()
  T.it("returns a new tree (does not mutate original)", function()
    local tree = make_tree()
    local result = filter(tree, "text")
    T.ok(result ~= tree, "should return a new object")
    -- original tree still has 2 children
    T.eq(#tree.children, 2)
  end)

  T.it("keeps nodes that pass the type test and their ancestors", function()
    local tree = make_tree()
    local result = filter(tree, "text")
    T.ok(result ~= nil)
    T.eq(result.type, "root")
    -- paragraph survives because it has text descendants
    T.eq(#result.children, 1)
    T.eq(result.children[1].type, "paragraph")
    -- comment is removed; emphasis survives; paragraph has text + emphasis
    local para = result.children[1]
    T.eq(#para.children, 2)
    T.eq(para.children[1].type, "text")
    T.eq(para.children[2].type, "emphasis")
  end)

  T.it("removes nodes that fail and have no passing descendants", function()
    local tree = make_tree()
    local result = filter(tree, "text")
    -- top-level comment should be gone
    for _, child in ipairs(result.children) do
      T.ok(child.type ~= "comment", "comment should be removed at root level")
    end
  end)

  T.it("returns nil when root fails and has no passing descendants", function()
    local tree = { type = "comment", value = "only node" }
    local result = filter(tree, "text")
    T.eq(result, nil)
  end)

  T.it("works with a function predicate", function()
    local tree = make_tree()
    local result = filter(tree, function(n) return n.type ~= "comment" end)
    T.ok(result ~= nil)
    -- paragraph should still have text + emphasis
    local para = result.children[1]
    T.eq(#para.children, 2)
    for _, child in ipairs(para.children) do
      T.ok(child.type ~= "comment")
    end
  end)

  T.it("keeps the root when it passes even if children are pruned", function()
    local tree = {
      type = "root",
      children = {
        { type = "comment", value = "only child" },
      },
    }
    local result = filter(tree, "root")
    T.ok(result ~= nil)
    T.eq(result.type, "root")
    T.eq(#result.children, 0)
  end)

  T.it("preserves other node fields in the copy", function()
    local tree = {
      type = "root",
      data = { custom = true },
      children = {
        { type = "text", value = "hi" },
      },
    }
    local result = filter(tree, "root")
    T.ok(result ~= nil)
    T.ok(result.data ~= nil)
    T.eq(result.data.custom, true)
  end)
end)
