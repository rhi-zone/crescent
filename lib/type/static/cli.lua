-- lib/type/static/cli.lua
-- CLI entry point for the static typechecker.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local errors = require("lib.type.static.errors")

local function glob_lua_files(dir)
  local files = {}
  local p = io.popen('find "' .. dir .. '" -name "*.lua" -not -name "*_test.lua" -not -path "*/dep/*" 2>/dev/null')
  if not p then return files end
  for line in p:lines() do
    files[#files + 1] = line
  end
  p:close()
  return files
end

local function main()
  local checker = require("lib.type.static")
  local files = {}
  local target = "luajit" -- default target

  local i = 1
  while i <= #arg do
    if arg[i] == "--target" and arg[i + 1] then
      target = arg[i + 1]
      i = i + 2
    else
      files[#files + 1] = arg[i]
      i = i + 1
    end
  end

  if #files == 0 then
    files = glob_lua_files("lib")
  end

  local total_errors = 0
  local total_warnings = 0
  local total_files = 0

  for _, filename in ipairs(files) do
    local err_ctx = checker.check_file(filename)
    local n_errors = errors.count(err_ctx, "error")
    local n_warnings = errors.count(err_ctx, "warning")

    if n_errors > 0 or n_warnings > 0 then
      -- Read source lines for display
      local source_lines = {}
      local f = io.open(filename, "r")
      if f then
        local line_num = 0
        for line in f:lines() do
          line_num = line_num + 1
          source_lines[line_num] = line
        end
        f:close()
      end

      io.stderr:write(errors.format(err_ctx, source_lines))
      io.stderr:write("\n")
    end

    total_errors = total_errors + n_errors
    total_warnings = total_warnings + n_warnings
    total_files = total_files + 1
  end

  -- Summary
  io.stderr:write(string.format("\nChecked %d file(s): %d error(s), %d warning(s)\n",
    total_files, total_errors, total_warnings))

  if total_errors > 0 then
    os.exit(1)
  else
    os.exit(0)
  end
end

main()
