if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local math_log = math.log
local math_sqrt = math.sqrt
local string_lower = string.lower
local string_gsub = string.gsub
local string_gmatch = string.gmatch
local table_sort = table.sort

local M = {}

--:: CorpusOpts = { tokenize?: (text: string, opts: unknown) -> { [integer]: string }, stopwords?: { [string]: boolean } }
--:: CorpusDoc = { text: string, tf: { [string]: number } }
--:: Corpus = { docs: { [string]: CorpusDoc }, df: { [string]: number }, doc_n: number, idf_cache: { [string]: number } | nil, opts: CorpusOpts | nil, add: (self: Corpus, id: string, text: string) -> nil, remove: (self: Corpus, id: string) -> nil, doc_count: (self: Corpus) -> number, idf: (self: Corpus, term: string) -> number, tfidf: (self: Corpus, id: string) -> ({ [string]: number } | nil, string | nil), tfidf_query: (self: Corpus, query: string) -> { [string]: number }, similarity: (self: Corpus, id_a: string, id_b: string) -> (number | nil, string | nil), search: (self: Corpus, query: string, opts: { limit?: number } | nil) -> { id: string, score: number }[], vocab: (self: Corpus) -> string[], vocab_size: (self: Corpus) -> number, keywords: (self: Corpus, id: string, opts: { limit?: number } | nil) -> ({ term: string, score: number }[] | nil, string | nil) }

-- ── Default stopwords (English, ~80 common words) ───────────────────────
--: { [string]: boolean }
local DEFAULT_STOPWORDS = {}
do
  local words = {
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could",
    "should", "may", "might", "shall", "can", "to", "of", "in", "for",
    "on", "with", "at", "by", "from", "as", "into", "through", "during",
    "before", "after", "above", "below", "between", "out", "off", "over",
    "under", "again", "further", "then", "once", "and", "but", "or", "nor",
    "not", "so", "if", "than", "too", "very", "just", "about", "up", "it",
    "its", "this", "that", "these", "those", "i", "me", "my", "we", "our",
    "you", "your", "he", "him", "his", "she", "her", "they", "them", "their",
  }
  for j = 1, #words do
    DEFAULT_STOPWORDS[words[j]] = true
  end
end

M.DEFAULT_STOPWORDS = DEFAULT_STOPWORDS

-- ── Tokenizer ───────────────────────────────────────────────────────────

--: (text: string, opts: CorpusOpts | nil) -> { [integer]: string }
function M.tokenize(text, opts)
  local lower = string_lower(text)
  local cleaned = string_gsub(lower, "[^%w%s]", " ")
  local tokens = {}
  local n = 0
  local stopwords = opts and opts.stopwords or nil
  for word in string_gmatch(cleaned, "%S+") do
    if not stopwords or not stopwords[word] then
      n = n + 1
      tokens[n] = word
    end
  end
  return tokens
end

-- ── Term Frequency ──────────────────────────────────────────────────────

--: (text: string, opts: CorpusOpts | nil) -> { [string]: number }
function M.tf(text, opts)
  local tokenize_fn = M.tokenize --: (string, CorpusOpts | nil) -> { [integer]: string }
  if opts and opts.tokenize then
    tokenize_fn = opts.tokenize --[[:! (string, CorpusOpts | nil) -> { [integer]: string } ]]
  end
  local tokens = tokenize_fn(text, opts)
  local counts = {}
  for j = 1, #tokens do
    local t = tokens[j]
    counts[t] = (counts[t] or 0) + 1
  end
  return counts
end

--: (text: string, opts: CorpusOpts | nil) -> { [string]: number }
function M.tf_normalized(text, opts)
  local tokenize_fn = M.tokenize --: (string, CorpusOpts | nil) -> { [integer]: string }
  if opts and opts.tokenize then
    tokenize_fn = opts.tokenize --[[:! (string, CorpusOpts | nil) -> { [integer]: string } ]]
  end
  local tokens = tokenize_fn(text, opts)
  local total = #tokens
  if total == 0 then return {} end
  local counts = {} --: { [string]: number }
  for j = 1, #tokens do
    local t = tokens[j]
    counts[t] = (counts[t] or 0) + 1
  end
  local inv = 1 / total
  for term, count in pairs(counts) do
    counts[term] = count * inv
  end
  return counts
end

-- ── Cosine similarity (sparse vectors as {term=score} tables) ───────────

--: (a: { [string]: number }, b: { [string]: number }) -> number
function M.cosine_similarity(a, b)
  local dot = 0 --: number
  local norm_a = 0 --: number
  local norm_b = 0 --: number
  for term, va in pairs(a) do
    norm_a = norm_a + va * va
    local vb = b[term]
    if vb then
      dot = dot + va * vb
    end
  end
  for _, vb in pairs(b) do
    norm_b = norm_b + vb * vb
  end
  if norm_a == 0 or norm_b == 0 then return 0 end
  return dot / (math_sqrt(norm_a) * math_sqrt(norm_b))
end

-- ── Corpus ──────────────────────────────────────────────────────────────

local Corpus = {}
Corpus.__index = Corpus

--: (opts: CorpusOpts | nil) -> Corpus
function M.corpus(opts)
  local self = {
    docs = {} --[[: { [string]: CorpusDoc }]],
    df = {} --[[: { [string]: number }]],
    doc_n = 0 --[[: number]],
    idf_cache = nil --[[: { [string]: number } | nil]],
    opts = opts,
  } --[[:! Corpus]]
  return setmetatable(self, Corpus) --[[:! Corpus]]
end

--: (self: Corpus, id: string, text: string) -> nil
function Corpus:add(id, text)
  if self.docs[id] then
    self:remove(id)
  end
  local tokenize_fn = M.tokenize --: (string, CorpusOpts | nil) -> { [integer]: string }
  if self.opts and self.opts.tokenize then
    tokenize_fn = self.opts.tokenize --[[:! (string, CorpusOpts | nil) -> { [integer]: string } ]]
  end
  local tokens = tokenize_fn(text, self.opts)
  local tf_counts = {} --: { [string]: number }
  for j = 1, #tokens do
    local t = tokens[j]
    tf_counts[t] = (tf_counts[t] or 0) + 1
  end
  self.docs[id] = { text = text, tf = tf_counts }
  self.doc_n = self.doc_n + 1
  local df = self.df
  -- Increment document frequency for each unique term
  for term in pairs(tf_counts) do
    df[term] = (df[term] or 0) + 1
  end
  self.idf_cache = nil
end

--: (self: Corpus, id: string) -> nil
function Corpus:remove(id)
  local doc = self.docs[id]
  if not doc then return end
  local df = self.df
  for term in pairs(doc.tf) do
    local count = df[term]
    if count then
      if count <= 1 then
        df[term] = nil
      else
        df[term] = count - 1
      end
    end
  end
  self.docs[id] = nil
  self.doc_n = self.doc_n - 1
  self.idf_cache = nil
end

--: (self: Corpus) -> number
function Corpus:doc_count()
  return self.doc_n
end

-- Smooth IDF: log((N + 1) / (df + 1)) + 1
--: (self: Corpus, term: string) -> number
function Corpus:idf(term)
  if self.idf_cache then
    local cached = self.idf_cache[term]
    if cached then return cached end
  end
  local n = self.doc_n
  local df_val = self.df[term] or 0
  local val = math_log((n + 1) / (df_val + 1)) + 1
  if not self.idf_cache then
    self.idf_cache = {}
  end
  self.idf_cache[term] = val
  return val
end

-- Compute TF-IDF vector for a stored document
--: (self: Corpus, id: string) -> (({ [string]: number } | nil), (string | nil))
function Corpus:tfidf(id)
  local doc = self.docs[id]
  if not doc then return nil, "document not found: " .. tostring(id) end
  local tf_counts = doc.tf --: { [string]: number }
  -- Count total terms for normalization
  local total = 0 --: number
  for _, count in pairs(tf_counts) do
    total = total + count
  end
  if total == 0 then return {} end
  local inv = 1 / total
  local vec = {} --: { [string]: number }
  for term, count in pairs(tf_counts) do
    vec[term] = (count * inv) * self:idf(term)
  end
  return vec
end

-- Compute TF-IDF vector for an arbitrary query string against corpus IDF
--: (self: Corpus, query: string) -> { [string]: number }
function Corpus:tfidf_query(query)
  local tokenize_fn = M.tokenize --: (string, CorpusOpts | nil) -> { [integer]: string }
  if self.opts and self.opts.tokenize then
    tokenize_fn = self.opts.tokenize --[[:! (string, CorpusOpts | nil) -> { [integer]: string } ]]
  end
  local tokens = tokenize_fn(query, self.opts)
  local total = #tokens
  if total == 0 then return {} end
  local tf_counts = {} --: { [string]: number }
  for j = 1, #tokens do
    local t = tokens[j]
    tf_counts[t] = (tf_counts[t] or 0) + 1
  end
  local inv = 1 / total
  local vec = {} --: { [string]: number }
  for term, count in pairs(tf_counts) do
    vec[term] = (count * inv) * self:idf(term)
  end
  return vec
end

-- Cosine similarity between two stored documents
--: (self: Corpus, id_a: string, id_b: string) -> ((number | nil), (string | nil))
function Corpus:similarity(id_a, id_b)
  local vec_a, err_a = self:tfidf(id_a)
  if not vec_a then return nil, err_a end
  local vec_b, err_b = self:tfidf(id_b)
  if not vec_b then return nil, err_b end
  return M.cosine_similarity(vec_a --[[:! { [string]: number }]], vec_b --[[:! { [string]: number }]])
end

-- Search: rank documents by cosine similarity to query
--: (self: Corpus, query: string, opts: ({ limit: (number  | nil)} | nil)) -> { id: string, score: number }[]
function Corpus:search(query, opts)
  local q_vec = self:tfidf_query(query)
  -- Check if query vector has any non-zero entries
  local has_terms = false
  for _ in pairs(q_vec) do
    has_terms = true
    break
  end
  if not has_terms then return {} end
  local results = {} --: { [integer]: { id: string, score: number } }
  local n = 0
  for id in pairs(self.docs) do
    local d_vec = self:tfidf(id)
    if d_vec then
      local score = M.cosine_similarity(q_vec, d_vec --[[:! { [string]: number }]])
      if score > 0 then
        n = n + 1
        results[n] = { id = id, score = score }
      end
    end
  end
  table.sort(results, function(a, b) return a.score > b.score end)
  local limit = opts and opts.limit --: number | nil
  if limit ~= nil and limit < n then
    local results_any = results --[[: { [integer]: { id: string, score: number } | nil }]]
    for j = limit + 1, n do
      results_any[j] = nil
    end
  end
  return results
end

-- Get all unique terms in the corpus
--: (self: Corpus) -> string[]
function Corpus:vocab()
  local terms = {}
  local n = 0
  for term in pairs(self.df) do
    n = n + 1
    terms[n] = term
  end
  local terms_s = (terms --[[:! { [integer]: string }]])
  for i = 2, #terms_s do
    local v = terms_s[i]; local j = i - 1
    while j >= 1 and terms_s[j] > v do terms_s[j + 1] = terms_s[j]; j = j - 1 end
    terms_s[j + 1] = v
  end
  return terms_s
end

--: (self: Corpus) -> number
function Corpus:vocab_size()
  local n = 0
  for _ in pairs(self.df) do
    n = n + 1
  end
  return n
end

-- Top-k terms by TF-IDF score for a document
--: (self: Corpus, id: string, opts: ({ limit: (number | nil) } | nil)) -> ({ term: string, score: number }[] | nil, string | nil)
function Corpus:keywords(id, opts)
  local vec_raw, err = self:tfidf(id)
  if not vec_raw then return nil, err end
  local vec = vec_raw --[[:! { [string]: number }]]
  local kw = {} --: { [integer]: { term: string, score: number } }
  local n = 0
  for term, score in pairs(vec) do
    n = n + 1
    kw[n] = { term = term, score = score }
  end
  for i = 2, n do
    local v = kw[i] --[[:! { term: string, score: number }]]; local j = i - 1
    while j >= 1 and kw[j].score < v.score do kw[j + 1] = kw[j]; j = j - 1 end
    kw[j + 1] = v
  end
  local limit = opts and opts.limit --: number | nil
  if limit ~= nil and limit < n then
    local kw_any = kw --[[: { [integer]: { term: string, score: number } | nil }]]
    for j = limit + 1, n do
      kw_any[j] = nil
    end
  end
  return kw
end

return M
