-- lib/type/static/v2/ann.lua
-- Annotation parser for the v2 typechecker.
-- Parses --: / --:: / --[[: type annotation content strings into flat
-- TypeSlot entries in a type arena. Returns type IDs (int32).

local defs = require("lib.type.static.v2.defs")
local arena_mod = require("lib.type.static.v2.arena")
local intern_mod = require("lib.type.static.v2.intern")

local format = string.format
local byte = string.byte
local sub = string.sub

local M = {}

-- Byte constants
local B_SPACE = 32
local B_TAB   = 9
local B_NL    = 10
local B_CR    = 13
local B_a = 97; local B_z = 122
local B_A = 65; local B_Z = 90
local B_0 = 48; local B_9 = 57
local B_UNDER = 95
local B_DQUOT = 34
local B_SQUOT = 39
local B_DOT   = 46
local B_DOLLAR = 36

local function is_ident_start(b)
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z) or b == B_UNDER
end

local function is_ident(b)
    return is_ident_start(b) or (b >= B_0 and b <= B_9)
end

local function is_digit(b)
    return b >= B_0 and b <= B_9
end

-- Primitive name → type tag
local prim_tags = {
    ["nil"]     = defs.TAG_NIL,
    ["boolean"] = defs.TAG_BOOLEAN,
    ["number"]  = defs.TAG_NUMBER,
    ["string"]  = defs.TAG_STRING,
    ["integer"] = defs.TAG_INTEGER,
    ["any"]     = defs.TAG_ANY,
    ["never"]   = defs.TAG_NEVER,
}

---------------------------------------------------------------------------
-- Scanner: minimal lexer for type expression strings
---------------------------------------------------------------------------

local function new_scanner(content, filename, line)
    return {
        src = content,
        pos = 1,
        len = #content,
        filename = filename or "?",
        line = line or 0,
    }
end

local function scan_error(s, msg)
    error(format("%s:%d: annotation: %s (at col %d)", s.filename, s.line, msg, s.pos), 0)
end

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

local function peek(s)
    skip_ws(s)
    if s.pos > s.len then return nil end
    return byte(s.src, s.pos)
end

local function peek_raw(s)
    if s.pos > s.len then return nil end
    return byte(s.src, s.pos)
end

local function advance(s)
    s.pos = s.pos + 1
end

local function expect_char(s, ch)
    skip_ws(s)
    if s.pos > s.len or byte(s.src, s.pos) ~= byte(ch) then
        scan_error(s, "expected '" .. ch .. "'")
    end
    s.pos = s.pos + 1
end

local function opt_char(s, ch)
    skip_ws(s)
    if s.pos <= s.len and byte(s.src, s.pos) == byte(ch) then
        s.pos = s.pos + 1
        return true
    end
    return false
end

local function scan_word(s)
    skip_ws(s)
    local start = s.pos
    if s.pos > s.len then return nil end
    local b = byte(s.src, s.pos)
    if not is_ident_start(b) then return nil end
    s.pos = s.pos + 1
    while s.pos <= s.len and is_ident(byte(s.src, s.pos)) do
        s.pos = s.pos + 1
    end
    return sub(s.src, start, s.pos - 1)
end

local function scan_string(s)
    skip_ws(s)
    local b = byte(s.src, s.pos)
    if b ~= B_DQUOT and b ~= B_SQUOT then
        scan_error(s, "expected string literal")
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
    scan_error(s, "unterminated string")
end

local function scan_number(s)
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
    return tonumber(sub(s.src, start, s.pos - 1))
end

local function at_end(s)
    skip_ws(s)
    return s.pos > s.len
end

---------------------------------------------------------------------------
-- Type expression parser
---------------------------------------------------------------------------

function M.parse_annotations(annotations, pool, filename)
    pool = pool or intern_mod.new()
    filename = filename or "?"
    local types = arena_mod.new_type_arena(64)
    local fields = arena_mod.new_field_arena(32)
    local type_lists = arena_mod.new_list_pool(128)

    local function alloc_type(tag)
        local i = types:alloc()
        local t = types:get(i)
        t.tag = tag
        t.flags = 0
        t.reserved = 0
        t.data[0] = 0; t.data[1] = 0; t.data[2] = 0
        t.data[3] = 0; t.data[4] = 0; t.data[5] = 0; t.data[6] = 0
        return i
    end

    local function flush_type_list(items)
        local m = type_lists:mark()
        for i = 1, #items do type_lists:push(items[i]) end
        return type_lists:since(m)
    end

    -- Forward declaration
    local parse_type

    -- Parse primary (non-union, non-intersection) type
    local function parse_primary(s)
        local b = peek(s)
        if not b then scan_error(s, "unexpected end of type") end

        -- String literal type: "foo"
        if b == B_DQUOT or b == B_SQUOT then
            local str = scan_string(s)
            local id = alloc_type(defs.TAG_LITERAL)
            local t = types:get(id)
            t.data[0] = defs.LIT_STRING
            t.data[1] = intern_mod.intern(pool, str)
            return id
        end

        -- Number literal type
        if is_digit(b) then
            local num = scan_number(s)
            local id = alloc_type(defs.TAG_LITERAL)
            local t = types:get(id)
            t.data[0] = defs.LIT_NUMBER
            t.data[1] = intern_mod.intern(pool, tostring(num))
            return id
        end

        -- Intrinsic: $Name or $Name<args>
        if b == B_DOLLAR then
            advance(s)
            local name = scan_word(s)
            if not name then scan_error(s, "expected intrinsic name after '$'") end
            local name_id = intern_mod.intern(pool, name)
            local base = alloc_type(defs.TAG_INTRINSIC)
            types:get(base).data[0] = name_id
            -- Check for type args
            if peek(s) == byte("<") then
                advance(s)  -- skip '<'
                local args = { parse_type(s) }
                while opt_char(s, ",") do
                    args[#args + 1] = parse_type(s)
                end
                expect_char(s, ">")
                local as, al = flush_type_list(args)
                local call = alloc_type(defs.TAG_TYPE_CALL)
                local ct = types:get(call)
                ct.data[0] = base
                ct.data[1] = as
                ct.data[2] = al
                return call
            end
            return base
        end

        -- Parenthesized type, tuple, or function type
        if b == byte("(") then
            advance(s)  -- skip '('
            -- Empty parens → unit function?
            if peek(s) == byte(")") then
                advance(s)  -- skip ')'
                -- Check for -> (function with no params)
                skip_ws(s)
                if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
                    s.pos = s.pos + 2
                    local ret = parse_type(s)
                    local fn = alloc_type(defs.TAG_FUNCTION)
                    local ft = types:get(fn)
                    -- no params, no returns list — single return
                    local rs, rl = flush_type_list({ ret })
                    ft.data[2] = rs
                    ft.data[3] = rl
                    ft.data[4] = -1
                    return fn
                end
                -- Empty tuple
                local id = alloc_type(defs.TAG_TUPLE)
                return id
            end
            local items = { parse_type(s) }
            while opt_char(s, ",") do
                items[#items + 1] = parse_type(s)
            end
            expect_char(s, ")")
            -- Check for -> (function type)
            skip_ws(s)
            if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
                s.pos = s.pos + 2
                -- Parse return type(s)
                local returns = {}
                if peek(s) == byte("(") then
                    advance(s)
                    if peek(s) ~= byte(")") then
                        returns[1] = parse_type(s)
                        while opt_char(s, ",") do
                            returns[#returns + 1] = parse_type(s)
                        end
                    end
                    expect_char(s, ")")
                else
                    returns[1] = parse_type(s)
                end
                -- Extract trailing spread as vararg
                local vararg_ann_id = -1
                if #items > 0 then
                    local last_t = types:get(items[#items])
                    if last_t.tag == defs.TAG_SPREAD then
                        vararg_ann_id = last_t.data[0]
                        items[#items] = nil
                    end
                end
                local ps, pl = flush_type_list(items)
                local rs, rl = flush_type_list(returns)
                local fn = alloc_type(defs.TAG_FUNCTION)
                local ft = types:get(fn)
                ft.data[0] = ps
                ft.data[1] = pl
                ft.data[2] = rs
                ft.data[3] = rl
                ft.data[4] = vararg_ann_id
                return fn
            end
            -- Single item in parens → just the type
            if #items == 1 then return items[1] end
            -- Multiple items → tuple
            local es, el = flush_type_list(items)
            local tuple = alloc_type(defs.TAG_TUPLE)
            types:get(tuple).data[0] = es
            types:get(tuple).data[1] = el
            return tuple
        end

        -- Table type: { ... }
        if b == byte("{") then
            advance(s)  -- skip '{'
            local flds = {}
            local indexers = {}
            local metas = {}
            if peek(s) ~= byte("}") then
                while true do
                    local fb = peek(s)
                    if fb == byte("#") then
                        -- Meta slot: #__add: type
                        advance(s)
                        local name = scan_word(s)
                        if not name then scan_error(s, "expected meta name after '#'") end
                        local optional = opt_char(s, "?")
                        expect_char(s, ":")
                        local ftype = parse_type(s)
                        local fi = fields:alloc()
                        local fe = fields:get(fi)
                        fe.name_id = intern_mod.intern(pool, name)
                        fe.type_id = ftype
                        fe.optional = optional and 1 or 0
                        metas[#metas + 1] = fi
                    elseif fb == byte("[") then
                        -- Indexer: [K]: V
                        advance(s)
                        local key_type = parse_type(s)
                        expect_char(s, "]")
                        expect_char(s, ":")
                        local val_type = parse_type(s)
                        indexers[#indexers + 1] = key_type
                        indexers[#indexers + 1] = val_type
                    elseif fb and is_ident_start(fb) then
                        -- Field: name?: type
                        local save_pos = s.pos
                        local name = scan_word(s)
                        -- Check if followed by : or ?: (field) or something else
                        local next_b = peek(s)
                        if next_b == byte(":") or next_b == byte("?") then
                            local optional = opt_char(s, "?")
                            expect_char(s, ":")
                            local ftype = parse_type(s)
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = intern_mod.intern(pool, name)
                            fe.type_id = ftype
                            fe.optional = optional and 1 or 0
                            flds[#flds + 1] = fi
                        else
                            -- Not a field declaration, might be just a type (positional)
                            -- Rewind and parse as type
                            s.pos = save_pos
                            -- Positional entry — treat as indexer [number]: T
                            local val_type = parse_type(s)
                            local num_type = alloc_type(defs.TAG_NUMBER)
                            indexers[#indexers + 1] = num_type
                            indexers[#indexers + 1] = val_type
                        end
                    elseif fb == byte(".") and s.pos + 2 <= s.len
                        and sub(s.src, s.pos, s.pos + 2) == "..." then
                        -- Spread: ...T
                        s.pos = s.pos + 3
                        local inner = parse_type(s)
                        local sp = alloc_type(defs.TAG_SPREAD)
                        types:get(sp).data[0] = inner
                        -- Spread in table context — store as special field
                        local fi = fields:alloc()
                        local fe = fields:get(fi)
                        fe.name_id = -1  -- spread marker
                        fe.type_id = sp
                        fe.optional = 0
                        flds[#flds + 1] = fi
                    else
                        break
                    end
                    if not (opt_char(s, ",") or opt_char(s, ";")) then
                        break
                    end
                end
            end
            expect_char(s, "}")
            local fs, fl = 0, 0
            if #flds > 0 then
                local m = type_lists:mark()
                for i = 1, #flds do type_lists:push(flds[i]) end
                fs, fl = type_lists:since(m)
            end
            local is, il = 0, 0
            if #indexers > 0 then
                is, il = flush_type_list(indexers)
            end
            local ms, ml = 0, 0
            if #metas > 0 then
                local m = type_lists:mark()
                for i = 1, #metas do type_lists:push(metas[i]) end
                ms, ml = type_lists:since(m)
            end
            local tbl = alloc_type(defs.TAG_TABLE)
            local tt = types:get(tbl)
            tt.data[0] = fs
            tt.data[1] = fl
            tt.data[2] = is
            tt.data[3] = il
            tt.data[4] = -1  -- row_id (no annotation syntax for row vars yet)
            tt.data[5] = ms
            tt.data[6] = ml
            return tbl
        end

        -- Forall: <T, U> type
        if b == byte("<") then
            advance(s)  -- skip '<'
            local params = {}
            params[1] = scan_word(s)
            if not params[1] then scan_error(s, "expected type parameter") end
            while opt_char(s, ",") do
                local p = scan_word(s)
                if not p then scan_error(s, "expected type parameter") end
                params[#params + 1] = p
            end
            expect_char(s, ">")
            -- Intern type param names
            local param_ids = {}
            for i = 1, #params do
                param_ids[i] = intern_mod.intern(pool, params[i])
            end
            local tps, tpl = flush_type_list(param_ids)
            local body = parse_type(s)
            local forall = alloc_type(defs.TAG_FORALL)
            local ft = types:get(forall)
            ft.data[0] = tps
            ft.data[1] = tpl
            ft.data[2] = body
            return forall
        end

        -- Word: could be primitive, keyword (match/newtype/function), or named type
        if is_ident_start(b) then
            local word = scan_word(s)

            -- Check for primitive
            local prim = prim_tags[word]
            if prim then
                return alloc_type(prim)
            end

            -- match T { ... }
            if word == "match" then
                local param = parse_type(s)
                expect_char(s, "{")
                local arms = {}
                while peek(s) ~= byte("}") do
                    local pat = parse_type(s)
                    skip_ws(s)
                    if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "=>" then
                        s.pos = s.pos + 2
                    else
                        scan_error(s, "expected '=>' in match arm")
                    end
                    local result = parse_type(s)
                    arms[#arms + 1] = pat
                    arms[#arms + 1] = result
                    opt_char(s, ",")
                end
                expect_char(s, "}")
                local as, al = flush_type_list(arms)
                local mt = alloc_type(defs.TAG_MATCH_TYPE)
                local mtt = types:get(mt)
                mtt.data[0] = param
                mtt.data[1] = as
                mtt.data[2] = al
                return mt
            end

            -- newtype Name = T (only in decl context, but parse it anyway)
            if word == "newtype" then
                local name = scan_word(s)
                if not name then scan_error(s, "expected name after 'newtype'") end
                expect_char(s, "=")
                local underlying = parse_type(s)
                local nom = alloc_type(defs.TAG_NOMINAL)
                local nt = types:get(nom)
                nt.data[0] = intern_mod.intern(pool, name)
                nt.data[1] = 0  -- identity (assigned by checker)
                nt.data[2] = underlying
                return nom
            end

            -- function keyword: function(A, B): C
            if word == "function" then
                if peek(s) == byte("(") then
                    return parse_primary(s)  -- re-enter with '(' handling
                end
                -- bare 'function' means any function
                return alloc_type(defs.TAG_FUNCTION)
            end

            -- Named type, possibly with generic args: Name or Name<T, U>
            local name_id = intern_mod.intern(pool, word)
            if peek(s) == byte("<") then
                advance(s)  -- skip '<'
                local args = { parse_type(s) }
                while opt_char(s, ",") do
                    args[#args + 1] = parse_type(s)
                end
                expect_char(s, ">")
                local as, al = flush_type_list(args)
                local named = alloc_type(defs.TAG_NAMED)
                local nt = types:get(named)
                nt.data[0] = name_id
                nt.data[1] = as
                nt.data[2] = al
                return named
            end
            -- Plain name
            local named = alloc_type(defs.TAG_NAMED)
            types:get(named).data[0] = name_id
            return named
        end

        -- Spread: ...T
        if b == byte(".") and s.pos + 2 <= s.len
            and sub(s.src, s.pos, s.pos + 2) == "..." then
            s.pos = s.pos + 3
            local inner = parse_type(s)
            local sp = alloc_type(defs.TAG_SPREAD)
            types:get(sp).data[0] = inner
            return sp
        end

        scan_error(s, "unexpected character '" .. string.char(b) .. "'")
    end

    -- Parse postfix: ? (nullable) and [] (array)
    local function parse_postfix(s)
        local ty = parse_primary(s)
        while true do
            if opt_char(s, "?") then
                -- Nullable: T? → T | nil
                local nil_type = alloc_type(defs.TAG_NIL)
                local ms, ml = flush_type_list({ ty, nil_type })
                local union = alloc_type(defs.TAG_UNION)
                types:get(union).data[0] = ms
                types:get(union).data[1] = ml
                ty = union
            elseif peek(s) == byte("[") then
                -- Check for [] (array) vs [K] (which would be indexer, handled in table)
                local save = s.pos
                advance(s)  -- skip '['
                if peek(s) == byte("]") then
                    advance(s)  -- skip ']'
                    -- Array: T[] → { [number]: T }
                    local num_type = alloc_type(defs.TAG_NUMBER)
                    local is, il = flush_type_list({ num_type, ty })
                    local tbl = alloc_type(defs.TAG_TABLE)
                    local tt = types:get(tbl)
                    tt.data[2] = is  -- indexers
                    tt.data[3] = il
                    ty = tbl
                else
                    -- Not an array suffix, rewind
                    s.pos = save
                    break
                end
            else
                break
            end
        end
        return ty
    end

    -- Parse intersection: A & B
    local function parse_intersection(s)
        local left = parse_postfix(s)
        if not opt_char(s, "&") then return left end
        local members = { left, parse_postfix(s) }
        while opt_char(s, "&") do
            members[#members + 1] = parse_postfix(s)
        end
        local ms, ml = flush_type_list(members)
        local inter = alloc_type(defs.TAG_INTERSECTION)
        types:get(inter).data[0] = ms
        types:get(inter).data[1] = ml
        return inter
    end

    -- Parse union: A | B
    parse_type = function(s)
        local left = parse_intersection(s)
        if not opt_char(s, "|") then return left end
        local members = { left, parse_intersection(s) }
        while opt_char(s, "|") do
            members[#members + 1] = parse_intersection(s)
        end
        local ms, ml = flush_type_list(members)
        local union = alloc_type(defs.TAG_UNION)
        types:get(union).data[0] = ms
        types:get(union).data[1] = ml
        return union
    end

    -------------------------------------------------------------------
    -- Process annotations
    -------------------------------------------------------------------

    local results = {}

    for line, ann in pairs(annotations) do
        local s = new_scanner(ann.content, filename, line)
        local ok, result = pcall(function()
            if ann.kind == defs.ANN_TYPE then
                local type_id = parse_type(s)
                return { kind = defs.ANN_TYPE, type_id = type_id }
            elseif ann.kind == defs.ANN_DECL then
                -- Parse "Name = type" or "Name<T, U> = type" or "newtype Name = type"
                -- Check for newtype or declare
                local save = s.pos
                local word = scan_word(s)
                if word == "declare" then
                    local vname = scan_word(s)
                    if not vname then scan_error(s, "expected name after 'declare'") end
                    local vname_id = intern_mod.intern(pool, vname)
                    expect_char(s, "=")
                    local type_id = parse_type(s)
                    return { kind = defs.ANN_DECL, type_id = type_id, name_id = vname_id, decl_var = true }
                end
                if word == "newtype" then
                    local name = scan_word(s)
                    if not name then scan_error(s, "expected name after 'newtype'") end
                    local name_id = intern_mod.intern(pool, name)
                    expect_char(s, "=")
                    local underlying = parse_type(s)
                    local nom = alloc_type(defs.TAG_NOMINAL)
                    local nt = types:get(nom)
                    nt.data[0] = name_id
                    nt.data[1] = 0
                    nt.data[2] = underlying
                    return { kind = defs.ANN_DECL, type_id = nom, name_id = name_id, newtype = true }
                end
                -- Regular: Name<T...> = type
                local name = word
                if not name then scan_error(s, "expected declaration name") end
                local name_id = intern_mod.intern(pool, name)
                local type_params
                if peek(s) == byte("<") then
                    advance(s)
                    type_params = {}
                    type_params[1] = intern_mod.intern(pool, scan_word(s))
                    while opt_char(s, ",") do
                        local p = scan_word(s)
                        if not p then scan_error(s, "expected type parameter") end
                        type_params[#type_params + 1] = intern_mod.intern(pool, p)
                    end
                    expect_char(s, ">")
                end
                expect_char(s, "=")
                local type_id = parse_type(s)
                local tps, tpl = 0, 0
                if type_params then
                    tps, tpl = flush_type_list(type_params)
                end
                return {
                    kind = defs.ANN_DECL,
                    type_id = type_id,
                    name_id = name_id,
                    type_params_start = tps,
                    type_params_len = tpl,
                }
            elseif ann.kind == defs.ANN_TYPE_ARGS then
                -- Parse <T, U> — type arguments for call-site specialization
                expect_char(s, "<")
                local args = {}
                while true do
                    local b = peek(s)
                    if b == byte("_") then
                        -- Wildcard: infer this param
                        local word = scan_word(s)
                        if word == "_" then
                            args[#args + 1] = -1  -- sentinel for "infer"
                        else
                            args[#args + 1] = parse_type(
                                new_scanner(word .. sub(s.src, s.pos), s.filename, s.line))
                        end
                    elseif b == byte(">") then
                        break
                    else
                        args[#args + 1] = parse_type(s)
                    end
                    if not opt_char(s, ",") then break end
                end
                expect_char(s, ">")
                local as, al = flush_type_list(args)
                return {
                    kind = defs.ANN_TYPE_ARGS,
                    args_start = as,
                    args_len = al,
                }
            end
        end)
        if ok and result then
            results[line] = result
        end
    end

    return {
        types = types,
        fields = fields,
        lists = type_lists,
        results = results,
        pool = pool,
    }
end

return M
