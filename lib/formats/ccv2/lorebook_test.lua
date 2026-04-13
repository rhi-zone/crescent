if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local lb = require("lib.formats.ccv2.lorebook")
local T = require("lib.test.assert")

-- ---------------------------------------------------------------------------
-- from_ccv2
-- ---------------------------------------------------------------------------

T.describe("from_ccv2", function()
  T.it("converts position strings", function()
    local book = { entries = {
      { keys = {"hello"}, content = "c1", position = "before_char" },
      { keys = {"world"}, content = "c2", position = "after_char" },
    }}
    local entries = lb.from_ccv2(book)
    T.eq(entries[1].position, 0, "before_char -> 0")
    T.eq(entries[2].position, 1, "after_char -> 1")
  end)

  T.it("maps field names from CCv2 to ST", function()
    local book = { entries = {
      { keys = {"k1", "k2"}, content = "hello", insertion_order = 5,
        secondary_keys = {"sk1"}, case_sensitive = true, selective = true },
    }}
    local entries = lb.from_ccv2(book)
    local e = entries[1]
    T.eq(e.key[1], "k1")
    T.eq(e.key[2], "k2")
    T.eq(e.content, "hello")
    T.eq(e.order, 5)
    T.eq(e.keysecondary[1], "sk1")
    T.eq(e.caseSensitive, true)
  end)

  T.it("fills defaults for missing fields", function()
    local book = { entries = { { keys = {"a"}, content = "b" } } }
    local entries = lb.from_ccv2(book)
    local e = entries[1]
    T.eq(e.enabled, true)
    T.eq(e.constant, false)
    T.eq(e.probability, 1.0)
    T.eq(e.depth, 0)
    T.eq(e.role, 0)
    T.eq(e.matchWholeWords, false)
    T.eq(e.sticky, false)
    T.eq(e.cooldown, 0)
    T.eq(e.delay, 0)
    T.eq(e.group, "")
    T.eq(e.groupWeight, 1)
  end)

  T.it("defaults unknown position to 0", function()
    local book = { entries = { { keys = {"a"}, content = "b", position = "custom_pos" } } }
    local entries = lb.from_ccv2(book)
    T.eq(entries[1].position, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- to_ccv2
-- ---------------------------------------------------------------------------

T.describe("to_ccv2", function()
  T.it("round-trips basic entries", function()
    local original = { entries = {
      { keys = {"hello"}, content = "world", position = "before_char",
        insertion_order = 10, case_sensitive = false, selective = false,
        secondary_keys = {}, constant = false, enabled = true },
    }}
    local st = lb.from_ccv2(original)
    local back = lb.to_ccv2(st)
    T.eq(back.entries[1].keys[1], "hello")
    T.eq(back.entries[1].content, "world")
    T.eq(back.entries[1].position, "before_char")
    T.eq(back.entries[1].insertion_order, 10)
  end)

  T.it("drops ST-only fields", function()
    local st = { lb.normalize({
      key = {"test"}, content = "data", order = 5,
      sticky = true, cooldown = 3, delay = 1,
      ignoreBudget = true, excludeRecursion = true,
    }) }
    local ccv2 = lb.to_ccv2(st)
    local ce = ccv2.entries[1]
    T.eq(ce.sticky, nil)
    T.eq(ce.cooldown, nil)
    T.eq(ce.delay, nil)
    T.eq(ce.ignoreBudget, nil)
    T.eq(ce.excludeRecursion, nil)
  end)

  T.it("converts position numbers to strings", function()
    local st = {
      lb.normalize({ key = {"a"}, position = 0 }),
      lb.normalize({ key = {"b"}, position = 1 }),
      lb.normalize({ key = {"c"}, position = 2 }),
    }
    local ccv2 = lb.to_ccv2(st)
    T.eq(ccv2.entries[1].position, "before_char")
    T.eq(ccv2.entries[2].position, "after_char")
    T.eq(ccv2.entries[3].position, "before_char") -- unknown -> before_char
  end)
end)

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

T.describe("normalize", function()
  T.it("fills all defaults for empty entry", function()
    local e = lb.normalize({})
    T.ok(e.uid ~= nil and e.uid ~= "", "uid generated")
    T.eq(e.comment, "")
    T.ok(type(e.key) == "table")
    T.eq(#e.key, 0)
    T.ok(type(e.keysecondary) == "table")
    T.eq(#e.keysecondary, 0)
    T.eq(e.selectiveLogic, 0)
    T.eq(e.content, "")
    T.eq(e.enabled, true)
    T.eq(e.constant, false)
    T.eq(e.order, 0)
    T.eq(e.position, 0)
    T.eq(e.depth, 0)
    T.eq(e.role, 0)
    T.eq(e.caseSensitive, false)
    T.eq(e.matchWholeWords, false)
    T.eq(e.probability, 1.0)
    T.eq(e.sticky, false)
    T.eq(e.cooldown, 0)
    T.eq(e.delay, 0)
    T.eq(e.ignoreBudget, false)
    T.eq(e.excludeRecursion, false)
    T.eq(e.preventRecursion, false)
    T.eq(e.group, "")
    T.eq(e.groupWeight, 1)
    T.eq(e.displayIndex, 0)
  end)

  T.it("does not mutate input", function()
    local input = { content = "original" }
    local output = lb.normalize(input)
    T.eq(input.uid, nil, "input unchanged")
    T.ok(output.uid ~= nil, "output has uid")
  end)

  T.it("preserves existing values", function()
    local e = lb.normalize({ content = "hello", order = 42, caseSensitive = true })
    T.eq(e.content, "hello")
    T.eq(e.order, 42)
    T.eq(e.caseSensitive, true)
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — plain keywords
-- ---------------------------------------------------------------------------

T.describe("scan - plain keywords", function()
  T.it("matches a single keyword", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "lore about dragons" }),
    }
    local indices = lb.scan(entries, "I saw a dragon in the sky")
    T.eq(#indices, 1)
    T.eq(indices[1], 1)
  end)

  T.it("matches multiple keywords from different entries", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "dragon lore", order = 10 }),
      lb.normalize({ key = {"castle"}, content = "castle lore", order = 5 }),
    }
    local indices = lb.scan(entries, "The dragon flew over the castle")
    T.eq(#indices, 2)
    -- Sorted by order descending: dragon(10) then castle(5)
    T.eq(indices[1], 1)
    T.eq(indices[2], 2)
  end)

  T.it("does not match absent keywords", function()
    local entries = {
      lb.normalize({ key = {"unicorn"}, content = "unicorn lore" }),
    }
    local indices = lb.scan(entries, "The dragon flew over the castle")
    T.eq(#indices, 0)
  end)

  T.it("matches any key in the key list", function()
    local entries = {
      lb.normalize({ key = {"dragon", "wyrm"}, content = "dragon lore" }),
    }
    local indices = lb.scan(entries, "A wyrm appeared")
    T.eq(#indices, 1)
    T.eq(indices[1], 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — case sensitivity
-- ---------------------------------------------------------------------------

T.describe("scan - case sensitivity", function()
  T.it("case insensitive by default", function()
    local entries = {
      lb.normalize({ key = {"Dragon"}, content = "lore" }),
    }
    local indices = lb.scan(entries, "i saw a dragon")
    T.eq(#indices, 1)
  end)

  T.it("case sensitive when enabled", function()
    local entries = {
      lb.normalize({ key = {"Dragon"}, content = "lore", caseSensitive = true }),
    }
    -- "dragon" should NOT match "Dragon" when case sensitive
    local indices = lb.scan(entries, "i saw a dragon")
    T.eq(#indices, 0)

    -- "Dragon" should match
    local indices2 = lb.scan(entries, "i saw a Dragon")
    T.eq(#indices2, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — secondary keys and selectiveLogic
-- ---------------------------------------------------------------------------

T.describe("scan - secondary keys", function()
  T.it("AND_ANY: triggers if any secondary matches", function()
    local entries = {
      lb.normalize({
        key = {"dragon"}, keysecondary = {"fire", "ice"},
        selectiveLogic = lb.LOGIC_AND_ANY, content = "lore",
      }),
    }
    T.eq(#lb.scan(entries, "dragon breathes fire"), 1)
    T.eq(#lb.scan(entries, "dragon breathes ice"), 1)
    T.eq(#lb.scan(entries, "dragon breathes wind"), 0)
  end)

  T.it("NOT_ALL: triggers unless all secondary match", function()
    local entries = {
      lb.normalize({
        key = {"dragon"}, keysecondary = {"fire", "ice"},
        selectiveLogic = lb.LOGIC_NOT_ALL, content = "lore",
      }),
    }
    -- Only fire matches -> not all match -> triggers
    T.eq(#lb.scan(entries, "dragon breathes fire"), 1)
    -- Both match -> all match -> does NOT trigger
    T.eq(#lb.scan(entries, "dragon breathes fire and ice"), 0)
    -- Neither matches -> not all match -> triggers
    T.eq(#lb.scan(entries, "dragon breathes wind"), 1)
  end)

  T.it("NOT_ANY: triggers unless any secondary matches", function()
    local entries = {
      lb.normalize({
        key = {"dragon"}, keysecondary = {"fire", "ice"},
        selectiveLogic = lb.LOGIC_NOT_ANY, content = "lore",
      }),
    }
    T.eq(#lb.scan(entries, "dragon breathes fire"), 0)
    T.eq(#lb.scan(entries, "dragon breathes wind"), 1)
  end)

  T.it("AND_ALL: triggers only if all secondary match", function()
    local entries = {
      lb.normalize({
        key = {"dragon"}, keysecondary = {"fire", "ice"},
        selectiveLogic = lb.LOGIC_AND_ALL, content = "lore",
      }),
    }
    T.eq(#lb.scan(entries, "dragon breathes fire"), 0)
    T.eq(#lb.scan(entries, "dragon breathes fire and ice"), 1)
  end)

  T.it("no secondary keys: primary match sufficient", function()
    local entries = {
      lb.normalize({
        key = {"dragon"}, keysecondary = {},
        selectiveLogic = lb.LOGIC_AND_ANY, content = "lore",
      }),
    }
    T.eq(#lb.scan(entries, "dragon"), 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — regex keys
-- ---------------------------------------------------------------------------

T.describe("scan - regex keys", function()
  T.it("matches /pattern/", function()
    local entries = {
      lb.normalize({ key = {"/drag.n/"}, content = "lore" }),
    }
    T.eq(#lb.scan(entries, "i saw a dragon"), 1)
    T.eq(#lb.scan(entries, "i saw a dragun"), 1)
    T.eq(#lb.scan(entries, "i saw a cat"), 0)
  end)

  T.it("matches /pattern/i case insensitively", function()
    local entries = {
      lb.normalize({ key = {"/Dragon/i"}, content = "lore", caseSensitive = true }),
    }
    -- /i flag overrides case sensitivity
    T.eq(#lb.scan(entries, "i saw a dragon"), 1)
    T.eq(#lb.scan(entries, "i saw a DRAGON"), 1)
  end)

  T.it("regex combined with plain keys", function()
    local entries = {
      lb.normalize({ key = {"castle", "/drag.n/"}, content = "lore" }),
    }
    T.eq(#lb.scan(entries, "dragon"), 1)
    T.eq(#lb.scan(entries, "castle"), 1)
    T.eq(#lb.scan(entries, "wizard"), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — skips disabled and constant entries
-- ---------------------------------------------------------------------------

T.describe("scan - entry filtering", function()
  T.it("skips disabled entries", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "lore", enabled = false }),
    }
    T.eq(#lb.scan(entries, "dragon"), 0)
  end)

  T.it("skips constant entries", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "lore", constant = true }),
    }
    T.eq(#lb.scan(entries, "dragon"), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- get_triggered
-- ---------------------------------------------------------------------------

T.describe("get_triggered", function()
  T.it("returns entry tables sorted by order descending", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "dragon lore", order = 5 }),
      lb.normalize({ key = {"castle"}, content = "castle lore", order = 20 }),
      lb.normalize({ key = {"wizard"}, content = "wizard lore", order = 10 }),
    }
    local triggered = lb.get_triggered(entries, "dragon castle wizard")
    T.eq(#triggered, 3)
    T.eq(triggered[1].content, "castle lore")
    T.eq(triggered[2].content, "wizard lore")
    T.eq(triggered[3].content, "dragon lore")
  end)
end)

-- ---------------------------------------------------------------------------
-- scan — probability filtering
-- ---------------------------------------------------------------------------

T.describe("scan - probability", function()
  T.it("filters by probability with deterministic rng", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "lore", probability = 0.5 }),
    }
    -- rng returns 0.3 -> 0.3 < 0.5 -> triggers
    local indices = lb.scan(entries, "dragon", { rng = function() return 0.3 end })
    T.eq(#indices, 1)

    -- rng returns 0.7 -> 0.7 >= 0.5 -> does not trigger
    local indices2 = lb.scan(entries, "dragon", { rng = function() return 0.7 end })
    T.eq(#indices2, 0)
  end)

  T.it("probability 1.0 always triggers", function()
    local entries = {
      lb.normalize({ key = {"dragon"}, content = "lore", probability = 1.0 }),
    }
    local indices = lb.scan(entries, "dragon", { rng = function() return 0.99 end })
    T.eq(#indices, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

T.describe("constants", function()
  T.it("exports position constants", function()
    T.eq(lb.POS_BEFORE, 0)
    T.eq(lb.POS_AFTER, 1)
    T.eq(lb.POS_AN_TOP, 2)
    T.eq(lb.POS_AN_BOTTOM, 3)
    T.eq(lb.POS_AT_DEPTH, 4)
    T.eq(lb.POS_EM_TOP, 5)
    T.eq(lb.POS_EM_BOTTOM, 6)
  end)

  T.it("exports selectiveLogic constants", function()
    T.eq(lb.LOGIC_AND_ANY, 0)
    T.eq(lb.LOGIC_NOT_ALL, 1)
    T.eq(lb.LOGIC_NOT_ANY, 2)
    T.eq(lb.LOGIC_AND_ALL, 3)
  end)

  T.it("exports role constants", function()
    T.eq(lb.ROLE_SYSTEM, 0)
    T.eq(lb.ROLE_USER, 1)
    T.eq(lb.ROLE_ASSISTANT, 2)
  end)
end)
