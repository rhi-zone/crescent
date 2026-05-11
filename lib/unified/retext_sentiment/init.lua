-- lib/unified/retext_sentiment/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_sentiment: document sentiment analysis using AFINN word scores.
-- Port of retext-sentiment (https://github.com/retextjs/retext-sentiment).
--
-- Sums AFINN-111 scores for matched words. Normalises to -1..1 via score/words.
--
-- Stores: root.data.sentiment = {
--   score=N, comparative=N,
--   positive={"good","great",...}, negative={"bad",...}
-- }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

-- Subset of AFINN-111 scores.
local AFINN = {
  -- Positive
  good=3, great=3, excellent=5, love=3, wonderful=3, best=3, happy=3,
  joy=3, fun=3, nice=2, like=2, enjoy=2, positive=2, beautiful=3,
  amazing=4, fantastic=4, awesome=4, perfect=5, brilliant=4, superb=5,
  outstanding=5, delight=3, delightful=4, pleased=2, pleasant=2,
  glad=2, grateful=3, thankful=3, brilliant=4, clever=2, smart=2,
  helpful=2, kind=2, generous=3, friendly=2, honest=2, brave=2,
  courageous=2, innovative=2, creative=3, inspired=3, exciting=3,
  enthusiastic=2, motivated=2, confident=2, successful=3, win=3,
  winner=3, victory=3, triumph=3, celebrate=3, praise=3, recommend=2,
  -- Negative
  bad=-3, terrible=-3, horrible=-3, hate=-3, awful=-3, worst=-3,
  sad=-2, ugly=-3, stupid=-2, boring=-2, dull=-2, poor=-2, wrong=-2,
  fail=-2, problem=-2, issue=-1, difficult=-1, hard=-1, slow=-1,
  broken=-2, angry=-3, frustrating=-2, annoying=-2, disappointing=-2,
  disappointed=-2, depressing=-3, depressed=-3, miserable=-3, pain=-2,
  suffer=-2, suffering=-2, disaster=-3, catastrophe=-3, crisis=-2,
  danger=-2, dangerous=-2, harmful=-2, useless=-2, worthless=-2,
  pathetic=-2, disgraceful=-3, embarrassing=-2, shameful=-3,
  corrupt=-3, evil=-3, dreadful=-3, nasty=-3, offensive=-3,
  disgusting=-3, toxic=-3, destructive=-3, violent=-3, abuse=-3,
}

local function collect_words(root)
  local result = {}
  local function walk(node)
    if node.type == nlcst.WORD then
      result[#result + 1] = nlcst.to_text(node):lower()
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: any }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end
  walk(root)
  return result
end

local function transformer(root)
  local words = collect_words(root)
  local total_score = 0
  local positive = {}
  local negative = {}

  for i = 1, #words do
    local w = words[i]
    local score = AFINN[w]
    if score then
      local score_ = score --[[:! integer]]
      total_score = total_score + score_
      if score > 0 then
        positive[#positive + 1] = w
      else
        negative[#negative + 1] = w
      end
    end
  end

  local comparative = #words > 0 and (total_score / #words) or 0

  root.data = root.data or {}
  root.data.sentiment = {
    score       = total_score,
    comparative = comparative,
    positive    = positive,
    negative    = negative,
  }

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
