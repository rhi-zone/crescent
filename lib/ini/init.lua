-- lib/ini/init.lua
-- INI file parser and encoder.
-- Pure Lua implementation — no dependencies, works on LuaJIT and PUC-Rio 5.2+.
--
-- Public API:
--   M.decode(s, opts?)            → table | (nil, errmsg)
--   M.encode(t, opts?)            → string | (nil, errmsg)
--   M.string_to_table(s, opts?)   → table | (nil, errmsg)
--   M.table_to_string(t, opts?)   → string | (nil, errmsg)
--   M._tier                       → "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Trim leading and trailing whitespace from a string.
--: (s: string) -> string
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Remove surrounding quotes from a value string if present.
--: (s: string) -> string
local function unquote(s)
  if #s >= 2 then
    local first = s:sub(1, 1)
    local last = s:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
      return s:sub(2, -2)
    end
  end
  return s
end

-- Strip an inline comment from a value string.
-- Only strips if the comment char is preceded by whitespace or is at position 1,
-- and is not inside quotes.
--: (s: string, comment_chars: string) -> string
local function strip_inline_comment(s, comment_chars)
  local in_quote = false
  local quote_char = nil
  for i = 1, #s do
    local c = s:sub(i, i)
    if in_quote then
      if c == quote_char then
        in_quote = false
      end
    elseif c == '"' or c == "'" then
      in_quote = true
      quote_char = c
    elseif comment_chars:find(c, 1, true) then
      -- Inline comment: must be preceded by whitespace
      if i == 1 or s:sub(i - 1, i - 1):match("%s") then
        return s:sub(1, i - 1)
      end
    end
  end
  return s
end

--- Parse an INI string into a table of sections.
-- Keys outside any section go into result[""] (empty string key).
-- Duplicate keys within a section: last value wins.
--: (s: string, opts: { comment: string?, delimiter: string?, lowercase: boolean? }?) -> { [string]: { [string]: string } } | (nil, string)
function M.string_to_table(s, opts)
  if type(s) ~= "string" then
    return nil, "expected string, got " .. type(s)
  end

  local comment_chars = (opts and opts.comment) or ";#"
  local delimiter = (opts and opts.delimiter) or "="
  local lowercase = opts and opts.lowercase

  local result = {}
  local current_section = ""
  result[current_section] = {}

  local continuation = nil -- accumulates backslash-continued lines

  local lines = {}
  -- Split into lines, handling \r\n and \n
  local pos = 1
  while pos <= #s do
    local nl = s:find("\n", pos, true)
    if nl then
      local line = s:sub(pos, nl - 1)
      -- Strip trailing \r
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      lines[#lines + 1] = line
      pos = nl + 1
    else
      lines[#lines + 1] = s:sub(pos)
      pos = #s + 1
    end
  end

  for i = 1, #lines do
    local raw_line = lines[i]
    local line

    -- Handle backslash continuation
    if continuation then
      line = continuation .. trim(raw_line)
      continuation = nil
    else
      line = raw_line
    end

    -- Check for backslash continuation (trailing backslash)
    if line:sub(-1) == "\\" then
      continuation = line:sub(1, -2)
      goto continue
    end

    -- Trim the line
    line = trim(line)

    -- Skip empty lines
    if line == "" then
      goto continue
    end

    -- Skip comment lines
    local first_char = line:sub(1, 1)
    if comment_chars:find(first_char, 1, true) then
      goto continue
    end

    -- Section header
    local section = line:match("^%[(.-)%]")
    if section then
      section = trim(section)
      if lowercase then
        section = section:lower()
      end
      current_section = section
      if not result[current_section] then
        result[current_section] = {}
      end
      goto continue
    end

    -- Key-value pair
    local delim_pos = line:find(delimiter, 1, true)
    if delim_pos then
      local key = trim(line:sub(1, delim_pos - 1))
      local value = trim(line:sub(delim_pos + #delimiter))

      if lowercase then
        key = key:lower()
      end

      -- Strip inline comments from value
      value = trim(strip_inline_comment(value, comment_chars))

      -- Unquote
      value = unquote(value)

      if not result[current_section] then
        result[current_section] = {}
      end
      result[current_section][key] = value
    end

    ::continue::
  end

  -- Remove empty global section if unused
  if result[""] and next(result[""]) == nil then
    result[""] = nil
  end

  return result
end

--- Encode a table of sections into an INI string.
--: (t: { [string]: { [string]: string } }, opts: { delimiter: string?, comment: string? }?) -> string | (nil, string)
function M.table_to_string(t, opts)
  if type(t) ~= "table" then
    return nil, "expected table, got " .. type(t)
  end

  local delimiter = (opts and opts.delimiter) or " = "

  local parts = {}

  -- Collect and sort section names for deterministic output
  local sections = {}
  for section in pairs(t) do
    sections[#sections + 1] = section
  end
  table.sort(sections)

  for si = 1, #sections do
    local section = sections[si]
    local kv = t[section]

    if type(kv) ~= "table" then
      return nil, "section '" .. tostring(section) .. "' value must be a table"
    end

    -- Add blank line between sections (not before the first)
    if #parts > 0 then
      parts[#parts + 1] = ""
    end

    -- Section header (skip for global section "")
    if section ~= "" then
      parts[#parts + 1] = "[" .. section .. "]"
    end

    -- Collect and sort keys for deterministic output
    local keys = {}
    for k in pairs(kv) do
      keys[#keys + 1] = k
    end
    table.sort(keys)

    for ki = 1, #keys do
      local k = keys[ki]
      local v = tostring(kv[k])
      parts[#parts + 1] = k .. delimiter .. v
    end
  end

  -- Trailing newline
  if #parts > 0 then
    parts[#parts + 1] = ""
  end

  return table.concat(parts, "\n")
end

-- Uniform aliases
M.decode = M.string_to_table
M.encode = M.table_to_string

return M
