-- lib/type/static/cdecl_parse.lua
-- Parser for C declaration syntax used in LuaJIT ffi.cdef() blocks.
-- Produces Lua descriptor tables; no AST nodes, no FFI allocations.

local intern_mod = require("lib.type.static.intern")
local cdecl_lex  = require("lib.type.static.cdecl_lex")

local TK_IDENT    = cdecl_lex.TK_IDENT
local TK_INT      = cdecl_lex.TK_INT
local TK_SEMI     = cdecl_lex.TK_SEMI
local TK_COMMA    = cdecl_lex.TK_COMMA
local TK_STAR     = cdecl_lex.TK_STAR
local TK_LPAREN   = cdecl_lex.TK_LPAREN
local TK_RPAREN   = cdecl_lex.TK_RPAREN
local TK_LBRACE   = cdecl_lex.TK_LBRACE
local TK_RBRACE   = cdecl_lex.TK_RBRACE
local TK_LBRACK   = cdecl_lex.TK_LBRACK
local TK_RBRACK   = cdecl_lex.TK_RBRACK
local TK_ASSIGN   = cdecl_lex.TK_ASSIGN
local TK_ELLIPSIS = cdecl_lex.TK_ELLIPSIS
local TK_EOF      = cdecl_lex.TK_EOF

local M = {}

---------------------------------------------------------------------------
-- C keywords to pre-intern
---------------------------------------------------------------------------

local C_KEYWORDS = {
    "void", "char", "short", "int", "long", "float", "double",
    "unsigned", "signed", "struct", "union", "enum",
    "typedef", "const", "volatile", "static", "extern", "inline", "restrict",
    "_Bool",
    "__attribute__", "__cdecl", "__declspec", "__extension__",
    "__restrict", "__restrict__", "__const", "__volatile__", "__volatile",
    "__inline", "__inline__",
    "int8_t", "uint8_t", "int16_t", "uint16_t",
    "int32_t", "uint32_t", "int64_t", "uint64_t",
    "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
    "ssize_t", "off_t", "pid_t", "uid_t", "gid_t",
    "wchar_t",
}

---------------------------------------------------------------------------
-- Parser construction
---------------------------------------------------------------------------

--[[::
CdeclParser = {
  lex: { tk: integer, val: integer, next: (unknown) -> integer, ... },
  pool: { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... },
  kw: { [string]: integer, ... },
  typedefs: { [integer]: boolean, ... },
  decls: { [integer]: unknown, ... },
  ...
}
]]

local function new_parser(source, pool)
    pool = pool or intern_mod.new()
    local lex = cdecl_lex.new(source, pool)

    -- Pre-intern C keywords
    local kw = {}
    for _, s in ipairs(C_KEYWORDS) do
        kw[s] = intern_mod.intern(pool, s)
    end

    return {
        lex      = lex,
        pool     = pool,
        kw       = kw,
        typedefs = {},   -- intern_id → true
        decls    = {},
    }
end

---------------------------------------------------------------------------
-- Token helpers
---------------------------------------------------------------------------

-- Advance and return current token type.
--: (CdeclParser) -> integer
local function advance(p)
    p.lex:next()
    return p.lex.tk
end

-- Check current token is TK_IDENT with a specific intern_id.
--: (CdeclParser, integer) -> boolean
local function check_kw(p, kw_id)
    if p.lex.tk == TK_IDENT and p.lex.val == kw_id then return true end
    return false
end

-- Consume current token if it matches tk; return true on success.
--: (CdeclParser, integer) -> boolean
local function eat(p, tk)
    if p.lex.tk == tk then
        advance(p)
        return true
    end
    return false
end

-- Consume keyword by name; return true on success.
--: (CdeclParser, string) -> boolean
local function eat_kw(p, name)
    local id = p.kw[name]
    if id and p.lex.tk == TK_IDENT and p.lex.val == id then
        advance(p)
        return true
    end
    return false
end

-- Expect a specific token; error if not present.
--: (CdeclParser, integer) -> ()
local function expect(p, tk)
    if p.lex.tk ~= tk then
        error("cdecl_parse: expected token " .. tk .. " got " .. p.lex.tk)
    end
    advance(p)
end

-- Expect TK_IDENT; return its intern_id.
--: (CdeclParser) -> integer
local function expect_ident(p)
    if p.lex.tk ~= TK_IDENT then
        error("cdecl_parse: expected identifier, got token " .. p.lex.tk)
    end
    local id = p.lex.val
    advance(p)
    return id
end

---------------------------------------------------------------------------
-- Qualifier / storage-class skipping
---------------------------------------------------------------------------

-- Keywords that are consumed and ignored wherever they appear.
local SKIP_KW = {
    "const", "volatile", "static", "extern", "inline", "restrict",
    "__restrict", "__restrict__", "__const", "__volatile__", "__volatile",
    "__inline", "__inline__", "__extension__", "__cdecl",
}

-- Skip __declspec(...)
--: (CdeclParser) -> ()
local function skip_declspec(p)
    -- consume '('
    if not eat(p, TK_LPAREN) then return end
    local depth = 1
    while p.lex.tk ~= TK_EOF and depth > 0 do
        if p.lex.tk == TK_LPAREN then
            depth = depth + 1
        elseif p.lex.tk == TK_RPAREN then
            depth = depth - 1
        end
        advance(p)
    end
end

-- Skip __attribute__((...))  — double paren expression.
--: (CdeclParser) -> ()
local function skip_attribute(p)
    -- expect first '('
    if not eat(p, TK_LPAREN) then return end
    -- expect second '('
    if not eat(p, TK_LPAREN) then
        -- fall back: just skip one paren-balanced group
        local depth = 1
        while p.lex.tk ~= TK_EOF and depth > 0 do
            if p.lex.tk == TK_LPAREN then depth = depth + 1
            elseif p.lex.tk == TK_RPAREN then depth = depth - 1 end
            advance(p)
        end
        return
    end
    -- now skip until matching double close ))
    local depth = 2
    while p.lex.tk ~= TK_EOF and depth > 0 do
        if p.lex.tk == TK_LPAREN then
            depth = depth + 1
        elseif p.lex.tk == TK_RPAREN then
            depth = depth - 1
        end
        advance(p)
    end
end

-- Skip all leading qualifiers/storage classes/attributes.
-- Returns true if anything was consumed (so caller can loop).
--: (CdeclParser) -> ()
local function skip_qualifiers(p)
    local consumed = false
    while true do
        local did = false
        for _, name in ipairs(SKIP_KW) do
            if eat_kw(p, name) then did = true; break end
        end
        if not did then
            if check_kw(p, p.kw["__attribute__"]) then
                advance(p)
                skip_attribute(p)
                did = true
            elseif check_kw(p, p.kw["__declspec"]) then
                advance(p)
                skip_declspec(p)
                did = true
            end
        end
        if not did then break end
        consumed = true
    end
    return consumed
end

---------------------------------------------------------------------------
-- Integer base-type classifier
---------------------------------------------------------------------------

-- Returns true if the current TK_IDENT is an integer modifier keyword.
--: (CdeclParser) -> boolean
local function is_int_modifier(p)
    if p.lex.tk ~= TK_IDENT then return false end
    local v = p.lex.val
    local kw = p.kw
    return v == kw["char"] or v == kw["short"] or v == kw["int"]
        or v == kw["long"] or v == kw["unsigned"] or v == kw["signed"]
end

-- Returns true if the current TK_IDENT is a float keyword.
--: (CdeclParser) -> boolean
local function is_float_kw(p)
    if p.lex.tk ~= TK_IDENT then return false end
    local v = p.lex.val
    local kw = p.kw
    return v == kw["float"] or v == kw["double"]
end

-- Integer typedef names (like int32_t, size_t, etc.) → {k="int"} or {k="char"}
local INT_TYPEDEFS = {
    "int8_t", "uint8_t", "int16_t", "uint16_t",
    "int32_t", "uint32_t", "int64_t", "uint64_t",
    "size_t", "ptrdiff_t", "intptr_t", "uintptr_t",
    "ssize_t", "off_t", "pid_t", "uid_t", "gid_t",
    "wchar_t",
}

--: (CdeclParser) -> boolean
local function is_int_typedef(p)
    if p.lex.tk ~= TK_IDENT then return false end
    local v = p.lex.val
    local kw = p.kw
    for _, name in ipairs(INT_TYPEDEFS) do
        if v == kw[name] then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Forward declarations
---------------------------------------------------------------------------

local parse_type_spec   -- forward
local parse_declarator  -- forward

---------------------------------------------------------------------------
-- Type specifier parsing
-- Returns a c_type table.  Consumes qualifiers around the base type.
---------------------------------------------------------------------------

-- Parse struct/union body: { field; field; ... }
-- Returns array of { name_id, type } or nil if no body present.
local function parse_struct_body(p)
    if p.lex.tk ~= TK_LBRACE then return nil end
    advance(p)  -- consume '{'
    local fields = {}
    while p.lex.tk ~= TK_RBRACE and p.lex.tk ~= TK_EOF do
        skip_qualifiers(p)
        if p.lex.tk == TK_RBRACE or p.lex.tk == TK_EOF then break end

        -- Parse base type for this field
        local base_type = parse_type_spec(p)

        -- Parse one or more declarators (comma-separated)
        -- A field could be: int x, y; or int x;
        -- Bit fields: int x : 3; — skip the colon and integer
        repeat
            local name_id, ftype = parse_declarator(p, base_type)
            -- skip bit-field width
            if p.lex.tk == cdecl_lex.TK_COLON then
                advance(p)  -- ':'
                -- skip the integer
                if p.lex.tk == TK_INT then advance(p) end
            end
            if name_id then
                fields[#fields + 1] = { name_id = name_id, type = ftype }
            end
        until not eat(p, TK_COMMA)

        eat(p, TK_SEMI)
        skip_qualifiers(p)
    end
    eat(p, TK_RBRACE)
    return fields
end

-- Parse enum body: { NAME [= val], ... }
-- Returns array of { name_id, value } and registers enum_val decls.
local function parse_enum_body(p)
    if p.lex.tk ~= TK_LBRACE then return nil end
    advance(p)  -- consume '{'
    local members = {}
    local counter = 0
    while p.lex.tk ~= TK_RBRACE and p.lex.tk ~= TK_EOF do
        skip_qualifiers(p)
        if p.lex.tk ~= TK_IDENT then break end
        local name_id = p.lex.val
        advance(p)
        local value = counter
        if eat(p, TK_ASSIGN) then
            -- May be negative (indicated by '-' — but lexer skips '-', so
            -- enum { A = -1 } is tricky; handle it if TK_INT follows)
            if p.lex.tk == TK_INT then
                value = p.lex.val
                advance(p)
            end
        end
        counter = value + 1
        members[#members + 1] = { name_id = name_id, value = value }
        -- Register as enum_val decl
        p.decls[#p.decls + 1] = { decl = "enum_val", name_id = name_id, value = value }
        eat(p, TK_COMMA)
    end
    eat(p, TK_RBRACE)
    return members
end

parse_type_spec = function(p)
    skip_qualifiers(p)

    local tk = p.lex.tk
    local kw = p.kw

    if tk ~= TK_IDENT then
        error("cdecl_parse: expected type specifier, got token " .. tk)
    end

    local val = p.lex.val

    -- void
    if val == kw["void"] then
        advance(p)
        return { k = "void" }

    -- _Bool
    elseif val == kw["_Bool"] then
        advance(p)
        return { k = "bool" }

    -- float / double
    elseif val == kw["float"] then
        advance(p)
        skip_qualifiers(p)
        return { k = "float" }

    elseif val == kw["double"] then
        advance(p)
        skip_qualifiers(p)
        -- "long double" — already consumed "double"
        return { k = "float" }

    -- struct
    elseif val == kw["struct"] then
        advance(p)
        skip_qualifiers(p)
        local name_id = nil
        if p.lex.tk == TK_IDENT and not p.typedefs[p.lex.val] then
            name_id = p.lex.val
            advance(p)
        end
        skip_qualifiers(p)
        local fields = parse_struct_body(p)
        return { k = "struct", name_id = name_id, fields = fields }

    -- union
    elseif val == kw["union"] then
        advance(p)
        skip_qualifiers(p)
        local name_id = nil
        if p.lex.tk == TK_IDENT and not p.typedefs[p.lex.val] then
            name_id = p.lex.val
            advance(p)
        end
        skip_qualifiers(p)
        local fields = parse_struct_body(p)
        return { k = "union", name_id = name_id, fields = fields }

    -- enum
    elseif val == kw["enum"] then
        advance(p)
        skip_qualifiers(p)
        local name_id = nil
        if p.lex.tk == TK_IDENT and not p.typedefs[p.lex.val] then
            name_id = p.lex.val
            advance(p)
        end
        skip_qualifiers(p)
        local members = parse_enum_body(p)
        return { k = "enum", name_id = name_id, members = members or {} }

    -- Integer modifier keywords: char short int long unsigned signed
    elseif is_int_modifier(p) then
        -- Consume all consecutive integer modifier keywords
        local saw_char = (val == kw["char"])
        local saw_unsigned_or_signed_only = false
        advance(p)
        skip_qualifiers(p)
        local only_sign = (val == kw["unsigned"] or val == kw["signed"])
        while is_int_modifier(p) do
            local v2 = p.lex.val
            if v2 == kw["char"] then saw_char = true end
            if v2 ~= kw["unsigned"] and v2 ~= kw["signed"] then only_sign = false end
            advance(p)
            skip_qualifiers(p)
        end
        -- If first token was "long" and next is "double", it's "long double"
        if val == kw["long"] and is_float_kw(p) then
            advance(p)  -- consume "double" or "float"
            return { k = "float" }
        end
        if saw_char then
            return { k = "char" }
        end
        return { k = "int" }

    -- Integer typedefs (size_t, int32_t, etc.)
    elseif is_int_typedef(p) then
        advance(p)
        return { k = "int" }

    -- Known typedef name or opaque type reference
    elseif p.typedefs[val] then
        advance(p)
        return { k = "name", id = val }

    -- Unknown identifier — treat as a named type reference
    else
        advance(p)
        return { k = "name", id = val }
    end
end

---------------------------------------------------------------------------
-- Parameter list parsing
-- Returns params array and vararg bool.
---------------------------------------------------------------------------

local function parse_params(p)
    -- consume '('
    expect(p, TK_LPAREN)
    local params = {}
    local vararg = false

    if p.lex.tk == TK_RPAREN then
        advance(p)
        return params, false
    end

    -- (void) → empty params
    if p.lex.tk == TK_IDENT and p.lex.val == p.kw["void"] then
        -- peek: if next is ')', it's (void)
        local saved_tk  = p.lex.tk
        local saved_val = p.lex.val
        advance(p)
        skip_qualifiers(p)
        if p.lex.tk == TK_RPAREN then
            advance(p)
            return {}, false
        end
        -- Not just (void); put back by re-parsing: we already consumed "void"
        -- so push a synthetic base type
        local base = { k = "void" }
        local name_id, ptype = parse_declarator(p, base)
        params[#params + 1] = { name_id = name_id, type = ptype }
        if not eat(p, TK_COMMA) then
            expect(p, TK_RPAREN)
            return params, vararg
        end
    end

    while true do
        if p.lex.tk == TK_ELLIPSIS then
            vararg = true
            advance(p)
            break
        end
        if p.lex.tk == TK_RPAREN or p.lex.tk == TK_EOF then break end
        skip_qualifiers(p)
        if p.lex.tk == TK_ELLIPSIS then
            vararg = true
            advance(p)
            break
        end
        local base = parse_type_spec(p)
        local name_id, ptype = parse_declarator(p, base)
        params[#params + 1] = { name_id = name_id, type = ptype }
        if not eat(p, TK_COMMA) then break end
    end

    expect(p, TK_RPAREN)
    return params, vararg
end

---------------------------------------------------------------------------
-- Declarator parsing
-- Handles: name, *name, **name, (*name)(params), name[N], name(params)
-- base_type: the type specifier already parsed before the declarator.
-- Returns: name_id (or nil), c_type
---------------------------------------------------------------------------

parse_declarator = function(p, base_type)
    skip_qualifiers(p)

    -- Collect leading stars (pointer layers)
    local ptr_depth = 0
    while p.lex.tk == TK_STAR do
        ptr_depth = ptr_depth + 1
        advance(p)
        skip_qualifiers(p)
    end

    -- Function pointer: (*name)(params) or (*)(params)
    if p.lex.tk == TK_LPAREN then
        local peek_is_star
        -- Look ahead: '(' followed by '*' means function pointer
        -- We consume '(' and check
        advance(p)  -- consume '('
        skip_qualifiers(p)
        if p.lex.tk == TK_STAR then
            advance(p)  -- consume '*'
            skip_qualifiers(p)
            -- Optional name
            local name_id = nil
            if p.lex.tk == TK_IDENT and not p.typedefs[p.lex.val] then
                -- Could be qualifiers we haven't stripped yet; but skip_qualifiers
                -- already ran. If still TK_IDENT here, it's the declarator name.
                name_id = p.lex.val
                advance(p)
            end
            expect(p, TK_RPAREN)  -- closing ')' of (*name)
            -- Now parse the parameter list
            local params, vararg = parse_params(p)
            -- Build function pointer type
            local fn_type = { k = "func", ret = base_type, params = params, vararg = vararg }
            local result = { k = "ptr", to = fn_type }
            -- Apply outer pointer layers
            for _ = 1, ptr_depth do
                result = { k = "ptr", to = result }
            end
            return name_id, result
        else
            -- Not a function pointer — this '(' starts a parameter list
            -- (abstract declarator returning base_type directly).
            -- We need to parse params but we already consumed '(' and are
            -- positioned at the first param token.
            -- Re-use parse_params logic inline.
            local params = {}
            local vararg = false
            -- Check for (void)
            if p.lex.tk == TK_IDENT and p.lex.val == p.kw["void"] then
                advance(p)
                skip_qualifiers(p)
                if p.lex.tk == TK_RPAREN then
                    advance(p)
                    -- params stays empty
                    goto done_inline_params
                end
                -- not just (void), parse as param
                local void_base = { k = "void" }
                local pname, ptype = parse_declarator(p, void_base)
                params[#params + 1] = { name_id = pname, type = ptype }
                eat(p, TK_COMMA)
            end
            while true do
                if p.lex.tk == TK_ELLIPSIS then
                    vararg = true; advance(p); break
                end
                if p.lex.tk == TK_RPAREN or p.lex.tk == TK_EOF then break end
                skip_qualifiers(p)
                if p.lex.tk == TK_ELLIPSIS then vararg = true; advance(p); break end
                local base2 = parse_type_spec(p)
                local pname, ptype = parse_declarator(p, base2)
                params[#params + 1] = { name_id = pname, type = ptype }
                if not eat(p, TK_COMMA) then break end
            end
            expect(p, TK_RPAREN)
            ::done_inline_params::
            local fn_type = { k = "func", ret = base_type, params = params, vararg = vararg }
            local result = fn_type
            for _ = 1, ptr_depth do result = { k = "ptr", to = result } end
            return nil, result
        end
    end

    -- Plain declarator name (or anonymous)
    local name_id = nil
    if p.lex.tk == TK_IDENT and not p.typedefs[p.lex.val]
        and not check_kw(p, p.kw["struct"])
        and not check_kw(p, p.kw["union"])
        and not check_kw(p, p.kw["enum"])
        and not check_kw(p, p.kw["typedef"])
        and not check_kw(p, p.kw["void"])
        and not is_int_modifier(p)
        and not is_int_typedef(p)
        and not is_float_kw(p)
        and not check_kw(p, p.kw["_Bool"])
    then
        name_id = p.lex.val
        advance(p)
        skip_qualifiers(p)
    end

    -- Function suffix: name(params)
    -- In C, ptr_depth applies to the return type when a function suffix follows.
    -- e.g. char *foo(int) → foo is func returning ptr to char (not ptr to func).
    if p.lex.tk == TK_LPAREN then
        -- Build pointer-to-base as the return type
        local ret_type = base_type
        for _ = 1, ptr_depth do
            ret_type = { k = "ptr", to = ret_type }
        end
        local params, vararg = parse_params(p)
        return name_id, { k = "func", ret = ret_type, params = params, vararg = vararg }
    end

    -- Array suffix: name[N] or name[]
    local result_type = base_type
    if p.lex.tk == TK_LBRACK then
        advance(p)
        local size = nil
        if p.lex.tk == TK_INT then
            size = p.lex.val
            advance(p)
        end
        eat(p, TK_RBRACK)
        result_type = { k = "arr", of = base_type, size = size }
    end

    -- Apply pointer layers for non-function declarators (variable/param)
    for _ = 1, ptr_depth do
        result_type = { k = "ptr", to = result_type }
    end

    return name_id, result_type
end

---------------------------------------------------------------------------
-- Skip to next semicolon for error recovery
---------------------------------------------------------------------------

--: (CdeclParser) -> ()
local function skip_to_semi(p)
    while p.lex.tk ~= TK_SEMI and p.lex.tk ~= TK_EOF do
        advance(p)
    end
    eat(p, TK_SEMI)
end

---------------------------------------------------------------------------
-- Top-level declaration parser
---------------------------------------------------------------------------

local function parse_one_decl(p)
    skip_qualifiers(p)

    if p.lex.tk == TK_EOF then return false end
    if p.lex.tk == TK_SEMI then advance(p); return true end

    local is_typedef = eat_kw(p, "typedef")
    skip_qualifiers(p)

    -- Parse the type specifier
    local base_type = parse_type_spec(p)
    skip_qualifiers(p)

    -- After a struct/union/enum with a body, followed by ';' only → struct decl
    -- e.g. struct Foo { ... }; with no variable name
    if p.lex.tk == TK_SEMI then
        advance(p)
        if is_typedef then
            -- typedef struct { ... };  — unnamed, skip
        else
            local nm = base_type.name_id
            if nm then
                p.decls[#p.decls + 1] = {
                    decl = "struct",
                    name_id = nm,
                    type = base_type,
                }
            end
        end
        return true
    end

    -- Parse declarator(s) — may be comma-separated (rare for typedef but handle)
    local first = true
    repeat
        if not first then skip_qualifiers(p) end
        first = false

        local name_id, decl_type = parse_declarator(p, base_type)
        skip_qualifiers(p)

        if name_id then
            if is_typedef then
                p.typedefs[name_id] = true
                p.decls[#p.decls + 1] = {
                    decl = "typedef",
                    name_id = name_id,
                    type = decl_type,
                }
            else
                -- Function declaration vs variable declaration
                local dk
                if decl_type.k == "func" then
                    dk = "func"
                elseif decl_type.k == "ptr" and decl_type.to and decl_type.to.k == "func" then
                    dk = "func"
                else
                    dk = "var"
                end
                p.decls[#p.decls + 1] = {
                    decl = dk,
                    name_id = name_id,
                    type = decl_type,
                }
            end
        end
    until not eat(p, TK_COMMA)

    -- Optional trailing __attribute__
    skip_qualifiers(p)

    eat(p, TK_SEMI)
    return true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.parse(source, pool)
    local p = new_parser(source, pool)
    while p.lex.tk ~= TK_EOF do
        local ok, err = pcall(parse_one_decl, p)
        if not ok then
            -- Error recovery: skip to next semicolon
            skip_to_semi(p)
        end
    end
    return p.decls
end

return M
