-- lib/type/static/fixtures_test.lua
-- Snapshot-based fixture tests for type error messages.
--
-- Error fixtures: lib/type/static/testdata/errors/*.lua
--   Each .lua input must produce errors matching the adjacent .expected file.
--   FIXTURE_UPDATE=1: write actual output to .expected instead of comparing.
--
-- Valid fixtures: lib/type/static/testdata/valid/*.lua
--   Each .lua input must check clean (zero errors).

local assert = require("lib.test.assert")
local checker = require("lib.type.static")

local update_mode = os.getenv("FIXTURE_UPDATE") == "1"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if not f then error("cannot write: " .. path) end
  f:write(content)
  f:close()
end

local function find_lua_fixtures(dir)
  local files = {}
  local handle = io.popen("find " .. dir .. " -name '*.lua' -type f 2>/dev/null | sort")
  if not handle then return files end
  for line in handle:lines() do
    files[#files + 1] = line
  end
  handle:close()
  return files
end

local function basename(path)
  return path:match("([^/]+)%.lua$") or path
end

-- ---------------------------------------------------------------------------
-- Error fixtures
-- ---------------------------------------------------------------------------

local error_dir = "lib/type/static/testdata/errors"
local error_fixtures = find_lua_fixtures(error_dir)

for _, path in ipairs(error_fixtures) do
  local name = basename(path)
  local expected_path = path:gsub("%.lua$", ".expected")

  assert.describe("error fixture: " .. name, function()
    assert.it("produces expected output", function()
      local src = read_file(path)
      assert.ok(src ~= nil, "cannot read: " .. path)

      local ok, errs = checker.check(src, "test.lua")
      local actual = (errs or "") .. (ok and "" or "")
      -- Normalise: ensure trailing newline is consistent
      if actual ~= "" and actual:sub(-1) ~= "\n" then actual = actual .. "\n" end

      if update_mode then
        write_file(expected_path, actual)
        assert.ok(true, "wrote " .. expected_path)
      else
        local expected = read_file(expected_path)
        if expected == nil then
          error("missing snapshot: " .. expected_path ..
                "\nRun with FIXTURE_UPDATE=1 to generate.")
        end
        assert.eq(actual, expected, "snapshot mismatch")
      end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Valid fixtures
-- ---------------------------------------------------------------------------

local valid_dir = "lib/type/static/testdata/valid"
local valid_fixtures = find_lua_fixtures(valid_dir)

for _, path in ipairs(valid_fixtures) do
  local name = basename(path)

  assert.describe("valid fixture: " .. name, function()
    assert.it("passes with no errors", function()
      local src = read_file(path)
      assert.ok(src ~= nil, "cannot read: " .. path)

      local ok, errs = checker.check(src, "test.lua")
      assert.ok(ok, "unexpected errors:\n" .. (errs or ""))
    end)
  end)
end
