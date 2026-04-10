-- lib/unified/retext_intensify/retext_intensify_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_intensify")

T.describe("retext_intensify", function()
  T.it("populates root.data.intensify", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("This is very good.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.intensify ~= nil, "intensify key exists")
    T.ok(type(tree.data.intensify) == "table", "is table")
  end)

  T.it("flags 'very'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("This is very good.")
    tree = proc:run(tree)
    local iv = tree.data.intensify
    T.ok(#iv > 0, "at least one weasel word")
    local found = false
    for _, e in ipairs(iv) do
      if e.word == "very" then found = true end
    end
    T.ok(found, "'very' flagged")
  end)

  T.it("flags multiple weasel words", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("It is really quite good.")
    tree = proc:run(tree)
    T.ok(#tree.data.intensify >= 2, "at least 2 weasel words")
  end)

  T.it("returns empty for clean text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat sat on the mat.")
    tree = proc:run(tree)
    T.eq(#tree.data.intensify, 0, "no weasel words in clean text")
  end)

  T.it("respects opts.ignore", function()
    local proc = retext():use(function(processor)
      plugin.plugin(processor, { ignore = { "very", "really" } })
    end)
    local tree = proc:parse("It is very really good.")
    tree = proc:run(tree)
    T.eq(#tree.data.intensify, 0, "ignored words not flagged")
  end)

  T.it("each finding has word and sentence fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("It is basically fine.")
    tree = proc:run(tree)
    local iv = tree.data.intensify
    T.ok(#iv > 0, "finding exists")
    T.ok(type(iv[1].word) == "string", "word is string")
    T.ok(type(iv[1].sentence) == "string", "sentence is string")
  end)

  T.it("is case-insensitive", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("This is Very important.")
    tree = proc:run(tree)
    local found = false
    for _, e in ipairs(tree.data.intensify) do
      if e.word == "very" then found = true end
    end
    T.ok(found, "case-insensitive match for Very")
  end)
end)
