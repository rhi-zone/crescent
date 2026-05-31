-- lib/type/static-v6/ann.lua
-- Minimal v6 annotation parser for M1.

local types = require("lib.type.static-v6.types")
local packs = require("lib.type.static-v6.packs")

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
--:: AnnState = {}
--:: Scanner = { src: string, pos: integer, len: integer }

local byte = string.byte
local sub = string.sub

local B_SPACE = 32
local B_TAB = 9
local B_NL = 10
local B_CR = 13
local B_A = 65
local B_Z = 90
local B_a = 97
local B_z = 122
local B_0 = 48
local B_9 = 57
local B_UNDER = 95
local B_DQUOT = 34
local B_SQUOT = 39
local B_TILDE = 126

--: () -> AnnState
function M.new_state()
    return {}
end

--: (string) -> Scanner
local function scanner(src)
    return { src = src, pos = 1, len = #src }
end

--: (Scanner, string) -> never
local function scan_error(s, msg)
    error("annotation: " .. msg .. " at col " .. tostring(s.pos), 0)
end

--: (integer | nil) -> boolean
local function is_ident_start(b)
    if b == nil then return false end
    if b >= B_a and b <= B_z then return true end
    if b >= B_A and b <= B_Z then return true end
    if b == B_UNDER then return true end
    return false
end

--: (integer | nil) -> boolean
local function is_ident(b)
    if is_ident_start(b) then return true end
    if b == nil then return false end
    if b >= B_0 and b <= B_9 then return true end
    return false
end

--: (integer | nil) -> boolean
local function is_digit(b)
    if b == nil then return false end
    if b >= B_0 and b <= B_9 then return true end
    return false
end

--: (Scanner) -> nil
local function skip_ws(s)
    while s.pos <= s.len do
        local b = byte(s.src, s.pos)
        if b == B_SPACE or b == B_TAB or b == B_NL or b == B_CR then
            s.pos = s.pos + 1
        else
            break
        end
    end
end

--: (Scanner) -> integer | nil
local function peek(s)
    skip_ws(s)
    if s.pos > s.len then return nil end
    return byte(s.src, s.pos)
end

--: (Scanner, string) -> boolean
local function starts_with(s, text)
    skip_ws(s)
    return sub(s.src, s.pos, s.pos + #text - 1) == text
end

--: (Scanner, string) -> boolean
local function opt_text(s, text)
    if not starts_with(s, text) then return false end
    s.pos = s.pos + #text
    return true
end

--: (Scanner, string) -> nil
local function expect_char(s, ch)
    skip_ws(s)
    if s.pos > s.len or byte(s.src, s.pos) ~= byte(ch) then
        scan_error(s, "expected '" .. ch .. "'")
    end
    s.pos = s.pos + 1
end

--: (Scanner, string) -> boolean
local function opt_char(s, ch)
    skip_ws(s)
    if s.pos <= s.len and byte(s.src, s.pos) == byte(ch) then
        s.pos = s.pos + 1
        return true
    end
    return false
end

--: (Scanner) -> string | nil
local function scan_word(s)
    skip_ws(s)
    if s.pos > s.len then return nil end
    if not is_ident_start(byte(s.src, s.pos)) then return nil end
    local start = s.pos
    s.pos = s.pos + 1
    while s.pos <= s.len and is_ident(byte(s.src, s.pos)) do
        s.pos = s.pos + 1
    end
    return sub(s.src, start, s.pos - 1)
end

--: (Scanner) -> string
local function scan_string_lit(s)
    skip_ws(s)
    local delim = byte(s.src, s.pos)
    if delim ~= B_DQUOT and delim ~= B_SQUOT then scan_error(s, "expected string literal") end
    s.pos = s.pos + 1
    local start = s.pos
    while s.pos <= s.len do
        if byte(s.src, s.pos) == delim then
            local out = sub(s.src, start, s.pos - 1)
            s.pos = s.pos + 1
            return out
        end
        s.pos = s.pos + 1
    end
    scan_error(s, "unterminated string literal")
end

--: (Scanner) -> number
local function scan_number_lit(s)
    skip_ws(s)
    local start = s.pos
    while s.pos <= s.len and is_digit(byte(s.src, s.pos)) do
        s.pos = s.pos + 1
    end
    if s.pos <= s.len and byte(s.src, s.pos) == byte(".") then
        s.pos = s.pos + 1
        while s.pos <= s.len and is_digit(byte(s.src, s.pos)) do
            s.pos = s.pos + 1
        end
    end
    local raw = sub(s.src, start, s.pos - 1)
    local n = tonumber(raw)
    if n == nil then scan_error(s, "invalid number literal") end
    return n
end

local parse_type
local parse_union
local parse_return_pack

--: (StaticType) -> Pack
local function result_pack(t)
    if t.tag == "never" then return packs.pack({}) end
    return packs.pack({ t })
end

--: (Scanner) -> StaticType
local function parse_primary(s)
    local b = peek(s)
    if not b then scan_error(s, "unexpected end of type") end

    if b == B_DQUOT or b == B_SQUOT then
        return types.literal("string", scan_string_lit(s))
    end

    if is_digit(b) then
        local n = scan_number_lit(s)
        if n % 1 == 0 then return types.literal("integer", math.floor(n)) end
        return types.literal("number", n)
    end

    if b == B_TILDE then
        s.pos = s.pos + 1
        return types.complement(parse_primary(s))
    end

    if opt_char(s, "(") then
        local items = {} --: { [integer]: StaticType }
        if not opt_char(s, ")") then
            items[#items + 1] = parse_type(s)
            while opt_char(s, ",") do
                items[#items + 1] = parse_type(s)
            end
            expect_char(s, ")")
        end
        if opt_text(s, "->") then
            local returns = parse_return_pack(s)
            if returns == nil then scan_error(s, "missing return pack") end
            return types.arrow(packs.pack(items), returns)
        end
        if #items == 1 then return items[1] end
        scan_error(s, "tuple types are not admitted in v6 M1 annotations")
    end

    local word = scan_word(s)
    if word then
        if word == "true" then return types.literal("boolean", true) end
        if word == "false" then return types.literal("boolean", false) end
        if word == "unknown" then return types.unknown() end
        if word == "never" then return types.never() end
        if word == "any" then return types.any() end
        if types.ATOMS[word] then return types.atom(word) end
        scan_error(s, "named types are not admitted in v6 M1 annotations: " .. word)
    end

    scan_error(s, "unexpected token")
end

--: (Scanner) -> StaticType
local function parse_intersection(s)
    local out = { parse_primary(s) } --: { [integer]: StaticType }
    while opt_char(s, "&") do
        out[#out + 1] = parse_primary(s)
    end
    if #out == 1 then return out[1] end
    return types.intersection(out)
end

--: (Scanner) -> StaticType
parse_union = function(s)
    local out = { parse_intersection(s) } --: { [integer]: StaticType }
    while opt_char(s, "|") do
        out[#out + 1] = parse_intersection(s)
    end
    if #out == 1 then return out[1] end
    return types.union(out)
end

--: (Scanner) -> Pack
parse_return_pack = function(s)
    if opt_char(s, "(") then
        local items = {} --: { [integer]: StaticType }
        if not opt_char(s, ")") then
            items[#items + 1] = parse_type(s)
            while opt_char(s, ",") do
                items[#items + 1] = parse_type(s)
            end
            expect_char(s, ")")
        end
        return packs.pack(items)
    end
    return result_pack(parse_type(s))
end

--: (Scanner) -> StaticType
parse_type = function(s)
    return parse_union(s)
end

--: (AnnState, string) -> (StaticType | nil, string | nil)
function M.parse_annotation(_state, text)
    local ok, result = pcall(function()
        local s = scanner(text)
        local typ = parse_type(s)
        if peek(s) ~= nil then scan_error(s, "unexpected trailing input") end
        return typ
    end)
    if ok then return result, nil end
    return nil, tostring(result)
end

--: (AnnState, string) -> (unknown | nil, string | nil)
function M.parse_declaration(_state, text)
    return nil, "v6 M1 declarations are not admitted yet: " .. text
end

return M
