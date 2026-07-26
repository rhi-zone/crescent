if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- The YATA conflict-resolution algorithm: integrates a newly-created Item
-- into its parent shared type's linked list, deterministically ordered
-- against any concurrently-inserted items so that every replica converges
-- to the same sequence regardless of delivery order.
--
-- This is a line-for-line port of yjs's `Item.prototype.integrate`
-- (src/structs/Item.js, fetched from github.com/yjs/yjs main branch during
-- this work) -- NOT a reimplementation from the English sketch of "compare
-- origins, lower client id goes left". That sketch is a simplification;
-- the actual algorithm tracks two sets while walking right from the left
-- neighbor (`conflictingItems`, `itemsBeforeOrigin`) and has two distinct
-- comparison cases (same origin vs. transitive origin-before-origin), not
-- one. Reimplementing from the paraphrase risked silent wire-incompatible
-- divergence, which is exactly what this port is required to avoid -- see
-- the task's "must be EXACTLY correct" requirement. Kept in its own module
-- (rather than item.lua or struct_store.lua) because it needs both Item and
-- StructStore, and either of those requiring the other back would be a
-- require() cycle.
--
-- SCOPE cut from the yjs source, all deliberate and non-semantic to
-- ordering: no search-marker maintenance (perf cache for YArray/YText
-- indexing), no `transaction.insertSet`/`addChangedTypeToTransaction`
-- (observer/gc bookkeeping), no ContentType/ContentDoc child-integration
-- callback (nested shared types aren't implemented yet -- see TODO.md), and
-- offset-based re-entry (the `offset > 0` branch) is kept because
-- StructStore's clean-start/clean-end splitting depends on it being
-- correct, even though nothing in this task's test surface exercises it via
-- a decoder yet.

local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local struct_store = require("lib.y_crdt.struct_store")
local gc = require("lib.y_crdt.gc")

local M = {}

-- StructStore is non-recursive, so `typeof` (see struct_store.lua) captures
-- it exactly with no issue.
local sample_store = struct_store.new()
--:: StructStore = typeof sample_store

-- TYPECHECKER WORKAROUND: `Item` and its `SharedType` (mutually
-- self-referential: Item.parent is a SharedType, SharedType.start/map/item
-- are Items) are hand-declared here instead of captured via `typeof` from
-- item.lua/shared_type.lua, unlike `StructStore` just above. Confirmed with
-- a minimal repro: a `typeof`-captured self-referential record type (e.g.
-- `--:: Item = typeof sample_item` where `sample_item.left` is `Item |
-- nil`) loses precision on its own recursive fields -- `i.left`, `i.left.
-- right`, etc. all silently degrade to `any` ("inference fell back to
-- any"), even though the exact same field access on item.lua's *natively
-- declared* `Item` (not round-tripped through typeof) type-checks with zero
-- warnings. Hand-restating the shape here (structurally identical to
-- item.lua's own, which remains the sole source of the *values*) avoids
-- the round-trip and keeps the fields precise. TODO.md tracks collapsing
-- this back to `typeof` once recursive-type capture is fixed upstream.
--:: SharedType = { type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: Item = {
--::   kind: "item",
--::   id: { client: integer, clock: integer },
--::   origin: { client: integer, clock: integer } | nil,
--::   origin_right: { client: integer, clock: integer } | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedType | nil,
--::   parent_sub: string | nil,
--::   content: { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string },
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }
--:: Transaction = { doc: { store: StructStore }, new_items: Item[], deleted_items: Item[] }

-- Integrates `it` into its parent (`it.parent`, a SharedType from
-- shared_type.lua) via txn.doc.store. `offset` re-enters integration
-- partway through `it` (used when a Skip placeholder for `it` was already
-- partially superseded); pass 0 (or omit) for a freshly created item.
--: (txn: Transaction, i: Item, offset: integer | nil) -> true | (nil, string)
function M.integrate(txn, i, offset)
  offset = offset or 0
  local store = txn.doc.store

  if offset > 0 then
    i.id = item.id_new(i.id.client, i.id.clock + offset)
    local left, err = struct_store.get_item_clean_end(store, item.id_new(i.id.client, i.id.clock - 1))
    if left == nil then return nil, err or "integrate: get_item_clean_end failed" end
    i.left = left
    i.origin = item.last_id(left)
    local spliced, sperr = content.splice(i.content, offset)
    if spliced == nil then return nil, sperr or "integrate: content splice failed" end
    i.content = spliced
    i.length = i.length - offset
  end

  -- Resolve `left`/`right` from `origin`/`origin_right` before the conflict
  -- search below, matching yjs's `getMissing` (src/utils/encoding.js): a
  -- fresh Item's `left`/`right` pointers are nil until this step looks up
  -- the actual neighbor Items by id. Skipped when `left`/`right` are
  -- already set (e.g. by the `offset > 0` re-entry above, or when the
  -- caller already resolved them) -- yjs's version has the same guard
  -- implicitly, since it only assigns when the corresponding id is present.
  local origin0 = i.origin
  if i.left == nil and origin0 ~= nil then
    local left, lerr = struct_store.get_item_clean_end(store, origin0)
    if left == nil then return nil, lerr or "integrate: origin resolution failed" end
    i.left = left
    i.origin = item.last_id(left)
  end
  local origin_right0 = i.origin_right
  if i.right == nil and origin_right0 ~= nil then
    local right, rerr = struct_store.get_item_clean_start(store, origin_right0)
    if right == nil then return nil, rerr or "integrate: origin_right resolution failed" end
    i.right = right
    i.origin_right = right.id
  end

  -- TYPECHECKER WORKAROUND: `i.parent` is captured into `parent0` before
  -- the nil guard rather than re-read as `i.parent` after it. Confirmed
  -- with a minimal repro: `if f.x == nil then return end; local y = f.x`
  -- still treats `f.x` as `T | nil` on the second read even though the
  -- guard already returned on nil -- field-narrowing does not persist a
  -- `return`-inside-`if` guard clause the way narrowing a bare local does
  -- (`if x == nil then return end; return x` DOES narrow `x` correctly).
  -- The natural code would just guard on `i.parent` and use `i.parent`
  -- (or `parent`, an alias of it) afterward. TODO.md tracks removing this
  -- indirection once field-narrowing survives guard clauses upstream.
  local parent0 = i.parent
  if parent0 == nil then
    -- No parent to attach to: this item's effect is discarded and only its
    -- clock range is retained, as a Gc struct (matches yjs: `new
    -- GC(this.id, this.length).integrate(...)`).
    local ok, add_err = struct_store.add(store, gc.new(i.id, i.length))
    if ok == nil then return nil, add_err or "integrate: gc add failed" end
    return true
  end

  local parent = parent0

  local needs_conflict_search = (i.left == nil and (i.right == nil or i.right.left ~= nil))
    or (i.left ~= nil and i.left.right ~= i.right)

  if needs_conflict_search then
    local left = i.left
    local o
    if left ~= nil then
      o = left.right
    elseif i.parent_sub ~= nil then
      o = parent.map[i.parent_sub]
      while o ~= nil do
        if o.left == nil then break end
        o = o.left
      end
    else
      o = parent.start
    end

    -- Let c in conflicting_items, b in items_before_origin.
    -- ***{origin}bbbb{it}{c,b}{c,b}{o}***
    -- conflicting_items is a subset of items_before_origin.
    local conflicting_items = {} --[[: { [unknown]: boolean } ]]
    local items_before_origin = {} --[[: { [unknown]: boolean } ]]
    while o ~= nil and o ~= i.right do
      items_before_origin[o] = true
      conflicting_items[o] = true
      if item.id_equal(i.origin, o.origin) then
        -- case 1: this and o were both inserted with the same left neighbor.
        if o.id.client < i.id.client then
          left = o
          conflicting_items = {}
        elseif item.id_equal(i.origin_right, o.origin_right) then
          -- this and o point to the same integration points on both sides;
          -- id order decides, and this is already to the left of o.
          break
        end
        -- else: o might be integrated before an item this conflicts with;
        -- keep walking.
      else
        local resolved = false
        if o.origin ~= nil then
          local origin_item, oerr = struct_store.find(store, o.origin)
          if origin_item == nil then return nil, oerr or "integrate: origin lookup failed" end
          if items_before_origin[origin_item] then
            resolved = true
            -- case 2: o's origin was already visited (transitively before
            -- our origin).
            if not conflicting_items[origin_item] then
              left = o
              conflicting_items = {}
            end
          end
        end
        if not resolved then
          break
        end
      end
      o = o.right
    end
    i.left = left
  end

  -- Reconnect left/right and update the parent's linked-list head / map.
  if i.left ~= nil then
    local right = i.left.right
    i.right = right
    i.left.right = i
  else
    local r
    if i.parent_sub ~= nil then
      r = parent.map[i.parent_sub]
      while r ~= nil do
        if r.left == nil then break end
        r = r.left
      end
    else
      r = parent.start
      parent.start = i
    end
    i.right = r
  end

  if i.right ~= nil then
    i.right.left = i
  elseif i.parent_sub ~= nil then
    -- No right neighbor and this is a Map entry: it is now the current
    -- value for that key. The previous value (if any, to the left) is
    -- superseded and deleted.
    parent.map[i.parent_sub] = i
    local superseded = i.left
    if superseded ~= nil then
      item.delete(txn, superseded)
    end
  end

  if i.parent_sub == nil and content.is_countable(i.content) and not i.deleted then
    local parent_len = parent.length --[[: number]]
    local i_len = i.length --[[: integer]]
    parent.length = parent_len + i_len
  end

  table.insert(txn.new_items, i)
  local ok, add_err = struct_store.add(store, i)
  if ok == nil then return nil, add_err or "integrate: add failed" end

  local parent_item = parent.item
  if (parent_item ~= nil and parent_item.deleted) or (i.parent_sub ~= nil and i.right ~= nil) then
    -- Parent got deleted concurrently, or this insert is a superseded Map
    -- value written before a later concurrent write: delete on arrival.
    item.delete(txn, i)
  end

  return true
end

return M
