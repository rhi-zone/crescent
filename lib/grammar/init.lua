if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- PEG (Parsing Expression Grammar) parser combinators.
--
-- Each parser is a table with:
--   _id    unique integer (used as packrat cache key)
--   _parse(input, pos, cache) -> (captures, new_pos) | (nil, err_pos)
--   _sub   (optional) single child parser — exposed for grammar ref-walking
--   _subs  (optional) list of child parsers — exposed for grammar ref-walking
--
-- Public API: parser:parse_at(input, pos), parser:match(input), parser:parse(input, pos)
-- Grammar:    G.grammar(opts), G.ref(name)
-- Packrat:    per-parse cache table, keyed by (parser_id, pos)

local M = {}
M._tier = "pure"

-- ── Parser ID counter ────────────────────────────────────────────────────────

local _next_id = 0
local function new_id()
  _next_id = _next_id + 1
  return _next_id
end

-- ── Empty captures sentinel ──────────────────────────────────────────────────

local EMPTY = {}  -- shared empty captures (treat as read-only)

-- ── Captures helpers ─────────────────────────────────────────────────────────

-- Merge a list of captures tables into one result table.
-- Named fields are merged by key; array entries accumulate.
--: (unknown) -> {}
local function merge_all(list)
  --: { [integer]: unknown, [string]: unknown, ... } | nil
  local r = nil
  for _, c in ipairs(list) do
    if c ~= EMPTY then
      if not r then
        --: { [integer]: unknown, [string]: unknown, ... }
        r = {}
      end
      for k, v in pairs(c) do
        if type(k) == "number" then
          r[#r + 1] = v
        else
          r[k] = v
        end
      end
    end
  end
  return r or EMPTY
end

-- ── Packrat cache ─────────────────────────────────────────────────────────────

-- Cache key: parser_id << 24 | pos  (works for inputs up to ~16M chars)
-- We use a plain table; miss = nil, in-progress = false, result = {caps, new_pos}.

local SHIFT = 2^24  -- pos fits in 24 bits for typical inputs

-- `_parse: any` opts out of checking _parse's function signature here; the actual parse
-- functions have heterogeneous input types (string methods vs integer bytes) that require
-- the individual call sites to be typed rather than through a shared parser-function type.
--: ({ _id: integer, _parse: any, ... }, unknown, integer, { [number]: unknown, ... } | nil) -> ({} | nil, integer)
local function cached_parse(p, input, pos, cache)
  if not cache then
    return p._parse(input, pos, nil)
  end
  local key = (p._id --[[:! integer]]) * SHIFT + pos
  local entry = cache[key]
  if entry ~= nil then
    if entry == false then
      -- In-progress (left-recursion guard) — treat as failure.
      return nil, pos
    end
    return entry[1] --[[:! {} | nil]], entry[2] --[[:! integer]]
  end
  -- Mark in-progress.
  cache[key] = false
  local caps, new_pos = p._parse(input, pos, cache)
  cache[key] = { caps, new_pos }
  return caps, new_pos
end

-- ── Parser constructor ────────────────────────────────────────────────────────

local function make_parser(parse_fn)
  local p = { _id = new_id(), _parse = parse_fn }

  function p:parse_at(input, pos)
    return self._parse(input, pos, nil)
  end

  function p:parse(input, pos)
    pos = pos or 1
    return self._parse(input, pos, nil)
  end

  function p:match(input)
    local caps, new_pos = self._parse(input, 1, nil)
    if caps then
      return true, input:sub(1, new_pos - 1), input:sub(new_pos)
    end
    return false, new_pos
  end

  return p
end

-- ── Primitives ────────────────────────────────────────────────────────────────

--- Match a literal string.
function M.lit(s)
  local n = #s
  return make_parser(function(input, pos, _cache)
    if input:sub(pos, pos + n - 1) == s then
      return EMPTY, pos + n
    end
    return nil, pos
  end)
end

--- Match any single character (fails at EOF).
M.any = make_parser(function(input, pos, _cache)
  if pos <= #input then
    return EMPTY, pos + 1
  end
  return nil, pos
end)

--- Match end of input.
M.eof = make_parser(function(input, pos, _cache)
  if pos > #input then
    return EMPTY, pos
  end
  return nil, pos
end)

--- Match a character in byte range [lo, hi].
function M.range(lo, hi)
  local lo_b = lo:byte(1)
  local hi_b = hi:byte(1)
  return make_parser(function(input, pos, _cache)
    local b = input:byte(pos)
    if b and b >= lo_b and b <= hi_b then
      return EMPTY, pos + 1
    end
    return nil, pos
  end)
end

--- Match any character in the set string.
function M.set(chars)
  local lut = {}
  for i = 1, #chars do lut[chars:byte(i)] = true end
  return make_parser(function(input, pos, _cache)
    local b = input:byte(pos)
    if b and lut[b] then
      return EMPTY, pos + 1
    end
    return nil, pos
  end)
end

--- Match any character NOT in the set string (also fails at EOF).
function M.not_set(chars)
  local lut = {}
  for i = 1, #chars do lut[chars:byte(i)] = true end
  return make_parser(function(input, pos, _cache)
    local b = input:byte(pos)
    if b and not lut[b] then
      return EMPTY, pos + 1
    end
    return nil, pos
  end)
end

-- ── Combinators ───────────────────────────────────────────────────────────────

--- Sequence: all parsers must match in order. Combines captures.
function M.seq(...)
  local parsers = { ... }
  local p = make_parser(function(input, pos, cache)
    local caps_list = {}
    local cur = pos
    for i = 1, #parsers do
      local caps, new_pos = cached_parse(parsers[i] --[[:! { _parse: any, _id: integer, ... }]], input, cur, cache)
      if not caps then
        return nil, new_pos
      end
      caps_list[#caps_list + 1] = caps
      cur = new_pos
    end
    return merge_all(caps_list), cur
  end)
  p._subs = parsers
  return p
end

--- Ordered choice: try each parser; return captures of the first match.
function M.alt(...)
  local parsers = { ... }
  local p = make_parser(function(input, pos, cache)
    local furthest = pos
    for i = 1, #parsers do
      local caps, new_pos = cached_parse(parsers[i] --[[:! { _parse: any, _id: integer, ... }]], input, pos, cache)
      if caps then
        return caps, new_pos
      end
      if new_pos > furthest then furthest = new_pos end
    end
    return nil, furthest
  end)
  p._subs = parsers
  return p
end

--- Optional: match 0 or 1 times (always succeeds).
function M.opt(inner)
  local p = make_parser(function(input, pos, cache)
    local caps, new_pos = cached_parse(inner, input, pos, cache)
    if caps then
      return caps, new_pos
    end
    return EMPTY, pos
  end)
  p._sub = inner
  return p
end

--- Zero or more (greedy). Collects captures into an array per iteration.
function M.star(inner)
  local p = make_parser(function(input, pos, cache)
    local all = {}
    local cur = pos
    while true do
      local caps, new_pos = cached_parse(inner, input, cur, cache)
      if not caps or new_pos == cur then break end
      all[#all + 1] = caps
      cur = new_pos
    end
    if #all == 0 then return EMPTY, cur end
    local r = {}
    for _, c in ipairs(all) do
      if c ~= EMPTY then r[#r + 1] = c end
    end
    if #r == 0 then return EMPTY, cur end
    return r, cur
  end)
  p._sub = inner
  return p
end

--- One or more (greedy). Fails if zero matches.
function M.plus(inner)
  local p = make_parser(function(input, pos, cache)
    local caps, new_pos = cached_parse(inner, input, pos, cache)
    if not caps then return nil, new_pos end
    local all = { caps }
    local cur = new_pos
    while true do
      caps, new_pos = cached_parse(inner, input, cur, cache)
      if not caps or new_pos == cur then break end
      all[#all + 1] = caps
      cur = new_pos
    end
    if #all == 1 then
      return all[1] --[[:! {}]], cur
    end
    local r = {}
    for _, c in ipairs(all) do
      if c ~= EMPTY then r[#r + 1] = c end
    end
    if #r == 0 then return EMPTY, cur end
    return r, cur
  end)
  p._sub = inner
  return p
end

--- Exactly n times.
function M.times(inner, n)
  local p = make_parser(function(input, pos, cache)
    local caps_list = {}
    local cur = pos
    for _ = 1, n do
      local caps, new_pos = cached_parse(inner, input, cur, cache)
      if not caps then return nil, new_pos end
      caps_list[#caps_list + 1] = caps
      cur = new_pos
    end
    local r = {}
    for _, c in ipairs(caps_list) do
      if c ~= EMPTY then r[#r + 1] = c end
    end
    if #r == 0 then return EMPTY, cur end
    return r, cur
  end)
  p._sub = inner
  return p
end

--- Between min and max times (inclusive). Greedy.
function M.between(inner, min, max)
  local p = make_parser(function(input, pos, cache)
    local caps_list = {}
    local cur = pos
    local count = 0
    while count < max do
      local caps, new_pos = cached_parse(inner, input, cur, cache)
      if not caps or new_pos == cur then break end
      caps_list[#caps_list + 1] = caps
      cur = new_pos
      count = count + 1
    end
    if count < min then return nil, cur end
    local r = {}
    for _, c in ipairs(caps_list) do
      if c ~= EMPTY then r[#r + 1] = c end
    end
    if #r == 0 then return EMPTY, cur end
    return r, cur
  end)
  p._sub = inner
  return p
end

--- Negative lookahead: succeeds without consuming if p does NOT match.
function M.not_(inner)
  local p = make_parser(function(input, pos, cache)
    local caps, _ = cached_parse(inner, input, pos, cache)
    if caps then return nil, pos end
    return EMPTY, pos
  end)
  p._sub = inner
  return p
end

--- Positive lookahead: succeeds without consuming if p matches.
function M.and_(inner)
  local p = make_parser(function(input, pos, cache)
    local caps, _ = cached_parse(inner, input, pos, cache)
    if caps then return EMPTY, pos end
    return nil, pos
  end)
  p._sub = inner
  return p
end

--- Capture: captures matched substring as named field.
-- Returns {[name] = matched_string} merged with any sub-captures.
function M.capture(inner, name)
  local p = make_parser(function(input, pos, cache)
    local caps, new_pos = cached_parse(inner, input, pos, cache)
    if not caps then return nil, new_pos end
    local result = { [name] = input:sub(pos, new_pos - 1) }
    if caps ~= EMPTY then
      for k, v in pairs(caps) do
        if type(k) ~= "number" then
          result[k] = v
        end
      end
    end
    return result, new_pos
  end)
  p._sub = inner
  return p
end

-- ── Forward reference ─────────────────────────────────────────────────────────

--- Lazy forward reference by name; resolved by grammar().
function M.ref(name)
  local proxy = { _id = new_id(), _is_ref = true, _name = name, _target = nil }

  proxy._parse = function(input, pos, cache)
    if not proxy._target then
      error("unresolved grammar ref: " .. name)
    end
    return cached_parse(proxy._target, input, pos, cache)
  end

  function proxy:parse_at(input, pos)
    return proxy._parse(input, pos, nil)
  end

  function proxy:parse(input, pos)
    pos = pos or 1
    return proxy._parse(input, pos, nil)
  end

  function proxy:match(input)
    local caps, new_pos = proxy._parse(input, 1, nil)
    if caps then
      return true, input:sub(1, new_pos - 1), input:sub(new_pos)
    end
    return false, new_pos
  end

  return proxy
end

-- ── Grammar ───────────────────────────────────────────────────────────────────

--- Build a grammar from a table of named rules with packrat memoization.
-- opts.start  = entry-point rule name (string)
-- opts.<name> = parser (rule definition)
function M.grammar(opts)
  local start_name = opts.start
  if not start_name then
    error("grammar: 'start' rule name required")
  end

  -- Collect rules.
  local rules = {}
  for k, v in pairs(opts) do
    if k ~= "start" then rules[k] = v end
  end

  -- Walk all parsers reachable from each rule and resolve refs.
  local function walk_and_resolve(root)
    local worklist = { root }
    local seen = {}
    while #worklist > 0 do
      local p = table.remove(worklist)
      if not p or type(p) ~= "table" or seen[p] then goto continue end
      seen[p] = true
      if p._is_ref then
        if not rules[p._name] then
          error("grammar: unknown rule '" .. p._name .. "'")
        end
        p._target = rules[p._name]
        worklist[#worklist + 1] = p._target
        goto continue
      end
      if p._sub then worklist[#worklist + 1] = p._sub end
      if p._subs then
        for _, s in ipairs(p._subs) do
          worklist[#worklist + 1] = s
        end
      end
      ::continue::
    end
  end

  for _, rule_parser in pairs(rules) do
    walk_and_resolve(rule_parser)
  end

  local start_parser = rules[start_name]
  if not start_parser then
    error("grammar: start rule '" .. start_name .. "' not defined")
  end

  local g = { _rules = rules }

  function g:parse(input, pos)
    pos = pos or 1
    local cache = {} --[[:! { [number]: unknown, ... } | nil]]
    return cached_parse(start_parser --[[:! { _parse: any, _id: integer, ... }]], input, pos, cache)
  end

  function g:parse_at(input, pos)
    return self:parse(input, pos)
  end

  function g:match(input)
    local caps, new_pos = self:parse(input, 1)
    if caps then
      return true, input:sub(1, new_pos - 1), input:sub(new_pos)
    end
    return false, new_pos
  end

  return g
end

return M
