-- lib/type/v9/subtype/structural.lua
-- Subtyping decider seam — DEFAULT backend: structural, THREE-VALUED.
-- Proof oracle: decide_ssub / ssub (ssub.v), with the atom base order and
-- connective routing from subtype.v. Mirrors the proof's honest-deferral
-- protocol (gdecide's DUnknown, subtype.v increment 6): a definite verdict
-- ("sub"/"notsub") is a proof commitment; deferred shapes return "unknown",
-- NEVER a fail-optimistic guess.
--
-- The decider depends only on the `TypeRep` interface (passed as `rep`), so it
-- is representation-agnostic — DIP both ways: swappable rep AND swappable
-- decider behind the same `SubtypeDecider` contract.

--:: require "lib.type.v9.type_defs"

local M = {}
M.name = "structural"

--: (Decision, Decision) -> Decision
local function and3(x, y)
    if x == "notsub" or y == "notsub" then return "notsub" end
    if x == "sub" and y == "sub" then return "sub" end
    return "unknown"
end

--: (Decision, Decision) -> Decision
local function or3(x, y)
    if x == "sub" or y == "sub" then return "sub" end
    if x == "notsub" and y == "notsub" then return "notsub" end
    return "unknown"
end

-- Record WIDTH subtyping (proof BRec, read open/width): every field required by
-- `b` must be present in `a` at a subtype. Missing key => notsub; field type
-- deferral => unknown. `dec` is the recursive decider (injected to avoid a
-- forward-declared mutable local).
--: (TypeRep, Ty, Ty, (TypeRep, Ty, Ty) -> Decision) -> Decision
local function decide_rec(rep, a, b, dec)
    local fa = rep.rec_fields(a)
    local fb = rep.rec_fields(b)
    local result = "sub" --: Decision
    for i = 1, #fb do
        local key = fb[i].key
        local found = nil --: Ty | nil
        for j = 1, #fa do
            if fa[j].key == key then found = fa[j].type break end
        end
        if found == nil then return "notsub" end
        local d = dec(rep, found, fb[i].type)
        if d == "notsub" then return "notsub" end
        if d == "unknown" then result = "unknown" end
    end
    return result
end

-- Core decision. `dec` is the recursive decider passed explicitly (rather than a
-- self-referencing local) so the annotated return type holds at every recursive
-- call — recursion stays Decision-valued, never nilable.
--: (TypeRep, Ty, Ty, (TypeRep, Ty, Ty) -> Decision) -> Decision
local function go(rep, a, b, dec)
    if rep.equal(a, b) then return "sub" end -- reflexivity (ssub_refl)
    local ka = rep.kind(a)
    local kb = rep.kind(b)

    -- universal bounds
    if kb == "top" then return "sub" end -- a <: top
    if ka == "bot" then return "sub" end -- bot <: b

    -- connectives on the RIGHT
    if kb == "union" then
        return or3(dec(rep, a, rep.union_left(b)), dec(rep, a, rep.union_right(b)))
    end
    if kb == "inter" then
        return and3(dec(rep, a, rep.inter_left(b)), dec(rep, a, rep.inter_right(b)))
    end
    -- connectives on the LEFT
    if ka == "union" then
        return and3(dec(rep, rep.union_left(a), b), dec(rep, rep.union_right(a), b))
    end
    if ka == "inter" then
        return or3(dec(rep, rep.inter_left(a), b), dec(rep, rep.inter_right(a), b))
    end

    -- atom base order (subtype.v): int <: num, int <: float; reflexive otherwise
    if ka == "atom" and kb == "atom" then
        local na = rep.atom_name(a)
        local nb = rep.atom_name(b)
        if na == nb then return "sub" end
        if na == "int" and (nb == "num" or nb == "float") then return "sub" end
        return "notsub"
    end

    -- arrows: contravariant domain, covariant codomain (proof BArrow)
    if ka == "arrow" and kb == "arrow" then
        local dom = dec(rep, rep.arrow_dom(b), rep.arrow_dom(a))
        local cod = dec(rep, rep.arrow_cod(a), rep.arrow_cod(b))
        return and3(dom, cod)
    end

    -- records
    if ka == "rec" and kb == "rec" then
        return decide_rec(rep, a, b, dec)
    end

    -- top on the left (b is not top here) / bot on the right (a is not bot):
    -- these are definitely false for proper types.
    if ka == "top" then return "notsub" end
    if kb == "bot" then return "notsub" end

    -- distinct concrete constructor heads denote disjoint value sets => notsub
    -- (proof: distinct heads unrelated). atom/arrow/rec are the decided heads.
    if (ka == "atom" or ka == "arrow" or ka == "rec")
        and (kb == "atom" or kb == "arrow" or kb == "rec") then
        return "notsub"
    end

    -- ref / anyref / tuple / neg: DEFERRED to a later/semantic backend.
    -- Honest "unknown" (the gdecide DUnknown arm), never a wrong commitment.
    return "unknown"
end

--: (TypeRep, Ty, Ty) -> Decision
local function decide(rep, a, b)
    return go(rep, a, b, decide)
end

M.decide = decide

return M
