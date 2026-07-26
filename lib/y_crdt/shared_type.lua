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
--
-- `kind: "shared_type"` is a literal-string discriminant (matching every
-- other struct/content variant in this library: item.kind, gc.kind,
-- skip.kind, content.kind, ...) -- distinct from the `M.is`/SharedTypeMeta
-- nominal check just below, which is a *runtime* identity check that
-- doesn't feed the static typechecker (a metatable isn't part of the
-- structural shape `--::` describes). `kind` exists so `Item.parent`'s
-- union with ParentPendingId (lib/y_crdt/item.lua/integrate.lua -- a
-- transient, wire-decode-only "parent is this other item's id, not yet
-- resolved" placeholder) can be narrowed by field-discriminant instead of
-- an unprovable checked cast. Before this field existed, SharedType had no
-- discriminant at all, so a union containing it could never be narrowed
-- structurally -- see item.lua's `M.delete` for the call site this exists
-- for.
--:: SharedType = {
--::   kind: "shared_type",
--::   type_name: string,
--::   start: unknown | nil,
--::   map: { [string]: unknown },
--::   length: number,
--::   item: unknown | nil,
--:: }

-- Private identity tag (matches yjs's `instanceof AbstractType` check, the
-- nominal-typing tool Lua doesn't have natively). Rich shared-type wrappers
-- (text.lua/array.lua/map.lua) need to tell "this Array/Map value is itself
-- a nested shared type" apart from "this is a plain table the caller wants
-- stored as JSON/Any content" -- duck-typing on field names risks a false
-- positive on an unrelated user table that happens to share field names, so
-- this uses metatable identity instead, checked via `M.is` below. Setting a
-- metatable does not add fields to the structural shape `--::` records
-- above describe, so it does not change what `typeof`-capturing callers
-- (doc.lua, item.lua, ...) infer.
local SharedTypeMeta = {}

--: (type_name: string) -> SharedType
function M.new(type_name)
  return setmetatable({
    kind = "shared_type",
    type_name = type_name,
    start = nil,
    map = {},
    length = 0,
    item = nil,
  }, SharedTypeMeta) --[[: SharedType]]
end

-- True iff `v` was produced by `M.new` (directly, or via text.new/array.new/
-- map.new, which call it). Used by array.lua/map.lua to decide whether an
-- inserted value should be stored as ContentType (nested shared type) or
-- ContentAny (plain value).
--: (v: unknown) -> boolean
function M.is(v)
  return type(v) == "table" and getmetatable(v) == SharedTypeMeta
end

return M
