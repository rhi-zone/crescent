-- lib/unified/retext_keywords/retext_keywords_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_keywords")

T.describe("retext_keywords", function()
  T.it("populates root.data.keywords", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Lua is fast. Lua is fun. Lua is great.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.keywords ~= nil, "keywords key exists")
    T.ok(type(tree.data.keywords) == "table", "keywords is a table")
  end)

  T.it("most frequent non-stopword is first", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Lua is fast. Lua is fun. Lua is great. Python is slow.")
    tree = proc:run(tree)
    local kw = tree.data.keywords
    T.ok(#kw > 0, "at least one keyword")
    T.eq(kw[1].word, "lua", "lua is the top keyword")
    T.eq(kw[1].count, 3, "lua appears 3 times")
  end)

  T.it("filters stopwords", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat and the dog and the bird.")
    tree = proc:run(tree)
    local kw = tree.data.keywords
    -- 'the', 'and' are stopwords; cat, dog, bird should appear
    for _, k in ipairs(kw) do
      T.ok(k.word ~= "the" and k.word ~= "and", "stopword not in keywords: " .. k.word)
    end
  end)

  T.it("respects maximum option", function()
    local proc = retext():use(function(p) plugin.plugin(p, { maximum = 2 }) end)
    local tree = proc:parse(
      "apple banana cherry date elderberry fig grape honeydew kiwi lemon mango")
    tree = proc:run(tree)
    T.ok(#tree.data.keywords <= 2, "at most 2 keywords returned")
  end)

  T.it("returns empty table for all-stopword text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The a an is are was were.")
    tree = proc:run(tree)
    T.eq(#tree.data.keywords, 0, "no keywords for stopword-only text")
  end)

  T.it("entries have word and count fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Lua rocks. Lua is great.")
    tree = proc:run(tree)
    local kw = tree.data.keywords
    T.ok(#kw > 0, "has keywords")
    T.ok(type(kw[1].word) == "string", "word is string")
    T.ok(type(kw[1].count) == "number", "count is number")
  end)
end)
