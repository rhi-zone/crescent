-- lib/rehype_infer_description/init.lua
-- rehype plugin: infer document description from the first paragraph.
-- Port of rehype-infer-description.
--
-- Strategy:
--   1. Find the first h1–h6 heading.
--   2. Use the first <p> that appears after that heading (as a sibling in the
--      root children list, or in any nested structure after the heading).
--   3. If no heading exists, use the very first <p> anywhere in the document.
--   4. Extract its text content, then truncate at opts.max_words words
--      (default 50) or opts.truncate_size characters (default 300).
--
-- Stores on the AST root:
--   root.data.description = "..."
--
-- Usage:
--   local rehype      = require("lib.unified.rehype")
--   local inferDesc   = require("lib.unified.rehype_infer_description")
--   local processor   = rehype():use(inferDesc, { max_words = 30 })
--   local ast         = processor:run(processor:parse(html))
--   -- ast.data.description == "..."

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

-- Truncate text to at most max_words words and truncate_size characters.
-- Appends "…" if truncated.
--: (string, integer, integer) -> string
local function truncate(s, max_words, truncate_size)
  -- Word truncation.
  local word_count = 0
  local word_end = #s
  for i = 1, #s do
    local c = s:sub(i, i)
    -- Count transitions into whitespace as word boundaries.
    if c:match("%s") then
      -- We just finished a word if previous char wasn't whitespace.
      if i > 1 and not s:sub(i-1, i-1):match("%s") then
        word_count = word_count + 1
        if word_count >= max_words then
          word_end = i - 1
          break
        end
      end
    end
  end
  -- Count the last word if we never hit whitespace.
  if word_count < max_words then
    word_end = #s
  end
  local word_end_ = word_end --[[:! integer]]
  local result = s:sub(1, word_end_)
  local truncated_by_words = word_end_ < #s

  -- Character truncation.
  if #result > truncate_size then
    result = result:sub(1, truncate_size)
    return result .. "\xe2\x80\xa6"  -- UTF-8 ellipsis "…"
  end
  if truncated_by_words then
    return result .. "\xe2\x80\xa6"
  end
  return result
end

-- Flat linear walk of root children to find first heading then first p.
-- Returns (heading_index, p_index) where heading_index may be nil if no
-- heading found. Indices are into node.children of the provided list.
--: ({ [integer]: HastNode }) -> (integer | nil, integer | nil)
local function find_heading_and_para(children)
  local heading_idx = nil --: integer | nil
  local para_idx = nil --: integer | nil
  for i, child in ipairs(children) do
    if child.type == "element" then
      local child_tag = (child.tag or "")
      if HEADING[child_tag] and not heading_idx then
        heading_idx = i
      elseif child_tag == "p" then
        if heading_idx then
          -- First <p> after heading — this is what we want.
          para_idx = i
          break
        elseif not para_idx then
          -- First <p> before any heading — fallback candidate.
          para_idx = i
        end
      end
    end
  end
  return heading_idx, para_idx
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (unknown, { max_words?: integer, truncate_size?: integer } | nil) -> nil
function M.plugin(processor, opts)
  local opts_t = (opts or {}) --[[:! { max_words?: integer, truncate_size?: integer }]]
  local max_words     = opts_t.max_words     or 50
  local truncate_size = opts_t.truncate_size or 300

  local processor_t = processor --[[:! { use_transformer: (unknown, (unknown) -> unknown) -> nil }]]
  processor_t:use_transformer(function(tree)
    local tree_node = tree --[[:! HastNode]]
    local children = (tree_node.children or {}) --[[:! { [integer]: HastNode }]]
    local _heading_idx, para_idx = find_heading_and_para(children)

    local para = para_idx and children[para_idx]
    if not para then
      -- No <p> among direct children — do a depth-first search for the first <p>.
      local find_first_p
      find_first_p = function(node)
        local node_t = node --[[:! HastNode]]
        local node_tag = (node_t.tag or "")
        if node_t.type == "element" and node_tag == "p" then
          return node
        end
        if node_t.children then
          for _, child in ipairs((node_t.children --[[:! { [integer]: HastNode }]])) do
            local found = find_first_p(child)
            if found then return found end
          end
        end
        return nil
      end
      para = find_first_p(tree_node)
    end

    if para then
      local raw_text = text_content(para --[[:! HastNode]])
      -- Normalize whitespace.
      raw_text = (raw_text:gsub("%s+", " "):match("^%s*(.-)%s*$") --[[:! string]])
      if raw_text ~= "" then
        local data = (tree_node.data or {}) --[[:! { [string]: unknown }]]
        data.description = truncate(raw_text, max_words, truncate_size)
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
