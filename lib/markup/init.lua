if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- AST node constructors
--:: Node = { tag: string, ... }
--: (tag: string, fields: { [string]: unknown, ... } | nil) -> Node
local function node(tag, fields)
  local n = --[[:! Node ]] (fields or {})
  n.tag = tag
  return n
end

-- HTML escape
--: (s: string) -> string
local function esc(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- ============================================================
-- Inline parser (shared between formats)
-- ============================================================

-- Parse inline markdown-style markup inside a string.
-- Returns list of AST nodes (Text, Bold, Italic, Code, Link, Image, LineBreak).
--: (s: string) -> { tag: string, ... }[]
local function parse_inline_markdown(s)
  local nodes = --[[:! Node[] ]] {}
  local i = 1
  local len = #s

  local function push_text(t)
    if t ~= "" then
      nodes[#nodes + 1] = node("Text", { value = t })
    end
  end

  while i <= len do
    local c = s:sub(i, i)

    -- LineBreak: two spaces at end of line (before \n)
    if c == " " and s:sub(i, i+1) == "  " and s:sub(i+2, i+2) == "\n" then
      nodes[#nodes + 1] = node("LineBreak")
      i = i + 3

    -- Image: ![alt](src)
    elseif c == "!" and s:sub(i+1, i+1) == "[" then
      local j = s:find("]", i+2, true)
      if j then
        local k = s:find("(", j+1, true)
        local m2 = k and s:find(")", k+1, true)
        if k and m2 and k == j+1 then
          local alt = s:sub(i+2, j-1)
          local src = s:sub(k+1, m2-1)
          nodes[#nodes + 1] = node("Image", { alt = alt, src = src })
          i = m2 + 1
        else
          push_text(c)
          i = i + 1
        end
      else
        push_text(c)
        i = i + 1
      end

    -- Link: [text](url)
    elseif c == "[" then
      local j = s:find("]", i+1, true)
      if j then
        local k = s:find("(", j+1, true)
        local m2 = k and s:find(")", k+1, true)
        if k and m2 and k == j+1 then
          local text = s:sub(i+1, j-1)
          local url = s:sub(k+1, m2-1)
          local child_nodes = parse_inline_markdown(text)
          nodes[#nodes + 1] = node("Link", { url = url, children = child_nodes })
          i = m2 + 1
        else
          push_text(c)
          i = i + 1
        end
      else
        push_text(c)
        i = i + 1
      end

    -- Inline code: `...`
    elseif c == "`" and s:sub(i, i+2) ~= "```" then
      local j = s:find("`", i+1, true)
      if j then
        nodes[#nodes + 1] = node("Code", { value = s:sub(i+1, j-1) })
        i = j + 1
      else
        push_text(c)
        i = i + 1
      end

    -- Bold+Italic: ***text*** or ___text___
    elseif (c == "*" and s:sub(i, i+2) == "***") or (c == "_" and s:sub(i, i+2) == "___") then
      local delim = s:sub(i, i+2)
      local j = s:find(delim, i+3, true)
      if j then
        local inner = s:sub(i+3, j-1)
        local child_nodes = parse_inline_markdown(inner)
        local bold = node("Bold", { children = { node("Italic", { children = child_nodes }) } })
        nodes[#nodes + 1] = bold
        i = j + 3
      else
        push_text(c)
        i = i + 1
      end

    -- Bold: **text** or __text__
    elseif (c == "*" and s:sub(i, i+1) == "**") or (c == "_" and s:sub(i, i+1) == "__") then
      local delim = s:sub(i, i+1)
      local j = s:find(delim, i+2, true)
      if j then
        local inner = s:sub(i+2, j-1)
        local child_nodes = parse_inline_markdown(inner)
        nodes[#nodes + 1] = node("Bold", { children = child_nodes })
        i = j + 2
      else
        push_text(c)
        i = i + 1
      end

    -- Italic: *text* or _text_
    elseif c == "*" or c == "_" then
      local delim = c
      -- find matching single delimiter not preceded/followed by same
      local j = i + 1
      local found = nil
      while j <= len do
        local p = s:find(delim, j, true)
        if not p then break end
        -- not a double
        if s:sub(p, p+1) ~= delim .. delim then
          found = p
          break
        end
        j = p + 2
      end
      if found then
        local inner = s:sub(i+1, found-1)
        local child_nodes = parse_inline_markdown(inner)
        nodes[#nodes + 1] = node("Italic", { children = child_nodes })
        i = found + 1
      else
        push_text(c)
        i = i + 1
      end

    -- Backslash escape
    elseif c == "\\" and i < len then
      push_text(s:sub(i+1, i+1))
      i = i + 2

    else
      -- Accumulate text
      local j = i
      while j <= len do
        local nc = s:sub(j, j)
        if nc == "*" or nc == "_" or nc == "`" or nc == "[" or nc == "!" or nc == "\\" then
          break
        end
        if nc == " " and s:sub(j, j+1) == "  " and s:sub(j+2, j+2) == "\n" then
          break
        end
        j = j + 1
      end
      push_text(s:sub(i, j-1))
      i = j
    end
  end

  return nodes
end

-- ============================================================
-- Inline parser for RST
-- ============================================================
--: (s: string) -> Node[]
local function parse_inline_rst(s)
  local nodes = --[[:! Node[] ]] {}
  local i = 1
  local len = #s

  local function push_text(t)
    if t ~= "" then
      nodes[#nodes + 1] = node("Text", { value = t })
    end
  end

  while i <= len do
    local c = s:sub(i, i)

    -- Inline code: ``...``
    if s:sub(i, i+1) == "``" then
      local j = s:find("``", i+2, true)
      if j then
        nodes[#nodes + 1] = node("Code", { value = s:sub(i+2, j-1) })
        i = j + 2
      else
        push_text(c)
        i = i + 1
      end

    -- Bold: **text**
    elseif s:sub(i, i+1) == "**" then
      local j = s:find("%*%*", i+2)
      if j then
        local inner = s:sub(i+2, j-1)
        nodes[#nodes + 1] = node("Bold", { children = parse_inline_rst(inner) })
        i = j + 2
      else
        push_text(c)
        i = i + 1
      end

    -- Italic: *text*
    elseif c == "*" then
      local j = s:find("%*", i+1)
      if j then
        local inner = s:sub(i+1, j-1)
        nodes[#nodes + 1] = node("Italic", { children = parse_inline_rst(inner) })
        i = j + 1
      else
        push_text(c)
        i = i + 1
      end

    else
      local j = i
      while j <= len do
        local nc = s:sub(j, j)
        if nc == "*" or nc == "`" then break end
        j = j + 1
      end
      push_text(s:sub(i, j-1))
      i = j
    end
  end

  return nodes
end

-- ============================================================
-- Inline parser for AsciiDoc
-- ============================================================
--: (s: string) -> Node[]
local function parse_inline_asciidoc(s)
  local nodes = --[[:! Node[] ]] {}
  local i = 1
  local len = #s

  local function push_text(t)
    if t ~= "" then
      nodes[#nodes + 1] = node("Text", { value = t })
    end
  end

  while i <= len do
    local c = s:sub(i, i)

    -- Inline code: `...`
    if c == "`" then
      local j = s:find("`", i+1, true)
      if j then
        nodes[#nodes + 1] = node("Code", { value = s:sub(i+1, j-1) })
        i = j + 1
      else
        push_text(c)
        i = i + 1
      end

    -- Bold: *text*
    elseif c == "*" then
      local j = s:find("%*", i+1)
      if j then
        local inner = s:sub(i+1, j-1)
        nodes[#nodes + 1] = node("Bold", { children = parse_inline_asciidoc(inner) })
        i = j + 1
      else
        push_text(c)
        i = i + 1
      end

    -- Italic: _text_
    elseif c == "_" then
      local j = s:find("_", i+1, true)
      if j then
        local inner = s:sub(i+1, j-1)
        nodes[#nodes + 1] = node("Italic", { children = parse_inline_asciidoc(inner) })
        i = j + 1
      else
        push_text(c)
        i = i + 1
      end

    else
      local j = i
      while j <= len do
        local nc = s:sub(j, j)
        if nc == "*" or nc == "_" or nc == "`" then break end
        j = j + 1
      end
      push_text(s:sub(i, j-1))
      i = j
    end
  end

  return nodes
end

-- ============================================================
-- Markdown parser
-- ============================================================

-- Split text into lines, keeping newlines
--: (text: string) -> string[]
local function split_lines(text)
  local lines = --[[:! string[] ]] {}
  local start = 1
  while true do
    local nl = text:find("\n", start, true)
    if nl then
      lines[#lines + 1] = text:sub(start, nl)
      start = nl --[[:! integer ]] + 1
    else
      local rest = text:sub(start)
      if rest ~= "" then lines[#lines + 1] = rest end
      break
    end
  end
  return lines
end

-- Parse list items from lines starting at index i.
-- indent: minimum indent level for items at this level.
-- Returns (list_node, next_i)
local function parse_md_list(lines, i, indent, ordered)
  local items = {}
  local list_node = node(ordered and "OrderedList" or "UnorderedList", { children = items })

  while i <= #lines do
    local line = lines[i]
    local stripped = line:gsub("\n$", "")

    -- Check indentation
    local spaces = stripped:match("^( *)")
    local indent_count = #spaces
    if indent_count < indent then break end

    -- Unordered item
    local ul_text = stripped:match("^%s*[-*+]%s+(.*)")
    -- Ordered item
    local ol_text = stripped:match("^%s*%d+%.%s+(.*)")

    local item_text, item_ordered
    if ul_text then
      item_text = ul_text
      item_ordered = false
    elseif ol_text then
      item_text = ol_text
      item_ordered = true
    else
      -- Blank line or continuation — end list
      break
    end

    -- Check if this item's ordered type matches expected
    if item_ordered ~= ordered then break end

    i = i + 1

    -- Collect continuation lines and nested lists
    local content_lines = { item_text }
    while i <= #lines do
      local next_line = lines[i]
      local next_stripped = next_line:gsub("\n$", "")
      local next_spaces = next_stripped:match("^( *)")
      local next_indent = #next_spaces

      -- Nested list?
      local nested_ul = next_stripped:match("^%s*[-*+]%s+")
      local nested_ol = next_stripped:match("^%s*%d+%.%s+")
      if (nested_ul or nested_ol) and next_indent > indent_count then
        break
      end

      -- Continuation (indented more than current item)
      if next_indent > indent_count and next_stripped ~= "" then
        content_lines[#content_lines + 1] = next_stripped:sub(indent_count + 1)
        i = i + 1
      else
        break
      end
    end

    local item_children = parse_inline_markdown(table.concat(content_lines, " "))

    -- Check for nested list
    if i <= #lines then
      local next_line = lines[i]:gsub("\n$", "")
      local next_spaces2 = next_line:match("^( *)")
      local next_indent2 = #next_spaces2
      local nested_ul2 = next_line:match("^%s*[-*+]%s+")
      local nested_ol2 = next_line:match("^%s*%d+%.%s+")

      if (nested_ul2 or nested_ol2) and next_indent2 > indent_count then
        local nested_ordered = nested_ol2 ~= nil
        local nested_list, new_i = parse_md_list(lines, i, next_indent2, nested_ordered)
        item_children[#item_children + 1] = nested_list
        i = new_i
      end
    end

    items[#items + 1] = node("ListItem", { children = item_children })
  end

  return list_node, i
end

--: (text: string) -> { tag: string, children: unknown[] }
function M.parse_markdown(text)
  -- Normalize line endings
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end

  local lines = split_lines(text)
  local ast = { tag = "Document", children = {} }
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local stripped = line:gsub("\n$", "")

    -- Blank line
    if stripped:match("^%s*$") then
      i = i + 1

    -- ATX heading: # to ######
    elseif stripped:match("^(#+)%s+(.*)") then
      local hashes, content = stripped:match("^(#+)%s+(.*)")
      -- Remove trailing hashes
      content = (content or ""):gsub("%s+#+%s*$", "")
      local hashes_str = hashes or "" --: string
      local level = math.min(#hashes_str, 6)
      local children = parse_inline_markdown(content)
      ast.children[#ast.children + 1] = node("Heading", { level = level, children = children })
      i = i + 1

    -- Setext heading (===  or ---)
    elseif i + 1 <= #lines and lines[i+1]:match("^[=%-]+%s*\n?$") then
      local underline = lines[i+1]:gsub("\n$", "")
      local level = underline:sub(1,1) == "=" and 1 or 2
      local children = parse_inline_markdown(stripped)
      ast.children[#ast.children + 1] = node("Heading", { level = level, children = children })
      i = i + 2

    -- Horizontal rule: --- or *** or ___
    elseif stripped:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s%-%*_]*$") then
      ast.children[#ast.children + 1] = node("HorizontalRule")
      i = i + 1

    -- Fenced code block: ```
    elseif stripped:match("^```") then
      local lang = stripped:match("^```%s*(.-)%s*$") or ""
      i = i + 1
      local code_lines = {}
      while i <= #lines do
        local cl = lines[i]:gsub("\n$", "")
        if cl:match("^```%s*$") then
          i = i + 1
          break
        end
        code_lines[#code_lines + 1] = lines[i]
        i = i + 1
      end
      local code = table.concat(code_lines)
      -- Remove trailing newline
      code = code:gsub("\n$", "")
      ast.children[#ast.children + 1] = node("CodeBlock", { lang = lang, value = code })

    -- Blockquote: > ...
    elseif stripped:match("^>") then
      local bq_lines = {}
      while i <= #lines do
        local bl = lines[i]:gsub("\n$", "")
        if bl:match("^>") then
          bq_lines[#bq_lines + 1] = bl:gsub("^>%s?", "")
          i = i + 1
        elseif bl:match("^%s*$") then
          break
        else
          break
        end
      end
      local inner_text = table.concat(bq_lines, "\n")
      local inner_ast = M.parse_markdown(inner_text)
      ast.children[#ast.children + 1] = node("BlockQuote", { children = inner_ast.children })

    -- Unordered list
    elseif stripped:match("^%s*[-*+]%s+") then
      local spaces = stripped:match("^( *)")
      local indent = #spaces
      local list_node, new_i = parse_md_list(lines, i, indent, false)
      ast.children[#ast.children + 1] = list_node
      i = new_i

    -- Ordered list
    elseif stripped:match("^%s*%d+%.%s+") then
      local spaces = stripped:match("^( *)")
      local indent = #spaces
      local list_node, new_i = parse_md_list(lines, i, indent, true)
      ast.children[#ast.children + 1] = list_node
      i = new_i

    -- Paragraph
    else
      local para_lines = {}
      while i <= #lines do
        local pl = lines[i]:gsub("\n$", "")
        if pl:match("^%s*$") then break end
        if pl:match("^(#+)%s") then break end
        if pl:match("^```") then break end
        if pl:match("^>") then break end
        if pl:match("^%s*[-*+]%s+") then break end
        if pl:match("^%s*%d+%.%s+") then break end
        if pl:match("^%s*[-*_]%s*[-*_]%s*[-*_][%s%-%*_]*$") then break end
        -- Setext heading underline check
        if i + 1 <= #lines and lines[i+1]:match("^[=%-]+%s*\n?$") then break end
        para_lines[#para_lines + 1] = pl
        i = i + 1
      end
      if #para_lines > 0 then
        local para_text = table.concat(para_lines, "\n")
        local children = parse_inline_markdown(para_text)
        ast.children[#ast.children + 1] = node("Paragraph", { children = children })
      end
    end
  end

  return ast
end

-- ============================================================
-- RST parser
-- ============================================================

-- Detect RST section heading underline style: 3+ punctuation chars (all same type)
--: (s: string) -> boolean
local function is_rst_underline(s)
  if #s < 3 then return false end
  -- Must be all punctuation chars, at least 3, optionally trailing spaces
  return s:match("^%p%p%p+%s*$") ~= nil
end

--: (s: string) -> string
local function strip_newline(s)
  local r = s:gsub("\n$", "")
  return r
end

--: (text: string) -> { tag: string, children: unknown[] }
function M.parse_rst(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end

  local lines = split_lines(text)
  local ast = { tag = "Document", children = {} }
  local i = 1

  -- RST uses adornment chars; track order for heading levels
  local heading_chars = {}
  local function get_heading_level(ch)
    for idx, c in ipairs(heading_chars) do
      if c == ch then return idx end
    end
    heading_chars[#heading_chars + 1] = ch
    return #heading_chars
  end

  while i <= #lines do
    local line = lines[i]
    local stripped = line:gsub("\n$", "")

    -- Blank line
    if stripped:match("^%s*$") then
      i = i + 1

    -- Section heading: line followed by underline (and optionally preceded by overline)
    elseif i + 1 <= #lines and is_rst_underline(strip_newline(lines[i+1])) then
      local underline = lines[i+1]:gsub("\n$", "")
      local ch = underline:sub(1, 1)
      local level = math.min(get_heading_level(ch), 6)
      local children = parse_inline_rst(stripped)
      ast.children[#ast.children + 1] = node("Heading", { level = level, children = children })
      i = i + 2

    -- Overline + title + underline
    elseif is_rst_underline(stripped) and i + 2 <= #lines then
      local title_line = lines[i+1]:gsub("\n$", "")
      local underline2 = (lines[i+2] or ""):gsub("\n$", "")
      if is_rst_underline(underline2) then
        local ch = stripped:sub(1, 1)
        local level = math.min(get_heading_level(ch), 6)
        local children = parse_inline_rst(title_line)
        ast.children[#ast.children + 1] = node("Heading", { level = level, children = children })
        i = i + 3
      else
        i = i + 1
      end

    -- Directive: .. something::
    elseif stripped:match("^%.%. ") then
      local directive = stripped:match("^%.%. ([%w%-]+)::")
      if directive == "code-block" or directive == "code" then
        local lang = stripped:match("^%.%. [%w%-]+::%s*(.-)%s*$") or ""
        i = i + 1
        -- Skip option lines
        while i <= #lines and lines[i]:match("^%s+:") do
          i = i + 1
        end
        -- Blank line before content
        if i <= #lines and lines[i]:match("^%s*$") then i = i + 1 end
        -- Collect indented content
        local code_lines = {}
        local base_indent = -1 --: integer
        while i <= #lines do
          local cl = lines[i]:gsub("\n$", "")
          if cl:match("^%s*$") then
            code_lines[#code_lines + 1] = ""
            i = i + 1
          else
            local sp = cl:match("^( +)")
            local ind = sp and #sp or 0
            if base_indent < 0 then base_indent = ind end
            if ind >= base_indent then
              code_lines[#code_lines + 1] = cl:sub(base_indent + 1)
              i = i + 1
            else
              break
            end
          end
        end
        -- Remove trailing blank lines
        while #code_lines > 0 and code_lines[#code_lines] == "" do
          code_lines[#code_lines] = nil
        end
        ast.children[#ast.children + 1] = node("CodeBlock", { lang = lang, value = table.concat(code_lines, "\n") })
      else
        -- Unknown directive, skip line
        i = i + 1
      end

    -- Unordered list: - item or * item
    elseif stripped:match("^%s*[-*]%s+") then
      local items = {}
      while i <= #lines do
        local il = lines[i]:gsub("\n$", "")
        local item_text = il:match("^%s*[-*]%s+(.*)")
        if not item_text then break end
        items[#items + 1] = node("ListItem", { children = parse_inline_rst(item_text) })
        i = i + 1
      end
      ast.children[#ast.children + 1] = node("UnorderedList", { children = items })

    -- Ordered list: #. item or 1. item
    elseif stripped:match("^%s*[%d#]+%.%s+") then
      local items = {}
      while i <= #lines do
        local il = lines[i]:gsub("\n$", "")
        local item_text = il:match("^%s*[%d#]+%.%s+(.*)")
        if not item_text then break end
        items[#items + 1] = node("ListItem", { children = parse_inline_rst(item_text) })
        i = i + 1
      end
      ast.children[#ast.children + 1] = node("OrderedList", { children = items })

    -- Paragraph
    else
      local para_lines = {}
      while i <= #lines do
        local pl = lines[i]:gsub("\n$", "")
        if pl:match("^%s*$") then break end
        if i + 1 <= #lines and is_rst_underline(strip_newline(lines[i+1])) then break end
        if is_rst_underline(pl) then break end
        if pl:match("^%.%.") then break end
        if pl:match("^%s*[-*]%s+") then break end
        if pl:match("^%s*[%d#]+%.%s+") then break end
        para_lines[#para_lines + 1] = pl
        i = i + 1
      end
      if #para_lines > 0 then
        local para_text = table.concat(para_lines, "\n")
        local children = parse_inline_rst(para_text)
        ast.children[#ast.children + 1] = node("Paragraph", { children = children })
      end
    end
  end

  return ast
end

-- ============================================================
-- AsciiDoc parser
-- ============================================================

--: (text: string) -> { tag: string, children: unknown[] }
function M.parse_asciidoc(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end

  local lines = split_lines(text)
  local ast = { tag = "Document", children = {} }
  local i = 1

  while i <= #lines do
    local line = lines[i]
    local stripped = line:gsub("\n$", "")

    -- Blank line
    if stripped:match("^%s*$") then
      i = i + 1

    -- Heading: = Title, == Section, etc.
    elseif stripped:match("^(=+)%s+(.+)") then
      local signs, content = stripped:match("^(=+)%s+(.*)")
      local signs_str = signs or "" --: string
      local level = math.min(#signs_str, 6)
      local children = parse_inline_asciidoc(content)
      ast.children[#ast.children + 1] = node("Heading", { level = level, children = children })
      i = i + 1

    -- Horizontal rule: ----
    elseif stripped:match("^%-%-%-%-+%s*$") then
      ast.children[#ast.children + 1] = node("HorizontalRule")
      i = i + 1

    -- Code block: ....
    elseif stripped == "...." then
      i = i + 1
      local code_lines = {}
      while i <= #lines do
        local cl = lines[i]:gsub("\n$", "")
        if cl == "...." then
          i = i + 1
          break
        end
        code_lines[#code_lines + 1] = lines[i]
        i = i + 1
      end
      local code = table.concat(code_lines):gsub("\n$", "")
      ast.children[#ast.children + 1] = node("CodeBlock", { lang = "", value = code })

    -- Source code block: [source,lang] followed by ----
    elseif stripped:match("^%[source") then
      local lang = stripped:match("^%[source%s*,%s*(.-)%s*%]") or ""
      i = i + 1
      -- Expect ---- delimiter
      if i <= #lines and lines[i]:gsub("\n$", ""):match("^%-%-%-%-+%s*$") then
        i = i + 1
        local code_lines = {}
        while i <= #lines do
          local cl = lines[i]:gsub("\n$", "")
          if cl:match("^%-%-%-%-+%s*$") then
            i = i + 1
            break
          end
          code_lines[#code_lines + 1] = lines[i]
          i = i + 1
        end
        local code = table.concat(code_lines):gsub("\n$", "")
        ast.children[#ast.children + 1] = node("CodeBlock", { lang = lang, value = code })
      end

    -- Unordered list: * item
    elseif stripped:match("^%*+%s+") then
      local items = {}
      while i <= #lines do
        local il = lines[i]:gsub("\n$", "")
        local item_text = il:match("^%*+%s+(.*)")
        if not item_text then break end
        items[#items + 1] = node("ListItem", { children = parse_inline_asciidoc(item_text) })
        i = i + 1
      end
      ast.children[#ast.children + 1] = node("UnorderedList", { children = items })

    -- Ordered list: . item
    elseif stripped:match("^%.+%s+") then
      local items = {}
      while i <= #lines do
        local il = lines[i]:gsub("\n$", "")
        local item_text = il:match("^%.+%s+(.*)")
        if not item_text then break end
        items[#items + 1] = node("ListItem", { children = parse_inline_asciidoc(item_text) })
        i = i + 1
      end
      ast.children[#ast.children + 1] = node("OrderedList", { children = items })

    -- Paragraph
    else
      local para_lines = {}
      while i <= #lines do
        local pl = lines[i]:gsub("\n$", "")
        if pl:match("^%s*$") then break end
        if pl:match("^(=+)%s") then break end
        if pl:match("^%-%-%-%-+%s*$") then break end
        if pl == "...." then break end
        if pl:match("^%*+%s+") then break end
        if pl:match("^%.+%s+") then break end
        if pl:match("^%[source") then break end
        para_lines[#para_lines + 1] = pl
        i = i + 1
      end
      if #para_lines > 0 then
        local para_text = table.concat(para_lines, "\n")
        local children = parse_inline_asciidoc(para_text)
        ast.children[#ast.children + 1] = node("Paragraph", { children = children })
      end
    end
  end

  return ast
end

-- ============================================================
-- AST to HTML serializer
-- ============================================================

local function serialize_html(n, buf)
  local tag = n.tag

  if tag == "Document" then
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end

  elseif tag == "Heading" then
    local ht = "h" .. (n.level --[[:! integer ]])
    buf[#buf + 1] = "<" .. ht .. ">"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</" .. ht .. ">\n"

  elseif tag == "Paragraph" then
    buf[#buf + 1] = "<p>"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</p>\n"

  elseif tag == "Bold" then
    buf[#buf + 1] = "<strong>"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</strong>"

  elseif tag == "Italic" then
    buf[#buf + 1] = "<em>"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</em>"

  elseif tag == "Code" then
    buf[#buf + 1] = "<code>" .. esc(n.value --[[:! string ]]) .. "</code>"

  elseif tag == "CodeBlock" then
    local cb_lang = n.lang --[[:! string | nil ]]
    local cb_val = n.value --[[:! string ]]
    if cb_lang and cb_lang ~= "" then
      buf[#buf + 1] = '<pre><code class="language-' .. esc(cb_lang) .. '">' .. esc(cb_val) .. "</code></pre>\n"
    else
      buf[#buf + 1] = "<pre><code>" .. esc(cb_val) .. "</code></pre>\n"
    end

  elseif tag == "UnorderedList" then
    buf[#buf + 1] = "<ul>\n"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</ul>\n"

  elseif tag == "OrderedList" then
    buf[#buf + 1] = "<ol>\n"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</ol>\n"

  elseif tag == "ListItem" then
    buf[#buf + 1] = "<li>"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</li>\n"

  elseif tag == "Link" then
    buf[#buf + 1] = '<a href="' .. esc(n.url --[[:! string ]]) .. '">'
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</a>"

  elseif tag == "Image" then
    buf[#buf + 1] = '<img src="' .. esc(n.src --[[:! string ]]) .. '" alt="' .. esc(n.alt --[[:! string ]]) .. '">'

  elseif tag == "BlockQuote" then
    buf[#buf + 1] = "<blockquote>\n"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</blockquote>\n"

  elseif tag == "HorizontalRule" then
    buf[#buf + 1] = "<hr>\n"

  elseif tag == "LineBreak" then
    buf[#buf + 1] = "<br>\n"

  elseif tag == "Text" then
    buf[#buf + 1] = esc(n.value --[[:! string ]])

  elseif tag == "Table" then
    buf[#buf + 1] = "<table>\n"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</table>\n"

  elseif tag == "TableRow" then
    buf[#buf + 1] = "<tr>\n"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</tr>\n"

  elseif tag == "TableCell" then
    local elem = n.header and "th" or "td"
    buf[#buf + 1] = "<" .. elem .. ">"
    for _, child in ipairs(n.children) do
      serialize_html(child, buf)
    end
    buf[#buf + 1] = "</" .. elem .. ">\n"
  end
end

function M.ast_to_html(ast)
  local buf = {}
  serialize_html(ast, buf)
  return table.concat(buf)
end

-- ============================================================
-- AST to plain text
-- ============================================================

local function serialize_text(n, buf)
  local tag = n.tag

  if tag == "Document" or tag == "BlockQuote" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end

  elseif tag == "Heading" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end
    buf[#buf + 1] = "\n"

  elseif tag == "Paragraph" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end
    buf[#buf + 1] = "\n"

  elseif tag == "Bold" or tag == "Italic" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end

  elseif tag == "Code" then
    buf[#buf + 1] = n.value

  elseif tag == "CodeBlock" then
    buf[#buf + 1] = n.value
    buf[#buf + 1] = "\n"

  elseif tag == "UnorderedList" or tag == "OrderedList" or tag == "Table" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end

  elseif tag == "ListItem" or tag == "TableRow" or tag == "TableCell" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end
    buf[#buf + 1] = "\n"

  elseif tag == "Link" then
    for _, child in ipairs(n.children) do
      serialize_text(child, buf)
    end

  elseif tag == "Image" then
    buf[#buf + 1] = n.alt

  elseif tag == "HorizontalRule" then
    buf[#buf + 1] = "\n"

  elseif tag == "LineBreak" then
    buf[#buf + 1] = "\n"

  elseif tag == "Text" then
    buf[#buf + 1] = n.value
  end
end

function M.ast_to_text(ast)
  local buf = {}
  serialize_text(ast, buf)
  return table.concat(buf)
end

-- ============================================================
-- Top-level convenience functions
-- ============================================================

function M.markdown(text)
  if type(text) ~= "string" then
    return nil, "expected string"
  end
  local ok, result = pcall(function()
    return M.ast_to_html(M.parse_markdown(text))
  end)
  if not ok then return nil, result end
  return result
end

function M.rst(text)
  if type(text) ~= "string" then
    return nil, "expected string"
  end
  local ok, result = pcall(function()
    return M.ast_to_html(M.parse_rst(text))
  end)
  if not ok then return nil, result end
  return result
end

function M.asciidoc(text)
  if type(text) ~= "string" then
    return nil, "expected string"
  end
  local ok, result = pcall(function()
    return M.ast_to_html(M.parse_asciidoc(text))
  end)
  if not ok then return nil, result end
  return result
end

return M
