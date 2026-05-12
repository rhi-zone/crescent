if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: query = { type: string, word?: string, words?: { [integer]: string }, op?: string, queries?: { [integer]: unknown }, max_dist?: number, prefix?: string, pattern?: string, ... }
--:: index = { add: (unknown, unknown, string, { fields: { [string]: unknown } | nil } | nil) -> unknown, remove: (unknown, unknown) -> unknown, search: (unknown, query, { limit: number | nil, offset: number | nil, scorer: string | nil, explain: boolean | nil } | nil) -> { results: { [integer]: unknown }, total: number }, facet: (unknown, query, string) -> { [string]: number }, size: () -> integer }

-- Default stop words (common English)
local DEFAULT_STOP_WORDS = {
  ["a"]=true, ["an"]=true, ["the"]=true, ["and"]=true, ["or"]=true,
  ["but"]=true, ["in"]=true, ["on"]=true, ["at"]=true, ["to"]=true,
  ["for"]=true, ["of"]=true, ["is"]=true, ["it"]=true, ["as"]=true,
  ["be"]=true, ["by"]=true, ["we"]=true, ["he"]=true, ["she"]=true,
}

-- Tokenize text: split on non-alphanumeric, lowercase
--: (text: string) -> { [integer]: string }
function M.tokenize(text)
  local tokens = {}
  for w in text:lower():gmatch("[%a%d]+") do
    tokens[#tokens + 1] = w
  end
  return tokens
end

-- Simple Porter-like stemmer (suffix removal, not full Porter2)
--: (word: string) -> string
function M.stem(word)
  local n = #word
  if n <= 3 then return word end
  -- -ies -> -y (carries -> carry)
  if word:sub(-3) == "ies" and n > 4 then return word:sub(1, -4) .. "y" end
  -- -ves -> -f (leaves -> leaf)
  if word:sub(-3) == "ves" and n > 4 then return word:sub(1, -4) .. "f" end
  -- -sses -> -ss
  if word:sub(-4) == "sses" then return word:sub(1, -3) end
  -- -ness -> remove
  if word:sub(-4) == "ness" and n > 5 then return word:sub(1, -5) end
  -- -ment -> remove
  if word:sub(-4) == "ment" and n > 5 then return word:sub(1, -5) end
  -- -ing -> remove (running -> runn, then double-consonant -> run)
  if word:sub(-3) == "ing" and n > 5 then
    local stem = word:sub(1, -4)
    -- un-double final consonant: "runn" -> "run"
    if #stem >= 2 and stem:sub(-1) == stem:sub(-2, -2) then
      stem = stem:sub(1, -2)
    end
    return stem
  end
  -- -ed -> remove
  if word:sub(-2) == "ed" and n > 4 then
    local stem = word:sub(1, -3)
    if #stem >= 2 and stem:sub(-1) == stem:sub(-2, -2) then
      stem = stem:sub(1, -2)
    end
    return stem
  end
  -- -er -> remove
  if word:sub(-2) == "er" and n > 4 then return word:sub(1, -3) end
  -- -ly -> remove
  if word:sub(-2) == "ly" and n > 4 then return word:sub(1, -3) end
  -- -s (not -ss, -us, -is)
  if word:sub(-1) == "s" and n > 3
      and word:sub(-2) ~= "ss" and word:sub(-2) ~= "us" and word:sub(-2) ~= "is" then
    return word:sub(1, -2)
  end
  return word
end

-- Highlight: wrap matched terms in tags
--: (text: string, terms: { [integer]: string }, opts: ({ open: (string | nil), close: (string | nil) } | nil)) -> string
function M.highlight(text, terms, opts)
  opts = opts or {} --[[:! { open: string | nil, close: string | nil }]]
  local open_tag = opts.open or "<mark>"
  local close_tag = opts.close or "</mark>"
  -- build set of lowercased terms
  local term_set = {}
  for i = 1, #terms do
    term_set[terms[i]:lower()] = true
  end
  -- tokenize preserving positions, then reconstruct with highlights
  local result = {}
  local pos = 1
  local len = #text
  while pos <= len do
    -- find start of next word
    local ws, we = text:find("[%a%d]+", pos)
    if not ws then
      result[#result + 1] = text:sub(pos)
      break
    end
    -- non-word text before word
    if ws > pos then
      result[#result + 1] = text:sub(pos, ws - 1)
    end
    local word = text:sub(ws, we)
    if term_set[word:lower()] then
      result[#result + 1] = open_tag .. word .. close_tag
    else
      result[#result + 1] = word
    end
    pos = (we or pos) + 1
  end
  return table.concat(result)
end

-- Edit distance (Levenshtein) between two strings
--: (a: string, b: string) -> number
local function edit_distance(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  -- two-row DP
  local prev = {} --: { [integer]: integer }
  local curr = {} --: { [integer]: integer }
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    curr[0] = i
    local ai = a:sub(i, i)
    for j = 1, lb do
      if ai == b:sub(j, j) then
        curr[j] = prev[j - 1]
      else
        local del = prev[j] + 1
        local ins = curr[j - 1] + 1
        local sub = prev[j - 1] + 1
        local m = del < ins and del or ins
        curr[j] = m < sub and m or sub
      end
    end
    -- swap
    prev, curr = curr, prev
  end
  return prev[lb]
end

-- Query constructors
--: (word: string) -> query
function M.term(word)
  return { type = "term", word = word:lower() }
end

--: (words: { [integer]: string }) -> query
function M.phrase(words)
  local lwords = {}
  for i = 1, #words do lwords[i] = words[i]:lower() end
  return { type = "phrase", words = lwords }
end

--: (op: string, queries: { [integer]: query }) -> (query | nil, string | nil)
function M.boolean(op, queries)
  if op ~= "and" and op ~= "or" and op ~= "not" then
    return nil, "search: boolean op must be 'and', 'or', or 'not'"
  end
  return { type = "boolean", op = op, queries = queries }
end

--: (word: string, max_dist: number | nil) -> query
function M.fuzzy(word, max_dist)
  return { type = "fuzzy", word = word:lower(), max_dist = max_dist or 1 }
end

--: (prefix: string) -> query
function M.prefix(prefix)
  return { type = "prefix", prefix = prefix:lower() }
end

--: (pattern: string) -> query
function M.wildcard(pattern)
  return { type = "wildcard", pattern = pattern:lower() }
end

-- Convert wildcard pattern (? = any char, * = any chars) to Lua pattern
--: (pattern: string) -> string
local function wildcard_to_lua_pattern(pattern)
  local parts = {} --: { [integer]: string }
  local parts_ = parts
  for i = 1, #pattern do
    local c = pattern:sub(i, i)
    if c == "?" then
      parts_[#parts + 1] = "."
    elseif c == "*" then
      parts_[#parts + 1] = ".*"
    elseif c:match("[%(%)%.%%%+%-%[%]%^%$]") then
      parts_[#parts + 1] = "%" .. c
    else
      parts_[#parts + 1] = c
    end
  end
  return "^" .. table.concat(parts) .. "$"
end

-- Create a new search index
--: (opts: ({ tokenize: ((string) -> string[]) | nil, normalize: ((string) -> string) | nil, stop_words: { [string]: boolean } | nil, bm25_k1: (number | nil), bm25_b: (number | nil) } | nil)) -> index
function M.index(opts)
  opts = opts or {} --[[:! { tokenize: ((string) -> string[]) | nil, normalize: ((string) -> string) | nil, stop_words: { [string]: boolean } | nil, bm25_k1: number | nil, bm25_b: number | nil }]]
  local stop_words = opts.stop_words or DEFAULT_STOP_WORDS
  local bm25_k1 = opts.bm25_k1 or 1.5
  local bm25_b  = opts.bm25_b  or 0.75

  local tokenize_fn = opts.tokenize or M.tokenize
  local normalize_fn = opts.normalize

  --:: InvEntry = { positions: { [integer]: integer }, freq: integer }
  -- Inverted index: term -> { doc_id -> { positions: {...}, freq: n } }
  local inverted = {} --[[:! { [string]: { [string]: InvEntry | nil } | nil }]]
  -- Document store: doc_id -> { text: string, length: n, fields: table? }
  local docs = {} --[[:! { [string]: { text: string, length: integer, fields: { [string]: unknown } | nil } | nil }]]
  local doc_count = 0
  local total_length = 0  -- sum of all doc lengths (for BM25 avg)

  -- Internal: normalize + stop-word filter a token list
  local function process_tokens(tokens)
    local result = {}
    for i = 1, #tokens do
      local t = tokens[i]
      if normalize_fn then t = (normalize_fn --[[:! (string) -> string]])(t) end
      if not stop_words[t] then
        result[#result + 1] = t
      end
    end
    return result
  end

  local idx = {}

  -- Add a document
  --: (self: unknown, id: unknown, text: string, opts: ({ fields: ({ [string]: unknown } | nil) } | nil)) -> unknown
  function idx:add(id, text, add_opts)
    if docs[id] then
      local self_ = idx; return self_:update(id --[[:! string]], text)
    end
    add_opts = add_opts or {} --[[:! { fields: { [string]: unknown } | nil }]]
    local raw_tokens = (tokenize_fn --[[:! (string) -> { [integer]: string }]])(text)
    local tokens = process_tokens(raw_tokens)
    local doc_len = #tokens

    docs[id] = { text = text, length = doc_len, fields = add_opts.fields }
    doc_count = doc_count + 1
    total_length = total_length + doc_len

    -- Update inverted index
    for pos, tok in ipairs(tokens) do
      if not inverted[tok] then inverted[tok] = {} end
      if not inverted[tok][id] then
        inverted[tok][id] = { positions = {}, freq = 0 }
      end
      local entry = inverted[tok][id] --[[:! InvEntry]]
      entry.positions[#entry.positions + 1] = pos
      entry.freq = entry.freq + 1
    end

    return self
  end

  -- Remove a document
  --: (self: unknown, id: unknown) -> unknown
  function idx:remove(id)
    local doc = docs[id]
    if not doc then return self end

    -- Remove from inverted index
    local raw_tokens = (tokenize_fn --[[:! (string) -> { [integer]: string }]])(doc.text --[[:! string]])
    local tokens = process_tokens(raw_tokens)
    for _, tok in ipairs(tokens) do
      if inverted[tok] and inverted[tok][id] then
        inverted[tok][id] = nil
        -- Clean up empty term entries
        local has_any = false
        for _ in pairs(inverted[tok]) do has_any = true; break end
        if not has_any then inverted[tok] = nil end
      end
    end

    total_length = total_length - doc.length
    doc_count = doc_count - 1
    docs[id] = nil
    return self
  end

  -- Update a document
  --: (self: unknown, id: unknown, text: string) -> unknown
  function idx:update(id, text)
    local self_ = idx
    self_:remove(id)
    self_:add(id, text)
    return self
  end

  -- Get all doc IDs matching a term (returns set: { doc_id -> true })
  local function posting_set(term)
    local set = {}
    local postings = inverted[term]
    if postings then
      for doc_id in pairs(postings) do
        set[doc_id] = true
      end
    end
    return set
  end

  -- Evaluate a query, returning a set of matching doc_ids
  local function eval_query(query)
    local q = query
    local qt = q.type
    if qt == "term" then
      return posting_set(q.word --[[:! string]])

    elseif qt == "phrase" then
      -- Find docs containing all words, then check adjacency
      local words = q.words --[[:! { [integer]: string }]]
      if #words == 0 then return {} end
      -- Start with docs that contain the first word
      local candidates = posting_set(words[1])
      for i = 2, #words do
        local next_set = posting_set(words[i])
        -- Intersect
        for doc_id in pairs(candidates) do
          if not next_set[doc_id] then
            candidates[doc_id] = nil
          end
        end
      end
      -- Check consecutive positions
      local result = {}
      for doc_id in pairs(candidates) do
        -- Get positions for first word
        local inv1 = inverted[words[1]]
        local inv1_doc = inv1 and inv1[doc_id]
        if not inv1_doc then goto continue_phrase end
        local first_positions = (inv1_doc --[[:! InvEntry]]).positions
        -- For each starting position, check if all subsequent words follow consecutively
        for _, start_pos in ipairs(first_positions) do
          local ok = true
          for i = 2, #words do
            local start_pos_ = start_pos
            local target = start_pos_ + (i - 1)
            local found = false
            local inv_i = inverted[words[i]]
            local inv_i_doc = inv_i and inv_i[doc_id]
            if inv_i_doc then
              for _, p in ipairs((inv_i_doc --[[:! InvEntry]]).positions) do
                if p == target then found = true; break end
              end
            end
            if not found then ok = false; break end
          end
          if ok then
            result[doc_id] = true
            break
          end
        end
        ::continue_phrase::
      end
      return result

    elseif qt == "boolean" then
      local op = q.op --[[:! string]]
      local queries = q.queries --[[:! { [integer]: unknown }]]
      if #queries == 0 then return {} end

      if op == "and" then
        local result = eval_query(queries[1] --[[:! query]])
        for i = 2, #queries do
          local s = eval_query(queries[i] --[[:! query]])
          for doc_id in pairs(result) do
            if not s[doc_id] then result[doc_id] = nil end
          end
        end
        return result

      elseif op == "or" then
        local result = {}
        for i = 1, #queries do
          for doc_id in pairs(eval_query(queries[i] --[[:! query]])) do
            result[doc_id] = true
          end
        end
        return result

      elseif op == "not" then
        -- NOT: all docs minus matches of first query
        -- If two queries: second is base set, subtract first
        local exclude = eval_query(queries[1] --[[:! query]])
        local base
        if #queries >= 2 then
          base = eval_query(queries[2] --[[:! query]])
        else
          base = {}
          for doc_id in pairs(docs) do base[doc_id] = true end
        end
        for doc_id in pairs(exclude) do base[doc_id] = nil end
        return base
      end

    elseif qt == "fuzzy" then
      local word = q.word --[[:! string]]
      local max_dist = (q.max_dist or 1)
      local result = {}
      for term in pairs(inverted) do
        if edit_distance(word, term) <= max_dist then
          for doc_id in pairs(inverted[term]) do
            result[doc_id] = true
          end
        end
      end
      return result

    elseif qt == "prefix" then
      local prefix = q.prefix --[[:! string]]
      local plen = #prefix
      local result = {}
      for term in pairs(inverted) do
        if term:sub(1, plen) == prefix then
          for doc_id in pairs(inverted[term]) do
            result[doc_id] = true
          end
        end
      end
      return result

    elseif qt == "wildcard" then
      local lua_pat = wildcard_to_lua_pattern(q.pattern --[[:! string]])
      local result = {}
      for term in pairs(inverted) do
        if term:match(lua_pat) then
          for doc_id in pairs(inverted[term]) do
            result[doc_id] = true
          end
        end
      end
      return result
    end

    return {}
  end

  -- Collect terms relevant to a query (for scoring)
  --: (query: query) -> { [integer]: string }
  local function collect_query_terms(query)
    local q = query
    local qt = q.type
    if qt == "term" then
      return { q.word --[[:! string]] }
    elseif qt == "phrase" then
      return q.words --[[:! { [integer]: string }]]
    elseif qt == "boolean" then
      local terms = {} --: { [integer]: string }
      local qs = q.queries --[[:! { [integer]: unknown }]]
      for i = 1, #qs do
        for _, t in ipairs(collect_query_terms(qs[i] --[[:! query]])) do
          terms[#terms + 1] = t
        end
      end
      return terms
    elseif qt == "fuzzy" then
      -- collect all terms within distance
      local word = q.word --[[:! string]]
      local max_dist = (q.max_dist or 1)
      local terms = {} --: { [integer]: string }
      for term in pairs(inverted) do
        if edit_distance(word, term) <= max_dist then
          terms[#terms + 1] = term
        end
      end
      return terms
    elseif qt == "prefix" then
      local prefix = q.prefix --[[:! string]]
      local plen = #prefix
      local terms = {} --: { [integer]: string }
      for term in pairs(inverted) do
        if term:sub(1, plen) == prefix then terms[#terms + 1] = term end
      end
      return terms
    elseif qt == "wildcard" then
      local lua_pat = wildcard_to_lua_pattern(q.pattern --[[:! string]])
      local terms = {} --: { [integer]: string }
      for term in pairs(inverted) do
        if term:match(lua_pat) then terms[#terms + 1] = term end
      end
      return terms
    end
    return {}
  end

  -- TF-IDF score for a doc given a list of query terms
  local function score_tfidf(doc_id, terms)
    local doc = docs[doc_id]
    if not doc then return 0 end
    local score = (0.0) --[[:! number]]
    for _, term in ipairs(terms) do
      local postings = inverted[term]
      local tfidf_entry = postings and postings[doc_id]
      if postings and tfidf_entry then
        local e = tfidf_entry --[[:! InvEntry]]
        local tf = e.freq / doc.length
        local df = 0
        for _ in pairs(postings) do df = df + 1 end
        local idf = math.log((doc_count + 1) / (df + 1)) + 1
        score = score + tf * idf
      end
    end
    return score
  end

  -- BM25 score for a doc given a list of query terms
  local function score_bm25(doc_id, terms)
    local doc = docs[doc_id]
    if not doc then return 0 end
    local avg_dl = doc_count > 0 and (total_length / doc_count) or 1
    local score = (0.0) --[[:! number]]
    for _, term in ipairs(terms) do
      local postings = inverted[term]
      local bm25_entry = postings and postings[doc_id]
      if postings and bm25_entry then
        local e = bm25_entry --[[:! InvEntry]]
        local tf = e.freq
        local df = 0
        for _ in pairs(postings) do df = df + 1 end
        local idf = math.log((doc_count - df + 0.5) / (df + 0.5) + 1)
        local dl = doc.length
        local tf_norm = (tf * (bm25_k1 + 1)) /
          (tf + bm25_k1 * (1 - bm25_b + bm25_b * dl / avg_dl))
        score = score + idf * tf_norm
      end
    end
    return score
  end

  -- Build highlight snippets for a doc
  local function make_highlights(doc_id, terms, doc)
    if not doc then return nil end
    local text = doc.text
    local snippet = M.highlight(text, terms)
    -- positions: collect all match positions
    local positions = {}
    local raw_tokens = (tokenize_fn --[[:! (string) -> { [integer]: string }]])(text --[[:! string]])
    local processed = process_tokens(raw_tokens)
    local term_set = {}
    for _, t in ipairs(terms) do term_set[t] = true end
    for pos, tok in ipairs(processed) do
      if term_set[tok] then positions[#positions + 1] = pos end
    end
    return { { field = "text", snippet = snippet, positions = positions } }
  end

  -- Search
  --: (self: unknown, query: query, opts: ({ limit: (number | nil), offset: (number | nil), scorer: (string | nil), explain: (boolean | nil) } | nil)) -> { results: { [integer]: unknown }, total: number }
  function idx:search(query, opts)
    opts = opts or {} --[[:! { limit: number | nil, offset: number | nil, scorer: string | nil, explain: boolean | nil }]]
    local limit  = (opts.limit  or 10) --[[:! number]]
    local offset = (opts.offset or 0) --[[:! number]]
    local scorer = (opts.scorer or "bm25")
    local explain = opts.explain or false

    local matching = eval_query(query)
    local terms = collect_query_terms(query)

    -- Score each matching doc
    local scored = {}
    for doc_id in pairs(matching) do
      local score
      if scorer == "tfidf" then
        score = score_tfidf(doc_id, terms)
      else
        score = score_bm25(doc_id, terms)
      end
      scored[#scored + 1] = { id = doc_id, score = score }
    end

    -- Sort by score descending
    table.sort(scored, function(a, b) return a.score > b.score end)

    local total = (#scored) --[[:! integer]]
    local results = {}
    for i = offset + 1, math.min(offset + limit, total) do
      local s = scored[i]
      local doc = docs[s.id]
      local r = { id = s.id, score = s.score }
      if explain then
        local r_ = r --[[:! { id: string, score: number, highlights: unknown, ... }]]
        r_.highlights = make_highlights(s.id, terms, doc)
      end
      results[#results + 1] = r
    end

    return { results = results, total = total }
  end

  -- Facet: count results by field value
  --: (self: unknown, query: query, field: string) -> { [string]: number }
  function idx:facet(query, field)
    local matching = eval_query(query)
    local counts = {}
    for doc_id in pairs(matching) do
      local doc = docs[doc_id]
      if doc and doc.fields then
        local val = doc.fields[field]
        if val ~= nil then
          local key = tostring(val)
          counts[key] = (counts[key] or 0) + 1
        end
      end
    end
    return counts
  end

  return idx
end

return M
