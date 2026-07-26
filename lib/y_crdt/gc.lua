if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- GC struct: a tombstoned run of clocks whose content has been discarded
-- entirely (cheaper than an Item + ContentDeleted). Mirrors yjs
-- structs/GC.js. Lives in the same per-client struct arrays as Item and
-- Skip inside StructStore -- `kind` is how struct_store.lua tells them apart
-- without a require() cycle back to this module... it still requires this
-- one, but this one requires nothing back, so no cycle.

local id = require("lib.y_crdt.id")

local M = {}

--:: Gc = { kind: "gc", id: Id, length: integer, deleted: true }

--: (iid: Id, length: integer) -> Gc
function M.new(iid, length)
  return { kind = "gc", id = iid, length = length, deleted = true }
end

-- Matches yjs `GC.prototype.mergeWith`. yjs's version takes `GC|Skip|Item`
-- and checks `this.constructor === right.constructor` at runtime because JS
-- has no static struct-kind check; here the parameter is statically `Gc`,
-- so that check is the type signature itself -- a caller holding a Skip or
-- Item cannot pass it as `right` without the typechecker rejecting it.
--: (left: Gc, right: Gc) -> boolean
function M.merge_with(left, right)
  left.length = left.length + right.length
  return true
end

-- Splits `g` at `diff`, mutating `g` to the left part and returning the
-- right part as a new Gc.
--: (g: Gc, diff: integer) -> Gc
function M.splice(g, diff)
  local right = M.new(id.new(g.id.client, g.id.clock + diff), g.length - diff)
  g.length = diff
  return right
end

return M
