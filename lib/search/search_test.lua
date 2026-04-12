if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local S = require("lib.search")

local describe, it = T.describe, T.it

describe("search.tokenize", function()
  it("splits on non-alphanumeric and lowercases", function()
    local tokens = S.tokenize("Hello, World! Foo-Bar")
    T.eq(#tokens, 4)
    T.eq(tokens[1], "hello")
    T.eq(tokens[2], "world")
    T.eq(tokens[3], "foo")
    T.eq(tokens[4], "bar")
  end)

  it("handles empty string", function()
    T.eq(#S.tokenize(""), 0)
  end)
end)

describe("search.stem", function()
  it("removes -ing", function()
    T.eq(S.stem("running"), "run")
  end)

  it("removes -ed", function()
    T.eq(S.stem("stopped"), "stop")
  end)

  it("removes trailing -s", function()
    T.eq(S.stem("cats"), "cat")
  end)

  it("removes -ly", function()
    T.eq(S.stem("quickly"), "quick")
  end)

  it("leaves short words unchanged", function()
    T.eq(S.stem("run"), "run")
    T.eq(S.stem("be"), "be")
  end)
end)

describe("search.highlight", function()
  it("wraps matched terms in mark tags", function()
    local out = S.highlight("hello world", { "world" })
    T.eq(out, "hello <mark>world</mark>")
  end)

  it("uses custom tags", function()
    local out = S.highlight("foo bar baz", { "foo", "baz" }, { open = "[", close = "]" })
    T.eq(out, "[foo] bar [baz]")
  end)

  it("is case insensitive for matching", function()
    local out = S.highlight("Hello World", { "hello" })
    T.eq(out, "<mark>Hello</mark> World")
  end)

  it("leaves non-matching text unchanged", function()
    T.eq(S.highlight("no match here", { "xyz" }), "no match here")
  end)
end)

describe("search index: add/search", function()
  it("finds a document by term", function()
    local idx = S.index()
    idx:add("doc1", "the quick brown fox")
    local r = idx:search(S.term("fox"))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc1")
  end)

  it("stop words are filtered out", function()
    local idx = S.index()
    idx:add("doc1", "the quick brown fox")
    -- 'the' is a stop word and should not be indexed
    local r = idx:search(S.term("the"))
    T.eq(r.total, 0)
  end)

  it("returns empty results when no match", function()
    local idx = S.index()
    idx:add("doc1", "hello world")
    local r = idx:search(S.term("xyz"))
    T.eq(r.total, 0)
    T.eq(#r.results, 0)
  end)

  it("returns multiple results", function()
    local idx = S.index()
    idx:add("doc1", "lua is great")
    idx:add("doc2", "lua programming rocks")
    idx:add("doc3", "python is nice")
    local r = idx:search(S.term("lua"))
    T.eq(r.total, 2)
  end)

  it("limit and offset work", function()
    local idx = S.index()
    for i = 1, 5 do
      idx:add("d" .. i, "lua document number " .. i)
    end
    local r1 = idx:search(S.term("lua"), { limit = 2 })
    T.eq(#r1.results, 2)
    T.eq(r1.total, 5)

    local r2 = idx:search(S.term("lua"), { limit = 2, offset = 2 })
    T.eq(#r2.results, 2)
    -- Different results due to offset
    T.ok(r1.results[1].id ~= r2.results[1].id or r1.results[2].id ~= r2.results[2].id,
      "offset should return different documents")
  end)
end)

describe("search index: TF-IDF scoring", function()
  it("more frequent term in fewer docs scores higher", function()
    local idx = S.index()
    -- doc1: 'lua' appears 3 times in a short doc
    idx:add("doc1", "lua lua lua rocks")
    -- doc2: 'lua' appears once in a long doc with many other words
    idx:add("doc2", "lua python ruby java go swift kotlin scala clojure haskell")

    local r = idx:search(S.term("lua"), { scorer = "tfidf" })
    T.eq(r.total, 2)
    -- doc1 has higher tf, so it should score higher
    T.eq(r.results[1].id, "doc1")
  end)
end)

describe("search index: BM25 scoring", function()
  it("correct relative ordering", function()
    local idx = S.index()
    -- doc_many: 'search' appears many times
    idx:add("doc_many", "search search search search engine for searching search results")
    -- doc_few: 'search' appears once
    idx:add("doc_few", "search engine comparison")
    -- doc_none: 'search' does not appear
    idx:add("doc_none", "database management system")

    local r = idx:search(S.term("search"), { scorer = "bm25" })
    T.eq(r.total, 2)
    T.eq(r.results[1].id, "doc_many")
    T.eq(r.results[2].id, "doc_few")
  end)

  it("custom k1 and b parameters are used", function()
    local idx = S.index({ bm25_k1 = 2.0, bm25_b = 0.5 })
    idx:add("d1", "test test test")
    idx:add("d2", "test")
    local r = idx:search(S.term("test"), { scorer = "bm25" })
    T.eq(r.total, 2)
    T.eq(r.results[1].id, "d1")
  end)
end)

describe("search index: phrase search", function()
  it("finds adjacent terms in order", function()
    local idx = S.index()
    idx:add("doc1", "quick brown fox jumped")
    idx:add("doc2", "brown quick fox jumped")
    local r = idx:search(S.phrase({ "quick", "brown" }))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc1")
  end)

  it("does not match non-adjacent terms", function()
    local idx = S.index()
    idx:add("doc1", "hello world goodbye")
    local r = idx:search(S.phrase({ "hello", "goodbye" }))
    T.eq(r.total, 0)
  end)

  it("matches exact phrase with multiple words", function()
    local idx = S.index()
    -- Use stop_words={} so 'on' is not filtered
    local idx2 = S.index({ stop_words = {} })
    idx2:add("doc1", "cat sat on mat")
    idx2:add("doc2", "cat sat under mat")
    local r = idx2:search(S.phrase({ "cat", "sat", "on" }))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc1")
  end)

  it("single word phrase works like term query", function()
    local idx = S.index()
    idx:add("doc1", "hello world")
    local r = idx:search(S.phrase({ "hello" }))
    T.eq(r.total, 1)
  end)
end)

describe("search index: boolean queries", function()
  it("AND: intersection of posting lists", function()
    local idx = S.index()
    idx:add("doc1", "lua rocks")
    idx:add("doc2", "lua python")
    idx:add("doc3", "ruby python")
    local r = idx:search(S.boolean("and", { S.term("lua"), S.term("python") }))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc2")
  end)

  it("OR: union of posting lists", function()
    local idx = S.index()
    idx:add("doc1", "lua rocks")
    idx:add("doc2", "python rules")
    idx:add("doc3", "ruby gems")
    local r = idx:search(S.boolean("or", { S.term("lua"), S.term("python") }))
    T.eq(r.total, 2)
    local ids = {}
    for _, res in ipairs(r.results) do ids[res.id] = true end
    T.ok(ids["doc1"])
    T.ok(ids["doc2"])
    T.ok(not ids["doc3"])
  end)

  it("NOT: exclusion from all docs", function()
    local idx = S.index()
    idx:add("doc1", "lua rocks")
    idx:add("doc2", "python rules")
    idx:add("doc3", "ruby gems")
    -- NOT lua: all docs except doc1
    local r = idx:search(S.boolean("not", { S.term("lua") }))
    local ids = {}
    for _, res in ipairs(r.results) do ids[res.id] = true end
    T.ok(not ids["doc1"], "doc1 should be excluded")
    T.ok(ids["doc2"])
    T.ok(ids["doc3"])
  end)

  it("AND with three terms", function()
    local idx = S.index()
    idx:add("doc1", "foo bar baz")
    idx:add("doc2", "foo bar")
    idx:add("doc3", "foo baz")
    local r = idx:search(S.boolean("and", { S.term("foo"), S.term("bar"), S.term("baz") }))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc1")
  end)

  it("nested boolean queries", function()
    local idx = S.index()
    idx:add("doc1", "lua rocks fast")
    idx:add("doc2", "python rocks slow")
    idx:add("doc3", "ruby gems nice")
    -- (lua OR python) AND rocks
    local r = idx:search(
      S.boolean("and", {
        S.boolean("or", { S.term("lua"), S.term("python") }),
        S.term("rocks"),
      })
    )
    T.eq(r.total, 2)
    local ids = {}
    for _, res in ipairs(r.results) do ids[res.id] = true end
    T.ok(ids["doc1"])
    T.ok(ids["doc2"])
  end)
end)

describe("search index: fuzzy search", function()
  it("finds typo variants within edit distance 1", function()
    local idx = S.index()
    idx:add("doc1", "hello world")
    idx:add("doc2", "python rules")
    -- 'helo' is distance 1 from 'hello'
    local r = idx:search(S.fuzzy("helo", 1))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc1")
  end)

  it("finds exact match at distance 0", function()
    local idx = S.index()
    idx:add("doc1", "hello world")
    local r = idx:search(S.fuzzy("hello", 0))
    T.eq(r.total, 1)
  end)

  it("finds variants within edit distance 2", function()
    local idx = S.index()
    idx:add("doc1", "programming languages")
    -- 'progrmming' is distance 1 from 'programming'
    local r = idx:search(S.fuzzy("progrmming", 2))
    T.eq(r.total, 1)
  end)

  it("does not match beyond max_dist", function()
    local idx = S.index()
    idx:add("doc1", "elephant")
    -- 'dog' is very different from 'elephant'
    local r = idx:search(S.fuzzy("dog", 1))
    T.eq(r.total, 0)
  end)
end)

describe("search index: prefix query", function()
  it("finds all terms starting with prefix", function()
    local idx = S.index()
    idx:add("doc1", "programming rocks")
    idx:add("doc2", "programs are fun")
    idx:add("doc3", "python is great")
    local r = idx:search(S.prefix("prog"))
    T.eq(r.total, 2)
    local ids = {}
    for _, res in ipairs(r.results) do ids[res.id] = true end
    T.ok(ids["doc1"])
    T.ok(ids["doc2"])
    T.ok(not ids["doc3"])
  end)

  it("empty prefix matches everything", function()
    local idx = S.index()
    idx:add("doc1", "foo")
    idx:add("doc2", "bar")
    local r = idx:search(S.prefix(""))
    T.ok(r.total >= 2)
  end)
end)

describe("search index: wildcard query", function()
  it("? matches single character", function()
    local idx = S.index()
    idx:add("doc1", "cat bat rat")
    -- ?at matches cat, bat, rat
    local r = idx:search(S.wildcard("?at"))
    T.eq(r.total, 1)  -- all in same doc
  end)

  it("* matches any sequence", function()
    local idx = S.index()
    idx:add("doc1", "programming")
    idx:add("doc2", "programs")
    idx:add("doc3", "python")
    local r = idx:search(S.wildcard("prog*"))
    T.eq(r.total, 2)
    local ids = {}
    for _, res in ipairs(r.results) do ids[res.id] = true end
    T.ok(ids["doc1"])
    T.ok(ids["doc2"])
  end)

  it("*word* finds substrings", function()
    local idx = S.index()
    idx:add("doc1", "uncomfortable truth")
    idx:add("doc2", "comfort zone")
    idx:add("doc3", "python")
    local r = idx:search(S.wildcard("*comfort*"))
    T.eq(r.total, 2)
  end)
end)

describe("search index: remove", function()
  it("doc no longer appears in results after remove", function()
    local idx = S.index()
    idx:add("doc1", "lua rocks")
    idx:add("doc2", "lua rules")
    T.eq(idx:search(S.term("lua")).total, 2)
    idx:remove("doc1")
    local r = idx:search(S.term("lua"))
    T.eq(r.total, 1)
    T.eq(r.results[1].id, "doc2")
  end)

  it("remove non-existent doc is a no-op", function()
    local idx = S.index()
    idx:add("doc1", "hello")
    idx:remove("does_not_exist")
    T.eq(idx:search(S.term("hello")).total, 1)
  end)
end)

describe("search index: update", function()
  it("updated doc reflects new content", function()
    local idx = S.index()
    idx:add("doc1", "hello world")
    T.eq(idx:search(S.term("hello")).total, 1)
    T.eq(idx:search(S.term("goodbye")).total, 0)
    idx:update("doc1", "goodbye world")
    T.eq(idx:search(S.term("hello")).total, 0)
    T.eq(idx:search(S.term("goodbye")).total, 1)
  end)

  it("add with existing id is treated as update", function()
    local idx = S.index()
    idx:add("doc1", "foo bar")
    idx:add("doc1", "baz qux")
    T.eq(idx:search(S.term("foo")).total, 0)
    T.eq(idx:search(S.term("baz")).total, 1)
  end)
end)

describe("search index: facet", function()
  it("counts by field value", function()
    local idx = S.index()
    idx:add("doc1", "apple fruit", { fields = { category = "fruit" } })
    idx:add("doc2", "banana fruit", { fields = { category = "fruit" } })
    idx:add("doc3", "carrot vegetable", { fields = { category = "vegetable" } })
    idx:add("doc4", "broccoli vegetable", { fields = { category = "vegetable" } })
    local counts = idx:facet(S.boolean("or", { S.term("fruit"), S.term("vegetable") }), "category")
    T.eq(counts["fruit"], 2)
    T.eq(counts["vegetable"], 2)
  end)

  it("facet on empty results returns empty table", function()
    local idx = S.index()
    idx:add("doc1", "hello", { fields = { cat = "x" } })
    local counts = idx:facet(S.term("nonexistent"), "cat")
    local n = 0
    for _ in pairs(counts) do n = n + 1 end
    T.eq(n, 0)
  end)

  it("facet with partial fields coverage", function()
    local idx = S.index()
    idx:add("doc1", "foo bar", { fields = { tag = "a" } })
    idx:add("doc2", "foo baz")  -- no fields
    local counts = idx:facet(S.term("foo"), "tag")
    T.eq(counts["a"], 1)
    -- doc2 has no fields, so nothing counted for it
    local n = 0
    for _ in pairs(counts) do n = n + 1 end
    T.eq(n, 1)
  end)
end)

describe("search index: explain/highlight", function()
  it("highlight wraps matched terms in results", function()
    local idx = S.index()
    idx:add("doc1", "the quick brown fox")
    local r = idx:search(S.term("quick"), { explain = true })
    T.eq(r.total, 1)
    local res = r.results[1]
    T.ok(res.highlights, "expected highlights")
    T.ok(#res.highlights >= 1)
    local snippet = res.highlights[1].snippet
    T.ok(snippet:find("<mark>quick</mark>"), "expected <mark>quick</mark> in snippet")
  end)
end)

describe("search index: custom tokenizer", function()
  it("uses provided tokenizer", function()
    local idx = S.index({
      tokenize = function(text)
        -- only split on spaces
        local tokens = {}
        for w in text:gmatch("%S+") do tokens[#tokens + 1] = w end
        return tokens
      end,
      stop_words = {},
    })
    idx:add("doc1", "Hello World")
    -- custom tokenizer preserves case; the stop_words are empty
    local r = idx:search(S.term("hello world"))
    -- 'hello world' won't match since tokens are 'Hello' and 'World' (no lowercase)
    -- but we can search for exact token
    local r2 = idx:search(S.term("hello"))
    T.eq(r2.total, 0)  -- 'Hello' != 'hello' in custom tokenizer
  end)
end)

describe("search index: edge cases", function()
  it("empty index returns no results", function()
    local idx = S.index()
    local r = idx:search(S.term("anything"))
    T.eq(r.total, 0)
  end)

  it("boolean with invalid op", function()
    local q, err = S.boolean("xor", {})
    T.ok(q == nil)
    T.ok(err ~= nil)
  end)

  it("multiple removes don't corrupt index", function()
    local idx = S.index()
    idx:add("doc1", "foo bar")
    idx:add("doc2", "foo baz")
    idx:remove("doc1")
    idx:remove("doc1")  -- double-remove
    T.eq(idx:search(S.term("foo")).total, 1)
  end)
end)
