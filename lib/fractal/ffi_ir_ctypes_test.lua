-- lib/fractal/ffi_ir_ctypes_test.lua
-- Tests for lib/fractal/ffi_ir_ctypes.lua (the Python `ctypes` projector),
-- ported from fractal's packages/ffi-ir/src/ctypes.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil, errmsg)`
-- assertions: the projector returns its failures rather than throwing (see the
-- port's file header), so each such test asserts the value is nil and that the
-- message still carries the substring the TS regex matched.
--
-- Emission ORDER inside a module is byte order of the resource/function map
-- keys, not the TS source's JS insertion order (see the port's `ordered_keys`),
-- so the one positional assertion below — the opaque Structure preceding the
-- module-level function that returns a pointer to it — is asserted against the
-- order this port actually emits: all resources, then all functions.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local ctypes   = require("lib.fractal.ffi_ir_ctypes")
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

-- Byte offset of `needle` in `haystack`, or nil — for the one assertion that
-- compares two declarations' positions rather than merely their presence.
--: (haystack: string, needle: string) -> integer | nil
local function index_of(haystack, needle)
	return (haystack:find(needle, 1, true))
end

-- The C-target convention for referencing an opaque resource by pointer: a
-- plain `ref` TypeRef carrying `opaque-handle` ownership — matches the C-ABI
-- and Ruby backends' identical `handle_ref` test helpers.
--: (resource_name: string, free_fn: string | nil) -> TypeRef
local function handle_ref(resource_name, free_fn)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(free_fn)
	)
end

T.describe("lib.fractal.ffi_ir_ctypes", function()

	T.describe("to_ctypes_shape", function()

		T.it("primitive kinds map to ctypes' own vocabulary", function()
			T.eq(ctypes.to_ctypes_shape(t(types.integer)), "c_int64")
			T.eq(ctypes.to_ctypes_shape(t(types.number)), "c_double")
			T.eq(ctypes.to_ctypes_shape(t(types.boolean)), "c_bool")
			T.eq(ctypes.to_ctypes_shape(t(types.string)), "c_char_p")
			T.eq(ctypes.to_ctypes_shape(t(types.void)), "None")
			T.eq(ctypes.to_ctypes_shape(t(types.null)), "None")
		end)

		T.it("a ref TypeRef passes the target name through, trusting a Structure of that name exists", function()
			T.eq(ctypes.to_ctypes_shape(t(types.ref("FileHandle"))), "FileHandle")
		end)

		T.it("an object TypeRef requires meta.typeName", function()
			local expr, err = ctypes.to_ctypes_shape(t(types.object({})))
			T.eq(expr, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "requires meta.typeName")) end
		end)

		T.it("an object TypeRef carrying meta.typeName emits that Structure class name", function()
			local expr, err = ctypes.to_ctypes_shape({ shape = types.object({}), meta = { typeName = "Point" } })
			T.eq(err, nil)
			T.eq(expr, "Point")
		end)

		T.it("array/tuple/map/union — no native ctypes representation, reported rather than degraded", function()
			--: (ref: TypeRef) -> nil
			local function assert_unsupported(ref)
				local expr, err = ctypes.to_ctypes_shape(ref)
				T.eq(expr, nil)
				T.ok(err ~= nil)
				if err ~= nil then T.ok(contains(err, "no ctypes representation")) end
			end

			assert_unsupported(t(types.array(t(types.integer))))
			assert_unsupported(t(types.tuple({ t(types.integer), t(types.string) })))
			assert_unsupported(t(types.map(t(types.string), t(types.integer))))
			assert_unsupported(t(types.union({ t(types.integer), t(types.string) })))
		end)

	end)

	T.describe("to_ctypes_type — ownership discipline", function()

		T.it("copy discipline (or no ownership meta at all) is the plain ctype", function()
			T.eq(ctypes.to_ctypes_type(t(types.integer)), "c_int64")
			T.eq(ctypes.to_ctypes_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "c_bool")
		end)

		T.it("opaque-handle discipline becomes POINTER(<T>)", function()
			T.eq(ctypes.to_ctypes_type(handle_ref("FileHandle", nil)), "POINTER(FileHandle)")
		end)

		T.it("refcount and resource(own/borrow) produce the SAME POINTER(<T>) declaration as opaque-handle — "
			.. "ctypes has no type-level way to distinguish them", function()
			local target = t(types.ref("FileHandle"))
			T.eq(ctypes.to_ctypes_type(ffi_ir.with_ownership(target, ownership.refcount())), "POINTER(FileHandle)")
			T.eq(ctypes.to_ctypes_type(ffi_ir.with_ownership(target, ownership.resource("own"))), "POINTER(FileHandle)")
			T.eq(ctypes.to_ctypes_type(ffi_ir.with_ownership(target, ownership.resource("borrow"))), "POINTER(FileHandle)")
			T.eq(ctypes.to_ctypes_type(ffi_ir.resource_ref("FileHandle", "own")), "POINTER(FileHandle)")
		end)

		T.it("a data shape with no ctypes representation is reported through the ownership wrapper too", function()
			local expr, err = ctypes.to_ctypes_type(
				ffi_ir.with_ownership(t(types.array(t(types.integer))), ownership.refcount())
			)
			T.eq(expr, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "no ctypes representation")) end
		end)

	end)

	T.describe("to_ctypes — function", function()

		T.it("a simple free function: argtypes/restype wiring plus a thin wrapper", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			local src, err = ctypes.to_ctypes(add_fn, "add", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "lib.add.argtypes = [c_int64, c_int64]"))
				T.ok(contains(src, "lib.add.restype = c_int64"))
				T.ok(contains(src, "def add(a, b):"))
				T.ok(contains(src, "    return lib.add(a, b)"))
			end
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = ctypes.to_ctypes(fn, nil, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a void-returning function gets restype = None", function()
			local close_fn = f(boundary.function_(
				{ { name = "handle", type = handle_ref("FileHandle", nil) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			local src, err = ctypes.to_ctypes(close_fn, "close", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "lib.close.argtypes = [POINTER(FileHandle)]"))
				T.ok(contains(src, "lib.close.restype = None"))
			end
		end)

		T.it("a parameter name is snake_cased and keyword-escaped for the Python wrapper", function()
			local fn = f(boundary.function_(
				{
					{ name = "filePath", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) },
					{ name = "class", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			local src, err = ctypes.to_ctypes(fn, "openFile", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "def open_file(file_path, class_):"))
				T.ok(contains(src, "    return lib.open_file(file_path, class_)"))
			end
		end)

		T.it("a parameter shape with no ctypes representation is reported, not guessed at", function()
			local fn = f(boundary.function_(
				{ { name = "xs", type = t(types.array(t(types.integer))) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			local src, err = ctypes.to_ctypes(fn, "sum", nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "no ctypes representation")) end
		end)

	end)

	T.describe("to_ctypes — resource, opaque-handle discipline", function()

		T.it("a resource: opaque Structure, method wiring, free-function wiring, wrapper class", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", nil)
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = ctypes.to_ctypes(fs_module, nil, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				-- opaque Structure, permanently incomplete (no _fields_)
				T.ok(contains(src, "class FileHandle(Structure):"))
				T.ok(contains(src, "    pass"))

				-- constructor returns a pointer to the opaque struct
				T.ok(contains(src, "lib.open.restype = POINTER(FileHandle)"))
				T.ok(contains(src, "def open(path):"))

				-- method wiring, receiver-prefixed with a synthesized handle parameter
				T.ok(contains(src, "lib.file_handle_read.argtypes = [POINTER(FileHandle)]"))
				T.ok(contains(src, "lib.file_handle_read.restype = c_int64"))
				T.ok(contains(src, "def file_handle_read(handle):"))

				-- auto-generated free-function wiring
				T.ok(contains(src, "lib.file_handle_free.argtypes = [POINTER(FileHandle)]"))
				T.ok(contains(src, "lib.file_handle_free.restype = None"))

				-- wrapper class: stores the handle, delegates read(), frees on __del__
				T.ok(contains(src, "class FileHandle:"))
				T.ok(contains(src, "    def __init__(self, handle):"))
				T.ok(contains(src, "        self._handle = handle"))
				T.ok(contains(src, "    def read(self):"))
				T.ok(contains(src, "        return file_handle_read(self._handle)"))
				T.ok(contains(src, "    def __del__(self):"))
				T.ok(contains(src, "        file_handle_free(self._handle)"))
			end
		end)

		T.it("a method's own parameters follow the synthesized handle, in both wrapper and class", function()
			local seek_method = f(boundary.method(
				{ { name = "offset", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy()),
				"FileHandle"
			))
			local file_handle = f(boundary.resource("FileHandle", { seek = seek_method }))

			local src, err = ctypes.to_ctypes(file_handle, nil, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "lib.file_handle_seek.argtypes = [POINTER(FileHandle), c_int64]"))
				T.ok(contains(src, "def file_handle_seek(handle, offset):"))
				T.ok(contains(src, "    def seek(self, offset):"))
				T.ok(contains(src, "        return file_handle_seek(self._handle, offset)"))
			end
		end)

		T.it("resource emission ignores an explicit name argument in favor of the shape's own name", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src, err = ctypes.to_ctypes(file_handle, "SomeOtherName", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "class FileHandle(Structure):"))
				T.ok(not contains(src, "SomeOtherName"))
			end
		end)

	end)

	T.describe("to_ctypes — resource, other ownership disciplines (refcount / resource own-borrow)", function()

		T.it("a refcount- or resource-discipline handle produces the IDENTICAL POINTER(<T>) argtype as "
			.. "opaque-handle — ctypes has no ownership model of its own", function()
			--: (discipline: OwnershipDiscipline, name: string) -> string | nil
			local function emit(discipline, name)
				local fn = f(boundary.function_(
					{ { name = "handle", type = ffi_ir.with_ownership(t(types.ref("FileHandle")), discipline) } },
					ffi_ir.with_ownership(t(types.void), ownership.copy())
				))
				local src, err = ctypes.to_ctypes(fn, name, nil)
				T.eq(err, nil)
				return src
			end

			local refcount_src = emit(ownership.refcount(), "release")
			local resource_src = emit(ownership.resource("borrow"), "borrow_use")
			local opaque_src = emit(ownership.opaque_handle(nil), "close")

			T.ok(refcount_src ~= nil)
			T.ok(resource_src ~= nil)
			T.ok(opaque_src ~= nil)
			if refcount_src ~= nil then T.ok(contains(refcount_src, "lib.release.argtypes = [POINTER(FileHandle)]")) end
			if resource_src ~= nil then T.ok(contains(resource_src, "lib.borrow_use.argtypes = [POINTER(FileHandle)]")) end
			if opaque_src ~= nil then T.ok(contains(opaque_src, "lib.close.argtypes = [POINTER(FileHandle)]")) end
		end)

	end)

	T.describe("to_ctypes — method", function()

		T.it("a method emitted on its own is receiver-prefixed and takes the synthesized handle", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "FileHandle"))
			local src, err = ctypes.to_ctypes(read_method, "read", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "lib.file_handle_read.argtypes = [POINTER(FileHandle)]"))
				T.ok(contains(src, "def file_handle_read(handle):"))
			end
		end)

		T.it("a method requires a name", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "FileHandle"))
			local src, err = ctypes.to_ctypes(read_method, nil, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"method" requires a name')) end
		end)

	end)

	T.describe("to_ctypes — module", function()

		T.it("emits a CDLL load block followed by resources then functions", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", nil)
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = ctypes.to_ctypes(fs_module, nil, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "from ctypes import *"))
				T.ok(contains(src, 'lib = CDLL("./libfs.so")'))
				T.ok(contains(src, "class FileHandle(Structure):"))
				T.ok(contains(src, "def open(path):"))
				T.ok(contains(src, "def file_handle_close(handle):"))

				-- the resource block precedes the module-level open() function, so
				-- the Structure class open()'s restype names is already bound when
				-- Python executes that assignment
				local struct_at = index_of(src, "class FileHandle(Structure):")
				local open_at = index_of(src, "def open(path):")
				T.ok(struct_at ~= nil)
				T.ok(open_at ~= nil)
				if struct_at ~= nil and open_at ~= nil then T.ok(struct_at < open_at) end
			end
		end)

		T.it("library_path overrides the default ./lib<name>.so placeholder", function()
			local fs_module = f(boundary.module("fs", {}, {}))
			local src, err = ctypes.to_ctypes(fs_module, nil, "/usr/local/lib/libfs.so.1")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, 'lib = CDLL("/usr/local/lib/libfs.so.1")')) end
		end)

		T.it("a failing member shape is reported from the module level, not swallowed", function()
			local bad_fn = f(boundary.function_(
				{ { name = "xs", type = t(types.array(t(types.integer))) } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))
			local fs_module = f(boundary.module("fs", { sum = bad_fn }, {}))

			local src, err = ctypes.to_ctypes(fs_module, nil, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "no ctypes representation")) end
		end)

	end)

	T.describe("to_ctypes — unhandled kind", function()

		T.it("an ffi-ir kind this backend does not implement is reported", function()
			local src, err = ctypes.to_ctypes(f({ kind = "interface" }), "Thing", nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "no ctypes mapping implemented")) end
		end)

	end)

	T.describe("doc comments", function()

		T.it("meta.description is emitted as a leading # comment", function()
			local fn = f(
				boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())),
				{ description = "Closes the handle." }
			)
			local src, err = ctypes.to_ctypes(fn, "close", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then T.eq(src:sub(1, 21), "# Closes the handle.\n") end
		end)

	end)

end)
