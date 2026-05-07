-- lib/stdlib/lint.lua
-- Mechanical compliance checker for stdlib conventions (docs/stdlib-design.md).

if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--: (string) -> (string | nil, string | nil)
local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local src = f:read("*a") --[[:! string]]
  f:close()
  return src
end

-- Split source into lines, return table of strings (1-indexed).
--: (string) -> { [integer]: string }
local function split_lines(src)
  local lines = {}
  local i = 1
  while i <= #src do
    local nl = src:find("\n", i, true)
    if nl then
      lines[#lines + 1] = src:sub(i, nl - 1)
      i = nl + 1
    else
      lines[#lines + 1] = src:sub(i)
      break
    end
  end
  return lines
end

-- Return parent directory of a file path.
local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

-- Return true if a file exists and is readable.
local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- ── rule implementations ──────────────────────────────────────────────────────

-- Rule: "module_var"
-- File must contain `local M = {}`. Warn if a different module-table name is used.
local OTHER_MOD_PATTERNS = {
  { pat = "^%s*local%s+mod%s*=%s*{}", name = "mod" },
  { pat = "^%s*local%s+lib%s*=%s*{}", name = "lib" },
  { pat = "^%s*local%s+self%s*=%s*{}", name = "self" },
}

local function check_module_var(lines, file, diags)
  local has_M = false
  for _, line in ipairs(lines) do
    if line:match("^%s*local%s+M%s*=%s*{}") then
      has_M = true
      break
    end
  end
  if not has_M then
    -- Check if another common module-table name is present; that's a violation.
    for lineno, line in ipairs(lines) do
      for _, entry in ipairs(OTHER_MOD_PATTERNS) do
        if line:match(entry.pat) then
          diags[#diags + 1] = {
            file    = file,
            line    = lineno,
            rule    = "module_var",
            message = "module table should be `local M = {}`, found `local " .. entry.name .. " = {}`",
          }
        end
      end
    end
  end
end

-- Rule: "path_guard"
-- Must contain `package.path:find("?/init.lua", 1, true)` (without `./` in the find string).
local function check_path_guard(lines, file, diags)
  local found = false
  for _, line in ipairs(lines) do
    -- Correct form: find("?/init.lua", 1, true)  — no "./" prefix
    if line:find('package%.path:find%("%?/init%.lua"', 1, false) then
      found = true
      break
    end
  end
  if not found then
    -- Check whether a wrong form (with ./ prefix) is present, for a better message.
    local has_wrong = false
    for _, line in ipairs(lines) do
      if line:find('package%.path:find%("%./%?/init%.lua"', 1, false) then
        has_wrong = true
        break
      end
    end
    local msg = has_wrong
      and 'path guard uses "./?" in find string — should be "?/init.lua" (no "./")'
      or  'missing path guard: `if not package.path:find("?/init.lua", 1, true) then`'
    diags[#diags + 1] = { file = file, line = 1, rule = "path_guard", message = msg }
  end
end

-- Rule: "assert_in_lib"
-- Flag any `assert(` call. (Only called for non-test files.)
local function check_assert(lines, file, diags)
  for lineno, line in ipairs(lines) do
    -- Skip comment lines.
    local stripped = line:match("^%s*(.-)%s*$")
    if not stripped:match("^%-%-") then
      -- Match assert( not preceded by a word char (avoids "noassert(", etc.)
      local col = 1
      while col <= #line do
        local s, e = line:find("assert%(", col)
        if not s then break end
        -- Ensure the character before 's' is not a word character.
        local pre = s > 1 and line:sub(s - 1, s - 1) or ""
        if not pre:match("[%w_]") then
          -- Check it's not inside a line comment.
          local before = line:sub(1, s - 1)
          if not before:find("%-%-") then
            diags[#diags + 1] = {
              file    = file,
              line    = lineno,
              rule    = "assert_in_lib",
              message = "`assert()` forbidden in library code — use `if not x then return nil, err end`",
            }
            break  -- one diag per line is enough
          end
        end
        col = e + 1
      end
    end
  end
end

-- Rule: "emmylua_annotation"
-- Flag LuaLS/EmmyLua annotation forms.
local EMMYLUA_PATTERNS = {
  { pat = "%-%-%-@param",    form = "---@param"    },
  { pat = "%-%-%-@return",   form = "---@return"   },
  { pat = "%-%-%-@type",     form = "---@type"     },
  { pat = "%-%-%-@class",    form = "---@class"    },
  { pat = "%-%-%[%[@",       form = "--[[@..."     },
  { pat = "@type",           form = "@type"        },
  { pat = "@class",          form = "@class"       },
  { pat = "@param",          form = "@param"       },
  { pat = "@return",         form = "@return"      },
}

-- Deduplicated patterns to avoid double-reporting the same position.
-- We scan each line once and report the first matching pattern.
local function check_emmylua(lines, file, diags)
  for lineno, line in ipairs(lines) do
    -- Skip pure comment lines that are crescent-style annotations.
    -- Look for the earliest match of any EmmyLua pattern.
    local earliest_s = nil
    local earliest_form = nil
    for _, entry in ipairs(EMMYLUA_PATTERNS) do
      local s = line:find(entry.pat)
      if s then
        -- Make sure it's not inside a crescent `--:` annotation.
        -- EmmyLua annotations always contain `@`.
        -- If the match is inside a line comment check for `--:` prefix.
        local before = line:sub(1, s - 1)
        -- Exclude if this line is a crescent annotation (starts with --:).
        if not line:match("^%s*%-%-:") then
          if not earliest_s or s < earliest_s then
            earliest_s = s
            earliest_form = entry.form
          end
        end
      end
    end
    if earliest_s then
      diags[#diags + 1] = {
        file    = file,
        line    = lineno,
        rule    = "emmylua_annotation",
        message = "EmmyLua/LuaLS annotation `" .. earliest_form .. "` — use `--:` crescent style instead",
      }
    end
  end
end

-- Rule: "bare_bit"
-- Flag `bit.` usage when `local bit = require` is absent from the file.
local function check_bare_bit(lines, file, diags)
  local has_require = false
  for _, line in ipairs(lines) do
    if line:match("local%s+bit%s*=%s*require") then
      has_require = true
      break
    end
  end
  if not has_require then
    for lineno, line in ipairs(lines) do
      -- Skip comment lines.
      if not line:match("^%s*%-%-") then
        local s = line:find("bit%.")
        if s then
          local before = line:sub(1, s - 1)
          -- Not inside a line comment.
          if not before:find("%-%-") then
            diags[#diags + 1] = {
              file    = file,
              line    = lineno,
              rule    = "bare_bit",
              message = "bare `bit.*` global — add `local bit = require(\"bit\")` at top of file",
            }
            -- Report first occurrence only (one diag is enough to trigger a fix).
            break
          end
        end
      end
    end
  end
end

-- Rule: "missing_tests"
-- Flag if there is no *_test.lua in the same directory as init.lua.
local function check_missing_tests(file, diags)
  local dir = dirname(file)
  -- Use io.popen + find to list test files in the directory (one level only).
  local handle = io.popen('find ' .. dir .. ' -maxdepth 1 -name "*_test.lua" -type f 2>/dev/null')
  local found = false
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result ~= nil and result ~= "" then found = true end
  end
  if not found then
    diags[#diags + 1] = {
      file    = file,
      line    = 1,
      rule    = "missing_tests",
      message = "no *_test.lua found in " .. dir,
    }
  end
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Check a single init.lua file against all stdlib conventions.
-- Returns an array of { file, line, rule, message } diagnostics.
-- The file is assumed to NOT be a test file.
--: (string) -> { file: string, line: integer, rule: string, message: string }[]
M.check_file = function(filepath)
  local src, err = read_file(filepath)
  if not src then
    return { { file = filepath, line = 1, rule = "io_error", message = "cannot read file: " .. tostring(err) } }
  end

  local lines = split_lines(src)
  local diags = {}

  check_module_var(lines, filepath, diags)
  check_path_guard(lines, filepath, diags)
  check_assert(lines, filepath, diags)
  check_emmylua(lines, filepath, diags)
  check_bare_bit(lines, filepath, diags)
  check_missing_tests(filepath, diags)

  return diags
end

--- Find all init.lua files under dir (excluding *_test.lua and archive/) and
-- run check_file on each. Returns array of diagnostics.
--: (string) -> ({ file: string, line: integer, rule: string, message: string }[], { [integer]: string } | nil)
M.check_dir = function(dir)
  local handle = io.popen(
    'find ' .. dir ..
    ' -name "init.lua" -type f' ..
    ' -not -path "*/archive/*"' ..
    ' | sort'
  )
  if not handle then return {} end

  local files = {}
  for line in handle:lines() do
    files[#files + 1] = line
  end
  handle:close()

  local all_diags = {}
  for _, filepath in ipairs(files) do
    local diags = M.check_file(filepath)
    for _, d in ipairs(diags) do
      all_diags[#all_diags + 1] = d
    end
  end
  return all_diags, files
end

return M
