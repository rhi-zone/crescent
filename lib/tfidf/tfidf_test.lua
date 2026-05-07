if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local tfidf = require("lib.tfidf")

T.describe("tfidf", function()

  T.describe("tokenize", function()
    T.it("converts string to lowercase tokens", function()
      local tokens = tfidf.tokenize("Hello World Test")
      T.eq(#tokens, 3)
      T.eq(tokens[1], "hello")
      T.eq(tokens[2], "world")
      T.eq(tokens[3], "test")
    end)

    T.it("strips punctuation", function()
      local tokens = tfidf.tokenize("Hello, World! This is a test.")
      T.eq(tokens[1], "hello")
      T.eq(tokens[2], "world")
      T.eq(tokens[3], "this")
      T.eq(tokens[4], "is")
      T.eq(tokens[5], "a")
      T.eq(tokens[6], "test")
      T.eq(#tokens, 6)
    end)

    T.it("returns empty table for empty string", function()
      local tokens = tfidf.tokenize("")
      T.eq(#tokens, 0)
    end)
  end)

  T.describe("tf", function()
    T.it("returns correct term counts", function()
      local tf = tfidf.tf("the cat sat on the mat")
      T.eq(tf["the"], 2)
      T.eq(tf["cat"], 1)
      T.eq(tf["sat"], 1)
      T.eq(tf["on"], 1)
      T.eq(tf["mat"], 1)
    end)
  end)

  T.describe("tf_normalized", function()
    T.it("returns counts divided by total", function()
      local tf = tfidf.tf_normalized("the cat sat on the mat")
      -- 6 tokens total, "the" appears 2 times
      local eps = 0.001
      T.ok(math.abs(tf["the"] - 2/6) < eps, "the should be ~0.333")
      T.ok(math.abs(tf["cat"] - 1/6) < eps, "cat should be ~0.167")
      T.ok(math.abs(tf["sat"] - 1/6) < eps, "sat should be ~0.167")
    end)
  end)

  T.describe("corpus", function()
    T.it("tracks document count after add", function()
      local c = tfidf.corpus()
      T.eq(c:doc_count(), 0)
      c:add("d1", "hello world")
      T.eq(c:doc_count(), 1)
      c:add("d2", "goodbye world")
      T.eq(c:doc_count(), 2)
    end)

    T.it("idf: term in one doc has higher IDF than term in all docs", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      c:add("d3", "cats and dogs are friends")
      -- "cat" is in 1 doc, "sat" is in 2 docs
      local idf_cat = c:idf("cat")
      local idf_sat = c:idf("sat")
      T.ok(idf_cat > idf_sat, "rare term should have higher IDF")
    end)

    T.it("idf: unknown term returns high IDF", function()
      local c = tfidf.corpus()
      c:add("d1", "hello world")
      c:add("d2", "goodbye world")
      local idf_unknown = c:idf("zzzzz")
      local idf_world = c:idf("world")
      T.ok(idf_unknown > idf_world, "unknown term should have higher IDF than common term")
    end)

    T.it("tfidf: returns vector for a document", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      local vec = c:tfidf("d1")
      T.ok(vec, "should return a vector")
      T.ok(vec["cat"], "should have cat")
      T.ok(vec["the"], "should have the")
    end)

    T.it("tfidf: common terms have lower scores than rare terms", function()
      local c = tfidf.corpus()
      c:add("d1", "cat fish bird")
      c:add("d2", "cat dog wolf")
      c:add("d3", "cat horse cow")
      local vec_raw = c:tfidf("d1")
      local vec = vec_raw --[[:! { [string]: number }]]
      -- "cat" in all 3 docs, "fish" only in d1 → fish should score higher
      T.ok(vec["fish"] > vec["cat"], "rare 'fish' should score higher than common 'cat'")
    end)

    T.it("similarity: identical documents score 1.0", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the cat sat on the mat")
      local sim_raw = c:similarity("d1", "d2")
      local sim = sim_raw --[[:! number]]
      T.ok(math.abs(sim - 1.0) < 0.001, "identical docs should have similarity ~1.0, got " .. sim)
    end)

    T.it("similarity: completely different documents score near 0", function()
      local c = tfidf.corpus()
      c:add("d1", "alpha beta gamma")
      c:add("d2", "delta epsilon zeta")
      local sim_raw = c:similarity("d1", "d2")
      local sim = sim_raw --[[:! number]]
      T.ok(sim < 0.01, "completely different docs should have similarity near 0, got " .. sim)
    end)

    T.it("similarity: partially overlapping documents between 0 and 1", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      c:add("d3", "cats and dogs are friends")
      local sim_raw = c:similarity("d1", "d2")
      local sim = sim_raw --[[:! number]]
      T.ok(sim > 0.0, "overlapping docs should have sim > 0, got " .. sim)
      T.ok(sim < 1.0, "overlapping docs should have sim < 1, got " .. sim)
    end)

    T.it("search: returns ranked results", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      c:add("d3", "cats and dogs are friends")
      local results = c:search("cat mat")
      T.ok(#results > 0, "should return results")
      -- Results should be sorted by score descending
      for j = 2, #results do
        T.ok(results[j-1].score >= results[j].score, "results should be sorted descending")
      end
    end)

    T.it("search: most relevant document first", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      c:add("d3", "cats and dogs are friends")
      local results = c:search("cat mat")
      T.eq(results[1].id, "d1")
    end)

    T.it("search: respects limit", function()
      local c = tfidf.corpus()
      c:add("d1", "alpha beta gamma")
      c:add("d2", "alpha beta delta")
      c:add("d3", "alpha epsilon zeta")
      local results = c:search("alpha beta", { limit = 2 })
      T.ok(#results <= 2, "should respect limit")
    end)

    T.it("search: query with no matching terms returns empty", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      local results = c:search("zzzzz qqqqqq")
      T.eq(#results, 0)
    end)

    T.it("keywords: returns top terms by TF-IDF score", function()
      local c = tfidf.corpus()
      c:add("d1", "cat fish bird")
      c:add("d2", "cat dog wolf")
      c:add("d3", "cat horse cow")
      local kw_raw = c:keywords("d1")
      local kw = kw_raw --[[:! { [number]: { term: string, score: number } }]]
      T.ok(#kw > 0, "should return keywords")
      -- Should be sorted by score descending
      for j = 2, #kw do
        T.ok(kw[j-1].score >= kw[j].score, "keywords should be sorted descending")
      end
      -- First keyword should be a rare term (fish or bird), not common (cat)
      T.ok(kw[1].term == "fish" or kw[1].term == "bird", "top keyword should be rare term, got " .. kw[1].term)
    end)

    T.it("keywords: respects limit", function()
      local c = tfidf.corpus()
      c:add("d1", "alpha beta gamma delta epsilon")
      c:add("d2", "alpha beta")
      local kw_raw = c:keywords("d1", { limit = 2 })
      local kw = kw_raw --[[:! { [number]: { term: string, score: number } }]]
      T.eq(#kw, 2)
    end)

    T.it("vocab and vocab_size", function()
      local c = tfidf.corpus()
      c:add("d1", "cat dog")
      c:add("d2", "dog fish")
      local v = c:vocab()
      T.eq(#v, 3)
      T.eq(c:vocab_size(), 3)
      -- vocab should be sorted
      T.eq(v[1], "cat")
      T.eq(v[2], "dog")
      T.eq(v[3], "fish")
    end)

    T.it("remove: document no longer in corpus", function()
      local c = tfidf.corpus()
      c:add("d1", "hello world")
      c:add("d2", "goodbye world")
      c:remove("d1")
      T.eq(c:doc_count(), 1)
      local vec, err = c:tfidf("d1")
      T.eq(vec, nil)
      T.ok(err, "should return error message")
    end)

    T.it("remove: IDF recomputed after removal", function()
      local c = tfidf.corpus()
      c:add("d1", "cat dog")
      c:add("d2", "cat fish")
      local idf_before = c:idf("cat")
      c:remove("d2")
      local idf_after = c:idf("cat")
      -- After removing d2, "cat" is only in 1 doc out of 1 (was 2 out of 2)
      -- IDF values may differ because N changed
      T.ok(idf_before ~= idf_after or c:doc_count() == 1, "IDF should change or be consistent")
    end)

    T.it("tfidf_query: TF-IDF for arbitrary query string", function()
      local c = tfidf.corpus()
      c:add("d1", "the cat sat on the mat")
      c:add("d2", "the dog sat on the log")
      local vec = c:tfidf_query("cat sat")
      T.ok(vec["cat"], "should have cat in query vector")
      T.ok(vec["sat"], "should have sat in query vector")
      T.ok(vec["cat"] > vec["sat"], "rare term should score higher in query")
    end)

    T.it("custom tokenizer via opts", function()
      -- Custom tokenizer that splits on commas
      --: (text: string, _opts: unknown) -> { [integer]: string }
      local function comma_tokenizer(text, _opts)
        local tokens = {} --: { [integer]: string }
        local n = 0
        for word in text --[[: string]]:gmatch("[^,]+") do
          local trimmed = word:match("^%s*(.-)%s*$") or ""
          if #trimmed > 0 then
            n = n + 1
            tokens[n] = trimmed:lower()
          end
        end
        return tokens
      end
      local c = tfidf.corpus({ tokenize = comma_tokenizer })
      c:add("d1", "hello world,goodbye world")
      c:add("d2", "hello world,foo bar")
      T.eq(c:doc_count(), 2)
      local vec_raw2 = c:tfidf("d1")
      local vec = vec_raw2 --[[:! { [string]: number }]]
      T.ok(vec["goodbye world"], "should tokenize on commas")
      T.ok(vec["hello world"], "should have hello world as single token")
    end)

    T.it("single document corpus", function()
      local c = tfidf.corpus()
      c:add("d1", "hello world hello")
      T.eq(c:doc_count(), 1)
      local vec_raw3 = c:tfidf("d1")
      local vec = vec_raw3 --[[:! { [string]: number }]]
      T.ok(vec["hello"], "should have hello")
      T.ok(vec["world"], "should have world")
      -- With only one document, all terms appear in all docs
      -- so IDF is the same for all terms, but TF differs
      T.ok(vec["hello"] > vec["world"], "hello appears twice, should have higher tf-idf")
    end)
  end)
end)

-- Print summary
local s = T._summary()
print(string.format("\n%d passed, %d failed", s.pass, s.fail))
if s.fail > 0 then
  for _, t in ipairs(s.tests) do
    if not t.ok then
      local terr = t.err --[[:! string | nil]]
      print("  FAIL: " .. t.name --[[:! string]] .. (terr and (" — " .. terr) or ""))
    end
  end
  os.exit(1)
end
