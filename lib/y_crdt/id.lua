if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- YATA/yjs struct identifier: a (client, clock) pair.
-- client is a per-replica random number; clock is a monotonically increasing
-- per-client counter. Both fit in a Lua double (53-bit integer precision),
-- matching yjs's use of JS numbers for both fields.

local M = {}

--:: Id = { client: integer, clock: integer }

--: (client: integer, clock: integer) -> Id
function M.new(client, clock)
  return { client = client, clock = clock }
end

-- Matches yjs `compareIDs`: identity-equal, or both non-nil with equal fields.
--: (a: Id | nil, b: Id | nil) -> boolean
function M.equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  return a.client == b.client and a.clock == b.clock
end

return M
