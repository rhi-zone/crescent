-- lib/unified/unist_util_find/unist_util_find_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local find = require("lib.unified.unist_util_find")

-- Sample tree:
--   root
--     paragraph
--       text("hello")
--       emphasis
--         text("world")
--     blockquote
--       text("bye")

local tree = {
  type = "root",
  children = {
    {
      type = "paragraph",
      children = {
        { type = "text", value = "hello" },
        {
          type = "emphasis",
          children = {
            { type = "text", value = "world" },
          },
        },
      },
    },
    {
      type = "blockquote",
      children = {
        { type = "text", value = "bye" },
      },
    },
  },
}

T.describe("unist_util_find", function()
  T.it("finds root by type string", function()
    local node = find(tree, "root")
    T.ok(node ~= nil, "should find root")
    T.eq(node.type, "root")
  end)

  T.it("finds first text node (depth-first pre-order)", function()
    local node = find(tree, "text")
    T.ok(node ~= nil, "should find a text node")
    T.eq(node.value, "hello")
  end)

  T.it("finds node by function predicate", function()
    local node = find(tree, function(n) return n.value == "world" end)
    T.ok(node ~= nil, "should find node with value 'world'")
    T.eq(node.type, "text")
    T.eq(node.value, "world")
  end)

  T.it("returns nil when not found by type", function()
    local node = find(tree, "heading")
    T.eq(node, nil)
  end)

  T.it("returns nil when predicate matches nothing", function()
    local node = find(tree, function(n) return n.value == "missing" end)
    T.eq(node, nil)
  end)

  T.it("finds deeply nested node", function()
    local node = find(tree, "emphasis")
    T.ok(node ~= nil)
    T.eq(node.type, "emphasis")
  end)

  T.it("finds blockquote", function()
    local node = find(tree, "blockquote")
    T.ok(node ~= nil)
    T.eq(node.type, "blockquote")
  end)
end)
