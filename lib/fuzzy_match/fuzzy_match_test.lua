if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local fm = require("lib.fuzzy_match")

T.describe("fuzzy_match.match", function()
  T.it("matches when all chars appear in order", function()
    T.ok(fm.match("init.lua", "ilu"))
  end)

  T.it("returns false when chars not present", function()
    T.ok(not fm.match("init.lua", "xyz"))
  end)

  T.it("returns false for empty string with non-empty pattern", function()
    T.ok(not fm.match("", "a"))
  end)

  T.it("returns true for empty pattern (matches everything)", function()
    T.ok(fm.match("abc", ""))
    T.ok(fm.match("", ""))
  end)

  T.it("is case insensitive by default", function()
    T.ok(fm.match("ABC", "abc"))
    T.ok(fm.match("abc", "ABC"))
    T.ok(fm.match("InitLua", "ilu"))
  end)

  T.it("respects case_sensitive option", function()
    T.ok(not fm.match("abc", "ABC", {case_sensitive = true}))
    T.ok(fm.match("ABC", "ABC", {case_sensitive = true}))
    T.ok(fm.match("abc", "abc", {case_sensitive = true}))
  end)

  T.it("handles single character patterns", function()
    T.ok(fm.match("hello", "h"))
    T.ok(fm.match("hello", "e"))
    T.ok(not fm.match("hello", "z"))
  end)

  T.it("handles pattern same length as string", function()
    T.ok(fm.match("abc", "abc"))
    T.ok(not fm.match("abc", "abd"))
  end)

  T.it("handles pattern longer than string", function()
    T.ok(not fm.match("ab", "abc"))
  end)
end)

T.describe("fuzzy_match.score", function()
  T.it("returns nil for non-matching pattern", function()
    T.eq(fm.score("init.lua", "xyz"), nil)
  end)

  T.it("returns a number for matching pattern", function()
    local s = fm.score("init.lua", "ilu")
    T.ok(s ~= nil)
    T.ok(type(s) == "number")
    T.ok(s >= 0)
  end)

  T.it("returns 0 score for empty pattern", function()
    T.eq(fm.score("abc", ""), 0)
  end)

  T.it("exact match scores higher than scattered match", function()
    local s_exact = fm.score("fzf", "fzf")
    local s_scattered = fm.score("foo/baz/file", "fzf")
    T.ok(s_exact ~= nil and s_scattered ~= nil)
    T.ok(s_exact > s_scattered, "exact should score higher than scattered")
  end)

  T.it("prefix match scores higher than mid-string match", function()
    local s_prefix = fm.score("foobar", "foo")
    local s_mid = fm.score("xyzfoo", "foo")
    T.ok(s_prefix ~= nil and s_mid ~= nil)
    T.ok(s_prefix > s_mid, "prefix should score higher than mid-string")
  end)

  T.it("consecutive match scores higher than scattered match", function()
    local s_consec = fm.score("abcdef", "abc")
    local s_scattered = fm.score("aXbXcdef", "abc")
    T.ok(s_consec ~= nil and s_scattered ~= nil)
    T.ok(s_consec > s_scattered, "consecutive should score higher than scattered")
  end)

  T.it("word boundary match scores higher than non-boundary", function()
    -- "fB" in "fooBar" hits camel case boundary (o->B)
    -- "fb" in "foobar" hits no boundary (just gap match)
    local s_boundary = fm.score("fooBar", "fB")
    local s_noboundary = fm.score("foobar", "fb")
    T.ok(s_boundary ~= nil and s_noboundary ~= nil)
    -- word boundary bonus should give fooBar/fB a boost over foobar/fb
    T.ok(s_boundary > s_noboundary, "word boundary should score higher")
  end)

  T.it("is case insensitive by default", function()
    local s1 = fm.score("ABC", "abc")
    local s2 = fm.score("abc", "abc")
    T.ok(s1 ~= nil)
    T.ok(s2 ~= nil)
  end)

  T.it("returns nil for non-match with case_sensitive", function()
    T.eq(fm.score("abc", "ABC", {case_sensitive = true}), nil)
  end)
end)

T.describe("fuzzy_match.positions", function()
  T.it("returns correct 1-based positions", function()
    local pos, sc = fm.positions("init.lua", "ilu")
    T.ok(pos ~= nil)
    -- 'i' at 1, 'l' at 6, 'u' at 7 (init.lua -> i=1,n=2,i=3,t=4,.=5,l=6,u=7,a=8)
    T.eq(pos[1], 1)
    T.eq(pos[2], 6)
    T.eq(pos[3], 7)
    T.ok(sc ~= nil)
    T.ok(type(sc) == "number")
  end)

  T.it("returns nil for no match", function()
    local pos, sc = fm.positions("init.lua", "xyz")
    T.eq(pos, nil)
    T.eq(sc, nil)
  end)

  T.it("returns empty positions for empty pattern", function()
    local pos, sc = fm.positions("abc", "")
    T.eq(type(pos), "table")
    T.eq(#pos, 0)
    T.eq(sc, 0)
  end)

  T.it("positions are valid indices into the string", function()
    local str = "foo/bar/baz"
    local pat = "fbz"
    local pos, sc = fm.positions(str, pat)
    T.ok(pos ~= nil)
    T.eq(#pos, #pat)
    for i = 1, #pos do
      T.ok(pos[i] >= 1 and pos[i] <= #str)
    end
    -- Verify each position actually matches (case insensitive)
    local pat_lower = pat:lower()
    local str_lower = str:lower()
    for i = 1, #pos do
      T.eq(str_lower:sub(pos[i], pos[i]), pat_lower:sub(i, i))
    end
  end)

  T.it("positions are strictly increasing", function()
    local pos = fm.positions("abcdef", "ace")
    T.ok(pos ~= nil)
    for i = 2, #pos do
      T.ok(pos[i] > pos[i-1])
    end
  end)

  T.it("consecutive match returns consecutive positions", function()
    -- "abc" in "xabcdef" — should find abc together
    local pos = fm.positions("xabcdef", "abc")
    T.ok(pos ~= nil)
    T.eq(pos[1], 2)
    T.eq(pos[2], 3)
    T.eq(pos[3], 4)
  end)
end)

T.describe("fuzzy_match.search", function()
  T.it("returns sorted results, best match first", function()
    local candidates = {"foo/baz/file", "fzf", "fuzzy"}
    local results = fm.search("fzf", candidates)
    T.ok(#results >= 1)
    -- "fzf" is exact match, should be first
    T.eq(results[1].item, "fzf")
  end)

  T.it("filters non-matching items", function()
    local candidates = {"hello", "world", "xyz"}
    local results = fm.search("abc", candidates)
    T.eq(#results, 0)
  end)

  T.it("returns all matching items", function()
    local candidates = {"abc", "aXbXc", "def"}
    local results = fm.search("abc", candidates)
    T.eq(#results, 2)
  end)

  T.it("result table has item, score, positions fields", function()
    local results = fm.search("abc", {"abcdef"})
    T.eq(#results, 1)
    T.ok(results[1].item ~= nil)
    T.ok(results[1].score ~= nil)
    T.ok(results[1].positions ~= nil)
    T.eq(results[1].item, "abcdef")
    T.ok(type(results[1].score) == "number")
    T.ok(type(results[1].positions) == "table")
  end)

  T.it("empty pattern matches all candidates with equal score", function()
    local candidates = {"abc", "def", "ghi"}
    local results = fm.search("", candidates)
    T.eq(#results, 3)
    -- All scores should be equal (0)
    T.eq(results[1].score, 0)
    T.eq(results[2].score, 0)
    T.eq(results[3].score, 0)
  end)

  T.it("works with custom key function", function()
    local items = {
      {name = "fzf", path = "/usr/bin/fzf"},
      {name = "fuzzy", path = "/home/fuzzy"},
      {name = "other", path = "/etc/other"},
    }
    local results = fm.search("fz", items, {key = function(item) return item.name end})
    T.ok(#results >= 1)
    -- Should match fzf and fuzzy, not other
    T.ok(#results == 2)
    -- Best match should be fzf (exact prefix)
    T.eq(results[1].item.name, "fzf")
    -- result.item is the original item table
    T.ok(results[1].item.path ~= nil)
  end)

  T.it("handles empty candidates list", function()
    local results = fm.search("abc", {})
    T.eq(#results, 0)
  end)

  T.it("scores are sorted descending", function()
    local candidates = {"abcdef", "aXbXcdef", "abc", "xabc"}
    local results = fm.search("abc", candidates)
    for i = 2, #results do
      T.ok(results[i-1].score >= results[i].score)
    end
  end)

  T.it("case insensitive by default", function()
    local results = fm.search("ABC", {"abcdef", "xyz"})
    T.eq(#results, 1)
    T.eq(results[1].item, "abcdef")
  end)

  T.it("case sensitive option works in search", function()
    local results = fm.search("ABC", {"abcdef", "ABCDEF"}, {case_sensitive = true})
    T.eq(#results, 1)
    T.eq(results[1].item, "ABCDEF")
  end)
end)

T.describe("fuzzy_match edge cases", function()
  T.it("single character string and pattern", function()
    T.ok(fm.match("a", "a"))
    T.ok(not fm.match("a", "b"))
  end)

  T.it("pattern equals string exactly", function()
    local pos, sc = fm.positions("hello", "hello")
    T.ok(pos ~= nil)
    T.eq(#pos, 5)
    for i = 1, 5 do T.eq(pos[i], i) end
  end)

  T.it("unicode-safe: works on byte level", function()
    -- Should not crash on multi-byte sequences
    T.ok(fm.match("hello world", "hw"))
  end)

  T.it("path-style word boundaries score well", function()
    -- 'f' after '/', 'b' after '/', 'f' in filename
    local s = fm.score("foo/bar/file.txt", "fbf")
    T.ok(s ~= nil)
    T.ok(s > 0)
  end)

  T.it("word boundary after underscore", function()
    T.ok(fm.match("my_function", "mf"))
    local s = fm.score("my_function", "mf")
    T.ok(s ~= nil)
  end)

  T.it("word boundary after dash", function()
    T.ok(fm.match("my-module", "mm"))
    local s = fm.score("my-module", "mm")
    T.ok(s ~= nil)
  end)
end)
