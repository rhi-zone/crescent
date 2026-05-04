-- lib/unified/retext_contractions/init.lua
-- retext plugin: detect missing or incorrect contractions in nlcst trees.
-- Port of https://github.com/retextjs/retext-contractions
--
-- Detects:
--   - Words missing an apostrophe that should be a contraction (e.g. "dont" → "don't")
--   - Optionally: straight apostrophe used instead of curly (opts.straight = true)
--   - Optionally: curly apostrophe used but straight expected (opts.smart = true)
--
-- Results are stored in root.data.contractions as a list of:
--   { word = "dont", suggestion = "don't", sentence = "I dont know." }
--
-- Plugin signature (unified):
--   function(processor, opts)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local nlcst = require("lib.unified.nlcst") --[[: any]]

local M = {}

-- ── Contraction dictionary ────────────────────────────────────────────────────

-- Mapping from lowercase mangled form → correct form with straight apostrophe.
-- Keys are what you'd get when someone writes the contraction without any apostrophe.
local CONTRACTIONS = {
  -- n't contractions
  dont     = "don't",
  cant     = "can't",
  wont     = "won't",
  wouldnt  = "wouldn't",
  couldnt  = "couldn't",
  shouldnt = "shouldn't",
  doesnt   = "doesn't",
  didnt    = "didn't",
  isnt     = "isn't",
  arent    = "aren't",
  wasnt    = "wasn't",
  werent   = "weren't",
  havent   = "haven't",
  hasnt    = "hasn't",
  hadnt    = "hadn't",
  mustnt   = "mustn't",
  neednt   = "needn't",
  -- 're contractions
  youre    = "you're",
  theyre   = "they're",
  -- 'm contractions (uppercase I)
  im       = "I'm",
  -- 'll contractions (uppercase I)
  ill      = "I'll",
}

-- Curly apostrophe variants (key = word with curly apostrophe inserted).
-- Used when opts.straight = true: warn that curly is used but straight expected.
-- We detect curly apostrophe (\xe2\x80\x99 in UTF-8, the RIGHT SINGLE QUOTATION MARK)
-- within words to flag them.
local CURLY_APOSTROPHE = "\xe2\x80\x99"  -- U+2019 '
local STRAIGHT_APOSTROPHE = "'"

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Extract plain text from a word node.
--: (any) -> string
local function word_text(word_node)
  return nlcst.to_text(word_node)
end

-- Reconstruct full sentence text from a SentenceNode.
--: (any) -> string
local function sentence_text(sent_node)
  return nlcst.to_text(sent_node)
end

-- ── Core check ────────────────────────────────────────────────────────────────

-- Check a single word. Returns a contraction issue or nil.
-- opts.straight: warn when curly apostrophe is used instead of straight.
-- opts.smart:    warn when straight apostrophe is used instead of curly.
--: (string, string, any) -> any
local function check_word(word, sentence, opts)
  local lower = word:lower()

  -- 1. Word contains a curly apostrophe.
  if word:find(CURLY_APOSTROPHE, 1, true) then
    if opts.straight then
      -- Warn: curly used, but straight expected.
      local straight_form = word:gsub(CURLY_APOSTROPHE, STRAIGHT_APOSTROPHE)
      return {
        word       = word,
        suggestion = straight_form,
        sentence   = sentence,
        reason     = "curly apostrophe used instead of straight",
      }
    end
    return nil
  end

  -- 2. Word contains a straight apostrophe — already a contraction.
  if word:find(STRAIGHT_APOSTROPHE, 1, true) then
    if opts.smart then
      -- Warn: straight used, but curly expected.
      local curly_form = word:gsub(STRAIGHT_APOSTROPHE, CURLY_APOSTROPHE)
      return {
        word       = word,
        suggestion = curly_form,
        sentence   = sentence,
        reason     = "straight apostrophe used instead of curly",
      }
    end
    return nil
  end

  -- 3. Check against the contraction dictionary (missing apostrophe).
  local suggestion = CONTRACTIONS[lower]
  if suggestion then
    return {
      word       = word,
      suggestion = suggestion,
      sentence   = sentence,
      reason     = "missing apostrophe in contraction",
    }
  end

  return nil
end

-- Walk the nlcst tree collecting issues.
--: (any, any, any) -> nil
local function walk_tree(node, issues, opts)
  if not node then return end

  if node.type == nlcst.SENTENCE then
    local sent = sentence_text(node)
    -- Walk each WordNode in the sentence.
    for _, child in ipairs(node.children or {}) do
      if child.type == nlcst.WORD then
        local w = word_text(child)
        local issue = check_word(w, sent, opts)
        if issue then
          issues[#issues + 1] = issue
        end
      end
    end
    return
  end

  for _, child in ipairs(node.children or {}) do
    walk_tree(child, issues, opts)
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, opts)
  opts = opts or {}

  processor:use_transformer(function(tree)
    local issues = {}
    walk_tree(tree, issues, opts)

    if not tree.data then tree.data = {} end
    tree.data.contractions = issues

    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

-- Expose the contraction dictionary for introspection.
M.CONTRACTIONS = CONTRACTIONS

return M
