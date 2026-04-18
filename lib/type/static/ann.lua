-- lib/type/static/ann.lua
-- Annotation parser for the typechecker.
-- Parses --: / --:: / --[[: type annotation content strings into flat
-- TypeSlot entries in a type arena. Returns type IDs (int32).

local defs = require("lib.type.static.defs")
local arena_mod = require("lib.type.static.arena")
local intern_mod = require("lib.type.static.intern")
local double_to_i32x2 = defs.double_to_i32x2
local band = require("bit").band

local FLAG_OPTIONAL  = defs.FLAG_OPTIONAL
local FLAG_READONLY  = defs.FLAG_READONLY
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY

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
local B_PERCENT = 37

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
    ["unknown"] = defs.TAG_UNKNOWN,
    ["cdata"]   = defs.TAG_CDATA,
}

---------------------------------------------------------------------------
-- Scanner: minimal lexer for type expression strings
---------------------------------------------------------------------------

--:: Scanner = { src: string, pos: integer, len: integer, filename: string, line: integer }

--: (string, string | nil, integer | nil) -> Scanner
local function new_scanner(content, filename, line)
    return {
        src = content,
        pos = 1,
        len = #content,
        filename = filename or "?",
        line = line or 0,
        depth = 0,   -- recursive parse_type depth; guards against stack overflow
    }
end

local MAX_TYPE_DEPTH = 64  -- parser stack limit; deeply-nested types beyond this produce an error

--: (Scanner, string) -> never
local function scan_error(s, msg)
    error(format("%s:%d: annotation: %s (at col %d)", s.filename, s.line, msg, s.pos), 0)
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

--: (Scanner) -> integer | nil
local function peek_raw(s)
    if s.pos > s.len then return nil end
    return byte(s.src, s.pos)
end

--: (Scanner) -> nil
local function advance(s)
    s.pos = s.pos + 1
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

--: (Scanner) -> string
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

--: (Scanner) -> number
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

--: (Scanner) -> boolean
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

    --: ({ [integer]: integer, ... }) -> (integer, integer)
    local function flush_type_list(items)
        local m = type_lists:mark()
        for i = 1, #items do type_lists:push(items[i]) end
        return type_lists:since(m)
    end

    -- Forward declaration
    local parse_type

    -- Accumulated parse warnings and errors (populated during parsing, returned with the result).
    local warnings = {}
    local parse_errors = {}  -- errors that survive the inner pcall (ordering errors, etc.)

    -- Check if an annotation type ID is a union containing at least one function type.
    -- Used to warn on `(A) -> B | (C) -> D` which parses as `(A) -> (B | (C) -> D)`.
    local function union_contains_fn(tid)
        local t = types:get(tid)
        if t.tag ~= defs.TAG_UNION then return false end
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            if types:get(type_lists:get(i)).tag == defs.TAG_FUNCTION then return true end
        end
        return false
    end

    -- Parse primary (non-union, non-intersection) type
    local function parse_primary(s)
        local b0 = peek(s)
        if not b0 then scan_error(s, "unexpected end of type") end
        local b = b0 or 0  -- non-nil guaranteed by scan_error above

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
            if num % 1 == 0 and num >= -(2^31) and num <= 2^31 - 1 then
                t.data[0] = defs.LIT_INTEGER
                t.data[1] = math.floor(num)
            else
                t.data[0] = defs.LIT_NUMBER
                t.data[1], t.data[2] = double_to_i32x2(num)
            end
            return id
        end

        -- Intrinsic: $Name or $Name<args>
        if b == B_DOLLAR then
            advance(s)
            local name = scan_word(s)
            if not name then scan_error(s, "expected intrinsic name after '$'") end
            -- $FfiC is a zero-argument magic type: the live ffi.C table.
            if name == "FfiC" then
                return alloc_type(defs.TAG_FFIC)
            end
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
                    skip_ws(s)
                    local ret
                    if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
                        -- -> ...(T): explicit multi-return spread
                        s.pos = s.pos + 3
                        expect_char(s, "(")
                        local inner = parse_type(s)
                        expect_char(s, ")")
                        local sp = alloc_type(defs.TAG_SPREAD)
                        types:get(sp).data[0] = inner
                        ret = sp
                    else
                        ret = parse_type(s)
                        if union_contains_fn(ret) then
                            warnings[#warnings + 1] = { line = s.line, col = 1,
                                msg = "function type in union return position"
                                    .. " — wrap each function type in parens:"
                                    .. " `(() -> A) | (() -> B)`" }
                        end
                    end
                    local fn = alloc_type(defs.TAG_FUNCTION)
                    local ft = types:get(fn)
                    -- Unpack TAG_TUPLE as multi-return (handles -> (A, B) correctly
                    -- while allowing -> () -> T to parse as returning a function).
                    local ret_t = types:get(ret)
                    local rets
                    if ret_t.tag == defs.TAG_TUPLE then
                        rets = {}
                        for i = 0, ret_t.data[1] - 1 do
                            rets[#rets + 1] = type_lists:get(ret_t.data[0] + i)
                        end
                    else
                        rets = { ret }
                    end
                    local rs, rl = flush_type_list(rets)
                    ft.data[2] = rs
                    ft.data[3] = rl
                    ft.data[4] = -1
                    return fn
                end
                -- Empty tuple
                local id = alloc_type(defs.TAG_TUPLE)
                return id
            end
            -- Parse items: support named params (x: T) alongside bare types (T)
            local items = {}
            local item_names = {}
            local has_param_names = false
            local function parse_one_param()
                local save_pos = s.pos
                local word = scan_word(s)
                if word then
                    local nb = peek(s)
                    if nb == byte(":") then
                        -- named param: word: type
                        advance(s)  -- skip ':'
                        local ty = parse_type(s)
                        item_names[#item_names + 1] = intern_mod.intern(pool, word)
                        has_param_names = true
                        return ty
                    else
                        s.pos = save_pos  -- not named, rewind and parse as bare type
                    end
                end
                item_names[#item_names + 1] = 0
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
                -- Parse return type(s)
                local returns = {}
                skip_ws(s)
                if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
                    -- -> ...(T): explicit multi-return spread
                    s.pos = s.pos + 3
                    expect_char(s, "(")
                    local inner = parse_type(s)
                    expect_char(s, ")")
                    local sp = alloc_type(defs.TAG_SPREAD)
                    types:get(sp).data[0] = inner
                    returns[1] = sp
                else
                    -- Detect assertion predicate syntax: `asserts name is T`
                    -- and type predicate syntax: `name is T`
                    -- Both are only valid when `name` is a known param name.
                    local guard_detected = false
                    if has_param_names then
                        local save_pos = s.pos
                        -- Check for "asserts" keyword first.
                        local assert_kw = s.pos + 6 <= s.len
                            and sub(s.src, s.pos, s.pos + 6) == "asserts"
                            and not is_ident(byte(s.src, s.pos + 7) or 0)
                        if assert_kw then
                            s.pos = s.pos + 7
                            skip_ws(s)
                            local pred_word = scan_word(s)
                            if pred_word then
                                local assert_param_idx = nil
                                for pi, nm_id in ipairs(item_names) do
                                    if nm_id ~= 0 then
                                        local pname = intern_mod.get(pool, nm_id)
                                        if pname == pred_word then
                                            assert_param_idx = pi - 1; break
                                        end
                                    end
                                end
                                if assert_param_idx then
                                    skip_ws(s)
                                    local is_kw2 = s.pos + 1 <= s.len
                                        and sub(s.src, s.pos, s.pos + 1) == "is"
                                        and not is_ident(byte(s.src, s.pos + 2) or 0)
                                    if is_kw2 then
                                        s.pos = s.pos + 2
                                        skip_ws(s)
                                        local assert_tid = parse_type(s)
                                        -- Assertion functions return nil (void).
                                        local ret_nil = alloc_type(defs.TAG_NIL)
                                        returns[1] = ret_nil
                                        -- Store assertion predicate info for narrowing.
                                        pool._pending_assert_predicate = {
                                            param_idx = assert_param_idx,
                                            type_id   = assert_tid,
                                        }
                                        guard_detected = true
                                    end
                                end
                            end
                            if not guard_detected then s.pos = save_pos end
                        end
                        if not guard_detected then
                            local pred_word = scan_word(s)
                            if pred_word then
                                -- Find the param index for this name
                                local guard_param_idx = nil
                                for pi, nm_id in ipairs(item_names) do
                                    if nm_id ~= 0 then
                                        local pname = intern_mod.get(pool, nm_id)
                                        if pname == pred_word then
                                            guard_param_idx = pi - 1; break
                                        end
                                    end
                                end
                                if guard_param_idx then
                                    skip_ws(s)
                                    -- Check for keyword "is" (not followed by ident char)
                                    local is_kw = s.pos + 1 <= s.len
                                        and sub(s.src, s.pos, s.pos + 1) == "is"
                                        and not is_ident(byte(s.src, s.pos + 2) or 0)
                                    if is_kw then
                                        s.pos = s.pos + 2
                                        skip_ws(s)
                                        local guard_tid = parse_type(s)
                                        -- Type predicate functions return boolean.
                                        local ret_bool = alloc_type(defs.TAG_BOOLEAN)
                                        returns[1] = ret_bool
                                        -- Store predicate info in pool for narrowing lookup.
                                        pool._type_predicates = pool._type_predicates or {}
                                        -- fn_type_id is assigned below; we need to patch it after
                                        -- alloc_type(TAG_FUNCTION). Use a deferred table entry.
                                        pool._pending_predicate = {
                                            param_idx = guard_param_idx,
                                            type_id   = guard_tid,
                                        }
                                        guard_detected = true
                                    end
                                end
                            end
                            if not guard_detected then s.pos = save_pos end
                        end
                    end
                    if not guard_detected then
                        returns[1] = parse_type(s)
                        -- If parse_type returned a TAG_TUPLE, unpack its elements
                        -- as multiple return types. This handles -> (A, B) multi-return
                        -- while allowing -> () -> T to correctly parse as returning a function.
                        local ret1_t = types:get(returns[1])
                        if ret1_t.tag == defs.TAG_TUPLE then
                            local ts, tl = ret1_t.data[0], ret1_t.data[1]
                            returns = {}
                            for i = 0, tl - 1 do
                                returns[#returns + 1] = type_lists:get(ts + i)
                            end
                        elseif union_contains_fn(returns[1]) then
                            warnings[#warnings + 1] = { line = s.line, col = 1,
                                msg = "function type in union return position"
                                    .. " — wrap each function type in parens:"
                                    .. " `((A) -> B) | ((A) -> C)`" }
                        end
                    end
                end
                -- Extract trailing spread as vararg.
                -- A TAG_SPREAD(TAG_CAPTURE) is a rest-capture param (...%P), NOT a vararg —
                -- leave it in the params list for match.lua to handle as a rest capture.
                local vararg_ann_id = -1
                if #items > 0 then
                    local last_t = types:get(items[#items])
                    if last_t.tag == defs.TAG_SPREAD then
                        local inner_t = types:get(last_t.data[0])
                        if inner_t.tag ~= defs.TAG_CAPTURE then
                            -- Normal vararg: ...T where T is not a capture
                            vararg_ann_id = last_t.data[0]
                            items[#items] = nil
                            item_names[#item_names] = nil
                        end
                        -- else: TAG_SPREAD(TAG_CAPTURE) = rest-capture param; leave in items list
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
                if has_param_names then
                    local pns, pnl = flush_type_list(item_names)
                    ft.data[5] = pns
                    ft.data[6] = pnl
                end
                -- Attach deferred type predicate info to pool (set by guard detection above).
                if pool._pending_predicate then
                    pool._type_predicates = pool._type_predicates or {}
                    pool._type_predicates[fn] = pool._pending_predicate
                    pool._pending_predicate = nil
                end
                -- Attach deferred assertion predicate info to pool (set by asserts detection above).
                if pool._pending_assert_predicate then
                    pool._assert_predicates = pool._assert_predicates or {}
                    pool._assert_predicates[fn] = pool._pending_assert_predicate
                    pool._pending_assert_predicate = nil
                end
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
            local row_var_ann_id = -1  -- set if bare ... seen (open table)
            if peek(s) ~= byte("}") then
                while true do
                    local fb = peek(s)
                    if fb == byte("#") then
                        advance(s)
                        -- Check for #...T (meta-spread) or #...%M (meta-spread capture pattern)
                        skip_ws(s)
                        if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
                            s.pos = s.pos + 3
                            skip_ws(s)
                            local nb2 = peek_raw(s)
                            if nb2 == B_PERCENT then
                                -- #...%M: meta-spread capture pattern (for match arm patterns)
                                advance(s)  -- skip '%'
                                local cap_name = scan_word(s)
                                if not cap_name then scan_error(s, "expected capture name after '#...%'") end
                                local cap_name_id = intern_mod.intern(pool, cap_name)
                                local pms = alloc_type(defs.TAG_PAT_META_SPREAD)
                                types:get(pms).data[0] = cap_name_id
                                -- Store as special field with name_id = -3 (meta-spread marker)
                                local fi = fields:alloc()
                                local fe = fields:get(fi)
                                fe.name_id = -3  -- meta-spread capture marker
                                fe.type_id = pms
                                fe.flags = 0
                                metas[#metas + 1] = fi
                            else
                                -- #...T: meta-spread (spreads all meta slots from T into this table)
                                local inner = parse_type(s)
                                local sp = alloc_type(defs.TAG_SPREAD)
                                types:get(sp).data[0] = inner
                                -- Store as special meta field with name_id = -1 (spread marker)
                                local fi = fields:alloc()
                                local fe = fields:get(fi)
                                fe.name_id = -1  -- meta-spread marker
                                fe.type_id = sp
                                fe.flags = 0
                                metas[#metas + 1] = fi
                            end
                        else
                            -- Meta slot: #__add: type
                            local name = scan_word(s)
                            if not name then scan_error(s, "expected meta name after '#'") end
                            local optional = opt_char(s, "?")
                            expect_char(s, ":")
                            local ftype = parse_type(s)
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = intern_mod.intern(pool, name)
                            fe.type_id = ftype
                            fe.flags = optional and FLAG_OPTIONAL or 0
                            metas[#metas + 1] = fi
                        end
                    elseif fb == byte("[") then
                        -- Indexer: [K]: V
                        -- Peek: if the bracket contains a single bare identifier that is not a
                        -- primitive keyword, treat it as an opaque-key field (typeclass dispatch).
                        -- This handles `{ [TC]: Instance }` where TC is a table-valued typeclass marker.
                        advance(s)
                        local save_bracket = s.pos
                        local bracket_word = scan_word(s)
                        skip_ws(s)
                        local is_opaque = bracket_word and not prim_tags[bracket_word]
                            and s.pos <= s.len and byte(s.src, s.pos) == byte("]")
                        if is_opaque then
                            -- Opaque key field: name_id = intern(IDENT), FLAG_OPAQUE_KEY
                            advance(s)  -- consume ']'
                            expect_char(s, ":")
                            local val_type = parse_type(s)
                            local key_name_id = intern_mod.intern(pool, bracket_word)
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = key_name_id
                            fe.type_id = val_type
                            fe.flags = FLAG_OPAQUE_KEY
                            flds[#flds + 1] = fi
                        else
                            -- Regular indexer: rewind and parse key as a full type
                            s.pos = save_bracket
                            local key_type = parse_type(s)
                            expect_char(s, "]")
                            expect_char(s, ":")
                            local val_type = parse_type(s)
                            local kt = types:get(key_type)
                            if kt.tag == defs.TAG_LITERAL and kt.data[0] == defs.LIT_STRING then
                                -- { ["foo"]: V } → named field entry (equivalent to { foo: V })
                                local name_id = kt.data[1]
                                local fi = fields:alloc()
                                local fe = fields:get(fi)
                                fe.name_id = name_id
                                fe.type_id = val_type
                                fe.flags = 0
                                flds[#flds + 1] = fi
                            elseif kt.tag == defs.TAG_CAPTURE then
                                -- { [%K]: V } is a footgun: field order is non-deterministic.
                                -- Use { ...[%K]: %V } for per-field distribution instead.
                                -- Push to parse_errors so it survives the inner pcall.
                                local cap_name = intern_mod.get(pool, kt.data[0]) or "?"
                                parse_errors[#parse_errors + 1] = {
                                    line = s.line, col = s.pos,
                                    msg = "capture key [%" .. cap_name ..
                                        "] requires ... prefix — use { ...[%K]: %V }",
                                }
                                scan_error(s, "capture key [%" .. cap_name ..
                                    "] requires ... prefix — use { ...[%K]: %V }")
                            else
                                indexers[#indexers + 1] = key_type
                                indexers[#indexers + 1] = val_type
                            end
                        end
                    elseif fb and is_ident_start(fb or 0) then
                        -- Field: [readonly] name[?]: type
                        local save_pos = s.pos
                        local word = scan_word(s)
                        -- Check for 'readonly' modifier keyword
                        local field_flags_val = 0
                        local name
                        if word == "readonly" then
                            -- peek: must be followed by a field name
                            local nb = peek(s)
                            if nb and is_ident_start(nb or 0) then
                                field_flags_val = FLAG_READONLY
                                name = scan_word(s)
                            else
                                -- 'readonly' used as a field name
                                name = word
                            end
                        else
                            name = word
                        end
                        -- Check if followed by : or ?: (field) or something else
                        local next_b = peek(s)
                        if next_b == byte(":") or next_b == byte("?") then
                            local optional = opt_char(s, "?")
                            if optional then field_flags_val = field_flags_val + FLAG_OPTIONAL end
                            expect_char(s, ":")
                            local ftype = parse_type(s)
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = intern_mod.intern(pool, name)
                            fe.type_id = ftype
                            fe.flags = field_flags_val
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
                        s.pos = s.pos + 3
                        local nb = peek(s)
                        if nb == byte("[") then
                            -- ...[%K]: %V → TAG_PAT_ALL_FIELDS (per-field distribution).
                            -- Iterates all named fields and indexers; K/V bound per entry.
                            advance(s)  -- skip '['
                            if peek(s) ~= B_PERCENT then
                                scan_error(s, "expected '%' capture sigil in ...[%K]: %V pattern")
                            end
                            advance(s)  -- skip '%'
                            local k_name = scan_word(s)
                            if not k_name then scan_error(s, "expected capture name after '%'") end
                            expect_char(s, "]")
                            expect_char(s, ":")
                            if peek(s) ~= B_PERCENT then
                                scan_error(s, "expected '%' capture sigil in ...[%K]: %V pattern")
                            end
                            advance(s)  -- skip '%'
                            local v_name = scan_word(s)
                            if not v_name then scan_error(s, "expected capture name after '%'") end
                            local k_name_id = intern_mod.intern(pool, k_name)
                            local v_name_id = intern_mod.intern(pool, v_name)
                            local paf = alloc_type(defs.TAG_PAT_ALL_FIELDS)
                            local paft = types:get(paf)
                            paft.data[0] = k_name_id
                            paft.data[1] = v_name_id
                            -- PAT_ALL_FIELDS is a standalone pattern; close the braces and return.
                            expect_char(s, "}")
                            return paf
                        elseif nb == B_PERCENT then
                            -- ...%Rest: rest-field capture. Captures remaining unmatched fields.
                            -- Used in: { field: _, ...%Rest } to avoid enumerating pass-through fields.
                            advance(s)  -- skip '%'
                            local rest_name = scan_word(s)
                            if not rest_name then scan_error(s, "expected capture name after '%'") end
                            local rest_name_id = intern_mod.intern(pool, rest_name)
                            local prf = alloc_type(defs.TAG_PAT_REST_FIELDS)
                            types:get(prf).data[0] = rest_name_id
                            -- Store as a field with name_id = -2 (rest capture marker)
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = -2  -- rest capture marker (distinct from -1 spread)
                            fe.type_id = prf
                            fe.flags = 0
                            flds[#flds + 1] = fi
                            -- Must be last; break out of the field loop
                            break
                        elseif nb == byte("}") or nb == byte(",") or nb == byte(";") or not nb then
                            -- Bare ...: open-table row variable marker.
                            row_var_ann_id = alloc_type(defs.TAG_ROWVAR)
                            break
                        else
                            -- ...T: spread base type (extends another table's fields).
                            local inner = parse_type(s)
                            local sp = alloc_type(defs.TAG_SPREAD)
                            types:get(sp).data[0] = inner
                            -- Spread in table context — store as special field
                            local fi = fields:alloc()
                            local fe = fields:get(fi)
                            fe.name_id = -1  -- spread marker
                            fe.type_id = sp
                            fe.flags = 0
                            flds[#flds + 1] = fi
                        end
                    elseif fb and fb ~= byte("}") and fb ~= byte(",") and fb ~= byte(";") then
                        -- Positional type entry starting with a non-ident character
                        -- (e.g. { {inner_table} } for brace-tuples, ("type"), etc.)
                        local val_type = parse_type(s)
                        local num_type = alloc_type(defs.TAG_NUMBER)
                        indexers[#indexers + 1] = num_type
                        indexers[#indexers + 1] = val_type
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
                local _is, _il = flush_type_list(indexers)
                is = _is; il = _il
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
            tt.data[4] = row_var_ann_id
            tt.data[5] = ms
            tt.data[6] = ml
            return tbl
        end

        -- Forall: <T, U> type or <T: Bound, U> type
        if b == byte("<") then
            advance(s)  -- skip '<'
            local params = {}
            -- bounds_by_idx[i] = ann type_id for param i's bound, or false if no bound.
            -- Using false (not nil) as the "no bound" sentinel because Lua table length
            -- does not count nil entries, so `bounds[i] = nil` would silently break `#bounds`.
            local bounds_by_idx = {}
            local has_bounds = false
            params[1] = scan_word(s)
            if not params[1] then scan_error(s, "expected type parameter") end
            -- Check for optional bound: T: Bound
            if opt_char(s, ":") then
                bounds_by_idx[1] = parse_type(s)
                has_bounds = true
            else
                bounds_by_idx[1] = false
            end
            while opt_char(s, ",") do
                local p = scan_word(s)
                if not p then scan_error(s, "expected type parameter") end
                params[#params + 1] = p
                if opt_char(s, ":") then
                    bounds_by_idx[#params] = parse_type(s)
                    has_bounds = true
                else
                    bounds_by_idx[#params] = false
                end
            end
            expect_char(s, ">")
            -- Intern type param names
            local param_ids = {}
            for i = 1, #params do
                param_ids[i] = intern_mod.intern(pool, params[i])
            end
            local tps, tpl = flush_type_list(param_ids)
            -- Store bounds in data[3]/data[4] if any bound was specified.
            -- Bounds list parallel to params (length = #params): -1 for "no bound".
            local bds, bdl = 0, 0
            if has_bounds then
                local bound_ids = {}
                for i = 1, #params do
                    bound_ids[i] = bounds_by_idx[i] or -1
                end
                local _bds, _bdl = flush_type_list(bound_ids)
                bds = _bds; bdl = _bdl
            end
            local body = parse_type(s)
            local forall = alloc_type(defs.TAG_FORALL)
            local ft = types:get(forall)
            ft.data[0] = tps
            ft.data[1] = tpl
            ft.data[2] = body
            ft.data[3] = bds
            ft.data[4] = bdl
            return forall
        end

        -- Capture sigil: %Name → TAG_CAPTURE(name_id)
        -- A name prefixed with % is an explicit capture in a match pattern.
        -- At use sites (result expressions) captures are referenced by bare name.
        if b == B_PERCENT then
            advance(s)  -- skip '%'
            local name = scan_word(s)
            if not name then scan_error(s, "expected capture name after '%'") end
            local name_id = intern_mod.intern(pool, name)
            local cap = alloc_type(defs.TAG_CAPTURE)
            types:get(cap).data[0] = name_id
            return cap
        end

        -- Word: could be primitive, keyword (typeof/match/newtype/function), or named type
        if is_ident_start(b) then
            local word = scan_word(s)

            -- typeof <ident>: capture the inferred type of a value binding
            if word == "typeof" then
                local ident = scan_word(s)
                if not ident then scan_error(s, "expected identifier after 'typeof'") end
                local name_id = intern_mod.intern(pool, ident)
                local id = alloc_type(defs.TAG_TYPEOF)
                types:get(id).data[0] = name_id
                return id
            end

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

    -- Parse postfix: [] (array)
    local function parse_postfix(s)
        local ty = parse_primary(s)
        while true do
            if peek(s) == byte("[") then
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
                    tt.data[4] = -1  -- no row var (closed table)
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
    -- Also handles top-level right-associative -> for curried function types.
    -- This allows F<A> -> F<B> (bare, without surrounding parens) and
    -- ((A -> B) -> F<A> -> F<B>) where the outer parens are transparent grouping.
    parse_type = function(s)
        s.depth = s.depth + 1
        if s.depth > MAX_TYPE_DEPTH then
            s.depth_limit_hit = true
            scan_error(s, "type annotation too deeply nested (max depth " .. MAX_TYPE_DEPTH .. ")")
        end
        local result
        local left = parse_intersection(s)
        if opt_char(s, "|") then
            local members = { left, parse_intersection(s) }
            while opt_char(s, "|") do
                members[#members + 1] = parse_intersection(s)
            end
            local ms, ml = flush_type_list(members)
            local union = alloc_type(defs.TAG_UNION)
            types:get(union).data[0] = ms
            types:get(union).data[1] = ml
            left = union
        end
        -- Top-level right-associative -> : T1 -> T2 means (T1) -> T2
        skip_ws(s)
        if s.pos + 1 <= s.len and sub(s.src, s.pos, s.pos + 1) == "->" then
            s.pos = s.pos + 2
            skip_ws(s)
            local ret
            if s.pos + 2 <= s.len and sub(s.src, s.pos, s.pos + 2) == "..." then
                -- -> ...(T): explicit multi-return spread
                s.pos = s.pos + 3
                expect_char(s, "(")
                local inner = parse_type(s)
                expect_char(s, ")")
                local sp = alloc_type(defs.TAG_SPREAD)
                types:get(sp).data[0] = inner
                ret = sp
            else
                ret = parse_type(s)  -- right-recursive for right-associativity
            end
            local ps, pl = flush_type_list({ left })
            local rs, rl = flush_type_list({ ret })
            local fn = alloc_type(defs.TAG_FUNCTION)
            local ft = types:get(fn)
            ft.data[0] = ps; ft.data[1] = pl
            ft.data[2] = rs; ft.data[3] = rl
            ft.data[4] = -1
            result = fn
        else
            result = left
        end
        s.depth = s.depth - 1
        return result
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
                -- module "name": T  — declares the type returned by require("name")
                if word == "module" then
                    local mod_name = scan_string(s)
                    expect_char(s, ":")
                    local type_id = parse_type(s)
                    return { kind = defs.ANN_MODULE, mod_name = mod_name, type_id = type_id }
                end
                -- require "mod.path" — load a declaration file into scope
                if word == "require" then
                    local mod_name = scan_string(s)
                    return { kind = defs.ANN_REQUIRE, mod_name = mod_name }
                end
                -- augment Name { field: T, ... } — merge fields into an existing type binding
                if word == "augment" then
                    local aug_name = scan_word(s)
                    if not aug_name then scan_error(s, "expected name after 'augment'") end
                    local aug_name_id = intern_mod.intern(pool, aug_name)
                    -- Parse the field table: reuse the '{' table parsing by backtracking to
                    -- before '{' and calling parse_type. We peek to confirm '{', then proceed.
                    skip_ws(s)
                    if s.pos > s.len or byte(s.src, s.pos) ~= byte("{") then
                        scan_error(s, "expected '{' after augment name")
                    end
                    local type_id = parse_type(s)
                    return { kind = defs.ANN_AUGMENT, name_id = aug_name_id, type_id = type_id }
                end
                -- unseal Name — rebinds opaque variable to its inner type in current scope
                if word == "unseal" then
                    local name = scan_word(s)
                    if not name then scan_error(s, "expected identifier after 'unseal'") end
                    local name_id = intern_mod.intern(pool, name)
                    return { kind = defs.ANN_UNSEAL, name_id = name_id }
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
                -- Regular: Name<T...> = type  or  Name<T: Bound, ...> = type
                local name = word
                if not name then scan_error(s, "expected declaration name") end
                local name_id = intern_mod.intern(pool, name)
                local type_params
                local type_bounds     -- parallel to type_params; nil entry = no bound
                local type_defaults   -- parallel to type_params; nil entry = no default
                local has_type_bounds = false
                local has_type_defaults = false
                if peek(s) == byte("<") then
                    advance(s)
                    type_params = {}
                    type_bounds = {}
                    type_defaults = {}
                    -- Use explicit count to avoid sparse-table issues with nil entries.
                    -- (Assigning nil to a Lua table is a no-op, so #table skips nil holes.)
                    local nparam = 0
                    local first_param = scan_word(s)
                    if not first_param then scan_error(s, "expected type parameter") end
                    nparam = nparam + 1
                    type_params[nparam] = intern_mod.intern(pool, first_param)
                    if opt_char(s, ":") then
                        type_bounds[nparam] = parse_type(s)
                        has_type_bounds = true
                    end
                    if opt_char(s, "=") then
                        type_defaults[nparam] = parse_type(s)
                        has_type_defaults = true
                    end
                    local saw_default = type_defaults[nparam] ~= nil
                    while opt_char(s, ",") do
                        local p = scan_word(s)
                        if not p then scan_error(s, "expected type parameter") end
                        nparam = nparam + 1
                        type_params[nparam] = intern_mod.intern(pool, p)
                        if opt_char(s, ":") then
                            type_bounds[nparam] = parse_type(s)
                            has_type_bounds = true
                        end
                        if opt_char(s, "=") then
                            type_defaults[nparam] = parse_type(s)
                            has_type_defaults = true
                            saw_default = true
                        else
                            if saw_default then
                                -- Non-default parameter after a default: ordering error.
                                -- Store as a parse error (survives the inner pcall via
                                -- parse_errors list) rather than throwing, so the result
                                -- is still parsed but the error is reported by constrain.lua.
                                parse_errors[#parse_errors + 1] = {
                                    line = s.line, col = s.pos,
                                    msg = "non-default type parameter after default parameter",
                                }
                            end
                        end
                    end
                    expect_char(s, ">")
                end
                -- Optional `: ConstraintName<args>` between param list and `=`.
                -- The constraint must be a named type alias (no inline type expressions).
                local constraint_type_id = nil
                if opt_char(s, ":") then
                    local cname = scan_word(s)
                    if not cname then
                        scan_error(s, "expected constraint name after ':'")
                    end
                    local cname_id = intern_mod.intern(pool, cname)
                    -- Parse optional <args> for the constraint.
                    local carg_ids = nil
                    if peek(s) == byte("<") then
                        advance(s)
                        carg_ids = {}
                        local cfirst = parse_type(s)
                        carg_ids[#carg_ids + 1] = cfirst
                        while opt_char(s, ",") do
                            carg_ids[#carg_ids + 1] = parse_type(s)
                        end
                        expect_char(s, ">")
                    end
                    -- Build a TAG_NAMED node in the annotation arena for the constraint.
                    local ctid = alloc_type(defs.TAG_NAMED)
                    local ct = types:get(ctid)
                    ct.data[0] = cname_id
                    if carg_ids and #carg_ids > 0 then
                        local cs, cl = flush_type_list(carg_ids)
                        ct = types:get(ctid)  -- re-fetch after possible arena grow
                        ct.data[1] = cs
                        ct.data[2] = cl
                    else
                        ct.data[1] = 0
                        ct.data[2] = 0
                    end
                    constraint_type_id = ctid
                end
                expect_char(s, "=")
                local type_id = parse_type(s)
                local tps, tpl = 0, 0
                if type_params then
                    local _tps, _tpl = flush_type_list(type_params)
                    tps = _tps; tpl = _tpl
                end
                -- Store bounds parallel to type_params: -1 sentinel for "no bound".
                local bds, bdl = 0, 0
                if has_type_bounds and type_bounds then
                    local tb = type_bounds or {}
                    local bound_ids = {}
                    for i = 1, #tb do
                        local bv = tb[i]
                        bound_ids[i] = bv ~= nil and bv or -1
                    end
                    local _bds, _bdl = flush_type_list(bound_ids)
                    bds = _bds; bdl = _bdl
                end
                -- Store defaults parallel to type_params: -1 sentinel for "no default".
                -- Iterate by type_params length to avoid sparse-table issues (type_defaults
                -- may have nil holes when some params have no default).
                local dds, ddl = 0, 0
                if has_type_defaults and type_defaults and type_params then
                    local default_ids = {}
                    for i = 1, #type_params do
                        local dv = type_defaults[i]
                        default_ids[i] = dv ~= nil and dv or -1
                    end
                    local _dds, _ddl = flush_type_list(default_ids)
                    dds = _dds; ddl = _ddl
                end
                return {
                    kind = defs.ANN_DECL,
                    type_id = type_id,
                    name_id = name_id,
                    type_params_start = tps,
                    type_params_len = tpl,
                    type_bounds_start = bds,
                    type_bounds_len = bdl,
                    type_defaults_start = dds,
                    type_defaults_len = ddl,
                    constraint_type_id = constraint_type_id,
                }
            elseif ann.kind == defs.ANN_TYPE_ARGS then
                -- Parse <T, U> — type arguments for call-site specialization
                expect_char(s, "<")
                local args = {}
                while true do
                    local b = peek(s)
                    if b == byte("_") then
                        -- Wildcard: infer this param
                        local word = scan_word(s) or ""
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
        elseif not ok and s.depth_limit_hit then
            -- Re-throw depth-limit errors so the outer pcall in constrain.lua
            -- can report them as diagnostics. Other parse errors (e.g. malformed
            -- or out-of-context annotations) are silently skipped.
            error(result, 0)
        end
    end

    -- make_intersection(type_ids): build an intersection node in the annotation arena
    -- from a list of annotation-arena type IDs. Returns the new type ID.
    local function make_intersection_ann(type_ids)
        local ms, ml = flush_type_list(type_ids)
        local inter = alloc_type(defs.TAG_INTERSECTION)
        types:get(inter).data[0] = ms
        types:get(inter).data[1] = ml
        return inter
    end

    return {
        types = types,
        fields = fields,
        lists = type_lists,
        results = results,
        warnings = warnings,
        parse_errors = parse_errors,
        pool = pool,
        make_intersection = make_intersection_ann,
    }
end

return M
