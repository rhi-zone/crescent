if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- YATA Item: the fundamental insertion-operation unit. Ports yjs's
-- structs/Item.js data shape and per-item operations (split, mergeWith,
-- delete). The conflict-resolution walk (`integrate`) lives in
-- lib/y_crdt/integrate.lua, not here -- it needs both Item and StructStore,
-- and putting it in either would create a require() cycle (StructStore's
-- get_item_clean_start/end need to call Item.split, and integrate needs
-- StructStore to look up neighbors and origins).
--
-- `left`/`right` are live pointers to current neighbors (mutated as the
-- document changes). `origin`/`origin_right` are the *ids* of the neighbors
-- at the time this item was created -- they never change after
-- construction, and are what makes YATA's ordering deterministic across
-- replicas that received concurrent inserts in different orders.

local content = require("lib.y_crdt.content")
local shared_type = require("lib.y_crdt.shared_type")

local M = {}

--:: Id = { client: integer, clock: integer }

-- Structurally identical to content.lua's `Content` and shared_type.lua's
-- `SharedType` aliases. `typeof` (docs/typechecker-reference.md) only
-- captures a plain identifier binding's type, not a call expression, so it
-- can't reach across the require() boundary here without introducing a
-- throwaway local just to hold a sample value -- restating the same
-- structural shape is the more direct option. These are structural types
-- (not FFI cdefs, which is what CLAUDE.md's "never duplicate type
-- definitions" rule targets), so restating the shape is not a divergence
-- risk: the typechecker unifies structurally, and content.lua/
-- shared_type.lua remain the sole source of the *values*.
--:: Content = { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string }
--:: SharedType = { type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }

-- `parent` is the SharedType this item is inserted into, or nil (see
-- integrate.lua's GC branch, for an item whose parent was garbage
-- collected before it arrived). `parent_sub` is the Map key, or nil for
-- sequence types. `keep`, if true, means never garbage-collect this item.
--:: Item = {
--::   kind: "item",
--::   id: Id,
--::   origin: Id | nil,
--::   origin_right: Id | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedType | nil,
--::   parent_sub: string | nil,
--::   content: Content,
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }

--:: Transaction = { doc: unknown, new_items: Item[], deleted_items: Item[] }

-- Matches yjs `compareIDs`.
--: (a: Id | nil, b: Id | nil) -> boolean
local function id_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  return a.client == b.client and a.clock == b.clock
end
M.id_equal = id_equal

--: (client: integer, clock: integer) -> Id
local function id_new(client, clock)
  return { client = client, clock = clock }
end
M.id_new = id_new

-- Matches yjs `Item.prototype.lastId`: the id of this item's final clock
-- slot, given its run-length `length`.
--: (it: Item) -> Id
function M.last_id(it)
  if it.length == 1 then return it.id end
  return id_new(it.id.client, it.id.clock + it.length - 1)
end

--: (iid: Id, origin: Id | nil, origin_right: Id | nil, parent: SharedType | nil, parent_sub: string | nil, c: Content) -> Item
function M.new(iid, origin, origin_right, parent, parent_sub, c)
  return {
    kind = "item",
    id = iid,
    origin = origin,
    origin_right = origin_right,
    left = nil,
    right = nil,
    parent = parent,
    parent_sub = parent_sub,
    content = c,
    length = content.length(c),
    deleted = false,
    keep = false,
  } --[[: Item]]
end

--: (it: Item) -> boolean
function M.is_countable(it)
  return content.is_countable(it.content)
end

--: (it: Item) -> boolean
function M.is_deleted(it)
  return it.deleted
end

-- Splits `it` at `offset` (0-indexed count of countable units kept on the
-- left side). Mutates `it` to hold the left part and returns a new Item
-- holding the right part, wired into the existing left/right linked list
-- (matches yjs `Item.prototype.split`, minus the `redone`/undo-manager
-- bookkeeping -- UndoManager is not part of this core data model).
--: (it: Item, offset: integer) -> Item | (nil, string)
function M.split(it, offset)
  local right_content, err = content.splice(it.content, offset)
  if right_content == nil then return nil, err or "content split failed" end

  local right_len = content.length(right_content)
  local right = {
    kind = "item",
    id = id_new(it.id.client, it.id.clock + offset),
    origin = id_new(it.id.client, it.id.clock + offset - 1),
    origin_right = it.origin_right,
    left = it,
    right = it.right,
    parent = it.parent,
    parent_sub = it.parent_sub,
    content = right_content,
    length = right_len,
    deleted = it.deleted,
    keep = it.keep,
  } --[[: Item]]

  if it.right ~= nil then
    it.right.left = right
  end
  if right.parent_sub ~= nil and right.right == nil and right.parent ~= nil then
    right.parent.map[right.parent_sub] = right
  end

  it.right = right
  it.length = offset
  return right
end

-- Tries to merge `right` into `left` (matches yjs `Item.prototype.mergeWith`
-- minus search-marker and redone/undo bookkeeping, which belong to the
-- YArray/YText cursor cache and UndoManager respectively -- neither exists
-- in this core data model yet). Mutates `left` and returns whether the
-- merge happened; `right` is expected to be dropped from the struct store
-- by the caller when this returns true.
--: (left: Item, right: Item) -> boolean
function M.merge_with(left, right)
  if id_equal(right.origin, M.last_id(left))
    and left.right == right
    and id_equal(left.origin_right, right.origin_right)
    and left.id.client == right.id.client
    and left.id.clock + left.length == right.id.clock
    and left.deleted == right.deleted
    and content.merge_with(left.content, right.content) then
    if right.keep then left.keep = true end
    left.right = right.right
    if left.right ~= nil then
      left.right.left = left
    end
    left.length = left.length + right.length
    return true
  end
  return false
end

-- Marks `it` deleted, adjusts its parent's visible length, and records it on
-- the transaction (matches yjs `Item.prototype.delete`, minus recursive
-- content deletion for ContentType/ContentDoc children -- nested shared
-- types are not implemented yet; see TODO.md).
--: (txn: Transaction, it: Item) -> nil
function M.delete(txn, it)
  if not it.deleted then
    local parent = it.parent
    if it.parent_sub == nil and content.is_countable(it.content) and parent ~= nil then
      parent.length = parent.length - it.length
    end
    it.deleted = true
    table.insert(txn.deleted_items, it)
  end
end

return M
