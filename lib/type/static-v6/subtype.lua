-- lib/type/static-v6/subtype.lua
-- First v6 producer <: consumer relation.

local types     = require("lib.type.static-v6.types")
local normalize = require("lib.type.static-v6.normalize")
local diag      = require("lib.type.static-v6.diagnostics")

local M = {}

--:: AtomType = { tag: "atom", name: string }
--:: LiteralType = { tag: "literal", base: string, value: unknown }
--:: UnknownType = { tag: "unknown" }
--:: NeverType = { tag: "never" }
--:: AnyType = { tag: "any" }
--:: UnionType = { tag: "union", members: { [integer]: StaticType } }
--:: IntersectionType = { tag: "intersection", members: { [integer]: StaticType } }
--:: ComplementType = { tag: "complement", of: StaticType }
--:: Pack = { items: { [integer]: StaticType }, rest: StaticType | nil }
--:: ArrowType = { tag: "arrow", params: Pack, returns: Pack, effects: unknown }
--:: Field = { type: StaticType, optional: boolean, readonly: boolean }
--:: Index = { key: StaticType, value: StaticType, readonly: boolean }
--:: RecordType = { tag: "record", fields: { [string]: Field }, indexes: { [integer]: Index }, row: string }
--:: NominalType = { tag: "nominal", name: string }
--:: VarType = { tag: "var", id: integer }
--:: StaticType = AtomType | LiteralType | UnknownType | NeverType | AnyType | UnionType | IntersectionType | ComplementType | ArrowType | RecordType | NominalType | VarType
--:: CheckOpts = { term_budget: integer, site: string, ... }
--:: CheckDiag = { code: string, message: string, details: unknown, ... }

--: () -> (true, nil)
local function ok()
    return true, nil
end

--: (string, StaticType, StaticType, string | nil) -> (false, CheckDiag)
local function no(message, a, b, site)
    return false, diag.type_mismatch(message, a, b, site)
end

--: (StaticType, StaticType) -> boolean
local function is_literal_sub_atom(a, b)
    if a.tag ~= "literal" or b.tag ~= "atom" then return false end
    if a.base == b.name then return true end
    if a.base == "integer" and b.name == "number" then return true end
    return false
end

--: (StaticType, StaticType) -> boolean
local function is_atom_sub_atom(a, b)
    if a.tag ~= "atom" or b.tag ~= "atom" then return false end
    if a.name == b.name then return true end
    if a.name == "integer" and b.name == "number" then return true end
    return false
end

--: (StaticType, StaticType) -> boolean
local function definitely_disjoint(a, b)
    if types.equal(a, b) then return false end
    if a.tag == "literal" and b.tag == "literal" then return not types.equal(a, b) end
    if a.tag == "literal" and b.tag == "atom" then return not is_literal_sub_atom(a, b) end
    if a.tag == "atom" and b.tag == "literal" then return not is_literal_sub_atom(b, a) end
    if a.tag == "atom" and b.tag == "atom" then
        if is_atom_sub_atom(a, b) or is_atom_sub_atom(b, a) then return false end
        return true
    end
    return false
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
local is_subtype_impl = function(_, _, _)
    return false, diag.new("INTERNAL_TYPECHECKER_ERROR", "subtype relation used before initialization", {})
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
local function subtype_union_left(a, b, opts)
    for _, member in ipairs(a.members) do
        local yes, err = is_subtype_impl(member, b, opts)
        if not yes then return false, err end
    end
    return ok()
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
local function subtype_union_right(a, b, opts)
    for _, member in ipairs(b.members) do
        local yes = is_subtype_impl(a, member, opts)
        if yes then return ok() end
    end
    return no(types.tostring(a) .. " matches no union branch in " .. types.tostring(b), a, b, opts and opts.site)
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
local function subtype_intersection_right(a, b, opts)
    for _, member in ipairs(b.members) do
        local yes, err = is_subtype_impl(a, member, opts)
        if not yes then return false, err end
    end
    return ok()
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
local function subtype_intersection_left(a, b, opts)
    for _, member in ipairs(a.members) do
        local yes = is_subtype_impl(member, b, opts)
        if yes then return ok() end
    end
    return no(types.tostring(a) .. " does not provide a part usable as " .. types.tostring(b), a, b, opts and opts.site)
end

--: (Pack, Pack, CheckOpts | nil, string) -> (boolean, CheckDiag | nil)
local function subtype_pack(a, b, opts, site)
    if a.rest ~= nil or b.rest ~= nil then
        return false, diag.new("FEATURE_NOT_ADMITTED",
            "v6 arrow subtyping does not admit open packs yet at " .. site,
            { producer = a, consumer = b, site = opts and opts.site })
    end
    if #a.items ~= #b.items then
        return false, diag.new("FUNCTION_ARITY_MISMATCH",
            "pack arity " .. tostring(#a.items) .. " does not match " .. tostring(#b.items) .. " at " .. site,
            { producer = a, consumer = b, site = opts and opts.site })
    end
    for i = 1, #a.items do
        local yes, err = is_subtype_impl(a.items[i], b.items[i], opts)
        if not yes then return false, err end
    end
    return ok()
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
is_subtype_impl = function(a, b, opts)
    local na, erra = normalize.normalize(a, opts)
    if erra then return false, erra end
    local nb, errb = normalize.normalize(b, opts)
    if errb then return false, errb end
    if not na or not nb then
        return false, diag.new("INTERNAL_TYPECHECKER_ERROR", "normalization produced no type", { producer = a, consumer = b })
    end
    a, b = na, nb

    if types.equal(a, b) then return ok() end
    if a.tag == "never" then return ok() end
    if b.tag == "unknown" then return ok() end
    if a.tag == "unknown" and b.tag ~= "unknown" then
        return false, diag.new("UNKNOWN_REQUIRES_NARROWING",
            "unknown must be narrowed before use as " .. types.tostring(b),
            { producer = a, consumer = b, site = opts and opts.site })
    end
    if a.tag == "any" or b.tag == "any" then
        return false, diag.unsafe_any(opts and opts.site or "subtype")
    end
    if a.tag == "union" then return subtype_union_left(a, b, opts) end
    if b.tag == "union" then return subtype_union_right(a, b, opts) end
    if b.tag == "intersection" then return subtype_intersection_right(a, b, opts) end
    if a.tag == "intersection" then return subtype_intersection_left(a, b, opts) end
    if b.tag == "complement" then
        local excluded = b.of
        if not excluded then
            return false, diag.new("INTERNAL_TYPECHECKER_ERROR", "complement missing operand", { consumer = b })
        end
        if definitely_disjoint(a, excluded) then return ok() end
        return no(types.tostring(a) .. " is not proven disjoint from " .. types.tostring(excluded), a, b, opts and opts.site)
    end
    if a.tag == "arrow" and b.tag == "arrow" then
        local aparams = a.params
        local bparams = b.params
        local areturns = a.returns
        local breturns = b.returns
        if aparams == nil or bparams == nil or areturns == nil or breturns == nil then
            return false, diag.new("INTERNAL_TYPECHECKER_ERROR", "arrow type missing pack", { producer = a, consumer = b })
        end
        local params_ok, params_err = subtype_pack(bparams, aparams, opts, "arrow parameters")
        if not params_ok then return false, params_err end
        return subtype_pack(areturns, breturns, opts, "arrow returns")
    end
    if is_literal_sub_atom(a, b) then return ok() end
    if is_atom_sub_atom(a, b) then return ok() end
    return no(types.tostring(a) .. " is not a subtype of " .. types.tostring(b), a, b, opts and opts.site)
end

--: (StaticType, StaticType, CheckOpts | nil) -> (boolean, CheckDiag | nil)
function M.is_subtype(a, b, opts)
    return is_subtype_impl(a, b, opts)
end

return M
