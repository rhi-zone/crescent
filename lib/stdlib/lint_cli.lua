-- lib/stdlib/lint_cli.lua — CLI wrapper for lib/stdlib/lint.lua
-- Used by bin/cr-lint.lua (bin/cr lint ...) and also runnable as a standalone script.
--
-- Usage:
--   bin/cr lint [--disable-rule=<name>...] <file|dir>...
--   luajit lib/stdlib/lint_cli.lua [--disable-rule=<name>...] <file|dir>...

if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local lint = require("lib.stdlib.lint")

local M = {}

--: ({ [integer]: string } | nil) -> nil
function M.main(argv)
  local args = argv or arg or {}
  local opts = { disabled_rules = nil, with_tests = nil } --: { disabled_rules: { [integer]: string } | nil, with_tests: boolean | nil }
  local paths = {} --: { [integer]: string }

  for _, a in ipairs(args) do
    local rule = a:match("^%-%-disable%-rule=(.+)$")
    if rule then
      if not opts.disabled_rules then opts.disabled_rules = {} end
      local dr = opts.disabled_rules --[[:! { [integer]: string }]]
      dr[#dr + 1] = rule
    else
      paths[#paths + 1] = a
    end
  end

  if #paths == 0 then
    io.stderr:write("usage: bin/cr lint [--disable-rule=<name>...] <file|dir>...\n")
    os.exit(1)
  end

  local all_diags = {} --: { [integer]: { file: string, line: integer, rule: string, message: string } }
  local total_files = 0

  for _, path in ipairs(paths) do
    local stat = io.open(path, "r")
    if stat then
      stat:close()
      -- Treat as a single file.
      local diags = lint.check_file(path, opts)
      total_files = total_files + 1
      for _, d in ipairs(diags) do all_diags[#all_diags + 1] = d end
    else
      -- Treat as a directory.
      local diags, files = lint.check_dir(path, opts)
      if files then
        total_files = total_files + #(files --[[:! { [integer]: string }]])
      end
      for _, d in ipairs(diags) do all_diags[#all_diags + 1] = d end
    end
  end

  for _, d in ipairs(all_diags) do
    io.write(d.file .. ":" .. d.line .. ": " .. d.rule .. ": " .. d.message .. "\n")
  end

  local n = #all_diags
  io.write("Checked " .. total_files .. " file(s): " .. n .. " violation(s)\n")

  if n > 0 then os.exit(1) end
end

-- Standalone invocation.
if not pcall(debug.getinfo, 2, "") then
  M.main(arg)
end

return M
