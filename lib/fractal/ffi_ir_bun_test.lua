-- lib/fractal/ffi_ir_bun_test.lua
-- Tests for lib/fractal/ffi_ir_bun.lua (the Bun `bun:ffi` consumer
-- projector), ported from fractal's packages/ffi-ir/src/bun.test.ts.
--
-- The TS source's `expect(...).toThrow(/pattern/)` cases become `(nil, errmsg)`
-- assertions: the projector returns its failures rather than throwing (see the
-- port's file header), so each such test asserts the value is nil and that the
-- message still carries the substring the TS regex matched.
--
-- The `toContain` assertions carry over unchanged — every one is a substring
-- test over the generated source, so none of them depends on the emission
-- ORDER of the symbol entries or wrappers, which this port derives from byte
-- order of the IR's map keys rather than JS insertion order (see the port's
-- EMISSION ORDER note). The one order-adjacent assertion, "exactly one dlopen
-- call for the whole module", is a count and is likewise unaffected.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local bun      = require("lib.fractal.ffi_ir_bun")
local ffi_ir   = require("lib.fractal.ffi_ir")
local type_ref = require("lib.fractal.type_ref")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- Substring test, standing in for the TS side's `toContain` / regex matching.
-- Plain (non-pattern) find, so a message's or a generated snippet's own
-- punctuation is never read as a Lua pattern.
--: (haystack: string, needle: string) -> boolean
local function contains(haystack, needle)
	return haystack:find(needle, 1, true) ~= nil
end

-- Number of non-overlapping occurrences of `needle` in `haystack`, standing in
-- for the TS side's `src.match(/dlopen\(/g)?.length`.
--: (haystack: string, needle: string) -> integer
local function count(haystack, needle)
	local n = 0
	local from = 1
	local _, stop = haystack:find(needle, from, true)
	while stop ~= nil do
		n = n + 1
		from = stop + 1
		_, stop = haystack:find(needle, from, true)
	end
	return n
end

-- The C-target convention for referencing an opaque resource by pointer — the
-- same helper the C-ABI and ruby-ffi backends' tests use, duplicated here
-- since ffi-ir's test files are self-contained (matching the source files' own
-- duplication precedent).
--: (resource_name: string, free_fn: string | nil) -> TypeRef
local function handle_ref(resource_name, free_fn)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(free_fn)
	)
end

T.describe("lib.fractal.ffi_ir_bun", function()

	T.describe("to_bun_ffi_type", function()

		T.it("copy discipline (or no ownership meta at all) maps primitives to their FFIType token", function()
			T.eq(bun.to_bun_ffi_type(t(types.integer)), "i64")
			T.eq(bun.to_bun_ffi_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "bool")
			T.eq(bun.to_bun_ffi_type(t(types.string)), "cstring")
			T.eq(bun.to_bun_ffi_type(t(types.void)), "void")
			T.eq(bun.to_bun_ffi_type(t(types.null)), "void")
		end)

		T.it('opaque-handle discipline becomes "ptr", regardless of the underlying shape', function()
			T.eq(bun.to_bun_ffi_type(handle_ref("FileHandle", nil)), "ptr")
		end)

		T.it("refcount discipline ALSO becomes \"ptr\" — not gated the way the C-ABI backend gates it: the "
			.. "dlopen symbol-level representation of a refcounted handle and an opaque handle are identical "
			.. "(both raw pointers); only the free-side bookkeeping differs, which this signature-only generator "
			.. "does not emit either way", function()
			T.eq(bun.to_bun_ffi_type(ffi_ir.with_ownership(t(types.integer), ownership.refcount())), "ptr")
		end)

		T.it("resource discipline (own/borrow) is reported as unsupported — WIT's Canonical ABI handle-table "
			.. "mechanism, not a raw C-ABI pointer a plain dlopen'd library speaks", function()
			local own, own_err = bun.to_bun_ffi_type(
				ffi_ir.with_ownership(t({ kind = "ref", target = "FileHandle" }), ownership.resource("own"))
			)
			T.eq(own, nil)
			T.ok(own_err ~= nil)
			if own_err ~= nil then T.ok(contains(own_err, 'unsupported ownership discipline "resource"')) end

			local borrow, borrow_err = bun.to_bun_ffi_type(
				ffi_ir.with_ownership(t({ kind = "ref", target = "FileHandle" }), ownership.resource("borrow"))
			)
			T.eq(borrow, nil)
			T.ok(borrow_err ~= nil)
			if borrow_err ~= nil then T.ok(contains(borrow_err, 'unsupported ownership discipline "resource"')) end
		end)

		T.it("struct-by-value (an \"object\" TypeRef under copy discipline) is reported — bun:ffi's FFIType "
			.. "vocabulary has no struct token", function()
			local token, err = bun.to_bun_ffi_type(t(types.object({ x = t(types.integer) })))
			T.eq(token, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unhandled kind "object"')) end
		end)

		T.it("other structurally-compound kinds are also reported rather than guessed at with a lossy "
			.. "encoding", function()
			local array_token, array_err = bun.to_bun_ffi_type(t(types.array(t(types.integer))))
			T.eq(array_token, nil)
			if array_err ~= nil then T.ok(contains(array_err, 'unhandled kind "array"')) end

			local map_token, map_err = bun.to_bun_ffi_type(t(types.map(t(types.string), t(types.integer))))
			T.eq(map_token, nil)
			if map_err ~= nil then T.ok(contains(map_err, 'unhandled kind "map"')) end

			local tuple_token, tuple_err = bun.to_bun_ffi_type(t(types.tuple({ t(types.integer), t(types.string) })))
			T.eq(tuple_token, nil)
			if tuple_err ~= nil then T.ok(contains(tuple_err, 'unhandled kind "tuple"')) end
		end)

	end)

	T.describe("to_bun — function", function()

		T.it("a simple free function: one dlopen call, one symbol entry, one wrapper", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			local src, err = bun.to_bun(add_fn, "./libmath.so", "add")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src == nil then return end

			T.ok(contains(src, 'import { dlopen } from "bun:ffi"'))
			T.ok(contains(src, 'dlopen("./libmath.so", {'))
			T.ok(contains(src, '"add": { args: ["i64", "i64"], returns: "i64" },'))
			T.ok(contains(src, "export function add(a: unknown, b: unknown) {"))
			T.ok(contains(src, 'return symbols["add"](a, b)'))
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = bun.to_bun(fn, "./lib.so", nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, '"function" requires a name')) end
		end)

		T.it("a function taking a resource parameter uses the opaque-handle ptr token", function()
			local close_fn = f(boundary.function_(
				{ { name = "handle", type = handle_ref("FileHandle", "file_handle_free") } },
				ffi_ir.with_ownership(t(types.void), ownership.copy())
			))

			local src, err = bun.to_bun(close_fn, "./lib.so", "close")
			T.eq(err, nil)
			if src ~= nil then T.ok(contains(src, '"close": { args: ["ptr"], returns: "void" },')) end
		end)

		T.it("a bare method cannot be projected standalone — it must go through its enclosing resource", function()
			local method = f(boundary.method({}, ffi_ir.with_ownership(t(types.void), ownership.copy()), "FileHandle"))
			local src, err = bun.to_bun(method, "./lib.so", "close")
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'a bare "method" cannot be projected on its own')) end
		end)

	end)

	T.describe("to_bun — resource", function()

		T.it("opaque-handle method receiver, plus an auto-generated free wrapper", function()
			local read_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.integer), ownership.copy()),
				"FileHandle"
			))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))

			local src, err = bun.to_bun(file_handle, "./lib.so", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src == nil then return end

			-- method: receiver synthesized as a leading "ptr" arg
			T.ok(contains(src, '"file_handle_read": { args: ["ptr"], returns: "i64" },'))
			T.ok(contains(src, "export function FileHandle_read(handle: number"))
			T.ok(contains(src, 'return symbols["file_handle_read"](handle)'))

			-- paired free function, matching the C-ABI backend's `<resource>_free` convention
			T.ok(contains(src, '"file_handle_free": { args: ["ptr"], returns: "void" },'))
			T.ok(contains(src, "export function FileHandle_free(handle: number) {"))
			T.ok(contains(src, 'return symbols["file_handle_free"](handle)'))
		end)

		T.it("a method whose data-shape return can't cross bun:ffi's FFIType vocabulary is reported "
			.. "(e.g. array-by-value)", function()
			local read_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.array(t(types.integer))), ownership.copy()),
				"FileHandle"
			))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method }))

			local src, err = bun.to_bun(file_handle, "./lib.so", nil)
			T.eq(src, nil)
			T.ok(err ~= nil)
			if err ~= nil then T.ok(contains(err, 'unhandled kind "array"')) end
		end)

	end)

	T.describe("to_bun — module", function()

		T.it("one dlopen call grouping every function's and every resource's methods' symbols", function()
			local close_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.void), ownership.copy()),
				"FileHandle"
			))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			local open_fn = f(boundary.function_(
				{ { name = "path", type = ffi_ir.with_ownership(t(types.string), ownership.copy()) } },
				handle_ref("FileHandle", nil)
			))
			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))

			local src, err = bun.to_bun(fs_module, "./libfs.so", nil)
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src == nil then return end

			-- exactly one dlopen call for the whole module
			T.eq(count(src, "dlopen("), 1)

			T.ok(contains(src, '"open": { args: ["cstring"], returns: "ptr" },'))
			T.ok(contains(src, '"file_handle_close": { args: ["ptr"], returns: "void" },'))
			T.ok(contains(src, '"file_handle_free": { args: ["ptr"], returns: "void" },'))

			T.ok(contains(src, "export function open(path: unknown) {"))
			T.ok(contains(src, "export function FileHandle_close(handle: number"))
			T.ok(contains(src, "export function FileHandle_free(handle: number) {"))
		end)

	end)

end)
