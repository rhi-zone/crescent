-- lib/unified/unist_util_remove/init.lua
-- Removes nodes matching a test from a tree in-place.
-- Port of https://github.com/syntax-tree/unist-util-remove
--
-- Usage:
--   local remove = require("lib.unified.unist_util_remove")
--   remove(tree, "comment")
--   remove(tree, function(node) return node.type == "comment" end)
--
-- Mutates the tree directly. Returns the modified tree, or nil if the root
-- itself matches the test.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local visit = require("lib.unified.unist_util_visit") --[[: unknown]]

local M = {}

-- Returns a predicate from a string type name or function.
--:: UnistNode = { type: string, ... }
--: (string | (UnistNode) -> boolean) -> (UnistNode) -> boolean
local function make_test(spec)
  if type(spec) == "string" then
    local t = spec
    return function(node) return node.type == t end
  else
    return spec --[[:! (UnistNode) -> boolean]]
  end
end

-- remove(tree, test) -> tree | nil
setmetatable(M, {
  __call = function(_, tree, spec)
    local test = make_test(spec)

    -- Check if root itself matches.
    if test(tree) then
      return nil
    end

    visit(tree, function(node)
      if test(node) then
        return visit.REMOVE
      end
    end)

    return tree
  end,
})

return M
