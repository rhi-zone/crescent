-- lib/fractal/type_ref_rust_wasm_bindgen_test.lua
-- Tests for lib/fractal/type_ref_rust_wasm_bindgen.lua, ported from fractal's
-- packages/type-ir/src/wasm-bindgen.test.ts.
--
-- Every expected string here was produced by running the TS projector on the
-- same input (`bun run` against packages/type-ir/src/rust-wasm-bindgen.ts), so
-- these are byte-comparisons against fractal's actual output, not
-- reconstructions from reading the code.
--
-- Two families of divergence from the TS test file, both structural:
--
--   1. The TS's `toThrow(/regex/)` cases become `(nil, errmsg)` assertions
--      with a plain substring check — the message text is carried across
--      verbatim, so the same fragment the TS regex matched is asserted here.
--   2. Struct field order is byte order, not `Object.entries` insertion
--      order (see the module header). Where a case's field names don't
--      happen to be alphabetical, the expectation below is the byte-ordered
--      one; `struct field order` covers that difference explicitly.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")
local common = require("lib.fractal.type_ref_kinds_common")
local wb = require("lib.fractal.type_ref_rust_wasm_bindgen")

local types = type_ref.types
local t = type_ref.type_ref_from_shape
local inline = wb.wasm_bindgen_type_from_type_ref
local source = wb.wasm_bindgen_source_from_type_ref

-- Assert a successful projection equals `expected` exactly.
--: (got: string | nil, err: string | nil, expected: string) -> nil
local function eq_ok(got, err, expected)
	T.eq(err, nil)
	T.eq(got, expected)
end

-- Assert a refusal: no value, and a message containing `fragment`.
--: (got: string | nil, err: string | nil, fragment: string) -> nil
local function refused(got, err, fragment)
	T.eq(got, nil)
	T.ok(type(err) == "string", "expected an error message")
	T.ok(
		type(err) == "string" and err:find(fragment, 1, true) ~= nil,
		"expected error to contain " .. fragment .. ", got " .. tostring(err)
	)
end

-- Join the expected output's lines. Written per-line rather than as one
-- long string so a diff points at the offending line.
--: (...string) -> string
local function lines(...)
	local parts = { ... } --[[: { [integer]: string }]]
	return table.concat(parts, "\n")
end

T.describe("lib.fractal.type_ref_rust_wasm_bindgen", function()

	T.describe("primitives", function()

		T.it("boolean -> bool", function()
			local got, err = inline(t(types.boolean))
			eq_ok(got, err, "bool")
		end)

		T.it("number -> f64", function()
			local got, err = inline(t(types.number))
			eq_ok(got, err, "f64")
		end)

		T.it("integer (bare) -> i64", function()
			local got, err = inline(t(types.integer))
			eq_ok(got, err, "i64")
		end)

		T.it("int32 -> i32", function()
			local got, err = inline(common.int32())
			eq_ok(got, err, "i32")
		end)

		T.it("int64 -> i64", function()
			local got, err = inline(common.int64())
			eq_ok(got, err, "i64")
		end)

		T.it("uint32 -> u32", function()
			local got, err = inline(common.uint32())
			eq_ok(got, err, "u32")
		end)

		T.it("string -> String", function()
			local got, err = inline(t(types.string))
			eq_ok(got, err, "String")
		end)

		T.it("null -> ()", function()
			local got, err = inline(t(types.null))
			eq_ok(got, err, "()")
		end)

		T.it("unknown -> JsValue (wasm-bindgen's real 'any JS value' primitive)", function()
			local got, err = inline(t(types.unknown))
			eq_ok(got, err, "JsValue")
		end)

		T.it("bytes -> Vec<u8>", function()
			local got, err = inline(common.bytes())
			eq_ok(got, err, "Vec<u8>")
		end)

		T.it("uuid falls through the lattice to string -> String", function()
			local got, err = inline(common.uuid())
			eq_ok(got, err, "String")
		end)

		T.it("nullable -> Option<T>", function()
			local got, err = inline(t(types.string, { nullable = true }))
			eq_ok(got, err, "Option<String>")
		end)

		T.it("optional -> Option<T>", function()
			local got, err = inline(t(types.integer, { optional = true }))
			eq_ok(got, err, "Option<i64>")
		end)

	end)

	T.describe("literals degrade to their base scalar", function()

		T.it("integral number -> i64", function()
			local got, err = inline(t(types.literal(3)))
			eq_ok(got, err, "i64")
		end)

		T.it("fractional number -> f64", function()
			local got, err = inline(t(types.literal(3.5)))
			eq_ok(got, err, "f64")
		end)

		T.it("string -> String", function()
			local got, err = inline(t(types.literal("a")))
			eq_ok(got, err, "String")
		end)

		T.it("boolean -> bool", function()
			local got, err = inline(t(types.literal(true)))
			eq_ok(got, err, "bool")
		end)

		T.it("the null sentinel -> ()", function()
			local got, err = inline(t(types.literal(type_ref.null)))
			eq_ok(got, err, "()")
		end)

	end)

	T.describe("Vec<T> element restrictions (confirmed against wasm-bindgen's boxed-slices docs)", function()

		T.it("array of string -> Vec<String>", function()
			local got, err = inline(t(types.array(t(types.string))))
			eq_ok(got, err, "Vec<String>")
		end)

		T.it("array of integer -> Vec<i64>", function()
			local got, err = inline(t(types.array(t(types.integer))))
			eq_ok(got, err, "Vec<i64>")
		end)

		T.it("array of unknown -> Vec<JsValue>", function()
			local got, err = inline(t(types.array(t(types.unknown))))
			eq_ok(got, err, "Vec<JsValue>")
		end)

		T.it("array of instance -> Vec<ClassName>", function()
			local got, err = inline(t(types.array(t(types.instance("Widget", "w.ts")))))
			eq_ok(got, err, "Vec<Widget>")
		end)

		T.it("array of boolean is refused — bool is not a documented Vec<T>/Box<[T]> element type", function()
			local got, err = inline(t(types.array(t(types.boolean))))
			refused(got, err, "Vec<bool>")
		end)

		T.it("array of array is refused — nested Vec<Vec<T>> needs serde-wasm-bindgen", function()
			local got, err = inline(t(types.array(t(types.array(t(types.string))))))
			refused(got, err, "nested Vec")
		end)

		T.it("array of bytes is refused — Vec<Vec<u8>> needs serde-wasm-bindgen", function()
			local got, err = inline(t(types.array(common.bytes())))
			refused(got, err, "Vec<Vec<u8>>")
		end)

		T.it("stream degrades to Vec<T> (materialized, same convention as rust-serde)", function()
			local got, err = inline(t(types.stream(t(types.string))))
			eq_ok(got, err, "Vec<String>")
		end)

		T.it("page degrades to Vec<T>", function()
			local got, err = inline(t(types.page(t(types.string), "cursor")))
			eq_ok(got, err, "Vec<String>")
		end)

		T.it("an inline (unhoisted) object element stays JsValue", function()
			local got, err = inline(t(types.array(t(types.object({ a = t(types.string) })))))
			eq_ok(got, err, "Vec<JsValue>")
		end)

		T.it("an inline (unhoisted) enum element becomes the member-count placeholder", function()
			local got, err = inline(t(types.array(t(types.enum({ "a" })))))
			eq_ok(got, err, "Vec<Enum1>")
		end)

	end)

	T.describe("structs", function()

		T.it("object -> #[derive(Clone)] #[wasm_bindgen(getter_with_clone)] struct with pub fields", function()
			local got, err = source(t(types.object({ name = t(types.string), age = t(types.integer) })), "Person")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Person {",
				"    pub age: i64,",
				"    pub name: String,",
				"}"
			))
		end)

		T.it("field order is byte order (the TS emits Object.entries insertion order)", function()
			local got, err = source(t(types.object({ zeta = t(types.string), alpha = t(types.string) })), "Ordered")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Ordered {",
				"    pub alpha: String,",
				"    pub zeta: String,",
				"}"
			))
		end)

		T.it("field name needing snake_case conversion gets a js_name rename", function()
			local got, err = source(t(types.object({ firstName = t(types.string) })), "Person")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Person {",
				'    #[wasm_bindgen(js_name = "firstName")]',
				"    pub first_name: String,",
				"}"
			))
		end)

		T.it("a field named after a Rust keyword is escaped and renamed", function()
			local got, err = source(t(types.object({ type = t(types.string) })), "K")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct K {",
				'    #[wasm_bindgen(js_name = "type")]',
				"    pub r#type: String,",
				"}"
			))
		end)

		T.it("descriptions, deprecated, readonly and optional all land on the right lines", function()
			local ref = t(
				types.object({
					id = t(types.string, { readonly = true, description = "the id" }),
					type = t(types.string),
					firstName = t(types.string, { optional = true, deprecated = true }),
				}),
				{ description = "A person", deprecated = true }
			)
			local got, err = source(ref, "Person")
			eq_ok(got, err, lines(
				"/// A person",
				"#[deprecated]",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Person {",
				'    #[wasm_bindgen(js_name = "firstName")]',
				"    #[deprecated]",
				"    pub first_name: Option<String>,",
				"    /// the id",
				"    #[wasm_bindgen(readonly)]",
				"    pub id: String,",
				'    #[wasm_bindgen(js_name = "type")]',
				"    pub r#type: String,",
				"}"
			))
		end)

		T.it("nested anonymous object fields hoist named struct declarations, dependency-first", function()
			local ref = t(types.object({
				address = t(types.object({ city = t(types.string), zipCode = t(types.string) })),
				tags = t(types.array(t(types.object({ label = t(types.string) })))),
			}))
			local got, err = source(ref, "Person")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Address {",
				"    pub city: String,",
				'    #[wasm_bindgen(js_name = "zipCode")]',
				"    pub zip_code: String,",
				"}",
				"",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Tags {",
				"    pub label: String,",
				"}",
				"",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Person {",
				"    pub address: Address,",
				"    pub tags: Vec<Tags>,",
				"}"
			))
		end)

		T.it("a hoist chain emits innermost-first", function()
			local ref = t(types.object({ a = t(types.object({ b = t(types.object({ c = t(types.string) })) })) }))
			local got, err = source(ref, "Outer")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct B {",
				"    pub c: String,",
				"}",
				"",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct A {",
				"    pub b: B,",
				"}",
				"",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct Outer {",
				"    pub a: A,",
				"}"
			))
		end)

		T.it("a refusal inside a nested field propagates out of the hoist", function()
			local ref = t(types.object({ inner = t(types.object({ m = t(types.map(t(types.string), t(types.integer))) })) }))
			local got, err = source(ref, "Outer")
			refused(got, err, "serde-wasm-bindgen")
		end)

		T.it("an anonymous object in inline position stays JsValue", function()
			local got, err = inline(t(types.object({ a = t(types.string) })))
			eq_ok(got, err, "JsValue")
		end)

		T.it("meta.typeName names an object in inline position", function()
			local got, err = inline(t(types.object({}), { typeName = "Widget" }))
			eq_ok(got, err, "Widget")
		end)

	end)

	T.describe("enums (fieldless / string-discriminant only)", function()

		T.it("enum -> #[wasm_bindgen] pub enum with string discriminants", function()
			local got, err = source(t(types.enum({ "active", "not-active", "IN_REVIEW" })), "Status")
			eq_ok(got, err, lines(
				"#[wasm_bindgen]",
				"pub enum Status {",
				'    Active = "active",',
				'    NotActive = "not-active",',
				'    INREVIEW = "IN_REVIEW",',
				"}"
			))
		end)

		T.it("inline enum with no name falls back to the member-count placeholder", function()
			local got, err = inline(t(types.enum({ "a", "b" })))
			eq_ok(got, err, "Enum2")
		end)

		T.it("meta.enumName names an enum in inline position", function()
			local got, err = inline(t(types.enum({ "a", "b" }), { enumName = "Foo" }))
			eq_ok(got, err, "Foo")
		end)

	end)

	T.describe("functions", function()

		T.it("function (no thisType) -> #[wasm_bindgen] pub fn with a todo!() stub body", function()
			local ref = t(types.function_(
				{ { name = "a", type = t(types.integer) }, { name = "b", type = t(types.integer) } },
				t(types.integer)
			))
			local got, err = source(ref, "add")
			eq_ok(got, err, lines(
				"#[wasm_bindgen]",
				"pub fn add(a: i64, b: i64) -> i64 {",
				'    todo!("implement add")',
				"}"
			))
		end)

		T.it("void return omits the arrow", function()
			local ref = t(types.function_({ { name = "msg", type = t(types.string) } }, t(types.void)))
			local got, err = source(ref, "log")
			eq_ok(got, err, lines(
				"#[wasm_bindgen]",
				"pub fn log(msg: String) {",
				'    todo!("implement log")',
				"}"
			))
		end)

		T.it("a camelCase function name gets a js_name rename and a snake_case Rust identifier", function()
			local ref = t(types.function_({}, t(types.void)))
			local got, err = source(ref, "doTheThing")
			eq_ok(got, err, lines(
				'#[wasm_bindgen(js_name = "doTheThing")]',
				"pub fn do_the_thing() {",
				'    todo!("implement do_the_thing")',
				"}"
			))
		end)

		T.it("params carry per-parameter js_name renames, keyword escapes, Option and hoists", function()
			local ref = t(
				types.function_(
					{
						{ name = "firstArg", type = t(types.object({ x = common.int32() })) },
						{ name = "type", type = t(types.string) },
						{ name = "maybe", type = t(types.string, { optional = true }) },
					},
					t(types.object({ y = t(types.string) }))
				),
				{ description = "does a thing" }
			)
			local got, err = source(ref, "doTheThing")
			eq_ok(got, err, lines(
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct FirstArg {",
				"    pub x: i32,",
				"}",
				"",
				"#[derive(Clone)]",
				"#[wasm_bindgen(getter_with_clone)]",
				"pub struct DoTheThingReturn {",
				"    pub y: String,",
				"}",
				"",
				"/// does a thing",
				'#[wasm_bindgen(js_name = "doTheThing")]',
				'pub fn do_the_thing(#[wasm_bindgen(js_name = "firstArg")] first_arg: FirstArg, '
					.. '#[wasm_bindgen(js_name = "type")] r#type: String, maybe: Option<String>) -> DoTheThingReturn {',
				'    todo!("implement do_the_thing")',
				"}"
			))
		end)

		T.it("an enum-valued param hoists its declaration too", function()
			local ref = t(types.function_({ { name = "status", type = t(types.enum({ "a", "b" })) } }, t(types.void)))
			local got, err = source(ref, "setStatus")
			eq_ok(got, err, lines(
				"#[wasm_bindgen]",
				"pub enum Status {",
				'    A = "a",',
				'    B = "b",',
				"}",
				"",
				'#[wasm_bindgen(js_name = "setStatus")]',
				"pub fn set_status(status: Status) {",
				'    todo!("implement set_status")',
				"}"
			))
		end)

		T.it("a function requires a name", function()
			local got, err = source(t(types.function_({}, t(types.void))))
			refused(got, err, "requires a name")
		end)

		T.it("a function with a thisType is refused — it needs an impl block, not a free function", function()
			local ref = t(types.function_({}, t(types.void), t(types.instance("Foo", "foo.ts"))))
			local got, err = source(ref, "bar")
			refused(got, err, "free-function wasm-bindgen mapping")
		end)

		T.it("a method is refused even with a name", function()
			local got, err = source(t(types.method({}, t(types.void))), "bar")
			refused(got, err, "impl block")
		end)

		T.it("a refusal inside a param type propagates out", function()
			local ref = t(types.function_({ { name = "t", type = t(types.tuple({ t(types.string) })) } }, t(types.void)))
			local got, err = source(ref, "f")
			refused(got, err, "Rust tuples are not among")
		end)

	end)

	T.describe("named non-struct declarations become type aliases", function()

		T.it("array -> pub type alias", function()
			local got, err = source(t(types.array(t(types.string))), "Names")
			eq_ok(got, err, "pub type Names = Vec<String>;")
		end)

		T.it("optional primitive -> pub type alias over Option<T>", function()
			local got, err = source(t(types.string, { optional = true }), "MaybeName")
			eq_ok(got, err, "pub type MaybeName = Option<String>;")
		end)

		T.it("a refused kind is still refused in named position", function()
			local got, err = source(t(types.never), "Bottom")
			refused(got, err, "bottom/uninhabited")
		end)

	end)

	T.describe("genuinely unsupported kinds are refused with an explanatory message", function()

		T.it("union (tagged)", function()
			local ref = t(
				types.union({
					t(types.object({ kind = t(types.literal("a")) })),
					t(types.object({ kind = t(types.literal("b")) })),
				}),
				{ discriminator = "kind" }
			)
			local got, err = inline(ref)
			refused(got, err, "dynamic union")
		end)

		T.it("union (untagged)", function()
			local got, err = inline(t(types.union({ t(types.string), t(types.integer) })))
			refused(got, err, "dynamic union")
		end)

		T.it("union in named position shares the same message", function()
			local got, err = source(t(types.union({ t(types.string) })), "U")
			refused(got, err, "dynamic union")
		end)

		T.it("map — needs serde-wasm-bindgen", function()
			local got, err = inline(t(types.map(t(types.string), t(types.integer))))
			refused(got, err, "serde-wasm-bindgen")
		end)

		T.it("tuple", function()
			local got, err = inline(t(types.tuple({ t(types.string), t(types.integer) })))
			refused(got, err, "Rust tuples are not among")
		end)

		T.it("intersection", function()
			local ref = t(types.intersection({
				t(types.object({ a = t(types.string) })),
				t(types.object({ b = t(types.string) })),
			}))
			local got, err = inline(ref)
			refused(got, err, "struct-merge")
		end)

		T.it("interface", function()
			local got, err = inline(t(types.interface({ foo = t(types.method({}, t(types.void))) })))
			refused(got, err, "service/trait-object")
		end)

		T.it("never", function()
			local got, err = inline(t(types.never))
			refused(got, err, "bottom/uninhabited")
		end)

		T.it("bare function in inline position (not a top-level declaration)", function()
			local got, err = inline(t(types.function_({}, t(types.void))))
			refused(got, err, "named top-level declaration")
		end)

		T.it("every refusal message keeps the greppable toWasmBindgen: prefix", function()
			local _, err = inline(t(types.never))
			T.ok(type(err) == "string" and err:sub(1, 15) == "toWasmBindgen: ")
		end)

		T.it("a kind with no handler and no known ancestor is reported as unhandled", function()
			local got, err = inline({ shape = { kind = "wb_unregistered_kind" }, meta = {} })
			refused(got, err, 'unhandled kind "wb_unregistered_kind"')
		end)

	end)

	T.describe("references (name pass-through, assumes declared elsewhere)", function()

		T.it("instance -> className", function()
			local got, err = inline(t(types.instance("Widget", "widget.ts")))
			eq_ok(got, err, "Widget")
		end)

		T.it("ref -> target", function()
			local got, err = inline(t(types.ref("Widget")))
			eq_ok(got, err, "Widget")
		end)

	end)

end)
