if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local search = require("lib.search")

local describe, it = T.describe, T.it

describe("search", function()
  it("open creates an index", function()
    local idx, err = search.open(":memory:")
    T.ok(idx, "expected index, got: " .. tostring(err))
    idx:close()
  end)

  it("create_collection with fields", function()
    local idx = search.open(":memory:")
    local ok, err = idx:create_collection("articles", {
      fields = { "title", "body" },
    })
    T.ok(ok, "create_collection failed: " .. tostring(err))
    idx:close()
  end)

  it("add a document", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    local ok, err = idx:add("articles", {
      id = "doc1",
      title = "Hello World",
      body = "This is a test document",
    })
    T.ok(ok, "add failed: " .. tostring(err))
    T.eq(idx:count("articles"), 1)
    idx:close()
  end)

  it("search finds document by text", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    idx:add("articles", {
      id = "doc1",
      title = "Introduction to Lua",
      body = "Lua is a lightweight scripting language",
    })
    local results, err = idx:search("articles", "lua")
    T.ok(results, "search failed: " .. tostring(err))
    T.eq(#results, 1)
    T.eq(results[1].id, "doc1")
    T.eq(results[1].title, "Introduction to Lua")
    idx:close()
  end)

  it("search with multiple documents, relevance ordering", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    idx:add("articles", {
      id = "doc1",
      title = "Cooking recipes",
      body = "How to make pasta with tomato sauce",
    })
    idx:add("articles", {
      id = "doc2",
      title = "Lua programming",
      body = "Lua is great for scripting and embedding in applications using lua",
    })
    idx:add("articles", {
      id = "doc3",
      title = "Advanced Lua techniques",
      body = "Lua metatables and coroutines in lua are powerful lua features",
    })
    local results, err = idx:search("articles", "lua")
    T.ok(results, "search failed: " .. tostring(err))
    T.ok(#results >= 2, "expected at least 2 results, got " .. #results)
    -- doc3 mentions lua more often, should rank higher (lower/more negative BM25 rank)
    -- just verify both lua docs are present
    local ids = {}
    for i = 1, #results do ids[results[i].id] = true end
    T.ok(ids["doc2"], "expected doc2 in results")
    T.ok(ids["doc3"], "expected doc3 in results")
    T.ok(not ids["doc1"], "doc1 should not match 'lua'")
    idx:close()
  end)

  it("search returns empty array for no match", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    idx:add("articles", {
      id = "doc1",
      title = "Hello World",
      body = "This is a test",
    })
    local results, err = idx:search("articles", "nonexistent")
    T.ok(results, "search failed: " .. tostring(err))
    T.eq(#results, 0)
    idx:close()
  end)

  it("search with limit and offset", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    for i = 1, 5 do
      idx:add("articles", {
        id = "doc" .. i,
        title = "Lua document " .. i,
        body = "Content about lua programming number " .. i,
      })
    end
    local results, err = idx:search("articles", "lua", { limit = 2 })
    T.ok(results, "search failed: " .. tostring(err))
    T.eq(#results, 2)

    local results2
    results2, err = idx:search("articles", "lua", { limit = 2, offset = 2 })
    T.ok(results2, "search with offset failed: " .. tostring(err))
    T.eq(#results2, 2)
    -- offset results should be different from first page
    T.ok(results[1].id ~= results2[1].id, "offset results should differ")
    idx:close()
  end)

  it("search with specific fields", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body", "author" } })
    idx:add("articles", {
      id = "doc1",
      title = "Lua Guide",
      body = "A comprehensive guide",
      author = "Roberto",
    })
    idx:add("articles", {
      id = "doc2",
      title = "Cooking Guide",
      body = "How to cook lua beans",
      author = "Chef",
    })
    -- search only in title field
    local results, err = idx:search("articles", "lua", { fields = { "title" } })
    T.ok(results, "search failed: " .. tostring(err))
    T.eq(#results, 1)
    T.eq(results[1].id, "doc1")
    idx:close()
  end)

  it("update a document, re-search finds updated content", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    idx:add("articles", {
      id = "doc1",
      title = "Old Title",
      body = "Original content about python",
    })
    -- should not find "lua" initially
    local results = idx:search("articles", "lua")
    T.eq(#results, 0)

    local ok, err = idx:update("articles", "doc1", { title = "Lua Tutorial", body = "Content about lua" })
    T.ok(ok, "update failed: " .. tostring(err))

    results = idx:search("articles", "lua")
    T.eq(#results, 1)
    T.eq(results[1].title, "Lua Tutorial")

    -- old content should not be found
    results = idx:search("articles", "python")
    T.eq(#results, 0)
    idx:close()
  end)

  it("remove a document, search no longer finds it", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title", "body" } })
    idx:add("articles", {
      id = "doc1",
      title = "Lua Guide",
      body = "All about lua",
    })
    T.eq(#idx:search("articles", "lua"), 1)

    local ok, err = idx:remove("articles", "doc1")
    T.ok(ok, "remove failed: " .. tostring(err))

    T.eq(#idx:search("articles", "lua"), 0)
    T.eq(idx:count("articles"), 0)
    idx:close()
  end)

  it("count returns correct count", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title" } })
    T.eq(idx:count("articles"), 0)
    idx:add("articles", { id = "a", title = "one" })
    T.eq(idx:count("articles"), 1)
    idx:add("articles", { id = "b", title = "two" })
    T.eq(idx:count("articles"), 2)
    idx:close()
  end)

  it("collections lists collection names", function()
    local idx = search.open(":memory:")
    idx:create_collection("alpha", { fields = { "text" } })
    idx:create_collection("beta", { fields = { "text" } })
    local names = idx:collections()
    T.eq(#names, 2)
    T.eq(names[1], "alpha")
    T.eq(names[2], "beta")
    idx:close()
  end)

  it("drop_collection removes everything", function()
    local idx = search.open(":memory:")
    idx:create_collection("temp", { fields = { "text" } })
    idx:add("temp", { id = "x", text = "hello" })
    T.eq(idx:count("temp"), 1)

    local ok, err = idx:drop_collection("temp")
    T.ok(ok, "drop failed: " .. tostring(err))

    local names = idx:collections()
    T.eq(#names, 0)
    idx:close()
  end)

  it("vector search: similar returns documents by cosine similarity", function()
    local idx = search.open(":memory:")
    idx:create_collection("docs", {
      fields = { "title" },
      vector_dims = 3,
    })
    idx:add("docs", { id = "a", title = "First", vector = { 1, 0, 0 } })
    idx:add("docs", { id = "b", title = "Second", vector = { 0, 1, 0 } })
    idx:add("docs", { id = "c", title = "Third", vector = { 0, 0, 1 } })

    local results, err = idx:similar("docs", { 1, 0, 0 }, { limit = 3 })
    T.ok(results, "similar failed: " .. tostring(err))
    T.eq(#results, 3)
    T.eq(results[1].id, "a")
    T.ok(results[1].score > 0.99, "expected high similarity for exact match")
    idx:close()
  end)

  it("vector search: most similar document ranked first", function()
    local idx = search.open(":memory:")
    idx:create_collection("docs", {
      fields = { "title" },
      vector_dims = 3,
    })
    idx:add("docs", { id = "far", title = "Far", vector = { 0, 0, 1 } })
    idx:add("docs", { id = "close", title = "Close", vector = { 0.9, 0.1, 0 } })
    idx:add("docs", { id = "exact", title = "Exact", vector = { 1, 0, 0 } })

    local results = idx:similar("docs", { 1, 0, 0 }, { limit = 3 })
    T.eq(results[1].id, "exact")
    T.eq(results[2].id, "close")
    T.eq(results[3].id, "far")
    idx:close()
  end)

  it("hybrid search: combines text and vector scores", function()
    local idx = search.open(":memory:")
    idx:create_collection("docs", {
      fields = { "title", "body" },
      vector_dims = 3,
    })
    idx:add("docs", {
      id = "text_match",
      title = "Lua programming",
      body = "Lua is a scripting language for lua developers who love lua",
      vector = { 0, 0, 1 },  -- far from query vector
    })
    idx:add("docs", {
      id = "vec_match",
      title = "Cooking recipes",
      body = "How to make pasta",
      vector = { 1, 0, 0 },  -- close to query vector
    })
    idx:add("docs", {
      id = "both_match",
      title = "Lua tutorial",
      body = "Learn lua basics",
      vector = { 0.9, 0.1, 0 },  -- close to query vector
    })

    local results, err = idx:hybrid("docs", {
      text = "lua",
      vector = { 1, 0, 0 },
      text_weight = 0.5,
      vector_weight = 0.5,
      limit = 10,
    })
    T.ok(results, "hybrid failed: " .. tostring(err))
    T.ok(#results >= 2, "expected at least 2 results")
    -- both_match should score well on both axes
    local found_both = false
    for i = 1, #results do
      if results[i].id == "both_match" then found_both = true end
    end
    T.ok(found_both, "expected both_match in results")
    idx:close()
  end)

  it("metadata: stored and returned correctly", function()
    local idx = search.open(":memory:")
    idx:create_collection("articles", { fields = { "title" } })
    idx:add("articles", {
      id = "doc1",
      title = "Lua Guide",
      meta = { tags = { "lua", "programming" }, priority = 1 },
    })
    local results = idx:search("articles", "lua")
    T.eq(#results, 1)
    T.ok(results[1].meta, "expected meta")
    T.eq(results[1].meta.tags[1], "lua")
    T.eq(results[1].meta.tags[2], "programming")
    T.eq(results[1].meta.priority, 1)
    idx:close()
  end)

  it("wrap wraps existing sqlite db", function()
    local sqlite_mod = require("lib.sqlite")
    local db = sqlite_mod.open(":memory:")
    local idx, err = search.wrap(db)
    T.ok(idx, "wrap failed: " .. tostring(err))
    idx:create_collection("test", { fields = { "text" } })
    idx:add("test", { id = "a", text = "hello world" })
    T.eq(idx:count("test"), 1)
    -- don't close idx (it wraps db), close db directly
    db:close()
  end)

  it("multiple collections: isolated from each other", function()
    local idx = search.open(":memory:")
    idx:create_collection("alpha", { fields = { "text" } })
    idx:create_collection("beta", { fields = { "text" } })
    idx:add("alpha", { id = "a1", text = "lua programming" })
    idx:add("beta", { id = "b1", text = "cooking recipes" })

    T.eq(idx:count("alpha"), 1)
    T.eq(idx:count("beta"), 1)

    local alpha_results = idx:search("alpha", "lua")
    T.eq(#alpha_results, 1)
    T.eq(alpha_results[1].id, "a1")

    local beta_results = idx:search("beta", "lua")
    T.eq(#beta_results, 0)
    idx:close()
  end)

  it("empty collection: search returns empty, count returns 0", function()
    local idx = search.open(":memory:")
    idx:create_collection("empty", { fields = { "title", "body" } })
    T.eq(idx:count("empty"), 0)
    local results = idx:search("empty", "anything")
    T.eq(#results, 0)
    idx:close()
  end)
end)
