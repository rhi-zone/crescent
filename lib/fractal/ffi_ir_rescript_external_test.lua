-- lib/fractal/ffi_ir_rescript_external_test.lua
-- Tests for lib/fractal/ffi_ir_rescript_external.lua (the ReScript
-- `external`-declaration projector), ported from fractal's
-- packages/ffi-ir/src/rescript-external.test.ts.
--
-- Two systematic adaptations of the TS source:
--
--   1. Every `expect(() => toReScriptFfi(...)).toThrow(/.../)` becomes an
--      assertion on the `(nil, errmsg)` pair this port returns instead — the
--      source text is asserted to be nil AND the message to contain the TS
--      regex's literal substance. `expect(...).not.toThrow()` becomes an
--      assertion that the error is nil.
--   2. A resource's methods and a module's functions/resources are emitted in
--      byte order here where the TS walks JS insertion order (see
--      `ordered_keys` in the module under test), so declaration order within
--      one block can differ from the TS test's call order. Every expectation
--      below is a containment check, none of them order-dependent — matching
--      the TS source, which is written entirely in `toContain` for the same
--      reason (nothing in the emitted ReScript depends on that order).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local rescript = require("lib.fractal.ffi_ir_rescript_external")
local type_ref = require("lib.fractal.type_ref")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- Plain-substring containment (the stand-in for the TS side's
-- `expect(...).toContain(...)`), as a byte-index or nil.
--: (haystack: string | nil, needle: string) -> integer | nil
local function index_of(haystack, needle)
	if haystack == nil then return nil end
	return (haystack:find(needle, 1, true))
end

--: (haystack: string | nil, needle: string) -> nil
local function contains(haystack, needle)
	T.ok(index_of(haystack, needle) ~= nil, "expected output to contain: " .. needle)
end

--: (haystack: string | nil, needle: string) -> nil
local function excludes(haystack, needle)
	T.ok(index_of(haystack, needle) == nil, "expected output NOT to contain: " .. needle)
end

T.describe("lib.fractal.ffi_ir_rescript_external", function()

	T.describe("to_rescript_ffi — function", function()

		T.it("a simple free function with no module context binds via @val", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = t(types.integer) },
					{ name = "b", type = t(types.integer) },
				},
				t(types.integer)
			))

			local src, err = rescript.to_rescript_ffi(add_fn, "add")
			T.eq(err, nil)
			contains(src, "@val")
			contains(src, 'external add: (int, int) => int = "add"')
			excludes(src, "@module")
		end)

		T.it("a free function reached through a module binds via @module, naming the module's raw JS name", function()
			local open_fn = f(boundary.function_(
				{ { name = "path", type = t(types.string) } },
				t(types.boolean)
			))
			local fs_module = f(boundary.module("node:fs", { open = open_fn }, {}))

			local src, err = rescript.to_rescript_ffi(fs_module, "node:fs")
			T.eq(err, nil)
			contains(src, '@module("node:fs")')
			-- "open" is a ReScript reserved word — the binding identifier is
			-- sanitized to "open_" while the JS-side name (string literal) stays
			-- exactly "open".
			contains(src, 'external open_: (string) => bool = "open"')
			-- The MODULE name, unlike the `@module(...)` specifier, is a ReScript
			-- identifier and is PascalCased: `node:fs` -> `NodeFs`.
			contains(src, "module NodeFs = {")
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, t(types.void)))
			local src, err = rescript.to_rescript_ffi(fn, nil)
			T.eq(src, nil)
			contains(err, "requires a name")
		end)

		T.it("a description on the function's meta renders as a ReScript doc comment", function()
			local fn = f(boundary.function_({}, t(types.void)), { description = "does a thing" })
			local src, err = rescript.to_rescript_ffi(fn, "doThing")
			T.eq(err, nil)
			contains(src, "/** does a thing */")
		end)

		T.it("meta.deprecated renders as ReScript's @deprecated attribute", function()
			local bare = f(boundary.function_({}, t(types.void)), { deprecated = true })
			local src, err = rescript.to_rescript_ffi(bare, "old")
			T.eq(err, nil)
			contains(src, "@deprecated\n")

			local with_reason = f(boundary.function_({}, t(types.void)), { deprecated = "use next instead" })
			local src2, err2 = rescript.to_rescript_ffi(with_reason, "old")
			T.eq(err2, nil)
			contains(src2, '@deprecated("use next instead")')
		end)

		T.it("an unregistered kind with no ancestor is reported", function()
			local odd = f({ kind = "gizmo" })
			local src, err = rescript.to_rescript_ffi(odd, "gizmo")
			T.eq(src, nil)
			contains(err, 'unhandled ffi-ir kind "gizmo"')
		end)

		T.it("a kind registered under `function` renders through the function handler", function()
			ffi_ir.register_parent("staticFunction", "function")
			local fn = f({ kind = "staticFunction", params = {}, returnType = t(types.void) })
			local src, err = rescript.to_rescript_ffi(fn, "reset")
			-- restore, so test order cannot leak this registration
			ffi_ir.register_parent("staticFunction", nil)

			T.eq(err, nil)
			contains(src, "@val")
			contains(src, 'external reset: (unit) => unit = "reset"')
		end)

	end)

	T.describe("to_rescript_ffi — method", function()

		T.it("a method on a resource binds via @send, with the receiver as the first positional parameter", function()
			local read_method = f(boundary.method(
				{ { name = "length", type = t(types.integer) } },
				t(types.array(t(types.integer))),
				"FileHandle"
			))

			local src, err = rescript.to_rescript_ffi(read_method, "read")
			T.eq(err, nil)
			contains(src, "@send")
			contains(src, 'external read: (FileHandle, int) => array<int> = "read"')
		end)

		T.it("a no-arg method still gets the receiver as its sole parameter", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local src, err = rescript.to_rescript_ffi(close_method, "close")
			T.eq(err, nil)
			contains(src, 'external close: (FileHandle) => unit = "close"')
		end)

	end)

	T.describe("to_rescript_ffi — resource", function()

		T.it("emits an opaque type plus @send externals per method, JS-side names preserved, ReScript-side names prefixed to avoid cross-resource collisions", function()
			local read_method = f(boundary.method({}, t(types.array(t(types.integer))), "FileHandle"))
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))

			local src, err = rescript.to_rescript_ffi(file_handle, "FileHandle")
			T.eq(err, nil)
			contains(src, "type FileHandle")
			contains(src, 'external fileHandleRead: (FileHandle) => array<int> = "read"')
			contains(src, 'external fileHandleClose: (FileHandle) => unit = "close"')
			-- no invented constructor — ffi-ir's `resource` kind has no
			-- constructor field, only a methods map (the same gap fractal's
			-- wasm-bindgen backend lives with).
			excludes(src, "@new")
		end)

		T.it("ownership discipline never gates for this target — copy/opaque-handle/refcount/resource all lower identically", function()
			local read_method = f(boundary.method({}, ffi_ir.with_ownership(t(types.string), ownership.copy()), "Handle"))
			local for_copy = f(boundary.resource("Handle", { read = read_method }), { ownership = ownership.copy() })
			local for_refcount = f(boundary.resource("Handle", { read = read_method }), { ownership = ownership.refcount() })
			local for_resource = f(boundary.resource("Handle", { read = read_method }), { ownership = ownership.resource("own") })
			local for_opaque = f(boundary.resource("Handle", { read = read_method }), { ownership = ownership.opaque_handle("handle_free") })

			local copy_src, copy_err = rescript.to_rescript_ffi(for_copy, "Handle")
			local refcount_src, refcount_err = rescript.to_rescript_ffi(for_refcount, "Handle")
			local resource_src, resource_err = rescript.to_rescript_ffi(for_resource, "Handle")
			local opaque_src, opaque_err = rescript.to_rescript_ffi(for_opaque, "Handle")

			T.eq(copy_err, nil)
			T.eq(refcount_err, nil)
			T.eq(resource_err, nil)
			T.eq(opaque_err, nil)
			T.eq(refcount_src, copy_src)
			T.eq(resource_src, copy_src)
			-- An opaque-handle's freeFn is NOT emitted as an extra binding here,
			-- unlike the Melange backend: this target gates nothing and adds
			-- nothing for any discipline.
			T.eq(opaque_src, copy_src)
		end)

		T.it("a resource_ref used as a parameter/return type resolves to the same identifier the resource's own type declares", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local resource_decl, resource_err = rescript.to_rescript_ffi(file_handle, "FileHandle")

			local open_return = ffi_ir.with_ownership(ffi_ir.resource_ref("FileHandle", "own"), ownership.resource("own"))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = t(types.string) } },
				open_return
			))
			local fn_decl, fn_err = rescript.to_rescript_ffi(open_fn, "open_")

			T.eq(resource_err, nil)
			T.eq(fn_err, nil)
			contains(resource_decl, "type FileHandle")
			contains(fn_decl, "=> FileHandle")
		end)

		T.it("a methods-map entry that is not callable is reported, not rendered around", function()
			local bogus = f(boundary.resource("Bogus", { thing = f({ kind = "resource" }) }))
			local src, err = rescript.to_rescript_ffi(bogus, "Bogus")
			T.eq(src, nil)
			contains(err, 'resource method "thing" has unexpected kind "resource"')
		end)

	end)

	T.describe("to_rescript_ffi — module", function()

		T.it("groups resources and functions into a ReScript module block", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_return = ffi_ir.with_ownership(ffi_ir.resource_ref("FileHandle", "own"), ownership.resource("own"))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = t(types.string) } },
				open_return
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = rescript.to_rescript_ffi(fs_module, "fs")
			T.eq(err, nil)
			contains(src, "module Fs = {")
			contains(src, "type FileHandle")
			contains(src, '@module("fs")')
			-- "open" is a ReScript reserved word — sanitized to "open_" on the
			-- ReScript side; the JS-side literal stays "open".
			contains(src, 'external open_: (string) => FileHandle = "open"')
			contains(src, 'external fileHandleClose: (FileHandle) => unit = "close"')
			-- Every declaration inside the block is indented one level.
			contains(src, "\n  type FileHandle")
			T.ok(src ~= nil)
			if src ~= nil then T.eq(src:sub(-1), "}") end
		end)

		T.it("a functions-map entry that is not callable is reported", function()
			local bogus_module = f(boundary.module("fs", { thing = f({ kind = "resource" }) }, {}))
			local src, err = rescript.to_rescript_ffi(bogus_module, "fs")
			T.eq(src, nil)
			contains(err, 'module function "thing" has unexpected kind "resource"')
		end)

	end)

	T.describe("rescript_type_from_type_ref re-export", function()

		T.it("is the same function type_ref_rescript_native exports", function()
			local native = require("lib.fractal.type_ref_rescript_native")
			T.eq(rescript.rescript_type_from_type_ref, native.rescript_type_from_type_ref)
		end)

	end)

end)
