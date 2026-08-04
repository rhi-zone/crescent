-- lib/fractal/ffi_ir_bun.lua — the Bun (`bun:ffi`) consumer projector, ported
-- from fractal's packages/ffi-ir/src/bun.ts.
--
-- This is the JS-side counterpart to the C-ABI backend: where that backend
-- emits the Rust *producer* of a plain C ABI (`extern "C"`, `#[repr(C)]`),
-- this file emits the TypeScript *consumer* loader code that calls INTO that
-- same shared library from a Bun process, via `bun:ffi`'s `dlopen`. Both
-- target the identical wire boundary — a plain, non-WIT, non-wasm-bindgen C
-- ABI — so the ownership-discipline scope decisions below are made relative to
-- the C-ABI backend's own decisions (documented there), not re-derived from
-- scratch.
--
-- `bun:ffi` API surface, verified two ways by the TS source's author on
-- 2026-08-03 (not carried over from memory, and not re-verified by this port —
-- the findings below are the TS source's, reproduced because they are the
-- reasoning behind every mapping choice in this file):
--   1. `dlopen(path, symbols)` signature and the symbol-descriptor shape
--      (`{ [name]: { args: FFIType[], returns: FFIType } }`) — via a fetch of
--      https://bun.com/docs/runtime/ffi.
--   2. The exact, complete `FFIType` token vocabulary — via direct runtime
--      introspection of the Bun 1.3.9 binary installed in that project's
--      environment (`bun -e 'console.log(require("bun:ffi").FFIType)'`), which
--      is authoritative over the docs page for this question and resolved one
--      real ambiguity the docs page left open (see below). The full enum, by
--      value: `char`(0) `i8`(1) `u8`(2) `i16`(3) `u16`(4) `i32`/`int`/`c_int`(5)
--      `u32`/`uint`/`c_uint`(6) `i64`/`isize`(7) `u64`/`usize`(8)
--      `f64`/`double`(9) `f32`/`float`(10) `bool`(11) `ptr`/`pointer`/`void*`(12)
--      `void`(13) `cstring`(14) `i64_fast`(15) `u64_fast`(16)
--      `function`/`fn`/`callback`(17) `napi_env`(18) `napi_value`(19)
--      `buffer`(20).
--   - Ambiguity resolved by the runtime check: the docs page's own prose table
--     never lists a `void` token (only ever discussing `void` in passing, e.g.
--     "you may declare a non-`void` returns" for `JSCallback`), leaving
--     genuinely unclear whether a void-returning function's `returns` field
--     should be omitted, `undefined`, or some other convention. The runtime
--     enum confirms `"void"` (13) IS a real, distinct `FFIType` token (separate
--     from `ptr`/12) — so void returns are emitted as `returns: "void"` below,
--     not omitted.
--   - No struct type exists anywhere in this enum (confirmed by the complete
--     list above, cross-checked against the docs page, which states plainly
--     that struct-by-value has no direct mapping and must be passed via manual
--     pointers). `bun:ffi` remains, in this respect, exactly as
--     experimental/limited as that session's earlier research flagged.
--     `to_bun_ffi_type` below reports an explicit error for any shape that
--     would require struct-by-value (or any other non-token-representable
--     encoding) rather than guessing a lossy one.
--
-- OWNERSHIP-DISCIPLINE SCOPE FOR THIS TARGET (mirrors the C-ABI backend's own
-- "discipline-per-target: decided" reasoning, applied to the SAME C ABI that
-- backend targets, viewed from the calling side rather than the producer side):
--   - no `meta.ownership` at all, or `copy` — plain by-value;
--     `to_bun_ffi_type` maps the underlying primitive kind directly.
--   - `opaque-handle` — `"ptr"`, regardless of the referenced TypeRef's own
--     structural kind (mirrors the C-ABI backend's `*mut <T>` — at the raw ABI,
--     the pointee's Rust-side layout is invisible to a JS caller either way).
--   - `refcount` — ALSO `"ptr"`, and deliberately NOT gated the way the C-ABI
--     backend gates it. That backend reports an error on `refcount` because it
--     has to *generate the free-function/bookkeeping implementation itself*,
--     and plain C has no native refcount mechanism to generate correct code
--     for. This file generates no implementation at all — only a `dlopen`
--     symbol-type declaration — and at that level a refcounted handle crosses
--     the C ABI exactly the same way an opaque handle does: a raw pointer
--     (`Arc::into_raw`/`Box::into_raw` are both `*const/*mut T` at the ABI).
--     The loader code is genuinely identical regardless of which of these two
--     disciplines a given handle uses; gating here would be gating on a
--     distinction that does not exist at this layer, not preserving a real one.
--     (This is the same "same reasoning, different conclusion per file"
--     latitude the Gleam and ReScript backends already took relative to the
--     wasm-bindgen and Melange ones for the identical four-discipline
--     question, documented in their own file headers.)
--   - `resource` (WIT's own/borrow) — REPORTED AS UNSUPPORTED. This is WIT's
--     Canonical ABI mechanism specifically: a resource crosses as an `i32`
--     handle-table index into a per-instance table with lend-count tracking,
--     NOT a raw memory pointer — a fundamentally different wire representation
--     than anything a plain `dlopen`'d C shared library (which never speaks the
--     Canonical ABI) can produce or consume. This matches the C-ABI backend's
--     own scope decision for the identical discipline, for the identical reason
--     (no such mechanism exists on this wire boundary) — not a new gate
--     invented for this file.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `type_ref.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported shape or
-- discipline is a data error, not a programming error. This propagates — the
-- internal builders below return `(nil, errmsg)` too, and every caller checks.
-- In particular the TS source's `unsupportedKind` helper is typed `never`
-- precisely because it always throws; here it is an ordinary error-returning
-- helper whose result every call site threads.
--
-- EMISSION ORDER. The TS source iterates `Object.entries(...)` — JS insertion
-- order — over a module's `functions`/`resources` and a resource's `methods`.
-- Lua tables have no insertion order to recover, so this file emits in byte
-- order of those map keys (see `ordered_keys`), the same deterministic
-- substitution `type_ref.lua`'s own `ordered_keys` makes. The emitted SET of
-- symbol entries and wrappers is identical; only their order within the
-- generated `dlopen` map and wrapper block can differ from the TS output.
-- Module-level structure is unchanged: every function's symbols first, then
-- every resource's.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir   = require("lib.fractal.ffi_ir")
-- The DATA-shape lattice, a different registry from ffi-ir's own: `resolve`
-- below dispatches a type-ir kind (`integer`, `string`, ...) through type-ir's
-- ancestor fallback, which is what makes `integer` reach a `number` handler
-- when no exact one is registered.
local type_ref = require("lib.fractal.type_ref")

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

local M = {}

-- ── Name and literal formatting ──────────────────────────────────────────────

-- The snake_case symbol convention shared with the C-ABI backend. This file's
-- whole job is binding against symbols that convention actually produced in
-- the compiled library, so the two MUST agree exactly; the duplication is the
-- TS package's own (every projector file carries an identical copy).
--
-- The three rewrites are the TS source's three regexes, in order: split a
-- lower/digit-to-upper boundary with an underscore (`readFile` -> `read_File`),
-- collapse every run of non-alphanumerics into one underscore, strip
-- leading/trailing underscores, lowercase the result.
--: (name: string) -> string
local function to_snake_case(name)
	local split = (name:gsub("([a-z0-9])(%u)", "%1_%2"))
	local collapsed = (split:gsub("[^a-zA-Z0-9]+", "_"))
	local head_trimmed = (collapsed:gsub("^_+", ""))
	local trimmed = (head_trimmed:gsub("_+$", ""))
	return trimmed:lower()
end

-- JavaScript's reserved words, as a set. Bracketed string keys throughout
-- because several of these (`break`, `do`, `else`, `for`, `function`, `if`,
-- `in`, `return`, `while`) are Lua keywords too and cannot appear as bare
-- table-literal keys.
local JS_RESERVED = {
	["break"] = true, ["case"] = true, ["catch"] = true, ["class"] = true,
	["const"] = true, ["continue"] = true, ["debugger"] = true, ["default"] = true,
	["delete"] = true, ["do"] = true, ["else"] = true, ["export"] = true,
	["extends"] = true, ["finally"] = true, ["for"] = true, ["function"] = true,
	["if"] = true, ["import"] = true, ["in"] = true, ["instanceof"] = true,
	["new"] = true, ["return"] = true, ["super"] = true, ["switch"] = true,
	["this"] = true, ["throw"] = true, ["try"] = true, ["typeof"] = true,
	["var"] = true, ["void"] = true, ["while"] = true, ["with"] = true,
	["yield"] = true, ["let"] = true, ["static"] = true, ["await"] = true,
	["async"] = true,
} --[[: { [string]: boolean }]]

-- `name`, made safe to emit as a bare JS identifier: a reserved word gets a
-- trailing underscore, everything else passes through unchanged.
--
-- Used ONLY for emitted JS binding names (a wrapper function's own name, a
-- parameter name) — never for a native symbol name, which must reach `dlsym`
-- unmodified. See `build_symbol_entry`.
--: (name: string) -> string
local function escape_js_ident(name)
	if JS_RESERVED[name] then return name .. "_" end
	return name
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements — reproducing the TS source's `JSON.stringify`, whose
-- output is also a valid JS/TS string literal.
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
-- Lowercase hex, matching `JSON.stringify`'s own casing.
--: (c: string) -> string
local function escape_char(c)
	local mapped = ESCAPES[c]
	if mapped ~= nil then return mapped end
	return string.format("\\u%04x", string.byte(c) or 0)
end

-- `value` as a double-quoted JS string literal. Every string reaching `quote`
-- today is a snake_case symbol name or a library path, so `escape_char`'s
-- `\uXXXX` fallback is unreachable in practice; it is there so a
-- hand-assembled IR carrying an odd name cannot emit a broken literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- The `// ...` doc-comment lines for a meta bag: one `indent`-prefixed line
-- when `description` holds a string, none otherwise. Returned as a list
-- because callers splice it into a line list.
--: (indent: string, meta: Meta) -> { [integer]: string }
local function doc_comment(indent, meta)
	local description = meta.description
	if type(description) ~= "string" then return {} --[[: { [integer]: string } ]] end
	return { indent .. "// " .. description } --[[: { [integer]: string } ]]
end

-- A record's keys in a deterministic (byte) order — see the EMISSION ORDER
-- note in the file header for why this stands in for the TS source's
-- `Object.entries` insertion order.
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

-- Minimal primitive-kind -> FFIType mapping. Deliberately NOT a full TypeShape
-- handler table the way the wasm-bindgen backend's is: `bun:ffi` has no
-- compound-type tokens at all (see file header), so there is no
-- struct/enum-hoisting path to build; every non-primitive kind is simply
-- unsupported.
local PRIMITIVE_HANDLERS = {
	boolean = "bool",
	number = "f64",
	integer = "i64",
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
	string = "cstring",
	uuid = "cstring",
	uri = "cstring",
	email = "cstring",
	datetime = "cstring",
	date = "cstring",
	time = "cstring",
	duration = "cstring",
	bytes = "buffer",
	null = "void",
	void = "void",
} --[[: { [string]: string }]]

-- The report for a data shape with no FFIType token. Always an error return —
-- the TS source's counterpart is typed `never` because it unconditionally
-- throws, so this helper's single job is producing the message its callers
-- thread outward.
--: (kind: string) -> (string | nil, string | nil)
local function unsupported_kind(kind)
	return nil,
		'to_bun_ffi_type: unhandled kind "' .. kind .. '" — bun:ffi\'s FFIType vocabulary has no token for this '
			.. "shape (no struct-by-value, tuple, map, union, or nested-container type exists in its "
			.. "documented/introspected type table; a value needing one of those crosses only as a manual pointer "
			.. "+ hand-written marshalling code, which this minimal generator does not attempt rather than guess a "
			.. "lossy encoding)"
end

-- The `bun:ffi` `FFIType` string token for one boundary position (a
-- parameter's or return's `TypeRef`), applying the same C-ABI ownership rule
-- the C-ABI backend applies, from the consumer side — see the file header for
-- the full reasoning on each discipline.
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy`: an unannotated value crosses by value.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_bun_ffi_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil then
		local discipline_kind = discipline.kind
		if discipline_kind == "opaque-handle" or discipline_kind == "refcount" then return "ptr" end
		if discipline_kind == "resource" then
			return nil,
				'to_bun_ffi_type: unsupported ownership discipline "resource" (own/borrow) for the bun:ffi target '
					.. "— that is WIT's Canonical ABI handle-table mechanism (an i32 index with lend-count "
					.. "tracking), not a raw C-ABI pointer; a plain dlopen'd shared library (what bun:ffi loads) "
					.. "never speaks that ABI, matching the C-ABI backend's identical scope decision for the same "
					.. "discipline on the same wire boundary"
		end
	end
	-- The discipline is absent or `copy` beyond this point — plain by-value.
	local token = type_ref.resolve(ref.shape.kind, PRIMITIVE_HANDLERS)
	if token == nil then return unsupported_kind(ref.shape.kind) end
	return token
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- One symbol-table entry (`name: { args: [...], returns: ... }`, the value
-- half of `dlopen`'s second argument) for a `function`/`method` shape.
--
-- `self_param`, when true, prepends the synthesized `"ptr"` receiver
-- parameter — mirrors the C-ABI backend's identical handling for a resource
-- method's implicit handle, since ffi-ir's `method` kind names its receiver by
-- resource name only and carries no parameter of its own.
--
-- The key MUST be the literal native symbol name `dlopen` looks up via `dlsym`
-- (verified against bun.com/docs/runtime/ffi, 2026-08-03: "the KEY in the
-- symbols object ... must exactly match the native exported symbol name" — no
-- separate lookup-name field exists, unlike `linkSymbols`'s explicit
-- aliasing). Always string-quoted (`quote`, not `escape_js_ident`) rather than
-- emitted as a bare identifier — escaping a reserved-word-shaped symbol name
-- would silently change the string `dlsym` looks up (e.g. turning a real
-- exported symbol literally named `new` into a lookup for `new_`, which does
-- not exist in the library). A quoted string key sidesteps both that risk and
-- the separate "starts with a digit"/non-identifier-shaped-name case, at no
-- cost — JS object literals accept any string as a quoted key.
--: (symbol_name: string, shape: FfiFunctionLike, self_param: boolean) -> (string | nil, string | nil)
local function build_symbol_entry(symbol_name, shape, self_param)
	local args = {} --[[: { [integer]: string } ]]
	local n = 0
	if self_param then
		n = n + 1
		args[n] = quote("ptr")
	end
	for i = 1, #shape.params do
		local mapped, err = M.to_bun_ffi_type(shape.params[i].type)
		if mapped == nil then return nil, err end
		n = n + 1
		args[n] = quote(mapped)
	end

	local returns, return_err = M.to_bun_ffi_type(shape.returnType)
	if returns == nil then return nil, return_err end

	return "  " .. quote(symbol_name) .. ": { args: [" .. table.concat(args, ", ") .. "], returns: " .. quote(returns) .. " },"
end

-- The thin exported wrapper function calling through `symbols.<symbol_name>`.
--
-- `wrapper_name` is the ffi-ir map key (already an idiomatic JS identifier);
-- `symbol_name` is the raw C-ABI export name the C-ABI backend actually
-- produced (may differ, e.g. snake_case vs camelCase).
--
-- `self_param`, when given, is the receiver resource's NAME: it prepends a
-- `handle: number` parameter and appears in that parameter's trailing comment,
-- which is its only use — the wrapper passes the handle through positionally.
--
-- This builder cannot fail: it emits only names, never a mapped FFIType, so it
-- returns a plain string rather than the `(value, errmsg)` pair the type-mapped
-- builders return.
--: (wrapper_name: string, symbol_name: string, ref: FfiRef, shape: FfiFunctionLike, self_param: string | nil) -> string
local function build_wrapper(wrapper_name, symbol_name, ref, shape, self_param)
	local params = {} --[[: { [integer]: string } ]]
	local args = {} --[[: { [integer]: string } ]]
	local n = 0
	if self_param ~= nil then
		n = n + 1
		params[n] = "handle: number /* " .. self_param .. " */"
		args[n] = "handle"
	end
	for i = 1, #shape.params do
		local ident = escape_js_ident(shape.params[i].name)
		n = n + 1
		params[n] = ident .. ": unknown"
		args[n] = ident
	end

	local lines = doc_comment("", ref.meta)
	lines[#lines + 1] = "export function " .. escape_js_ident(wrapper_name) .. "(" .. table.concat(params, ", ") .. ") {"
	-- Bracket + quoted access, same reason the symbol-entry key above is quoted
	-- rather than emitted as a bare/escaped identifier — `symbol_name` must
	-- reach `dlsym` unmodified.
	lines[#lines + 1] = "  return symbols[" .. quote(symbol_name) .. "](" .. table.concat(args, ", ") .. ")"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- Everything one `function`/`resource` shape contributes to the single shared
-- `dlopen` symbol map: its symbol-table entries and its exported wrappers.
-- Returned as one record so `collect` keeps the repo's two-value
-- `(result, errmsg)` return convention, matching the TS source's own single
-- `{ entries, wrappers }` object.
--:: BunCollected = { entries: { [integer]: string }, wrappers: { [integer]: string } }

-- Collect one `function`/`method`/`resource` shape's contribution — the
-- aggregation step `to_bun`'s `module` branch needs for its single `dlopen`
-- call, and that a standalone `to_bun` on a bare function or resource also
-- reuses, so both paths share one code path rather than diverging.
--: (ref: FfiRef, name: string) -> (BunCollected | nil, string | nil)
local function collect(ref, name)
	local kind = ref.shape.kind

	if kind == "function" then
		local shape = ref.shape --[[: FfiFunctionLike]]
		local symbol_name = to_snake_case(name)
		local entry, err = build_symbol_entry(symbol_name, shape, false)
		if entry == nil then return nil, err end
		return {
			entries = { entry } --[[: { [integer]: string } ]],
			wrappers = { build_wrapper(name, symbol_name, ref, shape, nil) } --[[: { [integer]: string } ]],
		}
	end

	if kind == "resource" then
		-- Cast to an OPEN structural type naming just the fields read here,
		-- rather than to `FfiResourceShape`: that alias pins `kind` to the
		-- literal `"resource"`, and a checked cast from `FfiShape`'s
		-- `kind: string` to a literal is not a subtype relation the checker
		-- accepts. Same formulation the ruby-ffi backend uses, for the same
		-- reason.
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		local resource_snake = to_snake_case(shape.name)
		local entries = {} --[[: { [integer]: string } ]]
		local wrappers = {} --[[: { [integer]: string } ]]
		local n = 0

		local method_names = ordered_keys(shape.methods)
		for i = 1, #method_names do
			local method_name = method_names[i]
			local method_ref = shape.methods[method_name]
			local method_shape = method_ref.shape --[[: FfiFunctionLike]]
			local symbol_name = resource_snake .. "_" .. to_snake_case(method_name)
			local entry, err = build_symbol_entry(symbol_name, method_shape, true)
			if entry == nil then return nil, err end
			n = n + 1
			entries[n] = entry
			wrappers[n] = build_wrapper(
				shape.name .. "_" .. method_name,
				symbol_name,
				method_ref,
				method_shape,
				shape.name
			)
		end

		-- The paired free function the C-ABI backend's resource emitter always
		-- produces (`<resource>_free`) — a real exported symbol in the compiled
		-- library this file's whole job is to bind against, so omitting it
		-- would leave callers with no way to ever release a handle.
		local free_symbol = resource_snake .. "_free"
		entries[n + 1] = "  " .. quote(free_symbol) .. ": { args: [" .. quote("ptr") .. "], returns: " .. quote("void") .. " },"
		wrappers[n + 1] = table.concat({
			"export function " .. escape_js_ident(shape.name) .. "_free(handle: number) {",
			"  return symbols[" .. quote(free_symbol) .. "](handle)",
			"}",
		}, "\n")

		return { entries = entries, wrappers = wrappers }
	end

	return nil,
		'to_bun: unhandled ffi-ir kind "' .. kind .. '" for collect() — only "function" and "resource" contribute '
			.. "dlopen symbols"
end

-- The complete emitted module: the `bun:ffi` import, the single `dlopen` call
-- carrying every symbol entry, then the wrappers separated by blank lines.
--: (lib_path: string, entries: { [integer]: string }, wrappers: { [integer]: string }) -> string
local function render_module(lib_path, entries, wrappers)
	local lines = {
		'import { dlopen } from "bun:ffi"',
		"",
		"const { symbols } = dlopen(" .. quote(lib_path) .. ", {",
	} --[[: { [integer]: string } ]]
	local n = #lines
	for i = 1, #entries do
		n = n + 1
		lines[n] = entries[i]
	end
	lines[n + 1] = "})"
	lines[n + 2] = ""
	n = n + 2
	for i = 1, #wrappers do
		if i > 1 then
			n = n + 1
			lines[n] = ""
		end
		n = n + 1
		lines[n] = wrappers[i]
	end
	return table.concat(lines, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to `bun:ffi` TypeScript loader source — a single
-- `dlopen(lib_path, { ... })` call plus one thin exported wrapper per
-- function/method, plus (for a `resource`) its paired `_free` wrapper.
--
-- `lib_path` is required unconditionally: `dlopen`'s first argument is the
-- actual shared-library path, which nothing in `FfiRef` carries (ffi-ir models
-- the boundary shape, not deployment paths) — a real, load-bearing parameter
-- of the API being wrapped, not an invented one. It is a positional argument
-- here rather than a `meta.libPath` lookup, matching the TS source's own
-- signature.
--
--   function — one symbol entry + one wrapper. Requires `name`: a dlopen
--              symbol is a named export, not an anonymous inline type.
--   method   — must be reached via its enclosing `resource`. A bare `method`
--              names a `receiver` by string but carries no way to know that
--              resource's *other* methods or its free function, so — mirroring
--              the C-ABI backend's `method`-requires-`name` precedent — a bare
--              `method` reports an error directing the caller to project the
--              whole `resource` instead.
--   resource — opaque-handle pointer passthrough for every method's receiver
--              (`ptr`), plus the paired `_free` wrapper. A `name` argument, if
--              given, is IGNORED: the shape carries its own `name` field.
--   module   — one `dlopen` call grouping every contained function's and every
--              contained resource's methods' symbols. This is `bun:ffi`'s own
--              hard constraint driving the design (`dlopen` loads the whole
--              shared library in one call; one entry per exported symbol needed
--              from it), not an arbitrary choice.
--: (ref: FfiRef, lib_path: string, name: string | nil) -> (string | nil, string | nil)
function M.to_bun(ref, lib_path, name)
	local kind = ref.shape.kind

	if kind == "method" then
		return nil,
			'to_bun: a bare "method" cannot be projected on its own — project its enclosing "resource" instead, so '
				.. "its receiver's other methods and paired free function land in the same dlopen call"
	end

	if kind == "function" then
		if name == nil then
			return nil,
				'to_bun: "function" requires a name — a dlopen symbol is a named export, not an anonymous inline type'
		end
		local collected, err = collect(ref, name)
		if collected == nil then return nil, err end
		return render_module(lib_path, collected.entries, collected.wrappers)
	end

	if kind == "resource" then
		-- Open structural cast rather than `FfiResourceShape` — see the note in
		-- `collect`'s own resource branch.
		local shape = ref.shape --[[: { name: string, ... }]]
		local collected, err = collect(ref, shape.name)
		if collected == nil then return nil, err end
		return render_module(lib_path, collected.entries, collected.wrappers)
	end

	if kind == "module" then
		local shape = ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		local entries = {} --[[: { [integer]: string } ]]
		local wrappers = {} --[[: { [integer]: string } ]]
		local entry_n = 0
		local wrapper_n = 0

		--: (collected: BunCollected) -> nil
		local function absorb(collected)
			for i = 1, #collected.entries do
				entry_n = entry_n + 1
				entries[entry_n] = collected.entries[i]
			end
			for i = 1, #collected.wrappers do
				wrapper_n = wrapper_n + 1
				wrappers[wrapper_n] = collected.wrappers[i]
			end
		end

		local fn_names = ordered_keys(shape.functions)
		for i = 1, #fn_names do
			local collected, err = collect(shape.functions[fn_names[i]], fn_names[i])
			if collected == nil then return nil, err end
			absorb(collected)
		end

		-- The resources map's KEY is ignored, exactly as in the TS source: a
		-- resource's symbol names derive from the shape's own `name` field, so
		-- a map key that disagrees with it does not change the emitted symbols.
		local res_names = ordered_keys(shape.resources)
		for i = 1, #res_names do
			local res_ref = shape.resources[res_names[i]]
			local res_shape = res_ref.shape --[[: { name: string, ... }]]
			local collected, err = collect(res_ref, res_shape.name)
			if collected == nil then return nil, err end
			absorb(collected)
		end

		return render_module(lib_path, entries, wrappers)
	end

	return nil, 'to_bun: unhandled ffi-ir kind "' .. kind .. '" — no bun:ffi mapping implemented for this backend'
end

return M
