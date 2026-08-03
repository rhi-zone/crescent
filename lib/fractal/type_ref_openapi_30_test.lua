-- lib/fractal/type_ref_openapi_30_test.lua
-- Tests for lib/fractal/type_ref_openapi_30.lua: the TypeRef -> OpenAPI 3.0
-- Schema Object projector.
--
-- The last group runs projected schemas through `lib/openapi`'s
-- `validate_schema`, so "this emits what the consumer expects" is checked
-- against the consumer rather than asserted.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")
local oas30    = require("lib.fractal.type_ref_openapi_30")
local openapi  = require("lib.openapi")

--: (unknown, unknown) -> boolean
local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--: (unknown, unknown, string | nil) -> nil
local function assert_deep_eq(a, b, msg)
  T.ok(deep_eq(a, b), (msg and msg .. ": " or "") .. "schemas not deeply equal")
end

local t     = type_ref.type_ref_from_shape
local types = type_ref.types
local to    = oas30.type_ref_to_openapi_30

T.describe("lib.fractal.type_ref_openapi_30", function()

  T.describe("divergences from the JSON Schema projectors", function()

    T.it("nullable is a keyword, never a type array", function()
      assert_deep_eq(to(t(types.string, { nullable = true })), {
        type = "string",
        nullable = true,
      })
      assert_deep_eq(to(t(types.array(t(types.string)), { nullable = true })), {
        type = "array",
        items = { type = "string" },
        nullable = true,
      })
    end)

    T.it("null and void are nullable, since there is no type null", function()
      assert_deep_eq(to(t(types.null)), { nullable = true })
      assert_deep_eq(to(t(types.void)), { nullable = true })
    end)

    T.it("bytes uses format byte, and duration has no format", function()
      assert_deep_eq(to(t({ kind = "bytes" })), { type = "string", format = "byte" })
      assert_deep_eq(to(t({ kind = "duration" })), { type = "string" })
    end)

    T.it("tuple uses an items array, with no additionalItems", function()
      assert_deep_eq(to(t(types.tuple({ t(types.string), t(types.number) }))), {
        type = "array",
        items = { { type = "string" }, { type = "number" } },
      })
    end)

    T.it("a literal is a single-member enum", function()
      assert_deep_eq(to(t(types.literal("draft"))), { enum = { "draft" } })
    end)

    T.it("enum is always type string, with no member-type inference", function()
      assert_deep_eq(to(t(types.enum({ "a", "b" }))), { type = "string", enum = { "a", "b" } })
      assert_deep_eq(to(t({ kind = "enum", members = { 1, 2 } })), { type = "string", enum = { 1, 2 } })
    end)

    T.it("ref points into components.schemas", function()
      assert_deep_eq(to(t(types.ref("User"))), { ["$ref"] = "#/components/schemas/User" })
    end)

    T.it("exclusive bounds are boolean modifiers on minimum/maximum", function()
      assert_deep_eq(to(t(types.number, { exclusiveMinimum = 0, maximum = 10 })), {
        type = "number",
        minimum = 0,
        exclusiveMinimum = true,
        maximum = 10,
      })
    end)

    T.it("the example keyword is singular, and examples is not passed through", function()
      assert_deep_eq(to(t(types.string, { example = "a", examples = { "a", "b" } })), {
        type = "string",
        example = "a",
      })
    end)

    T.it("instance has no handler and projects to the empty schema", function()
      assert_deep_eq(to(t(types.instance("User", "src/user.ts"))), {})
    end)

  end)

  T.describe("shared behaviour", function()

    T.it("primitives and refinements project to type plus format", function()
      assert_deep_eq(to(t(types.boolean)), { type = "boolean" })
      assert_deep_eq(to(t(types.integer)), { type = "integer" })
      assert_deep_eq(to(t(types.unknown)), {})
      assert_deep_eq(to(t(types.never)), { ["not"] = {} })
      assert_deep_eq(to(t({ kind = "int32" })), { type = "integer", format = "int32" })
      assert_deep_eq(to(t({ kind = "datetime" })), { type = "string", format = "date-time" })
    end)

    T.it("object lists non-optional fields in required", function()
      local shape = types.object({
        id = t(types.string),
        note = t(types.string, { optional = true }),
      })
      assert_deep_eq(to(t(shape)), {
        type = "object",
        properties = { id = { type = "string" }, note = { type = "string" } },
        required = { "id" },
      })
    end)

    T.it("a field's meta.readonly becomes readOnly on the property schema", function()
      local shape = types.object({ id = t(types.string, { readonly = true }) })
      assert_deep_eq(to(t(shape)), {
        type = "object",
        properties = { id = { type = "string", readOnly = true } },
        required = { "id" },
      })
    end)

    T.it("map, stream, page and intersection project their children", function()
      assert_deep_eq(to(t(types.map(t(types.string), t(types.number)))), {
        type = "object",
        additionalProperties = { type = "number" },
      })
      assert_deep_eq(to(t(types.stream(t(types.string)))), {
        type = "array",
        items = { type = "string" },
        ["x-stream"] = true,
      })
      assert_deep_eq(to(t(types.page(t(types.string), "offset"))), {
        type = "array",
        items = { type = "string" },
        ["x-page-style"] = "offset",
      })
      assert_deep_eq(to(t(types.intersection({ t(types.string), t(types.number) }))), {
        allOf = { { type = "string" }, { type = "number" } },
      })
    end)

    T.it("union is anyOf, or oneOf plus a Discriminator Object", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), { anyOf = { { type = "string" }, { type = "number" } } })
      assert_deep_eq(to(t(shape, { discriminator = "kind" })), {
        oneOf = { { type = "string" }, { type = "number" } },
        discriminator = { propertyName = "kind" },
      })
    end)

    T.it("readOnly and writeOnly pass through from meta", function()
      assert_deep_eq(to(t(types.string, { readOnly = true })), { type = "string", readOnly = true })
      assert_deep_eq(to(t(types.string, { writeOnly = true })), { type = "string", writeOnly = true })
    end)

    T.it("callables and interfaces degrade to vendor extensions", function()
      assert_deep_eq(to(t(types.function_({}, t(types.string)))), { ["x-function"] = true })
      assert_deep_eq(to(t(types.method({}, t(types.string)))), { ["x-method"] = true })
      assert_deep_eq(to(t(types.interface({}))), { type = "object", ["x-interface"] = true })
    end)

    T.it("a registered child falls back to its nearest handled ancestor", function()
      type_ref.register_parent("oas30_int128", "integer")
      assert_deep_eq(to(t({ kind = "oas30_int128" })), { type = "integer" })
      type_ref.register_parent("oas30_int128", nil)
    end)

  end)

  T.describe("type_ref_document_to_openapi_30", function()

    T.it("the shape is always schema plus components, even with no defs", function()
      local doc = type_ref.type_ref_document(t(types.string))
      assert_deep_eq(oas30.type_ref_document_to_openapi_30(doc), {
        schema = { type = "string" },
        components = { schemas = {} },
      })
    end)

    T.it("defs become components.schemas entries the root's refs resolve against", function()
      local doc = type_ref.type_ref_document(
        t(types.ref("User")),
        { User = t(types.object({ id = t(types.string) })) }
      )
      assert_deep_eq(oas30.type_ref_document_to_openapi_30(doc), {
        schema = { ["$ref"] = "#/components/schemas/User" },
        components = {
          schemas = {
            User = {
              type = "object",
              properties = { id = { type = "string" } },
              required = { "id" },
            },
          },
        },
      })
    end)

  end)

  T.describe("consumed by lib/openapi", function()

    T.it("a projected object schema accepts a conforming value", function()
      local shape = types.object({
        id = t(types.string),
        count = t(types.integer, { optional = true }),
      })
      local schema = to(t(shape))
      T.ok(openapi.validate_schema({ id = "a", count = 2 }, schema))
      T.fail(openapi.validate_schema({ count = 2 }, schema))
      T.fail(openapi.validate_schema({ id = 1 }, schema))
    end)

    T.it("a projected enum schema rejects a non-member", function()
      local schema = to(t(types.enum({ "draft", "live" })))
      T.ok(openapi.validate_schema("draft", schema))
      T.fail(openapi.validate_schema("archived", schema))
    end)

    T.it("a projected union's anyOf accepts either variant", function()
      local schema = to(t(types.union({ t(types.string), t(types.integer) })))
      T.ok(openapi.validate_schema("a", schema))
      T.ok(openapi.validate_schema(3, schema))
    end)

    T.it("a projected allOf requires every member", function()
      local left = types.object({ a = t(types.string) })
      local right = types.object({ b = t(types.string) })
      local schema = to(t(types.intersection({ t(left), t(right) })))
      T.ok(openapi.validate_schema({ a = "x", b = "y" }, schema))
      T.fail(openapi.validate_schema({ a = "x" }, schema))
    end)

  end)

end)
