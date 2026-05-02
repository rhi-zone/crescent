if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Extended string utilities beyond Lua's built-in string.*.
local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Inspection
-- ---------------------------------------------------------------------------

--- Returns true if s starts with prefix.
function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

--- Returns true if s ends with suffix.
function M.ends_with(s, suffix)
  if suffix == "" then return true end
  return s:sub(-#suffix) == suffix
end

--- Returns true if sub appears anywhere in s (plain substring).
function M.contains(s, sub)
  return s:find(sub, 1, true) ~= nil
end

--- Returns the number of non-overlapping occurrences of sub in s.
function M.count(s, sub)
  if sub == "" then return 0 end
  local n, i = 0, 1
  while true do
    local j = s:find(sub, i, true)
    if not j then break end
    n = n + 1
    i = j + #sub
  end
  return n
end

--- Returns true if s is nil or the empty string.
function M.is_empty(s)
  return s == nil or s == ""
end

--- Returns true if s is nil, empty, or contains only whitespace.
function M.is_blank(s)
  return s == nil or s:match("^%s*$") ~= nil
end

-- ---------------------------------------------------------------------------
-- Transformation
-- ---------------------------------------------------------------------------

--- Strip leading and trailing whitespace.
function M.trim(s)
  return s:match("^%s*(.-)%s*$")
end

--- Strip leading whitespace.
function M.trim_left(s)
  return s:match("^%s*(.*)")
end

--- Strip trailing whitespace.
function M.trim_right(s)
  return s:match("(.-)%s*$")
end

--- Pad s on the left to width n using char (default " ").
function M.pad_left(s, n, char)
  char = char or " "
  local len = #s
  if len >= n then return s end
  return char:rep(n - len) .. s
end

--- Pad s on the right to width n using char (default " ").
function M.pad_right(s, n, char)
  char = char or " "
  local len = #s
  if len >= n then return s end
  return s .. char:rep(n - len)
end

--- Center s in a field of width n using char (default " ").
-- On odd total padding, the extra char goes on the left.
function M.center(s, n, char)
  char = char or " "
  local len = #s
  if len >= n then return s end
  local total = n - len
  local right = math.floor(total / 2)
  local left = total - right
  return char:rep(left) .. s .. char:rep(right)
end

--- Truncate s to n characters. If truncated, append ellipsis (default "...").
function M.truncate(s, n, ellipsis)
  if #s <= n then return s end
  ellipsis = ellipsis or "..."
  local keep = n - #ellipsis
  if keep < 0 then keep = 0 end
  return s:sub(1, keep) .. ellipsis
end

--- Word-wrap s at n characters, returning an array of lines.
-- Long words that exceed n are placed on their own line unbroken.
function M.wrap(s, n)
  local lines = {}
  local line = ""
  for word in s:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= n then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return lines
end

--- Repeat s n times (alias for s:rep with a more explicit name).
function M.repeat_str(s, n)
  return s:rep(n)
end

--- Reverse a string.
function M.reverse(s)
  return s:reverse()
end

--- First character uppercase, rest lowercase.
function M.capitalize(s)
  if s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2):lower()
end

--- Each word capitalized (first char upper, rest lower).
function M.title_case(s)
  return s:gsub("(%a)([%w_']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end)
end

--- Convert to snake_case.
-- Handles camelCase, PascalCase, spaces, and hyphens.
function M.snake_case(s)
  -- Insert underscore before uppercase letters that follow lowercase letters or digits
  s = s:gsub("(%l)(%u)", "%1_%2")
  s = s:gsub("(%d)(%u)", "%1_%2")
  -- Replace spaces and hyphens with underscores
  s = s:gsub("[ %-]+", "_")
  return s:lower()
end

--- Convert to camelCase.
-- Handles snake_case, kebab-case, and space-separated words.
function M.camel_case(s)
  s = s:gsub("[ _%-]+(%a)", function(c) return c:upper() end)
  -- lowercase the very first character
  return s:sub(1, 1):lower() .. s:sub(2)
end

--- Convert to PascalCase.
-- Handles snake_case, kebab-case, and space-separated words.
function M.pascal_case(s)
  s = s:gsub("[ _%-]+(%a)", function(c) return c:upper() end)
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Convert to kebab-case.
-- Handles camelCase, PascalCase, spaces, and underscores.
function M.kebab_case(s)
  s = s:gsub("(%l)(%u)", "%1-%2")
  s = s:gsub("(%d)(%u)", "%1-%2")
  s = s:gsub("[ _]+", "-")
  return s:lower()
end

--- Uppercase the first character, leave the rest unchanged.
function M.upper_first(s)
  if s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2)
end

--- Lowercase the first character, leave the rest unchanged.
function M.lower_first(s)
  if s == "" then return s end
  return s:sub(1, 1):lower() .. s:sub(2)
end

-- ---------------------------------------------------------------------------
-- Splitting and joining
-- ---------------------------------------------------------------------------

--- Split s by separator sep. plain=true for literal separator (default true).
-- Returns array of strings. Empty parts are preserved.
--: (string, string, boolean | nil) -> { [integer]: string }
function M.split(s, sep, plain)
  if plain == nil then plain = true end
  local result = {}
  local i = 1
  while true do
    local j, k = s:find(sep, i, plain)
    if not j then
      result[#result + 1] = s:sub(i)
      break
    end
    result[#result + 1] = s:sub(i, j - 1)
    i = k + 1
  end
  return result
end

--- Split s into at most n parts. The last part contains the remainder.
--: (string, string, integer) -> { [integer]: string }
function M.split_n(s, sep, n)
  local result = {}
  local i = 1
  while #result < n - 1 do
    local j, k = s:find(sep, i, true)
    if not j then break end
    result[#result + 1] = s:sub(i, j - 1)
    i = k + 1
  end
  result[#result + 1] = s:sub(i)
  return result
end

--- Split s into lines, handling both \r\n and \n.
-- A trailing newline produces a trailing empty string in the result.
--: (string) -> { [integer]: string }
function M.lines(s)
  local result = {}
  local i = 1
  local len = #s
  while i <= len + 1 do
    local j = s:find("\n", i, true)
    if not j then
      result[#result + 1] = s:sub(i)
      break
    end
    -- Strip \r if present before \n
    local line = s:sub(i, j - 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    result[#result + 1] = line
    i = j + 1
  end
  return result
end

--- Split s into an array of single-character strings.
function M.chars(s)
  local result = {}
  for i = 1, #s do
    result[i] = s:sub(i, i)
  end
  return result
end

--- Split s into an array of byte values.
function M.bytes(s)
  local result = {}
  for i = 1, #s do
    result[i] = s:byte(i)
  end
  return result
end

--- Join arr with separator sep (wrapper around table.concat).
function M.join(sep, arr)
  return table.concat(arr, sep)
end

-- ---------------------------------------------------------------------------
-- Search and replace
-- ---------------------------------------------------------------------------

--- Replace the first n occurrences of from with to (plain text).
-- n=nil means replace all.
function M.replace(s, from, to, n)
  if from == "" then return s end
  -- Escape pattern magic chars
  local escaped_from = from:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
  local escaped_to   = to:gsub("%%", "%%%%")
  if n then
    return (s:gsub(escaped_from, escaped_to, n))
  else
    return (s:gsub(escaped_from, escaped_to))
  end
end

--- Replace all occurrences of from with to (plain text).
function M.replace_all(s, from, to)
  return M.replace(s, from, to)
end

--- Return the first position of sub in s starting at init (1-based).
-- Returns 0 if not found.
function M.index_of(s, sub, init)
  local i = s:find(sub, init or 1, true)
  return i or 0
end

--- Return the last position of sub in s.
-- Returns 0 if not found.
function M.last_index_of(s, sub)
  if sub == "" then return #s + 1 end
  local last = 0
  local i = 1
  while true do
    local j = s:find(sub, i, true)
    if not j then break end
    last = j
    i = j + 1
  end
  return last
end

--- Substring from i to j. Negative indices count from end (-1 = last char).
function M.slice(s, i, j)
  return s:sub(i, j)
end

-- ---------------------------------------------------------------------------
-- Encoding helpers
-- ---------------------------------------------------------------------------

--- Escape all Lua pattern magic characters in s.
function M.escape_pattern(s)
  return (s:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1"))
end

local HTML_ESCAPE = {
  ["&"]  = "&amp;",
  ["<"]  = "&lt;",
  [">"]  = "&gt;",
  ['"']  = "&quot;",
  ["'"]  = "&#39;",
}

local HTML_UNESCAPE = {
  ["&amp;"]  = "&",
  ["&lt;"]   = "<",
  ["&gt;"]   = ">",
  ["&quot;"] = '"',
  ["&#39;"]  = "'",
  ["&#x27;"] = "'",
  ["&apos;"] = "'",
}

--- Escape HTML special characters (& < > " ').
function M.escape_html(s)
  return (s:gsub('[&<>"\']', HTML_ESCAPE))
end

--- Unescape HTML entities back to characters.
function M.unescape_html(s)
  return (s:gsub("&[#%a][%w]*;", function(entity)
    return HTML_UNESCAPE[entity] or entity
  end))
end

-- Characters that do NOT need percent-encoding in a URI (RFC 3986 unreserved)
local URI_SAFE = {}
for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"):gmatch(".") do
  URI_SAFE[c] = true
end

--- Percent-encode a string for use in a URI.
function M.escape_uri(s)
  return (s:gsub(".", function(c)
    if URI_SAFE[c] then
      return c
    else
      return string.format("%%%02X", c:byte(1))
    end
  end))
end

--- Decode percent-encoded characters in a URI string.
function M.unescape_uri(s)
  return (s:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

return M
