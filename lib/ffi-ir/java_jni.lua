-- lib/ffi-ir/java_jni.lua — the JNI (Java Native Interface) projector,
-- ported from fractal's packages/ffi-ir/src/java-jni.ts.
--
-- This emits the Java-side `native` method declaration surface for calling
-- into native code — the human-facing counterpart of ReScript's `external` /
-- Gleam's `@external` / the C ABI's `extern "C" fn` — NOT the auto-generated
-- `JNIEnv*`/`jobject`-shaped C glue header.
--
-- The findings below are the TS source's own, verified by its author on
-- 2026-08-03 and reproduced here because they are the reasoning behind every
-- mapping choice in this file. They were NOT re-verified by this port.
--
-- WHY JNI IS ITS OWN BACKEND rather than a reuse of the C-ABI one
-- [VERIFIED-EXTERNAL: docs.oracle.com/en/java/javase/17/docs/specs/jni/
-- design.html]: a native method is declared in Java as `native ReturnType
-- name(Params...);`; the corresponding native function's REQUIRED first two
-- parameters are `JNIEnv *env` plus `jobject`/`jclass` (the implicit
-- receiver), with the function's exact C name deterministically derived from
-- the fully-qualified class + method name (`Java_p_q_r_A_f`, or with a
-- `__<descriptor>` suffix for overloads). That signature shape — `JNIEnv*`,
-- opaque `jobject`/`jclass`/`jstring` handles, VM-managed reference lifetime
-- — has no analogue in a plain `extern "C"` function signature. JNI is not
-- "a C-ABI library plus a loader"; it is a distinct glue-generation target.
--
-- HEADER GENERATION IS GENUINELY AUTOMATIC TOOLING [VERIFIED-EXTERNAL:
-- docs.oracle.com javah history + JDK 8 `javac -h` documentation]: `javac -h
-- <dir>` (the JDK 8+ replacement for the deprecated standalone `javah`)
-- generates the `JNIEnv*`-shaped C header directly from a compiled class's
-- `native` method declarations. Exactly as the C-ABI backend does not emit
-- the cbindgen-generated C header, this file emits ONLY the Java-side
-- `native` declarations — the `javac -h` header is a downstream artifact of
-- compiling them, not something fractal emits here.
--
-- RESOURCE IDIOM — verified, not assumed identical to C's opaque pointer
-- [VERIFIED-EXTERNAL: developer.android.com/training/articles/perf-jni,
-- "64-bit considerations"]: "To support architectures that use 64-bit
-- pointers, use a `long` field rather than an `int` when storing a pointer to
-- a native structure in a Java field." This is a DIFFERENT mechanism from
-- JNI's own `jobject`/local-ref/global-ref reference-type system (VM-managed
-- handles into a per-thread reference table, freed automatically on
-- native-method return for locals, requiring explicit `NewGlobalRef`/
-- `DeleteGlobalRef` for anything outstanding beyond one call). That system
-- governs how the JVM tracks *Java objects* handed to native code — a
-- GC-safety concern with no free/ownership decision for ffi-ir to make at all
-- (the VM handles it unconditionally). The native-pointer-as-a-long-field
-- idiom is the one with a citable, established convention answering the
-- question ffi-ir's ownership vocabulary actually asks ("how does a
-- native-owned resource cross the boundary"), so that is what `build_resource`
-- below implements — a `private long nativeHandle;` field on a generated
-- wrapper class, not an attempt to reproduce jobject/local-ref semantics
-- (which `OwnershipDiscipline` was never modeling in the first place).
--
-- OWNERSHIP-DISCIPLINE COVERAGE (see `OwnershipDiscipline` in init.lua) —
-- mirrors the C-ABI backend's decided split exactly, for closely related
-- reasons:
--   - `copy` (or no ownership metadata at all) — a plain by-value primitive /
--     String / byte[], via `to_jni_type` below.
--   - `opaque-handle` — the long-native-pointer-field idiom verified above:
--     an opaque handle crossing as a bare value (a parameter, a return, or
--     the resource wrapper class's own internal field) is rendered as Java's
--     `long`. This is the closest real match to the C-ABI backend's
--     `*mut T` -> raw pointer mapping, just wearing a fixed-width integer
--     instead of a pointer type, per the Android-documented convention.
--   - `refcount` — reported as unsupported, same as the C-ABI backend. No
--     native JNI/JVM mechanism performs shared reference counting at the
--     boundary; Java's own GC-triggered cleanup facilities (`finalize()`,
--     `java.lang.ref.Cleaner`) are a single-owner "run this when the JVM
--     decides to collect it" callback, not an increment/decrement shared-count
--     discipline — forcing that into "refcount" would be inventing a mapping
--     with no citable convention, not reporting an established one.
--   - `resource` (own/borrow) — reported as unsupported. That mode is WIT's
--     own Canonical-ABI per-instance handle-table + lend-count-and-trap
--     mechanism; nothing in the JNI spec or the Android NDK docs enforces an
--     own/borrow distinction or traps on a lend-count violation — the same
--     "no native mechanism" reasoning the C-ABI backend already applies to
--     this exact discipline. `ffi_ir.resource_ref(...)` (which sets
--     `ownership.resource(mode)` by convention) is therefore NOT the right
--     constructor to reach for when targeting JNI; this file's test suite
--     uses a local `handle_ref` helper built on `ownership.opaque_handle()`
--     instead, mirroring the C-ABI backend's tests.
--
-- TYPE MAPPING IS INTENTIONALLY MINIMAL, per the source's own scope: Java's
-- primitive vocabulary (`boolean`, `int`/`long`, `float`/`double`) plus
-- `String` and `byte[]` for the `bytes` kind. Bare `integer`/`number` (no
-- declared width) default to the WIDEST native form (`long`/`double`),
-- matching the same "no width info -> widest safe default" precedent type-ir's
-- own C++/nlohmann projector documents for its bare-`integer` case;
-- `int32`/`int64`/`float32`/`float64` (type-ir's optional fixed-width
-- extension kinds) map to their exact-width Java counterpart when used.
--
-- NAMING. Unlike the C-ABI backend (free to rewrite an exported symbol's
-- spelling to snake_case with no external constraint) or the ReScript backend
-- (whose `external` syntax keeps the ReScript-side identifier and the JS-side
-- string-literal target independently spellable), a JNI `native` method's Java
-- name and its JNI-mandated linkable C symbol name are THE SAME STRING,
-- deterministically derived (verified above) — there is no separate "wire
-- name" to decouple through. This file therefore does NOT camelCase- or
-- snake_case-transform an incoming name; it only sanitizes characters that
-- would not compile as a Java identifier and escapes exact Java reserved
-- words, since either would otherwise be a hard compile error, not a style
-- preference.
--
-- ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
-- `(nil, errmsg)` return here, the same conversion `lib/type-ir/init.lua`'s
-- `resolve_ref` applies to its own source's throw: an unsupported discipline,
-- an unmappable data shape, or a missing name is a data error, not a
-- programming error. This propagates — the internal builders below return
-- `(nil, errmsg)` too, and every caller checks.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of lib/type-ir/init.lua's
-- own declarations, reached transitively through the `require` above (every
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

-- ── Identifiers and literals ─────────────────────────────────────────────────

-- Every exact Java reserved word, plus the three reserved literals
-- (`true`/`false`/`null`), which are likewise not usable as identifiers.
--
-- Built by loop from a list rather than written as a table literal because
-- nine of these words (`break`, `do`, `else`, `for`, `if`, `return`, `true`,
-- `false`, `while`) are ALSO Lua keywords and cannot appear as bare
-- table-literal keys; a mixed literal of bare and bracket-quoted keys would
-- obscure that this is one flat set.
local JAVA_RESERVED_WORDS = {
	"abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
	"continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
	"for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native",
	"new", "package", "private", "protected", "public", "return", "short", "static", "strictfp",
	"super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void",
	"volatile", "while", "true", "false", "null",
} --[[: { [integer]: string } ]]

local JAVA_RESERVED = {} --[[: { [string]: boolean }]]
for i = 1, #JAVA_RESERVED_WORDS do
	JAVA_RESERVED[JAVA_RESERVED_WORDS[i]] = true
end

-- A valid Java identifier for `name` — replaces characters that cannot appear
-- in a Java identifier, prefixes a leading digit, and escapes exact Java
-- reserved words. Deliberately NOT a casing transform (see the file header: a
-- `native` method's Java name IS the linkable JNI symbol name, so this file
-- does not rewrite spelling beyond what is needed to compile).
--
-- `$` is a legal Java identifier character, hence its presence in both the
-- allowed-character class and the allowed-first-character class.
--: (name: string) -> string
local function sanitize_ident(name)
	local cleaned = (name:gsub("[^A-Za-z0-9_%$]", "_"))
	local based = cleaned
	if cleaned:match("^[A-Za-z_%$]") == nil then
		based = "_" .. cleaned
	end
	if JAVA_RESERVED[based] then return based .. "_" end
	return based
end

-- The Java class-name convention: split at a lower/digit-to-upper boundary and
-- at every run of non-alphanumerics, then uppercase each word's first
-- character and LOWERCASE its remainder (`read_file` -> `ReadFile`,
-- `HTTPClient` -> `Httpclient`). The lowercasing of the tail is the TS
-- source's own behavior (`w.charAt(0).toUpperCase() + w.slice(1).
-- toLowerCase()`) and is reproduced rather than corrected — this projector is
-- a port, and diverging would make it emit different Java than its source.
--: (name: string) -> string
local function to_pascal_case(name)
	local spaced = (name:gsub("([a-z0-9])(%u)", "%1 %2"))
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	-- The TS source splits on `/[^a-zA-Z0-9]+/` and drops empty pieces, which
	-- is exactly a match over maximal alphanumeric runs.
	for word in spaced:gmatch("[a-zA-Z0-9]+") do
		n = n + 1
		out[n] = word:sub(1, 1):upper() .. word:sub(2):lower()
	end
	return table.concat(out)
end

-- Characters that must be escaped inside a double-quoted string literal, and
-- their replacements. This reproduces the TS source's `JSON.stringify`, which
-- is what it uses to emit the `System.loadLibrary` argument. Java's string
-- literal escape syntax accepts all of these, and the `\uXXXX` fallback below,
-- unchanged.
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

-- `value` as a double-quoted Java string literal.
--: (value: string) -> string
local function quote(value)
	local escaped = (value:gsub('[%c"\\]', escape_char))
	return '"' .. escaped .. '"'
end

-- ── Layout ───────────────────────────────────────────────────────────────────

-- The TS source's `indent` helper: prefix every NON-EMPTY line of `block`,
-- leaving blank lines genuinely blank (no trailing whitespace). `prefix`
-- defaults to four spaces, the source's own default and the prefix every call
-- site in this file relies on — Java nesting depth in the emitted output is
-- entirely a product of how many times a block passes through here.
--
-- Unlike the Ruby backend's per-entry indentation, this indents per LINE, so a
-- multi-line declaration (one carrying a doc comment, say) has every one of
-- its lines indented. That is the TS source's behavior, and it matters here in
-- a way it does not there: Java is written with meaningful nesting even though
-- the compiler ignores it.
--: (block: string, prefix: string | nil) -> string
local function indent(block, prefix)
	local pre = prefix or "    "
	local out = {} --[[: { [integer]: string } ]]
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

-- The `/** ... */` doc-comment PREFIX for a meta bag — including its trailing
-- newline, so a caller concatenates it directly onto the declaration it
-- documents — or the empty string when `description` is absent or not a
-- string.
--: (meta: Meta) -> string
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return "" end
	return "/** " .. description .. " */\n"
end

-- A record's keys in a deterministic (byte) order.
--
-- The TS source iterates `Object.entries(...)`, i.e. JS insertion order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make the
-- order of the emitted method and function declarations vary between runs.
-- Byte order is the deterministic stand-in — the same substitution, for the
-- same reason, that lib/type-ir/init.lua's own `ordered_keys` makes. The emitted SET
-- of declarations is identical either way.
--: (tbl: { [string]: unknown }) -> string[]
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

-- The Java-declaration-surface type for one boundary position (a parameter's
-- or return's `TypeRef`), applying the JNI target's ownership rule (see the
-- file header):
--   - `opaque-handle` — Java's `long` (the Android-documented
--     native-pointer-field idiom), regardless of the referenced type-ir
--     shape's own kind: an opaque handle is opaque, and its Rust/C++-side
--     layout is not Java's concern.
--   - `refcount` / `resource` (own/borrow) — reported as unsupported, with
--     the per-discipline reasoning in the message.
--   - no ownership metadata, or `copy` — the minimal
--     boolean/integer/number/string/bytes/void mapping below.
--
-- `ownership_of` returns nil for an unannotated position, which is read as
-- `copy` — an unannotated value crosses by value.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.to_jni_type(ref)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline ~= nil then
		if discipline.kind == "opaque-handle" then return "long" end
		if discipline.kind == "refcount" then
			return nil,
				'to_jni_type: unsupported ownership discipline "refcount" for JNI target — no native JNI/JVM '
					.. "shared-refcount mechanism (Java's GC-triggered finalize()/Cleaner is a single-owner collection "
					.. "callback, not reference counting; see java_jni.lua's file header)"
		end
		if discipline.kind == "resource" then
			return nil,
				'to_jni_type: unsupported ownership discipline "resource" for JNI target — WIT-only own/borrow '
					.. "lend-count-and-trap mechanism, no citable JNI/Android NDK convention enforces it (see "
					.. "java_jni.lua's file header; use ownership.opaque_handle() instead)"
		end
		-- "copy" falls through to the plain mapping below.
	end

	local kind = ref.shape.kind
	if kind == "boolean" then return "boolean" end
	if kind == "integer" then return "long" end
	if kind == "int32" then return "int" end
	if kind == "int64" then return "long" end
	if kind == "number" then return "double" end
	if kind == "float32" then return "float" end
	if kind == "float64" then return "double" end
	if kind == "string" then return "String" end
	if kind == "bytes" then return "byte[]" end
	if kind == "void" or kind == "null" then return "void" end

	return nil,
		'to_jni_type: unsupported type-ir kind "' .. kind .. '" for JNI target — this minimal projector maps only '
			.. "boolean/integer(+int32/int64)/number(+float32/float64)/string/bytes/void to Java's "
			.. "native-declaration vocabulary"
end

-- ── Declaration builders ─────────────────────────────────────────────────────

-- One `native` method declaration. `is_static` distinguishes a module-level
-- free function (`public static native`, no receiver) from a resource method
-- (`public native`, no `static` — the receiver is JNI's own implicit `jobject
-- this`, requiring NO explicit handle parameter in the Java-side declaration,
-- unlike the C-ABI backend's synthesized `handle: *mut T` first parameter for
-- the same case: JNI supplies the receiver itself, per the Oracle spec's
-- documented native-function signature shape cited in the file header).
--: (java_name: string, ref: FfiRef, shape: FfiFunctionLike, is_static: boolean) -> (string | nil, string | nil)
local function build_decl(java_name, ref, shape, is_static)
	local params = {} --[[: { [integer]: string } ]]
	for i = 1, #shape.params do
		local param = shape.params[i]
		local mapped, err = M.to_jni_type(param.type)
		if mapped == nil then return nil, err end
		params[i] = mapped .. " " .. sanitize_ident(param.name)
	end

	local return_type, return_err = M.to_jni_type(shape.returnType)
	if return_type == nil then return nil, return_err end

	local modifiers = is_static and "public static native" or "public native"
	return doc_comment(ref.meta)
		.. modifiers
		.. " "
		.. return_type
		.. " "
		.. sanitize_ident(java_name)
		.. "("
		.. table.concat(params, ", ")
		.. ");"
end

-- A resource -> a Java class holding a `private long nativeHandle;` field (the
-- Android-documented native-pointer-field idiom, see the file header) plus one
-- instance `native` method per entry in `shape.methods`. `is_nested`, when
-- true, adds `static` to the class modifier (used when this resource is
-- emitted inside an enclosing module's wrapper class — a Java nested class
-- needs `static` to avoid an implicit, unwanted enclosing-instance reference;
-- a top-level resource class needs no such modifier).
--
-- Deliberately does NOT synthesize a constructor: ffi-ir's `resource` kind
-- carries only a `methods` map, no separate constructor field — the same gap
-- the C-ABI, ReScript, and wasm-bindgen backends already document and decline
-- to invent one for, rather than guessing at a constructor signature the
-- schema does not express.
-- `methods` is taken directly rather than the whole resource shape: a cast
-- from the open `FfiShape` to the CLOSED `FfiResourceShape` alias (whose
-- `kind` is the literal `"resource"`) is rejected, since a `kind: string` does
-- not narrow to a literal on the strength of an `if` on a copied-out local.
-- Every call site therefore casts to an open structural type and passes the
-- fields out, the same formulation the Ruby backend settled on.
--: (name: string, ref: FfiRef, methods: { [string]: FfiRef }, is_nested: boolean) -> (string | nil, string | nil)
local function build_resource(name, ref, methods, is_nested)
	local class_modifiers = is_nested and "public static class" or "public class"

	local method_decls = {} --[[: { [integer]: string } ]]
	local method_names = ordered_keys(methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = methods[method_name]
		local kind = method_ref.shape.kind
		if kind ~= "method" and kind ~= "function" then
			return nil,
				'to_jni_ffi: resource method "' .. method_name .. '" has unexpected kind "' .. kind
					.. '" (expected "method")'
		end
		local decl, err = build_decl(method_name, method_ref, method_ref.shape --[[: FfiFunctionLike]], false)
		if decl == nil then return nil, err end
		method_decls[i] = decl
	end

	-- The trailing empty entry after the `nativeHandle` field is the source's
	-- own blank separator line. With no methods at all, `concat` of an empty
	-- list is the empty string and `indent` leaves it empty, so the class body
	-- ends with two blank lines — reproduced rather than tidied, so this port
	-- emits byte-identical Java to its source.
	local lines = {
		doc_comment(ref.meta) .. class_modifiers .. " " .. name .. " {",
		"    private long nativeHandle;",
		"",
		indent(table.concat(method_decls, "\n\n"), nil),
		"}",
	} --[[: { [integer]: string } ]]
	return table.concat(lines, "\n")
end

-- A module -> a `public class ModuleName { ... }` grouping the module's static
-- native functions and nested resource classes, plus a `static {
-- System.loadLibrary("..."); }` block — the standard JNI idiom for loading the
-- backing native library before any native method on the class is invoked.
--
-- NAMING JUDGMENT CALL, flagged by the TS source rather than made silently and
-- carried over unchanged here: ffi-ir's `FfiModuleShape.name` carries no field
-- distinguishing "a Java class name" from "a native shared-library name"
-- (conventionally DIFFERENT strings — class `MyModule` loading library
-- `"mymodule"`, without the platform's `lib`/`.so`/`.dll` decoration, which
-- `System.loadLibrary` itself adds). This projector uses the SAME `name` for
-- both the generated class (PascalCased) and the `loadLibrary` argument
-- (passed through verbatim, undecorated) since the schema gives no second name
-- to draw the library name from — the same kind of naming gap the ReScript
-- backend flags for its own `@module`-vs-`@val` judgment call.
-- `functions`/`resources` are taken directly rather than the whole module
-- shape, for the same reason `build_resource` takes `methods` — see there.
--: (name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }) -> (string | nil, string | nil)
local function build_module(name, functions, resources)
	local class_name = to_pascal_case(name)

	local body = { "static {\n    System.loadLibrary(" .. quote(name) .. ");\n}" } --[[: { [integer]: string } ]]
	local n = 1

	local fn_names = ordered_keys(functions)
	for i = 1, #fn_names do
		local fn_name = fn_names[i]
		local fn_ref = functions[fn_name]
		local kind = fn_ref.shape.kind
		if kind ~= "function" and kind ~= "method" then
			return nil,
				'to_jni_ffi: module function "' .. fn_name .. '" has unexpected kind "' .. kind
					.. '" (expected "function")'
		end
		local decl, err = build_decl(fn_name, fn_ref, fn_ref.shape --[[: FfiFunctionLike]], true)
		if decl == nil then return nil, err end
		n = n + 1
		body[n] = decl
	end

	local res_names = ordered_keys(resources)
	for i = 1, #res_names do
		local res_name = res_names[i]
		local res_ref = resources[res_name]
		-- The nested class is named by the resource's KEY in the module's
		-- `resources` map, not by the resource shape's own `name` field — the
		-- TS source's `buildResource(resName, ...)`, carried over unchanged.
		local res_shape = res_ref.shape --[[: { methods: { [string]: FfiRef }, ... }]]
		local decl, err = build_resource(res_name, res_ref, res_shape.methods, true)
		if decl == nil then return nil, err end
		n = n + 1
		body[n] = decl
	end

	return "public class " .. class_name .. " {\n" .. indent(table.concat(body, "\n\n"), nil) .. "\n}"
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower one ffi-ir `FfiRef` to Java `native`-declaration source text.
--
--   function — `public static native ReturnType name(params...);`. A free
--              function has no JNI-implicit receiver, so it is emitted as a
--              static native method — the conventional JNI mapping for a
--              boundary entry point not tied to any resource. Requires
--              `name`: a Java native method is a named declaration, and a
--              free function's name lives as the key in the enclosing
--              `module.functions` map, not on the shape itself.
--   method   — `public native ReturnType name(params...);`, an instance
--              native method with no explicit receiver parameter (JNI
--              supplies it as the implicit `jobject this`). Requires `name`,
--              the method's own key in its resource's `methods` map.
--   resource — the wrapper-class-with-long-field group (see
--              `build_resource`). A `name` argument, if given, is IGNORED in
--              favor of the shape's own `name` field, matching the C-ABI
--              backend's identical precedent.
--   module   — the class-plus-loadLibrary group (see `build_module`), named
--              from the shape's own `name` field, so no `name` argument is
--              required.
--
-- Reports `(nil, errmsg)` for `refcount`/`resource`-discipline ownership
-- metadata anywhere in a crossed `TypeRef` (see `to_jni_type`) — the same
-- explicit report-don't-degrade pattern the C-ABI backend uses for the
-- disciplines it cannot realize on its own target.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_jni_ffi(ref, name)
	local kind = ref.shape.kind

	if kind == "function" then
		if name == nil then
			return nil,
				'to_jni_ffi: "function" requires a name — a Java native method is a named declaration, not an '
					.. "anonymous inline type"
		end
		return build_decl(name, ref, ref.shape --[[: FfiFunctionLike]], true)
	end

	if kind == "method" then
		if name == nil then
			return nil, 'to_jni_ffi: "method" requires a name — the method\'s own key in its resource\'s methods map'
		end
		return build_decl(name, ref, ref.shape --[[: FfiFunctionLike]], false)
	end

	if kind == "resource" then
		local shape = ref.shape --[[: { name: string, methods: { [string]: FfiRef }, ... }]]
		return build_resource(shape.name, ref, shape.methods, false)
	end

	if kind == "module" then
		local shape = ref.shape
			--[[: { name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		return build_module(shape.name, shape.functions, shape.resources)
	end

	return nil, 'to_jni_ffi: unhandled ffi-ir kind "' .. kind .. '" — no JNI mapping implemented for this backend'
end

return M
