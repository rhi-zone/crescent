-- lib/unified/unist_util_map/unist_util_map_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local map = require("lib.unified.unist_util_map")

-- Sample tree:
--   root
--     paragraph
--       text("hello")
--       emphasis
--         text("world")

local function make_tree()
  return {
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
    },
  }
end

T.describe("unist_util_map", function()
  T.it("returns a new tree, does not mutate original", function()
    local tree = make_tree()
    local result = map(tree, function(n) return n end)
    T.ok(result ~= tree, "root should be a new object")
    -- original unchanged
    T.eq(tree.children[1].children[1].value, "hello")
  end)

  T.it("maps text node values", function()
    local tree = make_tree()
    local result = map(tree, function(n)
      if n.type == "text" then
        return { type = "text", value = n.value:upper() }
      end
      return n
    end)
    local para = result.children[1]
    T.eq(para.children[1].value, "HELLO")
    T.eq(para.children[2].children[1].value, "WORLD")
  end)

  T.it("preserves tree structure when mapper returns node unchanged", function()
    local tree = make_tree()
    local result = map(tree, function(n) return n end)
    T.eq(result.type, "root")
    T.eq(#result.children, 1)
    T.eq(result.children[1].type, "paragraph")
    T.eq(#result.children[1].children, 2)
  end)

  T.it("replaces a node type", function()
    local tree = make_tree()
    local result = map(tree, function(n)
      if n.type == "emphasis" then
        return { type = "strong", children = n.children }
      end
      return n
    end)
    local para = result.children[1]
    T.eq(para.children[2].type, "strong")
    -- child text node should still be mapped
    T.eq(para.children[2].children[1].type, "text")
  end)

  T.it("stopping recursion by returning node without children", function()
    local tree = make_tree()
    local visited = {}
    map(tree, function(n)
      visited[n.type] = (visited[n.type] or 0) + 1
      if n.type == "emphasis" then
        -- return a leaf; children should NOT be visited
        return { type = "leaf_emphasis" }
      end
      return n
    end)
    -- emphasis children (text "world") should not be visited
    T.eq(visited["text"], 1)  -- only "hello"
    T.eq(visited["emphasis"], 1)
  end)

  T.it("maps the root node itself", function()
    local tree = make_tree()
    local result = map(tree, function(n)
      if n.type == "root" then
        local copy = {}
        for k, v in pairs(n) do copy[k] = v end
        copy.mapped = true
        return copy
      end
      return n
    end)
    T.eq(result.mapped, true)
  end)

  T.it("works on leaf-only trees", function()
    local leaf = { type = "text", value = "hi" }
    local result = map(leaf, function(n)
      return { type = n.type, value = n.value .. "!" }
    end)
    T.eq(result.value, "hi!")
  end)
end)
