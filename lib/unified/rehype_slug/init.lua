-- lib/rehype_slug/init.lua
-- rehype plugin: add id attributes to heading elements (h1–h6) by slugifying
-- their text content. Port of rehype-slug / github-slugger.
--
-- Slugification rules (github-slugger compatible):
--   1. Extract text from all descendant text nodes (concatenated).
--   2. Lowercase.
--   3. Replace sequences of non-alphanumeric chars (except hyphens) with "-".
--   4. Strip leading/trailing hyphens.
--   5. Duplicate ids get suffixed: -1, -2, etc. (tracked per process() call).
--
-- Plugin signature (unified):
--   function rehype_slug(processor, opts)
--
-- Usage:
--   local rehype     = require("lib.unified.rehype")
--   local rehypeSlug = require("lib.unified.rehype_slug")
--   local processor  = rehype():use(rehypeSlug)
--   local html       = processor:stringify(processor:run(my_hast_tree))

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: HastNode = { type: string, tag?: string, children?: { [integer]: HastNode }, props?: { [string]: unknown }, value?: string, ... }

-- ── Text extraction ───────────────────────────────────────────────────────────

--: (HastNode, { [integer]: string }) -> nil
local function collect_text(node, parts)
  if node.type == "text" then
    parts[#parts + 1] = (node.value or "") --[[:! string]]
  elseif node.children then
    for _, child in ipairs((node.children --[[:! { [integer]: HastNode }]])) do
      collect_text(child, parts)
    end
  end
end

--: (HastNode) -> string
local function text_content(node)
  local parts = {}
  collect_text(node, parts)
  return table.concat(parts)
end

-- ── Slugification ─────────────────────────────────────────────────────────────

--: (string) -> string
local function slugify(s)
  -- Lowercase.
  s = s:lower()
  -- Replace sequences of non-alphanumeric, non-hyphen chars with a hyphen.
  s = s:gsub("[^%a%d%-]+", "-")
  -- Strip leading/trailing hyphens.
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  return s
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

local HEADING = { h1=true, h2=true, h3=true, h4=true, h5=true, h6=true }

--: (HastNode, { [string]: integer }) -> nil
local function walk(node, seen)
  local tag = (node.tag or "") --[[:! string]]
  if node.type == "element" and HEADING[tag] then
    local slug = slugify(text_content(node))
    if slug ~= "" then
      local id = slug
      if seen[slug] then
        seen[slug] = seen[slug] + 1
        id = slug .. "-" .. seen[slug]
      else
        seen[slug] = 0
      end
      local props = (node.props or {}) --[[:! { [string]: unknown }]]
      props.id = id
      node.props = props
    end
  end
  if node.children then
    for _, child in ipairs((node.children --[[:! { [integer]: HastNode }]])) do
      walk(child, seen)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, unknown) -> nil
function M.plugin(processor, _opts)
  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    -- Fresh seen-ids table per transform call (i.e. per process() call).
    local seen = {} --: { [string]: integer }
    local tree_node = tree --[[:! HastNode]]
    walk(tree_node, seen)
    return tree_node
  end)
end

-- Allow use as both `rehype():use(rehype_slug)` and
-- `rehype():use(rehype_slug.plugin)`.
setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
