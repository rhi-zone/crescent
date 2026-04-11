if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local P = require("lib.parse")

-- ── Primitives ──────────────────────────────────────────────────────────

T.describe("literal", function()
  T.it("matches exact string", function()
    local p = P.literal("hello")
    local r, npos = p("hello world", 1)
    T.eq(r, "hello")
    T.eq(npos, 6)
  end)

  T.it("fails on mismatch", function()
    local p = P.literal("hello")
    local r, epos, err = p("hxllo", 1)
    T.eq(r, nil)
    T.eq(epos, 1)
    T.ok(err:find("expected"))
  end)
end)

T.describe("char", function()
  T.it("matches single char", function()
    local p = P.char("a")
    local r, npos = p("abc", 1)
    T.eq(r, "a")
    T.eq(npos, 2)
  end)

  T.it("fails on wrong char", function()
    local p = P.char("a")
    local r = p("xyz", 1)
    T.eq(r, nil)
  end)
end)

T.describe("any_char", function()
  T.it("matches any char", function()
    local p = P.any_char()
    local r, npos = p("xyz", 1)
    T.eq(r, "x")
    T.eq(npos, 2)
  end)

  T.it("fails at EOF", function()
    local p = P.any_char()
    local r = p("", 1)
    T.eq(r, nil)
  end)
end)

T.describe("eof", function()
  T.it("succeeds at end", function()
    local p = P.eof()
    local r, npos = p("", 1)
    T.eq(r, true)
    T.eq(npos, 1)
  end)

  T.it("fails with remaining input", function()
    local p = P.eof()
    local r = p("abc", 1)
    T.eq(r, nil)
  end)
end)

T.describe("satisfy", function()
  T.it("matches digit", function()
    local p = P.satisfy(function(c) return c >= "0" and c <= "9" end)
    local r, npos = p("5x", 1)
    T.eq(r, "5")
    T.eq(npos, 2)
  end)

  T.it("fails on letter", function()
    local p = P.satisfy(function(c) return c >= "0" and c <= "9" end)
    local r = p("abc", 1)
    T.eq(r, nil)
  end)
end)

T.describe("range", function()
  T.it("matches char in range", function()
    local p = P.range("a", "z")
    local r, npos = p("m", 1)
    T.eq(r, "m")
    T.eq(npos, 2)
  end)

  T.it("fails outside range", function()
    local p = P.range("a", "z")
    local r = p("5", 1)
    T.eq(r, nil)
  end)
end)

T.describe("one_of / none_of", function()
  T.it("one_of matches char in set", function()
    local p = P.one_of("abc")
    local r = p("b", 1)
    T.eq(r, "b")
  end)

  T.it("one_of fails on char not in set", function()
    local p = P.one_of("abc")
    local r = p("x", 1)
    T.eq(r, nil)
  end)

  T.it("none_of matches char not in set", function()
    local p = P.none_of("abc")
    local r = p("x", 1)
    T.eq(r, "x")
  end)

  T.it("none_of fails on char in set", function()
    local p = P.none_of("abc")
    local r = p("a", 1)
    T.eq(r, nil)
  end)
end)

T.describe("pattern", function()
  T.it("matches Lua pattern", function()
    local p = P.pattern("[%d]+")
    local r, npos = p("123abc", 1)
    T.eq(r, "123")
    T.eq(npos, 4)
  end)

  T.it("fails when pattern doesn't match", function()
    local p = P.pattern("[%d]+")
    local r = p("abc", 1)
    T.eq(r, nil)
  end)
end)

-- ── Combinators ─────────────────────────────────────────────────────────

T.describe("seq", function()
  T.it("matches sequence, returns array", function()
    local p = P.seq(P.literal("ab"), P.literal("cd"))
    local r, npos = p("abcd", 1)
    T.eq(r[1], "ab")
    T.eq(r[2], "cd")
    T.eq(npos, 5)
  end)

  T.it("fails if any part fails", function()
    local p = P.seq(P.literal("ab"), P.literal("xy"))
    local r = p("abcd", 1)
    T.eq(r, nil)
  end)
end)

T.describe("alt", function()
  T.it("returns first matching alternative", function()
    local p = P.alt(P.literal("foo"), P.literal("bar"))
    local r = p("foo", 1)
    T.eq(r, "foo")
  end)

  T.it("tries all alternatives", function()
    local p = P.alt(P.literal("foo"), P.literal("bar"), P.literal("baz"))
    local r = p("baz", 1)
    T.eq(r, "baz")
  end)

  T.it("fails when no alternative matches", function()
    local p = P.alt(P.literal("foo"), P.literal("bar"))
    local r = p("qux", 1)
    T.eq(r, nil)
  end)
end)

T.describe("many", function()
  T.it("zero or more", function()
    local p = P.many(P.char("a"))
    local r, npos = p("aaab", 1)
    T.eq(#r, 3)
    T.eq(npos, 4)
  end)

  T.it("returns empty array on zero matches", function()
    local p = P.many(P.char("a"))
    local r, npos = p("bbb", 1)
    T.eq(#r, 0)
    T.eq(npos, 1)
  end)
end)

T.describe("many1", function()
  T.it("one or more", function()
    local p = P.many1(P.char("a"))
    local r, npos = p("aaa", 1)
    T.eq(#r, 3)
    T.eq(npos, 4)
  end)

  T.it("fails on zero", function()
    local p = P.many1(P.char("a"))
    local r = p("bbb", 1)
    T.eq(r, nil)
  end)
end)

T.describe("optional", function()
  T.it("returns result when match", function()
    local p = P.optional(P.literal("yes"))
    local r, npos = p("yes!", 1)
    T.eq(r, "yes")
    T.eq(npos, 4)
  end)

  T.it("returns nil when no match", function()
    local p = P.optional(P.literal("yes"))
    local r, npos = p("no", 1)
    T.eq(r, nil)
    T.eq(npos, 1)
  end)
end)

T.describe("count", function()
  T.it("exactly N repetitions", function()
    local p = P.count(P.char("a"), 3)
    local r, npos = p("aaaa", 1)
    T.eq(#r, 3)
    T.eq(npos, 4)
  end)

  T.it("fails when fewer than N", function()
    local p = P.count(P.char("a"), 3)
    local r = p("aa", 1)
    T.eq(r, nil)
  end)
end)

T.describe("sep_by", function()
  T.it("comma-separated values", function()
    local p = P.sep_by(P.pattern("[%a]+"), P.literal(","))
    local r, npos = p("a,bb,ccc", 1)
    T.eq(#r, 3)
    T.eq(r[1], "a")
    T.eq(r[2], "bb")
    T.eq(r[3], "ccc")
    T.eq(npos, 9)
  end)

  T.it("returns empty on no match", function()
    local p = P.sep_by(P.pattern("[%d]+"), P.literal(","))
    local r = p("abc", 1)
    T.eq(#r, 0)
  end)
end)

T.describe("sep_by1", function()
  T.it("at least one", function()
    local p = P.sep_by1(P.pattern("[%d]+"), P.literal(","))
    local r = p("1,2,3", 1)
    T.eq(#r, 3)
  end)

  T.it("fails on zero", function()
    local p = P.sep_by1(P.pattern("[%d]+"), P.literal(","))
    local r = p("abc", 1)
    T.eq(r, nil)
  end)
end)

T.describe("between", function()
  T.it("parens around content", function()
    local p = P.between(P.char("("), P.pattern("[%d]+"), P.char(")"))
    local r, npos = p("(42)", 1)
    T.eq(r, "42")
    T.eq(npos, 5)
  end)

  T.it("fails on missing close", function()
    local p = P.between(P.char("("), P.pattern("[%d]+"), P.char(")"))
    local r = p("(42", 1)
    T.eq(r, nil)
  end)
end)

-- ── Transformers ────────────────────────────────────────────────────────

T.describe("map", function()
  T.it("transforms result", function()
    local p = P.map(P.pattern("[%d]+"), tonumber)
    local r = p("42x", 1)
    T.eq(r, 42)
  end)
end)

T.describe("const", function()
  T.it("replaces result", function()
    local p = P.const(P.literal("true"), true)
    local r = p("true", 1)
    T.eq(r, true)
  end)
end)

T.describe("concat", function()
  T.it("joins array to string", function()
    local p = P.concat(P.many1(P.range("a", "z")))
    local r = p("hello123", 1)
    T.eq(r, "hello")
  end)
end)

T.describe("peek", function()
  T.it("doesn't consume input", function()
    local p = P.peek(P.literal("ab"))
    local r, npos = p("abcd", 1)
    T.eq(r, "ab")
    T.eq(npos, 1)
  end)

  T.it("fails propagated", function()
    local p = P.peek(P.literal("xy"))
    local r = p("abcd", 1)
    T.eq(r, nil)
  end)
end)

T.describe("not_followed_by", function()
  T.it("succeeds when parser fails", function()
    local p = P.not_followed_by(P.literal("bad"))
    local r, npos = p("good", 1)
    T.eq(r, true)
    T.eq(npos, 1)
  end)

  T.it("fails when parser succeeds", function()
    local p = P.not_followed_by(P.literal("bad"))
    local r = p("bad", 1)
    T.eq(r, nil)
  end)
end)

-- ── Whitespace / lexing ─────────────────────────────────────────────────

T.describe("lexeme / token", function()
  T.it("lexeme skips trailing whitespace", function()
    local p = P.lexeme(P.literal("hello"))
    local r, npos = p("hello   world", 1)
    T.eq(r, "hello")
    T.eq(npos, 9)
  end)

  T.it("token matches literal and skips whitespace", function()
    local p = P.seq(P.token("a"), P.token("b"))
    local r = p("a  b  ", 1)
    T.eq(r[1], "a")
    T.eq(r[2], "b")
  end)
end)

-- ── Recursion ───────────────────────────────────────────────────────────

T.describe("lazy", function()
  T.it("recursive grammar: balanced parens", function()
    local expr
    expr = P.lazy(function()
      return P.alt(
        P.between(P.char("("), expr, P.char(")")),
        P.literal("x")
      )
    end)
    local r, err = P.parse(expr, "((x))")
    T.eq(r, "x")
    T.eq(err, nil)
  end)
end)

-- ── Running ─────────────────────────────────────────────────────────────

T.describe("parse", function()
  T.it("full input consumed", function()
    local r, err = P.parse(P.literal("hello"), "hello")
    T.eq(r, "hello")
    T.eq(err, nil)
  end)

  T.it("error on unconsumed input", function()
    local r, err = P.parse(P.literal("hello"), "hello world")
    T.eq(r, nil)
    T.ok(err:find("unexpected input"))
  end)

  T.it("error on failed parse", function()
    local r, err = P.parse(P.literal("hello"), "xyz")
    T.eq(r, nil)
    T.ok(err:find("parse error"))
  end)
end)

T.describe("parse_partial", function()
  T.it("allows remaining input", function()
    local r, remaining = P.parse_partial(P.literal("hello"), "hello world")
    T.eq(r, "hello")
    T.eq(remaining, " world")
  end)

  T.it("error on failed parse", function()
    local r, err = P.parse_partial(P.literal("hello"), "xyz")
    T.eq(r, nil)
    T.ok(err:find("parse error"))
  end)
end)

T.describe("error messages", function()
  T.it("include position info", function()
    local r, err = P.parse(P.literal("hello"), "xyz")
    T.ok(err:find("line %d"))
    T.ok(err:find("col %d"))
  end)
end)

-- ── Composed examples ───────────────────────────────────────────────────

T.describe("JSON number parser", function()
  T.it("parses integers and decimals", function()
    local sign = P.optional(P.one_of("+-"))
    local digits = P.concat(P.many1(P.range("0", "9")))
    local decimal = P.concat(P.seq(P.char("."), digits))
    local number = P.map(
      P.concat(P.seq(
        P.map(sign, function(s) return s or "" end),
        digits,
        P.map(P.optional(decimal), function(d) return d or "" end)
      )),
      tonumber
    )

    local r1 = P.parse(number, "42")
    T.eq(r1, 42)

    local r2 = P.parse(number, "-3.14")
    T.eq(r2, -3.14)

    local r3 = P.parse(number, "+100")
    T.eq(r3, 100)
  end)
end)

T.describe("simple expression parser", function()
  T.it("1+2*3 with precedence", function()
    -- expr = term (('+' | '-') term)*
    -- term = factor (('*' | '/') factor)*
    -- factor = number | '(' expr ')'
    local expr

    local number = P.map(P.concat(P.many1(P.range("0", "9"))), tonumber)
    local ws = P.ws()

    local function lex(p)
      return function(input, pos)
        local _, npos = ws(input, pos)
        return p(input, npos)
      end
    end

    local factor = P.lazy(function()
      return P.alt(
        P.between(lex(P.char("(")), expr, lex(P.char(")"))),
        lex(number)
      )
    end)

    local mul_op = lex(P.one_of("*/"))
    local add_op = lex(P.one_of("+-"))

    local term = P.map(
      P.seq(factor, P.many(P.seq(mul_op, factor))),
      function(r)
        local result = r[1]
        for _, pair in ipairs(r[2]) do
          if pair[1] == "*" then result = result * pair[2]
          else result = result / pair[2] end
        end
        return result
      end
    )

    expr = P.map(
      P.seq(term, P.many(P.seq(add_op, term))),
      function(r)
        local result = r[1]
        for _, pair in ipairs(r[2]) do
          if pair[1] == "+" then result = result + pair[2]
          else result = result - pair[2] end
        end
        return result
      end
    )

    local r1 = P.parse(expr, "1+2*3")
    T.eq(r1, 7)

    local r2 = P.parse(expr, "(1+2)*3")
    T.eq(r2, 9)

    local r3 = P.parse(expr, "10-3+2")
    T.eq(r3, 9)
  end)
end)

-- Tests are run via: luajit lib/test/cli.lua
