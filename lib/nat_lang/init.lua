if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- nat_lang: rule-based natural language processing utilities.
-- No external models — tokenization, stemming, TF-IDF, sentiment, POS, NER.

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Tokenization
-- ---------------------------------------------------------------------------

-- Split text on whitespace and punctuation boundaries.
-- Returns tokens including punctuation marks as separate tokens.
--: (string) -> { string }
M.tokenize = function(text)
  local tokens = {}
  -- Iterate over word sequences and standalone punctuation
  for tok in text:gmatch("[%w'%-]+[%w]*|[%p]") do
    tokens[#tokens + 1] = tok
  end
  -- Re-implement: scan character by character grouping word chars vs punct
  tokens = {}
  local i = 1
  local len = #text
  while i <= len do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c:match("[%w']") then
      -- gather word (allow apostrophes and hyphens mid-word)
      local j = i
      while j <= len and text:sub(j, j):match("[%w'%-]") do
        j = j + 1
      end
      tokens[#tokens + 1] = text:sub(i, j - 1)
      i = j
    else
      -- punctuation character
      tokens[#tokens + 1] = c
      i = i + 1
    end
  end
  return tokens
end

-- Words only — no punctuation tokens.
--: (string) -> { string }
M.word_tokenize = function(text)
  local words = {}
  for w in text:gmatch("[%w'%-]+") do
    words[#words + 1] = w
  end
  return words
end

-- Split text into sentences on . ! ? boundaries.
--: (string) -> { string }
M.sent_tokenize = function(text)
  local sentences = {}
  -- Split on sentence-ending punctuation followed by whitespace or end
  local buf = ""
  local i = 1
  local len = #text
  while i <= len do
    local c = text:sub(i, i)
    buf = buf .. c
    if c == "." or c == "!" or c == "?" then
      -- peek ahead: if next char is space/end and this isn't an abbreviation context
      local next = text:sub(i + 1, i + 1)
      if next == "" or next:match("%s") then
        local s = buf:match("^%s*(.-)%s*$")
        if s ~= "" then
          sentences[#sentences + 1] = s
        end
        buf = ""
      end
    end
    i = i + 1
  end
  -- remainder
  local rem = buf:match("^%s*(.-)%s*$")
  if rem ~= "" then
    sentences[#sentences + 1] = rem
  end
  return sentences
end

-- ---------------------------------------------------------------------------
-- Normalization
-- ---------------------------------------------------------------------------

-- Lowercase and collapse whitespace.
--: (string) -> string
M.normalize = function(text)
  return (text:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- Porter Stemmer (simplified — covers the most common rules)
-- ---------------------------------------------------------------------------

local function has_vowel(s)
  return s:find("[aeiou]") ~= nil
end

local function ends_double_consonant(s)
  local n = #s
  if n < 2 then return false end
  local c = s:sub(n, n)
  return c ~= "a" and c ~= "e" and c ~= "i" and c ~= "o" and c ~= "u"
    and s:sub(n - 1, n - 1) == c
end

local function cvc(s)
  local n = #s
  if n < 3 then return false end
  local c1 = s:sub(n - 2, n - 2)
  local v  = s:sub(n - 1, n - 1)
  local c2 = s:sub(n, n)
  local vowels = "aeiou"
  return not vowels:find(c1, 1, true)
    and     vowels:find(v,  1, true)
    and not vowels:find(c2, 1, true)
    and c2 ~= "w" and c2 ~= "x" and c2 ~= "y"
end

-- Count VC sequences (measure m) in a word stem
local function measure(s)
  local m = 0
  local in_vowel = false
  local vowels = "aeiou"
  for k = 1, #s do
    local c = s:sub(k, k)
    local is_v = vowels:find(c, 1, true) ~= nil
    if is_v then
      in_vowel = true
    elseif in_vowel then
      m = m + 1
      in_vowel = false
    end
  end
  return m
end

--: (string) -> string
M.stem = function(word)
  word = word:lower()
  local n = #word

  -- Step 1a
  if word:sub(-4) == "sses" then
    word = word:sub(1, -3) -- remove ss → keep ss
  elseif word:sub(-3) == "ies" then
    word = word:sub(1, -4) .. "i"
  elseif word:sub(-2) == "ss" then
    -- no change
  elseif word:sub(-1) == "s" then
    local stem = word:sub(1, -2)
    if has_vowel(stem) then
      word = stem
    end
  end

  -- Step 1b
  local step1b_extra = false
  if word:sub(-3) == "eed" then
    local stem = word:sub(1, -4)
    if measure(stem) > 0 then word = stem .. "ee" end
  elseif word:sub(-2) == "ed" then
    local stem = word:sub(1, -3)
    if has_vowel(stem) then
      word = stem
      step1b_extra = true
    end
  elseif word:sub(-3) == "ing" then
    local stem = word:sub(1, -4)
    if has_vowel(stem) then
      word = stem
      step1b_extra = true
    end
  end

  if step1b_extra then
    if word:sub(-2) == "at" or word:sub(-2) == "bl" or word:sub(-2) == "iz" then
      word = word .. "e"
    elseif ends_double_consonant(word) and
        not (word:sub(-1) == "l" or word:sub(-1) == "s" or word:sub(-1) == "z") then
      word = word:sub(1, -2)
    elseif measure(word) == 1 and cvc(word) then
      word = word .. "e"
    end
  end

  -- Step 1c
  if word:sub(-1) == "y" and has_vowel(word:sub(1, -2)) then
    word = word:sub(1, -2) .. "i"
  end

  -- Step 2
  local step2 = {
    {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"}, {"anci", "ance"},
    {"izer", "ize"}, {"abli", "able"}, {"alli", "al"}, {"entli", "ent"},
    {"eli", "e"}, {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
    {"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"}, {"fulness", "ful"},
    {"ousness", "ous"}, {"aliti", "al"}, {"iviti", "ive"}, {"biliti", "ble"},
  }
  for _, pair in ipairs(step2) do
    local suffix, replacement = pair[1], pair[2]
    if word:sub(-#suffix) == suffix then
      local stem = word:sub(1, -#suffix - 1)
      if measure(stem) > 0 then
        word = stem .. replacement
      end
      break
    end
  end

  -- Step 3
  local step3 = {
    {"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
    {"ical", "ic"}, {"ful", ""}, {"ness", ""},
  }
  for _, pair in ipairs(step3) do
    local suffix, replacement = pair[1], pair[2]
    if word:sub(-#suffix) == suffix then
      local stem = word:sub(1, -#suffix - 1)
      if measure(stem) > 0 then
        word = stem .. replacement
      end
      break
    end
  end

  -- Step 4
  local step4 = {
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement",
    "ment", "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
  }
  for _, suffix in ipairs(step4) do
    if word:sub(-#suffix) == suffix then
      local stem = word:sub(1, -#suffix - 1)
      if measure(stem) > 1 then
        if suffix == "ion" then
          local last = stem:sub(-1)
          if last == "s" or last == "t" then
            word = stem
          end
        else
          word = stem
        end
      end
      break
    end
  end

  -- Step 5a
  if word:sub(-1) == "e" then
    local stem = word:sub(1, -2)
    if measure(stem) > 1 then
      word = stem
    elseif measure(stem) == 1 and not cvc(stem) then
      word = stem
    end
  end

  -- Step 5b
  if measure(word) > 1 and ends_double_consonant(word) and word:sub(-1) == "l" then
    word = word:sub(1, -2)
  end

  return word
end

-- ---------------------------------------------------------------------------
-- Lemmatization (rule-based, irregular verbs + common patterns)
-- ---------------------------------------------------------------------------

local irregulars = {
  -- irregular verbs (past → base)
  ran = "run", gone = "go", went = "go", was = "be", were = "be",
  been = "be", had = "have", did = "do", done = "do", said = "say",
  saw = "see", seen = "see", came = "come", got = "get", gotten = "get",
  made = "make", took = "take", taken = "take", knew = "know", known = "know",
  thought = "think", brought = "bring", bought = "buy", caught = "catch",
  taught = "teach", fought = "fight", found = "find", lost = "lose",
  left = "leave", told = "tell", felt = "feel", kept = "keep",
  sent = "send", built = "build", stood = "stand", led = "lead",
  read = "read", heard = "hear", held = "hold", grew = "grow", grown = "grow",
  drew = "draw", drawn = "draw", drove = "drive", driven = "drive",
  wrote = "write", written = "write", spoke = "speak", spoken = "speak",
  broke = "break", broken = "break", chose = "choose", chosen = "choose",
  -- irregular nouns
  mice = "mouse", geese = "goose", men = "man", women = "woman",
  children = "child", teeth = "tooth", feet = "foot", oxen = "ox",
  -- adjectives
  better = "good", best = "good", worse = "bad", worst = "bad",
}

--: (string) -> string
M.lemmatize = function(word)
  local lower = word:lower()
  if irregulars[lower] then return irregulars[lower] end
  -- -ing → base (running → run)
  if lower:sub(-3) == "ing" then
    local stem = lower:sub(1, -4)
    if #stem >= 2 then
      -- double consonant: running → run
      if stem:sub(-1) == stem:sub(-2, -2) then
        return stem:sub(1, -2)
      end
      return stem
    end
  end
  -- -ed → base
  if lower:sub(-2) == "ed" then
    local stem = lower:sub(1, -3)
    if #stem >= 2 then
      if stem:sub(-1) == stem:sub(-2, -2) then
        return stem:sub(1, -2)
      end
      return stem
    end
  end
  -- -s → base (simple)
  if lower:sub(-2) == "es" then
    local stem = lower:sub(1, -3)
    if #stem >= 2 then return stem end
  end
  if lower:sub(-1) == "s" and lower:sub(-2) ~= "ss" then
    local stem = lower:sub(1, -2)
    if #stem >= 2 then return stem end
  end
  return lower
end

-- ---------------------------------------------------------------------------
-- Stopwords
-- ---------------------------------------------------------------------------

local _en_stopwords_list = {
  "a","an","the","and","or","but","in","on","at","to","for","of","with",
  "by","from","is","are","was","were","be","been","being","have","has","had",
  "do","does","did","will","would","could","should","may","might","shall",
  "can","need","dare","ought","used","it","its","this","that","these","those",
  "i","me","my","myself","we","our","ours","ourselves","you","your","yours",
  "yourself","yourselves","he","him","his","himself","she","her","hers",
  "herself","they","them","their","theirs","themselves","what","which","who",
  "whom","when","where","why","how","all","both","each","few","more","most",
  "other","some","such","no","not","only","same","so","than","too","very",
  "just","about","above","after","before","between","into","through","during",
  "up","down","out","off","over","under","again","then","once","here","there",
  "s","t","re","ve","d","ll","m",
}

local _stopword_cache = {}

--: (string) -> { [string]: boolean }
M.stopwords = function(lang)
  if lang ~= "en" then return {} end
  if _stopword_cache["en"] then return _stopword_cache["en"] end
  local set = {}
  for _, w in ipairs(_en_stopwords_list) do
    set[w] = true
  end
  _stopword_cache["en"] = set
  return set
end

--: ({ string }, string) -> { string }
M.remove_stopwords = function(words, lang)
  local stops = M.stopwords(lang)
  local out = {}
  for _, w in ipairs(words) do
    if not stops[w:lower()] then
      out[#out + 1] = w
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- N-grams and skip-grams
-- ---------------------------------------------------------------------------

--: ({ string }, number) -> { { string } }
M.ngrams = function(words, n)
  local result = {}
  for i = 1, #words - n + 1 do
    local gram = {}
    for j = 0, n - 1 do
      gram[j + 1] = words[i + j]
    end
    result[#result + 1] = gram
  end
  return result
end

-- k = number of words to skip between chosen words
--: ({ string }, number, number) -> { { string } }
M.skipgrams = function(words, n, k)
  local result = {}
  local function collect(start, chosen, remaining)
    if remaining == 0 then
      result[#result + 1] = chosen
      return
    end
    local max_start = #words - (remaining - 1) * (k + 1)
    for i = start, max_start do
      local new_chosen = {}
      for _, v in ipairs(chosen) do new_chosen[#new_chosen + 1] = v end
      new_chosen[#new_chosen + 1] = words[i]
      collect(i + 1 + k, new_chosen, remaining - 1)  -- skip k words
    end
  end
  -- For skip-k n-grams: pick n words with at most k skips between each pair
  -- Standard definition: consecutive pairs have exactly k words skipped
  -- Re-implement as: pick positions i1 < i2 < ... < in where i(j+1) - i(j) <= k+1
  result = {}
  local function gen(pos, chosen)
    if #chosen == n then
      result[#result + 1] = chosen
      return
    end
    local remaining = n - #chosen
    for i = pos, #words - remaining + 1 do
      if #chosen == 0 or i - chosen[#chosen].pos <= k + 1 then
        local new_chosen = {}
        for _, v in ipairs(chosen) do new_chosen[#new_chosen + 1] = v end
        new_chosen[#new_chosen + 1] = { word = words[i], pos = i }
        gen(i + 1, new_chosen)
      end
    end
  end
  gen(1, {})
  -- flatten pos out
  local flat = {}
  for _, gram in ipairs(result) do
    local g = {}
    for _, item in ipairs(gram) do g[#g + 1] = item.word end
    flat[#flat + 1] = g
  end
  return flat
end

-- ---------------------------------------------------------------------------
-- Bag of words / TF
-- ---------------------------------------------------------------------------

--: ({ string }) -> { [string]: number }
M.bag_of_words = function(words)
  local bow = {}
  for _, w in ipairs(words) do
    local lw = w:lower()
    bow[lw] = (bow[lw] or 0) + 1
  end
  return bow
end

--: ({ string }) -> { [string]: number }
M.term_freq = function(words)
  local bow = M.bag_of_words(words)
  local total = #words
  if total == 0 then return {} end
  local tf = {}
  for w, count in pairs(bow) do
    tf[w] = count / total
  end
  return tf
end

-- ---------------------------------------------------------------------------
-- TF-IDF (corpus-level)
-- ---------------------------------------------------------------------------

-- docs: array of word-arrays
-- Returns: tfidf[doc_idx] = {word → score}
--: ({ { string } }) -> { { [string]: number } }
M.tfidf = function(docs)
  local n_docs = #docs
  -- Compute document frequency for each word
  local df = {}
  for _, doc in ipairs(docs) do
    local seen = {}
    for _, w in ipairs(doc) do
      local lw = w:lower()
      if not seen[lw] then
        seen[lw] = true
        df[lw] = (df[lw] or 0) + 1
      end
    end
  end
  -- Compute TF-IDF per document
  local result = {}
  for d, doc in ipairs(docs) do
    local tf = M.term_freq(doc)
    local scores = {}
    for w, freq in pairs(tf) do
      local idf = math.log(n_docs / (df[w] or 1))
      scores[w] = freq * idf
    end
    result[d] = scores
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Edit distance (Wagner-Fischer / Levenshtein)
-- ---------------------------------------------------------------------------

--: (string, string) -> number
M.edit_distance = function(s1, s2)
  local m, n = #s1, #s2
  -- Use two-row rolling array
  local prev = {}
  local curr = {}
  for j = 0, n do prev[j] = j end
  for i = 1, m do
    curr[0] = i
    for j = 1, n do
      if s1:sub(i, i) == s2:sub(j, j) then
        curr[j] = prev[j - 1]
      else
        curr[j] = 1 + math.min(prev[j], curr[j - 1], prev[j - 1])
      end
    end
    for j = 0, n do prev[j] = curr[j] end
  end
  return prev[n]
end

-- Normalized similarity: 1 - (edit_distance / max_len)
--: (string, string) -> number
M.similarity = function(s1, s2)
  local max_len = math.max(#s1, #s2)
  if max_len == 0 then return 1.0 end
  return 1.0 - M.edit_distance(s1, s2) / max_len
end

-- ---------------------------------------------------------------------------
-- Named Entity Recognition (rule-based gazetteer + capitalization)
-- ---------------------------------------------------------------------------

local location_gazetteer = {
  Paris=true, London=true, Berlin=true, Tokyo=true, Beijing=true, Rome=true,
  Madrid=true, Moscow=true, Cairo=true, Sydney=true, Delhi=true, Mumbai=true,
  Shanghai=true, Lagos=true, Mexico=true, NewYork=true, Chicago=true,
  LosAngeles=true, Toronto=true, Seoul=true, Bangkok=true, Singapore=true,
  Amsterdam=true, Brussels=true, Vienna=true, Warsaw=true, Prague=true,
  Budapest=true, Lisbon=true, Athens=true, Istanbul=true, Dubai=true,
  Africa=true, Asia=true, Europe=true, America=true, Australia=true,
  France=true, Germany=true, Italy=true, Spain=true, Russia=true,
  China=true, Japan=true, India=true, Brazil=true, Canada=true,
  England=true, Scotland=true, Wales=true, Ireland=true, Argentina=true,
  Egypt=true, Nigeria=true, Kenya=true, Mexico=true, Thailand=true,
}

local org_gazetteer = {
  Google=true, Apple=true, Microsoft=true, Amazon=true, Facebook=true,
  Meta=true, Tesla=true, Netflix=true, Twitter=true, IBM=true, Intel=true,
  Oracle=true, Cisco=true, Adobe=true, Uber=true, Airbnb=true,
  NASA=true, WHO=true, UN=true, NATO=true, EU=true, FBI=true, CIA=true,
  BBC=true, CNN=true, Reuters=true,
}

local date_pattern = "^%d%d%d%d$"  -- years like 2023

-- Common first names for PERSON detection even at sentence start
local person_names = {
  John=true, Jane=true, Mary=true, James=true, Robert=true, Michael=true,
  William=true, David=true, Richard=true, Joseph=true, Thomas=true,
  Charles=true, Christopher=true, Daniel=true, Matthew=true, Anthony=true,
  Mark=true, Donald=true, Steven=true, Paul=true, Andrew=true, Joshua=true,
  Kevin=true, Brian=true, George=true, Timothy=true, Ronald=true, Edward=true,
  Jason=true, Jeffrey=true, Ryan=true, Jacob=true, Gary=true, Nicholas=true,
  Eric=true, Jonathan=true, Stephen=true, Larry=true, Justin=true, Scott=true,
  Frank=true, Patrick=true, Benjamin=true, Raymond=true, Alice=true,
  Patricia=true, Jennifer=true, Linda=true, Barbara=true, Elizabeth=true,
  Susan=true, Jessica=true, Sarah=true, Karen=true, Lisa=true, Nancy=true,
  Betty=true, Dorothy=true, Sandra=true, Ashley=true, Kimberly=true,
  Donna=true, Emily=true, Carol=true, Michelle=true, Amanda=true,
  Melissa=true, Deborah=true, Stephanie=true, Rebecca=true, Sharon=true,
  Laura=true, Cynthia=true, Katherine=true, Amy=true, Angela=true,
  -- Common surnames also used standalone
  Smith=true, Jones=true, Williams=true, Brown=true, Davis=true, Miller=true,
  Wilson=true, Moore=true, Taylor=true, Anderson=true, Jackson=true,
  Harris=true, Martin=true, Thompson=true, Garcia=true, Martinez=true,
  Robinson=true, Clark=true, Rodriguez=true, Lewis=true, Lee=true,
  Walker=true, Hall=true, Allen=true, Young=true, Hernandez=true,
  King=true, Wright=true, Lopez=true, Hill=true, Scott=true, Green=true,
  Adams=true, Baker=true, Gonzalez=true, Nelson=true, Carter=true,
  Mitchell=true, Perez=true, Roberts=true, Turner=true, Phillips=true,
  Campbell=true, Parker=true, Evans=true, Edwards=true, Collins=true,
  Stewart=true, Sanchez=true, Morris=true, Rogers=true, Reed=true,
}

--: (string) -> { { string } }
M.extract_entities = function(text)
  local tokens = M.tokenize(text)
  local entities = {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    -- Check if capitalized
    local first_char = tok:sub(1, 1)
    if first_char:match("%u") then
      local entity_text = tok
      if location_gazetteer[tok] then
        entities[#entities + 1] = { entity_text, "LOCATION" }
      elseif org_gazetteer[tok] then
        entities[#entities + 1] = { entity_text, "ORGANIZATION" }
      elseif person_names[tok] then
        entities[#entities + 1] = { entity_text, "PERSON" }
      else
        -- Unknown capitalized word: tag as PERSON only when not at sentence start
        -- (to avoid tagging normal sentence-opening words)
        local prev = tokens[i - 1]
        local is_sentence_start = (i == 1) or (prev == "." or prev == "!" or prev == "?")
        if not is_sentence_start then
          entities[#entities + 1] = { entity_text, "PERSON" }
        end
      end
    elseif tok:match(date_pattern) then
      entities[#entities + 1] = { tok, "DATE" }
    end
    i = i + 1
  end
  return entities
end

-- ---------------------------------------------------------------------------
-- POS Tagging (simplified rule-based, Brill-like)
-- ---------------------------------------------------------------------------

-- Common word lists for tagging
local determiners = { the=true, a=true, an=true, this=true, that=true,
  these=true, those=true, my=true, your=true, his=true, her=true,
  its=true, our=true, their=true, every=true, each=true, any=true, }

local prepositions = { ["in"]=true, on=true, at=true, by=true, ["for"]=true,
  with=true, about=true, against=true, between=true, into=true,
  through=true, during=true, before=true, after=true, above=true,
  below=true, from=true, up=true, down=true, out=true, off=true,
  over=true, under=true, of=true, to=true, }

local conjunctions = { ["and"]=true, ["or"]=true, but=true, nor=true, so=true,
  yet=true, ["for"]=true, although=true, because=true, since=true,
  unless=true, ["until"]=true, ["while"]=true, }

local pronouns = { i=true, me=true, my=true, myself=true, we=true,
  us=true, our=true, ourselves=true, you=true, your=true, yourself=true,
  he=true, him=true, his=true, himself=true, she=true, her=true,
  herself=true, it=true, its=true, itself=true, they=true, them=true,
  their=true, themselves=true, who=true, whom=true, whose=true, }

local aux_verbs = { is=true, are=true, was=true, were=true, be=true,
  been=true, being=true, have=true, has=true, had=true, ["do"]=true,
  does=true, did=true, will=true, would=true, could=true, should=true,
  may=true, might=true, shall=true, can=true, }

local common_adjectives = {
  good=true, bad=true, big=true, small=true, large=true, great=true,
  high=true, low=true, old=true, new=true, long=true, short=true,
  hot=true, cold=true, fast=true, slow=true, hard=true, soft=true,
  quick=true, dark=true, light=true, bright=true, clean=true, fresh=true,
  free=true, full=true, open=true, clear=true, early=true, late=true,
  right=true, wrong=true, ["true"]=true, ["false"]=true, real=true, sure=true,
}

local adverbs = { very=true, really=true, quite=true, just=true, also=true,
  often=true, never=true, always=true, sometimes=true, usually=true,
  here=true, there=true, now=true, ["then"]=true, still=true, already=true,
  soon=true, again=true, even=true, well=true, too=true, much=true, }

--: ({ string }) -> { { string } }
M.pos_tag = function(words)
  local tags = {}
  local n = #words
  for i, word in ipairs(words) do
    local lw = word:lower()
    local tag

    if determiners[lw] then
      tag = "DT"
    elseif pronouns[lw] then
      tag = "PRP"
    elseif aux_verbs[lw] then
      tag = "VBZ"
    elseif prepositions[lw] then
      tag = "IN"
    elseif conjunctions[lw] then
      tag = "CC"
    elseif adverbs[lw] then
      tag = "RB"
    elseif common_adjectives[lw] then
      tag = "JJ"
    elseif lw:match("ly$") then
      tag = "RB"  -- adverb
    elseif lw:match("ing$") then
      tag = "VBG" -- gerund/present participle
    elseif lw:match("ed$") then
      tag = "VBD" -- past tense
    elseif lw:match("er$") or lw:match("est$") then
      tag = "JJR" -- comparative/superlative
    elseif lw:match("ful$") or lw:match("ous$") or lw:match("ive$") or lw:match("al$") then
      tag = "JJ"  -- adjective suffix
    elseif lw:match("tion$") or lw:match("ness$") or lw:match("ment$") or lw:match("ity$") then
      tag = "NN"  -- noun suffix
    elseif word:match("^%u") then
      tag = "NNP" -- proper noun
    else
      -- Context-based: word after DT or JJ is usually NN
      local prev_tag = tags[i - 1] and tags[i - 1][2]
      if prev_tag == "DT" or prev_tag == "JJ" or prev_tag == "JJR" then
        tag = "NN"
      elseif lw:match("s$") then
        -- Could be VBZ (3rd sing present) or NNS (plural)
        -- If previous is DT/JJ/NN, treat as NNS; else VBZ
        if prev_tag == "DT" or prev_tag == "JJ" or prev_tag == "NN" or prev_tag == "NNP" then
          tag = "NNS"
        else
          tag = "VBZ"
        end
      else
        tag = "NN"
      end
    end

    tags[i] = { word, tag }
  end
  return tags
end

-- ---------------------------------------------------------------------------
-- Sentiment analysis (lexicon-based)
-- ---------------------------------------------------------------------------

local positive_words = {
  love=2, like=1, good=1, great=2, excellent=2, wonderful=2, amazing=2,
  fantastic=2, awesome=2, best=2, perfect=2, happy=1, joy=1, glad=1,
  pleased=1, enjoy=1, nice=1, beautiful=1, brilliant=2, superb=2,
  outstanding=2, positive=1, better=1, benefit=1, helpful=1, friendly=1,
  kind=1, smart=1, clever=1, easy=1, clean=1, fresh=1, free=1, safe=1,
  strong=1, success=1, successful=1, win=1, winning=1, victory=1,
  recommend=1, innovative=1, creative=1, inspiring=1, fun=1, exciting=1,
  delight=1, delightful=1, pleased=1, thank=1, thanks=1, appreciate=1,
  quality=1, reliable=1, trustworthy=1, honest=1, fair=1, generous=1,
}

local negative_words = {
  hate=2, dislike=1, bad=1, terrible=2, horrible=2, awful=2, worst=2,
  poor=1, ugly=1, nasty=1, disgusting=2, pathetic=1, sad=1, angry=1,
  annoying=1, frustrating=1, disappointing=1, disappointed=1, problem=1,
  fail=1, failure=1, error=1, wrong=1, broken=1, useless=1, waste=1,
  never=1, nothing=1, worse=1, difficult=1, hard=1, confusing=1,
  slow=1, expensive=1, overpriced=1, scam=1, fraud=1, lie=1, lies=1,
  misleading=1, fake=1, corrupt=1, unfair=1, rude=1, mean=1, cruel=1,
  damage=1, dangerous=1, harmful=1, toxic=1, painful=1, suffering=1,
  complaint=1, complain=1, refund=1, broken=1, crash=1, bug=1,
}

local negators = { ["not"]=true, ["no"]=true, never=true, neither=true,
  nobody=true, nothing=true, nowhere=true, nor=true, }

--: (string) -> number
M.sentiment = function(text)
  local words = M.word_tokenize(text:lower())
  local score = 0
  local negated = false
  for i, w in ipairs(words) do
    if negators[w] then
      negated = true
    elseif positive_words[w] then
      score = score + (negated and -positive_words[w] or positive_words[w])
      negated = false
    elseif negative_words[w] then
      score = score - (negated and -negative_words[w] or negative_words[w])
      negated = false
    else
      negated = false
    end
  end
  -- Normalize to -1..1
  local max_score = math.max(1, math.abs(score))
  return math.max(-1, math.min(1, score / max_score))
end

--: (string) -> string
M.sentiment_label = function(text)
  local score = M.sentiment(text)
  if score > 0.05 then return "positive"
  elseif score < -0.05 then return "negative"
  else return "neutral"
  end
end

-- ---------------------------------------------------------------------------
-- Keyword extraction (TF-IDF on a single document against itself)
-- ---------------------------------------------------------------------------

-- opts: { n = number (top N keywords) }
--: (string, { n: number } | nil) -> { string }
M.keywords = function(text, opts)
  opts = opts or {}
  local n = opts.n or 10
  local words = M.word_tokenize(text:lower())
  local stops = M.stopwords("en")
  -- Filter stopwords
  local content_words = {}
  for _, w in ipairs(words) do
    if not stops[w] and #w > 2 then
      content_words[#content_words + 1] = w
    end
  end
  -- Count frequency
  local freq = {}
  for _, w in ipairs(content_words) do
    freq[w] = (freq[w] or 0) + 1
  end
  -- Sort by frequency
  local pairs_list = {}
  for w, c in pairs(freq) do
    pairs_list[#pairs_list + 1] = { w, c }
  end
  table.sort(pairs_list, function(a, b) return a[2] > b[2] end)
  -- Return top n
  local result = {}
  for i = 1, math.min(n, #pairs_list) do
    result[i] = pairs_list[i][1]
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Readability scores
-- ---------------------------------------------------------------------------

-- Count syllables in a word (heuristic)
local function count_syllables(word)
  word = word:lower()
  -- Remove trailing e
  word = word:gsub("e$", "")
  local count = 0
  local prev_vowel = false
  for k = 1, #word do
    local c = word:sub(k, k)
    local is_vowel = c == "a" or c == "e" or c == "i" or c == "o" or c == "u" or c == "y"
    if is_vowel and not prev_vowel then
      count = count + 1
    end
    prev_vowel = is_vowel
  end
  return math.max(1, count)
end

-- Count words in text
local function count_words(text)
  local n = 0
  for _ in text:gmatch("[%w']+") do n = n + 1 end
  return n
end

-- Count sentences in text
local function count_sentences(text)
  local n = 0
  for _ in text:gmatch("[%.!%?]+") do n = n + 1 end
  return math.max(1, n)
end

-- Count total syllables in text
local function count_total_syllables(text)
  local n = 0
  for w in text:gmatch("[%w]+") do
    n = n + count_syllables(w)
  end
  return n
end

-- Flesch Reading Ease: 206.835 - 1.015*(words/sentences) - 84.6*(syllables/words)
-- Higher = easier to read (0-100 scale; ~70 = standard/easy)
--: (string) -> number
M.flesch_reading_ease = function(text)
  local words = count_words(text)
  local sents = count_sentences(text)
  local sylls = count_total_syllables(text)
  if words == 0 then return 0 end
  local asl = words / sents     -- avg sentence length
  local asw = sylls / words     -- avg syllables per word
  return 206.835 - 1.015 * asl - 84.6 * asw
end

-- Flesch-Kincaid Grade Level: 0.39*(words/sentences) + 11.8*(syllables/words) - 15.59
-- Corresponds roughly to US school grade
--: (string) -> number
M.flesch_kincaid_grade = function(text)
  local words = count_words(text)
  local sents = count_sentences(text)
  local sylls = count_total_syllables(text)
  if words == 0 then return 0 end
  local asl = words / sents
  local asw = sylls / words
  return 0.39 * asl + 11.8 * asw - 15.59
end

return M
