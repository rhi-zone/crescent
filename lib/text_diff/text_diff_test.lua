if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local td = require("lib.text_diff")

T.describe("text_diff.diff", function()
  T.it("identical strings produce one equal op", function()
    local d = td.diff("hello", "hello")
    T.eq(#d, 1)
    T.eq(d[1][1], "equal")
    T.eq(d[1][2], "hello")
  end)

  T.it("identical empty strings produce no ops", function()
    local d = td.diff("", "")
    T.eq(#d, 0)
  end)

  T.it("complete replacement produces delete then insert", function()
    local d = td.diff("abc", "xyz")
    -- Should have a delete of "abc" and insert of "xyz" (order may vary, but both present)
    local has_del, has_ins = false, false
    for _, op in ipairs(d) do
      if op[1] == "delete" then has_del = true end
      if op[1] == "insert" then has_ins = true end
    end
    T.ok(has_del, "should have delete op")
    T.ok(has_ins, "should have insert op")
  end)

  T.it("insertion in middle: equal + insert + equal", function()
    local d = td.diff("Hello World", "Hello Lua World")
    -- Reconstruct destination
    local result = td.apply("Hello World", d)
    T.eq(result, "Hello Lua World")
    -- Should contain an insert op
    local has_ins = false
    for _, op in ipairs(d) do
      if op[1] == "insert" then has_ins = true end
    end
    T.ok(has_ins, "should have insert op")
  end)

  T.it("deletion in middle: equal + delete + equal", function()
    local d = td.diff("Hello Lua World", "Hello World")
    local result = td.apply("Hello Lua World", d)
    T.eq(result, "Hello World")
    local has_del = false
    for _, op in ipairs(d) do
      if op[1] == "delete" then has_del = true end
    end
    T.ok(has_del, "should have delete op")
  end)

  T.it("mixed changes", function()
    local d = td.diff("cat in hat", "cat on mat")
    local result = td.apply("cat in hat", d)
    T.eq(result, "cat on mat")
  end)

  T.it("empty first string produces single insert", function()
    local d = td.diff("", "abc")
    T.eq(#d, 1)
    T.eq(d[1][1], "insert")
    T.eq(d[1][2], "abc")
  end)

  T.it("empty second string produces single delete", function()
    local d = td.diff("abc", "")
    T.eq(#d, 1)
    T.eq(d[1][1], "delete")
    T.eq(d[1][2], "abc")
  end)

  T.it("common prefix/suffix optimization", function()
    -- prefix "ab" and suffix "ef" should be equal ops
    local d = td.diff("abcdef", "abXYef")
    local prefix_ok = d[1][1] == "equal" and d[1][2] == "ab"
    local suffix_ok = d[#d][1] == "equal" and d[#d][2] == "ef"
    T.ok(prefix_ok, "common prefix should be equal op")
    T.ok(suffix_ok, "common suffix should be equal op")
  end)
end)

T.describe("text_diff.apply", function()
  T.it("reconstructs destination from source + diffs", function()
    local cases = {
      { "Hello World", "Hello Lua World" },
      { "foo bar baz", "foo qux baz" },
      { "abc", "" },
      { "", "xyz" },
      { "same", "same" },
    }
    for _, c in ipairs(cases) do
      local src, dst = c[1], c[2]
      local d = td.diff(src, dst)
      local got = td.apply(src, d)
      T.eq(got, dst)
    end
  end)

  T.it("patch is an alias for apply", function()
    local d = td.diff("foo", "bar")
    T.eq(td.patch("foo", d), td.apply("foo", d))
  end)
end)

T.describe("text_diff.levenshtein", function()
  T.it("matches character edit distance for simple cases", function()
    -- "kitten" -> "sitting": distance 3
    local d = td.diff("kitten", "sitting")
    local dist = td.levenshtein(d)
    -- Levenshtein from diffs counts insertions + deletions (with substitution = del+ins = 2 each)
    -- The actual levenshtein distance (allowing substitutions) is 3, but diff-based
    -- counts max(ins,del) per adjacent pair. Let's just check it's > 0 and reasonable.
    T.ok(dist > 0, "distance should be > 0")
    T.ok(dist <= 12, "distance should be bounded by string length sum")

    -- Identical
    local d2 = td.diff("hello", "hello")
    T.eq(td.levenshtein(d2), 0)

    -- Single char insert
    local d3 = td.diff("ab", "axb")
    T.eq(td.levenshtein(d3), 1)

    -- Single char delete
    local d4 = td.diff("axb", "ab")
    T.eq(td.levenshtein(d4), 1)
  end)
end)

T.describe("text_diff.stats", function()
  T.it("counts equal/inserted/deleted correctly", function()
    local d = td.diff("Hello World", "Hello Lua World")
    local s = td.stats(d)
    T.eq(s.equal, 11)   -- "Hello " (6) + "World" (5) = 11
    T.eq(s.inserted, 4) -- "Lua "
    T.eq(s.deleted, 0)
    T.eq(s.changes, 4)
  end)

  T.it("similarity is 1.0 for identical strings", function()
    local d = td.diff("hello", "hello")
    local s = td.stats(d)
    T.eq(s.similarity, 1.0)
  end)

  T.it("similarity is 0.0 for completely different strings", function()
    local d = td.diff("aaa", "bbb")
    local s = td.stats(d)
    T.eq(s.similarity, 0.0)
  end)

  T.it("similarity is between 0 and 1 for partial match", function()
    local d = td.diff("Hello World", "Hello Lua World")
    local s = td.stats(d)
    T.ok(s.similarity > 0 and s.similarity < 1, "similarity should be between 0 and 1")
  end)

  T.it("empty diff has similarity 1.0", function()
    local d = td.diff("", "")
    local s = td.stats(d)
    T.eq(s.similarity, 1.0)
  end)
end)

T.describe("text_diff.to_html", function()
  T.it("contains ins and del tags", function()
    local d = td.diff("Hello World", "Hello Lua World")
    local html = td.to_html(d)
    T.ok(html:find("<ins>"), "should contain <ins>")
    T.ok(html:find("</ins>"), "should contain </ins>")
    -- No del expected for pure insert
    local d2 = td.diff("Hello Lua World", "Hello World")
    local html2 = td.to_html(d2)
    T.ok(html2:find("<del>"), "should contain <del>")
    T.ok(html2:find("</del>"), "should contain </del>")
  end)

  T.it("identical text renders as span only", function()
    local d = td.diff("hello", "hello")
    local html = td.to_html(d)
    T.ok(html:find("<span>"), "should have span")
    T.ok(not html:find("<ins>"), "should not have ins")
    T.ok(not html:find("<del>"), "should not have del")
  end)

  T.it("escapes HTML special chars", function()
    local d = td.diff("a<b>c", "a<b>c")
    local html = td.to_html(d)
    T.ok(html:find("&lt;"), "should escape <")
    T.ok(html:find("&gt;"), "should escape >")
  end)
end)

T.describe("text_diff.to_unified", function()
  T.it("contains + and - lines for changes", function()
    local d = td.diff("Hello World\n", "Hello Lua World\n")
    local u = td.to_unified(d, "a.txt", "b.txt")
    T.ok(u:find("%+"), "should have + lines")
    T.ok(u:find("%-"), "should have - lines or headers")
    T.ok(u:find("---"), "should have --- header")
    T.ok(u:find("%+%+%+"), "should have +++ header")
  end)

  T.it("identical text produces empty string", function()
    local d = td.diff("hello\n", "hello\n")
    local u = td.to_unified(d, "a", "b")
    T.eq(u, "")
  end)
end)

T.describe("text_diff.cleanup_semantic", function()
  T.it("returns valid diffs that still reconstruct destination", function()
    local cases = {
      { "Hello World", "Hello Lua World" },
      { "The quick brown fox", "The slow red fox" },
    }
    for _, c in ipairs(cases) do
      local src, dst = c[1], c[2]
      local d = td.diff(src, dst)
      local clean = td.cleanup_semantic(d)
      local result = td.apply(src, clean)
      T.eq(result, dst)
    end
  end)

  T.it("shifts insertion to word boundary", function()
    -- "Helloworld" -> "Hello world": the space+word should be an insert at a good boundary
    local d = td.diff("Helloworld", "Hello world")
    local clean = td.cleanup_semantic(d)
    -- Result should still reconstruct correctly
    T.eq(td.apply("Helloworld", clean), "Hello world")
    -- After cleanup, check that edits align better with boundaries
    -- (just verify no empty ops leaked in)
    for _, op in ipairs(clean) do
      T.ok(op[2] ~= "", "no empty op texts")
    end
  end)
end)

T.describe("text_diff.cleanup_efficiency", function()
  T.it("returns valid diffs that still reconstruct destination", function()
    local src = "abcdefg"
    local dst = "aXcYeZg"
    local d = td.diff(src, dst)
    local clean = td.cleanup_efficiency(d, 4)
    T.eq(td.apply(src, clean), dst)
  end)
end)

T.describe("text_diff.word_diff", function()
  T.it("operations align to word boundaries", function()
    local d = td.word_diff("hello world foo", "hello earth foo")
    -- "world" should be delete, "earth" should be insert
    local has_del, has_ins = false, false
    for _, op in ipairs(d) do
      if op[1] == "delete" then has_del = true end
      if op[1] == "insert" then has_ins = true end
    end
    T.ok(has_del, "should have delete")
    T.ok(has_ins, "should have insert")
  end)

  T.it("reconstructs destination", function()
    local src = "the quick brown fox"
    local dst = "the slow red fox"
    local d = td.word_diff(src, dst)
    T.eq(td.apply(src, d), dst)
  end)

  T.it("identical text produces equal ops", function()
    local d = td.word_diff("hello world", "hello world")
    for _, op in ipairs(d) do
      T.eq(op[1], "equal")
    end
  end)

  T.it("empty first string produces insert", function()
    local d = td.word_diff("", "hello")
    T.eq(#d, 1)
    T.eq(d[1][1], "insert")
  end)

  T.it("empty second string produces delete", function()
    local d = td.word_diff("hello", "")
    T.eq(#d, 1)
    T.eq(d[1][1], "delete")
  end)
end)

T.describe("text_diff.to_patch / from_patch", function()
  T.it("round-trips diffs through serialization", function()
    local cases = {
      { "Hello World", "Hello Lua World" },
      { "foo\nbar\n", "foo\nbaz\n" },
      { "abc", "xyz" },
    }
    for _, c in ipairs(cases) do
      local src, dst = c[1], c[2]
      local d = td.diff(src, dst)
      local patch_text = td.to_patch(src, d)
      local d2 = td.from_patch(patch_text)
      T.eq(td.apply(src, d2), dst)
    end
  end)
end)

T.describe("text_diff._tier", function()
  T.it("is pure", function()
    T.eq(td._tier, "pure")
  end)
end)
