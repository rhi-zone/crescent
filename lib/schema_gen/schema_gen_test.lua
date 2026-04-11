if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local M = require("lib.schema_gen")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function is_integer(v)
  return type(v) == "number" and math.floor(v) == v and v == v
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function set_eq(a, b)
  -- compare two arrays as sets (unordered)
  if #a ~= #b then return false end
  local seen = {}
  for _, v in ipairs(b) do seen[v] = (seen[v] or 0) + 1 end
  for _, v in ipairs(a) do
    if not seen[v] or seen[v] == 0 then return false end
    seen[v] = seen[v] - 1
  end
  return true
end

-- ---------------------------------------------------------------------------
-- infer — primitives
-- ---------------------------------------------------------------------------

T.describe("infer primitives", function()
  T.it("nil -> null", function()
    local s = M.infer(nil)
    T.eq(s.type, "null")
  end)

  T.it("boolean true -> boolean", function()
    local s = M.infer(true)
    T.eq(s.type, "boolean")
  end)

  T.it("boolean false -> boolean", function()
    local s = M.infer(false)
    T.eq(s.type, "boolean")
  end)

  T.it("integer -> integer", function()
    local s = M.infer(42)
    T.eq(s.type, "integer")
  end)

  T.it("0 -> integer", function()
    local s = M.infer(0)
    T.eq(s.type, "integer")
  end)

  T.it("negative integer -> integer", function()
    local s = M.infer(-7)
    T.eq(s.type, "integer")
  end)

  T.it("float -> number", function()
    local s = M.infer(3.14)
    T.eq(s.type, "number")
  end)

  T.it("string -> string", function()
    local s = M.infer("hello")
    T.eq(s.type, "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- infer — array
-- ---------------------------------------------------------------------------

T.describe("infer array", function()
  T.it("uniform integer array", function()
    local s = M.infer({1, 2, 3})
    T.eq(s.type, "array")
    T.eq(s.items.type, "integer")
  end)

  T.it("uniform string array", function()
    local s = M.infer({"a", "b", "c"})
    T.eq(s.type, "array")
    T.eq(s.items.type, "string")
  end)

  T.it("mixed integer+string array -> oneOf items", function()
    local s = M.infer({1, "a"})
    T.eq(s.type, "array")
    T.ok(s.items.oneOf, "items should have oneOf")
    T.eq(#s.items.oneOf, 2)
  end)

  T.it("single-element array", function()
    local s = M.infer({99})
    T.eq(s.type, "array")
    T.eq(s.items.type, "integer")
  end)
end)

-- ---------------------------------------------------------------------------
-- infer — object
-- ---------------------------------------------------------------------------

T.describe("infer object", function()
  T.it("flat object", function()
    local s = M.infer({ name = "Alice", age = 30 })
    T.eq(s.type, "object")
    T.eq(s.properties.name.type, "string")
    T.eq(s.properties.age.type, "integer")
    T.ok(set_eq(s.required, {"name", "age"}), "required should contain name and age")
  end)

  T.it("nested object", function()
    local s = M.infer({ user = { id = 1, email = "a@b.com" } })
    T.eq(s.type, "object")
    T.eq(s.properties.user.type, "object")
    T.eq(s.properties.user.properties.id.type, "integer")
    T.eq(s.properties.user.properties.email.type, "string")
  end)

  T.it("empty table -> empty object", function()
    local s = M.infer({})
    T.eq(s.type, "object")
    T.eq(#s.required, 0)
  end)

  T.it("required is sorted", function()
    local s = M.infer({ z = 1, a = 2, m = 3 })
    T.eq(s.required[1], "a")
    T.eq(s.required[2], "m")
    T.eq(s.required[3], "z")
  end)
end)

-- ---------------------------------------------------------------------------
-- infer_many — merging
-- ---------------------------------------------------------------------------

T.describe("infer_many", function()
  T.it("single sample returns infer(sample)", function()
    local s = M.infer_many({42})
    T.eq(s.type, "integer")
  end)

  T.it("all same primitive type", function()
    local s = M.infer_many({1, 2, 3})
    T.eq(s.type, "integer")
  end)

  T.it("mixed primitive types -> oneOf", function()
    local s = M.infer_many({1, "hello"})
    T.ok(s.oneOf, "should have oneOf")
    T.eq(#s.oneOf, 2)
  end)

  T.it("objects: required = keys in ALL samples", function()
    local s = M.infer_many({
      { name = "Alice", age = 30 },
      { name = "Bob" },
    })
    T.eq(s.type, "object")
    -- "name" in both → required; "age" only in first → not required
    T.ok(set_eq(s.required, {"name"}), "only 'name' should be required")
    -- but "age" still present in properties
    T.ok(s.properties.age ~= nil, "age should still be in properties")
    T.ok(s.properties.name ~= nil, "name should be in properties")
  end)

  T.it("objects: all keys present in all samples → all required", function()
    local s = M.infer_many({
      { x = 1, y = 2 },
      { x = 3, y = 4 },
    })
    T.ok(set_eq(s.required, {"x", "y"}), "both x and y should be required")
  end)

  T.it("arrays: item schemas merged", function()
    local s = M.infer_many({{1, 2}, {3, 4}})
    T.eq(s.type, "array")
    T.eq(s.items.type, "integer")
  end)

  T.it("empty samples -> null", function()
    local s = M.infer_many({})
    T.eq(s.type, "null")
  end)
end)

-- ---------------------------------------------------------------------------
-- generate — primitives
-- ---------------------------------------------------------------------------

T.describe("generate primitives", function()
  T.it("null schema -> nil", function()
    local v = M.generate({ type = "null" })
    T.eq(v, nil)
  end)

  T.it("boolean schema -> boolean", function()
    local v = M.generate({ type = "boolean" })
    T.eq(type(v), "boolean")
  end)

  T.it("integer schema -> integer", function()
    local v = M.generate({ type = "integer" })
    T.ok(is_integer(v), "should be integer")
  end)

  T.it("number schema -> number", function()
    local v = M.generate({ type = "number" })
    T.eq(type(v), "number")
  end)

  T.it("string schema -> string", function()
    local v = M.generate({ type = "string" })
    T.eq(type(v), "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- generate — constraints
-- ---------------------------------------------------------------------------

T.describe("generate with constraints", function()
  T.it("integer with minimum", function()
    local v = M.generate({ type = "integer", minimum = 100 })
    T.ok(v >= 100, "should respect minimum")
  end)

  T.it("string with minLength", function()
    local v = M.generate({ type = "string", minLength = 5 })
    T.ok(#v >= 5, "should respect minLength")
  end)

  T.it("string with maxLength", function()
    local v = M.generate({ type = "string", maxLength = 3 })
    T.ok(#v <= 3, "should respect maxLength")
  end)

  T.it("array with minItems", function()
    local v = M.generate({ type = "array", items = { type = "integer" }, minItems = 3 })
    T.ok(#v >= 3, "should have at least minItems")
  end)

  T.it("array items are correct type", function()
    local v = M.generate({ type = "array", items = { type = "string" }, minItems = 2 })
    for i, item in ipairs(v) do
      T.eq(type(item), "string")
    end
  end)

  T.it("enum -> first value", function()
    local v = M.generate({ ["enum"] = {"a", "b", "c"} })
    T.eq(v, "a")
  end)
end)

-- ---------------------------------------------------------------------------
-- generate — object
-- ---------------------------------------------------------------------------

T.describe("generate object", function()
  T.it("required properties are populated", function()
    local v = M.generate({
      type = "object",
      properties = { x = { type = "integer" }, y = { type = "string" } },
      required = { "x", "y" },
    })
    T.ok(v ~= nil, "should return a table")
    T.ok(is_integer(v.x), "x should be integer")
    T.eq(type(v.y), "string")
  end)

  T.it("nested object generation", function()
    local v = M.generate({
      type = "object",
      properties = {
        user = {
          type = "object",
          properties = { id = { type = "integer" } },
          required = { "id" },
        },
      },
      required = { "user" },
    })
    T.ok(v.user ~= nil, "user should be generated")
    T.ok(is_integer(v.user.id), "user.id should be integer")
  end)
end)

-- ---------------------------------------------------------------------------
-- generate_many
-- ---------------------------------------------------------------------------

T.describe("generate_many", function()
  T.it("returns n values", function()
    local vs = M.generate_many({ type = "integer" }, 5)
    T.eq(#vs, 5)
  end)

  T.it("all values have correct type", function()
    local vs = M.generate_many({ type = "string" }, 3)
    for _, v in ipairs(vs) do
      T.eq(type(v), "string")
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- validate — passing cases
-- ---------------------------------------------------------------------------

T.describe("validate passing", function()
  T.it("null matches null", function()
    local ok = M.validate({ type = "null" }, nil)
    T.ok(ok)
  end)

  T.it("boolean matches boolean", function()
    local ok = M.validate({ type = "boolean" }, true)
    T.ok(ok)
  end)

  T.it("integer matches integer", function()
    local ok = M.validate({ type = "integer" }, 42)
    T.ok(ok)
  end)

  T.it("number matches float", function()
    local ok = M.validate({ type = "number" }, 3.14)
    T.ok(ok)
  end)

  T.it("string matches string", function()
    local ok = M.validate({ type = "string" }, "hello")
    T.ok(ok)
  end)

  T.it("array items validated", function()
    local ok = M.validate({ type = "array", items = { type = "integer" } }, {1, 2, 3})
    T.ok(ok)
  end)

  T.it("object with required fields", function()
    local ok = M.validate({
      type = "object",
      properties = { name = { type = "string" } },
      required = { "name" },
    }, { name = "Alice" })
    T.ok(ok)
  end)

  T.it("enum value present", function()
    local ok = M.validate({ ["enum"] = {"a", "b", "c"} }, "b")
    T.ok(ok)
  end)

  T.it("minLength satisfied", function()
    local ok = M.validate({ type = "string", minLength = 3 }, "abc")
    T.ok(ok)
  end)

  T.it("maximum satisfied", function()
    local ok = M.validate({ type = "integer", maximum = 100 }, 50)
    T.ok(ok)
  end)

  T.it("minItems satisfied", function()
    local ok = M.validate({ type = "array", minItems = 2 }, {1, 2, 3})
    T.ok(ok)
  end)

  T.it("oneOf matches at least one", function()
    local ok = M.validate({ oneOf = {{ type = "integer" }, { type = "string" }} }, 42)
    T.ok(ok)
  end)

  T.it("anyOf matches at least one", function()
    local ok = M.validate({ anyOf = {{ type = "integer" }, { type = "string" }} }, "hi")
    T.ok(ok)
  end)

  T.it("allOf all match", function()
    local ok = M.validate({ allOf = {{ type = "integer" }, { type = "number" }} }, 5)
    T.ok(ok)
  end)
end)

-- ---------------------------------------------------------------------------
-- validate — failing cases
-- ---------------------------------------------------------------------------

T.describe("validate failing", function()
  T.it("wrong type: string for integer", function()
    local ok, err = M.validate({ type = "integer" }, "hello")
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("wrong type: number for boolean", function()
    local ok, err = M.validate({ type = "boolean" }, 1)
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("float fails integer check", function()
    local ok, err = M.validate({ type = "integer" }, 3.14)
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("missing required field", function()
    local ok, err = M.validate({
      type = "object",
      properties = { name = { type = "string" } },
      required = { "name" },
    }, {})
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("enum value not present", function()
    local ok, err = M.validate({ ["enum"] = {"a", "b"} }, "c")
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("minLength violated", function()
    local ok, err = M.validate({ type = "string", minLength = 5 }, "ab")
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("maxLength violated", function()
    local ok, err = M.validate({ type = "string", maxLength = 2 }, "hello")
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("minimum violated", function()
    local ok, err = M.validate({ type = "integer", minimum = 10 }, 5)
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("maximum violated", function()
    local ok, err = M.validate({ type = "integer", maximum = 10 }, 20)
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("minItems violated", function()
    local ok, err = M.validate({ type = "array", minItems = 3 }, {1, 2})
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("maxItems violated", function()
    local ok, err = M.validate({ type = "array", maxItems = 2 }, {1, 2, 3})
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("array item type mismatch", function()
    local ok, err = M.validate({ type = "array", items = { type = "integer" } }, {1, "oops", 3})
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("oneOf: no match", function()
    local ok, err = M.validate({ oneOf = {{ type = "integer" }, { type = "boolean" }} }, "text")
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)

  T.it("nested object property type mismatch", function()
    local ok, err = M.validate({
      type = "object",
      properties = { count = { type = "integer" } },
      required = { "count" },
    }, { count = "not-a-number" })
    T.eq(ok, false)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- DSL helpers
-- ---------------------------------------------------------------------------

T.describe("DSL helpers", function()
  T.it("M.string() produces string schema", function()
    local s = M.string()
    T.eq(s.type, "string")
  end)

  T.it("M.string(opts) merges opts", function()
    local s = M.string({ minLength = 3 })
    T.eq(s.type, "string")
    T.eq(s.minLength, 3)
  end)

  T.it("M.number() produces number schema", function()
    T.eq(M.number().type, "number")
  end)

  T.it("M.integer() produces integer schema", function()
    T.eq(M.integer().type, "integer")
  end)

  T.it("M.boolean() produces boolean schema", function()
    T.eq(M.boolean().type, "boolean")
  end)

  T.it("M.null() produces null schema", function()
    T.eq(M.null().type, "null")
  end)

  T.it("M.array(items) produces array schema", function()
    local s = M.array(M.integer())
    T.eq(s.type, "array")
    T.eq(s.items.type, "integer")
  end)

  T.it("M.array(items, opts) merges opts", function()
    local s = M.array(M.integer(), { minItems = 2 })
    T.eq(s.minItems, 2)
  end)

  T.it("M.object(props, req) produces object schema", function()
    local s = M.object({ name = M.string() }, { "name" })
    T.eq(s.type, "object")
    T.eq(s.properties.name.type, "string")
    T.eq(s.required[1], "name")
  end)

  T.it("M.object without required defaults to all keys", function()
    local s = M.object({ x = M.integer(), y = M.string() })
    T.ok(set_eq(s.required, {"x", "y"}), "should require both x and y")
  end)

  T.it("M.enum produces enum schema", function()
    local s = M.enum({"a", "b", "c"})
    T.eq(s["enum"][1], "a")
    T.eq(s["enum"][2], "b")
  end)

  T.it("M.one_of produces oneOf schema", function()
    local s = M.one_of({ M.integer(), M.string() })
    T.ok(s.oneOf ~= nil)
    T.eq(#s.oneOf, 2)
  end)

  T.it("M.any_of produces anyOf schema", function()
    local s = M.any_of({ M.integer(), M.string() })
    T.ok(s.anyOf ~= nil)
    T.eq(#s.anyOf, 2)
  end)

  T.it("M.all_of produces allOf schema", function()
    local s = M.all_of({ M.integer(), M.number() })
    T.ok(s.allOf ~= nil)
    T.eq(#s.allOf, 2)
  end)

  T.it("M.nullable wraps with oneOf null", function()
    local s = M.nullable(M.string())
    T.ok(s.oneOf ~= nil)
    T.eq(#s.oneOf, 2)
    -- one branch is string, other is null
    local has_string = false
    local has_null = false
    for _, sub in ipairs(s.oneOf) do
      if sub.type == "string" then has_string = true end
      if sub.type == "null" then has_null = true end
    end
    T.ok(has_string, "nullable should contain string schema")
    T.ok(has_null, "nullable should contain null schema")
  end)

  T.it("M.ref produces $ref schema", function()
    local s = M.ref("User")
    T.eq(s["$ref"], "#/definitions/User")
  end)

  T.it("M._tier is pure", function()
    T.eq(M._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- round-trip: infer -> validate
-- ---------------------------------------------------------------------------

T.describe("round-trip infer->validate", function()
  T.it("inferred integer schema validates original", function()
    local v = 42
    local s = M.infer(v)
    local ok = M.validate(s, v)
    T.ok(ok)
  end)

  T.it("inferred string schema validates original", function()
    local v = "hello"
    local ok = M.validate(M.infer(v), v)
    T.ok(ok)
  end)

  T.it("inferred object schema validates original", function()
    local v = { name = "Alice", age = 30 }
    local ok = M.validate(M.infer(v), v)
    T.ok(ok)
  end)

  T.it("inferred array schema validates original", function()
    local v = {1, 2, 3}
    local ok = M.validate(M.infer(v), v)
    T.ok(ok)
  end)

  T.it("generate -> validate round-trip for object", function()
    local schema = M.object({
      id = M.integer(),
      label = M.string(),
    }, {"id", "label"})
    local v = M.generate(schema)
    local ok, err = M.validate(schema, v)
    T.ok(ok, err)
  end)
end)
