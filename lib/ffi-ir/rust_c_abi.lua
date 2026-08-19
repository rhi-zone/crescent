-- lib/ffi-ir/rust_c_abi.lua — the Rust-implementing-a-C-ABI projector,
-- ported from fractal's packages/ffi-ir/src/rust-c-abi.ts.
--
-- This is the PRODUCER side of a plain-C FFI boundary: Rust source
-- (`#[repr(C)]` structs, `#[no_mangle] pub extern "C" fn` functions) that a
-- C-ABI consumer — `python_ctypes.lua`'s ctypes bindings,
-- `ruby_ffi.lua`'s `ffi`-gem bindings, `csharp_pinvoke.lua`'s
-- P/Invoke declarations — calls into. Named, like this directory's sibling
-- projectors, after what it emits (Rust implementing a C ABI), not after the
-- ABI/boundary itself.
--
-- A C HEADER IS NOT EMITTED HERE. cbindgen's own documented job is generating
-- that header FROM compiled Rust source (confirmed in fractal's
-- docs/design/ffi-ir-architecture-options.md, Fork C deeper pass, point 1:
-- cbindgen covers "type layout, header config, type mappings, and function
-- declarations", reading FROM Rust, not the reverse), so a header is a
-- downstream artifact of this file's output rather than something fractal
-- emits directly.
--
-- OWNERSHIP-DISCIPLINE MAPPING (see `OwnershipDiscipline` in init.lua).
-- Exactly the two disciplines the design doc's Fork C "discipline-per-target:
-- decided" subsection names for the C target are implemented:
--
--   - `copy` (and absent ownership metadata) — plain by-value
--     parameter/return, reusing lib/type-ir/rust_serde.lua's primitive/struct type
--     mapping directly (`rust_type_from_type_ref`, fractal's `toRustType`),
--     reused rather than re-derived.
--   - `opaque-handle` — a raw pointer (`*mut T`) plus the paired
--     explicit-free-function convention, matching cbindgen's own documented
--     opaque-pointer pattern (the doc's Fork C, point 1: cbindgen prescribes no
--     alloc/free convention itself, so fractal adopts this one as its own
--     convention rather than inventing a different one) and the Rustonomicon's
--     documented opaque-struct idiom for FFI
--     (https://doc.rust-lang.org/nomicon/ffi.html#representing-opaque-structs —
--     `pub struct Foo { _private: [u8; 0] }`, a zero-sized-field marker type
--     with no C-visible layout).
--
-- `refcount` and `resource` (own/borrow) are explicitly OUT OF SCOPE for this
-- target per that same decided subsection — "no native mechanism" for refcount
-- (it would be entirely fractal/author-maintained bookkeeping cbindgen does not
-- generate or verify) and "no host runtime exists for plain C to enforce" the
-- resource/lend-count model (it would require generating a full handle-table
-- runtime from scratch). Both are REPORTED rather than silently approximated as
-- a pointer or a copy — the same report-don't-degrade convention
-- lib/type-ir/rust_wasm_bindgen.lua uses for kinds it cannot realize on its own
-- target's ABI, and the mirror image of `ruby_ffi.lua`/
-- `python_ctypes.lua`, where all three non-`copy` disciplines legitimately
-- collapse onto one pointer form because those targets' vocabularies genuinely
-- cannot distinguish them.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return, the same conversion the other ffi-ir backends apply:
-- an unsupported discipline or a missing name is a data error, not a
-- programming error. This propagates — the internal builders below return
-- `(nil, errmsg)` too, and every caller checks.
--
-- SELF-CONTAINED HELPERS. `to_snake_case`, the Rust keyword set /
-- `escape_rust_ident`, and `quote` are duplicated from
-- lib/type-ir/rust_serde.lua rather than shared, matching the TS source's own
-- documented decision that each projector file in this package is
-- self-contained (rust-wasm-bindgen.ts duplicates these exact helpers relative
-- to rust-serde.ts for the same stated reason). Only the type MAPPING is
-- shared, via the `rust_type_from_type_ref` import below.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")
local rust_serde = require("lib.type-ir.rust_serde")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of lib/type-ir/init.lua's
-- own declarations, reached transitively through the `require`s above (every
-- ffi-ir signature this file touches names them). Duplicating a type
-- definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — when a consumer (this file, and in turn this file's test) calls a
-- function whose signature names an alias declared in the required module, the
-- checker re-resolves that module's `--::` declarations in the CONSUMER's
-- scope, where lib/type-ir/init.lua's `TypeRef`/`Meta` are not bound. They resolve to
-- `undefined type`, silently degrade to `any`, and the consumer reports errors
-- against the DEPENDENCY's line numbers. See the full write-up and minimal
-- repro in init.lua's own copy of this comment, and the TODO.md entry
-- ("an alias imported via require ... degrades to any as soon as any consumer
-- uses that module"), which already records that the re-declaration is
-- repeated in each `lib/ffi-ir/*.lua` backend for this reason.
--
-- These MUST stay structurally identical to lib/type-ir/init.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- The snake_case convention Rust exports use, and the same one the C-ABI
-- consumers in this directory expect of the symbols they bind against.
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

-- Rust 2018+ reserved/strict keywords (https://doc.rust-lang.org/reference/keywords.html)
-- that cannot appear as a plain identifier. A parameter whose snake_case name
-- collides with one of these must be written as a raw identifier (`r#type`) to
-- compile. Duplicated from lib/type-ir/rust_serde.lua per the file header's
-- self-containment note.
local RUST_KEYWORDS = {
	["type"] = true, ["struct"] = true, ["enum"] = true, ["fn"] = true,
	["let"] = true, ["mut"] = true, ["ref"] = true, ["self"] = true,
	["super"] = true, ["crate"] = true, ["mod"] = true, ["pub"] = true,
	["use"] = true, ["impl"] = true, ["trait"] = true, ["where"] = true,
	["loop"] = true, ["while"] = true, ["for"] = true, ["if"] = true,
	["else"] = true, ["match"] = true, ["return"] = true, ["break"] = true,
	["continue"] = true, ["as"] = true, ["in"] = true, ["move"] = true,
	["box"] = true, ["dyn"] = true, ["abstract"] = true, ["async"] = true,
	["await"] = true, ["become"] = true, ["const"] = true, ["do"] = true,
	["extern"] = true, ["final"] = true, ["macro"] = true, ["override"] = true,
	["priv"] = true, ["static"] = true, ["try"] = true, ["typeof"] = true,
	["unsafe"] = true, ["unsized"] = true, ["virtual"] = true, ["yield"] = true,
	["union"] = true,
} --[[: { [string]: boolean }]]

-- Escape a snake_case Rust identifier that collides with a reserved keyword
-- using raw-identifier syntax (`r#type`); pass non-keyword identifiers through.
--: (rust_name: string) -> string
local function escape_rust_ident(rust_name)
	if RUST_KEYWORDS[rust_name] then return "r#" .. rust_name end
	return rust_name
end

-- Characters that must be escaped inside a double-quoted Rust string literal,
-- and their replacements. This reproduces the TS source's `JSON.stringify`
-- deliberately rather than "improving" on it: diverging would mean this port
-- emits different Rust than the source it is a port of. Every string reaching
-- `quote` today is a snake_case symbol name embedded in a `todo!(...)`
-- message.
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

-- `value` as a double-quoted Rust string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- The `/// ...` doc-comment lines for a meta bag: one line when `description`
-- holds a string, none otherwise. Returned as a list because callers splice it
-- into a line list.
--
-- The TS source's `docComment` takes a leading `indent` argument; every call
-- site passes `""` (nothing this backend emits nests a doc comment — struct
-- fields here are the single fixed `_private` marker, which carries no meta),
-- so the parameter is dropped rather than carried dead, matching
-- ruby_ffi.lua's identically-shaped helper.
--: (meta: Meta) -> { [integer]: string }
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: { [integer]: string } ]] end
	return { "/// " .. description } --[[: { [integer]: string } ]]
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of the emitted declarations vary between runs. Byte order is the
-- deterministic stand-in — the same substitution, for the same reason, that
-- lib/type-ir/init.lua's own `ordered_keys` makes. The emitted SET of declarations is
-- identical either way.
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

-- The type-ir-level Rust expression for one boundary position (a parameter's
-- or return's `TypeRef`), applying the C target's ownership rule:
--
--   - no `meta.ownership` at all, or `{ kind = "copy" }` — plain by-value,
--     delegating straight to lib/type-ir/rust_serde.lua's
--     `rust_type_from_type_ref`. That function is TOTAL (every type-ir kind has
--     a handler, unrecognized kinds fall back to `serde_json::Value`), so the
--     `copy` path here has no failure of its own to report.
--   - `{ kind = "opaque-handle" }` — `*mut <T>`, where `<T>` is the same
--     expression. For the documented `resource_ref`/`ref` convention this
--     collapses to the bare resource name (`*mut FileHandle`), but the mapping
--     is general: an opaque-handle TypeRef of any structural kind becomes a raw
--     pointer to its Rust type.
--   - `{ kind = "refcount" }` / `{ kind = "resource", mode = ... }` —
--     unsupported for this target (see the file header), reported rather than
--     silently approximated.
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy` — an unannotated value crosses by value.
--
-- An unrecognized discipline `kind` is reported too. The TS source calls that
-- branch unreachable for anything built via `ownership.*`, but ffi-ir's meta bag
-- is open and `ownership_of` deliberately does not validate what it finds
-- there, so a malformed discipline is data this projector must diagnose rather
-- than mis-lower.
--
-- The error prefix names this Lua function rather than the source's
-- `toRustCAbi:` (the TS message's prefix names the module's other export, not
-- the function that raises it); the rest of the message is the source's,
-- verbatim.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_rust_c_abi_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline == nil then return rust_serde.rust_type_from_type_ref(ref) end

	-- TYPECHECKER WORKAROUND, and a deliberate widening. Statically
	-- `OwnershipDiscipline.kind` is a closed literal union, so testing the known
	-- kinds narrows the fall-through branch below to `never` and the checker
	-- rejects the report that branch builds. At runtime the discipline came out
	-- of an OPEN meta bag and `ownership_of` explicitly does not validate what it
	-- finds there, so an unrecognized kind is reachable data — the same reason
	-- the TS source casts to `{ kind: string }` to build its own message. Same
	-- gap as the recorded TODO.md entry "a second read of an imported tagged
	-- union's discriminant, after narrowing on that same discriminant, is typed
	-- `never`" (worked around in `wit.lua` by reading the discriminant
	-- through an open structural cast, and in `python_ctypes.lua` by this
	-- same widening cast). Revert to a direct `discipline.kind` dispatch — which
	-- would also restore the exhaustiveness checking this widening gives up —
	-- once that resolves.
	local kind = discipline.kind --[[: string]]
	if kind == "copy" then return rust_serde.rust_type_from_type_ref(ref) end
	if kind == "opaque-handle" then return "*mut " .. rust_serde.rust_type_from_type_ref(ref) end

	return nil,
		'to_rust_c_abi_type: unsupported ownership discipline "'
			.. kind
			.. '" for C target — the C backend implements only "copy" and "opaque-handle" '
			.. '(docs/design/ffi-ir-architecture-options.md, Fork C "discipline-per-target: decided": no native C '
			.. "mechanism for refcounting or a resource/lend-count handle table; both are explicitly out of scope for "
			.. "this target, not an oversight)"
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- One `#[no_mangle] pub extern "C" fn` for a `function`/`method` shape.
--
-- `self_param`, when given, is prepended as the receiver parameter (a resource
-- method's implicit `self` — ffi-ir's `method` kind names its receiver by
-- resource name only and carries no parameter of its own, so the pointer
-- parameter is synthesized here using the same `opaque-handle` pointer
-- convention `to_rust_c_abi_type` uses for any other opaque-handle position).
--
-- A `void`/`null` return omits the `-> ...` clause entirely rather than
-- spelling out Rust's `()`, matching the source.
--
-- The body is a `todo!()` stub — ffi-ir carries only the signature, so there is
-- no implementation to emit, the same stub-body convention
-- lib/type-ir/rust_wasm_bindgen.lua uses for the same reason.
--: (fn_name: string, ref: FfiRef, shape: FfiFunctionLike, self_param: string | nil) -> (string | nil, string | nil)
local function build_function(fn_name, ref, shape, self_param)
	local params = {} --[[: { [integer]: string } ]]
	local n = 0
	if self_param ~= nil then
		n = n + 1
		params[n] = "handle: *mut " .. self_param
	end
	for i = 1, #shape.params do
		local param = shape.params[i]
		local mapped, err = M.to_rust_c_abi_type(param.type)
		if mapped == nil then return nil, err end
		n = n + 1
		params[n] = escape_rust_ident(to_snake_case(param.name)) .. ": " .. mapped
	end

	local return_kind = shape.returnType.shape.kind
	local return_clause = ""
	if return_kind ~= "void" and return_kind ~= "null" then
		local mapped, err = M.to_rust_c_abi_type(shape.returnType)
		if mapped == nil then return nil, err end
		return_clause = " -> " .. mapped
	end

	local lines = doc_comment(ref.meta)
	lines[#lines + 1] = "#[no_mangle]"
	lines[#lines + 1] = 'pub extern "C" fn ' .. fn_name .. "(" .. table.concat(params, ", ") .. ")" .. return_clause .. " {"
	lines[#lines + 1] = "    todo!(" .. quote("implement " .. fn_name) .. ")"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- The Rustonomicon-documented opaque-struct idiom for a C-ABI handle: a
-- zero-sized private field means the type has no C-visible layout (callers can
-- only ever hold `*mut Foo`/`*const Foo`, never a by-value `Foo`), which is
-- exactly the opaque-pointer convention cbindgen itself documents (see the file
-- header). `#[repr(C)]` is required so the struct's (empty) layout is
-- well-defined across the FFI boundary rather than left to Rust's default
-- unspecified-layout `repr(Rust)`.
--: (name: string, ref: FfiRef) -> string
local function build_opaque_struct(name, ref)
	local lines = doc_comment(ref.meta)
	lines[#lines + 1] = "#[repr(C)]"
	lines[#lines + 1] = "pub struct " .. name .. " {"
	lines[#lines + 1] = "    _private: [u8; 0],"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- The paired explicit free function cbindgen's opaque-pointer convention
-- requires (see `OwnershipDiscipline`'s `opaque-handle` case in init.lua,
-- which documents `freeFn` as "the exported free function a backend should emit
-- a call to, when known" — this is that function, synthesized by this backend
-- for every resource, and the one `ruby_ffi.lua`/
-- `python_ctypes.lua` bind against by the same `<resource>_free` name).
-- Null-checks before freeing (a defensive, standard C-FFI convention) and
-- reclaims the heap allocation via `Box::from_raw` + `drop` — the Rust-side
-- counterpart of whatever allocation produced the `*mut T` in the first place
-- (a constructor function returning `Box::into_raw(Box::new(...))`,
-- conventionally).
--: (free_fn_name: string, struct_name: string) -> string
local function build_free_function(free_fn_name, struct_name)
	return table.concat({
		"#[no_mangle]",
		'pub extern "C" fn ' .. free_fn_name .. "(handle: *mut " .. struct_name .. ") {",
		"    if handle.is_null() {",
		"        return;",
		"    }",
		"    unsafe {",
		"        drop(Box::from_raw(handle));",
		"    }",
		"}",
	}, "\n")
end

-- A resource -> its opaque struct, its methods (each receiver-prefixed and
-- taking a synthesized `handle` pointer), and the paired `<resource>_free`
-- function.
--
-- Takes the methods map rather than the whole resource shape: an `FfiShape`
-- reaching this backend is the OPEN `{ kind: string, ... }`, which no checked
-- cast can narrow to `FfiResourceShape`'s literal `kind: "resource"`, so every
-- call site casts to the open record carrying just the fields it reads. Same
-- structural-field-read precedent as lib/type-ir/init.lua's `resolve_ref`.
--: (name: string, ref: FfiRef, methods: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_resource(name, ref, methods)
	local resource_snake = to_snake_case(name)
	local decls = { build_opaque_struct(name, ref) } --[[: { [integer]: string } ]]
	local n = 1

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local fn_name = resource_snake .. "_" .. to_snake_case(method_name)
		local decl, err = build_function(fn_name, method_ref, method_ref.shape --[[: FfiFunctionLike]], name)
		if decl == nil then return nil, err end
		n = n + 1
		decls[n] = decl
	end

	decls[n + 1] = build_free_function(resource_snake .. "_free", name)
	return table.concat(decls, "\n\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Forward-declared for the `module` branch's recursion into its own contained
-- functions and resources.
local to_rust_c_abi

-- Lower one ffi-ir `FfiRef` to C-ABI-oriented Rust source.
--
--   function — a top-level `#[no_mangle] pub extern "C" fn` (requires `name`,
--              mirroring the wasm-bindgen backend's identical requirement: a
--              free function's name lives as the key in the enclosing
--              `module.functions` map, not on the shape itself).
--   method   — the same, plus a synthesized `handle: *mut <receiver>` first
--              parameter and a `<receiver>_<method>` name (requires `name`, the
--              method's own key in its resource's `methods` map).
--   resource — the opaque-struct-plus-methods-plus-free-function group. A
--              `name` argument, if given, is IGNORED: the shape carries its own
--              `name` field, matching `FfiKinds.resource`'s shape.
--   module   — all contained functions then all contained resources,
--              concatenated with NO wrapper of any kind (C has no
--              module/namespace construct), so the module's own `name` is
--              unused and the `name` argument is not required here either.
--
-- Reports `refcount`/`resource`-discipline ownership metadata anywhere in a
-- crossed `TypeRef` (see `to_rust_c_abi_type`), a missing `name` for the two
-- kinds that need one, and any boundary kind with no C-ABI mapping.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function to_rust_c_abi(ref, name)
	local kind = ref.shape.kind

	if kind == "function" then
		if name == nil then
			return nil,
				'to_rust_c_abi: "function" requires a name — a C export is a named symbol, not an anonymous inline type'
		end
		return build_function(to_snake_case(name), ref, ref.shape --[[: FfiFunctionLike]], nil)
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_rust_c_abi: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		local receiver = (ref.shape --[[: { receiver: string, ... }]]).receiver
		local fn_name = to_snake_case(receiver) .. "_" .. to_snake_case(name)
		return build_function(fn_name, ref, ref.shape --[[: FfiFunctionLike]], receiver)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		return build_resource(shape.name, ref, shape.methods)
	end

	if kind == "module" then
		local shape = ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		local decls = {} --[[: { [integer]: string } ]]
		local n = 0

		local fn_names = ordered_keys(shape.functions)
		for i = 1, #fn_names do
			local decl, err = to_rust_c_abi(shape.functions[fn_names[i]], fn_names[i])
			if decl == nil then return nil, err end
			n = n + 1
			decls[n] = decl
		end

		local res_names = ordered_keys(shape.resources)
		for i = 1, #res_names do
			local decl, err = to_rust_c_abi(shape.resources[res_names[i]], res_names[i])
			if decl == nil then return nil, err end
			n = n + 1
			decls[n] = decl
		end

		return table.concat(decls, "\n\n")
	end

	return nil,
		'to_rust_c_abi: unhandled ffi-ir kind "' .. kind .. '" — no C-ABI mapping implemented for this backend'
end

M.to_rust_c_abi = to_rust_c_abi

return M
