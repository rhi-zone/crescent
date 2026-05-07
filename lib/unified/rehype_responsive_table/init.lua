-- lib/unified/rehype_responsive_table/init.lua
-- rehype plugin: wrap <table> elements in a scrollable container <div>.
-- Port of the rehype-responsive-table concept.
--
-- Input:  <table>...</table>
-- Output: <div class="table-wrapper" style="overflow-x: auto;"><table>...</table></div>
--
-- Options:
--   opts.class — wrapper element class (default "table-wrapper")
--   opts.style — wrapper element style (default "overflow-x: auto;")
--   opts.tag   — wrapper element tag name (default "div")
--
-- Usage:
--   local rehype          = require("lib.unified.rehype")
--   local responsiveTable = require("lib.unified.rehype_responsive_table")
--   local processor       = rehype():use(responsiveTable)
--   local html            = processor:stringify(processor:run(my_hast_tree))

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Defaults ──────────────────────────────────────────────────────────────────

local DEFAULT_CLASS = "table-wrapper"
local DEFAULT_STYLE = "overflow-x: auto;"
local DEFAULT_TAG   = "div"

-- ── Tree transformation ───────────────────────────────────────────────────────

-- Wrap a table element in a wrapper element.
local function make_wrapper(table_node, wrapper_tag, cls, style)
  return {
    type     = "element",
    tag      = wrapper_tag,
    props    = { class = cls, style = style },
    children = { table_node },
  }
end

-- Recursively process children of `node`, replacing <table> nodes with wrapped
-- versions. Returns true if any replacement was made (so parent can update its
-- children array).
local function process_children(node, wrapper_tag, cls, style)
  local children = node.children
  if not children then return end

  local new_children = {}
  local changed = false

  for i = 1, #children do
    local child = children[i]
    if child.type == "element" and child.tag == "table" then
      -- Recurse into the table's children before wrapping (handles nested tables
      -- if they exist inside td/th, but those are rare and still handled).
      process_children(child, wrapper_tag, cls, style)
      new_children[#new_children + 1] = make_wrapper(child, wrapper_tag, cls, style)
      changed = true
    else
      -- Recurse into non-table elements.
      process_children(child, wrapper_tag, cls, style)
      new_children[#new_children + 1] = child
    end
  end

  if changed then
    node.children = new_children
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: ({ use_transformer: (unknown) -> unknown, ... }, { class: string | nil, style: string | nil, tag: string | nil } | nil) -> nil
local function rehype_responsive_table(processor, opts)
  local cls         = (opts and opts.class) or DEFAULT_CLASS
  local style       = (opts and opts.style) or DEFAULT_STYLE
  local wrapper_tag = (opts and opts.tag)   or DEFAULT_TAG

  processor:use_transformer(function(tree)
    process_children(tree, wrapper_tag, cls, style)
    return tree
  end)
end

M.plugin = rehype_responsive_table

setmetatable(M, { __call = function(_, ...) return rehype_responsive_table(...) end })

return M
