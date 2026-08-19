-- lib/ffi-ir/rust_wasm_bindgen_test.lua
-- Tests for lib/ffi-ir/rust_wasm_bindgen.lua (the ffi-ir wasm-bindgen
-- projector), ported from fractal's
-- packages/ffi-ir/src/rust-wasm-bindgen.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil, errmsg)`
-- assertions: the projector returns its failures rather than throwing (see the
-- port's file header), so each such test asserts the value is nil and that the
-- message still carries the substring the TS regex matched.
--
-- `type_ref_kinds_common` is required here and deliberately not by the
-- projector — the CONSUMER opts into the refined-kind lattice, the same
-- convention `lib/type-ir/rust_wasm_bindgen_test.lua` follows for the data-shape
-- projector this one delegates into. It stands in for the TS source's
-- side-effect `import "@rhi-zone/fractal-type-ir/kinds/common"`, which exists
-- there for a type-level reason with no Lua counterpart (see the port's
-- header).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.ffi-ir")
local type_ref = require("lib.type-ir")
local common   = require("lib.type-ir.kinds_common")
local wb       = require("lib.ffi-ir.rust_wasm_bindgen")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- Substring test, standing in for the TS side's `toContain` / regex matching.
-- Plain (non-pattern) find, so a message's own punctuation is never read as a
-- Lua pattern.
--: (haystack: string, needle: string) -> boolean
local function contains(haystack, needle)
	return haystack:find(needle, 1, true) ~= nil
end

T.describe("lib.ffi-ir.rust_wasm_bindgen", function()

	T.describe("to_wasm_bindgen_ffi — function", function()

		T.it("a free function with copy-discipline params/return delegates to the type-ir projector", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			local src, err = wb.to_wasm_bindgen_ffi(add_fn, "add")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "#[wasm_bindgen]"))
				T.ok(contains(src, "pub fn add(a: i64, b: i64) -> i64 {"))
				T.ok(contains(src, "todo!("))
			end
		end)

		T.it("a function with no ownership meta at all also delegates (unannotated = copy-by-value default)", function()
			local fn = f(boundary.function_({ { name = "n", type = t(types.integer) } }, t(types.string)))
			local src, err = wb.to_wasm_bindgen_ffi(fn, "greet")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn greet(n: i64) -> String {")) end
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = wb.to_wasm_bindgen_ffi(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a data shape the type-ir projector itself refuses propagates that projector's own message", function()
			local fn = f(boundary.function_({}, t(types.map(t(types.string), t(types.integer)))))
			local src, err = wb.to_wasm_bindgen_ffi(fn, "lookup")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "toWasmBindgen:")) end
		end)

	end)

	T.describe("to_wasm_bindgen_ffi — resource, copy discipline", function()

		T.it("emits a #[derive(Clone)] struct plus an impl block, with copy as the unset default", function()
			local greet_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.string), ownership.copy()), "Greeter"))
			local greeter = f(boundary.resource("Greeter", { greet = greet_method }))

			local src, err = wb.to_wasm_bindgen_ffi(greeter, "Greeter")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "#[derive(Clone)]"))
				T.ok(contains(src, "#[wasm_bindgen]"))
				T.ok(contains(src, "pub struct Greeter {}"))
				T.ok(contains(src, "impl Greeter {"))
				T.ok(contains(src, "pub fn greet(&self) -> String {"))
				-- copy discipline never emits a share() method — that is
				-- refcount-only.
				T.ok(not contains(src, "pub fn share("))
			end
		end)

		T.it("an explicit ownership.copy() on the resource's own meta produces the same output as the default", function()
			local value_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "Counter"))
			local counter = f(boundary.resource("Counter", { value = value_method }), { ownership = ownership.copy() })

			local src, err = wb.to_wasm_bindgen_ffi(counter, "Counter")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "pub struct Counter {}"))
				T.ok(contains(src, "pub fn value(&self) -> i64 {"))
			end
		end)

	end)

	T.describe("to_wasm_bindgen_ffi — resource, refcount discipline", function()

		T.it("emits an Arc-wrapped struct, a share() method, and no custom release/registry code", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.string), ownership.copy()), "Handle"))
			local handle = f(boundary.resource("Handle", { read = read_method }), { ownership = ownership.refcount() })

			local src, err = wb.to_wasm_bindgen_ffi(handle, "Handle")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "struct HandleData {}"))
				T.ok(contains(src, "pub struct Handle {"))
				T.ok(contains(src, "inner: std::sync::Arc<HandleData>,"))
				T.ok(contains(src, "pub fn share(&self) -> Self {"))
				T.ok(contains(src, "Self { inner: std::sync::Arc::clone(&self.inner) }"))
				T.ok(contains(src, "pub fn read(&self) -> String {"))

				-- No hand-rolled release()/FinalizationRegistry glue —
				-- wasm-bindgen's own generated free() plus its internal
				-- weak-refs machinery covers deterministic and GC-driven
				-- cleanup, so none is emitted. The struct's comment mentions
				-- `free()` and GC timing in prose, but no `fn release` /
				-- `new FinalizationRegistry` construct appears.
				T.ok(not contains(src, "pub fn release"))
				T.ok(not contains(src, "new FinalizationRegistry"))
			end
		end)

		T.it("methods splice a leading &self, with a comma only when the method itself takes params", function()
			local set_method = f(boundary.method(
				{ { name = "value", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				t(types.void),
				"Counter"
			))
			local counter = f(boundary.resource("Counter", { set = set_method }), { ownership = ownership.refcount() })

			local src, err = wb.to_wasm_bindgen_ffi(counter, "Counter")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn set(&self, value: i64) {")) end
		end)

		T.it("a snake_cased method name splices the receiver correctly (Lua's %w excludes underscores)", function()
			local read_all = f(boundary.method({}, ffi_ir.with_ownership(t(types.string), ownership.copy()), "Handle"))
			local handle = f(boundary.resource("Handle", { read_all = read_all }), { ownership = ownership.refcount() })

			local src, err = wb.to_wasm_bindgen_ffi(handle, "Handle")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn read_all(&self) -> String {")) end
		end)

	end)

	T.describe("to_wasm_bindgen_ffi — unsupported ownership disciplines", function()

		T.it("opaque-handle on a parameter is reported, naming the parameter", function()
			local handle_param = ffi_ir.with_ownership(
				t(types.ref("FileHandle")),
				ownership.opaque_handle("file_handle_free")
			)
			local fn = f(boundary.function_({ { name = "handle", type = handle_param } }, t(types.void)))

			local src, err = wb.to_wasm_bindgen_ffi(fn, "close")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then
				T.ok(contains(err, 'unsupported ownership discipline "opaque-handle" for wasm-bindgen/JS target at parameter "handle"'))
			end
		end)

		T.it("opaque-handle on a return type is reported, naming the return position", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.ref("FileHandle")), ownership.opaque_handle(nil))))

			local src, err = wb.to_wasm_bindgen_ffi(fn, "open")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then
				T.ok(contains(err, 'unsupported ownership discipline "opaque-handle" for wasm-bindgen/JS target at return type'))
			end
		end)

		T.it("the resource (own/borrow) discipline is reported for both modes", function()
			local owned = ffi_ir.with_ownership(t(types.ref("FileHandle")), ownership.resource("own"))
			local borrowed = ffi_ir.with_ownership(t(types.ref("FileHandle")), ownership.resource("borrow"))

			local own_src, own_err = wb.to_wasm_bindgen_ffi(f(boundary.function_({ { name = "h", type = owned } }, t(types.void))), "take")
			T.eq(own_src, nil)
			T.ok(own_err ~= nil)
			if own_err ~= nil then
				T.ok(contains(own_err, 'unsupported ownership discipline "resource" for wasm-bindgen/JS target'))
			end

			local borrow_src, borrow_err =
				wb.to_wasm_bindgen_ffi(f(boundary.function_({ { name = "h", type = borrowed } }, t(types.void))), "peek")
			T.eq(borrow_src, nil)
			T.ok(borrow_err ~= nil)
			if borrow_err ~= nil then
				T.ok(contains(borrow_err, 'unsupported ownership discipline "resource" for wasm-bindgen/JS target'))
			end
		end)

		T.it("a resource DECLARED with an unsupported discipline is reported when the declaration is emitted", function()
			local method = f(boundary.method({}, t(types.void), "Thing"))

			local opaque_thing = f(boundary.resource("Thing", { m = method }), { ownership = ownership.opaque_handle(nil) })
			local opaque_src, opaque_err = wb.to_wasm_bindgen_ffi(opaque_thing, "Thing")
			T.eq(opaque_src, nil)
			T.ok(opaque_err ~= nil)
			if opaque_err ~= nil then
				T.ok(contains(opaque_err, 'unsupported ownership discipline "opaque-handle" for wasm-bindgen/JS target on resource "Thing"'))
			end

			local resource_thing = f(boundary.resource("Thing", { m = method }), { ownership = ownership.resource("own") })
			local resource_src, resource_err = wb.to_wasm_bindgen_ffi(resource_thing, "Thing")
			T.eq(resource_src, nil)
			T.ok(resource_err ~= nil)
			if resource_err ~= nil then
				T.ok(contains(resource_err, 'unsupported ownership discipline "resource" for wasm-bindgen/JS target on resource "Thing"'))
			end
		end)

	end)

	T.describe("to_wasm_bindgen_ffi — module", function()

		T.it("groups functions and resources into a pub mod block", function()
			local greet_method = f(boundary.method({}, t(types.string), "Greeter"))
			local greeter = f(boundary.resource("Greeter", { greet = greet_method }))
			local hello_fn = f(boundary.function_({}, t(types.string)))

			local mod = f(boundary.module("MyModule", { hello = hello_fn }, { Greeter = greeter }))

			local src, err = wb.to_wasm_bindgen_ffi(mod, "MyModule")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "pub mod my_module {"))
				T.ok(contains(src, "    use wasm_bindgen::prelude::*;"))
				T.ok(contains(src, "pub struct Greeter {}"))
				T.ok(contains(src, "pub fn hello() -> String {"))
				T.eq(src:sub(-1), "}")
			end
		end)

		T.it("a module requires a name", function()
			local mod = f(boundary.module("MyModule", {}, {}))
			local src, err = wb.to_wasm_bindgen_ffi(mod, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"module" requires a name')) end
		end)

	end)

	T.describe("to_wasm_bindgen_ffi — kind lattice", function()

		T.it("a consumer-registered kind whose ancestor is function falls back to the free-function path", function()
			ffi_ir.register_parent("hot_function", "function")
			local hot = f({ kind = "hot_function", params = {}, returnType = t(types.integer) })

			local src, err = wb.to_wasm_bindgen_ffi(hot, "tick")
			ffi_ir.register_parent("hot_function", nil)

			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn tick() -> i64 {")) end
		end)

		T.it("a boundary kind with no handler and no known ancestor is reported", function()
			local unknown_ref = f({ kind = "widget" })
			local src, err = wb.to_wasm_bindgen_ffi(unknown_ref, "Widget")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unhandled ffi-ir kind "widget"')) end
		end)

		T.it("a resource methods map entry that is neither a method nor a function is reported", function()
			local bogus = f(boundary.resource("Thing", { m = f({ kind = "module", name = "nope", functions = {}, resources = {} }) }))
			local src, err = wb.to_wasm_bindgen_ffi(bogus, "Thing")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'resource method "m" has unexpected kind "module"')) end
		end)

	end)

	T.describe("re-exported data-shape entry point", function()

		T.it("rust_wasm_bindgen_type_from_type_ref is the type-ir projector's own function, re-exported unchanged", function()
			-- `common` is required above so the refined-kind lattice is
			-- registered; `uuid` reaching the `string` handler through it is
			-- what makes this assertion meaningful rather than incidental.
			T.eq(common ~= nil, true)
			T.eq(wb.rust_wasm_bindgen_type_from_type_ref(t(types.integer)), "i64")
			T.eq(wb.rust_wasm_bindgen_type_from_type_ref(t({ kind = "uuid" })), "String")
		end)

	end)

end)
