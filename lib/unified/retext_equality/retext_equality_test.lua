-- lib/unified/retext_equality/retext_equality_test.lua
local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local plugin = require("lib.unified.retext_equality")

T.describe("retext_equality", function()
  T.it("populates root.data.equality", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Add the term to the blacklist.")
    tree = proc:run(tree)
    T.ok(tree.data ~= nil, "data exists")
    T.ok(tree.data.equality ~= nil, "equality key exists")
    T.ok(type(tree.data.equality) == "table", "equality is table")
  end)

  T.it("flags 'blacklist' with suggestion 'denylist/blocklist'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Add the term to the blacklist.")
    tree = proc:run(tree)
    local eq = tree.data.equality
    T.ok(#eq > 0, "at least one finding")
    local found = false
    for _, entry in ipairs(eq) do
      if entry.word:lower() == "blacklist" then
        T.eq(entry.suggestion, "denylist/blocklist", "correct suggestion")
        found = true
      end
    end
    T.ok(found, "'blacklist' flagged")
  end)

  T.it("flags 'whitelist' with suggestion 'allowlist'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Add to the whitelist only.")
    tree = proc:run(tree)
    local eq = tree.data.equality
    local found = false
    for _, entry in ipairs(eq) do
      if entry.word:lower() == "whitelist" then
        T.eq(entry.suggestion, "allowlist")
        found = true
      end
    end
    T.ok(found, "'whitelist' flagged")
  end)

  T.it("returns empty for inclusive text", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The primary server connects to the replica.")
    tree = proc:run(tree)
    -- 'primary' and 'replica' are the suggested alternatives, not the flagged terms.
    local eq = tree.data.equality
    T.eq(#eq, 0, "no flags for already-inclusive text")
  end)

  T.it("each finding has word and suggestion fields", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("The master branch needs renaming.")
    tree = proc:run(tree)
    local eq = tree.data.equality
    T.ok(#eq > 0, "at least one finding")
    T.ok(type(eq[1].word) == "string", "word is string")
    T.ok(type(eq[1].suggestion) == "string", "suggestion is string")
  end)

  T.it("is case-insensitive", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("Use the Blacklist feature.")
    tree = proc:run(tree)
    local eq = tree.data.equality
    local found = false
    for _, entry in ipairs(eq) do
      if entry.word:lower() == "blacklist" then found = true end
    end
    T.ok(found, "case-insensitive match for Blacklist")
  end)

  T.it("flags 'mankind' suggesting 'humankind'", function()
    local proc = retext():use(plugin.plugin)
    local tree = proc:parse("This benefits all of mankind.")
    tree = proc:run(tree)
    local found = false
    for _, entry in ipairs(tree.data.equality) do
      if entry.word:lower() == "mankind" then
        T.eq(entry.suggestion, "humankind")
        found = true
      end
    end
    T.ok(found, "'mankind' flagged")
  end)
end)
