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
-- Must have <= 3 spaces of leading indent.
local function is_thematic_break(line)
  local indent, col = count_indent(line)
  if indent > 3 then return false end
  local stripped = str_sub(line, col):match("^(.-)%s*$") or str_sub(line, col)
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
-- Allows up to 3 spaces of leading indent.
local function match_atx_heading(line)
  local indent, col = count_indent(line)
  if indent > 3 then return nil end
  local stripped = str_sub(line, col)
  local hashes = stripped:match("^(#+)")
  if not hashes or #hashes > 6 then return nil end
  local depth = #hashes
  -- Must be followed by space/tab or end of line.
  local after_hashes = str_sub(stripped, depth + 1)
  if after_hashes == "" or after_hashes:match("^%s*$") then
    -- Heading with no content.
    return depth, ""
  end
  local first_ch = str_byte(after_hashes, 1)
  if first_ch ~= 32 and first_ch ~= 9 then
    -- Not a heading (no space after hashes).
    return nil
  end
  -- Content: strip leading/trailing spaces.
  local rest = after_hashes:match("^%s+(.-)%s*$") or ""
  -- Strip optional closing sequence: trailing space + 1+ hashes + optional spaces.
  -- Rule: trailing # sequence is only stripped if preceded by a space.
  if rest:match("%s+#+%s*$") then
    local closed = rest:match("^(.-)%s+#+%s*$")
    if closed ~= nil then rest = closed end
  elseif rest:match("^#+%s*$") then
    rest = ""
  end
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
  -- Bullet list: -, +, * followed by space/tab or at end-of-line (empty item).
  local bullet = rest:match("^([%-%+%*])$")  -- bare marker at EOL = empty item
  if bullet then
    return "bullet", bullet, nil, "", indent + 2
  end
  bullet = rest:match("^([%-%+%*])[ \t]")
  if bullet then
    -- Count extra spaces after the mandatory space (CommonMark: 1-4 spaces total).
    -- rest[1]=bullet, rest[2]=mandatory_space, rest[3+]=extra_spaces/content.
    local spaces_after = 1  -- mandatory space counts as 1
    local i = 3             -- start after the mandatory space
    while (str_byte(rest, i) == 32 or str_byte(rest, i) == 9) and spaces_after < 4 do
      spaces_after = spaces_after + 1
      i = i + 1
    end
    local after = str_sub(rest, i)
    -- If after is empty (trailing spaces only), use minimum iwidth (indent + 2).
    local iw = after == "" and (indent + 2) or (indent + 1 + spaces_after)
    return "bullet", bullet, nil, after, iw
  end
  -- Ordered list: digits followed by . or ) then space.
  local num_str, delim = rest:match("^(%d+)([%.%)])")
  if num_str and #num_str <= 9 then
    local i = #num_str + 2  -- after digit(s) + delimiter
    -- Check for bare marker at EOL (empty ordered item).
    if i > #rest then
      return "ordered", delim, tonumber(num_str), "", indent + #num_str + 2
    end
    local spaces_after = 0
    while str_byte(rest, i) == 32 or str_byte(rest, i) == 9 do
      spaces_after = spaces_after + 1
      i = i + 1
    end
    if spaces_after == 0 then return nil end  -- must have at least one space
    local after = str_sub(rest, i)
    -- If after is empty (trailing spaces only), use minimum iwidth (indent + marker + 2).
    local iw = after == "" and (indent + #num_str + 2) or (indent + #num_str + 1 + spaces_after)
    return "ordered", delim, tonumber(num_str), after, iw
  end
  return nil
end

-- Collect a definition line: [label]: url "optional title"
-- Returns label, url, title or nil.
local function match_definition(line)
  local label, rest = line:match("^%s*%[(.-)%]:%s*(.*)")
  if not label then return nil end
  if #label == 0 then return nil end
  -- Labels cannot contain unescaped '[' or ']' (CommonMark §4.7).
  -- An unescaped bracket is one not preceded by '\'.
  -- Check for unescaped brackets by scanning the label string.
  do
    local llen = #label
    local li = 1
    while li <= llen do
      local lb = str_byte(label, li)
      if lb == 92 then  -- backslash: skip next char
        li = li + 2
      elseif lb == 91 or lb == 93 then  -- unescaped '[' or ']'
        return nil
      else
        li = li + 1
      end
    end
  end
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
-- Returns: array of block nodes, defs table, had_top_blank (blank between top-level blocks).
parse_blocks = function(lines, i, j)
  local nodes = {}
  -- Collect link definitions into a table passed through inline parsing.
  local defs = {}
  -- Track whether a blank line appeared between top-level blocks.
  local had_top_blank = false
  local last_was_blank = false

  local function add(node)
    if last_was_blank and #nodes > 0 then had_top_blank = true end
    nodes[#nodes + 1] = node
    last_was_blank = false
  end

  while i <= j do
    local line = lines[i]

    -- 1. Blank line: skip.
    if is_blank(line) then
      last_was_blank = true
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
      -- Lazy continuation: a non-> non-blank line can continue a blockquote
      -- if it would not start a new block structure (i.e., is paragraph text).
      local bq_lines = {}
      local last_was_para = false  -- tracks if last non-blank BQ line was paragraph text
      while i <= j do
        local l = lines[i]
        local bq_content = match_blockquote(l)
        if bq_content then
          bq_lines[#bq_lines + 1] = bq_content
          -- Is this line paragraph-continuation content (not a block-level interrupt)?
          last_was_para = not (match_atx_heading(bq_content) or is_thematic_break(bq_content)
            or match_fence_open(bq_content) or count_indent(bq_content) >= 4
            or is_blank(bq_content))
          i = i + 1
        elseif is_blank(l) then
          -- Blank line terminates blockquote (no lazy continuation across blank).
          break
        elseif last_was_para and not match_atx_heading(l) and not is_thematic_break(l)
            and not match_fence_open(l) and not match_blockquote(l)
            and not match_list_item(l) then
          -- Lazy continuation: treat as paragraph continuation inside blockquote.
          -- Note: even 4+-space indented lines can lazily continue (they're paragraph text,
          -- not code blocks in this context).
          bq_lines[#bq_lines + 1] = l
          last_was_para = true
          i = i + 1
        else
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
    -- First definition wins (subsequent definitions for same label are ignored).
    elseif line:match("^%s*%[.-%]:") and match_definition(line) then
      local label, url, title = match_definition(line)
      if not defs[label] then
        defs[label] = { url = url, title = title }
      end
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
        _loose = false,
        children = {}
      }

      local prev_blank = false

      while i <= j do
        -- Skip leading blank lines; detect loose.
        if is_blank(lines[i]) then
          local ni = i
          while ni <= j and is_blank(lines[ni]) do ni = ni + 1 end
          if ni > j then break end
          local nt, nm = match_list_item(lines[ni])
          local same = (nt == list_type) and
            ((ordered and nm == marker_char) or (not ordered and nm == marker_char))
          if not same then break end
          list_node._loose = true
          prev_blank = true
          i = ni
        end
        if i > j then break end

        -- Thematic breaks and ATX headings always interrupt a list.
        if is_thematic_break(lines[i]) or match_atx_heading(lines[i]) then break end

        local it, im, inum, icont, iwidth = match_list_item(lines[i])
        if not it or it ~= list_type then break end
        if ordered and im ~= marker_char then break end
        if not ordered and im ~= marker_char then break end

        if prev_blank then list_node._loose = true end
        prev_blank = false

        local item_lines = {}
        if icont ~= nil then item_lines[1] = icont end
        i = i + 1

        local item_blank = false
        while i <= j do
          local cl = lines[i]
          if is_blank(cl) then
            local ni = i + 1
            while ni <= j and is_blank(lines[ni]) do ni = ni + 1 end
            if ni > j then break end
            local nind = count_indent(lines[ni])
            local nt2, nm2 = match_list_item(lines[ni])
            local next_same = (nt2 == list_type) and
              ((ordered and nm2 == marker_char) or (not ordered and nm2 == marker_char))
            -- For a truly empty item (no non-empty content yet), a blank line ends it.
            local has_content = false
            for _, il in ipairs(item_lines) do
              if il ~= "" then has_content = true; break end
            end
            if nind >= iwidth and has_content then
              item_lines[#item_lines + 1] = ""
              item_blank = true
              i = i + 1
            elseif next_same then
              break
            else
              break
            end
          else
            local cind = count_indent(cl)
            if cind >= iwidth then
              item_lines[#item_lines + 1] = strip_indent(cl, iwidth)
              i = i + 1
            elseif #item_lines > 0 and item_lines[#item_lines] ~= "" then
              -- Lazy continuation: the last item line is non-blank (we're inside a paragraph).
              -- Check the line can lazily continue (not a block-level interrupt).
              local lrest = str_sub(cl, cind + 1)  -- stripped content
              local can_lazy = true
              -- Cannot lazy-continue past a blank line, ATX heading, thematic break,
              -- fenced code, or block quote (these are hard stops).
              if is_blank(cl) then can_lazy = false
              elseif lrest:match("^#{1,6}[ \t]") or lrest:match("^#{1,6}$") then can_lazy = false  -- ATX heading
              elseif lrest:match("^[-*_][ \t]*[-*_][ \t]*[-*_]") then can_lazy = false  -- thematic break
              elseif lrest:match("^[`~][`~][`~]") then can_lazy = false  -- fenced code
              elseif lrest:match("^>") then can_lazy = false  -- block quote
              elseif match_list_item(cl) then can_lazy = false  -- another list item
              end
              if can_lazy then
                -- Strip the line's actual indentation and include as lazy continuation.
                item_lines[#item_lines + 1] = lrest
                i = i + 1
              else
                break
              end
            else
              break
            end
          end
        end

        -- (item_blank not used to set list loose here; list loose comes from
        --  prev_blank between siblings or from item looseness computed below)

        while #item_lines > 0 and item_lines[#item_lines] == "" do
          item_lines[#item_lines] = nil
        end

        local ich, _, item_had_top_blank = parse_blocks(item_lines, 1, #item_lines)
        -- Item is loose if its direct block children are separated by blank lines.
        local item_loose = item_had_top_blank
        list_node.children[#list_node.children + 1] = {
          type = "listItem", checked = nil, _loose = item_loose, children = ich
        }
      end

      add(list_node)

    -- 10. Paragraph (catch-all) — also handles setext headings.
    else
      local para_lines = {}
      while i <= j do
        local l = lines[i]
        if is_blank(l) then break end
        -- Setext heading underline check (only when we have para content already).
        if #para_lines > 0 then
          local si, sc = count_indent(l)
          if si <= 3 then
            local sr = str_sub(l, sc):match("^(.-)%s*$") or str_sub(l, sc)
            local sch = (sr ~= "" and sr:match("^[=]+$") and "=")
              or (sr ~= "" and sr:match("^[-]+$") and "-") or nil
            if sch then
              local depth = (sch == "=") and 1 or 2
              add({ type = "heading", depth = depth,
                    _raw = tbl_concat(para_lines, "\n"), children = nil })
              i = i + 1
              para_lines = {}
              break
            end
          end
        end
        -- Interrupt: ATX heading, thematic break, fenced code, blockquote.
        if match_atx_heading(l) or is_thematic_break(l) or match_fence_open(l)
            or match_blockquote(l) then
          break
        end
        -- List items interrupt paragraphs (unordered always; ordered only if start=1).
        -- Exception: empty list items (bare markers) cannot interrupt a paragraph.
        if #para_lines > 0 then
          local lt, lm, ln, lcont = match_list_item(l)
          local is_empty = lcont == nil or lcont == ""
          if not is_empty then
            if lt == "bullet" or (lt == "ordered" and ln == 1) then break end
          end
        end
        -- Strip up to 3 leading spaces from paragraph lines.
        local sl = strip_indent(l, math.min(count_indent(l), 3))
        para_lines[#para_lines + 1] = sl
        i = i + 1
      end
      if #para_lines > 0 then
        add({ type = "paragraph", _raw = tbl_concat(para_lines, "\n"), children = nil })
      end
    end
  end

  return nodes, defs, had_top_blank
end

-- ── Inline parsing ────────────────────────────────────────────────────────────

-- Parse inline content from a string. Returns array of inline nodes.
-- Uses a delimiter-stack approach for emphasis/strong.

local parse_inlines  -- forward declaration

-- Normalize a link reference label per CommonMark §6.6:
-- collapse whitespace sequences to a single space, then lowercase.
-- Note: backslash escapes are NOT processed — `\!` ≠ `!` in labels.
-- Backslash-escaped brackets (\[ \]) just happen to be the same raw string in both
-- definition and reference, so they match correctly without special handling.
local function normalize_label(s)
  s = s:gsub("%s+", " ")
  s = s:match("^%s*(.-)%s*$") or s  -- trim
  return s:lower()
end

-- Scan a reference label starting at pos: expects '[', returns label text and end pos, or nil.
local function scan_ref_label(src, pos)
  if str_byte(src, pos) ~= 91 then return nil end  -- '['
  local len = #src
  local i = pos + 1
  local start = i
  -- Labels may span at most one line and must not contain unescaped '[' or ']'.
  while i <= len do
    local b = str_byte(src, i)
    if b == 93 then  -- ']'
      return str_sub(src, start, i - 1), i + 1
    elseif b == 91 then  -- '[' unescaped — invalid label
      return nil
    elseif b == 92 then  -- backslash escape
      i = i + 2
    elseif b == 10 then  -- newline — labels may cross one line, skip
      i = i + 1
    else
      i = i + 1
    end
  end
  return nil  -- unclosed label
end

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
  -- Skip optional whitespace (including newlines).
  while pos <= len do
    local b = str_byte(src, pos)
    if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
  end
  -- URL: either <...> or run of non-whitespace, non-paren chars (balanced parens allowed).
  local url
  if pos <= len and str_byte(src, pos) == 60 then  -- '<'
    -- Angle-bracket URL: cannot contain line endings or unescaped '<' or '>'.
    -- Backslash IS an escape for '>' (and other chars) inside <...>.
    -- Spaces are allowed (will be percent-encoded by renderer).
    pos = pos + 1
    local url_parts = {}
    local valid = true
    while pos <= len do
      local b = str_byte(src, pos)
      if b == 62 then  -- unescaped '>' → end of URL
        break
      elseif b == 60 or b == 10 then  -- '<' or newline: invalid
        valid = false
        break
      elseif b == 92 then  -- backslash escape
        local nb = str_byte(src, pos + 1)
        if nb == 62 then  -- '\>' → escaped '>', include as '>'
          url_parts[#url_parts + 1] = ">"
          pos = pos + 2
        elseif nb then
          url_parts[#url_parts + 1] = "\\" .. str_char(nb)
          pos = pos + 2
        else
          url_parts[#url_parts + 1] = "\\"
          pos = pos + 1
        end
      else
        url_parts[#url_parts + 1] = str_char(b)
        pos = pos + 1
      end
    end
    if not valid or pos > len then return nil end
    url = tbl_concat(url_parts)
    pos = pos + 1  -- skip '>'
  else
    -- Bare URL: stop at space, ), EOF. Allow balanced parens and backslash escapes.
    local depth = 0
    local parts = {}
    while pos <= len do
      local b = str_byte(src, pos)
      if b == 40 then       -- '('
        depth = depth + 1
        parts[#parts + 1] = "("
        pos = pos + 1
      elseif b == 41 then   -- ')'
        if depth == 0 then break end
        depth = depth - 1
        parts[#parts + 1] = ")"
        pos = pos + 1
      elseif b == 92 then   -- backslash
        local nb = str_byte(src, pos + 1)
        -- Only ASCII punctuation is escapable (§2.4).
        local is_punct = nb and (
          (nb >= 33 and nb <= 47) or (nb >= 58 and nb <= 64) or
          (nb >= 91 and nb <= 96) or (nb >= 123 and nb <= 126))
        if is_punct then
          -- Backslash-escaped ASCII punctuation: include the literal char.
          parts[#parts + 1] = str_char(nb)
          pos = pos + 2
        else
          parts[#parts + 1] = "\\"
          pos = pos + 1
        end
      elseif b == 32 or b == 9 or b == 10 then
        break
      else
        parts[#parts + 1] = str_char(b)
        pos = pos + 1
      end
    end
    url = tbl_concat(parts)
  end
  -- Skip optional whitespace (including newlines) before title.
  while pos <= len do
    local b = str_byte(src, pos)
    if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
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
  -- Skip optional whitespace (including newlines) before closing ')'.
  while pos <= len do
    local b = str_byte(src, pos)
    if b == 32 or b == 9 or b == 10 or b == 13 then pos = pos + 1 else break end
  end
  -- Expect ')'.
  if pos > len or str_byte(src, pos) ~= 41 then return nil end
  return url, title, pos + 1
end

-- Delimiter stack entry: { char, count, pos, can_open, can_close }
-- For emphasis/strong processing after tokenizing.

-- Simple inline tokenizer: produces a flat list of tokens, then resolves delimiters.
-- Token types: "text", "code", "hardbreak", "softbreak", "delim", "link_open", "link_close",
--              "link_ref_close", "image_open"
-- link_ref_close has: ref (string, normalized label for full-ref) or collapsed (bool) or shortcut (bool)

local function tokenize_inlines(src, defs)
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
        -- Strip leading spaces on next line.
        while pos <= len and str_byte(src, pos) == 32 do pos = pos + 1 end
      elseif next_b then
        -- Escaped character: emit as text.
        tokens[#tokens + 1] = { type = "text", value = str_char(next_b) }
        pos = pos + 2
      else
        tokens[#tokens + 1] = { type = "text", value = "\\" }
        pos = pos + 1
      end
      text_start = pos

    -- Newline: soft break or hard break (two+ trailing spaces + newline).
    elseif b == 10 then
      -- Count trailing spaces before the \n.
      local trail = pos - 1
      while trail >= text_start and str_byte(src, trail) == 32 do
        trail = trail - 1
      end
      local n_trailing = pos - 1 - trail
      local is_hard = n_trailing >= 2
      if is_hard then
        -- Flush up to last non-space (strips trailing spaces).
        flush_text(trail + 1)
        tokens[#tokens + 1] = { type = "hardbreak" }
      else
        -- Soft break: strip trailing spaces from text too.
        flush_text(trail + 1)
        tokens[#tokens + 1] = { type = "softbreak" }
      end
      pos = pos + 1
      -- Strip leading spaces on next line (CommonMark: up to 3 leading spaces stripped).
      while pos <= len and str_byte(src, pos) == 32 do pos = pos + 1 end
      text_start = pos

    -- Asterisk or underscore: potential emphasis/strong delimiter.
    elseif b == 42 or b == 95 then  -- '*' or '_'
      flush_text(pos)
      local delim_start = pos
      local delim_char = b
      while pos <= len and str_byte(src, pos) == delim_char do pos = pos + 1 end
      local delim_count = pos - delim_start
      -- Determine can_open / can_close per CommonMark §6.1 rules.
      -- We need the Unicode codepoint before and after the delimiter run.
      -- For ASCII bytes we use the byte directly; for multi-byte UTF-8 we decode.
      local function decode_utf8_before(s, p)
        -- Return the leading byte of the UTF-8 codepoint ending at position p-1.
        -- For single-byte (< 128), returns that byte. For multi-byte, returns the
        -- leading byte (which lets us classify: leading byte >= 0xC0 = non-ASCII).
        if p <= 1 then return 0 end
        local b = str_byte(s, p - 1)
        if b < 128 then return b end
        -- Multi-byte UTF-8: walk back to find leading byte.
        local i = p - 1
        while i > 1 and str_byte(s, i) >= 128 and str_byte(s, i) < 192 do i = i - 1 end
        return str_byte(s, i) or 0
      end
      -- For the character after, just use the first byte of the next codepoint.
      local before_first = decode_utf8_before(src, delim_start)
      local before_b = before_first  -- leading byte of codepoint before run
      local after_b  = (pos <= len) and str_byte(src, pos) or 0  -- leading byte of codepoint after

      -- Unicode whitespace: space, tab, newline, \r, \f, \v.
      -- Non-ASCII codepoints are NOT whitespace here.
      local function is_unicode_ws(c)
        return c == 0 or c == 32 or c == 9 or c == 10 or c == 13 or c == 12 or c == 11
      end
      -- Unicode punctuation: ASCII punctuation characters only (codepoints U+0021..U+007E
      -- that are not alphanumeric), plus we treat non-ASCII leading bytes (>= 0xC0) as
      -- potential Unicode punctuation only if they're in known punct ranges — but for
      -- simplicity we handle only ASCII punct here; non-ASCII are treated as letters.
      local function is_unicode_punct(c)
        -- Only ASCII punctuation; non-ASCII (c >= 128) treated as non-punctuation (letters/symbols).
        return c < 128 and c > 32 and (
          (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or
          (c >= 91 and c <= 96) or (c >= 123 and c <= 126))
      end
      local left_flanking = not is_unicode_ws(after_b) and
        (not is_unicode_punct(after_b) or is_unicode_ws(before_b) or is_unicode_punct(before_b))
      local right_flanking = not is_unicode_ws(before_b) and
        (not is_unicode_punct(before_b) or is_unicode_ws(after_b) or is_unicode_punct(after_b))
      local can_open, can_close
      if delim_char == 42 then  -- *
        can_open  = left_flanking
        can_close = right_flanking
      else  -- _: additional restriction per CommonMark §6.1 rules 1 and 2.
        -- can_open: left-flanking AND (NOT right-flanking OR preceded by Unicode punctuation)
        can_open  = left_flanking and (not right_flanking or is_unicode_punct(before_b))
        -- can_close: right-flanking AND (NOT left-flanking OR followed by Unicode punctuation)
        can_close = right_flanking and (not left_flanking or is_unicode_punct(after_b))
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
      -- Check for image prefix '!': must be literal '!' (not a backslash-escaped '!').
      -- A backslash-escaped '!' (\!) should produce a literal '!' followed by a link, not image.
      local is_image = (pos > 1 and str_byte(src, pos - 1) == 33 and
                        not (pos > 2 and str_byte(src, pos - 2) == 92))  -- '!' not preceded by '\'
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

    -- ']': potential link close + destination or reference.
    elseif b == 93 then  -- ']'
      flush_text(pos)
      pos = pos + 1
      -- Try to parse (url "title") immediately → inline link.
      local url, title, end_pos = parse_link_dest(src, pos)
      if url ~= nil then
        tokens[#tokens + 1] = { type = "link_close", url = url, title = title }
        pos = end_pos
      elseif defs then
        -- Try reference forms (only when defs table is available).
        -- Full reference: [text][ref]
        local ref_label, ref_end = scan_ref_label(src, pos)
        if ref_label ~= nil and ref_label ~= "" then
          -- Non-empty [ref] after ] → full reference link.
          local norm = normalize_label(ref_label)
          if defs[norm] then
            tokens[#tokens + 1] = { type = "link_ref_close", ref = norm }
            pos = ref_end
          else
            -- Ref not in defs: fall back — emit ] as text, don't consume the [ref].
            tokens[#tokens + 1] = { type = "text", value = "]" }
          end
        elseif ref_label == "" then
          -- Empty [] after ] → collapsed reference: label = text between opener brackets.
          -- Store close_pos (position of ']' in src) so resolve_inlines can extract raw label.
          tokens[#tokens + 1] = { type = "link_ref_close", collapsed = true, close_pos = pos - 1 }
          pos = pos + 2  -- skip the '[]'
        else
          -- No [ref] → shortcut reference: label = text between opener brackets.
          -- Store close_pos (position of ']' in src) so resolve_inlines can extract raw label.
          tokens[#tokens + 1] = { type = "link_ref_close", shortcut = true, close_pos = pos - 1 }
        end
      else
        -- No destination and no defs: treat as text.
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

-- Extract plain text content from a list of tokens (for label matching in ref links).
-- Includes text, code, delimiters (as their literal chars), and break tokens.
local function tokens_to_label(inner_tokens)
  local parts = {}
  for _, t in ipairs(inner_tokens) do
    if t.type == "text" then
      parts[#parts + 1] = t.value or ""
    elseif t.type == "code" then
      parts[#parts + 1] = t.value or ""
    elseif t.type == "delim" then
      parts[#parts + 1] = str_rep(str_char(t.char), t.count)
    elseif t.type == "softbreak" or t.type == "hardbreak" then
      parts[#parts + 1] = " "
    elseif t.type == "node" then
      -- Resolved node inside label: extract text recursively.
      local function extract(node)
        if node.type == "text" then return node.value or ""
        elseif node.type == "inlineCode" then return node.value or ""
        elseif node.children then
          local ps = {}
          for _, c in ipairs(node.children) do ps[#ps+1] = extract(c) end
          return tbl_concat(ps)
        end
        return ""
      end
      parts[#parts + 1] = extract(t.node)
    end
  end
  return normalize_label(tbl_concat(parts))
end

-- Resolve delimiter tokens into emphasis/strong nodes.
-- Also resolves link/image open-close pairs.
-- Returns array of inline nodes.
local function resolve_inlines(tokens, defs, src)
  local result = {}

  -- First pass: resolve links/images.
  -- Find matching link_open for each link_close.
  local n = #tokens
  local i = 1
  local resolved = {}  -- new token list after link resolution

  -- We need to track bracket stack.
  -- Each frame: { idx, is_image, inactive }
  -- inactive=true: deactivated link_open (can't form a link, becomes '[' text)
  local bracket_stack = {}

  while i <= n do
    local tok = tokens[i]
    if tok.type == "link_open" or tok.type == "image_open" then
      bracket_stack[#bracket_stack + 1] = {
        idx = #resolved + 1,
        is_image = tok.type == "image_open",
        inactive = false,
      }
      resolved[#resolved + 1] = tok
      i = i + 1
    elseif tok.type == "link_close" or tok.type == "link_ref_close" then
      if #bracket_stack > 0 then
        local frame = bracket_stack[#bracket_stack]

        -- Collect content tokens between frame.idx and current position.
        local inner_tokens = {}
        for k = frame.idx + 1, #resolved do
          inner_tokens[#inner_tokens + 1] = resolved[k]
        end

        local url, title
        local matched = false

        -- Inactive frames cannot match (links can't be inside links).
        if not frame.inactive then
          if tok.type == "link_close" then
            url = tok.url
            title = tok.title
            matched = true
          elseif defs then
            local label
            if tok.ref then
              label = tok.ref
            elseif src and tok.close_pos then
              -- Shortcut/collapsed: use raw source text for label (preserves backslashes, etc.).
              -- opener token in resolved[frame.idx] has .pos = position of '[' in src.
              local opener_tok = resolved[frame.idx]
              if opener_tok and opener_tok.pos then
                local raw = str_sub(src, opener_tok.pos + 1, tok.close_pos - 1)
                label = normalize_label(raw)
              else
                label = tokens_to_label(inner_tokens)
              end
            else
              label = tokens_to_label(inner_tokens)
            end
            local def = defs[label]
            if def then
              url = def.url
              title = def.title
              matched = true
            end
          end
        end

        if matched then
          bracket_stack[#bracket_stack] = nil
          for k = #resolved, frame.idx, -1 do resolved[k] = nil end
          local node_type = frame.is_image and "image" or "link"
          local link_node = {
            type = node_type,
            url = url,
            title = title,
            children = resolve_inlines(inner_tokens, defs, src),
          }
          resolved[#resolved + 1] = { type = "node", node = link_node }
          -- CommonMark: after a link is created, deactivate all link_open (not image_open)
          -- frames remaining in the bracket_stack (links can't contain links).
          if node_type == "link" then
            for _, outer_frame in ipairs(bracket_stack) do
              if not outer_frame.is_image then
                outer_frame.inactive = true
              end
            end
          end
        else
          -- Unmatched (no dest or inactive): emit as text.
          bracket_stack[#bracket_stack] = nil
          for k = #resolved, frame.idx, -1 do resolved[k] = nil end
          resolved[#resolved + 1] = { type = "text", value = frame.is_image and "![" or "[" }
          for _, t in ipairs(inner_tokens) do
            resolved[#resolved + 1] = t
          end
          resolved[#resolved + 1] = { type = "text", value = "]" }
          -- Re-emit consumed suffix (url or reference label) so it can be processed.
          if tok.type == "link_close" and tok.url ~= nil then
            -- Re-emit the (url) that was consumed by this token.
            local title_part = tok.title and (' "' .. tok.title .. '"') or ""
            resolved[#resolved + 1] = { type = "text", value = "(" .. tok.url .. title_part .. ")" }
          elseif tok.type == "link_ref_close" and tok.ref and defs then
            -- The [ref] was consumed. Emit it as a link node if defined, otherwise as text.
            local def = defs[tok.ref]
            if def then
              resolved[#resolved + 1] = { type = "node", node = {
                type = "link", url = def.url, title = def.title,
                children = { { type = "text", value = tok.ref } },
              }}
            else
              resolved[#resolved + 1] = { type = "text", value = "[" .. tok.ref .. "]" }
            end
          elseif tok.type == "link_ref_close" and tok.collapsed then
            resolved[#resolved + 1] = { type = "text", value = "[]" }
          end
        end
      else
        -- Unmatched ]: emit as text.
        resolved[#resolved + 1] = { type = "text", value = "]" }
        if tok.type == "link_close" and tok.url then
          resolved[#resolved + 1] = { type = "text", value = "(" .. tok.url .. ")" }
        end
      end
      i = i + 1
    else
      resolved[#resolved + 1] = tok
      i = i + 1
    end
  end

  -- Unmatched link/image opens: convert to text '[' or '!['.
  for _, frame in ipairs(bracket_stack) do
    local tok2 = resolved[frame.idx]
    if tok2 then
      local is_img = tok2.type == "image_open"
      tok2.type = "text"
      tok2.value = is_img and "![" or "["
    end
  end

  -- Second pass: resolve emphasis/strong delimiters.
  -- Implements CommonMark §6.1 delimiter stack algorithm.
  --
  -- We maintain a flat list `out` of nodes and a `delim_stack` tracking open
  -- delimiter runs. Each delimiter stack entry records:
  --   idx_in_out  — index in `out` of the placeholder node
  --   char        — byte value (42='*', 95='_')
  --   count       — remaining chars in the run (decremented as chars are consumed)
  --   orig_count  — original run length (for the odd-sum rule)
  --   can_open / can_close
  local out = {}
  local delim_stack = {}

  local function emit(node)
    out[#out + 1] = node
  end

  local function emit_text(v)
    if #out > 0 and out[#out].type == "text" then
      out[#out].value = out[#out].value .. v
    else
      out[#out + 1] = { type = "text", value = v }
    end
  end

  -- Process one delimiter token (possibly recursing for remaining counts).
  -- This is called both for tokens from `resolved` and for synthetic remainder tokens.
  local function process_delim(tok)
    if tok.can_close then
      -- Search delimiter stack from top for a matching opener.
      local found = nil
      for di = #delim_stack, 1, -1 do
        local d = delim_stack[di]
        if d.char == tok.char and d.can_open then
          -- CommonMark rule 17: if both can_open and can_close, the sum of the
          -- original run lengths must not be a multiple of 3 (unless both are
          -- multiples of 3).
          local ok = true
          if (d.can_open and d.can_close) or (tok.can_open and tok.can_close) then
            local s = (d.orig_count + tok.count)
            if s % 3 == 0 and not (d.orig_count % 3 == 0 and tok.count % 3 == 0) then
              ok = false
            end
          end
          if ok then
            found = di
            break
          end
        end
      end

      if found then
        local opener = delim_stack[found]
        -- Use 2 chars if both have >= 2, otherwise 1.
        local use = (opener.count >= 2 and tok.count >= 2) and 2 or 1
        local node_type = use == 2 and "strong" or "emphasis"

        -- Convert any intermediate (between found+1 and top of stack) delim
        -- placeholders in `out` to text — they are "enclosed" by this match.
        for k = found + 1, #delim_stack do
          local d2 = delim_stack[k]
          local ph = out[d2.idx_in_out]
          if ph and ph.type == "_delim_placeholder" then
            ph.type = "text"
            ph.value = str_rep(str_char(d2.char), d2.count)
          end
        end
        -- Remove intermediate stack entries.
        for k = #delim_stack, found + 1, -1 do delim_stack[k] = nil end

        -- Collect children: everything in `out` after the opener placeholder.
        local children = {}
        for k = opener.idx_in_out + 1, #out do
          children[#children + 1] = out[k]
        end
        -- Trim out back to the opener placeholder position (remove placeholder too).
        for k = #out, opener.idx_in_out, -1 do out[k] = nil end

        local rem_open = opener.count - use

        if rem_open > 0 then
          -- Opener partially consumed: update opener stack entry.
          opener.count = rem_open
          local new_idx = #out + 1
          out[new_idx] = { type = "_delim_placeholder", char = tok.char, count = rem_open }
          opener.idx_in_out = new_idx
          emit({ type = node_type, children = children })
        else
          -- Opener fully consumed: remove it from the stack.
          for k = #delim_stack, found, -1 do delim_stack[k] = nil end
          emit({ type = node_type, children = children })
        end

        -- Closer's remaining chars: re-process as a new closer token.
        local rem_close = tok.count - use
        if rem_close > 0 then
          process_delim({
            type = "delim",
            char = tok.char,
            count = rem_close,
            orig_count = rem_close,
            can_open = tok.can_open,
            can_close = tok.can_close,
          })
        end
        return  -- matched
      end
      -- No matching opener found.
      if not tok.can_open then
        -- Pure closer with no match: emit as text.
        emit_text(str_rep(str_char(tok.char), tok.count))
        return
      end
      -- Falls through to opener handling below (can_open and can_close but no match).
    end

    -- Opener (or can_open+can_close with no match as closer): push to delimiter stack
    -- only if can_open. Otherwise emit as text.
    if not tok.can_open then
      emit_text(str_rep(str_char(tok.char), tok.count))
      return
    end
    local idx = #out + 1
    out[idx] = { type = "_delim_placeholder", char = tok.char, count = tok.count }
    delim_stack[#delim_stack + 1] = {
      idx_in_out = idx,
      char = tok.char,
      count = tok.count,
      orig_count = tok.orig_count or tok.count,
      can_open = tok.can_open,
      can_close = tok.can_close,
    }
  end

  for _, tok in ipairs(resolved) do
    if tok.type == "text" then
      if tok.value and tok.value ~= "" then emit_text(tok.value) end
    elseif tok.type == "code" then
      emit({ type = "inlineCode", value = tok.value })
    elseif tok.type == "hardbreak" then
      emit({ type = "break" })
    elseif tok.type == "softbreak" then
      emit({ type = "softBreak" })
    elseif tok.type == "node" then
      emit(tok.node)
    elseif tok.type == "link_open" or tok.type == "image_open" then
      emit_text(tok.type == "image_open" and "![" or "[")
    elseif tok.type == "delim" then
      tok.orig_count = tok.count
      process_delim(tok)
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

parse_inlines = function(src, defs)
  if not src or src == "" then return {} end
  local tokens = tokenize_inlines(src, defs)
  return resolve_inlines(tokens, defs, src)
end

-- ── Phase 2: inline expansion pass ────────────────────────────────────────────

-- Walk block tree and fill `children` for nodes that have `_raw`.
local function expand_inlines(nodes, defs)
  for _, node in ipairs(nodes) do
    if node.type == "heading" or node.type == "paragraph" then
      local raw = node._raw or ""
      -- Strip trailing whitespace (not significant at end of block).
      raw = raw:match("^(.-)%s*$") or raw
      node.children = parse_inlines(raw, defs)
      node._raw = nil
    elseif node.children then
      expand_inlines(node.children, defs)
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
  expand_inlines(blocks, defs)
  return {
    type = "root",
    children = blocks,
    _defs = defs,  -- link reference definitions (exposed for downstream use)
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
