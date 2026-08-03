-- lib/fractal/type_ref.lua — the TypeRef data model, ported from fractal's
-- packages/type-ir/src/index.ts.
--
-- Two pieces live here, the same two that live in the TS file:
--
--   1. The kind lattice — a single-parent map from kind name to parent kind
--      name. `ancestors(kind)` walks that chain; `resolve(kind, handlers)`
--      looks up a handler by kind, falling back through ancestors
--      nearest-first. This is how a projector that has no `method` handler
--      automatically gets its `function` handler.
--   2. The TypeRef data model itself — `types.*` shape constructors,
--      `type_ref_from_shape` to wrap a shape into a TypeRef, documents
--      (root + named defs), and the generic traversal (`child_type_refs`,
--      `walk_type_ref`, `node_count`).
--
-- A TypeRef is `{ shape = <TypeShape>, meta = <Meta> }`. The shape carries
-- the structure; `meta` is an open bag of conventions read by consumers, not
-- a fixed schema (see the TS file's comment block for the recognized keys:
-- `optional`, `nullable`, `readonly`, `typeName`/`declarationFile`,
-- `additionalProperties`, `additionalPropertyType`).
--
-- NOT ported here: the projection/serialization matrix, which lives in
-- separate modules exactly as it does in the TS package. Ported so far:
-- `type_ref_json_schema.lua` (draft 2020-12), `type_ref_json_schema_07.lua`,
-- `type_ref_json_schema_04.lua`, `type_ref_openapi_30.lua` and
-- `type_ref_openapi_20.lua`. Still unported: SQL DDL and the other ~20
-- projectors, and `derive.ts`'s partial/required/pick/omit helpers.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local null = require("lib.null")

local M = {}

-- The shared null sentinel, re-exported for callers that construct or
-- inspect a null `literal` (see `types.literal`). This is the SAME table as
-- `require("lib.null").null` — identity is the test, so re-exporting the
-- module's table rather than a fresh one is load-bearing.
M.null = null.null

-- ── Types ────────────────────────────────────────────────────────────────────

--:: Meta = { [string]: unknown }

-- A shape is any record carrying a string `kind`. Deliberately open rather
-- than a closed union of the kinds below: the TS interface is extended by
-- declaration merging (src/kinds/* register semantic refinements like
-- int32/uuid/datetime), so a shape whose kind this file has never heard of
-- is a legitimate, expected input — `child_type_refs` walks it generically.
--:: TypeShape = { kind: string, ... }

--:: TypeRef = { shape: TypeShape, meta: Meta }

-- One entry in a `function`/`method` parameter list.
--:: Param = { name: string, type: TypeRef }

-- The built-in kinds' concrete shapes. Each is a subtype of `TypeShape`
-- (a literal `kind` is a `string`, and `...` admits the payload fields), so
-- every one of these can be handed to `type_ref_from_shape` and walked by
-- `child_type_refs`. Spelled out rather than collapsed into `TypeShape`
-- because a caller reading `shape.fields` off an `object` should not have to
-- cast to get at it.
--:: ObjectShape = { kind: "object", fields: { [string]: TypeRef } }
--:: InstanceShape = { kind: "instance", className: string, declarationFile: string }
--:: ArrayShape = { kind: "array", element: TypeRef }
--:: StreamShape = { kind: "stream", element: TypeRef }
--:: PageShape = { kind: "page", element: TypeRef, style: string }
--:: TupleShape = { kind: "tuple", elements: TypeRef[] }
--:: MapShape = { kind: "map", key: TypeRef, value: TypeRef }
--:: UnionShape = { kind: "union", variants: TypeRef[] }
--:: LiteralShape = { kind: "literal", value: unknown }
--:: EnumShape = { kind: "enum", members: string[] }
--:: RefShape = { kind: "ref", target: string }
--:: IntersectionShape = { kind: "intersection", members: TypeRef[] }
--:: FunctionShape = { kind: "function", params: Param[], returnType: TypeRef, thisType?: TypeRef }
--:: MethodShape = { kind: "method", params: Param[], returnType: TypeRef, thisType?: TypeRef }
--:: InterfaceShape = { kind: "interface", methods: { [string]: TypeRef } }

-- Wrap a shape into a TypeRef. `meta` defaults to an empty bag.
-- (fractal's `t()` — renamed here because a one-letter name predicts
-- nothing about its signature.)
--: (TypeShape, Meta | nil) -> TypeRef
function M.type_ref_from_shape(shape, meta)
	return { shape = shape, meta = meta or {} }
end

-- The shape constructors. Kinds with no payload are shared constant tables
-- (matching the TS `as const` singletons, which are likewise shared, not
-- freshly allocated per use); kinds with a payload are functions.
--
-- Never mutate a constant shape — every TypeRef built from it would see the
-- change. The TS side guards this with `readonly`; Lua cannot, so it is a
-- convention here.
--
-- `literal` accepts a string, number, boolean, or the null sentinel
-- (`M.null` / `require("lib.null").null`). Lua has no value distinct from
-- absence, so a null literal CANNOT be written as `literal(nil)` — that
-- would produce a shape whose `value` key is simply missing, indistinguishable
-- from a malformed literal. Callers test for it with `shape.value == M.null`,
-- the same identity test the JSON codecs use.
M.types = {
	boolean = { kind = "boolean" },
	number = { kind = "number" },
	integer = { kind = "integer" },
	string = { kind = "string" },
	null = { kind = "null" },
	void = { kind = "void" },
	unknown = { kind = "unknown" },
	never = { kind = "never" },

	--: ({ [string]: TypeRef }) -> ObjectShape
	object = function(fields)
		return { kind = "object", fields = fields }
	end,

	-- A class instance — purely nominal, carrying only class identity, never
	-- structure. Deliberately NOT a subtype of `object`: a class's fields are
	-- only half its surface (methods are the other half), so exposing
	-- `fields` here would misrepresent the type as plain data.
	--: (string, string) -> InstanceShape
	instance = function(class_name, declaration_file)
		return { kind = "instance", className = class_name, declarationFile = declaration_file }
	end,

	--: (TypeRef) -> ArrayShape
	array = function(element)
		return { kind = "array", element = element }
	end,

	-- An asynchronously-produced sequence of values. Deliberately NOT a
	-- subtype of `array`: an array is materialized and synchronously
	-- indexable, a stream is an ongoing production over time.
	--: (TypeRef) -> StreamShape
	stream = function(element)
		return { kind = "stream", element = element }
	end,

	-- A paginated collection — one WINDOW over a larger, not-yet-fetched
	-- collection, so also NOT a subtype of `array`. `style` is "cursor" or
	-- "offset".
	--: (TypeRef, string) -> PageShape
	page = function(element, style)
		return { kind = "page", element = element, style = style }
	end,

	--: (TypeRef[]) -> TupleShape
	tuple = function(elements)
		return { kind = "tuple", elements = elements }
	end,

	--: (TypeRef, TypeRef) -> MapShape
	map = function(key, value)
		return { kind = "map", key = key, value = value }
	end,

	--: (TypeRef[]) -> UnionShape
	union = function(variants)
		return { kind = "union", variants = variants }
	end,

	-- `value` is a string, number, boolean, or the null sentinel. See the
	-- block comment above.
	--: (unknown) -> LiteralShape
	literal = function(value)
		return { kind = "literal", value = value }
	end,

	-- A closed set of string members with no payload. Numeric and mixed
	-- enums do not fit this kind and lower to a `union` of `literal`.
	--: (string[]) -> EnumShape
	enum = function(members)
		return { kind = "enum", members = members }
	end,

	-- A named reference, resolved against a document's `defs`. `target` is a
	-- plain name, not a TypeRef, so refs contribute no structural children —
	-- which is what keeps `walk_type_ref` from cycling.
	--: (string) -> RefShape
	ref = function(target)
		return { kind = "ref", target = target }
	end,

	--: (TypeRef[]) -> IntersectionShape
	intersection = function(members)
		return { kind = "intersection", members = members }
	end,

	-- A callable type. `this_type` is present for class methods and other
	-- functions with an explicit/implicit `this`, absent for free functions
	-- — and absent means the key is genuinely not set, matching the TS
	-- constructor's two branches.
	--
	-- Named `function_` because `function` is a Lua keyword and cannot be a
	-- table-literal key; every other kind keeps its fractal name.
	--: (Param[], TypeRef, TypeRef | nil) -> FunctionShape
	function_ = function(params, return_type, this_type)
		if this_type == nil then
			return { kind = "function", params = params, returnType = return_type }
		end
		return { kind = "function", params = params, returnType = return_type, thisType = this_type }
	end,

	-- A callable belonging to a type's contract. Same fields as `function`
	-- because a method IS a callable; the kind lattice below registers
	-- `method`'s parent as `function` so a projector with no `method`
	-- handler falls back to its `function` one.
	--: (Param[], TypeRef, TypeRef | nil) -> MethodShape
	method = function(params, return_type, this_type)
		if this_type == nil then
			return { kind = "method", params = params, returnType = return_type }
		end
		return { kind = "method", params = params, returnType = return_type, thisType = this_type }
	end,

	-- A type that carries methods — Protobuf's `service`, Cap'n Proto's
	-- `interface`. Structural, and deliberately NOT a subtype of `object`.
	--: ({ [string]: TypeRef }) -> InterfaceShape
	interface = function(methods)
		return { kind = "interface", methods = methods }
	end,
}

-- ── Kind lattice ─────────────────────────────────────────────────────────────

--:: ParentMap = { [string]: string | nil }

-- Seeded with the two built-in subtype relationships from the TS source.
-- Every other built-in kind is a root; in particular `instance`, `stream`,
-- `page` and `interface` deliberately have NO parent, so a projector that
-- cannot express them has nothing to silently fall back to and must degrade
-- explicitly (see the per-kind comments above).
local parents = {
	integer = "number",
	method = "function",
} --[[: ParentMap]]

-- Register (or overwrite) `kind`'s parent. Pass `nil` (or omit) to make
-- `kind` a root — a root has no ancestors.
--: (string, string | nil) -> nil
function M.register_parent(kind, parent)
	if parent == nil then
		parents[kind] = nil
	else
		parents[kind] = parent
	end
end

-- The chain of ancestor kind names for `kind`, nearest first, NOT including
-- `kind` itself. Stops at the first kind with no registered parent (a
-- root). Returns an empty list when `kind` itself has no registered parent.
--: (string) -> string[]
function M.ancestors(kind)
	local chain = {}
	local n = 0
	local current = parents[kind]
	while current ~= nil do
		n = n + 1
		chain[n] = current
		current = parents[current]
	end
	return chain
end

-- Look up a handler for `kind` in `handlers`: exact match first, then each
-- ancestor nearest-first via `ancestors()`. Returns nil if no handler
-- matches `kind` or any ancestor up to the root.
--: <T>(string, { [string]: T }) -> T | nil
function M.resolve(kind, handlers)
	local exact = handlers[kind]
	if exact ~= nil then return exact end
	local chain = M.ancestors(kind)
	for i = 1, #chain do
		local h = handlers[chain[i]]
		if h ~= nil then return h end
	end
	return nil
end

-- ── Documents ────────────────────────────────────────────────────────────────

-- A self-contained TypeRef plus the named definitions its `ref` shapes point
-- into. A recursive type lives in `defs`, and its own body contains a `ref`
-- back to its own name.
--:: TypeRefDocument = { root: TypeRef, defs: { [string]: TypeRef } }

-- Wrap a bare TypeRef (optionally with `defs`) into a document. A TypeRef
-- with no defs is simply a document with no shared definitions.
--: (TypeRef, { [string]: TypeRef } | nil) -> TypeRefDocument
function M.type_ref_document(root, defs)
	return { root = root, defs = defs or {} }
end

-- Resolve a `ref` TypeRef against a document's `defs`. Non-ref input is
-- returned unchanged. An unresolvable target is a malformed document, so it
-- returns `(nil, errmsg)` — fractal's TS throws here, but a data error is
-- not a programming error under this repo's error convention.
--: (TypeRefDocument, TypeRef) -> (TypeRef | nil, string | nil)
function M.resolve_ref(doc, ref)
	if ref.shape.kind ~= "ref" then return ref end
	local target = (ref.shape --[[: { target: unknown, ... }]]).target
	if type(target) ~= "string" then
		return nil, "resolve_ref: ref shape has no string `target`"
	end
	local resolved = doc.defs[target]
	if resolved == nil then
		return nil, 'resolve_ref: unresolved ref target "' .. target .. '" (no such entry in defs)'
	end
	return resolved
end

-- ── Traversal ────────────────────────────────────────────────────────────────

-- Duck-type `v` as a TypeRef. Every TypeRef carries `meta` plus a `shape`
-- with a string `kind`, which no other value appearing inside a shape does
-- (plain strings, `{ name, type }` param entries, string enum members).
-- Used by `child_type_refs` to walk an arbitrary — possibly
-- extension-registered — kind's shape without a per-kind branch.
--
-- fractal's TS tests `"meta" in v` (key presence, even if undefined); Lua
-- cannot distinguish a key holding nil from an absent key, so this tests
-- `meta ~= nil`. Equivalent for every TypeRef built by
-- `type_ref_from_shape`, which always sets `meta`.
--
-- Declared as a type predicate (`v is TypeRef`) so callers get the narrowed
-- value, exactly as the TS side's `v is TypeRef` does. This is what keeps
-- `child_type_refs` cast-free: a cast could not narrow `unknown` here, and
-- rebuilding a TypeRef to satisfy the checker would hand back a COPY, which
-- would silently break the identity comparison `is_recursion_target` relies
-- on.
--: (v: unknown) -> v is TypeRef
local function is_type_ref(v)
	if type(v) ~= "table" then return false end
	local rec = v --[[: { meta: unknown, shape: unknown, ... }]]
	if rec.meta == nil then return false end
	local shape = rec.shape
	if type(shape) ~= "table" then return false end
	return type((shape --[[: { kind: unknown, ... }]]).kind) == "string"
end

-- True when `t` is array-shaped: keys exactly 1..n with n > 0. Stands in for
-- JS's `Array.isArray`, which `child_type_refs` uses to tell a LIST of
-- TypeRefs (`tuple.elements`, `function.params`) from a RECORD of them
-- (`object.fields`, `interface.methods`) — the two are walked differently
-- (a list additionally unwraps `{ name, type }` entries).
--
-- The empty table is reported as a record, but the distinction is immaterial
-- here: an empty list and an empty record both contribute zero children. A
-- local rather than a shared helper because this module is the type-ir port
-- and must not depend on the api-tree port (`lib/fractal/init.lua`) — in
-- fractal they are separate packages, with the dependency running the other
-- way.
--: ({ [unknown]: unknown }) -> boolean
local function is_array(t)
	local len = 0
	for _ in pairs(t) do len = len + 1 end
	if len == 0 then return false end
	for i = 1, len do
		if t[i] == nil then return false end
	end
	return true
end

-- A record's keys in a deterministic order (byte order).
--
-- fractal's TS iterates `Object.values(shape)`, i.e. JS property order —
-- integer-like keys ascending, then string keys in INSERTION order. Lua
-- tables have no insertion order to recover, so `pairs()` alone would make
-- child order (and therefore visit order in `walk_type_ref`) vary between
-- runs. Byte order is the deterministic stand-in, and for every built-in
-- kind it coincides exactly with the TS order, because each kind's
-- TypeRef-valued fields happen to be declared alphabetically (`function`:
-- params < returnType < thisType; `map`: key < value). An
-- extension-registered kind whose fields are declared out of alphabetical
-- order would be visited in a different order here than in TS — the visited
-- SET is identical either way.
--
-- Non-string keys are skipped: a shape, and every TypeRef-bearing record
-- inside one, is a record of NAMED fields, so no other key form is
-- well-formed. (Lists are handled separately by `child_type_refs`, which
-- indexes them by position rather than going through this function.)
--: ({ [string]: unknown }) -> string[]
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

-- The immediate TypeRef children of a shape — generic over kind, so a kind
-- registered by an extension module is walked correctly without this file
-- knowing its name. Every built-in kind's TypeRef-valued fields take one of
-- three forms: a bare TypeRef (`array.element`, `map.key`/`value`), a list
-- of TypeRef or of `{ name, type }` (`tuple.elements`, `union.variants`,
-- `function.params`), or a record of TypeRef (`object.fields`,
-- `interface.methods`).
--
-- `ref.target` is a plain string, not a TypeRef, so refs contribute no
-- children — walking root + defs can never cycle structurally.
--: (TypeShape) -> TypeRef[]
function M.child_type_refs(shape)
	local out = {}
	local n = 0
	local rec = shape --[[: { [string]: unknown }]]
	local keys = ordered_keys(rec)
	for i = 1, #keys do
		local value = rec[keys[i]]
		if is_type_ref(value) then
			n = n + 1
			out[n] = value
		elseif type(value) == "table" then
			local tbl = value --[[: { [string]: unknown }]]
			if is_array(tbl) then
				local list = value --[[: unknown[] ]]
				for j = 1, #list do
					local item = list[j]
					if is_type_ref(item) then
						n = n + 1
						out[n] = item
					elseif type(item) == "table" then
						local param = (item --[[: { type: unknown, ... }]]).type
						if is_type_ref(param) then
							n = n + 1
							out[n] = param
						end
					end
				end
			else
				local nested_keys = ordered_keys(tbl)
				for j = 1, #nested_keys do
					local nested = tbl[nested_keys[j]]
					if is_type_ref(nested) then
						n = n + 1
						out[n] = nested
					end
				end
			end
		end
	end
	return out
end

-- Count of TypeRef nodes in a subtree: the node itself plus every descendant
-- reachable without crossing a `ref`. Used by callers' share heuristics to
-- decide whether a reused type is big enough to be worth hoisting into
-- `defs` instead of inlining at every use site.
--: (TypeRef) -> integer
function M.node_count(node)
	local count = 1
	local children = M.child_type_refs(node.shape)
	for i = 1, #children do
		count = count + M.node_count(children[i])
	end
	return count
end

-- Per-node context handed to a `walk_type_ref` visitor.
--
--   ancestors           — nodes on the path from this walk's starting point
--                         down to, but not including, the current node.
--   resolve_ref         — `M.resolve_ref` bound to this walk's document.
--   is_recursion_target — true when the given node is identity-equal to one
--                         of `ancestors`, i.e. revisiting it (typically
--                         after a caller-driven `resolve_ref`) would recurse
--                         forever.
--:: WalkContext = {
--::     ancestors: TypeRef[],
--::     resolve_ref: (TypeRef) -> (TypeRef | nil, string | nil),
--::     is_recursion_target: (TypeRef) -> boolean,
--:: }

-- Depth-first pre-order walk of a document: every node reachable from
-- `root`, then every node reachable from each `defs` entry. Each def starts
-- its own `ancestors` chain from empty — a def is an independent named root,
-- not structurally nested under `root`.
--
-- The visitor's return value is not collected; the walk is for its side
-- effects, so a caller wanting a fold accumulates into a closed-over local.
--
-- `defs` are visited in byte order of their names. fractal's TS uses
-- `Object.keys` insertion order, which Lua cannot recover — see
-- `ordered_keys`. The visited SET is identical.
--: (TypeRefDocument, (TypeRef, WalkContext) -> nil) -> nil
function M.walk_type_ref(doc, visitor)
	--: (TypeRef) -> (TypeRef | nil, string | nil)
	local function bound_resolve_ref(ref)
		return M.resolve_ref(doc, ref)
	end

	--: (TypeRef, TypeRef[]) -> nil
	local function visit(node, ancestors)
		--: (TypeRef) -> boolean
		local function is_recursion_target(n)
			for i = 1, #ancestors do
				if ancestors[i] == n then return true end
			end
			return false
		end

		visitor(node, {
			ancestors = ancestors,
			resolve_ref = bound_resolve_ref,
			is_recursion_target = is_recursion_target,
		})

		local next_ancestors = {}
		local count = #ancestors
		for i = 1, count do next_ancestors[i] = ancestors[i] end
		next_ancestors[count + 1] = node

		local children = M.child_type_refs(node.shape)
		for i = 1, #children do
			visit(children[i], next_ancestors)
		end
	end

	visit(doc.root, {})
	local names = ordered_keys(doc.defs)
	for i = 1, #names do
		local def = doc.defs[names[i]]
		if def ~= nil then visit(def, {}) end
	end
end

return M
