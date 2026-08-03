-- lib/fractal/type_ref_json_schema_07.lua — project a TypeRef to JSON Schema
-- draft-07. Ported from fractal's packages/type-ir/src/json-schema-07.ts.
--
-- Divergences from draft 2020-12 (type_ref_json_schema.lua) handled here:
--
--   - tuples use `items` as an ARRAY plus `additionalItems: false`; the
--     `prefixItems` keyword is a 2020-12 rename.
--   - `$ref` targets `#/definitions/NAME`; `$defs` arrives in draft-2019-09.
--   - `never` is the BOOLEAN `false` schema — draft-06 introduced boolean
--     schemas, so draft-07 does not need 2020-12's `{ "not": {} }` spelling.
--   - no `title` in the meta pass (draft 2020-12's projector emits it; this
--     one, following the TS source, does not).
--   - `instance` and `page` have no handler, and neither kind has a parent in
--     the lattice, so both project to the empty schema. Deliberate: the
--     vendor-extension degradations for them are 2020-12-projector decisions,
--     not draft-07 ones.
--
-- BOOLEAN SCHEMAS AND THE RETURN TYPE. Because `never` projects to `false`,
-- this module's result type is `JsonSchema07 = { [string]: unknown } | boolean`
-- rather than a bare record — the reason draft-07 gets its own file instead of
-- sharing one with the other drafts (`type_ref.resolve` is generic, and its
-- handler-table type is fixed once per file). `lib/json_schema`, crescent's
-- draft-7 validator, reads boolean schemas natively (`false` rejects every
-- value), so this is the shape the consumer already expects.
--
-- WHERE THIS DEVIATES FROM THE TS SOURCE: `with_meta` returns a boolean schema
-- UNCHANGED. fractal's TS spreads meta keys onto it (`{...false, description}`),
-- which silently discards the `false` and yields a schema accepting every
-- value — the exact opposite of `never`. Lua cannot reproduce that at all
-- (indexing a boolean raises), and reproducing it would be reproducing a bug,
-- so `never` keeps its meaning and any meta on it is dropped. For an empty
-- `meta` — the normal case for `never` — the two are identical.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local type_ref = require("lib.fractal.type_ref")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────────

--:: JsonSchema07Record = { [string]: unknown }

-- A draft-07 schema is either a record of keywords or a boolean schema
-- (`true` accepts every instance, `false` accepts none).
--:: JsonSchema07 = JsonSchema07Record | boolean

-- The recursive projector, threaded into each converter as its first argument
-- rather than closed over — see type_ref_json_schema.lua for why.
--:: JsonSchema07Project = (ref: TypeRef) -> JsonSchema07

--:: JsonSchema07Converter = (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07

-- ── Helpers ──────────────────────────────────────────────────────────────────

-- A shallow copy of `schema` with `key` set. Copy, not mutation: the `leaf`
-- converters return a SHARED constant table on every call.
--: (schema: JsonSchema07Record, key: string, value: unknown) -> JsonSchema07Record
local function assign(schema, key, value)
	local out = {} --: JsonSchema07Record
	for k, v in pairs(schema) do out[k] = v end
	out[key] = value
	return out
end

--: (schema: JsonSchema07) -> JsonSchema07Converter
local function leaf(schema)
	--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
	return function(_project, _shape, _meta)
		return schema
	end
end

-- True when `v` is a non-empty Lua list — the stand-in for `Array.isArray`,
-- used to decide whether `meta.examples` is the array draft-07 §10.4 requires.
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
--: (members: unknown[]) -> JsonSchema07Record
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

-- Held as a LIST, not a set, so the emitted key order is fixed rather than
-- `pairs()`-dependent.
local passthrough_keys = {
	"minimum",
	"maximum",
	-- draft-07 §6.2/§6.3: exclusiveMinimum/exclusiveMaximum are NUMBERS (since
	-- draft-06 — draft-04's boolean-modifier form lives in
	-- type_ref_json_schema_04.lua).
	"exclusiveMinimum",
	"exclusiveMaximum",
	"minLength",
	"maxLength",
	"pattern",
	"multipleOf",
	"$comment",
	-- draft-07 §10: readOnly/writeOnly are draft-07 additions; examples arrives
	-- in draft-06.
	"readOnly",
	"writeOnly",
} --[[: string[] ]]

--: (schema: JsonSchema07, meta: Meta, complex: boolean) -> JsonSchema07
local function with_meta(schema, meta, complex)
	-- A boolean schema carries no keywords to decorate. See the header note.
	if type(schema) ~= "boolean" then
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

		if type(meta.description) == "string" then result = assign(result, "description", meta.description) end
		if meta.deprecated == true then result = assign(result, "deprecated", true) end
		-- A JSON null default is the shared `lib.null` sentinel, not Lua `nil`,
		-- so it survives this presence test.
		if meta.default ~= nil then result = assign(result, "default", meta.default) end
		-- draft-07 §10.4: "examples" is an ARRAY of example values, distinct
		-- from OAS's singular "example".
		if is_list(meta.examples) then result = assign(result, "examples", meta.examples) end

		for i = 1, #passthrough_keys do
			local key = passthrough_keys[i]
			if meta[key] ~= nil then result = assign(result, key, meta[key]) end
		end

		return result
	end
	return schema
end

-- ── Converters ───────────────────────────────────────────────────────────────

--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
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
			-- draft-07 §10: `readOnly` is a per-schema annotation, driven by the
			-- `meta.readonly` open-metadata-bag convention set on the FIELD's own
			-- TypeRef. A boolean-schema property (a `never` field) has no
			-- keywords to annotate and is left as-is.
			if field.meta.readonly == true and type(prop) ~= "boolean" then
				prop = assign(prop, "readOnly", true)
			end
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

--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_array(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element) }
end

-- draft-07: `items` as an array of schemas positionally validates a
-- tuple; `additionalItems: false` forbids extra elements.
--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_tuple(project, shape, _meta)
	local s = shape --[[: { elements: TypeRef[], ... }]]
	local items = {} --: unknown[]
	for i = 1, #s.elements do items[i] = project(s.elements[i]) end
	return { type = "array", items = items, additionalItems = false }
end

--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_map(project, shape, _meta)
	local s = shape --[[: { value: TypeRef, ... }]]
	return { type = "object", additionalProperties = project(s.value) }
end

-- draft-07 has no streaming/async-sequence vocabulary — degrade to the same
-- array-of-element shape used for a materialized sequence, carrying
-- `x-stream: true`.
--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_stream(project, shape, _meta)
	local s = shape --[[: { element: TypeRef, ... }]]
	return { type = "array", items = project(s.element), ["x-stream"] = true }
end

-- draft-07 §9.2.1.3 defines `oneOf` (exactly one variant matches) but no
-- `discriminator` keyword; the OpenAPI-originated `discriminator:
-- { propertyName }` shape is a widely-recognized extension, carried by
-- `meta.discriminator`. Plain unions keep `anyOf`.
--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
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
-- `const` is always actually set.
--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_literal(_project, shape, _meta)
	local s = shape --[[: { value: unknown, ... }]]
	return { const = s.value }
end

--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_enum(_project, shape, _meta)
	local s = shape --[[: { members: unknown[], ... }]]
	return enum_schema(s.members)
end

--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
local function convert_ref(_project, shape, _meta)
	local s = shape --[[: { target: string, ... }]]
	return { ["$ref"] = "#/definitions/" .. s.target }
end

-- draft-07 §9.2.1.1 `allOf`: every listed schema must validate — the faithful
-- encoding of a structural intersection (mixin composition).
--: (project: JsonSchema07Project, shape: TypeShape, meta: Meta) -> JsonSchema07
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
	-- draft-06 introduced boolean schemas, so `never` is simply `false`.
	never = leaf(false),
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
	-- draft-07 has no callable-type vocabulary — degrade honestly to an untyped
	-- schema carrying `x-function: true`.
	["function"] = leaf({ ["x-function"] = true }),
	-- Same degrade, carrying `x-method: true` so a callable belonging to a
	-- type's contract stays distinguishable from a standalone one.
	method = leaf({ ["x-method"] = true }),
	-- No service/interface-with-methods vocabulary either.
	interface = leaf({ type = "object", ["x-interface"] = true }),
} --[[: { [string]: JsonSchema07Converter }]]

-- Kinds whose schema cannot absorb a `"null"` entry in its `type` keyword, so
-- nullability must wrap them in `anyOf` instead.
local complex_kinds = {
	object = true,
	array = true,
	stream = true,
	tuple = true,
	map = true,
	union = true,
	intersection = true,
	["function"] = true,
	method = true,
	interface = true,
} --[[: { [string]: boolean } ]]

-- ── Entry point ──────────────────────────────────────────────────────────────

-- Project one TypeRef. A kind with no handler and no handled ancestor projects
-- to the empty schema (plus whatever `meta` contributes), which constrains
-- nothing — the honest reading of "this draft cannot express that kind".
--
-- No document-level entry point here: fractal's draft-07 projector has none.
-- The `#/definitions/NAME` pointers the `ref` converter emits are resolved
-- against whatever `definitions` map the caller assembles (see
-- `type_ref_to_json_schema_04_document` in type_ref_json_schema_04.lua for the
-- draft-04 shape of that assembly).
--: (ref: TypeRef) -> JsonSchema07
function M.type_ref_to_json_schema_07(ref)
	local kind = ref.shape.kind
	local complex = complex_kinds[kind] == true
	local converter = type_ref.resolve(kind, handlers)
	if converter == nil then return with_meta({}, ref.meta, complex) end
	return with_meta(converter(M.type_ref_to_json_schema_07, ref.shape, ref.meta), ref.meta, complex)
end

return M
