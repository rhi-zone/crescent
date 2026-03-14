-- lib/type/static/cdecl_test.lua
-- Tests for the C declaration lexer (cdecl_lex.lua).

local assert = require("lib.test.assert")
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
local TK_COLON    = cdecl_lex.TK_COLON
local TK_EOF      = cdecl_lex.TK_EOF

-- Helper: lex all tokens from source, return list of {tk, val} pairs.
-- Stops at (and includes) TK_EOF.
local function lex_all(source, pool)
    local lex = cdecl_lex.new(source, pool)
    local tokens = {}
    while true do
        tokens[#tokens + 1] = { lex.tk, lex.val }
        if lex.tk == TK_EOF then break end
        lex:next()
    end
    return tokens
end

-- Helper: lex all non-EOF token types.
local function lex_types(source, pool)
    local toks = lex_all(source, pool)
    local types = {}
    for _, t in ipairs(toks) do
        if t[1] ~= TK_EOF then types[#types + 1] = t[1] end
    end
    return types
end

-- Helper: assert two arrays of integers are equal element-by-element.
local function assert_seq(got, expected, label)
    label = label or ""
    assert.eq(#got, #expected, label .. " length")
    for i = 1, #expected do
        assert.eq(got[i], expected[i], label .. "[" .. i .. "]")
    end
end

---------------------------------------------------------------------------
-- EOF on empty input
---------------------------------------------------------------------------

assert.describe("cdecl_lex: EOF", function()
    assert.it("empty string yields TK_EOF immediately", function()
        local lex = cdecl_lex.new("")
        assert.eq(lex.tk, TK_EOF)
    end)

    assert.it("whitespace-only yields TK_EOF", function()
        local lex = cdecl_lex.new("   \t\n\r  ")
        assert.eq(lex.tk, TK_EOF)
    end)
end)

---------------------------------------------------------------------------
-- Identifier lexing
---------------------------------------------------------------------------

assert.describe("cdecl_lex: identifiers", function()
    assert.it("single identifier", function()
        local pool = intern_mod.new()
        local lex = cdecl_lex.new("hello", pool)
        assert.eq(lex.tk, TK_IDENT)
        assert.eq(intern_mod.get(pool, lex.val), "hello")
    end)

    assert.it("underscore-prefixed identifier", function()
        local pool = intern_mod.new()
        local lex = cdecl_lex.new("_Foo123", pool)
        assert.eq(lex.tk, TK_IDENT)
        assert.eq(intern_mod.get(pool, lex.val), "_Foo123")
    end)

    assert.it("multiple identifiers separated by whitespace", function()
        local pool = intern_mod.new()
        local toks = lex_all("foo bar baz", pool)
        assert.eq(#toks, 4)  -- 3 idents + EOF
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(toks[3][1], TK_IDENT)
        assert.eq(toks[4][1], TK_EOF)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
        assert.eq(intern_mod.get(pool, toks[3][2]), "baz")
    end)

    assert.it("same identifier lexed twice has same intern_id", function()
        local pool = intern_mod.new()
        local t1 = lex_all("mytype", pool)
        local t2 = lex_all("mytype", pool)
        assert.eq(t1[1][2], t2[1][2])
    end)
end)

---------------------------------------------------------------------------
-- Keywords are just TK_IDENT
---------------------------------------------------------------------------

assert.describe("cdecl_lex: C keywords are TK_IDENT", function()
    local keywords = {
        "void", "int", "char", "short", "long", "float", "double",
        "unsigned", "signed", "struct", "union", "enum", "typedef",
        "const", "volatile", "extern", "static", "inline",
    }
    for _, kw in ipairs(keywords) do
        assert.it(kw .. " → TK_IDENT", function()
            local pool = intern_mod.new()
            local lex = cdecl_lex.new(kw, pool)
            assert.eq(lex.tk, TK_IDENT)
            assert.eq(intern_mod.get(pool, lex.val), kw)
        end)
    end
end)

---------------------------------------------------------------------------
-- Integer literals
---------------------------------------------------------------------------

assert.describe("cdecl_lex: integer literals", function()
    assert.it("decimal zero", function()
        local lex = cdecl_lex.new("0")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 0)
    end)

    assert.it("decimal positive", function()
        local lex = cdecl_lex.new("42")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 42)
    end)

    assert.it("decimal large", function()
        local lex = cdecl_lex.new("12345")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 12345)
    end)

    assert.it("hex lowercase 0xff", function()
        local lex = cdecl_lex.new("0xff")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 255)
    end)

    assert.it("hex uppercase 0XFF", function()
        local lex = cdecl_lex.new("0XFF")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 255)
    end)

    assert.it("hex mixed case 0xDeAdBeEf", function()
        local lex = cdecl_lex.new("0xDeAdBeEf")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 0xDeAdBeEf)
    end)

    assert.it("decimal with u suffix", function()
        local lex = cdecl_lex.new("10u")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 10)
    end)

    assert.it("decimal with U suffix", function()
        local lex = cdecl_lex.new("10U")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 10)
    end)

    assert.it("decimal with l suffix", function()
        local lex = cdecl_lex.new("10l")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 10)
    end)

    assert.it("decimal with L suffix", function()
        local lex = cdecl_lex.new("10L")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 10)
    end)

    assert.it("decimal with LL suffix", function()
        local lex = cdecl_lex.new("10LL")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 10)
    end)

    assert.it("hex with uLL suffix", function()
        local lex = cdecl_lex.new("0x1AuLL")
        assert.eq(lex.tk, TK_INT)
        assert.eq(lex.val, 26)
    end)

    assert.it("integer followed by semicolon", function()
        local toks = lex_all("255;")
        assert.eq(toks[1][1], TK_INT)
        assert.eq(toks[1][2], 255)
        assert.eq(toks[2][1], TK_SEMI)
    end)
end)

---------------------------------------------------------------------------
-- Punctuation tokens
---------------------------------------------------------------------------

assert.describe("cdecl_lex: punctuation", function()
    assert.it("semicolon", function()
        assert_seq(lex_types(";"), { TK_SEMI })
    end)

    assert.it("comma", function()
        assert_seq(lex_types(","), { TK_COMMA })
    end)

    assert.it("star", function()
        assert_seq(lex_types("*"), { TK_STAR })
    end)

    assert.it("lparen", function()
        assert_seq(lex_types("("), { TK_LPAREN })
    end)

    assert.it("rparen", function()
        assert_seq(lex_types(")"), { TK_RPAREN })
    end)

    assert.it("lbrace", function()
        assert_seq(lex_types("{"), { TK_LBRACE })
    end)

    assert.it("rbrace", function()
        assert_seq(lex_types("}"), { TK_RBRACE })
    end)

    assert.it("lbrack", function()
        assert_seq(lex_types("["), { TK_LBRACK })
    end)

    assert.it("rbrack", function()
        assert_seq(lex_types("]"), { TK_RBRACK })
    end)

    assert.it("assign", function()
        assert_seq(lex_types("="), { TK_ASSIGN })
    end)

    assert.it("colon", function()
        assert_seq(lex_types(":"), { TK_COLON })
    end)

    assert.it("multiple punctuation tokens", function()
        assert_seq(lex_types("(*)("), { TK_LPAREN, TK_STAR, TK_RPAREN, TK_LPAREN })
    end)
end)

---------------------------------------------------------------------------
-- Ellipsis
---------------------------------------------------------------------------

assert.describe("cdecl_lex: ellipsis", function()
    assert.it("... yields TK_ELLIPSIS", function()
        assert_seq(lex_types("..."), { TK_ELLIPSIS })
    end)

    assert.it("ellipsis in function params context", function()
        -- int foo(int x, ...)
        local pool = intern_mod.new()
        local toks = lex_all("int foo(int x, ...)", pool)
        local types = {}
        for _, t in ipairs(toks) do
            if t[1] ~= TK_EOF then types[#types + 1] = t[1] end
        end
        assert_seq(types, {
            TK_IDENT, TK_IDENT, TK_LPAREN,
            TK_IDENT, TK_IDENT, TK_COMMA,
            TK_ELLIPSIS, TK_RPAREN
        })
    end)
end)

---------------------------------------------------------------------------
-- Comment skipping
---------------------------------------------------------------------------

assert.describe("cdecl_lex: comment skipping", function()
    assert.it("line comment skipped", function()
        local pool = intern_mod.new()
        local toks = lex_all("foo // this is a comment\nbar", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
        assert.eq(toks[3][1], TK_EOF)
    end)

    assert.it("block comment skipped", function()
        local pool = intern_mod.new()
        local toks = lex_all("foo /* block comment */ bar", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
        assert.eq(toks[3][1], TK_EOF)
    end)

    assert.it("multiline block comment skipped", function()
        local pool = intern_mod.new()
        local toks = lex_all("a /*\n  multi\n  line\n*/ b", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "a")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "b")
        assert.eq(toks[3][1], TK_EOF)
    end)

    assert.it("line comment at end of file (no trailing newline)", function()
        local pool = intern_mod.new()
        local toks = lex_all("x // eof comment", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "x")
        assert.eq(toks[2][1], TK_EOF)
    end)

    assert.it("block comment containing * chars", function()
        local pool = intern_mod.new()
        local toks = lex_all("a /* x * y ** z */ b", pool)
        assert.eq(#toks, 3)  -- a, b, EOF
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(toks[2][1], TK_IDENT)
    end)
end)

---------------------------------------------------------------------------
-- Whitespace skipping
---------------------------------------------------------------------------

assert.describe("cdecl_lex: whitespace skipping", function()
    assert.it("spaces between tokens", function()
        local pool = intern_mod.new()
        local toks = lex_all("  foo   bar  ", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
        assert.eq(toks[3][1], TK_EOF)
    end)

    assert.it("tabs and form feeds skipped", function()
        assert_seq(lex_types("\t\f;\v;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("newlines (LF) skipped", function()
        assert_seq(lex_types(";\n;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("newlines (CR) skipped", function()
        assert_seq(lex_types(";\r;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("CRLF skipped as single newline", function()
        assert_seq(lex_types(";\r\n;"), { TK_SEMI, TK_SEMI })
    end)
end)

---------------------------------------------------------------------------
-- String and char literal skipping
---------------------------------------------------------------------------

assert.describe("cdecl_lex: string/char literal skipping", function()
    assert.it("double-quoted string skipped", function()
        local pool = intern_mod.new()
        local toks = lex_all('foo "some string" bar', pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
        assert.eq(toks[3][1], TK_EOF)
    end)

    assert.it("single-quoted char literal skipped", function()
        local pool = intern_mod.new()
        local toks = lex_all("foo 'x' bar", pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
    end)

    assert.it("string with escape sequence skipped cleanly", function()
        local pool = intern_mod.new()
        local toks = lex_all('foo "ab\\"cd" bar', pool)
        assert.eq(toks[1][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[1][2]), "foo")
        assert.eq(toks[2][1], TK_IDENT)
        assert.eq(intern_mod.get(pool, toks[2][2]), "bar")
    end)
end)

---------------------------------------------------------------------------
-- Unrecognized byte skipping
---------------------------------------------------------------------------

assert.describe("cdecl_lex: unrecognized byte skipping", function()
    assert.it("& skipped", function()
        assert_seq(lex_types(";&;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("~ skipped", function()
        assert_seq(lex_types(";~;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("# skipped", function()
        assert_seq(lex_types(";#;"), { TK_SEMI, TK_SEMI })
    end)

    assert.it("single dot skipped", function()
        assert_seq(lex_types(";.;"), { TK_SEMI, TK_SEMI })
    end)
end)

---------------------------------------------------------------------------
-- Shared intern pool
---------------------------------------------------------------------------

assert.describe("cdecl_lex: shared intern pool", function()
    assert.it("same identifier in C and Lua source gets same intern_id", function()
        local defs = require("lib.type.static.defs")
        local lex_mod = require("lib.type.static.lex")
        local pool = intern_mod.new()

        -- Lex a C declaration containing "mytype"
        local clex = cdecl_lex.new("typedef int mytype;", pool)
        local c_mytype_id
        while clex.tk ~= TK_EOF do
            if clex.tk == TK_IDENT then
                local name = intern_mod.get(pool, clex.val)
                if name == "mytype" then c_mytype_id = clex.val end
            end
            clex:next()
        end

        -- Lex Lua source containing "mytype"
        local lua_source = "local mytype = 1"
        local llex = lex_mod.new(lua_source, "test.lua", pool)
        local lua_mytype_id
        while llex.tk ~= defs.TK_EOF do
            if llex.tk == defs.TK_NAME then
                local name = intern_mod.get(pool, llex.val)
                if name == "mytype" then lua_mytype_id = llex.val end
            end
            llex:next()
        end

        assert.ok(c_mytype_id ~= nil, "c_mytype_id should be found")
        assert.ok(lua_mytype_id ~= nil, "lua_mytype_id should be found")
        assert.eq(c_mytype_id, lua_mytype_id)
    end)

    assert.it("C keywords interned to same IDs across two lexers with same pool", function()
        local pool = intern_mod.new()
        local lex1 = cdecl_lex.new("void int", pool)
        local lex2 = cdecl_lex.new("void int", pool)

        local id_void_1 = lex1.val
        lex1:next()
        local id_int_1 = lex1.val

        local id_void_2 = lex2.val
        lex2:next()
        local id_int_2 = lex2.val

        assert.eq(id_void_1, id_void_2)
        assert.eq(id_int_1, id_int_2)
    end)
end)

---------------------------------------------------------------------------
-- Realistic C declaration snippet
---------------------------------------------------------------------------

assert.describe("cdecl_lex: realistic snippet", function()
    assert.it("struct with fields", function()
        local pool = intern_mod.new()
        local src = [[
struct Point {
    int x;
    int y;
};
]]
        local toks = lex_all(src, pool)
        local types = {}
        for _, t in ipairs(toks) do
            if t[1] ~= TK_EOF then types[#types + 1] = t[1] end
        end
        assert_seq(types, {
            TK_IDENT,   -- struct
            TK_IDENT,   -- Point
            TK_LBRACE,
            TK_IDENT,   -- int
            TK_IDENT,   -- x
            TK_SEMI,
            TK_IDENT,   -- int
            TK_IDENT,   -- y
            TK_SEMI,
            TK_RBRACE,
            TK_SEMI,
        })
        -- Check field names
        assert.eq(intern_mod.get(pool, toks[1][2]), "struct")
        assert.eq(intern_mod.get(pool, toks[2][2]), "Point")
    end)

    assert.it("function pointer typedef", function()
        local pool = intern_mod.new()
        local src = "typedef int (*callback)(int, const char *);"
        local types = lex_types(src, pool)
        assert_seq(types, {
            TK_IDENT,   -- typedef
            TK_IDENT,   -- int
            TK_LPAREN,
            TK_STAR,
            TK_IDENT,   -- callback
            TK_RPAREN,
            TK_LPAREN,
            TK_IDENT,   -- int
            TK_COMMA,
            TK_IDENT,   -- const
            TK_IDENT,   -- char
            TK_STAR,
            TK_RPAREN,
            TK_SEMI,
        })
    end)

    assert.it("enum with hex values", function()
        local pool = intern_mod.new()
        local src = "enum Flags { A = 0x01, B = 0x02, C = 0x04 };"
        local toks = lex_all(src, pool)
        -- Collect INT values
        local ints = {}
        for _, t in ipairs(toks) do
            if t[1] == TK_INT then ints[#ints + 1] = t[2] end
        end
        assert_seq(ints, { 1, 2, 4 })
    end)
end)
