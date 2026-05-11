-- lib/unified/retext_repeated_words/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_repeated_words: detects consecutive repeated words in nlcst trees.
-- Port of retext-repeated-words (https://github.com/retextjs/retext-repeated-words).
--
-- Scans SentenceNode children. When two consecutive WordNodes have the same
-- value (case-insensitive) with only whitespace between them, records a finding.
--
-- Stores: root.data.repeated_words = { {word="the", sentence="..."}, ... }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

-- Walk a sentence node, collecting findings.
local function check_sentence(sent, findings)
  local children = sent.children
  local n = #children
  -- Track the last-seen word index and value.
  local last_word_val = nil
  local last_word_idx = nil

  for i = 1, n do
    local child = children[i]
    if child.type == nlcst.WORD then
      local val = nlcst.to_text(child):lower()
      if last_word_val ~= nil and val == last_word_val then
        -- Check that everything between last_word_idx and i is whitespace only.
        local only_ws = true
        for j = last_word_idx + 1, i - 1 do
          local between = children[j]
          if between.type ~= nlcst.WHITESPACE then
            only_ws = false
            break
          end
        end
        if only_ws then
          findings[#findings + 1] = {
            word     = val,
            sentence = nlcst.to_text(sent),
          }
        end
      end
      last_word_val = val
      last_word_idx = i
    elseif child.type == nlcst.PUNCTUATION then
      -- Punctuation resets the consecutive-word chain.
      last_word_val = nil
      last_word_idx = nil
    end
    -- Whitespace does NOT reset the chain.
  end
end

local function transformer(root)
  local findings = {}

  local function walk(node)
    if node.type == nlcst.SENTENCE then
      check_sentence(node, findings)
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end

  walk(root)

  root.data = root.data or {}
  root.data.repeated_words = findings

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
