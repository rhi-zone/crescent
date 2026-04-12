if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local z = require("lib.schema_validator")

-- ---------------------------------------------------------------------------
-- String
-- ---------------------------------------------------------------------------

T.describe("string", function()
  T.it("accepts valid string", function()
    local v, err = z.string():parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("rejects non-string", function()
    local v, err = z.string():parse(42)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(#err.issues > 0)
  end)

  T.it("min: passes when long enough", function()
    local v, err = z.string().min(3):parse("abc")
    T.eq(v, "abc")
    T.eq(err, nil)
  end)

  T.it("min: fails when too short", function()
    local v, err = z.string().min(3):parse("ab")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too short"))
  end)

  T.it("max: passes when short enough", function()
    local v, err = z.string().max(5):parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("max: fails when too long", function()
    local v, err = z.string().max(3):parse("toolong")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too long"))
  end)

  T.it("pattern: passes when matches", function()
    local v, err = z.string().pattern("^%a+$"):parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("pattern: fails when no match", function()
    local v, err = z.string().pattern("^%a+$"):parse("hello123")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("pattern"))
  end)

  T.it("chained min+max", function()
    local s = z.string().min(2).max(10)
    local v1, e1 = s:parse("hi")
    T.eq(v1, "hi")
    T.eq(e1, nil)
    local v2, e2 = s:parse("x")
    T.eq(v2, nil)
    T.ok(e2 ~= nil)
  end)

  T.it("trim transform", function()
    local v, err = z.string().trim():parse("  hello  ")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("email: valid", function()
    local v, err = z.string().email():parse("user@example.com")
    T.eq(v, "user@example.com")
    T.eq(err, nil)
  end)

  T.it("email: invalid", function()
    local v, err = z.string().email():parse("notanemail")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("url: valid", function()
    local v, err = z.string().url():parse("https://example.com")
    T.eq(v, "https://example.com")
    T.eq(err, nil)
  end)

  T.it("url: invalid", function()
    local v, err = z.string().url():parse("ftp://example.com")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Number
-- ---------------------------------------------------------------------------

T.describe("number", function()
  T.it("accepts valid number", function()
    local v, err = z.number():parse(42)
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("rejects non-number", function()
    local v, err = z.number():parse("42")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("min: passes", function()
    local v, err = z.number().min(0):parse(5)
    T.eq(v, 5)
    T.eq(err, nil)
  end)

  T.it("min: fails", function()
    local v, err = z.number().min(0):parse(-1)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too small"))
  end)

  T.it("max: passes", function()
    local v, err = z.number().max(100):parse(50)
    T.eq(v, 50)
    T.eq(err, nil)
  end)

  T.it("max: fails", function()
    local v, err = z.number().max(100):parse(101)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too large"))
  end)

  T.it("integer: passes for whole number", function()
    local v, err = z.number().integer():parse(7)
    T.eq(v, 7)
    T.eq(err, nil)
  end)

  T.it("integer: fails for float", function()
    local v, err = z.number().integer():parse(7.5)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("integer"))
  end)

  T.it("positive: passes", function()
    local v, err = z.number().positive():parse(1)
    T.eq(v, 1)
    T.eq(err, nil)
  end)

  T.it("positive: fails for zero", function()
    local v, err = z.number().positive():parse(0)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("negative: passes", function()
    local v, err = z.number().negative():parse(-5)
    T.eq(v, -5)
    T.eq(err, nil)
  end)

  T.it("chained min+max+integer", function()
    local s = z.number().min(0).max(100).integer()
    local v, err = s:parse(50)
    T.eq(v, 50)
    T.eq(err, nil)
    local v2, err2 = s:parse(50.5)
    T.eq(v2, nil)
    T.ok(err2 ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Boolean
-- ---------------------------------------------------------------------------

T.describe("boolean", function()
  T.it("accepts true", function()
    local v, err = z.boolean():parse(true)
    T.eq(v, true)
    T.eq(err, nil)
  end)

  T.it("accepts false", function()
    local v, err = z.boolean():parse(false)
    T.eq(v, false)
    T.eq(err, nil)
  end)

  T.it("rejects nil", function()
    local v, err = z.boolean():parse(nil)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("rejects number", function()
    local v, err = z.boolean():parse(1)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Enum
-- ---------------------------------------------------------------------------

T.describe("enum", function()
  T.it("passes valid value", function()
    local v, err = z.enum({"red", "green", "blue"}):parse("green")
    T.eq(v, "green")
    T.eq(err, nil)
  end)

  T.it("rejects invalid value", function()
    local v, err = z.enum({"red", "green", "blue"}):parse("yellow")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("one of"))
  end)

  T.it("passes first value", function()
    local v, err = z.enum({"a", "b"}):parse("a")
    T.eq(v, "a")
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Literal
-- ---------------------------------------------------------------------------

T.describe("literal", function()
  T.it("passes exact match string", function()
    local v, err = z.literal("active"):parse("active")
    T.eq(v, "active")
    T.eq(err, nil)
  end)

  T.it("rejects different string", function()
    local v, err = z.literal("active"):parse("inactive")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("literal"))
  end)

  T.it("passes exact match number", function()
    local v, err = z.literal(42):parse(42)
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("rejects wrong number", function()
    local v, err = z.literal(42):parse(43)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Object
-- ---------------------------------------------------------------------------

T.describe("object", function()
  local UserSchema = z.object({
    name = z.string().min(1),
    age  = z.number().integer().min(0),
    role = z.enum({"admin", "user"}),
  })

  T.it("accepts valid object", function()
    local v, err = UserSchema:parse({name = "Alice", age = 30, role = "user"})
    T.eq(err, nil)
    T.eq(v.name, "Alice")
    T.eq(v.age, 30)
    T.eq(v.role, "user")
  end)

  T.it("missing required field produces error", function()
    local v, err = UserSchema:parse({name = "Alice", role = "user"})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(#err.issues > 0)
    -- Should report age issue
    local found = false
    for _, issue in ipairs(err.issues) do
      if issue.path == "age" then found = true end
    end
    T.ok(found, "expected age path in issues")
  end)

  T.it("rejects non-table", function()
    local v, err = UserSchema:parse("not an object")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("optional field: present", function()
    local s = z.object({ email = z.string().optional() })
    local v, err = s:parse({ email = "a@b.com" })
    T.eq(err, nil)
    T.eq(v.email, "a@b.com")
  end)

  T.it("optional field: absent ok", function()
    local s = z.object({ email = z.string().optional() })
    local v, err = s:parse({})
    T.eq(err, nil)
  end)

  T.it("strict: rejects unknown keys", function()
    local s = z.object({ name = z.string() }):strict()
    local v, err = s:parse({ name = "Alice", extra = "oops" })
    T.eq(v, nil)
    T.ok(err ~= nil)
    local found = false
    for _, issue in ipairs(err.issues) do
      if issue.path == "extra" then found = true end
    end
    T.ok(found, "expected extra key in issues")
  end)

  T.it("collects multiple errors", function()
    local v, err = UserSchema:parse({name = "", age = -1, role = "boss"})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(#err.issues >= 3, "expected at least 3 issues, got " .. #err.issues)
  end)

  T.it("nested object", function()
    local s = z.object({
      user = z.object({
        name = z.string(),
        score = z.number(),
      }),
    })
    local v, err = s:parse({ user = { name = "Bob", score = 99 } })
    T.eq(err, nil)
    T.eq(v.user.name, "Bob")
    T.eq(v.user.score, 99)
  end)

  T.it("nested object: error path includes parent", function()
    local s = z.object({
      meta = z.object({ created = z.number() }),
    })
    local v, err = s:parse({ meta = { created = "not-a-number" } })
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(err.issues[1].path, "meta.created")
  end)
end)

-- ---------------------------------------------------------------------------
-- Array
-- ---------------------------------------------------------------------------

T.describe("array", function()
  T.it("accepts valid array", function()
    local v, err = z.array(z.number()):parse({1, 2, 3})
    T.eq(err, nil)
    T.eq(#v, 3)
    T.eq(v[2], 2)
  end)

  T.it("rejects non-table", function()
    local v, err = z.array(z.number()):parse("nope")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("validates each item", function()
    local v, err = z.array(z.number()):parse({1, "two", 3})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(err.issues[1].path, "[2]")
  end)

  T.it("min: passes", function()
    local v, err = z.array(z.string()).min(2):parse({"a", "b"})
    T.eq(err, nil)
  end)

  T.it("min: fails", function()
    local v, err = z.array(z.string()).min(3):parse({"a", "b"})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too short"))
  end)

  T.it("max: passes", function()
    local v, err = z.array(z.string()).max(5):parse({"a", "b"})
    T.eq(err, nil)
  end)

  T.it("max: fails", function()
    local v, err = z.array(z.string()).max(2):parse({"a", "b", "c"})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("too long"))
  end)

  T.it("nonempty: fails on empty", function()
    local v, err = z.array(z.string()).nonempty():parse({})
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("nested array of objects", function()
    local s = z.array(z.object({ id = z.number() }))
    local v, err = s:parse({{id=1},{id=2}})
    T.eq(err, nil)
    T.eq(v[1].id, 1)
    T.eq(v[2].id, 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- Union
-- ---------------------------------------------------------------------------

T.describe("union", function()
  T.it("matches first valid schema", function()
    local s = z.union({z.string(), z.number()})
    local v, err = s:parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("matches second schema when first fails", function()
    local s = z.union({z.string(), z.number()})
    local v, err = s:parse(42)
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("fails when none match", function()
    local s = z.union({z.string(), z.number()})
    local v, err = s:parse(true)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.ok(err.issues[1].message:find("union"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Optional / nullable
-- ---------------------------------------------------------------------------

T.describe("optional", function()
  T.it("nil allowed", function()
    local v, err = z.string().optional():parse(nil)
    T.eq(v, nil)
    T.eq(err, nil)
  end)

  T.it("valid value still passes", function()
    local v, err = z.string().optional():parse("hi")
    T.eq(v, "hi")
    T.eq(err, nil)
  end)

  T.it("invalid value still fails", function()
    local v, err = z.string().optional():parse(42)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

T.describe("nullable", function()
  T.it("nil allowed", function()
    local v, err = z.string().nullable():parse(nil)
    T.eq(v, nil)
    T.eq(err, nil)
  end)

  T.it("valid value passes", function()
    local v, err = z.string().nullable():parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Default
-- ---------------------------------------------------------------------------

T.describe("default", function()
  T.it("nil input returns default", function()
    local v, err = z.string().default("anonymous"):parse(nil)
    T.eq(v, "anonymous")
    T.eq(err, nil)
  end)

  T.it("non-nil input ignores default", function()
    local v, err = z.string().default("anonymous"):parse("alice")
    T.eq(v, "alice")
    T.eq(err, nil)
  end)

  T.it("default with number", function()
    local v, err = z.number().default(0):parse(nil)
    T.eq(v, 0)
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Transform
-- ---------------------------------------------------------------------------

T.describe("transform", function()
  T.it("applied after validation", function()
    local s = z.string().transform(function(s) return s:upper() end)
    local v, err = s:parse("hello")
    T.eq(v, "HELLO")
    T.eq(err, nil)
  end)

  T.it("not applied on validation failure", function()
    local called = false
    local s = z.string().min(10).transform(function(s) called = true; return s end)
    local v, err = s:parse("hi")
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(called, false)
  end)

  T.it("chained transforms", function()
    local s = z.string()
      .transform(function(s) return s:upper() end)
      .transform(function(s) return s .. "!" end)
    local v, err = s:parse("hello")
    T.eq(v, "HELLO!")
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Refine
-- ---------------------------------------------------------------------------

T.describe("refine", function()
  T.it("passes when predicate is true", function()
    local s = z.number().integer().refine(function(n) return n % 2 == 0 end, "must be even")
    local v, err = s:parse(4)
    T.eq(v, 4)
    T.eq(err, nil)
  end)

  T.it("fails when predicate is false", function()
    local s = z.number().integer().refine(function(n) return n % 2 == 0 end, "must be even")
    local v, err = s:parse(3)
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(err.issues[1].message, "must be even")
  end)
end)

-- ---------------------------------------------------------------------------
-- safe_parse
-- ---------------------------------------------------------------------------

T.describe("safe_parse", function()
  T.it("returns success=true on valid input", function()
    local result = z.string():safe_parse("hello")
    T.eq(result.success, true)
    T.eq(result.data, "hello")
    T.eq(result.error, nil)
  end)

  T.it("returns success=false on invalid input", function()
    local result = z.string():safe_parse(42)
    T.eq(result.success, false)
    T.ok(result.error ~= nil)
    T.ok(#result.error.issues > 0)
    T.eq(result.data, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Multiple error collection
-- ---------------------------------------------------------------------------

T.describe("multiple errors collected", function()
  T.it("object collects errors from all fields", function()
    local s = z.object({
      a = z.string(),
      b = z.number(),
      c = z.boolean(),
    })
    local v, err = s:parse({ a = 1, b = "x", c = "y" })
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(#err.issues, 3)
  end)

  T.it("array collects errors from all items", function()
    local s = z.array(z.number())
    local v, err = s:parse({"a", "b", "c"})
    T.eq(v, nil)
    T.ok(err ~= nil)
    T.eq(#err.issues, 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- Coerce
-- ---------------------------------------------------------------------------

T.describe("coerce", function()
  T.it("coerce.number: string '42' -> 42", function()
    local v, err = z.coerce.number():parse("42")
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("coerce.number: invalid string -> error", function()
    local v, err = z.coerce.number():parse("abc")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("coerce.number: float string", function()
    local v, err = z.coerce.number():parse("3.14")
    T.eq(v, 3.14)
    T.eq(err, nil)
  end)

  T.it("coerce.string: number -> string", function()
    local v, err = z.coerce.string():parse(42)
    T.eq(v, "42")
    T.eq(err, nil)
  end)

  T.it("coerce.boolean: 1 -> true", function()
    local v, err = z.coerce.boolean():parse(1)
    T.eq(v, true)
    T.eq(err, nil)
  end)

  T.it("coerce.boolean: 0 -> false", function()
    local v, err = z.coerce.boolean():parse(0)
    T.eq(v, false)
    T.eq(err, nil)
  end)

  T.it("coerce.boolean: 'true' -> true", function()
    local v, err = z.coerce.boolean():parse("true")
    T.eq(v, true)
    T.eq(err, nil)
  end)

  T.it("coerce.boolean: 'false' -> false", function()
    local v, err = z.coerce.boolean():parse("false")
    T.eq(v, false)
    T.eq(err, nil)
  end)

  T.it("coerce.boolean: non-coercible value fails", function()
    local v, err = z.coerce.boolean():parse("maybe")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Merge
-- ---------------------------------------------------------------------------

T.describe("merge", function()
  T.it("extends base schema fields", function()
    local Base = z.object({ name = z.string() })
    local Extended = z.merge(Base, { age = z.number() })
    local v, err = Extended:parse({ name = "Alice", age = 30 })
    T.eq(err, nil)
    T.eq(v.name, "Alice")
    T.eq(v.age, 30)
  end)

  T.it("overrides base field when same key given", function()
    local Base = z.object({ name = z.string() })
    local Extended = z.merge(Base, { name = z.string().min(5) })
    local v, err = Extended:parse({ name = "Hi" })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("merge two object schemas", function()
    local A = z.object({ x = z.number() })
    local B = z.object({ y = z.string() })
    local C = z.merge(A, B)
    local v, err = C:parse({ x = 1, y = "hello" })
    T.eq(err, nil)
    T.eq(v.x, 1)
    T.eq(v.y, "hello")
  end)
end)

-- ---------------------------------------------------------------------------
-- Error paths
-- ---------------------------------------------------------------------------

T.describe("error paths", function()
  T.it("top-level field has correct path", function()
    local s = z.object({ name = z.string() })
    local v, err = s:parse({ name = 42 })
    T.eq(v, nil)
    T.eq(err.issues[1].path, "name")
  end)

  T.it("nested field has dot-notation path", function()
    local s = z.object({
      user = z.object({ name = z.string() }),
    })
    local v, err = s:parse({ user = { name = 42 } })
    T.eq(v, nil)
    T.eq(err.issues[1].path, "user.name")
  end)

  T.it("array item has bracket-index path", function()
    local s = z.array(z.number())
    local v, err = s:parse({1, "bad", 3})
    T.eq(v, nil)
    T.eq(err.issues[1].path, "[2]")
  end)

  T.it("nested array in object", function()
    local s = z.object({
      tags = z.array(z.string()),
    })
    local v, err = s:parse({ tags = {"ok", 99} })
    T.eq(v, nil)
    T.eq(err.issues[1].path, "tags[2]")
  end)
end)

-- ---------------------------------------------------------------------------
-- any
-- ---------------------------------------------------------------------------

T.describe("any", function()
  T.it("accepts string", function()
    local v, err = z.any():parse("hello")
    T.eq(v, "hello")
    T.eq(err, nil)
  end)

  T.it("accepts number", function()
    local v, err = z.any():parse(42)
    T.eq(v, 42)
    T.eq(err, nil)
  end)

  T.it("accepts nil", function()
    local v, err = z.any():parse(nil)
    T.eq(err, nil)
  end)

  T.it("accepts table", function()
    local t = {1, 2, 3}
    local v, err = z.any():parse(t)
    T.eq(v, t)
    T.eq(err, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- _tier
-- ---------------------------------------------------------------------------

T.describe("module", function()
  T.it("_tier is pure", function()
    T.eq(z._tier, "pure")
  end)
end)
