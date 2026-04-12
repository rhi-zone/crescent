-- lib/text_justify/text_justify_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local J = require("lib.text_justify")

-- ── wrap ──────────────────────────────────────────────────────────────────────

T.describe("wrap: basic", function()
  T.it("short text that fits in one line", function()
    local lines = J.wrap("hello", 20)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("text that exactly fits in one line", function()
    local lines = J.wrap("hello world", 11)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello world")
  end)

  T.it("multi-line wrapping — classic example", function()
    local lines = J.wrap("The quick brown fox jumps over the lazy dog", 20)
    T.eq(lines[1], "The quick brown fox")
    T.eq(lines[2], "jumps over the lazy")
    T.eq(lines[3], "dog")
  end)

  T.it("empty string returns single empty line", function()
    local lines = J.wrap("", 20)
    T.eq(#lines, 1)
    T.eq(lines[1], "")
  end)

  T.it("single word shorter than width", function()
    local lines = J.wrap("hello", 10)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("single word equal to width", function()
    local lines = J.wrap("hello", 5)
    T.eq(#lines, 1)
    T.eq(lines[1], "hello")
  end)

  T.it("long word without break_long — kept whole on its own line", function()
    local lines = J.wrap("superlongword short", 5, {break_long = false})
    T.eq(lines[1], "superlongword")
    T.eq(lines[2], "short")
  end)

  T.it("collapses leading/trailing whitespace", function()
    local lines = J.wrap("  hello   world  ", 20)
    T.eq(lines[1], "hello world")
  end)
end)

T.describe("wrap: break_long=true", function()
  T.it("word longer than width gets broken into chunks", function()
    local lines = J.wrap("abcdefghij", 4, {break_long = true})
    T.eq(lines[1], "abcd")
    T.eq(lines[2], "efgh")
    T.eq(lines[3], "ij")
  end)

  T.it("break_long is true by default", function()
    local lines = J.wrap("abcdefghij", 4)
    T.eq(lines[1], "abcd")
    T.eq(lines[2], "efgh")
    T.eq(lines[3], "ij")
  end)

  T.it("long word followed by short word", function()
    local lines = J.wrap("abcdefghij hi", 4)
    T.eq(lines[1], "abcd")
    T.eq(lines[2], "efgh")
    T.eq(lines[3], "ij")
    T.eq(lines[4], "hi")
  end)

  T.it("word exactly width does not break", function()
    local lines = J.wrap("abcd", 4)
    T.eq(#lines, 1)
    T.eq(lines[1], "abcd")
  end)
end)

-- ── left ─────────────────────────────────────────────────────────────────────

T.describe("left", function()
  T.it("pads shorter text with spaces on right", function()
    T.eq(J.left("hi", 5), "hi   ")
  end)

  T.it("text equal to width: no change", function()
    T.eq(J.left("hello", 5), "hello")
  end)

  T.it("text longer than width: truncates", function()
    T.eq(J.left("hello world", 5), "hello")
  end)

  T.it("empty string: all spaces", function()
    T.eq(J.left("", 4), "    ")
  end)
end)

-- ── right ────────────────────────────────────────────────────────────────────

T.describe("right", function()
  T.it("pads shorter text with spaces on left", function()
    T.eq(J.right("hi", 5), "   hi")
  end)

  T.it("text equal to width: no change", function()
    T.eq(J.right("hello", 5), "hello")
  end)

  T.it("text longer than width: truncates", function()
    T.eq(J.right("hello world", 5), "hello")
  end)

  T.it("empty string: all spaces", function()
    T.eq(J.right("", 4), "    ")
  end)
end)

-- ── center ───────────────────────────────────────────────────────────────────

T.describe("center", function()
  T.it("even padding split evenly", function()
    T.eq(J.center("hi", 6), "  hi  ")
  end)

  T.it("odd padding: extra space goes right", function()
    T.eq(J.center("hi", 5), " hi  ")
  end)

  T.it("text equal to width: no change", function()
    T.eq(J.center("hello", 5), "hello")
  end)

  T.it("text longer than width: truncates", function()
    T.eq(J.center("hello world", 5), "hello")
  end)

  T.it("empty string: all spaces", function()
    T.eq(J.center("", 4), "    ")
  end)
end)

-- ── justify ──────────────────────────────────────────────────────────────────

T.describe("justify", function()
  T.it("single word: left-aligns (no gaps to spread)", function()
    T.eq(J.justify("hello", 10), "hello     ")
  end)

  T.it("two words: fills gap between them", function()
    -- 15 - 5 - 5 = 5 spaces between
    T.eq(J.justify("hello world", 15), "hello" .. string.rep(" ", 5) .. "world")
  end)

  T.it("many words: distributes spaces evenly", function()
    -- "a b c" width 9: words={"a","b","c"} words_len=3, gaps=2, spaces=6, base=3, extra=0
    -- "a   b   c"
    T.eq(J.justify("a b c", 9), "a   b   c")
  end)

  T.it("uneven distribution: extra spaces go to leftmost gaps first", function()
    -- "a b c" width 10: words_len=3, gaps=2, spaces=7, base=3, extra=1
    -- gap1 gets 4, gap2 gets 3: "a    b   c"
    T.eq(J.justify("a b c", 10), "a    b   c")
  end)

  T.it("text equal to width: returns as-is", function()
    T.eq(J.justify("hello world", 11), "hello world")
  end)

  T.it("text longer than width: truncates", function()
    local result = J.justify("hello world test", 5)
    T.eq(#result, 5)
  end)
end)

-- ── paragraph ────────────────────────────────────────────────────────────────

T.describe("paragraph", function()
  T.it("left mode: each line padded to width", function()
    local lines = J.paragraph("hello world foo bar", 10, "left")
    T.eq(lines[1], "hello     ")
    T.eq(lines[2], "world foo ")
    T.eq(lines[3], "bar       ")
  end)

  T.it("right mode: each line right-aligned", function()
    -- "hi there" is 8 chars, fits in 10 — one line, right-aligned
    local lines = J.paragraph("hi there", 10, "right")
    T.eq(#lines, 1)
    T.eq(lines[1], "  hi there")
  end)

  T.it("justify mode: last line is left-aligned", function()
    local lines = J.paragraph("The quick brown fox jumps over the lazy dog", 20, "justify")
    -- last line "dog" should be left-aligned, not stretched
    local last = lines[#lines]
    T.eq(last, J.left("dog", 20))
  end)

  T.it("justify mode: non-last lines are fully justified", function()
    local lines = J.paragraph("The quick brown fox jumps over the lazy dog", 20, "justify")
    -- all lines except last should be exactly 20 chars
    for i = 1, #lines - 1 do
      T.eq(#lines[i], 20, "line " .. i .. " should be 20 chars")
    end
  end)

  T.it("default mode is left", function()
    local a = J.paragraph("hello world", 10)
    local b = J.paragraph("hello world", 10, "left")
    T.eq(#a, #b)
    for i = 1, #a do T.eq(a[i], b[i]) end
  end)

  T.it("center mode", function()
    local lines = J.paragraph("hi", 6, "center")
    T.eq(lines[1], "  hi  ")
  end)
end)

-- ── columns ──────────────────────────────────────────────────────────────────

T.describe("columns", function()
  T.it("single column", function()
    local rows = {{"Alice"}, {"Bob"}, {"Charlie"}}
    local lines = J.columns(rows, {10})
    T.eq(lines[1], "Alice     ")
    T.eq(lines[2], "Bob       ")
    T.eq(lines[3], "Charlie   ")
  end)

  T.it("multiple columns with default separator", function()
    local rows = {{"Alice", "30"}, {"Bob", "25"}}
    local lines = J.columns(rows, {8, 4})
    T.eq(lines[1], "Alice    30  ")
    T.eq(lines[2], "Bob      25  ")
  end)

  T.it("right-aligned numbers column", function()
    local rows = {{"Alice", "1000"}, {"Bob", "25"}}
    local lines = J.columns(rows, {8, 6}, {align = {"left", "right"}})
    -- "Alice   " (8) + " " (sep) + "  1000" (6) = "Alice      1000"
    T.eq(lines[1], "Alice      1000")
    -- "Bob     " (8) + " " (sep) + "    25" (6) = "Bob         25"
    T.eq(lines[2], "Bob          25")
  end)

  T.it("custom separator", function()
    local rows = {{"A", "B"}}
    local lines = J.columns(rows, {3, 3}, {sep = " | "})
    T.eq(lines[1], "A   | B  ")
  end)

  T.it("missing cell treated as empty string", function()
    local rows = {{"hello"}}
    local lines = J.columns(rows, {5, 5})
    T.eq(lines[1], "hello      ")
  end)
end)

-- ── table ────────────────────────────────────────────────────────────────────

T.describe("table: border=true", function()
  T.it("headers and rows produce correct ASCII table", function()
    local result = J.table({
      headers = {"Name", "Age"},
      rows = {{"Alice", "30"}, {"Bob", "25"}},
    })
    -- Check separator line presence
    T.ok(result:find("+", 1, true) ~= nil, "contains + border chars")
    T.ok(result:find("|", 1, true) ~= nil, "contains | column chars")
    T.ok(result:find("Name", 1, true) ~= nil, "contains header Name")
    T.ok(result:find("Alice", 1, true) ~= nil, "contains row Alice")
    T.ok(result:find("30", 1, true) ~= nil, "contains value 30")
  end)

  T.it("starts and ends with separator line", function()
    local result = J.table({
      headers = {"X"},
      rows = {{"1"}},
    })
    local lines = {}
    for line in (result .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    T.ok(lines[1]:match("^%+"), "first line is separator")
    T.ok(lines[#lines]:match("^%+"), "last line is separator")
  end)

  T.it("three separator lines for headers + rows", function()
    local result = J.table({
      headers = {"A", "B"},
      rows = {{"1", "2"}},
    })
    local sep_count = 0
    for line in (result .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%+%-") then sep_count = sep_count + 1 end
    end
    T.eq(sep_count, 3)
  end)

  T.it("right-aligned column", function()
    local result = J.table({
      headers = {"Name", "Score"},
      rows = {{"Alice", "100"}, {"Bob", "9"}},
    }, {align = {"left", "right"}})
    T.ok(result:find("100", 1, true) ~= nil)
    T.ok(result:find("  9", 1, true) ~= nil, "9 is right-aligned, so preceded by spaces")
  end)
end)

T.describe("table: border=false", function()
  T.it("no + chars when border=false", function()
    local result = J.table({
      headers = {"Name", "Age"},
      rows = {{"Alice", "30"}},
    }, {border = false})
    T.ok(result:find("+", 1, true) == nil, "no + in borderless table")
    T.ok(result:find("Name", 1, true) ~= nil, "still has header")
    T.ok(result:find("Alice", 1, true) ~= nil, "still has data")
  end)
end)

-- ── truncate ─────────────────────────────────────────────────────────────────

T.describe("truncate", function()
  T.it("shorter than max: no change", function()
    T.eq(J.truncate("hello", 10), "hello")
  end)

  T.it("equal to max: no change", function()
    T.eq(J.truncate("hello", 5), "hello")
  end)

  T.it("longer than max: truncates with default ellipsis", function()
    T.eq(J.truncate("Hello, World!", 8), "Hello...")
  end)

  T.it("custom ellipsis (single-byte)", function()
    T.eq(J.truncate("Hello, World!", 8, "~"), "Hello, ~")
  end)

  T.it("empty ellipsis: just truncates", function()
    T.eq(J.truncate("Hello, World!", 5, ""), "Hello")
  end)

  T.it("max_len <= ellipsis length: returns ellipsis truncated to max_len", function()
    T.eq(J.truncate("Hello, World!", 2), "..")
  end)

  T.it("max_len exactly ellipsis length: returns just ellipsis", function()
    T.eq(J.truncate("Hello!", 3), "...")
  end)
end)

-- ── pad_left / pad_right / pad_center ────────────────────────────────────────

T.describe("pad_left", function()
  T.it("pads with spaces by default", function()
    T.eq(J.pad_left("hi", 5), "   hi")
  end)

  T.it("custom char", function()
    T.eq(J.pad_left("42", 6, "0"), "000042")
  end)

  T.it("already at width: no change", function()
    T.eq(J.pad_left("hello", 5), "hello")
  end)

  T.it("longer than width: no change", function()
    T.eq(J.pad_left("hello world", 5), "hello world")
  end)
end)

T.describe("pad_right", function()
  T.it("pads with spaces by default", function()
    T.eq(J.pad_right("hi", 5), "hi   ")
  end)

  T.it("custom char", function()
    T.eq(J.pad_right("hi", 5, "-"), "hi---")
  end)

  T.it("already at width: no change", function()
    T.eq(J.pad_right("hello", 5), "hello")
  end)

  T.it("longer than width: no change", function()
    T.eq(J.pad_right("hello world", 5), "hello world")
  end)
end)

T.describe("pad_center", function()
  T.it("pads both sides with spaces", function()
    T.eq(J.pad_center("hi", 6), "  hi  ")
  end)

  T.it("odd: extra goes right", function()
    T.eq(J.pad_center("hi", 5), " hi  ")
  end)

  T.it("custom char", function()
    T.eq(J.pad_center("hi", 6, "-"), "--hi--")
  end)

  T.it("already at width: no change", function()
    T.eq(J.pad_center("hello", 5), "hello")
  end)
end)

-- ── indent ───────────────────────────────────────────────────────────────────

T.describe("indent", function()
  T.it("single line gets indent prefix", function()
    T.eq(J.indent("hello", 2), "  hello")
  end)

  T.it("multi-line: each line gets prefix", function()
    T.eq(J.indent("hello\nworld", 2), "  hello\n  world")
  end)

  T.it("custom char", function()
    T.eq(J.indent("hello", 2, "\t"), "\t\thello")
  end)

  T.it("n=0: no change", function()
    T.eq(J.indent("hello\nworld", 0), "hello\nworld")
  end)
end)

-- ── dedent ───────────────────────────────────────────────────────────────────

T.describe("dedent", function()
  T.it("removes common leading spaces", function()
    T.eq(J.dedent("  hello\n  world"), "hello\nworld")
  end)

  T.it("removes only common prefix", function()
    T.eq(J.dedent("    hello\n  world"), "  hello\nworld")
  end)

  T.it("no common indent: no change", function()
    T.eq(J.dedent("hello\nworld"), "hello\nworld")
  end)

  T.it("single line", function()
    T.eq(J.dedent("   hi"), "hi")
  end)

  T.it("ignores empty lines when computing common prefix", function()
    -- "  hello\n\n  world" — empty line ignored, common = "  "
    T.eq(J.dedent("  hello\n\n  world"), "hello\n\nworld")
  end)

  T.it("tabs as common prefix", function()
    T.eq(J.dedent("\thello\n\tworld"), "hello\nworld")
  end)
end)
