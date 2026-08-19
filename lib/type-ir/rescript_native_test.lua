-- lib/type-ir/rescript_native_test.lua
-- Tests for lib/type-ir/rescript_native.lua: the native ReScript
-- type-declaration projector.
--
-- Expectations are the byte-for-byte output of fractal's
-- packages/type-ir/src/rescript-native.ts on the same input, EXCEPT where a
-- record's field order is observable. The TS iterates `Object.entries`
-- (insertion order); this port iterates in byte order of the field names,
-- because Lua has no insertion order to recover. Every such case is called
-- out at the test that pins it.
--
-- `type_ref_kinds_common` is required here, and deliberately not by the
-- projector: the refined-kind lattice is a consumer opt-in, mirroring
-- fractal, where no projector imports the kind modules itself.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.type-ir")
local kinds    = require("lib.type-ir.kinds_common")
local rescript = require("lib.type-ir.rescript_native")

local t         = type_ref.type_ref_from_shape
local types     = type_ref.types
local to_type   = rescript.rescript_type_from_type_ref
local to_source = rescript.rescript_source_from_type_ref

--: (string, string) -> nil
local function contains(haystack, needle)
  T.ok(haystack:find(needle, 1, true) ~= nil, "expected to contain: " .. needle .. "\ngot:\n" .. haystack)
end

--: (string, string) -> nil
local function omits(haystack, needle)
  T.ok(haystack:find(needle, 1, true) == nil, "expected NOT to contain: " .. needle .. "\ngot:\n" .. haystack)
end

T.describe("lib.type-ir.rescript_native", function()

  T.describe("primitive types", function()

    T.it("each primitive maps to its ReScript counterpart", function()
      T.eq(to_type(t(types.boolean)), "bool")
      T.eq(to_type(t(types.number)), "float")
      T.eq(to_type(t(types.integer)), "int")
      T.eq(to_type(t(types.string)), "string")
      T.eq(to_type(t(types.null)), "unit")
      T.eq(to_type(t(types.void)), "unit")
      T.eq(to_type(t(types.unknown)), "Js.Json.t")
    end)

    T.it("never degrades to Js.Json.t — no inline bottom-type construct exists", function()
      T.eq(to_type(t(types.never)), "Js.Json.t")
    end)

    T.it("a kind with no handler and no ancestors falls back to Js.Json.t", function()
      local shape = { kind = "bogus" } --[[: TypeShape]]
      T.eq(to_type(t(shape)), "Js.Json.t")
    end)

    T.it("a bare literal in type position carries no payload, so renders unit", function()
      T.eq(to_type(t(types.literal("x"))), "unit")
    end)

  end)

  T.describe("refined kinds reach handlers through the lattice", function()

    -- The projector declares no `uuid`/`int32`/… handler. These resolve only
    -- because requiring `type_ref_kinds_common` registered the parent edges.

    T.it("string-refining kinds reach the string handler", function()
      T.eq(to_type(kinds.uuid()), "string")
      T.eq(to_type(kinds.uri()), "string")
      T.eq(to_type(kinds.email()), "string")
      T.eq(to_type(kinds.time()), "string")
      T.eq(to_type(kinds.duration()), "string")
    end)

    T.it("numeric-refining kinds reach the integer/number handlers", function()
      T.eq(to_type(kinds.int32()), "int")
      T.eq(to_type(kinds.uint64()), "int")
      T.eq(to_type(kinds.float32()), "float")
      T.eq(to_type(kinds.float64()), "float")
    end)

    T.it("kinds registered as roots have nothing to fall back to and degrade", function()
      -- datetime/date name the DOMAIN type, and bytes is orthogonal to string,
      -- so none of them chain to `string` — they must degrade explicitly.
      T.eq(to_type(kinds.datetime()), "Js.Json.t")
      T.eq(to_type(kinds.date()), "Js.Json.t")
      T.eq(to_type(kinds.bytes()), "Js.Json.t")
    end)

  end)

  T.describe("containers", function()

    T.it("array, stream and page all render as array<T>", function()
      T.eq(to_type(t(types.array(t(types.string)))), "array<string>")
      T.eq(to_type(t(types.stream(t(types.string)))), "array<string>")
      T.eq(to_type(t(types.page(t(types.string), "cursor"))), "array<string>")
    end)

    T.it("tuples are native at arbitrary arity, unlike Elm's 3-max sugar", function()
      T.eq(to_type(t(types.tuple({ t(types.string), t(types.number) }))), "(string, float)")
      local four = types.tuple({ t(types.string), t(types.number), t(types.boolean), t(types.string) })
      T.eq(to_type(t(four)), "(string, float, bool, string)")
    end)

    T.it("a string-keyed map is Js.Dict.t<V>", function()
      T.eq(to_type(t(types.map(t(types.string), t(types.number)))), "Js.Dict.t<float>")
    end)

    T.it("a non-string-keyed map degrades to an array of key/value tuples", function()
      T.eq(to_type(t(types.map(t(types.integer), t(types.string)))), "array<(int, string)>")
    end)

    T.it("the map key test is on the exact kind, not lattice ancestry", function()
      -- A uuid key IS semantically a string, but `Js.Dict.t` is keyed by
      -- literal `string`; the TS compares `kind === "string"` rather than
      -- calling `isA`, so a uuid key takes the tuple-array branch.
      T.eq(to_type(t(types.map(kinds.uuid(), t(types.string)))), "array<(string, string)>")
    end)

  end)

  T.describe("optional and nullable", function()

    T.it("nullable wraps the rendered type in option<T>", function()
      T.eq(to_type(t(types.string, { nullable = true })), "option<string>")
    end)

    T.it("an optional field wraps in option<T>", function()
      local ref = t(types.object({ age = t(types.number, { optional = true }) }))
      contains(to_source(ref, "User"), "age: option<float>")
    end)

    T.it("optional and nullable together nest, they do not collapse", function()
      local ref = t(types.object({ a = t(types.string, { optional = true, nullable = true }) }))
      contains(to_source(ref, "N"), "a: option<option<string>>")
    end)

  end)

  T.describe("records", function()

    T.it("required and optional fields, in byte order of the field names", function()
      -- FIELD-ORDER DIVERGENCE: fractal emits `id` then `age` (JS insertion
      -- order); this port sorts, so `age` comes first.
      local ref = t(types.object({ id = t(types.string), age = t(types.number, { optional = true }) }))
      T.eq(to_source(ref, "User"), table.concat({
        "type User = {",
        "  age: option<float>,",
        "  id: string,",
        "}",
      }, "\n"))
    end)

    T.it("a field name that is not a valid ReScript label gets a sanitized label plus @as", function()
      local ref = t(types.object({ ["user-id"] = t(types.string) }))
      contains(to_source(ref, "Account"), '@as("user-id") user_id: string')
    end)

    T.it("a field name that is already a valid identifier is left alone", function()
      local out = to_source(t(types.object({ userId = t(types.string) })), "Account")
      contains(out, "userId: string")
      omits(out, "@as")
    end)

    T.it("every sanitize_label branch: leading digit, leading capital, reserved word, all-punctuation", function()
      -- FIELD-ORDER DIVERGENCE: byte order puts "0abc" < "Name" < "a-b" < "type".
      local ref = t(types.object({
        ["0abc"] = t(types.string),
        ["Name"] = t(types.string),
        ["a-b"]  = t(types.string),
        ["type"] = t(types.string),
      }))
      T.eq(to_source(ref, "R"), table.concat({
        "type R = {",
        '  @as("0abc") _0abc: string,',   -- leading digit gets an `_` prefix
        '  @as("Name") name: string,',    -- leading capital is decapitalized
        '  @as("a-b") a_b: string,',      -- `-` is not label-legal
        '  @as("type") type: string,',    -- valid label, but a reserved word
        "}",
      }, "\n"))
    end)

    T.it("an all-punctuation field name sanitizes to underscores and keeps @as", function()
      contains(to_source(t(types.object({ ["!!"] = t(types.string) })), "R"), '@as("!!") __: string')
    end)

    T.it("the declaration name is PascalCased from a snake/kebab hint", function()
      contains(to_source(t(types.object({ id = t(types.string) })), "account_summary"), "type AccountSummary = {")
    end)

    T.it("a fields-less object degrades to unit, not an invalid empty record", function()
      T.eq(to_source(t(types.object({})), "Empty"), "type Empty = unit")
    end)

    T.it("a nested object field is hoisted to its own named record", function()
      local ref = t(types.object({ address = t(types.object({ city = t(types.string) })) }))
      T.eq(to_source(ref, "Person"), table.concat({
        "type Person = {",
        "  address: PersonAddress,",
        "}",
        "",
        "type PersonAddress = {",
        "  city: string,",
        "}",
      }, "\n"))
    end)

    T.it("a hoisted declaration carries its own meta doc comment", function()
      local inner = t(types.object({ x = t(types.string) }), { description = "inner doc" })
      contains(to_source(t(types.object({ a = inner })), "D"), "/** inner doc */\ntype Da = {")
    end)

  end)

  T.describe("hoisting is keyed on TypeRef identity", function()

    T.it("the same TypeRef in two field positions is declared once", function()
      local shared = t(types.object({ x = t(types.string) }))
      T.eq(to_source(t(types.object({ a = shared, b = shared })), "Sh"), table.concat({
        "type Sh = {",
        "  a: ShA,",
        "  b: ShA,",
        "}",
        "",
        "type ShA = {",
        "  x: string,",
        "}",
      }, "\n"))
    end)

    T.it("two distinct TypeRefs whose name hints collide get a numbered suffix", function()
      -- FIELD-ORDER DIVERGENCE, and the reason field order is load-bearing:
      -- both hints PascalCase to "PersonHomeAddress", so whichever field is
      -- visited first claims the bare name. Byte order puts "homeAddress"
      -- ('A' = 0x41) before "home_address" ('_' = 0x5F); fractal, in insertion
      -- order, hands the bare name to `home_address` instead. Same set of
      -- declarations, different NAMES — not merely different line order.
      local ref = t(types.object({
        home_address = t(types.object({ city = t(types.string) })),
        homeAddress  = t(types.object({ zip = t(types.string) })),
      }))
      T.eq(to_source(ref, "Person"), table.concat({
        "type Person = {",
        "  homeAddress: PersonHomeAddress,",
        "  home_address: PersonHomeAddress2,",
        "}",
        "",
        "type PersonHomeAddress = {",
        "  zip: string,",
        "}",
        "",
        "type PersonHomeAddress2 = {",
        "  city: string,",
        "}",
      }, "\n"))
    end)

    T.it("output is stable across repeated calls", function()
      local ref = t(types.object({
        z = t(types.object({ q = t(types.string) })),
        a = t(types.enum({ "x", "y" })),
        m = t(types.string),
      }))
      local first = to_source(ref, "Stable")
      for _ = 1, 20 do
        T.eq(to_source(ref, "Stable"), first)
      end
    end)

  end)

  T.describe("enum and string-literal union render as nominal variants", function()

    T.it("one no-payload constructor per member", function()
      T.eq(to_source(t(types.enum({ "active", "inactive" })), "Status"), table.concat({
        "type Status =",
        "  | Active",
        "  | Inactive",
      }, "\n"))
    end)

    T.it("a member that does not round-trip through PascalCase gets @as on the constructor", function()
      contains(to_source(t(types.enum({ "in-progress" })), "Status"), '@as("in-progress") InProgress')
    end)

    T.it("a union of string literals renders exactly like an enum", function()
      local ref = t(types.union({ t(types.literal("a")), t(types.literal("b")) }))
      T.eq(to_source(ref, "Letter"), table.concat({
        "type Letter =",
        "  | A",
        "  | B",
      }, "\n"))
    end)

    T.it("a union with a non-string literal is not a string-literal union", function()
      local ref = t(types.union({ t(types.literal("a")), t(types.literal(1)) }))
      T.eq(to_source(ref, "M"), table.concat({
        "type M =",
        "  | Variant1(unit)",
        "  | Variant2(unit)",
      }, "\n"))
    end)

    T.it("a nested enum field is hoisted to its own variant declaration", function()
      local ref = t(types.object({ status = t(types.enum({ "a", "b" })) }))
      T.eq(to_source(ref, "Rec"), table.concat({
        "type Rec = {",
        "  status: RecStatus,",
        "}",
        "",
        "type RecStatus =",
        "  | A",
        "  | B",
      }, "\n"))
    end)

  end)

  T.describe("discriminated union renders as a tagged variant", function()

    T.it("one constructor per variant, named from the discriminant literal", function()
      local ref = t(types.union({
        t(types.object({ type = t(types.literal("circle")), radius = t(types.number) })),
        t(types.object({ type = t(types.literal("square")), side = t(types.number) })),
      }), { discriminator = "type" })
      local out = to_source(ref, "Shape")
      contains(out, "type Shape =")
      contains(out, "Circle({radius: float})")
      contains(out, "Square({side: float})")
      -- The discriminator field is dropped from the payload: it is recovered
      -- by pattern-matching the constructor, not carried as data.
      omits(out, "type:")
    end)

    T.it("a tag value that does not round-trip through PascalCase gets @as on the constructor", function()
      local ref = t(types.union({
        t(types.object({ kind = t(types.literal("in-progress")), n = t(types.integer) })),
      }), { discriminator = "kind" })
      T.eq(to_source(ref, "Task"), table.concat({
        "type Task =",
        '  | @as("in-progress") InProgress({n: int})',
      }, "\n"))
    end)

    T.it("a variant whose only field is the tag becomes a payload-less constructor", function()
      local ref = t(types.union({ t(types.object({ type = t(types.literal("empty")) })) }), { discriminator = "type" })
      local out = to_source(ref, "Shape")
      contains(out, "| Empty")
      omits(out, "Empty(")
    end)

    T.it("an object-valued payload field is hoisted, like any other nested object", function()
      local ref = t(types.union({
        t(types.object({ kind = t(types.literal("a")), inner = t(types.object({ x = t(types.string) })) })),
      }), { discriminator = "kind" })
      T.eq(to_source(ref, "Tag"), table.concat({
        "type Tag =",
        "  | A({inner: TagAinner})",
        "",
        "type TagAinner = {",
        "  x: string,",
        "}",
      }, "\n"))
    end)

    T.it("a non-object variant sends the whole union to the positional fallback", function()
      local ref = t(types.union({
        t(types.object({ kind = t(types.literal("a")) })),
        t(types.string),
      }), { discriminator = "kind" })
      T.eq(to_source(ref, "Bad"), table.concat({
        "type Bad =",
        "  | Variant1(BadVariant1)",
        "  | Variant2(string)",
        "",
        "type BadVariant1 = {",
        "  kind: unit,",
        "}",
      }, "\n"))
    end)

    T.it("a discriminator field that is not a string literal falls back too", function()
      local ref = t(types.union({ t(types.object({ k = t(types.string) })) }), { discriminator = "k" })
      contains(to_source(ref, "D"), "| Variant1(")
    end)

    T.it("a missing discriminator field falls back too", function()
      local ref = t(types.union({ t(types.object({ x = t(types.string) })) }), { discriminator = "k" })
      contains(to_source(ref, "D2"), "| Variant1(")
    end)

  end)

  T.describe("untagged union falls back to positional constructors", function()

    T.it("constructors are numbered from 1, not 0", function()
      local ref = t(types.union({ t(types.string), t(types.number) }))
      T.eq(to_source(ref, "StringOrNumber"), table.concat({
        "type StringOrNumber =",
        "  | Variant1(string)",
        "  | Variant2(float)",
      }, "\n"))
    end)

    T.it("a variant's own hoisted name comes from the PascalCase-from-WORDS variant", function()
      -- "UVariant2" has no lowercase-then-uppercase boundary, so it is one
      -- word and the remainder is lowercased: "Uvariant2". A strip-separators
      -- PascalCase would leave "UVariant2" — the two helpers are not
      -- interchangeable, and the TS picks this one.
      local ref = t(types.union({ t(types.string), t(types.object({ a = t(types.string) })) }))
      T.eq(to_source(ref, "U"), table.concat({
        "type U =",
        "  | Variant1(string)",
        "  | Variant2(Uvariant2)",
        "",
        "type Uvariant2 = {",
        "  a: string,",
        "}",
      }, "\n"))
    end)

  end)

  T.describe("intersection", function()

    T.it("object members merge their fields into one record", function()
      local ref = t(types.intersection({
        t(types.object({ a = t(types.string) })),
        t(types.object({ b = t(types.number) })),
      }))
      T.eq(to_source(ref, "Merged"), table.concat({
        "type Merged = {",
        "  a: string,",
        "  b: float,",
        "}",
      }, "\n"))
    end)

    T.it("a non-object member contributes nothing, so an all-scalar intersection is unit", function()
      T.eq(to_source(t(types.intersection({ t(types.string) })), "M2"), "type M2 = unit")
    end)

    T.it("an intersection in field position is hoisted like an object", function()
      local inner = types.intersection({ t(types.object({ a = t(types.string) })) })
      T.eq(to_source(t(types.object({ m = t(inner) })), "Outer"), table.concat({
        "type Outer = {",
        "  m: OuterM,",
        "}",
        "",
        "type OuterM = {",
        "  a: string,",
        "}",
      }, "\n"))
    end)

  end)

  T.describe("callables", function()

    T.it("params render positionally; a parameterless function takes unit", function()
      local one = types.function_({ { name = "a", type = t(types.string) } }, t(types.void))
      T.eq(to_type(t(one)), "(string) => unit")
      T.eq(to_type(t(types.function_({}, t(types.void)))), "(unit) => unit")
    end)

    T.it("thisType is prepended as a leading positional parameter", function()
      local f = types.function_({ { name = "a", type = t(types.string) } }, t(types.void), t(types.integer))
      T.eq(to_type(t(f)), "(int, string) => unit")
    end)

    T.it("method has no handler and reaches the function handler through the lattice", function()
      T.eq(to_type(t(types.method({}, t(types.string)))), "(unit) => string")
    end)

    T.it("this/param/return hints are distinct, so each hoists under its own name", function()
      local f = types.function_(
        { { name = "p", type = t(types.object({ a = t(types.string) })) } },
        t(types.object({ b = t(types.string) })),
        t(types.object({ c = t(types.string) }))
      )
      T.eq(to_source(t(types.object({ f = t(f) })), "F"), table.concat({
        "type F = {",
        "  f: (Ffthis, Ff0) => Ffreturn,",
        "}",
        "",
        "type Ffthis = {",
        "  c: string,",
        "}",
        "",
        "type Ff0 = {",
        "  a: string,",
        "}",
        "",
        "type Ffreturn = {",
        "  b: string,",
        "}",
      }, "\n"))
    end)

    T.it("an interface is a contract, not data, and degrades", function()
      T.eq(to_type(t(types.interface({ go = t(types.method({}, t(types.string))) }))), "Js.Json.t")
    end)

    T.it("an instance carries only nominal identity, and degrades", function()
      T.eq(to_type(t(types.instance("User", "/u.ts"))), "Js.Json.t")
    end)

  end)

  T.describe("refs", function()

    T.it("a ref renders as a PascalCased type reference", function()
      T.eq(to_type(t(types.ref("tree_node"))), "TreeNode")
    end)

    T.it("a self-referential field renders without recursing forever", function()
      local ref = t(types.object({
        value = t(types.integer),
        children = t(types.array(t(types.ref("Tree")))),
      }))
      contains(to_source(ref, "Tree"), "children: array<Tree>")
    end)

  end)

  T.describe("doc comments and deprecation", function()

    T.it("meta.description renders as a doc comment above the declaration", function()
      T.eq(to_source(t(types.string, { description = "A display name" }), "DisplayName"),
        "/** A display name */\ntype DisplayName = string")
    end)

    T.it("meta.deprecated = true renders a bare @deprecated attribute", function()
      T.eq(to_source(t(types.string, { deprecated = true }), "Old"), "@deprecated\ntype Old = string")
    end)

    T.it("meta.deprecated with a reason carries the reason, JSON-quoted", function()
      contains(to_source(t(types.string, { deprecated = "use New instead" }), "Old"),
        '@deprecated("use New instead")')
    end)

    T.it("description and deprecation stack, doc comment first", function()
      T.eq(to_source(t(types.string, { description = "d", deprecated = "why" }), "X"),
        '/** d */\n@deprecated("why")\ntype X = string')
    end)

  end)

  T.describe("entry points", function()

    T.it("the declaration name defaults to Value", function()
      T.eq(to_source(t(types.string)), "type Value = string")
    end)

    T.it("a non-record kind at the top level becomes a plain alias", function()
      T.eq(to_source(t(types.array(t(types.string))), "Xs"), "type Xs = array<string>")
    end)

    T.it("rescript_type_from_type_ref returns only the reference name, discarding hoisted decls", function()
      local ref = t(types.object({ tag = t(types.enum({ "a", "b" })) }))
      T.eq(to_type(ref), "Anonymous")
    end)

    T.it("a name hint that is entirely separators falls back to Anonymous", function()
      -- `pascal_case_from_words("--")` is "", which is the JS `|| "Anonymous"`
      -- falsiness case. A name that merely contains punctuation is NOT empty,
      -- so it survives verbatim — matching the TS.
      T.eq(to_type(t(types.object({ a = t(types.string) }))), "Anonymous")
      T.eq(to_source(t(types.string), "!!"), "type !! = string")
    end)

  end)

end)
