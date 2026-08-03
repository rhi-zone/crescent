-- lib/null/init.lua — the shared null sentinel.
--
-- Lua has no value distinct from absence: a table field holding `nil` and a
-- table field that was never set are indistinguishable, and `pairs()` cannot
-- observe either. Any data model that must carry an explicit null — JSON's
-- `null`, a type-ir `literal` whose value is null, a database NULL — needs a
-- stand-in value that is not `nil`. This module is that value.
--
-- Identity is the whole point: `M.null` is one table, allocated once, and
-- callers test with `v == null.null`. Two libraries that each made their own
-- private `{}` sentinel could not exchange data, because their sentinels
-- would compare unequal. That is why this module exists as a shared module
-- rather than a per-library constant.
--
-- Usage:
--   local null = require("lib.null")
--   if v == null.null then ... end          -- an explicit null
--   local record = { field = null.null }     -- distinct from `field = nil`
--
-- The sentinel is an empty table, which means it is truthy — `if v then` is
-- NOT a null test. Compare by identity.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- The sentinel. An empty table whose identity, not contents, carries the
-- meaning. Never mutate it and never copy it: a copy is a different table and
-- compares unequal to this one.
M.null = {}

return M
