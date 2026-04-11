-- lib/json_schema/json_schema_test.lua
-- Tests for the JSON Schema draft-7 validator.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local js = require("lib.json_schema")

-- Helpers
local function ok(value, schema, msg)
  local result, errs = js.validate(value, schema)
  T.ok(result, msg or ("expected valid but got errors: " .. (errs and errs[1] and errs[1].message or "?")))
end

local function fail(value, schema, msg)
  local result = js.validate(value, schema)
  T.fail(result, msg or "expected invalid but got valid")
end

local function err_contains(value, schema, substr, msg)
  local result, errs = js.validate(value, schema)
  T.fail(result, "expected invalid")
  local found = false
  if errs then
    for _, e in ipairs(errs) do
      if e.message:find(substr, 1, true) or e.path:find(substr, 1, true) then
        found = true
        break
      end
    end
  end
  T.ok(found, (msg or "error containing '" .. substr .. "' not found") .. ": got " .. (errs and errs[1] and errs[1].message or "nil"))
end

-- ---------------------------------------------------------------------------
T.describe("empty schema", function()
  T.it("accepts anything", function()
    ok(1, {})
    ok("hello", {})
    ok(nil, {})
    ok({}, {})
    ok(true, {})
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("boolean schema", function()
  T.it("true accepts everything", function()
    ok(42, true)
    ok("hi", true)
    ok(nil, true)
  end)
  T.it("false rejects everything", function()
    fail(42, false)
    fail("hi", false)
    fail(nil, false)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("type keyword — primitives", function()
  T.it("string", function()
    ok("hello", { type = "string" })
    fail(42, { type = "string" })
    fail(nil, { type = "string" })
    fail(true, { type = "string" })
  end)
  T.it("number", function()
    ok(3.14, { type = "number" })
    ok(3, { type = "number" })  -- integer is a subtype of number
    fail("3", { type = "number" })
    fail(nil, { type = "number" })
  end)
  T.it("integer", function()
    ok(3, { type = "integer" })
    ok(-10, { type = "integer" })
    fail(3.14, { type = "integer" })
    fail("3", { type = "integer" })
  end)
  T.it("boolean", function()
    ok(true, { type = "boolean" })
    ok(false, { type = "boolean" })
    fail(1, { type = "boolean" })
    fail("true", { type = "boolean" })
  end)
  T.it("null", function()
    ok(nil, { type = "null" })
    fail(false, { type = "null" })
    fail(0, { type = "null" })
  end)
  T.it("array", function()
    ok({1, 2, 3}, { type = "array" })
    ok({}, { type = "array" })
    fail("[]", { type = "array" })
    fail({1, 2, 3}, { type = "object" })
  end)
  T.it("object", function()
    ok({a = 1}, { type = "object" })
    fail({1, 2}, { type = "object" })
    fail("hi", { type = "object" })
  end)
  T.it("array of types", function()
    local s = { type = {"string", "number"} }
    ok("hi", s)
    ok(3.14, s)
    fail(true, s)
    fail(nil, s)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("nullable (OpenAPI extension)", function()
  T.it("allows null when nullable=true", function()
    ok(nil, { type = "string", nullable = true })
    ok("hi", { type = "string", nullable = true })
    fail(42, { type = "string", nullable = true })
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("enum", function()
  T.it("accepts listed values", function()
    local s = { enum = {1, "two", true} }
    ok(1, s)
    ok("two", s)
    ok(true, s)
  end)
  T.it("rejects unlisted values", function()
    local s = { enum = {"a", "b", "c"} }
    fail("d", s)
    fail(1, s)
    fail(nil, s)
  end)
  T.it("enum with false", function()
    local s = { enum = {false, 0} }
    ok(false, s)
    ok(0, s)
    fail(true, s)
    fail(1, s)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("const", function()
  T.it("accepts exact value", function()
    ok(42, { ["const"] = 42 })
    ok("hello", { ["const"] = "hello" })
    ok(false, { ["const"] = false })
    ok({a = 1}, { ["const"] = {a = 1} })
  end)
  T.it("rejects other values", function()
    fail(43, { ["const"] = 42 })
    fail("world", { ["const"] = "hello" })
    fail(true, { ["const"] = false })
    fail({a = 2}, { ["const"] = {a = 1} })
  end)
  -- Note: const = nil cannot be expressed in Lua table literals (nil values are not stored);
  -- use type = "null" for null validation instead.
end)

-- ---------------------------------------------------------------------------
T.describe("string keywords", function()
  T.it("minLength", function()
    ok("abc", { type = "string", minLength = 3 })
    ok("abcd", { type = "string", minLength = 3 })
    fail("ab", { type = "string", minLength = 3 })
    fail("", { type = "string", minLength = 1 })
  end)
  T.it("maxLength", function()
    ok("abc", { type = "string", maxLength = 5 })
    ok("abc", { type = "string", maxLength = 3 })
    fail("abcdef", { type = "string", maxLength = 5 })
  end)
  T.it("pattern", function()
    ok("hello123", { type = "string", pattern = "%d+" })
    fail("hello", { type = "string", pattern = "^%d+$" })
    ok("abc", { type = "string", pattern = "^%a+$" })
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("number keywords", function()
  T.it("minimum (inclusive)", function()
    ok(5, { type = "number", minimum = 5 })
    ok(6, { type = "number", minimum = 5 })
    fail(4, { type = "number", minimum = 5 })
  end)
  T.it("maximum (inclusive)", function()
    ok(5, { type = "number", maximum = 5 })
    ok(4, { type = "number", maximum = 5 })
    fail(6, { type = "number", maximum = 5 })
  end)
  T.it("exclusiveMinimum (boolean draft-4 style)", function()
    ok(6, { type = "number", minimum = 5, exclusiveMinimum = true })
    fail(5, { type = "number", minimum = 5, exclusiveMinimum = true })
    fail(4, { type = "number", minimum = 5, exclusiveMinimum = true })
  end)
  T.it("exclusiveMaximum (boolean draft-4 style)", function()
    ok(4, { type = "number", maximum = 5, exclusiveMaximum = true })
    fail(5, { type = "number", maximum = 5, exclusiveMaximum = true })
    fail(6, { type = "number", maximum = 5, exclusiveMaximum = true })
  end)
  T.it("exclusiveMinimum / exclusiveMaximum (numeric draft-6+ style)", function()
    ok(6, { type = "number", exclusiveMinimum = 5 })
    fail(5, { type = "number", exclusiveMinimum = 5 })
    ok(4, { type = "number", exclusiveMaximum = 5 })
    fail(5, { type = "number", exclusiveMaximum = 5 })
  end)
  T.it("multipleOf", function()
    ok(10, { type = "number", multipleOf = 5 })
    ok(0, { type = "number", multipleOf = 3 })
    fail(7, { type = "number", multipleOf = 5 })
    ok(0.2, { type = "number", multipleOf = 0.1 })
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("array keywords", function()
  T.it("minItems", function()
    ok({1, 2, 3}, { type = "array", minItems = 2 })
    fail({1}, { type = "array", minItems = 2 })
    fail({}, { type = "array", minItems = 1 })
  end)
  T.it("maxItems", function()
    ok({1, 2}, { type = "array", maxItems = 3 })
    fail({1, 2, 3, 4}, { type = "array", maxItems = 3 })
  end)
  T.it("items (single schema)", function()
    ok({1, 2, 3}, { type = "array", items = { type = "integer" } })
    fail({1, "two", 3}, { type = "array", items = { type = "integer" } })
  end)
  T.it("items (tuple schema)", function()
    local s = { type = "array", items = { { type = "integer" }, { type = "string" } } }
    ok({1, "hello"}, s)
    fail({"hello", 1}, s)
  end)
  T.it("additionalItems false", function()
    local s = {
      type = "array",
      items = { { type = "integer" } },
      additionalItems = false,
    }
    ok({1}, s)
    fail({1, 2}, s)
  end)
  T.it("additionalItems schema", function()
    local s = {
      type = "array",
      items = { { type = "integer" } },
      additionalItems = { type = "string" },
    }
    ok({1, "extra"}, s)
    fail({1, 2}, s)
  end)
  T.it("uniqueItems", function()
    ok({1, 2, 3}, { type = "array", uniqueItems = true })
    fail({1, 2, 2}, { type = "array", uniqueItems = true })
    ok({}, { type = "array", uniqueItems = true })
  end)
  T.it("contains", function()
    ok({1, "hello", true}, { type = "array", contains = { type = "string" } })
    fail({1, 2, 3}, { type = "array", contains = { type = "string" } })
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("object keywords", function()
  T.it("required", function()
    ok({ name = "Alice", age = 30 }, { type = "object", required = {"name"} })
    fail({ age = 30 }, { type = "object", required = {"name"} })
  end)
  T.it("properties", function()
    local s = {
      type = "object",
      properties = {
        name = { type = "string" },
        age  = { type = "integer" },
      }
    }
    ok({ name = "Alice", age = 30 }, s)
    fail({ name = 42 }, s)
    -- Extra properties are fine without additionalProperties = false
    ok({ name = "Alice", extra = true }, s)
  end)
  T.it("additionalProperties = false", function()
    local s = {
      type = "object",
      properties = { name = { type = "string" } },
      additionalProperties = false,
    }
    ok({ name = "Alice" }, s)
    fail({ name = "Alice", extra = true }, s)
  end)
  T.it("additionalProperties schema", function()
    local s = {
      type = "object",
      properties = { name = { type = "string" } },
      additionalProperties = { type = "integer" },
    }
    ok({ name = "Alice", count = 5 }, s)
    fail({ name = "Alice", count = "five" }, s)
  end)
  T.it("patternProperties", function()
    local s = {
      type = "object",
      patternProperties = {
        ["^str_"] = { type = "string" },
        ["^num_"] = { type = "number" },
      }
    }
    ok({ str_foo = "hello", num_bar = 42 }, s)
    fail({ str_foo = 123 }, s)
  end)
  T.it("minProperties / maxProperties", function()
    ok({ a = 1, b = 2 }, { type = "object", minProperties = 2 })
    fail({ a = 1 }, { type = "object", minProperties = 2 })
    ok({ a = 1 }, { type = "object", maxProperties = 2 })
    fail({ a = 1, b = 2, c = 3 }, { type = "object", maxProperties = 2 })
  end)
  T.it("dependencies (array)", function()
    local s = {
      type = "object",
      dependencies = {
        credit_card = { "billing_address" }
      }
    }
    ok({ credit_card = "1234", billing_address = "123 Main St" }, s)
    fail({ credit_card = "1234" }, s)
    ok({ billing_address = "123 Main St" }, s)  -- no dependency triggered
  end)
  T.it("dependencies (schema)", function()
    local s = {
      type = "object",
      dependencies = {
        name = { required = {"age"} }
      }
    }
    ok({ name = "Alice", age = 30 }, s)
    fail({ name = "Alice" }, s)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("combining keywords", function()
  T.it("allOf", function()
    local s = {
      allOf = {
        { type = "integer" },
        { minimum = 0 },
        { maximum = 100 },
      }
    }
    ok(50, s)
    fail(-1, s)
    fail(101, s)
    fail(3.14, s)
  end)
  T.it("anyOf", function()
    local s = { anyOf = { { type = "string" }, { type = "integer" } } }
    ok("hello", s)
    ok(42, s)
    fail(3.14, s)
    fail(true, s)
  end)
  T.it("oneOf", function()
    -- Mutually exclusive: type=integer XOR type=string
    local s = { oneOf = { { type = "integer" }, { type = "string" } } }
    ok(42, s)
    ok("hello", s)
    -- boolean matches neither
    fail(true, s)
    -- number (non-integer) matches neither
    fail(3.14, s)
    -- Test with value that could match multiple: use overlapping numeric constraints
    local s2 = { oneOf = { { minimum = 0 }, { maximum = 10 } } }
    -- 5 matches both (0..inf and -inf..10) → 2 matches ✗
    fail(5, s2)
    -- 20 matches only minimum=0 → 1 match ✓
    ok(20, s2)
    -- -5 matches only maximum=10 → 1 match ✓
    ok(-5, s2)
  end)
  T.it("not", function()
    local s = { ["not"] = { type = "string" } }
    ok(42, s)
    ok(nil, s)
    fail("hello", s)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("if/then/else", function()
  T.it("if true → then applied", function()
    local s = {
      ["if"]   = { minimum = 0 },
      ["then"] = { maximum = 100 },
    }
    ok(50, s)
    fail(150, s)
    ok(-5, s)  -- if=false → then not applied
  end)
  T.it("if false → else applied", function()
    local s = {
      ["if"]   = { type = "string" },
      ["then"] = { minLength = 3 },
      ["else"] = { minimum = 0 },
    }
    ok("hello", s)   -- if=true, then passes
    fail("hi", s)    -- if=true, then fails (minLength=3)
    ok(5, s)         -- if=false, else passes (>=0)
    fail(-1, s)      -- if=false, else fails (<0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("$ref and definitions", function()
  T.it("basic $ref resolution", function()
    local s = {
      definitions = {
        Address = {
          type = "object",
          required = {"street"},
          properties = { street = { type = "string" } },
        }
      },
      type = "object",
      properties = {
        home = { ["$ref"] = "#/definitions/Address" },
        work = { ["$ref"] = "#/definitions/Address" },
      }
    }
    ok({ home = { street = "123 Main" }, work = { street = "456 Elm" } }, s)
    fail({ home = { street = 123 } }, s)
    fail({ home = {} }, s)  -- missing required 'street'
  end)
  T.it("nested definitions", function()
    local s = {
      definitions = {
        NonNegInt = { type = "integer", minimum = 0 }
      },
      type = "array",
      items = { ["$ref"] = "#/definitions/NonNegInt" }
    }
    ok({1, 2, 3}, s)
    fail({1, -1, 3}, s)
    fail({1, "two"}, s)
  end)
  T.it("$ref cycle guard", function()
    -- A schema that references itself should not infinite-loop
    local s = {}
    s.definitions = { Node = { type = "object", properties = { child = { ["$ref"] = "#/definitions/Node" } } } }
    s["$ref"] = "#/definitions/Node"
    ok({ child = { child = {} } }, s)
    fail("not an object", s)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("format (advisory)", function()
  T.it("email", function()
    ok("user@example.com", { type = "string", format = "email" })
    fail("not-an-email", { type = "string", format = "email" })
  end)
  T.it("uri", function()
    ok("https://example.com/path", { type = "string", format = "uri" })
    ok("http://foo.bar", { type = "string", format = "uri" })
    fail("not-a-uri", { type = "string", format = "uri" })
  end)
  T.it("date", function()
    ok("2023-01-15", { type = "string", format = "date" })
    fail("23-1-15", { type = "string", format = "date" })
    fail("2023-13-01", { type = "string", format = "date" })
  end)
  T.it("date-time", function()
    ok("2023-01-15T10:30:00Z", { type = "string", format = "date-time" })
    fail("2023-01-15", { type = "string", format = "date-time" })
  end)
  T.it("time", function()
    ok("10:30:00", { type = "string", format = "time" })
    fail("10:30", { type = "string", format = "time" })
  end)
  T.it("ipv4", function()
    ok("192.168.1.1", { type = "string", format = "ipv4" })
    ok("0.0.0.0", { type = "string", format = "ipv4" })
    ok("255.255.255.255", { type = "string", format = "ipv4" })
    fail("999.0.0.1", { type = "string", format = "ipv4" })
    fail("1.2.3", { type = "string", format = "ipv4" })
  end)
  T.it("ipv6", function()
    ok("::1", { type = "string", format = "ipv6" })
    ok("2001:db8::1", { type = "string", format = "ipv6" })
    fail("not::ipv::6::addr::xyz", { type = "string", format = "ipv6" })
  end)
  T.it("unknown format is skipped", function()
    ok("anything", { type = "string", format = "fancy-custom-format" })
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("error path reporting", function()
  T.it("nested property path", function()
    local s = {
      type = "object",
      properties = {
        user = {
          type = "object",
          properties = {
            name = { type = "string" },
          }
        }
      }
    }
    local result, errs = js.validate({ user = { name = 42 } }, s)
    T.fail(result)
    T.ok(errs ~= nil)
    local found = false
    for _, e in ipairs(errs) do
      if e.path == "/user/name" then found = true end
    end
    T.ok(found, "expected path /user/name in errors")
  end)
  T.it("array item path (0-based JSON pointer)", function()
    local s = { type = "array", items = { type = "integer" } }
    local result, errs = js.validate({1, "bad", 3}, s)
    T.fail(result)
    local found = false
    for _, e in ipairs(errs) do
      if e.path == "/1" then found = true end  -- 0-based index of "bad" (Lua index 2 → 1)
    end
    T.ok(found, "expected path /1 in errors")
  end)
  T.it("required property path", function()
    local s = { type = "object", required = {"name"} }
    -- Use a non-empty object so typeof() detects it as "object" (empty table → "array" heuristic)
    local result, errs = js.validate({ age = 30 }, s)
    T.fail(result)
    local found = false
    for _, e in ipairs(errs) do
      if e.path == "/name" then found = true end
    end
    T.ok(found, "expected path /name in errors")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("compile API", function()
  T.it("returns a reusable validator function", function()
    local validator = js.compile({ type = "string", minLength = 3 })
    local ok1, errs1 = validator("hello")
    T.ok(ok1)
    T.eq(errs1, nil)
    local ok2, errs2 = validator("hi")
    T.fail(ok2)
    T.ok(errs2 ~= nil)
    T.ok(#errs2 > 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("complex combined schema", function()
  T.it("full object schema from spec", function()
    local schema = {
      type = "object",
      properties = {
        name = { type = "string", minLength = 1 },
        age  = { type = "integer", minimum = 0, maximum = 150 },
        tags = { type = "array", items = { type = "string" }, uniqueItems = true },
      },
      required = { "name" },
      additionalProperties = false,
    }
    local v = js.compile(schema)
    local r1, _ = v({ name = "Alice", age = 30, tags = {"a", "b"} })
    T.ok(r1)
    local r2, errs2 = v({ age = -1, tags = {"dup", "dup"} })
    T.fail(r2)
    T.ok(#errs2 >= 2, "expected at least 2 errors (missing name + negative age + dups)")
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("edge cases", function()
  T.it("null value with type null", function()
    ok(nil, { type = "null" })
  end)
  T.it("empty array vs empty object heuristic", function()
    -- Empty Lua table → treated as array
    ok({}, { type = "array" })
    -- Table with string keys → object
    ok({ a = 1 }, { type = "object" })
  end)
  T.it("integer 0 passes minimum=0", function()
    ok(0, { type = "integer", minimum = 0 })
  end)
  T.it("false as value for boolean type", function()
    ok(false, { type = "boolean" })
  end)
  T.it("deep equal for enum with nested tables", function()
    local s = { enum = { {a = 1}, {b = 2} } }
    ok({a = 1}, s)
    ok({b = 2}, s)
    fail({a = 2}, s)
    fail({c = 3}, s)
  end)
  T.it("items=false with non-empty array", function()
    fail({1}, { type = "array", items = false })
    ok({}, { type = "array", items = false })
  end)
  T.it("no errors returned when valid (nil errs)", function()
    local result, errs = js.validate("hello", { type = "string" })
    T.ok(result)
    T.eq(errs, nil)
  end)
end)
