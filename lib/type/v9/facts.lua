-- lib/type/v9/facts.lua
-- Narrowing / facts seam — flow facts over de-Bruijn places. Immutable-map impl.
-- Proof oracle: increments 13/15 (tifn truthiness / ttypetest type-test
-- narrowing). The minimal slice has no conditionals, so this seam is present but
-- unexercised by the end-to-end path; it exists so that adding `tif`/`tifn`
-- later is a LOCAL change (a fact assumption at the binder + a synth arm), not a
-- cross-cutting one. Immutable: `assume` returns a NEW store, never mutates.

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "immutable"

--: () -> FactStore
function M.empty() return {} end

-- Return a new store with `place` narrowed to `ty` (functional update).
--: (FactStore, integer, Ty) -> FactStore
function M.assume(store, place, ty)
    local next_store = {} --: FactStore
    for k, v in pairs(store) do next_store[k] = v end
    next_store[place] = ty
    return next_store
end

--: (FactStore, integer) -> (Ty | nil)
function M.lookup(store, place)
    return store[place]
end

return M
