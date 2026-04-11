if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Strip inline comment from a value string (outside of quotes)
local function strip_inline_comment(s)
  local in_quote = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then
      in_quote = not in_quote
    elseif not in_quote and (c == ';' or c == '#') then
      -- check for leading space
      return s:sub(1, i - 1)
    end
  end
  return s
end

-- Trim leading and trailing whitespace
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Coerce a string value to boolean or number if possible
local function coerce_value(v)
  if v == "true" then return true end
  if v == "false" then return false end
  local n = tonumber(v)
  if n then return n end
  return v
end

-- Decode an INI string into a table.
-- opts.lowercase: boolean (default false) — lowercase keys and section names
-- opts.coerce: boolean (default false) — convert "42"->42, "true"->true, "false"->false
function M.decode(str, opts)
  if type(str) ~= "string" then
    return nil, "ini.decode: expected string, got " .. type(str)
  end
  opts = opts or {}
  local result = {}
  local current_section = nil  -- nil = global keys

  local lineno = 0
  for line in (str .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local s = trim(line)

    -- blank line
    if s == "" then
      -- skip

    -- comment
    elseif s:sub(1, 1) == ";" or s:sub(1, 1) == "#" then
      -- skip

    -- section header
    elseif s:sub(1, 1) == "[" then
      local name = s:match("^%[([^%]]+)%]")
      if not name then
        return nil, "ini.decode: malformed section header at line " .. lineno .. ": " .. line
      end
      name = trim(name)
      if opts.lowercase then name = name:lower() end
      if not result[name] then
        result[name] = {}
      end
      current_section = name

    -- key = value
    else
      local eq = s:find("=")
      if not eq then
        return nil, "ini.decode: malformed key-value pair at line " .. lineno .. ": " .. line
      end
      local key = trim(s:sub(1, eq - 1))
      if key == "" then
        return nil, "ini.decode: empty key at line " .. lineno .. ": " .. line
      end
      if opts.lowercase then key = key:lower() end

      local raw_val = s:sub(eq + 1)
      -- Strip inline comment before trimming
      raw_val = strip_inline_comment(raw_val)
      raw_val = trim(raw_val)

      local value
      -- Handle double-quoted values
      if raw_val:sub(1, 1) == '"' then
        local inner = raw_val:match('^"(.*)"$')
        if not inner then
          return nil, "ini.decode: unterminated quoted value at line " .. lineno .. ": " .. line
        end
        value = inner
      else
        value = raw_val
      end

      if opts.coerce then
        value = coerce_value(value)
      end

      if current_section then
        result[current_section][key] = value
      else
        result[key] = value
      end
    end
  end

  return result, nil
end

M.parse = M.decode
M.string_to_table = M.decode

-- Check if a value needs quoting when encoding
local function needs_quotes(v)
  local s = tostring(v)
  return s:find("[=;#]") ~= nil
end

-- Encode a table into an INI string.
-- opts.sort: boolean (default false) — sort keys
function M.encode(t, opts)
  if type(t) ~= "table" then
    return nil, "ini.encode: expected table, got " .. type(t)
  end
  opts = opts or {}

  local parts = {}

  -- Collect global keys and sections
  local global_keys = {}
  local sections = {}

  for k, v in pairs(t) do
    if type(v) == "table" then
      sections[#sections + 1] = k
    else
      global_keys[#global_keys + 1] = k
    end
  end

  if opts.sort then
    table.sort(global_keys)
    table.sort(sections)
  end

  -- Write global keys first
  for _, k in ipairs(global_keys) do
    local v = t[k]
    local sv = tostring(v)
    if needs_quotes(sv) then
      sv = '"' .. sv .. '"'
    end
    parts[#parts + 1] = tostring(k) .. " = " .. sv
  end

  -- Write sections
  for _, sec in ipairs(sections) do
    if #parts > 0 then
      parts[#parts + 1] = ""
    end
    parts[#parts + 1] = "[" .. tostring(sec) .. "]"
    local sec_table = t[sec]
    local sec_keys = {}
    for k in pairs(sec_table) do
      sec_keys[#sec_keys + 1] = k
    end
    if opts.sort then
      table.sort(sec_keys)
    end
    for _, k in ipairs(sec_keys) do
      local v = sec_table[k]
      local sv = tostring(v)
      if needs_quotes(sv) then
        sv = '"' .. sv .. '"'
      end
      parts[#parts + 1] = tostring(k) .. " = " .. sv
    end
  end

  if #parts > 0 then
    parts[#parts + 1] = ""  -- trailing newline
  end

  return table.concat(parts, "\n"), nil
end

M.stringify = M.encode
M.table_to_string = M.encode

-- Get a value by section and key.
-- section may be nil for global keys.
function M.get(t, section, key)
  if section == nil then
    return t[key]
  end
  local sec = t[section]
  if type(sec) ~= "table" then return nil end
  return sec[key]
end

return M
