if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Markdown to HTML and plain text renderer.
-- Supports common Markdown elements (headings, lists, code blocks, inline
-- formatting). Not a full CommonMark parser — designed for practical use cases.
-- For full CommonMark compliance, see lib/unified/.

local M = {}

M._tier = "pure"

-- ---------------------------------------------------------------------------
-- HTML escaping
-- ---------------------------------------------------------------------------

-- Escape HTML special characters in text nodes.
--: (string) -> string
local function html_escape(s)
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  return s
end

-- ---------------------------------------------------------------------------
-- Inline rendering
-- ---------------------------------------------------------------------------

-- Process inline Markdown spans within a raw text line, returning HTML.
-- Text segments between spans are HTML-escaped. Spans produce their own HTML.
-- Uses a greedy left-to-right scan with a priority list of patterns.
--: (string) -> string
local function inline_html(s)
  -- Patterns tried in order (priority matters: longer markers first).
  -- Each returns (match_start, match_end, replacement_html) or nil.

  local function try_image(s, pos)
    local ms, me, alt, url = s:find("^!%[(.-)%]%((.-)%)", pos)
    if ms then
      return ms, me, '<img src="' .. html_escape(url) .. '" alt="' .. html_escape(alt) .. '" />'
    end
  end

  local function try_link(s, pos)
    local ms, me, text, url = s:find("^%[(.-)%]%((.-)%)", pos)
    if ms then
      -- Inline-process the link text (no recursive links)
      local inner = text:gsub("`([^`]+)`", function(code)
        return "<code>" .. html_escape(code) .. "</code>"
      end)
      inner = inner:gsub("%*%*%*(.-)%*%*%*", "<strong><em>%1</em></strong>")
      inner = inner:gsub("___(.-)___", "<strong><em>%1</em></strong>")
      inner = inner:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
      inner = inner:gsub("__(.-)__", "<strong>%1</strong>")
      inner = inner:gsub("%*(.-)%*", "<em>%1</em>")
      inner = inner:gsub("_(.-)_", "<em>%1</em>")
      inner = html_escape(inner):gsub("&amp;lt;", "&lt;"):gsub("&amp;gt;", "&gt;")
      -- inner was already partially processed; just escape remaining raw text portions
      -- Simpler: escape the raw text first then apply span transforms
      local inner2 = html_escape(text)
      inner2 = inner2:gsub("`([^`]+)`", function(code) return "<code>" .. code .. "</code>" end)
      inner2 = inner2:gsub("%*%*%*(.-)%*%*%*", "<strong><em>%1</em></strong>")
      inner2 = inner2:gsub("___(.-)___", "<strong><em>%1</em></strong>")
      inner2 = inner2:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
      inner2 = inner2:gsub("__(.-)__", "<strong>%1</strong>")
      inner2 = inner2:gsub("%*(.-)%*", "<em>%1</em>")
      inner2 = inner2:gsub("_(.-)_", "<em>%1</em>")
      return ms, me, '<a href="' .. html_escape(url) .. '">' .. inner2 .. '</a>'
    end
  end

  local function try_autolink(s, pos)
    local ms, me, url = s:find("^<(https?://[^>]+)>", pos)
    if ms then
      return ms, me, '<a href="' .. html_escape(url) .. '">' .. html_escape(url) .. '</a>'
    end
    ms, me, url = s:find("^<(mailto:[^>]+)>", pos)
    if ms then
      return ms, me, '<a href="' .. html_escape(url) .. '">' .. html_escape(url) .. '</a>'
    end
  end

  local function try_code(s, pos)
    local ms, me, code = s:find("^`([^`]+)`", pos)
    if ms then
      return ms, me, "<code>" .. html_escape(code) .. "</code>"
    end
  end

  local function try_bold_italic(s, pos)
    local ms, me, inner = s:find("^%*%*%*(.-)%*%*%*", pos)
    if ms then return ms, me, "<strong><em>" .. inner .. "</em></strong>" end
    ms, me, inner = s:find("^___(.-)___", pos)
    if ms then return ms, me, "<strong><em>" .. inner .. "</em></strong>" end
  end

  local function try_bold(s, pos)
    local ms, me, inner = s:find("^%*%*(.-)%*%*", pos)
    if ms then return ms, me, "<strong>" .. inner .. "</strong>" end
    ms, me, inner = s:find("^__(.-)__", pos)
    if ms then return ms, me, "<strong>" .. inner .. "</strong>" end
  end

  local function try_italic(s, pos)
    local ms, me, inner = s:find("^%*(.-)%*", pos)
    if ms then return ms, me, "<em>" .. inner .. "</em>" end
    ms, me, inner = s:find("^_(.-)_", pos)
    if ms then return ms, me, "<em>" .. inner .. "</em>" end
  end

  local spans = { try_image, try_link, try_autolink, try_code, try_bold_italic, try_bold, try_italic }

  local out = {}
  local pos = 1
  local len = #s

  -- Handle hard line break: two spaces before end of string / newline
  local trailing_br = s:match("  $")
  if trailing_br then
    s = s:sub(1, len - 2)
    len = len - 2
  end

  while pos <= len do
    -- Try each span starting at current pos
    local found = false
    for _, try_fn in ipairs(spans) do
      local ms, me, repl = try_fn(s, pos)
      if ms then
        -- Escape and emit any text before this span
        if ms > pos then
          out[#out + 1] = html_escape(s:sub(pos, ms - 1))
        end
        out[#out + 1] = repl
        pos = me + 1
        found = true
        break
      end
    end
    if not found then
      -- No span matched at this position; advance one character
      out[#out + 1] = html_escape(s:sub(pos, pos))
      pos = pos + 1
    end
  end

  if trailing_br then
    out[#out + 1] = "<br />"
  end

  return table.concat(out)
end

-- Process inline Markdown spans, returning plain text (strip markers).
--: (string) -> string
local function inline_text(s)
  -- Images: keep alt text
  s = s:gsub("!%[(.-)%]%((.-)%)", "%1")
  -- Links: text (url)
  s = s:gsub("%[(.-)%]%((.-)%)", "%1 (%2)")
  -- Auto-links: just the URL
  s = s:gsub("<(https?://[^>]+)>", "%1")
  s = s:gsub("<(mailto:[^>]+)>", "%1")
  -- Inline code: keep code content
  s = s:gsub("`([^`]+)`", "%1")
  -- Bold+italic markers
  s = s:gsub("%*%*%*(.-)%*%*%*", "%1")
  s = s:gsub("___(.-)___", "%1")
  -- Bold markers
  s = s:gsub("%*%*(.-)%*%*", "%1")
  s = s:gsub("__(.-)__", "%1")
  -- Italic markers
  s = s:gsub("%*(.-)%*", "%1")
  s = s:gsub("_(.-)_", "%1")
  -- Hard line break
  s = s:gsub("  $", "\n")
  return s
end

-- ---------------------------------------------------------------------------
-- Line splitting
-- ---------------------------------------------------------------------------

-- Split a string into lines (without trailing newline on each).
--: (string) -> { [integer]: string }
local function split_lines(s)
  local lines = {}
  local i = 1
  local len = #s
  while i <= len do
    local j = s:find("\n", i, true)
    if j then
      lines[#lines + 1] = s:sub(i, j - 1)
      i = j + 1
    else
      lines[#lines + 1] = s:sub(i)
      i = len + 1
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Block parser
-- ---------------------------------------------------------------------------

-- A block is: { type, ... }
-- Types: "heading", "paragraph", "blockquote", "ul", "ol",
--        "fenced_code", "indented_code", "hr", "raw_html", "blank"

--:: HeadingBlock    = { type: "heading",      level: integer, text: string }
--:: ParagraphBlock  = { type: "paragraph",    lines: { [integer]: string } }
--:: BlockquoteBlock = { type: "blockquote",   lines: { [integer]: string } }
--:: UlBlock         = { type: "ul",           items: { [integer]: string } }
--:: OlBlock         = { type: "ol",           items: { [integer]: string }, start: integer }
--:: FencedCodeBlock = { type: "fenced_code",  lang: string, code: string }
--:: IndentedCodeBlock = { type: "indented_code", code: string }
--:: HrBlock         = { type: "hr" }
--:: RawHtmlBlock    = { type: "raw_html",     content: string }
--:: Block = HeadingBlock | ParagraphBlock | BlockquoteBlock | UlBlock | OlBlock | FencedCodeBlock | IndentedCodeBlock | HrBlock | RawHtmlBlock

--: (string) -> boolean
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

--: (string) -> boolean
local function is_thematic_break(line)
  -- Three or more of -, *, _ (with optional spaces between)
  if line:match("^[ \t]*%-[ \t]*%-[ \t]*%-") and not line:match("[^%- \t]") then return true end
  if line:match("^[ \t]*%*[ \t]*%*[ \t]*%*") and not line:match("[^%* \t]") then return true end
  if line:match("^[ \t]*_[ \t]*_[ \t]*_")    and not line:match("[^_ \t]")  then return true end
  return false
end

-- Parse blocks from lines array.
--: ({ [integer]: string }) -> { [integer]: Block }
local function parse_blocks(lines)
  --: { [integer]: Block }
  local blocks = {}
  local i = 1
  local n = #lines

  while i <= n do
    local line = lines[i]

    -- Blank line
    if is_blank(line) then
      i = i + 1

    -- Fenced code block: ``` or ~~~
    elseif line:match("^[ \t]*```") or line:match("^[ \t]*~~~") then
      local fence = line:match("^[ \t]*(```+)") or line:match("^[ \t]*(~~~+)")
      local lang  = line:match("^[ \t]*[`~]+%s*(%S*)") or ""
      local code_lines = {}
      i = i + 1
      while i <= n and not lines[i]:match("^[ \t]*" .. fence:sub(1,3)) do
        code_lines[#code_lines + 1] = lines[i]
        i = i + 1
      end
      i = i + 1  -- skip closing fence
      blocks[#blocks + 1] = { type = "fenced_code", lang = lang, code = table.concat(code_lines, "\n") }

    -- Indented code block: 4 spaces or 1 tab
    elseif line:match("^    ") or line:match("^\t") then
      local code_lines = {}
      while i <= n and (lines[i]:match("^    ") or lines[i]:match("^\t") or is_blank(lines[i])) do
        local l = lines[i]
        if l:match("^    ") then
          code_lines[#code_lines + 1] = l:sub(5)
        elseif l:match("^\t") then
          code_lines[#code_lines + 1] = l:sub(2)
        else
          code_lines[#code_lines + 1] = ""
        end
        i = i + 1
      end
      -- Trim trailing blank lines
      while #code_lines > 0 and code_lines[#code_lines] == "" do
        code_lines[#code_lines] = nil
      end
      blocks[#blocks + 1] = { type = "indented_code", code = table.concat(code_lines, "\n") }

    -- ATX headings: # through ######
    elseif line:match("^#+ ") or line:match("^#+$") then
      local hashes, raw_text = line:match("^(#+)%s*(.*)")
      local level = math.min(#hashes, 6) --[[:! integer]]
      -- Strip optional trailing #s
      local text = (raw_text --[[:! string]]):gsub("%s+#+%s*$", ""):gsub("%s+$", "")
      blocks[#blocks + 1] = { type = "heading", level = level, text = text }
      i = i + 1

    -- Blockquote: > text
    elseif line:match("^>") then
      local bq_lines = {}
      while i <= n and (lines[i]:match("^>") or (not is_blank(lines[i]) and #bq_lines > 0 and not is_blank(bq_lines[#bq_lines]))) do
        local l = lines[i]
        if l:match("^>%s?") then
          bq_lines[#bq_lines + 1] = l:match("^>%s?(.*)")
        else
          bq_lines[#bq_lines + 1] = l
        end
        i = i + 1
      end
      blocks[#blocks + 1] = { type = "blockquote", lines = bq_lines }

    -- Unordered list: - * +
    elseif line:match("^[ \t]*[%-%*%+] ") then
      local items = {}
      while i <= n and (lines[i]:match("^[ \t]*[%-%*%+] ") or (not is_blank(lines[i]) and #items > 0)) do
        if lines[i]:match("^[ \t]*[%-%*%+] ") then
          items[#items + 1] = lines[i]:match("^[ \t]*[%-%*%+] (.*)")
        else
          -- continuation line — append to last item
          items[#items] = items[#items] .. " " .. lines[i]:match("^%s*(.*)")
        end
        i = i + 1
      end
      blocks[#blocks + 1] = { type = "ul", items = items }

    -- Ordered list: 1. 2. etc.
    elseif line:match("^[ \t]*%d+%. ") then
      local items = {}
      local start = (tonumber(line:match("^[ \t]*(%d+)%.")) or 1) --[[:! integer]]
      while i <= n and (lines[i]:match("^[ \t]*%d+%. ") or (not is_blank(lines[i]) and #items > 0)) do
        if lines[i]:match("^[ \t]*%d+%. ") then
          items[#items + 1] = lines[i]:match("^[ \t]*%d+%. (.*)")
        else
          items[#items] = items[#items] .. " " .. lines[i]:match("^%s*(.*)")
        end
        i = i + 1
      end
      blocks[#blocks + 1] = { type = "ol", items = items, start = start }

    -- Thematic break
    elseif is_thematic_break(line) then
      blocks[#blocks + 1] = { type = "hr" }
      i = i + 1

    -- Raw HTML block: line starts with < but is not an auto-link
    elseif line:match("^<[a-zA-Z/!]") and not line:match("^<https?://") and not line:match("^<mailto:") then
      local html_lines = {}
      while i <= n and not is_blank(lines[i]) do
        html_lines[#html_lines + 1] = lines[i]
        i = i + 1
      end
      blocks[#blocks + 1] = { type = "raw_html", content = table.concat(html_lines, "\n") }

    -- Paragraph (may become setext heading if followed by === or ---)
    else
      local para_lines = {}
      while i <= n and not is_blank(lines[i])
          and not lines[i]:match("^#+ ")
          and not lines[i]:match("^[ \t]*[%-%*%+] ")
          and not lines[i]:match("^[ \t]*%d+%. ")
          and not lines[i]:match("^[ \t]*```")
          and not lines[i]:match("^[ \t]*~~~")
          and not is_thematic_break(lines[i])
          -- Stop before setext underlines so they stay available for the check below.
          and not (i > 1 and #para_lines >= 1 and lines[i]:match("^=+%s*$"))
          and not (i > 1 and #para_lines >= 1 and lines[i]:match("^%-+%s*$")) do
        para_lines[#para_lines + 1] = lines[i]
        i = i + 1
      end
      if #para_lines == 0 then
        -- Fallback: consume one line as paragraph
        para_lines[#para_lines + 1] = line
        i = i + 1
      end
      -- Check for setext heading underline (any number of paragraph lines)
      if i <= n then
        local next_line = lines[i]
        if next_line:match("^=+%s*$") then
          -- Use all para_lines as the heading text (join with space)
          blocks[#blocks + 1] = { type = "heading", level = 1, text = table.concat(para_lines, " ") }
          i = i + 1
        elseif next_line:match("^%-+%s*$") then
          blocks[#blocks + 1] = { type = "heading", level = 2, text = table.concat(para_lines, " ") }
          i = i + 1
        else
          blocks[#blocks + 1] = { type = "paragraph", lines = para_lines }
        end
      else
        blocks[#blocks + 1] = { type = "paragraph", lines = para_lines }
      end
    end
  end

  return blocks
end

-- ---------------------------------------------------------------------------
-- HTML renderer
-- ---------------------------------------------------------------------------

--: (Block) -> string
local function render_block_html(block)
  if block.type == "heading" then
    local tag = "h" .. block.level
    return "<" .. tag .. ">" .. inline_html(block.text) .. "</" .. tag .. ">\n"

  elseif block.type == "paragraph" then
    local parts = {}
    for _, l in ipairs(block.lines) do
      parts[#parts + 1] = inline_html(l)
    end
    return "<p>" .. table.concat(parts, "\n") .. "</p>\n"

  elseif block.type == "blockquote" then
    local inner_blocks = parse_blocks(block.lines)
    local inner = {}
    for _, b in ipairs(inner_blocks) do
      inner[#inner + 1] = render_block_html(b)
    end
    return "<blockquote>\n" .. table.concat(inner) .. "</blockquote>\n"

  elseif block.type == "ul" then
    local parts = { "<ul>\n" }
    for _, item in ipairs(block.items) do
      parts[#parts + 1] = "<li>" .. inline_html(item) .. "</li>\n"
    end
    parts[#parts + 1] = "</ul>\n"
    return table.concat(parts)

  elseif block.type == "ol" then
    local parts
    if block.start ~= 1 then
      parts = { '<ol start="' .. block.start .. '">\n' }
    else
      parts = { "<ol>\n" }
    end
    for _, item in ipairs(block.items) do
      parts[#parts + 1] = "<li>" .. inline_html(item) .. "</li>\n"
    end
    parts[#parts + 1] = "</ol>\n"
    return table.concat(parts)

  elseif block.type == "fenced_code" then
    if block.lang ~= "" then
      return '<pre><code class="language-' .. html_escape(block.lang) .. '">'
        .. html_escape(block.code) .. "</code></pre>\n"
    else
      return "<pre><code>" .. html_escape(block.code) .. "</code></pre>\n"
    end

  elseif block.type == "indented_code" then
    return "<pre><code>" .. html_escape(block.code) .. "</code></pre>\n"

  elseif block.type == "hr" then
    return "<hr />\n"

  elseif block.type == "raw_html" then
    return block.content .. "\n"

  else
    return ""
  end
end

-- ---------------------------------------------------------------------------
-- Plain text renderer
-- ---------------------------------------------------------------------------

--: (Block) -> string
local function render_block_text(block)
  if block.type == "heading" then
    local text = inline_text(block.text)
    if block.level == 1 then
      return text .. "\n" .. string.rep("=", #text) .. "\n"
    elseif block.level == 2 then
      return text .. "\n" .. string.rep("-", #text) .. "\n"
    else
      return text .. "\n"
    end

  elseif block.type == "paragraph" then
    local parts = {}
    for _, l in ipairs(block.lines) do
      parts[#parts + 1] = inline_text(l)
    end
    return table.concat(parts, "\n") .. "\n"

  elseif block.type == "blockquote" then
    local inner_blocks = parse_blocks(block.lines)
    local lines = {}
    for _, b in ipairs(inner_blocks) do
      local rendered = render_block_text(b)
      for _, l in ipairs(split_lines(rendered)) do
        lines[#lines + 1] = "> " .. l
      end
    end
    return table.concat(lines, "\n") .. "\n"

  elseif block.type == "ul" then
    local parts = {}
    for _, item in ipairs(block.items) do
      parts[#parts + 1] = "- " .. inline_text(item)
    end
    return table.concat(parts, "\n") .. "\n"

  elseif block.type == "ol" then
    local parts = {}
    local start = block.start
    for idx, item in ipairs(block.items) do
      parts[#parts + 1] = (start + idx - 1) .. ". " .. inline_text(item)
    end
    return table.concat(parts, "\n") .. "\n"

  elseif block.type == "fenced_code" then
    return block.code .. "\n"

  elseif block.type == "indented_code" then
    return block.code .. "\n"

  elseif block.type == "hr" then
    return "---\n"

  elseif block.type == "raw_html" then
    return block.content .. "\n"

  else
    return ""
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Render Markdown to HTML string.
--: (string) -> string
function M.to_html(md)
  local lines = split_lines(md)
  local blocks = parse_blocks(lines)
  local parts = {}
  for _, block in ipairs(blocks) do
    parts[#parts + 1] = render_block_html(block)
  end
  return table.concat(parts)
end

-- Render Markdown to plain text (strip formatting, keep structure).
--: (string) -> string
function M.to_text(md)
  local lines = split_lines(md)
  local blocks = parse_blocks(lines)
  local parts = {}
  for _, block in ipairs(blocks) do
    parts[#parts + 1] = render_block_text(block)
  end
  return table.concat(parts)
end

-- Aliases
M.encode = M.to_html
M.render = M.to_html

return M
