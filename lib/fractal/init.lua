-- lib/fractal/init.lua — projection-tree constructors, ported from
-- fractal's packages/api-tree/src/node.ts (op/api/mergeMeta).
--
-- A Node is either a LEAF (carries `handler`) or a BRANCH (carries
-- `children`), or both. Every node carries `meta`, an open metadata bag
-- merged from zero or more contributions. `op()` builds a leaf, `api()`
-- builds a branch. See docs/fractal (if present) / the original fractal
-- source for the design rationale; this module is a faithful behavioral
-- port, not a redesign.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: Meta = { [string]: unknown }

--:: Node = { handler?: (unknown) -> unknown, children?: { [string]: Node }, fallback?: { name: string, subtree: Node }, meta: Meta }

-- True when every key of `t` is a positive integer 1..n with no gaps and no
-- other keys — i.e. `t` is array-shaped. An empty table is NOT considered
-- array-shaped (matches the `len > 0` convention used by
-- lib/format/json/pure.lua and lib/msgpack/init.lua for the same
-- Lua-table-conflates-array-and-object problem): Lua has no runtime tag
-- distinguishing `[]` from `{}` the way JS's `Array.isArray` does, so an
-- empty table is treated as an (empty) map, consistent with every other
-- codec in this repo that has to make the same call.
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

-- Deep-merge two record-like tables with precedence: `value`'s keys win.
-- Ported from node.ts's `mergeRecords`: plain objects merge recursively,
-- arrays concatenate, anything else (including a type mismatch, e.g. an
-- array merged against a map) resolves to `value`'s entry outright.
--
-- `value`'s keys holding an explicit `nil` are skipped in fractal's source
-- (`if (v === undefined) continue`) so a later merge never blanks out an
-- earlier one; Lua's `pairs()` already can't observe a key holding `nil`
-- (assigning `nil` removes the key), so that behavior falls out for free
-- here with no extra check needed.
--: ({ [string]: unknown }, { [string]: unknown }) -> { [string]: unknown }
local function merge_records(existing, value)
	local out = {}
	for k, v in pairs(existing) do out[k] = v end
	for k, v in pairs(value) do
		local e = out[k]
		if type(e) == "table" and type(v) == "table" and is_array(e) and is_array(v) then
			local merged = {}
			local n = 0
			for i = 1, #e do n = n + 1; merged[n] = e[i] end
			for i = 1, #v do n = n + 1; merged[n] = v[i] end
			out[k] = merged
		elseif type(e) == "table" and type(v) == "table" and not is_array(e) and not is_array(v) then
			out[k] = merge_records(e --[[: { [string]: unknown }]], v --[[: { [string]: unknown }]])
		else
			out[k] = v
		end
	end
	return out
end

-- Deep-merge meta bags left to right: later bags win per key, `nil` bags
-- are skipped entirely, plain tables merge recursively, arrays concatenate.
-- Ported from node.ts's `mergeMeta`.
--: (...(Meta | nil)) -> Meta
function M.merge_meta(...)
	local n = select("#", ...)
	local out = {}
	for i = 1, n do
		local m = select(i, ...)
		if type(m) == "table" then
			out = merge_records(out, m)
		end
	end
	return out
end

-- Build a leaf node: a Node carrying `handler` and merged `meta`.
--
-- `op(fn)` — bare fn, empty meta.
-- `op(fn, meta)` — single meta bag, used as-is (not copied, not merged
--   through mergeMeta — matches node.ts's `contributions.length === 1`
--   branch, which returns `contributions[0]` directly).
-- `op(fn, ...contributions)` — two or more bags, deep-merged left to right
--   via merge_meta (later wins per key).
--: ((unknown) -> unknown, ...Meta) -> Node
function M.op(fn, ...)
	local n = select("#", ...)
	if n == 0 then
		return { handler = fn, meta = {} }
	elseif n == 1 then
		local only = ...
		return { handler = fn, meta = only }
	end
	return { handler = fn, meta = M.merge_meta(...) }
end

--:: ApiOpts = { meta?: Meta, fallback?: { name: string, subtree: Node } }

-- Build a branch node: a Node carrying `children` and optional `meta`/
-- `fallback`. Ported from node.ts's `api()`. `opts.meta` defaults to `{}`
-- when absent; `opts.fallback` is only set on the result when present.
--: ({ [string]: Node }, ApiOpts | nil) -> Node
function M.api(children, opts)
	local meta = (opts and opts.meta) or {}
	local fallback = opts and opts.fallback
	if fallback ~= nil then
		return { children = children, meta = meta, fallback = fallback }
	end
	return { children = children, meta = meta }
end

return M
