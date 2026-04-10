-- lib/unified/nlcst/nlcst_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local nlcst = require("lib.unified.nlcst")

T.describe("nlcst constructors", function()
  T.it("root produces RootNode", function()
    local node = nlcst.root({})
    T.eq(node.type, "RootNode")
    T.eq(#node.children, 0)
  end)

  T.it("paragraph produces ParagraphNode", function()
    local node = nlcst.paragraph({})
    T.eq(node.type, "ParagraphNode")
  end)

  T.it("sentence produces SentenceNode", function()
    local node = nlcst.sentence({})
    T.eq(node.type, "SentenceNode")
  end)

  T.it("word produces WordNode with TextNode child", function()
    local node = nlcst.word("hello")
    T.eq(node.type, "WordNode")
    T.eq(#node.children, 1)
    T.eq(node.children[1].type, "TextNode")
    T.eq(node.children[1].value, "hello")
  end)

  T.it("punctuation produces PunctuationNode with TextNode child", function()
    local node = nlcst.punctuation(".")
    T.eq(node.type, "PunctuationNode")
    T.eq(node.children[1].type, "TextNode")
    T.eq(node.children[1].value, ".")
  end)

  T.it("whitespace produces WhiteSpaceNode with TextNode child", function()
    local node = nlcst.whitespace(" ")
    T.eq(node.type, "WhiteSpaceNode")
    T.eq(node.children[1].type, "TextNode")
    T.eq(node.children[1].value, " ")
  end)

  T.it("text produces TextNode leaf", function()
    local node = nlcst.text("foo")
    T.eq(node.type, "TextNode")
    T.eq(node.value, "foo")
  end)

  T.it("source produces SourceNode leaf", function()
    local node = nlcst.source("bar")
    T.eq(node.type, "SourceNode")
    T.eq(node.value, "bar")
  end)
end)

T.describe("nlcst.to_text", function()
  T.it("extracts text from TextNode", function()
    T.eq(nlcst.to_text(nlcst.text("hello")), "hello")
  end)

  T.it("extracts text from WordNode", function()
    T.eq(nlcst.to_text(nlcst.word("world")), "world")
  end)

  T.it("extracts text from nested SentenceNode", function()
    local sent = nlcst.sentence({
      nlcst.word("Hello"),
      nlcst.punctuation(","),
      nlcst.whitespace(" "),
      nlcst.word("world"),
      nlcst.punctuation("."),
    })
    T.eq(nlcst.to_text(sent), "Hello, world.")
  end)

  T.it("extracts text from full tree", function()
    local tree = nlcst.root({
      nlcst.paragraph({
        nlcst.sentence({
          nlcst.word("Hi"),
        }),
      }),
    })
    T.eq(nlcst.to_text(tree), "Hi")
  end)

  T.it("returns empty string for empty root", function()
    T.eq(nlcst.to_text(nlcst.root({})), "")
  end)
end)
