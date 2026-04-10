-- lib/rehype_infer_title/init.lua
-- rehype plugin: infer document title from first h1–h6 heading.
-- Port of rehype-infer-title.
--
-- After the transformer runs, stores the inferred title on the AST root:
--   root.data.title = "My Page Title"
--
-- If no heading is found, root.data.title is left unset.
--
-- Usage:
--   local rehype      = require("lib.unified.rehype")
--   local inferTitle  = require("lib.unified.rehype_infer_title")
--   local processor   = rehype():use(inferTitle)
--   local ast         = processor:parse(html)
--   ast = processor:run(ast)
--   -- ast.data.title == "My Page Title"

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADING = { h1=true, h2=true, h3=true, h4=true, h5=true, h6=true }

--: (any, any) -> nil
local function collect_text(node, parts)
  if node.type == "text" then
    parts[#parts + 1] = node.value or ""
  elseif node.children then
    for _, child in ipairs(node.children) do
      collect_text(child, parts)
    end
  end
end

--: (any) -> string
local function text_content(node)
  local parts = {}
  collect_text(node, parts)
  return table.concat(parts)
end

-- Depth-first search for the first heading element.
--: (any) -> any
local function find_first_heading(node)
  if node.type == "element" and HEADING[node.tag] then
    return node
  end
  if node.children then
    for _, child in ipairs(node.children) do
      local found = find_first_heading(child)
      if found then return found end
    end
  end
  return nil
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, _opts)
  processor:use_transformer(function(tree)
    local heading = find_first_heading(tree)
    if heading then
      local title = text_content(heading)
      if title ~= "" then
        tree.data = tree.data or {}
        tree.data.title = title
      end
    end
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
