-- lib/unified/retext_indefinite_article/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_indefinite_article: checks a/an usage before the following word.
-- Port of retext-indefinite-article (https://github.com/retextjs/retext-indefinite-article).
--
-- Rules:
--   "an" before words with a vowel *sound* (a,e,i,o,u first letter).
--   "a"  before words with a consonant sound.
--   Exception — silent h: "an hour", "an honest", "an honour", "an heir".
--   Exception — "you" sound (u/eu/uni...): "a uniform", "a union", "a unique",
--     "a unit", "a user", "a use", "a universal", "a university", "a url" (debated;
--     flagged as needing "a" since URL sounds like "you-ar-el").
--   Abbreviations: determine by first-letter sound (vowel letter → "an FBI").
--
-- Stores: root.data.indefinite_article =
--   { {actual="a", expected="an", word="apple", sentence="..."}, ... }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

-- Words where the initial letter is a vowel but the sound is consonant ("you" sound).
-- Use "a" before these.
local YOU_SOUND = {
  uniform=true, unique=true, union=true, unit=true, units=true,
  user=true, use=true, used=true, uses=true, using=true,
  universal=true, university=true, universities=true,
  usual=true, usually=true, utility=true, utilities=true,
  ukulele=true,
}

-- Words where the initial letter is a consonant (h) but it's silent: use "an".
local SILENT_H = {
  hour=true, hours=true, hourly=true,
  honest=true, honestly=true, honesty=true,
  honour=true, honours=true, honourable=true,
  honor=true, honors=true, honorable=true, honorary=true,
  heir=true, heirs=true, heiress=true, heirloom=true, heirloom=true,
  herb=true, herbs=true,        -- US English: silent h in herb
}

-- Vowel-letter abbreviations pronounced letter-by-letter: use "an".
-- Determined by first letter being a vowel sound (a,e,f,h,i,l,m,n,o,r,s,x).
-- We check dynamically via first_letter_is_vowel_sound for abbreviations.
local VOWEL_LETTER_SOUNDS = {
  a=true, e=true, f=true, h=true, i=true, l=true, m=true,
  n=true, o=true, r=true, s=true, x=true,
}

-- Returns true if the word should be preceded by "an".
local function needs_an(word)
  --: string
  local word_ = word --[[:! string]]
  if #word_ == 0 then return false end
  local lower = word_:lower()
  local first = lower:sub(1, 1)

  -- All uppercase (or mixed short word): treat as abbreviation spoken letter-by-letter.
  local is_abbrev = word_:match("^[A-Z][A-Z]+$") ~= nil

  if is_abbrev then
    return VOWEL_LETTER_SOUNDS[first] == true
  end

  if first == "h" then
    return SILENT_H[lower] == true
  end

  if first == "a" or first == "e" or first == "i" or first == "o" then
    return true
  end

  if first == "u" then
    -- "you" sound exceptions.
    if YOU_SOUND[lower] then return false end
    -- Other u- words: vowel sound.
    return true
  end

  return false
end

-- Collect word tokens from a sentence in order with their indices.
local function sentence_words(sent)
  local words = {}
  local children = sent.children
  for i = 1, #children do
    local child = children[i]
    if child.type == nlcst.WORD then
      words[#words + 1] = nlcst.to_text(child)
    end
  end
  return words
end

local function transformer(root)
  local findings = {}

  local function walk(node)
    if node.type == nlcst.SENTENCE then
      local words = sentence_words(node)
      local sent_text = nlcst.to_text(node)
      for i = 1, #words - 1 do
        local art = words[i]:lower()
        if art == "a" or art == "an" then
          local next_word = words[i + 1]
          local expected = needs_an(next_word) and "an" or "a"
          if art ~= expected then
            findings[#findings + 1] = {
              actual   = art,
              expected = expected,
              word     = next_word,
              sentence = sent_text,
            }
          end
        end
      end
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: any }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end

  walk(root)

  root.data = root.data or {}
  root.data.indefinite_article = findings

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
