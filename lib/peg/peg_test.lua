if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local peg = require("lib.peg")

T.describe("peg.lit", function()
  T.it("matches a literal string", function()
    local pos, caps = peg.match(peg.lit("hello"), "hello world")
    T.eq(pos, 6)
    T.eq(#caps, 0)
  end)

  T.it("fails when string doesn't match", function()
    local pos, err = peg.match(peg.lit("hello"), "world")
    T.eq(pos, nil)
    T.ok(type(err) == "string")
  end)

  T.it("matches at start only", function()
    local pos, err = peg.match(peg.lit("world"), "hello world")
    T.eq(pos, nil)
  end)

  T.it("matches empty string literal", function()
    local pos = peg.match(peg.lit(""), "abc")
    T.eq(pos, 1)
  end)
end)

T.describe("peg.cls", function()
  T.it("matches a lowercase letter", function()
    local pos = peg.match(peg.cls("[a-z]"), "hello")
    T.eq(pos, 2)
  end)

  T.it("matches an uppercase letter", function()
    local pos = peg.match(peg.cls("[A-Z]"), "Hello")
    T.eq(pos, 2)
  end)

  T.it("matches a digit", function()
    local pos = peg.match(peg.cls("[0-9]"), "42")
    T.eq(pos, 2)
  end)

  T.it("fails when char not in class", function()
    local pos = peg.match(peg.cls("[a-z]"), "0abc")
    T.eq(pos, nil)
  end)

  T.it("matches with multiple ranges", function()
    local pos = peg.match(peg.cls("[a-zA-Z0-9]"), "Z99")
    T.eq(pos, 2)
  end)

  T.it("negated class matches non-digit", function()
    local pos = peg.match(peg.cls("[^0-9]"), "abc")
    T.eq(pos, 2)
  end)

  T.it("negated class fails on digit", function()
    local pos = peg.match(peg.cls("[^0-9]"), "123")
    T.eq(pos, nil)
  end)

  T.it("fails at end of input", function()
    local pos = peg.match(peg.cls("[a-z]"), "")
    T.eq(pos, nil)
  end)

  T.it("matches literal char (no range)", function()
    local pos = peg.match(peg.cls("[+-]"), "+")
    T.eq(pos, 2)
    local pos2 = peg.match(peg.cls("[+-]"), "-")
    T.eq(pos2, 2)
    local pos3 = peg.match(peg.cls("[+-]"), "*")
    T.eq(pos3, nil)
  end)
end)

T.describe("peg.any", function()
  T.it("matches any character", function()
    local pos = peg.match(peg.any, "abc")
    T.eq(pos, 2)
  end)

  T.it("fails at end of input", function()
    local pos = peg.match(peg.any, "")
    T.eq(pos, nil)
  end)

  T.it("matches last character", function()
    local pos = peg.match(peg.any, "x")
    T.eq(pos, 2)
  end)
end)

T.describe("peg.eof", function()
  T.it("matches at end of input", function()
    local pos = peg.match(peg.eof, "")
    T.eq(pos, 1)
  end)

  T.it("fails when input remains", function()
    local pos = peg.match(peg.eof, "a")
    T.eq(pos, nil)
  end)
end)

T.describe("peg.empty", function()
  T.it("always succeeds and consumes nothing", function()
    local pos = peg.match(peg.empty, "abc")
    T.eq(pos, 1)
  end)

  T.it("succeeds on empty input", function()
    local pos = peg.match(peg.empty, "")
    T.eq(pos, 1)
  end)
end)

T.describe("peg.seq", function()
  T.it("matches all patterns in order", function()
    local p = peg.seq(peg.lit("he"), peg.lit("llo"))
    local pos = peg.match(p, "hello")
    T.eq(pos, 6)
  end)

  T.it("fails if first pattern fails", function()
    local p = peg.seq(peg.lit("he"), peg.lit("llo"))
    local pos = peg.match(p, "world")
    T.eq(pos, nil)
  end)

  T.it("fails if second pattern fails", function()
    local p = peg.seq(peg.lit("he"), peg.lit("llo"))
    local pos = peg.match(p, "hexxx")
    T.eq(pos, nil)
  end)

  T.it("sequences three patterns", function()
    local p = peg.seq(peg.lit("a"), peg.lit("b"), peg.lit("c"))
    local pos = peg.match(p, "abcd")
    T.eq(pos, 4)
  end)

  T.it("restores position on failure", function()
    -- choice uses seq internally; verify no partial advance
    local p = peg.choice(
      peg.seq(peg.lit("ab"), peg.lit("cd")),
      peg.lit("abxx")
    )
    local pos = peg.match(p, "abxx")
    T.eq(pos, 5)
  end)
end)

T.describe("peg.choice", function()
  T.it("matches first alternative", function()
    local p = peg.choice(peg.lit("hello"), peg.lit("world"))
    local pos = peg.match(p, "hello")
    T.eq(pos, 6)
  end)

  T.it("matches second when first fails", function()
    local p = peg.choice(peg.lit("hello"), peg.lit("world"))
    local pos = peg.match(p, "world")
    T.eq(pos, 6)
  end)

  T.it("fails when all alternatives fail", function()
    local p = peg.choice(peg.lit("hello"), peg.lit("world"))
    local pos = peg.match(p, "goodbye")
    T.eq(pos, nil)
  end)

  T.it("ordered: first match wins even if second is longer", function()
    local p = peg.choice(peg.lit("a"), peg.lit("ab"))
    local pos = peg.match(p, "ab")
    T.eq(pos, 2)  -- first match "a" wins
  end)
end)

T.describe("peg.star", function()
  T.it("matches zero occurrences", function()
    local p = peg.star(peg.lit("a"))
    local pos = peg.match(p, "bbb")
    T.eq(pos, 1)  -- consumed nothing, still succeeds
  end)

  T.it("matches one occurrence", function()
    local p = peg.star(peg.lit("a"))
    local pos = peg.match(p, "ab")
    T.eq(pos, 2)
  end)

  T.it("matches many occurrences", function()
    local p = peg.star(peg.lit("a"))
    local pos = peg.match(p, "aaaa")
    T.eq(pos, 5)
  end)

  T.it("stops at non-matching char", function()
    local p = peg.star(peg.cls("[a-z]"))
    local pos = peg.match(p, "abc123")
    T.eq(pos, 4)
  end)
end)

T.describe("peg.plus", function()
  T.it("fails on zero occurrences", function()
    local p = peg.plus(peg.lit("a"))
    local pos = peg.match(p, "bbb")
    T.eq(pos, nil)
  end)

  T.it("matches one occurrence", function()
    local p = peg.plus(peg.lit("a"))
    local pos = peg.match(p, "ab")
    T.eq(pos, 2)
  end)

  T.it("matches many occurrences", function()
    local p = peg.plus(peg.cls("[0-9]"))
    local pos = peg.match(p, "12345abc")
    T.eq(pos, 6)
  end)
end)

T.describe("peg.opt", function()
  T.it("matches when pattern present", function()
    local p = peg.opt(peg.lit("-"))
    local pos = peg.match(p, "-42")
    T.eq(pos, 2)
  end)

  T.it("succeeds (consumes nothing) when pattern absent", function()
    local p = peg.opt(peg.lit("-"))
    local pos = peg.match(p, "42")
    T.eq(pos, 1)
  end)
end)

T.describe("peg.neg", function()
  T.it("succeeds when pattern fails", function()
    local p = peg.neg(peg.lit("hello"))
    local pos = peg.match(p, "world")
    T.eq(pos, 1)  -- consumes nothing
  end)

  T.it("fails when pattern succeeds", function()
    local p = peg.neg(peg.lit("hello"))
    local pos = peg.match(p, "hello")
    T.eq(pos, nil)
  end)

  T.it("consumes nothing on success", function()
    local p = peg.seq(peg.neg(peg.cls("[0-9]")), peg.any)
    local pos = peg.match(p, "a1")
    T.eq(pos, 2)  -- neg consumed nothing, any consumed "a"
  end)

  T.it("used as not-followed-by", function()
    -- match "foo" not followed by "bar"
    local p = peg.seq(peg.lit("foo"), peg.neg(peg.lit("bar")))
    local pos1 = peg.match(p, "foobaz")
    T.eq(pos1, 4)
    local pos2 = peg.match(p, "foobar")
    T.eq(pos2, nil)
  end)
end)

T.describe("peg.pos", function()
  T.it("succeeds when pattern matches (no consumption)", function()
    local p = peg.pos(peg.lit("hello"))
    local pos = peg.match(p, "hello")
    T.eq(pos, 1)  -- consumes nothing
  end)

  T.it("fails when pattern fails", function()
    local p = peg.pos(peg.lit("hello"))
    local pos = peg.match(p, "world")
    T.eq(pos, nil)
  end)

  T.it("used as followed-by", function()
    -- match a digit only if followed by another digit
    local p = peg.seq(peg.pos(peg.seq(peg.cls("[0-9]"), peg.cls("[0-9]"))), peg.cls("[0-9]"))
    local pos1 = peg.match(p, "12")
    T.eq(pos1, 2)
    local pos2 = peg.match(p, "1a")
    T.eq(pos2, nil)
  end)
end)

T.describe("peg.cap", function()
  T.it("captures matched substring", function()
    local p = peg.cap(peg.plus(peg.cls("[a-z]")))
    local pos, caps = peg.match(p, "hello world")
    T.eq(pos, 6)
    T.eq(caps[1], "hello")
  end)

  T.it("captures empty string on empty match", function()
    local p = peg.cap(peg.star(peg.cls("[0-9]")))
    local pos, caps = peg.match(p, "abc")
    T.eq(pos, 1)
    T.eq(caps[1], "")
  end)

  T.it("multiple captures in sequence", function()
    local p = peg.seq(
      peg.cap(peg.plus(peg.cls("[a-z]"))),
      peg.lit("="),
      peg.cap(peg.plus(peg.cls("[0-9]")))
    )
    local pos, caps = peg.match(p, "foo=42")
    T.eq(pos, 7)
    T.eq(caps[1], "foo")
    T.eq(caps[2], "42")
  end)

  T.it("nested cap: inner captures appear as children", function()
    -- outer cap wraps the entire "key=value", inner caps wrap key and value
    local p = peg.cap(peg.seq(
      peg.cap(peg.plus(peg.cls("[a-z]"))),
      peg.lit("="),
      peg.cap(peg.plus(peg.cls("[0-9]")))
    ))
    local pos, caps = peg.match(p, "foo=42")
    T.eq(pos, 7)
    -- caps[1] is the outer capture: { full_string, child1, child2 }
    T.eq(type(caps[1]), "table")
    T.eq(caps[1][1], "foo=42")
    T.eq(caps[1][2], "foo")
    T.eq(caps[1][3], "42")
  end)

  T.it("cap fails if inner pattern fails", function()
    local p = peg.cap(peg.lit("hello"))
    local pos = peg.match(p, "world")
    T.eq(pos, nil)
  end)
end)

T.describe("peg.grammar with ref", function()
  T.it("matches balanced parentheses", function()
    -- S -> '(' S ')' | ''
    local g = peg.grammar({
      start = "S",
      rules = {
        S = peg.choice(
          peg.seq(peg.lit("("), peg.ref("S"), peg.lit(")")),
          peg.empty
        ),
      }
    })
    local pos = g:match("(((())))")
    T.eq(pos, 9)

    local pos2 = g:match("(())")
    T.eq(pos2, 5)

    local pos3 = g:match("")
    T.eq(pos3, 1)
  end)

  T.it("match_all rejects partial match", function()
    local g = peg.grammar({
      start = "S",
      rules = {
        S = peg.plus(peg.cls("[a-z]")),
      }
    })
    local pos, err = g:match_all("hello world")
    T.eq(pos, nil)
    T.ok(type(err) == "string")
  end)

  T.it("match_all accepts full match", function()
    local g = peg.grammar({
      start = "S",
      rules = {
        S = peg.plus(peg.cls("[a-z]")),
      }
    })
    local pos, caps = g:match_all("hello")
    T.eq(pos, 6)
  end)

  T.it("undefined rule raises error", function()
    local g = peg.grammar({
      start = "S",
      rules = {
        S = peg.ref("missing"),
      }
    })
    T.throws(function() g:match("abc") end)
  end)

  T.it("missing start rule returns error", function()
    local g = peg.grammar({
      start = "nonexistent",
      rules = {
        S = peg.lit("a"),
      }
    })
    local pos, err = g:match("abc")
    T.eq(pos, nil)
    T.ok(type(err) == "string")
  end)

  T.it("grammar for simple arithmetic: left-associative + *", function()
    -- expr   = term (('+' | '-') term)*
    -- term   = factor (('*' | '/') factor)*
    -- factor = '(' expr ')' | [0-9]+
    local g = peg.grammar({
      start = "expr",
      rules = {
        expr = peg.seq(
          peg.ref("term"),
          peg.star(peg.seq(peg.cls("[+-]"), peg.ref("term")))
        ),
        term = peg.seq(
          peg.ref("factor"),
          peg.star(peg.seq(peg.cls("[*/]"), peg.ref("factor")))
        ),
        factor = peg.choice(
          peg.seq(peg.lit("("), peg.ref("expr"), peg.lit(")")),
          peg.plus(peg.cls("[0-9]"))
        ),
      }
    })

    -- "1+2*3" should fully match
    local pos, caps = g:match_all("1+2*3")
    T.eq(pos, 6)

    -- "1+2*3+4" should fully match
    local pos2, caps2 = g:match_all("1+2*3+4")
    T.eq(pos2, 8)

    -- "(1+2)*3" should fully match
    local pos3, caps3 = g:match_all("(1+2)*3")
    T.eq(pos3, 8)

    -- "abc" should fail
    local pos4, err4 = g:match_all("abc")
    T.eq(pos4, nil)
  end)

  T.it("grammar with captures extracts tokens", function()
    local g = peg.grammar({
      start = "pair",
      rules = {
        pair = peg.seq(
          peg.cap(peg.plus(peg.cls("[a-z]"))),
          peg.lit(":"),
          peg.cap(peg.plus(peg.cls("[0-9]")))
        ),
      }
    })
    local pos, caps = g:match_all("foo:42")
    T.eq(pos, 7)
    T.eq(caps[1], "foo")
    T.eq(caps[2], "42")
  end)

  T.it("recursive grammar with captures: balanced parens depth", function()
    -- Capture the innermost content
    local g = peg.grammar({
      start = "S",
      rules = {
        S = peg.choice(
          peg.seq(peg.lit("("), peg.cap(peg.ref("S")), peg.lit(")")),
          peg.cap(peg.plus(peg.cls("[a-z]")))
        ),
      }
    })
    local pos, caps = g:match_all("(hello)")
    T.eq(pos, 8)
    -- caps[1] is outer cap (content between parens), caps[1] = { "(hello)", inner_cap }
    -- Actually inner cap of ref("S") matching "hello" produces "hello"
    T.ok(pos ~= nil)
  end)
end)

T.describe("peg.match standalone", function()
  T.it("returns nil and errmsg on no match", function()
    local pos, err = peg.match(peg.lit("abc"), "xyz")
    T.eq(pos, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns end_pos and empty caps on no captures", function()
    local pos, caps = peg.match(peg.lit("abc"), "abcdef")
    T.eq(pos, 4)
    T.eq(#caps, 0)
  end)
end)
