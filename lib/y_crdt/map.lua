if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Y.Map: a shared key-value map. A rich wrapper around the bare SharedType
-- record (shared_type.lua) and the YATA core (item.lua/integrate.lua) --
-- see TODO.md's "shared_type.lua is bare" entry this fills in.
--
-- Unlike text.lua/array.lua, Map entries use `parent_sub` (the key) instead
-- of sequence position, and conflict resolution is last-writer-wins by
-- (clock, client): `M.set` sets the new Item's `origin` to the current
-- head Item's `last_id` (or nil if the key is unset) and leaves `left`/
-- `right` nil, letting integrate.lua's normal origin-resolution path
-- (struct_store.get_item_clean_end) resolve `left` -- this reproduces yjs's
-- `typeMapSet` (`new Item(nextID, left, left && left.lastId, null, null,
-- parent, key, content)`) without any Map-specific branch here, because
-- integrate.lua already has the parent_sub-aware conflict search and
-- same-key supersession-delete built in (see its "Map entry" branches).

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local shared_type = require("lib.y_crdt.shared_type")
local integrate = require("lib.y_crdt.integrate")

local M = {}

-- See text.lua for why these are hand-restated rather than `typeof`-captured.
--:: Id = { client: integer, clock: integer }
-- `ParentPendingId`/`SharedType.kind` match item.lua's/shared_type.lua's own
-- additions (built alongside lib/y_crdt/update.lua, the wire decoder, in
-- parallel with this file) -- see integrate.lua's matching restatement for
-- the full rationale.
--:: ParentPendingId = { kind: "pending_parent_id", client: integer, clock: integer }
--:: Content = { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "embed", ref: integer, embed: unknown } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string }
--:: SharedType = { kind: "shared_type", type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: Item = {
--::   kind: "item",
--::   id: Id,
--::   origin: Id | nil,
--::   origin_right: Id | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedType | ParentPendingId | nil,
--::   parent_sub: string | nil,
--::   content: Content,
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }

--:: StructStore = { clients: { [number]: unknown } }
-- `merge_structs` matches transaction.lua's/text.lua's own field of the
-- same name (unused by this file -- map.lua has no split call sites of its
-- own -- but present so a `txn` value threaded through both this file and
-- text.lua in the same `doc.transact` callback type-checks consistently;
-- see transaction.lua's `Transaction` header comment for what the field is
-- for).
--:: Transaction = { doc: { client_id: number, store: StructStore, clock: number }, new_items: Item[], deleted_items: Item[], merge_structs: Item[] }

-- TYPECHECKER WORKAROUND: `shared_type.new(...)`'s return type is
-- shared_type.lua's own declared `SharedType`, whose `start`/`map`/`item`
-- fields are `unknown` (that file avoids a require() cycle back to
-- item.lua the same way content.lua does for `ContentType.shared_type`).
-- Casting that whole record to this file's `Item`-fielded `SharedType` in
-- one shot -- `shared_type.new(...) --[[: SharedType]]` -- is rejected
-- ("field 'start': value of type unknown must be narrowed before use"),
-- and confirmed (via several minimal repros, including one exactly
-- matching content.lua's ContentType shape) that unlike a single bare
-- `unknown` *value* casting to a concrete type (which does work, see
-- integrate.lua's `ContentType.shared_type` cast), a *record* whose fields
-- are `unknown` never casts field-for-field into a same-shaped record with
-- concrete field types, by any cast form (checked, doubly-indirected
-- through a fresh `unknown`, or via a function's own declared return
-- type) -- force casts are hard-rejected by this project's tooling
-- regardless. The natural code would be the single-line cast above.
-- Sidestepped here by not reading back `shared_type.new`'s unknown fields
-- at all: a freshly-constructed SharedType is always empty (`start = nil,
-- map = {}, length = 0, item = nil`), so this constructs the return value
-- from those known literal values directly (needing no cast, since none
-- of them are `unknown`) and borrows the original's metatable via
-- `getmetatable` so `shared_type.is()` still recognizes it -- `type_name`
-- is the one field read back, and it's already a plain `string` in
-- shared_type.lua's own declaration, so no cast is needed there either.
-- TODO.md tracks collapsing this back to the single-line cast once
-- unknown-fielded record casting is supported.
--: () -> SharedType
function M.new()
  local st = shared_type.new("map")
  return setmetatable({
    kind = "shared_type",
    type_name = st.type_name,
    start = nil,
    map = {},
    length = 0,
    item = nil,
  }, getmetatable(st)) --[[: SharedType]]
end

--: (it: Item) -> unknown
local function value_of(it)
  if it.content.kind == "any" then return it.content.arr[1] end
  if it.content.kind == "type" then return it.content.shared_type end
  return nil
end

-- Sets `key` to `value` (a plain value stored as ContentAny, or a nested
-- shared type stored as ContentType, wired back via `.item` the same way
-- array.lua does). The previous value for `key`, if any, is superseded and
-- marked deleted by integrate.lua's Map-entry branch.
-- `key` is `unknown`, not `string`, matching the runtime `type(key) ~=
-- "string"` guard right below: this is a public entry point taking
-- caller-supplied input, not a value a well-typed caller is trusted to get
-- right (the guard exists precisely so a non-string key is a caller-facing
-- data error, not a crash).
--: (m: SharedType, txn: Transaction, key: unknown, value: unknown) -> true | (nil, string)
function M.set(m, txn, key, value)
  if type(key) ~= "string" then return nil, "map.set: key must be a string" end

  -- TYPECHECKER WORKAROUND: `local c --[[: Content]]` declared empty (Lua
  -- implicitly nils it) and assigned in both arms of an if/else does not
  -- narrow away the initial `nil` for later use (`item.new`'s 6th argument
  -- then errors "cannot pass nil where Content expected") -- the natural
  -- code would be the if/else above. The ternary form infers a plain
  -- `Content` with no nil possibility, since neither `content.type`/
  -- `content.any` branch can itself be falsy. TODO.md tracks reverting to
  -- the if/else once this narrows correctly.
  local c = shared_type.is(value) and content.type(value) or content.any({ value })

  local existing = m.map[key]
  local origin = existing ~= nil and item.last_id(existing) or nil
  local doc = txn.doc
  local iid = id.new(math.floor(doc.client_id), math.floor(doc.clock))
  local new_item = item.new(iid, origin, nil, m, key, c)
  -- Wrapped to integrate.lua's exact declared Transaction shape -- see
  -- text.lua's insert_item for why (nested record fields aren't
  -- width-subtyped; new_items/deleted_items are the same array references).
  local ok, err = integrate.integrate({ doc = { store = doc.store }, new_items = txn.new_items, deleted_items = txn.deleted_items }, new_item)
  if ok == nil then return nil, err or "map.set: integrate failed" end
  doc.clock = doc.clock + new_item.length

  -- TYPECHECKER WORKAROUND: `value` is `unknown` (this API accepts any
  -- value); a plain `value --[[: { item: Item | nil } ]]` cast is rejected
  -- ("value of type unknown must be narrowed before use") -- confirmed
  -- `unknown` never casts directly to a record type, even a one-field
  -- non-recursive one, by minimal repro. The `type(value) == "table"`
  -- runtime check first is what actually narrows it (matches the
  -- already-documented "unknown toward table" narrowing elsewhere in this
  -- codebase); `shared_type.is` alone doesn't feed the static typechecker
  -- (it's a runtime-only nominal check, see shared_type.lua), so this
  -- guard is the type-level counterpart, redundant with `shared_type.is`
  -- at runtime but necessary for the checker.
  if shared_type.is(value) and type(value) == "table" then
    local v = value --[[: { item: Item | nil } ]]
    v.item = new_item
  end

  return true
end

--: (m: SharedType, key: string) -> unknown
function M.get(m, key)
  local it = m.map[key]
  if it == nil or it.deleted then return nil end
  return value_of(it)
end

--: (m: SharedType, txn: Transaction, key: string) -> true | (nil, string)
function M.delete(m, txn, key)
  local it = m.map[key]
  if it == nil or it.deleted then return true end
  -- TYPECHECKER WORKAROUND: item.lua's own `Transaction` alias doesn't
  -- carry this file's `merge_structs` field (added so a `txn` value
  -- threaded through both this file and text.lua in the same
  -- `doc.transact` callback type-checks consistently) -- reconstructing
  -- the narrower shape sidesteps that, same reasoning as `M.set`'s own
  -- `integrate.integrate` wrapping just above. The natural code would call
  -- `item.delete(txn, it)` directly.
  item.delete({ doc = txn.doc, new_items = txn.new_items, deleted_items = txn.deleted_items }, it)
  return true
end

--: (m: SharedType, key: string) -> boolean
function M.has(m, key)
  local it = m.map[key]
  return it ~= nil and not it.deleted
end

--: (m: SharedType) -> { [string]: unknown }
function M.to_table(m)
  local out = {} --[[: { [string]: unknown } ]]
  for key, it in pairs(m.map) do
    if not it.deleted then
      out[key] = value_of(it)
    end
  end
  return out
end

-- TYPECHECKER WORKAROUND: neither `next(m.map, k)` nor destructuring
-- `pairs(m.map)`'s return into a manual `(iter, tbl, control)` iterator
-- triple typechecks here. `next`'s stdlib signature (`<T>(t: T, k: Keys<T>
-- | nil) -> (Keys<T> | nil, Values<T> | nil)`, a mapped-type extraction)
-- fails to unify `T = { [string]: Item }`'s key type with a plain `string
-- | nil` local ("function expects `match ... { ... } | nil`, but `k`
-- might also be `string`"). `pairs`'s own declared type
-- (`PairsReturn<T> = match T { { ...[%K]: %V } => (K, V) }`) models it as
-- if it directly yields `(K, V)` pairs -- fine for the direct `for k, v in
-- pairs(t) do` form this module already uses in `to_table` above -- but
-- destructuring that same call into 3 locals to hand-roll `next`'s
-- iterator protocol binds the first local to `K` (here `string`), not an
-- iterator function, so calling it errors "cannot call value of type
-- string". Sidestepped by using `pairs()` only in its proven-working
-- direct for-loop form: eagerly collecting into a plain array first, then
-- returning a simple index-based closure over that array instead of a
-- live view over `m.map`. TODO.md tracks reverting to a lazy `next`-based
-- iterator once one of these unifies correctly.
--
-- Stateful iterator over non-deleted keys: `for k in map.keys(m) do ... end`.
--: (m: SharedType) -> (() -> string | nil)
function M.keys(m)
  local ks = {} --[[: string[] ]]
  for key, it in pairs(m.map) do
    if not it.deleted then table.insert(ks, key) end
  end
  local i = 0
  return function()
    i = i + 1
    return ks[i]
  end
end

-- Stateful iterator over non-deleted (key, value) pairs:
-- `for k, v in map.entries(m) do ... end`.
--: (m: SharedType) -> (() -> (string, unknown) | nil)
function M.entries(m)
  local ks = {} --[[: string[] ]]
  local vs = {} --[[: unknown[] ]]
  for key, it in pairs(m.map) do
    if not it.deleted then
      table.insert(ks, key)
      table.insert(vs, value_of(it))
    end
  end
  local i = 0
  return function()
    i = i + 1
    local k = ks[i]
    if k == nil then return nil end
    return k, vs[i]
  end
end

return M
