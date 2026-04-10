-- lib/unified/nlcst/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- nlcst: Natural Language Concrete Syntax Tree spec.
-- Provides node constructors and a to_text extractor.
-- Spec: https://github.com/syntax-tree/nlcst

local M = {}

-- Node type constants.
M.ROOT        = "RootNode"
M.PARAGRAPH   = "ParagraphNode"
M.SENTENCE    = "SentenceNode"
M.WORD        = "WordNode"
M.PUNCTUATION = "PunctuationNode"
M.WHITESPACE  = "WhiteSpaceNode"
M.TEXT        = "TextNode"
M.SOURCE      = "SourceNode"

-- RootNode: top-level container.
function M.root(children)
  return { type = M.ROOT, children = children or {} }
end

-- ParagraphNode: a paragraph, contains SentenceNodes.
function M.paragraph(children)
  return { type = M.PARAGRAPH, children = children or {} }
end

-- SentenceNode: a sentence, contains Word/Punctuation/WhiteSpace nodes.
function M.sentence(children)
  return { type = M.SENTENCE, children = children or {} }
end

-- WordNode: a word, wraps a TextNode.
function M.word(text)
  return { type = M.WORD, children = { { type = M.TEXT, value = text } } }
end

-- PunctuationNode: punctuation character(s), wraps a TextNode.
function M.punctuation(text)
  return { type = M.PUNCTUATION, children = { { type = M.TEXT, value = text } } }
end

-- WhiteSpaceNode: whitespace, wraps a TextNode.
function M.whitespace(text)
  return { type = M.WHITESPACE, children = { { type = M.TEXT, value = text } } }
end

-- TextNode: raw text leaf.
function M.text(value)
  return { type = M.TEXT, value = value }
end

-- SourceNode: source reference leaf.
function M.source(value)
  return { type = M.SOURCE, value = value }
end

-- to_text: recursively extract plain text from any nlcst node.
-- Concatenates all TextNode values in tree order.
function M.to_text(node)
  if node.type == M.TEXT or node.type == M.SOURCE then
    return node.value
  end
  if node.children then
    local parts = {}
    for i = 1, #node.children do
      parts[i] = M.to_text(node.children[i])
    end
    return table.concat(parts)
  end
  return ""
end

return M
