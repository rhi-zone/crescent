if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Glob pattern matching library.
-- Matches file paths against glob patterns (*, **, ?, [...], {a,b}, \x).
-- Pure Lua implementation, no external dependencies.

local M = {}

-- Metacharacters that make a string a glob pattern.
local META_CHARS = { ["*"] = true, ["?"] = true, ["["] = true, ["{"] = true, ["\\"] = true }

--: (s: string) -> boolean
function M.is_glob(s)
  local i = 1
  local len = #s
  while i <= len do
    local c = s:sub(i, i)
    if c == "\\" then
      return true -- escape sequence is glob syntax
    elseif META_CHARS[c] then
      return true
    else
      i = i + 1
    end
  end
  return false
end

-- Parse a character class [abc], [a-z], [!abc], [^abc].
-- Returns the index after the closing ] and a match function.
--: (pat: string, start: integer) -> (integer, (c: string) -> boolean) | (nil, string)
local function _parse_char_class(pat, start)
  local i = start
  local len = #pat
  local negate = false
  if i <= len and (pat:sub(i, i) == "!" or pat:sub(i, i) == "^") then
    negate = true
    i = i + 1
  end
  local chars = {}
  local ranges = {}
  -- Allow ] as first char in class
  if i <= len and pat:sub(i, i) == "]" then
    chars["]"] = true
    i = i + 1
  end
  while i <= len do
    local c = pat:sub(i, i)
    if c == "]" then
      local function matcher(ch)
        if chars[ch] then return not negate end
        for _, r in ipairs(ranges) do
          if ch >= r[1] and ch <= r[2] then return not negate end
        end
        return negate
      end
      return i + 1, matcher
    elseif c == "\\" and i + 1 <= len then
      i = i + 1
      chars[pat:sub(i, i)] = true
      i = i + 1
    elseif i + 2 <= len and pat:sub(i + 1, i + 1) == "-" and pat:sub(i + 2, i + 2) ~= "]" then
      ranges[#ranges + 1] = { c, pat:sub(i + 2, i + 2) }
      i = i + 3
    else
      chars[c] = true
      i = i + 1
    end
  end
  return nil, "unterminated character class"
end

-- Expand brace alternation {a,b,c} into a list of alternatives.
-- Supports nested braces.
-- Returns the index after the closing } and a list of strings.
--: (pat: string, start: integer) -> (integer, string[]) | (nil, string)
local function _parse_braces(pat, start)
  local depth = 1
  local i = start
  local len = #pat
  local parts = {}
  local current = {}
  while i <= len do
    local c = pat:sub(i, i)
    if c == "\\" and i + 1 <= len then
      current[#current + 1] = pat:sub(i, i + 1)
      i = i + 2
    elseif c == "{" then
      depth = depth + 1
      current[#current + 1] = c
      i = i + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then
        parts[#parts + 1] = table.concat(current)
        return i + 1, parts
      end
      current[#current + 1] = c
      i = i + 1
    elseif c == "," and depth == 1 then
      parts[#parts + 1] = table.concat(current)
      current = {}
      i = i + 1
    else
      current[#current + 1] = c
      i = i + 1
    end
  end
  return nil, "unterminated brace expression"
end

-- Token types for compiled patterns.
local TOK_LITERAL = 1   -- exact string
local TOK_STAR = 2      -- * (no /)
local TOK_GLOBSTAR = 3  -- ** (match across /)
local TOK_QUESTION = 4  -- ? (one char, not /)
local TOK_CLASS = 5     -- [...] character class
local TOK_ALT = 6       -- {a,b} alternation (each alt is a compiled pattern)

-- Compile a glob pattern into a token list.
-- Returns a list of tokens or (nil, errmsg).
--: (pat: string) -> { type: integer, ... }[] | (nil, string)
local function _compile(pat)
  local tokens = --[[:! { type: integer, ... }[] ]] {}
  local i = 1
  local len = #pat

  while i <= len do
    local c = pat:sub(i, i)

    if c == "*" then
      if i + 1 <= len and pat:sub(i + 1, i + 1) == "*" then
        -- ** globstar
        -- Skip any trailing /
        local j = i + 2
        if j <= len and pat:sub(j, j) == "/" then j = j + 1 end
        tokens[#tokens + 1] = { type = TOK_GLOBSTAR }
        i = j
      else
        tokens[#tokens + 1] = { type = TOK_STAR }
        i = i + 1
      end

    elseif c == "?" then
      tokens[#tokens + 1] = { type = TOK_QUESTION }
      i = i + 1

    elseif c == "[" then
      local after, matcher = _parse_char_class(pat, i + 1)
      if not after then return nil, matcher end
      tokens[#tokens + 1] = { type = TOK_CLASS, matcher = matcher }
      i = after

    elseif c == "{" then
      local after, parts = _parse_braces(pat, i + 1)
      if not after then return nil, parts end
      -- Compile each alternative
      local alts = {}
      for _, part in ipairs(parts) do
        local compiled, err = _compile(part)
        if not compiled then return nil, err end
        alts[#alts + 1] = compiled
      end
      tokens[#tokens + 1] = { type = TOK_ALT, alts = alts }
      i = after

    elseif c == "\\" then
      if i + 1 <= len then
        i = i + 1
        tokens[#tokens + 1] = { type = TOK_LITERAL, value = pat:sub(i, i) }
        i = i + 1
      else
        tokens[#tokens + 1] = { type = TOK_LITERAL, value = "\\" }
        i = i + 1
      end

    else
      -- Collect consecutive literal characters
      local start = i
      i = i + 1
      while i <= len do
        local cc = pat:sub(i, i)
        if cc == "*" or cc == "?" or cc == "[" or cc == "{" or cc == "\\" then
          break
        end
        i = i + 1
      end
      tokens[#tokens + 1] = { type = TOK_LITERAL, value = pat:sub(start, i - 1) }
    end
  end

  return tokens
end

-- Match a token list against a string starting at position si.
-- Returns true if the entire remaining string matches.
local function _match_tokens(tokens, ti, str, si)
  local tlen = #tokens
  local slen = #str

  while ti <= tlen do
    local tok = tokens[ti]

    if tok.type == TOK_LITERAL then
      local val = tok.value
      local vlen = #val
      if si + vlen - 1 > slen then return false end
      if str:sub(si, si + vlen - 1) ~= val then return false end
      si = si + vlen
      ti = ti + 1

    elseif tok.type == TOK_QUESTION then
      if si > slen then return false end
      if str:sub(si, si) == "/" then return false end
      si = si + 1
      ti = ti + 1

    elseif tok.type == TOK_CLASS then
      if si > slen then return false end
      local c = str:sub(si, si)
      if c == "/" then return false end
      if not tok.matcher(c) then return false end
      si = si + 1
      ti = ti + 1

    elseif tok.type == TOK_STAR then
      -- Try matching 0..N chars (not /)
      ti = ti + 1
      -- Optimization: if this is the last token, match all non-/ chars
      if ti > tlen then
        -- Must not contain / from si onward
        for j = si, slen do
          if str:sub(j, j) == "/" then return false end
        end
        return true
      end
      -- Try each possible extent
      for j = si, slen + 1 do
        if j > si and str:sub(j - 1, j - 1) == "/" then return false end
        if _match_tokens(tokens, ti, str, j) then return true end
      end
      return false

    elseif tok.type == TOK_GLOBSTAR then
      ti = ti + 1
      -- ** at end matches everything
      if ti > tlen then return true end
      -- Try matching the rest from every position
      for j = si, slen + 1 do
        if _match_tokens(tokens, ti, str, j) then return true end
      end
      return false

    elseif tok.type == TOK_ALT then
      -- Try each alternative; each alt's tokens are spliced in place
      ti = ti + 1
      for _, alt_tokens in ipairs(tok.alts) do
        -- Build a combined token list: alt_tokens + remaining tokens
        -- For efficiency, do a two-phase match
        local alt_len = #alt_tokens
        -- Try to match alt_tokens starting at si
        -- Use a recursive approach: match alt, then match rest
        local try_alt --: (integer, integer) -> boolean
        function try_alt(ai, sj)
          if ai > alt_len then
            -- Alt fully matched, now match the rest of the main tokens
            return _match_tokens(tokens, ti, str, sj)
          end
          -- Match one alt token
          local at = alt_tokens[ai]
          if at.type == TOK_LITERAL then
            local val = at.value
            local vlen = #val
            if sj + vlen - 1 > slen then return false end
            if str:sub(sj, sj + vlen - 1) ~= val then return false end
            return try_alt(ai + 1, sj + vlen)
          elseif at.type == TOK_STAR then
            local nai = ai + 1
            for j = sj, slen + 1 do
              if j > sj and str:sub(j - 1, j - 1) == "/" then return false end
              if try_alt(nai, j) then return true end
            end
            return false
          elseif at.type == TOK_GLOBSTAR then
            local nai = ai + 1
            for j = sj, slen + 1 do
              if try_alt(nai, j) then return true end
            end
            return false
          elseif at.type == TOK_QUESTION then
            if sj > slen then return false end
            if str:sub(sj, sj) == "/" then return false end
            return try_alt(ai + 1, sj + 1)
          elseif at.type == TOK_CLASS then
            if sj > slen then return false end
            local c = str:sub(sj, sj)
            if c == "/" then return false end
            if not at.matcher(c) then return false end
            return try_alt(ai + 1, sj + 1)
          elseif at.type == TOK_ALT then
            for _, sub_alts in ipairs(at.alts) do
              -- Recursively build combined list
              local combined = {}
              for _, t in ipairs(sub_alts) do combined[#combined + 1] = t end
              for k = ai + 1, alt_len do combined[#combined + 1] = alt_tokens[k] end
              -- Build outer combined
              local full = {}
              for _, t in ipairs(combined) do full[#full + 1] = t end
              for k = ti, tlen do full[#full + 1] = tokens[k] end
              if _match_tokens(full, 1, str, sj) then return true end
            end
            return false
          end
          return false
        end
        if try_alt(1, si) then return true end
      end
      return false
    end
  end

  return si > slen
end

-- Matcher object
local Matcher = {}
Matcher.__index = Matcher

--:: Matcher = { _tokens: { type: integer, ... }[], _pattern: string, ... }

--: (self: Matcher, str: string) -> boolean
function Matcher:match(str)
  return _match_tokens(self._tokens, 1, str, 1)
end

-- Compile a glob pattern into a matcher object.
--: (pattern: string) -> Matcher | (nil, string)
function M.compile(pattern)
  local tokens, err = _compile(pattern)
  if not tokens then return nil, err end
  local m = setmetatable({ _tokens = tokens, _pattern = pattern }, Matcher)
  return m
end

-- One-shot match: compile + match.
--: (pattern: string, str: string) -> boolean | (nil, string)
function M.match(pattern, str)
  local m, err = M.compile(pattern)
  if not m then return nil, err end
  return m:match(str)
end

-- Filter an array of strings, returning those that match the pattern.
--: (list: string[], pattern: string) -> string[] | (nil, string)
function M.filter(list, pattern)
  local m, err = M.compile(pattern)
  if not m then return nil, err end
  local result = {}
  for _, s in ipairs(list) do
    if m:match(s) then
      result[#result + 1] = s
    end
  end
  return result
end

-- Escape special characters in a Lua pattern.
local function _lua_pattern_escape(c)
  -- Characters that are special in Lua patterns
  if c:find("[%(%)%.%%%+%-%*%?%[%]%^%$]") then
    return "%" .. c
  end
  return c
end

-- Convert a glob pattern to a Lua pattern string.
-- Note: ** and {a,b} are complex; this handles common cases.
-- Returns a Lua pattern anchored with ^ and $.
--: (pattern: string) -> string | (nil, string)
function M.to_pattern(pattern)
  local parts = --[[:! string[] ]] {}
  local i = 1
  local len = #pattern

  parts[#parts + 1] = "^"

  while i <= len do
    local c = pattern:sub(i, i)

    if c == "*" then
      if i + 1 <= len and pattern:sub(i + 1, i + 1) == "*" then
        -- **
        local j = i + 2
        if j <= len and pattern:sub(j, j) == "/" then j = j + 1 end
        parts[#parts + 1] = ".*"
        i = j
      else
        parts[#parts + 1] = "[^/]*"
        i = i + 1
      end

    elseif c == "?" then
      parts[#parts + 1] = "[^/]"
      i = i + 1

    elseif c == "[" then
      -- Pass through character class (Lua pattern syntax is similar)
      local j = i + 1
      -- Handle negation: [! -> [^
      local class_parts = { "[" }
      if j <= len and (pattern:sub(j, j) == "!" or pattern:sub(j, j) == "^") then
        class_parts[#class_parts + 1] = "^"
        j = j + 1
      end
      -- Handle ] as first char
      if j <= len and pattern:sub(j, j) == "]" then
        class_parts[#class_parts + 1] = "]"
        j = j + 1
      end
      while j <= len and pattern:sub(j, j) ~= "]" do
        local cc = pattern:sub(j, j)
        if cc == "\\" and j + 1 <= len then
          class_parts[#class_parts + 1] = "%" .. pattern:sub(j + 1, j + 1)
          j = j + 2
        else
          -- Escape Lua pattern specials inside class if needed
          if cc == "%" then
            class_parts[#class_parts + 1] = "%%"
          else
            class_parts[#class_parts + 1] = cc
          end
          j = j + 1
        end
      end
      if j > len then return nil, "unterminated character class" end
      class_parts[#class_parts + 1] = "]"
      parts[#parts + 1] = table.concat(class_parts)
      i = j + 1

    elseif c == "{" then
      local after, alts = _parse_braces(pattern, i + 1)
      if not after then return nil, alts end
      -- Convert to Lua pattern alternation using nested patterns
      -- Lua patterns don't support alternation natively, so we
      -- convert each branch and combine. This is a best-effort conversion.
      -- For simple literal alternatives, we can use a character class or
      -- just pick the first. For full support, use compile() instead.
      local alt_pats = {}
      for _, alt in ipairs(alts) do
        local sub, err = M.to_pattern(alt)
        if not sub then return nil, err end
        -- Strip ^ and $ anchors from sub-patterns
        alt_pats[#alt_pats + 1] = sub:sub(2, -2)
      end
      -- Lua patterns don't have alternation; approximate with a helper
      -- Return a special marker that the caller would need to handle,
      -- or just do a simple case: if all alts are single chars, use [abc]
      local all_single = true
      for _, ap in ipairs(alt_pats) do
        if #ap ~= 1 or ap:find("[%%%[%]%(%)%.]") then
          all_single = false
          break
        end
      end
      if all_single then
        parts[#parts + 1] = "[" .. table.concat(alt_pats) .. "]"
      else
        -- Lua patterns can't do alternation; wrap in a group syntax that
        -- won't work as a pure Lua pattern. Return the pattern anyway
        -- for documentation, but note the limitation.
        parts[#parts + 1] = "(" .. table.concat(alt_pats, "|") .. ")"
      end
      i = after

    elseif c == "\\" then
      if i + 1 <= len then
        i = i + 1
        parts[#parts + 1] = _lua_pattern_escape(pattern:sub(i, i))
        i = i + 1
      else
        parts[#parts + 1] = "%%\\"
        i = i + 1
      end

    else
      parts[#parts + 1] = _lua_pattern_escape(c)
      i = i + 1
    end
  end

  parts[#parts + 1] = "$"
  return table.concat(parts)
end

return M
