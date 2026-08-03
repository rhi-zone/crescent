-- lib/fractal/type_ref_json_schema_test.lua
-- Tests for lib/fractal/type_ref_json_schema.lua: the TypeRef -> JSON Schema
-- draft 2020-12 projector.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")
local js       = require("lib.fractal.type_ref_json_schema")
local null     = require("lib.null")

-- Deep structural equality for plain tables (T.eq is reference/value `==`,
-- which is not useful for comparing projected schemas).
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
local to    = js.type_ref_to_json_schema

T.describe("lib.fractal.type_ref_json_schema", function()

  T.describe("leaf kinds", function()

    T.it("primitives project to their type keyword", function()
      assert_deep_eq(to(t(types.boolean)), { type = "boolean" })
      assert_deep_eq(to(t(types.number)), { type = "number" })
      assert_deep_eq(to(t(types.integer)), { type = "integer" })
      assert_deep_eq(to(t(types.string)), { type = "string" })
    end)

    T.it("null and void both project to type null", function()
      assert_deep_eq(to(t(types.null)), { type = "null" })
      assert_deep_eq(to(t(types.void)), { type = "null" })
    end)

    T.it("unknown projects to the empty schema", function()
      assert_deep_eq(to(t(types.unknown)), {})
    end)

    T.it("never projects to not:{} — draft 2020-12 has boolean schemas but the source uses not", function()
      assert_deep_eq(to(t(types.never)), { ["not"] = {} })
    end)

    T.it("refinement kinds carry a format", function()
      assert_deep_eq(to(t({ kind = "uuid" })), { type = "string", format = "uuid" })
      assert_deep_eq(to(t({ kind = "datetime" })), { type = "string", format = "date-time" })
      assert_deep_eq(to(t({ kind = "int32" })), { type = "integer", format = "int32" })
      assert_deep_eq(to(t({ kind = "float64" })), { type = "number", format = "double" })
      assert_deep_eq(to(t({ kind = "bytes" })), { type = "string", contentEncoding = "base64" })
    end)

    T.it("leaf schemas are not shared-table-corrupted by meta decoration", function()
      -- The `leaf` converters return one constant table per kind; `with_meta`
      -- must copy rather than mutate, or the second projection would inherit
      -- the first's description.
      local decorated = to(t(types.string, { description = "d" }))
      assert_deep_eq(decorated, { type = "string", description = "d" })
      assert_deep_eq(to(t(types.string)), { type = "string" })
    end)

  end)

  T.describe("composite kinds", function()

    T.it("object lists non-optional fields in required", function()
      local shape = types.object({
        id = t(types.string),
        note = t(types.string, { optional = true }),
      })
      local out = to(t(shape))
      assert_deep_eq(out.properties, { id = { type = "string" }, note = { type = "string" } })
      assert_deep_eq(out.required, { "id" })
      T.eq(out.type, "object")
    end)

    T.it("an all-optional object omits required entirely", function()
      local shape = types.object({ a = t(types.string, { optional = true }) })
      T.eq(to(t(shape)).required, nil)
    end)

    T.it("a field's meta.readonly becomes readOnly on the property schema", function()
      local shape = types.object({ id = t(types.string, { readonly = true }) })
      assert_deep_eq(to(t(shape)).properties, { id = { type = "string", readOnly = true } })
    end)

    T.it("array projects items", function()
      assert_deep_eq(to(t(types.array(t(types.string)))), {
        type = "array",
        items = { type = "string" },
      })
    end)

    T.it("tuple uses prefixItems and forbids extras", function()
      local shape = types.tuple({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), {
        type = "array",
        prefixItems = { { type = "string" }, { type = "number" } },
        items = false,
      })
    end)

    T.it("map projects its value type as additionalProperties", function()
      assert_deep_eq(to(t(types.map(t(types.string), t(types.number)))), {
        type = "object",
        additionalProperties = { type = "number" },
      })
    end)

    T.it("stream degrades to an array carrying x-stream", function()
      assert_deep_eq(to(t(types.stream(t(types.string)))), {
        type = "array",
        items = { type = "string" },
        ["x-stream"] = true,
      })
    end)

    T.it("page degrades to an array carrying x-page-style", function()
      assert_deep_eq(to(t(types.page(t(types.string), "cursor"))), {
        type = "array",
        items = { type = "string" },
        ["x-page-style"] = "cursor",
      })
    end)

    T.it("instance carries class identity as vendor extensions", function()
      assert_deep_eq(to(t(types.instance("User", "src/user.ts"))), {
        type = "object",
        ["x-class-name"] = "User",
        ["x-declaration-file"] = "src/user.ts",
      })
    end)

    T.it("an instance with no declaration file omits x-declaration-file", function()
      assert_deep_eq(to(t(types.instance("User", ""))), {
        type = "object",
        ["x-class-name"] = "User",
      })
    end)

    T.it("union without a discriminator is anyOf", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), { anyOf = { { type = "string" }, { type = "number" } } })
    end)

    T.it("union with meta.discriminator is oneOf plus a Discriminator Object", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape, { discriminator = "kind" })), {
        oneOf = { { type = "string" }, { type = "number" } },
        discriminator = { propertyName = "kind" },
      })
    end)

    T.it("intersection is allOf", function()
      local shape = types.intersection({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), { allOf = { { type = "string" }, { type = "number" } } })
    end)

    T.it("ref points into $defs", function()
      assert_deep_eq(to(t(types.ref("User"))), { ["$ref"] = "#/$defs/User" })
    end)

    T.it("callables and interfaces degrade to vendor extensions", function()
      assert_deep_eq(to(t(types.function_({}, t(types.string)))), { ["x-function"] = true })
      assert_deep_eq(to(t(types.method({}, t(types.string)))), { ["x-method"] = true })
      assert_deep_eq(to(t(types.interface({}))), { type = "object", ["x-interface"] = true })
    end)

  end)

  T.describe("literal and enum", function()

    T.it("a literal projects to const", function()
      assert_deep_eq(to(t(types.literal("draft"))), { const = "draft" })
      assert_deep_eq(to(t(types.literal(7))), { const = 7 })
    end)

    T.it("a null literal keeps the shared sentinel, not an absent key", function()
      local out = to(t(types.literal(null.null)))
      T.eq(out.const, null.null)
    end)

    T.it("string members infer type string", function()
      assert_deep_eq(to(t(types.enum({ "a", "b" }))), { type = "string", enum = { "a", "b" } })
    end)

    -- type_ref.lua's `EnumShape` declares `members: string[]`, but a converter
    -- receives the open `TypeShape` — an importer building an enum from a
    -- source type system can carry integer or boolean members. These cases
    -- build the shape literally rather than through `types.enum`, which is
    -- exactly how such a shape reaches the projector.

    T.it("whole-number members infer type integer", function()
      assert_deep_eq(to(t({ kind = "enum", members = { 1, 2 } })), { type = "integer", enum = { 1, 2 } })
    end)

    T.it("fractional members infer type number", function()
      assert_deep_eq(to(t({ kind = "enum", members = { 1.5, 2 } })), { type = "number", enum = { 1.5, 2 } })
    end)

    T.it("boolean members infer type boolean", function()
      assert_deep_eq(to(t({ kind = "enum", members = { true, false } })), {
        type = "boolean",
        enum = { true, false },
      })
    end)

    T.it("mixed members omit type and rely on enum alone", function()
      assert_deep_eq(to(t({ kind = "enum", members = { "a", 1 } })), { enum = { "a", 1 } })
    end)

    T.it("an empty enum omits type", function()
      assert_deep_eq(to(t(types.enum({}))), { enum = {} })
    end)

  end)

  T.describe("meta", function()

    T.it("nullable on a scalar widens its type keyword", function()
      assert_deep_eq(to(t(types.string, { nullable = true })), { type = { "string", "null" } })
    end)

    T.it("nullable on a complex kind wraps in anyOf", function()
      local out = to(t(types.array(t(types.string)), { nullable = true }))
      assert_deep_eq(out, {
        anyOf = { { type = "array", items = { type = "string" } }, { type = "null" } },
      })
    end)

    T.it("nullable on a typeless schema wraps in anyOf", function()
      assert_deep_eq(to(t(types.unknown, { nullable = true })), { anyOf = { {}, { type = "null" } } })
    end)

    T.it("annotations pass through", function()
      local out = to(t(types.string, {
        title = "Name",
        description = "the name",
        deprecated = true,
        default = "x",
      }))
      assert_deep_eq(out, {
        type = "string",
        title = "Name",
        description = "the name",
        deprecated = true,
        default = "x",
      })
    end)

    T.it("a null default survives as the shared sentinel", function()
      T.eq(to(t(types.string, { default = null.null })).default, null.null)
    end)

    T.it("examples pass through only as a list", function()
      assert_deep_eq(to(t(types.string, { examples = { "a", "b" } })), {
        type = "string",
        examples = { "a", "b" },
      })
      assert_deep_eq(to(t(types.string, { examples = "a" })), { type = "string" })
    end)

    T.it("numeric bounds use the standalone numeric exclusive form", function()
      assert_deep_eq(to(t(types.number, { minimum = 0, exclusiveMaximum = 10 })), {
        type = "number",
        minimum = 0,
        exclusiveMaximum = 10,
      })
    end)

    T.it("non-boolean deprecated is ignored", function()
      assert_deep_eq(to(t(types.string, { deprecated = "yes" })), { type = "string" })
    end)

  end)

  T.describe("kind lattice fallback", function()

    T.it("an unregistered kind with no ancestors projects to the empty schema", function()
      assert_deep_eq(to(t({ kind = "js_unheard_of_kind" })), {})
    end)

    T.it("a registered child falls back to its nearest handled ancestor", function()
      type_ref.register_parent("js_int128", "integer")
      assert_deep_eq(to(t({ kind = "js_int128" })), { type = "integer" })
      type_ref.register_parent("js_int128", nil)
    end)

  end)

  T.describe("nested structures", function()

    T.it("an object of arrays of refs projects all the way down", function()
      local shape = types.object({
        owners = t(types.array(t(types.ref("User")))),
      })
      assert_deep_eq(to(t(shape)), {
        type = "object",
        properties = {
          owners = { type = "array", items = { ["$ref"] = "#/$defs/User" } },
        },
        required = { "owners" },
      })
    end)

  end)

  T.describe("type_ref_document_to_json_schema", function()

    T.it("a document with no defs omits $defs", function()
      local doc = type_ref.type_ref_document(t(types.string))
      assert_deep_eq(js.type_ref_document_to_json_schema(doc), { type = "string" })
    end)

    T.it("defs become $defs entries the root's refs resolve against", function()
      local doc = type_ref.type_ref_document(
        t(types.ref("User")),
        { User = t(types.object({ id = t(types.string) })) }
      )
      assert_deep_eq(js.type_ref_document_to_json_schema(doc), {
        ["$ref"] = "#/$defs/User",
        ["$defs"] = {
          User = {
            type = "object",
            properties = { id = { type = "string" } },
            required = { "id" },
          },
        },
      })
    end)

    T.it("a recursive def terminates", function()
      local node = t(types.object({ next = t(types.ref("Node"), { optional = true }) }))
      local doc = type_ref.type_ref_document(t(types.ref("Node")), { Node = node })
      assert_deep_eq(js.type_ref_document_to_json_schema(doc), {
        ["$ref"] = "#/$defs/Node",
        ["$defs"] = {
          Node = {
            type = "object",
            properties = { next = { ["$ref"] = "#/$defs/Node" } },
          },
        },
      })
    end)

  end)

end)
