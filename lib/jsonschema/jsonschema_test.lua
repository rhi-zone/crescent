-- lib/jsonschema/jsonschema_test.lua — tests for lib/jsonschema/init.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local js = require("lib.jsonschema")

-- ── type: string ──────────────────────────────────────────────────────────────

T.describe("type: string", function()
  T.it("accepts a string", function()
    T.ok(js.is_valid({ type = "string" }, "hello"))
  end)
  T.it("rejects a number", function()
    T.ok(not js.is_valid({ type = "string" }, 42))
  end)
  T.it("rejects nil", function()
    T.ok(not js.is_valid({ type = "string" }, nil))
  end)
  T.it("rejects a table", function()
    T.ok(not js.is_valid({ type = "string" }, {}))
  end)
  T.it("returns errors with path and message", function()
    local ok, errs = js.validate({ type = "string" }, 42)
    T.eq(ok, nil)
    T.ok(#errs >= 1)
    T.eq(errs[1].path, "")
    T.ok(errs[1].message:find("string"))
  end)
end)

-- ── type: number ──────────────────────────────────────────────────────────────

T.describe("type: number", function()
  T.it("accepts an integer as number", function()
    T.ok(js.is_valid({ type = "number" }, 42))
  end)
  T.it("accepts a float", function()
    T.ok(js.is_valid({ type = "number" }, 3.14))
  end)
  T.it("rejects a string", function()
    T.ok(not js.is_valid({ type = "number" }, "42"))
  end)
end)

-- ── type: integer ─────────────────────────────────────────────────────────────

T.describe("type: integer", function()
  T.it("accepts an integer", function()
    T.ok(js.is_valid({ type = "integer" }, 42))
  end)
  T.it("rejects a float", function()
    T.ok(not js.is_valid({ type = "integer" }, 3.14))
  end)
  T.it("rejects a string", function()
    T.ok(not js.is_valid({ type = "integer" }, "42"))
  end)
  T.it("accepts zero", function()
    T.ok(js.is_valid({ type = "integer" }, 0))
  end)
  T.it("accepts negative integer", function()
    T.ok(js.is_valid({ type = "integer" }, -5))
  end)
end)

-- ── type: boolean ─────────────────────────────────────────────────────────────

T.describe("type: boolean", function()
  T.it("accepts true", function()
    T.ok(js.is_valid({ type = "boolean" }, true))
  end)
  T.it("accepts false", function()
    T.ok(js.is_valid({ type = "boolean" }, false))
  end)
  T.it("rejects a string", function()
    T.ok(not js.is_valid({ type = "boolean" }, "true"))
  end)
  T.it("rejects 0", function()
    T.ok(not js.is_valid({ type = "boolean" }, 0))
  end)
end)

-- ── type: null ────────────────────────────────────────────────────────────────

T.describe("type: null", function()
  T.it("accepts nil", function()
    T.ok(js.is_valid({ type = "null" }, nil))
  end)
  T.it("accepts M.null sentinel", function()
    T.ok(js.is_valid({ type = "null" }, js.null))
  end)
  T.it("rejects false", function()
    T.ok(not js.is_valid({ type = "null" }, false))
  end)
  T.it("rejects empty string", function()
    T.ok(not js.is_valid({ type = "null" }, ""))
  end)
end)

-- ── type: array ───────────────────────────────────────────────────────────────

T.describe("type: array", function()
  T.it("accepts an array-like table", function()
    T.ok(js.is_valid({ type = "array" }, { 1, 2, 3 }))
  end)
  T.it("accepts an empty array", function()
    T.ok(js.is_valid({ type = "array" }, {}))
  end)
  T.it("rejects an object", function()
    T.ok(not js.is_valid({ type = "array" }, { a = 1 }))
  end)
  T.it("rejects a string", function()
    T.ok(not js.is_valid({ type = "array" }, "list"))
  end)
end)

-- ── type: object ──────────────────────────────────────────────────────────────

T.describe("type: object", function()
  T.it("accepts an object-like table", function()
    T.ok(js.is_valid({ type = "object" }, { a = 1 }))
  end)
  T.it("rejects an array", function()
    T.ok(not js.is_valid({ type = "object" }, { 1, 2, 3 }))
  end)
  T.it("rejects a string", function()
    T.ok(not js.is_valid({ type = "object" }, "obj"))
  end)
end)

-- ── type: array of types ──────────────────────────────────────────────────────

T.describe("type as array", function()
  T.it("accepts string when type is ['string', 'null']", function()
    T.ok(js.is_valid({ type = { "string", "null" } }, "hello"))
  end)
  T.it("accepts nil when type is ['string', 'null']", function()
    T.ok(js.is_valid({ type = { "string", "null" } }, nil))
  end)
  T.it("rejects number when type is ['string', 'null']", function()
    T.ok(not js.is_valid({ type = { "string", "null" } }, 42))
  end)
  T.it("accepts integer when type is ['integer', 'boolean']", function()
    T.ok(js.is_valid({ type = { "integer", "boolean" } }, 3))
    T.ok(js.is_valid({ type = { "integer", "boolean" } }, true))
  end)
end)

-- ── minLength / maxLength ─────────────────────────────────────────────────────

T.describe("minLength / maxLength", function()
  T.it("passes when length equals minLength", function()
    T.ok(js.is_valid({ minLength = 3 }, "abc"))
  end)
  T.it("fails when length below minLength", function()
    T.ok(not js.is_valid({ minLength = 3 }, "ab"))
  end)
  T.it("passes when length equals maxLength", function()
    T.ok(js.is_valid({ maxLength = 5 }, "hello"))
  end)
  T.it("fails when length exceeds maxLength", function()
    T.ok(not js.is_valid({ maxLength = 5 }, "toolong"))
  end)
  T.it("passes when length in range", function()
    T.ok(js.is_valid({ minLength = 2, maxLength = 5 }, "hi"))
  end)
  T.it("error message mentions minLength", function()
    local _, errs = js.validate({ minLength = 5 }, "hi")
    T.ok(errs[1].message:find("minLength"))
  end)
  T.it("error message mentions maxLength", function()
    local _, errs = js.validate({ maxLength = 2 }, "hello")
    T.ok(errs[1].message:find("maxLength"))
  end)
end)

-- ── pattern ───────────────────────────────────────────────────────────────────

T.describe("pattern", function()
  T.it("passes when string matches pattern", function()
    T.ok(js.is_valid({ pattern = "^%d+$" }, "12345"))
  end)
  T.it("fails when string does not match pattern", function()
    T.ok(not js.is_valid({ pattern = "^%d+$" }, "abc"))
  end)
  T.it("partial match is sufficient (no implicit anchors)", function()
    T.ok(js.is_valid({ pattern = "%d" }, "abc123"))
  end)
  T.it("error message mentions pattern", function()
    local _, errs = js.validate({ pattern = "^%a+$" }, "123")
    T.ok(errs[1].message:find("pattern"))
  end)
end)

-- ── enum ──────────────────────────────────────────────────────────────────────

T.describe("enum", function()
  T.it("passes when value is in enum", function()
    T.ok(js.is_valid({ enum = { "red", "green", "blue" } }, "red"))
  end)
  T.it("fails when value is not in enum", function()
    T.ok(not js.is_valid({ enum = { "red", "green", "blue" } }, "yellow"))
  end)
  T.it("works with mixed types", function()
    T.ok(js.is_valid({ enum = { 1, "two", true } }, 1))
    T.ok(js.is_valid({ enum = { 1, "two", true } }, "two"))
    T.ok(js.is_valid({ enum = { 1, "two", true } }, true))
  end)
  T.it("fails for wrong type even if value looks similar", function()
    T.ok(not js.is_valid({ enum = { 1, 2, 3 } }, "1"))
  end)
end)

-- ── const ─────────────────────────────────────────────────────────────────────

T.describe("const", function()
  T.it("passes when value equals const", function()
    T.ok(js.is_valid({ const = "fixed" }, "fixed"))
  end)
  T.it("fails when value differs", function()
    T.ok(not js.is_valid({ const = "fixed" }, "other"))
  end)
  T.it("works with number const", function()
    T.ok(js.is_valid({ const = 42 }, 42))
    T.ok(not js.is_valid({ const = 42 }, 43))
  end)
  T.it("const table equality", function()
    T.ok(js.is_valid({ const = { a = 1 } }, { a = 1 }))
    T.ok(not js.is_valid({ const = { a = 1 } }, { a = 2 }))
  end)
end)

-- ── minimum / maximum ─────────────────────────────────────────────────────────

T.describe("minimum / maximum", function()
  T.it("passes at minimum", function()
    T.ok(js.is_valid({ minimum = 0 }, 0))
  end)
  T.it("fails below minimum", function()
    T.ok(not js.is_valid({ minimum = 0 }, -1))
  end)
  T.it("passes at maximum", function()
    T.ok(js.is_valid({ maximum = 100 }, 100))
  end)
  T.it("fails above maximum", function()
    T.ok(not js.is_valid({ maximum = 100 }, 101))
  end)
  T.it("passes within range", function()
    T.ok(js.is_valid({ minimum = 0, maximum = 100 }, 50))
  end)
end)

-- ── exclusiveMinimum / exclusiveMaximum ───────────────────────────────────────

T.describe("exclusiveMinimum / exclusiveMaximum (draft-07 numbers)", function()
  T.it("fails at exclusiveMinimum", function()
    T.ok(not js.is_valid({ exclusiveMinimum = 0 }, 0))
  end)
  T.it("passes above exclusiveMinimum", function()
    T.ok(js.is_valid({ exclusiveMinimum = 0 }, 0.001))
  end)
  T.it("fails at exclusiveMaximum", function()
    T.ok(not js.is_valid({ exclusiveMaximum = 10 }, 10))
  end)
  T.it("passes below exclusiveMaximum", function()
    T.ok(js.is_valid({ exclusiveMaximum = 10 }, 9.999))
  end)
end)

-- ── multipleOf ────────────────────────────────────────────────────────────────

T.describe("multipleOf", function()
  T.it("passes for exact multiple", function()
    T.ok(js.is_valid({ multipleOf = 3 }, 9))
  end)
  T.it("fails for non-multiple", function()
    T.ok(not js.is_valid({ multipleOf = 3 }, 10))
  end)
  T.it("works with float multiple", function()
    T.ok(js.is_valid({ multipleOf = 0.5 }, 1.5))
  end)
  T.it("fails for non-multiple float", function()
    T.ok(not js.is_valid({ multipleOf = 3 }, 7))
  end)
end)

-- ── required properties ───────────────────────────────────────────────────────

T.describe("required", function()
  T.it("passes when all required keys present", function()
    T.ok(js.is_valid({ required = { "name", "age" } }, { name = "Alice", age = 30 }))
  end)
  T.it("fails when a required key is missing", function()
    T.ok(not js.is_valid({ required = { "name", "age" } }, { name = "Alice" }))
  end)
  T.it("error path includes missing property name", function()
    local _, errs = js.validate({ required = { "email" } }, { name = "Alice" })
    T.ok(#errs >= 1)
    T.ok(errs[1].path:find("email"))
  end)
  T.it("error message mentions required property", function()
    local _, errs = js.validate({ required = { "email" } }, { name = "Alice" })
    T.ok(errs[1].message:find("email"))
  end)
end)

-- ── properties ────────────────────────────────────────────────────────────────

T.describe("properties", function()
  T.it("validates named properties", function()
    local schema = {
      properties = {
        name = { type = "string" },
        age  = { type = "integer" },
      }
    }
    T.ok(js.is_valid(schema, { name = "Alice", age = 30 }))
  end)
  T.it("fails when property type is wrong", function()
    local schema = {
      properties = {
        age = { type = "integer" },
      }
    }
    T.ok(not js.is_valid(schema, { age = "thirty" }))
  end)
  T.it("error path goes into property", function()
    local schema = { properties = { age = { type = "integer" } } }
    local _, errs = js.validate(schema, { age = "thirty" })
    T.ok(errs[1].path:find("age"))
  end)
end)

-- ── additionalProperties: false ───────────────────────────────────────────────

T.describe("additionalProperties: false", function()
  T.it("passes when no extra properties", function()
    local schema = {
      properties = { name = { type = "string" } },
      additionalProperties = false,
    }
    T.ok(js.is_valid(schema, { name = "Alice" }))
  end)
  T.it("fails when extra property present", function()
    local schema = {
      properties = { name = { type = "string" } },
      additionalProperties = false,
    }
    T.ok(not js.is_valid(schema, { name = "Alice", extra = "x" }))
  end)
  T.it("error mentions the extra property name", function()
    local schema = {
      properties = { name = { type = "string" } },
      additionalProperties = false,
    }
    local _, errs = js.validate(schema, { name = "Alice", extra = "x" })
    T.ok(errs[1].message:find("extra"))
  end)
end)

-- ── additionalProperties: schema ──────────────────────────────────────────────

T.describe("additionalProperties: schema", function()
  T.it("passes when additional properties match schema", function()
    local schema = {
      properties = { name = { type = "string" } },
      additionalProperties = { type = "number" },
    }
    T.ok(js.is_valid(schema, { name = "Alice", score = 99 }))
  end)
  T.it("fails when additional properties don't match schema", function()
    local schema = {
      properties = { name = { type = "string" } },
      additionalProperties = { type = "number" },
    }
    T.ok(not js.is_valid(schema, { name = "Alice", score = "high" }))
  end)
end)

-- ── minProperties / maxProperties ────────────────────────────────────────────

T.describe("minProperties / maxProperties", function()
  T.it("passes at minProperties", function()
    T.ok(js.is_valid({ minProperties = 2 }, { a = 1, b = 2 }))
  end)
  T.it("fails below minProperties", function()
    T.ok(not js.is_valid({ minProperties = 2 }, { a = 1 }))
  end)
  T.it("passes at maxProperties", function()
    T.ok(js.is_valid({ maxProperties = 2 }, { a = 1, b = 2 }))
  end)
  T.it("fails above maxProperties", function()
    T.ok(not js.is_valid({ maxProperties = 2 }, { a = 1, b = 2, c = 3 }))
  end)
end)

-- ── minItems / maxItems ───────────────────────────────────────────────────────

T.describe("minItems / maxItems", function()
  T.it("passes at minItems", function()
    T.ok(js.is_valid({ minItems = 2 }, { 1, 2 }))
  end)
  T.it("fails below minItems", function()
    T.ok(not js.is_valid({ minItems = 2 }, { 1 }))
  end)
  T.it("passes at maxItems", function()
    T.ok(js.is_valid({ maxItems = 3 }, { 1, 2, 3 }))
  end)
  T.it("fails above maxItems", function()
    T.ok(not js.is_valid({ maxItems = 3 }, { 1, 2, 3, 4 }))
  end)
end)

-- ── uniqueItems ───────────────────────────────────────────────────────────────

T.describe("uniqueItems", function()
  T.it("passes for unique items", function()
    T.ok(js.is_valid({ uniqueItems = true }, { 1, 2, 3 }))
  end)
  T.it("fails for duplicate items", function()
    T.ok(not js.is_valid({ uniqueItems = true }, { 1, 2, 2 }))
  end)
  T.it("passes for unique mixed types", function()
    T.ok(js.is_valid({ uniqueItems = true }, { 1, "1", true }))
  end)
  T.it("fails for duplicate objects", function()
    T.ok(not js.is_valid({ uniqueItems = true }, { { a = 1 }, { a = 1 } }))
  end)
end)

-- ── items: schema (all items) ─────────────────────────────────────────────────

T.describe("items: schema", function()
  T.it("passes when all items match schema", function()
    T.ok(js.is_valid({ items = { type = "integer" } }, { 1, 2, 3 }))
  end)
  T.it("fails when an item doesn't match", function()
    T.ok(not js.is_valid({ items = { type = "integer" } }, { 1, "two", 3 }))
  end)
  T.it("error path includes item index (0-based)", function()
    local _, errs = js.validate({ items = { type = "integer" } }, { 1, "two", 3 })
    T.ok(errs[1].path:find("/1"))
  end)
end)

-- ── items: array (tuple validation) ──────────────────────────────────────────

T.describe("items: array (tuple)", function()
  T.it("passes for valid tuple", function()
    local schema = {
      items = { { type = "string" }, { type = "integer" } }
    }
    T.ok(js.is_valid(schema, { "hello", 42 }))
  end)
  T.it("fails when first tuple item is wrong type", function()
    local schema = {
      items = { { type = "string" }, { type = "integer" } }
    }
    T.ok(not js.is_valid(schema, { 123, 42 }))
  end)
  T.it("allows additional items by default", function()
    local schema = {
      items = { { type = "string" }, { type = "integer" } }
    }
    T.ok(js.is_valid(schema, { "hello", 42, "extra" }))
  end)
end)

-- ── additionalItems ───────────────────────────────────────────────────────────

T.describe("additionalItems: false", function()
  T.it("fails when extra items present and additionalItems is false", function()
    local schema = {
      items = { { type = "string" } },
      additionalItems = false,
    }
    T.ok(not js.is_valid(schema, { "hello", "extra" }))
  end)
  T.it("passes when items count matches tuple length", function()
    local schema = {
      items = { { type = "string" } },
      additionalItems = false,
    }
    T.ok(js.is_valid(schema, { "hello" }))
  end)
end)

T.describe("additionalItems: schema", function()
  T.it("validates extra items against schema", function()
    local schema = {
      items = { { type = "string" } },
      additionalItems = { type = "integer" },
    }
    T.ok(js.is_valid(schema, { "hello", 1, 2 }))
  end)
  T.it("fails when extra items don't match schema", function()
    local schema = {
      items = { { type = "string" } },
      additionalItems = { type = "integer" },
    }
    T.ok(not js.is_valid(schema, { "hello", "extra" }))
  end)
end)

-- ── contains ─────────────────────────────────────────────────────────────────

T.describe("contains", function()
  T.it("passes when at least one item matches", function()
    T.ok(js.is_valid({ contains = { type = "integer" } }, { "a", 1, "b" }))
  end)
  T.it("fails when no item matches", function()
    T.ok(not js.is_valid({ contains = { type = "integer" } }, { "a", "b", "c" }))
  end)
  T.it("passes when all items match", function()
    T.ok(js.is_valid({ contains = { type = "integer" } }, { 1, 2, 3 }))
  end)
end)

-- ── allOf ─────────────────────────────────────────────────────────────────────

T.describe("allOf", function()
  T.it("passes when all schemas match", function()
    local schema = {
      allOf = {
        { type = "integer" },
        { minimum = 0 },
        { maximum = 100 },
      }
    }
    T.ok(js.is_valid(schema, 50))
  end)
  T.it("fails when one schema fails", function()
    local schema = {
      allOf = {
        { type = "integer" },
        { minimum = 0 },
      }
    }
    T.ok(not js.is_valid(schema, -1))
  end)
  T.it("accumulates errors from all failing sub-schemas", function()
    local schema = {
      allOf = {
        { minimum = 10 },
        { maximum = 5 },
      }
    }
    -- 7 fails maximum=5 and minimum/maximum both apply to numbers
    local _, errs = js.validate(schema, 7)
    T.ok(#errs >= 1)
  end)
end)

-- ── anyOf ─────────────────────────────────────────────────────────────────────

T.describe("anyOf", function()
  T.it("passes when first schema matches", function()
    T.ok(js.is_valid({ anyOf = { { type = "string" }, { type = "integer" } } }, "hello"))
  end)
  T.it("passes when second schema matches", function()
    T.ok(js.is_valid({ anyOf = { { type = "string" }, { type = "integer" } } }, 42))
  end)
  T.it("fails when no schema matches", function()
    T.ok(not js.is_valid({ anyOf = { { type = "string" }, { type = "integer" } } }, true))
  end)
  T.it("error mentions anyOf", function()
    local _, errs = js.validate({ anyOf = { { type = "string" }, { type = "integer" } } }, true)
    T.ok(errs[1].message:find("anyOf"))
  end)
end)

-- ── oneOf ─────────────────────────────────────────────────────────────────────

T.describe("oneOf", function()
  T.it("passes when exactly one schema matches", function()
    local schema = {
      oneOf = {
        { type = "integer" },
        { type = "string" },
      }
    }
    T.ok(js.is_valid(schema, 42))
    T.ok(js.is_valid(schema, "hello"))
  end)
  T.it("fails when no schema matches", function()
    local schema = {
      oneOf = {
        { type = "integer" },
        { type = "string" },
      }
    }
    T.ok(not js.is_valid(schema, true))
  end)
  T.it("fails when more than one schema matches", function()
    local schema = {
      oneOf = {
        { type = "number" },
        { type = "integer" },
      }
    }
    T.ok(not js.is_valid(schema, 5))
  end)
  T.it("error mentions count when multiple match", function()
    local schema = { oneOf = { { type = "number" }, { type = "integer" } } }
    local _, errs = js.validate(schema, 5)
    T.ok(errs[1].message:find("2"))
  end)
end)

-- ── not ───────────────────────────────────────────────────────────────────────

T.describe("not", function()
  T.it("passes when schema does NOT match", function()
    T.ok(js.is_valid({ ["not"] = { type = "string" } }, 42))
  end)
  T.it("fails when schema matches", function()
    T.ok(not js.is_valid({ ["not"] = { type = "string" } }, "hello"))
  end)
  T.it("error message mentions 'not'", function()
    local _, errs = js.validate({ ["not"] = { type = "string" } }, "hello")
    T.ok(errs[1].message:find("not"))
  end)
end)

-- ── if / then / else ──────────────────────────────────────────────────────────

T.describe("if/then/else", function()
  T.it("applies 'then' when 'if' matches", function()
    local schema = {
      ["if"]   = { type = "integer" },
      ["then"] = { minimum = 0 },
    }
    T.ok(js.is_valid(schema, 5))
    T.ok(not js.is_valid(schema, -1))
  end)
  T.it("applies 'else' when 'if' does not match", function()
    local schema = {
      ["if"]   = { type = "integer" },
      ["else"]  = { minLength = 3 },
    }
    T.ok(js.is_valid(schema, "hello"))
    T.ok(not js.is_valid(schema, "hi"))
  end)
  T.it("neither then nor else constrains the opposite branch", function()
    local schema = {
      ["if"]   = { type = "integer" },
      ["then"] = { minimum = 0 },
    }
    -- string doesn't match 'if', no 'else' — should pass regardless
    T.ok(js.is_valid(schema, "anything"))
  end)
end)

-- ── $ref with definitions ─────────────────────────────────────────────────────

T.describe("$ref with definitions", function()
  T.it("resolves a simple $ref", function()
    local schema = {
      definitions = {
        PositiveInt = { type = "integer", minimum = 1 }
      },
      ["$ref"] = "#/definitions/PositiveInt"
    }
    T.ok(js.is_valid(schema, 5))
    T.ok(not js.is_valid(schema, 0))
    T.ok(not js.is_valid(schema, "hello"))
  end)
  T.it("fails gracefully for unresolved $ref", function()
    local schema = { ["$ref"] = "#/definitions/Missing" }
    local ok, errs = js.validate(schema, 42)
    T.eq(ok, nil)
    T.ok(errs[1].message:find("unresolved"))
  end)
  T.it("resolves nested $ref via properties", function()
    local schema = {
      definitions = {
        Name = { type = "string", minLength = 1 }
      },
      type = "object",
      properties = {
        name = { ["$ref"] = "#/definitions/Name" }
      }
    }
    T.ok(js.is_valid(schema, { name = "Alice" }))
    T.ok(not js.is_valid(schema, { name = "" }))
  end)
end)

-- ── patternProperties ─────────────────────────────────────────────────────────

T.describe("patternProperties", function()
  T.it("validates matched properties", function()
    local schema = {
      patternProperties = {
        ["^s_"] = { type = "string" },
        ["^n_"] = { type = "number" },
      }
    }
    T.ok(js.is_valid(schema, { s_name = "Alice", n_age = 30 }))
  end)
  T.it("fails when a matched property has wrong type", function()
    local schema = {
      patternProperties = {
        ["^s_"] = { type = "string" },
      }
    }
    T.ok(not js.is_valid(schema, { s_name = 42 }))
  end)
  T.it("does not validate properties not matching pattern", function()
    local schema = {
      patternProperties = { ["^s_"] = { type = "string" } }
    }
    -- x_foo doesn't match ^s_, so it's unconstrained
    T.ok(js.is_valid(schema, { x_foo = 99 }))
  end)
  T.it("patternProperties marks properties as covered for additionalProperties", function()
    local schema = {
      patternProperties = { ["^s_"] = { type = "string" } },
      additionalProperties = false,
    }
    T.ok(js.is_valid(schema, { s_name = "Alice" }))
    T.ok(not js.is_valid(schema, { s_name = "Alice", extra = "x" }))
  end)
end)

-- ── dependencies ─────────────────────────────────────────────────────────────

T.describe("dependencies", function()
  T.it("key dependency: required keys present when dep key present", function()
    local schema = {
      dependencies = {
        credit_card = { "billing_address" }
      }
    }
    T.ok(js.is_valid(schema, { credit_card = "4111", billing_address = "123 Main St" }))
    T.ok(not js.is_valid(schema, { credit_card = "4111" }))
  end)
  T.it("passes when dep key is absent", function()
    local schema = {
      dependencies = { credit_card = { "billing_address" } }
    }
    T.ok(js.is_valid(schema, { name = "Alice" }))
  end)
  T.it("schema dependency: validates whole object against dep schema", function()
    local schema = {
      dependencies = {
        name = {
          properties = {
            name = { type = "string" },
            age  = { type = "integer" },
          },
          required = { "age" }
        }
      }
    }
    T.ok(js.is_valid(schema, { name = "Alice", age = 30 }))
    T.ok(not js.is_valid(schema, { name = "Alice" }))
  end)
end)

-- ── propertyNames ─────────────────────────────────────────────────────────────

T.describe("propertyNames", function()
  T.it("passes when all property names match schema", function()
    local schema = {
      propertyNames = { minLength = 1, maxLength = 5 }
    }
    T.ok(js.is_valid(schema, { abc = 1, de = 2 }))
  end)
  T.it("fails when a property name is too long", function()
    local schema = {
      propertyNames = { maxLength = 3 }
    }
    T.ok(not js.is_valid(schema, { toolong = 1 }))
  end)
end)

-- ── compile ───────────────────────────────────────────────────────────────────

T.describe("compile", function()
  T.it("returns a validator function", function()
    local validator = js.compile({ type = "string" })
    T.eq(type(validator), "function")
  end)
  T.it("validator function returns true for valid input", function()
    local validator = js.compile({ type = "string" })
    local result = validator("hello")
    T.ok(result)
  end)
  T.it("validator function returns nil,errors for invalid input", function()
    local validator = js.compile({ type = "string" })
    local ok, errs = validator(42)
    T.eq(ok, nil)
    T.ok(#errs >= 1)
  end)
  T.it("compiled validator can be called multiple times", function()
    local validator = js.compile({ type = "integer", minimum = 0 })
    T.ok(validator(5))
    T.ok(not validator(-1))
    T.ok(validator(0))
    T.ok(not validator(3.14))
  end)
end)

-- ── error path format ─────────────────────────────────────────────────────────

T.describe("error paths", function()
  T.it("root path is empty string", function()
    local _, errs = js.validate({ type = "string" }, 42)
    T.eq(errs[1].path, "")
  end)
  T.it("nested property path uses /key", function()
    local schema = { properties = { name = { type = "integer" } } }
    local _, errs = js.validate(schema, { name = "Alice" })
    T.eq(errs[1].path, "/name")
  end)
  T.it("array item path uses 0-based index", function()
    local _, errs = js.validate({ items = { type = "integer" } }, { 1, "bad", 3 })
    T.eq(errs[1].path, "/1")
  end)
  T.it("deeply nested path is correct", function()
    local schema = {
      properties = {
        user = {
          properties = {
            age = { type = "integer" }
          }
        }
      }
    }
    local _, errs = js.validate(schema, { user = { age = "thirty" } })
    T.eq(errs[1].path, "/user/age")
  end)
end)

-- ── is_valid API ──────────────────────────────────────────────────────────────

T.describe("is_valid", function()
  T.it("returns true for valid value", function()
    T.eq(js.is_valid({ type = "string" }, "hello"), true)
  end)
  T.it("returns false for invalid value", function()
    T.eq(js.is_valid({ type = "string" }, 42), false)
  end)
end)

-- ── boolean schema ────────────────────────────────────────────────────────────

T.describe("boolean schema", function()
  T.it("true schema accepts anything", function()
    T.ok(js.is_valid(true, "anything"))
    T.ok(js.is_valid(true, 42))
    T.ok(js.is_valid(true, nil))
  end)
  T.it("false schema rejects everything", function()
    T.ok(not js.is_valid(false, "anything"))
    T.ok(not js.is_valid(false, 42))
    T.ok(not js.is_valid(false, nil))
  end)
end)

-- ── full object schema integration ───────────────────────────────────────────

T.describe("full object schema", function()
  T.it("validates a complete user object", function()
    local schema = {
      type = "object",
      required = { "name", "email", "age" },
      properties = {
        name  = { type = "string", minLength = 1 },
        email = { type = "string", pattern = "@" },
        age   = { type = "integer", minimum = 0, maximum = 150 },
        score = { type = "number", minimum = 0.0, maximum = 1.0 },
      },
      additionalProperties = false,
    }
    T.ok(js.is_valid(schema, {
      name  = "Alice",
      email = "alice@example.com",
      age   = 30,
      score = 0.95,
    }))
    -- Missing required field
    T.ok(not js.is_valid(schema, { name = "Alice", email = "a@b.com" }))
    -- Extra property
    T.ok(not js.is_valid(schema, { name = "Alice", email = "a@b.com", age = 30, extra = "x" }))
    -- Wrong type
    T.ok(not js.is_valid(schema, { name = "Alice", email = "a@b.com", age = "thirty" }))
  end)
end)
