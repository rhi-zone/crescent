-- lib/ffi-ir/ocaml_melange.lua — the Melange (https://melange.re)
-- `external`-declaration projector, ported from fractal's
-- packages/ffi-ir/src/ocaml-melange.ts.
--
-- TOOLCHAIN DETERMINATION (the TS source's first job, reproduced here because
-- it is the reasoning behind this file existing at all, not a detail of it):
-- "OCaml/Reason binds to JS" names TWO genuinely different, unrelated
-- toolchains, not one syntax with two names —
--
--   - js_of_ocaml (https://ocsigen.org/js_of_ocaml) — compiles a whole
--     (already-typed, already-compiled-from-OCaml) program to JS. Its
--     idiomatic FFI story, per its own `Js.Unsafe`/`Js.t` machinery (verified
--     by the TS source's author via web search against ocaml.org's published
--     `Js_of_ocaml.Js` API docs and a copy of `js.mli`, 2026-08-03 — the
--     ocsigen.org manual pages themselves were unreachable, DNS timeout from
--     that sandbox; NOT re-verified by this port), is either (a) hand-written
--     `class type ... = object method m : t1 -> t2 meth ... end` declarations
--     giving typed `Js.t` wrappers around JS objects, or (b) untyped
--     escape-hatch calls through `Js.Unsafe.meth_call`/`Js.Unsafe.global`/
--     `Js.Unsafe.inject`. Neither is a per-function *attribute* syntax
--     analogous to wasm-bindgen's `#[wasm_bindgen]` or WIT's declarative
--     shape — (a) requires synthesizing a class-type declaration (a materially
--     different generative shape from an annotated `external`), and (b) is
--     explicitly the "type safety isn't critical" low-level path, not the
--     documented primary binding idiom.
--   - Melange (https://melange.re, Reason's actively-maintained modern JS
--     backend, a BuckleScript fork) — binds via ordinary `external`
--     declarations plus a family of namespaced attributes (`[@mel.module]`,
--     `[@mel.send]`, `[@mel.get]`/`[@mel.set]`, `[@mel.new]`, `[@mel.scope]`,
--     `[@mel.obj]`), verified against melange.re's own "Communicate with
--     JavaScript" page (fetched 2026-08-03 by the TS source's author; the
--     concrete examples it yielded are reproduced in the per-function comments
--     below) — structurally the closest analog to the attribute-decorated
--     `external`/`#[wasm_bindgen]` precedent this family of projectors already
--     has siblings for, and the one this file follows most directly.
--
-- Given that structural match, THIS FILE implements Melange only. A
-- js_of_ocaml backend is a genuinely separate, differently-shaped piece of
-- work (either a class-type synthesizer or an untyped-call emitter) — not
-- implemented here, and flagged as such by the TS source rather than guessed
-- at.
--
-- ── Ownership-discipline scope for this target ───────────────────────────────
--
-- (See `OwnershipDiscipline` in init.lua. Melange's ownership story is NOT
-- the same as any sibling backend's; this is the TS source's own re-derivation
-- for this target, not a copy of another projector's.)
--
--   - `copy` (and the absent-`meta.ownership` default, which every backend
--     reads as copy) — a plain passthrough. Melange values erase to their
--     underlying JS representation at compile time; there is no
--     serialization/marshalling boundary the way wasm-bindgen's Rust<->JS
--     boundary has, so "copy" here means exactly "reference this TypeRef's
--     rendered type, do nothing else" — not an emitted `Clone`-equivalent
--     (Melange/OCaml has no such attribute to emit; value semantics are the
--     host language's own, unmodified).
--   - `opaque-handle` — Melange's own well-documented idiom for "a JS value
--     this binding treats as opaque, released via an explicit call": an
--     abstract `type t` (no representation exposed) plus, when `freeFn` is
--     given, a normal `[@mel.send]`-bound external for it (the same shape as
--     any other bound method — e.g. Node's `fs` file-descriptor `.close()`,
--     DOM `WebSocket.close()`). This is the discipline this target implements
--     NATIVELY, unlike wasm-bindgen (no manual-free idiom there) or WIT
--     (redundant with `resource`).
--   - `refcount` — REPORTED AS AN ERROR. Melange has no `Arc`/refcount-wrapper
--     construct and no bundled `FinalizationRegistry` pairing the way
--     wasm-bindgen's generated `.free()` gets one automatically; wiring a
--     `FinalizationRegistry` by hand is JS-interop glue code outside what an
--     `external` declaration can express, not a native Melange mechanism.
--   - `resource` (own/borrow) — REPORTED AS AN ERROR, the same reasoning the
--     WIT and wasm-bindgen backends both give: no host JS/Melange runtime
--     enforces a lend-count-and-trap discipline.
--
-- ── Data-shape coverage ──────────────────────────────────────────────────────
--
-- Data-shape (type-ir TypeRef -> Melange type syntax) coverage is DELIBERATELY
-- MINIMAL, the same scope-limiting call the WIT backend makes and documents
-- for the identical reason: no type-ir -> OCaml/Melange projector exists (the
-- TS side confirmed by listing packages/type-ir/src/ — only a ReScript-native
-- projector, a different toolchain/syntax, is present), and building the full
-- projector-equivalent OCaml/Melange data-shape lowering is separate,
-- not-yet-done work, out of scope for this file. What IS implemented:
-- primitives, `option`-equivalent (OCaml's native `'a option`, from
-- `meta.optional`/`meta.nullable`), `array` (OCaml `array`, not `list` —
-- matches JS's mutable-indexable-sequence semantics more closely than OCaml's
-- singly-linked `list`), `object` (hoisted to a named OCaml record — OCaml has
-- no anonymous inline record-type syntax), `enum` (hoisted to a named
-- no-payload variant), and `ref` (a resource name, referencing the abstract
-- `type t` generated for it — see `build_resource`).
--
-- ── Errors are returned, not thrown ──────────────────────────────────────────
--
-- Every `throw` in the TS source becomes a `(nil, errmsg)` return here, the
-- same conversion `lib/type-ir/init.lua`'s `resolve_ref` applies to its own source's
-- throw: an unsupported discipline or an out-of-subset kind is a data error,
-- not a programming error. This propagates — every internal builder below
-- returns `(nil, errmsg)` too, and every caller checks before using the value.
--
-- The rendering context (`Ctx`, below) is mutated as rendering proceeds, and a
-- failure deep inside type rendering can leave it half-populated (a reserved
-- fresh name and a recorded hoist mapping whose declaration was never
-- emitted). That is unobservable by design: the Ctx is created inside
-- `to_melange_ffi` and never escapes it, so a `(nil, errmsg)` return discards
-- the whole context along with the partial state. No caller can see a
-- partially-mutated Ctx, and no partial output is ever returned alongside an
-- error.
--
-- The TS source spells two error prefixes, `toMelange:` and `toMelangeFfi:`,
-- for what is one entry point; this port uses `to_melange_ffi:` uniformly
-- (naming a function that actually exists) and `ffi_ir_ocaml_melange:` where the TS
-- named its own file. The substance of each message — which discipline or kind
-- is unsupported on this target and why — is carried over unchanged.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of lib/type-ir/init.lua's
-- own declarations, reached transitively through the `require` above (every
-- ffi-ir signature this file touches names them). Duplicating a type
-- definition is normally forbidden outright; it is here only because the
-- checker cannot currently keep an imported alias resolvable through a
-- consumer — when a consumer (this file, and in turn its test) calls a
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

-- ── Deterministic map ordering ───────────────────────────────────────────────

-- A record's keys in byte order — the same deterministic stand-in for JS
-- property order `lib/type-ir/init.lua`'s own `ordered_keys` establishes, and for the
-- same reason: fractal's TS walks `Object.entries(...)` (string keys in
-- INSERTION order), which a Lua table cannot recover, so `pairs()` alone would
-- make field/member/declaration order vary between runs.
--
-- WELL-FORMEDNESS OF THE OUTPUT DOES NOT DEPEND ON THIS ORDER. The one place
-- OCaml requires a specific emission order is the hoisted top-level `type`
-- declarations, where a record type must be declared after the types its
-- fields mention. Those are accumulated in `ctx.decls`, a LIST appended in
-- generation order exactly as the TS array is (a nested hoist completes, and
-- appends, before its enclosing declaration does), so dependencies always
-- precede dependents regardless of what order sibling map entries are visited
-- in. Byte order therefore only permutes independent siblings: fields within
-- one record, members within one module's struct — neither of which OCaml
-- constrains.
--: <T>(tbl: { [string]: T }) -> { [integer]: string }
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

-- ── Naming ───────────────────────────────────────────────────────────────────

-- OCaml/Melange keywords that collide with a bare lowercase identifier —
-- OCaml's keyword list, which differs slightly from ReScript's.
local RESERVED = {
	["and"] = true, ["as"] = true, ["asr"] = true, ["assert"] = true, ["begin"] = true,
	["class"] = true, ["constraint"] = true, ["do"] = true, ["done"] = true, ["downto"] = true,
	["else"] = true, ["end"] = true, ["exception"] = true, ["external"] = true, ["false"] = true,
	["for"] = true, ["fun"] = true, ["function"] = true, ["functor"] = true, ["if"] = true,
	["in"] = true, ["include"] = true, ["inherit"] = true, ["initializer"] = true, ["land"] = true,
	["lazy"] = true, ["let"] = true, ["lor"] = true, ["lsl"] = true, ["lsr"] = true,
	["lxor"] = true, ["match"] = true, ["method"] = true, ["mod"] = true, ["module"] = true,
	["mutable"] = true, ["new"] = true, ["nonrec"] = true, ["object"] = true, ["of"] = true,
	["open"] = true, ["or"] = true, ["private"] = true, ["rec"] = true, ["sig"] = true,
	["struct"] = true, ["then"] = true, ["to"] = true, ["true"] = true, ["try"] = true,
	["type"] = true, ["val"] = true, ["virtual"] = true, ["when"] = true, ["while"] = true,
	["with"] = true,
} --[[: { [string]: boolean }]]

-- Sanitized fallback for an OCaml value/label name, which must start
-- lowercase-or-underscore. The three steps are the TS source's three, in
-- order: replace every non-identifier character with `_`, lowercase a leading
-- uppercase letter, and prefix `_` when the result still does not start with
-- a lowercase letter or underscore.
--
-- The TS spells a final `|| "_"` guard; it is unreachable there and omitted
-- here rather than carried over as dead code — the prefix step returns either
-- a non-empty `lowered` or `"_" .. lowered`, both non-empty for every input
-- including the empty string.
--
-- The TS guards the lowercasing step with `/^[A-Z]/.test(cleaned)`; this port
-- lowercases the leading character unconditionally, which is the same function
-- — `cleaned` contains only `[a-zA-Z0-9_]` by then, and `:lower()` is the
-- identity on every one of those that is not `A-Z`.
--: (name: string) -> string
local function sanitize_lower(name)
	local cleaned = name:gsub("[^a-zA-Z0-9_]", "_")
	local lowered = cleaned:sub(1, 1):lower() .. cleaned:sub(2)
	if lowered:match("^[a-z_]") ~= nil then return lowered end
	return "_" .. lowered
end

--: (name: string) -> string
local function ocaml_label(name)
	local label = sanitize_lower(name)
	if RESERVED[label] then return label .. "_" end
	return label
end

-- Word splitting for the case converters below. fractal reimplements these
-- locally in melange.ts rather than reaching into a sibling package's internal
-- codegen helpers; this port keeps them local for the same reason (nothing in
-- any of `lib/api-tree/`, `lib/type-ir/`, `lib/ffi-ir/` owns a shared
-- case-conversion vocabulary, and inventing one
-- as a side effect of a backend port would be out of this file's scope).
--
-- The two rewrites are the TS source's two regexes, in order: split a
-- lower/digit-to-upper boundary with a space (`fooBar` -> `foo Bar`), then
-- collapse every run of underscores/hyphens/whitespace into one space. Empty
-- segments are dropped by matching runs of non-space rather than splitting.
--: (name: string) -> { [integer]: string }
local function split_words(name)
	local spaced = name:gsub("([a-z0-9])([A-Z])", "%1 %2")
	local collapsed = spaced:gsub("[_%-%s]+", " ")
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	for word in collapsed:gmatch("[^ ]+") do
		n = n + 1
		out[n] = word
	end
	return out
end

--: (name: string) -> string
local function to_pascal_case(name)
	local words = split_words(name)
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #words do
		local w = words[i]
		parts[i] = w:sub(1, 1):upper() .. w:sub(2):lower()
	end
	return table.concat(parts)
end

--: (name: string) -> string
local function to_camel_case(name)
	local pascal = to_pascal_case(name)
	if #pascal == 0 then return pascal end
	return pascal:sub(1, 1):lower() .. pascal:sub(2)
end

-- The JS-string literal an `external` binds to, i.e. the TS source's
-- `JSON.stringify(name)`. An ffi-ir name is normally a plain identifier, but
-- the IR does not constrain it, so the mandatory JSON escapes are applied
-- rather than assuming the input is quote-free.
local JSON_ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
} --[[: { [string]: string }]]

--: (s: string) -> string
local function json_string(s)
	local escaped = s:gsub('[%z\1-\31\\"]', function(c)
		local mapped = JSON_ESCAPES[c]
		if mapped ~= nil then return mapped end
		return ("\\u%04x"):format(c:byte())
	end)
	return '"' .. escaped .. '"'
end

-- ── Hoisting context ─────────────────────────────────────────────────────────

-- A nested object/enum is declared once (as a top-level `type ... = ...`) and
-- every reference to it agrees on the generated name. OCaml has no anonymous
-- inline record/variant syntax, so this is not an optimization — it is the
-- only way to render those shapes at all.
--
--   decls          — the hoisted declarations, IN EMISSION ORDER. A list, not
--                    a map, precisely so the dependency ordering OCaml
--                    requires is preserved: a nested hoist appends before the
--                    declaration that mentions it does.
--   used           — the set of names already handed out by `fresh_name`.
--   hoisted_refs / — parallel arrays standing in for the TS source's
--   hoisted_names    `Map<TypeRef, string>`. Keyed by TABLE IDENTITY, which is
--                    exactly what the TS Map's key semantics are: two
--                    structurally identical but distinct TypeRefs hoist to two
--                    declarations there and here alike. Parallel arrays rather
--                    than a table-keyed Lua table because the annotation
--                    vocabulary's index signatures are string/integer-keyed;
--                    the linear scan is over the count of hoisted types in one
--                    declaration, which is small.
--:: Ctx = {
--::     decls: { [integer]: string },
--::     used: { [string]: boolean },
--::     hoisted_refs: { [integer]: TypeRef },
--::     hoisted_names: { [integer]: string },
--:: }

--: () -> Ctx
local function new_ctx()
	return { decls = {}, used = {}, hoisted_refs = {}, hoisted_names = {} }
end

-- A name not yet used in this rendering, derived from `hint`. Collisions get a
-- numeric suffix starting at 2, matching the TS source's counter exactly.
--: (ctx: Ctx, hint: string) -> string
local function fresh_name(ctx, hint)
	local base = to_camel_case(hint)
	if #base == 0 then base = "anonymous" end
	if not ctx.used[base] then
		ctx.used[base] = true
		return base
	end
	local n = 2
	while ctx.used[base .. tostring(n)] do n = n + 1 end
	local name = base .. tostring(n)
	ctx.used[name] = true
	return name
end

-- The name `ref` was previously hoisted under, or nil when it has not been.
--: (ctx: Ctx, ref: TypeRef) -> string | nil
local function hoisted_name_of(ctx, ref)
	for i = 1, #ctx.hoisted_refs do
		if ctx.hoisted_refs[i] == ref then return ctx.hoisted_names[i] end
	end
	return nil
end

local generate_named_type -- forward declaration (mutually recursive with `melange_type`)

-- The name `ref` is declared under at top level, hoisting its declaration on
-- first sight. The mapping is recorded BEFORE the declaration is generated,
-- matching the TS order — a self-referential shape then resolves to its own
-- name instead of recursing forever.
--: (ctx: Ctx, ref: TypeRef, name_hint: string) -> (string | nil, string | nil)
local function hoisted_name(ctx, ref, name_hint)
	local cached = hoisted_name_of(ctx, ref)
	if cached ~= nil then return cached end

	local name = fresh_name(ctx, name_hint)
	local n = #ctx.hoisted_refs + 1
	ctx.hoisted_refs[n] = ref
	ctx.hoisted_names[n] = name

	local decl, err = generate_named_type(ref, name, ctx)
	if decl == nil then return nil, err end
	ctx.decls[#ctx.decls + 1] = decl
	return name
end

-- ── Type-expression rendering ────────────────────────────────────────────────
-- DELIBERATELY MINIMAL — see the file header.

local PRIMITIVES = {
	boolean = "bool",
	number = "float",
	integer = "int",
	string = "string",
	null = "unit",
	void = "unit",
} --[[: { [string]: string }]]

local melange_type -- forward declaration (mutually recursive with `generate_named_type`)

-- One top-level `type <name> = ...` declaration for an `object` (an OCaml
-- record) or an `enum` (a no-payload variant). Every other kind is outside
-- this file's data-shape subset and is reported rather than guessed at.
--
-- A record field is `option`-wrapped when the field's own TypeRef carries
-- `meta.optional`/`meta.nullable` — the same convention applied at
-- parameter/return position by `param_type` below.
--: (ref: TypeRef, name: string, ctx: Ctx) -> (string | nil, string | nil)
function generate_named_type(ref, name, ctx)
	local shape = ref.shape
	if shape.kind == "object" then
		local fields = (shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
		local lines = { "type " .. name .. " = {" } --[[: { [integer]: string } ]]
		local names = ordered_keys(fields)
		for i = 1, #names do
			local field_name = names[i]
			local field_ref = fields[field_name]
			local label = ocaml_label(field_name)
			local field_type, err = melange_type(field_ref, ctx, name .. "_" .. field_name)
			if field_type == nil then return nil, err end
			local optional = field_ref.meta.optional == true or field_ref.meta.nullable == true
			local rendered = field_type
			if optional then rendered = field_type .. " option" end
			lines[#lines + 1] = "  " .. label .. " : " .. rendered .. ";"
		end
		lines[#lines + 1] = "}"
		return table.concat(lines, "\n")
	end

	if shape.kind == "enum" then
		local members = (shape --[[: { members: { [integer]: string }, ... }]]).members
		local lines = { "type " .. name .. " =" } --[[: { [integer]: string } ]]
		for i = 1, #members do
			lines[#lines + 1] = "  | " .. to_pascal_case(members[i])
		end
		return table.concat(lines, "\n")
	end

	return nil,
		'ffi_ir_ocaml_melange: cannot hoist type-ir kind "' .. shape.kind ..
		'" — outside this file\'s minimal data-shape subset'
end

-- A TypeRef's Melange type expression. `name_hint` seeds the generated name
-- when the shape has to be hoisted.
--: (ref: TypeRef, ctx: Ctx, name_hint: string) -> (string | nil, string | nil)
function melange_type(ref, ctx, name_hint)
	local shape = ref.shape
	local primitive = PRIMITIVES[shape.kind]
	if primitive ~= nil then return primitive end

	if shape.kind == "array" then
		local element = (shape --[[: { element: TypeRef, ... }]]).element
		local rendered, err = melange_type(element, ctx, name_hint .. "Item")
		if rendered == nil then return nil, err end
		return rendered .. " array"
	end

	if shape.kind == "ref" then
		-- Convention (see `resource_ref`'s own doc comment in init.lua): a
		-- `ref` TypeRef carrying `meta.ownership.kind == "resource"`, or one
		-- wrapped by `with_ownership(..., ownership.opaque_handle(...))`, names
		-- a resource declared elsewhere in the enclosing module.
		-- `build_resource` below generates that resource as its own OCaml
		-- module with an abstract `type t`, so a reference to it renders as
		-- `<ResourceModule>.t`.
		local target = (shape --[[: { target: string, ... }]]).target
		return to_pascal_case(target) .. ".t"
	end

	if shape.kind == "object" or shape.kind == "enum" then
		return hoisted_name(ctx, ref, name_hint)
	end

	return nil,
		'ffi_ir_ocaml_melange: unsupported type-ir kind "' .. shape.kind ..
		'" — outside this file\'s minimal data-shape subset'
end

-- One parameter's (or return type's) Melange type, applying `option` for
-- `meta.optional`/`meta.nullable` — the same convention every sibling
-- projector already applies at these positions.
--: (ref: TypeRef, ctx: Ctx, name_hint: string) -> (string | nil, string | nil)
local function param_type(ref, ctx, name_hint)
	local base, err = melange_type(ref, ctx, name_hint)
	if base == nil then return nil, err end
	if ref.meta.optional == true or ref.meta.nullable == true then return base .. " option" end
	return base
end

-- ── Ownership gate ───────────────────────────────────────────────────────────

-- Reports the two disciplines this target has no native mechanism for
-- (`refcount`, `resource`), matching the report-don't-degrade convention the
-- sibling projectors establish. `copy` (or no `meta.ownership` at all) and
-- `opaque-handle` pass through unchanged — an `opaque-handle`'s `freeFn`, if
-- any, is consumed separately by `build_resource`, not here; this function
-- only GATES a parameter/return TypeRef's discipline, it never transforms one.
--
-- Returns `(true, nil)` when the position is acceptable, `(nil, errmsg)` when
-- it is not. `where` names the position for the message ('parameter "x"',
-- "return type").
--
-- TYPECHECKER WORKAROUND: `kind` is spelled as a literal at each call site
-- below instead of read back off the matched discipline. The natural code
-- reads the tag once (`local kind = discipline.kind`) and interpolates it into
-- one shared message. That does not typecheck: reading the discriminant field
-- off an un-narrowed tagged union types it `never`, and concatenating it then
-- fails with "cannot concatenate type `never`". Minimal repro (needs only
-- ffi_ir):
--
--     local d = ffi_ir.ownership_of(ref)
--     if d == nil then return "" end
--     return "kind=" .. d.kind
--
--   → cannot concatenate type `never`
--
-- The checker appears to INTERSECT the field's type across the union's arms
-- rather than union it; for disjoint string-literal discriminants that
-- intersection is empty. Narrowing first (`if d.kind == "refcount" then`) works
-- — it is only reading the tag as a value that fails. Collapse this back to one
-- message with an interpolated tag once a union's discriminant field reads back
-- as the union of its arms' literals (TODO.md).
--: (where: string, kind: string, why: string) -> string
local function unsupported_discipline_message(where, kind, why)
	return 'to_melange_ffi: unsupported ownership discipline "' .. kind ..
		'" for the Melange/JS target at ' .. where .. " — " .. why ..
		'. Melange/JS in this projector implements only "copy" and "opaque-handle" — project this value to a target ' ..
		"that natively supports this discipline instead (C for opaque-handle+free-fn done manually, WIT for resource+own/borrow)."
end

--: (ref: TypeRef, where: string) -> (boolean | nil, string | nil)
local function require_supported_ownership(ref, where)
	local discipline = ffi_ir.ownership_of(ref)
	if discipline == nil then return true end

	if discipline.kind == "refcount" then
		return nil, unsupported_discipline_message(where, "refcount",
			"Melange has no Arc-equivalent refcount wrapper and no bundled FinalizationRegistry pairing " ..
			"(unlike wasm-bindgen's generated .free()); use ownership.opaque_handle() with an explicit free_fn instead")
	end

	if discipline.kind == "resource" then
		return nil, unsupported_discipline_message(where, "resource",
			"no host JS/Melange runtime exists to enforce WIT-style lend-count-and-trap semantics")
	end

	return true
end

-- ── Function / method ────────────────────────────────────────────────────────

-- `meta.description` as an OCaml doc comment, with its trailing newline, or
-- the empty string when there is none.
--: (meta: Meta) -> string
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return "" end
	return "(** " .. description .. " *)\n"
end

-- The rendered parameter type list for a function-like shape, with every
-- parameter's ownership discipline already gated by the caller.
--: (name: string, params: FfiParam[], ctx: Ctx) -> ({ [integer]: string } | nil, string | nil)
local function param_types(name, params, ctx)
	local out = {} --[[: { [integer]: string } ]]
	for i = 1, #params do
		local p = params[i]
		local rendered, err = param_type(p.type, ctx, name .. "_" .. p.name)
		if rendered == nil then return nil, err end
		out[i] = rendered
	end
	return out
end

-- Gate every parameter's and the return type's ownership discipline, in the TS
-- source's order (parameters first, left to right, then the return type) so
-- the first unsupported position is the one reported.
--: (shape: FfiFunctionLike) -> (boolean | nil, string | nil)
local function gate_signature(shape)
	for i = 1, #shape.params do
		local p = shape.params[i]
		local ok, err = require_supported_ownership(p.type, 'parameter "' .. p.name .. '"')
		if ok == nil then return nil, err end
	end
	local ok, err = require_supported_ownership(shape.returnType, "return type")
	if ok == nil then return nil, err end
	return true
end

-- Free function -> a plain `external` with no receiver, one arrow per
-- parameter, and `[@@mel.val]` when no enclosing JS module is named (a global
-- function) — verified against melange.re's own documented default (a bare
-- `external` with no module/scope attribute binds a global value by its OCaml
-- name, e.g. `external setTimeout : (unit -> unit) -> int -> timeoutId =
-- "setTimeout"`) — or `[@@mel.module "<js_module>"]` when `js_module` is given
-- (this module's own JS import), matching `[@@mel.module "path"]` verbatim
-- from the same page.
--
-- A no-parameter function renders as `unit -> <return>`: OCaml has no
-- zero-argument function type.
--: (name: string, shape: FfiFunctionLike, meta: Meta, ctx: Ctx, js_module: string | nil) -> (string | nil, string | nil)
local function build_function(name, shape, meta, ctx, js_module)
	local gated, gate_err = gate_signature(shape)
	if gated == nil then return nil, gate_err end

	local label = ocaml_label(name)
	local params, params_err = param_types(name, shape.params, ctx)
	if params == nil then return nil, params_err end
	local return_type, return_err = param_type(shape.returnType, ctx, name .. "Result")
	if return_type == nil then return nil, return_err end

	local chain = {} --[[: { [integer]: string } ]]
	for i = 1, #params do chain[i] = params[i] end
	if #return_type > 0 then
		chain[#chain + 1] = return_type
	else
		chain[#chain + 1] = "unit"
	end

	local signature
	if #chain == 1 then
		signature = "unit -> " .. chain[1]
	else
		signature = table.concat(chain, " -> ")
	end

	local attr = "[@@mel.val]"
	if js_module ~= nil then attr = "[@@mel.module " .. json_string(js_module) .. "]" end
	return doc_comment(meta) .. "external " .. label .. " : " .. signature ..
		" = " .. json_string(name) .. " " .. attr
end

-- Method on a resource -> `[@mel.send]`, verified against melange.re's own
-- documented pattern (`external get_by_id : document -> string -> Dom.element
-- = "getElementById" [@@mel.send]`, called as `document |. get_by_id "my-id"`)
-- — the receiver is the FIRST explicit parameter (typed as the resource's
-- abstract `t`), not an implicit `self`; Melange's `external` mechanism has no
-- receiver-binding syntax distinct from "first argument", unlike
-- wasm-bindgen's `&self` splice or WIT's implicit resource-block receiver.
--: (name: string, shape: FfiFunctionLike, meta: Meta, ctx: Ctx, receiver_type: string) -> (string | nil, string | nil)
local function build_method(name, shape, meta, ctx, receiver_type)
	local gated, gate_err = gate_signature(shape)
	if gated == nil then return nil, gate_err end

	local label = ocaml_label(name)
	local params, params_err = param_types(name, shape.params, ctx)
	if params == nil then return nil, params_err end
	local return_type, return_err = param_type(shape.returnType, ctx, name .. "Result")
	if return_type == nil then return nil, return_err end

	-- No `unit` fallback and no one-element special case here, unlike
	-- `build_function`: the receiver is always present, so the chain has at
	-- least two elements.
	local chain = { receiver_type } --[[: { [integer]: string } ]]
	for i = 1, #params do chain[#chain + 1] = params[i] end
	chain[#chain + 1] = return_type

	return doc_comment(meta) .. "external " .. label .. " : " .. table.concat(chain, " -> ") ..
		" = " .. json_string(name) .. " [@@mel.send]"
end

-- ── Resource ─────────────────────────────────────────────────────────────────

--: (name: string, kind: string) -> string
local function unsupported_resource_discipline_message(name, kind)
	return 'to_melange_ffi: unsupported ownership discipline "' .. kind ..
		'" for the Melange/JS target on resource "' .. name .. '" — ' ..
		'Melange/JS in this projector implements only "copy" and "opaque-handle" for resource declarations ' ..
		"(see the file-level doc comment)"
end

--: (block: string, prefix: string) -> string
local function indent_block(block, prefix)
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	-- `gmatch` with an optional-content pattern yields every line including
	-- empty ones and a trailing empty segment, so a block is re-joined with
	-- exactly the lines it came in with.
	for line in (block .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		if #line == 0 then
			out[n] = line
		else
			out[n] = prefix .. line
		end
	end
	return table.concat(out, "\n")
end

-- One entry of a resource's `methods` map. The kind must be `method` or
-- `function` (a resource's method map holding anything else is malformed IR,
-- not something to render around).
--: (method_name: string, method_ref: FfiRef, ctx: Ctx) -> (string | nil, string | nil)
local function build_resource_method(method_name, method_ref, ctx)
	local kind = method_ref.shape.kind
	if kind ~= "method" and kind ~= "function" then
		return nil,
			'to_melange_ffi: resource method "' .. method_name .. '" has unexpected kind "' .. kind ..
			'" (expected "method")'
	end
	return build_method(method_name, method_ref.shape --[[: FfiFunctionLike]], method_ref.meta, ctx, "t")
end

-- Resource -> a dedicated OCaml module (PascalCase, matching Melange/OCaml's
-- module-naming rule) wrapping an abstract `type t` (per init.lua's own doc
-- comment, a resource "exposes behavior ONLY through `methods`" and cannot be
-- a plain data structure — an abstract type with no exposed representation is
-- the direct Melange analog) plus one `[@mel.send]` external per method,
-- receiver typed `t`.
--
-- When the resource's OWN `meta.ownership` names `opaque-handle` with a
-- `freeFn`, an additional `[@mel.send]`-bound external for that free function
-- is emitted alongside the declared methods — the same "explicit, separately
-- declared free function" contract `OwnershipDiscipline`'s own doc comment
-- describes. `refcount`/`resource` on the resource's own ownership are
-- reported, matching `require_supported_ownership`'s scope; `copy` (the
-- default) and unset both emit no extra free-function binding, there being
-- nothing to add beyond the abstract type and its methods.
--
-- `ref` is the resource's own FfiRef, read for both its meta bag and — via
-- `ffi_ir.ownership_of` — its ownership discipline. An FfiRef is structurally
-- a TypeRef (`{ shape = { kind = ... }, meta = ... }`), which is what lets one
-- reader serve both.
--
-- The shape is taken as the structural record this function actually reads
-- rather than as ffi_ir's `FfiResourceShape` alias: the alias pins `kind` to
-- the literal `"resource"`, and the value reaching here is an `FfiShape` whose
-- `kind` is a plain `string`, which no checked cast can narrow. Same reason
-- the sibling backends spell their resource/module shapes structurally.
--: (name: string, ref: FfiRef, shape: { methods: { [string]: FfiRef }, ... }, ctx: Ctx) -> (string | nil, string | nil)
local function build_resource(name, ref, shape, ctx)
	local discipline = ffi_ir.ownership_of(ref)

	-- Same TYPECHECKER WORKAROUND as `require_supported_ownership` above: the
	-- matched discipline's tag is spelled as a literal rather than read back off
	-- the value, because reading a tagged union's discriminant as a value types
	-- it `never`.
	if discipline ~= nil then
		if discipline.kind == "refcount" then
			return nil, unsupported_resource_discipline_message(name, "refcount")
		end
		if discipline.kind == "resource" then
			return nil, unsupported_resource_discipline_message(name, "resource")
		end
	end

	local parts = { "type t" } --[[: { [integer]: string } ]]

	if discipline ~= nil and discipline.kind == "opaque-handle" then
		local free_fn = discipline.freeFn
		if free_fn ~= nil then
			parts[#parts + 1] = "external " .. ocaml_label(free_fn) .. " : t -> unit = " ..
				json_string(free_fn) .. " [@@mel.send]"
		end
	end

	local method_names = ordered_keys(shape.methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local decl, err = build_resource_method(method_name, shape.methods[method_name], ctx)
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	local body = table.concat(parts, "\n\n")
	return doc_comment(ref.meta) .. "module " .. to_pascal_case(name) .. " = struct\n" ..
		indent_block(body, "  ") .. "\nend"
end

-- ── Module ───────────────────────────────────────────────────────────────────

local render_ffi -- forward declaration (mutually recursive with `build_module`)

-- Module -> an OCaml `module Name = struct ... end` purely for organization
-- (grouping the declarations this FFI boundary exports under one namespace) —
-- every free function inside it additionally gets `[@@mel.module "<name>"]` so
-- it imports from the actual underlying JS module of that name (verified
-- pattern: `[@@mel.module "path"]` generates `var Path = require("path")`),
-- not just an OCaml-side namespace with no runtime import behind it.
--
-- Resources are emitted before functions, as in the TS source. One `ctx` is
-- shared across every nested resource and function so hoisted names are
-- collected once for the whole module rather than duplicated per member.
--: (name: string, shape: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }, ctx: Ctx) -> (string | nil, string | nil)
local function build_module(name, shape, ctx)
	local parts = {} --[[: { [integer]: string } ]]

	local res_names = ordered_keys(shape.resources)
	for i = 1, #res_names do
		local res_name = res_names[i]
		local decl, err = render_ffi(shape.resources[res_name], res_name, ctx)
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	local fn_names = ordered_keys(shape.functions)
	for i = 1, #fn_names do
		local fn_name = fn_names[i]
		local fn_ref = shape.functions[fn_name]
		local decl, err = build_function(fn_name, fn_ref.shape --[[: FfiFunctionLike]], fn_ref.meta, ctx, name)
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	local body = table.concat(parts, "\n\n")
	return "module " .. to_pascal_case(name) .. " = struct\n" .. indent_block(body, "  ") .. "\nend"
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- True when `kind` is `target` or has it as an ancestor in ffi-ir's OWN kind
-- lattice (`ffi_ir.ancestors` — the boundary-kind lattice, NOT type_ref's
-- data-shape one).
--: (kind: string, target: string) -> boolean
local function is_a(kind, target)
	if kind == target then return true end
	local chain = ffi_ir.ancestors(kind)
	for i = 1, #chain do
		if chain[i] == target then return true end
	end
	return false
end

-- Dispatch shared by `to_melange_ffi` (which additionally prepends the hoisted
-- type declarations once, at the outermost call) and `build_module` (which
-- shares its `ctx` across nested members).
--: (ref: FfiRef, name: string, ctx: Ctx) -> (string | nil, string | nil)
function render_ffi(ref, name, ctx)
	local kind = ref.shape.kind

	if kind == "function" then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta, ctx, nil)
	end

	if kind == "method" then
		return nil,
			'to_melange_ffi: a top-level "method" needs its receiver\'s resource type — ' ..
			'call this via a "resource"\'s methods map instead'
	end

	if kind == "resource" then
		return build_resource(name, ref, ref.shape --[[: { methods: { [string]: FfiRef }, ... }]], ctx)
	end

	if kind == "module" then
		return build_module(
			name,
			ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]],
			ctx
		)
	end

	-- An extension-registered kind whose ancestor chain reaches `function` is
	-- rendered as one — the ancestor-fallback the ffi-ir lattice exists for.
	if is_a(kind, "function") then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta, ctx, nil)
	end

	return nil, 'to_melange_ffi: unhandled ffi-ir kind "' .. kind .. '" (no handler and no known ancestor)'
end

-- Lower an ffi-ir `FfiRef` to Melange `external`-declaration source text.
--
-- `name` is required for every kind (`function`/`method`/`resource`/`module`
-- are all named declarations — the same requirement every sibling projector
-- has). Any hoisted record/enum type declarations a function/method/resource
-- needed along the way are collected once and prepended, in dependency order,
-- before the requested declaration.
--
-- Returns `(nil, errmsg)` for a missing name, an unsupported ownership
-- discipline, or a data shape outside this file's subset — never a partial
-- rendering alongside an error.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_melange_ffi(ref, name)
	if name == nil then
		return nil,
			'to_melange_ffi: "' .. ref.shape.kind .. '" requires a name — ' ..
			"Melange externals/modules are named declarations, not anonymous inline types"
	end

	local ctx = new_ctx()
	local rendered, err = render_ffi(ref, name, ctx)
	if rendered == nil then return nil, err end
	if #ctx.decls == 0 then return rendered end

	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #ctx.decls do parts[i] = ctx.decls[i] end
	parts[#parts + 1] = rendered
	return table.concat(parts, "\n\n")
end

return M
