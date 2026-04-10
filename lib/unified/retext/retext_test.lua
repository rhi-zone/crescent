-- lib/unified/retext/retext_test.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local retext = require("lib.unified.retext")
local nlcst  = require("lib.unified.nlcst")

T.describe("retext preset", function()
  T.it("retext() returns a processor", function()
    local p = retext()
    T.ok(p ~= nil)
    T.ok(type(p.parse) == "function")
  end)

  T.it("parse returns a RootNode", function()
    local p = retext()
    local tree = p:parse("Hello!")
    T.eq(tree.type, "RootNode")
  end)

  T.it("tree has ParagraphNode child", function()
    local p = retext()
    local tree = p:parse("Hello!")
    T.ok(#tree.children >= 1)
    T.eq(tree.children[1].type, "ParagraphNode")
  end)

  T.it("tree has SentenceNode child", function()
    local p = retext()
    local tree = p:parse("Hello!")
    local para = tree.children[1]
    T.ok(#para.children >= 1)
    T.eq(para.children[1].type, "SentenceNode")
  end)

  T.it("tree has WordNode child with text Hello", function()
    local p = retext()
    local tree = p:parse("Hello!")
    local sent = tree.children[1].children[1]
    local word = sent.children[1]
    T.eq(word.type, "WordNode")
    T.eq(nlcst.to_text(word), "Hello")
  end)

  T.it("frozen processor clones on :use()", function()
    local p1 = retext()
    -- p1 is frozen; :use() should return a clone, not mutate p1
    local p2 = p1:use(function(proc) proc:use_transformer(function(ast) return ast end) end)
    T.ok(p1 ~= p2)
    T.ok(#p1._transformers == 0)
    T.ok(#p2._transformers == 1)
  end)
end)
