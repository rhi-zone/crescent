-- lib/unified/retext_intensify/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_intensify: warns about weasel words / vague intensifiers.
-- Port of retext-intensify (https://github.com/retextjs/retext-intensify).
--
-- Options:
--   opts.ignore — array of words to exclude from flagging (case-insensitive).
--
-- Stores: root.data.intensify = { {word="very", sentence="..."}, ... }

local nlcst = require("lib.unified.nlcst") --[[: unknown]]

local M = {}

local DEFAULT_WORDS = {
  "very", "really", "quite", "rather", "somewhat", "fairly", "pretty",
  "extremely", "incredibly", "literally", "basically", "actually",
  "honestly", "truly", "absolutely", "definitely", "certainly", "clearly",
  "obviously", "simply", "just", "maybe", "perhaps", "probably", "possibly",
  "generally", "usually", "often", "sometimes", "might", "could", "should",
  "would", "various", "several", "many", "few", "some", "lot", "lots",
  "bit", "little", "stuff", "things", "thing",
}

local function make_word_set(list)
  local s = {}
  for i = 1, #list do s[list[i]] = true end
  return s
end

local function transformer(root, opts)
  opts = opts or {}
  local active = make_word_set(DEFAULT_WORDS)
  if opts.ignore then
    for i = 1, #opts.ignore do
      active[opts.ignore[i]:lower()] = nil
    end
  end

  local findings = {}

  local function walk(node)
    if node.type == nlcst.SENTENCE then
      local sent_text = nlcst.to_text(node)
      local children = node.children --[[:! { [integer]: any }]]
      for i = 1, #children do
        local child = children[i]
        if child.type == nlcst.WORD then
          local word = nlcst.to_text(child):lower()
          if active[word] then
            findings[#findings + 1] = {
              word     = word,
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
  root.data.intensify = findings

  return root
end

function M.plugin(processor, opts)
  processor:use_transformer(function(root)
    return transformer(root, opts)
  end)
end

setmetatable(M, { __call = function(_self, processor, opts)
  return M.plugin(processor, opts)
end })

return M
