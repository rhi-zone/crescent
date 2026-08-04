-- lib/fractal/ffi_ir_rust_wasm_bindgen.lua — the ffi-ir wasm-bindgen
-- projector, ported from fractal's packages/ffi-ir/src/rust-wasm-bindgen.ts.
--
-- Rust codegen targeting wasm-bindgen for ffi-ir's BOUNDARY layer —
-- module/function/resource/ownership-discipline shapes — layered ON TOP of
-- `lib/fractal/type_ref_rust_wasm_bindgen.lua` (the data-shape-only projector:
-- primitives/structs/fieldless enums/plain functions, refusing union/map/tuple/
-- intersection/interface/method-with-receiver). That file is NOT modified here;
-- this one requires it and calls its exported
-- `rust_wasm_bindgen_source_from_type_ref`/`rust_wasm_bindgen_type_from_type_ref` for
-- every data-shape position (params, return types, hoisted struct/enum
-- declarations) rather than reimplementing type mapping, and adds only what
-- ffi-ir carries that type-ir doesn't: function/module boundaries, resource
-- declarations, and ownership-discipline-aware handling.
--
-- This is the first `ffi_ir_*` backend that delegates into a `type_ref_*`
-- projector instead of carrying its own type mapping — the delegation is the
-- TS source's own structure, not a choice made by this port.
--
-- TARGET-DISCIPLINE SCOPE, carried over from the TS source's own confirmation
-- against docs/design/ffi-ir-architecture-options.md's Fork C
-- "discipline-per-target: decided" section (2026-08-03; that verification is
-- the source author's, reproduced here because it is the reasoning behind
-- every branch below, and not re-verified by this port). JS/wasm-bindgen
-- implements exactly two of the four disciplines `OwnershipDiscipline` can
-- express:
--   - `copy` — already how the type-ir projector works today (`Clone` +
--     `getter_with_clone`); reused directly here for resources too.
--   - `refcount` — an `Arc<...>`-wrapped struct, added by this file. See the
--     "FinalizationRegistry" note on `build_refcount_resource` for what the
--     source confirmed about wasm-bindgen's own free()/weak-refs machinery
--     and why no custom JS glue is emitted.
-- `opaque-handle` (no native manual-free idiom in JS — refcount already covers
-- shared ownership) and `resource`/own-borrow (no host runtime JS can enforce
-- lend-count-and-trap against) are explicitly NOT implemented:
-- `unsupported_ownership_error` reports for both, matching the
-- report-don't-degrade convention the type-ir projector already uses for the
-- kinds it can't realize, rather than approximating either discipline.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return, the same conversion the type-ir wasm-bindgen
-- projector and every other `ffi_ir_*` backend apply: an unsupported
-- discipline, a missing name, or an unmapped kind is a data error. This
-- propagates — the internal builders below return `(nil, errmsg)` too, and
-- every caller checks. The `toWasmBindgenFfi:` message prefix becomes
-- `to_wasm_bindgen_ffi:`, matching the sibling ffi-ir backends' convention of
-- prefixing with this port's own entry-point name (`to_ruby_ffi:`,
-- `to_wit:`), rather than the type-ir projector's choice to keep its TS name
-- verbatim.
--
-- NO `type_ref_kinds_common` REQUIRE. The TS source has a side-effect import
-- of type-ir's `kinds/common` purely so that package's tsc program reaches
-- `kinds/bytes.ts` and the "bytes" member exists on the merged `TypeShape`
-- interface — a TYPE-LEVEL compile artifact with no runtime meaning. Lua has
-- no declaration merging: the "bytes" handling it exists for is a plain string
-- comparison inside `type_ref_rust_wasm_bindgen.lua`'s `vec_element_type`,
-- which works whether or not the kinds module has ever been loaded. So this
-- file does not require it, matching the crescent convention every projector
-- follows (see `type_ref_gleam_native.lua`'s and `type_ref_rescript_native.lua`'s
-- headers): the CONSUMER opts into the refined-kind lattice. This file's test
-- requires it, exactly as `type_ref_rust_wasm_bindgen_test.lua` does.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.fractal.ffi_ir")
local type_ref = require("lib.fractal.type_ref")
local codegen = require("lib.fractal.type_ref_codegen")
local wb = require("lib.fractal.type_ref_rust_wasm_bindgen")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, reached transitively through the `require`s above (every
-- ffi-ir signature this file touches names them). Duplicating a type
-- definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — when a consumer (this file, and in turn this file's test) calls a
-- function whose signature names an alias declared in the required module, the
-- checker re-resolves that module's `--::` declarations in the CONSUMER's
-- scope, where type_ref.lua's `TypeRef`/`Meta` are not bound. They resolve to
-- `undefined type`, silently degrade to `any`, and the consumer reports errors
-- against the DEPENDENCY's line numbers. See the full write-up and minimal
-- repro in ffi_ir.lua's own copy of this comment, and the TODO.md entry ("an
-- alias imported via require ... degrades to any as soon as any consumer uses
-- that module"), which already records that the re-declaration is repeated in
-- each `lib/fractal/ffi_ir_*.lua` backend for this reason.
--
-- These MUST stay structurally identical to type_ref.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

-- TYPECHECKER WORKAROUND: the natural spelling for every string list below is
-- `string[]`, which desugars to `{ [number]: string }`. `table.concat`'s
-- stdlib declaration takes `{ [integer]: string | number, ... }`, and
-- `{ [number]: _ }` is not assignable to `{ [integer]: _ }`, so every
-- `table.concat` on a `string[]` is rejected. Spelling the indexer `integer`
-- explicitly is accepted. Same alias, for the same reason, as the one in
-- `type_ref_rust_wasm_bindgen.lua`; the local copy exists because that one is
-- module-private. Revert to `string[]` once the array sugar and the stdlib
-- declaration agree.
--:: StringList = { [integer]: string }

local M = {}

-- ── Layout ───────────────────────────────────────────────────────────────────

-- Prefix every NON-EMPTY line of `block`, leaving blank lines genuinely blank
-- (no trailing whitespace) — the TS source's `indent` helper and its
-- `line.length === 0` guard. `prefix` defaults to four spaces, the source's
-- own default and the only prefix any call site here uses: nesting depth in
-- the emitted Rust is entirely a product of how many times a block passes
-- through this function.
--: (block: string, prefix: string | nil) -> string
local function indent(block, prefix)
	local pre = prefix or "    "
	local out = {} --[[: StringList]]
	local n = 0
	local pos = 1
	while true do
		local nl = block:find("\n", pos, true)
		local line = nl == nil and block:sub(pos) or block:sub(pos, nl - 1)
		n = n + 1
		out[n] = #line == 0 and line or (pre .. line)
		if nl == nil then break end
		pos = nl + 1
	end
	return table.concat(out, "\n")
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of the emitted method/function/resource declarations vary between
-- runs, and this backend's output is source text whose line order is
-- observable. Byte order is the deterministic stand-in — the same
-- substitution, for the same reason, that `type_ref.lua`'s own `ordered_keys`
-- makes. The emitted SET of declarations is identical either way.
--: (tbl: { [string]: unknown }) -> StringList
local function ordered_keys(tbl)
	local out = {} --[[: StringList]]
	local n = 0
	for k in pairs(tbl) do
		if type(k) == "string" then
			n = n + 1
			out[n] = k
		end
	end
	table.sort(out)
	return out
end

-- ── Kind lattice ─────────────────────────────────────────────────────────────

-- `kind` is `target`, or has it as an ancestor, in FFI-IR's registry.
--
-- Deliberately NOT `type_ref_codegen.is_a`, which walks type_ref.lua's
-- registry: ffi-ir keeps its own, separate kind lattice (see ffi_ir.lua's
-- header — `function`/`method` name different things in the two registries),
-- and asking the wrong one would resolve a boundary kind against data-shape
-- ancestry.
--: (kind: string, target: string) -> boolean
local function is_a(kind, target)
	if kind == target then return true end
	local chain = ffi_ir.ancestors(kind)
	for i = 1, #chain do
		if chain[i] == target then return true end
	end
	return false
end

-- ── Ownership discipline ─────────────────────────────────────────────────────

local UNSUPPORTED_OPAQUE_HANDLE_REASON =
	"JS has no native manual-free idiom; if shared ownership is needed, use ownership.refcount() instead"

local UNSUPPORTED_RESOURCE_REASON =
	"no host runtime exists in JS to enforce WIT-style lend-count-and-trap semantics"

local UNSUPPORTED_SUFFIX = '. Per docs/design/ffi-ir-architecture-options.md Fork C "discipline-per-target: decided", '
	.. 'JS/wasm-bindgen implements only "copy" and "refcount" — project this value to a target that '
	.. "natively supports this discipline instead (C for opaque-handle+free-fn, WIT for resource+own/borrow)."

-- Ownership-discipline gate for a single type-ir `TypeRef` crossing this
-- target's boundary (a parameter's type or a return type) — reports for the
-- two disciplines JS/wasm-bindgen has no native mechanism for
-- (`opaque-handle`, `resource`), matching the per-target scope in the file
-- header. `copy` and `refcount` (and no `meta.ownership` at all, which means
-- copy-by-value the same way the underlying type-ir projector already treats
-- an unannotated value) pass through unchanged — this function only gates, it
-- never transforms.
--
-- Returns the error message, or nil when the position is acceptable. (A
-- `(nil, errmsg)` pair would be misleading for a function whose success value
-- is nothing at all.)
--
-- SCOPE NOTE, carried from the source: this checks the TypeRef handed to it
-- directly (a param's `.type`, a `returnType`), not a deep recursive walk into
-- e.g. an object shape's own field TypeRefs — the type-ir projector's
-- `bare_type`/`build_struct` (where that recursion happens) are module-private
-- there, so a field carrying its own `meta.ownership` inside a struct is not
-- independently gated here. That matches how the data-shape projector already
-- treats struct fields (plain data; no ownership concept crosses a struct
-- field boundary in wasm-bindgen's ABI) — ownership discipline is
-- conventionally attached at parameter/return/resource-reference positions
-- (see `with_ownership`'s own doc comment in ffi_ir.lua), not on arbitrary
-- nested fields.
--: (ref: TypeRef, where: string) -> string | nil
local function unsupported_ownership_error(ref, where)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline == nil then return nil end

	-- TYPECHECKER WORKAROUND: the natural code is `discipline.kind`, which the
	-- checker resolves for ONE test and then collapses to `never` on a second
	-- read of the same discriminant when the union arrived across a `require`
	-- — and this function reads it three times (two branch tests plus the
	-- message). Reading it through an open structural cast, exactly as
	-- `ffi_ir.ownership_of` does internally and as `ffi_ir_wit.lua`'s
	-- `to_wit_type` already does for the same reason, keeps it a plain
	-- `string` at every use. The cost is the loss of exhaustiveness checking
	-- on the union, which is precisely what a discriminant read should give.
	-- See the TODO.md entry ("a second read of an imported tagged union's
	-- discriminant ... is typed `never`"); revert to `discipline.kind` once
	-- repeated discriminant reads narrow correctly across a require.
	local kind = (discipline --[[: { kind: string, ... }]]).kind
	if kind ~= "opaque-handle" and kind ~= "resource" then return nil end

	local reason = kind == "opaque-handle" and UNSUPPORTED_OPAQUE_HANDLE_REASON or UNSUPPORTED_RESOURCE_REASON
	return 'to_wasm_bindgen_ffi: unsupported ownership discipline "'
		.. kind
		.. '" for wasm-bindgen/JS target at '
		.. where
		.. " — "
		.. reason
		.. UNSUPPORTED_SUFFIX
end

-- The discipline named by an FfiRef's OWN meta bag — the discipline a
-- `resource` DECLARATION is emitted under, as opposed to the discipline a
-- reference to a value carries. `copy` when unset, matching the type-ir
-- projector's existing copy-by-default behavior.
--
-- Reads the raw bag rather than calling `ffi_ir.ownership_of`, which takes a
-- `TypeRef`: the value here is an `FfiRef`'s meta, and the two bags are
-- distinct positions even though the record types coincide structurally. The
-- `type()` guards are the same ones `ownership_of` applies — the meta bag is
-- open, so a value under this key that is not a well-formed discipline must
-- not be silently read as a discipline.
--: (meta: Meta) -> string
local function declared_discipline_kind(meta)
	local discipline = meta.ownership
	if type(discipline) ~= "table" then return "copy" end
	local rec = discipline --[[: { kind: unknown, ... }]]
	if type(rec.kind) ~= "string" then return "copy" end
	-- TYPECHECKER WORKAROUND: two casts, not one — `type(x) == "string"` does
	-- not narrow an `unknown` FIELD to `string`, so the guarded value is
	-- re-read through a cast of the WHOLE record instead — the same two-step
	-- (`{ kind: unknown, ... }` to probe, then a cast of the original value)
	-- that `ffi_ir.ownership_of` itself uses on the same data for the same
	-- reason. See that function's own comment for the minimal repro and the
	-- TODO.md entry both sites share; revert both once this narrows correctly.
	return (discipline --[[: { kind: string, ... }]]).kind
end

-- ── Signature reconstruction ─────────────────────────────────────────────────

-- A synthetic type-ir `function` TypeRef built from ffi-ir params/return.
--
-- ffi-ir's `FfiParam`/`function`/`method` shapes are structurally identical to
-- type-ir's own `function` kind (the same `{ name, type }` params plus
-- `returnType`, minus `thisType`/`receiver`), so this is a faithful
-- reconstruction, not an approximation — it lets the type-ir projector do
-- 100% of the actual signature/hoisting/doc-comment/rename work for both
-- `function` and `method` (methods get their receiver spliced in afterward,
-- see `build_method`).
--
-- Both ownership gates run here, before any emission, so an unsupported
-- discipline is reported against the position that carries it.
--: (params: FfiParam[], return_type: TypeRef, meta: Meta) -> (TypeRef | nil, string | nil)
local function synthetic_function_ref(params, return_type, meta)
	local type_params = {} --[[: { [integer]: { name: string, type: TypeRef } }]]
	for i = 1, #params do
		local p = params[i]
		local err = unsupported_ownership_error(p.type, 'parameter "' .. p.name .. '"')
		if err ~= nil then return nil, err end
		type_params[i] = { name = p.name, type = p.type }
	end

	local return_err = unsupported_ownership_error(return_type, "return type")
	if return_err ~= nil then return nil, return_err end

	return type_ref.type_ref_from_shape(type_ref.types.function_(type_params, return_type, nil), meta), nil
end

-- Free function -> delegates entirely to the type-ir projector's
-- `rust_wasm_bindgen_source_from_type_ref` via a reconstructed `function` TypeRef
-- (see `synthetic_function_ref`).
--: (name: string, shape: FfiFunctionLike, meta: Meta) -> (string | nil, string | nil)
local function build_function(name, shape, meta)
	local ref, err = synthetic_function_ref(shape.params, shape.returnType, meta)
	if ref == nil then return nil, err end
	return wb.rust_wasm_bindgen_source_from_type_ref(ref, name)
end

-- Method -> reuses the type-ir projector's free-function emission (hoisted
-- declarations, `todo!()` stub, `js_name` renaming, doc comments) via the same
-- synthetic-ref reconstruction, then splices a `&self` receiver into the
-- generated signature. String manipulation, not re-derivation: that projector
-- does not export its internal `build_function`/`bare_type`, so this is the
-- only reuse path that doesn't reimplement type mapping and struct-hoisting
-- from scratch.
--
-- The substitution is bounded to ONE replacement, matching the TS source's
-- non-global `String.replace`. Any hoisted struct/enum declarations the
-- projector emitted ahead of the function carry no `pub fn`, so the first
-- match is the function's own signature.
--
-- PATTERN DIVERGENCE, forced: the TS regex is `/pub fn (\w+)\(/`, and JS `\w`
-- includes `_` while Lua's `%w` does not — a snake_cased `read_file` would
-- match only `read` and then fail on `_`. The Lua pattern spells the class out
-- as `[%w_]+`, which is the same character class the TS regex means.
--
-- RECEIVER MUTABILITY, a judgment call carried over from the source: methods
-- are spliced with `&self` (shared reference), never `&mut self` — ffi-ir's
-- `method` kind carries no mutability signal (nothing on `FfiParam` or the
-- shape distinguishes a read from a write), so there is no schema-driven way
-- to pick `&mut self` for some methods and `&self` for others. `&self`
-- compiles for both read-only access and, via the refcount resource's `Arc`
-- without interior mutability, for shared-but-immutable access; a method that
-- genuinely needs mutation requires the resource's backing data wrapped in
-- `Mutex`/`RwLock` by hand and its emitted body edited accordingly. This
-- projector does not infer that need, and names the limit rather than
-- guessing at it — same as `build_refcount_resource`'s Arc-vs-Arc<Mutex<_>>
-- call below.
--: (name: string, shape: FfiFunctionLike, meta: Meta) -> (string | nil, string | nil)
local function build_method(name, shape, meta)
	local ref, err = synthetic_function_ref(shape.params, shape.returnType, meta)
	if ref == nil then return nil, err end
	local rendered, render_err = wb.rust_wasm_bindgen_source_from_type_ref(ref, name)
	if rendered == nil then return nil, render_err end
	local receiver = #shape.params == 0 and "pub fn %1(&self" or "pub fn %1(&self, "
	return (rendered:gsub("pub fn ([%w_]+)%(", receiver, 1)), nil
end

-- One entry of a resource's `methods` map.
--
-- ffi-ir's own lattice makes `method` a subtype of `function`, and the TS
-- source accepts either kind here for that reason; anything else is a
-- malformed methods map and is reported.
--: (method_name: string, method_ref: FfiRef) -> (string | nil, string | nil)
local function build_resource_method(method_name, method_ref)
	local kind = method_ref.shape.kind
	if kind ~= "method" and kind ~= "function" then
		return nil,
			'to_wasm_bindgen_ffi: resource method "'
				.. method_name
				.. '" has unexpected kind "'
				.. kind
				.. '" (expected "method")'
	end
	return build_method(method_name, method_ref.shape --[[: FfiFunctionLike]], method_ref.meta)
end

-- ── Resource declarations ────────────────────────────────────────────────────

-- The `/// ...` doc-comment lines for a meta bag: one line when `description`
-- holds a string, none otherwise. Returned as a list because every caller
-- splices it into a line list.
--: (meta: Meta) -> StringList
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: StringList]] end
	return { "/// " .. description } --[[: StringList]]
end

-- The fieldless-storage note both resource builders emit. ffi-ir's `resource`
-- kind — per its own doc comment in ffi_ir.lua ("exposes behavior ONLY through
-- `methods`, mirroring WIT's own constraint that resources cannot be plain
-- data structures") — carries no field/data shape at all, unlike an `object`
-- TypeRef. The generated struct is therefore intentionally fieldless: its
-- private Rust-side storage is implementation detail outside ffi-ir's boundary
-- contract, the same "signature is the contract, body is a stub" precedent the
-- type-ir projector's `todo!()` bodies already set for behavior.
local FIELDS_NOTE = {
	"// Fields are implementation-internal — ffi-ir's `resource` kind models",
	"// only the boundary's method surface, not private storage (see the",
	"// FfiKinds.resource doc comment in @rhi-zone/fractal-ffi-ir). Fill in",
	"// the actual fields this resource wraps.",
} --[[: StringList]]

-- Append every element of `src` to `dst`, returning the new length. (Lua has
-- no list-spread; the TS source's `[...description, ...]` array literals
-- become this.)
--: (dst: StringList, n: integer, src: StringList) -> integer
local function append_all(dst, n, src)
	local count = n
	for i = 1, #src do
		count = count + 1
		dst[count] = src[i]
	end
	return count
end

-- Every method of `methods`, each already indented one level, in byte order of
-- the method names.
--: (methods: { [string]: FfiRef }) -> (StringList | nil, string | nil)
local function build_indented_methods(methods)
	local out = {} --[[: StringList]]
	local names = ordered_keys(methods)
	for i = 1, #names do
		local rendered, err = build_resource_method(names[i], methods[names[i]])
		if rendered == nil then return nil, err end
		out[i] = indent(rendered, nil)
	end
	return out, nil
end

-- `copy`-discipline resource -> the type-ir projector's existing struct
-- pattern (`#[derive(Clone)]`), reused by name only (not re-derived) since the
-- resource carries no fields (see `FIELDS_NOTE`). No `getter_with_clone`
-- attribute is emitted: it only matters for non-`Copy` fields, and there are
-- no fields.
--: (name: string, methods: { [string]: FfiRef }, meta: Meta) -> (string | nil, string | nil)
local function build_copy_resource(name, methods, meta)
	local struct_lines = doc_comment(meta)
	local n = append_all(struct_lines, #struct_lines, FIELDS_NOTE)
	struct_lines[n + 1] = "#[derive(Clone)]"
	struct_lines[n + 2] = "#[wasm_bindgen]"
	struct_lines[n + 3] = "pub struct " .. name .. " {}"

	local rendered_methods, err = build_indented_methods(methods)
	if rendered_methods == nil then return nil, err end

	local impl_block = { "#[wasm_bindgen]", "impl " .. name .. " {" } --[[: StringList]]
	local m = append_all(impl_block, 2, rendered_methods)
	impl_block[m + 1] = "}"

	return table.concat(struct_lines, "\n") .. "\n\n" .. table.concat(impl_block, "\n"), nil
end

-- `refcount`-discipline resource. Emits a struct wrapping the resource's
-- (implementation-internal, same fieldless reasoning as `build_copy_resource`)
-- data in `Arc<NameData>`, an explicit `share()` method (`Arc::clone` — the
-- increment path; a JS caller wanting a second owning handle to the same
-- underlying value calls this rather than any implicit copy), and relies on
-- wasm-bindgen's own generated `free()` for the decrement path: dropping the
-- struct drops its `Arc` field and decrements the strong count through `Arc`'s
-- own `Drop`, ordinary Rust semantics with nothing custom needed.
--
-- FINALIZATION, verified by the TS source's author (WebFetch against
-- rustwasm.github.io/docs/wasm-bindgen's "Support for Weak References" page,
-- 2026-08-03; reproduced here, not re-verified by this port): wasm-bindgen
-- auto-generates a `.free()` for every `#[wasm_bindgen]`-exported struct AND —
-- since the TC39 weak-refs proposal shipped — "by default wasm-bindgen does
-- use the TC39 weak references proposal if support is detected" (all major
-- browsers do), pairing that generated `free()` with a wasm-bindgen-internal
-- `FinalizationRegistry` automatically, with no `--weak-refs` flag or Cargo
-- feature. So no custom Rust release function distinct from the default
-- `free()`, and no hand-written JS `FinalizationRegistry` snippet, is needed
-- to get the `Arc` decremented when the JS-side handle is collected — and none
-- is emitted. What the same research DID surface, and what is emitted as a
-- comment on the struct, is the caveat: automatic GC-driven cleanup is
-- non-deterministic and — per a still-open wasm-bindgen issue (#3917) — does
-- not run at all in fully synchronous code, so a JS caller wanting
-- deterministic release should call the generated `.free()` explicitly rather
-- than rely solely on GC.
--
-- ARC VS ARC<MUTEX<_>>, a judgment call carried over from the source: plain
-- `Arc<NameData>` (no interior mutability) is emitted. ffi-ir's `method` kind
-- carries no mutability signal to decide this from (the same gap named on
-- `build_method`'s `&self`-only splice) — `Arc<Mutex<NameData>>` would be a
-- defensible alternative if any of the resource's methods need to mutate
-- shared state, at the cost of lock overhead and deadlock risk for the ones
-- that don't. Named explicitly rather than guessed: a caller whose resource
-- methods need mutation changes the field to `Arc<Mutex<NameData>>` and
-- threads `.lock()` through the generated bodies by hand.
--: (name: string, methods: { [string]: FfiRef }, meta: Meta) -> (string | nil, string | nil)
local function build_refcount_resource(name, methods, meta)
	local data_name = name .. "Data"
	local data_struct = table.concat(FIELDS_NOTE, "\n") .. "\n" .. "struct " .. data_name .. " {}"

	local struct_lines = doc_comment(meta)
	local n = append_all(struct_lines, #struct_lines, {
		"// Shared ownership via Arc — wasm-bindgen already generates a `free()`",
		"// for this struct and (per the TC39 weak-references proposal, on by",
		"// default when the JS runtime supports it) pairs it with its own",
		"// FinalizationRegistry, so dropping the last JS-side handle decrements",
		"// this Arc automatically. GC timing is non-deterministic and does not",
		"// run in fully synchronous code (wasm-bindgen#3917) — call `.free()`",
		"// explicitly from JS when deterministic release matters.",
		"#[wasm_bindgen]",
	} --[[: StringList]])
	struct_lines[n + 1] = "pub struct " .. name .. " {"
	struct_lines[n + 2] = "    inner: std::sync::Arc<" .. data_name .. ">,"
	struct_lines[n + 3] = "}"

	local share_method = table.concat({
		"/// Returns a new handle sharing ownership of the same underlying value",
		"/// (increments the refcount — the explicit share path for this",
		"/// discipline; there is no implicit/automatic clone across the JS",
		"/// boundary).",
		"#[wasm_bindgen]",
		"pub fn share(&self) -> Self {",
		"    Self { inner: std::sync::Arc::clone(&self.inner) }",
		"}",
	} --[[: StringList]], "\n")

	local rendered_methods, err = build_indented_methods(methods)
	if rendered_methods == nil then return nil, err end

	local impl_block = { "#[wasm_bindgen]", "impl " .. name .. " {", indent(share_method, nil) } --[[: StringList]]
	local m = append_all(impl_block, 3, rendered_methods)
	impl_block[m + 1] = "}"

	return data_struct .. "\n\n" .. table.concat(struct_lines, "\n") .. "\n\n" .. table.concat(impl_block, "\n"), nil
end

-- Resource dispatch by ownership discipline. `meta.ownership` on the
-- resource's own `FfiRef` (not on a reference to it) names which discipline
-- this declaration itself is emitted under.
--: (name: string, methods: { [string]: FfiRef }, meta: Meta) -> (string | nil, string | nil)
local function build_resource(name, methods, meta)
	local discipline = declared_discipline_kind(meta)
	if discipline == "copy" then return build_copy_resource(name, methods, meta) end
	if discipline == "refcount" then return build_refcount_resource(name, methods, meta) end
	return nil,
		'to_wasm_bindgen_ffi: unsupported ownership discipline "'
			.. discipline
			.. '" for wasm-bindgen/JS target on resource "'
			.. name
			.. '" — JS/wasm-bindgen implements only "copy" and "refcount" for resource declarations (see the '
			.. "file-level doc comment)"
end

-- ── Module ───────────────────────────────────────────────────────────────────

-- Module -> groups its functions and resources into a `pub mod name { ... }`.
-- wasm-bindgen has no module-scoping attribute of its own; `#[wasm_bindgen]`
-- items work unmodified inside an ordinary Rust `mod` block (confirmed by the
-- guide's own multi-file examples nesting exports under plain Rust modules),
-- so this is the direct mapping.
--
-- Resources are emitted before functions, the source's own order.
--: (name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_module(name, functions, resources)
	local decls = {} --[[: StringList]]
	local n = 0

	local res_names = ordered_keys(resources)
	for i = 1, #res_names do
		local decl, err = M.to_wasm_bindgen_ffi(resources[res_names[i]], res_names[i])
		if decl == nil then return nil, err end
		n = n + 1
		decls[n] = decl
	end

	local fn_names = ordered_keys(functions)
	for i = 1, #fn_names do
		local decl, err = M.to_wasm_bindgen_ffi(functions[fn_names[i]], fn_names[i])
		if decl == nil then return nil, err end
		n = n + 1
		decls[n] = decl
	end

	local body = table.concat(decls, "\n\n")
	local lines = {
		"pub mod " .. codegen.snake_case_strip_separators(name) .. " {",
		"    use wasm_bindgen::prelude::*;",
		"",
		indent(body, nil),
		"}",
	} --[[: StringList]]
	return table.concat(lines, "\n"), nil
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to `#[wasm_bindgen]`-annotated Rust source.
--
-- `name` is REQUIRED for every kind — `function`/`method`/`resource` are all
-- named top-level or impl-scoped declarations (mirroring the type-ir
-- projector's own "wasm-bindgen exports are named JS bindings, not anonymous
-- inline types" requirement) and `module` needs the `pub mod` name. Unlike the
-- Ruby and C-ABI backends, a `resource`'s explicit `name` argument is USED
-- rather than ignored in favor of the shape's own `name` field: that is the TS
-- source's behavior, and it is what makes the recursive call from
-- `build_module` name each resource by its key in the module's `resources`
-- map.
--
-- Reports — never silently degrades — for: a missing `name`, an ownership
-- discipline this target has no native mechanism for (`opaque-handle`,
-- `resource`/own-borrow, at a parameter, a return type, or on a resource
-- declaration), a malformed entry in a resource's `methods` map, a boundary
-- kind with no handler and no known ancestor, and any data shape the
-- underlying type-ir projector itself refuses (union, map, tuple, ... — its
-- message is propagated unchanged).
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_wasm_bindgen_ffi(ref, name)
	local kind = ref.shape.kind

	if name == nil then
		return nil,
			'to_wasm_bindgen_ffi: "'
				.. kind
				.. '" requires a name — wasm-bindgen exports are named JS bindings/modules, not anonymous inline '
				.. "declarations"
	end

	if kind == "function" then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta)
	end

	if kind == "method" then
		return build_method(name, ref.shape --[[: FfiFunctionLike]], ref.meta)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { methods: { [string]: FfiRef }, ... }]]
		return build_resource(name, shape.methods, ref.meta)
	end

	if kind == "module" then
		local shape = ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		return build_module(name, shape.functions, shape.resources)
	end

	-- A consumer-registered kind whose nearest ancestor is `function` (through
	-- ffi_ir's own `register_parent` extension mechanism) falls back to the
	-- free-function path, mirroring the `method` -> `function` ancestry
	-- ffi_ir.lua seeds the registry with.
	if is_a(kind, "function") then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta)
	end

	return nil, 'to_wasm_bindgen_ffi: unhandled ffi-ir kind "' .. kind .. '" (no handler and no known ancestor)'
end

-- Re-exported unchanged from the type-ir projector, reproducing the TS
-- source's own `export { toWasmBindgenType }`: a caller lowering ffi-ir
-- boundary shapes routinely also needs the inline Rust type for a bare
-- data-shape `TypeRef`, and re-exporting saves it a second require. Same name
-- as in `type_ref_rust_wasm_bindgen.lua` — it is that function, not a wrapper.
M.rust_wasm_bindgen_type_from_type_ref = wb.rust_wasm_bindgen_type_from_type_ref

return M
