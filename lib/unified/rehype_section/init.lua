-- lib/unified/rehype_section/init.lua
-- rehype plugin: wrap headings and following content into nested <section> elements.
-- Port of rehype-section.
--
-- Algorithm:
--   Walk root children. When a heading (h1–h6) is encountered, open a new
--   section at that heading's depth, closing any deeper open sections first.
--   All nodes that follow the heading (until the next heading of equal or
--   lesser depth) are placed inside that section.
--
-- Options:
--   opts.wrap   boolean   wrap the entire content in a top-level <section>
--                         (default true)
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype  = require("lib.unified.rehype")
--   local section = require("lib.unified.rehype_section")
--   local processor = rehype():use(section, { wrap = false })

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local HEADING_DEPTH = { h1=1, h2=2, h3=3, h4=4, h5=5, h6=6 }

--: (any) -> integer | nil
local function heading_depth(node)
  if node.type == "element" then
    local val = HEADING_DEPTH[node.tag]
  return val --[[:! integer | nil]]
  end
  return nil
end

--: (any) -> any
local function make_section(children)
  return { type = "element", tag = "section", props = {}, children = children or {} }
end

-- ── Sectioning algorithm ──────────────────────────────────────────────────────
--
-- We maintain a stack of open sections. Each entry is a table:
--   { depth = number, children = table }
--
-- When we see a heading of depth D:
--   1. Pop all stack entries with depth >= D (close deeper/equal sections).
--   2. Push a new entry with depth D and the heading as first child.
-- Non-heading nodes are appended to the top of stack.
-- At the end, collapse the stack bottom-up.

--: (any) -> any
local function sectionize(nodes)
  -- Stack: each entry = { depth = int, children = [] }
  -- We also keep a "root" accumulator for nodes before the first heading.
  local pre = {}      -- nodes before any heading
  local stack = {}    -- open section entries

  --: () -> any
  local function top_children()
    if #stack > 0 then
      local top = stack[#stack] --[[:! { children: any, depth: integer }]]
      return top.children
    end
    return pre
  end

  for _, node in ipairs(nodes) do
    local d = heading_depth(node)
    if d then
      -- Close sections that are at depth >= d.
      while #stack > 0 do
        local stk_top = stack[#stack] --[[:! { depth: integer, children: { [integer]: any } }]]
        if stk_top.depth < d then break end
        local closed_ = table.remove(stack) --[[:! { children: { [integer]: any } }]]
        local sec = make_section(closed_.children)
        -- Append the closed section to the new top.
        local parent
        if #stack > 0 then
          local stk2 = stack[#stack] --[[:! { children: { [integer]: any } }]]
          parent = stk2.children
        else
          parent = pre
        end
        parent[#parent + 1] = sec
      end
      -- Open a new section at depth d with this heading.
      stack[#stack + 1] = { depth = d, children = { node } }
    else
      top_children()[#top_children() + 1] = node
    end
  end

  -- Close all remaining open sections.
  while #stack > 0 do
    local closed = table.remove(stack)
    local sec = make_section(closed.children)
    local parent = #stack > 0 and stack[#stack].children or pre
    parent[#parent + 1] = sec
  end

  return pre
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}
  local wrap = opts.wrap
  if wrap == nil then wrap = true end

  processor:use_transformer(function(tree)
    if not tree.children then return tree end
    local result = sectionize(tree.children)
    if wrap then
      tree.children = { make_section(result) }
    else
      tree.children = result
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
