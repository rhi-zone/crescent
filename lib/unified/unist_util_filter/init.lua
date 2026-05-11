-- lib/unified/unist_util_filter/init.lua
-- Returns a copy of the tree containing only nodes that pass the test (and
-- their ancestors). Nodes that fail and have no passing descendants are removed.
-- Port of https://github.com/syntax-tree/unist-util-filter
--
-- Usage:
--   local filter = require("lib.unified.unist_util_filter")
--   local filtered = filter(tree, "text")
--   local filtered = filter(tree, function(node) return node.type ~= "comment" end)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

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

-- Shallow-copy a node, then give it a new children array (or none).
--: (UnistNode, UnistNode[] | nil) -> UnistNode
local function copy_node(node, new_children)
  local copy = {}
  local node_map = node --[[:! { [string]: any }]]
  for k, v in pairs(node_map) do
    copy[k] = v
  end
  if new_children ~= nil then
    copy.children = new_children
  else
    local copy_any = copy --[[: unknown]]
    copy_any.children = nil
  end
  return copy
end

-- filter_node(node, test) -> node | nil
-- Returns a copy of the subtree that passes the test, or nil if pruned.
local function filter_node(node, test)
  local passes = test(node)

  if node.children then
    -- Recursively filter children first.
    local new_children = {}
    for i = 1, #node.children do
      local child_result = filter_node(node.children[i], test)
      if child_result ~= nil then
        new_children[#new_children + 1] = child_result
      end
    end

    if passes or #new_children > 0 then
      return copy_node(node, new_children)
    else
      return nil
    end
  else
    -- Leaf node: keep only if it passes.
    if passes then
      return copy_node(node, nil)
    else
      return nil
    end
  end
end

-- filter(tree, test) -> tree | nil
setmetatable(M, {
  __call = function(_, tree, spec)
    local test = make_test(spec)
    return filter_node(tree, test)
  end,
})

return M
