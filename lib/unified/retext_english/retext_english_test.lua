-- lib/unified/retext_english/retext_english_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T              = require("lib.test.assert")
local nlcst          = require("lib.unified.nlcst")
local retext_english = require("lib.unified.retext_english")

local function parse(s)
  return retext_english.parse(s)
end

-- Helper: collect all nodes of a given type from a tree (BFS).
local function find_all(tree, node_type)
  local result = {}
  local queue = { tree }
  while #queue > 0 do
    local node = table.remove(queue, 1)
    if node.type == node_type then
      result[#result + 1] = node
    end
    if node.children then
      for i = 1, #node.children do
        queue[#queue + 1] = node.children[i]
      end
    end
  end
  return result
end

T.describe("retext_english: single word", function()
  T.it("produces one WordNode", function()
    local tree = parse("Hello")
    local words = find_all(tree, "WordNode")
    T.eq(#words, 1)
    T.eq(nlcst.to_text(words[1]), "Hello")
  end)

  T.it("word is inside sentence inside paragraph inside root", function()
    local tree = parse("Hello")
    T.eq(tree.type, "RootNode")
    T.eq(tree.children[1].type, "ParagraphNode")
    T.eq(tree.children[1].children[1].type, "SentenceNode")
  end)
end)

T.describe("retext_english: sentence with punctuation", function()
  T.it("tokenizes Hello, world! into words and punctuation", function()
    local tree = parse("Hello, world!")
    local words = find_all(tree, "WordNode")
    local puncts = find_all(tree, "PunctuationNode")
    T.eq(#words, 2)
    T.eq(nlcst.to_text(words[1]), "Hello")
    T.eq(nlcst.to_text(words[2]), "world")
    -- comma and exclamation mark
    T.ok(#puncts >= 2)
  end)

  T.it("WhiteSpaceNode present between words", function()
    local tree = parse("Hello world")
    local ws = find_all(tree, "WhiteSpaceNode")
    T.ok(#ws >= 1)
    T.eq(nlcst.to_text(ws[1]), " ")
  end)
end)

T.describe("retext_english: multiple sentences", function()
  T.it("splits on . into two SentenceNodes", function()
    local tree = parse("Hello world. Goodbye world.")
    local sents = find_all(tree, "SentenceNode")
    T.ok(#sents == 2)
  end)

  T.it("splits on ! and ? too", function()
    local tree = parse("Hello! How are you?")
    local sents = find_all(tree, "SentenceNode")
    T.ok(#sents == 2)
  end)
end)

T.describe("retext_english: multiple paragraphs", function()
  T.it("splits on double newline into two ParagraphNodes", function()
    local tree = parse("Hello world.\n\nGoodbye world.")
    local paras = find_all(tree, "ParagraphNode")
    T.eq(#paras, 2)
  end)

  T.it("each paragraph has its own sentences", function()
    local tree = parse("Hi there. Nice day.\n\nBye now.")
    local paras = find_all(tree, "ParagraphNode")
    T.eq(#paras, 2)
    local sents1 = find_all(paras[1], "SentenceNode")
    local sents2 = find_all(paras[2], "SentenceNode")
    T.eq(#sents1, 2)
    T.eq(#sents2, 1)
  end)
end)

T.describe("retext_english: contractions", function()
  T.it("treats don't as a single word", function()
    local tree = parse("I don't know.")
    local words = find_all(tree, "WordNode")
    local texts = {}
    for i, w in ipairs(words) do texts[i] = nlcst.to_text(w) end
    -- words should include "don't" as one token
    local found = false
    for _, t in ipairs(texts) do
      if t == "don't" then found = true end
    end
    T.ok(found)
  end)
end)

T.describe("retext_english: hyphenated words", function()
  T.it("treats well-known as a single word", function()
    local tree = parse("It is well-known.")
    local words = find_all(tree, "WordNode")
    local found = false
    for _, w in ipairs(words) do
      if nlcst.to_text(w) == "well-known" then found = true end
    end
    T.ok(found)
  end)
end)
