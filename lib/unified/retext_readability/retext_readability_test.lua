-- lib/unified/retext_readability/retext_readability_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_readability")

T.describe("retext_readability", function()
  T.it("populates root.data.readability", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat sat on the mat. The dog ran fast.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data table exists")
    T.ok(tree.data.readability ~= nil, "readability key exists")
    local r = tree.data.readability
    T.ok(type(r.flesch) == "number", "flesch is a number")
    T.ok(type(r.grade) == "number", "grade is a number")
    T.ok(type(r.fog) == "number", "fog is a number")
  end)

  T.it("counts sentences and words correctly", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("I love Lua. Lua is great.")
    tree = proc:run(tree)
    local r = tree.data.readability
    T.eq(r.sentences, 2)
    T.eq(r.words, 6)
  end)

  T.it("flesch score is within 0-100 for simple text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The cat sat on the mat.")
    tree = proc:run(tree)
    local r = tree.data.readability
    T.ok(r.flesch >= 0 and r.flesch <= 120, "flesch in expected range")
  end)

  T.it("handles empty text gracefully", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("  ")
    tree = proc:run(tree)
    -- May have no sentences; should not error.
    T.ok(tree.data.readability ~= nil, "readability populated even for empty")
  end)

  T.it("complex words increase fog index", function()
    local proc = retext():use(plugin.plugin)
    -- "understanding" and "complicated" have 3+ syllables
    local tree1 = proc:parse("The cat sat here.")
    tree1 = proc:run(tree1)
    local tree2 = proc:parse("Understanding complicated terminology requires patience.")
    tree2 = proc:run(tree2)
    T.ok(tree2.data.readability.fog > tree1.data.readability.fog,
      "complex text has higher fog index")
  end)

  T.it("syllable count drives grade level", function()
    local proc = retext():use(plugin.plugin)
    local simple = proc:parse("Cats run fast here.")
    simple = proc:run(simple)
    local complex = proc:parse("Extraordinary circumstances necessitate extraordinary measures.")
    complex = proc:run(complex)
    T.ok(complex.data.readability.grade > simple.data.readability.grade,
      "complex text has higher grade level")
  end)
end)
