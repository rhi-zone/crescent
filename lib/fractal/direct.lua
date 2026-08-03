-- lib/fractal/direct.lua — the zero-protocol-overhead projection, ported from
-- fractal's packages/api-tree/src/direct.ts.
--
-- `create_direct_api(tree)` walks a Node tree and returns a nested callable
-- structure: a branch node becomes a table, a leaf becomes a callable, and a
-- `fallback` becomes a `(slug_value) -> sub_api` function keyed by the
-- fallback's name. There is no transport in the loop — no HTTP, no
-- serialization, no verb/path derivation; handlers are invoked in-process.
--
-- BOUND SLUG VALUES. On the HTTP side a param whose name matches a route
-- path slug always resolves from the `path` store, ahead of the primary store
-- or any source override (see `assemble`'s resolution order in input.lua). A
-- handler declaring an input like `{ bookId = ... }` relies on that seeding
-- and is never passed `bookId` explicitly by a caller. `api.books.bookId("123").read()`
-- only works if this projection reproduces it: each fallback call accumulates
-- its slug value, and every leaf beneath it merges the accumulated slugs into
-- the input it hands the handler — accumulated slugs first, caller-supplied
-- fields winning on conflict, the same precedence path params take in
-- `assemble`.
--
-- LEAF SHAPE. A leaf with no children and no fallback is a plain Lua
-- function, mirroring the TS, where such a node is a bare function too. A
-- node carrying BOTH a handler and children (uncommon but valid — see
-- init.lua) cannot be that, because a Lua function cannot hold keys: it
-- becomes a table whose child sub-APIs are ordinary keys and whose own
-- callable is exposed under a `handler` key (`node.handler(input)`), rather
-- than the node itself being callable. `type()` still distinguishes a bare
-- leaf (`"function"`) from a leaf-with-children (`"table"`).
--
-- ASYNC. Every leaf callable returns a promise, via `lib/async`'s established
-- transparent-coroutine convention (`async`/`await`, as used by
-- lib/http/server.lua) — the analogue of the TS projection's `async`
-- callables. A synchronous handler settles its promise before the call even
-- returns, so no event loop is required for the purely-synchronous case; a
-- handler that itself returns a promise is awaited, so a leaf never yields a
-- promise-of-a-promise.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local async   = require("lib.async")
local fractal = require("lib.fractal")

local M = {}

--:: NodeView = { handler?: (input: unknown) -> unknown, children?: { [string]: NodeView }, fallback?: { name: string, subtree: NodeView }, meta: { [string]: unknown } }

--:: Slugs = { [string]: string }

-- True for a plain mergeable table — the Lua reading of the TS
-- `typeof v === "object" && v !== null && !Array.isArray(v)`. Uses
-- init.lua's `is_array`, under which an empty table is NOT an array and so
-- IS a plain object, exactly matching JS's answer for `{}`.
--: (v: unknown) -> v is { [string]: unknown }
local function is_plain_table(v)
	if type(v) ~= "table" then return false end
	return not fractal.is_array(v)
end

-- Merge accumulated slug values into the caller-supplied input, slugs first
-- so explicit fields win on conflict. With no accumulated slugs the input
-- passes through unchanged, as does a non-table input, which a slug bag
-- cannot merge into.
--: (Slugs, unknown) -> unknown
local function with_slugs(slugs, input)
	if next(slugs) == nil then return input end
	local out = {}
	for k, v in pairs(slugs) do out[k] = v end
	if input == nil then return out end
	if not is_plain_table(input) then return input end
	for k, v in pairs(input) do out[k] = v end
	return out
end

-- A structural view of lib/async's `PromiseP`, declared here rather than
-- imported, carrying the `...` structural-subtyping marker its own
-- declaration uses.
--:: PromiseView = { _state: string, value: unknown, reason: unknown, _on_fulfill: { [integer]: (v: unknown) -> unknown }, _on_reject: { [integer]: (v: unknown) -> unknown }, _on_finally: { [integer]: () -> unknown }, ... }

-- lib/async's own promise detection, matching `M.await`'s guard: a table
-- carrying the internal `_state` field. Used to reproduce the TS `await`'s
-- thenable-unwrapping — a handler returning a promise is awaited, a handler
-- returning a plain value passes straight through.
--: (v: unknown) -> v is PromiseView
local function is_promise(v)
	if type(v) ~= "table" then return false end
	return v._state ~= nil
end

-- Wrap a leaf's handler as an async callable returning a promise.
--: (NodeView, Slugs) -> (input: unknown) -> unknown
local function make_caller(node, slugs)
	local handler = node.handler
	if handler == nil then
		error("fractal.direct: make_caller called on a node with no handler")
	end
	return async.async(function(input)
		local result = handler(with_slugs(slugs, input))
		if is_promise(result) then
			return async.await(result)
		end
		return result
	end)
end

--: (Slugs, string, string) -> Slugs
local function extend_slugs(slugs, name, value)
	local out = {}
	for k, v in pairs(slugs) do out[k] = v end
	out[name] = value
	return out
end

--: (NodeView, Slugs) -> unknown
local function build_api(tree, slugs)
	local children = tree.children
	local has_children = children ~= nil and next(children) ~= nil
	local fallback = tree.fallback
	local is_leaf = tree.handler ~= nil

	-- A leaf with nothing attached is a bare function, as in the TS.
	if is_leaf and not has_children and fallback == nil then
		return make_caller(tree, slugs)
	end

	local base = {}
	if children ~= nil then
		for key, child in pairs(children) do
			base[key] = build_api(child, slugs)
		end
	end
	if fallback ~= nil then
		local name = fallback.name
		local subtree = fallback.subtree
		base[name] = function(slug_value)
			return build_api(subtree, extend_slugs(slugs, name, slug_value))
		end
	end
	if is_leaf then
		-- Both a handler and children: the child sub-APIs are ordinary keys
		-- on this table, and the node's own callable sits under `handler`.
		base.handler = make_caller(tree, slugs)
	end
	return base
end

-- Recursively build a direct-call API from a Node tree.
--
--   - leaf (handler, no children/fallback) — a callable returning a promise;
--   - branch (children and/or fallback, no handler) — a nested table;
--   - both — a table with children as keys plus a `handler` key holding the
--     node's own callable;
--   - fallback — a `(slug_value) -> sub_api` function under `fallback.name`,
--     with the slug value threaded down and merged into every descendant
--     leaf's input (see the module doc's slug-seeding note).
--: (NodeView) -> unknown
function M.create_direct_api(tree)
	return build_api(tree, {})
end

return M
