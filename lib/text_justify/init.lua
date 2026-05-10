if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Text justification, alignment, word wrap, and layout utilities.
local M = {}
M._tier = "pure"

-- ── Helpers ──────────────────────────────────────────────────────────────────

--- Split a string into lines on \n boundaries.
--: (s: string) -> { [integer]: string }
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
  if len == 0 then lines[1] = "" end
  return lines
end

--- Collapse runs of whitespace (space/tab) into single spaces and trim.
--: (s: string) -> string
local function collapse_ws(s)
  return (s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Measure display width (plain ASCII: byte length).
--: (s: string) -> integer
local function display_width(s)
  return #s
end

-- ── wrap ─────────────────────────────────────────────────────────────────────

--- Word-wrap `text` into lines of at most `width` columns.
-- Returns an array of strings.
-- opts.break_long (bool, default true): break words longer than width
-- opts.preserve_spaces (bool, default false): keep original whitespace
--: (text: string, width: integer, opts: { break_long: boolean | nil, preserve_spaces: boolean | nil, ... } | nil) -> string[]
function M.wrap(text, width, opts)
  if not text or text == "" then return {""} end
  opts = (opts or {}) --[[:! { break_long: boolean | nil, preserve_spaces: boolean | nil, ... }]]
  local break_long = opts.break_long ~= false  -- default true
  local preserve_spaces = opts.preserve_spaces or false

  -- Tokenize into words
  local words = {} --[[: string[] ]]
  if preserve_spaces then
    -- Split on whitespace runs but keep track of original
    for tok in text:gmatch("%S+") do
      words[#words + 1] = tok
    end
  else
    text = collapse_ws(text)
    for tok in text:gmatch("%S+") do
      words[#words + 1] = tok
    end
  end

  if #words == 0 then return {""} end

  local lines = {}
  local line_words = {}
  local line_len = 0

  local function flush()
    if #line_words > 0 then
      lines[#lines + 1] = table.concat(line_words, " ")
      line_words = {}
      line_len = 0
    end
  end

  for _, word in ipairs(words) do
    local wlen = display_width(word)

    -- Handle word longer than width
    if break_long and wlen > width then
      -- Flush current line first
      flush()
      -- Break the long word into chunks
      local pos = 1
      while pos <= wlen do
        local chunk = word:sub(pos, pos + width - 1)
        if #chunk == width then
          lines[#lines + 1] = chunk
        else
          -- Last partial chunk: treat as normal word
          line_words[#line_words + 1] = chunk
          line_len = display_width(chunk)
        end
        pos = pos + width
      end
    else
      -- Does word fit on current line?
      local needed = line_len == 0 and wlen or (line_len + 1 + wlen)
      if needed <= width then
        line_words[#line_words + 1] = word
        line_len = needed
      else
        flush()
        line_words[1] = word
        line_len = wlen
      end
    end
  end

  flush()

  return lines
end

-- ── Single-line alignment ─────────────────────────────────────────────────────

--- Left-align `text` in a field of `width` chars (pad right with spaces).
-- Truncates if text is longer than width.
--: (text: string, width: integer) -> string
function M.left(text, width)
  local len = display_width(text)
  if len >= width then return text:sub(1, width) end
  return text .. string.rep(" ", width - len)
end

--- Right-align `text` in a field of `width` chars (pad left with spaces).
-- Truncates if text is longer than width.
--: (text: string, width: integer) -> string
function M.right(text, width)
  local len = display_width(text)
  if len >= width then return text:sub(1, width) end
  return string.rep(" ", width - len) .. text
end

--- Center `text` in a field of `width` chars.
-- Extra space goes to the right. Truncates if text is longer than width.
--: (text: string, width: integer) -> string
function M.center(text, width)
  local len = display_width(text)
  if len >= width then return text:sub(1, width) end
  local pad = width - len
  local left_pad = math.floor(pad / 2)
  local right_pad = pad - left_pad
  return string.rep(" ", left_pad) .. text .. string.rep(" ", right_pad)
end

--- Full-justify `text` in a field of `width` chars.
-- Spreads spaces between words to fill exactly `width`.
-- If there is only one word (or text > width), falls back to left-align.
--: (text: string, width: integer) -> string
function M.justify(text, width)
  local len = display_width(text)
  if len >= width then return text:sub(1, width) end

  -- Tokenize into words
  local words = {}
  for w in text:gmatch("%S+") do
    words[#words + 1] = w
  end

  if #words <= 1 then
    -- Single word: left-align
    return M.left(text, width)
  end

  local words_len = 0
  for _, w in ipairs(words) do words_len = words_len + display_width(w) end

  local gaps = #words - 1
  local total_spaces = width - words_len
  local base_space = math.floor(total_spaces / gaps)
  local extra = total_spaces - base_space * gaps  -- first `extra` gaps get one extra space

  local parts = {}
  for i, w in ipairs(words) do
    parts[#parts + 1] = w
    if i < #words then
      local sp = base_space + (i <= extra and 1 or 0)
      parts[#parts + 1] = string.rep(" ", sp)
    end
  end

  return table.concat(parts)
end

-- ── paragraph ────────────────────────────────────────────────────────────────

--- Wrap `text` and align each line using `mode`.
-- mode: "left" | "right" | "center" | "justify" (default "left")
-- In justify mode the last line is left-aligned.
-- Returns an array of lines, each exactly `width` chars.
--: (text: string, width: integer, mode: string | nil) -> string[]
function M.paragraph(text, width, mode)
  mode = mode or "left"
  local lines = M.wrap(text, width)
  local result = {}
  local align_fn = M[mode] or M.left
  for i, line in ipairs(lines) do
    local is_last = (i == #lines)
    if mode == "justify" and is_last then
      result[#result + 1] = M.left(line, width)
    else
      result[#result + 1] = align_fn(line, width)
    end
  end
  return result
end

-- ── columns ──────────────────────────────────────────────────────────────────

--- Format multiple columns.
-- rows: array of arrays (each row is an array of strings)
-- widths: array of column widths
-- opts.sep (string, default " "): column separator
-- opts.align (array of "left"|"right"|"center"): alignment per column
-- Returns array of formatted lines.
--: (rows: { [integer]: { [integer]: unknown, ... }, ... }, widths: integer[], opts: { sep: string | nil, align: { [integer]: string, ... } | nil, ... } | nil) -> string[]
function M.columns(rows, widths, opts)
  opts = (opts or {}) --[[:! { sep: string | nil, align: { [integer]: string, ... } | nil, ... }]]
  local sep = opts.sep or " "
  local align = opts.align or {}
  local result = {}
  for _, row in ipairs(rows) do
    local parts = {}
    for col = 1, #widths do
      local cell = row[col] or ""
      local mode = align[col] or "left"
      local fn = M[mode] or M.left
      parts[#parts + 1] = fn(cell, widths[col])
    end
    result[#result + 1] = table.concat(parts, sep)
  end
  return result
end

-- ── table ────────────────────────────────────────────────────────────────────

--- ASCII art table formatter.
-- data: {headers={"Name","Age",...}, rows={{...},...}}
-- opts.border (bool, default true): draw +---+ borders
-- opts.align (array): alignment per column ("left","right","center")
-- opts.padding (int, default 1): spaces inside each cell
-- Returns a multi-line string.
--: (data: { headers?: string[], rows?: { [integer]: { [integer]: unknown, ... }, ... } | nil, ... }, opts: { border: boolean | nil, align: { [integer]: string, ... } | nil, padding: integer | nil, ... } | nil) -> string
function M.table(data, opts)
  opts = (opts or {}) --[[:! { border: boolean | nil, align: { [integer]: string, ... } | nil, padding: integer | nil, ... }]]
  local border = opts.border ~= false  -- default true
  local align = opts.align or {}
  local padding = opts.padding or 1
  local pad = string.rep(" ", padding)

  local headers = data.headers or {}
  local rows = data.rows or {}
  local ncols = #headers
  for _, row in ipairs(rows) do
    if #row > ncols then ncols = #row end
  end

  -- Compute column widths (content width, without padding)
  local col_widths = {} --[[: integer[] ]]
  for c = 1, ncols do
    col_widths[c] = display_width(headers[c] or "")
  end
  for _, row in ipairs(rows) do
    for c = 1, ncols do
      local cell_str = tostring(row[c] or "")
      local w = display_width(cell_str)
      if w > col_widths[c] then col_widths[c] = w end
    end
  end

  local function fmt_cell(cell, col)
    local s = tostring(cell or "")
    local w = col_widths[col]
    local mode = align[col] or "left"
    local fn = M[mode] or M.left
    return pad .. fn(s, w) .. pad
  end

  local function separator()
    local parts = {}
    for c = 1, ncols do
      parts[#parts + 1] = string.rep("-", col_widths[c] + padding * 2)
    end
    return "+" .. table.concat(parts, "+") .. "+"
  end

  local function row_line(row)
    local parts = {}
    for c = 1, ncols do
      parts[#parts + 1] = fmt_cell(row[c] or "", c)
    end
    return "|" .. table.concat(parts, "|") .. "|"
  end

  local out = {}

  if border then
    out[#out + 1] = separator()
  end

  if #headers > 0 then
    out[#out + 1] = row_line(headers)
    if border then
      out[#out + 1] = separator()
    end
  end

  for _, row in ipairs(rows) do
    out[#out + 1] = row_line(row)
  end

  if border then
    out[#out + 1] = separator()
  end

  return table.concat(out, "\n")
end

-- ── truncate ─────────────────────────────────────────────────────────────────

--- Truncate `text` to at most `max_len` characters, appending `ellipsis` if cut.
-- Default ellipsis is "...".
--: (text: string, max_len: integer, ellipsis: string | nil) -> string
function M.truncate(text, max_len, ellipsis)
  if ellipsis == nil then ellipsis = "..." end
  local len = display_width(text)
  if len <= max_len then return text end
  local elen = display_width(ellipsis)
  if max_len <= elen then
    return ellipsis:sub(1, max_len)
  end
  return text:sub(1, max_len - elen) .. ellipsis
end

-- ── pad helpers ──────────────────────────────────────────────────────────────

--- Pad string on the left to `width` using `char` (default " ").
--: (s: string, width: integer, char: string | nil) -> string
function M.pad_left(s, width, char)
  char = char or " "
  local len = display_width(s)
  if len >= width then return s end
  return string.rep(char, width - len) .. s
end

--- Pad string on the right to `width` using `char` (default " ").
--: (s: string, width: integer, char: string | nil) -> string
function M.pad_right(s, width, char)
  char = char or " "
  local len = display_width(s)
  if len >= width then return s end
  return s .. string.rep(char, width - len)
end

--- Pad string on both sides to `width` using `char` (default " ").
-- Extra padding goes to the right.
--: (s: string, width: integer, char: string | nil) -> string
function M.pad_center(s, width, char)
  char = char or " "
  local len = display_width(s)
  if len >= width then return s end
  local pad = width - len
  local left_pad = math.floor(pad / 2)
  local right_pad = pad - left_pad
  return string.rep(char, left_pad) .. s .. string.rep(char, right_pad)
end

-- ── indent / dedent ──────────────────────────────────────────────────────────

--- Add `n` copies of `char` (default " ") to the start of each line in `text`.
--: (text: string, n: integer, char: string | nil) -> string
function M.indent(text, n, char)
  char = char or " "
  local prefix = string.rep(char, n)
  local lines = split_lines(text)
  for i, line in ipairs(lines) do
    lines[i] = prefix .. line
  end
  return table.concat(lines, "\n")
end

--- Remove common leading whitespace from all lines.
-- Ignores empty lines when computing the common prefix.
function M.dedent(text)
  local lines = split_lines(text)

  -- Find common leading whitespace (spaces/tabs)
  local common = nil
  for _, line in ipairs(lines) do
    if line:match("%S") then  -- non-empty line
      local leading = line:match("^(%s*)")
      if common == nil then
        common = leading
      else
        -- Find longest common prefix of common and leading
        local min_len = math.min(#common, #leading)
        local c = 0
        while c < min_len and common:sub(c+1,c+1) == leading:sub(c+1,c+1) do
          c = c + 1
        end
        common = common:sub(1, c)
      end
    end
  end

  if not common or common == "" then return text end

  for i, line in ipairs(lines) do
    if line:match("%S") then
      lines[i] = line:sub(#common + 1)
    end
  end

  return table.concat(lines, "\n")
end

return M
