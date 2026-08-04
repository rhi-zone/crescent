-- lib/fractal/ffi_ir_test.lua
-- Tests for lib/fractal/ffi_ir.lua (the FFI-IR data model), ported from
-- fractal's packages/ffi-ir/src/index.test.ts.
--
-- Table equality is asserted field by field: lib/test/assert's `eq` is `~=`,
-- which on tables is identity, not structure. The TS source's `toEqual` deep
-- comparisons expand into the per-field assertions below.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local type_ref = require("lib.fractal.type_ref")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- Count of a record's keys, for the tests that assert a map has exactly the
-- expected entries (the stand-in for the TS side's `Object.keys(...)` length).
--: (tbl: { [string]: unknown }) -> integer
local function key_count(tbl)
	local n = 0
	for _ in pairs(tbl) do n = n + 1 end
	return n
end

T.describe("lib.fractal.ffi_ir", function()

	T.describe("ownership", function()

		T.it("copy discipline", function()
			T.eq(ownership.copy().kind, "copy")
		end)

		T.it("opaque-handle discipline, with and without a named free function", function()
			local bare = ownership.opaque_handle()
			T.eq(bare.kind, "opaque-handle")
			T.eq(bare.freeFn, nil)

			local named = ownership.opaque_handle("buffer_free")
			T.eq(named.kind, "opaque-handle")
			T.eq(named.freeFn, "buffer_free")
		end)

		T.it("refcount discipline", function()
			T.eq(ownership.refcount().kind, "refcount")
		end)

		T.it("resource discipline distinguishes own vs. borrow per reference", function()
			T.eq(ownership.resource("own").kind, "resource")
			T.eq(ownership.resource("own").mode, "own")
			T.eq(ownership.resource("borrow").mode, "borrow")
		end)

		T.it("each constructor allocates a fresh table, never a shared singleton", function()
			-- The TS constructors are functions returning fresh objects, not
			-- `as const` singletons, so the Lua port keeps them functions.
			-- Callers may therefore treat a returned discipline as their own.
			T.neq(ownership.copy(), ownership.copy())
			T.neq(ownership.refcount(), ownership.refcount())
		end)

	end)

	T.describe("ownership_of", function()

		T.it("reads a discipline back off a TypeRef's meta bag", function()
			local ref = ffi_ir.with_ownership(t(types.string), ownership.refcount())
			local discipline = ffi_ir.ownership_of(ref)
			T.ok(discipline ~= nil)
			if discipline ~= nil then T.eq(discipline.kind, "refcount") end
		end)

		T.it("returns nil for an unannotated reference — a bare position crosses by value", function()
			T.eq(ffi_ir.ownership_of(t(types.string)), nil)
		end)

		T.it("returns nil for a meta.ownership that is not a well-formed discipline", function()
			T.eq(ffi_ir.ownership_of({ shape = types.string, meta = { ownership = "copy" } }), nil)
			T.eq(ffi_ir.ownership_of({ shape = types.string, meta = { ownership = {} } }), nil)
		end)

	end)

	T.describe("with_ownership", function()

		T.it("attaches meta.ownership without disturbing other meta", function()
			local ref = t(types.string, { description = "a buffer handle" })
			local owned = ffi_ir.with_ownership(ref, ownership.opaque_handle("buffer_free"))

			T.eq(owned.meta.description, "a buffer handle")
			local discipline = ffi_ir.ownership_of(owned)
			T.ok(discipline ~= nil)
			if discipline ~= nil then
				T.eq(discipline.kind, "opaque-handle")
				T.eq((discipline --[[: { freeFn: unknown, ... }]]).freeFn, "buffer_free")
			end
		end)

		T.it("leaves the shape untouched — ownership is metadata, not a wrapping constructor", function()
			local ref = t(types.string)
			local owned = ffi_ir.with_ownership(ref, ownership.copy())
			T.eq(owned.shape, ref.shape)
		end)

		T.it("does not mutate the input TypeRef — a shared TypeRef stays unannotated", function()
			local shared = t(types.integer)
			local _ = ffi_ir.with_ownership(shared, ownership.refcount())
			T.eq(shared.meta.ownership, nil)
		end)

	end)

	T.describe("resource_ref", function()

		T.it("builds a type-ir ref TypeRef carrying resource ownership metadata", function()
			local ref = ffi_ir.resource_ref("Buffer", "own")
			T.eq(ref.shape.kind, "ref")
			T.eq((ref.shape --[[: { target: unknown, ... }]]).target, "Buffer")

			local discipline = ffi_ir.ownership_of(ref)
			T.ok(discipline ~= nil)
			if discipline ~= nil then
				T.eq(discipline.kind, "resource")
				T.eq((discipline --[[: { mode: unknown, ... }]]).mode, "own")
			end
		end)

		T.it("the same resource can be owned in one signature and borrowed in another", function()
			local owned = ffi_ir.resource_ref("Buffer", "own")
			local borrowed = ffi_ir.resource_ref("Buffer", "borrow")

			T.eq(
				(owned.shape --[[: { target: unknown, ... }]]).target,
				(borrowed.shape --[[: { target: unknown, ... }]]).target
			)

			local a = ffi_ir.ownership_of(owned)
			local b = ffi_ir.ownership_of(borrowed)
			if a ~= nil then T.eq((a --[[: { mode: unknown, ... }]]).mode, "own") end
			if b ~= nil then T.eq((b --[[: { mode: unknown, ... }]]).mode, "borrow") end
		end)

	end)

	T.describe("boundary kind lattice", function()

		T.it("method falls back to function; the other kinds are roots", function()
			T.eq(#ffi_ir.ancestors("method"), 1)
			T.eq(ffi_ir.ancestors("method")[1], "function")
			T.eq(#ffi_ir.ancestors("function"), 0)
			T.eq(#ffi_ir.ancestors("resource"), 0)
			T.eq(#ffi_ir.ancestors("module"), 0)
		end)

		T.it("resolve finds an exact handler before falling back to an ancestor", function()
			T.eq(ffi_ir.resolve("method", { ["function"] = "FN", method = "METHOD" }), "METHOD")
			T.eq(ffi_ir.resolve("method", { ["function"] = "FN" }), "FN")
			T.eq(ffi_ir.resolve("resource", { ["function"] = "FN" }), nil)
		end)

		T.it("register_parent extends the lattice for a consumer-added kind", function()
			ffi_ir.register_parent("staticFunction", "function")
			T.eq(#ffi_ir.ancestors("staticFunction"), 1)
			T.eq(ffi_ir.ancestors("staticFunction")[1], "function")
			-- restore, so test order cannot leak this registration
			ffi_ir.register_parent("staticFunction", nil)
			T.eq(#ffi_ir.ancestors("staticFunction"), 0)
		end)

		T.it("is a SEPARATE registry from type_ref's — registering here does not affect that one", function()
			ffi_ir.register_parent("gadget", "function")
			T.eq(#ffi_ir.ancestors("gadget"), 1)
			T.eq(#type_ref.ancestors("gadget"), 0)
			ffi_ir.register_parent("gadget", nil)
		end)

	end)

	T.describe("function/method signature construction", function()

		T.it("a free function references type-ir TypeRefs for its params and return type", function()
			local params = {
				{ name = "path", type = t(types.string) },
				{ name = "mode", type = t(types.string) },
			}
			local return_type = ffi_ir.resource_ref("FileHandle", "own")
			local open_fn = f(
				boundary.function_(params, return_type),
				{ description = "open a file, owning the handle" }
			)

			T.eq(open_fn.shape.kind, "function")
			T.eq(#(open_fn.shape --[[: { params: unknown[], ... }]]).params, 2)
			T.eq(open_fn.meta.description, "open a file, owning the handle")
		end)

		T.it("a method carries a receiver naming its resource", function()
			local read_method = f(boundary.method(
				{ { name = "length", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
				ffi_ir.with_ownership(t(types.array(t(types.integer))), ownership.copy()),
				"FileHandle"
			))

			T.eq(read_method.shape.kind, "method")
			T.eq((read_method.shape --[[: { receiver: unknown, ... }]]).receiver, "FileHandle")
		end)

		T.it("an owned parameter sits alongside a copy-discipline return in one signature", function()
			local close_fn = boundary.function_(
				{ { name = "handle", type = ffi_ir.resource_ref("FileHandle", "own") } },
				ffi_ir.with_ownership(t(types.boolean), ownership.copy())
			)

			local param_discipline = ffi_ir.ownership_of(close_fn.params[1].type)
			if param_discipline ~= nil then
				T.eq(param_discipline.kind, "resource")
				T.eq((param_discipline --[[: { mode: unknown, ... }]]).mode, "own")
			end
			local return_discipline = ffi_ir.ownership_of(close_fn.returnType)
			if return_discipline ~= nil then T.eq(return_discipline.kind, "copy") end
		end)

	end)

	T.describe("resource construction", function()

		T.it("a resource exposes behavior only through its methods map", function()
			local read_method = f(boundary.method({}, t(types.array(t(types.integer))), "FileHandle"))
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))

			T.eq(file_handle.shape.kind, "resource")
			local shape = file_handle.shape --[[: FfiResourceShape]]
			T.eq(key_count(shape.methods), 2)
			T.eq(shape.methods.read.shape.kind, "method")
			T.eq(shape.name, "FileHandle")
		end)

	end)

	T.describe("module construction", function()

		T.it("groups exported functions and resources for one boundary", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = t(types.string) } },
				ffi_ir.resource_ref("FileHandle", "own")
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			T.eq(fs_module.shape.kind, "module")
			local shape = fs_module.shape --[[: FfiModuleShape]]
			T.eq(shape.name, "fs")
			T.eq(key_count(shape.functions), 1)
			T.eq(key_count(shape.resources), 1)
			T.eq(shape.functions.open.shape.kind, "function")
			T.eq(shape.resources.FileHandle.shape.kind, "resource")
		end)

		T.it("ffi_ref_from_shape defaults meta to an empty bag", function()
			local bare = f(boundary.module("fs", {}, {}))
			T.eq(key_count(bare.meta), 0)
		end)

	end)

	T.describe("with_provenance", function()

		T.it("attaches meta.provenance without disturbing other meta", function()
			local fs_module = f(boundary.module("fs", {}, {}), { description = "filesystem boundary" })
			local stamped = ffi_ir.with_provenance(fs_module, { source = "wit-file", path = "fs.wit" })

			T.eq(stamped.meta.description, "filesystem boundary")
			local provenance = stamped.meta.provenance --[[: { source: unknown, path: unknown, ... }]]
			T.eq(provenance.source, "wit-file")
			T.eq(provenance.path, "fs.wit")
		end)

		T.it("leaves the shape untouched — the SAME shape table, not a copy", function()
			local fs_module = f(boundary.module("fs", {}, {}))
			local stamped = ffi_ir.with_provenance(fs_module, { source = "c-header" })
			T.eq(stamped.shape, fs_module.shape)
		end)

		T.it("does not mutate the input FfiRef", function()
			local fs_module = f(boundary.module("fs", {}, {}))
			local _ = ffi_ir.with_provenance(fs_module, { source = "c-header" })
			T.eq(fs_module.meta.provenance, nil)
		end)

		T.it("coexists with meta.ownership on the nested TypeRef without interference", function()
			local open_fn = ffi_ir.with_provenance(
				f(boundary.function_(
					{ { name = "path", type = t(types.string) } },
					ffi_ir.resource_ref("FileHandle", "own")
				)),
				{ source = "hand-authored" }
			)

			-- provenance sits on the FfiRef's own meta bag...
			local provenance = open_fn.meta.provenance --[[: { source: unknown, ... }]]
			T.eq(provenance.source, "hand-authored")

			-- ...while ownership sits on the nested TypeRef's bag, untouched.
			local return_type = (open_fn.shape --[[: FfiFunctionShape]]).returnType
			local discipline = ffi_ir.ownership_of(return_type)
			if discipline ~= nil then T.eq(discipline.kind, "resource") end
			T.eq(return_type.meta.provenance, nil)
		end)

	end)

end)
