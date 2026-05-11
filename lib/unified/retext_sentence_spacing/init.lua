-- lib/unified/retext_sentence_spacing/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_sentence_spacing: checks whitespace between sentences.
-- Port of retext-sentence-spacing (https://github.com/retextjs/retext-sentence-spacing).
--
-- Options:
--   opts.preferred — number of spaces expected between sentences (default: 1).
--
-- Between consecutive SentenceNodes inside a ParagraphNode, checks the
-- intervening WhiteSpaceNode length. Flags when it doesn't match preferred.
--
-- Stores: root.data.sentence_spacing = { {actual=2, expected=1, sentence="..."}, ... }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

local function check_paragraph(para, preferred, findings)
  local children = para.children
  local n = #children
  local last_sent = nil
  local last_sent_idx = nil

  for i = 1, n do
    local child = children[i]
    if child.type == nlcst.SENTENCE then
      if last_sent ~= nil then
        -- Look at what's between last_sent_idx and i.
        -- Collect any WhiteSpaceNode in that range.
        for j = last_sent_idx + 1, i - 1 do
          local between = children[j]
          if between.type == nlcst.WHITESPACE then
            local ws_text = nlcst.to_text(between)
            local actual = #ws_text
            if actual ~= preferred then
              findings[#findings + 1] = {
                actual   = actual,
                expected = preferred,
                sentence = nlcst.to_text(last_sent),
              }
            end
          end
        end
      end
      last_sent = child
      last_sent_idx = i
    end
  end
end

local function transformer(root, opts)
  opts = opts or {}
  local preferred = opts.preferred or 1

  local findings = {}

  local function walk(node)
    if node.type == nlcst.PARAGRAPH then
      check_paragraph(node, preferred, findings)
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end

  walk(root)

  root.data = root.data or {}
  root.data.sentence_spacing = findings

  return root
end

function M.plugin(processor, opts)
  processor:use_transformer(function(root)
    return transformer(root, opts)
  end)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
