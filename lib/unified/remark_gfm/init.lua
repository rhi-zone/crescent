-- lib/remark_gfm/init.lua
-- remark plugin that adds GitHub Flavored Markdown (GFM) extensions:
--   • Tables          (pipe syntax → {type="table"} nodes)
--   • Strikethrough   (~~text~~ → {type="delete"} nodes)
--   • Task lists      (- [x] item → listItem.checked=true/false)
--   • Autolinks       (bare https?:// URLs → {type="link"} nodes)
--
-- The plugin registers a transformer that walks the parsed mdast tree and
-- applies GFM transformations in-place.  No parser wrapping is needed
-- because all four features are detectable post-parse.
--
-- Usage:
--   local remark = require("lib.unified.remark")
--   local gfm    = require("lib.unified.remark_gfm")
--   local ast    = remark():use(gfm):parse(source)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: GfmNode = { type: string, value?: string, children?: { [integer]: GfmNode }, depth?: integer, url?: string, title?: string, ordered?: boolean, start?: integer, lang?: string, checked?: boolean, label?: string, align?: unknown, header?: unknown, rows?: unknown, ... }

-- ── Helpers ───────────────────────────────────────────────────────────────────

local str_find  = string.find
local str_sub   = string.sub
local str_match = string.match
local tbl_concat = table.concat

-- Collect the plain-text value of a sequence of inline nodes (for table
-- cell content reconstruction).  softBreak nodes become "\n" so that the
-- table parser can split on newlines to find the separator row.
local function inline_text(nodes)
  if not nodes then return "" end
  local parts = {}
  for i = 1, #nodes do
    local n = nodes[i]
    if n.type == "text" then
      parts[#parts + 1] = n.value or ""
    elseif n.type == "softBreak" then
      parts[#parts + 1] = "\n"
    elseif n.type == "break" or n.type == "hardBreak" then
      parts[#parts + 1] = "\n"
    elseif n.type == "inlineCode" then
      parts[#parts + 1] = "`" .. (n.value or "") .. "`"
    elseif n.children then
      parts[#parts + 1] = inline_text(n.children)
    end
  end
  return tbl_concat(parts)
end

-- ── Table detection and parsing ───────────────────────────────────────────────

-- Trim leading/trailing whitespace from a string.
local function trim(s)
  return str_match(s, "^%s*(.-)%s*$") or s
end

-- Split a pipe-delimited row into cell strings.
-- Handles leading/trailing pipe, escaping not implemented (edge case).
local function split_row(line)
  local cells = {}
  -- Strip leading/trailing pipes and whitespace.
  local s = trim(line)
  if str_sub(s, 1, 1) == "|" then s = str_sub(s, 2) end
  if str_sub(s, -1) == "|" then s = str_sub(s, 1, -2) end
  -- Split on unescaped pipes.
  local pos = 1
  local len = #s
  while pos <= len do
    local pipe = str_find(s, "|", pos, true)
    if pipe then
      cells[#cells + 1] = trim(str_sub(s, pos, pipe - 1))
      pos = pipe + 1
    else
      cells[#cells + 1] = trim(str_sub(s, pos))
      break
    end
  end
  return cells
end

-- Check whether a string is a valid separator cell (e.g. "---", ":---", "---:", ":---:").
-- Returns alignment ("left"|"center"|"right"|nil) or false if not a separator.
local function parse_align_cell(s)
  s = trim(s)
  local left_colon  = str_sub(s, 1, 1) == ":"
  local right_colon = str_sub(s, -1) == ":"
  -- The remaining chars (after stripping colons) must be all dashes.
  local inner = s
  if left_colon  then inner = str_sub(inner, 2) end
  if right_colon then inner = str_sub(inner, 1, -2) end
  if not str_match(inner, "^%-+$") then return false end
  if left_colon and right_colon then return "center"
  elseif left_colon             then return "left"
  elseif right_colon            then return "right"
  else                               return nil  -- default (no alignment specified)
  end
end

-- Try to parse a GFM table starting at paragraph node `para`.
-- A GFM table requires:
--   line 1 : header row (pipe-separated)
--   line 2 : separator row (colons + dashes)
--   line 3+: data rows (optional)
--
-- Returns a table node on success, or nil if `para` is not a table.
local function try_parse_table(para)
  -- Reconstruct the raw text of the paragraph.
  local raw = inline_text(para.children)
  -- Split into lines.
  local lines = {}
  local pos = 1
  local len = #raw
  while pos <= len do
    local nl = str_find(raw, "\n", pos, true)
    if nl then
      lines[#lines + 1] = str_sub(raw, pos, nl - 1)
      pos = nl + 1
    else
      lines[#lines + 1] = str_sub(raw, pos)
      break
    end
  end

  if #lines < 2 then return nil end

  -- Line 1 must contain at least one pipe.
  if not str_find(lines[1], "|", 1, true) then return nil end

  -- Line 2 must be a separator row.
  local sep_cells = split_row(lines[2])
  if #sep_cells == 0 then return nil end
  local align = {}
  for i = 1, #sep_cells do
    local a = parse_align_cell(sep_cells[i])
    if a == false then return nil end  -- not a valid separator cell
    align[i] = a
  end

  -- Parse header row.
  local header_cells = split_row(lines[1])
  -- Parse data rows.
  local data_rows = {}
  for li = 3, #lines do
    if str_find(lines[li], "|", 1, true) then
      data_rows[#data_rows + 1] = split_row(lines[li])
    end
  end

  -- Build the table AST node.
  local col_count = #header_cells

  local function make_cell(text)
    return {
      type = "tableCell",
      children = text ~= "" and { { type = "text", value = text } } or {},
    }
  end

  local function make_row(cells, is_header)
    local row_cells = {}
    for ci = 1, col_count do
      row_cells[ci] = make_cell(cells[ci] or "")
    end
    return { type = "tableRow", isHeader = is_header or nil, children = row_cells }
  end

  local rows = {}
  rows[1] = make_row(header_cells, true)
  for i = 1, #data_rows do
    rows[#rows + 1] = make_row(data_rows[i], false)
  end

  return {
    type     = "table",
    align    = align,
    children = rows,
  }
end

-- ── Strikethrough and autolink inline transforms ───────────────────────────────

-- URL pattern for autolinks: https?:// followed by non-whitespace, non < > chars.
local URL_PATTERN = "https?://[^%s<>]+"

-- Process a single text node value, splitting it into a sequence of inline
-- nodes after applying strikethrough (~~...~~) and autolink transforms.
-- Returns an array of inline nodes (may be a single text node if no matches).
--: (value: string) -> { [integer]: unknown }
local function transform_text_value(value)
  local result = {} --[[: { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
  local pos = 1  --: integer
  local len = #value

  while pos <= len do
    -- Look for the earliest match: either ~~ or a URL.
    local strike_s, strike_e = str_find(value, "~~", pos, true)
    local url_s, url_e       = str_find(value, URL_PATTERN, pos)

    -- If there's a strike opener, check for a closer.
    local strike_close_s, strike_close_e
    if strike_s then
      strike_close_s, strike_close_e = str_find(value, "~~", (strike_e --[[:! integer]]) + 1, true)
    end

    -- Decide which match comes first.
    local has_strike = strike_s and strike_close_s
    local has_url    = url_s ~= nil

    local next_strike = has_strike and (strike_s or len + 1) or len + 1  --: integer
    local next_url    = has_url    and (url_s    or len + 1) or len + 1  --: integer

    if not has_strike and not has_url then
      -- No more special syntax: flush remaining text.
      if pos <= len then
        result[#result + 1] = { type = "text", value = str_sub(value, pos) }
      end
      break
    elseif next_strike <= next_url then
      -- Emit text before the ~~.
      local ss = strike_s --[[:! integer]]
      local se = strike_e --[[:! integer]]
      local scs = strike_close_s --[[:! integer]]
      local sce = strike_close_e --[[:! integer]]
      if ss > pos then
        result[#result + 1] = { type = "text", value = str_sub(value, pos, ss - 1) }
      end
      -- Emit delete node.
      local inner = str_sub(value, se + 1, scs - 1)
      result[#result + 1] = {
        type     = "delete",
        children = { { type = "text", value = inner } },
      }
      pos = sce + 1
    else
      -- Emit text before the URL.
      local us = url_s --[[:! integer]]
      local ue = url_e --[[:! integer]]
      if us > pos then
        result[#result + 1] = { type = "text", value = str_sub(value, pos, us - 1) }
      end
      -- Emit link node for the bare URL.
      local url = str_sub(value, us, ue)
      result[#result + 1] = {
        type     = "link",
        url      = url,
        title    = nil,
        children = { { type = "text", value = url } },
      }
      pos = ue + 1
    end
  end

  return result
end

-- Expand text nodes in an inline list, splitting strikethrough and autolinks.
-- Returns a new flat list of inline nodes.
local function expand_inline_nodes(nodes)
  local result = {}
  for i = 1, #nodes do
    local node = nodes[i]
    if node.type == "text" then
      local expanded = transform_text_value(node.value or "")
      for j = 1, #expanded do
        result[#result + 1] = expanded[j]
      end
    else
      -- Recurse into children (emphasis, strong, link, etc.).
      if node.children then
        node.children = expand_inline_nodes(node.children)
      end
      result[#result + 1] = node
    end
  end
  return result
end

-- ── Task list detection ────────────────────────────────────────────────────────

-- Returns true/false if the listItem starts with [ ]/[x], nil otherwise.
-- Mutates the listItem to strip the checkbox prefix and set .checked.
--: (item: { type: string, ... }) -> nil
local function try_task_list_item(item)
  local item_any = item --[[:! { children: { [integer]: GfmNode } | nil, checked?: boolean, ... }]]
  if not item_any.children or #(item_any.children --[[:! { [integer]: GfmNode }]]) == 0 then return end
  local first_child = item_any.children[1]
  -- The first child should be a paragraph (tight list) or directly inline nodes.
  local inlines
  if first_child.type == "paragraph" then
    inlines = first_child.children
  elseif first_child.type == "text" then
    inlines = item.children
  end
  local inlines_any = inlines --[[:! { [integer]: { type: string, value?: string, ... } }]]
  if not inlines_any or #inlines_any == 0 then return end
  local first_inline = inlines_any[1]
  if first_inline.type ~= "text" then return
  else
  local v = first_inline.value or ""
  local checked, rest
  if str_sub(v, 1, 4) == "[x] " or str_sub(v, 1, 4) == "[X] " then
    checked = true
    rest    = str_sub(v, 5)
  elseif str_sub(v, 1, 4) == "[ ] " then
    checked = false
    rest    = str_sub(v, 5)
  else
    return  -- not a task list item
  end
  -- Mutate the text node to remove the checkbox prefix.
  first_inline.value = rest
  -- Set checked on the listItem.
  item.checked = checked
  end -- else (type == "text")
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

-- Walk the block tree depth-first, applying all GFM transforms.
local function transform(node)
  if node.type == "root" or node.type == "blockquote" then
    local children = node.children --[[:! { [integer]: GfmNode, ... }]]
    local new_children = {}
    for i = 1, #children do
      local child = children[i]
      -- Try table conversion on paragraphs.
      if child.type == "paragraph" then
        local tbl = try_parse_table(child --[[:! { children: { [integer]: GfmNode } }]])
        if tbl then
          new_children[#new_children + 1] = tbl
        else
          -- Expand strikethrough and autolinks in paragraph inlines.
          if child.children then
            child.children = expand_inline_nodes(child.children)
          end
          new_children[#new_children + 1] = child
        end
      elseif child.type == "list" then
        -- Process task list items and recurse.
        local child_ch = child.children or {} --[[: { [integer]: GfmNode }]]
        for j = 1, #child_ch do
          local item = child_ch[j]
          try_task_list_item(item)
          -- Expand inline content inside list item children.
          if item.children then
            for k = 1, #item.children do
              local ic = item.children[k]
              if ic.children then
                ic.children = expand_inline_nodes(ic.children)
              end
            end
          end
        end
        new_children[#new_children + 1] = child
      else
        -- Recurse into other block containers.
        transform(child)
        -- Expand inline content in heading.
        if child.type == "heading" and child.children then
          child.children = expand_inline_nodes(child.children)
        end
        new_children[#new_children + 1] = child
      end
    end
    node.children = new_children
  end
  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

local function remark_gfm(processor, _opts)
  processor:use_transformer(function(ast)
    transform(ast)
    return ast
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_gfm(...) end })

M.plugin = remark_gfm

return M
