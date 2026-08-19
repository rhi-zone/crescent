-- lib/api-tree/page.lua — the pagination convention, ported from fractal's
-- packages/api-tree/src/page.ts.
--
-- A handler returning a cursor page or an offset page signals "this endpoint
-- is paginated" the same way a handler returning a stream signals streaming:
-- no fixed contract to implement, just a recognizable shape. The predicates
-- below are the RUNTIME half of that convention — the opt-in sniff a
-- projector performs on an actual resolved value, mirroring `is_stream_chunk`
-- / `is_result_shape` in result.lua.
--
--   cursor page — { items = {...}, cursor? = "...", hasMore = bool }
--                 an opaque continuation token; `cursor` is present while
--                 `hasMore` is true, absent on the last page.
--   offset page — { items = {...}, offset = n, total = n, hasMore = bool }
--                 a numeric window over a known-size collection; `offset` is
--                 the index of `items[1]` within the full collection.
--
-- Hierarchy via subtyping, not a closed enum: "a page" is their union, not a
-- third variant of its own.
--
-- WIRE FORMAT. The field names are camelCase (`hasMore`, not `has_more`)
-- because these values are JSON-serialized into response bodies and
-- shape-sniffed against decoded JSON on the far side of the wire — the names
-- are part of the cross-language contract, not an internal choice. This is
-- deliberately NOT `lib/pagination`'s snake_case convention; that library is
-- an independent in-memory paginator over Lua lists, is not wire-facing, and
-- is untouched by this module.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- Array-shaped test for page-shape detection, where an EMPTY table counts as
-- an array.
--
-- This deliberately differs from `is_array` in init.lua, which treats an
-- empty table as a map: Lua has no runtime tag distinguishing `[]` from `{}`,
-- so every consumer has to pick, and the two consumers want opposite
-- answers. For meta merging, "empty means map" keeps merge behavior
-- consistent with this repo's codecs. Here, the last page of any paginated
-- collection legitimately carries zero items, and that page must still be
-- recognized as a page — the single most common real case would otherwise
-- fail detection. Scoped local to this module on purpose; init.lua's
-- `is_array` semantics are unchanged.
--: (unknown) -> boolean
local function is_array_like(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { [unknown]: unknown }]]
	local len = 0
	for _ in pairs(t) do len = len + 1 end
	if len == 0 then return true end
	for i = 1, len do
		if t[i] == nil then return false end
	end
	return true
end

-- True when `v` structurally matches a cursor page: `items`/`hasMore`
-- present, but WITHOUT an offset page's numeric `offset`. The negative
-- `offset` check is what keeps the two predicates mutually exclusive on a
-- value that carries both styles' fields.
--: (unknown) -> boolean
function M.is_cursor_page(v)
	if type(v) ~= "table" then return false end
	local o = v --[[: { [string]: unknown }]]
	return is_array_like(o.items) and type(o.hasMore) == "boolean" and type(o.offset) ~= "number"
end

-- True when `v` structurally matches an offset page: numeric `offset`/`total`
-- alongside `items`/`hasMore`.
--: (unknown) -> boolean
function M.is_offset_page(v)
	if type(v) ~= "table" then return false end
	local o = v --[[: { [string]: unknown }]]
	return is_array_like(o.items)
		and type(o.hasMore) == "boolean"
		and type(o.offset) == "number"
		and type(o.total) == "number"
end

-- True when `v` matches either pagination shape — the opt-in runtime sniff,
-- mirroring `is_stream_effect`/`is_result_shape` in result.lua.
--: (unknown) -> boolean
function M.is_page_shape(v)
	return M.is_offset_page(v) or M.is_cursor_page(v)
end

return M
