-- lib/rehype_highlight/init.lua
-- rehype plugin: syntax highlighting for <pre><code> blocks.
--
-- Walks hast trees looking for <pre><code class="language-X"> nodes,
-- tokenizes the text content, and replaces children with highlighted
-- <span class="hljs-..."> elements.
--
-- API:
--   local rehype_highlight = require("lib.unified.rehype_highlight")
--   processor:use(rehype_highlight, opts)
--
-- opts:
--   opts.prefix  -- CSS class prefix, default "hljs-"
--   opts.detect  -- boolean, auto-detect language (default false, not implemented)
--   opts.aliases -- map of alias → canonical language name

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}

--:: list = { [integer]: unknown }
--:: Token = { [integer]: string }
--:: TokenList = { [integer]: Token }

-- ── Helpers ───────────────────────────────────────────────────────────────────

--: (string) -> boolean
local function is_word_char(c)
  return c:match("[%w_]") ~= nil
end

-- Check word boundary: character before pos (1-indexed) is not a word char.
--: (string, integer) -> boolean
local function at_word_start(src, pos)
  if pos == 1 then return true end
  return not is_word_char(src:sub(pos - 1, pos - 1))
end

-- Check word boundary: character after match end is not a word char.
--: (string, integer) -> boolean
local function at_word_end(src, pos)
  local c = src:sub(pos + 1, pos + 1)
  return c == "" or not is_word_char(c)
end

-- ── Token list → hast children ────────────────────────────────────────────────

-- tokens: list of {kind, text} where kind == "plain" or a hljs kind
--: (list, string) -> list
local function tokens_to_hast(tokens, prefix)
  local children = {} --: list
  local plain_buf = {} --: { [integer]: string }

  local function flush_plain()
    if #plain_buf > 0 then
      children[#children + 1] = { type = "text", value = table.concat(plain_buf) }
      plain_buf = {}
    end
  end

  for _, tok in ipairs(tokens) do
    local kind, text = tok[1], tok[2]
    if kind == "plain" then
      plain_buf[#plain_buf + 1] = text
    else
      flush_plain()
      children[#children + 1] = {
        type = "element",
        tag = "span",
        props = { class = prefix .. kind },
        children = { { type = "text", value = text } },
      }
    end
  end
  flush_plain()
  return children
end

-- ── Lua tokenizer ─────────────────────────────────────────────────────────────

local LUA_KEYWORDS = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
  ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
  ["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
  ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
  ["until"] = true, ["while"] = true,
}

local LUA_LITERALS = { ["true"] = true, ["false"] = true, ["nil"] = true }

local LUA_BUILTINS = {
  ["print"] = true, ["require"] = true, ["pairs"] = true, ["ipairs"] = true,
  ["type"] = true, ["tostring"] = true, ["tonumber"] = true, ["error"] = true,
  ["assert"] = true, ["pcall"] = true, ["xpcall"] = true, ["select"] = true,
  ["unpack"] = true, ["next"] = true, ["rawget"] = true, ["rawset"] = true,
  ["setmetatable"] = true, ["getmetatable"] = true,
}

--: (string) -> list
local function tokenize_lua(src)
  local tokens = {} --: TokenList
  local i = 1
  local n = #src

  while i <= n do
    -- Block comment --[[ ... ]]
    local bc_start, bc_end = src:find("^%-%-%[%[(.-)%]%]", i)
    if bc_start then
      local bc_end_ = bc_end --[[:! integer]]
      tokens[#tokens + 1] = { "comment", src:sub(bc_start, bc_end_) }
      i = bc_end_ + 1
    -- Line comment --
    elseif src:sub(i, i + 1) == "--" then
      local line_end = src:find("\n", i, true) or (n + 1)
      tokens[#tokens + 1] = { "comment", src:sub(i, line_end - 1) }
      i = line_end
    -- Long string [[...]]
    elseif src:sub(i, i + 1) == "[[" then
      local s, e = src:find("%]%]", i + 2, true)
      if s then
        local e_ = e --[[:! integer]]
        tokens[#tokens + 1] = { "string", src:sub(i, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Double-quoted string
    elseif src:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == '"' then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Single-quoted string
    elseif src:sub(i, i) == "'" then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == "'" then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Hex number
    elseif src:sub(i, i + 1):lower() == "0x" then
      local s, e = src:find("^0[xX][%x]+", i)
      if s then
        local e_ = e --[[:! integer]]
        tokens[#tokens + 1] = { "number", src:sub(s, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Number
    elseif src:sub(i, i):match("%d") or
           (src:sub(i, i) == "." and src:sub(i + 1, i + 1):match("%d")) then
      local s, e = src:find("^%d+%.?%d*", i)
      -- extend with optional exponent (e.g. 1e10, 3.14e-2)
      if s then
        local e_ = e --[[:! integer]]
        local e2 = src:match("^[eE][+%-]?%d+", e_ + 1)
        if e2 then e_ = e_ + #e2 end
        tokens[#tokens + 1] = { "number", src:sub(s, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Identifier / keyword / literal / built-in
    elseif src:sub(i, i):match("[%a_]") then
      local s, e = src:find("^[%w_]+", i)
      local word = src:sub(s, (e --[[:! integer]]))
      local kind
      if LUA_LITERALS[word] then
        kind = "literal"
      elseif LUA_KEYWORDS[word] then
        kind = "keyword"
      elseif LUA_BUILTINS[word] then
        kind = "built_in"
      else
        kind = "plain"
      end
      tokens[#tokens + 1] = { kind, word }
      i = (e --[[:! integer]]) + 1
    else
      tokens[#tokens + 1] = { "plain", src:sub(i, i) }
      i = i + 1
    end
  end

  return tokens
end

-- ── JavaScript tokenizer ──────────────────────────────────────────────────────

local JS_KEYWORDS = {
  ["var"] = true, ["let"] = true, ["const"] = true, ["function"] = true,
  ["return"] = true, ["if"] = true, ["else"] = true, ["for"] = true,
  ["while"] = true, ["do"] = true, ["break"] = true, ["continue"] = true,
  ["new"] = true, ["this"] = true, ["class"] = true, ["extends"] = true,
  ["import"] = true, ["export"] = true, ["default"] = true,
  ["typeof"] = true, ["instanceof"] = true, ["in"] = true, ["of"] = true,
  ["async"] = true, ["await"] = true, ["try"] = true, ["catch"] = true,
  ["finally"] = true, ["throw"] = true, ["switch"] = true, ["case"] = true,
}

local JS_LITERALS = {
  ["true"] = true, ["false"] = true, ["null"] = true, ["undefined"] = true,
}

--: (string) -> list
local function tokenize_js(src)
  local tokens = {} --: TokenList
  local i = 1
  local n = #src

  while i <= n do
    -- Block comment /* ... */
    if src:sub(i, i + 1) == "/*" then
      local s, e = src:find("%*/", i + 2, true)
      if s then
        local e_ = e --[[:! integer]]
        tokens[#tokens + 1] = { "comment", src:sub(i, e_ + 1) }
        i = e_ + 2
      else
        tokens[#tokens + 1] = { "comment", src:sub(i) }
        i = n + 1
      end
    -- Line comment //
    elseif src:sub(i, i + 1) == "//" then
      local line_end = src:find("\n", i, true) or (n + 1)
      tokens[#tokens + 1] = { "comment", src:sub(i, line_end - 1) }
      i = line_end
    -- Template literal `...`
    elseif src:sub(i, i) == "`" then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == "`" then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Double-quoted string
    elseif src:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == '"' then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Single-quoted string
    elseif src:sub(i, i) == "'" then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == "'" then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Number
    elseif src:sub(i, i):match("%d") or
           (src:sub(i, i) == "." and src:sub(i + 1, i + 1):match("%d")) then
      local s, e = src:find("^%d+%.?%d*", i)
      if s then
        local e_ = e --[[:! integer]]
        local e2 = src:match("^[eE][+%-]?%d+", e_ + 1)
        if e2 then e_ = e_ + #e2 end
        tokens[#tokens + 1] = { "number", src:sub(s, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Identifier / keyword / literal
    elseif src:sub(i, i):match("[%a_$]") then
      local s, e = src:find("^[%w_$]+", i)
      local word = src:sub(s, (e --[[:! integer]]))
      local kind
      if JS_LITERALS[word] then
        kind = "literal"
      elseif JS_KEYWORDS[word] then
        kind = "keyword"
      else
        kind = "plain"
      end
      tokens[#tokens + 1] = { kind, word }
      i = (e --[[:! integer]]) + 1
    else
      tokens[#tokens + 1] = { "plain", src:sub(i, i) }
      i = i + 1
    end
  end

  return tokens
end

-- ── Python tokenizer ──────────────────────────────────────────────────────────

local PY_KEYWORDS = {
  ["def"] = true, ["class"] = true, ["return"] = true, ["if"] = true,
  ["elif"] = true, ["else"] = true, ["for"] = true, ["while"] = true,
  ["import"] = true, ["from"] = true, ["as"] = true, ["with"] = true,
  ["try"] = true, ["except"] = true, ["finally"] = true, ["raise"] = true,
  ["pass"] = true, ["break"] = true, ["continue"] = true, ["and"] = true,
  ["or"] = true, ["not"] = true, ["in"] = true, ["is"] = true,
  ["lambda"] = true, ["yield"] = true, ["async"] = true, ["await"] = true,
}

local PY_LITERALS = { ["True"] = true, ["False"] = true, ["None"] = true }

--: (string) -> list
local function tokenize_python(src)
  local tokens = {} --: TokenList
  local i = 1
  local n = #src

  while i <= n do
    -- Triple double-quoted string
    if src:sub(i, i + 2) == '"""' then
      local s, e = src:find('"""', i + 3, true)
      if s then
        local e_ = e --[[:! integer]]
        tokens[#tokens + 1] = { "string", src:sub(i, e_ + 2) }
        i = e_ + 3
      else
        tokens[#tokens + 1] = { "string", src:sub(i) }
        i = n + 1
      end
    -- Triple single-quoted string
    elseif src:sub(i, i + 2) == "'''" then
      local s, e = src:find("'''", i + 3, true)
      if s then
        local e_ = e --[[:! integer]]
        tokens[#tokens + 1] = { "string", src:sub(i, e_ + 2) }
        i = e_ + 3
      else
        tokens[#tokens + 1] = { "string", src:sub(i) }
        i = n + 1
      end
    -- Comment #
    elseif src:sub(i, i) == "#" then
      local line_end = src:find("\n", i, true) or (n + 1)
      tokens[#tokens + 1] = { "comment", src:sub(i, line_end - 1) }
      i = line_end
    -- Double-quoted string
    elseif src:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == '"' then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Single-quoted string
    elseif src:sub(i, i) == "'" then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == "'" then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Number
    elseif src:sub(i, i):match("%d") or
           (src:sub(i, i) == "." and src:sub(i + 1, i + 1):match("%d")) then
      local s, e = src:find("^%d+%.?%d*", i)
      if s then
        local e_ = e --[[:! integer]]
        local e2 = src:match("^[eE][+%-]?%d+", e_ + 1)
        if e2 then e_ = e_ + #e2 end
        tokens[#tokens + 1] = { "number", src:sub(s, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Identifier / keyword / literal
    elseif src:sub(i, i):match("[%a_]") then
      local s, e = src:find("^[%w_]+", i)
      local word = src:sub(s, (e --[[:! integer]]))
      local kind
      if PY_LITERALS[word] then
        kind = "literal"
      elseif PY_KEYWORDS[word] then
        kind = "keyword"
      else
        kind = "plain"
      end
      tokens[#tokens + 1] = { kind, word }
      i = (e --[[:! integer]]) + 1
    else
      tokens[#tokens + 1] = { "plain", src:sub(i, i) }
      i = i + 1
    end
  end

  return tokens
end

-- ── JSON tokenizer ────────────────────────────────────────────────────────────

local JSON_LITERALS = { ["true"] = true, ["false"] = true, ["null"] = true }

--: (string) -> list
local function tokenize_json(src)
  local tokens = {} --: TokenList
  local i = 1
  local n = #src

  while i <= n do
    -- String — check if it's a key (followed by : after optional whitespace)
    if src:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == '"' then j = j + 1; break
        else j = j + 1
        end
      end
      local str_text = src:sub(i, j - 1)
      -- Peek past whitespace for ':'
      local after = src:match("^%s*:", j)
      if after then
        tokens[#tokens + 1] = { "attr", str_text }
      else
        tokens[#tokens + 1] = { "string", str_text }
      end
      i = j
    -- Number (including negative)
    elseif src:sub(i, i):match("[%d%-]") and
           (src:sub(i, i):match("%d") or src:sub(i + 1, i + 1):match("%d")) then
      local s, e = src:find("^%-?%d+%.?%d*", i)
      if s then
        local e_ = e --[[:! integer]]
        local e2 = src:match("^[eE][+%-]?%d+", e_ + 1)
        if e2 then e_ = e_ + #e2 end
        tokens[#tokens + 1] = { "number", src:sub(s, e_) }
        i = e_ + 1
      else
        tokens[#tokens + 1] = { "plain", src:sub(i, i) }
        i = i + 1
      end
    -- Literal: true / false / null
    elseif src:sub(i, i):match("[%a]") then
      local s, e = src:find("^[%a]+", i)
      local word = src:sub(s, (e --[[:! integer]]))
      if JSON_LITERALS[word] then
        tokens[#tokens + 1] = { "literal", word }
      else
        tokens[#tokens + 1] = { "plain", word }
      end
      i = (e --[[:! integer]]) + 1
    else
      tokens[#tokens + 1] = { "plain", src:sub(i, i) }
      i = i + 1
    end
  end

  return tokens
end

-- ── Bash tokenizer ────────────────────────────────────────────────────────────

local BASH_KEYWORDS = {
  ["if"] = true, ["then"] = true, ["else"] = true, ["elif"] = true,
  ["fi"] = true, ["for"] = true, ["while"] = true, ["do"] = true,
  ["done"] = true, ["case"] = true, ["esac"] = true, ["function"] = true,
  ["return"] = true, ["exit"] = true, ["export"] = true, ["local"] = true,
}

local BASH_BUILTINS = {
  ["echo"] = true, ["cd"] = true, ["ls"] = true, ["cat"] = true,
  ["grep"] = true, ["sed"] = true, ["awk"] = true, ["find"] = true,
  ["rm"] = true, ["cp"] = true, ["mv"] = true,
}

--: (string) -> list
local function tokenize_bash(src)
  local tokens = {} --: TokenList
  local i = 1
  local n = #src

  while i <= n do
    -- Comment #
    if src:sub(i, i) == "#" then
      local line_end = src:find("\n", i, true) or (n + 1)
      tokens[#tokens + 1] = { "comment", src:sub(i, line_end - 1) }
      i = line_end
    -- Double-quoted string
    elseif src:sub(i, i) == '"' then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "\\" then j = j + 2
        elseif c == '"' then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Single-quoted string (no escapes in bash $'...' ignored here, simple case)
    elseif src:sub(i, i) == "'" then
      local j = i + 1
      while j <= n do
        local c = src:sub(j, j)
        if c == "'" then j = j + 1; break
        else j = j + 1
        end
      end
      tokens[#tokens + 1] = { "string", src:sub(i, j - 1) }
      i = j
    -- Identifier / keyword / built-in
    elseif src:sub(i, i):match("[%a_]") then
      local s, e = src:find("^[%w_%-%.]+", i)
      local s_ = s --[[:! integer]]
      local e_ = e --[[:! integer]]
      local word = src:sub(s_, e_)
      -- Only match pure alpha-underscore for keywords/builtins
      local plain_word = src:match("^[%w_]+", i) or ""
      local kind
      if BASH_KEYWORDS[plain_word] and #plain_word == (e_ - s_ + 1) then
        kind = "keyword"
      elseif BASH_BUILTINS[plain_word] and #plain_word == (e_ - s_ + 1) then
        kind = "built_in"
      else
        kind = "plain"
      end
      tokens[#tokens + 1] = { kind, word }
      i = e_ + 1
    else
      tokens[#tokens + 1] = { "plain", src:sub(i, i) }
      i = i + 1
    end
  end

  return tokens
end

-- ── Language registry ─────────────────────────────────────────────────────────

local TOKENIZERS = {
  lua        = tokenize_lua,
  javascript = tokenize_js,
  js         = tokenize_js,
  python     = tokenize_python,
  py         = tokenize_python,
  json       = tokenize_json,
  bash       = tokenize_bash,
  sh         = tokenize_bash,
}

-- ── Tree walker ───────────────────────────────────────────────────────────────

-- Extract concatenated text content from a list of hast children.
--:: HastChild = { type: string, value: string | nil, children: list | nil, ... }
--: (list) -> string
local function extract_text(children)
  local parts = {} --: { [integer]: string }
  for _, child in ipairs(children) do
    local ch = child --[[:! HastChild]]
    if ch.type == "text" then
      parts[#parts + 1] = ch.value or ""
    elseif ch.type == "element" and ch.children then
      parts[#parts + 1] = extract_text(ch.children)
    end
  end
  return table.concat(parts)
end

-- Walk a hast tree and apply highlighting to <pre><code> blocks.
--: (any, string, { [string]: string }) -> any
local function walk(node, prefix, aliases)
  if not node then return node end

  if node.type == "element" and node.tag == "pre" then
    local children = node.children or {}
    -- Find first element child that is <code>
    local code_node
    for _, child in ipairs(children) do
      if child.type == "element" and child.tag == "code" then
        code_node = child
        break
      end
    end

    if code_node then
      local code_node_ = code_node --[[:! HastChild]]
      local class = ((code_node_.props or {}) --[[:! { class: string | nil, ... }]]).class or ""
      local lang = class:match("^language%-(.+)$")
      if lang then
        -- Resolve aliases
        lang = aliases[lang] or lang
        local tokenize = TOKENIZERS[lang]
        if tokenize then
          local tokenize_ = tokenize --[[:! (string) -> list]]
          local src = extract_text((code_node_.children or {}) --[[:! list]])
          local toks = tokenize_(src)
          local new_children = tokens_to_hast(toks, prefix)
          -- Replace code node children with highlighted children
          code_node_.children = new_children
          -- Add hljs class to <pre>
          local pre_props = node.props or {}
          local existing = pre_props.class
          if existing and existing ~= "" then
            pre_props.class = existing .. " hljs"
          else
            pre_props.class = "hljs"
          end
          node.props = pre_props
        end
      end
    end
    -- Still recurse into children for nested structure
    return node
  end

  -- Recurse into children
  if node.children then
    for i, child in ipairs(node.children) do
      node.children[i] = walk(child, prefix, aliases)
    end
  end

  return node
end

-- ── Plugin ────────────────────────────────────────────────────────────────────

--: (any, any) -> nil
local function plugin(processor, opts)
  opts = opts or {}
  local prefix  = opts.prefix  or "hljs-"
  local aliases = opts.aliases or {}

  processor:use_transformer(function(tree)
    return walk(tree, prefix, aliases)
  end)
end

M.plugin = plugin

-- Make the module callable as a plugin directly:
--   processor:use(rehype_highlight)
-- or with opts:
--   processor:use(rehype_highlight, opts)
setmetatable(M, { __call = function(_, proc, opts_) plugin(proc, opts_) end })

-- Expose tokenizers for testing and extension.
M.tokenizers = TOKENIZERS

return M
