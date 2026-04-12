if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local II = require("lib.inverted_index")

-- Helper: find result entry by id
local function find(results, id)
  for _, r in ipairs(results) do
    if r.id == id then return r end
  end
  return nil
end

-- Helper: collect just the ids in order
local function ids(results)
  local t = {}
  for _, r in ipairs(results) do t[#t + 1] = r.id end
  return t
end

T.describe("inverted_index", function()

  T.describe("basic add + search", function()
    T.it("single term returns correct doc", function()
      local idx = II.new()
      idx:add("a", "hello world")
      idx:add("b", "goodbye moon")
      local results = idx:search("hello")
      T.eq(#results, 1)
      T.eq(results[1].id, "a")
      T.ok(results[1].score > 0)
    end)

    T.it("term not in index returns empty", function()
      local idx = II.new()
      idx:add("a", "hello world")
      local results = idx:search("xyz")
      T.eq(#results, 0)
    end)

    T.it("empty query returns empty", function()
      local idx = II.new()
      idx:add("a", "hello world")
      local results = idx:search("")
      T.eq(#results, 0)
    end)

    T.it("numeric doc_id works", function()
      local idx = II.new()
      idx:add(1, "the quick brown fox")
      idx:add(2, "the lazy dog")
      local results = idx:search("quick")
      T.eq(#results, 1)
      T.eq(results[1].id, 1)
    end)
  end)

  T.describe("multi-doc scoring (TF)", function()
    T.it("higher TF scores higher", function()
      local idx = II.new()
      -- doc A: 'cat' appears once
      idx:add("A", "the cat sat on the mat")
      -- doc B: 'cat' appears three times
      idx:add("B", "cat cat cat sat on the mat on the mat on the mat")
      local results = idx:search("cat")
      T.eq(#results, 2)
      -- B should score higher due to more occurrences of 'cat'
      T.eq(results[1].id, "B")
      T.ok(results[1].score > results[2].score)
    end)

    T.it("search returns all matching docs", function()
      local idx = II.new()
      for i = 1, 5 do
        idx:add(i, "term repeated " .. string.rep("term ", i))
      end
      local results = idx:search("term")
      T.eq(#results, 5)
    end)
  end)

  T.describe("BM25 length normalization", function()
    T.it("shorter docs score higher for same TF", function()
      local idx = II.new()
      -- doc A: 'cat' once, very short doc
      idx:add("short", "cat")
      -- doc B: 'cat' once, very long doc
      local long_text = "cat " .. string.rep("filler word here now extra padding text content stuff ", 20)
      idx:add("long", long_text)
      local results = idx:search("cat")
      T.eq(#results, 2)
      -- shorter doc should score higher after length normalization
      T.eq(results[1].id, "short")
    end)
  end)

  T.describe("IDF scoring", function()
    T.it("rare terms score higher than common terms", function()
      local idx = II.new()
      -- Add 10 docs all containing 'common'
      for i = 1, 10 do
        idx:add("d" .. i, "common word here and some common text word common")
      end
      -- Only one doc contains 'rare'
      idx:add("rare_doc", "common word and also rare")
      -- 'rare' appears in 1 of 11 docs; 'common' in all 11
      -- For 'rare_doc', score("rare") should exceed score("common")
      local r_rare   = idx:search("rare")
      local r_common = idx:search("common")
      local rare_score   = find(r_rare,   "rare_doc").score
      local common_score = find(r_common, "rare_doc").score
      T.ok(rare_score > common_score, "rare term should score higher than common term")
    end)
  end)

  T.describe("AND / OR search", function()
    T.it("OR returns docs with any term (default)", function()
      local idx = II.new()
      idx:add("a", "apple pie")
      idx:add("b", "banana split")
      idx:add("c", "apple banana")
      local results = idx:search("apple banana", { op = "OR" })
      T.eq(#results, 3)
    end)

    T.it("AND requires all terms", function()
      local idx = II.new()
      idx:add("a", "apple pie")
      idx:add("b", "banana split")
      idx:add("c", "apple banana")
      local results = idx:search("apple banana", { op = "AND" })
      T.eq(#results, 1)
      T.eq(results[1].id, "c")
    end)

    T.it("AND with no matching doc returns empty", function()
      local idx = II.new()
      idx:add("a", "apple pie")
      idx:add("b", "banana split")
      local results = idx:search("apple banana", { op = "AND" })
      T.eq(#results, 0)
    end)

    T.it("AND with missing term returns empty", function()
      local idx = II.new()
      idx:add("a", "apple pie")
      local results = idx:search("apple zzzzzz", { op = "AND" })
      T.eq(#results, 0)
    end)

    T.it("default op is OR", function()
      local idx = II.new()
      idx:add("a", "apple")
      idx:add("b", "banana")
      local results = idx:search("apple banana")
      T.eq(#results, 2)
    end)
  end)

  T.describe("phrase search", function()
    T.it("matches adjacent terms in order", function()
      local idx = II.new()
      idx:add("a", "quick brown fox")
      idx:add("b", "brown quick fox")  -- wrong order
      idx:add("c", "the quick brown fox jumps")
      local results = idx:phrase_search("quick brown")
      -- Only a and c have 'quick' immediately before 'brown'
      T.eq(#results, 2)
      local result_ids = ids(results)
      local has_a, has_c = false, false
      for _, id in ipairs(result_ids) do
        if id == "a" then has_a = true end
        if id == "c" then has_c = true end
      end
      T.ok(has_a, "doc a should match phrase")
      T.ok(has_c, "doc c should match phrase")
    end)

    T.it("does not match non-adjacent terms", function()
      local idx = II.new()
      idx:add("a", "quick the brown fox")  -- 'quick' and 'brown' not adjacent
      local results = idx:phrase_search("quick brown")
      T.eq(#results, 0)
    end)

    T.it("single-term phrase search works", function()
      local idx = II.new()
      idx:add("a", "hello world")
      idx:add("b", "goodbye world")
      local results = idx:phrase_search("hello")
      T.eq(#results, 1)
      T.eq(results[1].id, "a")
    end)

    T.it("empty phrase returns empty", function()
      local idx = II.new()
      idx:add("a", "hello world")
      local results = idx:phrase_search("")
      T.eq(#results, 0)
    end)

    T.it("three-word phrase", function()
      local idx = II.new()
      idx:add("match",    "the quick brown fox")
      idx:add("no_match", "the quick red fox")
      local results = idx:phrase_search("quick brown fox")
      T.eq(#results, 1)
      T.eq(results[1].id, "match")
    end)
  end)

  T.describe("remove", function()
    T.it("removed doc no longer appears in results", function()
      local idx = II.new()
      idx:add("a", "hello world")
      idx:add("b", "hello darkness")
      idx:remove("a")
      local results = idx:search("hello")
      T.eq(#results, 1)
      T.eq(results[1].id, "b")
    end)

    T.it("remove updates doc_count", function()
      local idx = II.new()
      idx:add("a", "hello")
      idx:add("b", "world")
      T.eq(idx:doc_count(), 2)
      idx:remove("a")
      T.eq(idx:doc_count(), 1)
    end)

    T.it("remove updates term_count when term only in removed doc", function()
      local idx = II.new()
      idx:add("a", "uniqueterm")
      idx:add("b", "otherterm")
      local tc_before = idx:term_count()
      idx:remove("a")
      local tc_after = idx:term_count()
      T.ok(tc_after < tc_before, "term count should decrease after removing sole doc for a term")
    end)

    T.it("remove nonexistent doc returns error", function()
      local idx = II.new()
      local result, err = idx:remove("nope")
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)

    T.it("re-add after remove works", function()
      local idx = II.new()
      idx:add("a", "hello world")
      idx:remove("a")
      idx:add("a", "hello universe")
      local results = idx:search("universe")
      T.eq(#results, 1)
      T.eq(results[1].id, "a")
      -- old text should be gone
      local r2 = idx:search("world")
      T.eq(#r2, 0)
    end)
  end)

  T.describe("doc_count and term_count", function()
    T.it("empty index has 0 docs and 0 terms", function()
      local idx = II.new()
      T.eq(idx:doc_count(), 0)
      T.eq(idx:term_count(), 0)
    end)

    T.it("doc_count increments with add", function()
      local idx = II.new()
      idx:add("a", "hello")
      T.eq(idx:doc_count(), 1)
      idx:add("b", "world")
      T.eq(idx:doc_count(), 2)
    end)

    T.it("term_count reflects distinct terms", function()
      local idx = II.new()
      idx:add("a", "alpha beta gamma")
      T.eq(idx:term_count(), 3)
      idx:add("b", "alpha delta")  -- 'alpha' already exists
      T.eq(idx:term_count(), 4)
    end)

    T.it("terms_for returns terms in doc", function()
      local idx = II.new()
      idx:add("a", "hello world hello")
      local terms = idx:terms_for("a")
      table.sort(terms)
      T.eq(#terms, 2)
      T.eq(terms[1], "hello")
      T.eq(terms[2], "world")
    end)

    T.it("terms_for nonexistent doc returns nil + error", function()
      local idx = II.new()
      local result, err = idx:terms_for("nope")
      T.eq(result, nil)
      T.ok(err ~= nil)
    end)
  end)

  T.describe("add_all", function()
    T.it("adds multiple docs", function()
      local idx = II.new()
      idx:add_all({
        { "x", "foo bar baz" },
        { "y", "qux quux" },
        { "z", "foo qux" },
      })
      T.eq(idx:doc_count(), 3)
      local r = idx:search("foo")
      T.eq(#r, 2)
    end)
  end)

  T.describe("serialize/deserialize", function()
    T.it("round-trip preserves search results", function()
      local idx = II.new()
      idx:add("a", "the quick brown fox")
      idx:add("b", "the lazy dog sleeps")
      idx:add("c", "quick fox runs fast")

      local r1 = idx:search("quick fox")

      local t   = idx:serialize()
      local idx2 = II.deserialize(t)

      local r2 = idx2:search("quick fox")

      T.eq(#r1, #r2)
      for i = 1, #r1 do
        T.eq(r1[i].id, r2[i].id)
        -- scores should be identical
        T.eq(r1[i].score, r2[i].score)
      end
    end)

    T.it("round-trip preserves doc_count and term_count", function()
      local idx = II.new()
      idx:add("a", "hello world")
      idx:add("b", "foo bar")
      local t    = idx:serialize()
      local idx2 = II.deserialize(t)
      T.eq(idx2:doc_count(), idx:doc_count())
      T.eq(idx2:term_count(), idx:term_count())
    end)

    T.it("round-trip preserves BM25 params", function()
      local idx = II.new({ k1 = 1.2, b = 0.5 })
      idx:add("a", "hello world")
      local t    = idx:serialize()
      local idx2 = II.deserialize(t)
      T.eq(idx2.k1, 1.2)
      T.eq(idx2.b,  0.5)
    end)

    T.it("round-trip preserves phrase search", function()
      local idx = II.new()
      idx:add("a", "quick brown fox")
      idx:add("b", "brown quick fox")
      local t    = idx:serialize()
      local idx2 = II.deserialize(t)
      local r = idx2:phrase_search("quick brown")
      T.eq(#r, 1)
      T.eq(r[1].id, "a")
    end)
  end)

  T.describe("custom tokenizer", function()
    T.it("custom tokenizer is used for add and search", function()
      -- tokenizer that splits on whitespace and upcases
      local function upper_tok(text)
        local tokens = {}
        for w in text:gmatch("%S+") do
          tokens[#tokens + 1] = w:upper()
        end
        return tokens
      end
      local idx = II.new({ tokenize = upper_tok })
      idx:add("a", "Hello World")
      idx:add("b", "hello darkness")
      -- search with same tokenizer: "Hello" -> "HELLO"
      local r = idx:search("Hello")
      -- 'HELLO' matches doc a but not doc b (b has "hello" -> "HELLO" too)
      T.eq(#r, 2)
      -- both should be found since upper_tok("hello darkness") -> {"HELLO","DARKNESS"}
      local ra = find(r, "a")
      local rb = find(r, "b")
      T.ok(ra ~= nil)
      T.ok(rb ~= nil)
    end)

    T.it("custom stemmer is applied", function()
      local function simple_stem(t)
        -- strip trailing 's'
        return t:gsub("s$", "")
      end
      local idx = II.new({ stem = simple_stem })
      idx:add("a", "cats dogs")
      idx:add("b", "cat dog")
      -- 'cats' -> 'cat', 'cat' -> 'cat' — same stem
      local r = idx:search("cats")
      -- Both docs should match (stemmed to 'cat')
      T.eq(#r, 2)
    end)
  end)

  T.describe("limit (top-K)", function()
    T.it("limit truncates results to top K", function()
      local idx = II.new()
      for i = 1, 20 do
        idx:add(i, string.rep("term ", i) .. "filler")
      end
      local results = idx:search("term", { limit = 5 })
      T.eq(#results, 5)
    end)

    T.it("results with limit are top-K by score", function()
      local idx = II.new()
      for i = 1, 10 do
        idx:add(i, string.rep("term ", i))
      end
      local all     = idx:search("term")
      local limited = idx:search("term", { limit = 3 })
      T.eq(#limited, 3)
      -- limited should equal first 3 of all
      for i = 1, 3 do
        T.eq(limited[i].id, all[i].id)
      end
    end)

    T.it("limit larger than result count returns all", function()
      local idx = II.new()
      idx:add("a", "hello")
      idx:add("b", "hello world")
      local results = idx:search("hello", { limit = 100 })
      T.eq(#results, 2)
    end)
  end)

  T.describe("_tier", function()
    T.it("_tier is pure", function()
      T.eq(II._tier, "pure")
    end)
  end)

end)
