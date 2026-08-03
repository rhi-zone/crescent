-- lib/fractal/type_ref_json_schema.lua — project a TypeRef to JSON Schema
-- draft 2020-12. Ported from fractal's packages/type-ir/src/json-schema.ts.
--
-- The input model is `lib/fractal/type_ref.lua` (shape constructors, the kind
-- lattice, documents); this module only reads it. Dispatch goes through
-- `type_ref.resolve`, so a kind registered by an extension module is projected
-- by its nearest ancestor's handler (`method` -> `function`, `integer`-derived
-- refinements -> `integer`) with no per-kind branch here.
--
-- ONE DIALECT PER FILE, matching the TS package's own layout: draft-07 lives in
-- type_ref_json_schema_07.lua and draft-04 in type_ref_json_schema_04.lua. The
-- dialects diverge on the exact keywords they may emit, and each file's
-- per-kind comments are about ITS draft — merging them would make every comment
-- conditional. (The split is also what keeps `type_ref.resolve`'s single
-- generic instantiation per file well-typed: draft-07's converters return
-- `JsonSchema07`, which includes the boolean `false` schema, and draft
-- 2020-12's do not.)
--
-- EMPTY OBJECT vs EMPTY ARRAY. `unknown` projects to the empty schema `{}`,
-- which in Lua is the same value as an empty array. Every JSON encoder in this
-- repo has to pick one for an empty table, so a projected schema that contains
-- an empty sub-schema is ambiguous at SERIALIZATION time — not at consumption
-- time: `lib/json_schema` reads a schema by key lookup, and an empty schema
-- correctly imposes no constraints either way. Callers that must serialize an
-- exactly-round-tripping schema are the ones that need to care.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: JsonSchema = { [string]: unknown }

-- The recursive projector, threaded into each converter as its first argument.
--
-- fractal's TS lets converters close over the module-level `toJsonSchema`,
-- which Lua cannot do without a forward-declared local that is `nil` at
-- closure-creation time. Passing it explicitly keeps the handler table free of
-- that hole and makes every converter's dependency visible in its signature.
--:: JsonSchemaProject = (ref: TypeRef) -> JsonSchema

--:: JsonSchemaConverter = (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A shallow copy of `schema` with `key` set. Copy, not mutation: the `leaf`
-- converters below return a SHARED constant table on every call (as fractal's
-- `leaf` closures do), so mutating a converter's result would corrupt every
-- later projection of the same kind.
--: (schema: JsonSchema, key: string, value: unknown) -> JsonSchema
local function assign(schema, key, value)
	local out = {} --: JsonSchema
	for k, v in pairs(schema) do out[k] = v end
	out[key] = value
	return out
end

-- A converter for a kind whose schema is a constant, ignoring shape and meta.
--: (schema: JsonSchema) -> JsonSchemaConverter
local function leaf(schema)
	--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
	return function(_project, _shape, _meta)
		return schema
	end
end

-- True when `v` is a non-empty Lua list — the stand-in for `Array.isArray`,
-- used to decide whether `meta.examples` is the array draft 2020-12 §9.5
-- requires. An empty table reads as "not a list" here, which is the harmless
-- reading: an empty `examples` array carries no information and is dropped.
--: (v: unknown) -> boolean
local function is_list(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [unknown]: unknown }]]
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	if count == 0 then return false end
	for i = 1, count do
		if t[i] == nil then return false end
	end
	return true
end

-- A record's string keys in byte order.
--
-- fractal's TS iterates `Object.entries`/`Object.keys`, i.e. JS insertion
-- order. Lua tables have no insertion order to recover, so `pairs()` alone
-- would make `required` lists and `$defs` iteration vary between runs. Byte
-- order is the deterministic stand-in — same rationale as `ordered_keys` in
-- type_ref.lua. The emitted SET of properties/definitions is identical either
-- way; only the order of the `required` array differs from the TS output.
--: (t: { [string]: unknown }) -> string[]
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

-- A plain copy of a list, so the emitted schema never aliases the input shape.
--: (list: unknown[]) -> unknown[]
local function copy_list(list)
	local out = {} --: unknown[]
	for i = 1, #list do out[i] = list[i] end
	return out
end

-- Infer the JSON Schema `type` for an enum's members from their actual runtime
-- types rather than assuming `string`. type_ref.lua's `EnumShape` declares
-- `members: string[]`, but a converter receives the open `TypeShape`: a kind
-- registered by an importer (fractal's `from-*` modules build enums straight
-- from a source type system) can legitimately carry integer or boolean
-- members. Mixed membership omits `type` entirely and relies on `enum` alone,
-- valid per draft 2020-12 §6.1.2.
--: (members: unknown[]) -> JsonSchema
local function enum_schema(members)
	local n = #members
	if n > 0 then
		local all_boolean = true
		local all_number = true
		local all_string = true
		local all_integer = true
		for i = 1, n do
			local m = members[i]
			if type(m) == "number" then
				all_boolean = false
				all_string = false
				if m ~= math.floor(m) then all_integer = false end
			elseif type(m) == "boolean" then
				all_number = false
				all_integer = false
				all_string = false
			elseif type(m) == "string" then
				all_boolean = false
				all_number = false
				all_integer = false
			else
				all_boolean = false
				all_number = false
				all_integer = false
				all_string = false
			end
		end
		if all_boolean then return { type = "boolean", enum = copy_list(members) } end
		if all_number then
			return { type = all_integer and "integer" or "number", enum = copy_list(members) }
		end
		if all_string then return { type = "string", enum = copy_list(members) } end
	end
	return { enum = copy_list(members) }
end

-- ── Meta ─────────────────────────────────────────────────────────────────────

-- Keys copied verbatim from `meta` onto the schema. Held as a LIST, not a set,
-- so the emitted key order is fixed rather than `pairs()`-dependent.
local passthrough_keys = {
	"minimum",
	"maximum",
	-- draft 2020-12 §6.2.3/§6.2.4 (numeric form, since draft-06 — see
	-- type_ref_json_schema_04.lua for the boolean-modifier form draft-04 uses).
	"exclusiveMinimum",
	"exclusiveMaximum",
	"minLength",
	"maxLength",
	"pattern",
	"multipleOf",
	"$comment",
	-- draft 2020-12 §9.5 (Vocabularies for Basic Meta-Data Annotations):
	-- readOnly, writeOnly, examples (since draft-06/07).
	"readOnly",
	"writeOnly",
} --[[: string[] ]]

--: (schema: JsonSchema, meta: Meta, complex: boolean) -> JsonSchema
local function with_meta(schema, meta, complex)
	local result = schema

	if meta.nullable == true then
		if complex then
			result = { anyOf = { result, { type = "null" } } }
		elseif type(result.type) == "string" then
			result = assign(result, "type", { result.type, "null" })
		else
			result = { anyOf = { result, { type = "null" } } }
		end
	end

	if type(meta.title) == "string" then result = assign(result, "title", meta.title) end
	if type(meta.description) == "string" then result = assign(result, "description", meta.description) end
	if meta.deprecated == true then result = assign(result, "deprecated", true) end
	-- A JSON null default is the shared sentinel (`lib.null`), not Lua `nil`,
	-- so it survives this presence test — Lua cannot distinguish an absent key
	-- from one holding `nil`, which is exactly why the sentinel exists.
	if meta.default ~= nil then result = assign(result, "default", meta.default) end
	-- draft 2020-12 §9.5: "examples" is an ARRAY of example values, distinct
	-- from OAS's singular "example".
	if is_list(meta.examples) then result = assign(result, "examples", meta.examples) end

	for i = 1, #passthrough_keys do
		local key = passthrough_keys[i]
		if meta[key] ~= nil then result = assign(result, key, meta[key]) end
	end

	return result
end

-- ── Converters ───────────────────────────────────────────────────────────────

--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_object(project, shape, _meta)
	local s = shape --[[: { fields: { [string]: TypeRef }, ... }]]
	local properties = {} --: { [string]: unknown }
	local required = {} --: string[]
	local n = 0
	local names = ordered_keys(s.fields)
	for i = 1, #names do
		local name = names[i]
		local field = s.fields[name]
		if field ~= nil then
			local prop = project(field)
			-- draft 2020-12 §9.5: `readOnly` is a per-schema annotation, driven
			-- by the `meta.readonly` open-metadata-bag convention set on the
			-- FIELD's own TypeRef.
			if field.meta.readonly == true then prop = assign(prop, "readOnly", true) end
			properties[name] = prop
			if field.meta.optional ~= true then
				n = n + 1
				required[n] = name
			end
		end
	end
	-- Two literals rather than one plus a conditional field write: a `--:
	-- JsonSchema`-annotated local that is later given a NAMED field takes on
	-- that field as part of its inferred type, which then propagates into the
	-- shared alias.
	if n > 0 then return { type = "object", properties = properties, required = required } end
	return { type = "object", properties = properties }
end

-- JSON Schema has no class-identity concept, and `instance` carries no field
-- data to build `properties` from (it is purely nominal). Degrade honestly to
-- an untyped object schema, carrying the class name as `x-class-name` — a
-- vendor-extension-style key, the same convention the OAS projectors use — so
-- tooling that wants the identity back can still read it. `x-declaration-file`
-- travels alongside it so an importer can rebuild the FULL nominal identity
-- rather than half of it.
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_instance(_project, shape, _meta)
	local s = shape --[[: { className: string, declarationFile: string, ... }]]
	if s.declarationFile == "" then return { type = "object", ["x-class-name"] = s.className } end
	return {
		type = "object",
		["x-class-name"] = s.className,
		["x-declaration-file"] = s.declarationFile,
	}
end

--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_array(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element) }
end

-- draft 2020-12: `prefixItems` validates positionally; `items: false`
-- forbids anything past the listed prefix.
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_tuple(project, shape, _meta)
	local s = shape --[[: { elements: TypeRef[], ... }]]
	local items = {} --: unknown[]
	for i = 1, #s.elements do items[i] = project(s.elements[i]) end
	return { type = "array", prefixItems = items, items = false }
end

--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_map(project, shape, _meta)
	local s = shape --[[: { value: TypeRef, ... }]]
	return { type = "object", additionalProperties = project(s.value) }
end

-- JSON Schema has no streaming/async-sequence vocabulary — degrade to the same
-- array-of-element shape used for a materialized sequence, carrying
-- `x-stream: true` so tooling that cares can still tell a stream apart from an
-- ordinary array.
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_stream(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element), ["x-stream"] = true }
end

-- No pagination vocabulary either — same array degrade, carrying
-- `x-page-style` so a paginated endpoint's items stay distinguishable from a
-- plain array.
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_page(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, style: string, ... }]]
	return { type = "array", items = project(s.element), ["x-page-style"] = s.style }
end

-- draft 2019-09 §9.2.1.2 defines no `discriminator` keyword itself, but the
-- OpenAPI-originated `discriminator: { propertyName }` shape is a
-- widely-recognized extension (carried by `meta.discriminator`, an open
-- metadata bag convention). `oneOf` — exactly one variant matches — is the
-- correct composition keyword once a discriminator makes variants mutually
-- exclusive by construction; plain unions keep `anyOf`.
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_union(project, shape, meta)
	local s = shape --[[: { variants: TypeRef[], ... }]]
	local variants = {} --: unknown[]
	for i = 1, #s.variants do variants[i] = project(s.variants[i]) end
	if type(meta.discriminator) == "string" then
		return { oneOf = variants, discriminator = { propertyName = meta.discriminator } }
	end
	return { anyOf = variants }
end

-- A null literal carries the shared `lib.null` sentinel, never Lua `nil`, so
-- `const` is always actually set (see type_ref.lua's `types.literal`).
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_literal(_project, shape, _meta)
	local s = shape --[[: { value: unknown, ... }]]
	return { const = s.value }
end

--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_enum(_project, shape, _meta)
	local s = shape --[[: { members: unknown[], ... }]]
	return enum_schema(s.members)
end

--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_ref(_project, shape, _meta)
	local s = shape --[[: { target: string, ... }]]
	return { ["$ref"] = "#/$defs/" .. s.target }
end

-- draft 2020-12 §10.2.1.1 `allOf`: every listed schema must validate — the
-- faithful encoding of a structural intersection (mixin composition).
--: (project: JsonSchemaProject, shape: TypeShape, meta: Meta) -> JsonSchema
local function convert_intersection(project, shape, _meta)
	local s = shape --[[: { members: TypeRef[], ... }]]
	local members = {} --: unknown[]
	for i = 1, #s.members do members[i] = project(s.members[i]) end
	return { allOf = members }
end

local handlers = {
	boolean = leaf({ type = "boolean" }),
	number = leaf({ type = "number" }),
	integer = leaf({ type = "integer" }),
	int32 = leaf({ type = "integer", format = "int32" }),
	int64 = leaf({ type = "integer", format = "int64" }),
	float32 = leaf({ type = "number", format = "float" }),
	float64 = leaf({ type = "number", format = "double" }),
	string = leaf({ type = "string" }),
	uuid = leaf({ type = "string", format = "uuid" }),
	uri = leaf({ type = "string", format = "uri" }),
	email = leaf({ type = "string", format = "email" }),
	datetime = leaf({ type = "string", format = "date-time" }),
	date = leaf({ type = "string", format = "date" }),
	time = leaf({ type = "string", format = "time" }),
	duration = leaf({ type = "string", format = "duration" }),
	bytes = leaf({ type = "string", contentEncoding = "base64" }),
	null = leaf({ type = "null" }),
	void = leaf({ type = "null" }),
	unknown = leaf({}),
	never = leaf({ ["not"] = {} }),
	object = convert_object,
	instance = convert_instance,
	array = convert_array,
	tuple = convert_tuple,
	map = convert_map,
	stream = convert_stream,
	page = convert_page,
	union = convert_union,
	literal = convert_literal,
	enum = convert_enum,
	ref = convert_ref,
	intersection = convert_intersection,
	-- JSON Schema has no callable-type vocabulary — degrade honestly to an
	-- untyped schema carrying `x-function: true`.
	["function"] = leaf({ ["x-function"] = true }),
	-- Same degrade, carrying `x-method: true` so tooling can distinguish "a
	-- standalone callable" from "a callable belonging to a type's contract".
	-- An explicit entry rather than relying on the lattice's `method` ->
	-- `function` fallback, because the distinguishing key is the whole point.
	method = leaf({ ["x-method"] = true }),
	-- No service/interface-with-methods vocabulary either.
	interface = leaf({ type = "object", ["x-interface"] = true }),
} --[[: { [string]: JsonSchemaConverter }]]

-- Kinds whose schema cannot absorb a `"null"` entry in its `type` keyword, so
-- nullability must wrap them in `anyOf` instead (see `with_meta`).
local complex_kinds = {
	object = true,
	instance = true,
	array = true,
	stream = true,
	page = true,
	tuple = true,
	map = true,
	union = true,
	intersection = true,
	["function"] = true,
	method = true,
	interface = true,
} --[[: { [string]: boolean } ]]

-- ── Entry points ─────────────────────────────────────────────────────────────

-- Project one TypeRef. A kind with no handler and no handled ancestor projects
-- to the empty schema (plus whatever `meta` contributes), which constrains
-- nothing — the honest reading of "this dialect cannot express that kind".
--: (ref: TypeRef) -> JsonSchema
function M.type_ref_to_json_schema(ref)
	local kind = ref.shape.kind
	local complex = complex_kinds[kind] == true
	local converter = type_ref.resolve(kind, handlers)
	if converter == nil then return with_meta({}, ref.meta, complex) end
	return with_meta(converter(M.type_ref_to_json_schema, ref.shape, ref.meta), ref.meta, complex)
end

-- Project a whole document to a self-contained schema: the root schema plus a
-- top-level `$defs` object — one entry per `doc.defs` name — that the `ref`
-- converter's `#/$defs/NAME` pointers resolve against, per draft 2020-12
-- §8.2.4. Empty `defs` omits `$defs` entirely, so this is a strict superset of
-- calling `type_ref_to_json_schema(doc.root)` for the no-sharing case.
--: (doc: TypeRefDocument) -> JsonSchema
function M.type_ref_document_to_json_schema(doc)
	local schema = M.type_ref_to_json_schema(doc.root)
	local names = ordered_keys(doc.defs)
	if #names == 0 then return schema end
	local defs = {} --: { [string]: unknown }
	for i = 1, #names do
		local def = doc.defs[names[i]]
		if def ~= nil then defs[names[i]] = M.type_ref_to_json_schema(def) end
	end
	return assign(schema, "$defs", defs)
end

return M
