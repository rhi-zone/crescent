-- lib/fractal/ffi_ir_gleam_external_test.lua
-- Tests for lib/fractal/ffi_ir_gleam_external.lua (the Gleam `@external`
-- projector), ported from fractal's packages/ffi-ir/src/gleam-external.test.ts.
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
local gleam    = require("lib.fractal.ffi_ir_gleam_external")
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

T.describe("lib.fractal.ffi_ir_gleam_external", function()

	T.describe("to_gleam_ffi — function", function()

		T.it("a simple free function renders @external(javascript, ...) + pub fn", function()
			local add_fn = f(
				boundary.function_(
					{
						{ name = "a", type = t(types.integer) },
						{ name = "b", type = t(types.integer) },
					},
					t(types.integer)
				),
				{ jsModule = "./math.mjs" }
			)

			T.eq(
				gleam.to_gleam_ffi(add_fn, "add"),
				'@external(javascript, "./math.mjs", "add")\npub fn add(a: Int, b: Int) -> Int'
			)
		end)

		T.it("meta.jsName overrides the exported JS binding name when it differs from the Gleam name", function()
			local fn = f(
				boundary.function_({ { name = "id", type = t(types.string) } }, t(types.string)),
				{ jsModule = "./dom_ffi.mjs", jsName = "getElementById" }
			)
			local src, err = gleam.to_gleam_ffi(fn, "get_element_by_id")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, '@external(javascript, "./dom_ffi.mjs", "getElementById")'))
				T.ok(contains(src, "pub fn get_element_by_id(id: String) -> String"))
			end
		end)

		T.it("camelCase ffi-ir name converts to snake_case for the Gleam-side declaration", function()
			local fn = f(boundary.function_({}, t(types.void)), { jsModule = "./x.mjs" })
			local src = gleam.to_gleam_ffi(fn, "doTheThing")
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn do_the_thing() -> Nil")) end
		end)

		T.it("description meta renders as a /// doc comment", function()
			local fn = f(boundary.function_({}, t(types.void)), { jsModule = "./x.mjs", description = "Reverses a list." })
			local src = gleam.to_gleam_ffi(fn, "reverse")
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "/// Reverses a list.")) end
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, t(types.void)), { jsModule = "./x.mjs" })
			local src, err = gleam.to_gleam_ffi(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a missing meta.jsModule is reported rather than guessing a path", function()
			local fn = f(boundary.function_({}, t(types.void)))
			local src, err = gleam.to_gleam_ffi(fn, "greet")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "missing required meta.jsModule")) end
		end)

		T.it("a parameter name that snake_cases to a Gleam reserved word is escaped with a trailing underscore", function()
			-- Divergence from fractal's gleam-external.ts (which doesn't escape
			-- reserved words) — see the projector's file header and
			-- `build_function_decl`'s comment.
			local fn = f(
				boundary.function_({ { name = "type", type = t(types.string) } }, t(types.void)),
				{ jsModule = "./x.mjs" }
			)
			local src = gleam.to_gleam_ffi(fn, "set_kind")
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn set_kind(type_: String) -> Nil")) end
		end)

		T.it("ownership discipline metadata does not change the emitted declaration at all", function()
			-- JS/Gleam have no native ownership mechanism for @external to hook
			-- into — see the projector's file header.
			local copy_fn = f(
				boundary.function_(
					{ { name = "n", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) } },
					t(types.integer)
				),
				{ jsModule = "./x.mjs" }
			)
			local refcount_fn = f(
				boundary.function_(
					{ { name = "n", type = ffi_ir.with_ownership(t(types.integer), ownership.refcount()) } },
					t(types.integer)
				),
				{ jsModule = "./x.mjs" }
			)
			T.eq(gleam.to_gleam_ffi(copy_fn, "identity"), gleam.to_gleam_ffi(refcount_fn, "identity"))
		end)

	end)

	T.describe("to_gleam_ffi — method (degrades to a free function with the receiver as an explicit first parameter)", function()

		T.it("a method on a resource takes the receiver as its first parameter, named from the resource", function()
			local greet_method = f(boundary.method({}, t(types.string), "Greeter"), { jsModule = "./greeter.mjs" })
			T.eq(
				gleam.to_gleam_ffi(greet_method, "greet"),
				'@external(javascript, "./greeter.mjs", "greet")\npub fn greet(greeter: Greeter) -> String'
			)
		end)

		T.it("a method's own params follow the receiver", function()
			local set_name_method = f(
				boundary.method({ { name = "name", type = t(types.string) } }, t(types.void), "Greeter"),
				{ jsModule = "./greeter.mjs" }
			)
			local src = gleam.to_gleam_ffi(set_name_method, "set_name")
			T.ok(src ~= nil)
			if src ~= nil then T.ok(contains(src, "pub fn set_name(greeter: Greeter, name: String) -> Nil")) end
		end)

	end)

	T.describe("to_gleam_ffi — resource (degrades to a Gleam external type)", function()

		T.it("a resource emits `pub type Name` with no constructors, plus its methods as receiver-first free functions", function()
			local greet_method = f(boundary.method({}, t(types.string), "Greeter"), { jsModule = "./greeter.mjs" })
			local greeter = f(boundary.resource("Greeter", { greet = greet_method }))

			local src, err = gleam.to_gleam_ffi(greeter, "Greeter")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "pub type Greeter"))
				-- No constructor body — Gleam's external-type idiom carries no
				-- `Ctor(...)` at all.
				T.ok(not contains(src, "pub type Greeter {"))
				T.ok(contains(src, '@external(javascript, "./greeter.mjs", "greet")'))
				T.ok(contains(src, "pub fn greet(greeter: Greeter) -> String"))
			end
		end)

		T.it("resource description renders as a /// doc comment on the external type", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"), { jsModule = "./fs.mjs" })
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }), { description = "An open file." })
			local src = gleam.to_gleam_ffi(file_handle, "FileHandle")
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "/// An open file."))
				T.ok(contains(src, "pub type FileHandle"))
			end
		end)

		T.it("a resource method whose kind is neither method nor function is reported", function()
			local bogus = f(boundary.resource("Greeter", { greet = f(boundary.resource("Nested", {})) }))
			local src, err = gleam.to_gleam_ffi(bogus, "Greeter")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'has unexpected kind "resource"')) end
		end)

	end)

	T.describe("to_gleam_ffi — module (Gleam modules are files, not an inline construct)", function()

		T.it("groups function and resource declarations under a file-path comment, not a synthesized Gleam block", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"), { jsModule = "./fs.mjs" })
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(
				boundary.function_({ { name = "path", type = t(types.string) } }, t(types.ref("FileHandle"))),
				{ jsModule = "./fs.mjs" }
			)
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = gleam.to_gleam_ffi(fs_module, "fs")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "// module: fs (place these declarations in fs.gleam)"))
				T.ok(contains(src, "pub type FileHandle"))
				T.ok(contains(src, "pub fn open(path: String) -> FileHandle"))
			end
		end)

		T.it("a module requires a name", function()
			local fs_module = f(boundary.module("fs", {}, {}))
			local src, err = gleam.to_gleam_ffi(fs_module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"module" requires a name')) end
		end)

	end)

end)
