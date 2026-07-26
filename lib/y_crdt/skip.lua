if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Skip struct: a placeholder in a per-client struct array marking a clock
-- range whose contents are not yet known locally (used for sparse updates,
-- e.g. receiving client 5's clocks 10-20 before clocks 0-9 have arrived).
-- Mirrors yjs structs/Skip.js. Not deleted, not countable, and never
-- integrated into a shared type's linked list -- it is purely a struct-store
-- bookkeeping placeholder until the missing range arrives and
-- StructStore.add replaces it (see struct_store.lua).

local id = require("lib.y_crdt.id")

local M = {}

--:: Skip = { kind: "skip", id: Id, length: integer, deleted: false }

--: (iid: Id, length: integer) -> Skip
function M.new(iid, length)
  return { kind = "skip", id = iid, length = length, deleted = false }
end

-- Matches yjs `Skip.prototype.mergeWith`. See gc.lua's `merge_with` comment
-- on why this doesn't need a runtime kind check like the JS version.
--: (left: Skip, right: Skip) -> boolean
function M.merge_with(left, right)
  left.length = left.length + right.length
  return true
end

--: (s: Skip, diff: integer) -> Skip
function M.splice(s, diff)
  local right = M.new(id.new(s.id.client, s.id.clock + diff), s.length - diff)
  s.length = diff
  return right
end

return M
