-- lib/dice/init.lua
-- Dice notation parser, evaluator, and statistical analysis.
-- Supports NdS, keep/drop (k/kl), exploding (!), Fudge (dF), percentile (d%).
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local math2 = require("lib.math")
local floor, sqrt = math.floor, math.sqrt
local sort = table.sort
local concat = table.concat

--:: DiceSt = { s: string, pos: integer }
--:: RollNode = { type: "roll", count: integer, sides: integer, keep: integer | nil, keep_low: boolean, explode: boolean, fudge: boolean, pct: boolean }
--:: NegNode = { type: "neg", expr: DiceNode }
--:: BinopNode = { type: "binop", op: string, left: DiceNode, right: DiceNode }
--:: ConstNode = { type: "constant", value: number }
--:: DiceNode = RollNode | NegNode | BinopNode | ConstNode
--:: StatsResult = { min: number, max: number, mean: number | nil, variance: number | nil }

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------
-- Tokeniser state: { s=string, pos=integer }

--: (st: DiceSt) -> string
local function peek(st)
  return st.s:sub(st.pos, st.pos)
end

--: (st: DiceSt) -> boolean
local function at_end(st)
  return st.pos > #st.s
end

--: (st: DiceSt) -> nil
local function skip_ws(st)
  while st.pos <= #st.s and st.s:sub(st.pos, st.pos):match("%s") do
    st.pos = st.pos + 1
  end
end

-- Read zero or more digits; return integer or nil
--: (st: DiceSt) -> integer | nil
local function read_int(st)
  local s = st.s
  local i = st.pos
  if i > #s or not s:sub(i, i):match("%d") then return nil end
  local j = i
  while j <= #s and s:sub(j, j):match("%d") do j = j + 1 end
  st.pos = j
  return math2.tointeger(s:sub(i, j - 1))
end

-- Forward declarations
local parse_expr

-- Parse a single die-roll atom: [N]d(S|%|F[.2]) [k[l]K] [!]
-- Returns AST node or nil
--: (st: DiceSt) -> (RollNode | nil, string | nil)
local function parse_roll(st)
  local start = st.pos

  -- Optional count
  local count = read_int(st)

  -- Must have 'd' or 'D'
  local ch = st.s:sub(st.pos, st.pos):lower()
  if ch ~= "d" then
    -- Backtrack: it was just a number (constant), not a roll
    st.pos = start
    return nil
  end
  st.pos = st.pos + 1  -- consume 'd'

  -- Sides: %, F/f, or integer
  local sides
  local fudge = false
  local pct = false

  local sc = st.s:sub(st.pos, st.pos)
  if sc == "%" then
    pct = true
    sides = 100
    st.pos = st.pos + 1
  elseif sc:lower() == "f" then
    fudge = true
    sides = 3  -- internal: roll 1d3 then subtract 2
    st.pos = st.pos + 1
    -- Optionally consume ".2" (dF.2 is the standard notation)
    if st.s:sub(st.pos, st.pos + 1) == ".2" then
      st.pos = st.pos + 2
    end
  else
    sides = read_int(st)
    if not sides then
      -- bare 'd' with no valid sides — syntax error
      return nil, ("expected die sides after 'd' at position %d"):format(st.pos)
    end
    if sides < 1 then
      return nil, ("die sides must be >= 1, got %d"):format(sides)
    end
  end

  count = count or 1
  local sides_ = sides --[[:! integer]]

  -- Optional keep modifier: k[l]N
  local keep = nil
  local keep_low = false
  local kch = st.s:sub(st.pos, st.pos):lower()
  if kch == "k" then
    st.pos = st.pos + 1
    local lch = st.s:sub(st.pos, st.pos):lower()
    if lch == "l" then
      keep_low = true
      st.pos = st.pos + 1
    end
    keep = read_int(st)
    if not keep then
      return nil, ("expected number after 'k' at position %d"):format(st.pos)
    end
    if keep > count then
      return nil, ("keep count %d exceeds dice count %d"):format(keep, count)
    end
  end

  -- Optional explode: !
  local explode = false
  if st.s:sub(st.pos, st.pos) == "!" then
    explode = true
    st.pos = st.pos + 1
  end

  return {
    type     = "roll",
    count    = count,
    sides    = sides_,
    keep     = keep,
    keep_low = keep_low,
    explode  = explode,
    fudge    = fudge,
    pct      = pct,
  }
end

-- Parse a primary expression: number | roll | '(' expr ')'
--: (st: DiceSt) -> (DiceNode | nil, string | nil)
local function parse_primary(st)
  skip_ws(st)

  -- Parenthesised sub-expression
  if peek(st) == "(" then
    st.pos = st.pos + 1
    skip_ws(st)
    local expr, err = parse_expr(st, 0)
    if not expr then return nil, err end
    skip_ws(st)
    if peek(st) ~= ")" then
      return nil, ("expected ')' at position %d"):format(st.pos)
    end
    st.pos = st.pos + 1
    return expr
  end

  -- Unary minus
  if peek(st) == "-" then
    st.pos = st.pos + 1
    skip_ws(st)
    local inner, err = parse_primary(st)
    if not inner then return nil, err end
    return { type = "neg", expr = inner }
  end

  -- Try die roll first
  local rollnode, err = parse_roll(st)
  if err then return nil, err end
  if rollnode then return rollnode end

  -- Plain integer constant
  local n = read_int(st)
  if n then
    return { type = "constant", value = n }
  end

  return nil, ("unexpected character '%s' at position %d"):format(peek(st), st.pos)
end

-- Pratt-style binary operator parsing
local PREC = { ["+"] = 1, ["-"] = 1, ["*"] = 2, ["/"] = 2 }

--: (st: DiceSt, min_prec: integer) -> (DiceNode | nil, string | nil)
parse_expr = function(st, min_prec)
  local left, err = parse_primary(st)
  if not left then return nil, err end

  while true do
    skip_ws(st)
    local op = peek(st)
    local prec = PREC[op]
    if not prec or prec <= min_prec then break end
    st.pos = st.pos + 1
    skip_ws(st)
    local right
    right, err = parse_expr(st, prec)
    if not right then return nil, err end
    left = { type = "binop", op = op, left = left, right = right }
  end

  return left
end

-- Parse a dice notation string into an AST.
-- Returns: expr, nil  or  nil, errmsg
function M.parse(notation)
  if type(notation) ~= "string" then
    return nil, "expected string, got " .. type(notation)
  end
  notation = notation:match("^%s*(.-)%s*$")  -- trim
  if notation == "" then
    return nil, "empty dice notation"
  end

  local st = { s = notation, pos = 1 }
  local expr, err = parse_expr(st, 0)
  if not expr then return nil, err or "parse error" end
  skip_ws(st)
  if not at_end(st) then
    return nil, ("unexpected text at position %d: '%s'"):format(st.pos, st.s:sub(st.pos))
  end
  return expr
end

-- ---------------------------------------------------------------------------
-- Evaluator
-- ---------------------------------------------------------------------------

local MAX_EXPLODE = 100  -- prevent infinite explosion loops

-- Roll a single die of `sides` sides using rng.
-- For fudge: roll 1d3, subtract 2 → {-1, 0, 1}.
--: (sides: integer, rng: (integer) -> integer, fudge: boolean) -> integer
local function roll_one(sides, rng, fudge)
  local v = rng(sides)
  if fudge then return v - 2 end
  return v
end

-- Evaluate an AST node. Returns number or (nil, errmsg).
--: (node: DiceNode, rng: (integer) -> integer) -> (number | nil, string | nil)
local function eval(node, rng)
  local t = node.type

  if t == "constant" then
    local cn = node --[[:! ConstNode]]
    return cn.value

  elseif t == "neg" then
    local nn = node --[[:! NegNode]]
    local v, err = eval(nn.expr, rng)
    if not v then return nil, err end
    local v_ = v --[[:! number]]
    return -v_

  elseif t == "binop" then
    local bn = node --[[:! BinopNode]]
    local l, err = eval(bn.left, rng)
    if not l then return nil, err end
    local l_ = l --[[:! number]]
    local r
    r, err = eval(bn.right, rng)
    if not r then return nil, err end
    local r_ = r --[[:! number]]
    local op = bn.op
    if op == "+" then return l_ + r_
    elseif op == "-" then return l_ - r_
    elseif op == "*" then return l_ * r_
    elseif op == "/" then
      if r_ == 0 then return nil, "division by zero" end
      return floor(l_ / r_)
    end

  elseif t == "roll" then
    local rn = node --[[:! RollNode]]
    local dice = {} --: { [integer]: integer }
    for _ = 1, rn.count do
      local v = roll_one(rn.sides, rng, rn.fudge)
      -- Exploding dice
      if rn.explode and not rn.fudge then
        local boom = 0
        while v % rn.sides == 0 and boom < MAX_EXPLODE do
          v = v + roll_one(rn.sides, rng, false)
          boom = boom + 1
        end
      end
      dice[#dice + 1] = v
    end

    -- Keep highest/lowest
    if rn.keep then
      sort(dice)
      local keep_ = rn.keep --[[:! integer]]
      local sum = 0
      if rn.keep_low then
        -- keep lowest keep values (already sorted ascending)
        for i = 1, keep_ do sum = sum + dice[i] end
      else
        -- keep highest keep values
        for i = rn.count - keep_ + 1, rn.count do
          sum = sum + dice[i]
        end
      end
      return sum
    end

    local sum = 0
    for i = 1, #dice do sum = sum + dice[i] end
    return sum
  end

  return nil, "unknown node type: " .. tostring(t)
end

--:: DetailResult = { total: number, rolls: { [integer]: unknown }, breakdown: string | nil }
-- Evaluate a parsed AST node with full roll details.
-- Returns a details table or (nil, errmsg).
--: (node: DiceNode, rng: (integer) -> integer, breakdown_parts: { [integer]: string } | nil) -> (DetailResult | nil, string | nil)
local function eval_detailed(node, rng, breakdown_parts)
  local t = node.type
  breakdown_parts = breakdown_parts or {}

  if t == "constant" then
    local cn = node --[[:! ConstNode]]
    breakdown_parts[#breakdown_parts + 1] = tostring(cn.value)
    local empty_rolls = {} --: { [integer]: unknown }
    return { total = cn.value, rolls = empty_rolls, breakdown = nil }

  elseif t == "neg" then
    local nn = node --[[:! NegNode]]
    local inner, err = eval_detailed(nn.expr, rng, {})
    if not inner then return nil, err end
    local inner_ = inner --[[:! DetailResult]]
    breakdown_parts[#breakdown_parts + 1] = "-(" .. (inner_.breakdown or tostring(inner_.total)) .. ")"
    return { total = -inner_.total, rolls = inner_.rolls,
             breakdown = "-(" .. (inner_.breakdown or tostring(inner_.total)) .. ")" }

  elseif t == "binop" then
    local bn = node --[[:! BinopNode]]
    local lb = {} --: { [integer]: string }
    local rb = {} --: { [integer]: string }
    local l, err = eval_detailed(bn.left, rng, lb)
    if not l then return nil, err end
    local l_ = l --[[:! DetailResult]]
    local r
    r, err = eval_detailed(bn.right, rng, rb)
    if not r then return nil, err end
    local r_ = r --[[:! DetailResult]]
    local total = 0 --: number
    local op = bn.op
    if op == "+" then total = l_.total + r_.total
    elseif op == "-" then total = l_.total - r_.total
    elseif op == "*" then total = l_.total * r_.total
    elseif op == "/" then
      if r_.total == 0 then return nil, "division by zero" end
      total = floor(l_.total / r_.total)
    end
    local lbd = lb[1] or tostring(l_.total)
    local rbd = rb[1] or tostring(r_.total)
    local bd = lbd .. op .. rbd
    breakdown_parts[#breakdown_parts + 1] = bd
    local rolls = {} --: { [integer]: unknown }
    for _, v in ipairs(l_.rolls) do rolls[#rolls + 1] = v end
    for _, v in ipairs(r_.rolls) do rolls[#rolls + 1] = v end
    return { total = total, rolls = rolls, breakdown = bd }

  elseif t == "roll" then
    local rn = node --[[:! RollNode]]
    local dice = {} --: { [integer]: integer }
    for _ = 1, rn.count do
      local v = roll_one(rn.sides, rng, rn.fudge)
      if rn.explode and not rn.fudge then
        local boom = 0
        while v % rn.sides == 0 and boom < MAX_EXPLODE do
          v = v + roll_one(rn.sides, rng, false)
          boom = boom + 1
        end
      end
      dice[#dice + 1] = v
    end

    local kept = {} --: { [integer]: integer }
    local dropped = {} --: { [integer]: integer }
    if rn.keep then
      local sorted = {} --: { [integer]: integer }
      for i, v in ipairs(dice) do sorted[i] = v end
      sort(sorted)
      local keep_ = rn.keep --[[:! integer]]
      if rn.keep_low then
        for i = 1, keep_ do kept[#kept + 1] = sorted[i] end
        for i = keep_ + 1, #sorted do dropped[#dropped + 1] = sorted[i] end
      else
        for i = 1, rn.count - keep_ do dropped[#dropped + 1] = sorted[i] end
        for i = rn.count - keep_ + 1, rn.count do kept[#kept + 1] = sorted[i] end
      end
    else
      for i, v in ipairs(dice) do kept[i] = v end
    end

    local sum = 0
    for _, v in ipairs(kept) do sum = sum + v end

    local sides_str
    if rn.fudge then sides_str = "F"
    elseif rn.pct then sides_str = "%"
    else sides_str = tostring(rn.sides) end

    local label = rn.count .. "d" .. (sides_str --[[:! string]])
    if rn.keep then
      label = label .. "k" .. (rn.keep_low and "l" or "") .. (rn.keep --[[:! integer]])
    end
    if rn.explode then label = label .. "!" end

    local roll_entry = {
      label   = label,
      dice    = dice,
      kept    = kept,
      dropped = dropped,
      sum     = sum,
    }

    local dice_strs = {}
    for i, v in ipairs(dice) do dice_strs[i] = tostring(v) end
    local bd = label .. "[" .. concat(dice_strs, ",") .. "]=" .. sum
    breakdown_parts[#breakdown_parts + 1] = bd

    return { total = sum, rolls = { roll_entry }, breakdown = bd }
  end

  return nil, "unknown node type: " .. tostring(t)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local DEFAULT_RNG = math.random

-- Resolve expr_or_string to an AST node.
local function resolve(expr_or_string)
  if type(expr_or_string) == "string" then
    return M.parse(expr_or_string)
  end
  if type(expr_or_string) == "table" then
    return expr_or_string
  end
  return nil, "expected string or parsed expression"
end

-- Roll: evaluate and return total.
function M.roll(expr_or_string, rng)
  local node, err = resolve(expr_or_string)
  if not node then return nil, err end
  rng = rng or DEFAULT_RNG
  return eval(node, rng)
end

-- Roll with details.
function M.roll_detailed(expr_or_string, rng)
  local node, err = resolve(expr_or_string)
  if not node then return nil, err end
  rng = rng or DEFAULT_RNG
  local parts = {}
  local details
  details, err = eval_detailed(node, rng, parts)
  if not details then return nil, err end
  details.breakdown = details.breakdown or concat(parts, "")
  return details
end

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------

-- Compute {min, max, mean, variance} for an AST node.
-- For keep/explode we fall back to simulation.
local SIM_N = 10000

--: (node: DiceNode) -> { min: number, max: number, mean: number | nil, variance: number | nil } | nil
local function stats_node(node)
  local t = node.type

  if t == "constant" then
    local cn = node --[[:! ConstNode]]
    local v = cn.value --: number
    local zero = 0 --: number
    return { min = v, max = v, mean = v, variance = zero }

  elseif t == "neg" then
    local nn = node --[[:! NegNode]]
    local s = stats_node(nn.expr)
    if not s then return nil end
    local smin = s.min --: number
    local smax = s.max --: number
    local smean = s.mean
    local svar = s.variance
    return { min = -smax, max = -smin,
             mean = smean and -smean or nil, variance = svar }

  elseif t == "binop" then
    local bn = node --[[:! BinopNode]]
    local l_raw = stats_node(bn.left)
    local r_raw = stats_node(bn.right)
    if not l_raw or not r_raw then return nil end
    -- After nil guard, l_raw and r_raw are non-nil; use direct field access
    local l_min = (l_raw or {min=0}).min --: number
    local l_max = (l_raw or {max=0}).max --: number
    local l_mean = (l_raw or {mean=nil}).mean --: number | nil
    local l_var = (l_raw or {variance=nil}).variance --: number | nil
    local r_min = (r_raw or {min=0}).min --: number
    local r_max = (r_raw or {max=0}).max --: number
    local r_mean = (r_raw or {mean=nil}).mean --: number | nil
    local r_var = (r_raw or {variance=nil}).variance --: number | nil
    --:: _BinSR = { min: number, max: number, mean: number | nil, variance: number | nil }
    local l_ = { min = l_min, max = l_max, mean = l_mean, variance = l_var } --: _BinSR
    local r_ = { min = r_min, max = r_max, mean = r_mean, variance = r_var } --: _BinSR
    local op = bn.op
    if op == "+" then
      local lm = l_.mean --: number | nil
      local rm = r_.mean --: number | nil
      local lv = l_.variance --: number | nil
      local rv = r_.variance --: number | nil
      local cmean = lm and rm and (lm --[[:! number]]) + (rm --[[:! number]]) or nil --: number | nil
      local cvar = lv and rv and (lv --[[:! number]]) + (rv --[[:! number]]) or nil --: number | nil
      return { min = l_.min + r_.min, max = l_.max + r_.max,
               mean = cmean, variance = cvar }
    elseif op == "-" then
      local lm = l_.mean --: number | nil
      local rm = r_.mean --: number | nil
      local lv = l_.variance --: number | nil
      local rv = r_.variance --: number | nil
      local cmean = lm and rm and (lm --[[:! number]]) - (rm --[[:! number]]) or nil --: number | nil
      local cvar = lv and rv and (lv --[[:! number]]) + (rv --[[:! number]]) or nil --: number | nil
      return { min = l_.min - r_.max, max = l_.max - r_.min,
               mean = cmean, variance = cvar }
    elseif op == "*" then
      -- For simple constant * roll or roll * constant, compute analytically.
      -- Otherwise approximate via simulation mark.
      local mins = { l_.min * r_.min, l_.min * r_.max, l_.max * r_.min, l_.max * r_.max } --: { [integer]: number }
      sort(mins --[[:! { [integer]: integer }]])
      -- Mean of product of independent vars = product of means (only for independent).
      local lm = l_.mean --: number | nil
      local rm = r_.mean --: number | nil
      local cmean = lm and rm and (lm --[[:! number]]) * (rm --[[:! number]]) or nil --: number | nil
      return { min = mins[1], max = mins[4],
               mean = cmean, variance = nil }  -- nil triggers simulation
    elseif op == "/" then
      return { min = floor(l_.min / math.max(r_.max, 1)),
               max = floor(l_.max / math.max(r_.min, 1)),
               mean = nil, variance = nil }
    end

  elseif t == "roll" then
    local rn = node --[[:! RollNode]]
    -- Fudge: mean=0, var per die = 2/3
    if rn.fudge then
      if rn.keep then
        return nil  -- fall back to sim
      end
      local n = rn.count
      local n_ = n --: number
      local zero = 0 --: number
      return {
        min      = -n_,
        max      =  n_,
        mean     = zero,
        variance = n_ * (2 / 3),
      }
    end

    local s = rn.sides

    -- Basic NdS (no keep, no explode) — closed form
    if not rn.keep and not rn.explode then
      local n = rn.count
      local n_ = n --: number
      local mean = n_ * (s + 1) / 2
      local var  = n_ * (s * s - 1) / 12
      return { min = n_, max = n_ * s, mean = mean, variance = var }
    end

    -- Keep / explode: simulate
    return nil
  end

  return nil
end

-- Fallback: simulate to get stats.
--: (node: DiceNode, n: integer) -> { min: number, max: number, mean: number, variance: number }
local function simulate_stats(node, n)
  local sum = 0 --: number
  local sum2 = 0 --: number
  local mn = math.huge --: number
  local mx = -math.huge --: number
  local counts = {}
  for _ = 1, n do
    local v = eval(node, DEFAULT_RNG)
    if v then
      local v_ = v --[[:! number]]
      sum  = sum  + v_
      sum2 = sum2 + v_ * v_
      if v_ < mn then mn = v_ end
      if v_ > mx then mx = v_ end
      counts[v_] = ((counts[v_] --[[:! integer | nil]]) or 0) + 1
    end
  end
  local mean = sum / n
  local variance = sum2 / n - mean * mean
  return { min = mn, max = mx, mean = mean, variance = variance }
end

function M.stats(expr_or_string)
  local node, err = resolve(expr_or_string)
  if not node then return nil, err end

  local s_raw = stats_node(node)
  local s = (s_raw and s_raw.variance ~= nil and s_raw.mean ~= nil)
    and s_raw or simulate_stats(node, SIM_N)
  local svar = s.variance --[[:! number]]
  s.stddev = sqrt(svar)
  return s
end

-- Simulate: roll n times, return frequency table.
function M.simulate(expr_or_string, n, rng)
  local node, err = resolve(expr_or_string)
  if not node then return nil, err end
  rng = rng or DEFAULT_RNG
  local freq = {}
  for _ = 1, n do
    local v = eval(node, rng)
    if v then
      local v_ = v --[[:! number]]
      freq[v_] = ((freq[v_] --[[:! integer | nil]]) or 0) + 1
    end
  end
  return freq
end

-- Convenience: roll 1dN.
function M.d(n)
  return DEFAULT_RNG(n)
end

-- Convenience: roll a string expression.
function M.roll_str(s)
  return M.roll(s)
end

return M
