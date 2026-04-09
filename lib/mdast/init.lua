-- lib/mdast/init.lua
-- Markdown parser producing mdast-compatible AST nodes.
--
-- Phase 1: CommonMark core.
--   Block nodes: Root, Paragraph, Heading (ATX), Blockquote, Code (fenced + indented),
--     ThematicBreak, List, ListItem, Html, Definition
--   Inline nodes: Text, InlineCode, Emphasis, Strong, Link, Image, Break
--
-- Known gaps (Phase 2):
--   - Setext headings (underline style `===`/`---`)
--   - Link reference definitions resolved in inline parsing (definitions are
--     collected but not yet used for reference-style links [text][id])
--   - HTML block pass-through is minimal (no block-level HTML type classification)
--   - Tight vs loose list distinction (all lists treated as tight internally)
--   - GFM extensions (tables, strikethrough, task lists)
--   - Autolinks <url>
--
-- API:
--   mdast.parse(str) -> Root node
--   mdast.stringify(node) -> string  (basic round-trip, best-effort)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── String helpers ────────────────────────────────────────────────────────────

local str_byte  = string.byte
local str_sub   = string.sub
local str_find  = string.find
local str_rep   = string.rep
local str_char  = string.char
local tbl_concat = table.concat
local tbl_insert = table.insert

-- ── Line splitting ─────────────────────────────────────────────────────────────

-- Split src into lines. Each line does NOT include the trailing \n (or \r\n).
local function split_lines(src)
  local lines = {}
  local len = #src
  local pos = 1
  while pos <= len do
    local nl = str_find(src, "\n", pos, true)
    if nl then
      local line = str_sub(src, pos, nl - 1)
      -- Strip trailing \r if present.
      if #line > 0 and str_byte(line, #line) == 13 then
        line = str_sub(line, 1, #line - 1)
      end
      lines[#lines + 1] = line
      pos = nl + 1
    else
      lines[#lines + 1] = str_sub(src, pos)
      break
    end
  end
  return lines
end

-- ── Block-level parsing ───────────────────────────────────────────────────────

-- Count leading spaces (tabs count as 4 spaces for indentation purposes).
local function count_indent(line)
  local n = 0
  local len = #line
  local i = 1
  while i <= len do
    local b = str_byte(line, i)
    if b == 32 then       -- space
      n = n + 1
      i = i + 1
    elseif b == 9 then    -- tab → round up to next multiple of 4
      n = n + (4 - (n % 4))
      i = i + 1
    else
      break
    end
  end
  return n, i
end

-- Strip up to `n` leading spaces (or tab-equivalent), return rest.
local function strip_indent(line, n)
  local removed = 0
  local i = 1
  local len = #line
  while i <= len and removed < n do
    local b = str_byte(line, i)
    if b == 32 then
      removed = removed + 1
      i = i + 1
    elseif b == 9 then
      local tab_size = 4 - (removed % 4)
      if removed + tab_size > n then
        -- Partial tab: replace with spaces.
        return str_rep(" ", removed + tab_size - n) .. str_sub(line, i + 1)
      end
      removed = removed + tab_size
      i = i + 1
    else
      break
    end
  end
  return str_sub(line, i)
end

-- Is the line blank (empty or only whitespace)?
local function is_blank(line)
  return str_find(line, "^%s*$") ~= nil
end

-- Check if line is a thematic break: 3+ of the same char (-, *, _), optional spaces.
local function is_thematic_break(line)
  local stripped = line:match("^%s*(.-)%s*$") or line
  local ch = str_sub(stripped, 1, 1)
  if ch ~= "-" and ch ~= "*" and ch ~= "_" then return false end
  local count = 0
  for i = 1, #stripped do
    local b = str_byte(stripped, i)
    local c = str_char(b)
    if c == ch then
      count = count + 1
    elseif c ~= " " and c ~= "\t" then
      return false
    end
  end
  return count >= 3
end

-- Check for ATX heading. Returns depth (1-6) and rest content, or nil.
-- Lua patterns don't support {n,m}, so we use + and check length manually.
local function match_atx_heading(line)
  local hashes = line:match("^(#+)")
  if not hashes or #hashes > 6 then return nil end
  local depth = #hashes
  -- Must be followed by space/tab or end of line.
  local after_hashes = str_sub(line, depth + 1)
  if after_hashes == "" or after_hashes:match("^%s*$") then
    -- Heading with no content.
    return depth, ""
  end
  local first_ch = str_byte(after_hashes, 1)
  if first_ch ~= 32 and first_ch ~= 9 then
    -- Not a heading (no space after hashes).
    return nil
  end
  local rest = after_hashes:match("^%s+(.-)%s*$") or ""
  -- Strip optional closing sequence: space(s) + one or more #, optionally trailing spaces.
  local trimmed = rest:match("^(.-) +#+%s*$") or rest:match("^(.-) +#%s*$")
  -- Also handle: all hashes case.
  if not trimmed then trimmed = rest:match("^(#+)$") end
  if not trimmed then trimmed = rest:match("^(.-)%s*#+%s*$") end
  -- Only apply trim if rest ends with # (preceded by space).
  if rest:match(" #+%s*$") then
    trimmed = rest:match("^(.-)%s* +#+%s*$") or rest:match("^(.*%S)%s* +#+%s*$")
    if not trimmed and rest:match("^#+%s*$") then trimmed = "" end
  end
  rest = trimmed or rest
  return depth, rest
end

-- Check for fenced code block opening. Returns fence char, fence length, info string or nil.
-- Lua patterns don't support {n,m}, so we use + and check length manually.
local function match_fence_open(line)
  -- Allow up to 3 spaces of indentation.
  local indent, col = count_indent(line)
  if indent > 3 then return nil end
  local rest = str_sub(line, col)
  -- Backtick fence: 3+ backticks, no backticks in info.
  local fence = rest:match("^(`+)")
  if fence and #fence >= 3 then
    local info = rest:sub(#fence + 1):match("^%s*(.-)%s*$")
    if not info:find("`") then
      return "`", #fence, info, indent
    end
  end
  -- Tilde fence: 3+ tildes.
  fence = rest:match("^(~+)")
  if fence and #fence >= 3 then
    local info = rest:sub(#fence + 1):match("^%s*(.-)%s*$")
    return "~", #fence, info, indent
  end
  return nil
end

-- Check for blockquote line. Returns content after "> " or nil.
local function match_blockquote(line)
  -- Up to 3 spaces of indent, then >.
  local _, col = count_indent(line)
  local indent = col - 1
  if indent > 3 then return nil end
  local rest = str_sub(line, col)
  if str_byte(rest, 1) ~= 62 then return nil end  -- '>'
  local after = str_sub(rest, 2)
  -- Optional single space after >.
  if str_byte(after, 1) == 32 then
    after = str_sub(after, 2)
  end
  return after
end

-- Check for list item. Returns: marker_type ("bullet"|"ordered"), bullet_char or nil,
-- start_num or nil, content_after_marker, marker_width (spaces before content).
local function match_list_item(line)
  -- Up to 3 spaces of leading indent.
  local indent, col = count_indent(line)
  if indent > 3 then return nil end
  local rest = str_sub(line, col)
  -- Bullet list: -, +, * followed by space or tab.
  local bullet = rest:match("^([%-%+%*])[ \t]")
  if bullet then
    local after = str_sub(rest, 3)
    -- Actually may have more spaces: CommonMark rule: 1-4 spaces after marker.
    local spaces_after = 1
    local i = 2
    while str_byte(rest, i) == 32 or str_byte(rest, i) == 9 do
      spaces_after = spaces_after + 1
      i = i + 1
    end
    after = str_sub(rest, i)
    return "bullet", bullet, nil, after, indent + 1 + spaces_after
  end
  -- Ordered list: digits followed by . or ) then space.
  local num_str, delim = rest:match("^(%d+)([%.%)])")
  if num_str and #num_str <= 9 then
    local i = #num_str + 2  -- after digit(s) + delimiter
    local spaces_after = 0
    while str_byte(rest, i) == 32 or str_byte(rest, i) == 9 do
      spaces_after = spaces_after + 1
      i = i + 1
    end
    if spaces_after == 0 then return nil end  -- must have at least one space
    local after = str_sub(rest, i)
    return "ordered", delim, tonumber(num_str), after, indent + #num_str + 1 + spaces_after
  end
  return nil
end

-- Collect a definition line: [label]: url "optional title"
-- Returns label, url, title or nil.
local function match_definition(line)
  local label, rest = line:match("^%s*%[(.-)%]:%s*(.*)")
  if not label then return nil end
  if #label == 0 then return nil end
  -- url may be <...> or bare word (no spaces).
  local url, after
  if str_byte(rest, 1) == 60 then  -- '<'
    url, after = rest:match("^<([^>]*)>%s*(.*)")
    if not url then return nil end
  else
    url, after = rest:match("^(%S+)%s*(.*)")
    if not url then return nil end
  end
  -- Optional title: "...", '...', (...).
  local title
  if after and #after > 0 then
    title = after:match('^"(.-)"$')
      or after:match("^'(.-)'$")
      or after:match("^%((.-)%)$")
  end
  return label:lower(), url, title
end

-- ── Block parser ──────────────────────────────────────────────────────────────

-- Forward declare parse_blocks for mutual recursion.
local parse_blocks

-- Parse a sequence of lines into block nodes.
-- `lines` is an array of strings, `i` is the starting index, `j` is the end index.
-- Returns array of block nodes.
parse_blocks = function(lines, i, j)
  local nodes = {}
  -- Collect link definitions into a table passed through inline parsing.
  local defs = {}

  local function add(node)
    nodes[#nodes + 1] = node
  end

  while i <= j do
    local line = lines[i]

    -- 1. Blank line: skip.
    if is_blank(line) then
      i = i + 1

    -- 2. ATX heading.
    elseif match_atx_heading(line) then
      local depth, content = match_atx_heading(line)
      add({ type = "heading", depth = depth, _raw = content, children = nil })
      i = i + 1

    -- 3. Thematic break.
    elseif is_thematic_break(line) then
      add({ type = "thematicBreak" })
      i = i + 1

    -- 4. Fenced code block.
    elseif match_fence_open(line) then
      local fence_ch, fence_len, info_str, fence_indent = match_fence_open(line)
      local code_lines = {}
      i = i + 1
      while i <= j do
        local l = lines[i]
        -- Closing fence: same or more chars, optionally indented.
        local cl_indent, cl_col = count_indent(l)
        local cl_rest = str_sub(l, cl_col)
        local cl_fence = cl_rest:match("^(" .. str_rep(fence_ch == "`" and "`" or "~", fence_len) .. "+)%s*$")
        if cl_indent <= 3 and cl_fence and #cl_fence >= fence_len then
          i = i + 1
          break
        end
        -- Strip up to fence_indent leading spaces.
        code_lines[#code_lines + 1] = strip_indent(l, fence_indent)
        i = i + 1
      end
      local lang = (info_str ~= "") and info_str or nil
      -- lang is first word of info string.
      if lang then lang = lang:match("^(%S+)") end
      add({ type = "code", lang = lang, value = tbl_concat(code_lines, "\n") })

    -- 5. Indented code block (4 spaces or 1 tab).
    elseif count_indent(line) >= 4 then
      local code_lines = {}
      while i <= j do
        local l = lines[i]
        local ind = count_indent(l)
        if ind >= 4 then
          code_lines[#code_lines + 1] = strip_indent(l, 4)
          i = i + 1
        elseif is_blank(l) then
          -- Blank lines are included but trailing blanks are stripped.
          code_lines[#code_lines + 1] = ""
          i = i + 1
        else
          break
        end
      end
      -- Strip trailing blank lines.
      while #code_lines > 0 and code_lines[#code_lines] == "" do
        code_lines[#code_lines] = nil
      end
      add({ type = "code", lang = nil, value = tbl_concat(code_lines, "\n") })

    -- 6. Blockquote.
    elseif match_blockquote(line) then
      -- Collect all consecutive blockquote lines (lazy continuation allowed).
      local bq_lines = {}
      while i <= j do
        local l = lines[i]
        local bq_content = match_blockquote(l)
        if bq_content then
          bq_lines[#bq_lines + 1] = bq_content
          i = i + 1
        elseif is_blank(l) then
          -- Blank line: end of blockquote.
          break
        else
          -- Lazy continuation: non-blank line without > is part of blockquote
          -- if we're in an open paragraph. Simpler: stop at non-> non-blank.
          break
        end
      end
      local bq_children = parse_blocks(bq_lines, 1, #bq_lines)
      add({ type = "blockquote", children = bq_children })

    -- 7. HTML block (starts with <).
    elseif line:match("^%s*<") then
      -- Collect until blank line.
      local html_lines = {}
      while i <= j and not is_blank(lines[i]) do
        html_lines[#html_lines + 1] = lines[i]
        i = i + 1
      end
      add({ type = "html", value = tbl_concat(html_lines, "\n") })

    -- 8. Link definition: [label]: url
    elseif line:match("^%s*%[.-%]:") and match_definition(line) then
      local label, url, title = match_definition(line)
      defs[label] = { url = url, title = title }
      add({ type = "definition", label = label, url = url, title = title })
      i = i + 1

    -- 9. List.
    elseif match_list_item(line) then
      local list_type, marker_char, start_num, first_content, marker_width = match_list_item(line)
      local ordered = (list_type == "ordered")
      local list_node = {
        type = "list",
        ordered = ordered,
        start = ordered and start_num or nil,
        children = {}
      }

      -- Parse list items.
      while i <= j do
        local l = lines[i]
        if is_blank(l) then
          i = i + 1
          -- Blank line: skip, but next item might continue or end.
          break
        end
        local item_type, item_marker, item_num, item_content, item_width = match_list_item(l)
        if not item_type then break end
        -- Must be same list type.
        if item_type ~= list_type then break end
        -- Ordered: delimiter must match.
        if ordered and item_marker ~= marker_char then break end
        -- Bullet: marker char must match.
        if not ordered and item_marker ~= marker_char then break end

        -- Collect item lines.
        local item_lines = { item_content }
        i = i + 1
        -- Continuation lines: indented by at least marker_width spaces.
        while i <= j do
          local cl = lines[i]
          if is_blank(cl) then
            item_lines[#item_lines + 1] = ""
            i = i + 1
            -- Check if next non-blank line is continuation.
            local ni = i
            while ni <= j and is_blank(lines[ni]) do ni = ni + 1 end
            if ni > j then break end
            local next_indent = count_indent(lines[ni])
            if next_indent >= item_width then
              -- Continuation after blank; blanks already added.
            else
              break
            end
          else
            local cl_indent = count_indent(cl)
            if cl_indent >= item_width then
              item_lines[#item_lines + 1] = strip_indent(cl, item_width)
              i = i + 1
            else
              break
            end
          end
        end

        -- Strip trailing blanks from item_lines.
        while #item_lines > 0 and item_lines[#item_lines] == "" do
          item_lines[#item_lines] = nil
        end

        local item_children = parse_blocks(item_lines, 1, #item_lines)
        local item_node = { type = "listItem", checked = nil, children = item_children }
        list_node.children[#list_node.children + 1] = item_node

        -- After item, check for blank line before next.
        if i <= j and is_blank(lines[i]) then
          i = i + 1
          break
        end
      end

      add(list_node)

      -- Continue to next list item(s) via outer while loop if same list type continues.
      -- (Handled by jumping back to top of while loop.)

    -- 10. Paragraph (catch-all).
    else
      local para_lines = {}
      while i <= j do
        local l = lines[i]
        if is_blank(l) then
          break
        end
        -- Interrupt paragraph: heading, thematic break, fenced code, list, blockquote.
        if match_atx_heading(l) or is_thematic_break(l) or match_fence_open(l)
            or match_blockquote(l) or match_list_item(l) then
          break
        end
        para_lines[#para_lines + 1] = l
        i = i + 1
      end
      if #para_lines > 0 then
        local raw = tbl_concat(para_lines, "\n")
        add({ type = "paragraph", _raw = raw, children = nil })
      end
    end
  end

  return nodes, defs
end

-- ── Inline parsing ────────────────────────────────────────────────────────────

-- Parse inline content from a string. Returns array of inline nodes.
-- Uses a delimiter-stack approach for emphasis/strong.

local parse_inlines  -- forward declaration

-- Scan for a backtick run starting at `pos` in `src`.
-- Returns the closing position (after the closing backticks) and the content, or nil.
local function scan_code_span(src, pos, tick_len)
  local len = #src
  local pattern = str_rep("`", tick_len)
  local i = pos
  while i <= len do
    local s, e = str_find(src, pattern, i, true)
    if not s then break end
    -- Make sure we don't match a longer run.
    local before_ok = (s == 1) or (str_byte(src, s - 1) ~= 96)
    local after_ok  = (e == len) or (str_byte(src, e + 1) ~= 96)
    if before_ok and after_ok then
      local content = str_sub(src, pos, s - 1)
      -- Normalize: collapse internal newlines to spaces, strip one leading+trailing space if both present.
      content = content:gsub("\n", " ")
      if content:match("^ .+ $") then
        content = str_sub(content, 2, -2)
      end
      return e + 1, content
    end
    i = e + 1
  end
  return nil
end

-- Try to parse a link/image destination and title starting at pos (after '[...](').
-- src[pos] should be '('. Returns url, title, end_pos or nil.
local function parse_link_dest(src, pos)
  if str_byte(src, pos) ~= 40 then return nil end  -- '('
  pos = pos + 1
  local len = #src
  -- Skip whitespace.
  while pos <= len and (str_byte(src, pos) == 32 or str_byte(src, pos) == 9) do
    pos = pos + 1
  end
  -- URL: either <...> or run of non-whitespace, non-paren chars (balanced parens allowed).
  local url
  if pos <= len and str_byte(src, pos) == 60 then  -- '<'
    local e = str_find(src, ">", pos + 1, true)
    if not e then return nil end
    url = str_sub(src, pos + 1, e - 1)
    pos = e + 1
  else
    -- Bare URL: stop at space, ), EOF. Allow balanced parens.
    local depth = 0
    local start = pos
    while pos <= len do
      local b = str_byte(src, pos)
      if b == 40 then       -- '('
        depth = depth + 1
        pos = pos + 1
      elseif b == 41 then   -- ')'
        if depth == 0 then break end
        depth = depth - 1
        pos = pos + 1
      elseif b == 32 or b == 9 or b == 10 then
        break
      else
        pos = pos + 1
      end
    end
    url = str_sub(src, start, pos - 1)
  end
  -- Skip whitespace.
  while pos <= len and (str_byte(src, pos) == 32 or str_byte(src, pos) == 9) do
    pos = pos + 1
  end
  -- Optional title: "...", '...', (...).
  local title
  if pos <= len then
    local b = str_byte(src, pos)
    if b == 34 or b == 39 then  -- " or '
      local closer = b
      local start_t = pos + 1
      pos = pos + 1
      while pos <= len and str_byte(src, pos) ~= closer do
        pos = pos + 1
      end
      if pos <= len then
        title = str_sub(src, start_t, pos - 1)
        pos = pos + 1
      end
    elseif b == 40 then  -- (
      local start_t = pos + 1
      pos = pos + 1
      while pos <= len and str_byte(src, pos) ~= 41 do
        pos = pos + 1
      end
      if pos <= len then
        title = str_sub(src, start_t, pos - 1)
        pos = pos + 1
      end
    end
  end
  -- Skip whitespace.
  while pos <= len and (str_byte(src, pos) == 32 or str_byte(src, pos) == 9) do
    pos = pos + 1
  end
  -- Expect ')'.
  if pos > len or str_byte(src, pos) ~= 41 then return nil end
  return url, title, pos + 1
end

-- Delimiter stack entry: { char, count, pos, can_open, can_close }
-- For emphasis/strong processing after tokenizing.

-- Simple inline tokenizer: produces a flat list of tokens, then resolves delimiters.
-- Token types: "text", "code", "hardbreak", "softbreak", "delim", "link_open", "link_close", "image_open"

local function tokenize_inlines(src)
  local tokens = {}
  local len = #src
  local pos = 1
  local text_start = 1

  local function flush_text(upto)
    if upto > text_start then
      tokens[#tokens + 1] = { type = "text", value = str_sub(src, text_start, upto - 1) }
    end
  end

  while pos <= len do
    local b = str_byte(src, pos)

    -- Backtick: code span.
    if b == 96 then
      flush_text(pos)
      -- Count backtick run.
      local tick_start = pos
      while pos <= len and str_byte(src, pos) == 96 do pos = pos + 1 end
      local tick_len = pos - tick_start
      local end_pos, content = scan_code_span(src, pos, tick_len)
      if end_pos then
        tokens[#tokens + 1] = { type = "code", value = content }
        pos = end_pos
      else
        -- No matching closing backticks: emit as text.
        tokens[#tokens + 1] = { type = "text", value = str_sub(src, tick_start, pos - 1) }
      end
      text_start = pos

    -- Backslash: hard break or escape.
    elseif b == 92 then  -- '\'
      flush_text(pos)
      local next_b = str_byte(src, pos + 1)
      if next_b == 10 then  -- '\n' → hard break.
        tokens[#tokens + 1] = { type = "hardbreak" }
        pos = pos + 2
      elseif next_b then
        -- Escaped character: emit as text.
        tokens[#tokens + 1] = { type = "text", value = str_char(next_b) }
        pos = pos + 2
      else
        tokens[#tokens + 1] = { type = "text", value = "\\" }
        pos = pos + 1
      end
      text_start = pos

    -- Newline: soft break or hard break (two spaces + newline).
    elseif b == 10 then
      -- Check for two trailing spaces before the \n.
      local is_hard = (pos >= 3 and str_byte(src, pos - 1) == 32 and str_byte(src, pos - 2) == 32)
      -- Flush text up to (and not including) the trailing spaces for hard break.
      if is_hard then
        flush_text(pos - 2)
        tokens[#tokens + 1] = { type = "hardbreak" }
      else
        flush_text(pos)
        tokens[#tokens + 1] = { type = "softbreak" }
      end
      pos = pos + 1
      text_start = pos

    -- Asterisk or underscore: potential emphasis/strong delimiter.
    elseif b == 42 or b == 95 then  -- '*' or '_'
      flush_text(pos)
      local delim_start = pos
      local delim_char = b
      while pos <= len and str_byte(src, pos) == delim_char do pos = pos + 1 end
      local delim_count = pos - delim_start
      -- Determine can_open / can_close per CommonMark rules (simplified).
      local before_b = (delim_start > 1) and str_byte(src, delim_start - 1) or 0
      local after_b  = (pos <= len) and str_byte(src, pos) or 0
      local function is_ws_or_eol(c) return c == 0 or c == 32 or c == 9 or c == 10 end
      local function is_punct(c)
        return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or
               (c >= 91 and c <= 96) or (c >= 123 and c <= 126)
      end
      local left_flanking = not is_ws_or_eol(after_b) and
        (not is_punct(after_b) or is_ws_or_eol(before_b) or is_punct(before_b))
      local right_flanking = not is_ws_or_eol(before_b) and
        (not is_punct(before_b) or is_ws_or_eol(after_b) or is_punct(after_b))
      local can_open, can_close
      if delim_char == 42 then  -- *
        can_open  = left_flanking
        can_close = right_flanking
      else  -- _
        can_open  = left_flanking and (not right_flanking or is_punct(before_b))
        can_close = right_flanking and (not left_flanking or is_punct(after_b))
      end
      tokens[#tokens + 1] = {
        type = "delim",
        char = delim_char,
        count = delim_count,
        can_open = can_open,
        can_close = can_close,
      }
      text_start = pos

    -- '[': potential link or image open.
    elseif b == 91 then  -- '['
      flush_text(pos)
      local is_image = (pos > 1 and str_byte(src, pos - 1) == 33)  -- '!'
      -- Remove the '!' from previous text token if image.
      if is_image and #tokens > 0 and tokens[#tokens].type == "text" then
        local tv = tokens[#tokens].value
        if #tv > 0 and str_byte(tv, #tv) == 33 then
          tokens[#tokens].value = str_sub(tv, 1, #tv - 1)
          if tokens[#tokens].value == "" then table.remove(tokens) end
        end
      end
      tokens[#tokens + 1] = { type = is_image and "image_open" or "link_open", pos = pos }
      pos = pos + 1
      text_start = pos

    -- ']': potential link close + destination.
    elseif b == 93 then  -- ']'
      flush_text(pos)
      pos = pos + 1
      -- Try to parse (url "title") immediately.
      local url, title, end_pos = parse_link_dest(src, pos)
      if url ~= nil then
        tokens[#tokens + 1] = { type = "link_close", url = url, title = title }
        pos = end_pos
      else
        -- No destination: treat as text.
        tokens[#tokens + 1] = { type = "text", value = "]" }
      end
      text_start = pos

    else
      pos = pos + 1
    end
  end

  flush_text(pos)
  return tokens
end

-- Resolve delimiter tokens into emphasis/strong nodes.
-- Also resolves link/image open-close pairs.
-- Returns array of inline nodes.
local function resolve_inlines(tokens)
  local result = {}

  -- First pass: resolve links/images.
  -- Find matching link_open for each link_close.
  local n = #tokens
  local i = 1
  local resolved = {}  -- new token list after link resolution

  -- We need to track bracket stack.
  local bracket_stack = {}  -- stack of indices into `tokens` where link_open/image_open appear

  while i <= n do
    local tok = tokens[i]
    if tok.type == "link_open" or tok.type == "image_open" then
      bracket_stack[#bracket_stack + 1] = { idx = #resolved + 1, is_image = tok.type == "image_open" }
      resolved[#resolved + 1] = tok
      i = i + 1
    elseif tok.type == "link_close" then
      if #bracket_stack > 0 then
        local frame = bracket_stack[#bracket_stack]
        bracket_stack[#bracket_stack] = nil
        -- Collect content tokens between frame.idx and current position.
        local inner_tokens = {}
        for k = frame.idx + 1, #resolved do
          inner_tokens[#inner_tokens + 1] = resolved[k]
        end
        -- Remove the bracket open and everything after from resolved.
        for k = #resolved, frame.idx, -1 do
          resolved[k] = nil
        end
        -- Recursively resolve inner tokens (for nested emphasis, etc.).
        -- But we can't call resolve_inlines here without risk; just use them directly.
        local node_type = frame.is_image and "image" or "link"
        local link_node = {
          type = node_type,
          url = tok.url,
          title = tok.title,
          children = resolve_inlines(inner_tokens),
        }
        if frame.is_image then
          -- For images, children → alt text; follow mdast: alt is in children as text.
          link_node.alt = nil  -- computed from children by caller if needed
        end
        resolved[#resolved + 1] = { type = "node", node = link_node }
      else
        -- Unmatched ]: emit as text.
        resolved[#resolved + 1] = { type = "text", value = "]" }
        if tok.url then
          resolved[#resolved + 1] = { type = "text", value = "(" .. tok.url .. ")" }
        end
      end
      i = i + 1
    else
      resolved[#resolved + 1] = tok
      i = i + 1
    end
  end

  -- Unmatched link/image opens: convert to text '['.
  for _, frame in ipairs(bracket_stack) do
    resolved[frame.idx].type = "text"
    resolved[frame.idx].value = (resolved[frame.idx].type == "image_open") and "![" or "["
  end

  -- Second pass: resolve emphasis/strong delimiters.
  -- We walk the resolved token list and use the opener stack algorithm.
  local out = {}       -- final inline nodes
  local delim_stack = {}  -- stack of { idx_in_out, char, count, can_open, can_close }

  local function emit(node)
    out[#out + 1] = node
  end

  local function emit_text(v)
    -- Merge with previous text node if possible.
    if #out > 0 and out[#out].type == "text" then
      out[#out].value = out[#out].value .. v
    else
      out[#out + 1] = { type = "text", value = v }
    end
  end

  for _, tok in ipairs(resolved) do
    if tok.type == "text" then
      if tok.value and tok.value ~= "" then emit_text(tok.value) end
    elseif tok.type == "code" then
      emit({ type = "inlineCode", value = tok.value })
    elseif tok.type == "hardbreak" then
      emit({ type = "break" })
    elseif tok.type == "softbreak" then
      -- Soft break: emit as space for simplicity (CommonMark allows renderer choice).
      emit_text(" ")
    elseif tok.type == "node" then
      emit(tok.node)
    elseif tok.type == "link_open" or tok.type == "image_open" then
      -- Unmatched opens (bracket_stack cleanup above should have handled most).
      emit_text(tok.type == "image_open" and "![" or "[")
    elseif tok.type == "delim" then
      -- Closer: look back through delimiter stack for matching opener.
      if tok.can_close then
        local found = nil
        for di = #delim_stack, 1, -1 do
          local d = delim_stack[di]
          if d.char == tok.char and d.can_open then
            found = di
            break
          end
        end
        if found then
          local opener = delim_stack[found]
          -- How many chars to use: 1 (emphasis) or 2 (strong), prefer 2.
          local use = (opener.count >= 2 and tok.count >= 2) and 2 or 1
          local node_type = use == 2 and "strong" or "emphasis"
          -- Collect all out[] entries after opener.idx_in_out as children.
          local children = {}
          for k = opener.idx_in_out + 1, #out do
            children[#children + 1] = out[k]
          end
          -- Trim out back to opener position.
          for k = #out, opener.idx_in_out, -1 do
            out[k] = nil
          end
          -- If opener had remaining delims, emit them as text before the node.
          local rem_open = opener.count - use
          if rem_open > 0 then
            emit_text(str_rep(str_char(tok.char), rem_open))
          end
          emit({ type = node_type, children = children })
          -- Remove delimiter stack entries from found onward.
          for k = #delim_stack, found, -1 do
            delim_stack[k] = nil
          end
          -- If closer has remaining delims, re-process as new closer.
          local rem_close = tok.count - use
          if rem_close > 0 then
            -- Push as a new text delimiter opportunity.
            local new_tok = {
              type = "delim",
              char = tok.char,
              count = rem_close,
              can_open = tok.can_open,
              can_close = tok.can_close,
            }
            -- Re-add to end of out as placeholder for next closer search.
            -- Simplification: just emit as text (gives correct output for common cases).
            emit_text(str_rep(str_char(tok.char), rem_close))
          end
        else
          -- No matching opener: emit as text.
          emit_text(str_rep(str_char(tok.char), tok.count))
        end
      else
        -- Opener (or neither): push to delimiter stack.
        local idx = #out + 1  -- position after which children will be inserted
        -- Emit a placeholder text (will be removed if matched later).
        out[#out + 1] = { type = "_delim_placeholder", char = tok.char, count = tok.count }
        delim_stack[#delim_stack + 1] = {
          idx_in_out = idx,
          char = tok.char,
          count = tok.count,
          can_open = tok.can_open,
          can_close = tok.can_close,
        }
      end
    end
  end

  -- Unmatched openers: convert placeholders to text.
  for _, d in ipairs(delim_stack) do
    local placeholder = out[d.idx_in_out]
    if placeholder and placeholder.type == "_delim_placeholder" then
      placeholder.type = "text"
      placeholder.value = str_rep(str_char(d.char), d.count)
    end
  end

  -- Final merge pass: remove empty text nodes, merge adjacent text.
  result = {}
  for _, node in ipairs(out) do
    if node.type == "text" and (not node.value or node.value == "") then
      -- skip
    elseif node.type == "text" and #result > 0 and result[#result].type == "text" then
      result[#result].value = result[#result].value .. node.value
    else
      result[#result + 1] = node
    end
  end

  return result
end

parse_inlines = function(src)
  if not src or src == "" then return {} end
  local tokens = tokenize_inlines(src)
  return resolve_inlines(tokens)
end

-- ── Phase 2: inline expansion pass ────────────────────────────────────────────

-- Walk block tree and fill `children` for nodes that have `_raw`.
local function expand_inlines(nodes)
  for _, node in ipairs(nodes) do
    if node.type == "heading" or node.type == "paragraph" then
      node.children = parse_inlines(node._raw or "")
      node._raw = nil
    elseif node.children then
      expand_inlines(node.children)
    end
  end
end

-- ── Public API ─────────────────────────────────────────────────────────────────

-- Parse a Markdown string and return an mdast Root node.
M.parse = function(src)
  if type(src) ~= "string" then
    return nil, "mdast.parse: expected string, got " .. type(src)
  end
  local lines = split_lines(src)
  local blocks, defs = parse_blocks(lines, 1, #lines)
  expand_inlines(blocks)
  return {
    type = "root",
    children = blocks,
    _defs = defs,  -- link reference definitions (internal, for future use)
  }
end

-- ── Stringify (basic round-trip) ───────────────────────────────────────────────

local stringify_node  -- forward declaration

local function stringify_children(children, sep)
  if not children then return "" end
  local parts = {}
  for _, child in ipairs(children) do
    parts[#parts + 1] = stringify_node(child)
  end
  return tbl_concat(parts, sep or "")
end

stringify_node = function(node)
  local t = node.type
  if t == "root" then
    return stringify_children(node.children, "\n\n")
  elseif t == "heading" then
    return str_rep("#", node.depth) .. " " .. stringify_children(node.children)
  elseif t == "paragraph" then
    return stringify_children(node.children)
  elseif t == "text" then
    return node.value or ""
  elseif t == "inlineCode" then
    return "`" .. (node.value or "") .. "`"
  elseif t == "code" then
    local fence = "```"
    local lang = node.lang or ""
    return fence .. lang .. "\n" .. (node.value or "") .. "\n" .. fence
  elseif t == "emphasis" then
    return "*" .. stringify_children(node.children) .. "*"
  elseif t == "strong" then
    return "**" .. stringify_children(node.children) .. "**"
  elseif t == "link" then
    return "[" .. stringify_children(node.children) .. "](" .. (node.url or "") ..
      (node.title and (' "' .. node.title .. '"') or "") .. ")"
  elseif t == "image" then
    return "![" .. stringify_children(node.children) .. "](" .. (node.url or "") ..
      (node.title and (' "' .. node.title .. '"') or "") .. ")"
  elseif t == "thematicBreak" then
    return "---"
  elseif t == "blockquote" then
    local inner = stringify_children(node.children, "\n\n")
    local lines = {}
    for _, l in ipairs(split_lines(inner)) do
      lines[#lines + 1] = "> " .. l
    end
    return tbl_concat(lines, "\n")
  elseif t == "list" then
    local parts = {}
    for idx, item in ipairs(node.children) do
      local prefix = node.ordered and (tostring((node.start or 1) + idx - 1) .. ". ") or "- "
      local content = stringify_children(item.children, "\n\n")
      -- Indent continuation lines.
      local indent = str_rep(" ", #prefix)
      local item_lines = split_lines(content)
      local item_str = prefix .. (item_lines[1] or "")
      for k = 2, #item_lines do
        item_str = item_str .. "\n" .. indent .. item_lines[k]
      end
      parts[#parts + 1] = item_str
    end
    return tbl_concat(parts, "\n")
  elseif t == "listItem" then
    return stringify_children(node.children, "\n\n")
  elseif t == "html" then
    return node.value or ""
  elseif t == "definition" then
    return "[" .. (node.label or "") .. "]: " .. (node.url or "") ..
      (node.title and (' "' .. node.title .. '"') or "")
  elseif t == "break" then
    return "\\\n"
  else
    return ""
  end
end

M.stringify = stringify_node

return M
