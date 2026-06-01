-- lib/type/static-v6/types.lua
-- Core v6 type constructors and structural helpers.

local M = {}

--:: require "lib.type.static-v6.type_defs"

local ATOMS = {
    ["nil"] = true,
    boolean = true,
    integer = true,
    number = true,
    string = true,
    thread = true,
    userdata = true,
    cdata = true,
}

M.ATOMS = ATOMS

--: (string) -> StaticType
function M.atom(name)
    if not ATOMS[name] then
        error("unknown atom: " .. tostring(name))
    end
    return { tag = "atom", name = name }
end

--: (string, unknown) -> StaticType
function M.literal(base, value)
    if not ATOMS[base] or base == "nil" then
        error("invalid literal base: " .. tostring(base))
    end
    return { tag = "literal", base = base, value = value }
end

--: () -> StaticType
function M.unknown()
    return { tag = "unknown" }
end

--: () -> StaticType
function M.never()
    return { tag = "never" }
end

--: () -> StaticType
function M.any()
    return { tag = "any" }
end

--: ({ [integer]: StaticType }) -> StaticType
function M.union(members)
    return { tag = "union", members = members or {} }
end

--: ({ [integer]: StaticType }) -> StaticType
function M.intersection(members)
    return { tag = "intersection", members = members or {} }
end

--: (StaticType) -> StaticType
function M.complement(of)
    return { tag = "complement", of = of }
end

--: (Pack, Pack, unknown | nil) -> StaticType
function M.arrow(params, returns, effects)
    return { tag = "arrow", params = params, returns = returns, effects = effects }
end

--: (StaticType, boolean | nil, boolean | nil) -> Field
function M.field(typ, optional, readonly)
    return { type = typ, optional = optional == true, readonly = readonly == true }
end

--: (StaticType, StaticType, boolean | nil) -> Index
function M.index(key, value, readonly)
    return { key = key, value = value, readonly = readonly == true }
end

--: ({ [string]: Field } | nil, { [integer]: Index } | nil, string | nil) -> StaticType
function M.record(fields, indexes, row)
    row = row or "closed"
    if row ~= "closed" and row ~= "open" then
        error("record row must be 'closed' or 'open'")
    end
    return { tag = "record", fields = fields or {}, indexes = indexes or {}, row = row }
end

--: (Pack) -> string
local function pack_key(pack)
    local parts = {}
    for i, item in ipairs(pack.items) do parts[i] = M.key(item) end
    local rest = pack.rest
    if rest then parts[#parts + 1] = "..." .. M.key(rest) end
    return "pack(" .. table.concat(parts, ",") .. ")"
end

--: (Field) -> string
local function field_key(field)
    local flags = ""
    if field.optional then flags = flags .. "?" end
    if field.readonly then flags = flags .. "!" end
    return flags .. M.key(field.type)
end

--: (Index) -> string
local function index_key(index)
    local flags = ""
    if index.readonly then flags = "!" end
    return flags .. "[" .. M.key(index.key) .. "]=" .. M.key(index.value)
end

--: (RecordType) -> string
local function record_key(record)
    local parts = {} --: { [integer]: string }
    parts[#parts + 1] = "row:" .. record.row
    local names = {} --: { [integer]: string }
    for name, _field in pairs(record.fields) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        parts[#parts + 1] = "field:" .. name .. "=" .. field_key(record.fields[name])
    end
    for _, index in ipairs(record.indexes) do
        parts[#parts + 1] = "index:" .. index_key(index)
    end
    return "record(" .. table.concat(parts, ",") .. ")"
end

--: (StaticType) -> string | nil
local function scalar_key(t)
    if t.tag == "atom" then
        return "atom:" .. t.name
    end
    if t.tag == "literal" then
        return "literal:" .. t.base .. ":" .. tostring(t.value)
    end
    if t.tag == "unknown" then return "unknown" end
    if t.tag == "never" then return "never" end
    if t.tag == "any" then return "any" end
    return nil
end

--: (StaticType) -> string
function M.key(t)
    local k = scalar_key(t)
    if k then return k end
    if t.tag == "complement" then
        return "complement(" .. M.key(t.of) .. ")"
    end
    if t.tag == "union" or t.tag == "intersection" then
        local parts = {}
        for i, m in ipairs(t.members) do parts[i] = M.key(m) end
        table.sort(parts)
        return t.tag .. "(" .. table.concat(parts, ",") .. ")"
    end
    if t.tag == "arrow" then
        return "arrow(" .. pack_key(t.params) .. ")->" .. pack_key(t.returns)
    end
    if t.tag == "record" then
        return record_key(t)
    end
    if t.tag == "nominal" then
        return "nominal:" .. tostring(t.name)
    end
    if t.tag == "var" then
        return "var:" .. tostring(t.id)
    end
    return tostring(t.tag)
end

--: (StaticType, StaticType) -> boolean
function M.equal(a, b)
    return M.key(a) == M.key(b)
end

--: (StaticType) -> string
function M.tostring(t)
    if t.tag == "atom" then
        return t.name
    end
    if t.tag == "literal" then
        if t.base == "string" then return string.format("%q", t.value) end
        return tostring(t.value)
    end
    if t.tag == "unknown" then return "unknown" end
    if t.tag == "never" then return "never" end
    if t.tag == "any" then return "any" end
    if t.tag == "complement" then
        return "~" .. M.tostring(t.of)
    end
    if t.tag == "union" then
        local parts = {}
        for i, m in ipairs(t.members) do parts[i] = M.tostring(m) end
        return table.concat(parts, " | ")
    end
    if t.tag == "intersection" then
        local parts = {}
        for i, m in ipairs(t.members) do parts[i] = M.tostring(m) end
        return table.concat(parts, " & ")
    end
    if t.tag == "arrow" then return "<arrow>" end
    if t.tag == "record" then
        local parts = {} --: { [integer]: string }
        local names = {} --: { [integer]: string }
        for name, _field in pairs(t.fields) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local field = t.fields[name]
            local suffix = ""
            if field.optional then suffix = "?" end
            local prefix = ""
            if field.readonly then prefix = "readonly " end
            parts[#parts + 1] = prefix .. name .. suffix .. ": " .. M.tostring(field.type)
        end
        for _, index in ipairs(t.indexes) do
            local prefix = ""
            if index.readonly then prefix = "readonly " end
            parts[#parts + 1] = prefix .. "[" .. M.tostring(index.key) .. "]: " .. M.tostring(index.value)
        end
        if t.row == "open" then parts[#parts + 1] = "..." end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    if t.tag == "nominal" then
        return t.name
    end
    if t.tag == "var" then return "?" .. tostring(t.id) end
    return "<" .. tostring(t.tag) .. ">"
end

return M
