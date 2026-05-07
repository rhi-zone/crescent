-- lib/unified/remark_emoji/init.lua
-- remark plugin that replaces :shortcode: emoji in text nodes with Unicode
-- emoji characters, mirroring the behaviour of remark-emoji (rhysd).
--
-- Usage:
--   local remark = require("lib.unified.remark")
--   local emoji  = require("lib.unified.remark_emoji")
--
--   local processor = remark():use(emoji)
--   local result    = processor:process("Hello :smile: world!")
--
-- Options:
--   opts.emoticon — boolean; also replace ASCII emoticons like `:-)` (default false)
--   opts.alias    — table of extra `shortcode → emoji` mappings

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Built-in emoji table ──────────────────────────────────────────────────────

local EMOJI = {
  -- Faces / emotions
  smile        = "\xF0\x9F\x98\x8A",  -- 😊
  heart        = "\xE2\x9D\xA4\xEF\xB8\x8F",  -- ❤️
  thumbsup     = "\xF0\x9F\x91\x8D",  -- 👍
  thumbsdown   = "\xF0\x9F\x91\x8E",  -- 👎
  fire         = "\xF0\x9F\x94\xA5",  -- 🔥
  star         = "\xE2\xAD\x90",      -- ⭐
  check        = "\xE2\x9C\x85",      -- ✅
  x            = "\xE2\x9D\x8C",      -- ❌
  warning      = "\xE2\x9A\xA0\xEF\xB8\x8F",  -- ⚠️
  info         = "\xE2\x84\xB9\xEF\xB8\x8F",  -- ℹ️
  rocket       = "\xF0\x9F\x9A\x80",  -- 🚀
  tada         = "\xF0\x9F\x8E\x89",  -- 🎉
  wave         = "\xF0\x9F\x91\x8B",  -- 👋
  clap         = "\xF0\x9F\x91\x8F",  -- 👏
  eyes         = "\xF0\x9F\x91\x80",  -- 👀
  thinking     = "\xF0\x9F\xA4\x94",  -- 🤔
  sob          = "\xF0\x9F\x98\xAD",  -- 😭
  joy          = "\xF0\x9F\x98\x82",  -- 😂
  wink         = "\xF0\x9F\x98\x89",  -- 😉
  sunglasses   = "\xF0\x9F\x98\x8E",  -- 😎
  ghost        = "\xF0\x9F\x91\xBB",  -- 👻
  zap          = "\xE2\x9A\xA1",      -- ⚡
  bug          = "\xF0\x9F\x90\x9B",  -- 🐛
  wrench       = "\xF0\x9F\x94\xA7",  -- 🔧
  computer     = "\xF0\x9F\x92\xBB",  -- 💻
  book         = "\xF0\x9F\x93\x9A",  -- 📚
  memo         = "\xF0\x9F\x93\x9D",  -- 📝
  package      = "\xF0\x9F\x93\xA6",  -- 📦
  lock         = "\xF0\x9F\x94\x92",  -- 🔒
  key          = "\xF0\x9F\x94\x91",  -- 🔑
  bell         = "\xF0\x9F\x94\x94",  -- 🔔
  hammer       = "\xF0\x9F\x94\xA8",  -- 🔨
  bulb         = "\xF0\x9F\x92\xA1",  -- 💡
  money        = "\xF0\x9F\x92\xB0",  -- 💰
  globe        = "\xF0\x9F\x8C\x8D",  -- 🌍
  tree         = "\xF0\x9F\x8C\xB2",  -- 🌲
  sun          = "\xE2\x98\x80\xEF\xB8\x8F",  -- ☀️
  moon         = "\xF0\x9F\x8C\x99",  -- 🌙
  snowflake    = "\xE2\x9D\x84\xEF\xB8\x8F",  -- ❄️
  cloud        = "\xE2\x98\x81\xEF\xB8\x8F",  -- ☁️
  rainbow      = "\xF0\x9F\x8C\x88",  -- 🌈
  cat          = "\xF0\x9F\x90\xB1",  -- 🐱
  dog          = "\xF0\x9F\x90\xB6",  -- 🐶
  snake        = "\xF0\x9F\x90\x8D",  -- 🐍
  coffee       = "\xE2\x98\x95",      -- ☕
  pizza        = "\xF0\x9F\x8D\x95",  -- 🍕
  beer         = "\xF0\x9F\x8D\xBA",  -- 🍺
  cake         = "\xF0\x9F\x8E\x82",  -- 🎂
  trophy       = "\xF0\x9F\x8F\x86",  -- 🏆
  medal        = "\xF0\x9F\xA5\x87",  -- 🥇
  -- GitHub-compatible aliases
  ["+1"]       = "\xF0\x9F\x91\x8D",  -- 👍
  ["-1"]       = "\xF0\x9F\x91\x8E",  -- 👎
  ["100"]      = "\xF0\x9F\x92\xAF",  -- 💯
  octocat      = "\xF0\x9F\x90\xB1",  -- 🐱 (approximation)
}

-- ── ASCII emoticons (opt-in) ──────────────────────────────────────────────────

-- Map `:-)` style emoticons to emoji.  Only enabled when opts.emoticon = true.
-- These are expressed as plain-text strings (not :word: shortcodes), so they
-- are matched literally in text node values.
local EMOTICONS = {
  [":-)" ] = "\xF0\x9F\x98\x8A",  -- 😊
  [":)"  ] = "\xF0\x9F\x98\x8A",  -- 😊
  [":-D" ] = "\xF0\x9F\x98\x82",  -- 😂
  [":D"  ] = "\xF0\x9F\x98\x82",  -- 😂
  [":-("] = "\xF0\x9F\x98\xAD",  -- 😭
  [":("  ] = "\xF0\x9F\x98\xAD",  -- 😭
  [";-)" ] = "\xF0\x9F\x98\x89",  -- 😉
  [";)"  ] = "\xF0\x9F\x98\x89",  -- 😉
  [":-P" ] = "\xF0\x9F\x98\x9C",  -- 😜
  [":P"  ] = "\xF0\x9F\x98\x9C",  -- 😜
  [":-|" ] = "\xF0\x9F\x98\x90",  -- 😐
  [":|"  ] = "\xF0\x9F\x98\x90",  -- 😐
}

-- ── Shortcode replacement ──────────────────────────────────────────────────────

-- Replace all :shortcode: patterns in a string using the lookup table.
-- Unknown shortcodes are left as-is.
--: (s: string, lookup: { [string]: string }) -> string
local function replace_shortcodes(s, lookup)
  local result, _ = s:gsub(":([%w%+%-]+):", function(name)
    local em = lookup[name]
    return em  -- nil leaves the match unchanged (gsub semantics)
  end)
  return result
end

-- Replace all emoticon strings in a string.
-- Longer patterns must be tried before shorter ones to avoid partial matches
-- (e.g. ":-)" before ":-)").  We iterate over a sorted key list.
local EMOTICON_KEYS = (function()
  local keys = {}
  for k in pairs(EMOTICONS) do keys[#keys + 1] = k end
  -- Sort longest first so ":-)" beats ":)".
  table.sort(keys, function(a, b) return #a > #b end)
  return keys
end)()

--: (s: string) -> string
local function replace_emoticons(s)
  for i = 1, #EMOTICON_KEYS do
    local pat = EMOTICON_KEYS[i]
    local rep = EMOTICONS[pat]
    -- Use plain-text find/replace loop (no regex meta-chars in emoticons).
    local result = {}
    local pos = 1
    local pat_len = #pat
    local s_len   = #s
    while pos <= s_len do
      local found = s:find(pat, pos, true)
      if found then
        result[#result + 1] = s:sub(pos, found - 1)
        result[#result + 1] = rep
        pos = found + pat_len
      else
        result[#result + 1] = s:sub(pos)
        break
      end
    end
    if #result > 0 then
      s = table.concat(result)
    end
  end
  return s
end

-- ── Tree walker ───────────────────────────────────────────────────────────────

local function walk(node, fn)
  fn(node)
  local children = node.children
  if children then
    for i = 1, #children do
      walk(children[i], fn)
    end
  end
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (processor: any, opts: { emoticon: boolean | nil, alias: { [string]: string } | nil } | nil) -> nil
local function remark_emoji(processor, opts)
  local use_emoticon = opts and opts.emoticon
  local extra_alias  = opts and opts.alias

  -- Build the effective lookup table.
  local lookup
  if extra_alias then
    lookup = {}
    for k, v in pairs(EMOJI) do lookup[k] = v end
    for k, v in pairs(extra_alias) do lookup[k] = v end
  else
    lookup = EMOJI
  end

  processor:use_transformer(function(ast)
    walk(ast, function(node)
      if node.type == "text" and node.value then
        local v = replace_shortcodes(node.value --[[:! string]], lookup)
        if use_emoticon then
          v = replace_emoticons(v)
        end
        node.value = v
      end
    end)
    return ast
  end)
end

setmetatable(M, { __call = function(_, ...) return remark_emoji(...) end })

M.plugin = remark_emoji

return M
