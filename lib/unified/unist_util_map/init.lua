-- lib/unified/unist_util_map/init.lua
-- Returns a new tree by applying a mapper function to every node.
-- Port of https://github.com/syntax-tree/unist-util-map
--
-- Usage:
--   local map = require("lib.unified.unist_util_map")
--   local new_tree = map(tree, function(node)
--     if node.type == "text" then
--       return { type = "text", value = node.value:upper() }
--     end
--     return node
--   end)
--
-- The mapper receives each node and returns a replacement. The returned node's
-- children (if any) are then recursively mapped. Returning a node without
-- children stops recursion for that subtree.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- map_node(node, mapper) -> new_node
local function map_node(node, mapper)
  -- Apply mapper to this node first (pre-order replacement).
  local mapped = mapper(node)

  -- If the mapped node has children, recursively map them.
  if mapped.children then
    local new_children = {}
    for i = 1, #mapped.children do
      new_children[i] = map_node(mapped.children[i], mapper)
    end
    -- Shallow-copy mapped and replace children.
    local result = {}
    for k, v in pairs(mapped) do
      result[k] = v
    end
    result.children = new_children
    return result
  end

  return mapped
end

-- map(tree, mapper) -> new_tree
setmetatable(M, {
  __call = function(_, tree, mapper)
    return map_node(tree, mapper)
  end,
})

return M
