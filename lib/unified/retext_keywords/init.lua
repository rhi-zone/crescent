-- lib/unified/retext_keywords/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_keywords: extracts significant keywords using TF with stopword filtering.
-- Port of retext-keywords (https://github.com/retextjs/retext-keywords).
--
-- Algorithm:
--   1. Extract all WordNode text values, lowercased.
--   2. Filter stopwords.
--   3. Count frequency per word.
--   4. Sort by frequency descending.
--   5. Store top N on root.data.keywords.
--
-- Options: opts.maximum (default 10)
--
-- Stores: root.data.keywords = { {word="lua", count=5}, ... }

local nlcst = require("lib.unified.nlcst") --[[: any]]

local M = {}

-- 100 most common English function words / stopwords.
local STOPWORDS = {
  the=true, a=true, an=true, is=true, are=true, was=true, were=true,
  be=true, been=true, being=true, have=true, has=true, had=true,
  ["do"]=true, does=true, did=true, will=true, would=true, could=true,
  should=true, may=true, might=true, shall=true, can=true, need=true,
  dare=true, ought=true, used=true, to=true, of=true, ["in"]=true,
  ["for"]=true, on=true, with=true, at=true, by=true, from=true,
  up=true, about=true, into=true, through=true, during=true,
  before=true, after=true, above=true, below=true, between=true,
  each=true, all=true, both=true, few=true, more=true, most=true,
  other=true, some=true, such=true, no=true, nor=true, ["not"]=true,
  only=true, same=true, so=true, than=true, too=true, very=true,
  just=true, ["but"]=true, ["and"]=true, ["or"]=true, ["if"]=true, ["then"]=true,
  that=true, this=true, these=true, those=true, it=true, its=true,
  he=true, she=true, they=true, we=true, you=true, i=true,
  my=true, your=true, his=true, her=true, our=true, their=true,
  what=true, which=true, who=true, whom=true, ["when"]=true, where=true,
  why=true, how=true, as=true, s=true,
}

-- Walk the tree collecting word text values.
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

local function transformer(root, opts)
  local maximum = ((opts and opts.maximum) or 10) --[[:! integer]]

  local words = collect_words(root)

  -- Count frequencies, skipping stopwords.
  local freq = {}
  for i = 1, #words do
    local w = words[i]
    if not STOPWORDS[w] and #w > 1 then
      freq[w] = ((freq[w] or 0) --[[:! integer]]) + 1
    end
  end

  -- Collect into a sortable list.
  local list = {}
  for word, count in pairs(freq) do
    list[#list + 1] = { word = word, count = count }
  end

  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.word < b.word  -- stable alphabetic tie-break
  end)

  -- Trim to maximum.
  local keywords = {}
  local limit = maximum < #list and maximum or #list
  for i = 1, limit do
    keywords[i] = list[i]
  end

  root.data = root.data or {}
  root.data.keywords = keywords

  return root
end

-- Plugin entry point.
function M.plugin(processor, opts)
  processor:use_transformer(function(root) return transformer(root, opts) end)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
