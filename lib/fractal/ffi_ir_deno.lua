-- lib/fractal/ffi_ir_deno.lua — the Deno FFI consumer projector, ported from
-- fractal's packages/ffi-ir/src/deno.ts.
--
-- ffi-ir -> Deno FFI consumer projector: NOT a producer (unlike the C-ABI
-- backend, which emits Rust `extern "C"` source implementing a C-ABI library)
-- — this file emits the Deno-SIDE TypeScript loader that calls INTO whatever
-- library that backend's Rust output compiles to, via `Deno.dlopen`. Consumer
-- and producer are deliberately separate files/concerns; the Ruby `ffi`-gem
-- projector in ffi_ir_ruby_ffi.lua is the sibling consumer-side backend whose
-- conventions this one follows.
--
-- Deno.dlopen API surface, as verified by the TS source's author against
-- docs.deno.com/runtime/fundamentals/ffi/ (fetched 2026-08-03; NOT re-verified
-- by this port — the findings below are the TS source's, reproduced here
-- because they are the reasoning behind every mapping choice in this file):
--
--   - `Deno.dlopen(path, symbols)` returns `{ symbols, close() }`; each
--     `symbols[name]` is `{ parameters: FfiType[], result: FfiType }` and,
--     after the call, `lib.symbols.<name>(...)` invokes it directly
--     (synchronous — the docs describe no async/nonblocking calling convention
--     at the API level; `Deno.dlopen` itself "throws synchronously when the
--     library cannot be loaded").
--   - Full verified FFI type vocabulary (Deno type | JS type): `i8`/`u8`
--     (`number`), `i16`/`u16` (`number`), `i32`/`u32` (`number`), `i64`/`u64`
--     (`bigint`), `usize`/`isize` (`bigint`), `f32`/`f64` (`number`), `void`
--     (`undefined`), `pointer` (opaque object or `null` — "as of Deno 1.31 the
--     JavaScript representation of `pointer` has become an opaque pointer
--     object or `null` for null pointers"; the docs' own type table gives it as
--     `{} | null` and expose no dedicated `Deno.PointerValue`-named type on
--     that page, so this file spells the emitted TS annotation out as that
--     literal union rather than asserting an unverified type name), `buffer`
--     (`TypedArray | null`), `function` (callback pointer).
--   - Structs ARE natively supported by value: `{ struct: [...] }` describes a
--     C struct's layout as an ordered array of field FFI types, and struct
--     values cross the boundary as a `TypedArray` whose bytes match that C
--     layout (params) / a `Uint8Array` of the right length (returns). This file
--     does NOT implement that path (see `deno_ffi_type`'s reported gap for
--     `object` and every other structural kind) — correctly computing the
--     `{ struct: [...] }` field-type array AND the C ABI byte layout (natural
--     alignment + padding rules) a caller must pack/unpack against is a
--     separate, nontrivial undertaking, and no fractal C-ABI struct-layout
--     convention exists yet to mirror. Out of scope for this minimal
--     projector, the same "minimal subset, report the rest" scoping the sibling
--     backends document for their own data-shape coverage.
--   - No dedicated `bool` FFI type exists in Deno's vocabulary (verified, not
--     assumed) — `u8` is this file's documented convention for `boolean` (the
--     natural 1-byte width matching both Rust `bool` and C99 `_Bool`'s own
--     layout, not an arbitrary pick).
--   - `string` has NO native Deno FFI type and the docs describe no
--     established C-string convention (no `cstr`/`getCString()`/pointer+length
--     guidance found on that page) — genuinely unresolved, not a gap this
--     file's judgment can close: crossing a string requires a concrete encoding
--     decision (null-terminated buffer vs. pointer+length pair, and who
--     owns/frees the bytes) that neither ffi-ir's schema (ffi_ir.lua) nor the
--     C-ABI backend's own `copy` path has decided. `deno_ffi_type` reports the
--     gap explicitly rather than inventing an encoding.
--
-- OWNERSHIP-DISCIPLINE SCOPE FOR THIS TARGET (see `OwnershipDiscipline` in
-- ffi_ir.lua), mirroring the per-target reasoning each sibling backend gives:
--
--   - `copy` (or no `meta.ownership` at all) — the primitive/bytes value
--     crosses by its structural Deno FFI type (`PRIMITIVE_DENO_TYPES` below).
--     Struct/object-shaped copies report a gap (see above).
--   - `opaque-handle`, `refcount`, and `resource` (own/borrow) all collapse to
--     the exact same Deno-side representation: `pointer`. This is Deno FFI's
--     OWN structural fact, not a design choice made here — `Deno.dlopen`'s raw
--     calling convention has no ownership model of its own (no
--     inc/dec-refcount hook, no lend-count/trap runtime the way WIT's Canonical
--     ABI has); every one of these three disciplines is, at the raw
--     symbol-table level, "an opaque native handle, represented as `pointer`".
--     Ownership metadata is NOT entirely irrelevant to this file's output,
--     though: `opaque-handle`'s `freeFn` field is the one piece that changes
--     generated code shape — for any resource at all (see
--     `build_resource_group`, mirroring the C-ABI backend's own unconditional
--     per-resource free-function emission) an explicit `<resource>Free` wrapper
--     calling the paired free symbol is synthesized. `refcount`/`resource`
--     carry no equivalent function name in today's schema (`freeFn` is defined
--     only on the `opaque-handle` variant), so no such wrapper is synthesized
--     for them — not an oversight, a direct reading of what the schema does and
--     doesn't name.
--
-- MISSING UPSTREAM IMPORT, DELIBERATELY OMITTED. deno.ts opens with a
-- side-effect `import "@rhi-zone/fractal-type-ir/kinds/common"`, registering
-- type-ir's fixed-width int/float kinds and `bytes`. crescent has not ported
-- `kinds/common`, and for THIS backend the omission is inert: the registrations
-- it performs are `uuid`/`uri`/`email` -> `string` and `bytes` -> root, and
-- this file (like its TS source, whose own header says so) matches shape kinds
-- by LITERAL comparison against `PRIMITIVE_DENO_TYPES` and `"string"`, never
-- through `type_ref.resolve`/ancestor fallback. Nothing here consults the
-- type-ir parent registry, so no registration could change this file's
-- behavior; the TS import is a type-level/declaration-merging concern only.
-- Should this backend ever grow ancestor fallback, that port becomes a real
-- prerequisite.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `type_ref.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported shape or
-- discipline, a missing name, and a missing `meta.libPath` are all data errors,
-- not programming errors. This propagates — the internal builders below return
-- `(nil, errmsg)` too, and every caller checks. The messages keep the TS
-- versions' substance, because what they explain (which discipline or kind is
-- unsupported on this target, and why) is their actual content.
--
-- EMISSION ORDER. The generated source's symbol and wrapper order is visible
-- output, and the TS source takes it from `Object.entries` (JS insertion
-- order), which Lua tables cannot recover. `ordered_keys` below substitutes
-- byte order — the same substitution, for the same reason, that type_ref.lua's
-- own `ordered_keys` makes. The emitted SET of symbols and wrappers is
-- identical; only their order can differ from the TS backend's.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.fractal.ffi_ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, reached transitively through the `require` above (every
-- ffi-ir signature this file touches names them). Duplicating a type definition
-- is normally forbidden outright; it is here only because the checker cannot
-- currently keep an imported alias resolvable through a consumer — when a
-- consumer (this file, and in turn this file's test) calls a function whose
-- signature names an alias declared in the required module, the checker
-- re-resolves that module's `--::` declarations in the CONSUMER's scope, where
-- type_ref.lua's `TypeRef`/`Meta` are not bound. They resolve to `undefined
-- type`, silently degrade to `any`, and the consumer reports errors against the
-- DEPENDENCY's line numbers. See the full write-up and minimal repro in
-- ffi_ir.lua's own copy of this comment, and the TODO.md entry ("an alias
-- imported via require ... degrades to any as soon as any consumer uses that
-- module"), which already records that the re-declaration is repeated in each
-- `lib/fractal/ffi_ir_*.lua` backend for this reason.
--
-- These MUST stay structurally identical to type_ref.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- The three rewrites are the TS source's three regexes, in order: split a
-- lower/digit-to-upper boundary with an underscore (`readFile` -> `read_File`),
-- collapse every run of non-alphanumerics into one underscore, strip
-- leading/trailing underscores, lowercase the result. Symbol keys emitted by
-- this backend always come through here, which is what makes them plain
-- identifiers valid in `lib.symbols.<key>` property-access position.
--: (name: string) -> string
local function to_snake_case(name)
	local split = (name:gsub("([a-z0-9])(%u)", "%1_%2"))
	local collapsed = (split:gsub("[^a-zA-Z0-9]+", "_"))
	local head_trimmed = (collapsed:gsub("^_+", ""))
	local trimmed = (head_trimmed:gsub("_+$", ""))
	return trimmed:lower()
end

-- snake_case -> camelCase: each `_x` becomes `X`. Routed through
-- `to_snake_case` first, exactly as the TS source does, so the input's own
-- casing is normalized before the underscore rewrite.
--: (name: string) -> string
local function to_camel_case(name)
	local snake = to_snake_case(name)
	local camel = (snake:gsub("_([a-z0-9])", function(c)
		return c:upper()
	end))
	return camel
end

-- camelCase with an uppercased first character. The empty string maps to
-- itself (the TS source's explicit `length === 0` branch; Lua's `sub` would
-- also yield "" here, but the branch is kept so the two read the same).
--: (name: string) -> string
local function to_pascal_case(name)
	local camel = to_camel_case(name)
	if #camel == 0 then return camel end
	return camel:sub(1, 1):upper() .. camel:sub(2)
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements. This reproduces the TS source's `JSON.stringify`, which
-- is what it uses to quote every symbol key and library path it emits.
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
-- `\u00xx` form `JSON.stringify` uses for the remaining control characters
-- (lowercase hex, matching `JSON.stringify`'s own output). Lua's `%c` class
-- additionally covers DEL (0x7f), which `JSON.stringify` leaves raw — a
-- difference no input reaching `quote` can exhibit, since every string quoted
-- here is a snake_case symbol key or a library path.
--: (c: string) -> string
local function escape_char(c)
	local mapped = ESCAPES[c]
	if mapped ~= nil then return mapped end
	return string.format("\\u%04x", string.byte(c) or 0)
end

-- `value` as a double-quoted TypeScript/JSON string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- A record's keys in a deterministic (byte) order — see the file header's
-- EMISSION ORDER note.
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

-- The `/** ... */` doc-comment lines for a meta bag: one line when
-- `description` holds a string, none otherwise. Returned as a list because
-- callers splice it into a line list.
--: (meta: Meta) -> { [integer]: string }
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: { [integer]: string } ]] end
	return { "/** " .. description .. " */" } --[[: { [integer]: string } ]]
end

-- ── Type mapping ─────────────────────────────────────────────────────────────

-- Deno's own documented FFI pointer representation ("as of Deno 1.31 the
-- JavaScript representation of `pointer` has become an opaque pointer object or
-- `null`") — spelled out as this literal union rather than a
-- `Deno.PointerValue` reference, since that name was not confirmed on the
-- fetched docs page. Emitted once per generated file as a local alias.
local POINTER_TYPE_ALIAS = "type Pointer = {} | null"

-- The structural (no-ownership-metadata, or `copy` discipline) kind -> Deno FFI
-- type table. Matched by LITERAL kind name, never through ancestor fallback —
-- see the file header's note on the omitted `kinds/common` import.
local PRIMITIVE_DENO_TYPES = {
	boolean = "u8",
	integer = "i64",
	number = "f64",
	int8 = "i8",
	int16 = "i16",
	int32 = "i32",
	int64 = "i64",
	uint8 = "u8",
	uint16 = "u16",
	uint32 = "u32",
	uint64 = "u64",
	float32 = "f32",
	float64 = "f64",
	bytes = "buffer",
} --[[: { [string]: string }]]

-- Deno FFI type -> the TS type a wrapper function's parameter/return position
-- should carry, per the verified Deno/JS type table in the file header.
--: (deno_type: string) -> string
local function ts_type_for(deno_type)
	if deno_type == "i64" or deno_type == "u64" or deno_type == "usize" or deno_type == "isize" then
		return "bigint"
	end
	if deno_type == "void" then return "void" end
	if deno_type == "buffer" then return "Uint8Array | null" end
	if deno_type == "pointer" then return "Pointer" end
	return "number" -- i8/u8/i16/u16/i32/u32/f32/f64
end

--: (ref: TypeRef) -> boolean
local function is_void_type(ref)
	return ref.shape.kind == "void" or ref.shape.kind == "null"
end

-- The Deno FFI type string for one boundary position (a parameter's or
-- return's `TypeRef`), applying this target's ownership rule (see file header):
--
--   - `opaque-handle`/`refcount`/`resource` ownership — always `pointer`,
--     regardless of which of the three; Deno's raw FFI layer draws no
--     distinction between them.
--   - `copy` or no ownership metadata — the structural primitive mapping.
--     Reports a gap for `string` (no native type, no established encoding
--     convention) and for any shape kind outside the primitive/bytes table
--     (e.g. `object`/`array`: native struct-by-value support exists in Deno,
--     but this minimal projector does not implement the C-ABI layout
--     computation it requires).
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy` — an unannotated value crosses by value.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.deno_ffi_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil and discipline.kind ~= "copy" then return "pointer" end

	local kind = ref.shape.kind
	if is_void_type(ref) then return "void" end
	local primitive = PRIMITIVE_DENO_TYPES[kind]
	if primitive ~= nil then return primitive end

	if kind == "string" then
		return nil,
			'deno_ffi_type: "string" has no native Deno FFI type and no established fractal C-ABI string convention '
				.. "to encode against (null-terminated pointer vs. pointer+length, and byte ownership, are all "
				.. "undecided — see this file's header) — reporting rather than guessing an encoding"
	end

	return nil,
		'deno_ffi_type: shape kind "' .. kind .. '" has no mapping in this minimal projector\'s '
			.. "primitive/bytes/pointer subset — Deno FFI can represent a by-value struct natively via "
			.. "`{ struct: [...] }`, but computing the required C-ABI byte layout (field order, alignment, "
			.. "padding) is out of scope here; a full type-ir -> Deno-struct-layout projector is separate, "
			.. "not-yet-done work"
end

-- ── Emission records ─────────────────────────────────────────────────────────

-- One entry in the `Deno.dlopen` symbols object. `parameters`/`result` keep the
-- names Deno's own API gives them, since they are emitted verbatim as the
-- object's property names; `key` is the symbol name that entry is filed under.
--:: SymbolEntry = { key: string, parameters: { [integer]: string }, result: string }

-- One exported wrapper function. These field names are internal to this file —
-- nothing here is read back from cross-language tooling the way `returnType`
-- and `freeFn` are — so they are snake_case rather than camelCase.
--:: WrapperParam = { name: string, deno_type: string }
--:: Wrapper = {
--::     export_name: string,
--::     symbol_key: string,
--::     params: { [integer]: WrapperParam },
--::     result_deno_type: string,
--::     doc_lines: { [integer]: string },
--:: }

-- What one `function`/`method` shape contributes: its symbol-table entry and
-- its wrapper. Returned as one record because the two are always built and
-- consumed together (the TS source returns the same pair as an object literal).
--:: BuiltCallable = { symbol: SymbolEntry, wrapper: Wrapper }

--:: BuiltGroup = { symbols: { [integer]: SymbolEntry }, wrappers: { [integer]: Wrapper } }

-- ── Builders ─────────────────────────────────────────────────────────────────

-- A callable's `result` FFI type. A `void`/`null` return is `void` regardless
-- of any ownership metadata on it, which is why this tests the shape directly
-- instead of leaving the case to `deno_ffi_type`'s own void branch (the TS
-- source draws the same distinction at its own call site).
--: (return_type: TypeRef) -> (string | nil, string | nil)
local function result_deno_type_for(return_type)
	if is_void_type(return_type) then return "void" end
	return M.deno_ffi_type(return_type)
end

-- Builds the symbol-table entry and wrapper-function description for one
-- `function`/`method` shape. `self_param`, when given (a method's receiver
-- resource name), prepends a `pointer` parameter named `handle` — mirroring the
-- C-ABI backend's identical `selfParam` convention, since the native symbol
-- this calls into is the one that backend emits, which synthesizes that same
-- leading handle parameter for every method. Only its PRESENCE is read: the
-- receiver's name appears nowhere in this callable's own output.
--: (symbol_key: string, export_name: string, ref: FfiRef, shape: FfiFunctionLike, self_param: string | nil) -> (BuiltCallable | nil, string | nil)
local function build_callable(symbol_key, export_name, ref, shape, self_param)
	local params = {} --[[: { [integer]: WrapperParam } ]]
	local n = 0
	if self_param ~= nil then
		n = n + 1
		params[n] = { name = "handle", deno_type = "pointer" }
	end
	for i = 1, #shape.params do
		local p = shape.params[i]
		local mapped, err = M.deno_ffi_type(p.type)
		if mapped == nil then return nil, err end
		n = n + 1
		params[n] = { name = to_camel_case(p.name), deno_type = mapped }
	end

	local result_deno_type, result_err = result_deno_type_for(shape.returnType)
	if result_deno_type == nil then return nil, result_err end

	local parameters = {} --[[: { [integer]: string } ]]
	for i = 1, n do
		parameters[i] = params[i].deno_type
	end

	return {
		symbol = { key = symbol_key, parameters = parameters, result = result_deno_type },
		wrapper = {
			export_name = export_name,
			symbol_key = symbol_key,
			params = params,
			result_deno_type = result_deno_type,
			doc_lines = doc_comment(ref.meta),
		},
	}
end

-- The paired free-function wrapper for a resource — synthesized
-- unconditionally per resource, mirroring the C-ABI backend, which emits
-- `<resource>_free` unconditionally regardless of which ownership discipline
-- (if any) a given call site attaches to a reference to this resource.
-- `handle`'s Deno type is `pointer` unconditionally too — see the file header:
-- opaque-handle/refcount/resource all collapse to `pointer` at this raw layer,
-- so the free wrapper's own signature does not vary by discipline either.
--: (resource_name: string) -> BuiltCallable
local function build_free_wrapper(resource_name)
	local resource_snake = to_snake_case(resource_name)
	local symbol_key = resource_snake .. "_free"
	return {
		symbol = { key = symbol_key, parameters = { "pointer" }, result = "void" },
		wrapper = {
			export_name = to_camel_case(resource_name) .. "Free",
			symbol_key = symbol_key,
			params = { { name = "handle", deno_type = "pointer" } },
			result_deno_type = "void",
			doc_lines = {
				"/** Releases a " .. resource_name .. " handle — pairs with the C-ABI backend's synthesized `"
					.. symbol_key .. "` export. */",
			},
		},
	}
end

-- Every method of one resource, plus its paired free function.
--
-- The TS source additionally takes the resource's own `FfiRef` and discards it
-- (`void ref`, kept "for signature symmetry with sibling builders"); this port
-- drops the parameter instead of taking an unused one — resource-level meta
-- (e.g. `description`) is not currently surfaced per group either way, so
-- nothing about the output changes.
--
-- Takes the methods map rather than the whole resource shape: an `FfiShape`
-- reaching this backend is the OPEN `{ kind: string, ... }`, which no checked
-- cast can narrow to `FfiResourceShape`'s literal `kind: "resource"`, so every
-- call site casts to an open record carrying just the fields it reads. Same
-- structural-field-read precedent as type_ref.lua's `resolve_ref`, and the same
-- formulation ffi_ir_ruby_ffi.lua's own builders use.
--: (name: string, methods: { [string]: FfiRef }) -> (BuiltGroup | nil, string | nil)
local function build_resource_group(name, methods)
	local resource_snake = to_snake_case(name)
	local symbols = {} --[[: { [integer]: SymbolEntry } ]]
	local wrappers = {} --[[: { [integer]: Wrapper } ]]
	local n = 0

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local method_kind = method_ref.shape.kind
		if method_kind ~= "method" and method_kind ~= "function" then
			return nil,
				'to_deno_ffi: resource "' .. name .. '"\'s method "' .. method_name .. '" has shape kind "'
					.. method_kind .. '", not "method"/"function"'
		end
		local symbol_key = resource_snake .. "_" .. to_snake_case(method_name)
		local export_name = to_camel_case(name) .. to_pascal_case(method_name)
		local built, err = build_callable(
			symbol_key,
			export_name,
			method_ref,
			method_ref.shape --[[: FfiFunctionLike]],
			name
		)
		if built == nil then return nil, err end
		n = n + 1
		symbols[n] = built.symbol
		wrappers[n] = built.wrapper
	end

	local free = build_free_wrapper(name)
	symbols[n + 1] = free.symbol
	wrappers[n + 1] = free.wrapper

	return { symbols = symbols, wrappers = wrappers }
end

-- The library path `Deno.dlopen`'s first argument names. ffi-ir's schema has no
-- field for it (it is deliberately target-agnostic), so this projector reads it
-- from the `FfiRef`'s own `meta` bag under `meta.libPath` — the same open
-- metadata-bag convention every other backend uses for its own target-specific
-- key — and reports its absence rather than guessing a path. There is no
-- derivable default: a shared library's install location and name are
-- deployment-specific information no ffi-ir shape carries.
--
-- WIRE-FACING KEY NAME. `libPath` is camelCase because it is read from IR
-- assembled by cross-language tooling, the same reason `returnType`/`freeFn`
-- keep theirs.
--: (meta: Meta, where: string) -> (string | nil, string | nil)
local function lib_path_of(meta, where)
	local lib_path = meta.libPath
	if type(lib_path) ~= "string" then
		return nil,
			'to_deno_ffi: "' .. where .. '" is missing required meta.libPath (the path/URL Deno.dlopen\'s first '
				.. 'argument names, e.g. "./libexample.so") — there is no derivable default, so this must be '
				.. "supplied on the FfiRef's own meta bag"
	end
	return lib_path
end

-- ── Rendering ────────────────────────────────────────────────────────────────

--: (symbols: { [integer]: SymbolEntry }) -> string
local function render_symbols_object(symbols)
	local lines = { "{" } --[[: { [integer]: string } ]]
	local n = 1
	for i = 1, #symbols do
		local s = symbols[i]
		local quoted = {} --[[: { [integer]: string } ]]
		for j = 1, #s.parameters do
			quoted[j] = quote(s.parameters[j])
		end
		n = n + 1
		lines[n] = "    " .. quote(s.key) .. ": { parameters: [" .. table.concat(quoted, ", ") .. "], result: "
			.. quote(s.result) .. " },"
	end
	lines[n + 1] = "}"
	return table.concat(lines, "\n")
end

--: (lib_var: string, w: Wrapper) -> string
local function render_wrapper(lib_var, w)
	local decls = {} --[[: { [integer]: string } ]]
	local args = {} --[[: { [integer]: string } ]]
	for i = 1, #w.params do
		local p = w.params[i]
		decls[i] = p.name .. ": " .. ts_type_for(p.deno_type)
		args[i] = p.name
	end
	local return_ts = ts_type_for(w.result_deno_type)
	-- Symbol keys are always snake_case identifiers (from `to_snake_case`), so
	-- plain property access is always valid here.
	local call = lib_var .. ".symbols." .. w.symbol_key
	local arg_list = table.concat(args, ", ")
	local body = w.result_deno_type == "void" and ("  " .. call .. "(" .. arg_list .. ")")
		or ("  return " .. call .. "(" .. arg_list .. ") as " .. return_ts)

	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	for i = 1, #w.doc_lines do
		n = n + 1
		out[n] = w.doc_lines[i]
	end
	out[n + 1] = "export function " .. w.export_name .. "(" .. table.concat(decls, ", ") .. "): " .. return_ts .. " {"
	out[n + 2] = body
	out[n + 3] = "}"
	return table.concat(out, "\n")
end

--: (lib_var: string, lib_path: string, symbols: { [integer]: SymbolEntry }, wrappers: { [integer]: Wrapper }) -> string
local function render_module_or_group(lib_var, lib_path, symbols, wrappers)
	local out = {
		POINTER_TYPE_ALIAS,
		"",
		"const " .. lib_var .. " = Deno.dlopen(" .. quote(lib_path) .. ", " .. render_symbols_object(symbols) .. ")",
		"",
	} --[[: { [integer]: string } ]]
	local n = #out
	for i = 1, #wrappers do
		out[n + i] = render_wrapper(lib_var, wrappers[i])
	end
	return table.concat(out, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to Deno FFI consumer TypeScript source — a
-- `Deno.dlopen` call plus one exported wrapper function per exported
-- function/resource-method (and, per resource, one paired free-function wrapper
-- — see `build_free_wrapper`).
--
--   function — its own single-symbol `Deno.dlopen` call plus one wrapper
--              (requires `name`, mirroring the C-ABI and wasm-bindgen backends'
--              identical requirement: a symbol's name lives as the key in the
--              enclosing `module.functions` map, not on the shape itself. Also
--              requires `meta.libPath`, see `lib_path_of`).
--   method   — the same, plus a synthesized `handle: Pointer` first parameter
--              matching the C-ABI backend's receiver convention (requires
--              `name` and `meta.libPath`).
--   resource — one `Deno.dlopen` call grouping every declared method's symbol
--              plus the paired free-function symbol, with one wrapper per
--              method plus the free wrapper (requires `meta.libPath`; a `name`
--              argument, if given, is IGNORED — the shape carries its own
--              `name` field).
--   module   — one `Deno.dlopen` call grouping ALL of its functions' AND all of
--              its resources' methods'/free-functions' symbols together (a
--              module is one FFI boundary sharing one native library, so one
--              shared `lib` handle is the natural mapping — unlike the
--              single-item `Deno.dlopen` calls the standalone
--              function/method/resource cases synthesize, which are
--              independently valid per Deno's API but would reopen the same
--              library once per symbol if used for a whole module).
--
-- Reports — never silently degrades — for: a `string`-typed or struct-typed
-- value anywhere in a crossed `TypeRef` (see `deno_ffi_type`), a
-- `function`/`method` shape called without a `name`, an `FfiRef` missing the
-- required `meta.libPath` convention, a module/resource entry whose shape kind
-- does not match its position, and any boundary kind this backend does not map.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_deno_ffi(ref, name)
	local kind = ref.shape.kind

	if kind == "module" then
		-- Cast to an open record naming just the fields read, never to
		-- `FfiModuleShape`: see `build_resource_group` for why a literal-`kind`
		-- alias is unreachable by a checked cast here.
		local shape = ref.shape --[[: { name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		local lib_path, lib_err = lib_path_of(ref.meta, shape.name)
		if lib_path == nil then return nil, lib_err end
		local symbols = {} --[[: { [integer]: SymbolEntry } ]]
		local wrappers = {} --[[: { [integer]: Wrapper } ]]
		local n = 0

		local fn_names = ordered_keys(shape.functions)
		for i = 1, #fn_names do
			local fn_name = fn_names[i]
			local fn_ref = shape.functions[fn_name]
			local fn_kind = fn_ref.shape.kind
			if fn_kind ~= "function" and fn_kind ~= "method" then
				return nil,
					'to_deno_ffi: module "' .. shape.name .. '"\'s function "' .. fn_name .. '" has shape kind "'
						.. fn_kind .. '", not "function"/"method"'
			end
			local built, err = build_callable(
				to_snake_case(fn_name),
				to_camel_case(fn_name),
				fn_ref,
				fn_ref.shape --[[: FfiFunctionLike]],
				nil
			)
			if built == nil then return nil, err end
			n = n + 1
			symbols[n] = built.symbol
			wrappers[n] = built.wrapper
		end

		local res_names = ordered_keys(shape.resources)
		for i = 1, #res_names do
			local res_name = res_names[i]
			local res_ref = shape.resources[res_name]
			if res_ref.shape.kind ~= "resource" then
				return nil,
					'to_deno_ffi: module "' .. shape.name .. '"\'s resource "' .. res_name .. '" has shape kind "'
						.. res_ref.shape.kind .. '", not "resource"'
			end
			local res_shape = res_ref.shape --[[: { methods: { [string]: FfiRef }, ... }]]
			local group, err = build_resource_group(res_name, res_shape.methods)
			if group == nil then return nil, err end
			for j = 1, #group.symbols do
				n = n + 1
				symbols[n] = group.symbols[j]
				wrappers[n] = group.wrappers[j]
			end
		end

		return render_module_or_group("lib", lib_path, symbols, wrappers)
	end

	if kind == "function" then
		if name == nil then
			return nil,
				'to_deno_ffi: "function" requires a name — a Deno FFI symbol is a named entry, not an anonymous '
					.. "inline type"
		end
		local lib_path, lib_err = lib_path_of(ref.meta, name)
		if lib_path == nil then return nil, lib_err end
		local built, err = build_callable(
			to_snake_case(name),
			to_camel_case(name),
			ref,
			ref.shape --[[: FfiFunctionLike]],
			nil
		)
		if built == nil then return nil, err end
		return render_module_or_group("lib", lib_path, { built.symbol }, { built.wrapper })
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_deno_ffi: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		local receiver = (ref.shape --[[: { receiver: string, ... }]]).receiver
		local lib_path, lib_err = lib_path_of(ref.meta, name)
		if lib_path == nil then return nil, lib_err end
		local symbol_key = to_snake_case(receiver) .. "_" .. to_snake_case(name)
		local export_name = to_camel_case(receiver) .. to_pascal_case(name)
		local built, err = build_callable(
			symbol_key,
			export_name,
			ref,
			ref.shape --[[: FfiFunctionLike]],
			receiver
		)
		if built == nil then return nil, err end
		return render_module_or_group("lib", lib_path, { built.symbol }, { built.wrapper })
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		local lib_path, lib_err = lib_path_of(ref.meta, shape.name)
		if lib_path == nil then return nil, lib_err end
		local group, err = build_resource_group(shape.name, shape.methods)
		if group == nil then return nil, err end
		return render_module_or_group("lib", lib_path, group.symbols, group.wrappers)
	end

	return nil, 'to_deno_ffi: unhandled ffi-ir kind "' .. kind .. '" — no Deno FFI mapping implemented for this backend'
end

return M
