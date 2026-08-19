-- lib/ffi-ir/gleam_external.lua — the Gleam `@external` projector,
-- ported from fractal's packages/ffi-ir/src/gleam-external.ts.
--
-- Gleam `@external` codegen for ffi-ir's boundary layer — module/function/
-- resource/ownership-discipline shapes — the JS-target analogue of the
-- wasm-bindgen backend (which does the same thing for Rust/wasm-bindgen).
-- Reuses `lib/type-ir/gleam_native.lua`'s `gleam_type_from_type_ref` for every
-- data-shape position (params, return types) rather than reimplementing type
-- mapping, and adds only what ffi-ir carries that type-ir doesn't: function/
-- module boundaries, resource declarations, and the JS-source-path
-- information Gleam's `@external` attribute itself requires.
--
-- `@external` syntax, verified 2026-08-03 against gleam.run/documentation/
-- externals/ and tour.gleam.run/advanced-features/externals/ by the TS
-- source's author (not re-verified by this port — the findings below are the
-- TS source's, reproduced because they are the reasoning behind every mapping
-- choice here):
--
--   @external(javascript, "<module-path-or-package>", "<exported-name>")
--   pub fn <name>(<params>) -> <ReturnType>
--
-- Three positional arguments in that fixed order — target (`"javascript"` or
-- `"erlang"`; only `"javascript"` is relevant here), the JS module the
-- function is imported from (a relative `.mjs` path or an npm package name),
-- and the name of the exported binding in that module. Type annotations on
-- the Gleam-side signature are mandatory (the compiler cannot infer external
-- function types), and multiple `@external` attributes can stack on one
-- function to cover both targets — not used here since this file emits only
-- the `javascript` target. Both examples found in the docs
-- (`get_element_by_id`, `reverse_list`) are ordinary top-level function
-- declarations with named parameters — `@external` decorates a normal
-- `pub fn`, not a bare `fn(...) -> ...` type expression.
--
-- JS-SOURCE-PATH CONVENTION (the TS source's own addition, following the
-- "open metadata bag" precedent `with_ownership`/`meta.ownership` already
-- established in `init.lua`): `@external`'s second and third arguments name
-- information ffi-ir's `FfiRef`/`FfiShape` schema has no field for (the
-- schema was deliberately kept target-agnostic — see init.lua's file
-- header). This projector reads them from the `FfiRef`'s own `meta` bag:
--   - `meta.jsModule` (required `string`) — the JS module path/package
--     `@external`'s 2nd argument names. No default is defensible (there is no
--     way to derive a JS import path from a Gleam/ffi-ir name), so this
--     reports its absence rather than guessing a path.
--   - `meta.jsName` (optional `string`, defaults to the Gleam function's own
--     snake_case name) — the exported JS binding name, `@external`'s 3rd
--     argument. Defaulting to the same name is the common case in the docs'
--     own examples (`reverse_list`/`reverse_list`), so this only needs
--     overriding when the JS export is actually named differently.
--
-- WIRE-FACING KEY NAMES. `jsModule`/`jsName` are camelCase because they are
-- read from IR assembled by cross-language tooling, the same reason
-- `returnType`/`freeFn`/`libPath` keep theirs.
--
-- OWNERSHIP METADATA (`meta.ownership`, ffi-ir's `OwnershipDiscipline`) is
-- deliberately NOT gated or branched on anywhere in this file, unlike the
-- wasm-bindgen/C-ABI backends (both of which report the disciplines their
-- target can't realize). Those report because ownership discipline changes
-- the emitted Rust code shape itself (`*mut T` vs a plain value, `Arc<T>`
-- wrapping, a paired free function). Here it doesn't: JS has no
-- manual-free/refcount/lend-count-and-trap machinery of its own for
-- `@external` to hook into (the JS side of an external binding is opaque,
-- hand-written glue code this projector doesn't generate), and Gleam's own
-- type system has nothing an ownership qualifier could attach to (no
-- borrow-checking, no linear types) — so every one of the four disciplines
-- produces the exact same Gleam declaration. There is no "unsupported" branch
-- to take because there is no code-shape difference to fail to produce; a
-- value crossing this boundary is simply an opaque, GC-managed reference
-- either way.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion the sibling backends
-- apply: a missing name, a missing `meta.jsModule`, or an unhandled boundary
-- kind is a data error, not a programming error. This propagates — the
-- internal builders below return `(nil, errmsg)` too, and every caller checks.
--
-- RESERVED-WORD ESCAPING (a deliberate divergence from fractal's
-- gleam-external.ts, which doesn't escape reserved words — matches
-- gleam-native.ts's approach instead, likely a bug in the upstream source).
-- Every parameter/receiver name reaching a `pub fn` signature is snake_cased
-- and then escaped against Gleam's reserved words (trailing underscore, same
-- fallback `lib/type-ir/gleam_native.lua` uses). Without it, a source name that
-- snake_cases to a bare reserved word (`type`, `use`, `let`, ...) would emit
-- as invalid Gleam. See `build_function_decl`'s comment for the full
-- reasoning.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")
local gleam_native = require("lib.type-ir.gleam_native")

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
-- repro in init.lua's own copy of this comment, and the TODO.md entry ("an
-- alias imported via require ... degrades to any as soon as any consumer uses
-- that module"), which already records that the re-declaration is repeated in
-- each `lib/ffi-ir/*.lua` backend for this reason.
--
-- These MUST stay structurally identical to lib/type-ir/init.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- Gleam's snake_case convention for function and parameter names.
--
-- The TS source's `toSnakeCaseStripSeparators` regexes, in order: split a
-- lower/digit-to-upper boundary with an underscore (`readFile` ->
-- `read_File`), collapse every run of non-alphanumerics into one underscore,
-- strip leading/trailing underscores, lowercase the result. Written as
-- separate statements rather than a `gsub` chain because each `gsub` returns a
-- (string, count) pair, and chaining feeds the pair into the next call.
--
-- Local rather than shared with `lib/type-ir/codegen.lua`'s identically-behaving
-- `snake_case_strip_separators`: every sibling `ffi_ir_*.lua` backend keeps
-- its own copy, the same "each projector file is self-contained" precedent the
-- TS source states for its own duplication.
--: (name: string) -> string
local function to_snake_case(name)
	local split = name:gsub("([a-z0-9])(%u)", "%1_%2")
	local collapsed = split:gsub("[^A-Za-z0-9]+", "_")
	local no_leading = collapsed:gsub("^_+", "")
	local trimmed = no_leading:gsub("_+$", "")
	return trimmed:lower()
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements. This reproduces the TS source's `JSON.stringify`, which
-- is what produces `@external`'s two quoted arguments there.
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

-- `value` as a double-quoted string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- The `/// ...` doc-comment lines for a meta bag: one line when `description`
-- holds a string, none otherwise. Returned as a list because callers splice it
-- into a line list.
--
-- One line, not a per-newline split: the TS source emits the description
-- verbatim after `/// `, and this port matches it rather than "improving" on
-- it. (`lib/type-ir/gleam_native.lua`'s own `doc_comment` does split, because ITS
-- source does.)
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

-- ── Declaration builders ─────────────────────────────────────────────────────

-- `@external`'s required 2nd argument, read off the declaration's own meta bag
-- (see the file header for why it lives there and why no default is
-- defensible). `where` names the declaration in the error message.
--: (meta: Meta, where: string) -> (string | nil, string | nil)
local function js_module_of(meta, where)
	local js_module = meta.jsModule
	if type(js_module) ~= "string" then
		return nil,
			'to_gleam_ffi: "' .. where .. '" is missing required meta.jsModule (the JS module path/package '
				.. '@external\'s 2nd argument names — e.g. "./math.mjs" or an npm package name) — there is no '
				.. "derivable default, so this must be supplied explicitly on the FfiRef's meta bag"
	end
	return js_module
end

-- `@external`'s 3rd argument: `meta.jsName` when present, else the Gleam
-- function's own name (the docs' own `reverse_list`/`reverse_list` case).
--: (meta: Meta, gleam_name: string) -> string
local function js_name_of(meta, gleam_name)
	local js_name = meta.jsName
	if type(js_name) == "string" then return js_name end
	return gleam_name
end

-- Gleam's reserved words. VERBATIM COPY of `lib/type-ir/gleam_native.lua`'s own
-- `GLEAM_KEYWORDS` — see this function's comment for why this file diverges
-- from its TS source by escaping them, matching that module's approach.
local GLEAM_KEYWORDS = {
	["as"] = true, ["assert"] = true, ["auto"] = true, ["case"] = true,
	["const"] = true, ["delegate"] = true, ["derive"] = true, ["echo"] = true,
	["else"] = true, ["fn"] = true, ["if"] = true, ["implement"] = true,
	["import"] = true, ["let"] = true, ["macro"] = true, ["opaque"] = true,
	["panic"] = true, ["pub"] = true, ["test"] = true, ["todo"] = true,
	["type"] = true, ["use"] = true,
} --[[: { [string]: boolean }]]

-- Gleam has no raw-identifier escape (unlike Rust's `r#ident`), so a
-- collision is resolved with a trailing underscore — the same fallback
-- `lib/type-ir/gleam_native.lua`'s `escape_gleam_ident` uses.
--: (snake_name: string) -> string
local function escape_gleam_ident(snake_name)
	if GLEAM_KEYWORDS[snake_name] then return snake_name .. "_" end
	return snake_name
end

-- One `@external(javascript, ...)` + `pub fn name(...)` declaration for a
-- `function`-shaped signature. `extra_param`, when given, is prepended ahead
-- of the shape's own params — used by `build_method` to splice in the receiver
-- (see that function's comment for why).
--
-- DIVERGES FROM fractal's gleam-external.ts, which does NOT check parameter
-- names against Gleam's reserved words — a bare reserved word snake_cased
-- from a param name (e.g. a JS `type` parameter) would emit as an invalid
-- Gleam function signature. `lib/type-ir/gleam_native.lua`'s own port of
-- gleam-native.ts DOES escape reserved words for field labels, matching
-- Gleam's actual grammar; this file follows that approach instead of the
-- TS source's, on the read that the TS's omission is a latent bug rather than
-- an intentional target-language choice — a reserved word cannot legally
-- appear unescaped as a Gleam parameter name regardless of what fractal's own
-- source does.
--: (gleam_name: string, params: FfiParam[], return_type: TypeRef, meta: Meta, where: string, extra_param: FfiParam | nil) -> (string | nil, string | nil)
local function build_function_decl(gleam_name, params, return_type, meta, where, extra_param)
	local js_module, err = js_module_of(meta, where)
	if js_module == nil then return nil, err end
	local js_name = js_name_of(meta, gleam_name)

	local rendered = {} --[[: { [integer]: string } ]]
	local n = 0
	if extra_param ~= nil then
		n = n + 1
		rendered[n] = escape_gleam_ident(to_snake_case(extra_param.name))
			.. ": " .. gleam_native.gleam_type_from_type_ref(extra_param.type)
	end
	for i = 1, #params do
		n = n + 1
		rendered[n] = escape_gleam_ident(to_snake_case(params[i].name))
			.. ": " .. gleam_native.gleam_type_from_type_ref(params[i].type)
	end

	local lines = doc_comment(meta)
	lines[#lines + 1] = "@external(javascript, " .. quote(js_module) .. ", " .. quote(js_name) .. ")"
	lines[#lines + 1] = "pub fn " .. gleam_name .. "(" .. table.concat(rendered, ", ") .. ") -> "
		.. gleam_native.gleam_type_from_type_ref(return_type)
	return table.concat(lines, "\n")
end

-- A `function` shape -> a `pub fn` declaration under its snake_cased name.
--
-- Takes the shape as `FfiFunctionLike` (the structural "carries params and a
-- return type" alias) rather than `FfiFunctionShape`: the value reaching here
-- is an open `FfiShape` whose `kind` is a plain `string`, which no checked
-- cast can narrow to the concrete alias's literal `kind: "function"`. Same
-- reason every sibling backend spells its shapes structurally.
--: (name: string, shape: FfiFunctionLike, meta: Meta) -> (string | nil, string | nil)
local function build_function(name, shape, meta)
	local gleam_name = to_snake_case(name)
	return build_function_decl(gleam_name, shape.params, shape.returnType, meta, 'function "' .. name .. '"', nil)
end

-- Method -> free function taking the receiver as an explicit first parameter.
--
-- Verified by the TS source's author, not assumed:
-- gleam.run/documentation/externals/ and tour.gleam.run/advanced-features/
-- externals/ show `@external` binding only free functions in every example
-- found (`get_element_by_id`, `reverse_list`, `halt`) — no method/receiver
-- syntax of any kind is documented, which matches Gleam's own type system
-- having no method-on-a-type/receiver concept at all (custom types carry no
-- attached functions; a Gleam "method" is conventionally just a function
-- taking the value as its first argument, e.g. `list.map(my_list, f)`).
-- Degrading a `method` shape to that same convention is therefore the
-- idiomatic Gleam shape for this, not an invented workaround.
--
-- The receiver's own type is the resource's external-type name (see
-- `build_resource`), referenced here through a synthetic `ref` TypeRef so it
-- flows through `gleam_type_from_type_ref` unchanged.
--: (name: string, shape: FfiFunctionLike, receiver: string, meta: Meta) -> (string | nil, string | nil)
local function build_method(name, shape, receiver, meta)
	local gleam_name = to_snake_case(name)
	local receiver_param = {
		name = to_snake_case(receiver),
		type = { shape = { kind = "ref", target = receiver }, meta = {} },
	} --[[: FfiParam]]
	return build_function_decl(
		gleam_name,
		shape.params,
		shape.returnType,
		meta,
		'method "' .. name .. '"',
		receiver_param
	)
end

-- Resource -> a Gleam "external type" declaration: `pub type Name` with no
-- constructors.
--
-- Verified by the TS source's author against gleam.run/documentation/
-- externals/, which names exactly this construct as Gleam's idiom for an
-- opaque foreign value ("Gleam doesn't know anything about this type other
-- than its existence and the name it has been given... it cannot be
-- constructed or manipulated directly in Gleam code. External functions must
-- be used instead.") — an established Gleam idiom, not an invented one.
--
-- Each of the resource's own methods is emitted as a `build_method`-style free
-- function alongside the type declaration, since Gleam's external types carry
-- no attached-function/impl-block syntax of their own for this projector to
-- hook into. The declared type's name is the caller-supplied `name` verbatim
-- (Gleam type names are PascalCase and the IR's resource keys already are), so
-- the receiver parameter's `ref` target and this declaration always agree.
--
-- Takes the methods map rather than the whole resource shape, for the same
-- structural-cast reason `build_function` takes `FfiFunctionLike` — see there.
--: (name: string, methods: { [string]: FfiRef }, meta: Meta) -> (string | nil, string | nil)
local function build_resource(name, methods, meta)
	local parts = doc_comment(meta)
	parts[#parts + 1] = "pub type " .. name
	local decls = { table.concat(parts, "\n") } --[[: { [integer]: string } ]]

	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local method_kind = method_ref.shape.kind
		if method_kind ~= "method" and method_kind ~= "function" then
			return nil,
				'to_gleam_ffi: resource method "' .. method_name .. '" has unexpected kind "' .. method_kind
					.. '" (expected "method")'
		end
		-- The receiver is this resource, whatever the method shape's own
		-- `receiver` says: the TS source likewise overwrites it (`{ ...shape,
		-- receiver: name }`) when re-reading a resource's methods map, since a
		-- method's position in that map is what establishes what it is a method
		-- ON.
		local decl, err = build_method(method_name, method_ref.shape --[[: FfiFunctionLike]], name, method_ref.meta)
		if decl == nil then return nil, err end
		decls[#decls + 1] = decl
	end

	return table.concat(decls, "\n\n")
end

local render_ffi -- forward declaration (mutually recursive with `build_module`)

-- Module -> concatenated declarations, NOT an inline wrapping construct.
--
-- Verified by the TS source's author against Gleam's own project-layout
-- convention (gleam.run/documentation/externals/'s examples import across
-- files by path, e.g. `./my_app/pokemon.mjs`, plus the Gleam Tour's
-- project-structure material): a Gleam module IS a source file located by its
-- path in `src/`, not an inline `module name { ... }`/`mod name { ... }` block
-- the way Rust or many other targets support (contrast the wasm-bindgen
-- backend's `pub mod name { ... }`, which C-ABI-analogue targets can express
-- inline). There is therefore no idiomatic single-expression Gleam construct
-- this `name` could become — the concatenated declarations are the content of
-- the file at that module's path (`<name>.gleam`), noted here as a comment
-- rather than synthesized as Gleam syntax that doesn't exist.
--
-- Resources are emitted before functions, as in the TS source.
--: (name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_module(name, functions, resources)
	local parts = {
		"// module: " .. name .. " (place these declarations in " .. to_snake_case(name) .. ".gleam)",
	} --[[: { [integer]: string } ]]

	local res_names = ordered_keys(resources)
	for i = 1, #res_names do
		local decl, err = render_ffi(resources[res_names[i]], res_names[i])
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	local fn_names = ordered_keys(functions)
	for i = 1, #fn_names do
		local decl, err = render_ffi(functions[fn_names[i]], fn_names[i])
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	return table.concat(parts, "\n\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to Gleam `@external(javascript, ...)` source.
--
--   function — an `@external` attribute plus a `pub fn` declaration under the
--              snake_cased `name` (requires `meta.jsModule`; see
--              `js_module_of`).
--   method   — the same, with the receiver spliced in as an explicit first
--              parameter typed by the resource's external-type name (see
--              `build_method`).
--   resource — `pub type Name` with no constructors, followed by each of its
--              methods as a receiver-first free function (see
--              `build_resource`).
--   module   — the members' declarations concatenated under a file-path
--              comment, Gleam modules being files rather than an inline
--              construct (see `build_module`).
--
-- `name` is required for every kind — a Gleam `pub fn`/`pub type` is always a
-- named top-level declaration, and `module` uses it as the file-path comment's
-- label — mirroring the sibling backends' identical requirement.
--
-- No ownership discipline is unsupported on this target, and none changes the
-- output at all (see the file header). The failures this function can report
-- are a missing `name`, a missing `meta.jsModule`, a resource method whose
-- kind is neither `method` nor `function`, and a boundary kind with no
-- mapping.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function render_ffi(ref, name)
	local kind = ref.shape.kind

	if name == nil then
		return nil,
			'to_gleam_ffi: "' .. kind .. '" requires a name — a Gleam @external binding is always a named '
				.. "top-level declaration, not an anonymous inline type"
	end

	if kind == "function" then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta)
	end

	if kind == "method" then
		local receiver = (ref.shape --[[: { receiver: string, ... }]]).receiver
		return build_method(name, ref.shape --[[: FfiFunctionLike]], receiver, ref.meta)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { methods: { [string]: FfiRef }, ... }]]
		return build_resource(name, shape.methods, ref.meta)
	end

	if kind == "module" then
		local shape = ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		return build_module(name, shape.functions, shape.resources)
	end

	return nil,
		'to_gleam_ffi: unhandled ffi-ir kind "' .. kind .. '" — no Gleam @external mapping implemented for this backend'
end

-- The public name; `render_ffi` is the local binding `build_module` recurses
-- through, forward-declared above because a module's members are lowered by
-- this same entry point.
M.to_gleam_ffi = render_ffi

return M
