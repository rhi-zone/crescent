-- lib/type-ir/rust_serde.lua — the Rust/serde projector for the
-- TypeRef data model, ported from fractal's
-- packages/type-ir/src/rust-serde.ts.
--
-- Two entry points, matching the TS module's two exports:
--
--   `rust_type_from_type_ref(ref)` (fractal's `toRustType`) — the inline Rust
--   type EXPRESSION for a TypeRef. Used for positions that carry no naming
--   context of their own (array elements, tuple slots, map keys/values), so
--   `object`/`enum`/`union` fall back to a caller-supplied `meta.typeName` /
--   `meta.enumName` or to the honest opaque escape hatch
--   `serde_json::Value` rather than fabricating a struct with no name.
--
--   `rust_source_from_type_ref(ref, name)` (fractal's `toRust`) — a named
--   top-level DECLARATION plus every struct/enum hoisted out of its nested
--   fields. Rust, like FlatBuffers, has no anonymous nested struct/enum
--   syntax, so a nested `object`/`enum`/`union` in a field position becomes a
--   sibling declaration named after the field. Without `name` it degrades to
--   `rust_type_from_type_ref`.
--
-- Both are TOTAL: every kind has a handler, and an unrecognized kind (an
-- extension-registered kind with no handler and no handled ancestor) falls
-- back to `serde_json::Value`. There is no data input that fails, so neither
-- returns `(nil, errmsg)` — inventing a failure mode the source does not have
-- would push a nil check onto every call site for a branch that cannot be
-- reached.
--
-- Deliberate divergences from the TS:
--
--   * FIELD AND VARIANT-FIELD ORDER. fractal iterates `Object.entries(fields)`,
--     i.e. JS insertion order. Lua tables have no insertion order to recover,
--     so fields are emitted in byte order of their names — the same
--     deterministic stand-in `init.lua`'s `ordered_keys` uses, for the
--     same reason. Emitted field SET and per-field rendering are identical;
--     only the line order can differ, and only when the source object's keys
--     were not already in byte order.
--
--   * `build_tagged_enum` takes the discriminator name as an argument rather
--     than re-reading `ref.meta.discriminator` and casting it to `string`.
--     Both call sites have already tested `type(...) == "string"` to choose
--     the tagged branch at all, so passing the narrowed value carries the
--     proof along instead of discarding and re-asserting it.
--
--   * `field_type` returns `(type, skip)` as two values rather than a record.
--
-- Shape casts read `{ kind: string, ... }` where the TS reads
-- `TypeShape & { kind: "array" }`: a checked cast cannot narrow the open
-- `TypeShape`'s `kind: string` down to a string literal, and testing
-- `shape.kind == "array"` does not narrow it either. The cast is doing the
-- same job as the TS one — asserting the payload fields a shape of this kind
-- carries — and the kind itself is established by the dispatch that reached
-- the cast.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.type-ir")
local codegen = require("lib.type-ir.codegen")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

-- One entry in the base handler map: a shape plus its TypeRef's meta bag in,
-- an inline Rust type expression out.
--:: Converter = (shape: TypeShape, meta: Meta) -> string

-- ── Keywords ─────────────────────────────────────────────────────────────────

-- Rust 2018+ reserved/strict keywords (https://doc.rust-lang.org/reference/keywords.html)
-- that cannot appear as a plain identifier. A field whose snake_case name
-- collides with one of these must be written as a raw identifier (`r#type`)
-- to compile; `#[serde(rename = "...")]` keeps the wire-format field name
-- (the pre-escape, pre-snake_case source name) unchanged.
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
-- using raw-identifier syntax (`r#type`); pass non-keyword identifiers
-- through.
--: (rust_name: string) -> string
local function escape_rust_ident(rust_name)
	if RUST_KEYWORDS[rust_name] then return "r#" .. rust_name end
	return rust_name
end

-- ── Ordering ─────────────────────────────────────────────────────────────────

-- A field record's names in a deterministic order (byte order). See the
-- header note: this stands in for JS insertion order, which Lua cannot
-- recover, exactly as `init.lua`'s `ordered_keys` does for traversal.
-- A local rather than a shared helper for the same reason it is local there —
-- it is three lines, and exporting it would invite callers to depend on this
-- module for a table utility.
--: (fields: { [string]: TypeRef }) -> string[]
local function ordered_field_names(fields)
	local out = {} --[[: { [integer]: string } ]]
	local n = 0
	for k in pairs(fields) do
		n = n + 1
		out[n] = k
	end
	table.sort(out)
	return out
end

-- ── Base handlers ────────────────────────────────────────────────────────────

-- Mutually recursive with `handlers` below: forward-declared so the handler
-- bodies can call it, defined once the map exists for it to dispatch through.
local rust_type_from_type_ref

--: (rust_type: string) -> Converter
local function leaf(rust_type)
	--: (shape: TypeShape, meta: Meta) -> string
	return function(_shape, _meta)
		return rust_type
	end
end

-- Base inline-expression handlers — the Rust analogue of typescript.ts's
-- `handlers` map. Used for type positions that don't carry enough naming
-- context to hoist a fresh declaration (array elements, tuple slots, map
-- keys/values, standalone references): `object`/`enum`/`union` here fall
-- back to a caller-supplied name (`meta.typeName`/`meta.enumName`) or an
-- honest opaque escape hatch (`serde_json::Value`) rather than fabricating
-- a struct with no name. `bare_type` below is the field/variant-context
-- counterpart that DOES have a name to hoist a declaration under.
local handlers = {
	boolean = leaf("bool"),
	number = leaf("f64"),
	integer = leaf("i64"),
	int8 = leaf("i8"),
	int16 = leaf("i16"),
	int32 = leaf("i32"),
	int64 = leaf("i64"),
	uint8 = leaf("u8"),
	uint16 = leaf("u16"),
	uint32 = leaf("u32"),
	uint64 = leaf("u64"),
	float32 = leaf("f32"),
	float64 = leaf("f64"),
	string = leaf("String"),
	uuid = leaf("String"),
	uri = leaf("String"),
	email = leaf("String"),
	datetime = leaf("String"),
	date = leaf("String"),
	time = leaf("String"),
	duration = leaf("String"),
	bytes = leaf("Vec<u8>"),
	null = leaf("()"),
	void = leaf("()"),
	unknown = leaf("serde_json::Value"),
	never = leaf("std::convert::Infallible"),

	-- A class instance carries only nominal identity (className/source), never
	-- fields (see init.lua's `instance` comment) — referenced by
	-- className, trusting a struct of that name is declared/imported elsewhere.
	--: (shape: TypeShape, meta: Meta) -> string
	instance = function(shape, _meta)
		return (shape --[[: { kind: string, className: string, ... }]]).className
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	array = function(shape, _meta)
		local s = shape --[[: { kind: string, element: TypeRef, ... }]]
		return "Vec<" .. rust_type_from_type_ref(s.element) .. ">"
	end,

	-- No streaming construct in a plain data type — materializes to Vec<T>,
	-- same honest-degrade convention protobuf.ts/flatbuffers.ts use.
	--: (shape: TypeShape, meta: Meta) -> string
	stream = function(shape, _meta)
		local s = shape --[[: { kind: string, element: TypeRef, ... }]]
		return "Vec<" .. rust_type_from_type_ref(s.element) .. ">"
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	page = function(shape, _meta)
		local s = shape --[[: { kind: string, element: TypeRef, ... }]]
		return "Vec<" .. rust_type_from_type_ref(s.element) .. ">"
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	tuple = function(shape, _meta)
		local s = shape --[[: { kind: string, elements: TypeRef[], ... }]]
		local parts = {} --[[: { [integer]: string } ]]
		for i = 1, #s.elements do
			parts[i] = rust_type_from_type_ref(s.elements[i])
		end
		return "(" .. table.concat(parts, ", ") .. ")"
	end,

	-- Default to HashMap<K, V>; a map TypeRef whose own `meta.ordered` is true
	-- (project convention — no prior art in this codebase to match, since no
	-- existing projector distinguishes ordered/unordered maps) renders as
	-- BTreeMap<K, V> instead.
	--: (shape: TypeShape, meta: Meta) -> string
	map = function(shape, meta)
		local s = shape --[[: { kind: string, key: TypeRef, value: TypeRef, ... }]]
		local container = "HashMap"
		if meta.ordered == true then container = "BTreeMap" end
		return container .. "<" .. rust_type_from_type_ref(s.key) .. ", " .. rust_type_from_type_ref(s.value) .. ">"
	end,

	-- No naming context here — see the `bare_type`/`build_struct` field-context
	-- hoisting path below for the real (named) struct-generating case.
	--: (shape: TypeShape, meta: Meta) -> string
	object = function(_shape, meta)
		local name = meta.typeName
		if type(name) == "string" then return name end
		return "serde_json::Value"
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	enum = function(shape, meta)
		local name = meta.enumName
		if type(name) == "string" then return name end
		local s = shape --[[: { kind: string, members: string[], ... }]]
		return "Enum" .. #s.members
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	union = function(_shape, meta)
		local name = meta.typeName
		if type(name) == "string" then return name end
		return "serde_json::Value"
	end,

	-- Rust has no literal-type construct usable in a serde-derived struct field
	-- (const generics don't cover strings/floats generally) — degrades to the
	-- literal's base scalar type, same lossy convention protobuf.ts/flatbuffers.ts
	-- use for their own literal handling.
	--
	-- The final branch is the TS's `Number.isInteger(value) ? "i64" : "f64"`.
	-- The `type(value) == "number"` guard is not a narrower test than the TS's:
	-- `Number.isInteger` of a non-number is false, which lands on the same
	-- `f64`. In Lua the guard is load-bearing rather than cosmetic, since
	-- `value % 1` on a non-number raises.
	--: (shape: TypeShape, meta: Meta) -> string
	literal = function(shape, _meta)
		local value = (shape --[[: { kind: string, value: unknown, ... }]]).value
		if value == type_ref.null then return "()" end
		if type(value) == "string" then return "String" end
		if type(value) == "boolean" then return "bool" end
		if type(value) == "number" and value % 1 == 0 then return "i64" end
		return "f64"
	end,

	--: (shape: TypeShape, meta: Meta) -> string
	ref = function(shape, _meta)
		return (shape --[[: { kind: string, target: string, ... }]]).target
	end,

	-- No struct-merge/mixin construct in Rust — lossy: falls back to the first
	-- member's type, dropping the rest (same convention as protobuf.ts/flatbuffers.ts).
	--: (shape: TypeShape, meta: Meta) -> string
	intersection = function(shape, _meta)
		local s = shape --[[: { kind: string, members: TypeRef[], ... }]]
		local first = s.members[1]
		if first == nil then return "serde_json::Value" end
		return rust_type_from_type_ref(first)
	end,

	-- Not serializable data — degrades honestly to serde_json::Value, same as
	-- `unknown` above.
	["function"] = leaf("serde_json::Value"),
	interface = leaf("serde_json::Value"),
} --[[: { [string]: Converter }]]

-- Inline Rust type expression for `ref`, wrapping in `Option<T>` when
-- `meta.nullable` is set. Used for positions with no naming context of their
-- own (array elements, tuple slots, map keys/values) — see `bare_type` for the
-- named-declaration-hoisting counterpart used inside struct fields / enum
-- variants.
--: (ref: TypeRef) -> string
function rust_type_from_type_ref(ref)
	-- TYPECHECKER WORKAROUND: the cast should be unnecessary — `type_ref.resolve`
	-- is `<T>(string, { [string]: T }) -> T | nil` and `handlers` is
	-- `{ [string]: Converter }`, so `T` should infer as `Converter`. It does
	-- not: a type parameter is not inferred from an index-signature argument,
	-- and the call's result types as `never`, which then makes
	-- `"Option<" .. base .. ">"` fail because a union carrying `never` is
	-- rejected by the concatenation check rather than absorbing it. Naturally
	-- this line would be `local converter = type_ref.resolve(ref.shape.kind, handlers)`.
	local converter = type_ref.resolve(ref.shape.kind, handlers) --[[: Converter | nil]]
	local base = "serde_json::Value"
	if converter ~= nil then base = converter(ref.shape, ref.meta) end
	if ref.meta.nullable == true then return "Option<" .. base .. ">" end
	return base
end

M.rust_type_from_type_ref = rust_type_from_type_ref

-- ── Declaration building ─────────────────────────────────────────────────────

local DERIVE = "#[derive(Debug, Clone, Serialize, Deserialize)]"

-- Append `meta.description` as a Rust doc comment, if there is one.
--: (lines: string[], indent: string, meta: Meta) -> nil
local function push_doc_comment(lines, indent, meta)
	local description = meta.description
	if type(description) == "string" then
		lines[#lines + 1] = indent .. "/// " .. description
	end
end

-- Mutually recursive with every `build_*` below (a nested field hoists a
-- declaration, whose own fields may hoist further declarations), so it is
-- forward-declared and defined after them.
local bare_type

-- Field type + whether it needs `#[serde(skip_serializing_if = "Option::is_none")]`.
-- `meta.optional` (may be absent from the wire) and `meta.nullable` (present
-- but may carry JSON `null`) both map onto Rust's single `Option<T>` — Rust's
-- serde convention doesn't distinguish "missing key" from "explicit null" the
-- way the IR's two flags do, so both collapse onto one `Option` wrap rather
-- than `Option<Option<T>>`.
--: (field_name: string, field_ref: TypeRef, decls: string[]) -> (string, boolean)
local function field_type(field_name, field_ref, decls)
	local bare = bare_type(codegen.pascal_case_strip_separators(field_name), field_ref, decls)
	if field_ref.meta.optional == true or field_ref.meta.nullable == true then
		return "Option<" .. bare .. ">", true
	end
	return bare, false
end

--: (name: string, ref: TypeRef, decls: string[]) -> string
local function build_struct(name, ref, decls)
	local shape = ref.shape --[[: { kind: string, fields: { [string]: TypeRef }, ... }]]
	local lines = {} --[[: { [integer]: string } ]]
	push_doc_comment(lines, "", ref.meta)
	if ref.meta.deprecated == true then lines[#lines + 1] = "#[deprecated]" end
	lines[#lines + 1] = DERIVE
	lines[#lines + 1] = "pub struct " .. name .. " {"

	local field_names = ordered_field_names(shape.fields)
	for i = 1, #field_names do
		local field_name = field_names[i]
		local field_ref = shape.fields[field_name]
		local rust_name = codegen.snake_case_strip_separators(field_name)
		local ident = escape_rust_ident(rust_name)
		local rust_type, skip = field_type(field_name, field_ref, decls)
		push_doc_comment(lines, "    ", field_ref.meta)
		if rust_name ~= field_name or ident ~= rust_name then
			lines[#lines + 1] = "    #[serde(rename = " .. codegen.quote(field_name) .. ")]"
		end
		if skip then lines[#lines + 1] = '    #[serde(skip_serializing_if = "Option::is_none")]' end
		if field_ref.meta.deprecated == true then lines[#lines + 1] = "    #[deprecated]" end
		lines[#lines + 1] = "    pub " .. ident .. ": " .. rust_type .. ","
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

--: (name: string, ref: TypeRef) -> string
local function build_enum(name, ref)
	local shape = ref.shape --[[: { kind: string, members: string[], ... }]]
	local lines = {} --[[: { [integer]: string } ]]
	push_doc_comment(lines, "", ref.meta)
	lines[#lines + 1] = DERIVE
	lines[#lines + 1] = "pub enum " .. name .. " {"

	for i = 1, #shape.members do
		local member = shape.members[i]
		local variant = codegen.pascal_case_strip_separators(member)
		if variant ~= member then
			lines[#lines + 1] = "    #[serde(rename = " .. codegen.quote(member) .. ")]"
		end
		lines[#lines + 1] = "    " .. variant .. ","
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- Internally-tagged enum (https://serde.rs/enum-representations.html#internally-tagged) —
-- `#[serde(tag = "discriminator")]`. Each union variant is (per
-- from-jtd.ts's/json-schema.ts's shared `meta.discriminator` convention) an
-- `object` TypeRef whose discriminator field is a `literal` string tag; that
-- literal's value becomes both the Rust variant name and its
-- `#[serde(rename = ...)]`, and is excluded from the variant's own field list
-- since serde synthesizes the tag from the variant selection itself, not from
-- a real struct field.
--
-- `discriminator` is a parameter rather than a re-read of
-- `ref.meta.discriminator`: the callers have already narrowed it to a string
-- in order to choose this function at all.
--: (name: string, ref: TypeRef, discriminator: string, decls: string[]) -> string
local function build_tagged_enum(name, ref, discriminator, decls)
	local shape = ref.shape --[[: { kind: string, variants: TypeRef[], ... }]]
	local lines = {} --[[: { [integer]: string } ]]
	push_doc_comment(lines, "", ref.meta)
	lines[#lines + 1] = DERIVE
	lines[#lines + 1] = "#[serde(tag = " .. codegen.quote(discriminator) .. ")]"
	lines[#lines + 1] = "pub enum " .. name .. " {"

	for i = 1, #shape.variants do
		local variant = shape.variants[i]
		-- `fields` is optional here and only here: a union variant is an
		-- `object` by convention, not by construction, so a caller can hand
		-- over one that isn't (the TS reads `variantShape.fields?.[...]` for
		-- the same reason).
		local variant_shape = variant.shape --[[: { kind: string, fields?: { [string]: TypeRef }, ... }]]
		-- The TS reads the tag through `variantShape.fields?.[discriminator]`
		-- and the remaining fields through `Object.entries(variantShape.fields ?? {})`.
		-- Substituting an empty table once covers both: indexing it yields nil
		-- exactly where the optional chain would, and it has no entries to list.
		local fields = (variant_shape.fields or {}) --[[: { [string]: TypeRef } ]]

		local tag_value = "Variant" .. (i - 1)
		local tag_field = fields[discriminator]
		if tag_field ~= nil and tag_field.shape.kind == "literal" then
			local value = (tag_field.shape --[[: { kind: string, value: unknown, ... }]]).value
			if type(value) == "string" then tag_value = value end
		end
		local variant_name = codegen.pascal_case_strip_separators(tag_value)

		local other_names = {} --[[: { [integer]: string } ]]
		local all_names = ordered_field_names(fields)
		local n = 0
		for j = 1, #all_names do
			if all_names[j] ~= discriminator then
				n = n + 1
				other_names[n] = all_names[j]
			end
		end

		if variant_name ~= tag_value then
			lines[#lines + 1] = "    #[serde(rename = " .. codegen.quote(tag_value) .. ")]"
		end
		if #other_names == 0 then
			lines[#lines + 1] = "    " .. variant_name .. ","
		else
			lines[#lines + 1] = "    " .. variant_name .. " {"
			for j = 1, #other_names do
				local field_name = other_names[j]
				local field_ref = fields[field_name]
				local rust_name = codegen.snake_case_strip_separators(field_name)
				local ident = escape_rust_ident(rust_name)
				local rust_type, skip = field_type(field_name, field_ref, decls)
				if rust_name ~= field_name or ident ~= rust_name then
					lines[#lines + 1] = "        #[serde(rename = " .. codegen.quote(field_name) .. ")]"
				end
				if skip then lines[#lines + 1] = '        #[serde(skip_serializing_if = "Option::is_none")]' end
				lines[#lines + 1] = "        " .. ident .. ": " .. rust_type .. ","
			end
			lines[#lines + 1] = "    },"
		end
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- Untagged enum (https://serde.rs/enum-representations.html#untagged) — used
-- for a plain union with no `meta.discriminator`. Each variant is a
-- single-element tuple variant wrapping the member type; variant names are
-- synthesized (`Variant0`, `Variant1`, ...) since a bare union carries no
-- per-arm naming of its own.
--: (name: string, ref: TypeRef, decls: string[]) -> string
local function build_untagged_enum(name, ref, decls)
	local shape = ref.shape --[[: { kind: string, variants: TypeRef[], ... }]]
	local lines = {} --[[: { [integer]: string } ]]
	push_doc_comment(lines, "", ref.meta)
	lines[#lines + 1] = DERIVE
	lines[#lines + 1] = "#[serde(untagged)]"
	lines[#lines + 1] = "pub enum " .. name .. " {"

	for i = 1, #shape.variants do
		local variant_name = "Variant" .. (i - 1)
		local rust_type = bare_type(name .. variant_name, shape.variants[i], decls)
		lines[#lines + 1] = "    " .. variant_name .. "(" .. rust_type .. "),"
	end

	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

-- Field/variant-context inline type: same as `rust_type_from_type_ref`, except
-- `object`, `enum`, and `union` (undiscriminated or discriminated) hoist a
-- fresh named declaration into `decls` under `name_hint` (PascalCase) instead
-- of falling back to a generic placeholder — mirroring flatbuffers.ts's
-- `buildTable` nested-field hoisting (FlatBuffers, like Rust, has no anonymous
-- nested struct/enum syntax). `Vec<object>`/`Vec<enum>`/`Vec<union>` hoist the
-- element type under the same name hint and wrap it in `Vec<...>`.
--
-- `decls` is threaded by reference and appended to in place: a nested
-- declaration's own hoists land in `decls` BEFORE the declaration that
-- contains them, which is what makes the emitted order deepest-first. The
-- built string is bound to a local before the append for exactly that reason —
-- `decls[#decls + 1] = build_struct(...)` would evaluate `#decls` against the
-- pre-recursion length in Lua and overwrite what the recursion appended.
--: (name_hint: string, ref: TypeRef, decls: string[]) -> string
function bare_type(name_hint, ref, decls)
	local kind = ref.shape.kind
	if codegen.is_a(kind, "object") then
		local decl = build_struct(name_hint, ref, decls)
		decls[#decls + 1] = decl
		return name_hint
	end
	if kind == "enum" then
		decls[#decls + 1] = build_enum(name_hint, ref)
		return name_hint
	end
	if kind == "union" then
		local discriminator = ref.meta.discriminator
		local decl
		if type(discriminator) == "string" then
			decl = build_tagged_enum(name_hint, ref, discriminator, decls)
		else
			decl = build_untagged_enum(name_hint, ref, decls)
		end
		decls[#decls + 1] = decl
		return name_hint
	end
	if kind == "array" then
		local s = ref.shape --[[: { kind: string, element: TypeRef, ... }]]
		local element_kind = s.element.shape.kind
		if codegen.is_a(element_kind, "object") or element_kind == "enum" or element_kind == "union" then
			return "Vec<" .. bare_type(name_hint, s.element, decls) .. ">"
		end
		return "Vec<" .. rust_type_from_type_ref(s.element) .. ">"
	end
	-- TYPECHECKER WORKAROUND: same failed index-signature generic inference as
	-- in `rust_type_from_type_ref` above; without the cast the call's result
	-- types as `never`.
	local converter = type_ref.resolve(kind, handlers) --[[: Converter | nil]]
	if converter == nil then return "serde_json::Value" end
	return converter(ref.shape, ref.meta)
end

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Lower a TypeRef to idiomatic Rust source. With `name`, emits a named
-- top-level declaration — `struct` for `object`, `enum` for `enum`/`union`
-- (tagged when `meta.discriminator` is set, untagged otherwise), or a
-- `pub type` alias for anything else (primitives, `array`, `tuple`, `map`,
-- ...) — preceded by any struct/enum declarations hoisted out of nested
-- fields (Rust, like FlatBuffers, has no anonymous nested struct/enum syntax;
-- see `bare_type`). Without `name`, returns just the inline type expression
-- for `ref` (`rust_type_from_type_ref`) — the field-type building block other
-- projections (or a caller assembling its own struct) can plug into their own
-- declarations.
--: (ref: TypeRef, name: string | nil) -> string
function M.rust_source_from_type_ref(ref, name)
	if name == nil then return rust_type_from_type_ref(ref) end

	local decls = {} --[[: { [integer]: string } ]]
	local kind = ref.shape.kind
	local main_decl
	if codegen.is_a(kind, "object") then
		main_decl = build_struct(name, ref, decls)
	elseif kind == "enum" then
		main_decl = build_enum(name, ref)
	elseif kind == "union" then
		local discriminator = ref.meta.discriminator
		if type(discriminator) == "string" then
			main_decl = build_tagged_enum(name, ref, discriminator, decls)
		else
			main_decl = build_untagged_enum(name, ref, decls)
		end
	else
		main_decl = "pub type " .. name .. " = " .. rust_type_from_type_ref(ref) .. ";"
	end

	decls[#decls + 1] = main_decl
	return table.concat(decls, "\n\n")
end

return M
