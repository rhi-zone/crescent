-- lib/fractal/ffi_ir_rust_c_abi_test.lua
-- Tests for lib/fractal/ffi_ir_rust_c_abi.lua (the Rust-implementing-a-C-ABI
-- projector), ported from fractal's packages/ffi-ir/src/rust-c-abi.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil, errmsg)`
-- assertions: the projector returns its failures rather than throwing (see the
-- port's file header), so each such test asserts the value is nil and that the
-- message still carries the substring the TS regex matched.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local rust     = require("lib.fractal.ffi_ir_rust_c_abi")
local type_ref = require("lib.fractal.type_ref")

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

-- The C-target convention for referencing an opaque resource by pointer: a
-- plain `ref` TypeRef carrying `opaque-handle` ownership (NOT the
-- `resource`-discipline `resource_ref` helper, which is the WIT-oriented
-- own/borrow convention this target explicitly does not implement).
--: (resource_name: string, free_fn: string | nil) -> TypeRef
local function handle_ref(resource_name, free_fn)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(free_fn)
	)
end

T.describe("lib.fractal.ffi_ir_rust_c_abi", function()

	T.describe("to_rust_c_abi_type", function()

		T.it("copy discipline (or no ownership meta at all) maps straight through rust-serde's type mapping", function()
			T.eq(rust.to_rust_c_abi_type(t(types.integer)), "i64")
			T.eq(rust.to_rust_c_abi_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "bool")
		end)

		T.it("opaque-handle discipline becomes a raw *mut pointer to the underlying Rust type", function()
			T.eq(rust.to_rust_c_abi_type(handle_ref("FileHandle", nil)), "*mut FileHandle")
		end)

		T.it("refcount discipline is reported — no native C mechanism, out of scope by design", function()
			local rust_type, err = rust.to_rust_c_abi_type(ffi_ir.with_ownership(t(types.integer), ownership.refcount()))
			T.eq(rust_type, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "refcount" for C target')) end
		end)

		T.it("resource discipline (own/borrow) is reported — WIT-only, out of scope for C", function()
			local own_type, own_err = rust.to_rust_c_abi_type(ffi_ir.resource_ref("FileHandle", "own"))
			T.eq(own_type, nil)
			T.ok(own_err ~= nil)
			if own_err ~= nil then T.ok(contains(own_err, 'unsupported ownership discipline "resource" for C target')) end

			local borrow_type, borrow_err = rust.to_rust_c_abi_type(ffi_ir.resource_ref("FileHandle", "borrow"))
			T.eq(borrow_type, nil)
			T.ok(borrow_err ~= nil)
			if borrow_err ~= nil then
				T.ok(contains(borrow_err, 'unsupported ownership discipline "resource" for C target'))
			end
		end)

	end)

	T.describe("to_rust_c_abi — function", function()

		T.it("a simple free function with copy-discipline params/return", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			local src, err = rust.to_rust_c_abi(add_fn, "add")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "#[no_mangle]"))
				T.ok(contains(src, 'pub extern "C" fn add(a: i64, b: i64) -> i64 {'))
				T.ok(contains(src, "todo!("))
			end
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = rust.to_rust_c_abi(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a function taking a resource parameter uses the opaque-handle pointer convention", function()
			local close_fn = f(boundary.function_(
				{ { name = "handle", type = handle_ref("FileHandle", "file_handle_free") } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			local src, err = rust.to_rust_c_abi(close_fn, "close")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, 'pub extern "C" fn close(handle: *mut FileHandle) {'))
				-- a void return omits the arrow entirely
				T.ok(not contains(src, "->"))
			end
		end)

	end)

	T.describe("to_rust_c_abi — resource", function()

		T.it("a resource with a constructor, methods, and an auto-generated destructor", function()
			local read_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.array(t(types.integer))), ownership.copy()),
				"FileHandle"
			))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))

			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", "file_handle_free")
			))

			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = rust.to_rust_c_abi(fs_module, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				-- opaque struct
				T.ok(contains(src, "#[repr(C)]"))
				T.ok(contains(src, "pub struct FileHandle {"))
				T.ok(contains(src, "_private: [u8; 0],"))

				-- constructor (a plain module function returning an opaque-handle pointer)
				T.ok(contains(src, 'pub extern "C" fn open(path: String) -> *mut FileHandle {'))

				-- method, receiver-prefixed with a synthesized handle parameter
				T.ok(contains(src, 'pub extern "C" fn file_handle_read(handle: *mut FileHandle) -> Vec<i64> {'))

				-- auto-generated destructor
				T.ok(contains(src, 'pub extern "C" fn file_handle_free(handle: *mut FileHandle) {'))
				T.ok(contains(src, "drop(Box::from_raw(handle));"))
			end
		end)

		T.it("resource emission ignores an explicit name argument in favor of the shape's own name", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src = rust.to_rust_c_abi(file_handle, "SomeOtherName")
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "pub struct FileHandle {"))
				T.ok(not contains(src, "SomeOtherName"))
			end
		end)

	end)

	T.describe("to_rust_c_abi — module", function()

		T.it("concatenates all contained functions and resources with no module wrapper (C has no module system)", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", nil)
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = rust.to_rust_c_abi(fs_module, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, 'pub extern "C" fn open('))
				T.ok(contains(src, "pub struct FileHandle {"))
				T.ok(contains(src, 'pub extern "C" fn file_handle_close('))
				T.ok(contains(src, 'pub extern "C" fn file_handle_free('))
				-- no "mod fs" or namespace wrapper of any kind
				T.ok(not contains(src, "mod fs"))
			end
		end)

		T.it("an unsupported discipline inside a module's function is propagated, not swallowed", function()
			local bad_fn = f(boundary.function_(
				{ { name = "n", type = ffi_ir.with_ownership(t(types.integer), ownership.refcount()) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local mod = f(boundary.module("fs", { bump = bad_fn }, {}))

			local src, err = rust.to_rust_c_abi(mod, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "refcount" for C target')) end
		end)

	end)

end)
