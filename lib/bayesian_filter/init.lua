if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Tokenize text into lowercase words, stripping punctuation
--: (string) -> { [integer]: string }
local function tokenize(text)
  local words = {} --: { [integer]: string }
  local lower = text:lower()
  for word in lower:gmatch("[%a]+") do
    words[#words + 1] = word
  end
  return words
end

-- Softmax over a table of raw log scores
-- Returns a new table with probabilities summing to 1
local function softmax(log_scores)
  -- Find max for numerical stability
  local max_score = -math.huge
  for _, v in pairs(log_scores) do
    if v > max_score then max_score = v end
  end

  local sum = (0.0) --[[:! number]]
  local exp_scores = {}
  for k, v in pairs(log_scores) do
    local e = math.exp(v - max_score)
    exp_scores[k] = e
    sum = sum + e
  end

  local probs = {}
  for k, v in pairs(exp_scores) do
    probs[k] = v / sum
  end
  return probs
end

--:: ClfCat = { doc_count: integer, word_counts: { [string]: integer }, total_words: integer }
--:: Classifier = { _cats: { [string]: ClfCat }, _cat_list: { [integer]: string }, _vocab: { [string]: boolean }, _vocab_size: integer, _total_docs: integer, ... }

-- Classifier object methods
local Clf = {}
Clf.__index = Clf

--: (Classifier, string, string) -> nil
function Clf:train(category, text)
  local words = tokenize(text)

  -- Initialize category data if needed
  if not self._cats[category] then
    self._cats[category] = { doc_count = 0, word_counts = {}, total_words = 0 }
    self._cat_list[#self._cat_list + 1] = category
  end

  local cat = self._cats[category]
  cat.doc_count = cat.doc_count + 1
  self._total_docs = self._total_docs + 1

  for _, word in ipairs(words) do
    cat.word_counts[word] = (cat.word_counts[word] or 0) + 1
    cat.total_words = cat.total_words + 1

    -- Track global vocab
    if not self._vocab[word] then
      self._vocab[word] = true
      self._vocab_size = self._vocab_size + 1
    end
  end
end

--: (Classifier, string) -> { [string]: number }
function Clf:scores(text)
  if #self._cat_list == 0 then
    return {}
  end

  local words = tokenize(text)
  local log_scores = {}

  for _, cat_name in ipairs(self._cat_list) do
    local cat = self._cats[cat_name]
    -- log prior
    local score = math.log(cat.doc_count / self._total_docs)

    -- log likelihood for each word (Laplace smoothing)
    local denom = cat.total_words + self._vocab_size
    for _, word in ipairs(words) do
      local count = cat.word_counts[word] or 0
      score = score + math.log((count + 1) / denom)
    end

    log_scores[cat_name] = score
  end

  return softmax(log_scores)
end

function Clf:classify(text)
  local probs = self:scores(text)

  if next(probs) == nil then
    -- No categories trained yet
    return nil, {}
  end

  -- Pick highest probability
  local best_label, best_prob = nil, -math.huge
  for label, prob in pairs(probs) do
    if prob > best_prob then
      best_prob = prob
      best_label = label
    end
  end

  return best_label, probs
end

function Clf:classify_all(texts)
  local results = {}
  for i, text in ipairs(texts) do
    results[i] = self:classify(text)
  end
  return results
end

function Clf:stats()
  local total_words = 0
  for _, cat in pairs(self._cats) do
    total_words = total_words + cat.total_words
  end

  local cat_stats = {}
  for _, cat_name in ipairs(self._cat_list) do
    local cat = self._cats[cat_name]
    cat_stats[cat_name] = { doc_count = cat.doc_count, total_words = cat.total_words }
  end

  return {
    categories = self._cat_list,
    total_docs = self._total_docs,
    vocab_size = self._vocab_size,
    total_words = total_words,
    category_stats = cat_stats,
  }
end

function Clf:serialize()
  local cats = {}
  for cat_name, cat in pairs(self._cats) do
    cats[cat_name] = {
      doc_count = cat.doc_count,
      word_counts = cat.word_counts,
      total_words = cat.total_words,
    }
  end

  local vocab = {}
  for word in pairs(self._vocab) do
    vocab[#vocab + 1] = word
  end

  local cat_list = {}
  for i, v in ipairs(self._cat_list) do
    cat_list[i] = v
  end

  return {
    cats = cats,
    cat_list = cat_list,
    vocab = vocab,
    vocab_size = self._vocab_size,
    total_docs = self._total_docs,
  }
end

function Clf:reset()
  self._cats = {}
  self._cat_list = {}
  self._vocab = {}
  self._vocab_size = 0
  self._total_docs = 0
end

-- Create a new classifier
--: () -> Classifier
function M.new()
  local cats = {} --: { [string]: ClfCat }
  local cat_list = {} --: { [integer]: string }
  local vocab = {} --: { [string]: boolean }
  local clf = setmetatable({
    _cats = cats,
    _cat_list = cat_list,
    _vocab = vocab,
    _vocab_size = 0,
    _total_docs = 0,
  }, Clf) --[[:! Classifier]]
  return clf
end

--:: ClfSerial = { total_docs: integer, vocab_size: integer, vocab: { [integer]: string }, cat_list: { [integer]: string }, cats: { [string]: { doc_count: integer, word_counts: { [string]: integer }, total_words: integer } } }
-- Deserialize a classifier from a table
--: (ClfSerial) -> Classifier
function M.deserialize(t)
  local clf = M.new()
  clf._total_docs = t.total_docs
  clf._vocab_size = t.vocab_size

  for _, word in ipairs(t.vocab) do
    clf._vocab[word] = true
  end

  for i, cat_name in ipairs(t.cat_list) do
    clf._cat_list[i] = cat_name
  end

  for cat_name, cat_data in pairs(t.cats) do
    clf._cats[cat_name] = {
      doc_count = cat_data.doc_count,
      word_counts = cat_data.word_counts,
      total_words = cat_data.total_words,
    }
  end

  return clf
end

return M
