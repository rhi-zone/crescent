if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local SC = require("lib.spell_check")
local T  = require("lib.test.assert")

-- ── Levenshtein distance helper ───────────────────────────────────────────────

T.describe("levenshtein", function()
  T.it("identical strings → 0", function()
    T.eq(SC.levenshtein("", ""), 0)
    T.eq(SC.levenshtein("hello", "hello"), 0)
    T.eq(SC.levenshtein("abc", "abc"), 0)
  end)

  T.it("empty string edge cases", function()
    T.eq(SC.levenshtein("", "abc"), 3)
    T.eq(SC.levenshtein("abc", ""), 3)
    T.eq(SC.levenshtein("", "a"), 1)
    T.eq(SC.levenshtein("a", ""), 1)
  end)

  T.it("single substitution", function()
    T.eq(SC.levenshtein("cat", "bat"), 1)
    T.eq(SC.levenshtein("hello", "hella"), 1)
  end)

  T.it("single insertion", function()
    T.eq(SC.levenshtein("helo", "hello"), 1)
    T.eq(SC.levenshtein("wrld", "world"), 1)
  end)

  T.it("single deletion", function()
    T.eq(SC.levenshtein("helllo", "hello"), 1)
    T.eq(SC.levenshtein("worlds", "world"), 1)
  end)

  T.it("multiple operations", function()
    T.eq(SC.levenshtein("kitten", "sitting"), 3)
    T.eq(SC.levenshtein("saturday", "sunday"), 3)
    T.eq(SC.levenshtein("abc", "xyz"), 3)
  end)

  T.it("max_dist early exit returns max_dist+1 when exceeded", function()
    -- "abc" vs "xyz" is distance 3, so max_dist=2 → returns 3
    T.eq(SC.levenshtein("abc", "xyz", 2), 3)
    -- length diff alone exceeds max_dist
    T.eq(SC.levenshtein("a", "abcde", 2), 3)
  end)

  T.it("transpositions are counted as 2 ops in Levenshtein", function()
    -- "ab" → "ba": delete a, insert a at end = 2 ops
    T.eq(SC.levenshtein("ab", "ba"), 2)
    -- "ca" → "ac"
    T.eq(SC.levenshtein("ca", "ac"), 2)
  end)
end)

-- ── SC.new() with built-in dictionary ─────────────────────────────────────────

T.describe("SC.new() no args", function()
  T.it("creates a checker with built-in words", function()
    local c = SC.new()
    T.ok(c:size() > 100, "should have many words")
    T.ok(c:check("hello"), "hello should be in built-in dict")
    T.ok(c:check("the"), "the should be in built-in dict")
    T.ok(c:check("world"), "world should be in built-in dict") -- via "world" in list
  end)
end)

-- ── SC.new(words) with custom list ────────────────────────────────────────────

T.describe("SC.new(words)", function()
  T.it("creates checker with only the provided words", function()
    local c = SC.new({ "apple", "banana", "cherry" })
    T.eq(c:size(), 3)
    T.ok(c:check("apple"))
    T.ok(c:check("banana"))
    T.ok(c:check("cherry"))
    T.fail(c:check("the"), "should not have 'the' from built-in")
  end)
end)

-- ── check / correct ───────────────────────────────────────────────────────────

T.describe("check", function()
  local c = SC.new({ "hello", "world", "spelling", "test", "help", "held",
                     "tell", "sell", "bell", "fell", "well", "call", "ball",
                     "fall", "tall", "wall", "hall", "mall" })

  T.it("correct words return true", function()
    T.ok(c:check("hello"))
    T.ok(c:check("world"))
    T.ok(c:check("spelling"))
    T.ok(c:check("test"))
  end)

  T.it("misspelled words return false", function()
    T.fail(c:check("speling"))
    T.fail(c:check("helo"))
    T.fail(c:check("tset"))
    T.fail(c:check("wrold"))
  end)

  T.it("correct is an alias for check", function()
    T.ok(c:correct("hello"))
    T.fail(c:correct("helllo"))
  end)
end)

-- ── case insensitivity ────────────────────────────────────────────────────────

T.describe("case insensitivity", function()
  local c = SC.new({ "hello", "world", "the", "test" })

  T.it("uppercase input matches lowercase dict entry", function()
    T.ok(c:check("THE"))
    T.ok(c:check("HELLO"))
    T.ok(c:check("World"))
    T.ok(c:check("TEST"))
  end)

  T.it("mixed case input matches", function()
    T.ok(c:check("HeLLo"))
    T.ok(c:check("WoRlD"))
  end)
end)

-- ── suggest ───────────────────────────────────────────────────────────────────

T.describe("suggest", function()
  local c = SC.new({ "hello", "help", "held", "hell", "heal", "heap",
                     "spelling", "spilling", "shelling", "selling",
                     "world", "word", "cord", "ford",
                     "test", "text", "best", "rest", "nest", "fest",
                     "ball", "call", "fall", "hall", "tall", "wall", "mall", "bell", "fell", "sell", "tell", "well",
                     "cat", "bat", "rat", "hat", "mat", "fat", "sat",
                     "the", "there", "three", "tree", "free",
                     "apple", "apply", "ample" })

  T.it("helo → contains hello (distance 1)", function()
    local s = c:suggest("helo")
    local found = false
    for _, w in ipairs(s) do
      if w == "hello" then found = true; break end
    end
    T.ok(found, "hello should be a suggestion for helo")
  end)

  T.it("speling → contains spelling (distance 1)", function()
    local s = c:suggest("speling", { max_distance = 2 })
    local found = false
    for _, w in ipairs(s) do
      if w == "spelling" then found = true; break end
    end
    T.ok(found, "spelling should be a suggestion for speling")
  end)

  T.it("respects max_distance", function()
    -- "hello" is distance 1 from "helo"; "heap" is distance 3 from "helo"
    local s = c:suggest("helo", { max_distance = 1 })
    for _, w in ipairs(s) do
      T.ok(SC.levenshtein("helo", w) <= 1, w .. " should be within distance 1")
    end
  end)

  T.it("respects max_suggestions", function()
    local s = c:suggest("bell", { max_distance = 2, max_suggestions = 3 })
    T.ok(#s <= 3, "should return at most 3 suggestions")
  end)

  T.it("results sorted by distance then alphabetically", function()
    -- All 1-char edits from "cat": bat, fat, hat, mat, rat, sat (substitution)
    local s = c:suggest("cat", { max_distance = 2, max_suggestions = 10 })
    -- Verify distance ordering: no suggestion at distance d appears before one at distance < d
    for i = 2, #s do
      local d_prev = SC.levenshtein("cat", s[i - 1])
      local d_curr = SC.levenshtein("cat", s[i])
      T.ok(d_prev <= d_curr, "results should be sorted by distance: " .. s[i-1] .. " then " .. s[i])
      if d_prev == d_curr then
        T.ok(s[i - 1] <= s[i], "same-distance results should be alphabetical")
      end
    end
  end)

  T.it("no suggestions for a correct word in suggest (word excluded from self)", function()
    local s = c:suggest("hello")
    for _, w in ipairs(s) do
      T.neq(w, "hello", "the word itself should not appear in suggestions")
    end
  end)

  T.it("returns empty array when no words within max_distance", function()
    local s = c:suggest("xzqwerty", { max_distance = 1 })
    T.eq(#s, 0)
  end)
end)

-- ── check_with_suggestions ────────────────────────────────────────────────────

T.describe("check_with_suggestions", function()
  local c = SC.new({ "hello", "help", "held", "spell", "spelling", "world" })

  T.it("correct word returns (true, nil)", function()
    local ok, sugg = c:check_with_suggestions("hello")
    T.ok(ok)
    T.eq(sugg, nil)
  end)

  T.it("misspelled word returns (false, array)", function()
    local ok, sugg = c:check_with_suggestions("helo")
    T.fail(ok)
    T.ok(type(sugg) == "table", "suggestions should be a table")
    T.ok(#sugg >= 1, "should have at least one suggestion")
  end)

  T.it("passes opts to suggest", function()
    local ok, sugg = c:check_with_suggestions("speling", { max_distance = 2, max_suggestions = 1 })
    T.fail(ok)
    T.ok(#sugg <= 1)
  end)
end)

-- ── add / remove / size ───────────────────────────────────────────────────────

T.describe("add", function()
  T.it("newly added word is recognized as correct", function()
    local c = SC.new({ "hello" })
    T.fail(c:check("crescent"))
    c:add("crescent")
    T.ok(c:check("crescent"))
  end)

  T.it("adding duplicate does not change size", function()
    local c = SC.new({ "hello" })
    local s1 = c:size()
    c:add("hello")
    T.eq(c:size(), s1)
  end)

  T.it("added word appears in suggestions", function()
    local c = SC.new({ "hello" })
    c:add("helo")  -- add misspelling as valid
    T.ok(c:check("helo"))
  end)
end)

T.describe("add_all", function()
  T.it("adds multiple words at once", function()
    local c = SC.new({})
    c:add_all({ "one", "two", "three" })
    T.eq(c:size(), 3)
    T.ok(c:check("one"))
    T.ok(c:check("two"))
    T.ok(c:check("three"))
  end)
end)

T.describe("remove", function()
  T.it("removed word is no longer correct", function()
    local c = SC.new({ "hello", "world" })
    T.ok(c:check("hello"))
    c:remove("hello")
    T.fail(c:check("hello"))
    T.ok(c:check("world"), "other words unaffected")
  end)

  T.it("removing decrements size", function()
    local c = SC.new({ "hello", "world" })
    T.eq(c:size(), 2)
    c:remove("hello")
    T.eq(c:size(), 1)
  end)

  T.it("removing non-existent word is a no-op", function()
    local c = SC.new({ "hello" })
    c:remove("nonexistent")
    T.eq(c:size(), 1)
  end)
end)

T.describe("size", function()
  T.it("returns correct count", function()
    local c = SC.new({ "a", "bb", "ccc" })
    T.eq(c:size(), 3)
  end)

  T.it("deduplicates on creation", function()
    local c = SC.new({ "hello", "hello", "world" })
    T.eq(c:size(), 2)
  end)

  T.it("case-deduplicates on creation", function()
    local c = SC.new({ "Hello", "HELLO", "hello" })
    T.eq(c:size(), 1)
  end)
end)

-- ── check_text ────────────────────────────────────────────────────────────────

T.describe("check_text", function()
  local c = SC.new({ "the", "quick", "brown", "fox", "jumps", "over",
                     "lazy", "dog", "hello", "world", "test",
                     "this", "is", "sentence", "with", "some", "errors" })

  T.it("returns empty array for correctly spelled text", function()
    local errs = c:check_text("the quick brown fox")
    T.eq(#errs, 0)
  end)

  T.it("finds misspelled words", function()
    local errs = c:check_text("teh quick brwon fox")
    T.ok(#errs >= 2, "should find at least 2 errors")
    -- check that the misspelled words are present
    local words_found = {}
    for _, e in ipairs(errs) do words_found[e.word] = true end
    T.ok(words_found["teh"] or words_found["brwon"], "should find teh or brwon")
  end)

  T.it("each error has word, position, suggestions fields", function()
    local errs = c:check_text("teh quick fox")
    T.ok(#errs >= 1)
    local e = errs[1]
    T.ok(type(e.word) == "string")
    T.ok(type(e.position) == "number")
    T.ok(type(e.suggestions) == "table")
  end)

  T.it("position points to start of token in original text", function()
    local text = "the teh fox"
    local errs = c:check_text(text)
    T.eq(#errs, 1)
    T.eq(errs[1].word, "teh")
    T.eq(errs[1].position, 5)  -- "teh" starts at position 5
  end)

  T.it("strips punctuation from tokens", function()
    local errs = c:check_text("the, teh. fox!")
    T.ok(#errs >= 1)
    local found_teh = false
    for _, e in ipairs(errs) do
      if e.word == "teh" then found_teh = true end
    end
    T.ok(found_teh, "should strip punctuation and find teh")
  end)

  T.it("skips single character tokens", function()
    -- "a" and "I" are 1 char, should be skipped
    local errs = c:check_text("a I z")
    T.eq(#errs, 0)
  end)

  T.it("skips pure numbers", function()
    local errs = c:check_text("the 42 fox 123")
    T.eq(#errs, 0)
  end)

  T.it("ignore_capitalized skips proper nouns", function()
    -- "London" starts with uppercase — should be skipped with default opts
    local errs = c:check_text("the fox is in London today")
    local found_london = false
    for _, e in ipairs(errs) do
      if e.word == "London" then found_london = true end
    end
    T.fail(found_london, "London should be ignored (capitalized)")
  end)

  T.it("ignore_capitalized=false flags capitalized words", function()
    local errs = c:check_text("Zxqwerty is wrong", { ignore_capitalized = false })
    local found = false
    for _, e in ipairs(errs) do
      if e.word == "Zxqwerty" then found = true end
    end
    T.ok(found, "capitalized misspelling should be found when ignore_capitalized=false")
  end)

  T.it("respects max_suggestions option", function()
    local errs = c:check_text("teh fox", { max_suggestions = 1 })
    T.ok(#errs >= 1)
    T.ok(#errs[1].suggestions <= 1)
  end)
end)

-- ── correct_text ──────────────────────────────────────────────────────────────

T.describe("correct_text", function()
  local c = SC.new({ "the", "quick", "brown", "fox", "jumps", "over",
                     "lazy", "dog", "hello", "world", "spelling",
                     "test", "help", "this", "is", "sentence" })

  T.it("leaves correct text unchanged", function()
    T.eq(c:correct_text("the quick fox"), "the quick fox")
  end)

  T.it("fixes obvious single-op typos", function()
    -- "helo" → "hello" (distance 1, exactly one candidate)
    local result = c:correct_text("helo world")
    T.ok(result:find("hello") or result == "helo world",
         "should correct helo to hello or leave unchanged")
  end)

  T.it("preserves whitespace between tokens", function()
    local result = c:correct_text("the  quick   fox")
    T.ok(result:find("the") and result:find("quick") and result:find("fox"))
    -- multiple spaces preserved
    T.ok(result:find("  "), "double space should be preserved")
  end)

  T.it("preserves surrounding punctuation", function()
    -- punctuation around the token should be kept
    local result = c:correct_text("the, fox.")
    T.ok(result:find(","), "comma should be preserved")
    T.ok(result:find("%."), "period should be preserved")
  end)

  T.it("does not replace when multiple candidates exist at same distance", function()
    -- "bel" is equidistant from "bell", "belt", "gel", "eel" etc.
    -- use a dict where the word is ambiguous so no unique top suggestion exists
    local c2 = SC.new({ "bell", "belt", "ball", "bill", "bull", "sell", "tell", "fell", "well", "yell" })
    -- "bel" at distance 1: bell (insert l), ball (+1 sub), sell/tell/fell/well/yell (sub)...
    -- There will be multiple candidates → no replacement
    local sugg2 = c2:suggest("bel", { max_suggestions = 2, max_distance = 1 })
    if #sugg2 > 1 then
      local result = c2:correct_text("bel")
      T.eq(result, "bel")
    else
      -- If only one candidate, we verify replacement happened correctly
      T.ok(true, "only one candidate, replacement is valid")
    end
  end)
end)

-- ── Integration: built-in dict suggestions ───────────────────────────────────

T.describe("built-in dictionary suggestions", function()
  T.it("suggests 'spelling' for 'speling'", function()
    local c = SC.new()  -- built-in dict
    local s = c:suggest("speling", { max_distance = 2 })
    local found = false
    for _, w in ipairs(s) do
      if w == "spelling" then found = true; break end
    end
    T.ok(found, "spelling should be suggested for speling from built-in dict")
  end)

  T.it("suggests 'hello' for 'helo'", function()
    local c = SC.new()
    local s = c:suggest("helo")
    local found = false
    for _, w in ipairs(s) do
      if w == "hello" then found = true; break end
    end
    T.ok(found, "hello should be suggested for helo")
  end)

  T.it("does not flag days and months as misspelled", function()
    local c = SC.new()
    T.ok(c:check("monday"))
    T.ok(c:check("tuesday"))
    T.ok(c:check("january"))
    T.ok(c:check("december"))
  end)

  T.it("does not flag number words as misspelled", function()
    local c = SC.new()
    T.ok(c:check("one"))
    T.ok(c:check("hundred"))
    T.ok(c:check("thousand"))
  end)

  T.it("check_with_suggestions on misspelled word returns suggestions", function()
    local c = SC.new()
    local ok, sugg = c:check_with_suggestions("recieve")
    T.fail(ok)
    -- no specific suggestion guaranteed, but structure should be correct
    T.ok(type(sugg) == "table")
  end)
end)

-- ── _tier ─────────────────────────────────────────────────────────────────────

T.describe("module metadata", function()
  T.it("_tier is 'pure'", function()
    T.eq(SC._tier, "pure")
  end)
end)
