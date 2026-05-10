-- lib/unified/remark_squeeze_paragraphs/init.lua
-- remark plugin that removes empty paragraphs from the mdast tree.
-- A paragraph is considered empty if it has no children, or if all of its
-- children are text nodes containing only whitespace.
--
-- Mirrors the behaviour of remark-squeeze-paragraphs (remarkjs).
--
-- Usage:
--   local remark   = require("lib.unified.remark")
--   local squeeze  = require("lib.unified.remark_squeeze_paragraphs")
--
--   local processor = remark():use(squeeze)
--   local result    = processor:process(md)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: MdastNode = { type: string, value?: string, children?: { [integer]: MdastNode }, ... }

-- ── Predicate ─────────────────────────────────────────────────────────────────

-- Returns true when a paragraph node is empty (should be removed).
local function is_empty_paragraph(node)
  if node.type ~= "paragraph" then return false end
  local children = node.children --[[:! { [integer]: MdastNode }]]
  if not children or #children == 0 then return true end
  -- A paragraph is also empty when every child is a whitespace-only text node.
  for i = 1, #children do
    local child = children[i]
    if child.type ~= "text" then
      -- Any non-text child → paragraph is not empty.
      return false
    end
    local v = child.value or ""
    if v:find("[^ \t\r\n]") then
      -- Non-whitespace content found → not empty.
      return false
    end
  end
  return true
end

-- ── Filter helpers ────────────────────────────────────────────────────────────

-- Remove empty paragraphs from a children array, returning a new array.
local function filter_children(children)
  --: { [integer]: MdastNode } | nil
  if not children then return children end
  local children_ = children --[[:! { [integer]: MdastNode }]]
  local out = {}
  for i = 1, #children_ do
    if not is_empty_paragraph(children_[i]) then
      out[#out + 1] = children_[i]
    end
  end
  return out
end

-- Node types whose children lists may contain paragraphs and should be
-- recursively filtered.
local CONTAINER_TYPES = {
  root        = true,
  blockquote  = true,
  listItem    = true,
  footnote    = true,
}

local function squeeze(node)
  if CONTAINER_TYPES[node.type] then
    node.children = filter_children(node.children)
  end
  -- Recurse into all children regardless of container type, so deeply nested
  -- structures (list > listItem > blockquote > …) are all handled.
  local children = node.children
  if children then
    local nc = children --[[:! { [integer]: MdastNode }]]
    for i = 1, #nc do
      squeeze(nc[i])
    end
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_squeeze_paragraphs(processor, _opts)
  processor:use_transformer(function(ast)
    return squeeze(ast)
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_squeeze_paragraphs(...) end })

M.plugin = remark_squeeze_paragraphs

return M
