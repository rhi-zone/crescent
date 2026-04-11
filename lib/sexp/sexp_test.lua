if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.sexp")

-- ──────────────────────────────────────────────
-- Symbol helpers
-- ──────────────────────────────────────────────
T.describe("sym helpers", function()
  T.it("sym creates a symbol", function()
    local s = S.sym("foo")
    T.ok(S.is_sym(s), "is_sym")
    T.eq(s._sym, "foo", "name")
  end)

  T.it("is_sym rejects plain strings", function()
    T.ok(not S.is_sym("foo"), "string is not sym")
  end)

  T.it("is_sym rejects numbers", function()
    T.ok(not S.is_sym(42), "number is not sym")
  end)

  T.it("sym tostring", function()
    T.eq(tostring(S.sym("bar")), "bar", "tostring")
  end)
end)

-- ──────────────────────────────────────────────
-- Decode atoms / symbols
-- ──────────────────────────────────────────────
T.describe("decode atoms", function()
  T.it("bare atom becomes symbol", function()
    local v, err = S.decode("foo")
    T.ok(err == nil, "no error")
    T.ok(S.is_sym(v), "is sym")
    T.eq(v._sym, "foo", "name")
  end)

  T.it("hyphenated atom", function()
    local v, err = S.decode("hello-world")
    T.ok(err == nil, "no error")
    T.ok(S.is_sym(v))
    T.eq(v._sym, "hello-world")
  end)

  T.it("operator atoms", function()
    local v = S.decode("+")
    T.ok(S.is_sym(v))
    T.eq(v._sym, "+")
    local v2 = S.decode("=")
    T.ok(S.is_sym(v2))
    T.eq(v2._sym, "=")
  end)
end)

-- ──────────────────────────────────────────────
-- Decode numbers
-- ──────────────────────────────────────────────
T.describe("decode numbers", function()
  T.it("positive integer", function()
    local v, err = S.decode("42")
    T.ok(err == nil)
    T.eq(v, 42)
  end)

  T.it("negative integer", function()
    local v, err = S.decode("-7")
    T.ok(err == nil)
    T.eq(v, -7)
  end)

  T.it("float", function()
    local v, err = S.decode("3.14")
    T.ok(err == nil)
    T.eq(v, 3.14)
  end)

  T.it("negative float", function()
    local v, err = S.decode("-0.5")
    T.ok(err == nil)
    T.eq(v, -0.5)
  end)

  T.it("zero", function()
    local v = S.decode("0")
    T.eq(v, 0)
  end)
end)

-- ──────────────────────────────────────────────
-- Decode strings
-- ──────────────────────────────────────────────
T.describe("decode strings", function()
  T.it("simple string", function()
    local v, err = S.decode('"hello world"')
    T.ok(err == nil)
    T.eq(v, "hello world")
    T.ok(not S.is_sym(v))
  end)

  T.it("escape sequences", function()
    local v = S.decode('"line1\\nline2"')
    T.eq(v, "line1\nline2")
  end)

  T.it("escaped tab", function()
    local v = S.decode('"a\\tb"')
    T.eq(v, "a\tb")
  end)

  T.it("escaped backslash", function()
    local v = S.decode('"a\\\\b"')
    T.eq(v, "a\\b")
  end)

  T.it("escaped quote", function()
    local v = S.decode('"say \\"hi\\""')
    T.eq(v, 'say "hi"')
  end)

  T.it("empty string", function()
    local v = S.decode('""')
    T.eq(v, "")
  end)
end)

-- ──────────────────────────────────────────────
-- Decode booleans
-- ──────────────────────────────────────────────
T.describe("decode booleans", function()
  T.it("#t is true", function()
    local v, err = S.decode("#t")
    T.ok(err == nil)
    T.eq(v, true)
  end)

  T.it("#f is false", function()
    local v, err = S.decode("#f")
    T.ok(err == nil)
    T.eq(v, false)
  end)

  T.it("true keyword", function()
    local v = S.decode("true")
    T.eq(v, true)
  end)

  T.it("false keyword", function()
    local v = S.decode("false")
    T.eq(v, false)
  end)
end)

-- ──────────────────────────────────────────────
-- Decode nil
-- ──────────────────────────────────────────────
T.describe("decode nil", function()
  T.it("nil atom returns nil value, no error", function()
    local v, err = S.decode("nil")
    T.ok(err == nil, "no error for nil atom")
    T.ok(v == nil, "value is nil")
  end)

  T.it("empty list is empty table", function()
    local v, err = S.decode("()")
    T.ok(err == nil)
    T.eq(type(v), "table")
    T.eq(#v, 0)
  end)
end)

-- ──────────────────────────────────────────────
-- Decode lists
-- ──────────────────────────────────────────────
T.describe("decode lists", function()
  T.it("simple list", function()
    local v, err = S.decode("(a b c)")
    T.ok(err == nil)
    T.eq(type(v), "table")
    T.eq(#v, 3)
    T.ok(S.is_sym(v[1]))
    T.eq(v[1]._sym, "a")
    T.eq(v[2]._sym, "b")
    T.eq(v[3]._sym, "c")
  end)

  T.it("list with mixed types", function()
    local v, err = S.decode('(foo 42 "bar" #t)')
    T.ok(err == nil)
    T.eq(#v, 4)
    T.ok(S.is_sym(v[1]))
    T.eq(v[2], 42)
    T.eq(v[3], "bar")
    T.eq(v[4], true)
  end)

  T.it("nested list", function()
    local v, err = S.decode("(a (b c) d)")
    T.ok(err == nil)
    T.eq(#v, 3)
    T.eq(v[1]._sym, "a")
    T.eq(type(v[2]), "table")
    T.eq(#v[2], 2)
    T.eq(v[2][1]._sym, "b")
    T.eq(v[3]._sym, "d")
  end)

  T.it("deeply nested list", function()
    local v = S.decode("(define (factorial n) (if (= n 0) 1 (* n (factorial (- n 1)))))")
    T.ok(v ~= nil)
    T.eq(#v, 3)
    T.eq(v[1]._sym, "define")
    T.eq(type(v[2]), "table")
    T.eq(v[2][1]._sym, "factorial")
  end)
end)

-- ──────────────────────────────────────────────
-- Comments
-- ──────────────────────────────────────────────
T.describe("comments", function()
  T.it("inline comment stripped", function()
    local v, err = S.decode("foo ; this is ignored")
    T.ok(err == nil)
    T.ok(S.is_sym(v))
    T.eq(v._sym, "foo")
  end)

  T.it("comment before expression", function()
    local v, err = S.decode(";; header\n42")
    T.ok(err == nil)
    T.eq(v, 42)
  end)

  T.it("comment inside list", function()
    local v, err = S.decode("(a ; comment\n b)")
    T.ok(err == nil)
    T.eq(#v, 2)
    T.eq(v[1]._sym, "a")
    T.eq(v[2]._sym, "b")
  end)
end)

-- ──────────────────────────────────────────────
-- Quote shorthand
-- ──────────────────────────────────────────────
T.describe("quote shorthand", function()
  T.it("'x -> (quote x)", function()
    local v, err = S.decode("'x")
    T.ok(err == nil)
    T.eq(type(v), "table")
    T.eq(#v, 2)
    T.eq(v[1]._sym, "quote")
    T.ok(S.is_sym(v[2]))
    T.eq(v[2]._sym, "x")
  end)

  T.it("'(a b) -> (quote (a b))", function()
    local v, err = S.decode("'(a b)")
    T.ok(err == nil)
    T.eq(v[1]._sym, "quote")
    T.eq(type(v[2]), "table")
    T.eq(#v[2], 2)
  end)
end)

-- ──────────────────────────────────────────────
-- decode_all
-- ──────────────────────────────────────────────
T.describe("decode_all", function()
  T.it("multiple top-level expressions", function()
    local vals, err = S.decode_all("(a b) (c d) 42")
    T.ok(err == nil)
    T.eq(vals.n, 3)
    T.eq(type(vals[1]), "table")
    T.eq(vals[3], 42)
  end)

  T.it("decode_all with comments between exprs", function()
    local vals, err = S.decode_all(";; first\nfoo\n;; second\nbar")
    T.ok(err == nil)
    T.eq(vals.n, 2)
    T.eq(vals[1]._sym, "foo")
    T.eq(vals[2]._sym, "bar")
  end)

  T.it("decode_all with nil atom", function()
    -- nil creates a hole in Lua arrays; use .n for true count
    local vals, err = S.decode_all("nil foo")
    T.ok(err == nil)
    T.eq(vals.n, 2, "n tracks true count")
    T.ok(vals[1] == nil, "first is nil")
    T.eq(vals[2]._sym, "foo")
  end)
end)

-- ──────────────────────────────────────────────
-- Error cases
-- ──────────────────────────────────────────────
T.describe("decode errors", function()
  T.it("unmatched open paren", function()
    local v, err = S.decode("(a b")
    T.ok(err ~= nil, "should error")
    T.ok(v == nil)
  end)

  T.it("unexpected close paren", function()
    local v, err = S.decode(")")
    T.ok(err ~= nil, "should error")
  end)

  T.it("unterminated string", function()
    local v, err = S.decode('"hello')
    T.ok(err ~= nil, "should error")
  end)

  T.it("empty input", function()
    local v, err = S.decode("")
    T.ok(err ~= nil, "should error on empty")
  end)
end)

-- ──────────────────────────────────────────────
-- Encode
-- ──────────────────────────────────────────────
T.describe("encode symbols", function()
  T.it("symbol encodes unquoted", function()
    local s, err = S.encode(S.sym("foo"))
    T.ok(err == nil)
    T.eq(s, "foo")
  end)

  T.it("operator symbol", function()
    local s = S.encode(S.sym("+"))
    T.eq(s, "+")
  end)

  T.it("hyphenated symbol", function()
    local s = S.encode(S.sym("hello-world"))
    T.eq(s, "hello-world")
  end)
end)

T.describe("encode strings", function()
  T.it("plain string is quoted", function()
    local s, err = S.encode("hello")
    T.ok(err == nil)
    T.eq(s, '"hello"')
  end)

  T.it("string with newline escape", function()
    local s = S.encode("line1\nline2")
    T.eq(s, '"line1\\nline2"')
  end)

  T.it("string with quote escape", function()
    local s = S.encode('say "hi"')
    T.eq(s, '"say \\"hi\\""')
  end)

  T.it("empty string", function()
    local s = S.encode("")
    T.eq(s, '""')
  end)
end)

T.describe("encode numbers", function()
  T.it("integer", function()
    local s = S.encode(42)
    T.eq(s, "42")
  end)

  T.it("negative integer", function()
    local s = S.encode(-7)
    T.eq(s, "-7")
  end)

  T.it("float", function()
    local s = S.encode(3.14)
    T.ok(s ~= nil)
    T.ok(s:find("3.14") ~= nil)
  end)
end)

T.describe("encode booleans", function()
  T.it("true -> #t", function()
    T.eq(S.encode(true), "#t")
  end)

  T.it("false -> #f", function()
    T.eq(S.encode(false), "#f")
  end)
end)

T.describe("encode nil", function()
  T.it("nil -> 'nil'", function()
    T.eq(S.encode(nil), "nil")
  end)
end)

T.describe("encode lists", function()
  T.it("simple list", function()
    local s = S.encode({ S.sym("a"), S.sym("b"), S.sym("c") })
    T.eq(s, "(a b c)")
  end)

  T.it("list with mixed types", function()
    local s = S.encode({ S.sym("foo"), 42, "bar", true })
    T.eq(s, '(foo 42 "bar" #t)')
  end)

  T.it("nested list", function()
    local s = S.encode({ S.sym("foo"), { S.sym("bar"), 42 } })
    T.eq(s, "(foo (bar 42))")
  end)

  T.it("empty list", function()
    local s = S.encode({})
    T.eq(s, "()")
  end)
end)

-- ──────────────────────────────────────────────
-- Round-trip tests
-- ──────────────────────────────────────────────
T.describe("round-trip", function()
  local function rt(src)
    local v, err = S.decode(src)
    if err then return nil, err end
    return S.encode(v)
  end

  T.it("symbol round-trip", function()
    T.eq(rt("foo"), "foo")
  end)

  T.it("number round-trip", function()
    T.eq(rt("42"), "42")
  end)

  T.it("boolean round-trip", function()
    T.eq(rt("#t"), "#t")
    T.eq(rt("#f"), "#f")
  end)

  T.it("string round-trip", function()
    T.eq(rt('"hello"'), '"hello"')
  end)

  T.it("list round-trip", function()
    T.eq(rt("(a b c)"), "(a b c)")
  end)

  T.it("nested list round-trip", function()
    T.eq(rt("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))"),
         "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))")
  end)

  T.it("encode_all / decode_all round-trip", function()
    local vals, err = S.decode_all("foo 42 (a b)")
    T.ok(err == nil)
    -- encode_all takes a plain array; build one from vals
    local arr = {}
    for i = 1, vals.n do arr[i] = vals[i] end
    local s, err2 = S.encode_all(arr)
    T.ok(err2 == nil)
    T.eq(s, 'foo\n42\n(a b)')
  end)
end)

-- ──────────────────────────────────────────────
-- Aliases
-- ──────────────────────────────────────────────
T.describe("aliases", function()
  T.it("parse == decode", function()
    T.eq(S.parse, S.decode)
  end)

  T.it("read == decode", function()
    T.eq(S.read, S.decode)
  end)

  T.it("write == encode", function()
    T.eq(S.write, S.encode)
  end)
end)
