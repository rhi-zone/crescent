if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local ac = require("lib.aho_corasick")
local T = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- Helper: sort matches for deterministic comparison
-- ---------------------------------------------------------------------------
local function sorted(matches)
  local out = {}
  for i, m in ipairs(matches) do out[i] = m end
  table.sort(out, function(a, b)
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[3] < b[3]
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- M.new — construction and error handling
-- ---------------------------------------------------------------------------

T.describe("new", function()
  T.it("returns automaton for valid patterns", function()
    local auto, err = ac.new({"he", "she"})
    T.ok(auto ~= nil, "should return automaton")
    T.ok(err == nil, "should have no error")
  end)

  T.it("returns nil,err for empty pattern list", function()
    local auto, err = ac.new({})
    T.eq(auto, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err for nil input", function()
    local auto, err = ac.new(nil)
    T.eq(auto, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err for empty string pattern", function()
    local auto, err = ac.new({"hello", ""})
    T.eq(auto, nil)
    T.ok(type(err) == "string")
  end)

  T.it("returns nil,err for non-string pattern", function()
    local auto, err = ac.new({42})
    T.eq(auto, nil)
    T.ok(type(err) == "string")
  end)
end)

-- ---------------------------------------------------------------------------
-- patterns() and count()
-- ---------------------------------------------------------------------------

T.describe("patterns and count", function()
  T.it("patterns() returns copy of pattern list", function()
    local pats = {"he", "she", "his", "hers"}
    local auto = ac.new(pats)
    local got = auto:patterns()
    T.eq(#got, 4)
    T.eq(got[1], "he")
    T.eq(got[2], "she")
    T.eq(got[3], "his")
    T.eq(got[4], "hers")
  end)

  T.it("count() returns number of patterns", function()
    local auto = ac.new({"a", "bb", "ccc"})
    T.eq(auto:count(), 3)
  end)

  T.it("single pattern count", function()
    local auto = ac.new({"only"})
    T.eq(auto:count(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- search — classic Aho-Corasick example: "ushers"
-- ---------------------------------------------------------------------------

T.describe("search ushers", function()
  -- "ushers" = u(1) s(2) h(3) e(4) r(5) s(6)
  -- "he"   → starts at 3 (h=3,e=4)
  -- "she"  → starts at 2 (s=2,h=3,e=4)
  -- "hers" → starts at 3 (h=3,e=4,r=5,s=6)
  -- "his"  → not present
  local auto = ac.new({"he", "she", "his", "hers"})
  local matches = sorted(auto:search("ushers"))

  T.it("finds correct number of matches", function()
    T.eq(#matches, 3)
  end)

  T.it("finds 'she' at position 2", function()
    local found = false
    for _, m in ipairs(matches) do
      if m[2] == "she" and m[1] == 2 then found = true end
    end
    T.ok(found, "she at pos 2")
  end)

  T.it("finds 'he' at position 3", function()
    local found = false
    for _, m in ipairs(matches) do
      if m[2] == "he" and m[1] == 3 then found = true end
    end
    T.ok(found, "he at pos 3")
  end)

  T.it("finds 'hers' at position 3", function()
    local found = false
    for _, m in ipairs(matches) do
      if m[2] == "hers" and m[1] == 3 then found = true end
    end
    T.ok(found, "hers at pos 3")
  end)

  T.it("does not find 'his'", function()
    for _, m in ipairs(matches) do
      T.neq(m[2], "his")
    end
  end)

  T.it("pattern_index for 'he' is 1", function()
    for _, m in ipairs(matches) do
      if m[2] == "he" then T.eq(m[3], 1) end
    end
  end)

  T.it("pattern_index for 'she' is 2", function()
    for _, m in ipairs(matches) do
      if m[2] == "she" then T.eq(m[3], 2) end
    end
  end)

  T.it("pattern_index for 'hers' is 4", function()
    for _, m in ipairs(matches) do
      if m[2] == "hers" then T.eq(m[3], 4) end
    end
  end)
end)

-- ---------------------------------------------------------------------------
-- search — overlapping matches
-- ---------------------------------------------------------------------------

T.describe("search overlapping", function()
  T.it("'aa' in 'aaa' → 2 matches", function()
    local auto = ac.new({"aa"})
    local m = auto:search("aaa")
    T.eq(#m, 2)
    T.eq(m[1][1], 1)
    T.eq(m[2][1], 2)
  end)

  T.it("'a' in 'aaa' → 3 matches", function()
    local auto = ac.new({"a"})
    local m = auto:search("aaa")
    T.eq(#m, 3)
    T.eq(m[1][1], 1)
    T.eq(m[2][1], 2)
    T.eq(m[3][1], 3)
  end)

  T.it("both 'ab' and 'b' in 'ab'", function()
    local auto = ac.new({"ab", "b"})
    local m = sorted(auto:search("ab"))
    T.eq(#m, 2)
    -- "ab" starts at 1, "b" starts at 2
    T.eq(m[1][2], "ab")
    T.eq(m[1][1], 1)
    T.eq(m[2][2], "b")
    T.eq(m[2][1], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- search — single pattern (degenerate)
-- ---------------------------------------------------------------------------

T.describe("search single pattern", function()
  T.it("finds single pattern", function()
    local auto = ac.new({"world"})
    local m = auto:search("hello world")
    T.eq(#m, 1)
    T.eq(m[1][1], 7)
    T.eq(m[1][2], "world")
    T.eq(m[1][3], 1)
  end)

  T.it("finds multiple occurrences of single pattern", function()
    local auto = ac.new({"ab"})
    local m = auto:search("ababab")
    T.eq(#m, 3)
    T.eq(m[1][1], 1)
    T.eq(m[2][1], 3)
    T.eq(m[3][1], 5)
  end)
end)

-- ---------------------------------------------------------------------------
-- search — empty text and pattern not found
-- ---------------------------------------------------------------------------

T.describe("search edge cases", function()
  T.it("empty text → no matches", function()
    local auto = ac.new({"hello"})
    local m = auto:search("")
    T.eq(#m, 0)
  end)

  T.it("pattern not in text → empty result", function()
    local auto = ac.new({"xyz"})
    local m = auto:search("hello world")
    T.eq(#m, 0)
  end)

  T.it("text shorter than pattern → no match", function()
    local auto = ac.new({"longer"})
    local m = auto:search("lo")
    T.eq(#m, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- search — case sensitivity
-- ---------------------------------------------------------------------------

T.describe("case sensitivity", function()
  T.it("is case-sensitive by default", function()
    local auto = ac.new({"Hello"})
    T.eq(#auto:search("hello"), 0)
    T.eq(#auto:search("Hello"), 1)
  end)

  T.it("lower-case pattern does not match upper", function()
    local auto = ac.new({"abc"})
    T.eq(#auto:search("ABC"), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- find
-- ---------------------------------------------------------------------------

T.describe("find", function()
  T.it("returns first match start, pattern, index", function()
    local auto = ac.new({"he", "she", "his", "hers"})
    local start, pat, idx = auto:find("ushers")
    -- earliest start is 2 ("she")
    T.eq(start, 2)
    T.eq(pat, "she")
    T.eq(idx, 2)
  end)

  T.it("returns nil when no match", function()
    local auto = ac.new({"xyz"})
    local start = auto:find("hello")
    T.eq(start, nil)
  end)

  T.it("single pattern find", function()
    local auto = ac.new({"world"})
    local start, pat, idx = auto:find("hello world foo")
    T.eq(start, 7)
    T.eq(pat, "world")
    T.eq(idx, 1)
  end)

  T.it("find returns lowest pattern_index on tie", function()
    -- Both "ab" (idx=1) and "ab" copy as "ba" starts at 2; "ab" starts at 1
    local auto = ac.new({"a", "b"})
    local start, pat, idx = auto:find("ab")
    T.eq(start, 1)
    T.eq(pat, "a")
    T.eq(idx, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- contains
-- ---------------------------------------------------------------------------

T.describe("contains", function()
  T.it("returns true when pattern present", function()
    local auto = ac.new({"he", "she"})
    T.ok(auto:contains("ushers"))
  end)

  T.it("returns false when no pattern present", function()
    local auto = ac.new({"xyz", "qrs"})
    T.ok(not auto:contains("hello world"))
  end)

  T.it("returns false for empty text", function()
    local auto = ac.new({"hello"})
    T.ok(not auto:contains(""))
  end)

  T.it("returns true for exact match", function()
    local auto = ac.new({"abc"})
    T.ok(auto:contains("abc"))
  end)
end)

-- ---------------------------------------------------------------------------
-- replace — table
-- ---------------------------------------------------------------------------

T.describe("replace with table", function()
  T.it("replaces matching patterns", function()
    local auto = ac.new({"cat", "dog"})
    local result = auto:replace("I have a cat and a dog", {cat="CAT", dog="DOG"})
    T.eq(result, "I have a CAT and a DOG")
  end)

  T.it("replaces only matching patterns, leaves rest unchanged", function()
    local auto = ac.new({"foo"})
    local result = auto:replace("foo bar baz", {foo="FOO"})
    T.eq(result, "FOO bar baz")
  end)

  T.it("no match → returns original text", function()
    local auto = ac.new({"xyz"})
    local result = auto:replace("hello world", {xyz="ZZZ"})
    T.eq(result, "hello world")
  end)

  T.it("multiple occurrences all replaced", function()
    local auto = ac.new({"ab"})
    local result = auto:replace("ababab", {ab="X"})
    T.eq(result, "XXX")
  end)

  T.it("missing replacement key → keep original", function()
    local auto = ac.new({"cat", "dog"})
    local result = auto:replace("cat and dog", {cat="CAT"})
    -- dog has no replacement → keep "dog"
    T.eq(result, "CAT and dog")
  end)
end)

-- ---------------------------------------------------------------------------
-- replace — function
-- ---------------------------------------------------------------------------

T.describe("replace with function", function()
  T.it("calls function with pattern and start pos", function()
    local auto = ac.new({"hello"})
    local got_pat, got_start
    auto:replace("say hello", function(pat, start)
      got_pat = pat
      got_start = start
      return "HI"
    end)
    T.eq(got_pat, "hello")
    T.eq(got_start, 5)
  end)

  T.it("uses function return value as replacement", function()
    local auto = ac.new({"world"})
    local result = auto:replace("hello world", function(pat, _)
      return pat:upper()
    end)
    T.eq(result, "hello WORLD")
  end)

  T.it("function receives correct start positions", function()
    local auto = ac.new({"a"})
    local starts = {}
    auto:replace("bab", function(_, start)
      starts[#starts+1] = start
      return "X"
    end)
    table.sort(starts)
    T.eq(starts[1], 2)
    T.eq(#starts, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- search_cb
-- ---------------------------------------------------------------------------

T.describe("search_cb", function()
  T.it("calls callback for each match", function()
    local auto = ac.new({"he", "she"})
    local count = 0
    auto:search_cb("ushers", function(start, pat, idx)
      count = count + 1
    end)
    T.eq(count, 2)
  end)

  T.it("callback receives correct start positions", function()
    local auto = ac.new({"ab"})
    local starts = {}
    auto:search_cb("ababab", function(start, pat, idx)
      starts[#starts+1] = start
    end)
    table.sort(starts)
    T.eq(starts[1], 1)
    T.eq(starts[2], 3)
    T.eq(starts[3], 5)
  end)

  T.it("no callback calls on empty text", function()
    local auto = ac.new({"x"})
    local count = 0
    auto:search_cb("", function() count = count + 1 end)
    T.eq(count, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- multi-byte (UTF-8 treated as byte sequences)
-- ---------------------------------------------------------------------------

T.describe("multi-byte / UTF-8", function()
  T.it("finds UTF-8 pattern as byte sequence", function()
    -- "café" in UTF-8: c(1) a(2) f(3) é(2 bytes: 0xC3 0xA9) = 5 bytes
    local pattern = "caf\xc3\xa9"   -- "café" in UTF-8
    local text    = "I drink caf\xc3\xa9 daily"
    local auto = ac.new({pattern})
    local m = auto:search(text)
    T.eq(#m, 1)
    T.eq(m[1][1], 9)  -- byte position 9
    T.eq(m[1][2], pattern)
  end)

  T.it("treats strings as byte sequences, finds embedded NUL", function()
    local auto = ac.new({"a\0b"})
    local m = auto:search("xa\0by")
    T.eq(#m, 1)
    T.eq(m[1][1], 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- 10 patterns simultaneously
-- ---------------------------------------------------------------------------

T.describe("10 patterns simultaneously", function()
  local pats = {"one","two","three","four","five","six","seven","eight","nine","ten"}
  local auto = ac.new(pats)
  local text = "one two three four five six seven eight nine ten"

  T.it("finds all 10 patterns", function()
    local m = auto:search(text)
    T.eq(#m, 10)
  end)

  T.it("all patterns are found", function()
    local found = {}
    for _, m in ipairs(auto:search(text)) do
      found[m[2]] = true
    end
    for _, p in ipairs(pats) do
      T.ok(found[p], p .. " should be found")
    end
  end)

  T.it("contains returns true", function()
    T.ok(auto:contains(text))
  end)

  T.it("contains returns false on unrelated text", function()
    T.ok(not auto:contains("hello world"))
  end)
end)

-- ---------------------------------------------------------------------------
-- Duplicate patterns
-- ---------------------------------------------------------------------------

T.describe("duplicate patterns", function()
  T.it("both duplicates are reported", function()
    local auto = ac.new({"ab", "ab"})
    local m = auto:search("xaby")
    -- Both pattern indices should appear
    T.eq(#m, 2)
    local idxs = {m[1][3], m[2][3]}
    table.sort(idxs)
    T.eq(idxs[1], 1)
    T.eq(idxs[2], 2)
  end)
end)
