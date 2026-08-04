-- lib/fractal/type_ref_gleam_native.lua — the Gleam (https://gleam.run/)
-- type-declaration projector, ported from fractal's
-- packages/type-ir/src/gleam-native.ts.
--
-- fractal's file establishes Gleam's constraints directly from Gleam's own
-- documentation (The Gleam Language Tour, https://tour.gleam.run/, and
-- gleam_stdlib's hexdocs) rather than carrying them over from another
-- projector. That reasoning is what the code below IS, so it is carried
-- across rather than left behind with the TypeScript:
--
--   - Gleam's ONLY structural declaration mechanism is the custom type:
--     `pub type Name(a, b) { Ctor1(field: T) Ctor2(other: U) }`. There is no
--     separate "record" keyword — a record is just a custom type with a
--     single constructor and labelled fields
--     (https://tour.gleam.run/data-types/records/) — and there is no
--     anonymous/inline structural type of any kind: no inline `{ field: T }`
--     object-literal type, no inline union. Every `object`, `enum`, `union`
--     and `interface` TypeRef therefore has to be HOISTED into its own named
--     top-level declaration, even when nested inside a field. This is the
--     single fact that shapes the whole module: everything below the
--     `gleam_type_from_type_ref` section exists to do that hoisting.
--   - Generics: `pub type Box(a) { Box(value: a) }` — type parameters are
--     lowercase names in parens after the type name
--     (https://tour.gleam.run/data-types/custom-types/). Not used by this
--     projector's own generated declarations (TypeRef carries no notion of a
--     type PARAMETER, only concrete structure), but relevant to how
--     `Option`/`List`/`Dict` are themselves generic.
--   - `Option(a)` (`Some(a)` / `None`) and `Result(value, error)` are ordinary
--     custom types from `gleam/option` and Gleam's prelude respectively —
--     Gleam has no null/undefined and no built-in nullable sugar
--     (https://tour.gleam.run/standard-library/option-module/).
--   - Tuples: `#(a, b, ...)` at both value and type level, arbitrary arity
--     (https://tour.gleam.run/data-types/tuples/) — no degrade-at-high-arity
--     is needed the way an Elm target would require.
--   - `List(a)` is Gleam's only sequence type; `Dict(k, v)` (from
--     `gleam/dict`) is its map type.
--   - `Dynamic` (from `gleam/dynamic`) is Gleam's escape hatch for data whose
--     type isn't known at compile time — the natural target for `unknown`.
--   - No subtyping, no interfaces/traits, no inheritance: a `type` is always
--     a leaf in a flat namespace. `intersection`, `instance` and `interface`
--     all degrade or synthesize accordingly (see their handlers below).
--
-- This module does NOT require `lib/fractal/type_ref_kinds_common.lua`, and
-- that is deliberate — it matches fractal, where no projector imports the
-- kind modules itself; the CONSUMER opts into the refined lattice. The
-- consequence is worth stating because there are no handlers here for any
-- refined kind: once a consumer has required the kinds module, a `uuid`
-- renders as `String` and an `int32` as `Int` purely by the lattice falling
-- back through `resolve` to the `string`/`integer` handlers. Without it, both
-- are unregistered roots and degrade to `Dynamic`.
--
-- Divergences from the TypeScript, all of them forced:
--
--   - FIELD ORDER. fractal iterates `Object.entries(shape.fields)` /
--     `.methods`, i.e. JS insertion order. Lua tables have no insertion order
--     to recover, so field/method order here is byte order of the names —
--     the same deterministic stand-in `type_ref.lua` adopted for
--     `child_type_refs`/`walk_type_ref`, and for the same reason (`pairs()`
--     alone would make emitted source vary between runs). The emitted SET of
--     fields, constructors and hoisted declarations is identical either way;
--     only their order within a declaration can differ from fractal's.
--   - NULL LITERALS. `literal(null)` is `literal(type_ref.null)` in Lua —
--     the shared sentinel, since Lua has no value distinct from absence. The
--     `literal` handler tests for it by identity before anything else,
--     standing in for the TS's `s.value === null`.
--   - `Number.isInteger(v)` becomes `type(v) == "number" and v % 1 == 0`,
--     with any non-number value falling through to `Float` exactly as
--     `Number.isInteger` returning false does.
--
-- One fidelity note that is NOT a divergence: fractal's hoisting section
-- comment says declarations are hoisted out of "a field, array/list element,
-- tuple slot, or map key/value". The code hoists from field and array/stream/
-- page element positions only — a nested object inside a `tuple` slot or a
-- `map` value renders as `Dynamic`, since those positions go through
-- `gleam_type_from_type_ref`, not `bare_type`. Verified against the
-- TypeScript, and reproduced here; the comment overstates what the code does,
-- and the code is what a port has to match.
--
-- Both public functions are total. Every kind degrades (`Dynamic`/`Nil`)
-- rather than failing, so neither returns `(nil, errmsg)` — inventing a
-- failure channel the source has no way to reach would be a lie about the
-- contract.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")
local codegen = require("lib.fractal.type_ref_codegen")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }
--:: Param = { name: string, type: TypeRef }

-- TYPECHECKER WORKAROUND: every list-of-string in this file is spelled
-- `{ [integer]: string }` where the natural spelling is `string[]`. The `T[]`
-- sugar desugars to a NUMBER indexer (`{ [number]: string }`), and
-- `table.concat`'s stdlib declaration requires an INTEGER one
-- (`lib/type/static/stdlib_types.lua`: `concat: (t: { [integer]: string |
-- number, ... }, ...)`), so no `string[]` value can be passed to
-- `table.concat` at all — and this module's whole output path is
-- `table.concat` over accumulated lines. Revert to `string[]` once the sugar
-- and the stdlib declaration agree. (`lib/fractal/type_ref_rust_wasm_bindgen.lua`
-- carries the same workaround, arrived at independently.)
--:: StringList = { [integer]: string }

-- An inline type-expression renderer for one kind. Looked up through
-- `type_ref.resolve`, so a kind with no entry falls back to its nearest
-- ancestor's renderer.
--:: Converter = (shape: TypeShape, meta: Meta) -> string

-- ── Naming ───────────────────────────────────────────────────────────────────
--
-- Gleam requires snake_case for field labels and values, PascalCase for type
-- names and constructors (https://tour.gleam.run/basics/custom-types/: "Both
-- the type name and the names of the constructors start with uppercase
-- letters"; labelled fields throughout the Tour and stdlib are snake_case).
-- IR field/member names are wire-format strings — arbitrary camelCase,
-- kebab-case, whatever the source used — converted here the same way a Rust
-- target converts for Rust's identical casing convention, but WITHOUT an
-- equivalent to serde's `#[serde(rename = "...")]`: this projector emits type
-- declarations only, no codec, so there is nothing to keep a wire-format name
-- in sync with. The converted identifier simply IS the declaration.

-- Gleam's reserved words, collected from the Gleam Language Tour's keyword
-- usages. Gleam has no documented raw-identifier escape for a colliding name
-- (unlike Rust's `r#ident`), so a collision is resolved with a trailing
-- underscore — the safe fallback used wherever a target offers no native
-- escape.
--
-- Every key is bracketed so that `else` and `if`, which are Lua keywords, sit
-- among the rest rather than being singled out.
local GLEAM_KEYWORDS = {
	["as"] = true, ["assert"] = true, ["auto"] = true, ["case"] = true,
	["const"] = true, ["delegate"] = true, ["derive"] = true, ["echo"] = true,
	["else"] = true, ["fn"] = true, ["if"] = true, ["implement"] = true,
	["import"] = true, ["let"] = true, ["macro"] = true, ["opaque"] = true,
	["panic"] = true, ["pub"] = true, ["test"] = true, ["todo"] = true,
	["type"] = true, ["use"] = true,
} --[[: { [string]: boolean }]]

--: (snake_name: string) -> string
local function escape_gleam_ident(snake_name)
	if GLEAM_KEYWORDS[snake_name] then return snake_name .. "_" end
	return snake_name
end

--: (string) -> string
local function field_label(name)
	return escape_gleam_ident(codegen.snake_case_strip_separators(name))
end

-- A record's string keys in a deterministic order (byte order). See this
-- file's header for why fractal's insertion order cannot be reproduced, and
-- `type_ref.lua`'s `ordered_keys` for the same reasoning applied to
-- traversal. Duplicated rather than shared because that one is module-local
-- to `type_ref.lua`; the two are independent uses of the same convention, not
-- one helper wanting a home.
--: ({ [string]: unknown }) -> StringList
local function ordered_keys(t)
	local out = {}
	local n = 0
	for k in pairs(t) do
		if type(k) == "string" then
			n = n + 1
			out[n] = k
		end
	end
	table.sort(out)
	return out
end

-- ── Inline type-expression rendering ─────────────────────────────────────────

--: (string) -> Converter
local function leaf(name)
	--: Converter
	return function(_shape, _meta)
		return name
	end
end

-- Render the element of an `array`/`stream`/`page` shape as `List(T)`.
-- Shared by three handlers whose bodies are otherwise identical.
--: Converter
local function list_of_element(shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return "List(" .. M.gleam_type_from_type_ref(s.element) .. ")"
end

-- A `typeName`/`enumName` in `meta` names an already-declared type, so an
-- inline occurrence renders as that name; without one there is no name to
-- refer to and no anonymous syntax to inline into, so it degrades to
-- `Dynamic`. The real (named) declaration-generating path is `hoist.bare_type`
-- below, used in field and element positions that DO carry a name hint.
--: (Meta, string) -> string
local function named_or_dynamic(meta, meta_key)
	local name = meta[meta_key]
	if type(name) == "string" then return codegen.pascal_case_strip_separators(name) end
	return "Dynamic"
end

local handlers = {
	boolean = leaf("Bool"),
	number = leaf("Float"),
	integer = leaf("Int"),
	string = leaf("String"),

	-- Gleam has no null/undefined — `Nil` is its single unit-like "no
	-- meaningful value" value, the role `()` plays in an Elm or Rust target's
	-- own `null`/`void` handlers.
	null = leaf("Nil"),
	void = leaf("Nil"),

	-- `Dynamic` (gleam/dynamic) — see the file header.
	unknown = leaf("Dynamic"),

	-- Gleam has no bottom/uninhabited type (no `Never`/`Infallible` analogue
	-- in its prelude or stdlib) — degrades to `Nil`. This one is lossier than
	-- most (Elm's `Never` and Rust's `std::convert::Infallible` are both
	-- genuinely uninhabited; `Nil` is not), flagged here rather than silently
	-- presented as an exact fit.
	never = leaf("Nil"),

	-- A class instance carries only nominal identity (className /
	-- declarationFile), never structure — referenced by className, trusting a
	-- type of that name is declared or imported elsewhere.
	--: Converter
	instance = function(shape, _meta)
		local s = shape --[[: { className: string, ... }]]
		return s.className
	end,

	array = list_of_element,

	-- No streaming construct in Gleam's type system — materializes to
	-- `List(T)`.
	stream = list_of_element,
	page = list_of_element,

	-- `#(a, b, ...)` — Gleam tuples have no arity cap, so every arity renders
	-- directly.
	--: Converter
	tuple = function(shape, _meta)
		local s = shape --[[: { elements: TypeRef[], ... }]]
		local parts = {}
		for i = 1, #s.elements do
			parts[i] = M.gleam_type_from_type_ref(s.elements[i])
		end
		return "#(" .. table.concat(parts, ", ") .. ")"
	end,

	-- `Dict(k, v)` from gleam/dict.
	--: Converter
	map = function(shape, _meta)
		local s = shape --[[: { key: TypeRef, value: TypeRef, ... }]]
		return "Dict(" .. M.gleam_type_from_type_ref(s.key) .. ", " .. M.gleam_type_from_type_ref(s.value) .. ")"
	end,

	--: Converter
	object = function(_shape, meta)
		return named_or_dynamic(meta, "typeName")
	end,

	--: Converter
	enum = function(_shape, meta)
		return named_or_dynamic(meta, "enumName")
	end,

	--: Converter
	union = function(_shape, meta)
		return named_or_dynamic(meta, "typeName")
	end,

	-- Gleam has no interface/trait/mixin construct — but unlike `instance`
	-- (pure nominal identity, no structure to preserve) an `interface`'s
	-- `methods` map IS expressible: Gleam functions are first-class values, so
	-- a record of function-typed fields is a faithful (if unenforced — there
	-- is no vtable or dispatch, just a plain value) rendering rather than an
	-- opaque degrade. Hoisted like `object`; see `hoist.bare_type`.
	--: Converter
	interface = function(_shape, meta)
		return named_or_dynamic(meta, "typeName")
	end,

	-- Gleam has no literal-value type — degrades to the literal's base type.
	--: Converter
	literal = function(shape, _meta)
		local value = (shape --[[: { value: unknown, ... }]]).value
		if value == type_ref.null then return "Nil" end
		if type(value) == "string" then return "String" end
		if type(value) == "boolean" then return "Bool" end
		if type(value) == "number" and value % 1 == 0 then return "Int" end
		return "Float"
	end,

	--: Converter
	ref = function(shape, _meta)
		local s = shape --[[: { target: string, ... }]]
		return codegen.pascal_case_strip_separators(s.target)
	end,

	-- No struct-merge/mixin construct in Gleam, and no anonymous record syntax
	-- to splice a merge into even if the field types were combined — degrades
	-- to the first member's own rendering.
	--: Converter
	intersection = function(shape, _meta)
		local s = shape --[[: { members: TypeRef[], ... }]]
		local first = s.members[1]
		if first == nil then return "Dynamic" end
		return M.gleam_type_from_type_ref(first)
	end,

	-- Gleam function TYPES: `fn(ParamType, ...) -> ReturnType` — no parameter
	-- names in type position (https://tour.gleam.run/functions/functions/'s
	-- `fn` syntax, types-only form). `thisType`, if present, has no receiver
	-- position in Gleam (functions are not methods of a type), so it is
	-- prepended as a leading parameter.
	--
	-- `method` has no entry of its own: `type_ref.lua` registers `method`'s
	-- parent as `function`, so `resolve` lands here.
	--
	-- Written with a bracketed key because `function` is a Lua keyword and
	-- cannot be a bare table-literal key. (`type_ref.types` solves the same
	-- collision by renaming to `function_`; that is not an option here — this
	-- key must match the kind name `resolve` looks up.)
	--: Converter
	["function"] = function(shape, _meta)
		local s = shape --[[: { params: Param[], returnType: TypeRef, thisType: TypeRef | nil, ... }]]
		local parts = {}
		local n = 0
		local this_type = s.thisType
		if this_type ~= nil then
			n = 1
			parts[1] = M.gleam_type_from_type_ref(this_type)
		end
		for i = 1, #s.params do
			n = n + 1
			parts[n] = M.gleam_type_from_type_ref(s.params[i].type)
		end
		return "fn(" .. table.concat(parts, ", ") .. ") -> " .. M.gleam_type_from_type_ref(s.returnType)
	end,
} --[[: { [string]: Converter }]]

-- `meta.optional` (may be absent from the wire) and `meta.nullable` (present
-- but may carry JSON `null`) both collapse onto Gleam's single `Option(T)`.
-- Gleam has no null/undefined at all, so there is no second representation
-- for "missing key" distinct from "null value" — both map onto the one
-- `Option` wrap rather than `Option(Option(T))`.
--
-- fractal repeats this ternary at its two use sites (`toGleamType` and
-- `fieldType`); it is one function here because both sites want the identical
-- rule and neither should be able to drift.
--: (Meta, string) -> string
local function option_wrapped(meta, base)
	if meta.optional == true or meta.nullable == true then
		return "Option(" .. base .. ")"
	end
	return base
end

-- The inline Gleam type expression for `ref`.
--: (TypeRef) -> string
function M.gleam_type_from_type_ref(ref)
	local converter = type_ref.resolve(ref.shape.kind, handlers)
	if converter == nil then return option_wrapped(ref.meta, "Dynamic") end
	return option_wrapped(ref.meta, converter(ref.shape, ref.meta))
end

-- ── Declaration rendering ────────────────────────────────────────────────────

-- `///` doc lines followed by an `@deprecated` attribute, for whichever of
-- `meta.description` / `meta.deprecated` are present.
--
-- The description is split on "\n" preserving empty segments, matching JS
-- `String.split`: a description of "a\n\nb" produces three lines, the middle
-- one a bare `/// `. A `gmatch("[^\n]+")` loop would silently drop it.
--: (Meta) -> StringList
local function doc_comment(meta)
	local lines = {}
	local n = 0
	local description = meta.description
	if type(description) == "string" then
		local start = 1
		while true do
			local nl = description:find("\n", start, true)
			n = n + 1
			if nl == nil then
				lines[n] = "/// " .. description:sub(start)
				break
			end
			lines[n] = "/// " .. description:sub(start, nl - 1)
			start = nl + 1
		end
	end
	local deprecated = meta.deprecated
	if deprecated == true then
		lines[n + 1] = '@deprecated("Deprecated.")'
	elseif type(deprecated) == "string" then
		lines[n + 1] = "@deprecated(" .. codegen.quote(deprecated) .. ")"
	end
	return lines
end

-- A custom type of nullary constructors, one per member.
--: (string, TypeRef) -> string
local function build_enum(name, ref)
	local shape = ref.shape --[[: { members: StringList, ... }]]
	local lines = doc_comment(ref.meta)
	local n = #lines + 1
	lines[n] = "pub type " .. name .. " {"
	for i = 1, #shape.members do
		n = n + 1
		lines[n] = "  " .. codegen.pascal_case_strip_separators(shape.members[i])
	end
	lines[n + 1] = "}"
	return table.concat(lines, "\n")
end

-- A record of function-typed fields — see the `interface` handler above for
-- why this is a faithful rendering rather than an opaque degrade. Takes no
-- `decls`: a method's type is always a `function`, which renders inline and
-- never hoists.
--: (string, TypeRef) -> string
local function build_interface_record(name, ref)
	local shape = ref.shape --[[: { methods: { [string]: TypeRef }, ... }]]
	local method_names = ordered_keys(shape.methods)
	local lines = doc_comment(ref.meta)
	local n = #lines + 1
	lines[n] = "pub type " .. name .. " {"
	if #method_names == 0 then
		lines[n + 1] = "  " .. name
	else
		local fields = {}
		for i = 1, #method_names do
			local method_name = method_names[i]
			local method_ref = shape.methods[method_name]
			fields[i] = field_label(method_name) .. ": " .. M.gleam_type_from_type_ref(method_ref)
		end
		lines[n + 1] = "  " .. name .. "(" .. table.concat(fields, ", ") .. ")"
	end
	lines[n + 2] = "}"
	return table.concat(lines, "\n")
end

-- ── Named-declaration hoisting ───────────────────────────────────────────────
--
-- Every `object`/`enum`/`union`/`interface` TypeRef reached from a field or an
-- array/stream/page element gets its own top-level `pub type` declaration
-- (Gleam has no anonymous structural syntax at all — see the file header),
-- collected into `decls`. `decls` is threaded by reference and appended to as
-- the recursion unwinds, so a nested declaration lands BEFORE the declaration
-- that refers to it: the inner `build_*` call completes (pushing its own
-- children) before its result is pushed.
--
-- The functions below are mutually recursive — `bare_type` calls the
-- builders, `build_record`/the union builders call back into `field_type` and
-- `bare_type` — so they hang off a table rather than being plain locals. Lua
-- has no forward declaration for a local function, and an annotated
-- forward local cannot be left nil-initialized.

local hoist = {}

-- The `name_hint`-derived declaration for `ref`, returning the type expression to
-- use in the referring position. Kinds that need no declaration fall through
-- to their inline handler.
--: (string, TypeRef, StringList) -> string
function hoist.bare_type(name_hint, ref, decls)
	local kind = ref.shape.kind
	local name = codegen.pascal_case_strip_separators(name_hint)
	if kind == "object" then
		local decl = hoist.build_record(name, ref, decls)
		decls[#decls + 1] = decl
		return name
	end
	if kind == "enum" then
		local decl = build_enum(name, ref)
		decls[#decls + 1] = decl
		return name
	end
	if kind == "union" then
		local decl = hoist.build_union(name, ref, decls)
		decls[#decls + 1] = decl
		return name
	end
	if kind == "interface" then
		local decl = build_interface_record(name, ref)
		decls[#decls + 1] = decl
		return name
	end
	if kind == "array" or kind == "stream" or kind == "page" then
		local s = ref.shape --[[: { element: TypeRef, ... }]]
		local element_kind = s.element.shape.kind
		if element_kind == "object" or element_kind == "enum" or element_kind == "union" or element_kind == "interface" then
			return "List(" .. hoist.bare_type(name_hint, s.element, decls) .. ")"
		end
		return "List(" .. M.gleam_type_from_type_ref(s.element) .. ")"
	end
	local converter = type_ref.resolve(kind, handlers)
	if converter == nil then return "Dynamic" end
	return converter(ref.shape, ref.meta)
end

-- Tagged or positional, per `meta.discriminator`. fractal inlines this choice
-- as a ternary at both of its call sites; it is one function here so the
-- narrowed discriminator string has exactly one place to be read and passed
-- on (see `build_tagged_union`).
--: (string, TypeRef, StringList) -> string
function hoist.build_union(name, ref, decls)
	local discriminator = ref.meta.discriminator
	if type(discriminator) == "string" then
		return hoist.build_tagged_union(name, ref, discriminator, decls)
	end
	return hoist.build_positional_union(name, ref, decls)
end

-- A field's type: `bare_type`'s hoisting plus the same single-`Option`
-- collapse `gleam_type_from_type_ref` applies.
--: (string, TypeRef, StringList) -> string
function hoist.field_type(name_hint, field_ref, decls)
	return option_wrapped(field_ref.meta, hoist.bare_type(name_hint, field_ref, decls))
end

-- A single-constructor custom type with labelled fields — Gleam's record.
-- An empty object becomes a nullary constructor, since `Name()` is not valid
-- Gleam.
--: (string, TypeRef, StringList) -> string
function hoist.build_record(name, ref, decls)
	local shape = ref.shape --[[: { fields: { [string]: TypeRef }, ... }]]
	local field_names = ordered_keys(shape.fields)
	local lines = doc_comment(ref.meta)
	local n = #lines + 1
	lines[n] = "pub type " .. name .. " {"
	if #field_names == 0 then
		lines[n + 1] = "  " .. name
	else
		local fields = {}
		for i = 1, #field_names do
			local field_name = field_names[i]
			local field_ref = shape.fields[field_name]
			local hint = name .. codegen.pascal_case_strip_separators(field_name)
			fields[i] = field_label(field_name) .. ": " .. hoist.field_type(hint, field_ref, decls)
		end
		lines[n + 1] = "  " .. name .. "(" .. table.concat(fields, ", ") .. ")"
	end
	lines[n + 2] = "}"
	return table.concat(lines, "\n")
end

-- A tagged union: every variant is an `object` sharing `meta.discriminator`
-- as a literal-string field. One constructor per variant, named from the
-- discriminant's literal value, carrying the variant's REMAINING fields as
-- labelled constructor fields — the discriminator field itself is dropped,
-- since the constructor tag already encodes it.
--
-- A variant that doesn't fit that shape (not an object, or no string-literal
-- tag field) falls back to a synthesized `Variant<i>` name rather than
-- aborting the union, so every union stays representable. `i` is 0-based, as
-- in fractal's `forEach` index.
--
-- `discriminator` is passed in rather than read off `ref.meta` here (where
-- fractal casts `ref.meta.discriminator as string`): both call sites already
-- test it to choose between the tagged and positional forms, so threading the
-- narrowed string through is what makes this function total without inventing
-- a stand-in value for the impossible non-string case.
--: (string, TypeRef, string, StringList) -> string
function hoist.build_tagged_union(name, ref, discriminator, decls)
	local shape = ref.shape --[[: { variants: TypeRef[], ... }]]
	local lines = doc_comment(ref.meta)
	local n = #lines + 1
	lines[n] = "pub type " .. name .. " {"

	for i = 1, #shape.variants do
		local variant = shape.variants[i]
		local index = i - 1
		if variant.shape.kind ~= "object" then
			local hint = name .. "Variant" .. index
			n = n + 1
			lines[n] = "  " .. hint .. "(" .. hoist.bare_type(hint, variant, decls) .. ")"
		else
			local variant_shape = variant.shape --[[: { fields: { [string]: TypeRef }, ... }]]
			local tag_field = variant_shape.fields[discriminator]
			local tag_value = "Variant" .. index --: string
			if tag_field ~= nil and tag_field.shape.kind == "literal" then
				local literal_value = (tag_field.shape --[[: { value: unknown, ... }]]).value
				if type(literal_value) == "string" then tag_value = literal_value end
			end
			local ctor_name = codegen.pascal_case_strip_separators(tag_value)
			local field_names = ordered_keys(variant_shape.fields)
			local fields = {}
			local field_count = 0
			for j = 1, #field_names do
				local field_name = field_names[j]
				if field_name ~= discriminator then
					local field_ref = variant_shape.fields[field_name]
					local hint = name .. ctor_name .. codegen.pascal_case_strip_separators(field_name)
					field_count = field_count + 1
					fields[field_count] = field_label(field_name) .. ": " .. hoist.field_type(hint, field_ref, decls)
				end
			end
			n = n + 1
			if field_count == 0 then
				lines[n] = "  " .. ctor_name
			else
				lines[n] = "  " .. ctor_name .. "(" .. table.concat(fields, ", ") .. ")"
			end
		end
	end

	lines[n + 1] = "}"
	return table.concat(lines, "\n")
end

-- The untagged-union fallback — one positionally-named constructor per
-- variant (`Variant0`, `Variant1`, ...), each wrapping that variant's own
-- rendered type as a single unlabelled constructor argument. Gleam, like Rust
-- and Elm, has no anonymous/untagged sum type, so a union with no shared
-- discriminator has no encoding other than a synthesized tag.
--: (string, TypeRef, StringList) -> string
function hoist.build_positional_union(name, ref, decls)
	local shape = ref.shape --[[: { variants: TypeRef[], ... }]]
	local lines = doc_comment(ref.meta)
	local n = #lines + 1
	lines[n] = "pub type " .. name .. " {"
	for i = 1, #shape.variants do
		local ctor_name = "Variant" .. (i - 1)
		n = n + 1
		lines[n] = "  " .. ctor_name .. "(" .. hoist.bare_type(name .. ctor_name, shape.variants[i], decls) .. ")"
	end
	lines[n + 1] = "}"
	return table.concat(lines, "\n")
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- The declaration for `ref` under the already-PascalCased `type_name`,
-- appending anything it hoists to `decls`. Split out of
-- `gleam_source_from_type_ref` (where fractal keeps it inline, assigning into
-- a `let mainDecl: string`) because Lua has no uninitialized typed local: an
-- early-returning function is how a value gets one type across five branches
-- without a placeholder that is never read.
--: (string, TypeRef, StringList) -> string
local function build_named_decl(type_name, ref, decls)
	local kind = ref.shape.kind
	if kind == "object" then return hoist.build_record(type_name, ref, decls) end
	if kind == "interface" then return build_interface_record(type_name, ref) end
	if kind == "enum" then return build_enum(type_name, ref) end
	if kind == "union" then return hoist.build_union(type_name, ref, decls) end
	-- Every other kind renders inline, so it needs no declaration of its own —
	-- only an alias to the inline expression.
	local lines = doc_comment(ref.meta)
	lines[#lines + 1] = "pub type " .. type_name .. " = " .. M.gleam_type_from_type_ref(ref)
	return table.concat(lines, "\n")
end

-- Lower `ref` to idiomatic Gleam source.
--
-- With `name`, emits a named top-level `pub type` declaration — a record
-- (single labelled constructor) for `object`, a record-of-functions for
-- `interface`, a nullary-constructor custom type for `enum`, a tagged or
-- positional custom type for `union` — preceded by any declarations hoisted
-- out of nested fields and elements, blank-line separated. For any other kind
-- (primitives, `array`, `tuple`, `map`, `ref`, ...) it emits a type alias,
-- `pub type Name = ...`, over the inline expression.
--
-- Without `name`, returns just the inline type expression for `ref` — i.e.
-- `gleam_type_from_type_ref` — the building block a caller assembling its own
-- declarations plugs into its own source.
--: (TypeRef, string | nil) -> string
function M.gleam_source_from_type_ref(ref, name)
	if name == nil then return M.gleam_type_from_type_ref(ref) end

	local decls = {} --: StringList
	local type_name = codegen.pascal_case_strip_separators(name)
	local main_decl = build_named_decl(type_name, ref, decls)
	decls[#decls + 1] = main_decl
	return table.concat(decls, "\n\n")
end

return M
