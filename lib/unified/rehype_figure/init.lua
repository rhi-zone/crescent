-- lib/unified/rehype_figure/init.lua
-- rehype plugin: wrap standalone <img> elements in <figure> + <figcaption>.
-- Port of rehype-figure.
--
-- A "standalone" image is a <p> element whose only child is an <img>.
-- Such a <p> is replaced with a <figure> containing the <img> and optionally
-- a <figcaption> whose text is the img alt attribute.
--
-- Options:
--   opts.class   string   CSS class to add to the <figure> element (default nil)
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype = require("lib.unified.rehype")
--   local figure = require("lib.unified.rehype_figure")
--   local processor = rehype():use(figure, { class = "figure" })

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Returns the single img child if node is a <p> with exactly one element child
-- that is an <img>; otherwise returns nil.
--:: HastNode = { type: string, tag?: string, value?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, ... }
--: (HastNode) -> HastNode | nil
local function sole_img_child(node)
  if node.type ~= "element" or node.tag ~= "p" then return nil end
  local children = (node.children or {}) --[[:! { [integer]: HastNode, ... }]]
  -- Allow trailing/leading whitespace text nodes but require exactly one
  -- non-whitespace child and that child must be an <img>.
  local img_node = nil
  for _, child in ipairs(children) do
    if child.type == "text" then
      -- Allow pure-whitespace text nodes.
      local cv = child.value
      if cv and cv:match("^%s*$") then
        -- ok, skip
      else
        return nil
      end
    elseif child.type == "element" then
      if img_node then
        -- More than one element child.
        return nil
      end
      if child.tag ~= "img" then return nil end
      img_node = child
    else
      return nil
    end
  end
  return img_node
end

-- ── Tree transformer ──────────────────────────────────────────────────────────

--: ({ [integer]: HastNode, ... } | nil, string | nil) -> nil
local function transform_children(children, class)
  if not children then return end
  for i, node in ipairs(children) do
    local img = sole_img_child(node)
    if img then
      -- Build <figure> children.
      local figure_children = { img }
      local alt = (img.props or {}).alt
      if alt and alt ~= "" then
        figure_children[#figure_children + 1] = {
          type = "element",
          tag  = "figcaption",
          props = {},
          children = { { type = "text", value = alt } },
        }
      end
      local figure_props = {}
      if class and class ~= "" then
        figure_props["class"] = class
      end
      children[i] = {
        type     = "element",
        tag      = "figure",
        props    = figure_props,
        children = figure_children,
      }
    else
      -- Recurse into children.
      if node.children then
        transform_children(node.children, class)
      end
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, { class: string | nil, ... } | nil) -> nil
function M.plugin(processor, opts)
  opts = opts or ({} --[[:! { class: string | nil }]])
  local class = opts.class

  ;(processor --[[:! { use_transformer: (...unknown) -> unknown, ... }]]):use_transformer(function(tree)
    if tree.children then
      transform_children(tree.children, class)
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
