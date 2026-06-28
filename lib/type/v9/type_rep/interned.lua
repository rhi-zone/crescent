-- lib/type/v9/type_rep/interned.lua
-- Type representation seam — SECOND impl: arena-interned, demonstrating the
-- seam does not leak. This is the start of the reserved "interned-arena" impl
-- noted in ARCHITECTURE.md; it is deliberately minimal (atoms hash-consed).
--
-- It uses a DIFFERENT internal node shape from `tagged` (short keys `t/nm/l/r/x`
-- instead of `kind/name/a/b`) and SHARES identical atom nodes. Because every
-- consumer goes through the `TypeRep` accessor interface, swapping this in for
-- `tagged` changes nothing observable — that is the non-leak proof.

--:: require "lib.type.v9.type_defs"

--:: ArenaNode = { t: string, nm?: string, l?: Ty, r?: Ty, x?: Ty, fs?: { [integer]: Field }, it?: { [integer]: Ty } }

local M = {}

-- Atom interning cache (pure memoization; identical atom names share a node).
local atom_cache = {} --: { [string]: Ty }

--: (Ty) -> ArenaNode
local function as_node(t)
    if type(t) ~= "table" then error("v9.type_rep.interned: not a type handle") end
    return t --[[: ArenaNode]]
end

-- ---- constructors --------------------------------------------------------
--: (string) -> Ty
function M.atom(name)
    local cached = atom_cache[name]
    if cached ~= nil then return cached end
    local node = { t = "atom", nm = name } --: Ty
    atom_cache[name] = node
    return node
end
--: () -> Ty
function M.top() return { t = "top" } end
--: () -> Ty
function M.bot() return { t = "bot" } end
--: (Ty, Ty) -> Ty
function M.union(a, b) return { t = "union", l = a, r = b } end
--: (Ty, Ty) -> Ty
function M.inter(a, b) return { t = "inter", l = a, r = b } end
--: (Ty) -> Ty
function M.neg(a) return { t = "neg", x = a } end
--: (Ty, Ty) -> Ty
function M.arrow(dom, cod) return { t = "arrow", l = dom, r = cod } end
--: ({ [integer]: Field }) -> Ty
function M.rec(fields) return { t = "rec", fs = fields } end
--: (Ty) -> Ty
function M.ref(a) return { t = "ref", x = a } end
--: () -> Ty
function M.anyref() return { t = "anyref" } end
--: ({ [integer]: Ty }) -> Ty
function M.tuple(items) return { t = "tuple", it = items } end

-- ---- destructor + accessors ----------------------------------------------
--: (Ty) -> string
function M.kind(t) return as_node(t).t end
--: (Ty) -> string
function M.atom_name(t) return as_node(t).nm or error("v9.type_rep.interned: atom_name on non-atom") end
--: (Ty) -> Ty
function M.union_left(t) return as_node(t).l or error("v9.type_rep.interned: union_left on non-union") end
--: (Ty) -> Ty
function M.union_right(t) return as_node(t).r or error("v9.type_rep.interned: union_right on non-union") end
--: (Ty) -> Ty
function M.inter_left(t) return as_node(t).l or error("v9.type_rep.interned: inter_left on non-inter") end
--: (Ty) -> Ty
function M.inter_right(t) return as_node(t).r or error("v9.type_rep.interned: inter_right on non-inter") end
--: (Ty) -> Ty
function M.neg_of(t) return as_node(t).x or error("v9.type_rep.interned: neg_of on non-neg") end
--: (Ty) -> Ty
function M.arrow_dom(t) return as_node(t).l or error("v9.type_rep.interned: arrow_dom on non-arrow") end
--: (Ty) -> Ty
function M.arrow_cod(t) return as_node(t).r or error("v9.type_rep.interned: arrow_cod on non-arrow") end
--: (Ty) -> Ty
function M.ref_of(t) return as_node(t).x or error("v9.type_rep.interned: ref_of on non-ref") end
--: (Ty) -> { [integer]: Ty }
function M.tuple_items(t) return as_node(t).it or error("v9.type_rep.interned: tuple_items on non-tuple") end
--: (Ty) -> { [integer]: Field }
function M.rec_fields(t) return as_node(t).fs or error("v9.type_rep.interned: rec_fields on non-rec") end

-- ---- structural equality (identical logic, different storage) ------------
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
