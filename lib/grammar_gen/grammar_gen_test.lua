-- lib/grammar_gen/grammar_gen_test.lua
-- Tests for lib/grammar_gen

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local G = require("lib.grammar_gen")

-- Helper: check value is one of the given choices
local function one_of(val, choices)
  for _, c in ipairs(choices) do
    if val == c then return true end
  end
  return false
end

T.describe("grammar_gen", function()

  -- ────────────────────── Basic expansion ──────────────────────

  T.describe("basic expansion", function()
    T.it("expands a simple symbol", function()
      local g = G.new({ greeting = {"Hello", "Hi", "Hey"} }, {seed=1})
      local result = g:expand("#greeting#")
      T.ok(one_of(result, {"Hello", "Hi", "Hey"}), "should be one of the options, got: " .. tostring(result))
    end)

    T.it("returns literal text unchanged", function()
      local g = G.new({ }, {seed=1})
      local result = g:expand("no symbols here")
      T.eq(result, "no symbols here")
    end)

    T.it("returns empty string for empty input", function()
      local g = G.new({}, {seed=1})
      T.eq(g:expand(""), "")
    end)

    T.it("expands symbol in context", function()
      local g = G.new({ animal = {"cat", "dog"} }, {seed=1})
      local result = g:expand("The #animal# is here.")
      T.ok(result == "The cat is here." or result == "The dog is here.", "got: " .. tostring(result))
    end)

    T.it("all outputs are valid options (multiple runs)", function()
      local g = G.new({ color = {"red", "green", "blue"} })
      for _ = 1, 20 do
        local result = g:expand("#color#")
        T.ok(one_of(result, {"red", "green", "blue"}), "unexpected: " .. tostring(result))
      end
    end)
  end)

  -- ────────────────────── Nested expansion ──────────────────────

  T.describe("nested expansion", function()
    T.it("expands nested symbols", function()
      local g = G.new({
        origin = {"#greeting# #subject#!"},
        greeting = {"Hello"},
        subject = {"world"},
      }, {seed=1})
      T.eq(g:expand("#origin#"), "Hello world!")
    end)

    T.it("fully expands deep nesting", function()
      local g = G.new({
        a = {"#b# #b#"},
        b = {"#c#"},
        c = {"leaf"},
      }, {seed=1})
      T.eq(g:expand("#a#"), "leaf leaf")
    end)

    T.it("mixed literal and symbols", function()
      local g = G.new({
        adj = {"great"},
        noun = {"day"},
      }, {seed=1})
      local result = g:expand("Have a #adj# #noun#!")
      T.eq(result, "Have a great day!")
    end)
  end)

  -- ────────────────────── expand_symbol ──────────────────────

  T.describe("expand_symbol", function()
    T.it("expands a symbol directly", function()
      local g = G.new({ word = {"apple", "banana"} }, {seed=1})
      local result = g:expand_symbol("word")
      T.ok(one_of(result, {"apple", "banana"}), "got: " .. tostring(result))
    end)

    T.it("equivalent to expand('#symbol#')", function()
      local g1 = G.new({ x = {"hello"} }, {seed=42})
      local g2 = G.new({ x = {"hello"} }, {seed=42})
      T.eq(g1:expand_symbol("x"), g2:expand("#x#"))
    end)
  end)

  -- ────────────────────── Determinism / RNG ──────────────────────

  T.describe("determinism", function()
    T.it("same seed produces same output", function()
      local rules = { origin = {"#a# #b#"}, a = {"foo","bar","baz"}, b = {"1","2","3"} }
      local g1 = G.new(rules, {seed=777})
      local g2 = G.new(rules, {seed=777})
      for _ = 1, 10 do
        T.eq(g1:expand("#origin#"), g2:expand("#origin#"))
      end
    end)

    T.it("different seeds produce different outputs (probabilistic)", function()
      local rules = { x = {"a","b","c","d","e","f","g","h"} }
      local g1 = G.new(rules, {seed=100})
      local g2 = G.new(rules, {seed=999})
      local same = 0
      for _ = 1, 20 do
        if g1:expand("#x#") == g2:expand("#x#") then same = same + 1 end
      end
      -- With 8 options and 20 runs, probability of all same is (1/8)^20 ≈ 0
      T.ok(same < 20, "all outputs identical despite different seeds")
    end)
  end)

  -- ────────────────────── Modifiers ──────────────────────

  T.describe("modifiers", function()
    T.it("capitalize: first letter uppercase", function()
      local g = G.new({ w = {"hello"} }, {seed=1})
      T.eq(g:expand("#w.capitalize#"), "Hello")
    end)

    T.it("capitalize: already capitalized unchanged", function()
      local g = G.new({ w = {"World"} }, {seed=1})
      T.eq(g:expand("#w.capitalize#"), "World")
    end)

    T.it("uppercase: all uppercase", function()
      local g = G.new({ w = {"hello world"} }, {seed=1})
      T.eq(g:expand("#w.uppercase#"), "HELLO WORLD")
    end)

    T.it("lowercase: all lowercase", function()
      local g = G.new({ w = {"Hello World"} }, {seed=1})
      T.eq(g:expand("#w.lowercase#"), "hello world")
    end)

    T.it("a: vowel start → 'an'", function()
      local g = G.new({ w = {"apple"} }, {seed=1})
      T.eq(g:expand("#w.a#"), "an apple")
    end)

    T.it("a: consonant start → 'a'", function()
      local g = G.new({ w = {"banana"} }, {seed=1})
      T.eq(g:expand("#w.a#"), "a banana")
    end)

    T.it("a: uppercase vowel start → 'an'", function()
      local g = G.new({ w = {"Elephant"} }, {seed=1})
      T.eq(g:expand("#w.a#"), "an Elephant")
    end)

    T.it("s: basic plural", function()
      local g = G.new({ w = {"cat"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "cats")
    end)

    T.it("s: -s ending → -es", function()
      local g = G.new({ w = {"bus"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "buses")
    end)

    T.it("s: -x ending → -es", function()
      local g = G.new({ w = {"fox"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "foxes")
    end)

    T.it("s: -sh ending → -es", function()
      local g = G.new({ w = {"wish"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "wishes")
    end)

    T.it("s: consonant+y → -ies", function()
      local g = G.new({ w = {"city"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "cities")
    end)

    T.it("s: vowel+y → -s (normal)", function()
      local g = G.new({ w = {"day"} }, {seed=1})
      T.eq(g:expand("#w.s#"), "days")
    end)

    T.it("ed: basic past tense", function()
      local g = G.new({ w = {"walk"} }, {seed=1})
      T.eq(g:expand("#w.ed#"), "walked")
    end)

    T.it("ed: -e ending → -d", function()
      local g = G.new({ w = {"love"} }, {seed=1})
      T.eq(g:expand("#w.ed#"), "loved")
    end)

    T.it("ed: consonant+y → -ied", function()
      local g = G.new({ w = {"try"} }, {seed=1})
      T.eq(g:expand("#w.ed#"), "tried")
    end)

    T.it("ing: basic", function()
      local g = G.new({ w = {"walk"} }, {seed=1})
      T.eq(g:expand("#w.ing#"), "walking")
    end)

    T.it("ing: drops trailing -e", function()
      local g = G.new({ w = {"make"} }, {seed=1})
      T.eq(g:expand("#w.ing#"), "making")
    end)

    T.it("ing: keeps -ee", function()
      local g = G.new({ w = {"agree"} }, {seed=1})
      T.eq(g:expand("#w.ing#"), "agreeing")
    end)

    T.it("multiple modifiers applied in order", function()
      local g = G.new({ w = {"hello"} }, {seed=1})
      -- capitalize then uppercase → "HELLO"
      T.eq(g:expand("#w.capitalize.uppercase#"), "HELLO")
    end)

    T.it("unknown modifier is silently ignored", function()
      local g = G.new({ w = {"hello"} }, {seed=1})
      T.eq(g:expand("#w.unknownmod#"), "hello")
    end)
  end)

  -- ────────────────────── Inline assignments ──────────────────────

  T.describe("inline assignments", function()
    T.it("[var:value] assigns a literal value", function()
      local g = G.new({ origin = {"[hero:Alice]#hero# and #hero#"} }, {seed=1})
      T.eq(g:expand("#origin#"), "Alice and Alice")
    end)

    T.it("[var:#symbol#] assigns an expanded value", function()
      local g = G.new({
        origin = {"[hero:#name#]#hero# fights #hero#!"},
        name = {"Bob"},
      }, {seed=1})
      T.eq(g:expand("#origin#"), "Bob fights Bob!")
    end)

    T.it("inline variable is not leaked after expansion", function()
      local g = G.new({
        origin = {"[tmp:hi]#tmp#"},
      }, {seed=1})
      -- After expand completes, tmp should not be accessible
      T.eq(g:expand("#origin#"), "hi")
      local result, err = g:expand("#tmp#")
      T.ok(result == nil or err ~= nil, "tmp should not persist after expansion")
    end)

    T.it("multiple inline assignments", function()
      local g = G.new({
        origin = {"[a:foo][b:bar]#a# #b#"},
      }, {seed=1})
      T.eq(g:expand("#origin#"), "foo bar")
    end)
  end)

  -- ────────────────────── push / pop ──────────────────────

  T.describe("push/pop", function()
    T.it("pushed rule overrides base rule", function()
      local g = G.new({ animal = {"cat"} }, {seed=1})
      g:push({ animal = {"dog"} })
      T.eq(g:expand("#animal#"), "dog")
      g:pop()
    end)

    T.it("pop restores base rule", function()
      local g = G.new({ animal = {"cat"} }, {seed=1})
      g:push({ animal = {"dog"} })
      g:pop()
      T.eq(g:expand("#animal#"), "cat")
    end)

    T.it("nested push/pop", function()
      local g = G.new({ x = {"base"} }, {seed=1})
      g:push({ x = {"level1"} })
      g:push({ x = {"level2"} })
      T.eq(g:expand("#x#"), "level2")
      g:pop()
      T.eq(g:expand("#x#"), "level1")
      g:pop()
      T.eq(g:expand("#x#"), "base")
    end)

    T.it("push adds new symbol not in base", function()
      local g = G.new({ }, {seed=1})
      g:push({ fresh = {"mint"} })
      T.eq(g:expand("#fresh#"), "mint")
      g:pop()
    end)

    T.it("pop on empty stack does not crash", function()
      local g = G.new({ x = {"y"} }, {seed=1})
      g:pop() -- should be a no-op, not crash
      T.eq(g:expand("#x#"), "y")
    end)
  end)

  -- ────────────────────── symbols() ──────────────────────

  T.describe("symbols()", function()
    T.it("returns all symbol names", function()
      local g = G.new({ a = {"1"}, b = {"2"}, c = {"3"} }, {seed=1})
      local syms = g:symbols()
      table.sort(syms)
      T.eq(#syms, 3)
      T.eq(syms[1], "a")
      T.eq(syms[2], "b")
      T.eq(syms[3], "c")
    end)

    T.it("returns sorted names", function()
      local g = G.new({ z = {""}, a = {""}, m = {""} }, {seed=1})
      local syms = g:symbols()
      T.eq(syms[1], "a")
      T.eq(syms[2], "m")
      T.eq(syms[3], "z")
    end)

    T.it("empty grammar has empty symbols list", function()
      local g = G.new({}, {seed=1})
      T.eq(#g:symbols(), 0)
    end)
  end)

  -- ────────────────────── Error handling ──────────────────────

  T.describe("error handling", function()
    T.it("undefined symbol returns nil + errmsg", function()
      local g = G.new({}, {seed=1})
      local result, err = g:expand("#nope#")
      T.eq(result, nil)
      T.ok(err ~= nil, "expected error message")
      T.ok(err:find("nope") ~= nil, "error should mention symbol name")
    end)

    T.it("max depth exceeded returns nil + errmsg", function()
      local g = G.new({ loop = {"#loop#"} }, {seed=1, max_depth=10})
      local result, err = g:expand("#loop#")
      T.eq(result, nil)
      T.ok(err ~= nil, "expected error for max depth")
      T.ok(err:find("depth") ~= nil, "error should mention depth")
    end)
  end)

  -- ────────────────────── _tier ──────────────────────

  T.describe("_tier", function()
    T.it("_tier is 'pure'", function()
      T.eq(G._tier, "pure")
    end)
  end)

  -- ────────────────────── Integration: full grammar ──────────────────────

  T.describe("integration", function()
    T.it("Tracery-style story grammar expands without error", function()
      local g = G.new({
        origin = {"#hero.capitalize# went to #place# and found #item.a#."},
        hero = {"alice", "bob", "carol"},
        place = {"the forest", "the castle", "the cave"},
        item = {"sword", "egg", "apple"},
      }, {seed=42})
      local result = g:expand("#origin#")
      T.ok(type(result) == "string" and #result > 0, "got: " .. tostring(result))
      -- Should start with capitalized hero
      T.ok(result:sub(1,1):match("[A-Z]") ~= nil, "should start with capital: " .. result)
    end)

    T.it("sentence grammar with modifiers", function()
      local g = G.new({
        animal = {"cat", "elephant", "ox"},
        sentence = {"The #animal.a# has #animal.s#."},
      }, {seed=7})
      for _ = 1, 5 do
        local result = g:expand("#sentence#")
        T.ok(type(result) == "string" and #result > 0)
        T.ok(result:sub(1, 4) == "The ", "starts with 'The ': " .. result)
      end
    end)

    T.it("combined modifiers and nested expansion", function()
      local g = G.new({
        origin = {"#verb.ing# is #adj#"},
        verb = {"run", "make", "walk"},
        adj = {"fun", "great"},
      }, {seed=1})
      local result = g:expand("#origin#")
      T.ok(type(result) == "string" and result:find("ing") ~= nil, "should contain 'ing': " .. tostring(result))
    end)
  end)

end)

-- Print summary
local summary = T._summary()
local total = summary.pass + summary.fail
io.write(string.format("\n%d/%d assertions passed", summary.pass, total))
if summary.fail > 0 then
  io.write(string.format(", %d FAILED\n", summary.fail))
  for _, test in ipairs(summary.tests) do
    if not test.ok then
      io.write(string.format("  FAIL: %s\n", test.name))
      if test.err then io.write(string.format("        %s\n", test.err)) end
    end
  end
  os.exit(1)
else
  io.write("\n")
end
