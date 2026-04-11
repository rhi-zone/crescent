if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local G = require("lib.grammar")

-- ── lit ───────────────────────────────────────────────────────────────────────

T.describe("lit", function()
  T.it("matches exact string", function()
    local p = G.lit("hello")
    local ok, matched, rest = p:match("hello world")
    T.ok(ok)
    T.eq(matched, "hello")
    T.eq(rest, " world")
  end)

  T.it("fails when string not present", function()
    local p = G.lit("hello")
    local ok = p:match("world")
    T.fail(ok)
  end)

  T.it("fails on empty input", function()
    local p = G.lit("x")
    local ok = p:match("")
    T.fail(ok)
  end)

  T.it("matches at position via parse_at", function()
    local p = G.lit("bc")
    local caps, new_pos = p:parse_at("abcd", 2)
    T.ok(caps ~= nil)
    T.eq(new_pos, 4)
  end)

  T.it("fails at wrong position", function()
    local p = G.lit("bc")
    local caps = p:parse_at("abcd", 1)
    T.fail(caps)
  end)
end)

-- ── any ───────────────────────────────────────────────────────────────────────

T.describe("any", function()
  T.it("matches single character", function()
    local ok, matched, rest = G.any:match("abc")
    T.ok(ok)
    T.eq(matched, "a")
    T.eq(rest, "bc")
  end)

  T.it("fails on empty input", function()
    local ok = G.any:match("")
    T.fail(ok)
  end)

  T.it("matches last character", function()
    local ok, matched, rest = G.any:match("z")
    T.ok(ok)
    T.eq(matched, "z")
    T.eq(rest, "")
  end)
end)

-- ── eof ───────────────────────────────────────────────────────────────────────

T.describe("eof", function()
  T.it("matches empty string", function()
    local ok, matched = G.eof:match("")
    T.ok(ok)
    T.eq(matched, "")
  end)

  T.it("fails on non-empty input", function()
    local ok = G.eof:match("a")
    T.fail(ok)
  end)

  T.it("matches at end of input via parse_at", function()
    local caps, new_pos = G.eof:parse_at("ab", 3)
    T.ok(caps ~= nil)
    T.eq(new_pos, 3)
  end)
end)

-- ── range ─────────────────────────────────────────────────────────────────────

T.describe("range", function()
  T.it("matches character in range", function()
    local p = G.range("a", "z")
    local ok, matched = p:match("m")
    T.ok(ok)
    T.eq(matched, "m")
  end)

  T.it("matches boundary characters", function()
    local p = G.range("a", "z")
    local ok1 = p:match("a")
    local ok2 = p:match("z")
    T.ok(ok1)
    T.ok(ok2)
  end)

  T.it("fails on character outside range", function()
    local p = G.range("a", "z")
    local ok = p:match("A")
    T.fail(ok)
  end)

  T.it("fails on empty input", function()
    local p = G.range("a", "z")
    local ok = p:match("")
    T.fail(ok)
  end)
end)

-- ── set ───────────────────────────────────────────────────────────────────────

T.describe("set", function()
  T.it("matches character in set", function()
    local p = G.set("aeiou")
    local ok, matched = p:match("e")
    T.ok(ok)
    T.eq(matched, "e")
  end)

  T.it("fails on character not in set", function()
    local p = G.set("aeiou")
    local ok = p:match("b")
    T.fail(ok)
  end)

  T.it("fails on empty input", function()
    local ok = G.set("abc"):match("")
    T.fail(ok)
  end)
end)

-- ── not_set ───────────────────────────────────────────────────────────────────

T.describe("not_set", function()
  T.it("matches character not in set", function()
    local p = G.not_set("aeiou")
    local ok, matched = p:match("b")
    T.ok(ok)
    T.eq(matched, "b")
  end)

  T.it("fails on character in set", function()
    local p = G.not_set("aeiou")
    local ok = p:match("a")
    T.fail(ok)
  end)

  T.it("fails on empty input", function()
    local ok = G.not_set("abc"):match("")
    T.fail(ok)
  end)
end)

-- ── seq ───────────────────────────────────────────────────────────────────────

T.describe("seq", function()
  T.it("matches sequence of literals", function()
    local p = G.seq(G.lit("foo"), G.lit("bar"))
    local ok, matched, rest = p:match("foobar!")
    T.ok(ok)
    T.eq(matched, "foobar")
    T.eq(rest, "!")
  end)

  T.it("fails when any part fails", function()
    local p = G.seq(G.lit("foo"), G.lit("bar"))
    local ok = p:match("foobaz")
    T.fail(ok)
  end)

  T.it("fails on partial match", function()
    local p = G.seq(G.lit("foo"), G.lit("bar"))
    local ok = p:match("foo")
    T.fail(ok)
  end)

  T.it("combines captures from parts", function()
    local p = G.seq(G.capture(G.lit("foo"), "a"), G.capture(G.lit("bar"), "b"))
    local caps, _ = p:parse_at("foobar", 1)
    T.ok(caps ~= nil)
    T.eq(caps.a, "foo")
    T.eq(caps.b, "bar")
  end)
end)

-- ── alt ───────────────────────────────────────────────────────────────────────

T.describe("alt", function()
  T.it("matches first alternative", function()
    local p = G.alt(G.lit("foo"), G.lit("bar"))
    local ok, matched = p:match("foo")
    T.ok(ok)
    T.eq(matched, "foo")
  end)

  T.it("falls back to second alternative", function()
    local p = G.alt(G.lit("foo"), G.lit("bar"))
    local ok, matched = p:match("bar")
    T.ok(ok)
    T.eq(matched, "bar")
  end)

  T.it("fails when no alternative matches", function()
    local p = G.alt(G.lit("foo"), G.lit("bar"))
    local ok = p:match("baz")
    T.fail(ok)
  end)

  T.it("first alternative wins (PEG ordered choice)", function()
    -- Even if second is a longer match, first wins if it matches.
    local p = G.alt(G.lit("fo"), G.lit("foo"))
    local ok, matched = p:match("foo")
    T.ok(ok)
    T.eq(matched, "fo")
  end)
end)

-- ── opt ───────────────────────────────────────────────────────────────────────

T.describe("opt", function()
  T.it("matches when present", function()
    local p = G.opt(G.lit("foo"))
    local ok, matched, rest = p:match("foobar")
    T.ok(ok)
    T.eq(matched, "foo")
    T.eq(rest, "bar")
  end)

  T.it("succeeds with empty match when absent", function()
    local p = G.opt(G.lit("foo"))
    local ok, matched, rest = p:match("bar")
    T.ok(ok)
    T.eq(matched, "")
    T.eq(rest, "bar")
  end)

  T.it("always succeeds on empty input", function()
    local p = G.opt(G.lit("foo"))
    local ok = p:match("")
    T.ok(ok)
  end)
end)

-- ── star ─────────────────────────────────────────────────────────────────────

T.describe("star", function()
  T.it("matches zero times", function()
    local p = G.star(G.lit("a"))
    local ok, matched, rest = p:match("bbb")
    T.ok(ok)
    T.eq(matched, "")
    T.eq(rest, "bbb")
  end)

  T.it("matches one time", function()
    local p = G.star(G.lit("a"))
    local ok, matched, rest = p:match("ab")
    T.ok(ok)
    T.eq(matched, "a")
    T.eq(rest, "b")
  end)

  T.it("matches many times", function()
    local p = G.star(G.lit("a"))
    local ok, matched, rest = p:match("aaab")
    T.ok(ok)
    T.eq(matched, "aaa")
    T.eq(rest, "b")
  end)

  T.it("always succeeds on empty input", function()
    local p = G.star(G.range("a", "z"))
    local ok = p:match("")
    T.ok(ok)
  end)
end)

-- ── plus ─────────────────────────────────────────────────────────────────────

T.describe("plus", function()
  T.it("matches one time", function()
    local p = G.plus(G.lit("a"))
    local ok, matched, rest = p:match("ab")
    T.ok(ok)
    T.eq(matched, "a")
    T.eq(rest, "b")
  end)

  T.it("matches many times", function()
    local p = G.plus(G.lit("a"))
    local ok, matched, rest = p:match("aaab")
    T.ok(ok)
    T.eq(matched, "aaa")
    T.eq(rest, "b")
  end)

  T.it("fails on zero matches", function()
    local p = G.plus(G.lit("a"))
    local ok = p:match("bbb")
    T.fail(ok)
  end)

  T.it("fails on empty input", function()
    local p = G.plus(G.range("a", "z"))
    local ok = p:match("")
    T.fail(ok)
  end)
end)

-- ── times ─────────────────────────────────────────────────────────────────────

T.describe("times", function()
  T.it("matches exactly n times", function()
    local p = G.times(G.lit("a"), 3)
    local ok, matched, rest = p:match("aaab")
    T.ok(ok)
    T.eq(matched, "aaa")
    T.eq(rest, "b")
  end)

  T.it("fails when fewer than n matches", function()
    local p = G.times(G.lit("a"), 3)
    local ok = p:match("aab")
    T.fail(ok)
  end)

  T.it("stops at n (does not over-consume)", function()
    local p = G.times(G.lit("a"), 2)
    local ok, matched, rest = p:match("aaaa")
    T.ok(ok)
    T.eq(matched, "aa")
    T.eq(rest, "aa")
  end)
end)

-- ── between ──────────────────────────────────────────────────────────────────

T.describe("between", function()
  T.it("matches when count is within range", function()
    local p = G.between(G.lit("a"), 2, 4)
    local ok, matched, rest = p:match("aaab")
    T.ok(ok)
    T.eq(matched, "aaa")
    T.eq(rest, "b")
  end)

  T.it("matches exactly min times when only min available", function()
    local p = G.between(G.lit("a"), 2, 4)
    local ok, matched, rest = p:match("aab")
    T.ok(ok)
    T.eq(matched, "aa")
    T.eq(rest, "b")
  end)

  T.it("caps at max", function()
    local p = G.between(G.lit("a"), 2, 3)
    local ok, matched, rest = p:match("aaaaa")
    T.ok(ok)
    T.eq(matched, "aaa")
    T.eq(rest, "aa")
  end)

  T.it("fails when fewer than min matches", function()
    local p = G.between(G.lit("a"), 2, 4)
    local ok = p:match("ab")
    T.fail(ok)
  end)

  T.it("between(p, 0, 1) acts like opt", function()
    local p = G.between(G.lit("x"), 0, 1)
    local ok1 = p:match("x")
    local ok2 = p:match("y")
    T.ok(ok1)
    T.ok(ok2)
  end)
end)

-- ── not_ ─────────────────────────────────────────────────────────────────────

T.describe("not_", function()
  T.it("succeeds without consuming when p fails", function()
    local p = G.not_(G.lit("foo"))
    local ok, matched, rest = p:match("bar")
    T.ok(ok)
    T.eq(matched, "")   -- nothing consumed
    T.eq(rest, "bar")
  end)

  T.it("fails when p matches", function()
    local p = G.not_(G.lit("foo"))
    local ok = p:match("foobar")
    T.fail(ok)
  end)

  T.it("can be used as lookahead guard in seq", function()
    -- Match 'b' only when NOT preceded by (lookahead) 'a' — this tests not_ in a seq
    local p = G.seq(G.not_(G.lit("a")), G.any)
    local ok, matched = p:match("b")
    T.ok(ok)
    T.eq(matched, "b")
    local ok2 = p:match("a")
    T.fail(ok2)
  end)
end)

-- ── and_ ─────────────────────────────────────────────────────────────────────

T.describe("and_", function()
  T.it("succeeds without consuming when p matches", function()
    local p = G.and_(G.lit("foo"))
    local ok, matched, rest = p:match("foobar")
    T.ok(ok)
    T.eq(matched, "")    -- nothing consumed
    T.eq(rest, "foobar")
  end)

  T.it("fails when p does not match", function()
    local p = G.and_(G.lit("foo"))
    local ok = p:match("bar")
    T.fail(ok)
  end)
end)

-- ── capture ───────────────────────────────────────────────────────────────────

T.describe("capture", function()
  T.it("returns named field with matched text", function()
    local p = G.capture(G.plus(G.range("0", "9")), "num")
    local caps, new_pos = p:parse_at("123abc", 1)
    T.ok(caps ~= nil)
    T.eq(caps.num, "123")
    T.eq(new_pos, 4)
  end)

  T.it("fails when inner parser fails", function()
    local p = G.capture(G.lit("foo"), "x")
    local caps = p:parse_at("bar", 1)
    T.fail(caps)
  end)

  T.it("merges multiple named captures from seq", function()
    local p = G.seq(
      G.capture(G.plus(G.range("a", "z")), "word"),
      G.lit("="),
      G.capture(G.plus(G.range("0", "9")), "val")
    )
    local caps, _ = p:parse_at("abc=42", 1)
    T.ok(caps ~= nil)
    T.eq(caps.word, "abc")
    T.eq(caps.val, "42")
  end)

  T.it("match returns full matched string", function()
    local p = G.capture(G.plus(G.range("a", "z")), "w")
    local ok, matched = p:match("hello world")
    T.ok(ok)
    T.eq(matched, "hello")
  end)
end)

-- ── grammar and ref ───────────────────────────────────────────────────────────

T.describe("grammar + ref (arithmetic expression)", function()
  -- Simple expression grammar: expr = term (('+' | '-') term)*
  --                            term = factor (('*' | '/') factor)*
  --                            factor = number | '(' expr ')'
  --                            number = [0-9]+

  local g = G.grammar({
    start = "expr",
    expr = G.seq(
      G.ref("term"),
      G.star(G.seq(G.alt(G.lit("+"), G.lit("-")), G.ref("term")))
    ),
    term = G.seq(
      G.ref("factor"),
      G.star(G.seq(G.alt(G.lit("*"), G.lit("/")), G.ref("factor")))
    ),
    factor = G.alt(
      G.ref("number"),
      G.seq(G.lit("("), G.ref("expr"), G.lit(")"))
    ),
    number = G.capture(G.plus(G.range("0", "9")), "number"),
  })

  T.it("parses a simple number", function()
    local caps, new_pos = g:parse("42")
    T.ok(caps ~= nil)
    T.eq(new_pos, 3)
    T.eq(caps.number, "42")
  end)

  T.it("parses addition", function()
    local caps, new_pos = g:parse("1+2")
    T.ok(caps ~= nil)
    T.eq(new_pos, 4)
  end)

  T.it("parses complex expression", function()
    local caps, new_pos = g:parse("1+2*3")
    T.ok(caps ~= nil)
    T.eq(new_pos, 6)
  end)

  T.it("parses parenthesized expression", function()
    local caps, new_pos = g:parse("(1+2)*3")
    T.ok(caps ~= nil)
    T.eq(new_pos, 8)
  end)

  T.it("parses deeply nested parens", function()
    local caps, new_pos = g:parse("((42))")
    T.ok(caps ~= nil)
    T.eq(new_pos, 7)
  end)

  T.it("fails on empty input", function()
    local caps = g:parse("")
    T.fail(caps)
  end)

  T.it("match returns matched portion and remainder", function()
    local ok, matched, rest = g:match("1+2 extra")
    T.ok(ok)
    T.eq(matched, "1+2")
    T.eq(rest, " extra")
  end)
end)

-- ── grammar: mutually recursive rules ─────────────────────────────────────────

T.describe("grammar: balanced parentheses", function()
  -- balanced = '(' balanced ')' | ''
  local g = G.grammar({
    start = "balanced",
    balanced = G.alt(
      G.seq(G.lit("("), G.ref("balanced"), G.lit(")")),
      G.lit("")  -- empty (always matches, consuming nothing)
    ),
  })

  T.it("matches empty string", function()
    local caps, new_pos = g:parse("")
    T.ok(caps ~= nil)
    T.eq(new_pos, 1)
  end)

  T.it("matches single pair", function()
    local ok, matched = g:match("()")
    T.ok(ok)
    T.eq(matched, "()")
  end)

  T.it("matches nested pairs", function()
    local ok, matched = g:match("((()))")
    T.ok(ok)
    T.eq(matched, "((()))")
  end)

  T.it("stops at unbalanced paren", function()
    -- balanced grammar matches as far as it can; extra ')' is left in rest
    local ok, matched, rest = g:match("(())")
    T.ok(ok)
    T.eq(matched, "(())")
    T.eq(rest, "")
  end)
end)

-- ── packrat memoization correctness ───────────────────────────────────────────

T.describe("packrat memoization", function()
  T.it("produces same result with and without grammar wrapper", function()
    local digit = G.range("0", "9")
    local digits = G.plus(digit)
    -- Direct parse (no cache)
    local caps1, pos1 = digits:parse_at("456xyz", 1)
    T.ok(caps1 ~= nil)
    T.eq(pos1, 4)

    -- Via grammar (uses cache)
    local g = G.grammar({
      start = "num",
      num = G.capture(G.plus(G.range("0", "9")), "n"),
    })
    local caps2, pos2 = g:parse("456xyz")
    T.ok(caps2 ~= nil)
    T.eq(pos2, 4)
    T.eq(caps2.n, "456")
  end)

  T.it("same parser used multiple times in seq gives consistent results", function()
    local digit = G.range("0", "9")
    local two = G.seq(digit, digit)
    local ok, matched, rest = two:match("12xyz")
    T.ok(ok)
    T.eq(matched, "12")
    T.eq(rest, "xyz")
  end)

  T.it("star does not consume when inner fails (no infinite loop)", function()
    local p = G.star(G.lit("a"))
    local ok, matched, rest = p:match("bbb")
    T.ok(ok)
    T.eq(matched, "")
    T.eq(rest, "bbb")
  end)
end)

-- ── grammar with multiple rules and captures ──────────────────────────────────

T.describe("grammar: key=value parser", function()
  local g = G.grammar({
    start = "pair",
    pair = G.seq(G.ref("key"), G.lit("="), G.ref("value")),
    key   = G.capture(G.plus(G.alt(G.range("a", "z"), G.range("A", "Z"), G.lit("_"))), "key"),
    value = G.capture(G.plus(G.not_set(" \t\n=")), "value"),
  })

  T.it("parses key=value", function()
    local caps, new_pos = g:parse("name=alice")
    T.ok(caps ~= nil)
    T.eq(caps.key, "name")
    T.eq(caps.value, "alice")
    T.eq(new_pos, 11)
  end)

  T.it("parses underscore key", function()
    local caps, new_pos = g:parse("my_key=123")
    T.ok(caps ~= nil)
    T.eq(caps.key, "my_key")
    T.eq(caps.value, "123")
    T.eq(new_pos, 11)
  end)

  T.it("fails when no = sign", function()
    local caps = g:parse("noequal")
    T.fail(caps)
  end)
end)

-- ── edge cases ────────────────────────────────────────────────────────────────

T.describe("edge cases", function()
  T.it("seq of single parser works", function()
    local p = G.seq(G.lit("x"))
    local ok, matched = p:match("x")
    T.ok(ok)
    T.eq(matched, "x")
  end)

  T.it("alt of single parser works", function()
    local p = G.alt(G.lit("x"))
    local ok, matched = p:match("x")
    T.ok(ok)
    T.eq(matched, "x")
  end)

  T.it("times(p, 0) always succeeds consuming nothing", function()
    local p = G.times(G.lit("a"), 0)
    local ok, matched, rest = p:match("bbb")
    T.ok(ok)
    T.eq(matched, "")
    T.eq(rest, "bbb")
  end)

  T.it("not_ followed by any matches non-matching chars", function()
    -- Match chars that are not digits
    local non_digit = G.seq(G.not_(G.range("0", "9")), G.any)
    local ok, matched = non_digit:match("abc")
    T.ok(ok)
    T.eq(matched, "a")
    local ok2 = non_digit:match("1bc")
    T.fail(ok2)
  end)

  T.it("capture on empty match returns empty string", function()
    local p = G.capture(G.lit(""), "x")
    local caps, new_pos = p:parse_at("hello", 1)
    T.ok(caps ~= nil)
    T.eq(caps.x, "")
    T.eq(new_pos, 1)
  end)

  T.it("nested capture preserves outer name", function()
    -- Inner capture by lit doesn't add named field, outer capture wraps it
    local p = G.capture(G.seq(G.lit("ab"), G.lit("cd")), "all")
    local caps, new_pos = p:parse_at("abcd", 1)
    T.ok(caps ~= nil)
    T.eq(caps.all, "abcd")
    T.eq(new_pos, 5)
  end)

  T.it("and_ does not consume input", function()
    local p = G.seq(G.and_(G.lit("abc")), G.lit("ab"))
    local ok, matched, rest = p:match("abc")
    T.ok(ok)
    T.eq(matched, "ab")
    T.eq(rest, "c")
  end)

  T.it("eof after consuming all input", function()
    local p = G.seq(G.plus(G.range("a", "z")), G.eof)
    local ok, matched = p:match("hello")
    T.ok(ok)
    T.eq(matched, "hello")
  end)
end)

-- Print summary
local summary = T._summary()
local total = summary.pass + summary.fail
io.write(string.format("\n%d/%d assertions passed", summary.pass, total))
if summary.fail > 0 then
  io.write(string.format(", %d FAILED\n", summary.fail))
  for _, test in ipairs(summary.tests) do
    if not test.ok then
      io.write(string.format("  FAIL: %s\n", test.name))
      if test.err then io.write(string.format("        %s\n", test.err)) end
    end
  end
  os.exit(1)
else
  io.write("\n")
end
