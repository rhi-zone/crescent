-- lib/unified/unist_util_remove/unist_util_remove_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local remove = require("lib.unified.unist_util_remove")

-- Sample tree:
--   root
--     paragraph
--       text("keep")
--       comment("remove me")
--       emphasis
--         text("also keep")
--         comment("nested remove")
--     comment("top-level")

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
              { type = "comment", value = "nested remove" },
            },
          },
        },
      },
      { type = "comment", value = "top-level" },
    },
  }
end

T.describe("unist_util_remove", function()
  T.it("removes nodes by type string in-place", function()
    local tree = make_tree()
    local result = remove(tree, "comment")
    T.ok(result == tree, "should return the same tree object")
    -- top-level comment gone
    T.eq(#tree.children, 1)
    T.eq(tree.children[1].type, "paragraph")
    -- paragraph comment gone, emphasis remains
    local para = tree.children[1]
    T.eq(#para.children, 2)
    T.eq(para.children[1].type, "text")
    T.eq(para.children[2].type, "emphasis")
    -- nested comment inside emphasis gone
    local em = para.children[2]
    T.eq(#em.children, 1)
    T.eq(em.children[1].type, "text")
  end)

  T.it("removes nodes by function predicate", function()
    local tree = make_tree()
    remove(tree, function(n) return n.type == "comment" end)
    T.eq(#tree.children, 1)
    local para = tree.children[1]
    -- only text and emphasis remain
    T.eq(#para.children, 2)
  end)

  T.it("returns nil when root matches", function()
    local tree = { type = "comment", value = "only node" }
    local result = remove(tree, "comment")
    T.eq(result, nil)
  end)

  T.it("returns tree unchanged when nothing matches", function()
    local tree = make_tree()
    local result = remove(tree, "heading")
    T.ok(result == tree)
    T.eq(#tree.children, 2)
  end)

  T.it("preserves non-matching siblings after removal", function()
    local tree = {
      type = "root",
      children = {
        { type = "comment", value = "first" },
        { type = "text", value = "middle" },
        { type = "comment", value = "last" },
        { type = "text", value = "end" },
      },
    }
    remove(tree, "comment")
    T.eq(#tree.children, 2)
    T.eq(tree.children[1].value, "middle")
    T.eq(tree.children[2].value, "end")
  end)

  T.it("mutates in place (original reference is modified)", function()
    local para = {
      type = "paragraph",
      children = {
        { type = "text", value = "hi" },
        { type = "comment", value = "bye" },
      },
    }
    local tree = { type = "root", children = { para } }
    remove(tree, "comment")
    -- para is the same table object, now with one child
    T.eq(#para.children, 1)
    T.eq(para.children[1].type, "text")
  end)
end)
