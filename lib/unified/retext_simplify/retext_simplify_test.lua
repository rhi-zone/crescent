-- lib/unified/retext_simplify/retext_simplify_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_simplify")

T.describe("retext_simplify", function()
  T.it("populates root.data.simplify", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Please utilize this feature.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.simplify ~= nil, "simplify key exists")
    T.ok(type(tree.data.simplify) == "table", "simplify is table")
  end)

  T.it("flags 'utilize' and suggests 'use'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Please utilize this feature.")
    tree = proc:run(tree)
    local s = tree.data.simplify
    T.ok(#s > 0, "at least one suggestion")
    T.eq(s[1].word:lower(), "utilize", "word is 'utilize'")
    T.eq(s[1].suggestion, "use", "suggestion is 'use'")
  end)

  T.it("returns empty for simple text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat sat on the mat.")
    tree = proc:run(tree)
    T.eq(#tree.data.simplify, 0, "no suggestions for simple text")
  end)

  T.it("flags multiple words in one sentence", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Please commence and terminate the process.")
    tree = proc:run(tree)
    local s = tree.data.simplify
    T.ok(#s >= 2, "at least 2 suggestions")
  end)

  T.it("each finding has word, suggestion, and sentence fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("We need to facilitate this process.")
    tree = proc:run(tree)
    local s = tree.data.simplify
    T.ok(#s > 0, "at least one finding")
    T.ok(type(s[1].word) == "string", "word is string")
    T.ok(type(s[1].suggestion) == "string", "suggestion is string")
    T.ok(type(s[1].sentence) == "string", "sentence is string")
  end)

  T.it("is case-insensitive for lookups", function()
    local proc = retext():use(plugin.plugin)
    -- "Utilize" with capital U.
    local tree = proc:parse("Utilize the available resources.")
    tree = proc:run(tree)
    local s = tree.data.simplify
    T.ok(#s > 0, "case-insensitive match")
    T.eq(s[1].suggestion, "use")
  end)

  T.it("flags 'numerous' suggesting 'many'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("There are numerous reasons to do this.")
    tree = proc:run(tree)
    local found = false
    for _, entry in ipairs(tree.data.simplify) do
      if entry.word:lower() == "numerous" then found = true end
    end
    T.ok(found, "'numerous' flagged")
  end)
end)
