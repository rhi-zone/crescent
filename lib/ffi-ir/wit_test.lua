-- lib/ffi-ir/wit_test.lua
-- Tests for lib/ffi-ir/wit.lua (the WIT projector), ported from
-- fractal's packages/ffi-ir/src/wit.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil, errmsg)`
-- assertions: the projector returns its failures rather than throwing (see the
-- port's file header), so each such test asserts the value is nil and that the
-- message still carries the substring the TS regex matched.
--
-- Where the TS asserts a whole emitted document (`toBe`), the expectation here
-- is the port's own output: a Lua table has no insertion order, so the port
-- emits a module's resources, functions and a record's fields in byte order of
-- their names, and its hoisted `record` declarations in the order they were
-- first reserved (see `WitDecls` in the projector). Every such expectation
-- below is spelled out in full rather than reused from the TS.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.ffi-ir")
local wit      = require("lib.ffi-ir.wit")
local type_ref = require("lib.type-ir")

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

-- The `fs` module the TS source's resource suite builds in a shared helper: a
-- `FileHandle` resource with `read`/`close` methods, plus a free `open`
-- returning an OWNED handle to it.
--: () -> FfiRef
local function file_handle_module()
	local read_method = f(boundary.method(
		{},
		ffi_ir.with_ownership(t(types.array(t(types.integer))), ownership.copy()),
		"FileHandle"
	))
	local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
	local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))

	local open_fn = f(boundary.function_(
		{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
		ffi_ir.with_ownership(ffi_ir.resource_ref("FileHandle", "own"), ownership.resource("own"))
	))

	return f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))
end

T.describe("lib.ffi-ir.wit", function()

	T.describe("to_wit — module with a simple copy-discipline function", function()

		T.it("a module with one free function of copy-discipline primitive params/return", function()
			local params = {
				{ name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) },
				{ name = "mode", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) },
			}
			local return_type = ffi_ir.with_ownership(t(types.boolean), ownership.copy())
			local exists_fn = f(boundary.function_(params, return_type))
			local fs_module = f(boundary.module("fs", { fileExists = exists_fn }, {}))

			local src, err = wit.to_wit(fs_module, nil)
			T.eq(err, nil)
			T.eq(src, table.concat({
				"interface fs {",
				"    file-exists: func(path: string, mode: string) -> bool;",
				"}",
			}, "\n"))
		end)

		T.it("a copy-discipline record (object) return type hoists a named `record` declaration", function()
			local content_type = ffi_ir.with_ownership(
				t(types.object({ bytes = t(types.array(t(types.integer))), length = t(types.integer) })),
				ownership.copy()
			)
			local params = { { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } }
			local read_fn = f(boundary.function_(params, content_type))
			local fs_module = f(boundary.module("fs", { readFile = read_fn }, {}))

			local src, err = wit.to_wit(fs_module, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "record read-file-result {"))
				T.ok(contains(src, "bytes: list<s64>,"))
				T.ok(contains(src, "length: s64,"))
				T.ok(contains(src, "read-file: func(path: string) -> read-file-result;"))
			end
		end)

		T.it("hoisted records are emitted ahead of the interface body they were hoisted out of", function()
			-- Pins the emission order the TS source gets from its `Map`'s
			-- insertion order and this port reproduces explicitly (see
			-- `WitDecls`): declarations first, then the body, separated by a
			-- blank line, everything indented one level inside the interface.
			local content_type = ffi_ir.with_ownership(
				t(types.object({ bytes = t(types.array(t(types.integer))), length = t(types.integer) })),
				ownership.copy()
			)
			local params = { { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } }
			local read_fn = f(boundary.function_(params, content_type))
			local fs_module = f(boundary.module("fs", { readFile = read_fn }, {}))

			local src = wit.to_wit(fs_module, nil)
			T.eq(src, table.concat({
				"interface fs {",
				"    record read-file-result {",
				"        bytes: list<s64>,",
				"        length: s64,",
				"    }",
				"",
				"    read-file: func(path: string) -> read-file-result;",
				"}",
			}, "\n"))
		end)

	end)

	T.describe("to_wit — resource with own/borrow-style methods", function()

		T.it("a resource emits a nested `resource` block with implicit-receiver methods", function()
			local src, err = wit.to_wit(file_handle_module(), nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "resource file-handle {"))
				T.ok(contains(src, "    read: func() -> list<s64>;"))
				T.ok(contains(src, "    close: func();"))
			end
		end)

		T.it("an owned resource return type renders as the bare resource name", function()
			local src = wit.to_wit(file_handle_module(), nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "open: func(path: string) -> file-handle;"))
			end
		end)

		T.it("a borrowed resource parameter renders as borrow<name>", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))

			local release_params = { { name = "handle", type = ffi_ir.resource_ref("FileHandle", "borrow") } }
			local release_fn = f(boundary.function_(release_params, t(types.void)))
			local fs_module = f(boundary.module("fs", { release = release_fn }, { FileHandle = file_handle }))

			local src, err = wit.to_wit(fs_module, nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				T.ok(contains(src, "release: func(handle: borrow<file-handle>);"))
			end
		end)

		T.it("a standalone resource (not wrapped in a module) also emits a `resource` block", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))

			local src, err = wit.to_wit(file_handle, nil)
			T.eq(err, nil)
			T.eq(src, table.concat({ "resource file-handle {", "    close: func();", "}" }, "\n"))
		end)

	end)

	T.describe("to_wit — unsupported ownership disciplines are reported for this target", function()

		T.it("opaque-handle ownership is reported", function()
			local params = {
				{ name = "buffer", type = ffi_ir.with_ownership(t(types.string), ownership.opaque_handle("buffer_free")) },
			}
			local fn = f(boundary.function_(params, t(types.void)))
			local module = f(boundary.module("m", { useBuffer = fn }, {}))

			local src, err = wit.to_wit(module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "opaque-handle"')) end
		end)

		T.it("refcount ownership is reported", function()
			local params = { { name = "handle", type = ffi_ir.with_ownership(t(types.string), ownership.refcount()) } }
			local fn = f(boundary.function_(params, t(types.void)))
			local module = f(boundary.module("m", { useHandle = fn }, {}))

			local src, err = wit.to_wit(module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "refcount"')) end
		end)

		T.it("opaque-handle on a return type is reported too, not just on params", function()
			local return_type = ffi_ir.with_ownership(t(types.string), ownership.opaque_handle(nil))
			local fn = f(boundary.function_({}, return_type))
			local module = f(boundary.module("m", { getHandle = fn }, {}))

			local src, err = wit.to_wit(module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unsupported ownership discipline "opaque-handle"')) end
		end)

	end)

	T.describe("to_wit — error cases", function()

		T.it("a standalone function/method requires a name", function()
			local fn = f(boundary.function_({}, t(types.void)))
			local src, err = wit.to_wit(fn, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "requires a name")) end
		end)

		T.it("resource ownership metadata on a non-ref TypeRef is reported", function()
			local bad_type = ffi_ir.with_ownership(t(types.string), ownership.resource("own"))
			local fn = f(boundary.function_({}, bad_type))
			local module = f(boundary.module("m", { bad = fn }, {}))

			local src, err = wit.to_wit(module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'requires a { kind: "ref" } TypeRef')) end
		end)

		T.it("a data-shape kind outside the minimal subset is reported, not guessed at", function()
			local params = { { name = "id", type = t(types.tuple({ t(types.integer) })) } }
			local fn = f(boundary.function_(params, t(types.void)))
			local module = f(boundary.module("m", { useId = fn }, {}))

			local src, err = wit.to_wit(module, nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "has no WIT mapping in this minimal data-shape subset")) end
		end)

		T.it("a boundary kind this projector does not emit is reported", function()
			local src, err = wit.to_wit(f({ kind = "gadget" }), nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, "is not a boundary construct this projector emits")) end
		end)

	end)

end)
