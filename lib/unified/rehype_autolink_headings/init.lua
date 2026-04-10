-- lib/rehype_autolink_headings/init.lua
-- rehype plugin: wrap heading elements in anchor links pointing to their id.
-- Port of rehype-autolink-headings. Requires headings to already have an id
-- attribute (e.g. applied by rehype_slug).
--
-- Options:
--   opts.behavior  "wrap" (default) | "prepend" | "append"
--   opts.content   string or hast node used as anchor content in
--                  prepend/append mode (default: "¶")
--
-- Behavior:
--   "wrap"    — wraps all children in <a href="#id">…children…</a>
--   "prepend" — inserts <a href="#id" aria-hidden="true">content</a> before children
--   "append"  — inserts <a href="#id" aria-hidden="true">content</a> after children
--
-- Usage:
--   local rehype              = require("lib.unified.rehype")
--   local rehypeSlug          = require("lib.unified.rehype_slug")
--   local rehypeAutolinkHeadings = require("lib.unified.rehype_autolink_headings")
--   local processor = rehype():use(rehypeSlug):use(rehypeAutolinkHeadings)
--   local html = processor:stringify(processor:run(my_hast_tree))

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADING = { h1=true, h2=true, h3=true, h4=true, h5=true, h6=true }

--: (string) -> any
local function text_node(value)
  return { type = "text", value = value }
end

--: (string, any, any) -> any
local function el(tag, props, children)
  return { type = "element", tag = tag, props = props or {}, children = children or {} }
end

-- Build the content node(s) for prepend/append anchor.
--: (any) -> any
local function make_content(content_opt)
  if content_opt == nil then
    return text_node("\xC2\xB6") -- UTF-8 for ¶ (U+00B6 PILCROW SIGN)
  elseif type(content_opt) == "string" then
    return text_node(content_opt)
  else
    -- Assume it's a hast node; return as-is.
    return content_opt
  end
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

--: (any, string, any) -> nil
local function walk(node, behavior, content_opt)
  if node.type == "element" and HEADING[node.tag] then
    local id = node.props and node.props.id
    if id then
      local href = "#" .. id
      if behavior == "wrap" then
        -- Wrap all existing children in a single anchor.
        local anchor = el("a", { href = href }, node.children)
        node.children = { anchor }
      elseif behavior == "prepend" then
        local anchor = el("a", { href = href, ["aria-hidden"] = "true" }, { make_content(content_opt) })
        local new_children = { anchor }
        for _, child in ipairs(node.children) do
          new_children[#new_children + 1] = child
        end
        node.children = new_children
      elseif behavior == "append" then
        local anchor = el("a", { href = href, ["aria-hidden"] = "true" }, { make_content(content_opt) })
        local new_children = {}
        for _, child in ipairs(node.children) do
          new_children[#new_children + 1] = child
        end
        new_children[#new_children + 1] = anchor
        node.children = new_children
      end
    end
  end
  if node.children then
    for _, child in ipairs(node.children) do
      walk(child, behavior, content_opt)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local behavior    = opts.behavior or "wrap"
  local content_opt = opts.content

  processor:use_transformer(function(tree)
    walk(tree, behavior, content_opt)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

return M
