-- lib/type-ir/json_schema_04_test.lua
-- Tests for lib/type-ir/json_schema_04.lua: the TypeRef -> JSON
-- Schema draft-04 projector.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.type-ir")
local js04     = require("lib.type-ir.json_schema_04")
local null     = require("lib.null")

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
local to    = js04.type_ref_to_json_schema_04

T.describe("lib.type-ir.json_schema_04", function()

  T.describe("divergences from the later drafts", function()

    T.it("never is not:{} — draft-04 has no boolean schemas", function()
      assert_deep_eq(to(t(types.never)), { ["not"] = {} })
    end)

    T.it("a literal is a single-member enum — draft-04 has no const", function()
      assert_deep_eq(to(t(types.literal("draft"))), { enum = { "draft" } })
    end)

    T.it("a null literal keeps the shared sentinel as its member", function()
      assert_deep_eq(to(t(types.literal(null.null))), { enum = { null.null } })
    end)

    T.it("tuple uses an items array plus additionalItems", function()
      assert_deep_eq(to(t(types.tuple({ t(types.string), t(types.number) }))), {
        type = "array",
        items = { { type = "string" }, { type = "number" } },
        additionalItems = false,
      })
    end)

    T.it("ref points into definitions", function()
      assert_deep_eq(to(t(types.ref("User"))), { ["$ref"] = "#/definitions/User" })
    end)

    T.it("nullable always wraps in anyOf, even for a scalar", function()
      assert_deep_eq(to(t(types.string, { nullable = true })), {
        anyOf = { { type = "string" }, { type = "null" } },
      })
    end)

    T.it("exclusive bounds are boolean modifiers on minimum/maximum", function()
      assert_deep_eq(to(t(types.number, { exclusiveMinimum = 0, exclusiveMaximum = 10 })), {
        type = "number",
        minimum = 0,
        exclusiveMinimum = true,
        maximum = 10,
        exclusiveMaximum = true,
      })
    end)

    T.it("a plain minimum is emitted without the modifier", function()
      assert_deep_eq(to(t(types.number, { minimum = 0, maximum = 10 })), {
        type = "number",
        minimum = 0,
        maximum = 10,
      })
    end)

    T.it("an exclusive bound wins over a plain one on the same side", function()
      assert_deep_eq(to(t(types.number, { minimum = 0, exclusiveMinimum = 5 })), {
        type = "number",
        minimum = 5,
        exclusiveMinimum = true,
      })
    end)

    T.it("title, examples, $comment and a field's readonly are all dropped", function()
      assert_deep_eq(to(t(types.string, {
        title = "Name",
        examples = { "a" },
        ["$comment"] = "note",
      })), { type = "string" })
      local shape = types.object({ id = t(types.string, { readonly = true }) })
      assert_deep_eq(to(t(shape)), {
        type = "object",
        properties = { id = { type = "string" } },
        required = { "id" },
      })
    end)

    T.it("instance and page have no handler and project to the empty schema", function()
      assert_deep_eq(to(t(types.instance("User", "src/user.ts"))), {})
      assert_deep_eq(to(t(types.page(t(types.string), "offset"))), {})
    end)

  end)

  T.describe("shared behaviour", function()

    T.it("primitives and refinements project as in the later drafts", function()
      assert_deep_eq(to(t(types.boolean)), { type = "boolean" })
      assert_deep_eq(to(t(types.null)), { type = "null" })
      assert_deep_eq(to(t(types.unknown)), {})
      assert_deep_eq(to(t({ kind = "uuid" })), { type = "string", format = "uuid" })
      assert_deep_eq(to(t({ kind = "float32" })), { type = "number", format = "float" })
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

    T.it("enum members are type-inferred", function()
      assert_deep_eq(to(t(types.enum({ "a", "b" }))), { type = "string", enum = { "a", "b" } })
      assert_deep_eq(to(t({ kind = "enum", members = { 1, 2 } })), { type = "integer", enum = { 1, 2 } })
      assert_deep_eq(to(t({ kind = "enum", members = { "a", 1 } })), { enum = { "a", 1 } })
    end)

    T.it("callables and interfaces degrade to vendor extensions", function()
      assert_deep_eq(to(t(types.function_({}, t(types.string)))), { ["x-function"] = true })
      assert_deep_eq(to(t(types.method({}, t(types.string)))), { ["x-method"] = true })
      assert_deep_eq(to(t(types.interface({}))), { type = "object", ["x-interface"] = true })
    end)

    T.it("a registered child falls back to its nearest handled ancestor", function()
      type_ref.register_parent("js04_int128", "integer")
      assert_deep_eq(to(t({ kind = "js04_int128" })), { type = "integer" })
      type_ref.register_parent("js04_int128", nil)
    end)

  end)

  T.describe("type_ref_to_json_schema_04_document", function()

    T.it("a bare ref gets $schema and nothing else", function()
      assert_deep_eq(js04.type_ref_to_json_schema_04_document(t(types.string)), {
        ["$schema"] = "http://json-schema.org/draft-04/schema#",
        type = "string",
      })
    end)

    T.it("nil declaration behaves as an empty one", function()
      assert_deep_eq(
        js04.type_ref_to_json_schema_04_document(t(types.string), nil),
        js04.type_ref_to_json_schema_04_document(t(types.string), {})
      )
    end)

    T.it("id and definitions are emitted when declared", function()
      local out = js04.type_ref_to_json_schema_04_document(t(types.ref("User")), {
        id = "https://example.test/schema",
        definitions = { User = t(types.object({ id = t(types.string) })) },
      })
      assert_deep_eq(out, {
        ["$schema"] = "http://json-schema.org/draft-04/schema#",
        ["$ref"] = "#/definitions/User",
        id = "https://example.test/schema",
        definitions = {
          User = {
            type = "object",
            properties = { id = { type = "string" } },
            required = { "id" },
          },
        },
      })
    end)

    T.it("an empty definitions map is still emitted, unlike 2020-12's $defs", function()
      local out = js04.type_ref_to_json_schema_04_document(t(types.string), { definitions = {} })
      assert_deep_eq(out, {
        ["$schema"] = "http://json-schema.org/draft-04/schema#",
        type = "string",
        definitions = {},
      })
    end)

  end)

end)
