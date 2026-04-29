-- lib/unified/rehype_accessible_emojis/init.lua
-- rehype plugin: wrap emoji characters in text nodes with accessible <span>
-- elements (role="img" aria-label="emoji name").
-- Port of rehype-accessible-emojis.
--
-- Detects emoji by scanning text nodes for known emoji byte sequences.
-- Each found emoji is wrapped in:
--   <span role="img" aria-label="LABEL" aria-hidden="false">EMOJI</span>
-- Surrounding plain text is kept as text nodes.
--
-- Plugin signature (unified):
--   function(processor, opts)
--
-- Usage:
--   local rehype  = require("lib.unified.rehype")
--   local a11y    = require("lib.unified.rehype_accessible_emojis")
--   local processor = rehype():use(a11y)

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

-- ── Emoji lookup table ────────────────────────────────────────────────────────
-- Keys are raw UTF-8 byte strings. Values are accessible label strings.
-- Entries with variation selector U+FE0F (0xEF 0xB8 0x8F) are listed first so
-- the longer sequence is tried before the bare codepoint.

local EMOJI_NAMES = {
  -- Smileys & people
  ["\xF0\x9F\x98\x8A"] = "smiling face",
  ["\xF0\x9F\x98\x82"] = "face with tears of joy",
  ["\xF0\x9F\xA4\x94"] = "thinking face",
  ["\xF0\x9F\x91\x8B"] = "waving hand",
  -- Hearts & symbols
  ["\xE2\x9D\xA4\xEF\xB8\x8F"] = "red heart",   -- ❤️ (with VS16)
  ["\xE2\x9D\xA4"]              = "red heart",   -- ❤  (bare)
  -- Hand gestures
  ["\xF0\x9F\x91\x8D"] = "thumbs up",
  ["\xF0\x9F\x91\x8E"] = "thumbs down",
  -- Objects & symbols
  ["\xF0\x9F\x94\xA5"] = "fire",
  ["\xE2\xAD\x90\xEF\xB8\x8F"] = "star",        -- ⭐️ (with VS16)
  ["\xE2\xAD\x90"]              = "star",        -- ⭐ (bare)
  ["\xE2\x9C\x85"] = "check mark",
  ["\xE2\x9D\x8C"] = "cross mark",
  ["\xE2\x9A\xA0\xEF\xB8\x8F"] = "warning",     -- ⚠️ (with VS16)
  ["\xE2\x9A\xA0"]              = "warning",     -- ⚠  (bare)
  ["\xF0\x9F\x9A\x80"] = "rocket",
  ["\xF0\x9F\x8E\x89"] = "party popper",
  -- Tech & misc
  ["\xF0\x9F\x92\xBB"] = "laptop",
  ["\xF0\x9F\x93\x9A"] = "books",
  ["\xF0\x9F\x93\x9D"] = "memo",
  ["\xF0\x9F\x90\x9B"] = "bug",
  ["\xF0\x9F\x94\xA7"] = "wrench",
  ["\xF0\x9F\x92\xA1"] = "light bulb",
  -- Additional common ones
  ["\xF0\x9F\x8C\x9F"] = "glowing star",
  ["\xF0\x9F\x91\x8F"] = "clapping hands",
  ["\xF0\x9F\x92\xAF"] = "hundred points",
  ["\xF0\x9F\x99\x8F"] = "folded hands",
  ["\xF0\x9F\x92\xB0"] = "money bag",
  ["\xF0\x9F\x8E\xAF"] = "direct hit",
  ["\xF0\x9F\x93\xA2"] = "loudspeaker",
  ["\xF0\x9F\x93\x8C"] = "pushpin",
  ["\xF0\x9F\x93\xAF"] = "bell with slash",
  ["\xF0\x9F\x94\x94"] = "bell",
  ["\xF0\x9F\x93\x85"] = "calendar",
  ["\xF0\x9F\x93\x88"] = "chart increasing",
  ["\xF0\x9F\x93\x89"] = "chart decreasing",
  ["\xF0\x9F\x8F\xA0"] = "house",
  ["\xF0\x9F\x8C\x8D"] = "globe showing europe-africa",
  ["\xF0\x9F\x8C\x8E"] = "globe showing americas",
  ["\xF0\x9F\x8C\x8F"] = "globe showing asia-australia",
  ["\xF0\x9F\x8E\xB5"] = "musical note",
  ["\xF0\x9F\x8E\xB6"] = "musical notes",
}

-- Pre-sorted list of emoji byte strings, longest first, so greedy matching
-- tries longer sequences (with variation selector) before shorter bare ones.
local EMOJI_SORTED = {}
for k in pairs(EMOJI_NAMES) do
  EMOJI_SORTED[#EMOJI_SORTED + 1] = k
end
table.sort(EMOJI_SORTED, function(a, b) return #a > #b end)

-- ── Detection ─────────────────────────────────────────────────────────────────

-- Returns the byte length of the UTF-8 character at position i in s,
-- or 0 if the byte is not a valid UTF-8 lead byte.
--: (string, number) -> number
local function utf8_char_len(s, i)
  local b = s:byte(i)
  if not b then return 0 end
  if b < 0x80 then return 1 end
  if b < 0xC0 then return 0 end  -- continuation byte, shouldn't be lead
  if b < 0xE0 then return 2 end
  if b < 0xF0 then return 3 end
  return 4
end

-- Returns true when s starts with the bytes of pattern at position i.
--: (string, number, string) -> boolean
local function starts_with_at(s, i, pattern)
  local len = #pattern
  return s:sub(i, i + len - 1) == pattern
end

-- Find the first emoji in s starting at byte offset `from`.
-- Returns: start_byte, end_byte (inclusive), label  or nil if none found.
--: (string, number) -> (any, any, any)
local function find_emoji(s, from)
  local i = from
  local len = #s
  while i <= len do
    -- Try each emoji in longest-first order.
    local matched = false
    for _, e in ipairs(EMOJI_SORTED) do
      if starts_with_at(s, i, e) then
        local label = EMOJI_NAMES[e] or "emoji"
        return i, i + #e - 1, label
      end
    end
    -- Advance one UTF-8 character.
    local clen = utf8_char_len(s, i)
    i = i + (clen > 0 and clen or 1)
  end
  return nil, nil, nil
end

-- ── Span constructor ──────────────────────────────────────────────────────────

--: (string, string) -> any
local function emoji_span(emoji_str, label)
  return {
    type = "element",
    tag  = "span",
    props = {
      role             = "img",
      ["aria-label"]   = label,
    },
    children = { { type = "text", value = emoji_str } },
  }
end

-- ── Text node splitter ────────────────────────────────────────────────────────

-- Split a text node's value into a list of text/span nodes.
-- Returns a list (possibly length 1 = the original text node unchanged).
--: (any) -> any
local function split_text_node(node)
  local s = node.value or ""
  if #s == 0 then return { node } end

  local result = {}
  local pos = 1

  while pos <= #s do
    local es, ee, label = find_emoji(s, pos)
    if not es then
      -- No more emoji; append remainder as text.
      if pos <= #s then
        result[#result + 1] = { type = "text", value = s:sub(pos) }
      end
      break
    end
    -- Text before the emoji.
    if es > pos then
      result[#result + 1] = { type = "text", value = s:sub(pos, es - 1) }
    end
    -- The emoji span.
    result[#result + 1] = emoji_span(s:sub(es, ee), label)
    pos = ee + 1
  end

  if #result == 0 then return { node } end
  return result
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

-- Walk the tree; when a text node contains emoji, replace it with the
-- expanded list of text/span nodes in its parent's children array.
--: (any) -> nil
local function walk(node)
  if not node.children then return end
  local new_children = {}
  for _, child in ipairs(node.children) do
    if child.type == "text" then
      local parts = split_text_node(child)
      for _, p in ipairs(parts) do
        new_children[#new_children + 1] = p
      end
    else
      walk(child)
      new_children[#new_children + 1] = child
    end
  end
  node.children = new_children
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
function M.plugin(processor, _opts)
  processor:use_transformer(function(tree)
    walk(tree)
    return tree
  end)
end

setmetatable(M, {
  __call = function(_self, processor, opts)
    M.plugin(processor, opts)
  end,
})

-- Expose the lookup table and helpers for testing.
M._names = EMOJI_NAMES

return M
