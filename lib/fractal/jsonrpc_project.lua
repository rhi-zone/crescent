-- lib/fractal/jsonrpc_project.lua — JSON-RPC 2.0 method projection, ported
-- from fractal's packages/json-rpc-api-projector/src/project.ts.
--
-- Walks a Node tree (lib/fractal/init.lua) and produces a flat list of method
-- descriptors — one per leaf — plus the name -> handler dispatch table
-- jsonrpc_server.lua resolves calls through. One walk, one source of truth for
-- name construction, so a descriptor and the dispatch entry behind it can
-- never disagree about what a method is called.
--
-- NAMING. DOT-separated method names from tree position — `users.list`,
-- `books.get` — not MCP's underscore-joined names. A `fallback`
-- (wildcard-capture) node contributes its OWN name (e.g. "bookId") as a
-- literal dot-segment: the segment names the TREE POSITION, not a captured
-- runtime value (there is no URL to capture a value FROM at list time). The
-- actual argument travels through `params` like any other field and is
-- resolved at call time by the ordinary `assemble` pipeline against the single
-- `"params"` store — see jsonrpc_server.lua's dispatch.
--
--   root leaf "ping"                    -> "ping"
--   child "users" / leaf "list"         -> "users.list"
--   fallback "bookId" / leaf "get"      -> "books.bookId.get"
--   meta.jsonrpc.name on a leaf         -> full override (prefix ignored)
--   meta.jsonrpc.segment on a branch    -> that node's contribution to the prefix
--
-- TAGS -> METADATA. `readOnly`/`destructive`/`idempotent`/`streaming`/
-- `deprecated` are surfaced as three-valued top-level fields on the
-- descriptor, omitted when unknown (tags.lua's three-valued convention), not
-- nested under an MCP-style `annotations` bag — JSON-RPC has no
-- ToolAnnotations-shaped convention to mirror. A leaf's tags are read from its
-- OWN `meta.tags`; there is no ancestor inheritance (see tags.lua's note on
-- why inheritance-by-position is not a thing).
--
-- SCHEMAS. `paramsSchema`/`resultSchema`/`description` come from a
-- derived-from-type `SchemaMap` keyed by the DOT-joined method name, handed in
-- by the caller (codegen's job, exactly as on the TypeScript side — nothing
-- here reads a TypeRef). Absent an entry, `paramsSchema` degrades to
-- `{ type = "object" }` (JSON Schema's "any object", the spec minimum) and
-- `resultSchema` is omitted entirely — unlike MCP, JSON-RPC mandates no
-- minimum result shape. `errorSchema` is the fixed JSON-RPC 2.0 envelope from
-- type_ref_json_rpc.lua, optionally narrowed by `meta.jsonrpc.errorDataSchema`.
--
-- FIELD NAMES. The descriptor's keys are camelCase (`paramsSchema`, not
-- `params_schema`) for the same reason page.lua's are: these values are
-- JSON-serialized into a method listing and read on the far side of the wire
-- against the TypeScript projector's own output, so the names are part of the
-- cross-language contract. The same goes for the `meta.jsonrpc` keys an author
-- writes (`name`, `segment`, `errorDataSchema`, `sourceMap`) — a meta bag is
-- authored once and read by every projector, in either language. The internal
-- `Dispatch` record, which never leaves this process, is snake_case.
--
-- CHILD ORDER. Children are walked in sorted key order, not the insertion
-- order fractal emits — Lua has no insertion order to recover. Same call, same
-- reason, as `ordered_keys` in type_ref.lua; the SET of methods produced is
-- identical, only the array order of `methods` differs. `handlers` is keyed by
-- name and so is unaffected.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local tags_mod = require("lib.fractal.tags")
local codes    = require("lib.fractal.type_ref_json_rpc")

local M = {}

-- ── Types ────────────────────────────────────────────────────────────────

-- JSON Schema as an open bag — same convention every other module in this
-- port uses for one.
--:: JsonSchema = { [string]: unknown }

-- A minimal structural view of a Node, declared here rather than imported for
-- the same reason tags.lua and direct.lua each declare their own: cross-module
-- named types are not yet supported.
--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown } }

-- Param name -> source override, the shape input.lua's `assemble` consumes.
--:: ParamSource = { store: string, key?: string }
--:: SourceMap = { [string]: ParamSource }

-- One method's full JSON-RPC descriptor — one per leaf node.
-- The optional fields are declared `X | nil` rather than `field?: X` so every
-- one of them can be named in the table constructor (LuaJIT shapes a table at
-- construction; see docs/lua-gotchas.md). The two readings are the same at
-- runtime — a field holding nil IS an absent field in Lua — so the
-- three-valued convention is unaffected.
--:: JsonRpcMethod = { name: string, description: string, paramsSchema: JsonSchema, resultSchema: JsonSchema | nil, errorSchema: JsonSchema, readOnly: boolean | nil, destructive: boolean | nil, idempotent: boolean | nil, streaming: boolean | nil, deprecated: boolean | nil }

-- Derived-from-type facts for one method, keyed by its dot-joined name.
--:: MethodSchema = { paramsSchema?: JsonSchema, resultSchema?: JsonSchema, description?: string }
--:: SchemaMap = { [string]: MethodSchema }

-- A dispatch entry: the leaf's handler, its `meta.jsonrpc.sourceMap` (empty
-- when the leaf declares no overrides), and its own meta bag.
--:: Dispatch = { handler: (input: unknown) -> unknown, source_map: SourceMap, meta: { [string]: unknown } }

-- `schemas` is declared `SchemaMap | nil` rather than optional so a caller
-- forwarding a possibly-absent map (`{ schemas = opts.schemas }`) can name the
-- field unconditionally, the way jsonrpc_server.lua does.
--:: ProjectOptions = { schemas: SchemaMap | nil }
--:: ProjectResult = { methods: { [integer]: JsonRpcMethod }, handlers: { [string]: Dispatch } }

-- ── meta.jsonrpc open bag ────────────────────────────────────────────────

-- The per-projection override bag, split by role exactly as the TS source
-- splits `JsonRpcLeafMetaProperties` from `JsonRpcBranchMetaProperties` — no
-- key is valid at both positions, so one open reading covers both:
--
--   leaf   — name, description, errorDataSchema, sourceMap
--   branch — segment
--
-- The TS source's two wrapper types exist to make a misplaced key a compile
-- error at the `op()`/`api()` call site; that is declaration-level machinery
-- with no runtime behavior, so there is nothing to port beyond this reader.
--:: JsonRpcOverrides = { [string]: unknown }

-- Extract `meta.jsonrpc`, or an empty bag when absent or not a table.
--: (meta: { [string]: unknown }) -> JsonRpcOverrides
function M.overrides_from_meta(meta)
	local j = meta.jsonrpc
	if type(j) ~= "table" then return {} end
	return j --[[: JsonRpcOverrides]]
end

-- ── Tag -> metadata ──────────────────────────────────────────────────────

-- The three-valued readOnly/destructive/idempotent/streaming/deprecated fields
-- for a descriptor, derived from the leaf's OWN `meta.tags`. A key whose
-- resolved value is unknown is left off entirely — in Lua that is automatic,
-- since assigning nil is not assigning at all, which is the same three-valued
-- reading tags.lua documents.
--: (dst: JsonRpcMethod, tags: { [string]: boolean }) -> nil
local function apply_tag_fields(dst, tags)
	local r = tags_mod.resolve_tags(tags, nil)
	dst.readOnly    = r.readOnly
	dst.destructive = r.destructive
	dst.idempotent  = r.idempotent
	dst.streaming   = r.streaming
	dst.deprecated  = r.deprecated
end

-- The leaf's `meta.tags`, or an empty bag.
--: (meta: { [string]: unknown }) -> { [string]: boolean }
local function tags_from_meta(meta)
	local t = meta.tags
	if type(t) ~= "table" then return {} end
	return t --[[: { [string]: boolean }]]
end

-- ── Tree walk ────────────────────────────────────────────────────────────

-- Sorted string keys of `t`. See the module doc's CHILD ORDER note.
--: (t: { [string]: NodeView }) -> { [integer]: string }
local function ordered_keys(t)
	local out = {}
	local n = 0
	for k in pairs(t) do
		n = n + 1
		out[n] = k
	end
	table.sort(out)
	return out
end

-- Narrowing predicate, so a `meta` override read off an open bag (typed
-- `unknown`) can be used as a string without a cast at each site.
--: (v: unknown) -> v is string
local function is_string(v)
	return type(v) == "string"
end

--: (node: NodeView) -> boolean
local function is_leaf(node)
	return node.handler ~= nil
end

-- Build one descriptor and register its dispatch entry, for a leaf at a
-- fully-resolved `name`. Factored out so the SAME construction serves an
-- ordinary child leaf (name = prefix + its tree key) and a `fallback.subtree`
-- that is itself a bare leaf (name = prefix + the fallback's own name, no
-- further key). `description_fallback` is the last-resort description text.
--: (child: NodeView, name: string, description_fallback: string, schemas: SchemaMap, handlers: { [string]: Dispatch }) -> JsonRpcMethod
local function build_method(child, name, description_fallback, schemas, handlers)
	local jr = M.overrides_from_meta(child.meta)

	local jr_name = jr.name
	local resolved_name = name
	if is_string(jr_name) then resolved_name = jr_name end

	local derived = schemas[resolved_name]

	local jr_description = jr.description
	local meta_description = child.meta.description

	local description = description_fallback
	if is_string(jr_description) then
		description = jr_description
	elseif is_string(meta_description) then
		description = meta_description
	elseif derived ~= nil then
		local derived_description = derived.description
		if derived_description ~= nil then description = derived_description end
	end

	local error_data_schema = jr.errorDataSchema
	local narrowed_data = nil --: JsonSchema | nil
	if type(error_data_schema) == "table" then
		narrowed_data = error_data_schema --[[: JsonSchema]]
	end

	local source_map = {} --: SourceMap
	local jr_source_map = jr.sourceMap
	if type(jr_source_map) == "table" then
		source_map = jr_source_map --[[: SourceMap]]
	end

	local handler = child.handler
	if handler == nil then
		error("fractal.jsonrpc_project: build_method called on a node with no handler")
	end
	handlers[resolved_name] = { handler = handler, source_map = source_map, meta = child.meta }

	local params_schema = { type = "object" } --: JsonSchema
	local result_schema = nil --: JsonSchema | nil
	if derived ~= nil then
		local derived_params = derived.paramsSchema
		if derived_params ~= nil then params_schema = derived_params end
		result_schema = derived.resultSchema
	end

	local method = {
		name = resolved_name,
		description = description,
		paramsSchema = params_schema,
		resultSchema = result_schema,
		errorSchema = codes.error_schema_from_data_schema(narrowed_data),
		readOnly = nil,
		destructive = nil,
		idempotent = nil,
		streaming = nil,
		deprecated = nil,
	} --: JsonRpcMethod

	apply_tag_fields(method, tags_from_meta(child.meta))
	return method
end

-- The recursive walk. `out` accumulates descriptors in visit order.
--: (node: NodeView, prefix: string, schemas: SchemaMap, handlers: { [string]: Dispatch }, out: { [integer]: JsonRpcMethod }) -> nil
local function walk(node, prefix, schemas, handlers, out)
	local children = node.children
	if children ~= nil then
		local keys = ordered_keys(children)
		for i = 1, #keys do
			local key = keys[i]
			local child = children[key]
			if is_leaf(child) then
				local name = key
				if #prefix > 0 then name = prefix .. "." .. key end
				out[#out + 1] = build_method(child, name, key, schemas, handlers)
			else
				local child_jr = M.overrides_from_meta(child.meta)
				local child_segment = child_jr.segment
				local raw_seg = key
				if is_string(child_segment) then raw_seg = child_segment end
				local seg = raw_seg
				if #prefix > 0 then seg = prefix .. "." .. raw_seg end
				walk(child, seg, schemas, handlers, out)
			end
		end
	end

	local fallback = node.fallback
	if fallback ~= nil then
		local seg = fallback.name
		if #prefix > 0 then seg = prefix .. "." .. fallback.name end

		-- A `fallback.subtree` may be a bare leaf (`op()`), not only a branch
		-- (`api({...})`). Walking it as a branch would see no children and omit
		-- it entirely, so when the subtree IS the leaf its method is built
		-- directly at `seg` — no extra segment beyond the fallback's own name.
		if is_leaf(fallback.subtree) then
			out[#out + 1] = build_method(fallback.subtree, seg, fallback.name, schemas, handlers)
		else
			walk(fallback.subtree, seg, schemas, handlers, out)
		end
	end
end

-- Walk a Node tree and produce both the flat descriptor list and the
-- name -> dispatch table. See the module doc for name construction.
--: (tree: NodeView, opts: ProjectOptions | nil) -> ProjectResult
function M.project_methods(tree, opts)
	local schemas = (opts ~= nil and opts.schemas) or {}
	local handlers = {} --: { [string]: Dispatch }
	local methods = {} --: { [integer]: JsonRpcMethod }
	walk(tree, "", schemas, handlers, methods)
	return { methods = methods, handlers = handlers }
end

-- Walk a Node tree and produce only the descriptor list — `project_methods`
-- without the dispatch table, for a caller that is publishing a method listing
-- rather than serving calls.
--: (tree: NodeView, opts: ProjectOptions | nil) -> { [integer]: JsonRpcMethod }
function M.methods_from_tree(tree, opts)
	return M.project_methods(tree, opts).methods
end

return M
