-- lib/unified/rehype_xast/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- rehype_xast: bridge plugin from hast to xast.
-- Converts a hast tree into an xast tree for XML processing pipelines.
--
-- Mapping:
--   hast root    -> xast root(children)
--   hast element -> xast element(tag, props, children)
--   hast text    -> xast text(value)
--   hast comment -> xast comment(value)
--   hast doctype -> xast doctype("html")
--   hast raw     -> xast text(value)   (raw HTML can't round-trip through XML)

local xast = require("lib.unified.xast")

local M = {}

local convert_node  -- forward declaration

local function convert_children(children)
  if not children then return {} end
  local children_ = children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
  local out = {}
  for i = 1, #children_ do
    local x = convert_node(children_[i])
    if x then out[#out + 1] = x end
  end
  return out
end

convert_node = function(node)
  if not node then return nil end
  local t = node.type

  if t == "root" then
    return xast.root(convert_children(node.children))

  elseif t == "element" then
    -- hast uses `props`; xast uses `attributes`
    local attrs = {}
    if node.props then
      for k, v in pairs(node.props) do
        if v == true then
          attrs[k] = k        -- boolean attribute → name=name in XML
        elseif v and v ~= false then
          attrs[k] = tostring(v)
        end
      end
    end
    return xast.element(node.tag or "unknown", attrs, convert_children(node.children))

  elseif t == "text" then
    return xast.text(node.value or "")

  elseif t == "comment" then
    return xast.comment(node.value or "")

  elseif t == "doctype" then
    return xast.doctype("html")

  elseif t == "raw" then
    -- Raw HTML can't round-trip through XML; treat as text.
    return xast.text(node.value or "")

  else
    return nil
  end
end

-- Convert a hast tree to an xast tree (standalone utility).
function M.to_xast(hast_tree)
  return convert_node(hast_tree)
end

-- Plugin interface: replaces the tree in the processor with the xast tree.
function M.plugin(processor, _opts)
  processor:use_transformer(function(tree)
    return M.to_xast(tree)
  end)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
