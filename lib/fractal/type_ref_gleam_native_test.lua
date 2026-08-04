-- lib/fractal/type_ref_gleam_native_test.lua
-- Tests for lib/fractal/type_ref_gleam_native.lua: the Gleam type-declaration
-- projector. Ported from fractal's packages/type-ir/src/gleam-native.test.ts,
-- with the reference outputs for the intricate cases (nested hoisting and its
-- naming, tagged vs positional unions, keyword escaping) taken from running
-- the TypeScript rather than reasoned out.
--
-- Where fractal asserts `toContain(...)`, this file asserts the WHOLE emitted
-- source instead. `lib/test/assert` has no substring assertion, and a full
-- string is the stronger check anyway — it pins declaration order, which is
-- the part of hoisting most likely to regress.
--
-- FIELD ORDER: fractal emits object fields and interface methods in JS
-- insertion order; the Lua port emits them in byte order of the field name
-- (see the projector's header). Expectations here are the port's order, so a
-- case fractal writes as `Person(name: String, age: Int)` is
-- `Person(age: Int, name: String)` below. Enum members, union variants and
-- function parameters are LISTS in both, so their order is identical.
--
-- This file requires `type_ref_kinds_common`, which the projector
-- deliberately does not — that require is what registers the refined-kind
-- lattice, and the "refined kinds" group below exists to pin the fallback it
-- enables: the projector has no `uuid` or `int32` handler at all, so those
-- render as `String`/`Int` only by `resolve` walking to the `string`/
-- `integer` handler.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")
local kinds    = require("lib.fractal.type_ref_kinds_common")
local gleam    = require("lib.fractal.type_ref_gleam_native")

local t = type_ref.type_ref_from_shape
local types = type_ref.types
local to_type = gleam.gleam_type_from_type_ref
local to_source = gleam.gleam_source_from_type_ref

-- `{ [integer]: string }` rather than `string[]`: the `T[]` sugar desugars to
-- a number indexer, which `table.concat` rejects. Same workaround, and same
-- reason, as the projector's own `StringList`.
--: ({ [integer]: string }) -> string
local function src(lines)
  return table.concat(lines, "\n")
end

T.describe("lib.fractal.type_ref_gleam_native", function()

  T.describe("primitives", function()

    T.it("boolean -> Bool", function()
      T.eq(to_type(t(types.boolean)), "Bool")
    end)

    T.it("number -> Float", function()
      T.eq(to_type(t(types.number)), "Float")
    end)

    T.it("integer -> Int", function()
      T.eq(to_type(t(types.integer)), "Int")
    end)

    T.it("string -> String", function()
      T.eq(to_type(t(types.string)), "String")
    end)

    T.it("null -> Nil", function()
      T.eq(to_type(t(types.null)), "Nil")
    end)

    T.it("void -> Nil", function()
      T.eq(to_type(t(types.void)), "Nil")
    end)

    T.it("unknown -> Dynamic", function()
      T.eq(to_type(t(types.unknown)), "Dynamic")
    end)

    T.it("never -> Nil (lossy: Gleam has no bottom type)", function()
      T.eq(to_type(t(types.never)), "Nil")
    end)

  end)

  T.describe("containers", function()

    T.it("array -> List(T)", function()
      T.eq(to_type(t(types.array(t(types.string)))), "List(String)")
    end)

    T.it("map -> Dict(K, V)", function()
      T.eq(to_type(t(types.map(t(types.string), t(types.number)))), "Dict(String, Float)")
    end)

    T.it("2-tuple -> #(a, b)", function()
      T.eq(to_type(t(types.tuple({ t(types.string), t(types.number) }))), "#(String, Float)")
    end)

    T.it("5-tuple has no arity cap", function()
      local elements = {}
      for i = 1, 5 do elements[i] = t(types.string) end
      T.eq(to_type(t(types.tuple(elements))), "#(String, String, String, String, String)")
    end)

    T.it("stream degrades to List(T)", function()
      T.eq(to_type(t(types.stream(t(types.string)))), "List(String)")
    end)

    T.it("page degrades to List(T)", function()
      T.eq(to_type(t(types.page(t(types.string), "cursor"))), "List(String)")
    end)

  end)

  T.describe("optional and nullable both collapse to Option(T)", function()

    T.it("optional -> Option(T)", function()
      T.eq(to_type(t(types.string, { optional = true })), "Option(String)")
    end)

    T.it("nullable -> Option(T)", function()
      T.eq(to_type(t(types.string, { nullable = true })), "Option(String)")
    end)

    T.it("both flags still single-wrap, not Option(Option(T))", function()
      T.eq(to_type(t(types.string, { optional = true, nullable = true })), "Option(String)")
    end)

    T.it("an unhandled kind degrades to Dynamic and still takes the Option wrap", function()
      T.eq(to_type(t({ kind = "bogus_optional" }, { optional = true })), "Option(Dynamic)")
    end)

  end)

  T.describe("literal degrades to base type", function()

    T.it("string literal -> String", function()
      T.eq(to_type(t(types.literal("active"))), "String")
    end)

    T.it("number literal -> Float", function()
      T.eq(to_type(t(types.literal(1.5))), "Float")
    end)

    T.it("integer-valued number literal -> Int", function()
      T.eq(to_type(t(types.literal(42))), "Int")
    end)

    T.it("boolean literal -> Bool", function()
      T.eq(to_type(t(types.literal(true))), "Bool")
    end)

    T.it("null literal (the shared sentinel) -> Nil", function()
      T.eq(to_type(t(types.literal(type_ref.null))), "Nil")
    end)

  end)

  T.it("ref -> PascalCase target name", function()
    T.eq(to_type(t(types.ref("user"))), "User")
  end)

  T.it("instance renders the bare className, ignoring declarationFile", function()
    T.eq(to_type(t(types.instance("Widget", "/src/widget.ts"))), "Widget")
  end)

  T.describe("function types", function()

    T.it("fn(Params) -> Return, with no parameter names", function()
      local ref = t(types.function_({ { name = "x", type = t(types.integer) } }, t(types.string)))
      T.eq(to_type(ref), "fn(Int) -> String")
    end)

    T.it("no parameters -> fn() -> Return", function()
      T.eq(to_type(t(types.function_({}, t(types.void)))), "fn() -> Nil")
    end)

    T.it("thisType prepends as a leading parameter", function()
      local ref = t(types.function_(
        { { name = "x", type = t(types.integer) } },
        t(types.string),
        t(types.ref("Account"))
      ))
      T.eq(to_type(ref), "fn(Account, Int) -> String")
    end)

    T.it("method falls back to the function handler via the kind lattice", function()
      local ref = t(types.method({ { name = "x", type = t(types.integer) } }, t(types.boolean)))
      T.eq(to_type(ref), "fn(Int) -> Bool")
    end)

  end)

  T.describe("records (object)", function()

    T.it("object -> single-constructor custom type with labelled fields", function()
      local ref = t(types.object({ name = t(types.string), age = t(types.integer) }))
      T.eq(to_source(ref, "Person"), src({
        "pub type Person {",
        "  Person(age: Int, name: String)",
        "}",
      }))
    end)

    T.it("empty object -> nullary constructor", function()
      T.eq(to_source(t(types.object({})), "Empty"), src({
        "pub type Empty {",
        "  Empty",
        "}",
      }))
    end)

    T.it("camelCase field -> snake_case label", function()
      local ref = t(types.object({ firstName = t(types.string) }))
      T.eq(to_source(ref, "Person"), src({
        "pub type Person {",
        "  Person(first_name: String)",
        "}",
      }))
    end)

    T.it("keyword-colliding field name gets a trailing underscore", function()
      local ref = t(types.object({ type = t(types.string) }))
      T.eq(to_source(ref, "Wrapper"), src({
        "pub type Wrapper {",
        "  Wrapper(type_: String)",
        "}",
      }))
    end)

    T.it("optional field -> Option(T)", function()
      local ref = t(types.object({ nickname = t(types.string, { optional = true }) }))
      T.eq(to_source(ref, "Person"), src({
        "pub type Person {",
        "  Person(nickname: Option(String))",
        "}",
      }))
    end)

    T.it("nested object field hoists a sibling record BEFORE the main one", function()
      local ref = t(types.object({ address = t(types.object({ city = t(types.string) })) }))
      T.eq(to_source(ref, "Person"), src({
        "pub type PersonAddress {",
        "  PersonAddress(city: String)",
        "}",
        "",
        "pub type Person {",
        "  Person(address: PersonAddress)",
        "}",
      }))
    end)

    T.it("three levels of nesting hoist innermost-first", function()
      local ref = t(types.object({
        address = t(types.object({
          geo = t(types.object({ lat = t(types.number) })),
          city = t(types.string),
        })),
      }))
      T.eq(to_source(ref, "Person"), src({
        "pub type PersonAddressGeo {",
        "  PersonAddressGeo(lat: Float)",
        "}",
        "",
        "pub type PersonAddress {",
        "  PersonAddress(city: String, geo: PersonAddressGeo)",
        "}",
        "",
        "pub type Person {",
        "  Person(address: PersonAddress)",
        "}",
      }))
    end)

    T.it("array-of-object field hoists the ELEMENT under the field's own name", function()
      local ref = t(types.object({ tags = t(types.array(t(types.object({ label = t(types.string) })))) }))
      T.eq(to_source(ref, "Post"), src({
        "pub type PostTags {",
        "  PostTags(label: String)",
        "}",
        "",
        "pub type Post {",
        "  Post(tags: List(PostTags))",
        "}",
      }))
    end)

    T.it("optional array-of-object field wraps the List, not the element", function()
      local element = t(types.object({ label = t(types.string) }))
      local ref = t(types.object({ tags = t(types.array(element), { optional = true }) }))
      T.eq(to_source(ref, "Post"), src({
        "pub type PostTags {",
        "  PostTags(label: String)",
        "}",
        "",
        "pub type Post {",
        "  Post(tags: Option(List(PostTags)))",
        "}",
      }))
    end)

    T.it("stream-of-object field hoists like array", function()
      local ref = t(types.object({ s = t(types.stream(t(types.object({ a = t(types.string) })))) }))
      T.eq(to_source(ref, "S"), src({
        "pub type SS {",
        "  SS(a: String)",
        "}",
        "",
        "pub type S {",
        "  S(s: List(SS))",
        "}",
      }))
    end)

    T.it("description -> /// doc comment", function()
      local ref = t(types.object({ id = t(types.string) }), { description = "A person." })
      T.eq(to_source(ref, "Person"), src({
        "/// A person.",
        "pub type Person {",
        "  Person(id: String)",
        "}",
      }))
    end)

    T.it("a multi-line description becomes one /// line per line", function()
      local ref = t(types.object({ id = t(types.string) }), { description = "Line one.\nLine two." })
      T.eq(to_source(ref, "P"), src({
        "/// Line one.",
        "/// Line two.",
        "pub type P {",
        "  P(id: String)",
        "}",
      }))
    end)

    T.it("deprecated = true -> @deprecated with a placeholder message", function()
      local ref = t(types.object({ id = t(types.string) }), { deprecated = true })
      T.eq(to_source(ref, "Person"), src({
        '@deprecated("Deprecated.")',
        "pub type Person {",
        "  Person(id: String)",
        "}",
      }))
    end)

    T.it("deprecated = string -> @deprecated with that message, JSON-quoted", function()
      local ref = t(types.object({ id = t(types.string) }), { deprecated = 'Use "NewPerson".' })
      T.eq(to_source(ref, "Person"), src({
        '@deprecated("Use \\"NewPerson\\".")',
        "pub type Person {",
        "  Person(id: String)",
        "}",
      }))
    end)

  end)

  T.describe("enum", function()

    T.it("closed string set -> custom type of nullary constructors", function()
      T.eq(to_source(t(types.enum({ "active", "inactive" })), "Status"), src({
        "pub type Status {",
        "  Active",
        "  Inactive",
        "}",
      }))
    end)

    T.it("nested enum field hoists a sibling declaration", function()
      local ref = t(types.object({ status = t(types.enum({ "active", "inactive" })) }))
      T.eq(to_source(ref, "Person"), src({
        "pub type PersonStatus {",
        "  Active",
        "  Inactive",
        "}",
        "",
        "pub type Person {",
        "  Person(status: PersonStatus)",
        "}",
      }))
    end)

  end)

  T.describe("discriminated (tagged) unions", function()

    T.it("one constructor per variant, named from the tag, tag field dropped", function()
      local dog = t(types.object({ kind = t(types.literal("dog")), bark = t(types.boolean) }))
      local cat = t(types.object({ kind = t(types.literal("cat")), meow = t(types.boolean) }))
      local ref = t(types.union({ dog, cat }), { discriminator = "kind" })
      T.eq(to_source(ref, "Pet"), src({
        "pub type Pet {",
        "  Dog(bark: Bool)",
        "  Cat(meow: Bool)",
        "}",
      }))
    end)

    T.it("a variant whose only field is the tag becomes a nullary constructor", function()
      local ref = t(types.union({ t(types.object({ kind = t(types.literal("gone")) })) }), { discriminator = "kind" })
      T.eq(to_source(ref, "State"), src({
        "pub type State {",
        "  Gone",
        "}",
      }))
    end)

    T.it("a variant with no tag field falls back to a synthesized Variant<i> name", function()
      local ref = t(types.union({ t(types.object({ bark = t(types.boolean) })) }), { discriminator = "kind" })
      T.eq(to_source(ref, "Pet"), src({
        "pub type Pet {",
        "  Variant0(bark: Bool)",
        "}",
      }))
    end)

    T.it("a non-object variant is wrapped in a synthesized <Name>Variant<i> constructor", function()
      local dog = t(types.object({
        kind = t(types.literal("dog")),
        owner = t(types.object({ name = t(types.string) })),
      }))
      local ref = t(types.union({ dog, t(types.string) }), { discriminator = "kind" })
      T.eq(to_source(ref, "Pet"), src({
        "pub type PetDogOwner {",
        "  PetDogOwner(name: String)",
        "}",
        "",
        "pub type Pet {",
        "  Dog(owner: PetDogOwner)",
        "  PetVariant1(String)",
        "}",
      }))
    end)

  end)

  T.describe("untagged unions", function()

    T.it("union without a discriminator -> positionally-named constructors", function()
      local ref = t(types.union({ t(types.string), t(types.number) }))
      T.eq(to_source(ref, "StringOrNumber"), src({
        "pub type StringOrNumber {",
        "  Variant0(String)",
        "  Variant1(Float)",
        "}",
      }))
    end)

    T.it("structural variants hoist their own declarations first", function()
      local ref = t(types.union({ t(types.object({ a = t(types.string) })), t(types.enum({ "x", "y" })) }))
      T.eq(to_source(ref, "U"), src({
        "pub type UVariant0 {",
        "  UVariant0(a: String)",
        "}",
        "",
        "pub type UVariant1 {",
        "  X",
        "  Y",
        "}",
        "",
        "pub type U {",
        "  Variant0(UVariant0)",
        "  Variant1(UVariant1)",
        "}",
      }))
    end)

  end)

  T.describe("interface", function()

    T.it("renders a record of function-typed fields", function()
      local ref = t(types.interface({
        deposit = t(types.method({ { name = "amount", type = t(types.number) } }, t(types.void))),
      }))
      T.eq(to_source(ref, "Account"), src({
        "pub type Account {",
        "  Account(deposit: fn(Float) -> Nil)",
        "}",
      }))
    end)

    T.it("an empty interface -> nullary constructor", function()
      T.eq(to_source(t(types.interface({})), "Iface"), src({
        "pub type Iface {",
        "  Iface",
        "}",
      }))
    end)

    T.it("a keyword-colliding method name gets a trailing underscore", function()
      local ref = t(types.interface({ type = t(types.method({}, t(types.void))) }))
      T.eq(to_source(ref, "Iface"), src({
        "pub type Iface {",
        "  Iface(type_: fn() -> Nil)",
        "}",
      }))
    end)

  end)

  T.describe("intersection", function()

    T.it("degrades to the first member's own rendering", function()
      T.eq(to_type(t(types.intersection({ t(types.string), t(types.integer) }))), "String")
    end)

    T.it("a first member that is an unnamed object degrades to Dynamic", function()
      local ref = t(types.intersection({
        t(types.object({ id = t(types.string) })),
        t(types.object({ createdAt = t(types.string) })),
      }))
      T.eq(to_type(ref), "Dynamic")
    end)

    T.it("an empty intersection degrades to Dynamic", function()
      T.eq(to_type(t(types.intersection({}))), "Dynamic")
    end)

  end)

  T.describe("inline rendering of structural kinds", function()

    T.it("meta.typeName names an object inline; without it there is nothing to name", function()
      T.eq(to_type(t(types.object({}), { typeName = "my-thing" })), "MyThing")
      T.eq(to_type(t(types.object({}))), "Dynamic")
    end)

    T.it("meta.enumName names an enum inline", function()
      T.eq(to_type(t(types.enum({ "a" }), { enumName = "my-status" })), "MyStatus")
      T.eq(to_type(t(types.enum({ "a" }))), "Dynamic")
    end)

    T.it("a structural type in a TUPLE slot does not hoist — it renders Dynamic", function()
      local ref = t(types.object({ p = t(types.tuple({ t(types.object({ a = t(types.string) })) })) }))
      T.eq(to_source(ref, "T"), src({
        "pub type T {",
        "  T(p: #(Dynamic))",
        "}",
      }))
    end)

    T.it("a structural type in a MAP value does not hoist — it renders Dynamic", function()
      local ref = t(types.object({ m = t(types.map(t(types.string), t(types.object({ a = t(types.string) })))) }))
      T.eq(to_source(ref, "M"), src({
        "pub type M {",
        "  M(m: Dict(String, Dynamic))",
        "}",
      }))
    end)

  end)

  T.describe("gleam_source_from_type_ref without a name", function()

    T.it("returns just the inline type expression", function()
      T.eq(to_source(t(types.string)), "String")
      T.eq(to_source(t(types.array(t(types.integer)))), "List(Int)")
    end)

  end)

  T.describe("gleam_source_from_type_ref with a name, for non-declaring kinds", function()

    T.it("emits a pub type alias", function()
      T.eq(to_source(t(types.string), "Name"), "pub type Name = String")
    end)

    T.it("the name is PascalCased like every other emitted type name", function()
      T.eq(to_source(t(types.string), "user-name"), "pub type UserName = String")
    end)

    T.it("an alias carries its doc comment too", function()
      local ref = t(types.string, { description = "D", deprecated = "gone" })
      T.eq(to_source(ref, "N"), src({
        "/// D",
        '@deprecated("gone")',
        "pub type N = String",
      }))
    end)

  end)

  T.describe("refined kinds resolve through the lattice, with no handler of their own", function()

    -- The projector declares handlers for `string`, `integer` and `number`
    -- and for NOTHING below them. Each expectation here is therefore a test
    -- of `resolve`'s ancestor walk over the lattice
    -- `type_ref_kinds_common` registered at require time, not of a
    -- gleam-native handler.

    T.it("uuid/uri/email refine string -> String", function()
      T.eq(to_type(kinds.uuid()), "String")
      T.eq(to_type(kinds.uri()), "String")
      T.eq(to_type(kinds.email()), "String")
    end)

    T.it("time/duration refine string -> String", function()
      T.eq(to_type(kinds.time()), "String")
      T.eq(to_type(kinds.duration()), "String")
    end)

    T.it("every fixed-width integer refines integer -> Int", function()
      T.eq(to_type(kinds.int8()), "Int")
      T.eq(to_type(kinds.int16()), "Int")
      T.eq(to_type(kinds.int32()), "Int")
      T.eq(to_type(kinds.int64()), "Int")
      T.eq(to_type(kinds.uint8()), "Int")
      T.eq(to_type(kinds.uint16()), "Int")
      T.eq(to_type(kinds.uint32()), "Int")
      T.eq(to_type(kinds.uint64()), "Int")
    end)

    T.it("float widths refine number -> Float", function()
      T.eq(to_type(kinds.float32()), "Float")
      T.eq(to_type(kinds.float64()), "Float")
    end)

    T.it("datetime/date/bytes are explicit lattice ROOTS, so they degrade to Dynamic", function()
      T.eq(to_type(kinds.datetime()), "Dynamic")
      T.eq(to_type(kinds.date()), "Dynamic")
      T.eq(to_type(kinds.bytes()), "Dynamic")
    end)

    T.it("a refined kind carries its Option wrap like any other", function()
      T.eq(to_type(kinds.uuid({ optional = true })), "Option(String)")
      T.eq(to_type(kinds.datetime({ nullable = true })), "Option(Dynamic)")
    end)

    T.it("refined kinds flow through record fields and array elements", function()
      local ref = t(types.object({
        id = kinds.uuid(),
        count = kinds.int32(),
        seenAt = kinds.datetime({ optional = true }),
        scores = t(types.array(kinds.float64())),
      }))
      T.eq(to_source(ref, "Row"), src({
        "pub type Row {",
        "  Row(count: Int, id: String, scores: List(Float), seen_at: Option(Dynamic))",
        "}",
      }))
    end)

  end)

  T.describe("unrecognized kinds", function()

    T.it("a kind with no handler and no registered ancestor falls back to Dynamic", function()
      T.eq(to_type(t({ kind = "bogus" })), "Dynamic")
    end)

    T.it("a named declaration over an unrecognized kind is an alias to Dynamic", function()
      T.eq(to_source(t({ kind = "bogus" }), "Weird"), "pub type Weird = Dynamic")
    end)

  end)

end)
