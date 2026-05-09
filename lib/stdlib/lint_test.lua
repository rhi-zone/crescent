-- lib/stdlib/lint_test.lua
-- Tests for the stdlib lint tool.

if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local lint = require("lib.stdlib.lint")

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Create a unique temp directory for a test, returning its path.
-- Caller is responsible for cleanup.
local function mktmpdir()
  local base = os.tmpname()
  os.remove(base)  -- tmpname creates the file; remove so we can mkdir
  local dir = base .. "_linttest"
  os.execute("mkdir -p " .. dir)
  return dir
end

-- Write src to a temp init.lua in an isolated directory, run check_file,
-- clean up, return diagnostics.
-- opts.with_tests: if true, also create a sibling *_test.lua so missing_tests
--                  is suppressed.
local function check_src(src, opts)
  opts = opts or {}
  local dir = mktmpdir()
  local tmpfile = dir .. "/init.lua"
  local f = io.open(tmpfile, "w")
  f:write(src)
  f:close()

  -- Optionally create a fake test sibling to suppress missing_tests.
  if opts.with_tests then
    local sf = io.open(dir .. "/stub_test.lua", "w")
    sf:write("-- stub\n")
    sf:close()
  end

  -- Pass lint opts (disabled_rules, etc.) to check_file.
  local lint_opts = opts.disabled_rules and { disabled_rules = opts.disabled_rules } or nil
  local diags = lint.check_file(tmpfile, lint_opts)

  -- Clean up the directory.
  os.execute("rm -rf " .. dir)

  return diags
end

-- Return a list of rule names present in diagnostics.
local function rules(diags)
  local r = {}
  for _, d in ipairs(diags) do
    r[#r + 1] = d.rule
  end
  return r
end

-- Return true if rule appears at least once in diags.
local function has_rule(diags, rule)
  for _, d in ipairs(diags) do
    if d.rule == rule then return true end
  end
  return false
end

-- ── good source (should produce no violations except possibly missing_tests) ──

local GOOD_SRC = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: (string) -> string
M.greet = function(name)
  if type(name) ~= "string" then
    return nil, "expected string"
  end
  return "hello, " .. name
end

return M
]]

-- ── bad sources — one violation each (plus missing_tests since /tmp has none) ─

local BAD_MODULE_VAR = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local mod = {}

mod.fn = function() return true end

return mod
]]

local BAD_PATH_GUARD_MISSING = [[
local M = {}
M.fn = function() return true end
return M
]]

local BAD_PATH_GUARD_DOTSLASH = [[
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
return M
]]

local BAD_ASSERT = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.fn = function(x)
  assert(type(x) == "string", "expected string")
  return x
end

return M
]]

local BAD_EMMYLUA_DASHPARAM = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

---@param name string
M.greet = function(name) return "hi " .. name end

return M
]]

local BAD_EMMYLUA_BRACKET = [==[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--[[@param name string]]
M.greet = function(name) return "hi " .. name end

return M
]==]

local BAD_BARE_BIT = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M.mask = function(x)
  return bit.band(x, 0xFF)
end

return M
]]

-- ── tests ─────────────────────────────────────────────────────────────────────

T.describe("stdlib lint", function()

  T.describe("good source", function()
    T.it("no false positives (with sibling test file)", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      local filtered = {}
      for _, d in ipairs(diags) do
        -- io_error could appear on a temp file edge case; skip it
        if d.rule ~= "io_error" then
          filtered[#filtered + 1] = d
        end
      end
      T.eq(#filtered, 0)
    end)

    T.it("missing_tests fires when there is no sibling test file", function()
      local diags = check_src(GOOD_SRC)
      T.ok(has_rule(diags, "missing_tests"))
    end)
  end)

  T.describe("module_var", function()
    T.it("detects `local mod = {}`", function()
      local diags = check_src(BAD_MODULE_VAR, { with_tests = true })
      T.ok(has_rule(diags, "module_var"))
    end)

    T.it("no false positive for `local M = {}`", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "module_var"))
    end)
  end)

  T.describe("path_guard", function()
    T.it("detects missing path guard entirely", function()
      local diags = check_src(BAD_PATH_GUARD_MISSING, { with_tests = true })
      T.ok(has_rule(diags, "path_guard"))
    end)

    T.it("detects wrong form with ./ in find string", function()
      local diags = check_src(BAD_PATH_GUARD_DOTSLASH, { with_tests = true })
      T.ok(has_rule(diags, "path_guard"))
    end)

    T.it("no false positive for correct guard", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "path_guard"))
    end)
  end)

  T.describe("assert_in_lib", function()
    T.it("detects assert() call", function()
      local diags = check_src(BAD_ASSERT, { with_tests = true })
      T.ok(has_rule(diags, "assert_in_lib"))
    end)

    T.it("no false positive when assert is absent", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "assert_in_lib"))
    end)
  end)

  T.describe("emmylua_annotation", function()
    T.it("detects ---@param annotation", function()
      local diags = check_src(BAD_EMMYLUA_DASHPARAM, { with_tests = true })
      T.ok(has_rule(diags, "emmylua_annotation"))
    end)

    T.it("detects --[[@param ...]] bracket annotation", function()
      local diags = check_src(BAD_EMMYLUA_BRACKET, { with_tests = true })
      T.ok(has_rule(diags, "emmylua_annotation"))
    end)

    T.it("no false positive for --: style annotations", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "emmylua_annotation"))
    end)
  end)

  T.describe("bare_bit", function()
    T.it("detects bare bit.band() without local require", function()
      local diags = check_src(BAD_BARE_BIT, { with_tests = true })
      T.ok(has_rule(diags, "bare_bit"))
    end)

    T.it("no false positive when bit.* is absent", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "bare_bit"))
    end)

    T.it("no false positive when local bit = require is present", function()
      local src = [[
if not package.path:find("?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end
local bit = require("bit")
local M = {}
M.mask = function(x) return bit.band(x, 0xFF) end
return M
]]
      local diags = check_src(src, { with_tests = true })
      T.ok(not has_rule(diags, "bare_bit"))
    end)
  end)

  T.describe("missing_tests", function()
    T.it("fires when no sibling test file exists", function()
      local diags = check_src(GOOD_SRC)
      T.ok(has_rule(diags, "missing_tests"))
    end)

    T.it("silent when sibling test file is present", function()
      local diags = check_src(GOOD_SRC, { with_tests = true })
      T.ok(not has_rule(diags, "missing_tests"))
    end)
  end)

  T.describe("disabled_rules", function()
    T.it("passing disabled_rules = {'emmylua_annotation'} suppresses emmylua_annotation", function()
      local diags = check_src(BAD_EMMYLUA_DASHPARAM, { with_tests = true, disabled_rules = { "emmylua_annotation" } })
      T.ok(not has_rule(diags, "emmylua_annotation"))
    end)

    T.it("disabled_rules does not suppress unrelated rules", function()
      local diags = check_src(BAD_ASSERT, { with_tests = true, disabled_rules = { "emmylua_annotation" } })
      T.ok(has_rule(diags, "assert_in_lib"))
    end)

    T.it("emmylua_annotation rule fires without disabled_rules", function()
      local diags = check_src(BAD_EMMYLUA_DASHPARAM, { with_tests = true })
      T.ok(has_rule(diags, "emmylua_annotation"))
    end)

    T.it("emmylua_annotation message includes suppression hint", function()
      local diags = check_src(BAD_EMMYLUA_DASHPARAM, { with_tests = true })
      local found_hint = false
      for _, d in ipairs(diags) do
        if d.rule == "emmylua_annotation" and d.message:find("disabled_rules", 1, true) then
          found_hint = true
        end
      end
      T.ok(found_hint)
    end)
  end)

  T.describe("check_src API", function()
    T.it("check_src returns diagnostics for bad source without disk I/O", function()
      local diags = lint.check_src(BAD_EMMYLUA_DASHPARAM, "test.lua", nil)
      T.ok(has_rule(diags, "emmylua_annotation"))
    end)

    T.it("check_src respects disabled_rules", function()
      local diags = lint.check_src(BAD_EMMYLUA_DASHPARAM, "test.lua", { disabled_rules = { "emmylua_annotation" } })
      T.ok(not has_rule(diags, "emmylua_annotation"))
    end)
  end)

  T.describe("diagnostic structure", function()
    T.it("each diagnostic has file, line, rule, message fields", function()
      local diags = check_src(BAD_ASSERT, { with_tests = true })
      T.ok(#diags >= 1)
      local d = diags[1]
      T.ok(d.file ~= nil)
      T.ok(d.line ~= nil)
      T.ok(d.rule ~= nil)
      T.ok(d.message ~= nil)
      T.ok(type(d.line) == "number")
    end)

    T.it("line numbers are accurate for assert violation", function()
      local diags = check_src(BAD_ASSERT, { with_tests = true })
      local assert_diag
      for _, d in ipairs(diags) do
        if d.rule == "assert_in_lib" then assert_diag = d; break end
      end
      T.ok(assert_diag ~= nil)
      -- assert( is on line 8 of BAD_ASSERT
      T.eq(assert_diag.line, 8)
    end)
  end)

end)
