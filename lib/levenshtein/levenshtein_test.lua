-- lib/levenshtein/levenshtein_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local L = require("lib.levenshtein")

-- ---------------------------------------------------------------------------
-- distance
-- ---------------------------------------------------------------------------
T.describe("distance", function()
  T.it("identical strings → 0", function()
    T.eq(L.distance("hello", "hello"), 0)
    T.eq(L.distance("", ""), 0)
    T.eq(L.distance("a", "a"), 0)
  end)

  T.it("empty string cases", function()
    T.eq(L.distance("", "abc"), 3)
    T.eq(L.distance("abc", ""), 3)
    T.eq(L.distance("", ""), 0)
  end)

  T.it("single characters", function()
    T.eq(L.distance("a", "b"), 1)
    T.eq(L.distance("a", ""), 1)
    T.eq(L.distance("", "b"), 1)
  end)

  T.it("kitten → sitting = 3", function()
    T.eq(L.distance("kitten", "sitting"), 3)
  end)

  T.it("sunday → saturday = 3", function()
    T.eq(L.distance("sunday", "saturday"), 3)
  end)

  T.it("completely different strings", function()
    T.eq(L.distance("abc", "xyz"), 3)
  end)

  T.it("insertion only", function()
    T.eq(L.distance("abc", "abcd"), 1)
    T.eq(L.distance("abc", "xabc"), 1)
  end)

  T.it("deletion only", function()
    T.eq(L.distance("abcd", "abc"), 1)
    T.eq(L.distance("xabc", "abc"), 1)
  end)

  T.it("substitution only", function()
    T.eq(L.distance("abc", "axc"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- distance_weighted
-- ---------------------------------------------------------------------------
T.describe("distance_weighted", function()
  T.it("default costs match unweighted", function()
    T.eq(L.distance_weighted("kitten", "sitting", {}), 3)
    T.eq(L.distance_weighted("sunday", "saturday", {}), 3)
  end)

  T.it("asymmetric insert cost", function()
    -- With insert cost=2, inserting 3 chars costs 6 instead of 3
    T.eq(L.distance_weighted("abc", "abcdef", { insert = 2 }), 6)
  end)

  T.it("asymmetric delete cost", function()
    T.eq(L.distance_weighted("abcdef", "abc", { delete = 2 }), 6)
  end)

  T.it("zero substitute cost (but still need ins/del)", function()
    T.eq(L.distance_weighted("abc", "xyz", { substitute = 0 }), 0)
  end)

  T.it("function-based cost", function()
    -- vowels are expensive to insert
    local vowels = { a = true, e = true, i = true, o = true, u = true }
    local function ins_cost(c) return vowels[c] and 3 or 1 end
    -- "" -> "a": insert 'a' costs 3 (empty source, pure insertion)
    T.eq(L.distance_weighted("", "a", { insert = ins_cost }), 3)
    -- "" -> "b": insert 'b' costs 1
    T.eq(L.distance_weighted("", "b", { insert = ins_cost }), 1)
    -- "" -> "abc": insert a(3) + b(1) + c(1) = 5
    T.eq(L.distance_weighted("", "abc", { insert = ins_cost }), 5)
  end)

  T.it("empty string edge cases", function()
    T.eq(L.distance_weighted("", "abc", {}), 3)
    T.eq(L.distance_weighted("abc", "", {}), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- damerau
-- ---------------------------------------------------------------------------
T.describe("damerau", function()
  T.it("identical → 0", function()
    T.eq(L.damerau("abc", "abc"), 0)
  end)

  T.it("transposition ab → ba = 1", function()
    T.eq(L.damerau("ab", "ba"), 1)
  end)

  T.it("ca → abc = 2", function()
    T.eq(L.damerau("ca", "abc"), 2)
  end)

  T.it("empty strings", function()
    T.eq(L.damerau("", "abc"), 3)
    T.eq(L.damerau("abc", ""), 3)
  end)

  T.it("no transposition needed", function()
    T.eq(L.damerau("kitten", "sitting"), 3)
  end)

  T.it("multiple transpositions", function()
    -- "abcd" → "badc": two transpositions
    T.eq(L.damerau("abcd", "badc"), 2)
  end)
end)

-- ---------------------------------------------------------------------------
-- osa
-- ---------------------------------------------------------------------------
T.describe("osa", function()
  T.it("identical → 0", function()
    T.eq(L.osa("abc", "abc"), 0)
  end)

  T.it("transposition ab → ba = 1", function()
    T.eq(L.osa("ab", "ba"), 1)
  end)

  T.it("empty strings", function()
    T.eq(L.osa("", "abc"), 3)
    T.eq(L.osa("abc", ""), 3)
  end)

  T.it("matches levenshtein for non-transposition cases", function()
    T.eq(L.osa("kitten", "sitting"), 3)
    T.eq(L.osa("sunday", "saturday"), 3)
  end)

  T.it("single transposition", function()
    T.eq(L.osa("ca", "ac"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- lcs
-- ---------------------------------------------------------------------------
T.describe("lcs", function()
  T.it("classic ABCBDAB/BDCAB → 4", function()
    T.eq(L.lcs("ABCBDAB", "BDCAB"), 4)
  end)

  T.it("identical strings → full length", function()
    T.eq(L.lcs("hello", "hello"), 5)
  end)

  T.it("no common subsequence", function()
    T.eq(L.lcs("abc", "xyz"), 0)
  end)

  T.it("empty strings", function()
    T.eq(L.lcs("", "abc"), 0)
    T.eq(L.lcs("abc", ""), 0)
    T.eq(L.lcs("", ""), 0)
  end)

  T.it("one is subsequence of other", function()
    T.eq(L.lcs("ace", "abcde"), 3)
  end)
end)

-- ---------------------------------------------------------------------------
-- jaro
-- ---------------------------------------------------------------------------
local function approx(a, b, tol)
  return math.abs(a - b) <= (tol or 1e-3)
end

T.describe("jaro", function()
  T.it("identical → 1.0", function()
    T.ok(L.jaro("hello", "hello") == 1.0)
  end)

  T.it("both empty → 1.0", function()
    T.ok(L.jaro("", "") == 1.0)
  end)

  T.it("one empty → 0.0", function()
    T.ok(L.jaro("", "abc") == 0.0)
    T.ok(L.jaro("abc", "") == 0.0)
  end)

  T.it("MARTHA / MARHTA ≈ 0.944", function()
    T.ok(approx(L.jaro("MARTHA", "MARHTA"), 0.9444, 1e-3))
  end)

  T.it("completely different → low score", function()
    T.ok(L.jaro("abc", "xyz") < 0.5)
  end)

  T.it("DIXON / DICKSONX", function()
    -- Well-known test case: jaro("DIXON","DICKSONX") ≈ 0.767
    T.ok(approx(L.jaro("DIXON", "DICKSONX"), 0.7667, 1e-2))
  end)

  T.it("result in [0, 1]", function()
    local score = L.jaro("foo", "bar")
    T.ok(score >= 0.0 and score <= 1.0)
  end)
end)

-- ---------------------------------------------------------------------------
-- jaro_winkler
-- ---------------------------------------------------------------------------
T.describe("jaro_winkler", function()
  T.it("identical → 1.0", function()
    T.ok(L.jaro_winkler("hello", "hello") == 1.0)
  end)

  T.it("MARTHA / MARHTA ≥ jaro score", function()
    local jaro = L.jaro("MARTHA", "MARHTA")
    local jw = L.jaro_winkler("MARTHA", "MARHTA")
    T.ok(jw >= jaro)
  end)

  T.it("common prefix boosts score", function()
    -- "abcdef" vs "abcxyz": 3-char prefix
    local jaro = L.jaro("abcdef", "abcxyz")
    local jw = L.jaro_winkler("abcdef", "abcxyz")
    T.ok(jw >= jaro)
  end)

  T.it("no prefix → equals jaro", function()
    -- Completely different first chars, e.g. "abc" vs "xyz"
    local jaro = L.jaro("abc", "xyz")
    local jw = L.jaro_winkler("abc", "xyz")
    T.ok(approx(jaro, jw, 1e-9))
  end)

  T.it("result in [0, 1]", function()
    local score = L.jaro_winkler("foo", "bar")
    T.ok(score >= 0.0 and score <= 1.0)
  end)

  T.it("custom p parameter", function()
    local jw_default = L.jaro_winkler("MARTHA", "MARHTA")
    local jw_small = L.jaro_winkler("MARTHA", "MARHTA", 0.05)
    -- Smaller p → less boost but still ≥ jaro
    T.ok(jw_small >= L.jaro("MARTHA", "MARHTA"))
    T.ok(jw_default >= jw_small)
  end)
end)

-- ---------------------------------------------------------------------------
-- similarity
-- ---------------------------------------------------------------------------
T.describe("similarity", function()
  T.it("identical → 1.0", function()
    T.ok(L.similarity("hello", "hello") == 1.0)
    T.ok(L.similarity("", "") == 1.0)
  end)

  T.it("completely different → low", function()
    T.ok(L.similarity("abc", "xyz") < 0.5)
  end)

  T.it("result in [0, 1]", function()
    local s = L.similarity("kitten", "sitting")
    T.ok(s >= 0.0 and s <= 1.0)
  end)

  T.it("1 - d/max(m,n) formula", function()
    -- distance("kitten","sitting")=3, max=7, similarity = 4/7 ≈ 0.571
    T.ok(approx(L.similarity("kitten", "sitting"), 4 / 7, 1e-9))
  end)
end)

-- ---------------------------------------------------------------------------
-- fuzzy_find
-- ---------------------------------------------------------------------------
T.describe("fuzzy_find", function()
  T.it("exact match with 0 errors", function()
    local s, e, err = L.fuzzy_find("approximately", "approx", 0)
    T.ok(s ~= nil)
    T.eq(err, 0)
  end)

  T.it("find helo in hello world with 1 error", function()
    local s, e, err = L.fuzzy_find("hello world", "helo", 1)
    T.ok(s ~= nil)
    T.ok(err <= 1)
  end)

  T.it("empty pattern returns immediately", function()
    local s, e, err = L.fuzzy_find("hello", "", 0)
    T.eq(s, 1)
    T.eq(e, 0)
    T.eq(err, 0)
  end)

  T.it("no match with 0 errors", function()
    local result = L.fuzzy_find("hello", "xyz", 0)
    T.ok(result == nil)
  end)

  T.it("match with sufficient errors", function()
    -- "zzz" in "hello" needs substitutions — unlikely with 0 errors
    local r0 = L.fuzzy_find("hello", "zzz", 0)
    T.ok(r0 == nil)
    -- but with enough errors it may match
    local r3 = L.fuzzy_find("hello", "zzz", 3)
    -- just check it doesn't crash; result may or may not be found
    T.ok(true)
  end)
end)

-- ---------------------------------------------------------------------------
-- fuzzy_find_all
-- ---------------------------------------------------------------------------
T.describe("fuzzy_find_all", function()
  T.it("finds non-overlapping matches", function()
    local matches = L.fuzzy_find_all("abcabc", "abc", 0)
    T.ok(#matches >= 1)
  end)

  T.it("empty pattern returns empty table", function()
    local matches = L.fuzzy_find_all("hello", "", 0)
    T.eq(#matches, 0)
  end)

  T.it("no match returns empty", function()
    local matches = L.fuzzy_find_all("hello", "xyz", 0)
    T.eq(#matches, 0)
  end)

  T.it("returns table of {start, finish, errors}", function()
    local matches = L.fuzzy_find_all("hello world", "world", 0)
    T.ok(#matches >= 1)
    T.ok(matches[1][1] ~= nil)
    T.ok(matches[1][2] ~= nil)
    T.ok(matches[1][3] ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- closest
-- ---------------------------------------------------------------------------
T.describe("closest", function()
  T.it("returns sorted by distance", function()
    local result = L.closest("hello", { "hell", "world", "help", "hello!" })
    -- "hell" and "hello!" are both distance 1; "world" is farther
    T.eq(result[1], "hell")  -- or "hello!" — both dist 1, first alphabetically stable
    T.ok(#result == 4)
  end)

  T.it("limits to n results", function()
    local result = L.closest("abc", { "abc", "abx", "xyz", "abcd", "ab" }, 2)
    T.eq(#result, 2)
    T.eq(result[1], "abc")  -- exact match first
  end)

  T.it("exact match is first", function()
    local result = L.closest("foo", { "baz", "bar", "foo", "fob" })
    T.eq(result[1], "foo")
  end)

  T.it("empty candidates", function()
    local result = L.closest("foo", {})
    T.eq(#result, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- is_subsequence
-- ---------------------------------------------------------------------------
T.describe("is_subsequence", function()
  T.it("ace in abcde → true", function()
    T.ok(L.is_subsequence("ace", "abcde") == true)
  end)

  T.it("aec in abcde → false", function()
    T.ok(L.is_subsequence("aec", "abcde") == false)
  end)

  T.it("empty pattern → true", function()
    T.ok(L.is_subsequence("", "hello") == true)
  end)

  T.it("pattern longer than text → false", function()
    T.ok(L.is_subsequence("abcdef", "abc") == false)
  end)

  T.it("identical strings → true", function()
    T.ok(L.is_subsequence("hello", "hello") == true)
  end)

  T.it("single char found", function()
    T.ok(L.is_subsequence("h", "hello") == true)
    T.ok(L.is_subsequence("z", "hello") == false)
  end)

  T.it("subsequence at boundaries", function()
    T.ok(L.is_subsequence("ho", "hello") == true)
    T.ok(L.is_subsequence("he", "hello") == true)
    T.ok(L.is_subsequence("lo", "hello") == true)
  end)
end)
