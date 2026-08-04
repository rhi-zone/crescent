-- lib/fractal/ffi_ir_ruby_ffi_test.lua
-- Tests for lib/fractal/ffi_ir_ruby_ffi.lua (the Ruby `ffi` gem projector),
-- ported from fractal's packages/ffi-ir/src/ruby-ffi.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become
-- `(nil, errmsg)` assertions: the projector returns its failures rather than
-- throwing (see the port's file header), so each such test asserts the value
-- is nil and that the message still carries the substring the TS regex
-- matched.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local ruby     = require("lib.fractal.ffi_ir_ruby_ffi")
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

-- The opaque-handle convention shared with the C-ABI backend's tests: a plain
-- `ref` TypeRef carrying `opaque-handle` ownership metadata.
--: (resource_name: string, free_fn: string | nil) -> TypeRef
local function handle_ref(resource_name, free_fn)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(free_fn)
	)
end

T.describe("lib.fractal.ffi_ir_ruby_ffi", function()

	T.describe("to_ruby_ffi_type", function()

		T.it("copy discipline (or no ownership meta at all) maps to the base ffi-gem primitive symbols", function()
			T.eq(ruby.to_ruby_ffi_type(t(types.integer)), ":int64")
			T.eq(ruby.to_ruby_ffi_type(t(types.number)), ":double")
			T.eq(ruby.to_ruby_ffi_type(t(types.string)), ":string")
			T.eq(ruby.to_ruby_ffi_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), ":bool")
			T.eq(ruby.to_ruby_ffi_type(t(types.void)), ":void")
		end)

		T.it("opaque-handle, refcount, and resource disciplines all collapse to the identical bare :pointer symbol", function()
			T.eq(ruby.to_ruby_ffi_type(handle_ref("FileHandle", nil)), ":pointer")
			T.eq(ruby.to_ruby_ffi_type(ffi_ir.with_ownership(t(types.integer), ownership.refcount())), ":pointer")
			T.eq(ruby.to_ruby_ffi_type(ffi_ir.resource_ref("FileHandle", "own")), ":pointer")
			T.eq(ruby.to_ruby_ffi_type(ffi_ir.resource_ref("FileHandle", "borrow")), ":pointer")
		end)

		T.it("a structural shape with no minimal ffi-gem mapping is reported, not guessed at", function()
			local sym, err = ruby.to_ruby_ffi_type(t(types.object({ x = t(types.integer) })))
			T.eq(sym, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "no minimal ffi-gem type-symbol mapping")) end
		end)

	end)

	T.describe("to_ruby_ffi — function", function()

		T.it("a simple free function with copy-discipline params/return", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			T.eq(ruby.to_ruby_ffi(add_fn, "add"), 'attach_function "add", [:int64, :int64], :int64')
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = ruby.to_ruby_ffi(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

	end)

	T.describe("to_ruby_ffi — resource with an opaque-handle method", function()

		T.it("a resource's method takes the receiver as a synthesized leading :pointer, plus an auto-generated free binding", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.integer), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))

			local src, err = ruby.to_ruby_ffi(file_handle, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, 'attach_function "file_handle_read", [:pointer], :int64'))
				T.ok(contains(src, 'attach_function "file_handle_free", [:pointer], :void'))
			end
		end)

		T.it("resource emission ignores an explicit name argument in favor of the shape's own name", function()
			local file_handle = f(boundary.resource("FileHandle", {}))
			local src = ruby.to_ruby_ffi(file_handle, "SomeOtherName")
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, 'attach_function "file_handle_free"'))
				T.ok(not contains(src, "SomeOtherName"))
			end
		end)

	end)

	T.describe("to_ruby_ffi — module", function()

		T.it("wraps functions and resources in a Ruby module extending FFI::Library, requiring meta.libPath", function()
			local close_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", nil)
			))
			local fs_module = f(
				boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }),
				{ libPath = "./libfs.so" }
			)

			local src, err = ruby.to_ruby_ffi(fs_module, "fs")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "module Fs"))
				T.ok(contains(src, "extend FFI::Library"))
				T.ok(contains(src, 'ffi_lib "./libfs.so"'))
				T.ok(contains(src, 'attach_function "open", [:string], :pointer'))
				T.ok(contains(src, 'attach_function "file_handle_close", [:pointer], :void'))
				T.ok(contains(src, 'attach_function "file_handle_free", [:pointer], :void'))
				T.eq(src:sub(-3), "end")
			end
		end)

		T.it("a module without meta.libPath is reported rather than guessing a library path", function()
			local fs_module = f(boundary.module("fs", {}, {}))
			local src, err = ruby.to_ruby_ffi(fs_module, "fs")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "missing required meta.libPath")) end
		end)

		T.it("a module requires a name", function()
			local fs_module = f(boundary.module("fs", {}, {}), { libPath = "./libfs.so" })
			local src, err = ruby.to_ruby_ffi(fs_module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"module" requires a name')) end
		end)

	end)

end)
