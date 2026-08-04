-- lib/fractal/ffi_ir_dotnet_test.lua
-- Tests for lib/fractal/ffi_ir_dotnet.lua (the .NET/P-Invoke backend), ported
-- from fractal's packages/ffi-ir/src/dotnet.test.ts.
--
-- Two mechanical differences from the TS source, both following the porting
-- conventions the sibling fractal ports already set:
--
--   - The TS `expect(src).toContain(...)` becomes `T.ok(contains(src, ...))`
--     against the plain-text `contains` helper below (lib/test/assert has no
--     substring assertion, and `eq` is `~=`, i.e. identity on tables).
--   - The TS `expect(() => ...).toThrow(/re/)` becomes a `(nil, errmsg)`
--     return check: this repo never throws on a data error, so every throw in
--     dotnet.ts is an error return here (see the backend file's ERROR
--     CONVENTION header). The regexes' substance is asserted as a plain
--     substring of the message.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local dotnet   = require("lib.fractal.ffi_ir_dotnet")
local ffi_ir   = require("lib.fractal.ffi_ir")
local type_ref = require("lib.fractal.type_ref")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- TYPECHECKER WORKAROUND: verbatim copies of type_ref.lua's declarations,
-- required in every consumer of the fractal type/FFI modules. See the same
-- three lines (and the full explanation) in lib/fractal/ffi_ir.lua and
-- lib/fractal/ffi_ir_dotnet.lua, and the TODO.md entry they point at.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

-- Plain-text substring test. `haystack` is `string | nil` because every
-- emitter entry point returns `(string | nil, string | nil)`, so a failed
-- projection reads as "does not contain" rather than erroring here — the
-- accompanying `T.eq(src, nil)` / message assertions are what pin a failure.
--: (haystack: string | nil, needle: string) -> boolean
local function contains(haystack, needle)
	if haystack == nil then return false end
	return haystack:find(needle, 1, true) ~= nil
end

-- The C-target convention for referencing an opaque resource by pointer: a
-- plain `ref` TypeRef carrying ownership metadata — matching c-abi's own test
-- helper for the same reason (this is the consumer-side counterpart to that
-- producer). Defaults to `opaque-handle`, the discipline c-abi actually emits;
-- other disciplines are passed explicitly where the uniform-IntPtr behavior is
-- under test.
--: (resource_name: string, discipline: OwnershipDiscipline | nil) -> TypeRef
local function handle_ref(resource_name, discipline)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		discipline or ownership.opaque_handle()
	)
end

T.describe("lib.fractal.ffi_ir_dotnet", function()

	T.describe("to_dotnet_type", function()

		T.it("copy discipline (or no ownership meta at all) maps scalar kinds to their closest C# type", function()
			T.eq(dotnet.to_dotnet_type(t(types.integer)), "long")
			T.eq(dotnet.to_dotnet_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "bool")
			T.eq(dotnet.to_dotnet_type(t(types.string)), "string")
			T.eq(dotnet.to_dotnet_type(t(types.number)), "double")
		end)

		T.it("fixed-width int/float kinds map to their exact-width C# counterpart", function()
			T.eq(dotnet.to_dotnet_type(t({ kind = "int32" })), "int")
			T.eq(dotnet.to_dotnet_type(t({ kind = "uint64" })), "ulong")
			T.eq(dotnet.to_dotnet_type(t({ kind = "float32" })), "float")
		end)

		T.it("opaque-handle discipline becomes IntPtr", function()
			T.eq(dotnet.to_dotnet_type(handle_ref("FileHandle", ownership.opaque_handle())), "IntPtr")
		end)

		T.it("refcount and resource(own/borrow) disciplines ALSO become IntPtr", function()
			-- Uniform handle representation: ownership discipline is a
			-- caller-side bookkeeping concern, not a marshaling one (see the
			-- backend file's header).
			T.eq(dotnet.to_dotnet_type(handle_ref("FileHandle", ownership.refcount())), "IntPtr")
			T.eq(dotnet.to_dotnet_type(handle_ref("FileHandle", ownership.resource("own"))), "IntPtr")
			T.eq(dotnet.to_dotnet_type(handle_ref("FileHandle", ownership.resource("borrow"))), "IntPtr")
		end)

		T.it("a structural kind with no P/Invoke-compatible scalar mapping errors, rather than guessing a struct layout", function()
			local arr, arr_err = dotnet.to_dotnet_type(t(types.array(t(types.integer))))
			T.eq(arr, nil)
			T.ok(contains(arr_err, 'unsupported type-ir kind "array"'))

			local obj, obj_err = dotnet.to_dotnet_type(t(types.object({})))
			T.eq(obj, nil)
			T.ok(contains(obj_err, 'unsupported type-ir kind "object"'))
		end)

		T.it("KNOWN GAP: a semantic-string/temporal kind errors here, where upstream lowers it to C# string", function()
			-- Pins the CURRENT behavior of the unported `kinds/common` gap
			-- documented in the backend file's header. `uuid`/`uri`/`email`
			-- (kinds/semantic-strings), `time` (kinds/date-time) and `duration`
			-- (kinds/duration) reach C# `string` upstream ONLY through the
			-- ancestor edge those modules register into type-ir's lattice —
			-- crescent has no port of them, so `resolve` finds no ancestor and
			-- the kind is reported unsupported instead.
			--
			-- WHEN `kinds/common` IS PORTED: these five stop erroring and
			-- become `"string"` (and, in a signature, pull
			-- `StringMarshalling = StringMarshalling.Utf8` onto the
			-- declaration). Flip this test to assert that then; it exists so
			-- the change is caught rather than silent.
			local semantic_string_kinds = { "uuid", "uri", "email", "time", "duration" }
			for i = 1, #semantic_string_kinds do
				local kind = semantic_string_kinds[i]
				local cs, err = dotnet.to_dotnet_type(t({ kind = kind }))
				T.eq(cs, nil)
				T.ok(contains(err, 'unsupported type-ir kind "' .. kind .. '"'))
			end

			-- `datetime`/`date` are roots upstream too (deliberately NOT
			-- subtypes of `string`), so they error on both sides — no delta,
			-- and no change expected when the port lands.
			local dt = dotnet.to_dotnet_type(t({ kind = "datetime" }))
			T.eq(dt, nil)
		end)

	end)

	T.describe("to_dotnet — function", function()

		T.it("a simple free function with copy-discipline params/return", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))
			local src = dotnet.to_dotnet(add_fn, "add", "my_native_lib")

			T.ok(contains(src, '[LibraryImport("my_native_lib", EntryPoint = "add")]'))
			T.ok(contains(src, "internal static partial long add(long a, long b);"))
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = dotnet.to_dotnet(fn, nil, "my_native_lib")
			T.eq(src, nil)
			T.ok(contains(err, '"function" requires a name'))
		end)

		T.it("a function requires a libraryName when projected standalone", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = dotnet.to_dotnet(fn, "doThing")
			T.eq(src, nil)
			T.ok(contains(err, '"function" requires a libraryName'))
		end)

		T.it("a bool parameter/return gets [MarshalAs(UnmanagedType.U1)] on both sides", function()
			local is_even_fn = f(boundary.function_(
				{ { name = "n", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.boolean), ownership.copy())
			))
			local src = dotnet.to_dotnet(is_even_fn, "is_even", "my_native_lib")

			T.ok(contains(src, "[return: MarshalAs(UnmanagedType.U1)]"))
			T.ok(contains(src, "internal static partial bool is_even(long n);"))
		end)

		T.it("a bool parameter (not just a return) gets the same MarshalAs annotation, inline", function()
			local set_flag_fn = f(boundary.function_(
				{ { name = "flag", type = ffi_ir.with_ownership(t(types.boolean), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local src = dotnet.to_dotnet(set_flag_fn, "set_flag", "my_native_lib")

			T.ok(contains(src, "internal static partial void set_flag([MarshalAs(UnmanagedType.U1)] bool flag);"))
		end)

		T.it("a string parameter/return adds StringMarshalling = StringMarshalling.Utf8 to the attribute", function()
			local greet_fn = f(boundary.function_(
				{ { name = "name", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.string), ownership.copy())
			))
			local src = dotnet.to_dotnet(greet_fn, "greet", "my_native_lib")

			T.ok(contains(src, '[LibraryImport("my_native_lib", EntryPoint = "greet", StringMarshalling = StringMarshalling.Utf8)]'))
			T.ok(contains(src, "internal static partial string greet(string name);"))
		end)

		T.it("a function with no string in its signature omits StringMarshalling entirely", function()
			local add_fn = f(boundary.function_(
				{ { name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))
			local src = dotnet.to_dotnet(add_fn, "identity", "my_native_lib")
			T.ok(src ~= nil)
			T.ok(not contains(src, "StringMarshalling"))
		end)

		T.it("a function taking a resource parameter uses the IntPtr handle convention", function()
			local close_fn = f(boundary.function_(
				{ { name = "handle", type = handle_ref("FileHandle") } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local src = dotnet.to_dotnet(close_fn, "close", "my_native_lib")

			T.ok(contains(src, "internal static partial void close(IntPtr handle);"))
		end)

	end)

	T.describe("to_dotnet — method", function()

		T.it("a method synthesizes an IntPtr receiver and a <receiver>_<method> entry point", function()
			local read_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.integer), ownership.copy()),
				"FileHandle"
			))
			local src = dotnet.to_dotnet(read_method, "read", "my_native_lib")

			T.ok(contains(src, '[LibraryImport("my_native_lib", EntryPoint = "file_handle_read")]'))
			T.ok(contains(src, "internal static partial long file_handle_read(IntPtr handle);"))
		end)

		T.it("a method requires a name and a libraryName", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))

			local no_name, name_err = dotnet.to_dotnet(read_method, nil, "my_native_lib")
			T.eq(no_name, nil)
			T.ok(contains(name_err, '"method" requires a name'))

			local no_lib, lib_err = dotnet.to_dotnet(read_method, "read")
			T.eq(no_lib, nil)
			T.ok(contains(lib_err, '"method" requires a libraryName'))
		end)

	end)

	T.describe("to_dotnet — resource", function()

		T.it("a resource with an opaque-handle method gets an IntPtr receiver plus an auto-generated free declaration", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))

			local src = dotnet.to_dotnet(file_handle, nil, "my_native_lib")

			T.ok(contains(src, "internal static partial class FileHandle"))
			T.ok(contains(src, "internal static partial long file_handle_read(IntPtr handle);"))
			T.ok(contains(src, '[LibraryImport("my_native_lib", EntryPoint = "file_handle_free")]'))
			T.ok(contains(src, "internal static partial void file_handle_free(IntPtr handle);"))
		end)

		T.it("resource emission ignores an explicit name argument in favor of the shape's own name", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src = dotnet.to_dotnet(file_handle, "SomeOtherName", "my_native_lib")
			T.ok(contains(src, "internal static partial class FileHandle"))
			T.ok(src ~= nil)
			T.ok(not contains(src, "SomeOtherName"))
		end)

		T.it("a resource requires a libraryName when projected standalone", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src, err = dotnet.to_dotnet(file_handle)
			T.eq(src, nil)
			T.ok(contains(err, '"resource" requires a libraryName'))
		end)

	end)

	T.describe("to_dotnet — module", function()

		T.it("wraps functions and resources into one static partial class, defaulting libraryName from the module's own name", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle")
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src = dotnet.to_dotnet(fs_module)

			T.ok(contains(src, "using System;"))
			T.ok(contains(src, "using System.Runtime.InteropServices;"))
			T.ok(contains(src, "internal static partial class Fs"))
			T.ok(contains(src, '[LibraryImport("fs", EntryPoint = "open"'))
			T.ok(contains(src, "internal static partial IntPtr open(string path);"))
			T.ok(contains(src, "internal static partial class FileHandle"))
			T.ok(contains(src, "internal static partial void file_handle_close(IntPtr handle);"))
			T.ok(contains(src, "internal static partial void file_handle_free(IntPtr handle);"))
		end)

		T.it("an explicit libraryName override wins over the module-name default", function()
			local noop_fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local fs_module = f(boundary.module("fs", { noop = noop_fn }, {}))
			local src = dotnet.to_dotnet(fs_module, nil, "custom_lib_name")
			T.ok(contains(src, "custom_lib_name"))
			T.ok(src ~= nil)
			T.ok(not contains(src, '"fs"'))
		end)

		T.it("an unsupported parameter kind inside a module propagates as an error return, not a partial emission", function()
			-- The (nil, errmsg) convention propagates through every builder:
			-- a module whose one function has an unmappable parameter yields
			-- no source at all, rather than source with a hole in it.
			local bad_fn = f(boundary.function_(
				{ { name = "rows", type = t(types.array(t(types.integer))) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local fs_module = f(boundary.module("fs", { load = bad_fn }, {}))
			local src, err = dotnet.to_dotnet(fs_module)
			T.eq(src, nil)
			T.ok(contains(err, 'unsupported type-ir kind "array"'))
		end)

	end)

	T.describe("identifier escaping", function()

		T.it("a parameter named with a C# keyword is escaped with @", function()
			local fn = f(boundary.function_(
				{ { name = "string", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local src = dotnet.to_dotnet(fn, "take", "my_native_lib")
			T.ok(contains(src, "internal static partial void take(long @string);"))
		end)

	end)

	T.describe("doc comments", function()

		T.it("meta.description becomes a /// <summary> line above the declaration", function()
			local fn = f(
				boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())),
				{ description = "does the thing" }
			)
			local src = dotnet.to_dotnet(fn, "do_thing", "my_native_lib")
			T.ok(contains(src, "/// <summary>does the thing</summary>"))
		end)

	end)

	T.describe("unhandled kinds", function()

		T.it("an ffi-ir kind with no .NET mapping reports it explicitly", function()
			local widget = f({ kind = "widget" })
			local src, err = dotnet.to_dotnet(widget, "widget", "my_native_lib")
			T.eq(src, nil)
			T.ok(contains(err, 'unhandled ffi-ir kind "widget"'))
		end)

	end)

end)
