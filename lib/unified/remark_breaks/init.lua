-- lib/unified/remark_breaks/init.lua
-- remark plugin that converts soft line breaks to hard breaks, mirroring
-- GitHub's behaviour where a single newline in Markdown source becomes a <br>.
--
-- Usage:
--   local remark = require("lib.unified.remark")
--   local breaks = require("lib.unified.remark_breaks")
--
--   local processor = remark():use(breaks)
--   local ast       = processor:parse("line one\nline two")
--   -- softBreak nodes are now hardBreak nodes in the tree

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Tree walker ───────────────────────────────────────────────────────────────

local function walk(node, fn)
  fn(node)
  local children = node.children
  if children then
    for i = 1, #children do
      walk(children[i], fn)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_breaks(processor, _opts)
  processor:use_transformer(function(ast)
    walk(ast, function(node)
      local children = node.children
      if not children then return end
      for i = 1, #children do
        if children[i].type == "softBreak" then
          children[i] = { type = "hardBreak" }
        end
      end
    end)
    return ast
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_breaks(...) end })

M.plugin = remark_breaks

return M
