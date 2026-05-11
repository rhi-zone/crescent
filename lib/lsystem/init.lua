if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/lsystem — Lindenmayer system procedural generation
-- Pure Lua implementation. No external dependencies.

local M = {}
M._tier = "pure"

-- ========================
-- INTERNAL: LCG RNG
-- ========================

local function make_rng(seed)
  local s = seed or 12345
  return {
    next = function(self)
      s = (s * 1664525 + 1013904223) % 4294967296
      return s
    end,
    float = function(self)
      s = (s * 1664525 + 1013904223) % 4294967296
      return s / 4294967296
    end,
  }
end

-- ========================
-- EXPAND
-- ========================

--:: Rng = { next: (self: Rng) -> integer, float: (self: Rng) -> number }
--:: Rules = { [string]: unknown }

-- Apply rules once to a string, return new string.
--: (string, Rules, Rng) -> string
local function apply_rules(s, rules, rng)
  local parts = {}
  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    local rule = rules[ch]
    if rule == nil then
      parts[#parts + 1] = ch
    elseif type(rule) == "string" then
      parts[#parts + 1] = rule
    else
      -- stochastic: array of {replacement, prob}
      local r = rng:float()
      local cumul = 0
      local chosen = ch -- fallback identity
      for _, entry in ipairs(rule) do
        cumul = cumul + entry[2]
        if r < cumul then
          chosen = entry[1]
          break
        end
      end
      parts[#parts + 1] = chosen
    end
    i = i + 1
  end
  return table.concat(parts)
end

-- ========================
-- TURTLE INTERPRETER
-- ========================

-- Map symbol → turtle command
-- Returns {op=string, ...} or nil if symbol is decoration/ignored.
local TURTLE_OPS = {
  F = "forward",  -- forward + draw
  G = "forward",  -- forward + draw (alias)
  f = "move",     -- forward, no draw
  ["+"] = function(angle) return { op = "turn", angle = angle } end,
  ["-"] = function(angle) return { op = "turn", angle = -angle } end,
  ["|"] = function(_) return { op = "turn", angle = 180 } end,
  ["["] = function(_) return { op = "push" } end,
  ["]"] = function(_) return { op = "pop" } end,
  ["&"] = function(_) return { op = "pitch", angle = -1 } end, -- pitch down, factor of angle
  ["^"] = function(_) return { op = "pitch", angle = 1 } end,  -- pitch up
  ["\\"] = function(_) return { op = "roll", angle = -1 } end, -- roll left
  ["/"] = function(_) return { op = "roll", angle = 1 } end,   -- roll right
  ["!"] = function(_) return { op = "width", delta = -1 } end,
  ["`"] = function(_) return { op = "width", delta = 1 } end,
  ["#"] = function(_) return { op = "color", delta = 1 } end,
}

--:: TurtleCmd = { op: string, ... }
--: (string, number) -> { [integer]: TurtleCmd, ... }
local function parse_turtle(s, angle)
  local cmds = {} --: { [integer]: TurtleCmd, ... }
  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "F" or ch == "G" then
      cmds[#cmds + 1] = { op = "forward" }
    elseif ch == "f" then
      cmds[#cmds + 1] = { op = "move" }
    else
      local handler = TURTLE_OPS[ch]
      if type(handler) == "function" then
        local cmd = handler(angle)
        if cmd then cmds[#cmds + 1] = cmd end
      end
      -- unknown symbols are silently ignored (they may be decoration)
    end
    i = i + 1
  end
  return cmds
end

-- ========================
-- LSYSTEM OBJECT
-- ========================

--:: LsSpec = { axiom: string, rules: { [string]: unknown }, angle?: number, step?: number, seed?: integer }
--:: LsObj = { _axiom: string, _rules: { [string]: unknown }, _angle: number, _step: number, _rng: Rng, ... }

local Ls = {}
Ls.__index = Ls

--: (self: LsObj, integer) -> (string | nil, string | nil)
function Ls:expand(n)
  if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
    return nil, "expand: n must be a non-negative integer"
  end
  local s = self._axiom
  for _ = 1, n do
    s = apply_rules(s, self._rules, self._rng)
  end
  return s
end

--: (self: LsObj, integer) -> (() -> (integer | nil, string | nil))
function Ls:expand_iter(n)
  if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
    -- return an iterator that immediately errors
    local done = false
    --: () -> (integer | nil, string | nil)
    return function()
      if not done then
        done = true
        error("expand_iter: n must be a non-negative integer")
      end
      return nil, nil
    end
  end
  local s = self._axiom
  local step = 0
  --: () -> (integer | nil, string | nil)
  return function()
    if step > n then return nil, nil end
    local current = s
    local i = step
    step = step + 1
    if step <= n then
      s = apply_rules(s, self._rules, self._rng)
    end
    return i --[[:! integer]], current
  end
end

function Ls:turtle(s)
  if type(s) ~= "string" then
    return nil, "turtle: argument must be a string"
  end
  return parse_turtle(s, self._angle)
end

-- ========================
-- CONSTRUCTOR
-- ========================

--: (LsSpec) -> (LsObj | nil, string | nil)
function M.new(spec)
  if type(spec) ~= "table" then
    return nil, "new: spec must be a table"
  end
  if spec.axiom == nil then
    return nil, "new: spec.axiom is required"
  end
  if type(spec.axiom) ~= "string" then
    return nil, "new: spec.axiom must be a string"
  end
  if spec.rules == nil then
    return nil, "new: spec.rules is required"
  end
  if type(spec.rules) ~= "table" then
    return nil, "new: spec.rules must be a table"
  end

  -- Validate rules
  for sym, rule in pairs(spec.rules) do
    local sym_s = sym --[[:! string]]
    if type(sym) ~= "string" or #sym_s ~= 1 then
      return nil, "new: rule keys must be single characters, got: " .. tostring(sym)
    end
    if type(rule) == "table" then
      local total = 0.0 --: number
      for _, entry in ipairs(rule --[[:! { [integer]: unknown }]]) do
        if type(entry) ~= "table" or type(entry[1]) ~= "string" or type(entry[2]) ~= "number" then
          return nil, "new: stochastic rule entries must be {string, number}"
        end
        local entry_ = entry --[[:! { [integer]: unknown }]]
        total = total + (entry_[2] --[[:! number]])
      end
      -- allow small floating point error
      if math.abs(total - 1.0) > 0.01 then
        return nil, "new: stochastic rule probabilities must sum to 1.0, got " .. total
      end
    elseif type(rule) ~= "string" then
      return nil, "new: rule value must be string or stochastic table"
    end
  end

  local angle = spec.angle or 90
  local step  = spec.step  or 1
  local seed  = spec.seed  or 42

  local ls = setmetatable({
    _axiom = spec.axiom,
    _rules = spec.rules,
    _angle = angle,
    _step  = step,
    _rng   = make_rng(seed),
  }, Ls)
  return ls
end

-- ========================
-- PRESETS
-- ========================

M.presets = {}

-- Koch snowflake / Koch curve
M.presets.koch_snowflake = M.new({
  axiom = "F--F--F",
  rules = { F = "F+F--F+F" },
  angle = 60,
})

-- Dragon curve
M.presets.dragon_curve = M.new({
  axiom = "FX",
  rules = {
    X = "X+YF+",
    Y = "-FX-Y",
  },
  angle = 90,
})

-- Sierpinski triangle
M.presets.sierpinski = M.new({
  axiom = "F-G-G",
  rules = {
    F = "F-G+F+G-F",
    G = "GG",
  },
  angle = 120,
})

-- Classic plant / fractal plant
M.presets.plant = M.new({
  axiom = "X",
  rules = {
    X = "F+[[X]-X]-F[-FX]+X",
    F = "FF",
  },
  angle = 25,
})

-- Hilbert curve (2D space-filling)
M.presets.hilbert = M.new({
  axiom = "A",
  rules = {
    A = "+BF-AFA-FB+",
    B = "-AF+BFB+FA-",
  },
  angle = 90,
})

-- Pentigree (pentaflake / pentigree L-system)
M.presets.pentigree = M.new({
  axiom = "F-F-F-F-F",
  rules = {
    F = "F-F++F+F-F-F",
  },
  angle = 72,
})

return M
