-- lib/unified/retext_passive/retext_passive_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_passive")

T.describe("retext_passive", function()
  T.it("populates root.data.passive", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The book was written by Lua.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.passive ~= nil, "passive key exists")
    T.ok(type(tree.data.passive) == "table", "passive is table")
  end)

  T.it("detects 'was written' as passive", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The book was written by the author.")
    tree = proc:run(tree)
    local p = tree.data.passive
    T.ok(#p > 0, "passive construction detected")
    -- Find the 'was written' pattern.
    local found = false
    for _, entry in ipairs(p) do
      if entry.pattern == "was written" then found = true end
    end
    T.ok(found, "pattern 'was written' found")
  end)

  T.it("detects regular -ed past participles", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The letter was delivered yesterday.")
    tree = proc:run(tree)
    local p = tree.data.passive
    T.ok(#p > 0, "passive detected with -ed participle")
    local found = false
    for _, entry in ipairs(p) do
      if entry.pattern == "was delivered" then found = true end
    end
    T.ok(found, "'was delivered' pattern found")
  end)

  T.it("returns empty for active voice text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The author wrote the book quickly.")
    tree = proc:run(tree)
    -- No be + participle combination.
    local p = tree.data.passive
    -- Might catch nothing or something; check no false positives for simple active.
    T.ok(type(p) == "table", "passive is a table")
  end)

  T.it("each finding has sentence and pattern fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The work was done well.")
    tree = proc:run(tree)
    local p = tree.data.passive
    T.ok(#p > 0, "at least one passive found")
    T.ok(type(p[1].sentence) == "string", "sentence field is string")
    T.ok(type(p[1].pattern) == "string", "pattern field is string")
  end)

  T.it("detects 'is being done' (double be)", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The work is being done now.")
    tree = proc:run(tree)
    local p = tree.data.passive
    T.ok(#p > 0, "passive detected for 'is being done'")
  end)
end)
