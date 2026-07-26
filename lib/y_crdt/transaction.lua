if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Batches the effects of a Doc mutation. Mirrors the parts of yjs's
-- Transaction that this core data model needs: tracking newly-integrated
-- items and newly-deleted items so a caller can compact and (later) emit an
-- update event once the mutation finishes.
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

local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")

local M = {}

-- Captured via `typeof` from item.lua's own constructor (see id.lua/
-- content.lua/item.lua for the same pattern) so this file's `Item` is
-- exactly item.lua's, not a hand-restated approximation.
local sample_id = id.new(0, 0)
local sample_item = item.new(sample_id, nil, nil, nil, nil, content.deleted(0))
--:: Item = typeof sample_item

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

return M
