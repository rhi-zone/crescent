-- lib/fractal/type_ref_openapi_20_test.lua
-- Tests for lib/fractal/type_ref_openapi_20.lua: the TypeRef -> Swagger 2.0
-- Schema Object projector.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")
local oas20    = require("lib.fractal.type_ref_openapi_20")

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
local to    = oas20.type_ref_to_openapi_20

T.describe("lib.fractal.type_ref_openapi_20", function()

  T.describe("vendor extensions for what Swagger 2.0 dropped", function()

    T.it("nullable becomes x-nullable", function()
      assert_deep_eq(to(t(types.string, { nullable = true })), {
        type = "string",
        ["x-nullable"] = true,
      })
    end)

    T.it("null and void are typeless x-nullable schemas", function()
      assert_deep_eq(to(t(types.null)), { ["x-nullable"] = true })
      assert_deep_eq(to(t(types.void)), { ["x-nullable"] = true })
    end)

    T.it("never is x-never — there is no not keyword", function()
      local out = to(t(types.never))
      assert_deep_eq(out, { ["x-never"] = true })
      T.eq((out --[[: { [string]: unknown }]])["not"], nil)
    end)

    T.it("deprecated becomes x-deprecated", function()
      assert_deep_eq(to(t(types.string, { deprecated = true })), {
        type = "string",
        ["x-deprecated"] = true,
      })
    end)

    T.it("a union carries its variants in x-oneOf and constrains nothing else", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape)), {
        ["x-oneOf"] = { { type = "string" }, { type = "number" } },
      })
    end)

    T.it("a discriminator is a bare string, not a Discriminator Object", function()
      local shape = types.union({ t(types.string), t(types.number) })
      assert_deep_eq(to(t(shape, { discriminator = "kind" })), {
        ["x-oneOf"] = { { type = "string" }, { type = "number" } },
        discriminator = "kind",
      })
    end)

    T.it("callables and interfaces degrade to vendor extensions", function()
      assert_deep_eq(to(t(types.function_({}, t(types.string)))), { ["x-function"] = true })
      assert_deep_eq(to(t(types.method({}, t(types.string)))), { ["x-method"] = true })
      assert_deep_eq(to(t(types.interface({}))), { type = "object", ["x-interface"] = true })
    end)

    T.it("stream degrades to an array carrying x-stream", function()
      assert_deep_eq(to(t(types.stream(t(types.string)))), {
        type = "array",
        items = { type = "string" },
        ["x-stream"] = true,
      })
    end)

    T.it("writeOnly is dropped, since no vendor convention exists for it", function()
      assert_deep_eq(to(t(types.string, { writeOnly = true })), { type = "string" })
    end)

    T.it("instance and page have no handler and project to the empty schema", function()
      assert_deep_eq(to(t(types.instance("User", "src/user.ts"))), {})
      assert_deep_eq(to(t(types.page(t(types.string), "cursor"))), {})
    end)

  end)

  T.describe("tuples", function()

    T.it("a homogeneous tuple uses its common element schema as items", function()
      assert_deep_eq(to(t(types.tuple({ t(types.string), t(types.string) }))), {
        type = "array",
        items = { type = "string" },
      })
    end)

    T.it("a mixed tuple falls back to the empty items schema", function()
      assert_deep_eq(to(t(types.tuple({ t(types.string), t(types.number) }))), {
        type = "array",
        items = {},
      })
    end)

    T.it("an empty tuple falls back to the empty items schema", function()
      assert_deep_eq(to(t(types.tuple({}))), { type = "array", items = {} })
    end)

    T.it("sameness is structural, not by reference", function()
      -- Two separately-built TypeRefs projecting to the same schema still count
      -- as homogeneous.
      local shape = types.tuple({ t(types.array(t(types.string))), t(types.array(t(types.string))) })
      assert_deep_eq(to(t(shape)), {
        type = "array",
        items = { type = "array", items = { type = "string" } },
      })
    end)

  end)

  T.describe("shared behaviour", function()

    T.it("primitives and refinements project to type plus format", function()
      assert_deep_eq(to(t(types.boolean)), { type = "boolean" })
      assert_deep_eq(to(t(types.unknown)), {})
      assert_deep_eq(to(t({ kind = "int64" })), { type = "integer", format = "int64" })
      assert_deep_eq(to(t({ kind = "bytes" })), { type = "string", format = "byte" })
      assert_deep_eq(to(t({ kind = "duration" })), { type = "string" })
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

    T.it("intersection keeps allOf, the one combinator Swagger 2.0 retained", function()
      assert_deep_eq(to(t(types.intersection({ t(types.string), t(types.number) }))), {
        allOf = { { type = "string" }, { type = "number" } },
      })
    end)

    T.it("a literal is a single-member enum, and enum is always type string", function()
      assert_deep_eq(to(t(types.literal("draft"))), { enum = { "draft" } })
      assert_deep_eq(to(t(types.enum({ "a", "b" }))), { type = "string", enum = { "a", "b" } })
    end)

    T.it("ref points into the top-level definitions map", function()
      assert_deep_eq(to(t(types.ref("User"))), { ["$ref"] = "#/definitions/User" })
    end)

    T.it("exclusive bounds are boolean modifiers on minimum/maximum", function()
      assert_deep_eq(to(t(types.number, { minimum = 0, exclusiveMaximum = 10 })), {
        type = "number",
        minimum = 0,
        maximum = 10,
        exclusiveMaximum = true,
      })
    end)

    T.it("description, default and the singular example pass through", function()
      assert_deep_eq(to(t(types.string, { description = "d", default = "x", example = "y" })), {
        type = "string",
        description = "d",
        default = "x",
        example = "y",
      })
    end)

    T.it("a registered child falls back to its nearest handled ancestor", function()
      type_ref.register_parent("oas20_int128", "integer")
      assert_deep_eq(to(t({ kind = "oas20_int128" })), { type = "integer" })
      type_ref.register_parent("oas20_int128", nil)
    end)

  end)

  T.describe("type_refs_to_openapi_20_definitions", function()

    T.it("an empty map yields an empty definitions map", function()
      assert_deep_eq(oas20.type_refs_to_openapi_20_definitions({}), {})
    end)

    T.it("each named ref becomes one definitions entry", function()
      local out = oas20.type_refs_to_openapi_20_definitions({
        User = t(types.object({ id = t(types.string) })),
        Tag = t(types.string),
      })
      assert_deep_eq(out, {
        User = {
          type = "object",
          properties = { id = { type = "string" } },
          required = { "id" },
        },
        Tag = { type = "string" },
      })
    end)

  end)

end)
