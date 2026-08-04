-- lib/fractal/ffi_ir.lua — the FFI-IR data model, ported from fractal's
-- packages/ffi-ir/src/index.ts.
--
-- FFI-IR is boundary-crossing vocabulary — modules/interfaces, function and
-- method signatures, opaque resource handles — layered ON TOP of the TypeRef
-- model in `lib/fractal/type_ref.lua` rather than folded into it. Every
-- parameter/return/field position here is a type-ir `TypeRef`; this module
-- references that model and never re-derives data shape.
--
-- Three pieces live here, the same three that live in the TS file:
--
--   1. Ownership metadata — the four disciplines (`copy`, `opaque-handle`,
--      `refcount`, `resource` own/borrow) as a tagged union, attached to a
--      TypeRef's open `meta` bag under the key `ownership`. This deliberately
--      reuses the exact mechanism `meta.optional`/`meta.nullable` already use
--      in type_ref.lua — it is NOT a wrapping type constructor the way WIT's
--      `own<T>`/`borrow<T>` are. The same value's resource can be passed
--      `own` in one signature and `borrow` in another, which is precisely why
--      the discipline lives on the REFERENCE's metadata and not on a
--      type-level flag.
--   2. The boundary kind lattice and data model — `FfiKinds`/`FfiShape`/
--      `FfiRef`, mirroring type_ref.lua's `TypeShape`/`TypeRef` pattern (open
--      kind vocabulary, ancestor fallback via `ancestors`/`resolve`/
--      `register_parent`) on ffi-ir's OWN, SEPARATE kind space.
--   3. Provenance metadata — which ingestor or hand-authored source produced
--      an FfiRef, under the `provenance` key of an FfiRef's own meta bag.
--
-- SEPARATE REGISTRY, DELIBERATELY. `parents` below is ffi-ir's own and has
-- nothing to do with type_ref.lua's. Boundary-semantics kinds (`function`,
-- `method`, `resource`, `module`) have no business living in the same
-- ancestor-fallback lattice as type-ir's data-shape kinds, even though the
-- MECHANISM is the same mechanism, reused rather than reinvented. Note that
-- `function` and `method` are names appearing in BOTH registries meaning
-- different things: type-ir's are callable VALUES (a struct field typed as a
-- callback), ffi-ir's are top-level boundary EXPORTS. Registering a parent
-- here has no effect on type_ref.resolve, and vice versa.
--
-- WHICH DISCIPLINE A BACKEND IMPLEMENTS IS A BACKEND CONCERN. The IR stays
-- capable of expressing all four; a projector that cannot realize a given
-- discipline on its target reports `(nil, errmsg)` explicitly rather than
-- silently mis-lowering it. Nothing in this file restricts which are
-- expressible.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

-- Required for its TYPE declarations, not for its functions: `TypeRef` and
-- `Meta` below are type_ref.lua's, and every parameter/return position in
-- this file is one of its TypeRefs. Nothing here calls into it at runtime —
-- ffi-ir references the data model, it does not construct or traverse it.
local type_ref = require("lib.fractal.type_ref")

-- TYPECHECKER WORKAROUND: these three are VERBATIM COPIES of type_ref.lua's
-- own declarations, which this file already imports via the `require` above.
-- Duplicating a type definition is normally forbidden outright; it is here
-- only because the checker cannot currently keep an imported alias resolvable
-- through a consumer.
--
-- The natural code is no re-declaration at all — `require` alone, exactly as
-- type_ref_json_schema.lua does. That works while ffi_ir.lua is the file being
-- checked, and breaks as soon as ANY file consumes it: when a consumer calls a
-- function whose signature names an alias declared here, the checker
-- re-resolves this file's `--::` declarations in the CONSUMER's scope, where
-- type_ref.lua's `TypeRef`/`Meta` are not bound. They resolve to `undefined
-- type`, silently degrade to `any`, and every consumer reports errors against
-- THIS file's line numbers. Minimal repro, against this module as it would
-- naturally be written:
--
--     local ffi_ir = require("lib.fractal.ffi_ir")
--     --: (s: unknown) -> unknown
--     local function pick(s) return (s --[[: FfiModuleShape]]).name end
--
--   → lib/fractal/ffi_ir.lua:263: undefined type `TypeRef`
--     lib/fractal/ffi_ir.lua:263: type contains 'any' — use 'unknown' ...
--
-- Casting to inline structural types on the consumer side does NOT avoid it —
-- the trigger is the signature of any function the consumer calls, not the
-- consumer's own casts. Re-declaring here is the only formulation found that
-- lets both this file and its consumers check clean.
--
-- These MUST stay structurally identical to type_ref.lua's. Delete all three
-- and rely on the `require` once the checker resolves imported aliases through
-- a consumer (TODO.md). The same three lines are repeated in each backend for
-- the same reason.
--:: Meta = { [string]: unknown }
--:: TypeShape = { kind: string, ... }
--:: TypeRef = { shape: TypeShape, meta: Meta }

local M = {}

-- A shallow copy of `meta` with `key` set. Copy, not mutation: a TypeRef or
-- FfiRef is routinely shared between positions, so annotating one position
-- must never annotate every other.
--
-- TYPECHECKER WORKAROUND: `key` is a `string` PARAMETER here, and every
-- caller below passes the key name as an argument, purely to keep the write
-- off a literal field name. The natural code at each call site is a direct
-- `meta.ownership = discipline` / `meta.provenance = provenance` after
-- copying the bag inline, with no helper at all. That does not typecheck: a
-- named-key write to a table typed by an index signature (`{ [string]:
-- unknown }`) adds that key to the index-signature type itself as a REQUIRED
-- field, and the pollution is shared by every `{ [string]: unknown }` in the
-- file — so a later `local m = {} --: Meta` is rejected for "missing field
-- 'ownership'". Minimal repro (no project dependencies):
--
--     --:: Meta = { [string]: unknown }
--     --: (d: string) -> Meta
--     local function f(d)
--         local out = {} --: Meta
--         out.ownership = d   -- makes `ownership` required on Meta
--         return out
--     end
--
-- A computed key (`out["ownership"]`) and an inline `{ [string]: unknown }`
-- annotation instead of the alias both fail identically. Routing the write
-- through a `string`-typed parameter is the only formulation that passes.
-- Same shape as the `assign` helper in type_ref_json_schema.lua, which is
-- there for the same reason. Revert to direct field writes and drop this
-- helper once the checker stops treating a named-key write as a refinement of
-- the index-signature type (TODO.md).
--: (meta: Meta, key: string, value: unknown) -> Meta
local function assign(meta, key, value)
	local out = {} --: Meta
	for k, v in pairs(meta) do out[k] = v end
	out[key] = value
	return out
end

-- ── Ownership metadata ───────────────────────────────────────────────────────

-- The four disciplines, as a tagged union keyed on `kind` — the same
-- `{ kind = ... }` discriminated-union convention result.lua uses for
-- `ok`/`err`.
--
--   copy          — crosses by value, always cloned/duplicated at the
--                   boundary. Native to every target.
--   opaque-handle — an opaque pointer/handle plus an explicit, separately
--                   declared free function; no compiler- or runtime-checked
--                   discipline beyond "call free exactly once". `freeFn`
--                   names the exported free function a backend should emit a
--                   call to, when known, and is absent when it is not.
--   refcount      — shared ownership via a reference count, freed when the
--                   count reaches zero.
--   resource      — an owned-or-borrowed handle (WIT's own shipped mechanism:
--                   per-instance handle table, lend-count tracking, trap on
--                   violation). `mode` is "own" or "borrow", distinguishing
--                   the two call-site qualifiers WIT itself distinguishes
--                   PER REFERENCE, not per type.
--
-- WIRE-ADJACENT FIELD NAME. `freeFn` is camelCase, matching the TS source's
-- field name, because these records are read by projectors ported from the
-- same source and by callers assembling IR from cross-language tooling — the
-- name is part of the shared vocabulary, not an internal choice. Same
-- rationale as page.lua's `hasMore`.
--:: OwnershipCopy = { kind: "copy" }
--:: OwnershipOpaqueHandle = { kind: "opaque-handle", freeFn?: string }
--:: OwnershipRefcount = { kind: "refcount" }
--:: OwnershipResource = { kind: "resource", mode: string }
--:: OwnershipDiscipline = OwnershipCopy | OwnershipOpaqueHandle | OwnershipRefcount | OwnershipResource

-- Convenience constructors for `OwnershipDiscipline` values.
--
-- All four are FUNCTIONS returning a fresh table, including the two with no
-- payload. type_ref.lua's `types` table makes its payload-free kinds shared
-- constant tables instead, but its stated reason is to match the TS source's
-- own `as const` singletons — and this source's `ownership.copy`/`refcount`
-- are functions allocating fresh objects, not singletons. Matching the
-- source's allocation behavior is the rule; a constant table here would be a
-- divergence, not the precedent.
M.ownership = {
	--: () -> OwnershipCopy
	copy = function()
		return { kind = "copy" }
	end,

	-- `free_fn` is optional: omitted means the free function's name is not
	-- known at IR-construction time, and the key is genuinely absent from the
	-- result rather than present-and-nil (the two branches match the TS
	-- constructor's own `freeFn === undefined` test).
	--: (free_fn: string | nil) -> OwnershipOpaqueHandle
	opaque_handle = function(free_fn)
		if free_fn == nil then
			return { kind = "opaque-handle" }
		end
		return { kind = "opaque-handle", freeFn = free_fn }
	end,

	--: () -> OwnershipRefcount
	refcount = function()
		return { kind = "refcount" }
	end,

	-- `mode` is "own" or "borrow". Not validated here: the TS side constrains
	-- it with a literal union the Lua annotation cannot enforce at runtime,
	-- and a projector reading an unrecognized mode reports it explicitly
	-- rather than this constructor rejecting late-bound input.
	--: (mode: string) -> OwnershipResource
	resource = function(mode)
		return { kind = "resource", mode = mode }
	end,
}

-- Read the ownership discipline off a TypeRef's meta bag, or nil when the
-- reference carries none (which every backend reads as `copy` — an
-- unannotated position crosses by value).
--
-- Returns the raw table without validating its `kind`: the meta bag is open,
-- so a value under this key that is not a well-formed discipline is data a
-- projector must diagnose, not something this reader can silently drop.
--: (ref: TypeRef) -> OwnershipDiscipline | nil
function M.ownership_of(ref)
	local discipline = ref.meta.ownership
	if type(discipline) ~= "table" then return nil end
	local rec = discipline --[[: { kind: unknown, ... }]]
	if type(rec.kind) ~= "string" then return nil end
	return discipline --[[: OwnershipDiscipline]]
end

-- A copy of `ref` carrying `discipline` under `meta.ownership`. The original
-- is never mutated — a TypeRef built by `type_ref.types.*` is routinely
-- shared between positions, and annotating one position must not annotate
-- every other.
--: (ref: TypeRef, discipline: OwnershipDiscipline) -> TypeRef
function M.with_ownership(ref, discipline)
	return { shape = ref.shape, meta = assign(ref.meta, "ownership", discipline) }
end

-- A type-ir `ref` TypeRef pointing at a resource by name, carrying resource
-- ownership metadata — the documented convention for a resource handle
-- crossing a boundary, as a constructor so callers need not hand-assemble the
-- `{ kind = "ref" }` shape themselves.
--
-- `resource_name` names an entry in the enclosing module's `resources` map.
-- This is a convention this module documents and follows, not a contract it
-- enforces — the same "conventions over contracts" precedent type_ref.lua's
-- own metadata bag uses.
--: (resource_name: string, mode: string) -> TypeRef
function M.resource_ref(resource_name, mode)
	return {
		shape = { kind = "ref", target = resource_name },
		meta = assign({}, "ownership", M.ownership.resource(mode)),
	}
end

-- ── Boundary kinds ───────────────────────────────────────────────────────────

-- One named parameter of a boundary function/method. `type` is a type-ir
-- `TypeRef`; ownership discipline, when applicable, is metadata on that
-- TypeRef itself (see `with_ownership`), never a field here.
--:: FfiParam = { name: string, type: TypeRef }

-- A boundary shape is any record carrying a string `kind`. Deliberately open
-- rather than a closed union of the four kinds below, for the same reason
-- type_ref.lua's `TypeShape` is open: the TS interface is extended by
-- declaration merging, so a shape whose kind this file has never heard of is
-- a legitimate, expected input.
--:: FfiShape = { kind: string, ... }

-- `meta` is an open metadata bag, same "conventions over contracts" precedent
-- as type_ref.lua's `TypeRef.meta`. Recognized keys today: `description` (a
-- doc comment every backend emits), `provenance` (see below), and the
-- per-backend keys individual projectors document (e.g. a library path).
--
-- No calling-convention key is defined. WIT has a first-class `async`
-- qualifier plus `stream<T>`/`future<T>`, C has no async calling convention
-- at all, and JS has native Promise; a single shared async model is NOT
-- decided upstream, so none is invented here. The bag exists so one can be
-- added without a schema change when it is.
--:: FfiRef = { shape: FfiShape, meta: Meta }

-- The four built-in boundary kinds' concrete shapes. Each is a subtype of
-- `FfiShape`, so every one can be handed to `ffi_ref_from_shape` and
-- dispatched by `resolve`. Spelled out rather than collapsed into `FfiShape`
-- because a caller reading `shape.params` off a `function` should not have to
-- cast to get at it.
--
--   function — a free function exported at an FFI boundary. NOT a data-shape
--              callable value (that is type-ir's own `function` kind; a
--              struct field typed as a callback still uses a type-ir
--              `function` TypeRef, unchanged) but the boundary's own
--              top-level export: a named entry point with an
--              ownership-annotatable parameter/return list.
--   method   — a callable belonging to a resource's own method surface. Same
--              shape as `function` plus `receiver`, naming the resource (by
--              its key in the enclosing module's `resources` map) the method
--              operates on.
--   resource — an opaque/owned handle to an entity existing at the boundary.
--              Exposes behavior ONLY through `methods`, mirroring WIT's own
--              constraint that resources cannot be plain data structures.
--              Note that own/borrow is NOT part of this declaration — it is
--              metadata on each REFERENCE to the resource (see
--              `resource_ref`).
--   module   — groups the functions and resources exported at one boundary.
--              Roughly analogous to WIT's `interface`, and deliberately
--              narrower: WIT's richer world/package import/export/versioning
--              layer is ecosystem-bound to the Component Model specifically
--              and is not part of this vocabulary.
--:: FfiFunctionShape = { kind: "function", params: FfiParam[], returnType: TypeRef }
--:: FfiMethodShape = { kind: "method", params: FfiParam[], returnType: TypeRef, receiver: string }
--:: FfiResourceShape = { kind: "resource", name: string, methods: { [string]: FfiRef } }
--:: FfiModuleShape = { kind: "module", name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef } }

-- A shape carrying a parameter list and a return type — `function` and
-- `method` both satisfy it. Backends take this rather than either concrete
-- shape wherever they emit a signature, which is what lets one emitter serve
-- both kinds.
--:: FfiFunctionLike = { params: FfiParam[], returnType: TypeRef, ... }

-- Wrap a boundary shape into an FfiRef. `meta` defaults to an empty bag.
-- (fractal's `f()` — renamed here because a one-letter name predicts nothing
-- about its signature, the same rename type_ref.lua applied to `t()`.)
--: (shape: FfiShape, meta: Meta | nil) -> FfiRef
function M.ffi_ref_from_shape(shape, meta)
	return { shape = shape, meta = meta or {} }
end

-- The boundary shape constructors, mirroring type_ref.lua's `types`.
--
-- `function_` carries a trailing underscore because `function` is a Lua
-- keyword and cannot be a table-literal key; every other kind keeps its
-- fractal name. Same rename type_ref.lua applied for the same reason.
M.boundary = {
	--: (params: FfiParam[], return_type: TypeRef) -> FfiFunctionShape
	function_ = function(params, return_type)
		return { kind = "function", params = params, returnType = return_type }
	end,

	--: (params: FfiParam[], return_type: TypeRef, receiver: string) -> FfiMethodShape
	method = function(params, return_type, receiver)
		return { kind = "method", params = params, returnType = return_type, receiver = receiver }
	end,

	--: (name: string, methods: { [string]: FfiRef }) -> FfiResourceShape
	resource = function(name, methods)
		return { kind = "resource", name = name, methods = methods }
	end,

	--: (name: string, functions: { [string]: FfiRef }, resources: { [string]: FfiRef }) -> FfiModuleShape
	module = function(name, functions, resources)
		return { kind = "module", name = name, functions = functions, resources = resources }
	end,
}

-- ── Kind lattice ─────────────────────────────────────────────────────────────

--:: FfiParentMap = { [string]: string | nil }

-- Seeded with the one built-in subtype relationship from the TS source: a
-- method IS a callable, so a projector without an explicit `method` handler
-- falls back to its `function` handler. `function`, `resource` and `module`
-- are roots — a projector that cannot express a resource or a module has
-- nothing to silently fall back to and must degrade explicitly.
local parents = {
	method = "function",
} --[[: FfiParentMap]]

-- Register (or overwrite) `kind`'s parent in ffi-ir's registry. Pass `nil`
-- (or omit) to make `kind` a root.
--
-- This registry is NOT type_ref.lua's — see the file header. Registering
-- `method` here does not affect `type_ref.resolve`.
--: (kind: string, parent: string | nil) -> nil
function M.register_parent(kind, parent)
	if parent == nil then
		parents[kind] = nil
	else
		parents[kind] = parent
	end
end

-- The chain of ancestor kind names for `kind`, nearest first, NOT including
-- `kind` itself. Stops at the first kind with no registered parent. Returns
-- an empty list when `kind` itself has no registered parent.
--: (kind: string) -> string[]
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
-- ancestor nearest-first. Returns nil when neither `kind` nor any ancestor
-- has a handler.
--: <T>(kind: string, handlers: { [string]: T }) -> T | nil
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

-- ── Provenance ───────────────────────────────────────────────────────────────

-- A record of where an FfiRef came from — which ingestor (a C-header parser,
-- a `.wit` parser) or hand-authored source produced it.
--
-- `source` is an OPEN string tag, not a fixed set: enumerating every ingestor
-- fractal will ever have would fix a vocabulary this schema leaves open
-- (`"c-header"`, `"wit-file"`, `"hand-authored"` are examples, not the
-- allowed values). Beyond `source` the record is an open bag — a file path, a
-- line number, a parser version, an original identifier — with no schema
-- change needed here.
--:: Provenance = { source: string, ... }

-- A copy of `ref` carrying `provenance` under `meta.provenance`. The natural
-- attachment point is the module-level FfiRef — one module is the natural
-- unit of "this came from one ingestion event" — but nothing restricts it to
-- that level: `meta` exists on every FfiRef, so a function-level or
-- resource-level override is representable the same way, e.g. when a module
-- is assembled by hand from pieces stamped by different ingestors.
--: (ref: FfiRef, provenance: Provenance) -> FfiRef
function M.with_provenance(ref, provenance)
	return { shape = ref.shape, meta = assign(ref.meta, "provenance", provenance) }
end

return M
