if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/safe_regex/init.lua
--
-- Validator for JS regex patterns against catastrophic backtracking.
--
-- Invariant enforced (the "hologram-shaped" rule):
--   No quantifier may be applied to an expression that itself contains
--   an UNBOUNDED quantifier.
--
-- Quantifier classification (this implementation):
--   *        unbounded
--   +        unbounded
--   {n,}     unbounded
--   {n,m}    unbounded when m > n (the loop allows backtracking width)
--   ?        bounded   (matches 0 or 1)
--   {n}      bounded   (exact count)
--   {n,n}    bounded
--   {0,0}    bounded
--
-- "Contains an unbounded quantifier" is a property of the subexpression
-- the quantifier applies to. Anchors (^, $, \b, \B) are zero-width and
-- cannot be quantified at all (rejected).
--
-- Patterns rejected by this validator:
--   (a+)+b      -- + applied to a group containing +
--   (a*)*b      -- * on *
--   (\d+)+      -- + on +
--   (a+){3}     -- {3} (bounded) on a group with + (unbounded child)
--                  The outer is bounded but the inner is unbounded
--                  expansion -- still classified as nesting; we reject.
--   (?:(.+)+)
--   (?=(.+)+)x  -- lookaround contents are a child subtree
--
-- Patterns accepted:
--   a+b
--   (ab)+c
--   a{3}b{2}
--   [a-z]+
--   \d+
--   (?:abc)+
--   (a)(b)(c)        -- sibling quantifiers don't compose
--   ^a+$             -- anchors are not quantified
--
-- Known limitation (v1):
--   Alternation overlap is NOT detected. Patterns like (a|aa)+ or
--   (a|a)+ are accepted by this validator even though they exhibit
--   catastrophic backtracking on rejecting inputs. Detecting overlap
--   requires Thompson-NFA construction with ambiguity analysis and
--   is planned for a future stronger pass.
--
-- API:
--   M.validate_pattern(pattern: string)
--     -> (true, nil)              when safe
--     -> (false, errmsg: string)  when unsafe or malformed
--
-- This shape (boolean + optional errmsg) is intentional: the function
-- is a validator, not a value producer, so (nil, errmsg) would be
-- awkward.  See docs/conventions.md -- error returns. Pure function,
-- no I/O, no module-level state.
--
-- Algorithm: single-pass recursive descent parser. Each parse function
-- returns a node with two booleans:
--   has_unbounded -- subtree contains an unbounded quantifier
--   is_anchor     -- node is zero-width (cannot be quantified)
-- At every quantifier the parser checks the child's has_unbounded
-- (when the new quantifier is itself unbounded OR when stacking on
-- a child that already has one): nesting fails immediately.
--
-- Reference: ~/git/exoplace/hologram/src/logic/safe-regex.ts. The
-- hologram version additionally rejects capturing groups, lookaround,
-- backreferences, and unknown escapes as "unsafe" outright. We accept
-- those structurally (this is a validator for full JS regex surface)
-- but enforce the same nesting invariant.

local M = {}
M._tier = "pure"

--:: Node = { has_unbounded: boolean, is_anchor: boolean }
--:: Parser = { pattern: string, pos: integer, len: integer }

-- byte values used throughout (avoid string.sub allocations in hot loop)
local B_LPAREN = (string.byte("(") or 0) --: integer
local B_RPAREN = (string.byte(")") or 0) --: integer
local B_LBRACKET = (string.byte("[") or 0) --: integer
local B_RBRACKET = (string.byte("]") or 0) --: integer
local B_LBRACE = (string.byte("{") or 0) --: integer
local B_RBRACE = (string.byte("}") or 0) --: integer
local B_BACKSLASH = (string.byte("\\") or 0) --: integer
local B_PIPE = (string.byte("|") or 0) --: integer
local B_STAR = (string.byte("*") or 0) --: integer
local B_PLUS = (string.byte("+") or 0) --: integer
local B_QUESTION = (string.byte("?") or 0) --: integer
local B_DOT = (string.byte(".") or 0) --: integer
local B_CARET = (string.byte("^") or 0) --: integer
local B_DOLLAR = (string.byte("$") or 0) --: integer
local B_COLON = (string.byte(":") or 0) --: integer
local B_EQUALS = (string.byte("=") or 0) --: integer
local B_BANG = (string.byte("!") or 0) --: integer
local B_LT = (string.byte("<") or 0) --: integer
local B_GT = (string.byte(">") or 0) --: integer
local B_COMMA = (string.byte(",") or 0) --: integer
local B_0 = (string.byte("0") or 0) --: integer
local B_9 = (string.byte("9") or 0) --: integer
local B_LOWER_B = (string.byte("b") or 0) --: integer
local B_UPPER_B = (string.byte("B") or 0) --: integer
local B_K = (string.byte("k") or 0) --: integer
local B_LOWER_A = (string.byte("a") or 0) --: integer
local B_LOWER_F = (string.byte("f") or 0) --: integer
local B_LOWER_U = (string.byte("u") or 0) --: integer
local B_LOWER_X = (string.byte("x") or 0) --: integer
local B_UPPER_A = (string.byte("A") or 0) --: integer
local B_UPPER_F = (string.byte("F") or 0) --: integer

--: (integer | nil) -> boolean
local function is_hex_byte(c)
  if c == nil then return false end
  if c >= B_0 and c <= B_9 then return true end
  if c >= B_LOWER_A and c <= B_LOWER_F then return true end
  if c >= B_UPPER_A and c <= B_UPPER_F then return true end
  return false
end

--: (string, integer) -> boolean
local function is_digit(s, i)
  local b = string.byte(s, i) --: integer | nil
  if b == nil then return false end
  if b < B_0 then return false end
  if b > B_9 then return false end
  return true
end

-- Decide whether `{` at position `start` opens a valid quantifier:
-- {n}, {n,}, {n,m}. If it does, return end_pos (the `}`), n, m.
-- If m has no upper bound ({n,}), m = -1.
-- If not a valid quantifier brace, return nil.
-- Returns end_pos, n, m on success (n present; m == -1 for {n,}).
-- Returns nil, nil, nil on failure.
--: (string, integer) -> (integer | nil, integer | nil, integer | nil)
local function scan_quant_brace(pattern, start)
  local len = #pattern
  local i = start + 1 -- skip '{'
  if not is_digit(pattern, i) then return nil end
  local n_start = i
  while is_digit(pattern, i) do i = i + 1 end
  local n_str = string.sub(pattern, n_start, i - 1) --: string
  local n_raw = tonumber(n_str)
  if not n_raw then return nil end
  local n = math.floor(n_raw)
  if i > len then return nil end
  local b = string.byte(pattern, i) --: integer | nil
  if b == B_RBRACE then
    return i, n, n
  end
  if b ~= B_COMMA then return nil end
  i = i + 1
  if i > len then return nil end
  b = string.byte(pattern, i)
  if b == B_RBRACE then
    return i, n, -1 -- {n,}
  end
  if not is_digit(pattern, i) then return nil end
  local m_start = i
  while is_digit(pattern, i) do i = i + 1 end
  if i > len then return nil end
  local m_str = string.sub(pattern, m_start, i - 1) --: string
  local m_raw = tonumber(m_str)
  if not m_raw then return nil end
  local m = math.floor(m_raw)
  if string.byte(pattern, i) ~= B_RBRACE then return nil end
  return i, n, m
end

-- forward declarations
local parse_alternation
local parse_sequence
local parse_atom
local parse_group
local parse_character_class
local parse_escape

-- Parse an escape sequence starting at the backslash. Advances state.pos
-- past the entire escape. Returns Node (with is_anchor for \b / \B).
-- Recognizes JS-style escapes: shorthand classes, special chars,
-- backreferences (\1..\9), named backref (\k<name>), \xHH, \uHHHH,
-- \cX (control), and treats any single-char escape as a literal.
--: (Parser) -> (Node | nil, string | nil)
parse_escape = function(state)
  local pattern = state.pattern
  local len = state.len
  local pos = state.pos
  if pos > len then
    return nil, "trailing backslash with nothing after it"
  end
  local b = string.byte(pattern, pos) --: integer | nil
  if b == nil then
    -- shouldn't happen given pos <= len, but narrows the type
    return nil, "internal: unexpected end of pattern"
  end

  -- \b and \B are word-boundary anchors (zero-width)
  if b == B_LOWER_B or b == B_UPPER_B then
    state.pos = pos + 1
    return { has_unbounded = false, is_anchor = true }
  end

  -- backreferences \1..\9 -- numeric
  if b >= B_0 and b <= B_9 then
    -- consume run of digits
    while pos <= len and is_digit(pattern, pos) do pos = pos + 1 end
    state.pos = pos
    return { has_unbounded = false, is_anchor = false }
  end

  -- named backref \k<name>
  if b == B_K and string.byte(pattern, pos + 1) == B_LT then
    local i = pos + 2
    while i <= len and string.byte(pattern, i) ~= B_GT do i = i + 1 end
    if i > len then
      return nil, "unterminated named backreference \\k<...>"
    end
    state.pos = i + 1
    return { has_unbounded = false, is_anchor = false }
  end

  -- everything else: a single-char escape (\d, \w, \., \\, \xHH, etc.)
  -- We don't enforce JS escape vocabulary; for safety analysis what
  -- matters is that one atom is consumed.
  -- For \x and \u we still only need to advance one char -- the trailing
  -- hex digits are themselves just literals from the validator's view,
  -- but consuming them avoids treating them as separate atoms which
  -- would mis-attribute quantifier scope. So consume them.
  if b == B_LOWER_X then
    state.pos = pos + 1
    -- consume up to 2 hex digits
    for _ = 1, 2 do
      local c = string.byte(pattern, state.pos) --: integer | nil
      if not is_hex_byte(c) then break end
      state.pos = state.pos + 1
    end
    return { has_unbounded = false, is_anchor = false }
  end
  if b == B_LOWER_U then
    state.pos = pos + 1
    -- JS: \uHHHH or \u{HHHH..}
    if string.byte(pattern, state.pos) == B_LBRACE then
      state.pos = state.pos + 1
      while state.pos <= len and string.byte(pattern, state.pos) ~= B_RBRACE do
        state.pos = state.pos + 1
      end
      if state.pos > len then
        return nil, "unterminated \\u{...} escape"
      end
      state.pos = state.pos + 1 -- consume '}'
    else
      for _ = 1, 4 do
        local c = string.byte(pattern, state.pos) --: integer | nil
        if not is_hex_byte(c) then break end
        state.pos = state.pos + 1
      end
    end
    return { has_unbounded = false, is_anchor = false }
  end

  -- generic single-char escape
  state.pos = pos + 1
  return { has_unbounded = false, is_anchor = false }
end

-- Parse [...] character class. Position is on '['. Advances past ']'.
--: (Parser) -> (Node | nil, string | nil)
parse_character_class = function(state)
  local pattern = state.pattern
  local len = state.len
  state.pos = state.pos + 1 -- consume '['
  -- optional negation
  if string.byte(pattern, state.pos) == B_CARET then
    state.pos = state.pos + 1
  end
  -- ']' as first char is a literal
  if string.byte(pattern, state.pos) == B_RBRACKET then
    state.pos = state.pos + 1
  end
  while state.pos <= len do
    local b = string.byte(pattern, state.pos) --: integer | nil
    if b == B_RBRACKET then
      state.pos = state.pos + 1
      return { has_unbounded = false, is_anchor = false }
    end
    if b == B_BACKSLASH then
      state.pos = state.pos + 1
      if state.pos > len then
        return nil, "trailing backslash inside character class"
      end
      -- consume the escaped char (or \xHH, \uHHHH) -- single advance is
      -- structurally sufficient here; classes don't host quantifiers.
      state.pos = state.pos + 1
    else
      state.pos = state.pos + 1
    end
  end
  return nil, "unterminated character class -- missing ']'"
end

-- Parse a group starting at '('. Advances past matching ')'.
-- Handles: (...), (?:...), (?<name>...), (?=...), (?!...),
-- (?<=...), (?<!...).
--: (Parser) -> (Node | nil, string | nil)
parse_group = function(state)
  local pattern = state.pattern
  local len = state.len
  state.pos = state.pos + 1 -- consume '('
  if state.pos > len then
    return nil, "unterminated group -- missing ')'"
  end
  -- Detect (?...) variants and skip the prefix
  if string.byte(pattern, state.pos) == B_QUESTION then
    state.pos = state.pos + 1
    if state.pos > len then
      return nil, "unterminated group -- missing ')'"
    end
    local b = string.byte(pattern, state.pos) --: integer | nil
    if b == B_COLON or b == B_EQUALS or b == B_BANG then
      -- (?:...), (?=...), (?!...)
      state.pos = state.pos + 1
    elseif b == B_LT then
      state.pos = state.pos + 1
      if state.pos > len then
        return nil, "unterminated group -- missing ')'"
      end
      local b2 = string.byte(pattern, state.pos) --: integer | nil
      if b2 == B_EQUALS or b2 == B_BANG then
        -- (?<=...), (?<!...)
        state.pos = state.pos + 1
      else
        -- (?<name>...)
        while state.pos <= len and string.byte(pattern, state.pos) ~= B_GT do
          state.pos = state.pos + 1
        end
        if state.pos > len then
          return nil, "unterminated named group -- missing '>'"
        end
        state.pos = state.pos + 1 -- consume '>'
      end
    else
      return nil, "unknown group type '(?" .. string.char(b) .. "...)'"
    end
  end
  local inner, err = parse_alternation(state)
  if not inner then return nil, err end
  if state.pos > len or string.byte(pattern, state.pos) ~= B_RPAREN then
    return nil, "unterminated group -- missing ')'"
  end
  state.pos = state.pos + 1 -- consume ')'
  return { has_unbounded = inner.has_unbounded, is_anchor = false }
end

-- Parse one atom -- the operand of a (possible) quantifier.
-- Returns nil with no error to signal "no atom here" (end of input
-- or a sequence delimiter); returns nil with an error for malformed.
--: (Parser) -> (Node | nil, string | nil)
parse_atom = function(state)
  if state.pos > state.len then return nil end
  local pattern = state.pattern
  local b = string.byte(pattern, state.pos) --: integer | nil

  if b == B_PIPE or b == B_RPAREN then
    return nil
  end

  if b == B_BACKSLASH then
    state.pos = state.pos + 1
    return parse_escape(state)
  end
  if b == B_LBRACKET then
    return parse_character_class(state)
  end
  if b == B_LPAREN then
    return parse_group(state)
  end
  if b == B_DOT then
    state.pos = state.pos + 1
    return { has_unbounded = false, is_anchor = false }
  end
  if b == B_CARET or b == B_DOLLAR then
    state.pos = state.pos + 1
    return { has_unbounded = false, is_anchor = true }
  end

  -- Quantifier without an atom in front of it: malformed.
  -- For '{', defer to scan_quant_brace; if it isn't a real quantifier,
  -- the '{' is a literal.
  if b == B_STAR or b == B_PLUS or b == B_QUESTION then
    return nil, "quantifier '" .. string.char(b) .. "' without preceding element"
  end
  if b == B_LBRACE then
    local end_pos = scan_quant_brace(pattern, state.pos)
    if end_pos then
      return nil, "quantifier '{...}' without preceding element"
    end
    -- literal '{'
    state.pos = state.pos + 1
    return { has_unbounded = false, is_anchor = false }
  end
  if b == B_RBRACE then
    -- bare '}' is treated as literal in JS
    state.pos = state.pos + 1
    return { has_unbounded = false, is_anchor = false }
  end
  if b == B_RBRACKET then
    -- bare ']' is treated as literal in JS
    state.pos = state.pos + 1
    return { has_unbounded = false, is_anchor = false }
  end

  -- ordinary literal char
  state.pos = state.pos + 1
  return { has_unbounded = false, is_anchor = false }
end

-- Parse atom followed by optional quantifier; returns the resulting
-- node. Enforces the nesting invariant on quantifier composition.
--: (Parser) -> (Node | nil, string | nil)
local function parse_quantified(state)
  local atom, err = parse_atom(state)
  if not atom then return nil, err end
  if state.pos > state.len then return atom end
  local pattern = state.pattern
  local b = string.byte(pattern, state.pos) --: integer | nil

  local quant_str = "" --: string
  local is_unbounded = false --: boolean
  local end_pos = nil --: integer | nil

  if b == B_STAR then
    quant_str = "*"; is_unbounded = true
  elseif b == B_PLUS then
    quant_str = "+"; is_unbounded = true
  elseif b == B_QUESTION then
    quant_str = "?"; is_unbounded = false
  elseif b == B_LBRACE then
    local ep, n, m = scan_quant_brace(pattern, state.pos)
    if not ep or not n or not m then return atom end
    end_pos = ep
    quant_str = string.sub(pattern, state.pos, ep)
    -- m == -1 means {n,} -- unbounded
    -- m > n means {n,m} with a range -- treat as unbounded
    -- m == n means {n} or {n,n} -- bounded
    if m == -1 then
      is_unbounded = true
    else
      is_unbounded = m > n
    end
  else
    return atom
  end

  -- A quantifier on an anchor is never valid (anchors are zero-width).
  if atom.is_anchor then
    return nil, "quantifier '" .. quant_str ..
      "' applied to a zero-width anchor (^ $ \\b \\B)"
  end

  -- Enforce the nesting invariant.
  -- If the operand subtree already contains an unbounded quantifier,
  -- composing ANY further quantifier on top of it is the catastrophic
  -- backtracking shape. Reject regardless of whether the new
  -- quantifier itself is bounded or not -- the inner unbounded loop
  -- is what supplies the exponential alternative count.
  if atom.has_unbounded then
    return nil, "nested quantifier '" .. quant_str ..
      "' on a subexpression that already contains an unbounded " ..
      "quantifier -- this can cause catastrophic backtracking"
  end

  -- consume the quantifier
  if end_pos then
    state.pos = end_pos + 1
  else
    state.pos = state.pos + 1
  end
  -- optional lazy / possessive modifier
  if state.pos <= state.len then
    local nb = string.byte(pattern, state.pos) --: integer | nil
    if nb == B_QUESTION or nb == B_PLUS then
      state.pos = state.pos + 1
    end
  end

  -- This composed node has an unbounded quantifier IFF the outer one
  -- itself was unbounded (the operand has none, by the check above).
  return { has_unbounded = is_unbounded, is_anchor = false }
end

-- Parse a sequence of atoms (with quantifiers) until '|' or ')' or EOF.
--: (Parser) -> (Node | nil, string | nil)
parse_sequence = function(state)
  local has_unbounded = false
  while state.pos <= state.len do
    local b = string.byte(state.pattern, state.pos) --: integer | nil
    if b == B_PIPE or b == B_RPAREN then break end
    local node, err = parse_quantified(state)
    if not node then
      if err then return nil, err end
      break
    end
    if node.has_unbounded then has_unbounded = true end
  end
  return { has_unbounded = has_unbounded, is_anchor = false }
end

-- Parse alternation: seq ('|' seq)*
--: (Parser) -> (Node | nil, string | nil)
parse_alternation = function(state)
  local node, err = parse_sequence(state)
  if not node then return nil, err end
  while state.pos <= state.len and string.byte(state.pattern, state.pos) == B_PIPE do
    state.pos = state.pos + 1
    local right
    right, err = parse_sequence(state)
    if not right then return nil, err end
    if right.has_unbounded then
      node = { has_unbounded = true, is_anchor = false }
    end
  end
  return node
end

--: (string) -> (boolean, string | nil)
M.validate_pattern = function(pattern)
  if type(pattern) ~= "string" then
    return false, "pattern must be a string"
  end
  local state = { pattern = pattern, pos = 1, len = #pattern }
  local node, err = parse_alternation(state)
  if not node then
    return false, "malformed pattern: " .. (err or "unknown error")
  end
  if state.pos <= state.len then
    local b = string.byte(pattern, state.pos) --: integer | nil
    if b == B_RPAREN then
      return false, "malformed pattern: unexpected ')' without matching '('"
    end
    return false,
      "malformed pattern: unexpected character '" .. string.char(b) ..
      "' at position " .. state.pos
  end
  return true, nil
end

return M
