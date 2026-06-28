-- lib/type/v9/subtype/reflexive.lua
-- Subtyping decider seam — SECOND backend (trivial), proving the decider seam
-- is genuinely hot-swappable. It commits to "sub" ONLY when certain (equality
-- or a primitive-atom base-order step) and defers everything else as "unknown".
-- It is sound (never a wrong commitment) but maximally imprecise — exactly the
-- kind of independent realization the dual-engine parity discipline cross-checks
-- against `structural`. Mirrors the proof's reflexivity (ssub_refl) only.

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "reflexive"

--: (TypeRep, Ty, Ty) -> Decision
function M.decide(rep, a, b)
    if rep.equal(a, b) then return "sub" end
    if rep.kind(a) == "atom" and rep.kind(b) == "atom" then
        local na = rep.atom_name(a)
        local nb = rep.atom_name(b)
        if na == nb then return "sub" end
        if na == "int" and (nb == "num" or nb == "float") then return "sub" end
    end
    return "unknown"
end

return M
