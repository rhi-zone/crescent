-- lib/fractal/ffi_ir_melange_test.lua
-- Tests for lib/fractal/ffi_ir_melange.lua (the Melange `external`-declaration
-- projector), ported from fractal's packages/ffi-ir/src/melange.test.ts.
--
-- Two systematic adaptations of the TS source:
--
--   1. Every `expect(() => toMelangeFfi(...)).toThrow(/.../)` becomes an
--      assertion on the `(nil, errmsg)` pair this port returns instead — the
--      source text is asserted to be nil AND the message to contain the TS
--      regex's literal substance.
--   2. Record iteration is byte-ordered here where the TS walks JS insertion
--      order (see `ordered_keys` in the module under test), so an emitted
--      record's fields can appear in a different order than the TS test's
--      `toContain` calls suggest. Every expectation below is order-independent
--      except where the ordering is itself the property under test, which is
--      the hoisted-declaration test at the bottom: OCaml requires a type to be
--      declared before it is mentioned, and that ordering is preserved by the
--      declaration LIST, not by any map's iteration order.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local ffi_ir   = require("lib.fractal.ffi_ir")
local melange  = require("lib.fractal.ffi_ir_melange")
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

T.describe("lib.fractal.ffi_ir_melange", function()

	T.describe("to_melange_ffi — function", function()

		T.it("a simple free function with copy-discipline params/return emits a plain [@@mel.val] external", function()
			local add_fn = f(boundary.function_(
				{
					{ name = "a", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
					{ name = "b", type = ffi_ir.with_ownership(t(types.integer), ownership.copy()) },
				},
				ffi_ir.with_ownership(t(types.integer), ownership.copy())
			))

			local src, err = melange.to_melange_ffi(add_fn, "add")
			T.eq(err, nil)
			T.eq(src, 'external add : int -> int -> int = "add" [@@mel.val]')
		end)

		T.it("a function with no ownership meta at all also emits (unannotated = copy-by-value default)", function()
			local fn = f(boundary.function_({ { name = "n", type = t(types.integer) } }, t(types.string)))
			local src, err = melange.to_melange_ffi(fn, "greet")
			T.eq(err, nil)
			T.eq(src, 'external greet : int -> string = "greet" [@@mel.val]')
		end)

		T.it("a no-parameter function takes `unit` — OCaml has no zero-argument function type", function()
			local fn = f(boundary.function_({}, t(types.integer)))
			local src, err = melange.to_melange_ffi(fn, "now")
			T.eq(err, nil)
			T.eq(src, 'external now : unit -> int = "now" [@@mel.val]')
		end)

		T.it("a function requires a name", function()
			local fn = f(boundary.function_({}, ffi_ir.with_ownership(t(types.void), ownership.copy())))
			local src, err = melange.to_melange_ffi(fn, nil)
			T.eq(src, nil)
			contains(err, "requires a name")
		end)

		T.it("a description on the function's meta renders as an OCaml doc comment", function()
			local fn = f(boundary.function_({}, t(types.void)), { description = "does a thing" })
			local src, err = melange.to_melange_ffi(fn, "doThing")
			T.eq(err, nil)
			contains(src, "(** does a thing *)")
		end)

		T.it("a name colliding with an OCaml keyword is suffixed with an underscore", function()
			local fn = f(boundary.function_({}, t(types.void)))
			local src, err = melange.to_melange_ffi(fn, "method")
			T.eq(err, nil)
			T.eq(src, 'external method_ : unit -> unit = "method" [@@mel.val]')
		end)

	end)

	T.describe("to_melange_ffi — ownership gating", function()

		T.it("refcount discipline on a parameter is reported — no Arc-equivalent in Melange", function()
			local fn = f(boundary.function_(
				{ { name = "h", type = ffi_ir.with_ownership(t(types.integer), ownership.refcount()) } },
				t(types.void)
			))

			local src, err = melange.to_melange_ffi(fn, "use")
			T.eq(src, nil)
			contains(err, 'unsupported ownership discipline "refcount"')
			contains(err, 'parameter "h"')
			-- The message's substance is the reasoning, not just the tag.
			contains(err, "no bundled FinalizationRegistry pairing")
		end)

		T.it("resource (own/borrow) discipline on a return type is reported — no lend-count-and-trap runtime in JS", function()
			local fn = f(boundary.function_({}, ffi_ir.resource_ref("Thing", "own")))
			local src, err = melange.to_melange_ffi(fn, "make")
			T.eq(src, nil)
			contains(err, 'unsupported ownership discipline "resource"')
			contains(err, "return type")
			contains(err, "lend-count-and-trap")
		end)

		T.it("opaque-handle discipline on a parameter passes through unchanged", function()
			local fn = f(boundary.function_(
				{ { name = "h", type = ffi_ir.with_ownership(t(types.integer), ownership.opaque_handle()) } },
				t(types.void)
			))

			local src, err = melange.to_melange_ffi(fn, "use")
			T.eq(err, nil)
			T.eq(src, 'external use : int -> unit = "use" [@@mel.val]')
		end)

	end)

	T.describe("to_melange_ffi — resource", function()

		T.it("emits a module with an abstract `type t` and [@mel.send] methods", function()
			local greet_method = f(boundary.method(
				{},
				ffi_ir.with_ownership(t(types.string), ownership.copy()),
				"Greeter"
			))
			local greeter = f(boundary.resource("Greeter", { greet = greet_method }))

			local src, err = melange.to_melange_ffi(greeter, "Greeter")
			T.eq(err, nil)
			contains(src, "module Greeter = struct")
			contains(src, "type t")
			contains(src, 'external greet : t -> string = "greet" [@@mel.send]')
			T.ok(src ~= nil)
			if src ~= nil then T.eq(src:sub(-3), "end") end
		end)

		T.it("opaque-handle discipline with a freeFn emits an extra [@mel.send]-bound free binding", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(
				boundary.resource("FileHandle", { close = close_method }),
				{ ownership = ownership.opaque_handle("file_free") }
			)

			local src, err = melange.to_melange_ffi(file_handle, "FileHandle")
			T.eq(err, nil)
			contains(src, 'external file_free : t -> unit = "file_free" [@@mel.send]')
			contains(src, 'external close : t -> unit = "close" [@@mel.send]')
		end)

		T.it("opaque-handle discipline with no freeFn emits no free binding", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(
				boundary.resource("FileHandle", { close = close_method }),
				{ ownership = ownership.opaque_handle() }
			)

			local src, err = melange.to_melange_ffi(file_handle, "FileHandle")
			T.eq(err, nil)
			contains(src, 'external close : t -> unit = "close" [@@mel.send]')
			T.eq(index_of(src, "t -> unit = \"\""), nil)
		end)

		T.it("refcount discipline on the resource's own meta is reported", function()
			local file_handle = f(boundary.resource("FileHandle", {}), { ownership = ownership.refcount() })
			local src, err = melange.to_melange_ffi(file_handle, "FileHandle")
			T.eq(src, nil)
			contains(err, 'unsupported ownership discipline "refcount"')
			contains(err, 'resource "FileHandle"')
		end)

		T.it("a methods-map entry that is not callable is reported, not rendered around", function()
			local bogus = f(boundary.resource("Bogus", { thing = f({ kind = "resource" }) }))
			local src, err = melange.to_melange_ffi(bogus, "Bogus")
			T.eq(src, nil)
			contains(err, 'resource method "thing" has unexpected kind "resource"')
		end)

	end)

	T.describe("to_melange_ffi — module", function()

		T.it("groups functions/resources into an OCaml module, functions carrying [@@mel.module]", function()
			local close_method = f(boundary.method({}, t(types.void), "FileHandle"))
			local file_handle = f(boundary.resource("FileHandle", { close = close_method }))
			-- A resource returned "own" would be reported (resource discipline is
			-- unsupported on this target — see the ownership-gating block above),
			-- so copy discipline is used here instead, matching what this target
			-- actually supports.
			local open_fn = f(boundary.function_(
				{ { name = "path", type = t(types.string) } },
				ffi_ir.with_ownership(t(types.string), ownership.copy())
			))

			local fs_module = f(boundary.module("fs", { open = open_fn }, { FileHandle = file_handle }))
			local src, err = melange.to_melange_ffi(fs_module, "fs")
			T.eq(err, nil)
			contains(src, "module Fs = struct")
			contains(src, "module FileHandle = struct")
			contains(src, 'external open_ : string -> string = "open" [@@mel.module "fs"]')
		end)

		T.it("a top-level method has no receiver to bind and is reported", function()
			local method = f(boundary.method({}, t(types.void), "FileHandle"))
			local src, err = melange.to_melange_ffi(method, "close")
			T.eq(src, nil)
			contains(err, "needs its receiver's resource type")
		end)

		T.it("an unregistered kind with no ancestor is reported", function()
			local odd = f({ kind = "gizmo" })
			local src, err = melange.to_melange_ffi(odd, "gizmo")
			T.eq(src, nil)
			contains(err, 'unhandled ffi-ir kind "gizmo"')
		end)

		T.it("a kind registered under `function` renders through the function handler", function()
			ffi_ir.register_parent("staticFunction", "function")
			local fn = f({ kind = "staticFunction", params = {}, returnType = t(types.void) })
			local src, err = melange.to_melange_ffi(fn, "reset")
			-- restore, so test order cannot leak this registration
			ffi_ir.register_parent("staticFunction", nil)

			T.eq(err, nil)
			T.eq(src, 'external reset : unit -> unit = "reset" [@@mel.val]')
		end)

	end)

	T.describe("to_melange_ffi — object/enum data-shape hoisting", function()

		T.it("an object-shaped return type hoists a named record declaration", function()
			local return_type = t(types.object({ id = t(types.string), count = t(types.integer) }))
			local fn = f(boundary.function_({}, return_type))

			local src, err = melange.to_melange_ffi(fn, "getStats")
			T.eq(err, nil)
			contains(src, "type getStatsResult = {")
			contains(src, "id : string;")
			contains(src, "count : int;")
			contains(src, "external getStats : unit -> getStatsResult")
		end)

		T.it("hoisted declarations precede the declaration that mentions them", function()
			-- The property OCaml actually constrains: a record type must be
			-- declared before it is used. Field ORDER inside the record is
			-- byte-ordered here rather than insertion-ordered as in the TS, which
			-- OCaml does not constrain.
			local return_type = t(types.object({ id = t(types.string) }))
			local fn = f(boundary.function_({}, return_type))

			local src, err = melange.to_melange_ffi(fn, "getStats")
			T.eq(err, nil)
			local decl_at = index_of(src, "type getStatsResult = {")
			local use_at = index_of(src, "external getStats :")
			T.ok(decl_at ~= nil)
			T.ok(use_at ~= nil)
			if decl_at ~= nil and use_at ~= nil then T.ok(decl_at < use_at) end
		end)

		T.it("an optional field renders as an OCaml `option`", function()
			local return_type = t(types.object({ id = t(types.string, { optional = true }) }))
			local fn = f(boundary.function_({}, return_type))

			local src, err = melange.to_melange_ffi(fn, "getStats")
			T.eq(err, nil)
			contains(src, "id : string option;")
		end)

		T.it("an enum-shaped parameter hoists a named no-payload variant", function()
			local param_type = t(types.enum({ "red", "green", "blue" }))
			local fn = f(boundary.function_({ { name = "color", type = param_type } }, t(types.void)))

			local src, err = melange.to_melange_ffi(fn, "setColor")
			T.eq(err, nil)
			contains(src, "| Red")
			contains(src, "| Green")
			contains(src, "| Blue")
		end)

		T.it("the same object TypeRef used twice hoists exactly one declaration", function()
			local shared = t(types.object({ id = t(types.string) }))
			local fn = f(boundary.function_({ { name = "a", type = shared } }, shared))

			local src, err = melange.to_melange_ffi(fn, "echo")
			T.eq(err, nil)
			T.ok(src ~= nil)
			if src ~= nil then
				local first = src:find("type ", 1, true)
				T.ok(first ~= nil)
				if first ~= nil then T.eq(src:find("type ", first + 1, true), nil) end
			end
		end)

		T.it("an array of a primitive renders as an OCaml array", function()
			local fn = f(boundary.function_({}, t(types.array(t(types.integer)))))
			local src, err = melange.to_melange_ffi(fn, "counts")
			T.eq(err, nil)
			T.eq(src, 'external counts : unit -> int array = "counts" [@@mel.val]')
		end)

		T.it("a data shape outside this file's minimal subset is reported", function()
			local fn = f(boundary.function_({}, t(types.tuple({ t(types.string) }))))
			local src, err = melange.to_melange_ffi(fn, "pair")
			T.eq(src, nil)
			contains(err, 'unsupported type-ir kind "tuple"')
		end)

	end)

end)
