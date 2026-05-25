-- lib/type/static-v5/ann.lua
-- v5 annotation parser.
--
-- Parses --: / --:: annotation content strings into v5 substrate types
-- (Lua-table V5Type values from lib/type/experiments/v5_perf/types.lua).
--
-- Entry points:
--   M.parse_annotation(text)   -> V5Type, string|nil   (nil err = ok)
--   M.parse_declaration(text)  -> table, string|nil     (directive record)
--   M.declare_effect(name, n)  -> nil                   (register arity N for !Name)
--
-- Surface syntax mirrors v4 (lib/type/static/ann.lua) plus:
--   !Name          effect-type head  (N=0 or declared arity)
--   !Name<A, B>    effect-type application (arity must match declaration)
--   --:: declare effect !Name : N   register effect arity

local types_mod = require("lib.type.experiments.v5_perf.types")

local M = {}

-- ── Byte constants ──────────────────────────────────────────────────────────

local byte   = string.byte
local sub    = string.sub
local format = string.format

local B_SPACE  = 32
local B_TAB    = 9
local B_NL     = 10
local B_CR     = 13
local B_a = 97;  local B_z = 122
local B_A = 65;  local B_Z = 90
local B_0 = 48;  local B_9 = 57
local B_UNDER  = 95
local B_DQUOT  = 34
local B_SQUOT  = 39
local B_DOT    = 46
local B_BANG   = 33   -- '!'
local B_DOLLAR = 36   -- '$'

-- ── Effect arity registry ───────────────────────────────────────────────────

-- effect_arities[name] = arity N   (name excludes leading '!')
local effect_arities = {} --[[: { [string]: number } ]]

-- Register a declared effect arity.
--: (string, number) -> nil
function M.declare_effect(name, n)
    effect_arities[name] = math.floor(n)
end

-- ── Primitive type name → const name ───────────────────────────────────────

local prim_names = {
    ["nil"]     = "nil",
    ["boolean"] = "boolean",
    ["number"]  = "number",
    ["string"]  = "string",
    ["integer"] = "integer",
    ["never"]   = "never",
    ["unknown"] = "unknown",
    ["cdata"]   = "cdata",
}

-- ── Scanner ─────────────────────────────────────────────────────────────────

--:: AnnScanner = { src: string, pos: integer, len: integer, depth: integer, depth_limit_hit?: boolean }

--: (string) -> AnnScanner
local function new_scanner(src)
    return { src = src, pos = 1, len = #src, depth = 0 }
end

local MAX_DEPTH = 64

--: (AnnScanner, string) -> never
local function scan_error(s, msg)
    error("annotation: " .. msg .. " (at col " .. s.pos .. ")", 0)
end

--: (integer | nil) -> boolean
local function is_ident_start(b)
    if b == nil then return false end
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z) or b == B_UNDER
end

--: (integer | nil) -> boolean
local function is_ident(b)
    if b == nil then return false end
    if is_ident_start(b) then return true end
    if b >= B_0 and b <= B_9 then return true end
    return false
end

--: (integer | nil) -> boolean
local function is_digit(b)
    if b == nil then return false end
    if b >= B_0 and b <= B_9 then return true end
    return false
end

--: (AnnScanner) -> nil
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

--: (AnnScanner) -> integer | nil
local function peek(s)
    skip_ws(s)
    if s.pos > s.len then return nil end
    return byte(s.src, s.pos)
end

--: (AnnScanner) -> nil
local function advance(s)
    s.pos = s.pos + 1
end

--: (AnnScanner, string) -> nil
local function expect_char(s, ch)
    skip_ws(s)
    if s.pos > s.len or byte(s.src, s.pos) ~= byte(ch) then
        scan_error(s, "expected '" .. ch .. "'")
    end
    s.pos = s.pos + 1
end

--: (AnnScanner, string) -> boolean
local function opt_char(s, ch)
    skip_ws(s)
    if s.pos <= s.len and byte(s.src, s.pos) == byte(ch) then
        s.pos = s.pos + 1
        return true
    end
    return false
end

--: (AnnScanner) -> string | nil
local function scan_word(s)
    skip_ws(s)
    if s.pos > s.len then return nil end
    local b = byte(s.src, s.pos)
    if not is_ident_start(b) then return nil end
    local start = s.pos
    s.pos = s.pos + 1
    while s.pos <= s.len and is_ident(byte(s.src, s.pos)) do
        s.pos = s.pos + 1
    end
    return sub(s.src, start, s.pos - 1)
end

--: (AnnScanner) -> string
local function scan_string_lit(s)
    skip_ws(s)
    local b = byte(s.src, s.pos)
    if b ~= B_DQUOT and b ~= B_SQUOT then
        scan_error(s, "expected string literal")
        error("unreachable")
    end
    local delim = b
    s.pos = s.pos + 1
    local start = s.pos
    while s.pos <= s.len do
        b = byte(s.src, s.pos)
        if b == delim then
            local str = sub(s.src, start, s.pos - 1)
            s.pos = s.pos + 1
            return str
        end
        s.pos = s.pos + 1
    end
    scan_error(s, "unterminated string literal")
    error("unreachable")
end

--: (AnnScanner) -> number
local function scan_number_lit(s)
    skip_ws(s)
    local start = s.pos
    while s.pos <= s.len and is_digit(byte(s.src, s.pos)) do
        s.pos = s.pos + 1
    end
    if s.pos <= s.len and byte(s.src, s.pos) == B_DOT then
        s.pos = s.pos + 1
        while s.pos <= s.len and is_digit(byte(s.src, s.pos)) do
            s.pos = s.pos + 1
        end
    end
    return tonumber(sub(s.src, start, s.pos - 1)) or 0
end

--: (AnnScanner) -> boolean
local function at_end(s)
    skip_ws(s)
    return s.pos > s.len
end

-- ── Type expression parser ───────────────────────────────────────────────────

-- Forward declaration
local parse_type --[[: (AnnScanner) -> V5Type ]]

-- Row-variable counter for fresh row variables.
local _next_rowvar = 1

--: () -> integer
local function fresh_rowvar_id()
    local id = _next_rowvar
    _next_rowvar = id + 1
    return id
end

-- parse_primary: parses a single non-union, non-intersection type.
--: (AnnScanner) -> V5Type
local function parse_primary(s)
    s.depth = s.depth + 1
    if s.depth > MAX_DEPTH then
        s.depth_limit_hit = true
        scan_error(s, "type annotation too deeply nested (max " .. MAX_DEPTH .. ")")
    end

    local b0 = peek(s)
    if not b0 then scan_error(s, "unexpected end of type") end
    local b = b0

    -- String literal: "foo" or 'foo'
    if b == B_DQUOT or b == B_SQUOT then
        local str = scan_string_lit(s)
        s.depth = s.depth - 1
        -- Represent as App(Const("$LitStr"), Const(str))
        return types_mod.app(types_mod.const("$LitStr"), types_mod.const(str))
    end

    -- Number literal
    if is_digit(b) then
        local num = scan_number_lit(s)
        s.depth = s.depth - 1
        if num % 1 == 0 then
            return types_mod.app(types_mod.const("$LitInt"), types_mod.const(tostring(math.floor(num))))
        else
            return types_mod.app(types_mod.const("$LitNum"), types_mod.const(tostring(num)))
        end
    end

    -- Effect type: !Name or !Name<Args>
    if b == B_BANG then
        advance(s)
        local name = scan_word(s)
        if not name then scan_error(s, "expected effect name after '!'") end
        local eff_head = types_mod.effect(name)
        local result
        if peek(s) == byte("<") then
            advance(s)  -- skip '<'
            local args = { parse_type(s) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s)
            end
            expect_char(s, ">")
            -- Check arity if declared
            local declared = effect_arities[name]
            if declared ~= nil and declared ~= #args then
                scan_error(s, "effect '!" .. name .. "' declared with arity " ..
                    declared .. " but applied to " .. #args .. " arg(s)")
            end
            result = types_mod.effect_apply(eff_head, args)
        else
            -- Bare !Name: allowed when arity == 0 or undeclared
            local declared = effect_arities[name]
            if declared ~= nil and declared ~= 0 then
                scan_error(s, "effect '!" .. name .. "' requires " .. declared ..
                    " type argument(s)")
            end
            result = eff_head
        end
        s.depth = s.depth - 1
        return result
    end

    -- Intrinsic: $Name or $Name<args>
    if b == B_DOLLAR then
        advance(s)
        local name = scan_word(s)
        if not name then scan_error(s, "expected intrinsic name after '$'") end
        local base = types_mod.const("$" .. name)
        local result
        if peek(s) == byte("<") then
            advance(s)
            local args = { parse_type(s) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s)
            end
            expect_char(s, ">")
            -- Curried application: App(App(base, a1), a2) ...
            local cur = base
            for i = 1, #args do
                local a = args[i]
                if a ~= nil then cur = types_mod.app(cur, a) end
            end
            result = cur
        else
            result = base
        end
        s.depth = s.depth - 1
        return result
    end

    -- Parenthesized type, tuple, or function type
    if b == byte("(") then
        advance(s)
        -- Empty parens: () -> T (zero-param function) or unit
        if peek(s) == byte(")") then
            advance(s)
            skip_ws(s)
            if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
                s.pos = s.pos + 2
                local ret = parse_type(s)
                s.depth = s.depth - 1
                return types_mod.arrow({}, { ret })
            end
            -- Empty tuple / unit type
            s.depth = s.depth - 1
            return types_mod.const("$Unit")
        end
        -- Parse items (named or bare)
        local items = {} --[[: V5Type[] ]]
        --: () -> V5Type
        local function parse_one_param()
            local save_pos = s.pos
            local word = scan_word(s)
            if word then
                if peek(s) == byte(":") then
                    advance(s)
                    return parse_type(s)
                else
                    s.pos = save_pos
                end
            end
            return parse_type(s)
        end
        items[1] = parse_one_param()
        while opt_char(s, ",") do
            items[#items + 1] = parse_one_param()
        end
        expect_char(s, ")")
        -- Check for -> (function type)
        skip_ws(s)
        if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
            s.pos = s.pos + 2
            skip_ws(s)
            local ret
            if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
                s.pos = s.pos + 3
                expect_char(s, "(")
                local inner = parse_type(s)
                expect_char(s, ")")
                -- Spread return: represent as App($Spread, inner)
                ret = types_mod.app(types_mod.const("$Spread"), inner)
            else
                ret = parse_type(s)
            end
            -- Unpack tuple return into multi-return list
            local rets = {} --[[: V5Type[] ]]
            if ret.tag == "const" and ret.name == "$Unit" then
                -- empty tuple = void, rets stays empty
            else
                rets = { ret }
            end
            -- Extract trailing spread as vararg indicator (best-effort)
            local params = items
            s.depth = s.depth - 1
            return types_mod.arrow(params, rets)
        end
        -- Single item in parens → just the type
        if #items == 1 and items[1] ~= nil then
            local result = items[1]
            s.depth = s.depth - 1
            return result
        end
        -- Multiple items → tuple (no arrow)
        local tup_fields = {} --[[: { [string]: V5Type } ]]
        for i = 1, #items do
            local v = items[i]
            if v ~= nil then tup_fields[tostring(i)] = v end
        end
        s.depth = s.depth - 1
        return { tag = "record", fields = tup_fields, row = nil }
    end

    -- Record / table type: { ... }
    if b == byte("{") then
        advance(s)
        local fields = {} --[[: { [string]: V5Type } ]]
        local row_id = -1  -- set to fresh ID when bare ... seen (open table)
        -- Indexers: stored as $idx_N fields to distinguish from named fields.
        -- e.g. { [string]: T } → fields["$idx_string"] = T  (for Phase 5.B to handle)
        local idx_count = 0
        if peek(s) ~= byte("}") then
            while true do
                local fb = peek(s)
                if fb == byte("[") then
                    -- Indexer: [K]: V
                    advance(s)
                    -- Check for opaque key (bare word not a primitive)
                    local save_bracket = s.pos
                    local bracket_word = scan_word(s)
                    skip_ws(s)
                    local is_opaque = bracket_word and not prim_names[bracket_word]
                        and s.pos <= s.len and byte(s.src, s.pos) == byte("]")
                    if is_opaque and bracket_word then
                        advance(s)  -- consume ']'
                        expect_char(s, ":")
                        local val_type = parse_type(s)
                        -- Opaque key: store as $opaque_KEY = val
                        fields["$opaque_" .. bracket_word] = val_type
                    else
                        s.pos = save_bracket
                        local key_type = parse_type(s)
                        expect_char(s, "]")
                        expect_char(s, ":")
                        local val_type = parse_type(s)
                        -- Store indexer by key type tag for Phase 5.B
                        idx_count = idx_count + 1
                        -- Pair key+val as an App node under a synthetic field name
                        fields["$idx_" .. tostring(idx_count)] =
                            types_mod.app(types_mod.app(types_mod.const("$Idx"), key_type), val_type)
                    end
                elseif fb == byte(".") and s.pos + 2 <= s.len
                    and sub(s.src, s.pos, s.pos + 2) == "..." then
                    s.pos = s.pos + 3
                    local nb = peek(s)
                    if nb == byte("}") or nb == byte(",") or nb == byte(";") or not nb then
                        -- Bare ...: open-table row variable
                        row_id = fresh_rowvar_id()
                        break
                    else
                        -- ...T: spread base type
                        local inner = parse_type(s)
                        -- Store as $spread_N field
                        idx_count = idx_count + 1
                        fields["$spread_" .. tostring(idx_count)] =
                            types_mod.app(types_mod.const("$Spread"), inner)
                    end
                elseif fb and is_ident_start(fb) then
                    -- Named field: [readonly] name[?]: type
                    local save_pos = s.pos
                    local word = scan_word(s)
                    -- Check for 'readonly' modifier
                    local fname
                    local is_readonly = false
                    if word == "readonly" then
                        local nb = peek(s)
                        if nb and is_ident_start(nb) then
                            is_readonly = true
                            fname = scan_word(s)
                        else
                            fname = word
                        end
                    else
                        fname = word
                    end
                    local next_b = peek(s)
                    if next_b == byte(":") or next_b == byte("?") then
                        local optional = opt_char(s, "?")
                        expect_char(s, ":")
                        local ftype = parse_type(s)
                        -- Encode optional/readonly in field name for Phase 5.B
                        local key = fname or ""
                        if optional then key = "$opt_" .. key end
                        if is_readonly then key = "$ro_" .. key end
                        fields[key] = ftype
                    else
                        -- Positional type entry
                        s.pos = save_pos
                        local val_type = parse_type(s)
                        idx_count = idx_count + 1
                        fields["$pos_" .. tostring(idx_count)] = val_type
                    end
                elseif fb and fb ~= byte("}") and fb ~= byte(",") and fb ~= byte(";") then
                    -- Positional type starting with non-ident char
                    local val_type = parse_type(s)
                    idx_count = idx_count + 1
                    fields["$pos_" .. tostring(idx_count)] = val_type
                else
                    break
                end
                if not (opt_char(s, ",") or opt_char(s, ";")) then break end
            end
        end
        expect_char(s, "}")
        s.depth = s.depth - 1
        if row_id >= 0 then
            -- Construct rowvar inline so the checker sees TRowVar shape directly.
            local rv = { tag = "rowvar", id = row_id }
            return types_mod.record_open(fields, rv)
        end
        return types_mod.record(fields)
    end

    -- Spread: ...T
    if b == B_DOT and s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
        s.pos = s.pos + 3
        local inner = parse_type(s)
        s.depth = s.depth - 1
        return types_mod.app(types_mod.const("$Spread"), inner)
    end

    -- Word: primitive, keyword, or named type
    if is_ident_start(b) then
        local word = scan_word(s) or ""

        -- typeof <ident>
        if word == "typeof" then
            local ident = scan_word(s)
            if not ident then scan_error(s, "expected identifier after 'typeof'") end
            s.depth = s.depth - 1
            return types_mod.app(types_mod.const("$Typeof"), types_mod.const(ident))
        end

        -- true / false literals
        if word == "true" then
            s.depth = s.depth - 1
            return types_mod.app(types_mod.const("$LitBool"), types_mod.const("true"))
        end
        if word == "false" then
            s.depth = s.depth - 1
            return types_mod.app(types_mod.const("$LitBool"), types_mod.const("false"))
        end

        -- Primitives
        local pname = prim_names[word]
        if pname then
            s.depth = s.depth - 1
            return types_mod.const(pname)
        end

        -- 'function' keyword followed by '(' → re-enter with '(' handling
        if word == "function" and peek(s) == byte("(") then
            s.depth = s.depth - 1
            -- parse_primary will increment and decrement depth itself
            return parse_primary(s)
        end

        -- Named type with optional generic args: Name or Name<T, U>
        local base = types_mod.const(word)
        if peek(s) == byte("<") then
            advance(s)
            local args = { parse_type(s) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s)
            end
            expect_char(s, ">")
            -- Curried application
            local cur = base
            for i = 1, #args do
                local a = args[i]
                if a ~= nil then cur = types_mod.app(cur, a) end
            end
            s.depth = s.depth - 1
            return cur
        end
        s.depth = s.depth - 1
        return base
    end

    scan_error(s, "unexpected character '" .. string.char(b) .. "'")
end

-- parse_postfix: array sugar T[] and indexed access T[K]
--: (AnnScanner) -> V5Type
local function parse_postfix(s)
    local ty = parse_primary(s)
    while true do
        if peek(s) == byte("[") then
            advance(s)
            if peek(s) == byte("]") then
                advance(s)
                -- T[] → { [integer]: T }
                ty = types_mod.app(types_mod.app(types_mod.const("$Idx"), types_mod.const("integer")), ty)
            else
                local key = parse_type(s)
                expect_char(s, "]")
                -- T[K] → $IndexAccess(T, K)
                ty = types_mod.app(types_mod.app(types_mod.const("$IndexAccess"), ty), key)
            end
        elseif peek(s) == byte("?") then
            -- T? is not valid; skip and continue
            advance(s)
        else
            break
        end
    end
    return ty
end

-- parse_intersection: A & B
--: (AnnScanner) -> V5Type
local function parse_intersection(s)
    local left = parse_postfix(s)
    if not opt_char(s, "&") then return left end
    local parts = { left, parse_postfix(s) } --[[: V5Type[] ]]
    while opt_char(s, "&") do
        parts[#parts + 1] = parse_postfix(s)
    end
    return types_mod.intersection(parts)
end

-- parse_type: union and top-level right-associative ->
parse_type = function(s)
    local left = parse_intersection(s)
    if opt_char(s, "|") then
        local xs = { left, parse_intersection(s) } --[[: V5Type[] ]]
        while opt_char(s, "|") do
            xs[#xs + 1] = parse_intersection(s)
        end
        left = types_mod.union(xs)
    end
    -- Top-level bare arrow: A -> B (right-associative single-param shorthand)
    skip_ws(s)
    if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
        s.pos = s.pos + 2
        skip_ws(s)
        local ret
        if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
            s.pos = s.pos + 3
            expect_char(s, "(")
            local inner = parse_type(s)
            expect_char(s, ")")
            ret = types_mod.app(types_mod.const("$Spread"), inner)
        else
            ret = parse_type(s)
        end
        return types_mod.arrow({ left }, { ret })
    end
    return left
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- parse_annotation: parse a type annotation string into a V5Type.
-- Returns (V5Type, nil) on success, (nil, errmsg) on failure.
--: (string) -> (V5Type | nil, string | nil)
function M.parse_annotation(text)
    local s = new_scanner(text)
    local ok, result = pcall(parse_type, s)
    if not ok then
        return nil, tostring(result)
    end
    -- Warn on trailing tokens but still return the type.
    skip_ws(s)
    if s.pos <= s.len then
        local rest = sub(s.src, s.pos)
        if #rest > 32 then rest = sub(rest, 1, 32) .. "..." end
        return result, "trailing tokens ignored: `" .. rest .. "`"
    end
    return result, nil
end

-- parse_declaration: parse a --:: declaration line.
-- Returns (directive_table, nil) or (nil, errmsg).
--
-- Supported directive kinds (mirrors v4's ANN_DECL / module / require / etc.):
--   { kind = "type_alias",  name = string, type = V5Type, params = string[]? }
--   { kind = "declare_var", name = string, type = V5Type }
--   { kind = "declare_effect", name = string, arity = integer }
--   { kind = "module",      mod_name = string, type = V5Type }
--   { kind = "require",     mod_name = string }
--   { kind = "template" }
--
--: (string) -> ({ [string]: unknown } | nil, string | nil)
function M.parse_declaration(text)
    local s = new_scanner(text)
    local ok, result = pcall(function()
        local word = scan_word(s)
        if not word then scan_error(s, "expected declaration keyword") end

        -- --:: template
        if word == "template" then
            skip_ws(s)
            if s.pos <= s.len then
                scan_error(s, "unexpected tokens after 'template'")
            end
            return { kind = "template" }
        end

        -- --:: declare [effect] name = type  or  --:: declare effect !Name : N
        if word == "declare" then
            skip_ws(s)
            -- Peek for 'effect' keyword
            local save = s.pos
            local kw = scan_word(s)
            if kw == "effect" then
                -- --:: declare effect !Name : N
                skip_ws(s)
                if peek(s) ~= B_BANG then
                    scan_error(s, "expected '!' before effect name in 'declare effect'")
                end
                advance(s)  -- skip '!'
                local eff_name = scan_word(s)
                if not eff_name then scan_error(s, "expected effect name after '!'") end
                expect_char(s, ":")
                skip_ws(s)
                -- Parse arity integer
                local start = s.pos
                while s.pos <= s.len and is_digit(byte(s.src, s.pos)) do
                    s.pos = s.pos + 1
                end
                if s.pos == start then scan_error(s, "expected integer arity after ':'") end
                local arity = tonumber(sub(s.src, start, s.pos - 1)) or 0
                M.declare_effect(eff_name, arity)
                return { kind = "declare_effect", name = eff_name, arity = arity }
            end
            -- Not 'effect': rewind and parse as declare var
            s.pos = save
            local vname = scan_word(s)
            if not vname then scan_error(s, "expected name after 'declare'") end
            expect_char(s, "=")
            local ty = parse_type(s)
            skip_ws(s)
            if s.pos <= s.len then
                local rest = sub(s.src, s.pos, s.pos + 31)
                scan_error(s, "unexpected trailing tokens: `" .. rest .. "`")
            end
            return { kind = "declare_var", name = vname, type = ty }
        end

        -- --:: module "name": T
        if word == "module" then
            local mod_name = scan_string_lit(s)
            expect_char(s, ":")
            local ty = parse_type(s)
            skip_ws(s)
            if s.pos <= s.len then
                scan_error(s, "unexpected trailing tokens after module declaration")
            end
            return { kind = "module", mod_name = mod_name, type = ty }
        end

        -- --:: require "mod.path"
        if word == "require" then
            local mod_name = scan_string_lit(s)
            skip_ws(s)
            if s.pos <= s.len then
                scan_error(s, "unexpected trailing tokens after require")
            end
            return { kind = "require", mod_name = mod_name }
        end

        -- --:: Name<T...> = type  (type alias)
        local alias_name = word
        local params = nil --[[: string[] | nil ]]
        if peek(s) == byte("<") then
            advance(s)
            params = {} --[[: string[] ]]
            local p = scan_word(s)
            if not p then scan_error(s, "expected type parameter") end
            params[1] = p
            while opt_char(s, ",") do
                local q = scan_word(s)
                if not q then scan_error(s, "expected type parameter") end
                params[#params + 1] = q
            end
            expect_char(s, ">")
        end
        expect_char(s, "=")
        local ty = parse_type(s)
        skip_ws(s)
        if s.pos <= s.len then
            local rest = sub(s.src, s.pos, s.pos + 31)
            scan_error(s, "unexpected trailing tokens: `" .. rest .. "`")
        end
        return { kind = "type_alias", name = alias_name, type = ty, params = params }
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

-- Expose parse_type for testing (internal use).
M._parse_type = parse_type
M._new_scanner = new_scanner

return M
