-- lib/unified/retext_readability/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_readability: computes readability scores for nlcst trees.
-- Port of retext-readability (https://github.com/retextjs/retext-readability).
--
-- Formulas:
--   Flesch Reading Ease:     206.835 - 1.015*(words/sents) - 84.6*(sylls/words)
--   Flesch-Kincaid Grade:    0.39*(words/sents) + 11.8*(sylls/words) - 15.59
--   Gunning Fog Index:       0.4*((words/sents) + 100*(complex/words))
--     complex = words with 3+ syllables
--
-- Syllable counting: count vowel groups [aeiouAEIOU]+ per word.
--
-- Stores: root.data.readability = {
--   flesch=N, grade=N, fog=N,
--   sentences=N, words=N, syllables=N
-- }

local nlcst = require("lib.unified.nlcst") --[[: any]]

local M = {}

-- Count syllable groups in a word string.
local function count_syllables(word)
  local n = 0
  for _ in word:gmatch("[aeiouAEIOU]+") do
    n = n + 1
  end
  -- Every word has at least 1 syllable.
  return n > 0 and n or 1
end

-- Walk a node tree and collect word strings and sentence counts.
-- Returns total_sentences, total_words, total_syllables, total_complex_words.
--:: NlcstNode = { type: string, children?: { [integer]: NlcstNode }, data?: { [string]: unknown }, ... }
--: (NlcstNode) -> (integer, integer, integer, integer)
local function collect_stats(root)
  local sentences   = 0
  local words       = 0
  local syllables   = 0
  local complex     = 0

  local function walk(node)
    if node.type == nlcst.SENTENCE then
      sentences = sentences + 1
    end
    if node.type == nlcst.WORD then
      local text = nlcst.to_text(node)
      local sylls = count_syllables(text)
      words     = words + 1
      syllables = syllables + sylls
      if sylls >= 3 then
        complex = complex + 1
      end
      return -- Don't descend into word children.
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: any }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end

  walk(root)
  return sentences, words, syllables, complex
end

-- Compute readability scores and store on root.data.
local function transformer(root)
  local sentences, words, syllables, complex = collect_stats(root)

  root.data = root.data or {}

  if sentences == 0 or words == 0 then
    root.data.readability = {
      flesch    = 0,
      grade     = 0,
      fog       = 0,
      sentences = sentences,
      words     = words,
      syllables = syllables,
    }
    return root
  end

  local wps = words / sentences      -- words per sentence
  local spw = syllables / words      -- syllables per word
  local cpw = complex / words        -- complex words per word

  local flesch = 206.835 - 1.015 * wps - 84.6 * spw
  local grade  = 0.39 * wps + 11.8 * spw - 15.59
  local fog    = 0.4 * (wps + 100 * cpw)

  root.data.readability = {
    flesch    = flesch,
    grade     = grade,
    fog       = fog,
    sentences = sentences,
    words     = words,
    syllables = syllables,
  }

  return root
end

-- Plugin entry point for unified :use().
function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
