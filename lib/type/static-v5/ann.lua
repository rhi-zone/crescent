-- lib/type/static-v5/ann.lua
-- v5 annotation parser.
--
-- Parses --: / --:: annotation content strings into v5 substrate types
-- (Lua-table V5Type values from lib/type/experiments/v5_perf/types.lua).
--
-- Entry points:
--   M.new_state()                  -> AnnState          (construct per-session state)
--   M.parse_annotation(state, text)   -> V5Type, string|nil   (nil err = ok)
--   M.parse_declaration(state, text)  -> table, string|nil     (directive record)
--   M.declare_effect(state, name, n)  -> nil                   (register arity N for !Name)
--
-- Surface syntax mirrors v4 (lib/type/static/ann.lua) plus:
--   !Name          effect-type head  (N=0 or declared arity)
--   !Name<A, B>    effect-type application (arity must match declaration)
--   --:: declare effect !Name : N   register effect arity

local types_mod = require("lib.type.experiments.v5_perf.types")

local M = {}

-- ── Directive record type declarations ────────────────────────────────────────

-- Note: the `type` fields carry V5Type values at runtime.  We declare them as
-- `unknown` so that callers (e.g. constrain.lua) can access the `kind` and
-- `name` / `arity` fields which have concrete types, while narrowing the `type`
-- field themselves via checked casts in their own V5Type-aware scope.
--:: DeclDirTypeAlias   = { kind: string, name: string, type: unknown, params: string[] | nil }
--:: DeclDirDeclareVar  = { kind: string, name: string, type: unknown }
--:: DeclDirDeclEffect  = { kind: string, name: string, arity: number }
--:: DeclDirModule      = { kind: string, mod_name: string, type: unknown }
--:: DeclDirRequire     = { kind: string, mod_name: string }
--:: DeclDirTemplate    = { kind: string }
--:: V5Directive = DeclDirTypeAlias | DeclDirDeclareVar | DeclDirDeclEffect | DeclDirModule | DeclDirRequire | DeclDirTemplate

-- ── Per-session state ────────────────────────────────────────────────────────

--:: AnnState = { next_rowvar: integer, effect_arities: { [string]: integer } }

-- Construct a fresh parser state.  One state per parse session; never share
-- across concurrent or sequential independent parse calls.
--: () -> AnnState
function M.new_state()
    return { next_rowvar = 1, effect_arities = {} }
end

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
local B_PCT    = 37   -- '%'

-- ── Effect arity registry ───────────────────────────────────────────────────

-- Register a declared effect arity into per-session state.
--: (AnnState, string, number) -> nil
function M.declare_effect(state, name, n)
    state.effect_arities[name] = math.floor(n)
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

--:: AnnScanner = { src: string, pos: integer, len: integer, depth: integer, depth_limit_hit?: boolean, caps?: { [string]: integer }, next_cap?: integer }

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
    local raw = sub(s.src, start, s.pos - 1)
    local n = tonumber(raw)
    if n == nil then
        -- Scanner advanced past digits but tonumber failed: real bug.
        error("annotation: scan_number_lit: failed to parse numeric literal '" .. raw .. "' at col " .. tostring(start), 0)
    end
    return n
end

--: (AnnScanner) -> boolean
local function at_end(s)
    skip_ws(s)
    return s.pos > s.len
end

-- ── Type expression parser ───────────────────────────────────────────────────

-- Forward declaration
local parse_type --[[: (AnnScanner, AnnState) -> V5Type ]]
local parse_match --[[: (AnnScanner, AnnState) -> V5Type ]]

-- Fresh row-variable ID from per-session state.
--: (AnnState) -> integer
local function fresh_rowvar_id(state)
    local id = state.next_rowvar
    state.next_rowvar = id + 1
    return id
end

-- cap_index(s, name): the arm-local binder index for capture `name`, allocating
-- a fresh index on first sight within the current arm.  `s.caps` is the
-- arm-local map (set up per arm by parse_match); when nil, captures are not in
-- a match-arm scope and are treated as a parse error by the caller.
--: (AnnScanner, string) -> integer
local function cap_index(s, name)
    local caps = s.caps
    if caps == nil then caps = {} --[[: { [string]: integer } ]]; s.caps = caps end
    local existing = caps[name]
    if existing ~= nil then return existing end
    local nxt = s.next_cap or 0
    caps[name] = nxt
    s.next_cap = nxt + 1
    return nxt
end

-- parse_primary: parses a single non-union, non-intersection type.
--: (AnnScanner, AnnState) -> V5Type
local function parse_primary(s, state)
    s.depth = s.depth + 1
    if s.depth > MAX_DEPTH then
        s.depth_limit_hit = true
        scan_error(s, "type annotation too deeply nested (max " .. MAX_DEPTH .. ")")
    end

    local b0 = peek(s)
    if not b0 then scan_error(s, "unexpected end of type") end
    local b = b0

    -- String literal: "foo" or 'foo'  → TLiteral (Spec C).
    if b == B_DQUOT or b == B_SQUOT then
        local str = scan_string_lit(s)
        s.depth = s.depth - 1
        return types_mod.literal("string", str)
    end

    -- Number literal → TLiteral (Spec C); integer-valued → base "integer".
    if is_digit(b) then
        local num = scan_number_lit(s)
        s.depth = s.depth - 1
        if num % 1 == 0 then
            return types_mod.literal("integer", math.floor(num))
        else
            return types_mod.literal("number", num)
        end
    end

    -- Capture sigil: %Name (a match pattern capture) or %_ wildcard alias.
    if b == B_PCT then
        advance(s)
        local name = scan_word(s)
        if not name then scan_error(s, "expected capture name after '%'") end
        s.depth = s.depth - 1
        if name == "_" then return types_mod.capture(-1) end
        return types_mod.capture(cap_index(s, name))
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
            local args = { parse_type(s, state) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s, state)
            end
            expect_char(s, ">")
            -- Check arity if declared
            local declared = state.effect_arities[name]
            if declared ~= nil and declared ~= #args then
                scan_error(s, "effect '!" .. name .. "' declared with arity " ..
                    declared .. " but applied to " .. #args .. " arg(s)")
            end
            result = types_mod.effect_apply(eff_head, args)
        else
            -- Bare !Name: allowed when arity == 0 or undeclared
            local declared = state.effect_arities[name]
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
            local args = { parse_type(s, state) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s, state)
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
                local ret = parse_type(s, state)
                s.depth = s.depth - 1
                return types_mod.arrow({}, { ret })
            end
            -- Empty tuple / unit type → the `unit` primitive (Spec C).
            s.depth = s.depth - 1
            return types_mod.const("unit")
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
                    return parse_type(s, state)
                else
                    s.pos = save_pos
                end
            end
            return parse_type(s, state)
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
                local inner = parse_type(s, state)
                expect_char(s, ")")
                -- Spread return: represent as App($Spread, inner)
                ret = types_mod.app(types_mod.const("$Spread"), inner)
            else
                ret = parse_type(s, state)
            end
            -- Unpack tuple return into multi-return list
            local rets = {} --[[: V5Type[] ]]
            if ret.tag == "const" and ret.name == "unit" then
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
        -- Multiple items → tuple type.  Per Spec B, a bare tuple `(A, B)` is a
        -- closed TPack `pack([A, B], nil)` (not a positional record).
        local tup_items = {} --[[: V5Type[] ]]
        for i = 1, #items do
            local v = items[i]
            if v ~= nil then tup_items[i] = v end
        end
        s.depth = s.depth - 1
        return types_mod.pack(tup_items, nil)
    end

    -- Record / table type: { ... }  → three-region TRecord (Spec C).
    if b == byte("{") then
        advance(s)
        local fields = {} --[[: { [string]: TField } ]]
        local indexes = {} --[[: TIndex[] ]]
        local pos_vals = {} --[[: V5Type[] ]]
        local row_id = -1  -- set to fresh ID when bare ... seen (open table)
        if peek(s) ~= byte("}") then
            while true do
                local fb = peek(s)
                if fb == byte("[") then
                    -- Indexer: [K]: V  → an indexes[] entry { key = K, value = V }.
                    advance(s)
                    -- Check for opaque key (bare word not a primitive).
                    local save_bracket = s.pos
                    local bracket_word = scan_word(s)
                    skip_ws(s)
                    local is_opaque = bracket_word and not prim_names[bracket_word]
                        and s.pos <= s.len and byte(s.src, s.pos) == byte("]")
                    if is_opaque and bracket_word then
                        advance(s)  -- consume ']'
                        expect_char(s, ":")
                        local val_type = parse_type(s, state)
                        -- Opaque key: a single-key index signature (key = Const(K)).
                        indexes[#indexes + 1] =
                            types_mod.index(types_mod.const(bracket_word), val_type, false)
                    else
                        s.pos = save_bracket
                        local key_type = parse_type(s, state)
                        expect_char(s, "]")
                        expect_char(s, ":")
                        local val_type = parse_type(s, state)
                        indexes[#indexes + 1] = types_mod.index(key_type, val_type, false)
                    end
                elseif fb == byte(".") and s.pos + 2 <= s.len
                    and sub(s.src, s.pos, s.pos + 2) == "..." then
                    s.pos = s.pos + 3
                    local nb = peek(s)
                    if nb == byte("[") then
                        -- All-fields distribution `{ ...[%K]: %V }` (Spec B match
                        -- pattern): the `...` here means ITERATE per field.  K/V are
                        -- captures; lower to a TPatAllFields holding their binder idxs.
                        advance(s)  -- consume '['
                        local kt = parse_type(s, state)
                        expect_char(s, "]")
                        expect_char(s, ":")
                        local vt = parse_type(s, state)
                        if kt.tag ~= "capture" or vt.tag ~= "capture" then
                            scan_error(s, "'{ ...[%K]: %V }' requires capture key and value")
                        end
                        expect_char(s, "}")
                        s.depth = s.depth - 1
                        return types_mod.patallfields(kt.idx, vt.idx)
                    elseif nb == byte("%") then
                        -- Rest-field capture `{ f: T, ...%Rest }` (Spec B match
                        -- pattern): bind the unmatched fields.  Stored as the reserved
                        -- field "..." carrying the capture.
                        local rest = parse_primary(s, state)
                        if rest.tag ~= "capture" then
                            scan_error(s, "'...%Rest' requires a capture name")
                        end
                        local rest_key = "..." --[[: string ]]
                        fields[rest_key] = types_mod.field(rest, false, false)
                    elseif nb == byte("}") or nb == byte(",") or nb == byte(";") or not nb then
                        -- Bare ...: open-table row variable.
                        row_id = fresh_rowvar_id(state)
                        break
                    else
                        -- ...T: record spread.  Spec C defers record spread to Spec
                        -- B's TPack rest; the v5.0 surface lowers it conservatively
                        -- to a string-keyed index signature over the spread base.
                        local inner = parse_type(s, state)
                        indexes[#indexes + 1] =
                            types_mod.index(types_mod.const("string"), inner, false)
                    end
                elseif fb and is_ident_start(fb) then
                    -- Named field: [readonly] name[?]: type
                    local save_pos = s.pos
                    local word = scan_word(s)
                    -- Check for 'readonly' modifier.
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
                        local ftype = parse_type(s, state)
                        -- Optional/readonly are real attributes on the TField.
                        fields[fname or ""] = types_mod.field(ftype, optional, is_readonly)
                    else
                        -- Positional type entry (array element).
                        s.pos = save_pos
                        local val_type = parse_type(s, state)
                        pos_vals[#pos_vals + 1] = val_type
                    end
                elseif fb and fb ~= byte("}") and fb ~= byte(",") and fb ~= byte(";") then
                    -- Positional type starting with non-ident char.
                    local val_type = parse_type(s, state)
                    pos_vals[#pos_vals + 1] = val_type
                else
                    break
                end
                if not (opt_char(s, ",") or opt_char(s, ";")) then break end
            end
        end
        expect_char(s, "}")
        s.depth = s.depth - 1
        -- Positional entries → one integer-keyed index signature (value = union of
        -- the positional element types).  Positional records are retired (Spec C).
        if #pos_vals > 0 then
            indexes[#indexes + 1] =
                types_mod.index(types_mod.const("integer"), types_mod.union(pos_vals), false)
        end
        if row_id >= 0 then
            -- Construct rowvar inline so the checker sees TRowVar shape directly.
            local rv = { tag = "rowvar", id = row_id }
            return types_mod.record_full(fields, indexes, rv)
        end
        return types_mod.record_full(fields, indexes, nil)
    end

    -- Spread: ...T
    if b == B_DOT and s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
        s.pos = s.pos + 3
        local inner = parse_type(s, state)
        s.depth = s.depth - 1
        return types_mod.app(types_mod.const("$Spread"), inner)
    end

    -- Word: primitive, keyword, or named type
    if is_ident_start(b) then
        local word = scan_word(s) or ""

        -- typeof <ident>
        if word == "typeof" then
            scan_word(s) -- consume the identifier even though we error
            scan_error(s, "'typeof' is not yet supported in v5 annotations")
        end

        -- match Scrutinee { Pat => Res, ... }  → TMatch (Spec B)
        if word == "match" then
            s.depth = s.depth - 1
            return parse_match(s, state)
        end

        -- `_` wildcard pattern: always matches, no binding.
        if word == "_" then
            s.depth = s.depth - 1
            return types_mod.capture(-1)
        end

        -- Bare ident bound as a capture in the current arm → capture reference.
        if s.caps ~= nil and s.caps[word] ~= nil then
            local cidx = s.caps[word]
            s.depth = s.depth - 1
            if cidx == nil then return types_mod.const(word) end
            return types_mod.capture(cidx)
        end

        -- true / false literals → TLiteral (Spec C).
        if word == "true" then
            s.depth = s.depth - 1
            return types_mod.literal("boolean", true)
        end
        if word == "false" then
            s.depth = s.depth - 1
            return types_mod.literal("boolean", false)
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
            return parse_primary(s, state)
        end

        -- Named type with optional generic args: Name or Name<T, U>
        local base = types_mod.const(word)
        if peek(s) == byte("<") then
            advance(s)
            local args = { parse_type(s, state) } --[[: V5Type[] ]]
            while opt_char(s, ",") do
                args[#args + 1] = parse_type(s, state)
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
--: (AnnScanner, AnnState) -> V5Type
local function parse_postfix(s, state)
    local ty = parse_primary(s, state)
    while true do
        if peek(s) == byte("[") then
            advance(s)
            if peek(s) == byte("]") then
                advance(s)
                -- T[] → { [integer]: T } as a three-region TRecord (Spec C).
                local idxs = {} --[[: TIndex[] ]]
                idxs[1] = types_mod.index(types_mod.const("integer"), ty, false)
                ty = types_mod.record_full({} --[[: { [string]: TField } ]], idxs, nil)
            else
                -- T[K] index-access is not yet supported in v5 annotations
                scan_error(s, "'T[K]' index-access is not yet supported in v5 annotations")
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
--: (AnnScanner, AnnState) -> V5Type
local function parse_intersection(s, state)
    local left = parse_postfix(s, state)
    if not opt_char(s, "&") then return left end
    local parts = { left, parse_postfix(s, state) } --[[: V5Type[] ]]
    while opt_char(s, "&") do
        parts[#parts + 1] = parse_postfix(s, state)
    end
    return types_mod.intersection(parts)
end

-- parse_match: `match` already consumed.  Parse the scrutinee, then a
-- brace-delimited list of `Pattern => Result` arms separated by ',' or '|'.
-- Each arm has its own capture scope (s.caps / s.next_cap reset per arm).
parse_match = function(s, state)
    skip_ws(s)
    -- Scrutinee: parse at the intersection level (stops before the '{' arm block).
    local saved_caps = s.caps
    local saved_next = s.next_cap
    s.caps = nil  -- scrutinee is not a pattern: no capture scope
    s.next_cap = nil
    local scrutinee = parse_intersection(s, state)
    s.caps = saved_caps
    s.next_cap = saved_next
    skip_ws(s)
    expect_char(s, "{")
    local arms = {} --[[: TMatchArm[] ]]
    skip_ws(s)
    if peek(s) ~= byte("}") then
        while true do
            -- Fresh arm-local capture scope.
            s.caps = {} --[[: { [string]: integer } ]]
            s.next_cap = 0
            local pattern = parse_intersection(s, state)
            skip_ws(s)
            if not (s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "=>") then
                scan_error(s, "expected '=>' in match arm")
            end
            s.pos = s.pos + 2
            -- Result shares the arm's capture scope (bare names resolve to captures).
            local result = parse_type(s, state)
            arms[#arms + 1] = { pattern = pattern, result = result }
            s.caps = nil
            s.next_cap = nil
            skip_ws(s)
            if not (opt_char(s, ",") or opt_char(s, "|")) then break end
            skip_ws(s)
            if peek(s) == byte("}") then break end
        end
    end
    expect_char(s, "}")
    return types_mod.match(scrutinee, arms)
end

-- parse_type: union and top-level right-associative ->
parse_type = function(s, state)
    local left = parse_intersection(s, state)
    if opt_char(s, "|") then
        local xs = { left, parse_intersection(s, state) } --[[: V5Type[] ]]
        while opt_char(s, "|") do
            xs[#xs + 1] = parse_intersection(s, state)
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
            local inner = parse_type(s, state)
            expect_char(s, ")")
            ret = types_mod.app(types_mod.const("$Spread"), inner)
        else
            ret = parse_type(s, state)
        end
        return types_mod.arrow({ left }, { ret })
    end
    return left
end

-- ── Public API ───────────────────────────────────────────────────────────────

-- parse_annotation: parse a type annotation string into a V5Type.
-- Returns (V5Type, nil) on success, (nil, errmsg) on failure.
--: (AnnState, string) -> (V5Type | nil, string | nil)
function M.parse_annotation(state, text)
    local s = new_scanner(text)
    local ok, result = pcall(parse_type, s, state)
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
--: (AnnState, string) -> (V5Directive | nil, string | nil)
function M.parse_declaration(state, text)
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
                M.declare_effect(state, eff_name, arity)
                return { kind = "declare_effect", name = eff_name, arity = arity }
            end
            -- Not 'effect': rewind and parse as declare var
            s.pos = save
            local vname = scan_word(s)
            if not vname then scan_error(s, "expected name after 'declare'") end
            expect_char(s, "=")
            local ty = parse_type(s, state)
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
            local ty = parse_type(s, state)
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

        -- --:: augment Name { ... }  (v4 directive; not yet supported in v5)
        if word == "augment" then
            scan_error(s, "augment declarations are not yet supported in v5 (tracked gap)")
        end

        -- --:: unseal Name  (v4 directive; not yet supported in v5)
        if word == "unseal" then
            scan_error(s, "unseal declarations are not yet supported in v5 (tracked gap)")
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
        local ty = parse_type(s, state)
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

-- Expose internals for testing (internal use only).
M._new_scanner = new_scanner
M._parse_type  = parse_type

return M
