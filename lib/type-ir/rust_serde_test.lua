-- lib/type-ir/rust_serde_test.lua
-- Tests for lib/type-ir/rust_serde.lua: the Rust/serde projector.
--
-- The cases from fractal's packages/type-ir/src/rust-serde.test.ts are ported
-- as-is. The whole-output fixtures beyond that set were captured by running
-- the TS projector on the same input (`bun run` against
-- packages/type-ir/src/rust-serde.ts), so they pin byte-for-byte agreement
-- rather than this port's own idea of the right answer.
--
-- Every object in these fixtures has its fields named in byte order, so the
-- one place the port cannot match the TS — JS insertion order for
-- `Object.entries` — does not silently absorb a difference here.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local type_ref   = require("lib.type-ir")
local rust_serde = require("lib.type-ir.rust_serde")
-- Required for the side effect: registers int32/uint64/bytes/... in the kind
-- lattice. The projector has explicit handlers for all of them, so this is
-- only about the constructors these cases build their input with.
local kinds      = require("lib.type-ir.kinds_common")

local t = type_ref.type_ref_from_shape
local types = type_ref.types

--: (lines: { [integer]: string }) -> string
local function joined(lines)
  return table.concat(lines, "\n")
end

--: (haystack: string, needle: string) -> nil
local function contains(haystack, needle)
  T.ok(haystack:find(needle, 1, true) ~= nil, "expected output to contain: " .. needle .. "\n--- got ---\n" .. haystack)
end

--: (haystack: string, needle: string) -> nil
local function excludes(haystack, needle)
  T.ok(haystack:find(needle, 1, true) == nil, "expected output NOT to contain: " .. needle .. "\n--- got ---\n" .. haystack)
end

T.describe("lib.type-ir.rust_serde", function()

  T.describe("primitives", function()

    T.it("boolean -> bool", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.boolean)), "bool")
    end)

    T.it("number -> f64", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.number)), "f64")
    end)

    T.it("integer (bare) -> i64", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.integer)), "i64")
    end)

    T.it("fixed-width integers map onto their Rust namesakes", function()
      T.eq(rust_serde.rust_type_from_type_ref(kinds.int8()), "i8")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.int16()), "i16")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.int32()), "i32")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.int64()), "i64")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uint8()), "u8")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uint16()), "u16")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uint32()), "u32")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uint64()), "u64")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.float32()), "f32")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.float64()), "f64")
    end)

    T.it("string -> String", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.string)), "String")
    end)

    T.it("semantic and temporal strings -> String", function()
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uuid()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.uri()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.email()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.datetime()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.date()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.time()), "String")
      T.eq(rust_serde.rust_type_from_type_ref(kinds.duration()), "String")
    end)

    T.it("null -> ()", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.null)), "()")
    end)

    T.it("void -> ()", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.void)), "()")
    end)

    T.it("unknown -> serde_json::Value", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.unknown)), "serde_json::Value")
    end)

    T.it("never -> std::convert::Infallible", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.never)), "std::convert::Infallible")
    end)

    T.it("bytes -> Vec<u8>", function()
      T.eq(rust_serde.rust_type_from_type_ref(kinds.bytes()), "Vec<u8>")
    end)

  end)

  T.describe("containers", function()

    T.it("array -> Vec<T>", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.array(t(types.string)))), "Vec<String>")
    end)

    T.it("stream and page materialize to Vec<T>", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.stream(t(types.string)))), "Vec<String>")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.page(t(types.string), "cursor"))), "Vec<String>")
    end)

    T.it("map with string key -> HashMap<String, V>", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.map(t(types.string), t(types.number)))), "HashMap<String, f64>")
    end)

    T.it("map with meta.ordered -> BTreeMap<K, V>", function()
      local ref = t(types.map(t(types.string), t(types.number)), { ordered = true })
      T.eq(rust_serde.rust_type_from_type_ref(ref), "BTreeMap<String, f64>")
    end)

    T.it("tuple -> (T1, T2, ...)", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.tuple({ t(types.string), t(types.number) }))), "(String, f64)")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.tuple({}))), "()")
    end)

    T.it("nullable -> Option<T>", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.string, { nullable = true })), "Option<String>")
    end)

  end)

  T.describe("inline expressions with no naming context", function()

    T.it("an anonymous object or union is the opaque escape hatch", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.object({}))), "serde_json::Value")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.union({}))), "serde_json::Value")
    end)

    T.it("meta.typeName names an object or union instead", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.object({}), { typeName = "Foo" })), "Foo")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.union({}), { typeName = "Foo" })), "Foo")
    end)

    T.it("an anonymous enum falls back to its member count, meta.enumName to a name", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.enum({ "a", "b" }))), "Enum2")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.enum({ "a", "b" }), { enumName = "Foo" })), "Foo")
    end)

    T.it("an instance is referenced by class name, a ref by target", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.instance("User", "/u.ts"))), "User")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.ref("Node"))), "Node")
    end)

    T.it("an intersection degrades to its first member, or the escape hatch when empty", function()
      local both = t(types.intersection({ t(types.string), t(types.number) }))
      T.eq(rust_serde.rust_type_from_type_ref(both), "String")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.intersection({}))), "serde_json::Value")
    end)

    T.it("callables and interfaces are not serializable data", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.function_({}, t(types.void)))), "serde_json::Value")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.method({}, t(types.void)))), "serde_json::Value")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.interface({}))), "serde_json::Value")
    end)

    T.it("a kind with no handler and no handled ancestor falls back, rather than failing", function()
      local shape = { kind = "totally-unknown" } --[[: { kind: string, ... } ]]
      T.eq(rust_serde.rust_type_from_type_ref(t(shape)), "serde_json::Value")
    end)

    T.it("a literal degrades to its base scalar type", function()
      T.eq(rust_serde.rust_type_from_type_ref(t(types.literal("s"))), "String")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.literal(true))), "bool")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.literal(3))), "i64")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.literal(3.5))), "f64")
      T.eq(rust_serde.rust_type_from_type_ref(t(types.literal(type_ref.null))), "()")
    end)

  end)

  T.describe("structs", function()

    T.it("object -> derived struct with pub fields", function()
      local ref = t(types.object({ age = t(types.integer), name = t(types.string) }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "Person"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Person {",
        "    pub age: i64,",
        "    pub name: String,",
        "}",
      }))
    end)

    T.it("camelCase field -> snake_case + serde rename", function()
      local rust = rust_serde.rust_source_from_type_ref(t(types.object({ firstName = t(types.string) })), "Person")
      contains(rust, '#[serde(rename = "firstName")]')
      contains(rust, "pub first_name: String,")
    end)

    T.it("a field colliding with a Rust keyword becomes a raw identifier, renamed on the wire", function()
      local ref = t(types.object({
        ["my-ref"] = t(types.string),
        ["type"] = t(types.string),
        ["unsafe"] = t(types.string),
      }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "K"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct K {",
        '    #[serde(rename = "my-ref")]',
        "    pub my_ref: String,",
        '    #[serde(rename = "type")]',
        "    pub r#type: String,",
        -- `unsafe` snake_cases to itself, so the rename is there purely
        -- because the identifier had to be escaped.
        '    #[serde(rename = "unsafe")]',
        "    pub r#unsafe: String,",
        "}",
      }))
    end)

    T.it("optional field -> Option<T> + skip_serializing_if", function()
      local ref = t(types.object({ nickname = t(types.string, { optional = true }) }))
      local rust = rust_serde.rust_source_from_type_ref(ref, "Person")
      contains(rust, '#[serde(skip_serializing_if = "Option::is_none")]')
      contains(rust, "pub nickname: Option<String>,")
    end)

    T.it("a nullable field collapses onto the same single Option, not Option<Option<T>>", function()
      local ref = t(types.object({ a = t(types.string, { nullable = true }) }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "N"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct N {",
        '    #[serde(skip_serializing_if = "Option::is_none")]',
        "    pub a: Option<String>,",
        "}",
      }))
    end)

    T.it("nested object field hoists a sibling struct", function()
      local ref = t(types.object({ address = t(types.object({ city = t(types.string) })) }))
      local rust = rust_serde.rust_source_from_type_ref(ref, "Person")
      contains(rust, "pub struct Address {")
      contains(rust, "pub city: String,")
      contains(rust, "pub address: Address,")
      -- hoisted decl comes before the main struct
      T.ok(rust:find("pub struct Address {", 1, true) < rust:find("pub struct Person {", 1, true))
    end)

    T.it("nested hoists are emitted deepest-first, each complete", function()
      -- Pins the by-reference threading of `decls`: the innermost struct is
      -- appended before the one that contains it, and a shallower hoist never
      -- overwrites a deeper one.
      local ref = t(types.object({
        address = t(types.object({ geo = t(types.object({ lat = t(types.number) })) })),
        name = t(types.string),
      }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "Person"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Geo {",
        "    pub lat: f64,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Address {",
        "    pub geo: Geo,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Person {",
        "    pub address: Address,",
        "    pub name: String,",
        "}",
      }))
    end)

    T.it("an array-of-objects field hoists the element type under the field's name", function()
      local ref = t(types.object({ items = t(types.array(t(types.object({ id = t(types.string) })))) }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "Bag"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Items {",
        "    pub id: String,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Bag {",
        "    pub items: Vec<Items>,",
        "}",
      }))
    end)

    T.it("an optional nested object is hoisted AND wrapped", function()
      local ref = t(types.object({ addr = t(types.object({ c = t(types.string) }), { optional = true }) }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "P"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct Addr {",
        "    pub c: String,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct P {",
        '    #[serde(skip_serializing_if = "Option::is_none")]',
        "    pub addr: Option<Addr>,",
        "}",
      }))
    end)

    T.it("description -> doc comment", function()
      local ref = t(types.object({ id = t(types.string) }), { description = "A person." })
      contains(rust_serde.rust_source_from_type_ref(ref, "Person"), "/// A person.")
    end)

    T.it("description and deprecated are emitted on both the struct and its fields", function()
      local ref = t(
        types.object({ a = t(types.string, { description = "field doc", deprecated = true }) }),
        { description = "struct doc", deprecated = true }
      )
      T.eq(rust_serde.rust_source_from_type_ref(ref, "D"), joined({
        "/// struct doc",
        "#[deprecated]",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct D {",
        "    /// field doc",
        "    #[deprecated]",
        "    pub a: String,",
        "}",
      }))
    end)

  end)

  T.describe("enums", function()

    T.it("string enum -> Rust enum with PascalCase variants", function()
      T.eq(rust_serde.rust_source_from_type_ref(t(types.enum({ "active", "inactive" })), "Status"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub enum Status {",
        '    #[serde(rename = "active")]',
        "    Active,",
        '    #[serde(rename = "inactive")]',
        "    Inactive,",
        "}",
      }))
    end)

    T.it("a member already in PascalCase needs no rename", function()
      T.eq(rust_serde.rust_source_from_type_ref(t(types.enum({ "Active" })), "Status"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub enum Status {",
        "    Active,",
        "}",
      }))
    end)

    T.it("nested enum field hoists a sibling enum", function()
      local ref = t(types.object({ status = t(types.enum({ "active", "inactive" })) }))
      local rust = rust_serde.rust_source_from_type_ref(ref, "Person")
      contains(rust, "pub enum Status {")
      contains(rust, "pub status: Status,")
    end)

  end)

  T.describe("discriminated unions", function()

    T.it("union with meta.discriminator -> internally-tagged enum", function()
      local dog = t(types.object({ bark = t(types.boolean), kind = t(types.literal("dog")) }))
      local cat = t(types.object({ kind = t(types.literal("cat")), meow = t(types.boolean) }))
      local ref = t(types.union({ dog, cat }), { discriminator = "kind" })
      local rust = rust_serde.rust_source_from_type_ref(ref, "Pet")

      contains(rust, '#[serde(tag = "kind")]')
      contains(rust, "pub enum Pet {")
      contains(rust, "Dog {")
      contains(rust, "bark: bool,")
      contains(rust, "Cat {")
      contains(rust, "meow: bool,")
      -- the discriminator field itself is not rendered as a struct field
      excludes(rust, "kind:")
    end)

    T.it("a tag value that is not already a variant name is renamed; a payload-free variant is a unit variant", function()
      local dog = t(types.object({ bark = t(types.boolean), kind = t(types.literal("dog")) }))
      local cat = t(types.object({
        kind = t(types.literal("cat")),
        meow_loud = t(types.boolean, { optional = true }),
      }))
      local plain = t(types.object({ kind = t(types.literal("plain-old")) }))
      local ref = t(types.union({ dog, cat, plain }), { discriminator = "kind" })
      T.eq(rust_serde.rust_source_from_type_ref(ref, "Pet"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        '#[serde(tag = "kind")]',
        "pub enum Pet {",
        '    #[serde(rename = "dog")]',
        "    Dog {",
        "        bark: bool,",
        "    },",
        '    #[serde(rename = "cat")]',
        "    Cat {",
        '        #[serde(skip_serializing_if = "Option::is_none")]',
        "        meow_loud: Option<bool>,",
        "    },",
        '    #[serde(rename = "plain-old")]',
        "    PlainOld,",
        "}",
      }))
    end)

    T.it("a variant carrying no string tag falls back to a positional variant name", function()
      local ref = t(types.union({ t(types.object({ a = t(types.string) })) }), { discriminator = "kind" })
      T.eq(rust_serde.rust_source_from_type_ref(ref, "Bad"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        '#[serde(tag = "kind")]',
        "pub enum Bad {",
        "    Variant0 {",
        "        a: String,",
        "    },",
        "}",
      }))
    end)

    T.it("union without discriminator -> untagged enum", function()
      local ref = t(types.union({ t(types.string), t(types.number) }))
      local rust = rust_serde.rust_source_from_type_ref(ref, "StringOrNumber")
      contains(rust, "#[serde(untagged)]")
      contains(rust, "pub enum StringOrNumber {")
      contains(rust, "Variant0(String),")
      contains(rust, "Variant1(f64),")
    end)

    T.it("an untagged variant that needs a declaration is hoisted under the enum's own name", function()
      local ref = t(types.union({
        t(types.string),
        t(types.object({ x = t(types.integer) })),
        t(types.array(t(types.object({ y = t(types.string) })))),
      }))
      T.eq(rust_serde.rust_source_from_type_ref(ref, "U"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct UVariant1 {",
        "    pub x: i64,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub struct UVariant2 {",
        "    pub y: String,",
        "}",
        "",
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "#[serde(untagged)]",
        "pub enum U {",
        "    Variant0(String),",
        "    Variant1(UVariant1),",
        "    Variant2(Vec<UVariant2>),",
        "}",
      }))
    end)

  end)

  T.describe("rust_source_from_type_ref without a name", function()

    T.it("returns just the inline type expression", function()
      T.eq(rust_serde.rust_source_from_type_ref(t(types.string)), "String")
      T.eq(rust_serde.rust_source_from_type_ref(t(types.array(t(types.integer)))), "Vec<i64>")
    end)

  end)

  T.describe("rust_source_from_type_ref with a name for non-struct/enum kinds", function()

    T.it("emits a pub type alias", function()
      T.eq(rust_serde.rust_source_from_type_ref(t(types.string), "Name"), "pub type Name = String;")
      T.eq(
        rust_serde.rust_source_from_type_ref(t(types.map(t(types.string), t(types.integer))), "M"),
        "pub type M = HashMap<String, i64>;"
      )
    end)

    T.it("an empty enum is still a declaration, not an alias", function()
      T.eq(rust_serde.rust_source_from_type_ref(t(types.enum({})), "E"), joined({
        "#[derive(Debug, Clone, Serialize, Deserialize)]",
        "pub enum E {",
        "}",
      }))
    end)

  end)

end)
