-- lib/dice/init.lua
-- Dice notation parser, evaluator, and statistical analysis.
-- Supports NdS, keep/drop (k/kl), exploding (!), Fudge (dF), percentile (d%).
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local floor, sqrt = math.floor, math.sqrt
local sort = table.sort
local concat = table.concat

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------
-- Tokeniser state: { s=string, pos=integer }

local function peek(st)
  return st.s:sub(st.pos, st.pos)
end

local function at_end(st)
  return st.pos > #st.s
end

local function skip_ws(st)
  while st.pos <= #st.s and st.s:sub(st.pos, st.pos):match("%s") do
    st.pos = st.pos + 1
  end
end

-- Read zero or more digits; return integer or nil
local function read_int(st)
  local s = st.s
  local i = st.pos
  if i > #s or not s:sub(i, i):match("%d") then return nil end
  local j = i
  while j <= #s and s:sub(j, j):match("%d") do j = j + 1 end
  st.pos = j
  return tonumber(s:sub(i, j - 1))
end

-- Forward declarations
local parse_expr

-- Parse a single die-roll atom: [N]d(S|%|F[.2]) [k[l]K] [!]
-- Returns AST node or nil
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
    sides    = sides,
    keep     = keep,
    keep_low = keep_low,
    explode  = explode,
    fudge    = fudge,
    pct      = pct,
  }
end

-- Parse a primary expression: number | roll | '(' expr ')'
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
local function roll_one(sides, rng, fudge)
  local v = rng(sides)
  if fudge then return v - 2 end
  return v
end

-- Evaluate an AST node. Returns number or (nil, errmsg).
local function eval(node, rng)
  local t = node.type

  if t == "constant" then
    return node.value

  elseif t == "neg" then
    local v, err = eval(node.expr, rng)
    if not v then return nil, err end
    return -v

  elseif t == "binop" then
    local l, err = eval(node.left, rng)
    if not l then return nil, err end
    local r
    r, err = eval(node.right, rng)
    if not r then return nil, err end
    local op = node.op
    if op == "+" then return l + r
    elseif op == "-" then return l - r
    elseif op == "*" then return l * r
    elseif op == "/" then
      if r == 0 then return nil, "division by zero" end
      return floor(l / r)
    end

  elseif t == "roll" then
    local dice = {}
    for _ = 1, node.count do
      local v = roll_one(node.sides, rng, node.fudge)
      -- Exploding dice
      if node.explode and not node.fudge then
        local boom = 0
        while v % node.sides == 0 and boom < MAX_EXPLODE do
          v = v + roll_one(node.sides, rng, false)
          boom = boom + 1
        end
      end
      dice[#dice + 1] = v
    end

    -- Keep highest/lowest
    if node.keep then
      sort(dice)
      local sum = 0
      if node.keep_low then
        -- keep lowest keep values (already sorted ascending)
        for i = 1, node.keep do sum = sum + dice[i] end
      else
        -- keep highest keep values
        for i = node.count - node.keep + 1, node.count do
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

-- Evaluate a parsed AST node with full roll details.
-- Returns a details table or (nil, errmsg).
local function eval_detailed(node, rng, breakdown_parts)
  local t = node.type
  breakdown_parts = breakdown_parts or {}

  if t == "constant" then
    breakdown_parts[#breakdown_parts + 1] = tostring(node.value)
    return { total = node.value, rolls = {} }

  elseif t == "neg" then
    local inner, err = eval_detailed(node.expr, rng, {})
    if not inner then return nil, err end
    breakdown_parts[#breakdown_parts + 1] = "-(" .. (inner.breakdown or tostring(inner.total)) .. ")"
    return { total = -inner.total, rolls = inner.rolls,
             breakdown = "-(" .. (inner.breakdown or tostring(inner.total)) .. ")" }

  elseif t == "binop" then
    local lb, rb = {}, {}
    local l, err = eval_detailed(node.left, rng, lb)
    if not l then return nil, err end
    local r
    r, err = eval_detailed(node.right, rng, rb)
    if not r then return nil, err end
    local total
    local op = node.op
    if op == "+" then total = l.total + r.total
    elseif op == "-" then total = l.total - r.total
    elseif op == "*" then total = l.total * r.total
    elseif op == "/" then
      if r.total == 0 then return nil, "division by zero" end
      total = floor(l.total / r.total)
    end
    local lbd = lb[1] or tostring(l.total)
    local rbd = rb[1] or tostring(r.total)
    local bd = lbd .. op .. rbd
    breakdown_parts[#breakdown_parts + 1] = bd
    local rolls = {}
    for _, v in ipairs(l.rolls) do rolls[#rolls + 1] = v end
    for _, v in ipairs(r.rolls) do rolls[#rolls + 1] = v end
    return { total = total, rolls = rolls, breakdown = bd }

  elseif t == "roll" then
    local dice = {}
    for _ = 1, node.count do
      local v = roll_one(node.sides, rng, node.fudge)
      if node.explode and not node.fudge then
        local boom = 0
        while v % node.sides == 0 and boom < MAX_EXPLODE do
          v = v + roll_one(node.sides, rng, false)
          boom = boom + 1
        end
      end
      dice[#dice + 1] = v
    end

    local kept, dropped = {}, {}
    if node.keep then
      local sorted = {}
      for i, v in ipairs(dice) do sorted[i] = v end
      sort(sorted)
      if node.keep_low then
        for i = 1, node.keep do kept[#kept + 1] = sorted[i] end
        for i = node.keep + 1, #sorted do dropped[#dropped + 1] = sorted[i] end
      else
        for i = 1, node.count - node.keep do dropped[#dropped + 1] = sorted[i] end
        for i = node.count - node.keep + 1, node.count do kept[#kept + 1] = sorted[i] end
      end
    else
      for i, v in ipairs(dice) do kept[i] = v end
    end

    local sum = 0
    for _, v in ipairs(kept) do sum = sum + v end

    local sides_str
    if node.fudge then sides_str = "F"
    elseif node.pct then sides_str = "%"
    else sides_str = tostring(node.sides) end

    local label = node.count .. "d" .. sides_str
    if node.keep then
      label = label .. "k" .. (node.keep_low and "l" or "") .. node.keep
    end
    if node.explode then label = label .. "!" end

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

local function stats_node(node)
  local t = node.type

  if t == "constant" then
    return { min = node.value, max = node.value, mean = node.value, variance = 0 }

  elseif t == "neg" then
    local s = stats_node(node.expr)
    return { min = -s.max, max = -s.min, mean = -s.mean, variance = s.variance }

  elseif t == "binop" then
    local l = stats_node(node.left)
    local r = stats_node(node.right)
    local op = node.op
    if op == "+" then
      return { min = l.min + r.min, max = l.max + r.max,
               mean = l.mean + r.mean, variance = l.variance + r.variance }
    elseif op == "-" then
      return { min = l.min - r.max, max = l.max - r.min,
               mean = l.mean - r.mean, variance = l.variance + r.variance }
    elseif op == "*" then
      -- For simple constant * roll or roll * constant, compute analytically.
      -- Otherwise approximate via simulation mark.
      local mins = { l.min * r.min, l.min * r.max, l.max * r.min, l.max * r.max }
      sort(mins)
      -- Mean of product of independent vars = product of means (only for independent).
      return { min = mins[1], max = mins[4],
               mean = l.mean * r.mean, variance = nil }  -- nil triggers simulation
    elseif op == "/" then
      return { min = floor(l.min / math.max(r.max, 1)),
               max = floor(l.max / math.max(r.min, 1)),
               mean = nil, variance = nil }
    end

  elseif t == "roll" then
    -- Fudge: mean=0, var per die = 2/3
    if node.fudge then
      if node.keep then
        return nil  -- fall back to sim
      end
      local n = node.count
      return {
        min      = -n,
        max      =  n,
        mean     = 0,
        variance = n * (2 / 3),
      }
    end

    local s = node.sides

    -- Basic NdS (no keep, no explode) — closed form
    if not node.keep and not node.explode then
      local n = node.count
      local mean = n * (s + 1) / 2
      local var  = n * (s * s - 1) / 12
      return { min = n, max = n * s, mean = mean, variance = var }
    end

    -- Keep / explode: simulate
    return nil
  end

  return nil
end

-- Fallback: simulate to get stats.
local function simulate_stats(node, n)
  local sum, sum2 = 0, 0
  local mn, mx = math.huge, -math.huge
  local counts = {}
  for _ = 1, n do
    local v = eval(node, DEFAULT_RNG)
    if v then
      sum  = sum  + v
      sum2 = sum2 + v * v
      if v < mn then mn = v end
      if v > mx then mx = v end
      counts[v] = (counts[v] or 0) + 1
    end
  end
  local mean = sum / n
  local variance = sum2 / n - mean * mean
  return { min = mn, max = mx, mean = mean, variance = variance }
end

function M.stats(expr_or_string)
  local node, err = resolve(expr_or_string)
  if not node then return nil, err end

  local s = stats_node(node)
  if not s or s.variance == nil or s.mean == nil then
    -- Fall back to simulation
    s = simulate_stats(node, SIM_N)
  end

  s.stddev = sqrt(s.variance)
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
    if v then freq[v] = (freq[v] or 0) + 1 end
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
