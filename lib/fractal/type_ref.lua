-- lib/fractal/type_ref.lua — TypeRef kind registry, ported from fractal's
-- packages/type-ir/src/index.ts (registerParent/ancestors/resolve).
--
-- A single-parent map from kind name to its parent kind name (or nil at the
-- root). `ancestors(kind)` walks that chain; `resolve(kind, handlers)` looks
-- up a handler table by kind, falling back through ancestors nearest-first,
-- returning nil if nothing matches all the way to the root.

local M = {}

--:: ParentMap = { [string]: string | nil }

local parents = {} --[[: ParentMap]]

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

return M
