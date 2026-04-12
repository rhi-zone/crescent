-- lib/porter_stemmer/init.lua
-- Porter stemmer (1980) and Porter2/Snowball English stemmer (2002).
-- Text normalization, tokenization, stop words, and inverted index building.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, len, lower, find, gmatch =
  string.byte, string.char, string.sub, string.len, string.lower,
  string.find, string.gmatch

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local VOWELS = { [byte("a")] = true, [byte("e")] = true, [byte("i")] = true,
                 [byte("o")] = true, [byte("u")] = true }

-- Returns true if character at position i in word is a vowel (Porter1 rules).
-- y is a vowel only when preceded by a consonant.
local function is_vowel(word, i)
  local c = byte(word, i)
  if VOWELS[c] then return true end
  if c == byte("y") and i > 1 then
    -- y is a vowel after a consonant
    local prev = byte(word, i - 1)
    return not VOWELS[prev] and prev ~= byte("y")
  end
  return false
end

-- Compute measure m: number of VC sequences in word[1..n]
local function measure(word, n)
  local m = 0
  local i = 1
  -- skip leading consonants
  while i <= n and not is_vowel(word, i) do i = i + 1 end
  while i <= n do
    -- skip vowels
    while i <= n and is_vowel(word, i) do i = i + 1 end
    if i > n then break end
    -- skip consonants
    m = m + 1
    while i <= n and not is_vowel(word, i) do i = i + 1 end
  end
  return m
end

-- Does word[1..n] contain a vowel?
local function contains_vowel(word, n)
  for i = 1, n do
    if is_vowel(word, i) then return true end
  end
  return false
end

-- Does word[1..n] end with a double consonant?
local function ends_double_consonant(word, n)
  if n < 2 then return false end
  local c = byte(word, n)
  if c ~= byte(word, n - 1) then return false end
  return not VOWELS[c] and c ~= byte("y")
end

-- Does word[1..n] end with CVC where the last C is not w, x, or y?
local function ends_cvc(word, n)
  if n < 3 then return false end
  local c3 = byte(word, n)
  if c3 == byte("w") or c3 == byte("x") or c3 == byte("y") then return false end
  if VOWELS[c3] then return false end
  if not is_vowel(word, n - 1) then return false end
  if is_vowel(word, n - 2) then return false end
  return true
end

-- ---------------------------------------------------------------------------
-- Porter1 steps
-- ---------------------------------------------------------------------------

local function step1a(word)
  local n = len(word)
  if sub(word, n - 3) == "sses" then
    return sub(word, 1, n - 2)
  elseif sub(word, n - 2) == "ies" then
    return sub(word, 1, n - 3) .. "i"
  elseif sub(word, n - 1) == "ss" then
    return word
  elseif sub(word, n) == "s" then
    return sub(word, 1, n - 1)
  end
  return word
end

-- Step 1b helper: fix up after removing -ed or -ing
local function step1b_fix(word)
  local n = len(word)
  -- at, bl, iz → add e
  local tail2 = sub(word, n - 1)
  if tail2 == "at" or tail2 == "bl" or tail2 == "iz" then
    return word .. "e"
  end
  -- double consonant (not l, s, z) → remove one
  if ends_double_consonant(word, n) then
    local last = sub(word, n)
    if last ~= "l" and last ~= "s" and last ~= "z" then
      return sub(word, 1, n - 1)
    end
  end
  -- m=1 and *o → add e
  if measure(word, n) == 1 and ends_cvc(word, n) then
    return word .. "e"
  end
  return word
end

local function step1b(word)
  local n = len(word)
  if sub(word, n - 2) == "eed" then
    local stem = sub(word, 1, n - 3)
    if measure(stem, len(stem)) > 0 then
      return stem .. "ee"
    end
    return word
  elseif sub(word, n - 1) == "ed" then
    local stem = sub(word, 1, n - 2)
    if contains_vowel(stem, len(stem)) then
      return step1b_fix(stem)
    end
    return word
  elseif sub(word, n - 2) == "ing" then
    local stem = sub(word, 1, n - 3)
    if contains_vowel(stem, len(stem)) then
      return step1b_fix(stem)
    end
    return word
  end
  return word
end

local function step1c(word)
  local n = len(word)
  if sub(word, n) == "y" and contains_vowel(word, n - 1) then
    return sub(word, 1, n - 1) .. "i"
  end
  return word
end

-- Step 2 suffix table: {suffix, replacement}
local STEP2 = {
  {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"}, {"anci", "ance"},
  {"izer", "ize"}, {"abli", "able"}, {"alli", "al"}, {"entli", "ent"},
  {"eli", "e"}, {"ousli", "ous"}, {"ization", "ize"}, {"ation", "ate"},
  {"ator", "ate"}, {"alism", "al"}, {"iveness", "ive"}, {"fulness", "ful"},
  {"ousness", "ous"}, {"aliti", "al"}, {"iviti", "ive"}, {"biliti", "ble"},
}

local function step2(word)
  local n = len(word)
  for _, rule in ipairs(STEP2) do
    local suf, rep = rule[1], rule[2]
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      if measure(stem, len(stem)) > 0 then
        return stem .. rep
      end
      return word
    end
  end
  return word
end

-- Step 3 suffix table: {suffix, replacement}
local STEP3 = {
  {"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
  {"ical", "ic"}, {"ful", ""}, {"ness", ""},
}

local function step3(word)
  local n = len(word)
  for _, rule in ipairs(STEP3) do
    local suf, rep = rule[1], rule[2]
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      if measure(stem, len(stem)) > 0 then
        return stem .. rep
      end
      return word
    end
  end
  return word
end

-- Step 4 suffixes (m>1, remove suffix)
local STEP4 = {
  "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement",
  "ment", "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
}

local function step4(word)
  local n = len(word)
  for _, suf in ipairs(STEP4) do
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      -- special case: ion preceded by s or t
      if suf == "ion" then
        local last = sub(stem, len(stem))
        if last ~= "s" and last ~= "t" then
          goto continue
        end
      end
      if measure(stem, len(stem)) > 1 then
        return stem
      end
      return word
    end
    ::continue::
  end
  return word
end

local function step5a(word)
  local n = len(word)
  if sub(word, n) == "e" then
    local stem = sub(word, 1, n - 1)
    local m = measure(stem, len(stem))
    if m > 1 then return stem end
    if m == 1 and not ends_cvc(stem, len(stem)) then return stem end
  end
  return word
end

local function step5b(word)
  local n = len(word)
  if sub(word, n) == "l" and ends_double_consonant(word, n) then
    if measure(word, n - 1) > 1 then
      return sub(word, 1, n - 1)
    end
  end
  return word
end

-- ---------------------------------------------------------------------------
-- Porter1 public entry point
-- ---------------------------------------------------------------------------

--: (string) -> string
function M.stem_porter1(word)
  word = lower(word)
  -- words of length <= 2 are not stemmed
  if len(word) <= 2 then return word end
  word = step1a(word)
  word = step1b(word)
  word = step1c(word)
  word = step2(word)
  word = step3(word)
  word = step4(word)
  word = step5a(word)
  word = step5b(word)
  return word
end

-- ---------------------------------------------------------------------------
-- Porter2 / Snowball English stemmer
-- ---------------------------------------------------------------------------

-- Return position of start of R1 (first non-vowel following first vowel)
local function get_r1(word)
  local n = len(word)
  -- Special prefixes
  if sub(word, 1, 5) == "gener" or sub(word, 1, 6) == "commun" then
    return 6
  end
  if sub(word, 1, 5) == "arsen" then return 5 end
  local i = 1
  -- skip to first vowel
  while i <= n and not is_vowel(word, i) do i = i + 1 end
  -- skip vowels
  while i <= n and is_vowel(word, i) do i = i + 1 end
  -- R1 starts after first non-vowel following first vowel
  return i + 1
end

local function get_r2(word, r1)
  local n = len(word)
  local i = r1
  -- skip to first vowel in r1
  while i <= n and not is_vowel(word, i) do i = i + 1 end
  -- skip vowels
  while i <= n and is_vowel(word, i) do i = i + 1 end
  return i + 1
end

-- Check if position p is within the R1/R2 region (p >= region_start)
local function in_region(p, region_start)
  return p >= region_start
end

local function p2_step1a(word)
  local n = len(word)
  if sub(word, n - 3) == "sses" then
    return sub(word, 1, n - 2)
  end
  local tail3 = sub(word, n - 2)
  if tail3 == "ied" or tail3 == "ies" then
    if n > 4 then
      return sub(word, 1, n - 2)
    else
      return sub(word, 1, n - 1)
    end
  end
  -- us or ss: do nothing
  local tail2 = sub(word, n - 1)
  if tail2 == "ss" or tail2 == "us" then return word end
  -- s preceded by a vowel somewhere before the last two chars
  if sub(word, n) == "s" and n > 2 then
    -- check if there's a vowel in word[1..n-2]
    if contains_vowel(word, n - 2) then
      return sub(word, 1, n - 1)
    end
  end
  return word
end

local P2_STEP1B_LONG = { "eed", "eedly" }
local P2_STEP1B_VOWEL = { "ed", "edly", "ing", "ingly" }

local function p2_step1b(word, r1)
  local n = len(word)
  -- eed/eedly: if in R1, replace with ee
  for _, suf in ipairs(P2_STEP1B_LONG) do
    local sl = len(suf)
    if n >= sl and sub(word, n - sl + 1) == suf then
      local stem_end = n - sl
      if in_region(stem_end + 1, r1) then
        return sub(word, 1, stem_end) .. "ee"
      end
      return word
    end
  end
  -- ed/edly/ing/ingly: if vowel in stem
  for _, suf in ipairs(P2_STEP1B_VOWEL) do
    local sl = len(suf)
    if n >= sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      local sn = len(stem)
      if contains_vowel(stem, sn) then
        -- fix: at/bl/iz → add e; double consonant (not l,s,z) → remove; m=1 CVC → add e
        local tail2 = sub(stem, sn - 1)
        if tail2 == "at" or tail2 == "bl" or tail2 == "iz" then
          return stem .. "e"
        end
        if ends_double_consonant(stem, sn) then
          local last = sub(stem, sn)
          if last ~= "l" and last ~= "s" and last ~= "z" then
            return sub(stem, 1, sn - 1)
          end
        end
        if measure(stem, sn) == 1 and ends_cvc(stem, sn) then
          return stem .. "e"
        end
        return stem
      end
      return word
    end
  end
  return word
end

local function p2_step1c(word)
  local n = len(word)
  local last = sub(word, n)
  if (last == "y" or last == "Y") and n > 2 and not is_vowel(word, n - 1) then
    return sub(word, 1, n - 1) .. "i"
  end
  return word
end

-- Step 2 table for Porter2: {suffix, replacement, requires_r1=true}
local P2_STEP2 = {
  {"ization", "ize"}, {"ational", "ate"}, {"fulness", "ful"},
  {"ousness", "ous"}, {"iveness", "ive"}, {"tional", "tion"},
  {"biliti", "ble"}, {"lessli", "less"}, {"entli", "ent"},
  {"ation", "ate"}, {"alism", "al"}, {"aliti", "al"},
  {"ousli", "ous"}, {"iviti", "ive"}, {"fulli", "ful"},
  {"enci", "ence"}, {"anci", "ance"}, {"abli", "able"},
  {"izer", "ize"}, {"ator", "ate"}, {"alli", "al"},
  {"bli", "ble"}, {"ogi", "og"},  -- ogi: only if preceded by l
  {"li", ""},  -- li: only if preceded by valid li-ending
}

local LI_ENDINGS = { [byte("c")] = true, [byte("d")] = true, [byte("e")] = true,
                     [byte("g")] = true, [byte("h")] = true, [byte("k")] = true,
                     [byte("m")] = true, [byte("n")] = true, [byte("r")] = true,
                     [byte("t")] = true }

local function p2_step2(word, r1)
  local n = len(word)
  for _, rule in ipairs(P2_STEP2) do
    local suf, rep = rule[1], rule[2]
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      local sn = len(stem)
      if not in_region(sn + 1, r1) then return word end
      -- special: ogi → og only if preceded by l
      if suf == "ogi" then
        if sub(stem, sn) == "l" then
          return stem .. rep
        end
        return word
      end
      -- special: li → delete only if preceded by valid li-ending char
      if suf == "li" then
        if sn >= 1 and LI_ENDINGS[byte(stem, sn)] then
          return stem
        end
        return word
      end
      return stem .. rep
    end
  end
  return word
end

local P2_STEP3 = {
  {"ational", "ate"}, {"tional", "tion"}, {"alize", "al"},
  {"icate", "ic"}, {"iciti", "ic"}, {"ical", "ic"},
  {"ness", ""}, {"ful", ""},
  {"ative", ""},  -- only if in R2
}

local function p2_step3(word, r1, r2)
  local n = len(word)
  for _, rule in ipairs(P2_STEP3) do
    local suf, rep = rule[1], rule[2]
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      local sn = len(stem)
      if suf == "ative" then
        if in_region(sn + 1, r2) then
          return stem .. rep
        end
        return word
      end
      if in_region(sn + 1, r1) then
        return stem .. rep
      end
      return word
    end
  end
  return word
end

local P2_STEP4 = {
  "ement", "ment", "ance", "ence", "able", "ible", "ism", "ate",
  "iti", "ous", "ive", "ize", "ant", "al", "er", "ic",
  "ion",  -- only if preceded by s or t
}

local function p2_step4(word, r2)
  local n = len(word)
  for _, suf in ipairs(P2_STEP4) do
    local sl = len(suf)
    if n > sl and sub(word, n - sl + 1) == suf then
      local stem = sub(word, 1, n - sl)
      local sn = len(stem)
      if suf == "ion" then
        local last = sub(stem, sn)
        if last ~= "s" and last ~= "t" then goto p2step4_continue end
      end
      if in_region(sn + 1, r2) then
        return stem
      end
      return word
    end
    ::p2step4_continue::
  end
  return word
end

local function p2_step5(word, r1, r2)
  local n = len(word)
  if sub(word, n) == "e" then
    local stem = sub(word, 1, n - 1)
    local sn = len(stem)
    if in_region(n, r2) then return stem end
    if in_region(n, r1) and not ends_cvc(stem, sn) then return stem end
    return word
  end
  if sub(word, n) == "l" and sub(word, n - 1, n - 1) == "l" then
    if in_region(n, r2) then
      return sub(word, 1, n - 1)
    end
  end
  return word
end

-- Porter2 exceptions (applied before algorithm)
local P2_EXCEPTIONS1 = {
  skis = "ski", skies = "sky", dying = "die", lying = "lie", tying = "tie",
  idly = "idl", gently = "gentl", ugly = "ugli", early = "earli",
  only = "onli", singly = "singl", sky = "sky", news = "news",
  howe = "howe", atlas = "atlas", cosmos = "cosmos", bias = "bias",
  andes = "andes",
}

-- Porter2 exceptions (applied after step 1a)
local P2_EXCEPTIONS2 = {
  inning = "inning", outing = "outing", canning = "canning",
  herring = "herring", earring = "earring", proceed = "proceed",
  exceed = "exceed", succeed = "succeed",
}

--: (string) -> string
function M.stem_porter2(word)
  word = lower(word)
  if len(word) <= 2 then return word end

  -- Check exceptions first
  local exc = P2_EXCEPTIONS1[word]
  if exc then return exc end

  -- Step 0: remove leading apostrophe
  if sub(word, 1, 1) == "'" then word = sub(word, 2) end

  -- Handle initial y: mark as Y (uppercase)
  if sub(word, 1, 1) == "y" then
    word = "Y" .. sub(word, 2)
  end
  -- Mark y after vowel as Y
  local n = len(word)
  local chars = {}
  for i = 1, n do chars[i] = sub(word, i, i) end
  for i = 2, n do
    if chars[i] == "y" and VOWELS[byte(word, i - 1)] then
      chars[i] = "Y"
    end
  end
  word = table.concat(chars)

  local r1 = get_r1(word)
  local r2 = get_r2(word, r1)

  word = p2_step1a(word)

  -- Check exceptions after step 1a
  local exc2 = P2_EXCEPTIONS2[lower(word)]
  if exc2 then return exc2 end

  word = p2_step1b(word, r1)
  word = p2_step1c(word)
  word = p2_step2(word, r1)
  word = p2_step3(word, r1, r2)
  word = p2_step4(word, r2)
  word = p2_step5(word, r1, r2)

  -- Restore Y to y
  word = word:gsub("Y", "y")
  return word
end

-- Alias
M.stem = M.stem_porter1

-- ---------------------------------------------------------------------------
-- Utility: ends_with
-- ---------------------------------------------------------------------------

--: (string, string) -> boolean
function M.ends_with(word, suffix)
  local wl, sl = len(word), len(suffix)
  if sl > wl then return false end
  return sub(word, wl - sl + 1) == suffix
end

-- ---------------------------------------------------------------------------
-- Normalize: lowercase + remove non-alpha characters
-- ---------------------------------------------------------------------------

--: (string) -> string
function M.normalize(word)
  return lower(word):gsub("[^a-z]", "")
end

-- ---------------------------------------------------------------------------
-- Stop words
-- ---------------------------------------------------------------------------

M.stop_words = {}
local SW_LIST = {
  "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
  "of", "with", "by", "from", "as", "is", "was", "are", "were", "be",
  "been", "being", "have", "has", "had", "do", "does", "did", "will",
  "would", "could", "should", "may", "might", "shall", "can", "this",
  "that", "these", "those", "i", "you", "he", "she", "it", "we", "they",
  "me", "him", "her", "us", "them", "my", "your", "his", "its", "our",
  "their", "what", "which", "who", "whom", "when", "where", "why", "how",
  "all", "each", "every", "both", "few", "more", "most", "other", "some",
  "such", "no", "not", "only", "own", "same", "than", "then", "so", "if",
  "also", "etc", "up", "out", "about", "into", "through", "during",
  "before", "after", "above", "below", "between", "just", "because",
  "while", "although", "however", "therefore", "thus", "yet", "still",
  "very", "too", "quite", "rather", "much", "many", "any", "over",
  "under", "again", "further", "once",
}
for _, w in ipairs(SW_LIST) do
  M.stop_words[w] = true
end

--: (string) -> boolean
function M.is_stop_word(word)
  return M.stop_words[lower(word)] == true
end

-- ---------------------------------------------------------------------------
-- stem_all: stem an array of words
-- ---------------------------------------------------------------------------

--: (string[], string | nil) -> string[]
function M.stem_all(words, algorithm)
  local fn = algorithm == "porter2" and M.stem_porter2 or M.stem_porter1
  local result = {}
  for i, w in ipairs(words) do
    result[i] = fn(w)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Tokenize: split text into words
-- ---------------------------------------------------------------------------

local function tokenize(text)
  local tokens = {}
  for word in gmatch(lower(text), "[a-z]+") do
    tokens[#tokens + 1] = word
  end
  return tokens
end

-- ---------------------------------------------------------------------------
-- stem_text: tokenize + optionally remove stop words + stem
-- ---------------------------------------------------------------------------

--: (string, { algorithm: string | nil, stop_words: boolean | nil } | nil) -> string[]
function M.stem_text(text, opts)
  opts = opts or {}
  local algorithm = opts.algorithm or "porter1"
  local remove_stop = opts.stop_words ~= false  -- default true
  local fn = algorithm == "porter2" and M.stem_porter2 or M.stem_porter1

  local tokens = tokenize(text)
  local result = {}
  for _, word in ipairs(tokens) do
    if not remove_stop or not M.stop_words[word] then
      result[#result + 1] = fn(word)
    end
  end
  return result
end

-- ---------------------------------------------------------------------------
-- index: build inverted index from array of documents
-- ---------------------------------------------------------------------------

--: (string[]) -> { [string]: { doc_idx: integer, positions: integer[] }[] }
function M.index(documents)
  local idx = {}
  for doc_i, doc in ipairs(documents) do
    local pos = 0
    for word in gmatch(lower(doc), "[a-z]+") do
      pos = pos + 1
      if not M.stop_words[word] then
        local stem = M.stem_porter1(word)
        if not idx[stem] then idx[stem] = {} end
        local entries = idx[stem]
        -- find existing entry for this doc
        local found = false
        for _, entry in ipairs(entries) do
          if entry.doc_idx == doc_i then
            entry.positions[#entry.positions + 1] = pos
            found = true
            break
          end
        end
        if not found then
          entries[#entries + 1] = { doc_idx = doc_i, positions = { pos } }
        end
      end
    end
  end
  return idx
end

return M
