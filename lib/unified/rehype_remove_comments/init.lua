-- lib/unified/rehype_remove_comments/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- rehype_remove_comments: removes HTML comment nodes from a hast tree.
-- Port of rehype-remove-comments (https://github.com/rehypejs/rehype-remove-comments).
--
-- Options:
--   opts.preserve — function(node)->boolean; if true, keep the comment node.
--
-- Uses unist_util_remove to mutate the tree in-place.

local remove = require("lib.unified.unist_util_remove")

local M = {}

local function transformer(tree, opts)
  opts = opts or {}
  local preserve = opts.preserve

  if preserve then
    -- Use the visit module directly so we can honour the preserve callback.
    local visit_mod = require("lib.unified.unist_util_visit")
    local visit = visit_mod --[[: any]]
    visit(tree, "comment", function(node)
      if not preserve(node) then
        return visit_mod.REMOVE
      end
    end)
  else
    local remove_fn = remove --[[: any]]
    remove_fn(tree, "comment")
  end

  return tree
end

function M.plugin(processor, opts)
  processor:use_transformer(function(tree)
    return transformer(tree, opts)
  end)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
