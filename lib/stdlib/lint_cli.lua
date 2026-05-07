-- lib/stdlib/lint_cli.lua
-- CLI for the stdlib lint tool.
-- Usage:
--   luajit lib/stdlib/lint_cli.lua lib/          -- lint all packages
--   luajit lib/stdlib/lint_cli.lua lib/hash/     -- lint a namespace

if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local lint = require("lib.stdlib.lint")

-- ── argument parsing ──────────────────────────────────────────────────────────

local target = arg and arg[1]
if not target then
  io.stderr:write("usage: luajit lib/stdlib/lint_cli.lua <dir>\n")
  os.exit(1)
end

-- ── run ───────────────────────────────────────────────────────────────────────

local all_diags, files = lint.check_dir(target --[[:! string]])

-- Print diagnostics.
for _, d in ipairs(all_diags) do
  io.write(d.file .. ":" .. d.line .. " [" .. d.rule .. "] " .. d.message .. "\n")
end

-- ── summary ───────────────────────────────────────────────────────────────────

local total_files = 0
if files ~= nil then total_files = #(files --[[:! { [integer]: string }]]) end
local total_violations = #all_diags

-- Count violations by rule.
local by_rule = {} --: { [string]: integer }
local rule_order = {} --: { [integer]: string }
for _, d in ipairs(all_diags) do
  if not by_rule[d.rule] then
    by_rule[d.rule] = 0
    rule_order[#rule_order + 1] = d.rule
  end
  by_rule[d.rule] = by_rule[d.rule] + 1
end
table.sort(rule_order)

io.write("\n")
io.write("files checked:  " .. total_files .. "\n")
io.write("violations:     " .. total_violations .. "\n")
if total_violations > 0 then
  io.write("by rule:\n")
  for _, rule in ipairs(rule_order) do
    io.write("  " .. rule .. ": " .. by_rule[rule] .. "\n")
  end
end

if total_violations > 0 then
  os.exit(1)
end
