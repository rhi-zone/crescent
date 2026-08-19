-- lib/api-tree/input.lua — the shared input-source resolution mechanism,
-- ported from fractal's packages/api-tree/src/input.ts.
--
-- A request/invocation is exposed as named STORES — uniform key-value
-- interfaces over each input source (path, query, header, body for HTTP;
-- flag, positional for a CLI; argument for MCP; ...). `assemble` reads each
-- declared param from a store, choosing the store by convention plus optional
-- per-param overrides.
--
-- Everything else in input.ts is compile-time-only TypeScript machinery with
-- no runtime behavior — the declaration-merged `StoreRegistry` and the
-- `Stores`/`ServiceStores`/`ProjectorStores` projections over it, and the
-- static source-coverage checks (`InputKeys`, `FindStoreForParam`,
-- `DeclaredSourceParams`, `UncoveredSourceParams`). They exist to make a
-- mis-declared store name or an uncovered `source()` override a compile
-- error at the `op()` call site; none of them emit code, so there is nothing
-- to port. `assemble` is input.ts's entire runtime surface.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- A named key-value interface over a single input source. Plain key access —
-- `store[key]`, not `store:get(key)`. A source that is method-backed rather
-- than table-backed is adapted to this shape by whichever projector builds
-- it, not by this module.
--:: Store = { [string]: unknown }

-- Where a specific param should be read from, overriding the convention.
-- `key` defaults to the param's own name when omitted.
--:: ParamSource = { store: string, key?: string }

-- Param name to source override. Only params listed here diverge from the
-- convention; every other param follows the primary-store rule.
--:: SourceMap = { [string]: ParamSource }

-- Build the handler's input bag by reading named params from stores.
--
-- Resolution order for each param:
--   1. the param name is in `path_param_names` → read from the "path" store;
--   2. the param has an explicit override in `source_map` → read from that;
--   3. otherwise → read from `primary_store` (the projector's convention).
--
-- `path_param_names` is optional: HTTP uses it for slug params captured from
-- the URL path; a projector with no such concept (e.g. MCP) omits it.
--
-- `primary_store` is skipped when it is the empty string, matching the TS
-- source's `if (primaryStore)` truthiness guard — a caller with no
-- convention passes `""` and gets only steps 1 and 2. (Lua's `""` is truthy,
-- so this has to be an explicit comparison rather than a bare `if`.)
--
-- A param that resolves to no value is simply absent from the returned
-- table. The TS original assigns `undefined` to the key, so `"x" in values`
-- is true there and false here; Lua has no way to hold a nil-valued key, and
-- introducing a sentinel would invent vocabulary the TS side has no notion
-- of. Callers must not use key presence to distinguish "declared but
-- unresolved" from "not declared" — consult `param_names` for that.
--
-- Callers needing to report where a param came from consult
-- `source_map[param]` directly, falling back to
-- `{ store = primary_store, key = param }`: the source map passed in here
-- already is the provenance record, so `assemble` does not hand back a
-- second one.
--: ({ [string]: Store }, string[], SourceMap, string, string[] | nil) -> { [string]: unknown }
function M.assemble(stores, param_names, source_map, primary_store, path_param_names)
	local path_names = path_param_names or {}

	--: (string) -> ParamSource | nil
	local function resolve(name)
		for i = 1, #path_names do
			if path_names[i] == name then
				return { store = "path", key = name }
			end
		end
		local override = source_map[name]
		if override ~= nil then
			return override
		end
		if primary_store ~= "" then
			return { store = primary_store, key = name }
		end
		return nil
	end

	local values = {}
	for i = 1, #param_names do
		local name = param_names[i]
		local src = resolve(name)
		if src ~= nil then
			local store = stores[src.store]
			if store ~= nil then
				values[name] = store[src.key or name]
			end
		end
	end
	return values
end

return M
