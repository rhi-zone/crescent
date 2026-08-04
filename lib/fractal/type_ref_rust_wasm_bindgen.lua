-- lib/fractal/type_ref_rust_wasm_bindgen.lua — Rust codegen targeting
-- wasm-bindgen (https://wasm-bindgen.github.io/wasm-bindgen/), ported from
-- fractal's packages/type-ir/src/rust-wasm-bindgen.ts.
--
-- Emits `#[wasm_bindgen]`-annotated structs/enums/functions that JS can call
-- into once compiled to wasm. Generated snippets assume the caller has
-- `use wasm_bindgen::prelude::*;` in scope (declarations only, no import
-- lines emitted) — the same convention fractal's rust-serde.ts uses for
-- `use serde::{Serialize, Deserialize};`.
--
-- This is deliberately a SUBSET of type-ir's kinds. wasm-bindgen's ABI
-- boundary — confirmed by fractal against the project's guide
-- (https://github.com/rustwasm/wasm-bindgen, guide/src/reference/types/*
-- and guide/src/reference/attributes/on-rust-exports/*, fetched 2026-08-03)
-- — only crosses a fixed set of shapes:
--   - numeric widths, bool, String, JsValue, Option<T>, Result<T, E> as a
--     *return* type only, Vec<T>/Box<[T]> (T restricted to JsValue/imported
--     JS types/exported Rust types/String, plus numeric widths via
--     "boxed number slices" — bool is NOT in either list), and
--     `#[wasm_bindgen]`-exported struct/enum types.
--   - Structs need every crossed field `pub`; non-`Copy` fields (String,
--     Vec<_>, nested structs) need `#[wasm_bindgen(getter_with_clone)]`
--     (struct- or field-level), which requires the field type to impl
--     `Clone` — hence every struct here carries `#[derive(Clone)]`.
--   - Enums only cross cleanly when fieldless (C-style / string-discriminant
--     — `Variant = "wireValue"`). Newer wasm-bindgen versions support
--     "dynamic unions" (single-field tuple variants + order-dependent
--     runtime-witness dispatch), but that mechanism doesn't fit type-ir's
--     `union` kind: type-ir's tagged-union variants are multi-field
--     *objects*, not bare wrapped types, and an untagged union has no
--     natural variant ordering to dispatch on. See `REASON_UNION` below for
--     what is refused and why.
--   - HashMap<K, V>, arbitrary tuples, and nested containers (Vec<Vec<T>>,
--     Vec<HashMap<..>>, ...) are NOT directly ABI-crossable — wasm-bindgen's
--     own docs name these exact cases as needing the `serde-wasm-bindgen`
--     crate (JsValue + serde) instead, which is a real added dependency,
--     not a decision this projector makes on the caller's behalf.
--
-- Kinds outside this subset are REFUSED rather than degraded to a lossy
-- placeholder — unlike every other projector in the package (rust-serde,
-- protobuf, json-schema, ...), which degrade genuinely-unsupported kinds to
-- an honest opaque placeholder (`serde_json::Value`,
-- `google.protobuf.Any`, `x-function: true`) because their target formats
-- are pure data shapes with no compiled-code obligation. wasm-bindgen's
-- output has to compile and its ABI boundary is a hard wall, not a
-- best-effort data shape — silently emitting `JsValue` for, say, a `map`
-- would compile but misrepresent a structured key/value type as opaque, and
-- silently emitting Rust for an untagged union without doing dynamic-union
-- dispatch bookkeeping would compile but be wrong at runtime. Refusing
-- forces the caller to make the tradeoff explicitly (add
-- serde-wasm-bindgen, restructure the type, or hand-write the binding).
--
-- ── Deliberate divergences from the TS ───────────────────────────────────────
--
-- THROW -> `(nil, errmsg)`. fractal's file is the one projector in the
-- package that throws, and it throws from deep inside the recursion (Vec
-- element types, hoisted nested structs, function params). Crescent's
-- convention is that a data error returns `(nil, errmsg)` and never throws,
-- so both public entry points are fallible and EVERY internal recursion site
-- (`bare_type`, `vec_element_type`, `build_struct`, `build_function`,
-- `field_type`, and each handler) propagates the pair instead of unwinding.
-- The MESSAGES are carried across verbatim — they carry the real content
-- (which wasm-bindgen doc justifies the refusal, what to do instead), and
-- the `toWasmBindgen:` prefix is kept deliberately so a message stays
-- greppable across both ports.
--
-- The TS calls `handlers.method!(...)`/`handlers.union!(...)` purely for
-- their throw, then has to write an unreachable `mainDecl = ""` after the
-- union call to satisfy the compiler. Here the refusal texts are named
-- constants (`REASON_METHOD`, `REASON_UNION`) that both the handler table
-- and those two sites read, so the shared explanation is still shared — but
-- as a value rather than as a control-flow side effect, and with no
-- unreachable branch to write.
--
-- Struct field order is BYTE order of the field names, not the TS's
-- `Object.entries` insertion order, which Lua tables cannot recover. Same
-- problem and same resolution as `type_ref.lua`'s `ordered_keys` (see its
-- comment); the local copy here exists because that one is module-private.
-- The emitted field SET is identical either way; only the line order within
-- a generated struct can differ from fractal's.
--
-- The `handlers` table is keyed by kind and looked up through
-- `type_ref.resolve`, so a refined kind with no entry of its own (`int8`,
-- `uuid`, … once `type_ref_kinds_common` has been required) falls back to
-- its ancestor's handler exactly as in fractal — with the same explicit
-- entries for the refined kinds whose Rust width differs from `integer`'s.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")
local codegen = require("lib.fractal.type_ref_codegen")

local M = {}

--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

-- TYPECHECKER WORKAROUND: the natural spelling for every string list below
-- is `string[]`, which desugars to `{ [number]: string }`. `table.concat`'s
-- stdlib declaration takes `{ [integer]: string | number, ... }`, and
-- `{ [number]: _ }` is not assignable to `{ [integer]: _ }`, so every
-- `table.concat` on a `string[]` is rejected. Spelling the indexer
-- `integer` explicitly is accepted and is what this file does. Revert to
-- `string[]` once the array sugar and the stdlib declaration agree.
--:: StringList = { [integer]: string }

-- ── Rust identifiers ─────────────────────────────────────────────────────────

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

--: (rust_name: string) -> string
local function escape_rust_ident(rust_name)
	if RUST_KEYWORDS[rust_name] then return "r#" .. rust_name end
	return rust_name
end

-- ── Deterministic key order ──────────────────────────────────────────────────

-- A record's keys in byte order. See this file's header for why the TS's
-- `Object.entries` insertion order has no Lua equivalent, and
-- `type_ref.lua`'s `ordered_keys` for the same decision made once already.
--: (t: { [string]: unknown }) -> StringList
local function ordered_keys(t)
	local out = {} --[[: StringList]]
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

-- ── Refusal messages ─────────────────────────────────────────────────────────

-- A kind with no direct wasm-bindgen ABI mapping. Refused instead of
-- degraded — see the file header for why this projector's convention
-- differs from every other projector in the package.
--: (kind: string, reason: string) -> string
local function unsupported_message(kind, reason)
	return 'toWasmBindgen: "' .. kind .. '" has no direct wasm-bindgen mapping — ' .. reason
end

local REASON_NEVER =
	"no wasm-bindgen-documented Rust type represents the bottom/uninhabited type across the ABI (std::convert::Infallible, rust-serde.ts's own degrade target, is not among wasm-bindgen's documented crossable types)"

local REASON_TUPLE =
	'Rust tuples are not among wasm-bindgen\'s documented ABI-crossable types (see guide/src/reference/types/*.md — no "tuple" entry); restructure as a named struct with named fields, or use serde-wasm-bindgen'

local REASON_MAP =
	"no direct HashMap<K, V> ABI crossing — wasm-bindgen's own guide (arbitrary-data-with-serde.md) names HashMap as one of the exact cases requiring the serde-wasm-bindgen crate as an added dependency; js_sys::Map is available for an opaque JS Map handle but doesn't carry type-ir's key/value element types"

local REASON_UNION =
	'wasm-bindgen enums cross the ABI cleanly only when fieldless (string/numeric discriminants), or via the newer "dynamic union" mechanism restricted to single-field tuple variants with order-dependent runtime-witness dispatch. type-ir\'s tagged-union variants are multi-field objects (not bare wrapped types) and untagged unions carry no natural dispatch order — neither maps onto wasm-bindgen\'s enum forms without redesigning the variant shapes by hand, or depending on serde-wasm-bindgen to cross as JsValue'

local REASON_INTERSECTION =
	"no struct-merge/mixin construct in Rust. rust-serde.ts degrades this by taking the first member's type and silently dropping the rest — acceptable for a pure-data format, but silently dropping fields across a compiled JS/Rust ABI boundary would misrepresent the binding's actual shape, so this is surfaced explicitly instead"

local REASON_FUNCTION =
	"a callable TypeRef only becomes valid wasm-bindgen output as a named top-level declaration (see toWasmBindgen(ref, name)); as an inline type (e.g. a struct field holding a JS callback) it would need js_sys::Function, which this projector does not implement"

local REASON_METHOD =
	"a method (function with a `thisType` receiver) belongs inside a #[wasm_bindgen] impl block tied to its receiver's own exported struct — that requires correlating the method with its receiver's struct declaration, which a single TypeRef->string conversion can't do. Project the containing type's struct first, then hand-write (or separately generate) the impl block for each of its `interface.methods` entries"

local REASON_INTERFACE =
	"no service/trait-object construct crosses the wasm-bindgen ABI directly — an `interface`'s methods would each need their own #[wasm_bindgen] impl block on a concrete receiver type (see the `method` entry above), which isn't something a single TypeRef can express"

-- ── Vec element restrictions ─────────────────────────────────────────────────

local VEC_BOOL_REFUSAL =
	'toWasmBindgen: Vec<bool> has no documented wasm-bindgen ABI mapping — wasm-bindgen\'s Vec<T>/Box<[T]> guide lists JsValue/imported JS types/exported Rust types/String, plus numeric widths via "boxed number slices", but not bool; wrap elements as JsValue (e.g. via serde-wasm-bindgen) or model as Vec<u8>/a bitset instead'

local VEC_NESTED_REFUSAL =
	'toWasmBindgen: nested Vec<Vec<T>> (an "array"/"stream"/"page" element inside another) is not directly ABI-crossable — wasm-bindgen\'s own guide (arbitrary-data-with-serde.md) cites this exact shape as requiring the serde-wasm-bindgen crate'

local VEC_BYTES_REFUSAL =
	'toWasmBindgen: Vec<Vec<u8>> (an "array" of "bytes") is not directly ABI-crossable, for the same reason nested Vec<Vec<T>> generally isn\'t — requires serde-wasm-bindgen'

-- Kinds allowed as a Vec<T>/Box<[T]> element per wasm-bindgen's documented
-- ABI-crossable categories (guide/src/reference/types/boxed-slices.md +
-- boxed-number-slices.md): JsValues, imported JS types, exported Rust types
-- (struct/enum/instance/ref), Strings, and numeric widths. Notably `bool` is
-- NOT in either documented list, and nested containers (array-of-array,
-- array-of-bytes i.e. Vec<Vec<u8>>, array-of-map, ...) are excluded even
-- though their non-Vec inline type would otherwise resolve fine.
--: (element: TypeRef) -> (string | nil, string | nil)
local function vec_element_type(element)
	local kind = element.shape.kind
	if kind == "boolean" then return nil, VEC_BOOL_REFUSAL end
	if kind == "array" or kind == "stream" or kind == "page" then
		return nil, VEC_NESTED_REFUSAL
	end
	if kind == "bytes" then return nil, VEC_BYTES_REFUSAL end
	return M.rust_wasm_bindgen_type_from_type_ref(element)
end

-- ── Handlers ─────────────────────────────────────────────────────────────────

-- Every converter is fallible: `(shape, meta) -> (rust_type | nil, errmsg | nil)`.
--:: Converter = (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)

--: (rust_type: string) -> Converter
local function leaf(rust_type)
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	return function(_shape, _meta)
		return rust_type, nil
	end
end

--: (kind: string, reason: string) -> Converter
local function unsupported(kind, reason)
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	return function(_shape, _meta)
		return nil, unsupported_message(kind, reason)
	end
end

-- Shared by `array`, `stream` and `page`, whose TS handlers are the same
-- one-line `Vec<${vecElementType(shape.element)}>`.
--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
local function element_vec_converter(shape, _meta)
	local element = (shape --[[: { element: TypeRef, ... }]]).element
	local inner, err = vec_element_type(element)
	if inner == nil then return nil, err end
	return "Vec<" .. inner .. ">", nil
end

-- Base inline-expression handlers — the wasm-bindgen analogue of
-- rust-serde.ts's `handlers` map. Used for type positions with no naming
-- context of their own (Vec elements not hoisted, ref/instance targets);
-- `bare_type` below is the field/param-context counterpart that hoists a
-- named struct/enum declaration when one is needed.
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

	-- JsValue is wasm-bindgen's actual "any JS value" primitive — a faithful,
	-- fully ABI-crossable representation of "unknown", not a lossy escape
	-- hatch the way rust-serde.ts's `serde_json::Value` fallback is for a
	-- pure-data format.
	unknown = leaf("JsValue"),

	never = unsupported("never", REASON_NEVER),

	-- Purely nominal — referenced by className, trusting a `#[wasm_bindgen]`
	-- struct/enum of that name is declared/exported elsewhere. Same
	-- "Exported Rust types" ABI category Vec<T>/Option<T> accept.
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	instance = function(shape, _meta)
		return (shape --[[: { className: string, ... }]]).className, nil
	end,

	array = element_vec_converter,

	-- No streaming construct crosses the wasm-bindgen ABI — materializes to
	-- Vec<T>, same honest-degrade convention rust-serde.ts uses (a stream's
	-- element type is still the closest structural analogue once the
	-- asynchrony/laziness itself can't be preserved). Vec<T> genuinely IS a
	-- valid, ABI-crossable representation, so this isn't a lossy placeholder.
	stream = element_vec_converter,
	page = element_vec_converter,

	tuple = unsupported("tuple", REASON_TUPLE),
	map = unsupported("map", REASON_MAP),

	-- No naming context here — see `bare_type`'s hoisting path for the named
	-- (real) struct-generating case. Anonymous object falls back to JsValue
	-- (an honest "opaque object" representation, not a lossy
	-- struct-in-name-only).
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	object = function(_shape, meta)
		local type_name = meta.typeName
		if type(type_name) == "string" then return type_name, nil end
		return "JsValue", nil
	end,

	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	enum = function(shape, meta)
		local enum_name = meta.enumName
		if type(enum_name) == "string" then return enum_name, nil end
		local members = (shape --[[: { members: StringList, ... }]]).members
		return "Enum" .. tostring(#members), nil
	end,

	union = unsupported("union", REASON_UNION),

	-- Same base-scalar degrade rust-serde.ts uses — unlike that file's other
	-- degrades, this one stays fully ABI-crossable (bool/String/i64/f64/())
	-- rather than an opaque placeholder, so it's a legitimate simplification.
	--
	-- A null literal carries the shared sentinel (`type_ref.null`), not Lua
	-- `nil`: Lua has no value distinct from absence, so a null literal cannot
	-- be written as a missing `value` key. See `type_ref.types.literal`.
	--
	-- The TS's last line is `Number.isInteger(value) ? "i64" : "f64"`, which
	-- is false for every non-number, so a malformed literal lands on `f64` on
	-- both sides rather than erroring. `value % 1 == 0` is the Lua spelling
	-- of `Number.isInteger` (both reject inf/NaN, both accept 3.0).
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	literal = function(shape, _meta)
		local value = (shape --[[: { value: unknown, ... }]]).value
		if value == type_ref.null then return "()", nil end
		if type(value) == "string" then return "String", nil end
		if type(value) == "boolean" then return "bool", nil end
		if type(value) == "number" and value % 1 == 0 then return "i64", nil end
		return "f64", nil
	end,

	-- Name reference — same caveat as `instance` above (trusts a declaration
	-- exists elsewhere with this exact name).
	--: (shape: TypeShape, meta: Meta) -> (string | nil, string | nil)
	ref = function(shape, _meta)
		return (shape --[[: { target: string, ... }]]).target, nil
	end,

	intersection = unsupported("intersection", REASON_INTERSECTION),

	-- Handled structurally by `rust_wasm_bindgen_source_from_type_ref` /
	-- `build_function` (a callable needs a name to become a
	-- `#[wasm_bindgen] pub fn`) — not meaningful as a bare inline type
	-- expression (e.g. a struct field holding a callback would need
	-- js_sys::Function, which isn't verified/implemented here).
	["function"] = unsupported("function", REASON_FUNCTION),

	method = unsupported("method", REASON_METHOD),
	interface = unsupported("interface", REASON_INTERFACE),
} --[[: { [string]: Converter }]]

-- TYPECHECKER WORKAROUND: the natural call is `type_ref.resolve(kind,
-- handlers)` inlined at each of the two use sites. `resolve` is generic
-- (`<T>(string, { [string]: T }) -> T | nil`) and `handlers` is
-- `{ [string]: Converter }`, so `T` should infer as `Converter` — it does
-- not, because a type parameter is not inferred from an index-signature
-- argument, and the call's result types as `never`, which surfaces later as
-- "cannot concatenate type `never`" on the value a `converter(...)` call
-- returns. Declaring the result's type restores it; this file does that with
-- a wrapper carrying a concrete return type, while `type_ref_rust_serde.lua`
-- does it with a `--[[: Converter | nil]]` cast at the call site — same gap,
-- two spellings, to be unified once it is closed. Inline the call again once
-- the type parameter is inferred.
--: (kind: string) -> Converter | nil
local function converter_for(kind)
	return type_ref.resolve(kind, handlers)
end

-- ── Inline type expression ───────────────────────────────────────────────────

--: (kind: string) -> string
local function unhandled_kind_message(kind)
	return 'toWasmBindgen: unhandled kind "' .. kind .. '" (no handler and no known ancestor)'
end

-- True when `meta` marks the ref optional or nullable. Both collapse onto
-- Rust's single `Option<T>`, the same convention rust-serde.ts uses — JS
-- doesn't distinguish "missing" from "null" at wasm-bindgen's `Option<T>`
-- boundary either.
--: (meta: Meta) -> boolean
local function is_optional(meta)
	return meta.optional == true or meta.nullable == true
end

-- Inline wasm-bindgen Rust type expression for `ref`, wrapping in
-- `Option<T>` when `meta.optional` or `meta.nullable` is set. Returns
-- `(nil, errmsg)` for any kind with no direct ABI mapping — see the
-- `unsupported` handlers above and this file's header.
--: (ref: TypeRef) -> (string | nil, string | nil)
function M.rust_wasm_bindgen_type_from_type_ref(ref)
	local converter = converter_for(ref.shape.kind)
	if converter == nil then return nil, unhandled_kind_message(ref.shape.kind) end
	local base, err = converter(ref.shape, ref.meta)
	if base == nil then return nil, err end
	if is_optional(ref.meta) then return "Option<" .. base .. ">", nil end
	return base, nil
end

-- ── Declarations ─────────────────────────────────────────────────────────────

--:: FieldType = { type: string, rustName: string, ident: string, attrs: StringList }

-- `bare_type` and `build_struct` are mutually recursive (a struct's fields
-- go through `bare_type`, which hoists nested structs back through
-- `build_struct`), so they live on a table rather than as forward-declared
-- locals: an annotated `local f --: T` with no initializer is rejected
-- unless `nil` is admitted into `T`, which would put an unreachable nil
-- check at every call site. `field_type` and `build_function` join them for
-- uniformity — everything that builds a declaration is one group.
local emit = {}

-- Field/param-context inline type: same as
-- `rust_wasm_bindgen_type_from_type_ref`, except `object`/`enum` hoist a fresh
-- named declaration into `decls` under `name_hint` (PascalCase) instead of
-- falling back to a generic placeholder — mirroring rust-serde.ts's
-- `bareType` (Rust, like FlatBuffers, has no anonymous nested struct/enum
-- syntax). `Vec<object>`/`Vec<enum>` hoist the element type under the same
-- name hint and wrap it in `Vec<...>`. `union` is still refused even in this
-- context — see `REASON_UNION`.
--
-- `decls` is threaded by reference and appended to in place, exactly as in
-- the TS: a nested hoist pushes its own dependencies before the declaration
-- that needs them, so the emitted order is dependency-first.
--: (name_hint: string, ref: TypeRef, decls: StringList) -> (string | nil, string | nil)
function emit.bare_type(name_hint, ref, decls)
	local kind = ref.shape.kind
	if codegen.is_a(kind, "object") then
		local decl, err = emit.build_struct(name_hint, ref, decls)
		if decl == nil then return nil, err end
		decls[#decls + 1] = decl
		return name_hint, nil
	end
	if kind == "enum" then
		decls[#decls + 1] = emit.build_enum(name_hint, ref)
		return name_hint, nil
	end
	if kind == "array" or kind == "stream" or kind == "page" then
		local element = (ref.shape --[[: { element: TypeRef, ... }]]).element
		local element_kind = element.shape.kind
		if codegen.is_a(element_kind, "object") or element_kind == "enum" then
			local hoisted, hoist_err = emit.bare_type(name_hint, element, decls)
			if hoisted == nil then return nil, hoist_err end
			return "Vec<" .. hoisted .. ">", nil
		end
		local inner, err = vec_element_type(element)
		if inner == nil then return nil, err end
		return "Vec<" .. inner .. ">", nil
	end
	local converter = converter_for(kind)
	if converter == nil then return nil, unhandled_kind_message(kind) end
	return converter(ref.shape, ref.meta)
end

-- Field type + `js_name`/`readonly` attribute lines needed alongside it.
-- `meta.readonly` maps directly onto wasm-bindgen's own `readonly` field
-- attribute (both mean "no JS-side setter"). A field/param name that doesn't
-- round-trip through snake_case gets `#[wasm_bindgen(js_name = "...")]`,
-- mirroring rust-serde.ts's `#[serde(rename = "...")]` for the same reason
-- (wire-format name preserved, Rust identifier stays idiomatic) — confirmed
-- via wasm-bindgen's js_name.md, which documents this exact attribute on
-- both struct fields and function/method parameters.
--: (field_name: string, field_ref: TypeRef, decls: StringList) -> (FieldType | nil, string | nil)
function emit.field_type(field_name, field_ref, decls)
	local bare, err = emit.bare_type(codegen.pascal_case_strip_separators(field_name), field_ref, decls)
	if bare == nil then return nil, err end
	local rust_type = bare
	if is_optional(field_ref.meta) then rust_type = "Option<" .. bare .. ">" end
	local rust_name = codegen.snake_case_strip_separators(field_name)
	local ident = escape_rust_ident(rust_name)
	local attrs = {} --[[: StringList]]
	local n = 0
	if rust_name ~= field_name or ident ~= rust_name then
		n = n + 1
		attrs[n] = "js_name = " .. codegen.quote(field_name)
	end
	if field_ref.meta.readonly == true then
		n = n + 1
		attrs[n] = "readonly"
	end
	return { type = rust_type, rustName = rust_name, ident = ident, attrs = attrs }, nil
end

--: (indent: string, meta: Meta) -> StringList
local function doc_comment(indent, meta)
	local description = meta.description
	if type(description) == "string" then
		local out = {} --[[: StringList]]
		out[1] = indent .. "/// " .. description
		return out
	end
	return {}
end

-- `#[derive(Clone)]` is required for `getter_with_clone` (wasm-bindgen's
-- generated getters need Clone when a field isn't Copy — String, Vec<_>,
-- nested exported structs never are). Applied unconditionally rather than
-- per-field for simplicity; every field type this projector emits (leaf
-- primitives, String, Vec<T>, other #[derive(Clone)] structs, JsValue) is
-- Clone.
--: (name: string, ref: TypeRef, decls: StringList) -> (string | nil, string | nil)
function emit.build_struct(name, ref, decls)
	local fields = (ref.shape --[[: { fields: { [string]: TypeRef }, ... }]]).fields
	local lines = doc_comment("", ref.meta)
	local n = #lines
	if ref.meta.deprecated == true then
		n = n + 1
		lines[n] = "#[deprecated]"
	end
	lines[n + 1] = "#[derive(Clone)]"
	lines[n + 2] = "#[wasm_bindgen(getter_with_clone)]"
	lines[n + 3] = "pub struct " .. name .. " {"
	n = n + 3

	local names = ordered_keys(fields)
	for i = 1, #names do
		local field_name = names[i]
		local field_ref = fields[field_name]
		local field, err = emit.field_type(field_name, field_ref, decls)
		if field == nil then return nil, err end
		local docs = doc_comment("    ", field_ref.meta)
		for j = 1, #docs do
			n = n + 1
			lines[n] = docs[j]
		end
		if #field.attrs > 0 then
			n = n + 1
			lines[n] = "    #[wasm_bindgen(" .. table.concat(field.attrs, ", ") .. ")]"
		end
		if field_ref.meta.deprecated == true then
			n = n + 1
			lines[n] = "    #[deprecated]"
		end
		n = n + 1
		lines[n] = "    pub " .. field.ident .. ": " .. field.type .. ","
	end

	lines[n + 1] = "}"
	return table.concat(lines, "\n"), nil
end

-- Fieldless / string-discriminant enum — matches wasm-bindgen's own
-- "String Discriminants" form (guide/src/reference/types/enums.md) exactly:
-- `Variant = "wireValue"`, preserving the IR member's exact wire string as
-- the JS-visible value without a separate rename attribute.
--: (name: string, ref: TypeRef) -> string
function emit.build_enum(name, ref)
	local members = (ref.shape --[[: { members: StringList, ... }]]).members
	local lines = doc_comment("", ref.meta)
	local n = #lines
	lines[n + 1] = "#[wasm_bindgen]"
	lines[n + 2] = "pub enum " .. name .. " {"
	n = n + 2
	for i = 1, #members do
		local member = members[i]
		n = n + 1
		lines[n] = "    " .. codegen.pascal_case_strip_separators(member) .. " = " .. codegen.quote(member) .. ","
	end
	lines[n + 1] = "}"
	return table.concat(lines, "\n")
end

-- Free function (`function` kind with no `thisType`) as a
-- `#[wasm_bindgen] pub fn`. Body is a `todo!()` stub — type-ir carries no
-- implementation, only the signature, so the honest output is a signature
-- that compiles and panics if called before the caller fills it in (the
-- standard Rust scaffolding idiom; there's no valid free-standing
-- signature-only Rust syntax outside a trait). `method` (thisType present)
-- is rejected earlier, in `rust_wasm_bindgen_source_from_type_ref`.
--:: FunctionShape = { params: { [integer]: { name: string, type: TypeRef } }, returnType: TypeRef, ... }
--: (name: string, ref: TypeRef, decls: StringList) -> (string | nil, string | nil)
function emit.build_function(name, ref, decls)
	local shape = ref.shape --[[: FunctionShape]]
	local fn_name = codegen.snake_case_strip_separators(name)
	local attrs = {} --[[: StringList]]
	if fn_name ~= name then attrs[1] = "js_name = " .. codegen.quote(name) end

	local params = {} --[[: StringList]]
	for i = 1, #shape.params do
		local p = shape.params[i]
		local bare, err = emit.bare_type(codegen.pascal_case_strip_separators(p.name), p.type, decls)
		if bare == nil then return nil, err end
		local param_type = bare
		if is_optional(p.type.meta) then param_type = "Option<" .. bare .. ">" end
		local rust_name = codegen.snake_case_strip_separators(p.name)
		local ident = escape_rust_ident(rust_name)
		local rename = ""
		if rust_name ~= p.name or ident ~= rust_name then
			rename = "#[wasm_bindgen(js_name = " .. codegen.quote(p.name) .. ")] "
		end
		params[i] = rename .. ident .. ": " .. param_type
	end

	local return_kind = shape.returnType.shape.kind
	local return_type = ""
	if return_kind ~= "void" and return_kind ~= "null" then
		local returned, err =
			emit.bare_type(codegen.pascal_case_strip_separators(name) .. "Return", shape.returnType, decls)
		if returned == nil then return nil, err end
		return_type = " -> " .. returned
	end

	local lines = doc_comment("", ref.meta)
	local n = #lines + 1
	if #attrs > 0 then
		lines[n] = "#[wasm_bindgen(" .. table.concat(attrs, ", ") .. ")]"
	else
		lines[n] = "#[wasm_bindgen]"
	end
	lines[n + 1] = "pub fn " .. fn_name .. "(" .. table.concat(params, ", ") .. ")" .. return_type .. " {"
	lines[n + 2] = "    todo!(" .. codegen.quote("implement " .. fn_name) .. ")"
	lines[n + 3] = "}"
	return table.concat(lines, "\n"), nil
end

-- ── Entry point ──────────────────────────────────────────────────────────────

local FUNCTION_THIS_TYPE_REFUSAL =
	'toWasmBindgen: "function" with a thisType (an implicit/explicit receiver) has no free-function wasm-bindgen mapping — see the "method" handler for why'

local FUNCTION_NEEDS_NAME_REFUSAL =
	'toWasmBindgen: "function" requires a name — wasm-bindgen exports are named JS bindings, not anonymous inline types'

-- Lower a `TypeRef` to wasm-bindgen-annotated Rust source. With `name`,
-- emits a named top-level declaration — `struct` for `object`, `enum` for
-- `enum` (fieldless/string-discriminant), a `#[wasm_bindgen] pub fn` for
-- `function` (refuses `method` — see `REASON_METHOD`), or a `pub type` alias
-- for anything else (primitives, `array`, ...) — preceded by any struct/enum
-- declarations hoisted out of nested fields/params (see `emit.bare_type`).
-- Without `name`, returns just the inline type expression for `ref`
-- (`rust_wasm_bindgen_type_from_type_ref`).
--
-- Returns `(nil, errmsg)` for any kind (or nested kind) with no direct
-- wasm-bindgen ABI mapping — see this file's header for the full unsupported
-- list and why this projector refuses instead of degrading.
--: (ref: TypeRef, name: string | nil) -> (string | nil, string | nil)
function M.rust_wasm_bindgen_source_from_type_ref(ref, name)
	local kind = ref.shape.kind

	if kind == "function" then
		local this_type = (ref.shape --[[: { thisType: unknown, ... }]]).thisType
		if this_type ~= nil then return nil, FUNCTION_THIS_TYPE_REFUSAL end
		if name == nil then return nil, FUNCTION_NEEDS_NAME_REFUSAL end
		local decls = {} --[[: StringList]]
		local fn, err = emit.build_function(name, ref, decls)
		if fn == nil then return nil, err end
		decls[#decls + 1] = fn
		return table.concat(decls, "\n\n"), nil
	end

	-- Shares the inline-position `method` handler's explanatory message.
	if kind == "method" then return nil, unsupported_message("method", REASON_METHOD) end

	if name == nil then return M.rust_wasm_bindgen_type_from_type_ref(ref) end

	local decls = {} --[[: StringList]]
	local main_decl = "" --: string
	if codegen.is_a(kind, "object") then
		local decl, err = emit.build_struct(name, ref, decls)
		if decl == nil then return nil, err end
		main_decl = decl
	elseif kind == "enum" then
		main_decl = emit.build_enum(name, ref)
	elseif kind == "union" then
		-- Shares the inline-position `union` handler's explanatory message.
		-- (The TS calls that handler for its throw and then writes an
		-- unreachable `mainDecl = ""`; sharing the message as a value needs no
		-- unreachable branch.)
		return nil, unsupported_message("union", REASON_UNION)
	else
		local inline, err = M.rust_wasm_bindgen_type_from_type_ref(ref)
		if inline == nil then return nil, err end
		main_decl = "pub type " .. name .. " = " .. inline .. ";"
	end

	decls[#decls + 1] = main_decl
	return table.concat(decls, "\n\n"), nil
end

return M
