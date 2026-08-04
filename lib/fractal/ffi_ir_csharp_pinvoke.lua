-- lib/fractal/ffi_ir_csharp_pinvoke.lua — the .NET/P-Invoke consumer-side projector,
-- ported from fractal's packages/ffi-ir/src/csharp-pinvoke.ts.
--
-- This backend emits the CALLER of a C-ABI shared library (the counterpart to
-- `rust-c-abi.ts`'s Rust `#[no_mangle] pub extern "C"` PRODUCER side). Named by
-- target platform, matching the TS package's naming split: `rescript`/`gleam`/
-- `melange` name by target language/platform (the file emits a whole
-- language's own idiomatic external-declaration syntax), while
-- `wasm-bindgen`/`c-abi` name by technique (a specific binding mechanism
-- inside one language, Rust). P/Invoke is .NET's ONE mechanism for calling
-- native code — there is no second competing technique inside .NET the way
-- wasm-bindgen is one of several ways to bind Rust to JS — so, like ReScript's
-- `external`, "the platform" and "the technique" name the same thing here.
--
-- ============================================================================
-- P/Invoke attribute choice: `LibraryImportAttribute`, verified upstream
-- against Microsoft Learn (the TS source records the WebFetch, 2026-08-03):
--   - "P/Invoke source generation": `[LibraryImport]` (.NET 7+) triggers
--     compile-time source generation of marshalling code on a `static partial`
--     method, "removing the need for generation of an IL stub at runtime" that
--     `[DllImport]` requires, and works under Native AOT/trimming where
--     `[DllImport]`'s runtime-generated IL stub does not.
--   - "Native interoperability best practices": "DO use `[LibraryImport]`, if
--     possible, when targeting .NET 7+" is Microsoft's own stated current
--     guidance for new code; `[DllImport]` is called out as appropriate only
--     in the specific cases the SYSLIB1054 analyzer flags (calling-convention/
--     marshalling features `[LibraryImport]` doesn't support — none of which
--     this backend's scope needs: no COM, no `PreserveSig=false`
--     HRESULT-to-exception translation, no non-UTF-8/UTF-16 legacy ANSI/
--     BestFitMapping).
--   This backend targets `[LibraryImport]` exclusively — no `[DllImport]`
--   fallback path is implemented, since nothing in its scope (primitive
--   scalars, UTF-8 strings, opaque handles) needs a feature `[LibraryImport]`
--   lacks.
--
-- Requirements this imposes (same source-generation doc): a
-- `[LibraryImport]`-annotated method must be `static` AND `partial` (the
-- source generator supplies the body in a compiler-generated partial
-- declaration) — which in turn requires its ENCLOSING type be declared
-- `partial` too (an ordinary C# partial-method constraint: a partial method
-- cannot exist inside a non-partial type). Hence every wrapping class this
-- backend emits (`module` -> class, `resource` -> nested class) is declared
-- `static partial class`, not plain `static class`.
--
-- String marshaling: `[LibraryImport]` replaces `[DllImport]`'s Windows-centric
-- `CharSet` with `StringMarshalling`, and "ANSI has been removed and UTF-8 is
-- now available as a first-class option" — `StringMarshalling.Utf8`. This is
-- the correct match for the paired `c-abi` producer: its `string` mapping is
-- Rust's `String`/`&str`, which is guaranteed-valid UTF-8, not UTF-16 — so
-- `StringMarshalling.Utf8` (not `.Utf16`, `[DllImport]`'s historical default on
-- Windows) is emitted on every declaration whose signature contains a string,
-- keeping the two backends' string convention aligned.
-- `[MarshalAs(UnmanagedType.LPUTF8Str)]` is real but is the `[DllImport]`-era
-- per-parameter mechanism `StringMarshalling` supersedes for
-- `[LibraryImport]` — not used here, since one declaration-level setting
-- covers every string parameter/return.
--
-- Bool marshaling: a bare C# `bool` is explicitly listed as NOT blittable, and
-- "by default, a .NET `bool` is marshalled to a Windows `BOOL`... a 4-byte
-- value. However, the `_Bool`... type in C... [is] a *single* byte" — silently
-- leaving a C# `bool` unmarshaled against a C/Rust `bool` (both 1 byte,
-- matching the Rust `bool` `c-abi` emits) risks exactly this mismatch. The
-- doc's own Windows-data-types table gives the fix: `BOOLEAN` (an 8-bit
-- Windows bool, the same width as Rust/C's `bool`) maps to
-- `[MarshalAs(UnmanagedType.U1)] bool`, and the source generator respects
-- `[MarshalAs]` — so it is emitted on every bool-typed parameter/return (as
-- `[return: MarshalAs(...)]` in a return position).
--
-- ============================================================================
-- Ownership-discipline scope for this target. `c-abi` (the producer this
-- backend consumes) implements exactly two of the four ownership disciplines —
-- `copy` (by-value) and `opaque-handle` (`*mut T` plus a separately-emitted
-- `<resource>_free` function) — and reports `refcount`/`resource` (own/borrow)
-- as unsupported, since plain C has no native mechanism for either. Every
-- P/Invoke declaration this file emits is meant to pair 1:1 with what `c-abi`
-- can actually produce, so in practice only `copy` and `opaque-handle` cross
-- this specific boundary today.
--
-- That said, this file does NOT report an error for `refcount`/`resource` the
-- way `c-abi` does — reasoned through explicitly upstream, not guessed:
-- ownership discipline governs WHO is responsible for freeing a handle and
-- WHEN (call an explicit free-fn once / decrement a refcount / respect a
-- lend-count-and-trap contract) — a caller-side bookkeeping question. It does
-- NOT change how the handle crosses the ABI wire: in every one of the four
-- disciplines, a resource reference is still, physically, one pointer-sized
-- value — `IntPtr` on the .NET side, `*mut T` on the C-ABI side.
-- `to_dotnet_type` below therefore renders `IntPtr` uniformly for ANY
-- non-`copy` ownership discipline attached to a reference, regardless of which
-- of the three it is. A caller pairing this against a producer that doesn't
-- yet emit a matching refcount/resource-discipline C ABI (i.e. `c-abi` today)
-- gets a P/Invoke-correct `IntPtr` declaration for a symbol that doesn't yet
-- exist to link against — that mismatch is a producer-side coverage gap, not
-- something this consumer-side backend can detect or should paper over by
-- failing instead.
--
-- The one case this file DOES fail for, as a genuine P/Invoke-side limitation
-- rather than a caller-side bookkeeping distinction: a `copy` (or unset)
-- ownership TypeRef whose structural type-ir kind is anything beyond the flat
-- scalar set below (`object`/`array`/`map`/`tuple`/`union`/`enum`/
-- `intersection`/`interface`/a bare `ref` with no ownership metadata/etc.).
-- By-value struct marshaling for those would require this backend to also emit
-- `[StructLayout(LayoutKind.Sequential)]` C# struct declarations mirroring the
-- producer's own layout — no such struct-shape projector exists for either
-- side of this pairing yet, so emitting a same-layout C# struct here would be
-- inventing a struct definition with nothing on the producer side to verify it
-- against. Reports `(nil, errmsg)` rather than guessing at a layout, matching
-- the report-don't-degrade convention the sibling backends already use.
--
-- ============================================================================
-- ERROR CONVENTION. Every `throw` in the TS source becomes a `(nil, errmsg)`
-- return here — a malformed or unsupported IR is a DATA error, and this repo
-- never throws on one (precedent: `type_ref.lua`'s `resolve_ref`, which
-- converts the same TS throw the same way). This propagates: the internal
-- builders below that can fail return `(nil, errmsg)` too, and every caller
-- checks before using the result.
--
-- ============================================================================
-- KNOWN GAP — `kinds/common` is not ported yet.
--
-- dotnet.ts opens with a side-effect import of
-- `@rhi-zone/fractal-type-ir/kinds/common`, which registers type-ir's shipped
-- kind-extension parents into the shared lattice. crescent has no port of
-- those modules, so `lib/fractal/type_ref.lua`'s lattice carries only its two
-- built-in edges (`integer -> number`, `method -> function`).
--
-- This backend is the one that actually READS the lattice — `to_dotnet_type`'s
-- `type_ref.resolve(kind, SCALAR_TYPES)` fallback, and the `is_bool_type` /
-- `is_string_type` gates — so the missing registrations are a REAL behavioral
-- difference here, unlike in the sibling backends that only ever match kinds
-- directly. Reading the upstream modules `kinds/common` re-exports (directly
-- and transitively, via `kinds/wire-numerics` and `kinds/temporal`), the
-- registrations are:
--
--   kinds/semantic-strings — uuid, uri, email    -> string
--   kinds/date-time        — time                -> string
--                            (datetime and date are deliberately roots
--                            upstream too, so they fail on BOTH sides — no
--                            delta)
--   kinds/duration         — duration            -> string
--   kinds/int-widths       — int8..64, uint8..64 -> integer
--   kinds/float-widths     — float32, float64    -> number
--   kinds/bytes            — bytes               -> root (a no-op in Lua,
--                            where an absent entry already means root)
--   kinds/refinements      — no kinds at all (TS-type-only)
--
-- Of those, the int/float widths are listed DIRECTLY in `SCALAR_TYPES` below,
-- so their missing ancestor edges change nothing here. The delta is exactly
-- the five kinds that reach `string` ONLY via an ancestor edge:
--
--     uuid, uri, email, time, duration
--
-- Upstream those lower to C# `string` (and pull `StringMarshalling.Utf8` onto
-- the declaration). Here they fall through to `to_dotnet_type`'s
-- unsupported-kind error instead. The delta is narrow and fails toward an
-- explicit error rather than a silent mis-lowering, which is why this backend
-- lands ahead of the `kinds/common` port. `ffi_ir_csharp_pinvoke_test.lua` pins the
-- CURRENT behavior with a test so the change is caught rather than silent;
-- delete this note and flip that test when `kinds/common` is ported.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")
local ffi_ir = require("lib.fractal.ffi_ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, already imported via the `require` above. Duplicating a
-- type definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — an alias imported via `require` degrades to `any` as soon as any
-- consumer uses that module, and every consumer then reports errors against
-- THIS file's line numbers. `lib/fractal/ffi_ir.lua` carries the same three
-- lines, for the same reason, with the full minimal repro; the TODO.md entry
-- ("an alias imported via require ... degrades to any as soon as any consumer
-- uses that module") tracks deleting all of them once the checker resolves
-- imported aliases through a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Identifier and text helpers ──────────────────────────────────────────────

-- The TS `toSnakeCase`'s regex passes, in order: split a lowerCamel boundary
-- with an underscore, collapse every run of non-alphanumerics into a single
-- underscore, strip leading and trailing underscores, lowercase. Written as
-- separate statements rather than a `gsub` chain because each `gsub` returns a
-- (string, count) pair, and chaining feeds the pair into the next call.
--: (name: string) -> string
local function to_snake_case(name)
	local split = name:gsub("([a-z0-9])(%u)", "%1_%2")
	local collapsed = split:gsub("[^A-Za-z0-9]+", "_")
	local no_leading = collapsed:gsub("^_+", "")
	local trimmed = no_leading:gsub("_+$", "")
	return trimmed:lower()
end

-- The TS `toPascalCase`: split on runs of non-alphanumerics, drop empty parts,
-- capitalize each part's first character, join. Matching alphanumeric runs
-- with `gmatch` does the split and the empty-part filter in one step.
--: (name: string) -> string
local function to_pascal_case(name)
	local parts = {}
	local n = 0
	for part in name:gmatch("[A-Za-z0-9]+") do
		n = n + 1
		parts[n] = part:sub(1, 1):upper() .. part:sub(2)
	end
	return table.concat(parts)
end

-- Prefix every non-empty line of `block`. Empty lines are left bare rather
-- than becoming trailing whitespace, matching the TS `indent`'s own
-- `line.length === 0` guard. `prefix` defaults to four spaces.
--: (block: string, prefix: string | nil) -> string
local function indent(block, prefix)
	local p = prefix or "    "
	local out = {}
	local n = 0
	local pos = 1
	while true do
		local nl = block:find("\n", pos, true)
		local line
		if nl == nil then
			line = block:sub(pos)
		else
			line = block:sub(pos, nl - 1)
		end
		n = n + 1
		if #line == 0 then
			out[n] = line
		else
			out[n] = p .. line
		end
		if nl == nil then break end
		pos = nl + 1
	end
	return table.concat(out, "\n")
end

-- A record's keys in a deterministic order (byte order).
--
-- The TS iterates `Object.entries(...)`, i.e. JS property order — for the
-- string-keyed maps here, INSERTION order. Lua tables have no insertion order
-- to recover, so `pairs()` alone would make declaration emission order vary
-- between runs, and this backend's output is source text whose line order is
-- observable. Byte order is the deterministic stand-in — the same precedent
-- `type_ref.lua`'s own `ordered_keys` sets, for the same reason. The emitted
-- SET of declarations is identical either way; only their order within a class
-- body can differ from the TS.
--: (tbl: { [string]: unknown }) -> string[]
local function ordered_keys(tbl)
	local out = {}
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

-- C# reserved keywords (ECMA-334 §7.4.4 / the C# language reference's keyword
-- list) that cannot appear as a plain identifier and require `@`
-- verbatim-identifier escaping.
--
-- Held as a LIST plus a derived set rather than as a table literal of
-- `name = true` pairs, because ten of these words (`break`, `do`, `else`,
-- `false`, `for`, `if`, `in`, `return`, `true`, `while`) are Lua keywords too
-- and cannot be written as bare table-literal keys. A list plus one loop is
-- the faithful port of the TS `new Set([...])` and avoids a literal in which
-- some entries are bracket-quoted and others are not.
local CSHARP_KEYWORD_LIST = {
	"abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
	"class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
	"enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
	"foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
	"long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
	"private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed",
	"short", "sizeof", "stackalloc", "static", "string", "struct", "switch", "this",
	"throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
	"using", "virtual", "void", "volatile", "while",
}

local CSHARP_KEYWORDS = {} --[[: { [string]: boolean }]]

-- TYPECHECKER WORKAROUND: the set below is filled through this helper, whose
-- `word` is a plain `string` parameter, rather than by writing
-- `CSHARP_KEYWORDS[CSHARP_KEYWORD_LIST[i]] = true` directly in the loop. The
-- natural code is that direct write. It does not typecheck: a write whose key
-- carries a literal string type refines the index-signature type itself,
-- adding that key as a REQUIRED field, so the `{}` initializer above is then
-- rejected for "missing field 'abstract'". This is the same named-key-write
-- gap already recorded in TODO.md ("a named-key write to an
-- index-signature-typed table adds that key to the index-signature TYPE as a
-- required field"), and the same shape of fix as `ffi_ir.lua`'s `assign`
-- helper. Inline the write and delete this helper once that is fixed.
--: (set: { [string]: boolean }, word: string) -> nil
local function mark_keyword(set, word)
	set[word] = true
end

for i = 1, #CSHARP_KEYWORD_LIST do
	mark_keyword(CSHARP_KEYWORDS, CSHARP_KEYWORD_LIST[i])
end

--: (name: string) -> string
local function escape_csharp_ident(name)
	if CSHARP_KEYWORDS[name] then return "@" .. name end
	return name
end

-- A C# string literal for `value`.
--
-- The TS uses `JSON.stringify`, whose output for a string is a valid C# string
-- literal for every input this backend feeds it. Reproduced directly rather
-- than routed through a JSON encoder: the escaping the two agree on is exactly
-- backslash, double quote, and the three C0 whitespace escapes below, and the
-- values reaching here (native library names and exported symbol names) are
-- identifier-shaped, so nothing beyond that set is reachable in practice. A
-- literal control character surviving unescaped would produce invalid C#, so
-- they are escaped rather than trusted to be absent.
--: (value: string) -> string
local function quote(value)
	local backslashed = value:gsub("\\", "\\\\")
	local quoted = backslashed:gsub('"', '\\"')
	local no_nl = quoted:gsub("\n", "\\n")
	local no_cr = no_nl:gsub("\r", "\\r")
	local escaped = no_cr:gsub("\t", "\\t")
	return '"' .. escaped .. '"'
end

-- ── Type mapping ─────────────────────────────────────────────────────────────

-- Structural (non-ownership) type-ir kind -> C# type mapping — the `copy`/
-- unset-ownership scalar leaves this backend implements. Deliberately flat (no
-- recursion into array/object/etc.): see the file header's "genuine P/Invoke
-- limitation" note for why non-scalar kinds report an error instead.
local SCALAR_TYPES = {
	boolean = "bool",
	number = "double",
	integer = "long",
	int8 = "sbyte",
	int16 = "short",
	int32 = "int",
	int64 = "long",
	uint8 = "byte",
	uint16 = "ushort",
	uint32 = "uint",
	uint64 = "ulong",
	float32 = "float",
	float64 = "double",
	string = "string",
	void = "void",
	null = "void",
} --[[: { [string]: string }]]

-- Single-entry lattice probes for the two marshaling gates below.
--
-- TYPECHECKER WORKAROUND: the TS writes these inline as `resolve(kind,
-- { boolean: true }) === true` — a presence test against a one-entry handler
-- map. Here they are `{ [string]: string }` maps tested with `~= nil` instead,
-- so that all three `type_ref.resolve` call sites in this file instantiate its
-- `<T>` at the SAME type. The natural code is a `{ [string]: boolean }` probe
-- next to the `{ [string]: string }` `SCALAR_TYPES` lookup; that does not
-- typecheck — a generic function's type variable is solved once per FILE, not
-- once per call site, so whichever call is reached first pins `<T>` and the
-- others are checked against it ("argument 2: cannot pass
-- `{ [string]: string }` where `{ [string]: true }` expected"). TODO.md
-- records this for stdlib generics (`table.remove`/`table.sort` pinned by an
-- earlier call in the same file); it applies identically to a project-declared
-- generic like `type_ref.resolve`. The presence test is semantically the same
-- either way — the marker VALUE is never read, only its presence. Revert to a
-- boolean probe once each call site instantiates the generic freshly.
local BOOLEAN_PROBE = { boolean = "boolean" } --[[: { [string]: string }]]
local STRING_PROBE = { string = "string" } --[[: { [string]: string }]]

-- True for the `boolean` kind (or a registered descendant of it) under
-- `copy`/unset ownership — the gate for whether `[MarshalAs(UnmanagedType.U1)]`
-- is required (see the file header's bool-marshaling note). A resource
-- reference (any non-`copy` ownership discipline) is never a bool, so this
-- returns false for those without inspecting the structural kind.
--
-- `ownership_of` is how `meta.ownership` is read: it returns the discipline
-- table, or nil for an unannotated position — which every backend treats as
-- `copy`, hence the `discipline ~= nil and` guard rather than a nil branch of
-- its own.
--: (ref: TypeRef) -> boolean
local function is_bool_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil and discipline.kind ~= "copy" then return false end
	return type_ref.resolve(ref.shape.kind, BOOLEAN_PROBE) ~= nil
end

-- True for the `string` kind (or descendant) under `copy`/unset ownership —
-- the gate for whether `StringMarshalling = StringMarshalling.Utf8` is added to
-- a declaration's `[LibraryImport(...)]` attribute (see the file header's
-- string-marshaling note).
--: (ref: TypeRef) -> boolean
local function is_string_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil and discipline.kind ~= "copy" then return false end
	return type_ref.resolve(ref.shape.kind, STRING_PROBE) ~= nil
end

-- The C# type for one boundary position (a parameter's or return's TypeRef),
-- applying this target's ownership rule (see the file header's
-- "Ownership-discipline scope" section):
--
--   - no `meta.ownership` at all, or `{ kind = "copy" }` — the flat scalar
--     mapping in `SCALAR_TYPES`, with an ancestor fallback for a kind not
--     directly listed (e.g. a further subtype an extension module registers
--     under one of these). Any structural kind outside that table reports an
--     error — see the file header's "one case this file DOES fail for", and
--     its KNOWN GAP note for which kinds currently reach that error only
--     because `kinds/common` is unported.
--   - `{ kind = "opaque-handle" }` / `{ kind = "refcount" }` /
--     `{ kind = "resource", mode = ... }` — `IntPtr`, uniformly, regardless of
--     which of the three (the header explains why this is not a
--     marshaling-level distinction).
--: (ref: TypeRef) -> (string | nil, string | nil)
local function to_dotnet_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil and discipline.kind ~= "copy" then return "IntPtr" end

	local kind = ref.shape.kind
	local direct = SCALAR_TYPES[kind]
	if direct ~= nil then return direct end
	local via_ancestor = type_ref.resolve(kind, SCALAR_TYPES)
	if via_ancestor ~= nil then return via_ancestor end

	return nil,
		'to_dotnet_type: unsupported type-ir kind "' .. kind .. '" for the .NET/P-Invoke target — this backend implements only the flat ' ..
		"scalar kinds (boolean/number/integer/int8..64/uint8..64/float32/float64/string/void/null) under copy/unset ownership, plus " ..
		'resource references carrying non-"copy" ownership metadata (rendered as IntPtr regardless of discipline — see this file\'s ' ..
		"header). Structural kinds (object/array/map/tuple/union/enum/intersection/interface, or a bare ref with no ownership metadata) " ..
		"would require a matching repr(C)-equivalent C# struct declaration this backend does not generate (no producer-side " ..
		"struct-layout projector exists yet to verify such a struct against)."
end

M.to_dotnet_type = to_dotnet_type

-- ── Declaration builders ─────────────────────────────────────────────────────

-- The `/// <summary>` doc comment for a meta bag carrying a string
-- `description`, or no lines at all when it does not. The bag is open, so a
-- value under that key that is not a string is simply not a doc comment.
--: (meta: Meta) -> string[]
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return {} end
	return { "/// <summary>" .. description .. "</summary>" }
end

-- The synthesized receiver parameter a `method` declaration is given. Held as
-- a `string`-typed constant rather than written inline at its (conditional,
-- first) append below, so the list it is appended to is not inferred as a list
-- of that one literal — every later append is an ordinary computed `string`.
local RECEIVER_PARAM_DECL = "IntPtr handle" --: string

-- One `[LibraryImport]`-annotated `internal static partial` method for a
-- `function`/`method` shape. `self_param`, when given, prepends a synthesized
-- `IntPtr handle` receiver parameter (mirroring `c-abi`'s own
-- `selfParam`-driven receiver synthesis for the exact same reason: ffi-ir's
-- `method` kind names its receiver by resource name only, carrying no
-- parameter of its own). Only its PRESENCE is read — the receiver's name never
-- appears in the emitted declaration, since the synthesized parameter is always
-- spelled `handle`; the name is passed anyway so call sites read as "this is a
-- method on X", exactly as the TS does.
--
-- Method/parameter naming: kept as the EXACT native symbol/parameter name (not
-- PascalCased) per "Native interoperability best practices"'s own guidance
-- ("DO use the same naming and capitalization for your methods and parameters
-- as the native method you want to call") — `fn_name` here is already the
-- snake_case symbol `c-abi` emits for the paired producer side (see the
-- `to_snake_case` calls at each call site below), so this function does not
-- reformat it. `EntryPoint` is still set explicitly (defensive, doesn't rely on
-- any implicit exact-spelling assumption) even though it equals the method's
-- own escaped name in every case emitted here.
--: (fn_name: string, ref: FfiRef, shape: FfiFunctionLike, library_name: string, self_param: string | nil) -> (string | nil, string | nil)
local function build_function(fn_name, ref, shape, library_name, self_param)
	local param_decls = {}
	local n = 0
	if self_param ~= nil then
		n = n + 1
		param_decls[n] = RECEIVER_PARAM_DECL
	end
	for i = 1, #shape.params do
		local p = shape.params[i]
		local ident = escape_csharp_ident(p.name)
		local marshal_as = ""
		if is_bool_type(p.type) then marshal_as = "[MarshalAs(UnmanagedType.U1)] " end
		local cs_type, type_err = to_dotnet_type(p.type)
		if cs_type == nil then return nil, type_err end
		n = n + 1
		param_decls[n] = marshal_as .. cs_type .. " " .. ident
	end

	-- `void`/`null` short-circuit ahead of the scalar mapping: a void return is
	-- not a marshaled value at all, so neither the string nor the bool gate
	-- applies to it.
	local return_kind = shape.returnType.shape.kind
	local is_void_return = return_kind == "void" or return_kind == "null"
	local return_type = "void"
	if not is_void_return then
		local mapped, return_err = to_dotnet_type(shape.returnType)
		if mapped == nil then return nil, return_err end
		return_type = mapped
	end

	local has_string = false
	for i = 1, #shape.params do
		if is_string_type(shape.params[i].type) then has_string = true end
	end
	if not is_void_return and is_string_type(shape.returnType) then has_string = true end
	local return_is_bool = not is_void_return and is_bool_type(shape.returnType)

	local attr_args = { quote(library_name), "EntryPoint = " .. quote(fn_name) }
	if has_string then attr_args[3] = "StringMarshalling = StringMarshalling.Utf8" end

	local lines = {}
	local m = 0
	local doc = doc_comment(ref.meta)
	for i = 1, #doc do
		m = m + 1
		lines[m] = doc[i]
	end
	m = m + 1
	lines[m] = "[LibraryImport(" .. table.concat(attr_args, ", ") .. ")]"
	if return_is_bool then
		m = m + 1
		lines[m] = "[return: MarshalAs(UnmanagedType.U1)]"
	end
	m = m + 1
	lines[m] = "internal static partial " .. return_type .. " " .. escape_csharp_ident(fn_name) ..
		"(" .. table.concat(param_decls, ", ") .. ");"
	return table.concat(lines, "\n")
end

-- The paired free-function declaration for a resource. `c-abi`'s own
-- `buildResource` ALWAYS emits a `<resource>_free(handle: *mut T)` Rust
-- function for every resource (regardless of whether the `opaque-handle`
-- discipline's `freeFn` names one explicitly), so this backend always emits the
-- matching P/Invoke declaration too, to stay paired 1:1 with what the producer
-- guarantees to export.
--: (free_fn_name: string, library_name: string) -> string
local function build_free_function(free_fn_name, library_name)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = "[LibraryImport(" .. quote(library_name) .. ", EntryPoint = " .. quote(free_fn_name) .. ")]"
	n = n + 1
	lines[n] = "internal static partial void " .. escape_csharp_ident(free_fn_name) .. "(IntPtr handle);"
	return table.concat(lines, "\n")
end

-- The `shape` parameter is typed as a kind-free structural VIEW rather than as
-- ffi_ir's `FfiResourceShape`: a checked cast from the open `FfiShape`
-- (`{ kind: string, ... }`) to a shape whose `kind` is the literal
-- `"resource"` is rejected, since `string` is not assignable to a string
-- literal. Reading fields off an open shape through an inline structural cast
-- is the existing precedent (`type_ref.lua`'s `resolve_ref`, `ffi_ir_test.lua`),
-- and `ffi_ir.lua`'s own `FfiFunctionLike` is the same idea given a name.
--: (name: string, ref: FfiRef, shape: { methods: { [string]: FfiRef }, ... }, library_name: string) -> (string | nil, string | nil)
local function build_resource(name, ref, shape, library_name)
	local resource_snake = to_snake_case(name)
	local decls = {}
	local n = 0

	local method_names = ordered_keys(shape.methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = shape.methods[method_name]
		if method_ref ~= nil then
			local method_shape = method_ref.shape --[[: FfiFunctionLike]]
			local fn_name = resource_snake .. "_" .. to_snake_case(method_name)
			local src, err = build_function(fn_name, method_ref, method_shape, library_name, name)
			if src == nil then return nil, err end
			n = n + 1
			decls[n] = src
		end
	end

	n = n + 1
	decls[n] = build_free_function(resource_snake .. "_free", library_name)

	local body = table.concat(decls, "\n\n")
	local lines = {}
	local m = 0
	local doc = doc_comment(ref.meta)
	for i = 1, #doc do
		m = m + 1
		lines[m] = doc[i]
	end
	local class_lines = {
		"// Handle representation: IntPtr, uniformly, for every ownership discipline",
		"// a reference to this resource might carry (opaque-handle/refcount/",
		"// resource own-or-borrow) — see this file's header for why that's a",
		"// caller-side bookkeeping distinction, not a marshaling one. Call the",
		"// paired " .. quote(resource_snake .. "_free") .. " export exactly once per handle",
		"// when using the opaque-handle discipline's manual-free convention.",
		"internal static partial class " .. name,
		"{",
		indent(body, nil),
		"}",
	}
	for i = 1, #class_lines do
		m = m + 1
		lines[m] = class_lines[i]
	end
	return table.concat(lines, "\n")
end

-- `shape` is a kind-free structural view for the same reason `build_resource`'s
-- is; see its comment.
--: (name: string, shape: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }, library_name: string) -> (string | nil, string | nil)
local function build_module(name, shape, library_name)
	local decls = {}
	local n = 0

	-- Resources first, then free functions — the TS concatenation order.
	local resource_names = ordered_keys(shape.resources)
	for i = 1, #resource_names do
		local res_ref = shape.resources[resource_names[i]]
		if res_ref ~= nil then
			-- The resource's own `name` field wins over its key in the map,
			-- matching `c-abi`'s identical "a resource carries its own name"
			-- convention.
			local res_shape = res_ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
			local src, err = build_resource(res_shape.name, res_ref, res_shape, library_name)
			if src == nil then return nil, err end
			n = n + 1
			decls[n] = src
		end
	end

	local function_names = ordered_keys(shape.functions)
	for i = 1, #function_names do
		local key = function_names[i]
		local fn_ref = shape.functions[key]
		if fn_ref ~= nil then
			local fn_shape = fn_ref.shape --[[: FfiFunctionLike]]
			local src, err = build_function(to_snake_case(key), fn_ref, fn_shape, library_name)
			if src == nil then return nil, err end
			n = n + 1
			decls[n] = src
		end
	end

	local body = table.concat(decls, "\n\n")
	local lines = {}
	local m = 0
	local file_lines = {
		"using System;",
		"using System.Runtime.InteropServices;",
		"",
		"internal static partial class " .. to_pascal_case(name),
		"{",
		indent(body, nil),
		"}",
	}
	for i = 1, #file_lines do
		m = m + 1
		lines[m] = file_lines[i]
	end
	return table.concat(lines, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to `[LibraryImport]`-annotated C#/.NET P/Invoke
-- source — the consumer side that calls INTO the shared library `c-abi`'s Rust
-- output produces (see the file header for the full attribute/marshaling
-- rationale).
--
--   - `function` -> a top-level `[LibraryImport]` declaration (requires `name`
--     and `library_name` — see below).
--   - `method` -> the same, plus a synthesized `IntPtr handle` first parameter
--     and a `<receiver>_<method>` entry point, matching `c-abi`'s own naming
--     (requires `name`, the method's own key, and `library_name`).
--   - `resource` -> a nested `static partial class` grouping the resource's
--     method declarations plus its always-paired `<resource>_free` declaration
--     (requires `library_name`; the `name` argument, if given, is IGNORED in
--     favor of the shape's own `name` field, matching `c-abi`'s identical
--     "a resource carries its own name" convention).
--   - `module` -> a `static partial class` (PascalCased from the module name)
--     grouping all contained functions/resources, with the `System`/
--     `System.Runtime.InteropServices` `using` directives a standalone C# file
--     emitting this needs. `library_name` defaults to the module's own `name`
--     when not given (the natural "one module -> one native library" default;
--     override when the native library's filename differs from the ffi-ir
--     module's logical name).
--
-- `library_name` (the native shared library `[LibraryImport]`'s first argument
-- names, e.g. `"my_native_lib"` for `libmy_native_lib.so`) has no
-- ffi-ir-schema equivalent — it's a consumer-side loading detail the producer
-- side doesn't carry — so it's a required argument for
-- `function`/`method`/`resource` (there is no enclosing module to default it
-- from) and an optional override for `module`.
--: (ref: FfiRef, name: string | nil, library_name: string | nil) -> (string | nil, string | nil)
function M.to_dotnet(ref, name, library_name)
	local kind = ref.shape.kind

	if kind == "function" then
		if name == nil then
			return nil, 'to_dotnet: "function" requires a name — a P/Invoke declaration is a named symbol, not an anonymous inline type'
		end
		if library_name == nil then
			return nil,
				'to_dotnet: "function" requires a libraryName (the native shared library to load) when projected standalone — pass it ' ..
				'explicitly, or project the enclosing "module" instead, which defaults it from the module\'s own name'
		end
		local shape = ref.shape --[[: FfiFunctionLike]]
		return build_function(to_snake_case(name), ref, shape, library_name)
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_dotnet: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		if library_name == nil then
			return nil,
				'to_dotnet: "method" requires a libraryName (the native shared library to load) when projected standalone — pass it ' ..
				'explicitly, or project the enclosing "module" instead'
		end
		local shape = ref.shape --[[: { params: FfiParam[], returnType: TypeRef, receiver: string, ... }]]
		local fn_name = to_snake_case(shape.receiver) .. "_" .. to_snake_case(name)
		return build_function(fn_name, ref, shape, library_name, shape.receiver)
	end

	if kind == "resource" then
		if library_name == nil then
			return nil,
				'to_dotnet: "resource" requires a libraryName (the native shared library to load) when projected standalone — pass it ' ..
				'explicitly, or project the enclosing "module" instead'
		end
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		return build_resource(shape.name, ref, shape, library_name)
	end

	if kind == "module" then
		local shape = ref.shape --[[: { name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		return build_module(shape.name, shape, library_name or shape.name)
	end

	return nil, 'to_dotnet: unhandled ffi-ir kind "' .. kind .. '" — no .NET P/Invoke mapping implemented for this backend'
end

return M
