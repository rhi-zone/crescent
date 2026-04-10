-- lib/remark_toc/init.lua
-- remark plugin that generates a Table of Contents from headings and inserts
-- it after a specially-marked heading.
--
-- Usage:
--   local remark = require("lib.remark")
--   local toc    = require("lib.remark_toc")
--
--   local result = remark():use(toc):process(md)
--
-- The plugin scans root.children for a heading whose text matches opts.heading
-- (default: "table of contents|toc|contents", case-insensitive).  All headings
-- that follow that marker heading are collected, nested by depth, and a list
-- node is inserted immediately after the marker heading.
--
-- Options:
--   opts.heading   — pipe-separated patterns (case-insensitive), default shown above
--   opts.ordered   — boolean, produce an ordered list (default false)
--   opts.tight     — boolean, tight list items (default true)
--   opts.max_depth — max heading depth to include (default 6)
--   opts.min_depth — min heading depth to include (default 2)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Text extraction ───────────────────────────────────────────────────────────

-- Recursively concatenate all `text` node values from a node's children.
local function extract_text(node)
  if node.type == "text" then
    return node.value or ""
  end
  local children = node.children
  if not children then return "" end
  local parts = {}
  for i = 1, #children do
    parts[i] = extract_text(children[i])
  end
  return table.concat(parts)
end

-- ── Slugification ─────────────────────────────────────────────────────────────

-- Produce a URL-friendly anchor slug from heading text.
-- Algorithm: lowercase → replace runs of non-alphanumeric/non-hyphen chars
-- with a single hyphen → strip leading/trailing hyphens.
local function slugify(text)
  local s = text:lower()
  s = s:gsub("[^%a%d%-]+", "-")
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  return s
end

-- ── Heading-match predicate ───────────────────────────────────────────────────

-- Build a matcher function from a pipe-separated pattern string.
-- Each alternative is matched as a plain substring after lowercasing.
local function make_matcher(pattern)
  local alts = {}
  for alt in (pattern .. "|"):gmatch("([^|]*)|") do
    local trimmed = alt:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      alts[#alts + 1] = trimmed:lower()
    end
  end
  return function(text)
    local lower = text:lower():match("^%s*(.-)%s*$")
    for i = 1, #alts do
      if lower == alts[i] then return true end
    end
    return false
  end
end

-- ── TOC node construction ─────────────────────────────────────────────────────

-- Build a list node from a flat array of {depth, text} entries.
-- Returns the top-level list node, or nil if entries is empty.
local function build_toc_list(entries, ordered, min_depth)
  if #entries == 0 then return nil end

  -- Each entry: { depth, text, slug }
  -- We build a stack of list nodes.  stack[i] is the list node at nesting
  -- level i (1 = top level, 2 = one level nested, ...).
  local function make_list()
    return { type = "list", ordered = ordered, children = {} }
  end

  local function make_list_item(text, slug)
    return {
      type = "listItem",
      children = {
        {
          type = "paragraph",
          children = {
            {
              type = "link",
              url  = "#" .. slug,
              children = {
                { type = "text", value = text }
              }
            }
          }
        }
      }
    }
  end

  local root_list = make_list()
  -- stack maps relative depth → {list_node, parent_item}
  -- stack[1] = { list = root_list, item = nil }
  local stack = { { list = root_list, item = nil } }

  for e = 1, #entries do
    local entry = entries[e]
    local rel   = entry.depth - min_depth + 1   -- 1-based relative depth

    -- Ensure stack has entries up to rel.
    -- If the stack is shorter, create intermediate lists attached to the last item.
    while #stack < rel do
      local parent_level = stack[#stack]
      local parent_list  = parent_level.list
      -- If the parent list has no items yet, add a placeholder.
      local last_item = parent_list.children[#parent_list.children]
      if not last_item then
        last_item = { type = "listItem", children = { { type = "paragraph", children = { { type = "text", value = "" } } } } }
        parent_list.children[#parent_list.children + 1] = last_item
      end
      local new_list = make_list()
      last_item.children[#last_item.children + 1] = new_list
      stack[#stack + 1] = { list = new_list, item = last_item }
    end

    -- If the stack is deeper, pop back.
    while #stack > rel do
      stack[#stack] = nil
    end

    -- Add the item to the current list.
    local current = stack[#stack]
    local item = make_list_item(entry.text, entry.slug)
    current.list.children[#current.list.children + 1] = item
    -- Update the current level's tracked item (for nesting).
    stack[#stack] = { list = current.list, item = item }

    -- Truncate any deeper stack levels (they're stale after a new sibling).
    -- (Already done by the pop-back loop above — no further action needed.)
  end

  return root_list
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local DEFAULT_HEADING = "table of contents|toc|contents"

local function remark_toc(processor, opts)
  opts = opts or {}
  local heading_pattern = opts.heading   or DEFAULT_HEADING
  local ordered         = opts.ordered   or false
  local max_depth       = opts.max_depth or 6
  local min_depth       = opts.min_depth or 2

  local matches = make_matcher(heading_pattern)

  processor:use_transformer(function(ast)
    local children = ast.children
    if not children then return ast end
    local n = #children

    -- 1. Find the TOC marker heading.
    local marker_idx = nil
    for i = 1, n do
      local node = children[i]
      if node.type == "heading" then
        local text = extract_text(node)
        if matches(text) then
          marker_idx = i
          break
        end
      end
    end

    if not marker_idx then return ast end

    -- 2. Collect subsequent headings within depth bounds.
    local entries   = {}
    local min_found = math.huge   -- actual minimum depth present

    for i = marker_idx + 1, n do
      local node = children[i]
      if node.type == "heading" then
        local d = node.depth or 1
        if d >= min_depth and d <= max_depth then
          local text = extract_text(node)
          local slug = slugify(text)
          entries[#entries + 1] = { depth = d, text = text, slug = slug }
          if d < min_found then min_found = d end
        end
      end
    end

    if #entries == 0 then return ast end

    -- 3. Build the list node.
    local toc_list = build_toc_list(entries, ordered, min_found)
    if not toc_list then return ast end

    -- 4. Insert the list after the marker heading.
    --    Splice: children[1..marker_idx] + toc_list + children[marker_idx+1..n]
    local new_children = {}
    for i = 1, marker_idx do
      new_children[#new_children + 1] = children[i]
    end
    new_children[#new_children + 1] = toc_list
    for i = marker_idx + 1, n do
      new_children[#new_children + 1] = children[i]
    end

    ast.children = new_children
    return ast
  end)
end

-- Make the module callable as a plugin: processor:use(toc)
setmetatable(M, { __call = function(_, ...) return remark_toc(...) end })

M.plugin    = remark_toc
M.slugify   = slugify
M.extract_text = extract_text

return M
