-- lib/fractal/type_ref_json_schema_07_test.lua
-- Tests for lib/fractal/type_ref_json_schema_07.lua: the TypeRef -> JSON
-- Schema draft-07 projector.
--
-- The last group runs projected schemas through `lib/json_schema`, crescent's
-- draft-7 validator, so "this emits what the consumer expects" is checked
-- against the consumer rather than asserted.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local type_ref    = require("lib.fractal.type_ref")
local js07        = require("lib.fractal.type_ref_json_schema_07")
local json_schema = require("lib.json_schema")
local null        = require("lib.null")

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
local to    = js07.type_ref_to_json_schema_07

T.describe("lib.fractal.type_ref_json_schema_07", function()

  T.describe("divergences from draft 2020-12", function()

    T.it("never is the boolean false schema, not not:{}", function()
      T.eq(to(t(types.never)), false)
    end)

    T.it("a boolean schema is returned undecorated even when meta is present", function()
      -- Deliberate divergence from the TS source, which spreads meta onto
      -- `false` and thereby discards the schema. See the module header.
      T.eq(to(t(types.never, { description = "nothing" })), false)
    end)

    T.it("tuple uses an items array plus additionalItems", function()
      local shape = types.tuple({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), {
        type = "array",
        items = { { type = "string" }, { type = "number" } },
        additionalItems = false,
      })
    end)

    T.it("ref points into definitions, not $defs", function()
      assert_deep_eq(to(t(types.ref("User"))), { ["$ref"] = "#/definitions/User" })
    end)

    T.it("literal uses const", function()
      assert_deep_eq(to(t(types.literal("draft"))), { const = "draft" })
    end)

    T.it("title is not emitted", function()
      assert_deep_eq(to(t(types.string, { title = "Name" })), { type = "string" })
    end)

    T.it("instance and page have no handler and project to the empty schema", function()
      assert_deep_eq(to(t(types.instance("User", "src/user.ts"))), {})
      assert_deep_eq(to(t(types.page(t(types.string), "cursor"))), {})
    end)

  end)

  T.describe("leaf kinds", function()

    T.it("primitives project to their type keyword", function()
      assert_deep_eq(to(t(types.boolean)), { type = "boolean" })
      assert_deep_eq(to(t(types.integer)), { type = "integer" })
      assert_deep_eq(to(t(types.null)), { type = "null" })
      assert_deep_eq(to(t(types.void)), { type = "null" })
      assert_deep_eq(to(t(types.unknown)), {})
    end)

    T.it("refinement kinds carry a format", function()
      assert_deep_eq(to(t({ kind = "uuid" })), { type = "string", format = "uuid" })
      assert_deep_eq(to(t({ kind = "int64" })), { type = "integer", format = "int64" })
      assert_deep_eq(to(t({ kind = "duration" })), { type = "string", format = "duration" })
    end)

  end)

  T.describe("composite kinds", function()

    T.it("object lists non-optional fields in required", function()
      local shape = types.object({
        id = t(types.string),
        note = t(types.string, { optional = true }),
      })
      local out = to(t(shape))
      assert_deep_eq(out, {
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

    T.it("a never-typed field stays the boolean false schema", function()
      -- `assign` cannot decorate a boolean, and a schema rejecting every value
      -- has nothing readOnly could mean.
      local shape = types.object({ nope = t(types.never, { readonly = true }) })
      assert_deep_eq(to(t(shape)), {
        type = "object",
        properties = { nope = false },
        required = { "nope" },
      })
    end)

    T.it("array, map, stream and intersection project their children", function()
      assert_deep_eq(to(t(types.array(t(types.string)))), {
        type = "array",
        items = { type = "string" },
      })
      assert_deep_eq(to(t(types.map(t(types.string), t(types.number)))), {
        type = "object",
        additionalProperties = { type = "number" },
      })
      assert_deep_eq(to(t(types.stream(t(types.string)))), {
        type = "array",
        items = { type = "string" },
        ["x-stream"] = true,
      })
      assert_deep_eq(to(t(types.intersection({ t(types.string), t(types.number) }))), {
        allOf = { { type = "string" }, { type = "number" } },
      })
    end)

    T.it("union is anyOf, or oneOf plus a discriminator", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), { anyOf = { { type = "string" }, { type = "number" } } })
      assert_deep_eq(to(t(shape, { discriminator = "kind" })), {
        oneOf = { { type = "string" }, { type = "number" } },
        discriminator = { propertyName = "kind" },
      })
    end)

    T.it("callables and interfaces degrade to vendor extensions", function()
      assert_deep_eq(to(t(types.function_({}, t(types.string)))), { ["x-function"] = true })
      assert_deep_eq(to(t(types.method({}, t(types.string)))), { ["x-method"] = true })
      assert_deep_eq(to(t(types.interface({}))), { type = "object", ["x-interface"] = true })
    end)

  end)

  T.describe("enum", function()

    T.it("string members infer type string", function()
      assert_deep_eq(to(t(types.enum({ "a", "b" }))), { type = "string", enum = { "a", "b" } })
    end)

    T.it("whole-number members infer type integer", function()
      assert_deep_eq(to(t({ kind = "enum", members = { 1, 2 } })), { type = "integer", enum = { 1, 2 } })
    end)

    T.it("mixed members omit type", function()
      assert_deep_eq(to(t({ kind = "enum", members = { "a", 1 } })), { enum = { "a", 1 } })
    end)

  end)

  T.describe("meta", function()

    T.it("nullable widens a scalar's type keyword and wraps a complex one", function()
      assert_deep_eq(to(t(types.string, { nullable = true })), { type = { "string", "null" } })
      assert_deep_eq(to(t(types.array(t(types.string)), { nullable = true })), {
        anyOf = { { type = "array", items = { type = "string" } }, { type = "null" } },
      })
    end)

    T.it("annotations and numeric bounds pass through", function()
      assert_deep_eq(to(t(types.number, {
        description = "count",
        deprecated = true,
        default = 0,
        minimum = 0,
        exclusiveMaximum = 10,
        readOnly = true,
      })), {
        type = "number",
        description = "count",
        deprecated = true,
        default = 0,
        minimum = 0,
        exclusiveMaximum = 10,
        readOnly = true,
      })
    end)

    T.it("a null default survives as the shared sentinel", function()
      -- deep_eq compares the sentinel by identity, which is the whole point of
      -- lib/null: a copy would compare unequal.
      assert_deep_eq(to(t(types.string, { default = null.null })), {
        type = "string",
        default = null.null,
      })
    end)

    T.it("examples pass through only as a list", function()
      assert_deep_eq(to(t(types.string, { examples = { "a" } })), {
        type = "string",
        examples = { "a" },
      })
      assert_deep_eq(to(t(types.string, { examples = 3 })), { type = "string" })
    end)

  end)

  T.describe("kind lattice fallback", function()

    T.it("a registered child falls back to its nearest handled ancestor", function()
      type_ref.register_parent("js07_int128", "integer")
      assert_deep_eq(to(t({ kind = "js07_int128" })), { type = "integer" })
      type_ref.register_parent("js07_int128", nil)
    end)

    T.it("an unhandled kind projects to the empty schema", function()
      assert_deep_eq(to(t({ kind = "js07_unheard_of_kind" })), {})
    end)

  end)

  T.describe("consumed by lib/json_schema", function()

    T.it("a projected object schema accepts a conforming value and rejects a missing field", function()
      local shape = types.object({
        id = t(types.string),
        count = t(types.integer, { optional = true }),
      })
      local schema = to(t(shape))
      T.ok(json_schema.validate({ id = "a", count = 2 }, schema))
      T.fail(json_schema.validate({ count = 2 }, schema))
      T.fail(json_schema.validate({ id = 1 }, schema))
    end)

    T.it("the boolean false schema rejects every value, as never means", function()
      T.fail(json_schema.validate("anything", to(t(types.never))))
      T.fail(json_schema.validate(42, to(t(types.never))))
    end)

    T.it("a nullable scalar's type array accepts both the value and null", function()
      local schema = to(t(types.string, { nullable = true }))
      T.ok(json_schema.validate("a", schema))
      T.ok(json_schema.validate(nil, schema))
      T.fail(json_schema.validate(1, schema))
    end)

    T.it("an enum schema rejects a non-member", function()
      local schema = to(t(types.enum({ "draft", "live" })))
      T.ok(json_schema.validate("draft", schema))
      T.fail(json_schema.validate("archived", schema))
    end)

    T.it("a union's anyOf accepts either variant", function()
      local schema = to(t(types.union({ t(types.string), t(types.integer) })))
      T.ok(json_schema.validate("a", schema))
      T.ok(json_schema.validate(3, schema))
      T.fail(json_schema.validate(true, schema))
    end)

  end)

end)
