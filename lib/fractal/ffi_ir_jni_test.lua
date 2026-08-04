-- lib/fractal/ffi_ir_jni_test.lua
-- Tests for lib/fractal/ffi_ir_jni.lua (the JNI projector), ported from
-- fractal's packages/ffi-ir/src/jni.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil,
-- errmsg)` assertions: the projector returns its failures rather than throwing
-- (see the port's file header), so each such test asserts the value is nil and
-- that the message still carries the substring the TS regex matched.
--
-- Where the TS asserts on emitted text with `toContain`, so does this file —
-- via the `contains` helper below, since lib/test/assert has no substring
-- assertion and its `eq` on strings is exact equality.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local jni      = require("lib.fractal.ffi_ir_jni")
local type_ref = require("lib.fractal.type_ref")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- Substring test, standing in for the TS side's `toContain`. Plain
-- (non-pattern) find, so emitted punctuation — `(`, `[`, `.` — is never read
-- as a Lua pattern.
--: (haystack: string, needle: string) -> boolean
local function contains(haystack, needle)
	return haystack:find(needle, 1, true) ~= nil
end

-- The JNI-target convention for referencing a native-owned resource by its
-- long-native-pointer-field handle: a plain `ref` TypeRef carrying
-- `opaque-handle` ownership — NOT the `resource`-discipline
-- `ffi_ir.resource_ref` helper, which is WIT's own own/borrow lend-count
-- convention this target does not implement (no citable JNI/Android NDK
-- mechanism enforces it; see the projector's file header). Mirrors the C-ABI
-- backend's tests' identical local helper.
--: (resource_name: string) -> TypeRef
local function handle_ref(resource_name)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(nil)
	)
end

T.describe("lib.fractal.ffi_ir_jni", function()

	T.describe("to_jni_type", function()

		T.it("copy discipline (or no ownership meta at all) maps to Java's primitive/reference vocabulary", function()
			T.eq(jni.to_jni_type(t(types.integer)), "long")
			T.eq(jni.to_jni_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "boolean")
			T.eq(jni.to_jni_type(ffi_ir.with_ownership(t(types.number), ownership.copy())), "double")
			T.eq(jni.to_jni_type(ffi_ir.with_ownership(t(types.string), ownership.copy())), "String")
		end)

		T.it("bytes maps to byte[]", function()
			T.eq(jni.to_jni_type(t({ kind = "bytes" })), "byte[]")
		end)

		T.it("void/null map to Java's void", function()
			T.eq(jni.to_jni_type(t(types.void)), "void")
			T.eq(jni.to_jni_type(t(types.null)), "void")
		end)

		T.it("fixed-width int/float kinds map to Java's exact-width counterpart", function()
			T.eq(jni.to_jni_type(t({ kind = "int32" })), "int")
			T.eq(jni.to_jni_type(t({ kind = "int64" })), "long")
			T.eq(jni.to_jni_type(t({ kind = "float32" })), "float")
			T.eq(jni.to_jni_type(t({ kind = "float64" })), "double")
		end)

		T.it("opaque-handle discipline becomes Java's long — the Android-documented native-pointer-field idiom", function()
			T.eq(jni.to_jni_type(handle_ref("FileHandle")), "long")
		end)

		T.it("refcount discipline is reported — no native JNI/JVM shared-refcount mechanism", function()
			local mapped, err = jni.to_jni_type(ffi_ir.with_ownership(t(types.integer), ownership.refcount()))
			T.eq(mapped, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "refcount" for JNI target')) end
		end)

		T.it("resource discipline (own/borrow) is reported — WIT-only, no JNI/Android NDK convention enforces it", function()
			for _, mode in ipairs({ "own", "borrow" }) do
				local ref = ffi_ir.with_ownership(t({ kind = "ref", target = "FileHandle" }), ownership.resource(mode))
				local mapped, err = jni.to_jni_type(ref)
				T.eq(mapped, nil)
				T.ok(err ~= nil)
				if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "resource" for JNI target')) end
			end
		end)

		T.it("a data shape outside the minimal Java vocabulary is reported, not guessed at", function()
			local mapped, err = jni.to_jni_type(t(types.object({ x = t(types.integer) })))
			T.eq(mapped, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported type-ir kind "object" for JNI target')) end
		end)

	end)

	T.describe("to_jni_ffi — function", function()

		T.it("a simple free function becomes a public static native method", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			T.eq(jni.to_jni_ffi(add_fn, "add"), "public static native long add(long a, long b);")
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = jni.to_jni_ffi(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a function taking a resource parameter uses the long native-handle convention", function()
			local close_fn = f(boundary.function_(
				{ { name = "handle", type = handle_ref("FileHandle") } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			T.eq(jni.to_jni_ffi(close_fn, "close"), "public static native void close(long handle);")
		end)

		T.it("a Java reserved word and an illegal identifier character are escaped, never re-cased", function()
			-- The JNI name IS the linkable symbol name (see the projector's
			-- file header), so this is the only rewriting the port performs.
			local fn = f(boundary.function_(
				{ { name = "class", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			T.eq(jni.to_jni_ffi(fn, "read-file"), "public static native void read_file(long class_);")
		end)

		T.it("a doc comment on the FfiRef's meta precedes the declaration", function()
			local fn = f(
				boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())),
				{ description = "flush pending writes" }
			)

			T.eq(jni.to_jni_ffi(fn, "flush"), "/** flush pending writes */\npublic static native void flush();")
		end)

		T.it("an unmappable parameter type propagates out of the declaration builder", function()
			local fn = f(boundary.function_(
				{ { name = "handle", type = ffi_ir.resource_ref("FileHandle", "own") } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local src, err = jni.to_jni_ffi(fn, "close")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "resource" for JNI target')) end
		end)

	end)

	T.describe("to_jni_ffi — method", function()

		T.it("a resource method becomes a public (non-static) native method with no explicit receiver parameter", function()
			local read = f(boundary.method(
				{ { name = "length", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t({ kind = "bytes" }), ownership.copy()),
				"FileHandle"
			))

			T.eq(jni.to_jni_ffi(read, "read"), "public native byte[] read(long length);")
		end)

		T.it("a no-arg method still needs no receiver parameter — JNI supplies it as the implicit jobject this", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			T.eq(jni.to_jni_ffi(close_method, "close"), "public native void close();")
		end)

		T.it("a method requires a name", function()
			local m = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local src, err = jni.to_jni_ffi(m, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"method" requires a name')) end
		end)

	end)

	T.describe("to_jni_ffi — resource", function()

		T.it("emits a class with a private long nativeHandle field and one instance native method per entry in methods", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t({ kind = "bytes" }), ownership.copy()), "FileHandle"))
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))

			local src, err = jni.to_jni_ffi(file_handle, "FileHandle")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "public class FileHandle {"))
				T.ok(contains(src, "private long nativeHandle;"))
				T.ok(contains(src, "public native byte[] read();"))
				T.ok(contains(src, "public native void close();"))
				-- No invented constructor — ffi-ir's `resource` kind has no
				-- constructor field, only a methods map (the same gap the
				-- C-ABI, ReScript and wasm-bindgen backends already document
				-- and decline to paper over). The TS assertion is
				-- `not.toMatch(/FileHandle\s*\(/)`; `%s*%(` is its Lua
				-- pattern, so this is a pattern find, not the plain
				-- `contains` used elsewhere in this file.
				T.eq(src:find("FileHandle%s*%("), nil)
			end
		end)

		T.it("methods are emitted in byte order of their keys, indented one level inside the class", function()
			-- Byte order stands in for the TS source's JS insertion order (see
			-- the projector's `ordered_keys`), so `close` precedes `read` here
			-- where the TS emits them insertion-ordered. Asserted on the whole
			-- string because the exact nesting and blank-line layout — four
			-- spaces per level, a blank line after the handle field, a blank
			-- line between declarations — is the part of this backend's output
			-- that a `contains` check cannot see.
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t({ kind = "bytes" }), ownership.copy()), "FileHandle"))
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))

			T.eq(jni.to_jni_ffi(file_handle, nil), table.concat({
				"public class FileHandle {",
				"    private long nativeHandle;",
				"",
				"    public native void close();",
				"",
				"    public native byte[] read();",
				"}",
			}, "\n"))
		end)

		T.it("resource emission ignores an explicit name argument in favor of the shape's own name", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src = jni.to_jni_ffi(file_handle, "SomeOtherName")
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "public class FileHandle {"))
				T.ok(not contains(src, "SomeOtherName"))
			end
		end)

		T.it("a resource method with a non-callable kind is reported", function()
			local bogus = f(boundary.resource("FileHandle", { read = f({ kind = "module" }) }))
			local src, err = jni.to_jni_ffi(bogus, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'has unexpected kind "module"')) end
		end)

	end)

	T.describe("to_jni_ffi — module", function()

		T.it("groups static native functions and nested resource classes into one class, with a System.loadLibrary block", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle")
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = jni.to_jni_ffi(fs_module, "fs")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "public class Fs {"))
				T.ok(contains(src, 'System.loadLibrary("fs");'))
				T.ok(contains(src, "public static native long open(String path);"))
				T.ok(contains(src, "public static class FileHandle {"))
				T.ok(contains(src, "public native void close();"))
			end
		end)

		T.it("nests the loadLibrary block, functions and resource classes one level in, in that order", function()
			-- The layout assertion the `contains` checks above cannot make: a
			-- nested resource class's own methods sit two levels deep, and the
			-- `static { ... }` block comes first regardless of key order.
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			T.eq(jni.to_jni_ffi(fs_module, nil), table.concat({
				"public class Fs {",
				"    static {",
				'        System.loadLibrary("fs");',
				"    }",
				"",
				"    public static native void open();",
				"",
				"    public static class FileHandle {",
				"        private long nativeHandle;",
				"",
				"        public native void close();",
				"    }",
				"}",
			}, "\n"))
		end)

		T.it("the module's class name is PascalCased while the loadLibrary argument stays verbatim", function()
			-- The naming judgment call carried over from the TS source: one
			-- `name` field serves both, since ffi-ir carries no second name.
			local fs_module = f(boundary.module("file_system", {}, {}))
			local src = jni.to_jni_ffi(fs_module, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "public class FileSystem {"))
				T.ok(contains(src, 'System.loadLibrary("file_system");'))
			end
		end)

	end)

	T.describe("to_jni_ffi — unhandled kind", function()

		T.it("a boundary kind with no JNI mapping is reported", function()
			local src, err = jni.to_jni_ffi(f({ kind = "interface" }), "Thing")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unhandled ffi-ir kind "interface"')) end
		end)

	end)

end)
