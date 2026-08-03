-- lib/fractal/type_ref_openapi_30.lua — project a TypeRef to an OpenAPI 3.0
-- Schema Object. Ported from fractal's packages/type-ir/src/openapi30.ts.
--
-- OAS 3.0.3 §4.8.24 restricts schemas to a JSON Schema Wright Draft-05-based
-- vocabulary, so this is NOT the same output as any of the JSON Schema
-- projectors in this directory:
--
--   - nullability is `nullable: true`, not a `["T","null"]` type array
--     (§4.8.24.1) — there is no `type: "null"` at all.
--   - `exclusiveMinimum`/`exclusiveMaximum` are draft-04-style BOOLEAN
--     modifiers on `minimum`/`maximum`; the standalone numeric form arrives
--     with OAS 3.1's move to 2020-12.
--   - tuples use `items` as an array; `prefixItems` is 2020-12.
--   - there is no `const` — a literal is a single-member `enum`.
--   - `$ref` targets `#/components/schemas/NAME`, not `#/$defs/` or
--     `#/definitions/`.
--   - the example keyword is the singular `example`, not the plural `examples`
--     array JSON Schema uses.
--   - `instance` has no handler and no parent in the lattice, so it projects to
--     the empty schema. Deliberate: the `x-class-name` degradation is a
--     decision the draft 2020-12 projector makes, not this one.
--
-- The result is one SCHEMA's worth of output. Assembling a whole OAS document
-- (paths, operations, responses) around it is a caller's job — `lib/openapi`
-- is the consumer side of that document, and `type_ref_document_to_openapi_30`
-- below produces the `components.schemas` map to merge into it.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: OpenApi30Schema = { [string]: unknown }

-- The recursive projector, threaded into each converter as its first argument
-- rather than closed over — see type_ref_json_schema.lua for why.
--:: OpenApi30Project = (ref: TypeRef) -> OpenApi30Schema

--:: OpenApi30Converter = (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema

-- What `type_ref_document_to_openapi_30` returns: the root schema plus the
-- component map its `$ref`s resolve against.
--:: OpenApi30Components = { schema: OpenApi30Schema, components: { schemas: { [string]: unknown } } }

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A shallow copy of `schema` with `key` set. Copy, not mutation: the `leaf`
-- converters return a SHARED constant table on every call.
--: (schema: OpenApi30Schema, key: string, value: unknown) -> OpenApi30Schema
local function assign(schema, key, value)
	local out = {} --: OpenApi30Schema
	for k, v in pairs(schema) do out[k] = v end
	out[key] = value
	return out
end

--: (schema: OpenApi30Schema) -> OpenApi30Converter
local function leaf(schema)
	--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
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

-- ── Meta ─────────────────────────────────────────────────────────────────────

-- `minimum`/`maximum` are NOT here: they interact with exclusiveMinimum/
-- exclusiveMaximum and are handled explicitly in `with_meta`. Held as a LIST,
-- not a set, so the emitted key order is fixed rather than `pairs()`-dependent.
local passthrough_keys = {
	"minLength",
	"maxLength",
	"pattern",
	"multipleOf",
	"$comment",
} --[[: string[] ]]

--: (schema: OpenApi30Schema, meta: Meta) -> OpenApi30Schema
local function with_meta(schema, meta)
	local result = schema

	-- OAS 3.0.3 §4.8.24/§4.8.24.1: `nullable: true`, since a draft-05-based
	-- vocabulary has no type-array nullable.
	if meta.nullable == true then result = assign(result, "nullable", true) end

	if type(meta.description) == "string" then result = assign(result, "description", meta.description) end
	if meta.deprecated == true then result = assign(result, "deprecated", true) end
	-- A JSON null default/example is the shared `lib.null` sentinel, not Lua
	-- `nil`, so it survives these presence tests.
	if meta.default ~= nil then result = assign(result, "default", meta.default) end
	if meta.example ~= nil then result = assign(result, "example", meta.example) end
	-- OAS 3.0.3 §4.8.24.2: readOnly/writeOnly are booleans, mutually exclusive
	-- by spec ("a property MUST NOT be marked as both readOnly and writeOnly
	-- being true") — passed through as-authored, not cross-validated here.
	if meta.readOnly == true then result = assign(result, "readOnly", true) end
	if meta.writeOnly == true then result = assign(result, "writeOnly", true) end

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

--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
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
			-- OAS 3.0.3 §4.8.24.2: `readOnly` is a per-schema annotation, driven
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

--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_array(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element) }
end

-- OAS 3.0.3 §4.8.24 has no `prefixItems` — tuples use `items` as an array.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_tuple(project, shape, _meta)
	local s = shape --[[: { elements: TypeRef[], ... }]]
	local items = {} --: unknown[]
	for i = 1, #s.elements do items[i] = project(s.elements[i]) end
	return { type = "array", items = items }
end

--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_map(project, shape, _meta)
	local s = shape --[[: { value: TypeRef, ... }]]
	return { type = "object", additionalProperties = project(s.value) }
end

-- OAS 3.0 has no streaming/async-sequence vocabulary — degrade to the same
-- array-of-element shape used for a materialized sequence, carrying
-- `x-stream: true` (§4.7.26 Specification Extensions) so tooling that cares can
-- still tell a stream apart from an ordinary array.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_stream(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element), ["x-stream"] = true }
end

-- Same degrade — OAS 3.0 has no pagination vocabulary either — carrying
-- `x-page-style` instead of `x-stream`.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_page(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, style: string, ... }]]
	return { type = "array", items = project(s.element), ["x-page-style"] = s.style }
end

-- OAS 3.0.3 §4.8.25 Discriminator Object: `discriminator.propertyName` names
-- the field OAS-aware tooling reads to pick the matching variant without
-- trying each `oneOf` member — a NATIVE feature here, unlike in the JSON
-- Schema projectors where it is a borrowed extension. `oneOf` (not `anyOf`) is
-- used once a discriminator is present, since the variants are then mutually
-- exclusive by construction.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_union(project, shape, meta)
	local s = shape --[[: { variants: TypeRef[], ... }]]
	local variants = {} --: unknown[]
	for i = 1, #s.variants do variants[i] = project(s.variants[i]) end
	if type(meta.discriminator) == "string" then
		return { oneOf = variants, discriminator = { propertyName = meta.discriminator } }
	end
	return { anyOf = variants }
end

-- OAS 3.0.3 has no `const` (a 2020-12 addition) — a single-value `enum` is the
-- equivalent. A null literal carries the shared `lib.null` sentinel, never Lua
-- `nil`, so the member is always actually present.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_literal(_project, shape, _meta)
	local s = shape --[[: { value: unknown, ... }]]
	return { enum = { s.value } }
end

-- Unlike the JSON Schema projectors, this one does NOT infer the member type:
-- the TS source emits `type: "string"` unconditionally for OAS 3.0, and
-- type_ref.lua's `EnumShape` declares `members: string[]`.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_enum(_project, shape, _meta)
	local s = shape --[[: { members: unknown[], ... }]]
	return { type = "string", enum = copy_list(s.members) }
end

-- OAS 3.0.3 §4.8.24.2: components live under `#/components/schemas/`.
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
local function convert_ref(_project, shape, _meta)
	local s = shape --[[: { target: string, ... }]]
	return { ["$ref"] = "#/components/schemas/" .. s.target }
end

-- OAS 3.0.3 §4.8.24 inherits JSON Schema's `allOf` — the faithful encoding of
-- a structural intersection (mixin composition).
--: (project: OpenApi30Project, shape: TypeShape, meta: Meta) -> OpenApi30Schema
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
	-- No `duration` format in the OAS Data Types table — a plain string.
	duration = leaf({ type = "string" }),
	bytes = leaf({ type = "string", format = "byte" }),
	-- OAS 3.0.3 §4.8.24.1: `nullable` is the substitute for a "null" type,
	-- which draft-05-based OAS schemas do not have.
	null = leaf({ nullable = true }),
	void = leaf({ nullable = true }),
	unknown = leaf({}),
	never = leaf({ ["not"] = {} }),
	object = convert_object,
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
	-- OAS 3.0 has no callable-type concept — same vendor-extension degradation
	-- the JSON Schema projectors use.
	["function"] = leaf({ ["x-function"] = true }),
	-- Same degrade, distinguished by `x-method: true`.
	method = leaf({ ["x-method"] = true }),
	-- No service/interface-with-methods concept either.
	interface = leaf({ type = "object", ["x-interface"] = true }),
} --[[: { [string]: OpenApi30Converter }]]

-- ── Entry points ─────────────────────────────────────────────────────────────

-- Project one TypeRef. A kind with no handler and no handled ancestor projects
-- to the empty schema (plus whatever `meta` contributes), which constrains
-- nothing — the honest reading of "OAS 3.0 cannot express that kind".
--: (ref: TypeRef) -> OpenApi30Schema
function M.type_ref_to_openapi_30(ref)
	local converter = type_ref.resolve(ref.shape.kind, handlers)
	if converter == nil then return with_meta({}, ref.meta) end
	return with_meta(converter(M.type_ref_to_openapi_30, ref.shape, ref.meta), ref.meta)
end

-- Project a whole document to a schema plus the `components.schemas` map the
-- `ref` converter's `#/components/schemas/NAME` pointers resolve against.
--
-- `components.schemas` is an empty table when `doc.defs` is empty: the return
-- shape is ALWAYS `{ schema, components }`, never a bare schema, so callers
-- never branch on whether sharing was in play. Merging `components.schemas`
-- into a full OAS document's own top-level `components` is the caller's job —
-- this function produces one schema's worth.
--: (doc: TypeRefDocument) -> OpenApi30Components
function M.type_ref_document_to_openapi_30(doc)
	local schema = M.type_ref_to_openapi_30(doc.root)
	local schemas = {} --: { [string]: unknown }
	local names = ordered_keys(doc.defs)
	for i = 1, #names do
		local def = doc.defs[names[i]]
		if def ~= nil then schemas[names[i]] = M.type_ref_to_openapi_30(def) end
	end
	return { schema = schema, components = { schemas = schemas } }
end

return M
