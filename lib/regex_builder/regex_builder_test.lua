-- lib/regex_builder/regex_builder_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local rb = require("lib.regex_builder")

T.describe("regex_builder elements", function()
  T.it("digit produces %d", function()
    T.eq(rb.digit(), "%d")
  end)

  T.it("alpha produces %a", function()
    T.eq(rb.alpha(), "%a")
  end)

  T.it("whitespace produces %s", function()
    T.eq(rb.whitespace(), "%s")
  end)

  T.it("alphanumeric produces %w", function()
    T.eq(rb.alphanumeric(), "%w")
  end)

  T.it("lower produces %l", function()
    T.eq(rb.lower(), "%l")
  end)

  T.it("upper produces %u", function()
    T.eq(rb.upper(), "%u")
  end)

  T.it("punctuation produces %p", function()
    T.eq(rb.punctuation(), "%p")
  end)

  T.it("any produces .", function()
    T.eq(rb.any(), ".")
  end)
end)

T.describe("regex_builder literal escaping", function()
  T.it("escapes dot", function()
    T.eq(rb.literal("."), "%.")
  end)

  T.it("escapes caret", function()
    T.eq(rb.literal("^"), "%^")
  end)

  T.it("escapes dollar", function()
    T.eq(rb.literal("$"), "%$")
  end)

  T.it("escapes parens", function()
    T.eq(rb.literal("(x)"), "%(x%)")
  end)

  T.it("escapes plus star", function()
    T.eq(rb.literal("+*"), "%+%*")
  end)

  T.it("plain text unchanged", function()
    T.eq(rb.literal("hello"), "hello")
  end)
end)

T.describe("regex_builder quantifiers", function()
  T.it("zero_or_more appends *", function()
    T.eq(rb.zero_or_more_of(rb.digit()), "%d*")
  end)

  T.it("one_or_more appends +", function()
    T.eq(rb.one_or_more_of(rb.alpha()), "%a+")
  end)

  T.it("maybe_of appends ?", function()
    T.eq(rb.maybe_of(rb.whitespace()), "%s?")
  end)
end)

T.describe("regex_builder builder methods", function()
  T.it("digit() method appends %d", function()
    local b = rb.new():digit()
    T.eq(b:build(), "%d")
  end)

  T.it("one_or_more on builder", function()
    local b = rb.new():one_or_more(rb.digit())
    T.eq(b:build(), "%d+")
  end)

  T.it("zero_or_more on builder", function()
    local b = rb.new():zero_or_more(rb.alpha())
    T.eq(b:build(), "%a*")
  end)

  T.it("maybe on builder", function()
    local b = rb.new():maybe(rb.whitespace())
    T.eq(b:build(), "%s?")
  end)

  T.it("exactly expands to n copies", function()
    local b = rb.new():exactly(3, rb.digit())
    T.eq(b:build(), "%d%d%d")
  end)

  T.it("exactly 1", function()
    local b = rb.new():exactly(1, rb.alpha())
    T.eq(b:build(), "%a")
  end)

  T.it("capture wraps in parens", function()
    local b = rb.new():capture(rb.digit())
    T.eq(b:build(), "(%d)")
  end)

  T.it("capture with one_or_more", function()
    local b = rb.new():capture(rb.one_or_more_of(rb.alpha()))
    T.eq(b:build(), "(%a+)")
  end)

  T.it("start anchor", function()
    local b = rb.new():start():digit()
    T.eq(b:build(), "^%d")
  end)

  T.it("finish anchor", function()
    local b = rb.new():digit():finish()
    T.eq(b:build(), "%d$")
  end)

  T.it("start and finish anchors", function()
    local b = rb.new():start():one_or_more(rb.digit()):finish()
    T.eq(b:build(), "^%d+$")
  end)

  T.it("literal on builder", function()
    local b = rb.new():literal(".")
    T.eq(b:build(), "%.")
  end)

  T.it("chained pattern: digits dot digits", function()
    local b = rb.new()
      :start()
      :one_or_more(rb.digit())
      :literal(".")
      :one_or_more(rb.digit())
      :finish()
    T.eq(b:build(), "^%d+%.%d+$")
  end)

  T.it("char_class", function()
    local b = rb.new():char_class("[aeiou]")
    T.eq(b:build(), "[aeiou]")
  end)

  T.it("not_class from bracketed string", function()
    local b = rb.new():not_class("[aeiou]")
    T.eq(b:build(), "[^aeiou]")
  end)
end)

T.describe("regex_builder match/gmatch/gsub", function()
  T.it("match returns matched string", function()
    local b = rb.new():maybe(rb.literal("-")):one_or_more(rb.digit())
    T.eq(b:match("-123"), "-123")
  end)

  T.it("match returns nil on no match", function()
    local b = rb.new():start():one_or_more(rb.digit()):finish()
    T.eq(b:match("abc"), nil)
  end)

  T.it("gsub replaces matches", function()
    local b = rb.new():one_or_more(rb.digit())
    local result, count = b:gsub("foo123bar456", "NUM")
    T.eq(result, "fooNUMbarNUM")
    T.eq(count, 2)
  end)

  T.it("gmatch iterates matches", function()
    local b = rb.new():one_or_more(rb.digit())
    local matches = {}
    for m in b:gmatch("a1b22c333") do
      matches[#matches + 1] = m
    end
    T.eq(#matches, 3)
    T.eq(matches[1], "1")
    T.eq(matches[2], "22")
    T.eq(matches[3], "333")
  end)
end)

T.describe("regex_builder prebuilt patterns", function()
  T.it("integer matches -123", function()
    T.ok(rb.test(rb.patterns.integer, "-123"))
  end)

  T.it("integer matches 0", function()
    T.ok(rb.test(rb.patterns.integer, "0"))
  end)

  T.it("float matches 3.14", function()
    T.ok(rb.test(rb.patterns.float, "3.14"))
  end)

  T.it("float matches -0.5", function()
    T.ok(rb.test(rb.patterns.float, "-0.5"))
  end)

  T.it("word matches letters", function()
    T.eq(rb.extract(rb.patterns.word, "hello world"), "hello")
  end)

  T.it("email matches basic email", function()
    T.ok(rb.test(rb.patterns.email, "user@example.com"))
  end)

  T.it("ipv4 matches 192.168.1.1", function()
    T.ok(rb.test(rb.patterns.ipv4, "192.168.1.1"))
  end)

  T.it("hex_color matches #ff0000", function()
    T.ok(rb.test(rb.patterns.hex_color, "#ff0000"))
  end)

  T.it("hex_color matches #RGB shortform", function()
    T.ok(rb.test(rb.patterns.hex_color, "#abc"))
  end)

  T.it("date_iso matches 2024-01-15", function()
    T.ok(rb.test(rb.patterns.date_iso, "2024-01-15"))
  end)

  T.it("time_24 matches 13:45:00", function()
    T.ok(rb.test(rb.patterns.time_24, "13:45:00"))
  end)

  T.it("url matches http URL", function()
    T.ok(rb.test(rb.patterns.url, "https://example.com/path?q=1"))
  end)

  T.it("identifier matches Lua identifier", function()
    T.ok(rb.test(rb.patterns.identifier, "_myVar123"))
  end)
end)

T.describe("regex_builder utility functions", function()
  T.it("test returns true on match", function()
    T.ok(rb.test("%d+", "abc123"))
  end)

  T.it("test returns false on no match", function()
    T.ok(not rb.test("^%d+$", "abc"))
  end)

  T.it("extract returns first match", function()
    T.eq(rb.extract("%d+", "foo42bar"), "42")
  end)

  T.it("extract returns nil on no match", function()
    T.eq(rb.extract("%d+", "nope"), nil)
  end)

  T.it("extract_all returns all matches", function()
    local all = rb.extract_all("%d+", "a1b22c333")
    T.eq(#all, 3)
    T.eq(all[1], "1")
    T.eq(all[2], "22")
    T.eq(all[3], "333")
  end)

  T.it("extract_all returns empty table when no match", function()
    local all = rb.extract_all("%d+", "nope")
    T.eq(#all, 0)
  end)

  T.it("replace substitutes matches", function()
    local result = rb.replace("%d+", "a1b22c333", "N")
    T.eq(result, "aNbNcN")
  end)

  T.it("named returns the same as patterns field", function()
    T.eq(rb.named("integer"), rb.patterns.integer)
  end)
end)

T.describe("regex_builder complex patterns", function()
  T.it("integer = word capture", function()
    local pat = rb.new()
      :capture(rb.one_or_more_of(rb.digit()))
      :literal("=")
      :capture(rb.one_or_more_of(rb.alpha()))
      :build()
    T.eq(pat, "(%d+)=(%a+)")
    local num, word = string.match("42=hello", pat)
    T.eq(num, "42")
    T.eq(word, "hello")
  end)

  T.it("sequence builder", function()
    local b = rb.sequence(
      rb.start_anchor,
      rb.one_or_more_of(rb.digit()),
      rb.end_anchor
    )
    T.eq(b:build(), "^%d+$")
  end)

  T.it("optional minus then digits", function()
    local b = rb.new()
      :maybe(rb.literal("-"))
      :one_or_more(rb.digit())
    T.eq(b:match("-99"), "-99")
    T.eq(b:match("42"),  "42")
  end)
end)
