-- lib/unified/rehype_remove_comments/rehype_remove_comments_test.lua
local T      = require("lib.test.assert")
local rehype = require("lib.unified.rehype")
local plugin = require("lib.unified.rehype_remove_comments")

-- Build a simple hast tree with comments.
local function make_tree()
  return {
    type = "root",
    children = {
      { type = "element", tag = "div", props = {}, children = {
          { type = "comment", value = "hello" },
          { type = "text", value = "world" },
        }
      },
      { type = "comment", value = "top-level comment" },
    },
  }
end

local function count_type(node, t)
  local n = 0
  if node.type == t then n = n + 1 end
  if node.children then
    for _, child in ipairs(node.children) do
      n = n + count_type(child, t)
    end
  end
  return n
end

T.describe("rehype_remove_comments", function()
  T.it("removes all comment nodes", function()
    local proc = rehype():use(plugin.plugin)
    local tree = make_tree()
    tree = proc:run(tree)
    T.eq(count_type(tree, "comment"), 0, "no comment nodes remain")
  end)

  T.it("preserves non-comment nodes", function()
    local proc = rehype():use(plugin.plugin)
    local tree = make_tree()
    tree = proc:run(tree)
    T.eq(count_type(tree, "text"), 1, "text node preserved")
    T.eq(count_type(tree, "element"), 1, "element node preserved")
  end)

  T.it("opts.preserve keeps matching comments", function()
    local proc = rehype():use(function(processor)
      plugin.plugin(processor, {
        preserve = function(node) return node.value:sub(1, 1) == "!" end
      })
    end)
    local tree = {
      type = "root",
      children = {
        { type = "comment", value = "!important" },
        { type = "comment", value = "remove me" },
      },
    }
    tree = proc:run(tree)
    T.eq(count_type(tree, "comment"), 1, "preserved comment kept")
    T.eq(tree.children[1].value, "!important", "correct comment kept")
  end)

  T.it("works on a tree with no comments", function()
    local proc = rehype():use(plugin.plugin)
    local tree = {
      type = "root",
      children = {
        { type = "element", tag = "p", props = {}, children = {
            { type = "text", value = "hello" },
          }
        },
      },
    }
    tree = proc:run(tree)
    T.eq(count_type(tree, "element"), 1, "element intact")
    T.eq(count_type(tree, "text"), 1, "text intact")
  end)
end)
