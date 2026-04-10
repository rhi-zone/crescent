-- lib/unified/retext_repeated_words/retext_repeated_words_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_repeated_words")

T.describe("retext_repeated_words", function()
  T.it("populates root.data.repeated_words", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The the cat sat.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.repeated_words ~= nil, "repeated_words key exists")
    T.ok(type(tree.data.repeated_words) == "table", "repeated_words is table")
  end)

  T.it("detects 'the the' repetition", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The the cat sat on the mat.")
    tree = proc:run(tree)
    local rw = tree.data.repeated_words
    T.ok(#rw > 0, "at least one repeated word")
    T.eq(rw[1].word, "the", "word is 'the'")
  end)

  T.it("is case-insensitive", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Is IS this right?")
    tree = proc:run(tree)
    local rw = tree.data.repeated_words
    T.ok(#rw > 0, "case-insensitive match")
    T.eq(rw[1].word, "is")
  end)

  T.it("returns empty for normal text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat sat on the mat.")
    tree = proc:run(tree)
    T.eq(#tree.data.repeated_words, 0, "no repeats in normal text")
  end)

  T.it("punctuation between words prevents detection", function()
    local proc = retext():use(plugin.plugin)
    -- Comma resets the chain so "word , word" should not fire.
    local tree = proc:parse("This is great, great work.")
    tree = proc:run(tree)
    T.eq(#tree.data.repeated_words, 0, "comma between words is not a repeat")
  end)

  T.it("each finding has word and sentence fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("It is is true.")
    tree = proc:run(tree)
    local rw = tree.data.repeated_words
    T.ok(#rw > 0, "repeat found")
    T.ok(type(rw[1].word) == "string", "word is string")
    T.ok(type(rw[1].sentence) == "string", "sentence is string")
  end)
end)
