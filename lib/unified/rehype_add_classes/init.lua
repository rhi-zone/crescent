-- lib/unified/rehype_add_classes/init.lua
-- rehype plugin: add CSS classes to matched elements.
-- Port of rehype-add-classes by nicktindall.
--
-- Options table maps CSS selector strings (tag names or comma-separated tag
-- names) to class strings (space-separated) to append.
--
-- Usage:
--   rehype():use(addClasses, {
--     p              = "prose",
--     h1             = "title heading",
--     ["h1,h2,h3"]  = "heading",
--     pre            = "code-block",
--   })
--
-- Classes are appended to props.class (space-separated). Duplicates are
-- removed: existing classes are kept, new ones added only when not present.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

--: (string) -> { [string]: boolean }
local function parse_class_set(s)
  local set = {}
  for cls in s:gmatch("%S+") do
    set[cls] = true
  end
  return set
end

--: (string, string) -> string
local function add_classes(existing, to_add)
  local set = parse_class_set(existing)
  local result_parts = {}
  -- Keep existing order.
  for cls in existing:gmatch("%S+") do
    result_parts[#result_parts + 1] = cls
  end
  -- Append new classes not already present.
  for cls in to_add:gmatch("%S+") do
    if not set[cls] then
      set[cls] = true
      result_parts[#result_parts + 1] = cls
    end
  end
  return table.concat(result_parts, " ")
end

-- ── Selector compilation ──────────────────────────────────────────────────────

-- Build a flat table: tag_name -> list of class strings to add.
--: (any) -> { [string]: string[] }
local function compile_selectors(opts)
  local map = {}
  for selector, classes in pairs(opts) do
    -- Split comma-separated selectors.
    for tag in selector:gmatch("[^,]+") do
      tag = tag:match("^%s*(.-)%s*$")  -- trim
      if tag ~= "" then
        if not map[tag] then map[tag] = {} end
        map[tag][#map[tag] + 1] = classes
      end
    end
  end
  return map
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

--: (any, any) -> nil
local function walk(node, map)
  if node.type == "element" then
    local class_list = map[node.tag]
    if class_list then
      node.props = node.props or {}
      local existing = node.props["class"] or ""
      for _, classes in ipairs(class_list) do
        existing = add_classes(existing, classes)
      end
      node.props["class"] = existing
    end
  end
  if node.children then
    for _, child in ipairs(node.children) do
      walk(child, map)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local map = compile_selectors(opts)
  processor:use_transformer(function(tree)
    walk(tree, map)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
