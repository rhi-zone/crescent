if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local toml = require("lib.format.toml")

-- Helper: deep equality check (T.eq uses ~= which doesn't work for tables)
local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then
    -- Handle NaN
    if a ~= a and b ~= b then return true end
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function check(input, expected)
  local result, e = toml.decode(input)
  T.ok(result, e)
  T.ok(deep_eq(result, expected), "mismatch: got " .. tostring(result) .. " for input: " .. input:sub(1, 60))
end

local function check_err(input, pattern)
  local result, e = toml.decode(input)
  T.eq(result, nil, "expected error for: " .. input:sub(1, 60))
  if pattern then
    T.ok(e and e:find(pattern, 1, true), "error should contain '" .. pattern .. "', got: " .. tostring(e))
  end
end

T.describe("TOML parser", function()

  T.describe("basic key/value pairs", function()
    T.it("parses string values", function()
      check('name = "Tom"', { name = "Tom" })
    end)

    T.it("parses integer values", function()
      check("age = 42", { age = 42 })
    end)

    T.it("parses negative integers", function()
      check("temp = -17", { temp = -17 })
    end)

    T.it("parses positive integers with sign", function()
      check("temp = +99", { temp = 99 })
    end)

    T.it("parses float values", function()
      check("pi = 3.14", { pi = 3.14 })
    end)

    T.it("parses boolean true", function()
      check("flag = true", { flag = true })
    end)

    T.it("parses boolean false", function()
      check("flag = false", { flag = false })
    end)

    T.it("parses multiple key/value pairs", function()
      check('a = 1\nb = "two"\nc = true', { a = 1, b = "two", c = true })
    end)
  end)

  T.describe("comments", function()
    T.it("ignores comments", function()
      check("# this is a comment\nkey = 42", { key = 42 })
    end)

    T.it("ignores end-of-line comments", function()
      check('key = "value" # comment', { key = "value" })
    end)
  end)

  T.describe("tables", function()
    T.it("parses basic table", function()
      check("[server]\nhost = \"localhost\"\nport = 8080", {
        server = { host = "localhost", port = 8080 }
      })
    end)

    T.it("parses nested tables", function()
      check("[a]\nx = 1\n[a.b]\ny = 2", {
        a = { x = 1, b = { y = 2 } }
      })
    end)

    T.it("parses empty table", function()
      check("[empty]", { empty = {} })
    end)

    T.it("creates implicit tables", function()
      check("[a.b.c]\nx = 1", { a = { b = { c = { x = 1 } } } })
    end)
  end)

  T.describe("arrays", function()
    T.it("parses integer array", function()
      check("arr = [1, 2, 3]", { arr = { 1, 2, 3 } })
    end)

    T.it("parses string array", function()
      check('arr = ["a", "b"]', { arr = { "a", "b" } })
    end)

    T.it("parses empty array", function()
      check("arr = []", { arr = {} })
    end)

    T.it("parses nested arrays", function()
      check("arr = [[1, 2], [3, 4]]", { arr = { { 1, 2 }, { 3, 4 } } })
    end)

    T.it("handles trailing commas", function()
      check("arr = [1, 2, 3,]", { arr = { 1, 2, 3 } })
    end)

    T.it("handles multiline arrays", function()
      check("arr = [\n  1,\n  2,\n  3\n]", { arr = { 1, 2, 3 } })
    end)

    T.it("handles comments in arrays", function()
      check("arr = [\n  1, # first\n  2, # second\n]", { arr = { 1, 2 } })
    end)
  end)

  T.describe("arrays of tables", function()
    T.it("parses array of tables", function()
      local input = "[[products]]\nname = \"Hammer\"\n[[products]]\nname = \"Nail\""
      check(input, {
        products = {
          { name = "Hammer" },
          { name = "Nail" },
        }
      })
    end)

    T.it("parses nested array of tables", function()
      local input = "[[fruit]]\nname = \"apple\"\n[[fruit.variety]]\nname = \"red\"\n[[fruit.variety]]\nname = \"green\""
      check(input, {
        fruit = {
          {
            name = "apple",
            variety = {
              { name = "red" },
              { name = "green" },
            }
          }
        }
      })
    end)
  end)

  T.describe("dotted keys", function()
    T.it("parses dotted keys", function()
      check('a.b.c = 1', { a = { b = { c = 1 } } })
    end)

    T.it("parses dotted keys with quoted parts", function()
      check('"a.b".c = 1', { ["a.b"] = { c = 1 } })
    end)

    T.it("parses multiple dotted keys into same table", function()
      check("a.x = 1\na.y = 2", { a = { x = 1, y = 2 } })
    end)
  end)

  T.describe("basic strings", function()
    T.it("parses escape sequences", function()
      check('s = "tab\\there"', { s = "tab\there" })
      check('s = "line\\nfeed"', { s = "line\nfeed" })
      check('s = "back\\\\slash"', { s = "back\\slash" })
      check('s = "quote\\"mark"', { s = 'quote"mark' })
    end)

    T.it("parses unicode escapes", function()
      check('s = "\\u0041"', { s = "A" })
      check('s = "\\U00000041"', { s = "A" })
    end)

    T.it("rejects newlines in basic strings", function()
      check_err('s = "line\nbreak"', "newline")
    end)
  end)

  T.describe("literal strings", function()
    T.it("parses literal strings (no escapes)", function()
      check("s = 'C:\\\\Users'", { s = "C:\\\\Users" })
    end)

    T.it("rejects newlines in literal strings", function()
      check_err("s = 'line\nbreak'", "newline")
    end)
  end)

  T.describe("multiline basic strings", function()
    T.it("parses multiline basic string", function()
      check('s = """\nhello\nworld"""', { s = "hello\nworld" })
    end)

    T.it("handles line-ending backslash", function()
      check('s = """\\\n  hello"""', { s = "hello" })
    end)

    T.it("supports escape sequences", function()
      check('s = """\\t\\n"""', { s = "\t\n" })
    end)
  end)

  T.describe("multiline literal strings", function()
    T.it("parses multiline literal string", function()
      check("s = '''\nhello\nworld'''", { s = "hello\nworld" })
    end)

    T.it("preserves backslashes", function()
      check("s = '''\nC:\\\\Users'''", { s = "C:\\\\Users" })
    end)
  end)

  T.describe("integer formats", function()
    T.it("parses hexadecimal", function()
      check("x = 0xff", { x = 255 })
      check("x = 0xDEAD_BEEF", { x = 0xDEADBEEF })
    end)

    T.it("parses octal", function()
      check("x = 0o77", { x = 63 })
      check("x = 0o755", { x = 493 })
    end)

    T.it("parses binary", function()
      check("x = 0b1010", { x = 10 })
      check("x = 0b1111_0000", { x = 240 })
    end)

    T.it("handles underscores in decimal", function()
      check("x = 1_000_000", { x = 1000000 })
    end)
  end)

  T.describe("float special values", function()
    T.it("parses positive infinity", function()
      local r = toml.decode("x = inf")
      T.ok(r)
      T.eq(r.x, math.huge)
    end)

    T.it("parses negative infinity", function()
      local r = toml.decode("x = -inf")
      T.ok(r)
      T.eq(r.x, -math.huge)
    end)

    T.it("parses nan", function()
      local r = toml.decode("x = nan")
      T.ok(r)
      T.ok(r.x ~= r.x, "expected NaN")
    end)

    T.it("parses +nan", function()
      local r = toml.decode("x = +nan")
      T.ok(r)
      T.ok(r.x ~= r.x, "expected NaN")
    end)

    T.it("parses floats with exponent", function()
      check("x = 5e+22", { x = 5e+22 })
      check("x = 1e06", { x = 1e06 })
      check("x = -2E-2", { x = -2e-2 })
    end)

    T.it("parses floats with underscore", function()
      check("x = 9_224_617.445_991_228", { x = 9224617.445991228 })
    end)
  end)

  T.describe("datetime types", function()
    T.it("parses offset datetime with Z", function()
      local r = toml.decode("dt = 1979-05-27T07:32:00Z")
      T.ok(r)
      T.eq(r.dt.__toml_type, "datetime")
      T.eq(r.dt.year, 1979)
      T.eq(r.dt.month, 5)
      T.eq(r.dt.day, 27)
      T.eq(r.dt.hour, 7)
      T.eq(r.dt.min, 32)
      T.eq(r.dt.sec, 0)
      T.eq(r.dt.offset, "Z")
    end)

    T.it("parses offset datetime with +/-", function()
      local r = toml.decode("dt = 1979-05-27T07:32:00+05:30")
      T.ok(r)
      T.eq(r.dt.__toml_type, "datetime")
      T.eq(r.dt.offset, "+05:30")
    end)

    T.it("parses local datetime", function()
      local r = toml.decode("dt = 1979-05-27T07:32:00")
      T.ok(r)
      T.eq(r.dt.__toml_type, "datetime-local")
      T.eq(r.dt.year, 1979)
      T.eq(r.dt.hour, 7)
    end)

    T.it("parses local date", function()
      local r = toml.decode("d = 1979-05-27")
      T.ok(r)
      T.eq(r.d.__toml_type, "date")
      T.eq(r.d.year, 1979)
      T.eq(r.d.month, 5)
      T.eq(r.d.day, 27)
    end)

    T.it("parses local time", function()
      local r = toml.decode("t = 07:32:00")
      T.ok(r)
      T.eq(r.t.__toml_type, "time")
      T.eq(r.t.hour, 7)
      T.eq(r.t.min, 32)
      T.eq(r.t.sec, 0)
    end)

    T.it("parses fractional seconds", function()
      local r = toml.decode("dt = 1979-05-27T07:32:00.999999Z")
      T.ok(r)
      T.eq(r.dt.sec, 0.999999)
    end)

    T.it("parses datetime with space separator", function()
      local r = toml.decode("dt = 1979-05-27 07:32:00Z")
      T.ok(r)
      T.eq(r.dt.__toml_type, "datetime")
      T.eq(r.dt.year, 1979)
    end)
  end)

  T.describe("inline tables", function()
    T.it("parses empty inline table", function()
      check("t = {}", { t = {} })
    end)

    T.it("parses inline table with values", function()
      check('t = {a = 1, b = "two"}', { t = { a = 1, b = "two" } })
    end)

    T.it("parses nested inline tables", function()
      check('t = {a = {b = 1}}', { t = { a = { b = 1 } } })
    end)

    T.it("parses inline table with dotted keys", function()
      check('t = {a.b = 1}', { t = { a = { b = 1 } } })
    end)
  end)

  T.describe("error cases", function()
    T.it("rejects duplicate keys", function()
      check_err("a = 1\na = 2", "duplicate")
    end)

    T.it("rejects duplicate table definitions", function()
      check_err("[a]\nx = 1\n[a]\ny = 2", "already defined")
    end)

    T.it("rejects invalid bare key characters", function()
      check_err("@invalid = 1", "unexpected")
    end)

    T.it("rejects unterminated strings", function()
      check_err('s = "unterminated', "unterminated")
    end)

    T.it("includes line numbers in errors", function()
      local _, e = toml.decode("a = 1\nb = 2\nc = ")
      T.ok(e)
      T.ok(e:find("line 3", 1, true), "error should mention line 3, got: " .. e)
    end)
  end)

  T.describe("edge cases", function()
    T.it("parses empty input", function()
      check("", {})
    end)

    T.it("parses input with only comments and whitespace", function()
      check("# just a comment\n\n  \n", {})
    end)

    T.it("handles CRLF line endings", function()
      check("a = 1\r\nb = 2\r\n", { a = 1, b = 2 })
    end)

    T.it("handles bare keys with dashes and underscores", function()
      check("my-key_1 = 42", { ["my-key_1"] = 42 })
    end)

    T.it("handles quoted keys with special characters", function()
      check('"key with spaces" = 1', { ["key with spaces"] = 1 })
    end)

    T.it("handles super-table after sub-table", function()
      check("[a.b]\nx = 1\n[a]\ny = 2", { a = { y = 2, b = { x = 1 } } })
    end)
  end)
end)
