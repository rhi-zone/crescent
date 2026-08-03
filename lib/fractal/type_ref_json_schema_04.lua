-- lib/fractal/type_ref_json_schema_04.lua — project a TypeRef to JSON Schema
-- draft-04. Ported from fractal's packages/type-ir/src/json-schema-04.ts.
--
-- Divergences from draft-07 / draft 2020-12 handled here:
--
--   - `$schema` is "http://json-schema.org/draft-04/schema#" (draft-04 §6).
--   - the document identifier keyword is `id`, not `$id` (draft-04 §7.2; `$id`
--     arrives in draft-06).
--   - no `const` (draft-06) — a literal becomes `enum: [value]`.
--   - `$ref` targets `#/definitions/...` (draft-04 §7.2.3; `$defs` arrives in
--     draft-2019-09).
--   - no boolean schemas (draft-06) — `never` must be `{ "not": {} }`, not the
--     literal `false` draft-07 uses.
--   - tuples use `items` as an array plus `additionalItems: false`
--     (draft-04 §5.3.1).
--   - nullability ALWAYS wraps in `anyOf: [schema, {type:"null"}]`. draft-04
--     §5.5.2 does permit `type` as an array of primitive type names, but the
--     uniform `anyOf` encoding composes safely with every other keyword, so
--     the TS source uses it unconditionally and so does this port.
--   - no `examples` (draft-06), no `$comment` (draft-07), no `title` in the
--     meta pass, no `readOnly`/`writeOnly` (draft-07) — `meta.readonly` on a
--     field is DROPPED rather than emitting a keyword draft-04 does not define.
--   - `exclusiveMinimum`/`exclusiveMaximum` are BOOLEAN modifiers on
--     `minimum`/`maximum` (draft-04 §5.1.1/§5.1.2), not standalone numbers.
--   - `instance` and `page` have no handler and no parent in the lattice, so
--     both project to the empty schema. Deliberate: their vendor-extension
--     degradations are decisions the 2020-12 projector makes, not draft-04
--     ones.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: JsonSchema04 = { [string]: unknown }

-- The recursive projector, threaded into each converter as its first argument
-- rather than closed over — see type_ref_json_schema.lua for why.
--:: JsonSchema04Project = (ref: TypeRef) -> JsonSchema04

--:: JsonSchema04Converter = (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04

-- A top-level declaration: draft-04's document-level keywords, as opposed to
-- the per-node keywords a converter produces.
--:: JsonSchema04Declaration = { id?: string, definitions?: { [string]: TypeRef } }

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A shallow copy of `schema` with `key` set. Copy, not mutation: the `leaf`
-- converters return a SHARED constant table on every call.
--: (schema: JsonSchema04, key: string, value: unknown) -> JsonSchema04
local function assign(schema, key, value)
	local out = {} --: JsonSchema04
	for k, v in pairs(schema) do out[k] = v end
	out[key] = value
	return out
end

--: (schema: JsonSchema04) -> JsonSchema04Converter
local function leaf(schema)
	--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
	return function(_project, _shape, _meta)
		return schema
	end
end

-- A record's string keys in byte order — the deterministic stand-in for JS
-- insertion order, same rationale as `ordered_keys` in type_ref.lua.
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

--: (list: unknown[]) -> unknown[]
local function copy_list(list)
	local out = {} --: unknown[]
	for i = 1, #list do out[i] = list[i] end
	return out
end

-- Infer the `type` for an enum's members from their actual runtime types
-- rather than assuming `string` — see type_ref_json_schema.lua for the full
-- rationale. Mixed membership omits `type` and relies on `enum` alone, which
-- is valid: `type` is optional, and `enum` on its own still constrains the
-- instance to the listed values.
--: (members: unknown[]) -> JsonSchema04
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

-- `$comment` is draft-07+ and `examples` draft-06+, so neither appears here.
-- Held as a LIST, not a set, so the emitted key order is fixed rather than
-- `pairs()`-dependent.
local passthrough_keys = {
	"minLength",
	"maxLength",
	"pattern",
	"multipleOf",
} --[[: string[] ]]

-- draft-04 §5.1.1/§5.1.2: exclusiveMinimum/exclusiveMaximum are BOOLEAN
-- modifiers on `minimum`/`maximum`. A `meta.exclusiveMinimum` value is
-- therefore the bound itself, emitted as `minimum` with the modifier set.
--: (schema: JsonSchema04, meta: Meta) -> JsonSchema04
local function apply_numeric_bounds(schema, meta)
	local result = schema

	if meta.exclusiveMinimum ~= nil then
		result = assign(assign(result, "minimum", meta.exclusiveMinimum), "exclusiveMinimum", true)
	elseif meta.minimum ~= nil then
		result = assign(result, "minimum", meta.minimum)
	end

	if meta.exclusiveMaximum ~= nil then
		result = assign(assign(result, "maximum", meta.exclusiveMaximum), "exclusiveMaximum", true)
	elseif meta.maximum ~= nil then
		result = assign(result, "maximum", meta.maximum)
	end

	return result
end

--: (schema: JsonSchema04, meta: Meta) -> JsonSchema04
local function with_meta(schema, meta)
	local result = schema

	-- draft-04 has no `nullable` keyword and no `["T","null"]` shorthand this
	-- projector is willing to rely on — always wrap.
	if meta.nullable == true then result = { anyOf = { result, { type = "null" } } } end

	if type(meta.description) == "string" then result = assign(result, "description", meta.description) end
	if meta.deprecated == true then result = assign(result, "deprecated", true) end
	-- A JSON null default is the shared `lib.null` sentinel, not Lua `nil`, so
	-- it survives this presence test.
	if meta.default ~= nil then result = assign(result, "default", meta.default) end

	result = apply_numeric_bounds(result, meta)

	for i = 1, #passthrough_keys do
		local key = passthrough_keys[i]
		if meta[key] ~= nil then result = assign(result, key, meta[key]) end
	end

	return result
end

-- ── Converters ───────────────────────────────────────────────────────────────

-- draft-04 has no `readOnly` (a draft-07 addition), so a field's
-- `meta.readonly` contributes nothing here — the one place this projector is
-- deliberately lossier than the later drafts'.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
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
			properties[name] = project(field)
			if field.meta.optional ~= true then
				n = n + 1
				required[n] = name
			end
		end
	end
	if n > 0 then return { type = "object", properties = properties, required = required } end
	return { type = "object", properties = properties }
end

--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_array(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element) }
end

-- draft-04 §5.3.1: `items` as an array of schemas positionally validates a
-- tuple; `additionalItems: false` forbids extra elements.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_tuple(project, shape, _meta)
	local s = shape --[[: { elements: TypeRef[], ... }]]
	local items = {} --: unknown[]
	for i = 1, #s.elements do items[i] = project(s.elements[i]) end
	return { type = "array", items = items, additionalItems = false }
end

--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_map(project, shape, _meta)
	local s = shape --[[: { value: TypeRef, ... }]]
	return { type = "object", additionalProperties = project(s.value) }
end

-- draft-04 has no streaming/async-sequence vocabulary — degrade to the same
-- array-of-element shape used for a materialized sequence, carrying
-- `x-stream: true`.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_stream(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element), ["x-stream"] = true }
end

-- draft-04 §5.5.4 defines `oneOf` (exactly one variant matches) but no
-- `discriminator` keyword; the OpenAPI-originated `discriminator:
-- { propertyName }` shape is a widely-recognized extension, carried by
-- `meta.discriminator`. Plain unions keep `anyOf`.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_union(project, shape, meta)
	local s = shape --[[: { variants: TypeRef[], ... }]]
	local variants = {} --: unknown[]
	for i = 1, #s.variants do variants[i] = project(s.variants[i]) end
	if type(meta.discriminator) == "string" then
		return { oneOf = variants, discriminator = { propertyName = meta.discriminator } }
	end
	return { anyOf = variants }
end

-- draft-04 has no `const` (draft-06) — a single-member `enum` is the
-- equivalent. A null literal carries the shared `lib.null` sentinel, never Lua
-- `nil`, so the member is always actually present.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_literal(_project, shape, _meta)
	local s = shape --[[: { value: unknown, ... }]]
	return { enum = { s.value } }
end

--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_enum(_project, shape, _meta)
	local s = shape --[[: { members: unknown[], ... }]]
	return enum_schema(s.members)
end

--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
local function convert_ref(_project, shape, _meta)
	local s = shape --[[: { target: string, ... }]]
	return { ["$ref"] = "#/definitions/" .. s.target }
end

-- draft-04 §5.5.3 `allOf`: every listed schema must validate — the faithful
-- encoding of a structural intersection (mixin composition), unchanged from
-- later drafts.
--: (project: JsonSchema04Project, shape: TypeShape, meta: Meta) -> JsonSchema04
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
	-- No boolean schemas until draft-06, so `never` cannot be the literal
	-- `false` draft-07 uses.
	never = leaf({ ["not"] = {} }),
	object = convert_object,
	array = convert_array,
	tuple = convert_tuple,
	map = convert_map,
	stream = convert_stream,
	union = convert_union,
	literal = convert_literal,
	enum = convert_enum,
	ref = convert_ref,
	intersection = convert_intersection,
	-- draft-04 has no callable-type vocabulary — degrade honestly to an untyped
	-- schema carrying `x-function: true`.
	["function"] = leaf({ ["x-function"] = true }),
	-- Same degrade, carrying `x-method: true` so a callable belonging to a
	-- type's contract stays distinguishable from a standalone one.
	method = leaf({ ["x-method"] = true }),
	-- No service/interface-with-methods vocabulary either.
	interface = leaf({ type = "object", ["x-interface"] = true }),
} --[[: { [string]: JsonSchema04Converter }]]

-- ── Entry points ─────────────────────────────────────────────────────────────

-- Project one TypeRef. A kind with no handler and no handled ancestor projects
-- to the empty schema (plus whatever `meta` contributes), which constrains
-- nothing — the honest reading of "this draft cannot express that kind".
--: (ref: TypeRef) -> JsonSchema04
function M.type_ref_to_json_schema_04(ref)
	local converter = type_ref.resolve(ref.shape.kind, handlers)
	if converter == nil then return with_meta({}, ref.meta) end
	return with_meta(converter(M.type_ref_to_json_schema_04, ref.shape, ref.meta), ref.meta)
end

-- Wrap a top-level TypeRef with draft-04's document-level keywords: `$schema`,
-- the optional `id`, and the `definitions` map the `ref` converter's
-- `#/definitions/NAME` pointers resolve against.
--
-- Takes a bare TypeRef plus a declaration rather than a `TypeRefDocument`,
-- matching the TS source: draft-04's `id` has no place in a TypeRefDocument,
-- and the two carry different information.
--: (ref: TypeRef, declaration: JsonSchema04Declaration | nil) -> JsonSchema04
function M.type_ref_to_json_schema_04_document(ref, declaration)
	local decl = declaration or {}
	local schema = assign(
		M.type_ref_to_json_schema_04(ref),
		"$schema",
		"http://json-schema.org/draft-04/schema#"
	)

	if decl.id ~= nil then schema = assign(schema, "id", decl.id) end

	local defs = decl.definitions
	if defs ~= nil then
		local definitions = {} --: { [string]: unknown }
		local names = ordered_keys(defs)
		for i = 1, #names do
			local def = defs[names[i]]
			if def ~= nil then definitions[names[i]] = M.type_ref_to_json_schema_04(def) end
		end
		schema = assign(schema, "definitions", definitions)
	end

	return schema
end

return M
