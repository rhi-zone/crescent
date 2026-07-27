if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Batches the effects of a Doc mutation. Mirrors the parts of yjs's
-- Transaction that this core data model needs: tracking newly-integrated
-- items and newly-deleted items so `M.cleanup` can compact them once the
-- mutation finishes, and (later) so a caller can emit an update event.
--
-- SCOPE: yjs's real Transaction also carries an insert id-set (for skipping
-- already-known items when merging concurrent inserts into a delete-set),
-- a delete-set keyed by client+clock ranges (for wire encoding), subdoc
-- tracking, and a `changed` map for observers. None of those are built yet
-- -- delete tracking here is a flat list of Items, sufficient for in-memory
-- correctness but not yet a wire-ready range-compacted delete-set. See
-- TODO.md: encoding.lua's sync-protocol bridge will need a real delete-set.
--
-- `new_items`/`deleted_items` are plain fields, not accessed through
-- getters -- `lib/y_crdt/integrate.lua` and `item.lua`'s `delete` write to
-- them directly (avoiding a require() cycle back to this module). This
-- module's `add_item`/`delete_item` are the documented, friendly entry
-- points for callers who aren't already inside the integrate/delete
-- algorithms.
--
-- `M.cleanup` implements the two transaction-cleanup passes yjs's
-- `cleanupTransactions` performs (`src/utils/Transaction.js`, verified
-- against `node_modules/yjs/dist/yjs.cjs`, tag v13.6.31):
--
--   1. GC (only when `gc_enabled`): every item in `deleted_items` that
--      isn't `.keep` gets its content replaced with a bare
--      `content.deleted(length)` placeholder (`tryGcDeleteSet` + `Item.gc`
--      with `parentGCd=false` -- this port has no recursive ContentType/
--      ContentDoc child deletion, so `parentGCd` is never true here; see
--      TODO.md's existing ContentType/ContentDoc scope cut).
--   2. Merge (`tryToMergeWithLefts`, unconditional): for every client
--      touched by this transaction (a new item or a deleted item),
--      right-to-left across that client's ENTIRE struct array, merging any
--      adjacent same-client/same-deleted-state/mergeable-content pair into
--      one Item.
--
-- Upstream runs three narrower passes instead of one full-array sweep per
-- touched client (`tryGcDeleteSet`+`tryMergeDeleteSet` keyed off the
-- delete-set, a `beforeState`-vs-`afterState` sweep keyed off state
-- advancement, and a `_mergeStructs` retry list for items produced by a
-- split during this transaction). This port doesn't track a delete-set,
-- before/after state, or a split-retry list -- instead it re-sweeps each
-- touched client's whole array. This is behaviorally equivalent, not an
-- approximation: `merge_with`'s conditions are purely pairwise-local
-- (adjacent array position + linked-list adjacency + matching deleted
-- state + mergeable content), so the maximal-merge fixed point for a
-- client's array does not depend on which subset of positions triggered
-- the sweep -- untouched regions are already maximally merged (that
-- invariant holds after every prior cleanup), so re-checking them is a
-- guaranteed no-op, not a source of drift. `M._try_merge_with_lefts`
-- itself is a direct, faithful port of `tryToMergeWithLefts` -- a single
-- call at the rightmost position of a mergeable run cascades leftward
-- through the whole run in one pass, exactly like upstream.

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local gc = require("lib.y_crdt.gc")
local skip = require("lib.y_crdt.skip")

local M = {}

-- Captured via `typeof` from item.lua's own constructor (see id.lua/
-- content.lua/item.lua for the same pattern) so this file's `Item` is
-- exactly item.lua's, not a hand-restated approximation.
local sample_id = id.new(0, 0)
local sample_item = item.new(sample_id, nil, nil, nil, nil, content.deleted(0))
--:: Item = typeof sample_item

-- Captured via `typeof` from gc.lua's/skip.lua's own constructors, matching
-- struct_store.lua's own `GcT`/`SkipT` captures exactly (needed here too
-- since `M.cleanup`/`try_merge_with_lefts` walk raw struct arrays, not just
-- Items).
local sample_gc = gc.new(sample_id, 1)
--:: GcT = typeof sample_gc
local sample_skip = skip.new(sample_id, 1)
--:: SkipT = typeof sample_skip

-- TYPECHECKER WORKAROUND: `Struct`/`StructStore` are hand-declared here
-- (structurally identical to struct_store.lua's own declarations) instead
-- of captured via `typeof` from `struct_store.new()`, unlike `GcT`/`SkipT`
-- just above -- same root cause as integrate.lua's own `Item`/`SharedType`
-- hand-restatement (see that file's comment for the fuller repro):
-- `StructStore.clients`' element type `Struct[]` includes `Item`, which is
-- self-referential (`Item.left`/`.right: Item | nil`), and a
-- `typeof`-captured record loses precision on ITS OWN nested fields once
-- self-reference is involved anywhere inside it -- confirmed here directly:
-- indexing `store.clients[client]` on a `typeof`-captured `StructStore`
-- silently degraded to `any` ("inference fell back to any"), even before
-- reaching any recursive field, while the identical index expression
-- inside struct_store.lua itself (using ITS OWN natively-declared
-- `StructStore`, never round-tripped through `typeof`) has zero warnings.
-- Hand-restating the shape here (structurally identical to
-- struct_store.lua's own, which remains the sole source of the *values*)
-- avoids the round-trip. TODO.md tracks collapsing this back to `typeof`
-- once recursive-type capture is fixed upstream (already tracked there for
-- integrate.lua's copy of this workaround).
--:: Struct = Item | GcT | SkipT
--:: StructStore = { clients: { [number]: Struct[] } }

--:: Transaction = { doc: unknown, new_items: Item[], deleted_items: Item[] }

--: (doc: unknown) -> Transaction
function M.new(doc)
  return { doc = doc, new_items = {}, deleted_items = {} } --[[: Transaction]]
end

--: (txn: Transaction, it: Item) -> nil
function M.add_item(txn, it)
  table.insert(txn.new_items, it)
end

--: (txn: Transaction, it: Item) -> nil
function M.delete_item(txn, it)
  item.delete(txn, it)
end

-- TYPECHECKER WORKAROUND: indexing `store.clients[client]` (an index
-- signature field) infers `any` at the two call sites below (`inference
-- fell back to any` warnings), the same gap struct_store.lua's own
-- `as_structs` works around (see that comment for the fuller repro).
-- Routing the lookup through this identity function resets whatever
-- provenance tag causes that. The natural code would index
-- `store.clients[client]` directly with no extra call. TODO.md tracks
-- removing this once that narrowing bug is fixed upstream (already tracked
-- there for struct_store.lua's own copy of this workaround).
--: (structs: Struct[]) -> Struct[]
local function as_structs(structs)
  return structs
end

-- Removes the `count` structs starting at `from` from `structs`, shifting
-- everything after them down and truncating. Used instead of
-- `table.remove` in a loop: `table.remove`'s stdlib signature requires
-- `{ [integer]: T }`, but a struct array reached through `StructStore`'s
-- `{ [number]: Struct[] }` index signature (struct_store.lua's own
-- declaration) types as `{ [number]: Struct }`, and `number` doesn't
-- satisfy that. The natural code would be `table.remove(structs, from)`
-- called `count` times.
--: (structs: Struct[], from: integer, count: integer) -> nil
local function remove_range(structs, from, count)
  local n = #structs
  for k = from, n - count do
    structs[k] = structs[k + count]
  end
  for k = n - count + 1, n do
    structs[k] = nil
  end
end

-- Matches yjs `tryToMergeWithLefts`: tries to merge `structs[pos]` into its
-- left neighbor, and -- on success -- keeps cascading leftward (the
-- survivor against ITS left neighbor, and so on) until a merge fails or the
-- start of the array is reached. Removes every absorbed struct from
-- `structs`. Returns how many structs were merged away.
--: (store: StructStore, client: number, pos: integer) -> integer
local function try_merge_with_lefts(store, client, pos)
  local structs0 = store.clients[client]
  if structs0 == nil then return 0 end
  local structs = as_structs(structs0)
  local i = pos
  while i > 1 do
    local left = structs[i - 1]
    local right = structs[i]
    if left.kind == "item" and right.kind == "item" and left.deleted == right.deleted then
      local l = left --[[: Item]]
      local r = right --[[: Item]]
      if item.merge_with(l, r) then
        i = i - 1
      else
        break
      end
    else
      break
    end
  end
  local merged = pos - i
  if merged > 0 then
    remove_range(structs, i + 1, merged)
  end
  return merged
end
M._try_merge_with_lefts = try_merge_with_lefts

-- Post-transaction cleanup (matches yjs's `cleanupTransactions` finally
-- block -- see the module header for the exact mapping and why a full
-- per-touched-client sweep is behaviorally equivalent to upstream's three
-- narrower passes). `gc_enabled` mirrors `Doc.gc` (yjs default: true).
--: (txn: Transaction, store: StructStore, gc_enabled: boolean) -> nil
function M.cleanup(txn, store, gc_enabled)
  if gc_enabled then
    for _, it in ipairs(txn.deleted_items) do
      if not it.keep and it.content.kind ~= "deleted" then
        it.content = content.deleted(it.length)
      end
    end
  end

  local touched = {} --[[: { [number]: boolean } ]]
  for _, it in ipairs(txn.new_items) do touched[it.id.client] = true end
  for _, it in ipairs(txn.deleted_items) do touched[it.id.client] = true end

  for client in pairs(touched) do
    local structs0 = store.clients[client]
    if structs0 ~= nil then
      local structs = as_structs(structs0)
      local i = #structs
      while i > 1 do
        local merged = try_merge_with_lefts(store, client, i)
        i = i - 1 - merged
      end
    end
  end
end

return M
