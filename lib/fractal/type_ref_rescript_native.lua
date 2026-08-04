-- lib/fractal/type_ref_rescript_native.lua — the native ReScript
-- type-declaration projector, ported from fractal's
-- packages/type-ir/src/rescript-native.ts.
--
-- Emits plain ReScript type syntax (records, variants, tuples, `option<T>`)
-- and no serialization glue. ReScript code that needs JSON codecs typically
-- reaches for a library (@glennsl/rescript-json, rescript-schema, …), so this
-- projector — like fractal's flow-native.ts/php-native.ts, and unlike
-- elm-json.ts, which must pair every type with a decoder/encoder because Elm
-- has no runtime reflection at all — stays on the type layer.
--
-- DESIGN CHOICE CARRIED ACROSS FROM THE TS HEADER, flagged rather than
-- silently decided. ReScript has TWO sum-type constructs:
--
--   * ordinary (nominal) variants — `type t = Foo | Bar(int)`, which must be
--     declared under a name and cannot appear as an anonymous inline type;
--   * polymorphic variants — `[#foo | #bar(int)]`, structurally typed, which
--     CAN appear inline with no prior declaration.
--
-- This projector renders `union`/`enum` as ORDINARY nominal variants, hoisted
-- to their own top-level declaration, exactly the way fractal's elm-json.ts
-- hoists Elm's (also nominal-only) custom types: a nested union/enum met
-- while rendering a field is lifted out to a synthetic top-level `type` and
-- the field just references it by name. Picked for consistency with the
-- sibling ML-family projector and because ordinary variants are the more
-- idiomatic, more widely tooled ReScript default (better pattern-match
-- exhaustiveness diagnostics, better behaviour with `@genType`/interop
-- tooling). The real alternative — inline polymorphic variants, avoiding
-- hoisting entirely and staying closer to how `union` behaves in the
-- structural projectors — is a genuine, differently-shaped design with its
-- own tradeoffs (no separate named declaration, but weaker exhaustiveness
-- checking, `#tag` payload syntax instead of `Ctor(payload)`, and a less
-- common idiom for closed, non-extensible sum types). Not chosen here.
--
-- Records get the same treatment for the same reason: ReScript record types,
-- like variants, must be declared under a name — there is no anonymous inline
-- record-TYPE syntax — so a nested `object` in field position is hoisted too.
-- (elm-json.ts needs no such hoisting because Elm's `{ field : T }` IS a
-- valid anonymous inline type.)
--
-- ── Divergences from the TS, all deliberate ─────────────────────────────────
--
-- 1. NO `currentRef` SIDE CHANNEL. The TS `Converter` signature carries only
--    `(shape, ctx, nameHint)`, but the `object`/`union`/`enum`/`intersection`
--    converters need the whole TypeRef, because hoisting is cached on TypeRef
--    IDENTITY. The TS bridges that with a module-level mutable `currentRef`
--    saved/restored around every `rescriptType` call. Here the converter
--    signature is widened to `(TypeRef, Ctx, string) -> string` and the side
--    channel is deleted: a converter that wants the shape reads `ref.shape`.
--    Same behaviour — the TS's save/restore discipline exists purely to make
--    the global behave like a parameter — with no module-level mutable state,
--    and so no reentrancy question to reason about at all. A structural
--    simplification, not a semantic change.
--
-- 2. DETERMINISTIC FIELD ORDER. The TS iterates `Object.entries(fields)`, i.e.
--    JS insertion order. Lua tables have no insertion order to recover, so
--    record fields, intersection merges, and tagged-union payloads are
--    emitted in byte order of the field names — the same stand-in, for the
--    same reason, that `type_ref.lua`'s `ordered_keys` documents.
--
--    It matters MORE here than it does there. Field order feeds the
--    `name_hint` sequence, which feeds `fresh_name`'s collision numbering, so
--    a different order does not merely reorder output lines — it can change
--    which hoisted type gets the bare name and which gets the `2` suffix.
--    Two sibling fields whose hints PascalCase to the same string is the only
--    case where that can happen; everything else is order-independent.
--
-- 3. `intersection`'s merge. The TS `Object.assign`es each object member's
--    fields in member order, so a later member's field wins a name clash;
--    that is preserved. What it cannot preserve is the resulting ITERATION
--    order, which byte order replaces per (2).
--
-- Both public entry points are total. Every kind this projector cannot
-- represent degrades explicitly (`Js.Json.t`, `unit`) rather than failing, so
-- they return a plain `string`, not the repo's `(nil, errmsg)` pair — there
-- is no failure mode in the source to model, and inventing one would make
-- every call site handle an error that cannot occur.
--
-- This module deliberately does NOT require `type_ref_kinds_common` — the
-- consumer opts into the refined-kind lattice, exactly as in fractal, where
-- no projector imports the kind modules itself. Once a consumer has required
-- it, `uuid` reaches this file's `string` handler and `int32` its `integer`
-- handler through `type_ref.resolve`'s ancestor walk, with no entry here.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")
local codegen = require("lib.fractal.type_ref_codegen")

local M = {}

-- ── Naming ───────────────────────────────────────────────────────────────────

-- ReScript field/variant-payload label rules: an identifier must start with a
-- lowercase letter or an underscore. A wire field name that is not a valid
-- bare label (numeric-leading, kebab-case, a reserved word, …) is written
-- with a sanitized label plus an explicit `@as("original")` attribute — the
-- standard ReScript escape hatch for "the JS/JSON key does not look like a
-- ReScript identifier".
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
} --: { [string]: boolean }

-- The TS is three JS regexes: `replace(/[^a-zA-Z0-9_]/g, "_")`, then
-- `/^[A-Z]/` to decapitalize a leading capital, then `/^[a-z_]/` to decide
-- whether an `_` prefix is needed. Translated one-for-one; the character
-- classes are spelled out (`A-Za-z`) rather than using Lua's `%a`, which is
-- locale-dependent.
--
-- The empty string is a real input (a field named `""`): it matches neither
-- test, falls through to the `_` prefix, and comes out `"_"` — as in JS.
--: (string) -> string
local function sanitize_label(name)
	local cleaned = name:gsub("[^A-Za-z0-9_]", "_")
	local lowered = cleaned
	if cleaned:match("^[A-Z]") ~= nil then
		lowered = cleaned:sub(1, 1):lower() .. cleaned:sub(2)
	end
	if lowered:match("^[a-z_]") ~= nil then return lowered end
	return "_" .. lowered
end

-- The label to write, and the `@as(...) ` prefix that must accompany it (the
-- empty string when the label is already a lossless, non-reserved rendering
-- of the wire name). Two returns rather than a record: the caller always
-- wants both, immediately, and never stores them.
--: (string) -> (string, string)
local function field_label(name)
	local label = sanitize_label(name)
	if label == name and not RESERVED[name] then return label, "" end
	return label, "@as(" .. codegen.quote(name) .. ") "
end

-- Decapitalizes just the leading character — the inverse of the trivial
-- "first letter uppercased" step of PascalCasing. Used to test whether a
-- constructor name is a LOSSLESS rendering of its member (a pure casing
-- difference, `"active"` -> `Active`) or one that actually dropped
-- information (`"in-progress"` -> `InProgress`; the hyphen is gone for good).
--: (string) -> string
local function decapitalize(name)
	if #name == 0 then return name end
	return name:sub(1, 1):lower() .. name:sub(2)
end

-- A record's keys in byte order. See divergence (2) in the header — this is
-- the deterministic stand-in for JS insertion order, and it is load-bearing
-- for hoisted type NAMES, not only for line order.
--: ({ [string]: TypeRef }) -> { [integer]: string }
local function ordered_keys(fields)
	local out = {} --: { [integer]: string }
	local n = 0
	for k in pairs(fields) do
		n = n + 1
		out[n] = k
	end
	table.sort(out)
	return out
end

-- ── Hoisting context ─────────────────────────────────────────────────────────

-- Shared across a single `rescript_source_from_type_ref` call so a nested
-- object/union/enum is declared once and every reference agrees on its name.
--
--   decls — fully-rendered top-level `type ... = ...` declarations for
--           hoisted nested records/unions/enums, in the order first
--           encountered. That is dependency order: hoisting happens
--           depth-first during rendering, so a referenced type is always
--           pushed before the type referencing it.
--   used  — names already claimed (the top-level name plus every hoisted
--           one), so a collision falls back to a numbered suffix.
--   names — TypeRef IDENTITY -> the name it was hoisted under. A Lua table
--           keys on identity natively, so this is the direct analogue of the
--           TS `Map<TypeRef, string>`; nothing is rebuilt or copied, which is
--           what keeps identity meaningful (the same property
--           `type_ref.lua`'s traversal comments rely on).
--
-- The key type is written `unknown` rather than `TypeRef` because an index
-- signature's key may only be `string`, `integer`, or `unknown` —
-- `{ [TypeRef]: string }` parses as a record with one field literally named
-- `TypeRef`. The `--[[: unknown]]` widening cast at the use site below is
-- what that annotation forces; it discards nothing the runtime relies on,
-- since a Lua table key is compared by identity regardless of its type.
--:: Ctx = { decls: { [integer]: string }, used: { [string]: boolean }, names: { [unknown]: string } }

--: () -> Ctx
local function new_ctx()
	return { decls = {}, used = {}, names = {} }
end

--: (Ctx, string) -> string
local function fresh_name(ctx, hint)
	-- `pascal_case_from_words` splits only on camelCase boundaries and
	-- `_`/`-`/whitespace runs, so it returns "" only for a hint that is empty
	-- or entirely separators — which is exactly when the TS's `|| "Anonymous"`
	-- falsiness test fires.
	local base = codegen.pascal_case_from_words(hint)
	if base == "" then base = "Anonymous" end
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

-- ── Type-expression rendering ────────────────────────────────────────────────

-- Widened from the TS's `(shape, ctx, nameHint)` — see divergence (1).
--:: Converter = (ref: TypeRef, ctx: Ctx, name_hint: string) -> string

-- Declared empty here and populated at the bottom of the file. The four
-- hoisting converters need `hoisted_name`, which needs `generate_named_type`,
-- which needs `rescript_type`, which dispatches through this table: one
-- genuine cycle, closed by a table whose contents are read at call time
-- rather than by a forward-declared function needing a cast at every call.
local type_handlers = {} --: { [string]: Converter }

--: (TypeRef, Ctx, string) -> string
local function rescript_type(ref, ctx, name_hint)
	-- TYPECHECKER WORKAROUND: the `--: Converter | nil` annotation should be
	-- redundant. `type_ref.resolve` is `<T>(string, { [string]: T }) -> T | nil`
	-- and `type_handlers` is `{ [string]: Converter }`, so `T` is pinned by the
	-- argument. Without the annotation the checker infers the result as `never`
	-- when `T` is instantiated at a FUNCTION type, and the call below is then
	-- reported as `cannot concatenate type 'never | string'`. (The same
	-- instantiation also leaks across call sites: a second `resolve` call in
	-- one file is checked against the first call's `T`.) Natural code is
	-- `local converter = type_ref.resolve(ref.shape.kind, type_handlers)`.
	local converter = type_ref.resolve(ref.shape.kind, type_handlers) --: Converter | nil
	local text = "Js.Json.t" --: string
	if converter ~= nil then text = converter(ref, ctx, name_hint) end
	if ref.meta.nullable == true then text = "option<" .. text .. ">" end
	return text
end

--: (string) -> Converter
local function leaf(text)
	--: (TypeRef, Ctx, string) -> string
	return function(_ref, _ctx, _hint)
		return text
	end
end

-- A ReScript record-field list, one entry per field. Used for hoisted named
-- record declarations and for tagged-union inline-record payloads; there
-- being no anonymous-record alternative, every `object` met in plain field
-- position is hoisted instead (see the `object` converter).
--: ({ [string]: TypeRef }, Ctx, string) -> { [integer]: string }
local function render_fields(fields, ctx, name_hint)
	local keys = ordered_keys(fields)
	local out = {} --: { [integer]: string }
	for i = 1, #keys do
		local field_name = keys[i]
		local field_ref = fields[field_name]
		local label, as_attr = field_label(field_name)
		local rendered = rescript_type(field_ref, ctx, name_hint .. codegen.pascal_case_from_words(field_name))
		if field_ref.meta.optional == true then rendered = "option<" .. rendered .. ">" end
		out[i] = as_attr .. label .. ": " .. rendered
	end
	return out
end

-- ── Named-declaration rendering ──────────────────────────────────────────────

-- A member whose PascalCased constructor name is more than a pure re-casing
-- of the original (kebab/snake case, a leading digit, …) gets an explicit
-- `@as("original")` tag — ReScript's documented mechanism for customizing a
-- variant constructor's runtime representation — so the exact wire string
-- stays recoverable. A plain casing difference (`"active"` -> `Active`) needs
-- no `@as`: decapitalizing the constructor name alone recovers the original.
--: (string) -> string
local function render_ctor(member)
	local name = codegen.pascal_case_from_words(member)
	if decapitalize(name) == member then return name end
	return "@as(" .. codegen.quote(member) .. ") " .. name
end

--: (string, { [integer]: string }) -> string
local function render_enum_like(type_name, members)
	local lines = {} --: { [integer]: string }
	for i = 1, #members do
		lines[i] = render_ctor(members[i])
	end
	return "type " .. type_name .. " =\n  | " .. table.concat(lines, "\n  | ")
end

-- A union whose every variant is a string `literal` (the TypeScript
-- "string literal union" idiom) renders as a no-payload variant, one
-- constructor per member — the same convention fractal's elm-json.ts uses.
-- Returns nil when `ref` is not such a union.
--: (TypeRef) -> { [integer]: string } | nil
local function string_literal_members(ref)
	if ref.shape.kind ~= "union" then return nil end
	local variants = (ref.shape --[[: { variants: TypeRef[], ... }]]).variants
	local members = {} --: { [integer]: string }
	for i = 1, #variants do
		local variant = variants[i]
		if variant.shape.kind ~= "literal" then return nil end
		local value = (variant.shape --[[: { value: unknown, ... }]]).value
		if type(value) ~= "string" then return nil end
		members[i] = value
	end
	return members
end

-- A tagged union: every variant is an `object`, and all carry the union's
-- `meta.discriminator` as a string-literal-valued field. Renders one
-- constructor per variant, named from the discriminant's literal value and
-- carrying the variant's REMAINING fields as an inline-record payload
-- (`Ctor({field: T, …})`, ReScript 10+ variant inline records). Returns nil
-- when any variant fails that shape, which sends the caller to the
-- positional fallback.
--: (string, string, TypeRef[], Ctx) -> string | nil
local function render_tagged_union(type_name, discriminator, variants, ctx)
	local tag_values = {} --: { [integer]: string }
	local ctors = {} --: { [integer]: string }
	local payloads = {} --: { [integer]: { [string]: TypeRef } }

	for i = 1, #variants do
		local variant = variants[i]
		if variant.shape.kind ~= "object" then return nil end
		local fields = (variant.shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
		local tag_ref = fields[discriminator]
		if tag_ref == nil then return nil end
		if tag_ref.shape.kind ~= "literal" then return nil end
		local tag_value = (tag_ref.shape --[[: { value: unknown, ... }]]).value
		if type(tag_value) ~= "string" then return nil end

		-- The TS's `{ ...fields }` shallow copy followed by
		-- `delete payload[discriminator]`. The discriminator is dropped from
		-- the payload because it is recovered by pattern-matching the
		-- constructor, not carried as data. Copying rather than mutating
		-- matters: `fields` belongs to the caller's TypeRef.
		local payload = {} --: { [string]: TypeRef }
		local keys = ordered_keys(fields)
		for j = 1, #keys do
			if keys[j] ~= discriminator then payload[keys[j]] = fields[keys[j]] end
		end

		tag_values[i] = tag_value
		ctors[i] = codegen.pascal_case_from_words(tag_value)
		payloads[i] = payload
	end

	-- Second pass, matching the TS: nothing is rendered — and so nothing is
	-- hoisted into `ctx` — until every variant has been accepted.
	local ctor_lines = {} --: { [integer]: string }
	for i = 1, #variants do
		local ctor = ctors[i]
		local tag = ctor
		if decapitalize(ctor) ~= tag_values[i] then
			tag = "@as(" .. codegen.quote(tag_values[i]) .. ") " .. ctor
		end
		local fields = render_fields(payloads[i], ctx, type_name .. ctor)
		if #fields == 0 then
			ctor_lines[i] = tag
		else
			ctor_lines[i] = tag .. "({" .. table.concat(fields, ", ") .. "})"
		end
	end
	return "type " .. type_name .. " =\n  | " .. table.concat(ctor_lines, "\n  | ")
end

-- The general (untagged) union fallback — one positionally-named constructor
-- per variant, each wrapping that variant's own rendered type as a single
-- positional payload. Numbering is 1-BASED here (`Variant1`, `Variant2`, …),
-- unlike the sibling projectors' `Variant0`; that is the TS's choice for this
-- target and is preserved.
--: (string, TypeRef[], Ctx) -> string
local function render_positional_union(type_name, variants, ctx)
	local ctors = {} --: { [integer]: string }
	for i = 1, #variants do
		ctors[i] = "Variant" .. tostring(i)
	end
	local payload_types = {} --: { [integer]: string }
	for i = 1, #variants do
		payload_types[i] = rescript_type(variants[i], ctx, type_name .. ctors[i])
	end
	local ctor_lines = {} --: { [integer]: string }
	for i = 1, #variants do
		ctor_lines[i] = ctors[i] .. "(" .. payload_types[i] .. ")"
	end
	return "type " .. type_name .. " =\n  | " .. table.concat(ctor_lines, "\n  | ")
end

-- A ReScript doc comment — `/** … */` immediately above the declaration —
-- driven by `meta.description`, the same open-metadata-bag convention the
-- sibling projectors' own `docComment` helpers use.
--: (Meta) -> string
local function doc_comment(meta)
	local description = meta.description
	if type(description) ~= "string" then return "" end
	return "/** " .. description .. " */\n"
end

-- `meta.deprecated` becomes a `@deprecated` ATTRIBUTE rather than a
-- doc-comment line, because ReScript (unlike Elm) has a real
-- compiler-recognized deprecation attribute.
--: (Meta) -> string
local function deprecated_attr(meta)
	local deprecated = meta.deprecated
	if deprecated == true then return "@deprecated\n" end
	if type(deprecated) == "string" then
		return "@deprecated(" .. codegen.quote(deprecated) .. ")\n"
	end
	return ""
end

-- The field set a record declaration renders: an `object`'s own fields, or an
-- `intersection`'s object members merged left-to-right (a later member wins a
-- name clash, matching the TS's `Object.assign` loop). A non-object member
-- contributes nothing.
--: (TypeRef) -> { [string]: TypeRef }
local function record_fields(ref)
	if ref.shape.kind == "object" then
		return (ref.shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
	end
	local members = (ref.shape --[[: { members: TypeRef[], ... }]]).members
	local merged = {} --: { [string]: TypeRef }
	for i = 1, #members do
		local member = members[i]
		if member.shape.kind == "object" then
			local fields = (member.shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
			local keys = ordered_keys(fields)
			for j = 1, #keys do
				merged[keys[j]] = fields[keys[j]]
			end
		end
	end
	return merged
end

-- A complete named declaration for `ref` under `name`: a record type, a
-- variant type (union/enum), or a plain type alias for anything else. Used
-- both for the top-level call and, recursively via `hoisted_name`, for nested
-- objects/unions/enums/intersections.
--: (TypeRef, string, Ctx) -> string
local function generate_named_type(ref, name, ctx)
	local type_name = codegen.pascal_case_from_words(name)
	local kind = ref.shape.kind
	local header = doc_comment(ref.meta) .. deprecated_attr(ref.meta)

	if kind == "enum" then
		local members = (ref.shape --[[: { members: { [integer]: string }, ... }]]).members
		return header .. render_enum_like(type_name, members)
	end

	-- `string_literal_members` already returns nil for a non-union, so the
	-- TS's separate `kind === "union" &&` guard is redundant here.
	local literal_members = string_literal_members(ref)
	if literal_members ~= nil then
		return header .. render_enum_like(type_name, literal_members)
	end

	if kind == "union" then
		local variants = (ref.shape --[[: { variants: TypeRef[], ... }]]).variants
		local discriminator = ref.meta.discriminator
		if type(discriminator) == "string" then
			local tagged = render_tagged_union(type_name, discriminator, variants, ctx)
			if tagged ~= nil then return header .. tagged end
		end
		return header .. render_positional_union(type_name, variants, ctx)
	end

	if kind == "object" or kind == "intersection" then
		local rendered = render_fields(record_fields(ref), ctx, type_name)
		-- A ReScript record type must have at least one field: records have no
		-- zero-field literal syntax. `{}` is not valid record syntax, and
		-- `{.}`/`{..}` are a structurally DIFFERENT construct (JS object
		-- types, not records) — emitting either here would be actively wrong,
		-- not merely a stylistic choice. A fields-less object therefore
		-- degrades to `unit`, the same "no information" convention
		-- `null`/`void`/`literal` already use.
		if #rendered == 0 then return header .. "type " .. type_name .. " = unit" end
		return header
			.. "type "
			.. type_name
			.. " = {\n  "
			.. table.concat(rendered, ",\n  ")
			.. ",\n}"
	end

	-- Any other kind (a primitive, array, tuple, map, ref, …) at the top
	-- level: a plain type alias to its rendered type.
	return header .. "type " .. type_name .. " = " .. rescript_type(ref, ctx, type_name)
end

-- The name previously hoisted for `ref` (by identity), hoisting it now —
-- rendering its full `type` declaration into `ctx.decls` — if this is the
-- first sighting.
--: (Ctx, TypeRef, string) -> string
local function hoisted_name(ctx, ref, name_hint)
	local key = ref --[[: unknown]]
	local cached = ctx.names[key]
	if cached ~= nil then return cached end
	local name = fresh_name(ctx, name_hint)
	ctx.names[key] = name
	ctx.decls[#ctx.decls + 1] = generate_named_type(ref, name, ctx)
	return name
end

-- ── Per-kind converters ──────────────────────────────────────────────────────

-- A nested object type has nowhere to inline to, so it is hoisted exactly
-- like a union/enum.
--: (TypeRef, Ctx, string) -> string
local function convert_object(ref, ctx, name_hint)
	return hoisted_name(ctx, ref, name_hint)
end

-- `array`, `stream` and `page` share a body: `stream` has no native
-- async-sequence construct and `page` no native window construct, so both
-- degrade to their array equivalent — the same honest-degrade convention the
-- sibling projectors use. Spelled as three entries, as in the TS, because the
-- kind lattice deliberately gives neither `array` as a parent.
--: (TypeRef, Ctx, string) -> string
local function convert_element_array(ref, ctx, name_hint)
	local element = (ref.shape --[[: { element: TypeRef, ... }]]).element
	return "array<" .. rescript_type(element, ctx, name_hint .. "Item") .. ">"
end

-- ReScript tuples are native and support arbitrary arity (unlike Elm, whose
-- tuple sugar tops out at 3), so `(a, b, c, d)` renders directly regardless
-- of element count.
--: (TypeRef, Ctx, string) -> string
local function convert_tuple(ref, ctx, name_hint)
	local elements = (ref.shape --[[: { elements: TypeRef[], ... }]]).elements
	local parts = {} --: { [integer]: string }
	for i = 1, #elements do
		parts[i] = rescript_type(elements[i], ctx, name_hint .. tostring(i - 1))
	end
	return "(" .. table.concat(parts, ", ") .. ")"
end

-- `Js.Dict.t<V>` is ReScript's standard dictionary and is string-keyed only,
-- so it is a faithful rendering for a STRING key and nothing else. The test
-- is on the exact kind, not on kind-lattice ancestry: a `uuid` key is
-- semantically a string but is not `string`, and takes the non-string branch.
-- That matches the TS, which likewise compares `s.key.shape.kind === "string"`
-- rather than calling `isA`.
--: (TypeRef, Ctx, string) -> string
local function convert_map(ref, ctx, name_hint)
	local s = ref.shape --[[: { key: TypeRef, value: TypeRef, ... }]]
	if s.key.shape.kind == "string" then
		return "Js.Dict.t<" .. rescript_type(s.value, ctx, name_hint .. "Value") .. ">"
	end
	-- No idiomatic single ReScript construct carries both a non-string key
	-- type and a value type together (`Js.Dict.t` is string-keyed;
	-- `Belt.Map.t` needs a first-class comparator module, not just two type
	-- parameters), so this degrades to an array of key/value tuples — the
	-- closest structural analogue that stays representable without inventing
	-- a comparator. A real, flagged design choice, not the only reasonable
	-- one.
	return "array<("
		.. rescript_type(s.key, ctx, name_hint .. "Key")
		.. ", "
		.. rescript_type(s.value, ctx, name_hint .. "Value")
		.. ")>"
end

-- `union`, `enum` and `intersection` all hoist. `intersection` does because
-- ReScript has no structural intersection-type operator: its object members
-- are merged into one named record (see `record_fields`).
--: (TypeRef, Ctx, string) -> string
local function convert_hoisted(ref, ctx, name_hint)
	return hoisted_name(ctx, ref, name_hint)
end

--: (TypeRef, Ctx, string) -> string
local function convert_ref(ref, _ctx, _hint)
	return codegen.pascal_case_from_words((ref.shape --[[: { target: string, ... }]]).target)
end

-- ReScript function-type syntax is `(paramTypes) => returnType`, positional
-- only (there are no named-parameter function types), so `thisType` — when
-- present — is prepended as a leading positional parameter, the same
-- convention the sibling projectors use for a callable's `this`. A
-- parameterless function takes `unit`.
--: (TypeRef, Ctx, string) -> string
local function convert_function(ref, ctx, name_hint)
	local s = ref.shape --[[: { params: Param[], returnType: TypeRef, thisType?: TypeRef, ... }]]
	local params = {} --: { [integer]: string }
	local n = 0
	local this_type = s.thisType
	if this_type ~= nil then
		n = 1
		params[1] = rescript_type(this_type, ctx, name_hint .. "This")
	end
	for i = 1, #s.params do
		n = n + 1
		params[n] = rescript_type(s.params[i].type, ctx, name_hint .. tostring(i - 1))
	end
	local param_list = "unit"
	if n > 0 then param_list = table.concat(params, ", ") end
	return "(" .. param_list .. ") => " .. rescript_type(s.returnType, ctx, name_hint .. "Return")
end

-- `method` deliberately has no entry: it reaches `function` through the kind
-- lattice's `method -> function` edge, exactly as in the TS.
type_handlers = {
	boolean = leaf("bool"),
	number = leaf("float"),
	integer = leaf("int"),
	string = leaf("string"),
	null = leaf("unit"),
	void = leaf("unit"),

	-- `Js.Json.t` is ReScript's standard "arbitrary JSON value" type, the
	-- closest analogue to TS `unknown` / Elm `Json.Decode.Value`.
	unknown = leaf("Js.Json.t"),

	-- ReScript has no built-in bottom/uninhabited type name (unlike Flow's
	-- `empty` or TS's `never`) usable at an arbitrary inline type position —
	-- an empty variant (`type t = |`) expresses "uninhabited" but only as its
	-- own named declaration. So `never` degrades to the same opaque
	-- JSON-value placeholder `unknown` uses: an honest degrade, not a
	-- fabricated builtin name.
	never = leaf("Js.Json.t"),

	object = convert_object,

	-- A class instance carries only nominal identity, never structure — there
	-- is no ReScript construct to reconstruct it from.
	instance = leaf("Js.Json.t"),

	array = convert_element_array,
	stream = convert_element_array,
	page = convert_element_array,
	tuple = convert_tuple,
	map = convert_map,

	union = convert_hoisted,
	enum = convert_hoisted,
	intersection = convert_hoisted,

	-- A bare literal in field position carries no distinguishing payload once
	-- its single value is fixed — the same `unit` degrade elm-json.ts's type
	-- pass uses. The literal's actual value only matters at the JSON boundary,
	-- which this projector does not generate.
	literal = leaf("unit"),

	ref = convert_ref,
	["function"] = convert_function,

	-- A method surface is a service/interface contract, not data, and has no
	-- field-level construct — degrades to the same opaque JSON-value
	-- placeholder `instance` uses.
	interface = leaf("Js.Json.t"),
}

-- ── Public entry points ──────────────────────────────────────────────────────

-- Standalone type-expression rendering, for callers that just want the
-- ReScript type text (e.g. to embed in hand-written source) without a full
-- declaration. Nested records/unions/enums still render correctly — each gets
-- its own name — but their hoisted declarations are discarded with the
-- throwaway context, so use `rescript_source_from_type_ref` when those need
-- emitting too.
--: (TypeRef) -> string
function M.rescript_type_from_type_ref(ref)
	return rescript_type(ref, new_ctx(), "Anonymous")
end

-- Converts a TypeRef into idiomatic native ReScript source: a `type`
-- declaration named `name` (a record for `object`, a variant for
-- `union`/`enum`, an alias otherwise), plus one additional top-level
-- declaration for every nested object/union/enum hoisted out along the way.
-- `name` defaults to "Value".
--
-- Types only — no encoder/decoder pair — since idiomatic ReScript JSON
-- handling is delegated to a chosen library rather than baked into every
-- generated type.
--: (TypeRef, string | nil) -> string
function M.rescript_source_from_type_ref(ref, name)
	local ctx = new_ctx()
	local type_name = codegen.pascal_case_from_words(name or "Value")
	ctx.used[type_name] = true
	local main = generate_named_type(ref, type_name, ctx)
	local parts = {} --: { [integer]: string }
	parts[1] = main
	-- Read AFTER `generate_named_type`, which is what populates `decls`.
	for i = 1, #ctx.decls do
		parts[i + 1] = ctx.decls[i]
	end
	return table.concat(parts, "\n\n")
end

return M
