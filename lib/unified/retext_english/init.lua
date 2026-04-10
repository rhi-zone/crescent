-- lib/unified/retext_english/init.lua
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- retext_english: English language tokenizer producing nlcst trees.
-- Ported from retext-english (https://github.com/retextjs/retext).
--
-- Parse algorithm:
--   1. Split into paragraphs on double newline (\n\n).
--   2. Within each paragraph, split into sentences on . ! ? followed by
--      whitespace or end-of-string.
--   3. Within each sentence, tokenize into:
--      - Words:       [%a%d'%-]+ (letters, digits, apostrophes, hyphens)
--      - Punctuation: [%p] (excluding apostrophes/hyphens consumed in words)
--      - Whitespace:  [ \t]+

local nlcst = require("lib.unified.nlcst")

local M = {}

-- Tokenize a sentence string into nlcst child nodes.
local function tokenize_sentence(s)
  local children = {}
  local i = 1
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("[ \t]") then
      -- Whitespace run.
      local j = i + 1
      while j <= n and s:sub(j, j):match("[ \t]") do j = j + 1 end
      children[#children + 1] = nlcst.whitespace(s:sub(i, j - 1))
      i = j
    elseif c:match("[%a%d]") or
           ((c == "'" or c == "-") and i < n and s:sub(i + 1, i + 1):match("[%a%d]")) then
      -- Word: letters/digits, with embedded apostrophes/hyphens.
      local j = i + 1
      while j <= n do
        local ch = s:sub(j, j)
        if ch:match("[%a%d]") then
          j = j + 1
        elseif (ch == "'" or ch == "-") and j < n and s:sub(j + 1, j + 1):match("[%a%d]") then
          j = j + 1
        else
          break
        end
      end
      children[#children + 1] = nlcst.word(s:sub(i, j - 1))
      i = j
    elseif c:match("[%p]") then
      -- Single punctuation character.
      children[#children + 1] = nlcst.punctuation(c)
      i = i + 1
    else
      -- Any other character (e.g. unicode above ASCII) — treat as punctuation.
      children[#children + 1] = nlcst.punctuation(c)
      i = i + 1
    end
  end
  return children
end

-- Split a paragraph string into sentence strings, preserving inter-sentence
-- whitespace. Returns an array of { text=string, ws=string|nil } entries.
-- ws is the whitespace that followed the sentence terminator (or nil for last).
local function split_sentences(para)
  local sentences = {}
  local start = 1
  local n = #para
  local i = 1
  while i <= n do
    local c = para:sub(i, i)
    if c == "." or c == "!" or c == "?" then
      -- Check if followed by whitespace or end.
      if i == n or para:sub(i + 1, i + 1):match("[ \t\n]") then
        local sent_text = para:sub(start, i)
        -- Collect trailing whitespace after the sentence terminator.
        local j = i + 1
        local ws_start = j
        while j <= n and para:sub(j, j):match("[ \t]") do j = j + 1 end
        local ws = (j > ws_start) and para:sub(ws_start, j - 1) or nil
        sentences[#sentences + 1] = { text = sent_text, ws = ws }
        start = j
        i = j
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  -- Remainder (no terminal punctuation).
  if start <= n then
    local tail = para:sub(start, n)
    if tail:match("[^ \t\n]") then
      sentences[#sentences + 1] = { text = tail, ws = nil }
    end
  end
  return sentences
end

-- Parse a source string into an nlcst RootNode.
function M.parse(source)
  -- 1. Split into paragraphs on \n\n (one or more blank lines).
  local raw_paras = {}
  local s = source
  -- Normalise \r\n.
  s = s:gsub("\r\n", "\n")
  for para in (s .. "\n\n"):gmatch("(.-)\n\n+") do
    local trimmed = para:match("^(.-)%s*$")
    if trimmed and #trimmed > 0 then
      raw_paras[#raw_paras + 1] = trimmed
    end
  end
  if #raw_paras == 0 then
    -- Single paragraph with no blank lines.
    local trimmed = s:match("^(.-)%s*$")
    if trimmed and #trimmed > 0 then
      raw_paras[1] = trimmed
    end
  end

  -- 2. Build paragraph nodes.
  local para_nodes = {}
  for _, para_text in ipairs(raw_paras) do
    local sent_strs = split_sentences(para_text)
    local sent_nodes = {}
    for si, sent_entry in ipairs(sent_strs) do
      local children = tokenize_sentence(sent_entry.text)
      if #children > 0 then
        sent_nodes[#sent_nodes + 1] = nlcst.sentence(children)
      end
      -- Insert a WhiteSpaceNode between sentences (not after the last one).
      if sent_entry.ws and si < #sent_strs then
        sent_nodes[#sent_nodes + 1] = nlcst.whitespace(sent_entry.ws)
      end
    end
    if #sent_nodes > 0 then
      para_nodes[#para_nodes + 1] = nlcst.paragraph(sent_nodes)
    end
  end

  return nlcst.root(para_nodes)
end

-- Plugin interface for unified: attach parse function to processor.
function M.plugin(processor, _opts)
  processor:parser(M.parse)
end

-- Allow use as both a standalone module and a unified plugin.
-- `retext_english(processor)` works via __call metamethod.
setmetatable(M, { __call = function(self, processor, opts)
  return self.plugin(processor, opts)
end })

return M
