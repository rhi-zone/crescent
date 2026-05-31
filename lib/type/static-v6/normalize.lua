-- lib/type/static-v6/normalize.lua
-- Bounded canonicalization for the v6 value algebra.

local types = require("lib.type.static-v6.types")
local diag  = require("lib.type.static-v6.diagnostics")

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
--:: RecordType = { tag: "record" }
--:: NominalType = { tag: "nominal", name: string }
--:: VarType = { tag: "var", id: integer }
--:: StaticType = AtomType | LiteralType | UnknownType | NeverType | AnyType | UnionType | IntersectionType | ComplementType | ArrowType | RecordType | NominalType | VarType
--:: CheckOpts = { term_budget: integer, site: string, ... }
--:: CheckDiag = { code: string, message: string, details: unknown, ... }

local DEFAULT_BUDGET = 256

--: (CheckOpts | nil) -> integer
local function opts_budget(opts)
    if opts and opts.term_budget then return opts.term_budget end
    return DEFAULT_BUDGET
end

--: ({ [integer]: StaticType }, { [string]: boolean }, StaticType) -> nil
local function append_unique(out, seen, t)
    local key = types.key(t)
    if not seen[key] then
        seen[key] = true
        out[#out + 1] = t
    end
end

--: ({ [integer]: StaticType }) -> nil
local function sort_members(members)
    table.sort(members, function(a, b) return types.key(a) < types.key(b) end)
end

--: (StaticType, CheckOpts | nil) -> (StaticType | nil, CheckDiag | nil)
local function normalize_union(t, opts)
    local budget = opts_budget(opts)
    local out = {} --: { [integer]: StaticType }
    local seen = {} --: { [string]: boolean }
    for _, member in ipairs(t.members) do
        local norm, err = M.normalize(member, opts)
        if err then return nil, err end
        if not norm then return nil, diag.new("INTERNAL_TYPECHECKER_ERROR", "normalization produced no type", { operation = "union" }) end
        if norm.tag == "union" then
            for _, inner in ipairs(norm.members) do
                append_unique(out, seen, inner)
                if #out > budget then return nil, diag.complexity_limit("union") end
            end
        elseif norm.tag ~= "never" then
            append_unique(out, seen, norm)
            if #out > budget then return nil, diag.complexity_limit("union") end
        end
    end
    if #out == 0 then return types.never(), nil end
    if seen["unknown"] then return types.unknown(), nil end
    if #out == 1 then return out[1], nil end
    sort_members(out)
    return types.union(out), nil
end

--: (StaticType, CheckOpts | nil) -> (StaticType | nil, CheckDiag | nil)
local function normalize_intersection(t, opts)
    local budget = opts_budget(opts)
    local out = {} --: { [integer]: StaticType }
    local seen = {} --: { [string]: boolean }
    for _, member in ipairs(t.members) do
        local norm, err = M.normalize(member, opts)
        if err then return nil, err end
        if not norm then return nil, diag.new("INTERNAL_TYPECHECKER_ERROR", "normalization produced no type", { operation = "intersection" }) end
        if norm.tag == "intersection" then
            for _, inner in ipairs(norm.members) do
                append_unique(out, seen, inner)
                if #out > budget then return nil, diag.complexity_limit("intersection") end
            end
        elseif norm.tag ~= "unknown" then
            append_unique(out, seen, norm)
            if #out > budget then return nil, diag.complexity_limit("intersection") end
        end
    end
    if #out == 0 then return types.unknown(), nil end
    if seen["never"] then return types.never(), nil end
    if #out == 1 then return out[1], nil end
    sort_members(out)
    return types.intersection(out), nil
end

--: (StaticType, CheckOpts | nil) -> (StaticType | nil, CheckDiag | nil)
function M.normalize(t, opts)
    if t.tag == "union" then return normalize_union(t, opts) end
    if t.tag == "intersection" then return normalize_intersection(t, opts) end
    if t.tag == "complement" then
        local inner, err = M.normalize(t.of, opts)
        if err then return nil, err end
        if not inner then return nil, diag.new("INTERNAL_TYPECHECKER_ERROR", "normalization produced no type", { operation = "complement" }) end
        if inner.tag == "complement" then
            local inner_of = inner.of
            if not inner_of then
                return nil, diag.new("INTERNAL_TYPECHECKER_ERROR", "complement missing operand", { operation = "complement" })
            end
            return M.normalize(inner_of, opts)
        end
        return types.complement(inner), nil
    end
    return t, nil
end

return M
