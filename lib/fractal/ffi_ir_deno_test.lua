-- lib/fractal/ffi_ir_deno_test.lua
-- Tests for lib/fractal/ffi_ir_deno.lua (the Deno FFI consumer projector),
-- ported from fractal's packages/ffi-ir/src/deno.test.ts.
--
-- Two systematic differences from the TS tests, both consequences of decisions
-- documented in the backend itself:
--
--   1. The TS source throws where this port returns `(nil, errmsg)`, so every
--      `expect(...).toThrow(/re/)` becomes an assertion that the value is nil
--      and the message contains the regex's literal substance.
--   2. `expect(src).toContain(...)` becomes `contains` below (a plain
--      substring search — `lib/test/assert`'s `eq` is `~=`, which on strings is
--      exact equality, so a containment check needs its own helper).
--
-- Emission ORDER differs from the TS backend's (byte order in place of JS
-- insertion order — see the backend's header), which none of these assertions
-- depend on: they are all substring checks, plus one whole-source equality
-- between two fixtures that differ only in ownership metadata.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local type_ref = require("lib.fractal.type_ref")
local deno     = require("lib.fractal.ffi_ir_deno")

local ownership = ffi_ir.ownership
local boundary  = ffi_ir.boundary
local types     = type_ref.types
local t         = type_ref.type_ref_from_shape
local f         = ffi_ir.ffi_ref_from_shape

-- `expect(haystack).toContain(needle)`, plain (non-pattern) search.
--: (haystack: string | nil, needle: string) -> nil
local function contains(haystack, needle)
	if haystack == nil then
		T.ok(false, "expected generated source, got nil (" .. needle .. ")")
		return
	end
	T.ok(haystack:find(needle, 1, true) ~= nil, "expected output to contain: " .. needle)
end

-- The `(nil, errmsg)` counterpart of `expect(...).toThrow(/needle/)`.
--: (value: string | nil, err: string | nil, needle: string) -> nil
local function failed_with(value, err, needle)
	T.eq(value, nil)
	if err == nil then
		T.ok(false, "expected an error mentioning: " .. needle)
		return
	end
	T.ok(err:find(needle, 1, true) ~= nil, "expected error to mention: " .. needle)
end

-- The TS test's own `handleRef` fixture helper: a `ref` TypeRef pointing at a
-- resource by name, carrying opaque-handle ownership.
--: (resource_name: string, free_fn: string | nil) -> TypeRef
local function handle_ref(resource_name, free_fn)
	return ffi_ir.with_ownership(
		{ shape = { kind = "ref", target = resource_name }, meta = {} },
		ownership.opaque_handle(free_fn)
	)
end

T.describe("lib.fractal.ffi_ir_deno", function()

	T.describe("deno_ffi_type", function()

		T.it("copy discipline (or no ownership meta at all) maps primitives to Deno's FFI type vocabulary", function()
			T.eq(deno.deno_ffi_type(t(types.integer)), "i64")
			T.eq(deno.deno_ffi_type(t(types.number)), "f64")
			T.eq(deno.deno_ffi_type(ffi_ir.with_ownership(t(types.boolean), ownership.copy())), "u8")
			T.eq(deno.deno_ffi_type(t(types.void)), "void")
		end)

		T.it("bytes maps to Deno's native buffer type", function()
			T.eq(deno.deno_ffi_type(t({ kind = "bytes" })), "buffer")
		end)

		T.it("opaque-handle, refcount and resource disciplines all collapse to pointer", function()
			-- Deno's raw FFI layer has no ownership model of its own to
			-- distinguish them (see the backend's file header).
			local ref_shape = { kind = "ref", target = "FileHandle" }
			T.eq(deno.deno_ffi_type(handle_ref("FileHandle")), "pointer")
			T.eq(deno.deno_ffi_type(ffi_ir.with_ownership(t(ref_shape), ownership.refcount())), "pointer")
			T.eq(deno.deno_ffi_type(ffi_ir.with_ownership(t(ref_shape), ownership.resource("own"))), "pointer")
			T.eq(deno.deno_ffi_type(ffi_ir.with_ownership(t(ref_shape), ownership.resource("borrow"))), "pointer")
		end)

		T.it("string reports a gap — no native Deno FFI type and no C-ABI encoding convention", function()
			local mapped, err = deno.deno_ffi_type(t(types.string))
			failed_with(mapped, err, "no native Deno FFI type")
		end)

		T.it("object (struct-shaped) reports a gap — this projector computes no C-ABI layout", function()
			local mapped, err = deno.deno_ffi_type(t(types.object({ n = t(types.integer) })))
			failed_with(mapped, err, "no mapping in this minimal projector")
		end)

	end)

	T.describe("to_deno_ffi — simple function", function()

		T.it("a free function with copy-discipline primitive params/return", function()
			local add_fn = f(
				boundary.function_(
					{
						{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
						{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					},
					ffi_ir.with_ownership(t(types.integer), ownership.copy())
				),
				{ libPath = "./libmath.so" }
			)

			local src, err = deno.to_deno_ffi(add_fn, "add")
			T.eq(err, nil)

			contains(src, 'Deno.dlopen("./libmath.so"')
			contains(src, '"add": { parameters: ["i64", "i64"], result: "i64" }')
			contains(src, "export function add(a: bigint, b: bigint): bigint {")
			contains(src, "return lib.symbols.add(a, b) as bigint")
		end)

		T.it("a function requires a name", function()
			local fn = f(
				boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())),
				{ libPath = "./lib.so" }
			)
			local src, err = deno.to_deno_ffi(fn, nil)
			failed_with(src, err, '"function" requires a name')
		end)

		T.it("a function without meta.libPath reports a gap — no derivable dlopen path", function()
			local fn = f(boundary.function_({}, t(types.void)), nil)
			local src, err = deno.to_deno_ffi(fn, "noop")
			failed_with(src, err, "missing required meta.libPath")
		end)

	end)

	T.describe("to_deno_ffi — resource with an opaque-handle method", function()

		T.it("methods take/return a pointer-typed handle; a paired free wrapper is synthesized", function()
			-- "string" isn't crossable per deno_ffi_type's own reported gap (see the
			-- dedicated block above) — "path" is typed as bytes here to build a
			-- realistic module without hitting that unrelated, separately-tested
			-- limitation.
			local open_fn_bytes = f(
				boundary.function_({ { name = "path", type = t({ kind = "bytes" }) } }, handle_ref("FileHandle")),
				{ libPath = "./libfile.so" }
			)

			local read_method = f(boundary.method({}, t({ kind = "bytes" }), "FileHandle"))
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { read = read_method, close = close_method }))
			local fs_module = f(
				boundary.module("fs", { open = open_fn_bytes }, { FileHandle = file_handle }),
				{ libPath = "./libfile.so" }
			)

			local src, err = deno.to_deno_ffi(fs_module, nil)
			T.eq(err, nil)

			contains(src, '"open": { parameters: ["buffer"], result: "pointer" }')
			contains(src, '"file_handle_read": { parameters: ["pointer"], result: "buffer" }')
			contains(src, '"file_handle_close": { parameters: ["pointer"], result: "void" }')
			contains(src, '"file_handle_free": { parameters: ["pointer"], result: "void" }')

			contains(src, "export function open(path: Uint8Array | null): Pointer {")
			contains(src, "export function fileHandleRead(handle: Pointer): Uint8Array | null {")
			contains(src, "export function fileHandleClose(handle: Pointer): void {")
			contains(src, "export function fileHandleFree(handle: Pointer): void {")
			contains(src, "lib.symbols.file_handle_free(handle)")
		end)

	end)

	T.describe("to_deno_ffi — refcount/resource disciplines produce identical codegen to opaque-handle", function()

		T.it("a method returning a refcount- or resource-disciplined reference emits the same wrapper", function()
			local node_shape = { kind = "ref", target = "Node" }
			local share_method_refcount = f(
				boundary.method({}, ffi_ir.with_ownership(t(node_shape), ownership.refcount()), "Node")
			)
			local share_method_resource = f(
				boundary.method({}, ffi_ir.with_ownership(t(node_shape), ownership.resource("own")), "Node")
			)
			local node_refcount = f(
				boundary.resource("Node", { share = share_method_refcount }),
				{ libPath = "./libtree.so" }
			)
			local node_resource = f(
				boundary.resource("Node", { share = share_method_resource }),
				{ libPath = "./libtree.so" }
			)

			local src_refcount, refcount_err = deno.to_deno_ffi(node_refcount, "Node")
			local src_resource, resource_err = deno.to_deno_ffi(node_resource, "Node")
			T.eq(refcount_err, nil)
			T.eq(resource_err, nil)

			-- Same symbol/parameter/result shape either way — Deno's raw FFI layer
			-- draws no distinction between refcount and own/borrow resource
			-- disciplines (see the backend's file header); only the ownership
			-- metadata differs between the two fixtures above, and it produces
			-- byte-identical generated source.
			T.eq(src_refcount, src_resource)
			contains(src_refcount, '"node_share": { parameters: ["pointer"], result: "pointer" }')
			contains(src_refcount, "export function nodeShare(handle: Pointer): Pointer {")
		end)

	end)

end)
