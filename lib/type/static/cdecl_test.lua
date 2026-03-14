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

---------------------------------------------------------------------------
-- cdecl_parse tests
---------------------------------------------------------------------------

local cdecl_parse = require("lib.type.static.cdecl_parse")

-- Helper: parse source and return decls array.
local function parse(src, pool)
    return cdecl_parse.parse(src, pool)
end

-- Helper: find first decl with a given name string.
local function find_decl(decls, pool, name)
    local id = intern_mod.intern(pool, name)
    for _, d in ipairs(decls) do
        if d.name_id == id then return d end
    end
    return nil
end

assert.describe("cdecl_parse: simple function declarations", function()
    assert.it("void foo(void) → func decl, empty params", function()
        local pool = intern_mod.new()
        local decls = parse("void foo(void);", pool)
        local d = find_decl(decls, pool, "foo")
        assert.ok(d ~= nil, "foo decl found")
        assert.eq(d.decl, "func")
        assert.eq(d.type.k, "func")
        assert.eq(d.type.ret.k, "void")
        assert.eq(#d.type.params, 0)
        assert.eq(d.type.vararg, false)
    end)

    assert.it("int add(int a, int b) → func decl with two params", function()
        local pool = intern_mod.new()
        local decls = parse("int add(int a, int b);", pool)
        local d = find_decl(decls, pool, "add")
        assert.ok(d ~= nil, "add decl found")
        assert.eq(d.decl, "func")
        assert.eq(d.type.ret.k, "int")
        assert.eq(#d.type.params, 2)
        assert.eq(d.type.params[1].type.k, "int")
        assert.eq(d.type.params[2].type.k, "int")
        local a_id = intern_mod.intern(pool, "a")
        local b_id = intern_mod.intern(pool, "b")
        assert.eq(d.type.params[1].name_id, a_id)
        assert.eq(d.type.params[2].name_id, b_id)
    end)

    assert.it("int printf(const char *fmt, ...) → variadic", function()
        local pool = intern_mod.new()
        local decls = parse("int printf(const char *fmt, ...);", pool)
        local d = find_decl(decls, pool, "printf")
        assert.ok(d ~= nil, "printf decl found")
        assert.eq(d.type.vararg, true)
        assert.eq(#d.type.params, 1)
        assert.eq(d.type.params[1].type.k, "ptr")
        assert.eq(d.type.params[1].type.to.k, "char")
    end)
end)

assert.describe("cdecl_parse: struct typedef", function()
    assert.it("typedef struct { int x; int y; } Point", function()
        local pool = intern_mod.new()
        local decls = parse("typedef struct { int x; int y; } Point;", pool)
        local d = find_decl(decls, pool, "Point")
        assert.ok(d ~= nil, "Point typedef found")
        assert.eq(d.decl, "typedef")
        assert.eq(d.type.k, "struct")
        local fields = d.type.fields
        assert.ok(fields ~= nil, "struct has fields")
        assert.eq(#fields, 2)
        assert.eq(fields[1].type.k, "int")
        assert.eq(fields[2].type.k, "int")
        local x_id = intern_mod.intern(pool, "x")
        local y_id = intern_mod.intern(pool, "y")
        assert.eq(fields[1].name_id, x_id)
        assert.eq(fields[2].name_id, y_id)
    end)
end)

assert.describe("cdecl_parse: opaque struct", function()
    assert.it("struct Foo; → struct decl with no fields", function()
        local pool = intern_mod.new()
        local decls = parse("struct Foo;", pool)
        local d = find_decl(decls, pool, "Foo")
        assert.ok(d ~= nil, "Foo decl found")
        assert.eq(d.decl, "struct")
        assert.eq(d.type.k, "struct")
        assert.eq(d.type.fields, nil)
    end)
end)

assert.describe("cdecl_parse: pointer return type", function()
    assert.it("char *strdup(const char *s)", function()
        local pool = intern_mod.new()
        local decls = parse("char *strdup(const char *s);", pool)
        local d = find_decl(decls, pool, "strdup")
        assert.ok(d ~= nil, "strdup decl found")
        assert.eq(d.type.k, "func")
        assert.eq(d.type.ret.k, "ptr")
        assert.eq(d.type.ret.to.k, "char")
        assert.eq(#d.type.params, 1)
        assert.eq(d.type.params[1].type.k, "ptr")
        assert.eq(d.type.params[1].type.to.k, "char")
    end)
end)

assert.describe("cdecl_parse: enum typedef", function()
    assert.it("typedef enum { A=0, B=1 } MyEnum", function()
        local pool = intern_mod.new()
        local decls = parse("typedef enum { A=0, B=1 } MyEnum;", pool)
        local d = find_decl(decls, pool, "MyEnum")
        assert.ok(d ~= nil, "MyEnum typedef found")
        assert.eq(d.decl, "typedef")
        assert.eq(d.type.k, "enum")
        assert.eq(#d.type.members, 2)
        -- enum_val decls also emitted
        local a = find_decl(decls, pool, "A")
        local b = find_decl(decls, pool, "B")
        assert.ok(a ~= nil, "A enum_val found")
        assert.ok(b ~= nil, "B enum_val found")
        assert.eq(a.decl, "enum_val")
        assert.eq(a.value, 0)
        assert.eq(b.value, 1)
    end)
end)

assert.describe("cdecl_parse: multiple declarations", function()
    assert.it("two declarations in one string", function()
        local pool = intern_mod.new()
        local src = "void foo(void); int bar(int x);"
        local decls = parse(src, pool)
        local foo = find_decl(decls, pool, "foo")
        local bar = find_decl(decls, pool, "bar")
        assert.ok(foo ~= nil, "foo found")
        assert.ok(bar ~= nil, "bar found")
        assert.eq(foo.type.ret.k, "void")
        assert.eq(bar.type.ret.k, "int")
    end)
end)

assert.describe("cdecl_parse: typedef chain", function()
    assert.it("typedef int MyInt; MyInt foo(void) → foo ret is k=name", function()
        local pool = intern_mod.new()
        local src = "typedef int MyInt; MyInt foo(void);"
        local decls = parse(src, pool)
        local foo = find_decl(decls, pool, "foo")
        assert.ok(foo ~= nil, "foo found")
        assert.eq(foo.type.ret.k, "name")
        local myint_id = intern_mod.intern(pool, "MyInt")
        assert.eq(foo.type.ret.id, myint_id)
    end)
end)

assert.describe("cdecl_parse: __attribute__ skipping", function()
    assert.it("int foo(void) __attribute__((noreturn)) is parsed", function()
        local pool = intern_mod.new()
        local decls = parse("int foo(void) __attribute__((noreturn));", pool)
        local d = find_decl(decls, pool, "foo")
        assert.ok(d ~= nil, "foo found despite __attribute__")
        assert.eq(d.type.ret.k, "int")
        assert.eq(#d.type.params, 0)
    end)
end)

assert.describe("cdecl_parse: (void) parameter", function()
    assert.it("void bar(void) → empty params array", function()
        local pool = intern_mod.new()
        local decls = parse("void bar(void);", pool)
        local d = find_decl(decls, pool, "bar")
        assert.ok(d ~= nil, "bar found")
        assert.eq(#d.type.params, 0)
    end)
end)

assert.describe("cdecl_parse: function pointer typedef", function()
    assert.it("typedef void (*callback)(int) → ptr to func", function()
        local pool = intern_mod.new()
        local decls = parse("typedef void (*callback)(int);", pool)
        local d = find_decl(decls, pool, "callback")
        assert.ok(d ~= nil, "callback typedef found")
        assert.eq(d.decl, "typedef")
        assert.eq(d.type.k, "ptr")
        assert.eq(d.type.to.k, "func")
        assert.eq(d.type.to.ret.k, "void")
        assert.eq(#d.type.to.params, 1)
        assert.eq(d.type.to.params[1].type.k, "int")
    end)
end)

assert.describe("cdecl_parse: error recovery", function()
    assert.it("bad decl followed by good one — good one is parsed", function()
        local pool = intern_mod.new()
        -- "123 !!!" is not a valid declaration; skip to ';', then parse good one
        local src = "@@@ bad decl ###; void good(void);"
        local decls = parse(src, pool)
        local d = find_decl(decls, pool, "good")
        assert.ok(d ~= nil, "good decl found after error recovery")
        assert.eq(d.type.ret.k, "void")
    end)
end)
