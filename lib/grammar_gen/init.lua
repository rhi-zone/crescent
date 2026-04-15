-- lib/grammar_gen/init.lua
-- Context-free grammar text generation (Tracery-inspired).
-- Expands #symbol# patterns recursively with modifier support.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- xorshift32 RNG using LuaJIT bit library
local bit = require("bit")
local function make_rng_luajit(seed)
  if not seed then error("grammar_gen: seed is required") end
  local state = seed
  if state == 0 then state = 12345 end
  -- ensure unsigned 32-bit
  state = bit.band(state, 0xFFFFFFFF)
  if state == 0 then state = 1 end
  return {
    next = function(self)
      state = bit.bxor(state, bit.lshift(state, 13))
      state = bit.band(state, 0xFFFFFFFF)
      state = bit.bxor(state, bit.rshift(state, 17))
      state = bit.bxor(state, bit.lshift(state, 5))
      state = bit.band(state, 0xFFFFFFFF)
      -- tobit may give negative; convert to unsigned
      if state < 0 then state = state + 4294967296 end
      if state == 0 then state = 1 end
      return state
    end,
    float = function(self)
      return self:next() / 4294967296.0
    end,
    choice = function(self, n)
      return math.floor(self:float() * n) + 1
    end,
  }
end

-- ──────────────────────── Modifiers ────────────────────────

local VOWELS = { a=true, e=true, i=true, o=true, u=true,
                 A=true, E=true, I=true, O=true, U=true }

local modifiers = {}

function modifiers.capitalize(s)
  if #s == 0 then return s end
  return s:sub(1,1):upper() .. s:sub(2)
end

function modifiers.uppercase(s)
  return s:upper()
end

function modifiers.lowercase(s)
  return s:lower()
end

function modifiers.a(s)
  if #s == 0 then return "a" end
  if VOWELS[s:sub(1,1)] then
    return "an " .. s
  else
    return "a " .. s
  end
end

function modifiers.s(s)
  if #s == 0 then return s end
  local last = s:sub(-1):lower()
  local last2 = s:sub(-2):lower()
  -- ends in -s, -x, -z, -sh, -ch → -es
  if last == "s" or last == "x" or last == "z" then
    return s .. "es"
  elseif last2 == "sh" or last2 == "ch" then
    return s .. "es"
  -- ends in consonant + y → -ies
  elseif last == "y" and #s >= 2 and not VOWELS[s:sub(-2,-2)] then
    return s:sub(1,-2) .. "ies"
  else
    return s .. "s"
  end
end

function modifiers.ed(s)
  if #s == 0 then return s end
  local last = s:sub(-1):lower()
  local last2 = #s >= 2 and s:sub(-2,-2):lower() or ""
  -- ends in -e → just add d
  if last == "e" then
    return s .. "d"
  -- ends in consonant + y → -ied
  elseif last == "y" and not VOWELS[last2] and #s >= 2 then
    return s:sub(1,-2) .. "ied"
  -- ends in single consonant after single vowel (CVC) for short words → double
  -- simplified: if last is consonant and second-to-last is vowel and length <= 4
  elseif not VOWELS[last] and last ~= "w" and last ~= "x" and last ~= "y"
         and last2 ~= "" and VOWELS[last2] and #s <= 4 then
    return s .. last .. "ed"
  else
    return s .. "ed"
  end
end

function modifiers.ing(s)
  if #s == 0 then return s end
  local last = s:sub(-1):lower()
  -- ends in -e (not -ee) → drop e
  if last == "e" and #s >= 2 and s:sub(-2,-2):lower() ~= "e" then
    return s:sub(1,-2) .. "ing"
  else
    return s .. "ing"
  end
end

-- ──────────────────────── Grammar object ────────────────────

local Grammar = {}
Grammar.__index = Grammar

-- Parse inline assignments [var:value] from start of a string.
-- Returns: assignments table, rest of string after all [var:value] blocks.
local function parse_inline_assignments(s)
  local assignments = {}
  local pos = 1
  while true do
    -- skip leading whitespace? No — Tracery matches [...]  at any position but
    -- we only consume them from the front before expansion.
    local bracket_start = s:find("%[", pos)
    if not bracket_start or bracket_start ~= pos then
      break
    end
    local bracket_end = s:find("%]", bracket_start + 1)
    if not bracket_end then break end
    local inner = s:sub(bracket_start + 1, bracket_end - 1)
    local colon = inner:find(":", 1, true)
    if not colon then break end
    local var = inner:sub(1, colon - 1)
    local val = inner:sub(colon + 1)
    assignments[#assignments + 1] = { var = var, val = val }
    pos = bracket_end + 1
  end
  return assignments, s:sub(pos)
end

-- Expand a template string within a grammar (grammar object with :expand_raw).
-- depth: current recursion depth
local function expand_template(grammar, template, depth, max_depth)
  if depth > max_depth then
    return nil, "max expansion depth exceeded"
  end

  -- First process inline assignments at the start: [var:value]
  local assignments, rest = parse_inline_assignments(template)

  -- Push any inline assignments
  local pushed = #assignments > 0
  if pushed then
    local override = {}
    for _, a in ipairs(assignments) do
      -- The value itself may contain a symbol ref like #name#
      local expanded_val, err = expand_template(grammar, a.val, depth + 1, max_depth)
      if not expanded_val then return nil, err end
      override[a.var] = { expanded_val }
    end
    grammar:push(override)
  end

  -- Now expand the rest of the string
  local result, err = expand_raw(grammar, rest, depth, max_depth)

  if pushed then
    grammar:pop()
  end

  return result, err
end

-- expand_raw: expand #...# patterns in a string (no inline assignment processing)
function expand_raw(grammar, s, depth, max_depth)
  -- Find first #
  local result = {}
  local pos = 1
  local len = #s

  while pos <= len do
    local hash_start = s:find("#", pos, true)
    if not hash_start then
      result[#result + 1] = s:sub(pos)
      break
    end

    -- Append text before the hash
    if hash_start > pos then
      result[#result + 1] = s:sub(pos, hash_start - 1)
    end

    local hash_end = s:find("#", hash_start + 1, true)
    if not hash_end then
      -- Unmatched #, treat as literal
      result[#result + 1] = s:sub(hash_start)
      break
    end

    local inner = s:sub(hash_start + 1, hash_end - 1)

    -- Parse symbol and modifiers: symbol.mod1.mod2...
    local parts = {}
    for part in (inner .. "."):gmatch("([^.]*)[.]") do
      parts[#parts + 1] = part
    end

    local symbol = parts[1]
    local mods = {}
    for i = 2, #parts do
      mods[#mods + 1] = parts[i]
    end

    -- Look up symbol
    local options = grammar:_lookup(symbol)
    if not options then
      return nil, "undefined symbol: " .. symbol
    end

    -- Pick a random option
    local choice_idx = grammar._rng:choice(#options)
    local chosen = options[choice_idx]

    -- Recursively expand
    local expanded, err = expand_template(grammar, chosen, depth + 1, max_depth)
    if not expanded then return nil, err end

    -- Apply modifiers
    for _, mod_name in ipairs(mods) do
      local fn = modifiers[mod_name]
      if fn then
        expanded = fn(expanded)
      end
      -- unknown modifiers are silently ignored (passthrough)
    end

    result[#result + 1] = expanded
    pos = hash_end + 1
  end

  return table.concat(result)
end

-- Internal: look up a symbol in context stack (top → bottom)
function Grammar:_lookup(symbol)
  -- Walk context stack from top
  for i = #self._stack, 1, -1 do
    local rules = self._stack[i]
    if rules[symbol] then
      return rules[symbol]
    end
  end
  return nil
end

--- Expand a template string containing #symbol# patterns.
-- @param template string
-- @return string | nil, errmsg
function Grammar:expand(template)
  return expand_template(self, template, 0, self._max_depth)
end

--- Expand a symbol directly (equivalent to expand("#symbol#")).
-- @param symbol string
-- @return string | nil, errmsg
function Grammar:expand_symbol(symbol)
  return self:expand("#" .. symbol .. "#")
end

--- Push a set of rule overrides onto the context stack.
-- @param rules table  { symbol = {option1, option2, ...} }
function Grammar:push(rules)
  self._stack[#self._stack + 1] = rules
end

--- Pop the most recently pushed rule overrides.
function Grammar:pop()
  if #self._stack <= 1 then return end  -- never pop base rules
  self._stack[#self._stack] = nil
end

--- List all symbol names defined in the base grammar.
-- @return string[]
function Grammar:symbols()
  local result = {}
  local base = self._stack[1]
  for k in pairs(base) do
    result[#result + 1] = k
  end
  table.sort(result)
  return result
end

--- Create a new Grammar.
-- @param rules  table  { symbol = {option1, ...} }
-- @param opts   table  { seed=number, max_depth=number }
--   seed is required.
-- @return Grammar
function M.new(rules, opts)
  if not opts or not opts.seed then error("grammar_gen.new: opts.seed is required") end
  local g = setmetatable({}, Grammar)
  g._stack = { rules }
  g._rng = make_rng_luajit(opts.seed)
  g._max_depth = opts.max_depth or 100
  return g
end

return M
