-- lib/fractal/tags.lua — standard behavioral tags, the implication lattice
-- resolver, and the pre-order tree visitor. Ported from fractal's
-- packages/api-tree/src/tags.ts.
--
-- Tags are well-known keys in the open `meta.tags` sub-bag — NOT a closed
-- enum. A consumer may add its own tag keys; the constants below are the
-- standard library.
--
-- Three-valued semantics, which map onto Lua without a sentinel because a
-- Lua table cannot hold a `nil` value (assigning `nil` removes the key), so
-- "absent" and "unknown" are already the same observable state:
--   true  — this tag is explicitly asserted
--   false — this tag is explicitly negated
--   nil   — unknown (absence asserts nothing; no default inference)

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Standard tag keys ────────────────────────────────────────────────────

-- `readOnly`: the operation produces no observable side-effects on persistent
-- state; calling it any number of times is equivalent to calling it once.
-- Implies `idempotent`. Mutually exclusive with `destructive`.
M.TAG_READ_ONLY = "readOnly"

-- `idempotent`: calling the operation multiple times with the same arguments
-- produces the same state as calling it once. Implied by `readOnly`. Valid in
-- combination with `destructive` (e.g. DELETE).
M.TAG_IDEMPOTENT = "idempotent"

-- `destructive`: the operation irrevocably destroys or removes existing
-- state. Mutually exclusive with `readOnly`. Valid with `idempotent`.
M.TAG_DESTRUCTIVE = "destructive"

-- `openWorld`: the operation may reach systems outside the local service
-- boundary. Orthogonal to every other standard tag.
M.TAG_OPEN_WORLD = "openWorld"

-- `streaming`: the operation yields a sequence of items over time rather than
-- a single value. Orthogonal to every other standard tag. Derivable from the
-- handler's return type — see `resolve_tags`'s `output_type` parameter.
M.TAG_STREAMING = "streaming"

-- `deprecated`: the operation is slated for removal. Orthogonal to every
-- other standard tag — a deprecated operation may still be readOnly,
-- destructive, etc.
M.TAG_DEPRECATED = "deprecated"

-- `unvalidated`: a build-time escape hatch marking a leaf deliberately exempt
-- from the "every leaf must have a matching generated validator" check.
-- Deliberately NOT part of the implication lattice below: it has no
-- implications and is read directly off `meta.tags` by the validator wrapper,
-- rather than being a behavioral fact about the operation the way
-- `readOnly`/`destructive` are.
M.TAG_UNVALIDATED = "unvalidated"

-- ── Tag resolution — implication lattice ─────────────────────────────────

--:: Tags = { [string]: boolean }

--:: ResolvedTags = { readOnly?: boolean, idempotent?: boolean, destructive?: boolean, openWorld?: boolean, streaming?: boolean, deprecated?: boolean, conflict?: string }

-- The only part of a TypeRef `resolve_tags` reads. Declared structurally here
-- rather than imported, mirroring tags.ts's own type-only import: nothing in
-- this module constructs or otherwise touches a TypeRef at runtime.
--:: OutputTypeView = { shape: { kind: string } }

-- Apply the implication lattice to a `meta.tags` bag.
--
-- Rules applied:
--   readOnly ⇒ idempotent    (readOnly=true, idempotent unknown → idempotent=true)
--   readOnly ∧ destructive   → conflict (both true is a contradiction)
--   output_type.shape.kind == "stream" ⇒ streaming (when streaming is unknown)
--
-- Unknowns stay unknown — absence does NOT default to false. `openWorld` and
-- `deprecated` pass through untouched, as does `streaming` aside from the
-- return-type-derived default. Standard keys are read from the bag; any
-- additional keys the caller added are ignored here and remain in the bag,
-- untouched.
--
-- An explicit `tags.streaming` (true OR false) always wins over the
-- `output_type` derivation — authored fact over inferred one.
--: (Tags, OutputTypeView | nil) -> ResolvedTags
function M.resolve_tags(tags, output_type)
	local read_only = tags[M.TAG_READ_ONLY]
	local destructive = tags[M.TAG_DESTRUCTIVE]
	local raw_idempotent = tags[M.TAG_IDEMPOTENT]
	local open_world = tags[M.TAG_OPEN_WORLD]
	local raw_streaming = tags[M.TAG_STREAMING]
	local deprecated = tags[M.TAG_DEPRECATED]

	local streaming = raw_streaming
	if raw_streaming == nil and output_type ~= nil and output_type.shape.kind == "stream" then
		streaming = true
	end

	-- readOnly ⇒ idempotent: lift unknown to true when readOnly is asserted.
	local idempotent = raw_idempotent
	if read_only == true and raw_idempotent == nil then
		idempotent = true
	end

	-- readOnly ∧ destructive is a contradiction (both cannot be true).
	if read_only == true and destructive == true then
		return {
			readOnly = read_only,
			idempotent = idempotent,
			destructive = destructive,
			openWorld = open_world,
			streaming = streaming,
			deprecated = deprecated,
			conflict = "readOnly and destructive are mutually exclusive (both asserted true)",
		}
	end

	return {
		readOnly = read_only,
		idempotent = idempotent,
		destructive = destructive,
		openWorld = open_world,
		streaming = streaming,
		deprecated = deprecated,
	}
end

-- ── Tree transforms — the general modification primitive ─────────────────
--
-- Tag inheritance (a closest-wins ancestor walk) deliberately does not exist:
-- a node's tags are exactly what is on the node, never a function of its
-- ancestors, because inheritance-by-position breaks composability — moving a
-- subtree would silently change its behavior. `(tree) -> tree` transforms are
-- the general modification primitive instead, and `map_nodes` is the shared
-- walking primitive underneath them. A transform that wants "push this tag
-- down to descendants" builds that explicitly as its own recursion.

-- A minimal structural view of a Node, declared here rather than imported
-- from init.lua — mirrors tags.ts, which keeps its own `Node` import
-- type-only to avoid a runtime circular dependency with node.ts.
--:: NodeView = { handler?: (unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown } }

-- Pre-order visitor over a Node tree: `fn` sees each node BEFORE its children
-- (and its fallback subtree) are walked. Returns a new tree with `fn` applied
-- to every node reachable via `children` and `fallback.subtree`. The input
-- tree is not mutated; nodes are shallow-copied on the way out.
--: (NodeView, (NodeView) -> NodeView) -> NodeView
function M.map_nodes(tree, fn)
	local mapped = fn(tree)
	local out = {}
	for k, v in pairs(mapped) do out[k] = v end
	local children = mapped.children
	if children ~= nil then
		local mapped_children = {}
		for k, child in pairs(children) do
			mapped_children[k] = M.map_nodes(child, fn)
		end
		out.children = mapped_children
	end
	local fallback = mapped.fallback
	if fallback ~= nil then
		out.fallback = { name = fallback.name, subtree = M.map_nodes(fallback.subtree, fn) }
	end
	return out
end

return M
