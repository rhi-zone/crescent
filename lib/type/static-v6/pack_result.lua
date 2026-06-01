-- lib/type/static-v6/pack_result.lua
-- Whole-pack result alternatives for v6 value-list movement sites.

local packs = require("lib.type.static-v6.packs")
local types = require("lib.type.static-v6.types")

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
--:: PackResultSingle = { tag: "single", pack: Pack }
--:: PackResultUnion = { tag: "union", alternatives: { [integer]: Pack } }
--:: PackResult = PackResultSingle | PackResultUnion

--: (Pack) -> PackResult
function M.single(pack)
    return { tag = "single", pack = pack }
end

--: ({ [integer]: Pack }) -> PackResult
function M.union(alternatives)
    if #alternatives == 1 then return M.single(alternatives[1]) end
    return { tag = "union", alternatives = alternatives }
end

--: (PackResult) -> { [integer]: Pack }
function M.alternatives(result)
    if result.tag == "single" then return { result.pack } end
    return result.alternatives
end

--: ({ [integer]: StaticType }, PackResult) -> PackResult
function M.prepend_items(prefix, result)
    if #prefix == 0 then return result end
    local out = {} --: { [integer]: Pack }
    for _, pack in ipairs(M.alternatives(result)) do
        local items = {} --: { [integer]: StaticType }
        for _, item in ipairs(prefix) do
            items[#items + 1] = item
        end
        for _, item in ipairs(pack.items) do
            items[#items + 1] = item
        end
        out[#out + 1] = packs.pack(items, pack.rest)
    end
    return M.union(out)
end

--: ({ [integer]: StaticType }) -> StaticType
local function union_or_single(members)
    if #members == 0 then return types.atom("nil") end
    if #members == 1 then return members[1] end
    return types.union(members)
end

--: (Pack, integer) -> StaticType
local function pack_slot(pack, index)
    return pack.items[index] or types.atom("nil")
end

--: (PackResult) -> StaticType
function M.to_scalar(result)
    local members = {} --: { [integer]: StaticType }
    for _, pack in ipairs(M.alternatives(result)) do
        members[#members + 1] = pack_slot(pack, 1)
    end
    return union_or_single(members)
end

--: (PackResult, integer) -> { [integer]: StaticType }
function M.adjust_to_arity(result, arity)
    local out = {} --: { [integer]: StaticType }
    local alternatives = M.alternatives(result)
    for i = 1, arity do
        local members = {} --: { [integer]: StaticType }
        for _, pack in ipairs(alternatives) do
            members[#members + 1] = pack_slot(pack, i)
        end
        out[i] = union_or_single(members)
    end
    return out
end

--: ({ [integer]: StaticType }) -> PackResult
function M.from_items(items)
    return M.single(packs.pack(items))
end

--: (PackResult) -> string
function M.key(result)
    if result.tag == "single" then return "single:" .. packs.key(result.pack) end
    local parts = {} --: { [integer]: string }
    for i, pack in ipairs(result.alternatives) do
        parts[i] = packs.key(pack)
    end
    table.sort(parts)
    return "union:" .. table.concat(parts, "|")
end

--: (PackResult) -> string
function M.tostring(result)
    if result.tag == "single" then return packs.tostring(result.pack) end
    local parts = {} --: { [integer]: string }
    for i, pack in ipairs(result.alternatives) do
        parts[i] = packs.tostring(pack)
    end
    return table.concat(parts, " | ")
end

return M
