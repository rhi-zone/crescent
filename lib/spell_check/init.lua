-- lib/spell_check/init.lua
-- Spell checker with Levenshtein edit-distance suggestions.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, sub, lower, len = string.byte, string.sub, string.lower, string.len
local insert, sort, concat = table.insert, table.sort, table.concat
local floor, abs, min = math.floor, math.abs, math.min

-- ── Levenshtein distance ──────────────────────────────────────────────────────

-- Standard Wagner-Fischer algorithm, two-row space optimization.
-- Returns distance, or max_dist+1 if length difference exceeds max_dist.
--: (string, string, integer | nil) -> integer
local function levenshtein(a, b, max_dist)
  local la, lb = len(a), len(b)
  -- Early exit: length difference alone exceeds budget
  if max_dist and abs(la - lb) > max_dist then
    return max_dist + 1
  end
  if la == 0 then return lb end
  if lb == 0 then return la end
  if a == b then return 0 end

  -- prev[j] = edit distance between a[1..i-1] and b[1..j]
  --: { [integer]: integer }
  local prev = {}
  --: { [integer]: integer }
  local curr = {}
  for j = 0, lb do prev[j] = j end

  for i = 1, la do
    curr[0] = i
    local ai = byte(a, i)
    for j = 1, lb do
      local cost = ai == byte(b, j) and 0 or 1
      local del  = prev[j] + 1
      local ins  = curr[j - 1] + 1
      local sub_ = prev[j - 1] + cost
      curr[j] = del < ins and (del < sub_ and del or sub_) or (ins < sub_ and ins or sub_)
    end
    -- Early exit: if min value in curr row exceeds max_dist, no solution
    if max_dist then
      local row_min = curr[0]
      for j = 1, lb do
        if curr[j] < row_min then row_min = curr[j] end
      end
      if row_min > max_dist then
        return max_dist + 1
      end
    end
    -- swap rows
    for j = 0, lb do prev[j] = curr[j] end
  end
  return prev[lb]
end

M.levenshtein = levenshtein

-- ── Built-in dictionary ───────────────────────────────────────────────────────

-- ~500 common English words
local BUILTIN_WORDS = {
  -- Articles, pronouns, conjunctions, prepositions
  "a", "an", "the", "and", "or", "but", "if", "in", "on", "at", "to", "for",
  "of", "with", "by", "from", "up", "about", "into", "through", "during",
  "before", "after", "above", "below", "between", "out", "off", "over",
  "under", "again", "then", "once", "here", "there", "when", "where", "why",
  "how", "all", "both", "each", "few", "more", "most", "other", "some",
  "such", "no", "not", "only", "own", "same", "so", "than", "too", "very",
  "just", "because", "as", "until", "while", "although", "though", "since",
  -- Pronouns
  "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your",
  "yours", "yourself", "he", "him", "his", "himself", "she", "her", "hers",
  "herself", "it", "its", "itself", "they", "them", "their", "theirs",
  "themselves", "what", "which", "who", "whom", "this", "that", "these",
  "those",
  -- Common verbs
  "be", "is", "are", "was", "were", "been", "being", "have", "has", "had",
  "having", "do", "does", "did", "doing", "will", "would", "could", "should",
  "may", "might", "must", "shall", "can", "need", "dare", "ought", "used",
  "say", "get", "make", "go", "know", "take", "see", "come", "think", "look",
  "want", "give", "use", "find", "tell", "ask", "seem", "feel", "try", "leave",
  "call", "keep", "let", "begin", "show", "hear", "play", "run", "move", "live",
  "believe", "hold", "bring", "happen", "write", "provide", "sit", "stand",
  "lose", "pay", "meet", "include", "continue", "set", "learn", "change",
  "lead", "understand", "watch", "follow", "stop", "create", "speak", "read",
  "spend", "grow", "open", "walk", "win", "offer", "remember", "love", "consider",
  "appear", "buy", "wait", "serve", "die", "send", "expect", "build", "stay",
  "fall", "cut", "reach", "kill", "remain", "suggest", "raise", "pass", "sell",
  "require", "report", "decide", "pull", "break", "put", "turn",
  -- Common nouns
  "time", "year", "people", "way", "day", "man", "woman", "child", "world",
  "life", "hand", "part", "place", "case", "week", "company", "system",
  "program", "question", "work", "government", "number", "night", "point",
  "home", "water", "room", "mother", "area", "money", "story", "fact",
  "month", "lot", "right", "study", "book", "eye", "job", "word", "business",
  "issue", "side", "kind", "head", "house", "service", "friend", "father",
  "power", "hour", "game", "line", "end", "among", "never", "last", "always",
  "however", "whole", "still", "city", "name", "air", "school", "state",
  "family", "student", "group", "country", "problem", "hand", "part",
  "thing", "idea", "body", "information", "back", "order", "face",
  "action", "law", "car", "road", "town", "form", "door", "product", "age",
  "sound", "computer", "letter", "model", "table", "food", "plan", "fire",
  "south", "north", "east", "west", "land", "field", "large", "small",
  -- Adjectives
  "good", "new", "first", "last", "long", "great", "little", "own", "right",
  "big", "high", "different", "small", "large", "next", "early", "young",
  "important", "public", "private", "real", "best", "free", "able", "old",
  "true", "false", "open", "close", "short", "full", "sure", "clear",
  "low", "special", "hard", "easy", "left", "strong", "light", "dark",
  "bad", "hot", "cold", "late", "near", "far", "fast", "slow", "happy",
  "sad", "sick", "well", "safe", "deep", "heavy", "simple", "common",
  "natural", "possible", "human", "local", "ready", "major", "certain",
  "national", "political", "social", "economic", "personal",
  -- Days of week
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  -- Months
  "january", "february", "march", "april", "may", "june", "july", "august",
  "september", "october", "november", "december",
  -- Numbers (written)
  "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
  "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
  "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
  "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
  "million", "billion",
  -- Common adverbs
  "also", "back", "even", "much", "well", "now", "still", "down", "away",
  "already", "soon", "yet", "often", "never", "always", "sometimes",
  "usually", "actually", "maybe", "probably", "certainly", "definitely",
  "clearly", "quickly", "slowly", "finally", "really", "quite", "rather",
  "almost", "enough", "either", "instead", "together", "however", "therefore",
  "otherwise", "perhaps", "especially", "exactly", "later", "forward",
  -- Additional common words
  "help", "hello", "spelling", "language", "english", "test", "error",
  "correct", "wrong", "check", "spell", "word", "text", "sentence",
  "paragraph", "document", "file", "path", "type", "value", "key", "index",
  "array", "list", "string", "number", "boolean", "table", "function",
  "method", "class", "module", "library", "package", "version", "release",
}

-- ── Checker object ────────────────────────────────────────────────────────────

--:: Checker = { _dict: { [string]: boolean }, _by_len: { [integer]: { [integer]: string } }, _count: integer, ... }
local Checker = {}
Checker.__index = Checker

-- Build the internal lookup table and length-bucket index.
--: ({ [integer]: string }) -> ({ [string]: boolean }, { [integer]: { [integer]: string } })
local function build_index(words)
  local dict = {}       -- word -> true (lowercase keys)
  local by_len = {}     -- length -> array of lowercase words
  for _, w in ipairs(words) do
    local lw = lower(w)
    if not dict[lw] then
      dict[lw] = true
      local l = len(lw)
      if not by_len[l] then by_len[l] = {} end
      insert(by_len[l], lw)
    end
  end
  return dict, by_len
end

-- Create a new spell checker.
-- words: optional array of strings; if nil, uses built-in dictionary.
function M.new(words)
  local src = words or BUILTIN_WORDS
  local d, bl = build_index(src)
  local cnt = 0
  for _ in pairs(d) do cnt = cnt + 1 end
  local self = setmetatable({ _dict = d, _by_len = bl, _count = cnt }, Checker) --[[:! Checker]]
  return self
end

-- Check if a word is spelled correctly (case-insensitive).
--: (Checker, string) -> boolean
function Checker:check(word)
  return self._dict[lower(word)] == true
end

-- Alias for check.
Checker.correct = Checker.check

-- Return the number of words in the dictionary.
--: (Checker) -> integer
function Checker:size()
  return self._count
end

-- Add a single word to the dictionary.
--: (Checker, string) -> nil
function Checker:add(word)
  local lw = lower(word)
  if not self._dict[lw] then
    self._dict[lw] = true
    self._count = self._count + 1
    local l = len(lw)
    if not self._by_len[l] then self._by_len[l] = {} end
    insert(self._by_len[l], lw)
  end
end

-- Add multiple words.
--: (Checker, { [integer]: string }) -> nil
function Checker:add_all(words)
  for _, w in ipairs(words) do
    Checker.add(self, w)
  end
end

-- Remove a word from the dictionary.
--: (Checker, string) -> nil
function Checker:remove(word)
  local lw = lower(word)
  if self._dict[lw] then
    self._dict[lw] = nil
    self._count = self._count - 1
    local l = len(lw)
    if self._by_len[l] then
      local arr = self._by_len[l]
      for i = 1, #arr do
        if arr[i] == lw then
          table.remove(arr, i)
          break
        end
      end
    end
  end
end

-- Get spelling suggestions for a word.
-- opts: { max_suggestions=5, max_distance=2, case_sensitive=false }
-- Returns array of candidate words sorted by distance then alphabetically.
--: (Checker, string, { [string]: unknown } | nil) -> { [integer]: string }
function Checker:suggest(word, opts)
  local max_sugg   = (opts and opts.max_suggestions or 5) --[[:! integer]]
  local max_dist   = (opts and opts.max_distance or 2) --[[:! integer]]
  local case_sens  = opts and opts.case_sensitive or false

  local query = case_sens and word or lower(word)
  local qlen  = len(query)

  -- Collect candidates from length buckets within reach
  local candidates = {}
  for bucket_len, words_in_bucket in pairs(self._by_len) do
    if abs(bucket_len - qlen) <= max_dist then
      for _, w in ipairs(words_in_bucket) do
        if w ~= query then
          local d = levenshtein(query, w, max_dist)
          if d <= max_dist then
            insert(candidates, { word = w, dist = d })
          end
        end
      end
    end
  end

  -- Sort: distance ascending, then alphabetically
  sort(candidates, function(x, y)
    if x.dist ~= y.dist then return x.dist < y.dist end
    return x.word < y.word
  end)

  -- Return at most max_sugg results
  local result = {}
  for i = 1, min(max_sugg, #candidates) do
    local c = candidates[i] --[[:! { word: string, dist: integer }]]
    result[i] = c.word
  end
  return result
end

-- Check a word and return suggestions if incorrect.
-- Returns (true, nil) if correct; (false, suggestions) if incorrect.
function Checker:check_with_suggestions(word, opts)
  if Checker.check(self, word) then
    return true, nil
  end
  return false, Checker.suggest(self, word, opts)
end

-- ── Text checking ─────────────────────────────────────────────────────────────

-- Strip leading and trailing punctuation from a token.
-- Returns cleaned string (may be empty).
local function strip_punct(s)
  -- strip leading punctuation
  local i = 1
  local n = len(s)
  while i <= n do
    local c = byte(s, i) --[[:! integer]]
    -- keep alphanumeric (a-z A-Z 0-9) and apostrophe inside a word
    if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) then
      break
    end
    i = i + 1
  end
  -- strip trailing punctuation
  local j = n
  while j >= i do
    local c = byte(s, j) --[[:! integer]]
    if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or (c >= 48 and c <= 57) then
      break
    end
    j = j - 1
  end
  if j < i then return "" end
  return sub(s, i, j)
end

-- Check all words in a text string.
-- Returns array of { word, position, suggestions } for each misspelled word.
-- opts: { max_suggestions=3, ignore_capitalized=true }
--: (Checker, string, { max_suggestions: integer | nil, ignore_capitalized: boolean | nil } | nil) -> { [integer]: { word: string, position: integer, suggestions: { [integer]: string } } }
function Checker:check_text(text, opts)
  local max_sugg       = opts and opts.max_suggestions or 3
  local ignore_caps    = opts and opts.ignore_capitalized
  if ignore_caps == nil then ignore_caps = true end

  local errors = {}
  local pos = 1
  local tlen = len(text)

  while pos <= tlen do
    -- skip whitespace
    while pos <= tlen do
      local c = byte(text, pos)
      if c ~= 32 and c ~= 9 and c ~= 10 and c ~= 13 then break end
      pos = pos + 1
    end
    if pos > tlen then break end

    -- find end of token
    local tok_start = pos
    while pos <= tlen do
      local c = byte(text, pos)
      if c == 32 or c == 9 or c == 10 or c == 13 then break end
      pos = pos + 1
    end
    local tok_end = pos - 1
    local token = sub(text, tok_start, tok_end)

    -- strip punctuation
    local word = strip_punct(token)

    -- skip empty, single char, pure numbers
    if len(word) >= 2 then
      -- check for pure number
      local is_num = true
      for k = 1, len(word) do
        local c = byte(word, k) --[[:! integer]]
        if not (c >= 48 and c <= 57) then
          is_num = false
          break
        end
      end

      if not is_num then
        -- ignore_capitalized: skip words whose first char is uppercase
        local first = byte(word, 1) --[[:! integer]]
        local is_cap = first >= 65 and first <= 90
        if not (ignore_caps and is_cap) then
          if not Checker.check(self, word) then
            local sugg = Checker.suggest(self, word, { max_suggestions = max_sugg })
            insert(errors, { word = word, position = tok_start, suggestions = sugg })
          end
        end
      end
    end
  end
  return errors
end

-- Correct a text by replacing each misspelled word with its top suggestion,
-- but only when there is exactly one candidate at distance 1.
-- Returns the corrected string.
--: (Checker, string) -> string
function Checker:correct_text(text)
  local result = {}
  local pos = 1
  local tlen = len(text)

  while pos <= tlen do
    -- collect whitespace
    local ws_start = pos
    while pos <= tlen do
      local c = byte(text, pos)
      if c ~= 32 and c ~= 9 and c ~= 10 and c ~= 13 then break end
      pos = pos + 1
    end
    if pos > ws_start then
      insert(result, sub(text, ws_start, pos - 1))
    end
    if pos > tlen then break end

    -- collect token
    local tok_start = pos
    while pos <= tlen do
      local c = byte(text, pos)
      if c == 32 or c == 9 or c == 10 or c == 13 then break end
      pos = pos + 1
    end
    local tok_end = pos - 1
    local token = sub(text, tok_start, tok_end)

    local word = strip_punct(token)
    if len(word) >= 2 and not Checker.check(self, word) then
      -- find how much leading/trailing punctuation was stripped
      local lead = token:find(word, 1, true)
      local before = lead and sub(token, 1, lead - 1) or ""
      local after_start = lead and (lead + len(word)) or (len(token) + 1)
      local after = sub(token, after_start)

      -- Only replace if there is exactly one candidate at distance 1
      local sugg = Checker.suggest(self, word, { max_suggestions = 2, max_distance = 1 })
      if #sugg == 1 then
        insert(result, before .. sugg[1] .. after)
      else
        insert(result, token)
      end
    else
      insert(result, token)
    end
  end
  return concat(result)
end

return M
