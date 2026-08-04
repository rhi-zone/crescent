-- lib/fractal/type_ref_kinds_common_test.lua
-- Tests for lib/fractal/type_ref_kinds_common.lua: the refined-kind
-- constructors and the lattice registrations they come with.
--
-- Unlike lib/fractal/type_ref_test.lua, which prefixes every kind name to
-- keep its registrations out of everyone's way, this file asserts on the REAL
-- kind names — registering them is the module's entire purpose, and the
-- registration is process-wide and idempotent. That is fractal's semantics
-- too: importing `kinds/common` extends the shared lattice for every consumer
-- in the process, which is exactly what lets a projector with no `uuid`
-- handler fall back to its `string` one.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local kinds    = require("lib.fractal.type_ref_kinds_common")
local type_ref = require("lib.fractal.type_ref")

T.describe("lib.fractal.type_ref_kinds_common", function()

  T.describe("constructors", function()

    T.it("build a TypeRef, not a bare shape", function()
      local ref = kinds.uuid()
      T.eq(type(ref.shape), "table")
      T.eq(ref.shape.kind, "uuid")
      T.eq(type(ref.meta), "table")
    end)

    T.it("default to an empty meta bag", function()
      local ref = kinds.int32()
      T.eq(next(ref.meta), nil)
    end)

    T.it("carry a caller-supplied meta bag through unchanged", function()
      local meta = { description = "a user id", optional = true }
      local ref = kinds.uuid(meta)
      T.eq(ref.meta, meta)
    end)

    T.it("allocate a fresh shape per call, never a shared constant", function()
      -- type_ref.types.* payload-free kinds ARE shared constants; these are
      -- not, matching fractal's `t({ kind: "..." }, meta)`. Two refs built
      -- from one constructor must not alias.
      local a, b = kinds.bytes(), kinds.bytes()
      T.neq(a.shape, b.shape)
      T.eq(a.shape.kind, b.shape.kind)
    end)

    T.it("every kind in the vocabulary has a constructor naming its own kind", function()
      local names = {
        "int8", "int16", "int32", "int64",
        "uint8", "uint16", "uint32", "uint64",
        "float32", "float64",
        "datetime", "date", "time", "duration",
        "uuid", "uri", "email",
        "bytes",
      }
      for i = 1, #names do
        local name = names[i]
        local constructor = kinds[name]
        T.eq(type(constructor), "function")
        T.eq(constructor().shape.kind, name)
      end
    end)

  end)

  T.describe("lattice registration", function()

    T.it("every fixed-width integer refines `integer`", function()
      local widths = { "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64" }
      for i = 1, #widths do
        local chain = type_ref.ancestors(widths[i])
        T.eq(chain[1], "integer")
        -- `integer -> number` is seeded by type_ref.lua itself, so the full
        -- chain reaches `number` transitively.
        T.eq(chain[2], "number")
      end
    end)

    T.it("both fixed-width floats refine `number` directly", function()
      T.eq(type_ref.ancestors("float32")[1], "number")
      T.eq(type_ref.ancestors("float64")[1], "number")
    end)

    T.it("the string-shaped semantic kinds refine `string`", function()
      local semantic = { "uuid", "uri", "email", "time", "duration" }
      for i = 1, #semantic do
        local chain = type_ref.ancestors(semantic[i])
        T.eq(#chain, 1)
        T.eq(chain[1], "string")
      end
    end)

    -- The two deliberate roots. `datetime`/`date` name the domain type (a
    -- Date), not its wire format, so falling through to `string`'s handlers
    -- and constraints would be structurally wrong; `bytes` is orthogonal to
    -- `string`, never a subtype of it.
    T.it("datetime and date are roots, NOT subtypes of string", function()
      T.eq(#type_ref.ancestors("datetime"), 0)
      T.eq(#type_ref.ancestors("date"), 0)
    end)

    T.it("bytes is a root, NOT a subtype of string", function()
      T.eq(#type_ref.ancestors("bytes"), 0)
    end)

  end)

  T.describe("handler fallback", function()

    -- The point of the registrations: a projector that never heard of `uuid`
    -- resolves to its `string` handler, and one that never heard of `int32`
    -- resolves to `integer` in preference to `number`.

    T.it("a refined string kind resolves to a `string` handler", function()
      local handlers = { string = "String", number = "f64" }
      T.eq(type_ref.resolve("uuid", handlers), "String")
      T.eq(type_ref.resolve("duration", handlers), "String")
    end)

    T.it("a fixed-width integer prefers `integer` over the further `number`", function()
      local handlers = { integer = "i64", number = "f64" }
      T.eq(type_ref.resolve("int32", handlers), "i64")
    end)

    T.it("a fixed-width integer still reaches `number` when no `integer` handler exists", function()
      local handlers = { number = "f64" }
      T.eq(type_ref.resolve("uint8", handlers), "f64")
    end)

    T.it("an exact handler still wins over the ancestor chain", function()
      local handlers = { int32 = "i32", integer = "i64", number = "f64" }
      T.eq(type_ref.resolve("int32", handlers), "i32")
    end)

    -- The flip side of the two root registrations: a projector with no
    -- explicit entry gets NOTHING rather than silently inheriting `string`'s
    -- handler, and so has to degrade explicitly.
    T.it("datetime, date, and bytes resolve to nothing without an explicit handler", function()
      local handlers = { string = "String", number = "f64" }
      T.eq(type_ref.resolve("datetime", handlers), nil)
      T.eq(type_ref.resolve("date", handlers), nil)
      T.eq(type_ref.resolve("bytes", handlers), nil)
    end)

  end)

end)
