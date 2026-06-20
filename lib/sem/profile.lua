-- lib/sem/profile.lua
-- The Profile record. A Profile is (desugar, value-algebra, enabled-rule-set,
-- typing-delta) per docs/typechecker-formal-semantics.md §3 — version AND
-- language are the SAME parameter type. S1 ships exactly ONE profile: luajit51.
-- S2 adds PUC 5.1–5.4 (starting with the 5.3 int/float split as the proving
-- case for the parametric value algebra) as MORE profiles, never as branches in
-- the trusted reducer.
--
-- For S1 the Profile carries the value algebra and a name. The desugar lives in
-- lang/lua/lower.lua (selected per profile in S2); the enabled-rule-set and
-- typing-delta are S2 concerns (S1 enables the whole core fragment). step.lua
-- reads only `{ name, va }` off the profile, so the shape is forward-compatible.

local value = require("lib.sem.value")

--:: require "lib.sem.value"

local M = {}

--:: Profile = { name: string, va: ValueAlgebra }

-- The sole S1 profile: vendored LuaJIT 5.1. One number kind (IEEE double); no
-- int/float split (that is S2's first version delta).
M.luajit51 = { name = "luajit51", va = value.luajit51 } --[[: Profile]]

return M
