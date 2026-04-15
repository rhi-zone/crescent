-- lib/dotenv/init.lua
-- .env file parser with variable expansion.
-- Supports bare, double-quoted, and single-quoted values; comments;
-- export prefix; \n/\t/\\/\" escapes; ${VAR}/$VAR expansion.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Process double-quoted escape sequences: \n \t \\ \" \r
--: (string) -> string
local function unescape_double(s)
  return (s:gsub("\\(.)", function(c)
    if c == "n"  then return "\n"
    elseif c == "t"  then return "\t"
    elseif c == "r"  then return "\r"
    elseif c == "\\" then return "\\"
    elseif c == '"'  then return '"'
    else return "\\" .. c  -- leave unknown escapes as-is
    end
  end))
end

-- Expand ${VAR} and $VAR references in a string, looking up vars then env_fn.
--: (string, { [string]: string }, ((string) -> string | nil) | nil) -> string
local function expand_vars(s, vars, env_fn)
  -- ${VAR} form
  s = s:gsub("%${([A-Za-z_][A-Za-z0-9_]*)}", function(name)
    local v = vars[name]
    if v ~= nil then return v end
    return env_fn and env_fn(name) or ""
  end)
  -- $VAR form (not followed by { or alphanumeric to avoid double-expansion)
  s = s:gsub("%$([A-Za-z_][A-Za-z0-9_]*)", function(name)
    local v = vars[name]
    if v ~= nil then return v end
    return env_fn and env_fn(name) or ""
  end)
  return s
end

-- ---------------------------------------------------------------------------
-- Core parser
-- ---------------------------------------------------------------------------

-- Parse .env content from a string.
-- Returns a table of key=value pairs, or nil + error message.
--: (string) -> { [string]: string } | nil, string | nil
function M.parse(content, env_fn)
  if type(content) ~= "string" then
    return nil, "dotenv.parse: expected string, got " .. type(content)
  end

  local vars = {}

  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    -- Strip trailing \r (Windows line endings)
    line = line:gsub("\r$", "")

    -- Skip empty lines
    if line == "" then goto continue end

    -- Skip comment lines
    if line:match("^%s*#") then goto continue end

    -- Strip leading whitespace
    line = line:match("^%s*(.-)%s*$") or line

    -- Strip optional "export " prefix
    line = line:gsub("^export%s+", "")

    -- Match KEY=... or KEY (bare, no =)
    local key, rest = line:match("^([A-Za-z_][A-Za-z0-9_.]*)%s*=%s*(.*)")
    if not key then
      -- KEY without = → value is "true"
      local bare_key = line:match("^([A-Za-z_][A-Za-z0-9_.]*)%s*$")
      if bare_key then
        vars[bare_key] = "true"
      end
      -- Lines that don't match are silently skipped
      goto continue
    end

    local value

    if rest == "" then
      -- KEY= with nothing → empty string
      value = ""
    elseif rest:sub(1,1) == '"' then
      -- Double-quoted value
      local inner = rest:match('^"(.-)"')  -- greedy-minimal to first closing "
      -- Handle escaped quotes inside: need to respect \" sequences
      -- Re-parse manually for correctness
      local i = 2  -- skip opening quote
      local buf = {}
      local closed = false
      while i <= #rest do
        local c = rest:sub(i, i)
        if c == "\\" then
          local nc = rest:sub(i+1, i+1)
          if nc == "n" then buf[#buf+1] = "\n"; i = i + 2
          elseif nc == "t" then buf[#buf+1] = "\t"; i = i + 2
          elseif nc == "r" then buf[#buf+1] = "\r"; i = i + 2
          elseif nc == "\\" then buf[#buf+1] = "\\"; i = i + 2
          elseif nc == '"' then buf[#buf+1] = '"'; i = i + 2
          else buf[#buf+1] = c; i = i + 1
          end
        elseif c == '"' then
          closed = true
          i = i + 1
          break
        else
          buf[#buf+1] = c
          i = i + 1
        end
      end
      inner = table.concat(buf)
      -- Expand variables in double-quoted values
      value = expand_vars(inner, vars, env_fn)

    elseif rest:sub(1,1) == "'" then
      -- Single-quoted value: no escapes, no expansion
      local inner = rest:match("^'(.-)'")
      if inner == nil then
        -- Unterminated single quote — treat rest as value
        inner = rest:sub(2)
      end
      value = inner

    else
      -- Bare (unquoted) value
      -- Inline # after a space ends the value; strip trailing whitespace
      -- Per dotenv convention: VALUE#notcomment is literal; VALUE #comment strips
      local bare = rest:match("^(.-)%s+#.*$") or rest
      -- Also strip trailing whitespace
      bare = bare:match("^(.-)%s*$") or bare
      -- Expand variables in bare values
      value = expand_vars(bare, vars, env_fn)
    end

    vars[key] = value

    ::continue::
  end

  return vars
end

-- ---------------------------------------------------------------------------
-- File I/O
-- ---------------------------------------------------------------------------

-- Load .env file from path. read_fn(path) -> string|nil, err.
--: ((string) -> (string | nil, string | nil), string, ((string) -> string | nil) | nil) -> { [string]: string } | nil, string | nil
function M.load(read_fn, path, env_fn)
  if type(read_fn) ~= "function" then
    error("dotenv.load: read_fn function is required")
  end
  local content, err = read_fn(path)
  if not content then return nil, "dotenv.load: cannot open " .. path .. ": " .. (err or "unknown error") end
  return M.parse(content, env_fn)
end

-- Load .env file and merge vars into an existing table t. Returns t.
-- On error returns nil + errmsg.
--: ({ [string]: string }, (string) -> (string | nil, string | nil), string, ((string) -> string | nil) | nil) -> { [string]: string } | nil, string | nil
function M.load_into(t, read_fn, path, env_fn)
  local vars, err = M.load(read_fn, path, env_fn)
  if not vars then return nil, err end
  for k, v in pairs(vars) do
    t[k] = v
  end
  return t
end

-- Load multiple .env files and merge. Later files override earlier unless
-- opts.existing=true (first value wins).
--: ((string) -> (string | nil, string | nil), { string }, { existing: boolean | nil, env_fn: ((string) -> string | nil) | nil } | nil) -> { [string]: string } | nil, string | nil
function M.load_files(read_fn, paths, opts)
  if type(read_fn) ~= "function" then
    error("dotenv.load_files: read_fn function is required")
  end
  opts = opts or {}
  local env_fn = opts.env_fn
  local result = {}
  for _, path in ipairs(paths) do
    local vars, err = M.load(read_fn, path, env_fn)
    if not vars then return nil, err end
    for k, v in pairs(vars) do
      if not opts.existing or result[k] == nil then
        result[k] = v
      end
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Resolver
-- ---------------------------------------------------------------------------

-- Return a resolver function that looks up key in vars, then env_fn.
-- vars must be a table (already-parsed). env_fn is optional.
--: ({ [string]: string }, ((string) -> string | nil) | nil) -> ((string) -> string | nil)
function M.resolver(vars, env_fn)
  if type(vars) ~= "table" then
    error("dotenv.resolver: vars table is required")
  end
  return function(key)
    local v = vars[key]
    if v ~= nil then return v end
    return env_fn and env_fn(key)
  end
end

-- ---------------------------------------------------------------------------
-- Stringify
-- ---------------------------------------------------------------------------

-- Generate .env content from a vars table.
-- Values containing spaces, #, ", ', =, or \n are double-quoted.
--: ({ [string]: string }, { sorted: boolean | nil } | nil) -> string
function M.stringify(vars, opts)
  opts = opts or {}
  local lines = {}

  -- Optionally sort for deterministic output
  local keys = {}
  for k in pairs(vars) do keys[#keys+1] = k end
  if opts.sorted ~= false then
    table.sort(keys)
  end

  for _, k in ipairs(keys) do
    local v = tostring(vars[k])
    -- Quote if value contains whitespace, quotes, #, =, $, backslash, or newlines
    local needs_quote = v:find('[ \t\r\n"\'#=$\\]') ~= nil or v == ""
    if needs_quote then
      -- Escape for double-quoted output
      local escaped = v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t'):gsub('\r', '\\r')
      lines[#lines+1] = k .. '="' .. escaped .. '"'
    else
      lines[#lines+1] = k .. "=" .. v
    end
  end

  return table.concat(lines, "\n") .. (# lines > 0 and "\n" or "")
end

return M
