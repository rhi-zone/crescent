-- lib/ffi-ir/rescript_external.lua — the ReScript `external`-declaration
-- projector, ported from fractal's packages/ffi-ir/src/rescript-external.ts.
--
-- ReScript codegen for ffi-ir's boundary layer — module/function/method/
-- resource/ownership-discipline shapes — targeting ReScript's `external`
-- declaration syntax for binding to JS
-- (https://v11.rescript-lang.org/docs/manual/v11.0.0/bind-to-js-function,
-- https://v11.rescript-lang.org/docs/manual/v11.0.0/bind-to-js-object; fetched
-- 2026-08-03 by the TS source's author, NOT re-verified by this port). This is
-- the direct structural sibling of fractal's wasm-bindgen backend (which
-- generates the `#[wasm_bindgen]` annotations a human would otherwise
-- hand-write for the Rust/JS boundary): this file generates the
-- `external`/`@module`/`@val`/`@send` declarations a ReScript developer would
-- otherwise hand-write for the ReScript/JS boundary.
--
-- Verified against the manual by the TS source's author, not from memory:
--   - `@module("name") external x: T = "jsName"` — binds a named export of a
--     JS module.
--   - `@val external x: T = "jsName"` — binds a global JS value/function (no
--     enclosing module).
--   - `@send external f: (t, ...params) => ret = "jsMethodName"` — calls a
--     method on a JS value; the receiver is the function type's FIRST
--     positional parameter, not a special calling form.
--   - `@new external make: (...params) => t = "JsClassName"` — constructs via
--     JS's `new`; combines with `@module` for a class exported from a module.
--   - `@get`/`@set` (property read/write) and `@get_index`/`@set_index`
--     (indexed access) also exist but have no counterpart in ffi-ir's current
--     kind vocabulary (`function`/`method`/`resource`/`module` only — no
--     "property" kind), so they are not emitted here; see the note on
--     `build_resource` below.
--   - Opaque JS object type: `type t` with no definition, the manual's own
--     documented idiom for "this type exists in JS, structure not modeled."
--
-- TYPE-SHAPE REUSE. Every parameter/return-type position is rendered via
-- `type_ref_rescript_native`'s already-merged `rescript_type_from_type_ref`,
-- not reimplemented — mirroring the TS source's reuse of type-ir's own
-- ReScript projector. In particular, a `method`'s receiver is expressed by
-- constructing a synthetic type-ir `function` TypeRef with `thisType` set to a
-- `ref` TypeRef naming the receiver resource: that projector's `function`
-- handler ALREADY prepends `thisType` as a leading positional parameter (see
-- `convert_function` there), which is exactly ReScript's own "@send takes the
-- receiver as its first parameter" shape. No string surgery is needed here.
--
-- OWNERSHIP: NOTHING IS GATED, NOTHING IS REPORTED. JS/ReScript's FFI docs say
-- nothing about ownership discipline at all (both sides are garbage-collected;
-- `external` bindings are plain type signatures with no lifetime/ownership
-- annotation anywhere in the syntax verified above). So — unlike every sibling
-- backend in this directory, which reports `(nil, errmsg)` for the disciplines
-- its target cannot realize — this target does not force an artificial
-- ownership mapping: every `OwnershipDiscipline` (`copy`, `opaque-handle`,
-- `refcount`, `resource`) is treated identically, as "just a reference/value
-- crossing the boundary", and none of them gates. The one borderline case the
-- TS source considered: `"copy"` on a TypeRef whose shape is already a
-- ReScript-native by-value primitive (`bool`/`float`/`int`/`string`) needs no
-- special handling either — those are already immutable values in both JS and
-- ReScript, so "copy discipline" and "no discipline at all" render
-- identically.
--
-- NAMING JUDGMENT CALL — function vs. global binding (flagged in the TS source
-- rather than decided silently, and carried across unchanged here). ffi-ir's
-- `function` kind carries no field saying where in JS the function lives (a
-- module export vs. a global). The enclosing `module` kind's `name` is the only
-- place that information could come from, and only when a function is actually
-- reached through a module's `functions` map. So: when a function is lowered as
-- part of a `module` (via `build_module`, threading the module's `name` down),
-- it emits `@module(<name>)` — never `@val` — even though the schema cannot
-- truly distinguish "this JS module export" from "this is secretly a global".
-- When `to_rescript_ffi` is called directly on a bare `function`/`method`
-- FfiRef with NO enclosing module context at all (no name to put in
-- `@module(...)`), there is nothing to reference, so it falls back to `@val`,
-- the only attribute that needs no module name.
--
-- ── Divergences from the TS, all deliberate ─────────────────────────────────
--
-- 1. ERRORS ARE RETURNED, NOT THROWN. Every `throw` in the TS source becomes a
--    `(nil, errmsg)` return, the same conversion every sibling backend in this
--    directory applies: a missing name, a malformed methods-map entry, or an
--    unhandled kind is a data error, not a programming error. Only the two
--    builders whose TS counterparts can throw (`build_resource`,
--    `build_module`) and the entry point are fallible; `build_function` and
--    `build_method` return a plain `string`, because
--    `rescript_type_from_type_ref` is itself total (it degrades unrepresentable
--    kinds to `Js.Json.t`/`unit` rather than failing) and there is no other
--    failure mode at those two sites to model.
--
-- 2. NO REGEX SPLICE FOR A RESOURCE METHOD'S JS-SIDE NAME. The TS builds the
--    method declaration under its PREFIXED ReScript identifier and then
--    rewrites the trailing `= "prefixedName"` back to `= "methodName"` with an
--    anchored regex. Here `build_method` takes the JS-side name as an explicit
--    parameter instead. The rewritten text is always the declaration's final
--    segment and always exactly that literal, so the output is identical; this
--    only removes a string surgery the TS needed because its helper had no
--    parameter for it.
--
-- 3. DETERMINISTIC MAP ORDER. The TS walks `Object.entries(...)` (JS insertion
--    order), which a Lua table cannot recover, so a resource's methods and a
--    module's functions/resources are emitted in byte order of their keys — the
--    same stand-in, for the same reason, that `lib/type-ir/init.lua`'s own
--    `ordered_keys` documents. Nothing in the emitted ReScript depends on it:
--    `external` declarations within one `module` block have no ordering
--    constraint (unlike OCaml/Melange's hoisted `type` declarations), and the
--    only cross-declaration dependency — a resource's opaque `type` being in
--    scope for the functions mentioning it — is satisfied by ReScript module
--    scoping regardless of line order.
--
-- 4. `to_rescript_ffi:` is the error-message prefix throughout, naming the
--    function that actually exists here (the TS spells `toReScriptFfi:`).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi_ir = require("lib.ffi-ir")
local type_ref = require("lib.type-ir")
local rescript = require("lib.type-ir.rescript_native")
local codegen = require("lib.type-ir.codegen")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of lib/type-ir/init.lua's
-- own declarations, reached both directly and transitively through the
-- `require`s above (every ffi-ir and type-ir signature this file touches names
-- them). Duplicating a type definition is normally forbidden outright; it is
-- here only because the checker cannot currently keep an imported alias
-- resolvable through a consumer — when a consumer (this file, and in turn this
-- file's test) calls a function whose signature names an alias declared in the
-- required module, the checker re-resolves that module's `--::` declarations in
-- the CONSUMER's scope, where lib/type-ir/init.lua's `TypeRef`/`Meta` are not bound.
-- They resolve to `undefined type`, silently degrade to `any`, and the consumer
-- reports errors against the DEPENDENCY's line numbers. See the full write-up
-- and minimal repro in init.lua's own copy of this comment, and the TODO.md
-- entry ("an alias imported via require ... degrades to any as soon as any
-- consumer uses that module"), which already records that the re-declaration is
-- repeated in each `lib/ffi-ir/*.lua` backend for this reason.
--
-- These MUST stay structurally identical to lib/type-ir/init.lua's. Delete all three
-- and rely on the `require`s once the checker resolves imported aliases through
-- a consumer.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- ── Deterministic map ordering ───────────────────────────────────────────────

-- An FfiRef map's keys in byte order. See divergence (3) in the header.
--: (tbl: { [string]: FfiRef }) -> { [integer]: string }
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

-- PascalCase, as the TS source's own local `toPascalCase`: split on every run
-- of non-alphanumerics AND at camelCase boundaries, capitalize each word's
-- first character, lowercase the rest, join.
--
-- NOT `type_ref_codegen.pascal_case_from_words`, despite the TS source calling
-- its local copy "`toPascalCaseFromWords`-equivalent" — that claim holds only
-- for names whose sole word separators are `_`, `-`, or whitespace, which is
-- all `split_words` breaks on. A JS module specifier like `"node:fs"` is
-- exactly where they part ways: this function yields `NodeFs` (a legal
-- ReScript module name), `pascal_case_from_words` yields `Node:fs` (not one).
-- The TS behaviour is what is ported.
--
-- The consequence for cross-file agreement is that a resource's opaque type
-- name (emitted here) and the identifier a `ref` TypeRef pointing at it renders
-- to (emitted by `type_ref_rescript_native`'s `convert_ref`, which DOES use
-- `pascal_case_from_words`) coincide for every resource name whose separators
-- are `_`/`-`/whitespace — including every plain identifier — and can diverge
-- for one containing, say, a `.` or `:`. That divergence is the TS source's,
-- reproduced rather than papered over.
--: (name: string) -> string
local function to_pascal_case(name)
	local spaced = (name:gsub("([a-z0-9])([A-Z])", "%1 %2"))
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	for word in spaced:gmatch("[a-zA-Z0-9]+") do
		n = n + 1
		out[n] = word:sub(1, 1):upper() .. word:sub(2):lower()
	end
	return table.concat(out)
end

--: (name: string) -> string
local function decapitalize(name)
	if #name == 0 then return name end
	return name:sub(1, 1):lower() .. name:sub(2)
end

-- ReScript reserved words that cannot be used as an `external`'s binding
-- identifier (the left-hand name). Mirrors `type_ref_rescript_native`'s own
-- RESERVED set, which that module does not export — a small local duplicate,
-- not a reach into another module's internals, the same call the TS source
-- makes and documents for the identical reason.
local RESERVED = {
	["and"] = true, ["as"] = true, ["assert"] = true, ["constraint"] = true,
	["else"] = true, ["exception"] = true, ["external"] = true, ["false"] = true,
	["for"] = true, ["fun"] = true, ["function"] = true, ["functor"] = true,
	["if"] = true, ["in"] = true, ["include"] = true, ["inherit"] = true,
	["initializer"] = true, ["lazy"] = true, ["let"] = true, ["module"] = true,
	["mutable"] = true, ["new"] = true, ["of"] = true, ["open"] = true,
	["or"] = true, ["private"] = true, ["rec"] = true, ["sig"] = true,
	["struct"] = true, ["then"] = true, ["to"] = true, ["true"] = true,
	["try"] = true, ["type"] = true, ["val"] = true, ["virtual"] = true,
	["when"] = true, ["while"] = true, ["with"] = true, ["switch"] = true,
} --[[: { [string]: boolean }]]

-- A valid ReScript lowercase-leading identifier for `name`, used as the
-- left-hand binding identifier of an `external` declaration. The JS-side name
-- (the right-hand string literal) is untouched, since `external x: T =
-- "actualName"` already separates "what ReScript calls it" from "what JS calls
-- it" — unlike a record field label, no `@as`-style attribute is needed here,
-- because the string literal already IS that mechanism.
--
-- The three steps are the TS source's three regexes, in order: replace every
-- non-identifier character with `_`, decapitalize a leading uppercase letter,
-- and prefix `_` when the result still does not start with a lowercase letter
-- or underscore. A reserved word then gets a trailing `_`.
--
-- TYPECHECKER WORKAROUND: the decapitalization step is a separate function
-- returning the unchanged string on the non-matching path, and the `_` prefix
-- decision is spelled with two returns. The natural code — and the exact
-- formulation `lib/type-ir/rescript_native.lua`'s own `sanitize_label` uses — is
-- one function with a local reassigned inside the `if`:
--
--     local lowered = cleaned
--     if cleaned:match("^[A-Z]") ~= nil then
--         lowered = cleaned:sub(1, 1):lower() .. cleaned:sub(2)
--     end
--     if lowered:match("^[a-z_]") ~= nil then return lowered end
--
-- That does not typecheck here: a local REASSIGNED inside a conditional branch
-- is typed `nil` at any later use of it as a METHOD-CALL RECEIVER, so the
-- second `lowered:match(...)` fails with "cannot call value of type `nil`".
-- Minimal repro (no project dependencies, no aliasing, literal initializer):
--
--     --: (name: string) -> string
--     local function a(name)
--         local lowered = "y"
--         if name:match("^[A-Z]") ~= nil then lowered = "x" end
--         if lowered:match("^[a-z_]") ~= nil then return lowered end
--         return "_" .. lowered
--     end
--
--   → cannot call value of type `nil`
--
-- Only the method-call receiver position is affected — using the same
-- reassigned local in a CONCATENATION checks clean, which is why the `attr`
-- and `type_decl` reassignments elsewhere in this file are left as they are.
-- (`sanitize_label` in lib/type-ir/rescript_native.lua passes with the natural
-- formulation; extracted verbatim into a standalone file it fails, so
-- something in that file's surrounding context suppresses it — the trigger is
-- narrower than the repro alone shows.) Collapse this back into one function
-- with the reassignment once a conditionally-reassigned local keeps its type
-- at a method-call receiver (TODO.md).
--: (s: string) -> string
local function decapitalize_leading_upper(s)
	if s:match("^[A-Z]") ~= nil then return decapitalize(s) end
	return s
end

--: (name: string) -> string
local function external_ident(name)
	local cleaned = (name:gsub("[^a-zA-Z0-9_]", "_"))
	local lowered = decapitalize_leading_upper(cleaned)
	if lowered:match("^[a-z_]") ~= nil then
		if RESERVED[lowered] then return lowered .. "_" end
		return lowered
	end
	local prefixed = "_" .. lowered
	if RESERVED[prefixed] then return prefixed .. "_" end
	return prefixed
end

-- ── Formatting ───────────────────────────────────────────────────────────────

-- `block` with `prefix` prepended to every non-empty line. Empty lines stay
-- empty (the TS's `line.length === 0 ? line : prefix + line`), so a blank
-- separator between declarations does not become a line of trailing spaces.
--: (block: string, prefix: string) -> string
local function indent(block, prefix)
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	-- `gmatch` with an optional-content pattern over `block .. "\n"` yields
	-- every line including empty ones, and exactly as many as `block` has.
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

-- `meta.description` as a ReScript doc comment with its trailing newline, or
-- the empty string when there is none.
--: (meta: Meta) -> string
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return "" end
	return "/** " .. description .. " */\n"
end

-- `meta.deprecated` as ReScript's compiler-recognized `@deprecated` attribute:
-- bare for `true`, with a reason string when the value is a string. Same
-- convention `type_ref_rescript_native`'s own `deprecated_attr` applies.
--: (meta: Meta) -> string
local function deprecated_attr(meta)
	local deprecated = meta.deprecated
	if deprecated == true then return "@deprecated\n" end
	if type(deprecated) == "string" then
		return "@deprecated(" .. codegen.quote(deprecated) .. ")\n"
	end
	return ""
end

-- ── Signature rendering ──────────────────────────────────────────────────────

-- A synthetic type-ir `function` TypeRef built from ffi-ir params/return (plus
-- an optional receiver as `thisType`), so that `rescript_type_from_type_ref` —
-- used unmodified — does 100% of the actual signature rendering, including
-- prepending the receiver as a leading positional parameter for methods.
--
-- The two branches differ only in whether `thisType` is PRESENT: omitted (not
-- set to nil) when there is no receiver, matching the TS's conditional spread,
-- so the projector's `s.thisType ~= nil` test sees exactly what the TS's
-- `thisType === undefined` test does.
--: (params: FfiParam[], return_type: TypeRef, receiver: string | nil) -> TypeRef
local function synthetic_function_ref(params, return_type, receiver)
	local copied = {} --[[: { [integer]: FfiParam } ]]
	for i = 1, #params do
		copied[i] = { name = params[i].name, type = params[i].type }
	end

	if receiver == nil then
		return type_ref.type_ref_from_shape(
			{ kind = "function", params = copied, returnType = return_type }, {})
	end

	local this_type = type_ref.type_ref_from_shape({ kind = "ref", target = receiver }, {})
	return type_ref.type_ref_from_shape(
		{ kind = "function", params = copied, returnType = return_type, thisType = this_type }, {})
end

-- ── Function / method ────────────────────────────────────────────────────────

-- Free function -> a `@module`/`@val` external, per the header's naming
-- judgment call. `js_module`, when given, is the enclosing `module` kind's raw
-- JS name, passed through to `@module(...)` VERBATIM and NOT PascalCased —
-- that is a JS module specifier / npm package / relative path string, not a
-- ReScript identifier.
--: (name: string, shape: FfiFunctionLike, meta: Meta, js_module: string | nil) -> string
local function build_function(name, shape, meta, js_module)
	local signature = rescript.rescript_type_from_type_ref(
		synthetic_function_ref(shape.params, shape.returnType, nil))
	local attr = "@val"
	if js_module ~= nil then attr = "@module(" .. codegen.quote(js_module) .. ")" end
	return doc_comment(meta) .. deprecated_attr(meta) .. attr .. "\nexternal " ..
		external_ident(name) .. ": " .. signature .. " = " .. codegen.quote(name)
end

-- Method -> a `@send` external. Verified in the header: the receiver is the
-- function type's first positional parameter, not a special calling form —
-- realized here by giving `synthetic_function_ref` the receiver as `thisType`,
-- which `type_ref_rescript_native`'s `function` handler already prepends.
--
-- `js_name` is the JS-side method name the declaration binds to, taken
-- separately from `name` (the ReScript-side binding identifier) because
-- `build_resource` prefixes the latter and must not touch the former — see
-- divergence (2) in the header.
--: (name: string, js_name: string, shape: FfiFunctionLike, meta: Meta, receiver: string | nil) -> string
local function build_method(name, js_name, shape, meta, receiver)
	local signature = rescript.rescript_type_from_type_ref(
		synthetic_function_ref(shape.params, shape.returnType, receiver))
	return doc_comment(meta) .. deprecated_attr(meta) .. "@send\nexternal " ..
		external_ident(name) .. ": " .. signature .. " = " .. codegen.quote(js_name)
end

-- ── Resource ─────────────────────────────────────────────────────────────────

-- Resource -> an opaque `type Name` (the manual's own documented "this type
-- exists in JS, structure not modeled" idiom) plus one `@send` external per
-- entry in `methods`, all at the SAME nesting level the resource's own `type`
-- declaration is emitted at — `build_module` wraps a whole boundary module's
-- resources and functions together in one ReScript `module` block, so that is
-- the namespacing unit, not a per-resource wrapper here.
--
-- Deliberately does NOT invent a constructor/`@new` binding: ffi-ir's
-- `resource` kind has no separate constructor field, only a `methods` map,
-- uniformly receiver-based — the exact gap fractal's wasm-bindgen backend
-- already lives with. Matching that precedent rather than inventing a
-- ReScript-only constructor notion the schema does not carry.
--
-- NAMING. The `type` is named `to_pascal_case(name)` to line up with how a
-- `{ kind = "ref", target = name }` TypeRef renders elsewhere (see
-- `to_pascal_case`'s own note for the one case where the two can part ways) —
-- that is what lets a `ffi_ir.resource_ref(name, ...)` used as a
-- parameter/return type resolve to the SAME identifier this opaque type
-- declares, with no string patching to bridge them. Method binding identifiers
-- are prefixed with the decapitalized resource name (`bufferRead`, not bare
-- `read`) because a resource's `methods` keys are unique only WITHIN one
-- resource, not across a whole module's flat ReScript declaration namespace —
-- two resources both having `close` would otherwise collide at the top level.
-- That prefixing is a style choice to avoid the collision, not a schema
-- requirement.
--
-- The shape is taken as the structural record this function actually reads
-- rather than as ffi_ir's `FfiResourceShape` alias: the alias pins `kind` to
-- the literal `"resource"`, and the value reaching here is an `FfiShape` whose
-- `kind` is a plain `string`, which no checked cast can narrow. Same reason the
-- sibling backends spell their resource/module shapes structurally.
--: (name: string, shape: { methods: { [string]: FfiRef }, ... }, meta: Meta) -> (string | nil, string | nil)
local function build_resource(name, shape, meta)
	local type_name = to_pascal_case(name)

	local type_decl = "type " .. type_name
	local description = meta.description
	if type(description) == "string" then
		type_decl = "/** " .. description .. " */\n" .. type_decl
	end

	local parts = { type_decl } --[[: { [integer]: string } ]]

	local method_names = ordered_keys(shape.methods)
	for i = 1, #method_names do
		local method_name = method_names[i]
		local method_ref = shape.methods[method_name]
		local kind = method_ref.shape.kind
		if kind ~= "method" and kind ~= "function" then
			return nil,
				'to_rescript_ffi: resource method "' .. method_name .. '" has unexpected kind "' ..
				kind .. '" (expected "method")'
		end
		-- The receiver is bound explicitly to this resource's own name rather
		-- than read off the method shape's `receiver`, which may be unset when
		-- the method was built without wiring `receiver` through the resource —
		-- this function's caller already knows which resource this is.
		parts[#parts + 1] = build_method(
			decapitalize(type_name) .. to_pascal_case(method_name),
			method_name,
			method_ref.shape --[[: FfiFunctionLike]],
			method_ref.meta,
			name
		)
	end

	return table.concat(parts, "\n\n")
end

-- ── Module ───────────────────────────────────────────────────────────────────

-- True when `kind` is `target` or has it as an ancestor in ffi-ir's OWN kind
-- lattice (`ffi_ir.ancestors` — the boundary-kind lattice, NOT type_ref's
-- data-shape one, which is what `type_ref_codegen.is_a` walks).
--: (kind: string, target: string) -> boolean
local function is_a(kind, target)
	if kind == target then return true end
	local chain = ffi_ir.ancestors(kind)
	for i = 1, #chain do
		if chain[i] == target then return true end
	end
	return false
end

-- Module -> a ReScript `module Name = { ... }` block grouping the resources and
-- functions exported at one FFI boundary. ReScript modules are a core,
-- always-available grouping construct (not itself a binding-specific attribute
-- needing separate verification), and this mirrors the "wrap the boundary's
-- declarations in the target's native grouping construct" choice fractal's
-- wasm-bindgen backend makes with `pub mod`.
--
-- The module's raw `name` (a JS module specifier/package name, e.g. `"fs"`,
-- `"node:path"`) is threaded down as `js_module` for the `@module(...)`
-- attributes on the functions inside — see `build_function` and the header's
-- naming note. Resources are emitted before functions, as in the TS source.
--: (name: string, shape: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }) -> (string | nil, string | nil)
local function build_module(name, shape)
	local parts = {} --[[: { [integer]: string } ]]

	local res_names = ordered_keys(shape.resources)
	for i = 1, #res_names do
		local res_name = res_names[i]
		local res_ref = shape.resources[res_name]
		local decl, err = build_resource(
			res_name,
			res_ref.shape --[[: { methods: { [string]: FfiRef }, ... }]],
			res_ref.meta
		)
		if decl == nil then return nil, err end
		parts[#parts + 1] = decl
	end

	local fn_names = ordered_keys(shape.functions)
	for i = 1, #fn_names do
		local fn_name = fn_names[i]
		local fn_ref = shape.functions[fn_name]
		if not is_a(fn_ref.shape.kind, "function") then
			return nil,
				'to_rescript_ffi: module function "' .. fn_name .. '" has unexpected kind "' ..
				fn_ref.shape.kind .. '" (expected "function")'
		end
		parts[#parts + 1] = build_function(
			fn_name, fn_ref.shape --[[: FfiFunctionLike]], fn_ref.meta, name)
	end

	return "module " .. to_pascal_case(name) .. " = {\n" ..
		indent(table.concat(parts, "\n\n"), "  ") .. "\n}"
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower an ffi-ir `FfiRef` to ReScript `external`/`type` declaration source
-- text.
--
-- `name` is required for `function`/`method`/`resource` (all named
-- declarations) and for `module` (the ReScript module name). Never fails for
-- an ownership discipline — see the header's ownership note; every discipline
-- lowers identically, since JS/ReScript's FFI has no ownership concept of its
-- own to gate against.
--
-- Returns `(nil, errmsg)` for a missing name, a malformed methods-map or
-- functions-map entry, or a kind with neither a handler nor a known ancestor.
--: (ref: FfiRef, name: string | nil) -> (string | nil, string | nil)
function M.to_rescript_ffi(ref, name)
	local kind = ref.shape.kind

	if name == nil then
		return nil,
			'to_rescript_ffi: "' .. kind .. '" requires a name — ReScript externals/types/modules ' ..
			"are named declarations, not anonymous inline expressions"
	end

	if kind == "function" then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta, nil)
	end

	if kind == "method" then
		local shape = ref.shape --[[: { params: FfiParam[], returnType: TypeRef, receiver: string, ... }]]
		return build_method(name, name, ref.shape --[[: FfiFunctionLike]], ref.meta, shape.receiver)
	end

	if kind == "resource" then
		return build_resource(
			name,
			ref.shape --[[: { methods: { [string]: FfiRef }, ... }]],
			ref.meta
		)
	end

	if kind == "module" then
		return build_module(
			name,
			ref.shape --[[: { functions: { [string]: FfiRef }, resources: { [string]: FfiRef }, ... }]]
		)
	end

	-- An extension-registered kind whose ancestor chain reaches `function` is
	-- rendered as one — the ancestor-fallback the ffi-ir lattice exists for.
	if is_a(kind, "function") then
		return build_function(name, ref.shape --[[: FfiFunctionLike]], ref.meta, nil)
	end

	return nil, 'to_rescript_ffi: unhandled ffi-ir kind "' .. kind .. '" (no handler and no known ancestor)'
end

-- Re-exported so a caller rendering a boundary declaration and a bare type
-- expression side by side reaches one projector, not two — the TS source's own
-- `export { toReScriptType }`, kept because dropping it would silently narrow
-- this module's public surface relative to the file it ports.
M.rescript_type_from_type_ref = rescript.rescript_type_from_type_ref

return M
