-- lib/type/v9/type_rep/tagged.lua
-- Type representation seam — DEFAULT impl: immutable-structural tagged tables.
-- Mirrors proof `BTy` (subtype.v): each `kind` is a BTy constructor head.
--
-- Handles are plain immutable tables. Consumers NEVER see this shape — they go
-- through the `TypeRep` accessor interface, so the (reserved) interned-arena
-- impl can replace this without touching a single consumer. The opacity is
-- enforced by the public type `Ty = unknown` (see type_defs.lua): a consumer
-- holds `unknown` and can only narrow it back through these functions.

--:: require "lib.type.v9.type_defs"

-- Concrete node shape — PRIVATE to this impl. Inner type slots are `Ty`
-- (opaque) so nesting stays representation-agnostic.
--:: TaggedNode = { kind: string, name?: string, a?: Ty, b?: Ty, dom?: Ty, cod?: Ty, fields?: { [integer]: Field }, items?: { [integer]: Ty } }

local M = {}

-- Narrow an opaque handle to this impl's concrete node. A non-table handle is a
-- programmer error (a foreign or corrupt handle), surfaced via `error`.
--: (Ty) -> TaggedNode
local function as_node(t)
    if type(t) ~= "table" then error("v9.type_rep.tagged: not a type handle") end
    return t --[[: TaggedNode]]
end

-- ---- constructors --------------------------------------------------------
--: (string) -> Ty
function M.atom(name) return { kind = "atom", name = name } end
--: () -> Ty
function M.top() return { kind = "top" } end
--: () -> Ty
function M.bot() return { kind = "bot" } end
--: (Ty, Ty) -> Ty
function M.union(a, b) return { kind = "union", a = a, b = b } end
--: (Ty, Ty) -> Ty
function M.inter(a, b) return { kind = "inter", a = a, b = b } end
--: (Ty) -> Ty
function M.neg(a) return { kind = "neg", a = a } end
--: (Ty, Ty) -> Ty
function M.arrow(dom, cod) return { kind = "arrow", dom = dom, cod = cod } end
--: ({ [integer]: Field }) -> Ty
function M.rec(fields) return { kind = "rec", fields = fields } end
--: (Ty) -> Ty
function M.ref(a) return { kind = "ref", a = a } end
--: () -> Ty
function M.anyref() return { kind = "anyref" } end
--: ({ [integer]: Ty }) -> Ty
function M.tuple(items) return { kind = "tuple", items = items } end

-- ---- destructor + accessors ----------------------------------------------
--: (Ty) -> string
function M.kind(t) return as_node(t).kind end
--: (Ty) -> string
function M.atom_name(t) return as_node(t).name or error("v9.type_rep.tagged: atom_name on non-atom") end
--: (Ty) -> Ty
function M.union_left(t) return as_node(t).a or error("v9.type_rep.tagged: union_left on non-union") end
--: (Ty) -> Ty
function M.union_right(t) return as_node(t).b or error("v9.type_rep.tagged: union_right on non-union") end
--: (Ty) -> Ty
function M.inter_left(t) return as_node(t).a or error("v9.type_rep.tagged: inter_left on non-inter") end
--: (Ty) -> Ty
function M.inter_right(t) return as_node(t).b or error("v9.type_rep.tagged: inter_right on non-inter") end
--: (Ty) -> Ty
function M.neg_of(t) return as_node(t).a or error("v9.type_rep.tagged: neg_of on non-neg") end
--: (Ty) -> Ty
function M.arrow_dom(t) return as_node(t).dom or error("v9.type_rep.tagged: arrow_dom on non-arrow") end
--: (Ty) -> Ty
function M.arrow_cod(t) return as_node(t).cod or error("v9.type_rep.tagged: arrow_cod on non-arrow") end
--: (Ty) -> Ty
function M.ref_of(t) return as_node(t).a or error("v9.type_rep.tagged: ref_of on non-ref") end
--: (Ty) -> { [integer]: Ty }
function M.tuple_items(t) return as_node(t).items or error("v9.type_rep.tagged: tuple_items on non-tuple") end
--: (Ty) -> { [integer]: Field }
function M.rec_fields(t) return as_node(t).fields or error("v9.type_rep.tagged: rec_fields on non-rec") end

-- ---- structural equality (over the accessor interface) -------------------
--: (Ty, Ty) -> boolean
function M.equal(a, b)
    local ka = M.kind(a)
    if ka ~= M.kind(b) then return false end
    if ka == "atom" then
        return M.atom_name(a) == M.atom_name(b)
    elseif ka == "top" or ka == "bot" or ka == "anyref" then
        return true
    elseif ka == "neg" then
        return M.equal(M.neg_of(a), M.neg_of(b))
    elseif ka == "ref" then
        return M.equal(M.ref_of(a), M.ref_of(b))
    elseif ka == "union" then
        return M.equal(M.union_left(a), M.union_left(b)) and M.equal(M.union_right(a), M.union_right(b))
    elseif ka == "inter" then
        return M.equal(M.inter_left(a), M.inter_left(b)) and M.equal(M.inter_right(a), M.inter_right(b))
    elseif ka == "arrow" then
        return M.equal(M.arrow_dom(a), M.arrow_dom(b)) and M.equal(M.arrow_cod(a), M.arrow_cod(b))
    elseif ka == "tuple" then
        local ia, ib = M.tuple_items(a), M.tuple_items(b)
        if #ia ~= #ib then return false end
        for i = 1, #ia do
            if not M.equal(ia[i], ib[i]) then return false end
        end
        return true
    elseif ka == "rec" then
        local fa, fb = M.rec_fields(a), M.rec_fields(b)
        if #fa ~= #fb then return false end
        for i = 1, #fa do
            if fa[i].key ~= fb[i].key then return false end
            if not M.equal(fa[i].type, fb[i].type) then return false end
        end
        return true
    end
    return false
end

-- ---- rendering -----------------------------------------------------------
--: (Ty) -> string
function M.show(t)
    local k = M.kind(t)
    if k == "atom" then
        return M.atom_name(t)
    elseif k == "top" then
        return "top"
    elseif k == "bot" then
        return "bot"
    elseif k == "anyref" then
        return "anyref"
    elseif k == "neg" then
        return "~" .. M.show(M.neg_of(t))
    elseif k == "ref" then
        return "ref(" .. M.show(M.ref_of(t)) .. ")"
    elseif k == "union" then
        return "(" .. M.show(M.union_left(t)) .. " | " .. M.show(M.union_right(t)) .. ")"
    elseif k == "inter" then
        return "(" .. M.show(M.inter_left(t)) .. " & " .. M.show(M.inter_right(t)) .. ")"
    elseif k == "arrow" then
        return "(" .. M.show(M.arrow_dom(t)) .. " -> " .. M.show(M.arrow_cod(t)) .. ")"
    elseif k == "tuple" then
        local parts = {} --: { [integer]: string }
        local items = M.tuple_items(t)
        for i = 1, #items do parts[i] = M.show(items[i]) end
        return "(" .. table.concat(parts, ", ") .. ")"
    elseif k == "rec" then
        local parts = {} --: { [integer]: string }
        local fields = M.rec_fields(t)
        for i = 1, #fields do parts[i] = fields[i].key .. ": " .. M.show(fields[i].type) end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "?"
end

return M
