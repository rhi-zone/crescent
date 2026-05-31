-- lib/type/static-v6/packs.lua
-- Structural helpers for v6 parameter and return packs.

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

--: (unknown) -> boolean
local function is_static_type(value)
    if type(value) ~= "table" then return false end
    if type(value.tag) ~= "string" then return false end
    return true
end

--: ({ [integer]: StaticType }) -> nil
local function validate_dense_items(items)
    local count = 0 --: number
    local max = 0 --: number
    for key, value in pairs(items) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            error("pack item keys must be positive integer positions")
        end
        if not is_static_type(value) then
            error("pack item at position " .. tostring(key) .. " is not a type")
        end
        count = count + 1
        if key > max then max = key end
    end
    if count ~= max then
        error("pack items must be dense; sparse packs would lose positions")
    end
end

--: ({ [integer]: StaticType } | nil, StaticType | nil) -> Pack
function M.pack(items, rest)
    items = items or {}
    validate_dense_items(items)
    if rest ~= nil and not is_static_type(rest) then
        error("pack rest must be a type")
    end
    return { items = items, rest = rest }
end

--: (Pack) -> integer
function M.fixed_arity(pack)
    return #pack.items
end

--: (Pack) -> boolean
function M.is_open(pack)
    return pack.rest ~= nil
end

--: (Pack) -> string
function M.key(pack)
    local parts = {}
    for i, item in ipairs(pack.items) do
        parts[i] = types.key(item)
    end
    local rest = pack.rest
    if rest then
        parts[#parts + 1] = "..." .. types.key(rest)
    end
    return "pack(" .. table.concat(parts, ",") .. ")"
end

--: (Pack, Pack) -> boolean
function M.equal(a, b)
    return M.key(a) == M.key(b)
end

--: (Pack) -> string
function M.tostring(pack)
    local parts = {}
    for i, item in ipairs(pack.items) do
        parts[i] = types.tostring(item)
    end
    local rest = pack.rest
    if rest then
        parts[#parts + 1] = "..." .. types.tostring(rest)
    end
    return "(" .. table.concat(parts, ", ") .. ")"
end

return M
