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
-- `ParentPendingId`/`SharedType.kind` mirror item.lua's/shared_type.lua's
-- own additions (built alongside lib/y_crdt/update.lua, the wire decoder, in
-- parallel with this file): a wire-decoded item can name its parent by the
-- id of another Item whose content is a nested Type, instead of a resolved
-- SharedType directly (yjs writes `writeLeftID(parentItem.id)` when the
-- parent isn't a root type). `kind` on SharedType exists so this 3-way
-- union (SharedType | ParentPendingId | nil) can be narrowed by
-- field-discriminant instead of an unprovable checked cast -- ParentPendingId
-- has no other field in common with SharedType, so without a shared `kind`
-- tag neither variant could be told apart from the other structurally.
--:: ParentPendingId = { kind: "pending_parent_id", client: integer, clock: integer }
--:: SharedType = { kind: "shared_type", type_name: string, start: Item | nil, map: { [string]: Item }, length: number, item: Item | nil }
--:: Item = {
--::   kind: "item",
--::   id: { client: integer, clock: integer },
--::   origin: { client: integer, clock: integer } | nil,
--::   origin_right: { client: integer, clock: integer } | nil,
--::   left: Item | nil,
--::   right: Item | nil,
--::   parent: SharedType | ParentPendingId | nil,
--::   parent_sub: string | nil,
--::   content: { kind: "deleted", ref: integer, len: integer } | { kind: "string", ref: integer, str: string } | { kind: "json", ref: integer, arr: unknown[] } | { kind: "embed", ref: integer, embed: unknown } | { kind: "any", ref: integer, arr: unknown[] } | { kind: "format", ref: integer, key: string, value: unknown } | { kind: "type", ref: integer, shared_type: unknown } | { kind: "doc", ref: integer, guid: string, opts: unknown } | { kind: "binary", ref: integer, bytes: string },
--::   length: integer,
--::   deleted: boolean,
--::   keep: boolean,
--:: }
--:: Transaction = { doc: { store: StructStore }, new_items: Item[], deleted_items: Item[] }

-- A struct resolved from an origin/origin_right lookup can be an Item or a
-- Gc (see struct_store.lua's `get_clean_start`/`get_clean_end`, added
-- alongside this file's parent-resolution work for exactly this case).
--:: Gc = { kind: "gc", id: { client: integer, clock: integer }, length: integer, deleted: true }
--:: ResolvedNeighbor = Item | Gc

-- TYPECHECKER WORKAROUND: a value typed `SharedType | ParentPendingId |
-- nil`, once assigned to a local that a *sibling* `if`/`elseif` branch also
-- reassigns, loses narrowing precision in ways that show up at two
-- distinct points below, each needing its own fix (confirmed both with
-- minimal repros isolating this exact if/elseif shape):
--
-- 1. Reading `i.parent` straight into a local (`local parent0 = i.parent`)
--    fails to narrow `parent0.client`/`parent0.clock` inside this file's
--    `elseif parent0.kind == "pending_parent_id"` branch, even on the very
--    next line of that same branch -- even though that branch's own guard
--    should determine `parent0`'s type independently of what a *different*
--    branch (the `parent0 == nil` one, which also reassigns `parent0`)
--    does. Routing the read through `identity_parent` below fixes this one
--    (matches the more common field-read-narrowing bug already documented
--    in item.lua/struct_store.lua).
-- 2. Separately, by the time `parent0`'s if/elseif chain finishes and it's
--    used afterward (`M.integrate` below), `identity_parent` alone no
--    longer helps -- what works there is moving the final nil-check +
--    invariant-check into its own top-level function taking the union as a
--    plain parameter (`require_resolved_parent`, further below), using two
--    sequential `if`-with-early-return statements rather than one combined
--    condition (matches a separate, already-documented narrowing
--    limitation on combined `and`/`or` conditions -- see item.lua's
--    `M.delete` and struct_store.lua's comments on that one).
--
-- The natural code would read `i.parent` directly with no indirection, and
-- inline the final nil-check + invariant-check where `parent0` is used,
-- with no separate function. TODO.md tracks collapsing both once a value's
-- narrowing precision survives a sibling branch's reassignment.
--: (v: SharedType | ParentPendingId | nil) -> SharedType | ParentPendingId | nil
local function identity_parent(v)
  return v
end

-- Resolves `parent0` (already run through the GC-neighbor / neighbor-
-- inheritance / ParentPendingId-lookup logic in `M.integrate` below) to its
-- final `SharedType | nil`. A live ParentPendingId surviving to this call
-- is an internal invariant violation, not a caller-facing data error: this
-- function is the only place that ever writes a raw ParentPendingId into
-- an Item's `.parent`, and always resolves it (to nil or a concrete
-- SharedType) before that Item is added to the struct store -- so any
-- *already-integrated* neighbor's `.parent` this code inherits from is
-- guaranteed already resolved.
--: (parent0: SharedType | ParentPendingId | nil) -> SharedType | nil
local function require_resolved_parent(parent0)
  if parent0 == nil then
    return nil
  end
  if parent0.kind == "pending_parent_id" then
    error("integrate: unresolved parent id survived resolution (internal invariant violation)", 2)
  end
  return parent0
end

-- Integrates `it` into its parent (`it.parent`, a SharedType from
-- shared_type.lua) via txn.doc.store. `offset` re-enters integration
-- partway through `it` (used when a Skip placeholder for `it` was already
-- partially superseded); pass 0 (or omit) for a freshly created item.
--
-- TYPECHECKER WORKAROUND: declared `(true | nil, string | nil)` -- two
-- separate optional return values -- rather than `true | (nil, string)`
-- (matches the same fix on struct_store.lua's `get_clean_start`/
-- `get_clean_end`/`add` -- see their comments for the minimal repro). Pure
-- annotation change: both branches already return two values at runtime.
--: (txn: Transaction, i: Item, offset: integer | nil) -> (true | nil, string | nil)
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
  -- search below, matching yjs's `Item.prototype.getMissing`
  -- (src/structs/Item.js, verified against github.com/yjs/yjs tag
  -- v13.6.31, fetched 2026-07-27 -- the actual npm `latest`; `main` is an
  -- unreleased 14.0.0-rc rewrite with a different struct architecture and
  -- is not the deployed wire format). Resolved into locals first (NOT
  -- committed to `i.left`/`i.right` yet) because the neighbor can be a Gc
  -- struct: a wire-decoded item's origin can legitimately point into an
  -- already garbage-collected range (yjs's `getItemCleanStart`/
  -- `getItemCleanEnd` are typed `-> Item` in their JSDoc but in practice
  -- return `Item | GC` -- the `struct.constructor !== GC` guard on their
  -- split step is the tell; see struct_store.lua's `get_clean_start`/
  -- `get_clean_end`, added alongside this). When a neighbor is Gc, yjs
  -- nulls out `parent` and this item's own effect is discarded entirely
  -- (the GC-neighbor check just below) without `i.left`/`i.right` ever
  -- being read again -- so they're committed to `i` only once it's known
  -- the neighbor is actually an Item (item.lua's `Item.left`/`.right` are
  -- `Item | nil`, never `Gc`).
  local resolved_left = i.left --[[: ResolvedNeighbor | nil]]
  local origin0 = i.origin
  if resolved_left == nil and origin0 ~= nil then
    local left, lerr = struct_store.get_clean_end(store, origin0)
    if left == nil then return nil, lerr or "integrate: origin resolution failed" end
    resolved_left = left
  end
  local resolved_right = i.right --[[: ResolvedNeighbor | nil]]
  local origin_right0 = i.origin_right
  if resolved_right == nil and origin_right0 ~= nil then
    local right, rerr = struct_store.get_clean_start(store, origin_right0)
    if right == nil then return nil, rerr or "integrate: origin_right resolution failed" end
    resolved_right = right
  end

  -- Parent resolution: the rest of yjs `Item.prototype.getMissing`. A
  -- wire-decoded item's `parent` (and `parentSub`) are omitted from the
  -- wire -- left `nil` here -- whenever origin or origin_right was present,
  -- because they're reconstructible from whichever neighbor resolved to an
  -- Item (`this.parent = this.left.parent; this.parentSub =
  -- this.left.parentSub`, else from `this.right`). This is the common case
  -- for any item with a left/right neighbor, NOT an edge case, and is
  -- distinct from `parent` staying `nil` because the item is genuinely
  -- parentless (which only happens when neither origin nor origin_right
  -- resolved to anything, i.e. `resolved_left`/`resolved_right` are both
  -- nil too). `ParentPendingId` (parent written as another item's id, not a
  -- root type name) is update.lua's placeholder for the remaining case:
  -- `else if (this.parent.constructor === ID) { const parentItem =
  -- getItem(store, this.parent); this.parent = parentItem.constructor ===
  -- GC ? null : parentItem.content.type }`.
  --
  -- TYPECHECKER WORKAROUND: a plain `local parent0 = i.parent` read here
  -- (no indirection) fails to narrow `parent0.client`/`parent0.clock` in
  -- the `elseif parent0.kind == "pending_parent_id"` branch below, even on
  -- the very next line inside that same branch -- confirmed by minimal
  -- repro reproducing this exact if/elseif shape (a sibling branch
  -- reassigns `parent0` from a different expression; that alone is enough
  -- to poison narrowing in this branch, which doesn't touch that
  -- reassignment at all). Routing the field read through this identity
  -- function first fixes it (a distinct fix from `require_resolved_parent`
  -- above, which fixes a different point further down -- both are needed).
  -- The natural code would read `i.parent` directly with no indirection.
  -- TODO.md tracks removing this once this narrowing is fixed upstream.
  local parent0 = identity_parent(i.parent)
  local left_is_gc = resolved_left ~= nil and resolved_left.kind == "gc"
  local right_is_gc = resolved_right ~= nil and resolved_right.kind == "gc"
  if left_is_gc or right_is_gc then
    -- Either neighbor was already garbage-collected: this item's parent is
    -- unrecoverable, so (matching yjs) its own effect is discarded too.
    parent0 = nil
  elseif parent0 == nil then
    if resolved_left ~= nil and resolved_left.kind == "item" then
      parent0 = resolved_left.parent
      i.parent_sub = resolved_left.parent_sub
    elseif resolved_right ~= nil and resolved_right.kind == "item" then
      parent0 = resolved_right.parent
      i.parent_sub = resolved_right.parent_sub
    end
  elseif parent0.kind == "pending_parent_id" then
    local parent_struct, perr = struct_store.get(store, item.id_new(parent0.client, parent0.clock))
    if parent_struct == nil then return nil, perr or "integrate: parent lookup failed" end
    if parent_struct.kind == "gc" then
      parent0 = nil
    elseif parent_struct.kind == "item" then
      local parent_content = parent_struct.content
      if parent_content.kind ~= "type" then
        return nil, "integrate: parent item's content is not a nested type"
      end
      -- CHECKED CAST (not forced): ContentType.shared_type is declared
      -- `unknown` in content.lua specifically to avoid a content.lua <->
      -- shared_type.lua require() cycle (content.lua's `M.type` doc
      -- comment). This is the one trust boundary where that `unknown` is
      -- narrowed back to a concrete SharedType, structurally checked
      -- against the alias above -- not a blind force-cast past an
      -- unnarrowable `unknown`.
      parent0 = parent_content.shared_type --[[: SharedType]]
    else
      -- Struct is a Skip: the referenced parent item hasn't arrived yet.
      -- This port's `integrate` (unlike yjs's two-phase getMissing/apply)
      -- assumes all dependencies are already present when called -- see
      -- this file's SCOPE note -- so this is a caller-facing data error,
      -- not a case this function resolves by waiting.
      return nil, "integrate: parent item not yet available (skip)"
    end
  end

  -- BUG FIX (found via lib/y_crdt/parity_test.lua against real yjs
  -- fixtures): `parent0` above was previously only a local -- the result of
  -- resolving `i.parent` (inherited from a neighbor, resolved from a
  -- pending-parent-id, or nulled by a GC neighbor) was never written back
  -- onto `i.parent` itself. Matches yjs's actual `Item.prototype.getMissing`,
  -- which assigns `this.parent = ...` as a side effect in every one of these
  -- branches (not just locally). Without this, a THIRD item chaining off a
  -- second item that itself inherited its parent this way would find
  -- `resolved_left.parent` still `nil` and be wrongly discarded as GC --
  -- confirmed with a 3-item repro (string item, then a same-transaction
  -- insert+delete collapsed to ContentDeleted, then another string item):
  -- the third item's content silently vanished. This one-line write-back
  -- restores parity; every branch above already computes the exact value
  -- yjs would assign, including the intentional `nil` from the GC-neighbor
  -- case.
  i.parent = parent0

  -- Parent's fate is now known: commit the resolved neighbors into
  -- `i.left`/`i.right` (only reached when parent0 is non-nil -- the
  -- GC-discard path below returns before touching them again).
  if parent0 ~= nil then
    if resolved_left ~= nil and resolved_left.kind == "item" then
      i.left = resolved_left
      i.origin = item.last_id(resolved_left)
    end
    if resolved_right ~= nil and resolved_right.kind == "item" then
      i.right = resolved_right
      i.origin_right = resolved_right.id
    end
  end

  if parent0 == nil then
    -- No parent to attach to: this item's effect is discarded and only its
    -- clock range is retained, as a Gc struct (matches yjs: `new
    -- GC(this.id, this.length).integrate(...)`).
    local ok, add_err = struct_store.add(store, gc.new(i.id, i.length))
    if ok == nil then return nil, add_err or "integrate: gc add failed" end
    return true
  end

  -- See `require_resolved_parent`'s doc comment above for why this is a
  -- separate top-level function rather than an inline nil-check +
  -- invariant-check here.
  local parent = require_resolved_parent(parent0)
  if parent == nil then
    -- `parent0 == nil` was already handled above (the GC-discard `return
    -- true` path) -- reaching a nil result here would mean
    -- `require_resolved_parent` disagreed with that earlier check, which
    -- is itself an internal invariant violation.
    return nil, "integrate: parent resolved to nil unexpectedly (internal invariant violation)"
  end

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
