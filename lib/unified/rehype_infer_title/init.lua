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

--:: HastNode = { type: string, tag?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, value?: string, data?: { [string]: unknown }, ... }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADING = { h1=true, h2=true, h3=true, h4=true, h5=true, h6=true }

--: (HastNode, { [integer]: string }) -> nil
local function collect_text(node, parts)
  if node.type == "text" then
    parts[#parts + 1] = (node.value or "")
  elseif node.children then
    for _, child in ipairs((node.children --[[:! { [integer]: HastNode }]])) do
      collect_text(child, parts)
    end
  end
end

--: (HastNode) -> string
local function text_content(node)
  local parts = {} --: { [integer]: string }
  collect_text(node, parts)
  return table.concat(parts)
end

-- Depth-first search for the first heading element.
--: (HastNode) -> HastNode | nil
local function find_first_heading(node)
  local tag = (node.tag or "")
  if node.type == "element" and HEADING[tag] then
    return node
  end
  if node.children then
    for _, child in ipairs((node.children --[[:! { [integer]: HastNode }]])) do
      local found = find_first_heading(child)
      if found then return found end
    end
  end
  return nil
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, unknown) -> nil
function M.plugin(processor, _opts)
  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    local tree_node = tree --[[:! HastNode]]
    local heading = find_first_heading(tree_node)
    if heading then
      local title = text_content(heading)
      if title ~= "" then
        local data = (tree_node.data or {}) --[[:! { [string]: unknown }]]
        data.title = title
        tree_node.data = data
      end
    end
    return tree_node
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
