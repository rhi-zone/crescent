if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Minimal shared-type record: the fields `item.lua`'s `integrate` needs on
-- an Item's `parent` (mirrors the subset of yjs's internal YType fields --
-- `_start`, `_map`, `_length`, `_item` -- that the YATA algorithm itself
-- touches).
--
-- SCOPE: this is deliberately not Y.Text/Y.Array/Y.Map. Those are rich
-- public APIs (insert/delete/toString/observe/...) built on top of this
-- data model, out of scope for this core-CRDT-data-model task -- see
-- TODO.md. `doc.lua`'s get_text/get_array/get_map return one of these bare
-- records, tagged by `type_name`, for the algorithm to operate on; a future
-- library builds the ergonomic type wrappers around it.

local M = {}

-- `type_name` is e.g. "text" | "array" | "map". `start` (yjs `_start`) is
-- the first Item in the sequence linked list. `map` (yjs `_map`) maps
-- parent_sub -> current Item for Map-like entries. `length` (yjs `_length`)
-- is the visible (non-deleted, countable) length. `item` (yjs `_item`) is
-- the Item this type is embedded in, nil if root-level.
--:: SharedType = {
--::   type_name: string,
--::   start: unknown | nil,
--::   map: { [string]: unknown },
--::   length: number,
--::   item: unknown | nil,
--:: }

--: (type_name: string) -> SharedType
function M.new(type_name)
  return {
    type_name = type_name,
    start = nil,
    map = {},
    length = 0,
    item = nil,
  } --[[: SharedType]]
end

return M
