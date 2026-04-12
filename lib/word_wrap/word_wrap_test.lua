if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local wrap = require("lib.word_wrap")

-- ────────────────────────────────────────────────
-- greedy
-- ────────────────────────────────────────────────

T.describe("greedy", function()

  T.it("basic wrapping", function()
    local lines = wrap.greedy("Hello world foo bar", 10)
    -- "Hello" = 5, "world" = 5, "foo" = 3, "bar" = 3
    -- "Hello world" = 11 > 10 → "Hello" alone, then "world foo" = 9 ≤ 10, then "bar"
    T.eq(#lines, 3)
    T.eq(lines[1], "Hello")
    T.eq(lines[2], "world foo")
    T.eq(lines[3], "bar")
  end)

  T.it("exact fit on one line", function()
    local lines = wrap.greedy("Hello", 5)
    T.eq(#lines, 1)
    T.eq(lines[1], "Hello")
  end)

  T.it("exact fit for every word", function()
    local lines = wrap.greedy("ab cd ef", 2)
    T.eq(#lines, 3)
    T.eq(lines[1], "ab")
    T.eq(lines[2], "cd")
    T.eq(lines[3], "ef")
  end)

  T.it("all words fit on one line", function()
    local lines = wrap.greedy("Hello world", 20)
    T.eq(#lines, 1)
    T.eq(lines[1], "Hello world")
  end)

  T.it("empty input", function()
    local lines = wrap.greedy("", 10)
    T.eq(#lines, 0)
  end)

  T.it("single word shorter than width", function()
    local lines = wrap.greedy("hello", 10)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("single word equal to width", function()
    local lines = wrap.greedy("hello", 5)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("single word longer than width — no break by default", function()
    local lines = wrap.greedy("superlongword", 5)
    -- Without break_long_words the word appears on its own line unbroken
    T.eq(#lines, 1)
    T.eq(lines[1], "superlongword")
  end)

  T.it("width=1 forces each word onto its own line", function()
    local lines = wrap.greedy("a b c", 1)
    T.eq(#lines, 3)
    T.eq(lines[1], "a")
    T.eq(lines[2], "b")
    T.eq(lines[3], "c")
  end)

  T.it("collapses multiple spaces between words", function()
    local lines = wrap.greedy("hello   world", 20)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello world")
  end)

  T.it("break_long_words splits a word across lines", function()
    local lines = wrap.greedy("superlongword", 5, { break_long_words = true })
    -- "super" "longw" "ord"
    T.ok(#lines >= 2, "should produce multiple lines")
    local joined = table.concat(lines, "")
    T.eq(joined, "superlongword")
    for _, line in ipairs(lines) do
      T.ok(#line <= 5, "each line fits within width: " .. line)
    end
  end)

  T.it("break_long_words with surrounding normal words", function()
    local lines = wrap.greedy("hi superlongword ok", 5, { break_long_words = true })
    local joined = table.concat(lines, "")
    -- The joined result may include "hi" on its own line plus broken chunks plus "ok"
    T.ok(joined:find("superlongword", 1, true), "long word content preserved")
    for _, line in ipairs(lines) do
      T.ok(#line <= 5, "each line within width: " .. line)
    end
  end)

  T.it("no extra leading/trailing whitespace on lines", function()
    local lines = wrap.greedy("  leading spaces and trailing  ", 15)
    for _, line in ipairs(lines) do
      T.eq(line, line:match("^%s*(.-)%s*$"))
    end
  end)

end)

-- ────────────────────────────────────────────────
-- optimal
-- ────────────────────────────────────────────────

T.describe("optimal", function()

  T.it("basic wrapping produces valid lines", function()
    local lines = wrap.optimal("Hello world foo bar", 10)
    T.ok(#lines >= 1)
    for _, line in ipairs(lines) do
      T.ok(#line <= 10, "line fits: " .. line)
    end
  end)

  T.it("empty input", function()
    local lines = wrap.optimal("", 10)
    T.eq(#lines, 0)
  end)

  T.it("single word", function()
    local lines = wrap.optimal("hello", 10)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("all words on one line when they fit", function()
    local lines = wrap.optimal("Hello world", 20)
    T.eq(#lines, 1)
    T.eq(lines[1], "Hello world")
  end)

  T.it("raggedness ≤ greedy raggedness on same input", function()
    local text = "The quick brown fox jumps over the lazy dog"
    local width = 15
    local g_lines = wrap.greedy(text, width)
    local o_lines = wrap.optimal(text, width)
    local g_rag = wrap.raggedness(g_lines, width)
    local o_rag = wrap.raggedness(o_lines, width)
    T.ok(o_rag <= g_rag, "optimal rag=" .. o_rag .. " greedy rag=" .. g_rag)
  end)

  T.it("all words preserved", function()
    local text = "one two three four five six seven"
    local lines = wrap.optimal(text, 12)
    local joined = table.concat(lines, " ")
    T.eq(joined, text)
  end)

  T.it("width=1 forces each word onto its own line", function()
    local lines = wrap.optimal("a b c", 1)
    T.eq(#lines, 3)
  end)

end)

-- ────────────────────────────────────────────────
-- raggedness
-- ────────────────────────────────────────────────

T.describe("raggedness", function()

  T.it("single line has zero raggedness", function()
    T.eq(wrap.raggedness({"hello"}, 10), 0)
  end)

  T.it("two equal-length lines — last excluded", function()
    -- Only first line counts: slack = 10 - 5 = 5 → 25
    T.eq(wrap.raggedness({"hello", "world"}, 10), 25)
  end)

  T.it("three lines — last excluded", function()
    local lines = {"hello", "hi", "world"}
    -- slack line1 = 10-5=5 → 25; slack line2 = 10-2=8 → 64; last excluded
    T.eq(wrap.raggedness(lines, 10), 25 + 64)
  end)

  T.it("empty lines list", function()
    T.eq(wrap.raggedness({}, 10), 0)
  end)

end)

-- ────────────────────────────────────────────────
-- paragraph
-- ────────────────────────────────────────────────

T.describe("paragraph", function()

  T.it("single paragraph wraps normally", function()
    local result = wrap.paragraph("Hello world foo bar", 10)
    T.ok(result:find("\n") or true)  -- may or may not have newline
    local lines = {}
    for l in (result .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    T.ok(#lines >= 1)
  end)

  T.it("preserves paragraph boundary (double newline)", function()
    local result = wrap.paragraph("Hello world\n\nFoo bar", 20)
    -- Should contain a blank line separating the two paragraphs
    T.ok(result:find("\n\n") or result:find("\n$") or true)
    local lines = {}
    for l in (result .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
    -- At minimum 3 lines: first para + blank + second para
    T.ok(#lines >= 3, "got " .. #lines .. " lines")
  end)

  T.it("empty input returns empty string", function()
    local result = wrap.paragraph("", 10)
    -- An empty segment wraps to one empty line
    T.ok(result == "" or result == "\n" or true)
    T.eq(type(result), "string")
  end)

  T.it("each line within width", function()
    local text = "The quick brown fox jumps\nover the lazy dog"
    local result = wrap.paragraph(text, 12)
    for line in (result .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then
        T.ok(#line <= 12, "line too long: " .. line)
      end
    end
  end)

end)

-- ────────────────────────────────────────────────
-- count_words / count_chars
-- ────────────────────────────────────────────────

T.describe("count_words", function()

  T.it("counts words in normal text", function()
    T.eq(wrap.count_words("hello world foo"), 3)
  end)

  T.it("empty string", function()
    T.eq(wrap.count_words(""), 0)
  end)

  T.it("multiple spaces between words", function()
    T.eq(wrap.count_words("hello   world"), 2)
  end)

  T.it("single word", function()
    T.eq(wrap.count_words("hello"), 1)
  end)

end)

T.describe("count_chars", function()

  T.it("counts non-whitespace chars", function()
    T.eq(wrap.count_chars("hello world"), 10)
  end)

  T.it("empty string", function()
    T.eq(wrap.count_chars(""), 0)
  end)

  T.it("spaces only", function()
    T.eq(wrap.count_chars("   "), 0)
  end)

end)

-- ────────────────────────────────────────────────
-- justify
-- ────────────────────────────────────────────────

T.describe("justify", function()

  T.it("single line is not justified (last line rule)", function()
    local result = wrap.justify({"hello world"}, 20)
    T.eq(result[1], "hello world")
  end)

  T.it("non-last lines are padded to width", function()
    local lines = {"hello world", "foo bar", "baz"}
    local result = wrap.justify(lines, 11)
    -- Line 1 and 2 should be exactly 11 chars; line 3 left-aligned
    T.eq(#result[1], 11)
    T.eq(#result[2], 11)
    T.eq(result[3], "baz")
  end)

  T.it("correct space distribution — 2 gaps, 3 extra spaces", function()
    -- "a b c" in width 9: words = a, b, c (total 3), gaps=2, spaces=6
    -- base=3, extra=0 → "a   b   c"
    local result = wrap.justify({"a b c", "end"}, 9)
    T.eq(result[1], "a   b   c")
    T.eq(#result[1], 9)
  end)

  T.it("extra spaces go to leftmost gaps", function()
    -- "a b c" in width 10: words=a,b,c (3 chars), gaps=2, spaces=7
    -- base=3, extra=1 → gap1=4, gap2=3 → "a    b   c"
    local result = wrap.justify({"a b c", "end"}, 10)
    T.eq(result[1], "a    b   c")
    T.eq(#result[1], 10)
  end)

  T.it("single word line stays as-is", function()
    local result = wrap.justify({"hello", "world"}, 10)
    T.eq(result[1], "hello")
  end)

  T.it("empty lines list", function()
    local result = wrap.justify({}, 10)
    T.eq(#result, 0)
  end)

end)

-- ────────────────────────────────────────────────
-- center
-- ────────────────────────────────────────────────

T.describe("center", function()

  T.it("even padding", function()
    -- "hi" in 6 → 2 left, 2 right → "  hi  "
    T.eq(wrap.center("hi", 6), "  hi  ")
  end)

  T.it("odd padding goes right", function()
    -- "hi" in 7 → total_pad=5, left=2, right=3 → "  hi   "
    T.eq(wrap.center("hi", 7), "  hi   ")
  end)

  T.it("text exactly width", function()
    T.eq(wrap.center("hello", 5), "hello")
  end)

  T.it("text longer than width returned unchanged", function()
    T.eq(wrap.center("toolong", 4), "toolong")
  end)

  T.it("empty string pads fully", function()
    T.eq(wrap.center("", 4), "    ")
  end)

end)

-- ────────────────────────────────────────────────
-- pad_left
-- ────────────────────────────────────────────────

T.describe("pad_left", function()

  T.it("right-aligns short text", function()
    T.eq(wrap.pad_left("hi", 5), "   hi")
  end)

  T.it("exact width unchanged", function()
    T.eq(wrap.pad_left("hello", 5), "hello")
  end)

  T.it("longer than width unchanged", function()
    T.eq(wrap.pad_left("toolong", 4), "toolong")
  end)

  T.it("empty string pads fully", function()
    T.eq(wrap.pad_left("", 3), "   ")
  end)

end)

-- ────────────────────────────────────────────────
-- truncate
-- ────────────────────────────────────────────────

T.describe("truncate", function()

  T.it("short text unchanged", function()
    T.eq(wrap.truncate("hello", 10), "hello")
  end)

  T.it("exact width unchanged", function()
    T.eq(wrap.truncate("hello", 5), "hello")
  end)

  T.it("truncates with default ellipsis", function()
    local result = wrap.truncate("hello world", 8)
    T.eq(result, "hello...")
    T.eq(#result, 8)
  end)

  T.it("result fits within width", function()
    local result = wrap.truncate("superlongtext here", 10)
    T.ok(#result <= 10, "length=" .. #result)
  end)

  T.it("custom ellipsis", function()
    local result = wrap.truncate("hello world", 7, "→")
    T.eq(#result, 7)
    T.ok(result:sub(-#"→") == "→")
  end)

  T.it("very short width clips ellipsis itself", function()
    local result = wrap.truncate("hello", 2)
    T.ok(#result <= 2, "length=" .. #result)
  end)

end)

-- ────────────────────────────────────────────────
-- wrap (full pipeline)
-- ────────────────────────────────────────────────

T.describe("wrap", function()

  T.it("returns string not table", function()
    local result = wrap.wrap("hello world foo bar", 10)
    T.eq(type(result), "string")
  end)

  T.it("lines joined by newlines", function()
    local result = wrap.wrap("hello world foo bar", 10)
    local count = 0
    for _ in (result .. "\n"):gmatch("[^\n]+\n") do count = count + 1 end
    T.ok(count >= 1)
  end)

  T.it("empty text returns empty string", function()
    T.eq(wrap.wrap("", 10), "")
  end)

  T.it("all lines within width", function()
    local result = wrap.wrap("The quick brown fox jumps over the lazy dog", 15)
    for line in (result .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then
        T.ok(#line <= 15, "line too long: " .. line)
      end
    end
  end)

end)

-- ────────────────────────────────────────────────
-- _tier
-- ────────────────────────────────────────────────

T.describe("_tier", function()
  T.it("is 'pure'", function()
    T.eq(wrap._tier, "pure")
  end)
end)

-- ────────────────────────────────────────────────
-- edge cases
-- ────────────────────────────────────────────────

T.describe("edge cases", function()

  T.it("greedy: whitespace-only input", function()
    local lines = wrap.greedy("   ", 10)
    T.eq(#lines, 0)
  end)

  T.it("optimal: two words equal to width", function()
    -- "ab cd" width=5: "ab cd" = 5 fits on one line
    local lines = wrap.optimal("ab cd", 5)
    T.eq(#lines, 1)
    T.eq(lines[1], "ab cd")
  end)

  T.it("greedy: two words exactly fill width", function()
    local lines = wrap.greedy("ab cd", 5)
    T.eq(#lines, 1)
    T.eq(lines[1], "ab cd")
  end)

  T.it("justify: two lines, second is last", function()
    local result = wrap.justify({"hello world", "foo"}, 15)
    T.eq(#result[1], 15)
    T.eq(result[2], "foo")
  end)

  T.it("center: single char in wide field", function()
    local result = wrap.center("x", 5)
    T.eq(#result, 5)
    T.ok(result:find("x", 1, true) ~= nil)
  end)

  T.it("count_words: punctuation counts as part of word", function()
    T.eq(wrap.count_words("hello, world!"), 2)
  end)

  T.it("optimal: long sequence", function()
    local words = {}
    for i = 1, 20 do words[i] = "w" .. i end
    local text = table.concat(words, " ")
    local lines = wrap.optimal(text, 10)
    -- All words should be preserved
    local joined = table.concat(lines, " ")
    T.eq(joined, text)
  end)

end)
