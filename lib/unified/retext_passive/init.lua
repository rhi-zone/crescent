-- lib/unified/retext_passive/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_passive: detects passive voice constructions in nlcst trees.
-- Port of retext-passive (https://github.com/retextjs/retext-passive).
--
-- Pattern: [be verb] + optional adverb/whitespace + [past participle]
--
-- Be verbs: is, are, was, were, be, been, being, am.
-- Past participles: words ending in -ed, or known irregular forms.
--
-- Stores: root.data.passive = { {sentence="...", pattern="was written"}, ... }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

local BE_VERBS = {
  is=true, are=true, was=true, were=true,
  be=true, been=true, being=true, am=true,
}

-- Irregular past participles.
local IRREGULARS = {
  written=true, done=true, taken=true, given=true, known=true,
  seen=true, gone=true, come=true, run=true, put=true, set=true,
  let=true, hit=true, cut=true, read=true, made=true, said=true,
  told=true, shown=true, found=true, thought=true, brought=true,
  bought=true, taught=true, caught=true, left=true, lost=true,
  kept=true, built=true, sent=true, spent=true, held=true,
  meant=true, felt=true, heard=true, sold=true, paid=true, led=true,
  drawn=true, driven=true, eaten=true, fallen=true, flown=true,
  forgotten=true, frozen=true, hidden=true, ridden=true, risen=true,
  spoken=true, stolen=true, sworn=true, thrown=true, worn=true,
  beaten=true, chosen=true, proven=true, broken=true, shaken=true,
  woken=true, torn=true,
}

local function is_past_participle(word)
  local lw = word:lower()
  if IRREGULARS[lw] then return true end
  -- Regular: ends in -ed (at least 4 chars to exclude "red", "bed").
  if #lw >= 4 and lw:sub(-2) == "ed" then return true end
  return false
end

-- Extract word tokens in order from a sentence node.
local function sentence_words(sent)
  local words = {}
  local function walk(node)
    if node.type == nlcst.WORD then
      words[#words + 1] = nlcst.to_text(node)
      return
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
      for i = 1, #nc do walk(nc[i]) end
    end
  end
  walk(sent)
  return words
end

-- Walk the tree looking for passive constructions.
local function transformer(root)
  local findings = {}

  local function walk_node(node)
    if node.type == nlcst.SENTENCE then
      local words = sentence_words(node)
      -- Scan consecutive pairs (with gap for one intervening word, e.g. "is being done").
      for i = 1, #words - 1 do
        local w1 = words[i]:lower()
        if BE_VERBS[w1] then
          -- Check next word.
          local w2 = words[i + 1]
          if is_past_participle(w2) then
            findings[#findings + 1] = {
              sentence = nlcst.to_text(node),
              pattern  = w1 .. " " .. w2:lower(),
            }
          end
          -- Also check with one word gap (e.g. "was not taken").
          if i + 2 <= #words then
            local w3 = words[i + 2]
            if is_past_participle(w3) then
              local mid = words[i + 1]:lower()
              -- Limit intervening word to adverbs/function words (not, also, already, etc.).
              if #mid <= 8 then
                findings[#findings + 1] = {
                  sentence = nlcst.to_text(node),
                  pattern  = w1 .. " " .. mid .. " " .. w3:lower(),
                }
              end
            end
          end
        end
      end
      return -- Don't recurse further into sentence.
    end
    if node.children then
      local nc = node.children --[[:! { [integer]: { type: string, children?: unknown, value?: string, ... } }]]
      for i = 1, #nc do walk_node(nc[i]) end
    end
  end

  walk_node(root)

  root.data = root.data or {}
  root.data.passive = findings

  return root
end

function M.plugin(processor, _opts)
  processor:use_transformer(transformer)
end

setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
