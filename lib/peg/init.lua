if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Internal pattern metatable
local Pat = {}
Pat.__index = Pat

--: ((string, integer) -> integer | nil) -> { match: (string, integer) -> integer | nil, ... }
local function make_pat(fn)
  return setmetatable({ match = fn }, Pat)
end

-- Thread-local state for captures and active grammar rules.
-- These are module-level upvalues, safe for single-threaded LuaJIT use.
local _cap_stack = nil   -- current capture list being populated
local _active_rules = nil  -- current grammar's rule table

-- Primitive: match a literal string
function M.lit(s)
  local len = #s
  return make_pat(function(input, pos)
    if input:sub(pos, pos + len - 1) == s then
      return pos + len
    end
    return nil
  end)
end

-- Primitive: match a character class like "[a-zA-Z0-9_]" or "a-zA-Z0-9_"
-- Supports: ranges (a-z), negation (^), literal chars
function M.cls(spec)
  local inner = spec
  if inner:sub(1, 1) == "[" and inner:sub(-1) == "]" then
    inner = inner:sub(2, -2)
  end

  local negate = false
  local i = 1
  if inner:sub(1, 1) == "^" then
    negate = true
    i = 2
  end

  local chars = {}
  while i <= #inner do
    local c = inner:sub(i, i)
    if i + 2 <= #inner and inner:sub(i + 1, i + 1) == "-" then
      -- range
      local lo = c:byte()
      local hi = inner:sub(i + 2, i + 2):byte()
      for b = lo, hi do
        chars[string.char(b)] = true
      end
      i = i + 3
    else
      chars[c] = true
      i = i + 1
    end
  end

  --: (string, integer) -> integer | nil
  local fn = function(input, pos)
    if pos > #input then return nil end
    local c = input:sub(pos, pos)
    local found = chars[c]
    if negate then
      return (not found) and pos + 1 or nil
    else
      return found and pos + 1 or nil
    end
  end
  return make_pat(fn)
end

-- Primitive: match any single character
do
  --: (string, integer) -> integer | nil
  local fn = function(input, pos)
    if pos <= #input then return pos + 1 end
    return nil
  end
  M.any = make_pat(fn)
end

-- Primitive: match end of input
do
  --: (string, integer) -> integer | nil
  local fn = function(input, pos)
    if pos > #input then return pos end
    return nil
  end
  M.eof = make_pat(fn)
end

-- Primitive: always succeeds, consumes nothing
M.empty = make_pat(function(input, pos)
  return pos
end)

-- Sequence: all patterns must match in order
function M.seq(...)
  local pats = {...}
  return make_pat(function(input, pos)
    local cur = pos
    for _, p in ipairs(pats) do
      local next_pos = p.match(input, cur)
      if next_pos == nil then return nil end
      cur = next_pos
    end
    return cur
  end)
end

-- Ordered choice: try each pattern until one succeeds
function M.choice(...)
  local pats = {...}
  return make_pat(function(input, pos)
    for _, p in ipairs(pats) do
      local next_pos = p.match(input, pos)
      if next_pos ~= nil then return next_pos end
    end
    return nil
  end)
end

-- Zero or more (greedy)
function M.star(p)
  return make_pat(function(input, pos)
    local cur = pos
    while true do
      local next_pos = p.match(input, cur)
      if next_pos == nil or next_pos == cur then break end
      cur = next_pos
    end
    return cur
  end)
end

-- One or more
function M.plus(p)
  return make_pat(function(input, pos)
    local first = p.match(input, pos)
    if first == nil then return nil end
    local cur = first
    while true do
      local next_pos = p.match(input, cur)
      if next_pos == nil or next_pos == cur then break end
      cur = next_pos
    end
    return cur
  end)
end

-- Optional (zero or one)
function M.opt(p)
  return make_pat(function(input, pos)
    local next_pos = p.match(input, pos)
    return next_pos ~= nil and next_pos or pos
  end)
end

-- Negative lookahead: succeed if p fails, consume nothing
function M.neg(p)
  --: (string, integer) -> integer | nil
  local fn = function(input, pos)
    local next_pos = p.match(input, pos)
    return next_pos == nil and pos or nil
  end
  return make_pat(fn)
end

-- Positive lookahead: succeed if p matches, consume nothing
function M.pos(p)
  --: (string, integer) -> integer | nil
  local fn = function(input, pos)
    local next_pos = p.match(input, pos)
    return next_pos ~= nil and pos or nil
  end
  return make_pat(fn)
end

-- Capture: record matched substring into captures
-- Nested cap() calls produce nested capture arrays.
function M.cap(p)
  return make_pat(function(input, pos)
    local start = pos
    local parent = _cap_stack
    local my_caps = {}
    _cap_stack = my_caps

    local next_pos = p.match(input, pos)

    _cap_stack = parent

    if next_pos == nil then return nil end

    local substr = input:sub(start, next_pos - 1)
    local entry
    if #my_caps == 0 then
      entry = substr
    else
      -- nested captures: { full_string, child1, child2, ... }
      entry = { substr, unpack(my_caps) }
    end

    if parent ~= nil then
      parent[#parent + 1] = entry
    end

    return next_pos
  end)
end

-- Reference to a named rule (resolved via active grammar context at match time)
function M.ref(name)
  return make_pat(function(input, pos)
    if _active_rules == nil then
      error("peg.ref: '" .. name .. "' used outside of a grammar context")
    end
    local rule = _active_rules[name]
    if rule == nil then
      error("peg.ref: undefined rule '" .. name .. "'")
    end
    return rule.match(input, pos)
  end)
end

-- Grammar: named rules with a start rule
-- spec: { start = "name", rules = { name = pattern, ... } }
-- Returns a grammar object with :match(input) and :match_all(input)
function M.grammar(spec)
  local start_name = spec.start
  local rules = spec.rules

  local function run_match(input, pos)
    local start_rule = rules[start_name]
    if start_rule == nil then
      return nil, "peg.grammar: no rule named '" .. start_name .. "'"
    end

    local prev_rules = _active_rules
    local prev_caps = _cap_stack
    local root_caps = {}
    _cap_stack = root_caps
    _active_rules = rules

    local end_pos = start_rule.match(input, pos)

    _cap_stack = prev_caps
    _active_rules = prev_rules

    if end_pos == nil then
      return nil, "peg.grammar: match failed at position " .. pos
    end

    return end_pos, root_caps
  end

  local g = {}

  function g:match(input)
    return run_match(input, 1)
  end

  function g:match_all(input)
    local end_pos, caps = run_match(input, 1)
    if end_pos == nil then
      return nil, caps
    end
    if end_pos ~= #input + 1 then
      return nil, "peg.grammar: input not fully consumed (stopped at " .. end_pos .. ")"
    end
    return end_pos, caps
  end

  return g
end

-- Match a single pattern against input (starting at pos 1)
-- Returns (end_pos, captures) or (nil, errmsg)
function M.match(pat, input)
  local prev_caps = _cap_stack
  local root_caps = {}
  _cap_stack = root_caps

  local end_pos = pat.match(input, 1)

  _cap_stack = prev_caps

  if end_pos == nil then
    return nil, "peg.match: pattern did not match"
  end

  return end_pos, root_caps
end

return M
