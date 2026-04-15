if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Markov chain text generation library.
-- Supports variable-order chains (bigram, trigram, etc.) with start/end
-- sentinels, weighted random sampling, and save/load serialization.

local M = {}
M._tier = "pure"

local START = "<START>"
local END   = "<END>"

M.START = START
M.END   = END

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Tokenize a string on whitespace, returning an array of tokens.
--: (string) -> { [integer]: string }
local function tokenize(text)
  local tokens = {}
  for tok in text:gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end
  return tokens
end

-- Build an n-gram key string from a table slice tokens[i..i+order-1].
--: ({ [integer]: string }, integer, integer) -> string
local function key_from(tokens, i, order)
  local parts = {}
  for j = 0, order - 1 do
    parts[j + 1] = tokens[i + j]
  end
  return table.concat(parts, "\0")
end

-- Weighted random pick from a transitions map { token -> count }.
-- Returns chosen token and its probability.
--: ({ [string]: integer }, () -> number) -> string, number
local function weighted_pick(trans, rand)
  local total = 0
  for _, count in pairs(trans) do
    total = total + count
  end
  if total == 0 then return nil, 0 end
  local r = rand() * total
  local cum = 0
  -- deterministic iteration order: sort keys
  local keys = {}
  for k in pairs(trans) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    cum = cum + trans[k]
    if r < cum then
      return k, trans[k] / total
    end
  end
  -- fallback (floating point edge)
  local last = keys[#keys]
  return last, trans[last] / total
end

-- ---------------------------------------------------------------------------
-- Chain object
-- ---------------------------------------------------------------------------

local Chain = {}
Chain.__index = Chain

-- Train the chain from a sequence of tokens (already split).
--: ({ [integer]: string }) -> nil
function Chain:_train_tokens(tokens)
  local order = self._order
  -- Prepend `order` START sentinels and one END sentinel.
  local seq = {}
  for _ = 1, order do seq[#seq + 1] = START end
  for _, t in ipairs(tokens) do seq[#seq + 1] = t end
  seq[#seq + 1] = END

  -- Walk the sequence building n-gram counts.
  for i = 1, #seq - order do
    local ctx_key = key_from(seq, i, order)
    local next_tok = seq[i + order]
    local ctx = self._table[ctx_key]
    if not ctx then
      ctx = {}
      self._table[ctx_key] = ctx
    end
    ctx[next_tok] = (ctx[next_tok] or 0) + 1
  end
end

-- Train from a string (splits on whitespace) or an array of tokens.
--: (string | { [integer]: string }) -> nil
function Chain:train(input)
  local tokens
  if type(input) == "string" then
    tokens = tokenize(input)
  else
    tokens = input
  end
  self:_train_tokens(tokens)
end

-- Return the raw transitions map { token -> count } for a context.
-- context may be a string key (pre-joined) or an array of tokens.
--: (string | { [integer]: string }) -> { [string]: integer }
function Chain:transitions(context)
  local key
  if type(context) == "string" then
    -- single-token context convenience: just use as-is for order-1
    key = context
  else
    key = table.concat(context, "\0")
  end
  local t = self._table[key]
  if not t then return {} end
  -- return a shallow copy so callers can't mutate internal state
  local copy = {}
  for k, v in pairs(t) do copy[k] = v end
  return copy
end

-- Predict the next token given a context array (length == order).
-- Returns next_token, probability, or nil, 0 if unknown context.
--: ({ [integer]: string }) -> string | nil, number
function Chain:next(context)
  local key
  if type(context) == "string" then
    key = context
  else
    key = table.concat(context, "\0")
  end
  local trans = self._table[key]
  if not trans then return nil, 0 end
  return weighted_pick(trans, self._rand)
end

-- Generate a string of tokens.
-- opts: { max_tokens, seed_token, separator }
--   max_tokens  (default 100)  — hard cap on output tokens (not counting sentinels)
--   seed_token  (optional)     — force the first real token (must exist in chain)
--   separator   (default " ")  — join separator
--: ({ max_tokens: integer | nil, seed_token: string | nil, separator: string | nil } | nil) -> string
function Chain:generate(opts)
  opts = opts or {}
  local max_tokens = opts.max_tokens or 100
  local separator  = opts.separator or " "
  local seed_token = opts.seed_token

  local order = self._order
  -- Start with `order` START sentinels as context.
  local ctx = {}
  for _ = 1, order do ctx[#ctx + 1] = START end

  local result = {}
  local count  = 0

  -- If a seed token is given, inject it as the first token.
  if seed_token then
    result[#result + 1] = seed_token
    count = count + 1
    -- Advance context.
    table.remove(ctx, 1)
    ctx[#ctx + 1] = seed_token
  end

  while count < max_tokens do
    local key  = table.concat(ctx, "\0")
    local trans = self._table[key]
    if not trans then break end
    local tok = weighted_pick(trans, self._rand)
    if tok == nil or tok == END then break end
    result[#result + 1] = tok
    count = count + 1
    -- Slide the context window.
    table.remove(ctx, 1)
    ctx[#ctx + 1] = tok
  end

  return table.concat(result, separator)
end

-- Serialize the chain to a plain Lua table (snapshot).
--: () -> table
function Chain:save()
  local snapshot = {
    order = self._order,
    seed  = self._seed,
    table = {},
  }
  for ctx_key, trans in pairs(self._table) do
    local t = {}
    for tok, count in pairs(trans) do
      t[#t + 1] = { tok, count }
    end
    snapshot.table[ctx_key] = t
  end
  return snapshot
end

-- ---------------------------------------------------------------------------
-- Module-level constructors
-- ---------------------------------------------------------------------------

-- Create a new empty chain of the given order (default 1).
-- seed is required for deterministic random generation.
--: (integer, integer) -> table
function M.chain(order, seed)
  if not seed then error("markov.chain: seed is required") end
  order = order or 1
  math.randomseed(seed)
  local obj = setmetatable({
    _order = order,
    _table = {},
    _seed  = seed,
    _rand  = math.random,
  }, Chain)
  return obj
end

-- Restore a chain from a snapshot produced by chain:save().
-- seed is required for deterministic random generation.
--: (table, integer) -> table
function M.load(snapshot, seed)
  if not seed then error("markov.load: seed is required") end
  local order = snapshot.order or 1
  math.randomseed(seed)
  local obj = setmetatable({
    _order = order,
    _table = {},
    _seed  = seed,
    _rand  = math.random,
  }, Chain)
  for ctx_key, entries in pairs(snapshot.table) do
    local trans = {}
    for _, pair in ipairs(entries) do
      trans[pair[1]] = pair[2]
    end
    obj._table[ctx_key] = trans
  end
  return obj
end

-- Convenience: build a chain from text, train it, and return it.
-- order defaults to 1. seed is required.
--: (string, integer, integer | nil) -> table
function M.from_text(text, seed, order)
  local c = M.chain(order or 1, seed)
  c:train(text)
  return c
end

return M
