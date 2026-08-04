-- lib/fractal/ffi_ir_ruby_ffi.lua — the Ruby `ffi` gem projector, ported from
-- fractal's packages/ffi-ir/src/ruby-ffi.ts.
--
-- This is the consumer side of the C-ABI backend: where that backend emits the
-- Rust source implementing a plain C ABI, this file emits the Ruby-side loader
-- code that calls INTO a compiled C-ABI shared library through the `ffi` gem
-- (https://github.com/ffi/ffi). That is a different shape of task than every
-- other projector in this family: those all target languages with their own
-- native FFI-declaration syntax embedded in the producer language itself
-- (Rust's `#[wasm_bindgen]`, WIT text, ReScript's `external`, Gleam's
-- `@external`); the `ffi` gem is a pure *consumer*-side runtime library — Ruby
-- has no calling-into-C syntax of its own, so binding declarations are
-- ordinary Ruby method calls (`ffi_lib`, `attach_function`) evaluated at load
-- time, not a compiler-recognized attribute/keyword.
--
-- `ffi` gem API, verified 2026-08-03 against github.com/ffi/ffi's wiki by the
-- TS source's author (not carried over from memory, and not re-verified by
-- this port — the findings below are the TS source's, reproduced because they
-- are the reasoning behind every mapping choice in this file):
--   - Basic-Usage (github.com/ffi/ffi/wiki/Basic-Usage): the canonical pattern
--     is `module Foo; extend FFI::Library; ffi_lib 'libname_or_path';
--     attach_function :symbol, [:argtype, ...], :returntype; end` — `extend
--     FFI::Library` "enables you to attach native functions to the module",
--     `ffi_lib` "specifies which C library to load", `attach_function`
--     "locates the C function in a specific external library and maps it to
--     Ruby". `attach_function` also accepts a two-name form
--     (`attach_function :ruby_name, :c_symbol, [...], :return`) when the
--     Ruby-side method name should differ from the C symbol — not used here,
--     since this projector always derives both from the same ffi-ir name via
--     the same snake_case convention the C-ABI backend already uses for its
--     Rust exports, so the two names always coincide.
--   - Types (github.com/ffi/ffi/wiki/Types): confirmed type-symbol vocabulary
--     includes `:bool`, `:string`, `:pointer`, `:void`, and the sized integer
--     family `:int8`/`:uint8`/`:int16`/`:uint16`/`:int32`/`:uint32`/`:int64`/
--     `:uint64` (plus platform aliases `:int`/`:long`/etc, not used here in
--     favor of the explicitly-sized forms), and `:float`/`:double` for
--     floating point.
--   - Structs (github.com/ffi/ffi/wiki/Structs): `class Foo < FFI::Struct;
--     layout :field, :type, ...; end` for structs with known field layout —
--     NOT used for opaque handles here (see below).
--   - Pointers (github.com/ffi/ffi/wiki/Pointers): no documented
--     typedef-to-a-named-handle-type convention, and Structs' own page doesn't
--     address opaque (fields-unknown) handles either. The confirmed,
--     documented idiom for an opaque handle in both pages is a bare `:pointer`
--     used directly in `attach_function`'s type list — NOT an `FFI::Struct`
--     subclass with an empty `layout` (no such convention is documented
--     anywhere fetched; a struct's whole purpose per the Structs page is
--     exposing named fields, which an opaque handle by definition has none
--     of). So: bare `:pointer`, not a struct wrapper.
--
-- OWNERSHIP-DISCIPLINE MAPPING (see `OwnershipDiscipline` in ffi_ir.lua).
-- Unlike a GC'd target (where every discipline produces the same declaration)
-- this target has ONE real branch, not zero — `copy` crosses as the value's
-- own mapped type (`to_base_ruby_ffi_type`'s table below), because the ffi
-- gem's type-symbol vocabulary genuinely distinguishes value types from
-- `:pointer`. But `opaque-handle`, `refcount`, and `resource` (own/borrow) all
-- collapse to the exact same `:pointer` declaration as each other: the `ffi`
-- gem's type vocabulary (see Types above) has no ownership-aware pointer
-- variant — refcounting and WIT-style own/borrow are memory-management
-- PROTOCOLS a caller or generated wrapper follows on top of a plain pointer,
-- not something `attach_function`'s type-symbol list itself distinguishes. So
-- this is the "declaration is identical regardless of discipline" case for
-- three of the four, not a failure — there is no unsupported discipline here
-- at all, since every one maps onto something the gem can genuinely express
-- (unlike the C-ABI backend, which cannot express refcount/resource because
-- plain C itself has no refcounting or lend-count runtime).
--
-- RESOURCE -> FREE FUNCTION. Since this projector's stated purpose is calling
-- into a C-ABI-produced shared library specifically, it mirrors that backend's
-- own `<resource>_free` naming convention by attaching that same paired free
-- function as an ordinary `attach_function` alongside the resource's own
-- methods — the Ruby-side counterpart callers need to actually release a
-- handle obtained from this library, not a new convention invented here.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `type_ref.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported shape or a
-- missing `meta.libPath` is a data error, not a programming error. This
-- propagates — the internal builders below return `(nil, errmsg)` too, and
-- every caller checks.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.fractal.ffi_ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, reached transitively through the `require` above (every
-- ffi-ir signature this file touches names them). Duplicating a type
-- definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — when a consumer (this file, and in turn this file's test) calls a
-- function whose signature names an alias declared in the required module, the
-- checker re-resolves that module's `--::` declarations in the CONSUMER's
-- scope, where type_ref.lua's `TypeRef`/`Meta` are not bound. They resolve to
-- `undefined type`, silently degrade to `any`, and the consumer reports errors
-- against the DEPENDENCY's line numbers. See the full write-up and minimal
-- repro in ffi_ir.lua's own copy of this comment, and the TODO.md entry
-- ("an alias imported via require ... degrades to any as soon as any consumer
-- uses that module"), which already records that the re-declaration is
-- repeated in each `lib/fractal/ffi_ir_*.lua` backend for this reason.
--
-- These MUST stay structurally identical to type_ref.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- The snake_case symbol convention shared with the C-ABI backend, so a Ruby
-- binding's symbol name matches the C symbol that backend exported.
--
-- The three rewrites are the TS source's three regexes, in order: split a
-- lower/digit-to-upper boundary with an underscore (`readFile` ->
-- `read_File`), collapse every run of non-alphanumerics into one underscore,
-- strip leading/trailing underscores, lowercase the result.
--: (name: string) -> string
local function to_snake_case(name)
	local split = (name:gsub("([a-z0-9])(%u)", "%1_%2"))
	local collapsed = (split:gsub("[^a-zA-Z0-9]+", "_"))
	local head_trimmed = (collapsed:gsub("^_+", ""))
	local trimmed = (head_trimmed:gsub("_+$", ""))
	return trimmed:lower()
end

-- The Ruby module-name convention: non-alphanumeric runs become word
-- boundaries, each word's first character is uppercased, and the words are
-- concatenated. A word's remaining characters are left ALONE, not lowercased
-- — `HTTPClient` stays `HTTPClient`, matching the TS source, which likewise
-- only maps `word[0]` and appends `word.slice(1)` unchanged.
--: (name: string) -> string
local function pascal_case(name)
	local spaced = (name:gsub("[^a-zA-Z0-9]+", " "))
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	-- Splitting on " " and dropping empty pieces (the TS source's
	-- `split(" ").filter(len > 0)`) is exactly a match over non-space runs.
	for word in spaced:gmatch("[^ ]+") do
		n = n + 1
		out[n] = word:sub(1, 1):upper() .. word:sub(2)
	end
	return table.concat(out)
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements. This reproduces the TS source's `JSON.stringify` —
-- deliberately, rather than "improving" on it: Ruby's `#{...}` interpolation
-- is NOT escaped here because JSON.stringify does not escape `#` either, and
-- diverging would mean this port emits different Ruby than the source it is a
-- port of. Every string reaching `quote` today is a snake_case symbol name or
-- a library path, neither of which can contain an interpolation sequence.
local ESCAPES = {
	["\\"] = "\\\\",
	['"'] = '\\"',
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
} --[[: { [string]: string }]]

-- One character's escaped form: its named escape when it has one, else the
-- `\uXXXX` form `JSON.stringify` uses for the remaining control characters.
--: (c: string) -> string
local function escape_char(c)
	local mapped = ESCAPES[c]
	if mapped ~= nil then return mapped end
	return string.format("\\u%04X", string.byte(c) or 0)
end

-- `value` as a double-quoted Ruby string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- The `# ...` doc-comment lines for a meta bag: one line when `description`
-- holds a string, none otherwise. Returned as a list because callers splice it
-- into a line list.
--: (meta: Meta) -> { [integer]: string }
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: { [integer]: string } ]] end
	return { "# " .. description } --[[: { [integer]: string } ]]
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of the emitted `attach_function` declarations vary between runs. Byte
-- order is the deterministic stand-in — the same substitution, for the same
-- reason, that type_ref.lua's own `ordered_keys` makes. The emitted SET of
-- declarations is identical either way.
--: (tbl: { [string]: unknown }) -> { [integer]: string }
local function ordered_keys(tbl)
	local out = {} --[[: { [integer]: string } ]]
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

-- ── Type mapping ─────────────────────────────────────────────────────────────

-- Base (no-ownership-metadata, or `copy` discipline) type mapping —
-- intentionally minimal: only the type-ir kinds that map onto a genuine
-- `ffi`-gem primitive symbol. Anything structural (`object`, `array`, `tuple`,
-- `map`, `union`, `enum`, a bare unannotated `ref`, ...) would require
-- synthesizing an `FFI::Struct` subclass or a richer per-shape convention this
-- projector does not define, so it reports the gap explicitly rather than
-- guessing at one — the same report-don't-degrade precedent the C-ABI and
-- wasm-bindgen backends use for the shapes and disciplines they do not
-- implement.
--: (ref: TypeRef) -> (string | nil, string | nil)
local function to_base_ruby_ffi_type(ref)
	local kind = ref.shape.kind
	if kind == "boolean" then return ":bool" end
	if kind == "number" then return ":double" end
	if kind == "integer" then return ":int64" end
	if kind == "string" then return ":string" end
	if kind == "void" or kind == "null" then return ":void" end
	return nil,
		'to_ruby_ffi_type: type-ir kind "' .. kind .. '" has no minimal ffi-gem type-symbol mapping — only '
			.. "boolean/number/integer/string/void/null are implemented (structural shapes would need a synthesized "
			.. "FFI::Struct subclass, out of scope for this minimal mapping)"
end

-- The `ffi`-gem type symbol for one boundary position (a parameter's or
-- return's `TypeRef`), applying the ownership rule documented in the file
-- header: `opaque-handle`/`refcount`/`resource` all become a bare `:pointer`
-- (identical to each other — no ownership-aware pointer variant exists in the
-- gem's vocabulary); `copy`, or no ownership metadata at all, falls through to
-- `to_base_ruby_ffi_type`'s primitive mapping.
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy` — an unannotated value crosses by value.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_ruby_ffi_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil and discipline.kind ~= "copy" then return ":pointer" end
	return to_base_ruby_ffi_type(ref)
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- One `attach_function :name, [:type, ...], :returntype` declaration.
--
-- `handle_param`, when given, prepends a `:pointer` receiver parameter — a
-- resource method's implicit `self`, synthesized the same way the C-ABI
-- backend synthesizes its `handle: *mut T` parameter, since ffi-ir's `method`
-- kind names its receiver by resource name only and carries no parameter of
-- its own. Only its PRESENCE is read, never its value: the receiver's name
-- does not appear in the emitted declaration, because `attach_function`'s
-- parameter list is positional and untyped by name. It is a `string | nil`
-- rather than a boolean to match the TS source's own parameter, which is
-- likewise passed the receiver name and likewise only tested for presence.
--
-- There is no body to emit: `attach_function` binds directly against the
-- loaded shared library, unlike the C-ABI backend's `todo!()` stub. This file
-- emits only the binding declaration, since the C-ABI side already carries the
-- implementation this loader calls into.
--: (fn_name: string, ref: FfiRef, shape: FfiFunctionLike, handle_param: string | nil) -> (string | nil, string | nil)
local function build_attach_function(fn_name, ref, shape, handle_param)
	local symbol = to_snake_case(fn_name)
	local param_types = {} --[[: { [integer]: string } ]]
	local n = 0
	if handle_param ~= nil then
		n = n + 1
		param_types[n] = ":pointer"
	end
	for i = 1, #shape.params do
		local mapped, err = M.to_ruby_ffi_type(shape.params[i].type)
		if mapped == nil then return nil, err end
		n = n + 1
		param_types[n] = mapped
	end

	local return_type, return_err = M.to_ruby_ffi_type(shape.returnType)
	if return_type == nil then return nil, return_err end

	local lines = doc_comment(ref.meta)
	lines[#lines + 1] = "attach_function "
		.. quote(symbol)
		.. ", ["
		.. table.concat(param_types, ", ")
		.. "], "
		.. return_type
	return table.concat(lines, "\n")
end

-- A resource -> its own methods plus the paired `<resource>_free` binding (see
-- the file header). No `FFI::Struct` subclass is emitted for the resource
-- itself — per the verified `:pointer`-is-the-idiom finding above, an opaque
-- resource handle needs no struct wrapper; every method and the free function
-- simply take/return `:pointer` for this resource's positions.
--
-- Takes the methods map rather than the whole resource shape: an `FfiShape`
-- reaching this backend is the OPEN `{ kind: string, ... }`, which no checked
-- cast can narrow to `FfiResourceShape`'s literal `kind: "resource"`, so every
-- call site casts to the open record carrying just the fields it reads. Same
-- structural-field-read precedent as type_ref.lua's `resolve_ref`.
--: (name: string, methods: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_resource(name, methods)
	local resource_snake = to_snake_case(name)
	local decls = {} --[[: { [integer]: string } ]]
	local n = 0

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local method_shape = method_ref.shape --[[: FfiFunctionLike]]
		local fn_name = resource_snake .. "_" .. to_snake_case(method_name)
		local decl, err = build_attach_function(fn_name, method_ref, method_shape, name)
		if decl == nil then return nil, err end
		n = n + 1
		decls[n] = decl
	end

	decls[n + 1] = "attach_function " .. quote(resource_snake .. "_free") .. ", [:pointer], :void"
	return table.concat(decls, "\n")
end

-- The required `ffi_lib` argument — the shared library name/path `ffi_lib`
-- loads (see Basic-Usage in the file header: `ffi_lib 'libname_or_path'`).
-- ffi-ir's schema has no field for this (it is deliberately target-agnostic),
-- so this projector reads it from the module `FfiRef`'s own `meta` bag under
-- `meta.libPath` — the same "open metadata bag" convention the other backends
-- use for their own target-specific keys — and reports its absence rather than
-- guessing a path. There is no derivable default: a shared library's install
-- location and name are deployment-specific information no ffi-ir shape
-- carries.
--
-- WIRE-FACING KEY NAME. `libPath` is camelCase because it is read from IR
-- assembled by cross-language tooling, the same reason `returnType`/`freeFn`
-- keep theirs.
--: (meta: Meta, where: string) -> (string | nil, string | nil)
local function lib_path_of(meta, where)
	local lib_path = meta.libPath
	if type(lib_path) ~= "string" then
		return nil,
			'to_ruby_ffi: "' .. where .. '" is missing required meta.libPath (the shared library name/path ffi_lib '
				.. 'loads, e.g. "./libfoo.so" or "foo") — there is no derivable default, so this must be supplied '
				.. "explicitly on the module FfiRef's meta bag"
	end
	return lib_path
end

-- Takes the two exported maps rather than the whole module shape, for the same
-- reason `build_resource` takes the methods map — see there.
--: (name: string, ref: FfiRef, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_module(name, ref, functions, resources)
	local ruby_name = pascal_case(name)
	local lib_path, lib_err = lib_path_of(ref.meta, 'module "' .. name .. '"')
	if lib_path == nil then return nil, lib_err end

	local body = { "extend FFI::Library", "ffi_lib " .. quote(lib_path), "" } --[[: { [integer]: string } ]]
	local n = #body

	local fn_names = ordered_keys(functions)
	for i = 1, #fn_names do
		local fn_ref = functions[fn_names[i]]
		local decl, err = build_attach_function(fn_names[i], fn_ref, fn_ref.shape --[[: FfiFunctionLike]], nil)
		if decl == nil then return nil, err end
		n = n + 1
		body[n] = decl
	end

	local res_names = ordered_keys(resources)
	for i = 1, #res_names do
		local res_ref = resources[res_names[i]]
		local res_shape = res_ref.shape --[[: { methods: { [string]: FfiRef }, ... }]]
		local decl, err = build_resource(res_names[i], res_shape.methods)
		if decl == nil then return nil, err end
		n = n + 1
		body[n] = decl
	end

	-- Indentation is applied per BODY ENTRY, not per emitted line — a
	-- declaration that spans several lines (one carrying a doc comment) has
	-- only its first line indented. That is the TS source's behavior too (its
	-- `body.map` sees one array element per declaration, not one per line), and
	-- it is reproduced rather than corrected: Ruby is indentation-insensitive,
	-- so the two backends emit byte-identical output.
	local out = doc_comment(ref.meta)
	out[#out + 1] = "module " .. ruby_name
	for i = 1, n do
		local line = body[i]
		out[#out + 1] = #line == 0 and "" or ("  " .. line)
	end
	out[#out + 1] = "end"
	return table.concat(out, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to `ffi`-gem Ruby source.
--
--   function — a single `attach_function` declaration (requires `name`,
--              mirroring the C-ABI and wasm-bindgen backends' identical
--              requirement: a free function's name lives as the key in the
--              enclosing `module.functions` map, not on the shape itself).
--              Emitted BARE — no enclosing `extend FFI::Library`/`ffi_lib` —
--              when called directly on a `function` outside a `module`
--              context, the same way the C-ABI backend emits a bare
--              `#[no_mangle] fn`, since `attach_function` is only meaningful
--              inside a module/class that has already called `ffi_lib`, which
--              this projector cannot synthesize without a `meta.libPath`. Call
--              `to_ruby_ffi` on the enclosing `module` FfiRef to get a
--              complete, loadable declaration.
--   method   — the same, plus a synthesized `:pointer` first parameter and a
--              `<receiver>_<method>` symbol name (requires `name`, the
--              method's own key in its resource's `methods` map).
--              `attach_function` has no receiver/method syntax of its own
--              (verified: Basic-Usage/Structs show only flat free-function
--              bindings), so a method degrades to a free function taking the
--              handle explicitly — the same flattening the C-ABI backend
--              already does for the same reason.
--   resource — its methods plus the paired `<resource>_free` binding. A `name`
--              argument, if given, is IGNORED: the shape carries its own
--              `name` field, matching the C-ABI backend's identical behavior.
--   module   — a `module Name; extend FFI::Library; ffi_lib '...'; ...; end`
--              block (requires `meta.libPath` on the module FfiRef — see
--              `lib_path_of`).
--
-- No ownership discipline is unsupported on this target (see the file header):
-- `copy`/absent-metadata uses the base type mapping, and
-- `opaque-handle`/`refcount`/`resource` all become `:pointer` — every
-- discipline maps onto something the `ffi` gem can genuinely express. The
-- failures this function can report are a missing `name`, a missing
-- `meta.libPath`, a boundary kind with no mapping, and a data shape outside
-- the minimal primitive set.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_ruby_ffi(ref, name)
	local kind = ref.shape.kind

	if kind == "function" then
		if name == nil then
			return nil,
				'to_ruby_ffi: "function" requires a name — an attach_function binding is always a named '
					.. "declaration, not an anonymous inline type"
		end
		return build_attach_function(name, ref, ref.shape --[[: FfiFunctionLike]], nil)
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_ruby_ffi: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		local receiver = (ref.shape --[[: { receiver: string, ... }]]).receiver
		local fn_name = to_snake_case(receiver) .. "_" .. to_snake_case(name)
		return build_attach_function(fn_name, ref, ref.shape --[[: FfiFunctionLike]], receiver)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		return build_resource(shape.name, shape.methods)
	end

	if kind == "module" then
		if name == nil then
			return nil, 'to_ruby_ffi: "module" requires a name — a Ruby module declaration is always named'
		end
		local shape = ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		return build_module(name, ref, shape.functions, shape.resources)
	end

	return nil, 'to_ruby_ffi: unhandled ffi-ir kind "' .. kind .. '" — no ffi-gem mapping implemented for this backend'
end

return M
