if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/tokenizer: declarative lexer/tokenizer builder for LuaJIT.
--
-- Usage:
--   local tok = require("lib.tokenizer")
--   local lexer = tok.new()
--     :skip("%s+")
--     :token("NUMBER", "%d+%.?%d*")
--     :token("IDENT",  "[%a_][%w_]*")
--     :keyword("if", "then", "else")
--   local tokens, err = lexer:tokenize("if x then 1 end")
--
-- Rule priority: rules are tried in declaration order.
-- Keywords: matched as IDENT first, then reclassified.
-- Modes: lexer:in_mode("name", sublexer) switches rules based on state.
-- Error convention: (nil, {message, line, col}) on unrecognized input.

local M = {}
M._tier = "pure"

--:: TokState = { _stack: { [integer]: string }, push: (TokState, string) -> nil, pop: (TokState) -> nil, current: (TokState) -> string | nil, ... }
--:: TokRule = { kind: string, type: string | nil, pat: string, transform: ((string, TokState) -> string) | nil }
--:: TokLexer = { _rules: { [integer]: TokRule }, _keywords: { [string]: boolean }, _modes: { [string]: TokLexer }, ... }

-- ---------------------------------------------------------------------------
-- State object (passed to transform functions in mode lexers)
-- ---------------------------------------------------------------------------

local State = {}
State.__index = State

local function new_state()
  local st = setmetatable({ _stack = {} }, State) --[[: any]]
  return st --[[:! TokState]]
end

function State:push(mode)
  local self_ = self --[[:! TokState]]
  self_._stack[#self_._stack + 1] = mode
end

function State:pop()
  local self_ = self --[[:! TokState]]
  self_._stack[#self_._stack] = nil
end

function State:current()
  local self_ = self --[[:! TokState]]
  return self_._stack[#self_._stack]
end

-- ---------------------------------------------------------------------------
-- Lexer builder
-- ---------------------------------------------------------------------------

local Lexer = {}
Lexer.__index = Lexer

-- Create a new lexer builder.
--: () -> TokLexer
function M.new()
  --: { [integer]: TokRule }
  local rules = {}
  --: { [string]: boolean }
  local keywords = {}
  --: { [string]: TokLexer }
  local modes = {}
  local lx = setmetatable({ _rules = rules, _keywords = keywords, _modes = modes }, Lexer) --[[: any]]
  return lx --[[:! TokLexer]]
end

-- Add a token rule. transform(value, state?) may return a modified value.
function Lexer:token(ttype, pattern, transform)
  self._rules[#self._rules + 1] = {
    kind      = "token",
    type      = ttype,
    pat       = pattern,
    transform = transform,
  }
  return self
end

-- Add a skip rule (whitespace, comments, etc.).
function Lexer:skip(pattern)
  self._rules[#self._rules + 1] = {
    kind = "skip",
    pat  = pattern,
  }
  return self
end

-- Register keywords. Any IDENT token whose value appears here is reclassified.
function Lexer:keyword(...)
  for i = 1, select("#", ...) do
    self._keywords[select(i, ...)] = true
  end
  return self
end

-- Associate a sublexer with a named mode.
function Lexer:in_mode(name, sublexer)
  self._modes[name] = sublexer
  return self
end

-- ---------------------------------------------------------------------------
-- Core scan step: try all rules of a lexer at position pos.
-- Returns kind, ttype, matched_string, transform | nil on no match.
-- ---------------------------------------------------------------------------

--: ({ [integer]: TokRule }, string, integer) -> (string | nil, string | nil, string | nil, ((string, TokState) -> string) | nil)
local function try_rules(rules, input, pos)
  for _, rule in ipairs(rules) do
    -- Anchor to current position using %f[] or plain sub+match.
    -- We use string.find with init=pos and anchored '^' at the front.
    local anchored = "^(?:" .. rule.pat .. ")"
    -- Lua patterns don't have (?:...) — use plain anchor by slicing.
    -- Build an anchored pattern: prepend "^" then match from pos.
    local start, finish = input:find("^" .. rule.pat, pos)
    if start then
      return rule.kind, rule.type, input:sub(start, finish), rule.transform
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Tokenize a full input string.
-- Returns: array of token tables, or nil + error table.
-- ---------------------------------------------------------------------------

function Lexer:tokenize(input)
  local self_ = self --[[:! TokLexer]]
  local tokens = {}
  local state  = new_state()
  local pos    = 1
  local line   = 1
  local col    = 1
  local len    = #input

  while pos <= len do
    -- Determine which lexer to use based on current mode.
    local mode      = state:current()
    local active    = (mode and self_._modes[mode]) or self_
    local rules     = active._rules
    local keywords  = active._keywords

    local kind, ttype, matched, transform = try_rules(rules, input, pos)

    if not kind then
      -- Unrecognized character — report error.
      local ch = input:sub(pos, pos)
      return nil, {
        message = "unexpected character '" .. ch .. "'",
        line    = line,
        col     = col,
      }
    end

    local matched_ = matched --[[:! string]]
    local value = matched_

    if kind == "token" then
      if transform then
        value = transform(value --[[:! string]], state)
      end
      -- Reclassify IDENT as keyword if applicable.
      local effective_type = ttype
      if ttype == "IDENT" and self_._keywords[matched] then
        effective_type = matched
      end
      -- Also reclassify from sublexer's keywords.
      if mode and self_._modes[mode] then
        local sub = self_._modes[mode]
        if ttype == "IDENT" and sub._keywords[matched] then
          effective_type = matched
        end
      end
      tokens[#tokens + 1] = {
        type  = effective_type,
        value = value,
        line  = line,
        col   = col,
      }
    end
    -- For "skip" rules, no token is emitted.

    -- Advance position and update line/col.
    local advance = #matched_
    for i = pos, pos + advance - 1 do
      if input:sub(i, i) == "\n" then
        line = line + 1
        col  = 1
      else
        col = col + 1
      end
    end
    pos = pos + advance
  end

  return tokens, nil
end

-- ---------------------------------------------------------------------------
-- Iterator form: yields token tables lazily.
-- ---------------------------------------------------------------------------

function Lexer:iter(input)
  local tokens, err = self:tokenize(input)
  if not tokens then
    -- Return a single-shot iterator that yields nothing (error case).
    -- Callers who care about errors should use :tokenize().
    return function() return nil end
  end
  local i = 0
  return function()
    i = i + 1
    return tokens[i]
  end
end

return M
