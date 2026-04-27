if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Default tokenizer: lowercase, split on non-alpha characters
local function default_tokenize(text)
  local tokens = {}
  for word in text:lower():gmatch("[a-z]+") do
    tokens[#tokens + 1] = word
  end
  return tokens
end

-- Create a new inverted index
-- opts.k1       BM25 term frequency saturation (default 1.5)
-- opts.b        BM25 field length normalization (default 0.75)
-- opts.tokenize custom tokenizer: string -> array of tokens
-- opts.stem     optional stemmer: token -> token
function M.new(opts)
  opts = opts or {}
  local self = {
    k1       = opts.k1 or 1.5,
    b        = opts.b or 0.75,
    tokenize = opts.tokenize or default_tokenize,
    stem     = opts.stem,
    -- postings[term] = { [doc_id] = tf }
    postings = {},
    -- doc_lens[doc_id] = token count
    doc_lens = {},
    -- docs[doc_id] = true
    docs     = {},
    -- total_len: sum of all doc lengths (for avgdl)
    total_len = 0,
    -- N: doc count
    N        = 0,
    -- positions[term][doc_id] = array of positions (1-indexed)
    positions = {},
  }
  return setmetatable(self, { __index = M })
end

-- Tokenize and optionally stem a text string.
-- Returns tokens array and positions table: pos_map[term] = {pos, ...}
local function process_text(self, text)
  local raw = self.tokenize(text)
  local tokens = {}
  local pos_map = {}
  for i, tok in ipairs(raw) do
    local t = self.stem and self.stem(tok) or tok
    tokens[i] = t
    if not pos_map[t] then pos_map[t] = {} end
    local p = pos_map[t]
    p[#p + 1] = i
  end
  return tokens, pos_map
end

-- Add a single document to the index.
function M:add(doc_id, text)
  -- Remove first if already present
  if self.docs[doc_id] then
    self:remove(doc_id)
  end

  local tokens, pos_map = process_text(self, text)
  local len = #tokens

  self.docs[doc_id]     = true
  self.doc_lens[doc_id] = len
  self.total_len        = self.total_len + len
  self.N                = self.N + 1

  for term, positions in pairs(pos_map) do
    local tf = #positions
    -- postings
    if not self.postings[term] then
      self.postings[term] = {}
    end
    self.postings[term][doc_id] = tf
    -- positions
    if not self.positions[term] then
      self.positions[term] = {}
    end
    self.positions[term][doc_id] = positions
  end
end

-- Add multiple documents.
-- docs = array of {id, text} pairs
function M:add_all(docs)
  for _, pair in ipairs(docs) do
    self:add(pair[1], pair[2])
  end
end

-- Remove a document from the index.
function M:remove(doc_id)
  if not self.docs[doc_id] then
    return nil, "doc not found"
  end

  self.total_len = self.total_len - self.doc_lens[doc_id]
  self.N         = self.N - 1
  self.doc_lens[doc_id] = nil
  self.docs[doc_id]     = nil

  -- Remove from postings and positions
  for term, posting in pairs(self.postings) do
    if posting[doc_id] then
      posting[doc_id] = nil
      -- clean up empty postings
      local any = next(posting)
      if not any then
        self.postings[term]  = nil
        self.positions[term] = nil
      else
        self.positions[term][doc_id] = nil
      end
    end
  end
  return true
end

-- Compute avgdl
local function avgdl(self)
  if self.N == 0 then return 0 end
  return self.total_len / self.N
end

-- BM25 score for a single term in a document
local function bm25_term(self, term, doc_id, avg_dl)
  local posting = self.postings[term]
  if not posting then return 0 end
  local tf = posting[doc_id]
  if not tf then return 0 end

  local N  = self.N
  local df = 0
  for _ in pairs(posting) do df = df + 1 end

  local idf = math.log((N - df + 0.5) / (df + 0.5) + 1)
  local dl  = self.doc_lens[doc_id] or 0
  local k1  = self.k1
  local b   = self.b

  local num = tf * (k1 + 1)
  local den = tf + k1 * (1 - b + b * dl / (avg_dl == 0 and 1 or avg_dl))
  return idf * num / den
end

-- Search the index.
-- opts.op    = "OR" (default) or "AND"
-- opts.limit = max results to return
function M:search(query, opts)
  opts = opts or {}
  local op    = opts.op or "OR"
  local limit = opts.limit

  local query_tokens = process_text(self, query)
  -- deduplicate query terms
  local seen = {}
  local terms = {}
  for _, t in ipairs(query_tokens) do
    if not seen[t] then
      seen[t] = true
      terms[#terms + 1] = t
    end
  end

  if #terms == 0 then return {} end

  local avg = avgdl(self)
  local scores = {}

  if op == "AND" then
    -- Candidate docs must contain ALL terms
    -- Start with docs for first term
    local first_posting = self.postings[terms[1]]
    if not first_posting then return {} end

    for doc_id in pairs(first_posting) do
      -- Check all other terms
      local ok = true
      for i = 2, #terms do
        local p = self.postings[terms[i]]
        if not p or not p[doc_id] then
          ok = false
          break
        end
      end
      if ok then
        local score = 0
        for _, term in ipairs(terms) do
          score = score + bm25_term(self, term, doc_id, avg)
        end
        scores[#scores + 1] = { id = doc_id, score = score }
      end
    end
  else
    -- OR: union of all doc sets
    local candidate_set = {}
    for _, term in ipairs(terms) do
      local posting = self.postings[term]
      if posting then
        for doc_id in pairs(posting) do
          candidate_set[doc_id] = true
        end
      end
    end

    for doc_id in pairs(candidate_set) do
      local score = 0
      for _, term in ipairs(terms) do
        score = score + bm25_term(self, term, doc_id, avg)
      end
      scores[#scores + 1] = { id = doc_id, score = score }
    end
  end

  -- Sort descending by score, with doc id as tiebreaker for stability
  table.sort(scores, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)

  if limit and #scores > limit then
    local trimmed = {}
    for i = 1, limit do
      trimmed[i] = scores[i]
    end
    return trimmed
  end

  return scores
end

-- Phrase search: terms must appear adjacent and in order.
function M:phrase_search(query)
  local query_tokens = process_text(self, query)
  local terms = query_tokens
  if #terms == 0 then return {} end

  -- Find candidate docs: must contain all terms
  local first_posting = self.postings[terms[1]]
  if not first_posting then return {} end

  local avg = avgdl(self)
  local scores = {}

  for doc_id in pairs(first_posting) do
    -- check all terms present
    local all_present = true
    for i = 2, #terms do
      local p = self.postings[terms[i]]
      if not p or not p[doc_id] then
        all_present = false
        break
      end
    end
    if all_present then
      -- Check adjacency: for each position of terms[1], check terms[i] at pos+i-1
      local pos1 = self.positions[terms[1]][doc_id]
      local found = false
      for _, start_pos in ipairs(pos1) do
        local match = true
        for i = 2, #terms do
          local pi = self.positions[terms[i]][doc_id]
          -- binary-search or linear scan for start_pos + i - 1
          local target = start_pos + i - 1
          local hit = false
          for _, p in ipairs(pi) do
            if p == target then hit = true; break end
          end
          if not hit then match = false; break end
        end
        if match then found = true; break end
      end
      if found then
        local score = 0
        for _, term in ipairs(terms) do
          score = score + bm25_term(self, term, doc_id, avg)
        end
        scores[#scores + 1] = { id = doc_id, score = score }
      end
    end
  end

  table.sort(scores, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.id < b.id
  end)
  return scores
end

-- Return the number of indexed documents.
function M:doc_count()
  return self.N
end

-- Return the number of distinct terms.
function M:term_count()
  local n = 0
  for _ in pairs(self.postings) do n = n + 1 end
  return n
end

-- Return the list of terms present in a document.
function M:terms_for(doc_id)
  if not self.docs[doc_id] then return nil, "doc not found" end
  local result = {}
  for term, posting in pairs(self.postings) do
    if posting[doc_id] then
      result[#result + 1] = term
    end
  end
  return result
end

-- Serialize the index to a plain Lua table.
function M:serialize()
  local t = {
    k1        = self.k1,
    b         = self.b,
    total_len = self.total_len,
    N         = self.N,
    postings  = {},
    doc_lens  = {},
    docs      = {},
    positions = {},
  }
  -- docs: encode keys as array of {id}
  -- We need to handle both string and number keys.
  -- Store as array of pairs.
  local docs_arr = {}
  for id in pairs(self.docs) do
    docs_arr[#docs_arr + 1] = id
  end
  t.docs = docs_arr

  local doc_lens_arr = {}
  for id, len in pairs(self.doc_lens) do
    doc_lens_arr[#doc_lens_arr + 1] = { id, len }
  end
  t.doc_lens = doc_lens_arr

  -- postings: array of { term, { {doc_id, tf}, ... } }
  local postings_arr = {}
  for term, posting in pairs(self.postings) do
    local entries = {}
    for doc_id, tf in pairs(posting) do
      entries[#entries + 1] = { doc_id, tf }
    end
    postings_arr[#postings_arr + 1] = { term, entries }
  end
  t.postings = postings_arr

  -- positions: array of { term, { {doc_id, {pos, ...}}, ... } }
  local positions_arr = {}
  for term, pos_docs in pairs(self.positions) do
    local entries = {}
    for doc_id, pos_list in pairs(pos_docs) do
      entries[#entries + 1] = { doc_id, pos_list }
    end
    positions_arr[#positions_arr + 1] = { term, entries }
  end
  t.positions = positions_arr

  return t
end

-- Restore an index from a serialized table.
-- Note: custom tokenizer and stemmer are not serialized;
-- pass them via opts if needed.
function M.deserialize(t, opts)
  opts = opts or {}
  local self = M.new({
    k1       = t.k1,
    b        = t.b,
    tokenize = opts.tokenize,
    stem     = opts.stem,
  })
  self.total_len = t.total_len
  self.N         = t.N

  for _, id in ipairs(t.docs) do
    self.docs[id] = true
  end

  for _, pair in ipairs(t.doc_lens) do
    self.doc_lens[pair[1]] = pair[2]
  end

  for _, entry in ipairs(t.postings) do
    local term, pairs_arr = entry[1], entry[2]
    local posting = {}
    for _, p in ipairs(pairs_arr) do
      posting[p[1]] = p[2]
    end
    self.postings[term] = posting
  end

  for _, entry in ipairs(t.positions) do
    local term, pairs_arr = entry[1], entry[2]
    local pos_docs = {}
    for _, p in ipairs(pairs_arr) do
      pos_docs[p[1]] = p[2]
    end
    self.positions[term] = pos_docs
  end

  return self
end

return M
