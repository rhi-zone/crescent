-- lib/type-ir/openapi_20.lua — project a TypeRef to a Swagger 2.0
-- Schema Object. Ported from fractal's packages/type-ir/src/openapi20.ts.
--
-- Swagger 2.0 §4.6 (Data Types) + §4.7.4 (Schema Object): the vocabulary is
-- JSON Schema draft-04 restricted further. `type` MUST be a single string (no
-- type arrays), the only composition keyword kept is `allOf` (no `oneOf`, no
-- `anyOf`, no `not`), and there is no `nullable`, `deprecated`, `writeOnly`, or
-- `examples`. Vendor extensions (`x-*`, §4.7.26 Specification Extensions) are
-- the only escape hatch for concepts the format has no slot for, and this
-- projector uses them for exactly the concepts Swagger 2.0 dropped:
--
--   x-nullable   nullability, and the `null`/`void` kinds (the de facto
--                convention — Autorest, drf-yasg and other Swagger 2.0 tooling
--                read it).
--   x-deprecated `deprecated` on a Schema Object is an OAS 3.0 addition.
--   x-never      there is no way to say "no value satisfies this" without
--                `not`; marking the intent beats silently degrading to an
--                unconstrained schema.
--   x-oneOf      a union has no faithful encoding; the emitted schema accepts
--                every value (and more), with the variant list carried
--                losslessly alongside it.
--   x-stream / x-function / x-method / x-interface
--                the same kind degradations the other projectors apply.
--
-- `writeOnly` is DROPPED entirely (OAS 3.0 added it, and there is no
-- established vendor convention worth inventing here), as are `instance` and
-- `page`, which have no handler and no parent in the lattice.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.type-ir")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: OpenApi20Schema = { [string]: unknown }

-- The recursive projector, threaded into each converter as its first argument
-- rather than closed over — see json_schema.lua for why.
--:: OpenApi20Project = (ref: TypeRef) -> OpenApi20Schema

--:: OpenApi20Converter = (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A shallow copy of `schema` with `key` set. Copy, not mutation: the `leaf`
-- converters return a SHARED constant table on every call.
--: (schema: OpenApi20Schema, key: string, value: unknown) -> OpenApi20Schema
local function assign(schema, key, value)
	local out = {} --: OpenApi20Schema
	for k, v in pairs(schema) do out[k] = v end
	out[key] = value
	return out
end

--: (schema: OpenApi20Schema) -> OpenApi20Converter
local function leaf(schema)
	--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
	return function(_project, _shape, _meta)
		return schema
	end
end

-- A record's string keys in byte order — the deterministic stand-in for JS
-- insertion order, same rationale as `ordered_keys` in init.lua.
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

-- Structural equality over two projected schemas, used by the tuple converter
-- to decide whether every element shares one schema.
--
-- fractal's TS compares `JSON.stringify(a) === JSON.stringify(b)`, which is
-- key-order-sensitive but safe there because both sides come out of the same
-- converter. A recursive compare is the Lua equivalent and does not depend on
-- key order at all — encoding to a string first would need a JSON codec this
-- module has no other reason to require.
--: (a: unknown, b: unknown) -> boolean
local function deep_equal(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	local at = a --[[: { [unknown]: unknown }]]
	local bt = b --[[: { [unknown]: unknown }]]
	for k, v in pairs(at) do
		if not deep_equal(v, bt[k]) then return false end
	end
	for k in pairs(bt) do
		if at[k] == nil then return false end
	end
	return true
end

-- ── Meta ─────────────────────────────────────────────────────────────────────

-- `minimum`/`maximum` are NOT here: they interact with exclusiveMinimum/
-- exclusiveMaximum and are handled explicitly in `with_meta`. `$comment` is a
-- draft-07 keyword and has no place in Swagger 2.0's draft-04 base. Held as a
-- LIST, not a set, so the emitted key order is fixed rather than
-- `pairs()`-dependent.
local passthrough_keys = {
	"minLength",
	"maxLength",
	"pattern",
	"multipleOf",
} --[[: string[] ]]

--: (schema: OpenApi20Schema, meta: Meta) -> OpenApi20Schema
local function with_meta(schema, meta)
	local result = schema

	if meta.nullable == true then result = assign(result, "x-nullable", true) end

	if type(meta.description) == "string" then result = assign(result, "description", meta.description) end
	if meta.deprecated == true then result = assign(result, "x-deprecated", true) end
	-- A JSON null default/example is the shared `lib.null` sentinel, not Lua
	-- `nil`, so it survives these presence tests.
	if meta.default ~= nil then result = assign(result, "default", meta.default) end
	-- Swagger 2.0 §4.7.4 Schema Object has a singular `example` field; the
	-- plural `examples` map is an OAS 3.0 Media Type Object concept.
	if meta.example ~= nil then result = assign(result, "example", meta.example) end
	-- Swagger 2.0 §4.7.4 supports `readOnly` directly; `writeOnly` is OAS 3.0
	-- only and is dropped (lossy, deliberately).
	if meta.readOnly == true then result = assign(result, "readOnly", true) end

	-- Draft-04-style boolean modifiers: a `meta.exclusiveMinimum` value is the
	-- bound itself, emitted as `minimum` with the modifier set.
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

	for i = 1, #passthrough_keys do
		local key = passthrough_keys[i]
		if meta[key] ~= nil then result = assign(result, key, meta[key]) end
	end

	return result
end

-- ── Converters ───────────────────────────────────────────────────────────────

--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
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
			-- Swagger 2.0 §4.7.4: `readOnly` is a per-schema annotation, driven
			-- by the `meta.readonly` open-metadata-bag convention set on the
			-- FIELD's own TypeRef — distinct from `meta.readOnly`, which
			-- `with_meta` handles for schemas carrying the OAS-cased key
			-- directly.
			if field.meta.readonly == true then prop = assign(prop, "readOnly", true) end
			properties[name] = prop
			if field.meta.optional ~= true then
				n = n + 1
				required[n] = name
			end
		end
	end
	if n > 0 then return { type = "object", properties = properties, required = required } end
	return { type = "object", properties = properties }
end

--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_array(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element) }
end

-- Swagger 2.0 §4.7.4: "items — Required if type is array. Value MUST be an
-- object and not an array." There is no tuple-validation form at all, so
-- encoding a tuple is inherently lossy. When every element projects to the
-- same schema, that schema is the accurate common `items`; otherwise fall back
-- to the empty schema (any value), the least-wrong approximation of a mixed
-- tuple's element type.
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_tuple(project, shape, _meta)
	local s = shape --[[: { elements: TypeRef[], ... }]]
	local count = #s.elements
	if count == 0 then return { type = "array", items = {} } end
	local first = project(s.elements[1])
	for i = 2, count do
		if not deep_equal(project(s.elements[i]), first) then
			return { type = "array", items = {} }
		end
	end
	return { type = "array", items = first }
end

--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_map(project, shape, _meta)
	local s = shape --[[: { value: TypeRef, ... }]]
	return { type = "object", additionalProperties = project(s.value) }
end

-- Swagger 2.0 has no streaming/async-sequence vocabulary — degrade to the same
-- array-of-element shape used for a materialized sequence, carrying
-- `x-stream: true`.
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_stream(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element), ["x-stream"] = true }
end

-- No `oneOf`/`anyOf` (both OAS 3.0 additions — the only JSON Schema combinator
-- Swagger 2.0 kept is `allOf`, used solely for the discriminator/inheritance
-- pattern in §4.7.4). A union has no faithful encoding: the emitted schema is
-- otherwise empty (accepting every variant, and more), with `x-oneOf` carrying
-- the lossless variant list.
--
-- Swagger 2.0's `discriminator` is a plain STRING naming the property, unlike
-- OAS 3.0's Discriminator Object with a `propertyName` field.
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_union(project, shape, meta)
	local s = shape --[[: { variants: TypeRef[], ... }]]
	local variants = {} --: unknown[]
	for i = 1, #s.variants do variants[i] = project(s.variants[i]) end
	if type(meta.discriminator) == "string" then
		return { ["x-oneOf"] = variants, discriminator = meta.discriminator }
	end
	return { ["x-oneOf"] = variants }
end

-- No `const` in draft-04 — a single-member `enum` is the equivalent. A null
-- literal carries the shared `lib.null` sentinel, never Lua `nil`, so the
-- member is always actually present.
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_literal(_project, shape, _meta)
	local s = shape --[[: { value: unknown, ... }]]
	return { enum = { s.value } }
end

-- Unlike the JSON Schema projectors, this one does NOT infer the member type:
-- the TS source emits `type: "string"` unconditionally for Swagger 2.0, and
-- init.lua's `EnumShape` declares `members: string[]`.
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_enum(_project, shape, _meta)
	local s = shape --[[: { members: unknown[], ... }]]
	return { type = "string", enum = copy_list(s.members) }
end

-- Swagger 2.0 §4.7.4: `$ref` resolves against the top-level `definitions` map,
-- not `#/components/schemas/` (an OAS 3.0 rename).
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
local function convert_ref(_project, shape, _meta)
	local s = shape --[[: { target: string, ... }]]
	return { ["$ref"] = "#/definitions/" .. s.target }
end

-- Swagger 2.0 §4.7.4 keeps `allOf` from its draft-04 base — the faithful
-- encoding of a structural intersection (mixin composition).
--: (project: OpenApi20Project, shape: TypeShape, meta: Meta) -> OpenApi20Schema
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
	duration = leaf({ type = "string" }),
	-- Swagger 2.0 §4.6 Data Type Format table: `byte` is a base64-encoded
	-- string (`binary` is raw octets).
	bytes = leaf({ type = "string", format = "byte" }),
	-- No `type: "null"` and no `nullable` keyword — the closest signal is the
	-- same `x-nullable` convention `with_meta` uses, on an otherwise typeless
	-- schema since there is no scalar "null" type to declare.
	null = leaf({ ["x-nullable"] = true }),
	void = leaf({ ["x-nullable"] = true }),
	unknown = leaf({}),
	never = leaf({ ["x-never"] = true }),
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
	-- Swagger 2.0 has no callable-type concept — same vendor-extension
	-- degradation the other projectors use.
	["function"] = leaf({ ["x-function"] = true }),
	-- Same degrade, distinguished by `x-method: true`.
	method = leaf({ ["x-method"] = true }),
	-- No service/interface-with-methods concept either.
	interface = leaf({ type = "object", ["x-interface"] = true }),
} --[[: { [string]: OpenApi20Converter }]]

-- ── Entry points ─────────────────────────────────────────────────────────────

-- Project one TypeRef. A kind with no handler and no handled ancestor projects
-- to the empty schema (plus whatever `meta` contributes), which constrains
-- nothing — the honest reading of "Swagger 2.0 cannot express that kind".
--: (ref: TypeRef) -> OpenApi20Schema
function M.type_ref_to_openapi_20(ref)
	local converter = type_ref.resolve(ref.shape.kind, handlers)
	if converter == nil then return with_meta({}, ref.meta) end
	return with_meta(converter(M.type_ref_to_openapi_20, ref.shape, ref.meta), ref.meta)
end

-- Project a map of named TypeRefs into the top-level `definitions` map of a
-- Swagger Object (§2.2/§4.7.4), which the `ref` converter's `#/definitions/
-- NAME` pointers resolve against.
--
-- Takes a bare name -> TypeRef map rather than a `TypeRefDocument`, matching
-- the TS source: Swagger 2.0 has no place for a document ROOT schema — every
-- schema is reached from an operation, so only the definitions map is
-- meaningful at this level.
--: (refs: { [string]: TypeRef }) -> { [string]: unknown }
function M.type_refs_to_openapi_20_definitions(refs)
	local definitions = {} --: { [string]: unknown }
	local names = ordered_keys(refs)
	for i = 1, #names do
		local ref = refs[names[i]]
		if ref ~= nil then definitions[names[i]] = M.type_ref_to_openapi_20(ref) end
	end
	return definitions
end

return M
