-- lib/logic_circuit/init.lua
-- Digital logic circuit simulation: gates, flip-flops, truth tables, Quine-McCluskey.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
--: string
M._tier = "pure"

-- LuaJIT bit operations (available as built-in 'bit' library)
local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot

-- ── Gate evaluation ───────────────────────────────────────────────────────────

local GATE_FNS = {
  AND    = function(inputs) local r=1 for _,v in ipairs(inputs) do if v==0 then return 0 end end return r end,
  OR     = function(inputs) for _,v in ipairs(inputs) do if v~=0 then return 1 end end return 0 end,
  NOT    = function(inputs) return inputs[1]==0 and 1 or 0 end,
  BUFFER = function(inputs) return inputs[1] end,
  NAND   = function(inputs) local r=1 for _,v in ipairs(inputs) do if v==0 then return 1 end end return 0 end,
  NOR    = function(inputs) for _,v in ipairs(inputs) do if v~=0 then return 0 end end return 1 end,
  XOR    = function(inputs)
    local r = inputs[1] or 0
    for i=2,#inputs do r = (r ~= inputs[i]) and 1 or 0 end
    return r
  end,
  XNOR   = function(inputs)
    local r = inputs[1] or 0
    for i=2,#inputs do r = (r ~= inputs[i]) and 1 or 0 end
    return r==0 and 1 or 0
  end,
  MUX    = function(inputs)
    -- inputs: ..data lines, then sel line(s)
    -- For 2-input MUX: inputs = {A, B, S} → S=0 → A, S=1 → B
    local n = #inputs
    local sel = inputs[n]
    return inputs[sel+1] or 0
  end,
  DEMUX  = function(inputs)
    -- Returns single value; caller chooses output by sel
    return inputs[1]
  end,
}

local function eval_gate(gtype, input_vals)
  local fn = GATE_FNS[gtype]
  if not fn then return nil, "unknown gate type: " .. tostring(gtype) end
  return fn(input_vals)
end

-- ── Circuit ───────────────────────────────────────────────────────────────────

local Circuit = {}
Circuit.__index = Circuit

function M.circuit()
  return setmetatable({
    _inputs  = {},   -- ordered list of input names
    _outputs = {},   -- ordered list of output names
    _gates   = {},   -- ordered list: {name, type, inputs=[...]}
    _gate_map= {},   -- name → gate index
    _conns   = {},   -- output_name → source_name (gate or input)
    _input_set = {}, -- name → true
  }, Circuit)
end

function Circuit:input(name)
  self._inputs[#self._inputs+1] = name
  self._input_set[name] = true
end

function Circuit:output(name)
  self._outputs[#self._outputs+1] = name
end

function Circuit:gate(name, gtype, inputs)
  if not GATE_FNS[gtype] then
    return nil, "unknown gate type: " .. tostring(gtype)
  end
  local idx = #self._gates + 1
  self._gates[idx] = { name=name, gtype=gtype, inputs=inputs }
  self._gate_map[name] = idx
  return true
end

-- gate_n: multi-bit gate (bus-aware); same as gate for now
function Circuit:gate_n(name, gtype, inputs, opts)
  return self:gate(name, gtype, inputs)
end

function Circuit:connect(source, output_name)
  self._conns[output_name] = source
end

-- bus: declare a named multi-bit bus (informational; eval treats as scalar)
function Circuit:bus(name, width)
  -- Record bus meta; eval doesn't use it directly
  self._buses = self._buses or {}
  self._buses[name] = width
end

-- Topological evaluation
function Circuit:eval(input_values)
  -- memo: node_name → computed value
  local memo = {}
  for k,v in pairs(input_values) do
    memo[k] = v
  end

  -- Resolve a node (input, gate output) by name
  local function resolve(name)
    if memo[name] ~= nil then return memo[name] end
    local gi = self._gate_map[name]
    if not gi then
      -- might be an undeclared node; return nil
      return nil, "unknown node: " .. tostring(name)
    end
    local g = self._gates[gi]
    local iv = {}
    for i, inp in ipairs(g.inputs) do
      local v, err = resolve(inp)
      if v == nil and err then return nil, err end
      iv[i] = v or 0
    end
    local result, err = eval_gate(g.gtype, iv)
    if result == nil then return nil, err end
    memo[name] = result
    return result
  end

  -- Compute all gates
  for _, g in ipairs(self._gates) do
    local _, err = resolve(g.name)
    if err then return nil, err end
  end

  -- Collect outputs
  local out = {}
  for _, oname in ipairs(self._outputs) do
    local src = self._conns[oname]
    if src then
      local v, err = resolve(src)
      if v == nil and err then return nil, err end
      out[oname] = v or 0
    else
      out[oname] = nil
    end
  end
  return out
end

function Circuit:truth_table()
  local n = #self._inputs
  local rows = {}
  local total = 2^n
  for i = 0, total-1 do
    local iv = {}
    for b = 0, n-1 do
      local bit_val = math.floor(i / 2^(n-1-b)) % 2
      iv[self._inputs[b+1]] = bit_val
    end
    local ov, err = self:eval(iv)
    if ov == nil then return nil, err end
    rows[#rows+1] = { inputs=iv, outputs=ov }
  end
  return rows
end

function Circuit:gate_count()
  return #self._gates
end

function Circuit:critical_path()
  -- Longest path from any input to any gate output, in gate hops
  local memo = {}

  local function depth(name)
    if memo[name] ~= nil then return memo[name] end
    if self._input_set[name] then
      memo[name] = 0
      return 0
    end
    local gi = self._gate_map[name]
    if not gi then
      memo[name] = 0
      return 0
    end
    local g = self._gates[gi]
    local max_d = 0
    for _, inp in ipairs(g.inputs) do
      local d = depth(inp)
      if d > max_d then max_d = d end
    end
    local result = max_d + 1
    memo[name] = result
    return result
  end

  local max_depth = 0
  for _, oname in ipairs(self._outputs) do
    local src = self._conns[oname]
    if src then
      local d = depth(src)
      if d > max_depth then max_depth = d end
    end
  end
  -- Also check all gates in case no outputs declared
  for _, g in ipairs(self._gates) do
    local d = depth(g.name)
    if d > max_depth then max_depth = d end
  end
  return max_depth
end

-- ── D Flip-Flop ───────────────────────────────────────────────────────────────

local DFF = {}
DFF.__index = DFF

function M.d_flipflop()
  return setmetatable({ _q=0, _clk_prev=0 }, DFF)
end

-- tick(d, clk): rising edge of clk captures d
function DFF:tick(d, clk)
  if clk ~= 0 and self._clk_prev == 0 then
    -- rising edge
    self._q = d ~= 0 and 1 or 0
  end
  self._clk_prev = clk ~= 0 and 1 or 0
end

function DFF:output()
  return self._q
end

-- ── SR Latch ──────────────────────────────────────────────────────────────────

local SR = {}
SR.__index = SR

function M.sr_latch()
  return setmetatable({ _q=0 }, SR)
end

-- set(s, r): S=1,R=0 → Q=1; S=0,R=1 → Q=0; S=0,R=0 → hold; S=1,R=1 → invalid (Q→0)
function SR:set(s, r)
  if s ~= 0 and r ~= 0 then
    self._q = 0  -- invalid / forbidden state
  elseif s ~= 0 then
    self._q = 1
  elseif r ~= 0 then
    self._q = 0
  end
  -- else hold
end

function SR:output()
  return self._q
end

-- ── Boolean expression parser → circuit ───────────────────────────────────────

-- Tokenizer
local function tokenize(expr)
  local tokens = {}
  local i = 1
  while i <= #expr do
    local c = expr:sub(i,i)
    if c:match("%s") then
      i = i + 1
    elseif c == "(" then
      tokens[#tokens+1] = { kind="lparen" }
      i = i + 1
    elseif c == ")" then
      tokens[#tokens+1] = { kind="rparen" }
      i = i + 1
    else
      -- word (AND, OR, NOT, NAND, NOR, XOR, XNOR, variable)
      local j = i
      while j <= #expr and expr:sub(j,j):match("[%w_]") do j = j+1 end
      local word = expr:sub(i, j-1)
      local up = word:upper()
      if up == "AND" or up == "OR" or up == "NOT" or up == "NAND" or up == "NOR"
         or up == "XOR" or up == "XNOR" then
        tokens[#tokens+1] = { kind="op", val=up }
      else
        tokens[#tokens+1] = { kind="var", val=word }
      end
      i = j
    end
  end
  return tokens
end

-- Recursive descent parser: expr → circuit
-- Grammar (simplified, left-to-right precedence):
--   expr   = term (OR term)*
--   term   = factor (AND factor)*
--   factor = NOT factor | atom
--   atom   = var | "(" expr ")"
-- NAND/NOR/XOR/XNOR treated as binary ops at AND precedence level
function M.from_bool(expr)
  local tokens = tokenize(expr)
  local pos = 1
  local circ = M.circuit()
  local gate_seq = 0
  local vars = {}

  local function peek()
    return tokens[pos]
  end
  local function consume()
    local t = tokens[pos]
    pos = pos + 1
    return t
  end
  local function consume_kind(k)
    local t = peek()
    if t and t.kind == k then consume(); return true end
    return false
  end

  local function new_gate(gtype, inputs)
    gate_seq = gate_seq + 1
    local name = "g" .. gate_seq
    circ:gate(name, gtype, inputs)
    return name
  end

  local parse_expr  -- forward decl
  local parse_term
  local parse_factor
  local parse_atom

  parse_atom = function()
    local t = peek()
    if t and t.kind == "lparen" then
      consume()
      local node = parse_expr()
      consume_kind("rparen")
      return node
    elseif t and t.kind == "var" then
      consume()
      -- Register as input if new
      if not vars[t.val] then
        vars[t.val] = true
        circ:input(t.val)
      end
      return t.val
    elseif t and t.kind == "op" and t.val == "NOT" then
      -- NOT as prefix without parentheses around single var
      consume()
      local operand = parse_atom()
      return new_gate("NOT", {operand})
    end
    return nil
  end

  parse_factor = function()
    local t = peek()
    if t and t.kind == "op" and t.val == "NOT" then
      consume()
      local operand = parse_factor()
      return new_gate("NOT", {operand})
    end
    return parse_atom()
  end

  parse_term = function()
    local left = parse_factor()
    while true do
      local t = peek()
      if not t or t.kind ~= "op" then break end
      local op = t.val
      if op == "AND" or op == "NAND" or op == "XOR" or op == "XNOR" then
        consume()
        local right = parse_factor()
        left = new_gate(op, {left, right})
      elseif op == "NOR" then
        consume()
        local right = parse_factor()
        left = new_gate("NOR", {left, right})
      else
        break
      end
    end
    return left
  end

  parse_expr = function()
    local left = parse_term()
    while true do
      local t = peek()
      if t and t.kind == "op" and t.val == "OR" then
        consume()
        local right = parse_term()
        left = new_gate("OR", {left, right})
      else
        break
      end
    end
    return left
  end

  local output_node = parse_expr()
  circ:output("OUT")
  circ:connect(output_node, "OUT")
  return circ
end

-- ── Quine-McCluskey minimization ─────────────────────────────────────────────

-- Count 1-bits in an integer
local function popcount(x)
  local c = 0
  while x > 0 do
    c = c + (x % 2)
    x = math.floor(x / 2)
  end
  return c
end

-- Check if two implicants can be merged (differ by exactly one bit, no dash conflicts)
-- Implicants are represented as {val=int, mask=int} where mask bit=1 means "don't care"
local function can_merge(a, b)
  -- bits that differ (ignoring dashes)
  local conflict = bxor(a.mask, b.mask)  -- bits where one has dash and other doesn't
  if conflict ~= 0 then return false end
  local diff = bxor(a.val, b.val)  -- XOR on non-dash bits
  -- diff must be exactly one bit
  return diff ~= 0 and band(diff, diff-1) == 0
end

local function merge(a, b)
  local diff = bxor(a.val, b.val)
  return { val = band(a.val, bnot(diff)), mask = bor(a.mask, diff), minterms = {} }
end

-- Merge minterm sets
local function merge_minterms(a, b)
  local seen = {}
  local r = {}
  for _, v in ipairs(a) do seen[v]=true; r[#r+1]=v end
  for _, v in ipairs(b) do if not seen[v] then r[#r+1]=v end end
  return r
end

-- Convert implicant to boolean expression string
local function implicant_to_expr(imp, vars)
  local terms = {}
  local n = #vars
  for i = 1, n do
    local bit_pos = n - i  -- MSB first
    local bit_mask = 2^bit_pos
    local is_dc = band(imp.mask, bit_mask) ~= 0
    if not is_dc then
      local bit_val = math.floor(imp.val / bit_mask) % 2
      if bit_val == 1 then
        terms[#terms+1] = vars[i]
      else
        terms[#terms+1] = "NOT " .. vars[i]
      end
    end
  end
  if #terms == 0 then return "1" end
  return table.concat(terms, " AND ")
end

-- Petrick's method to find minimal cover
local function find_cover(essential, remaining_minterms, prime_imps)
  -- Build a coverage table: minterm → list of prime implicant indices
  local coverage = {}
  for _, m in ipairs(remaining_minterms) do
    coverage[m] = {}
  end
  for i, pi in ipairs(prime_imps) do
    for _, m in ipairs(pi.minterms) do
      if coverage[m] then
        coverage[m][#coverage[m]+1] = i
      end
    end
  end

  -- Greedy cover: pick PI that covers most uncovered minterms
  local covered = {}
  for _, m in ipairs(essential) do covered[m] = true end

  local selected = {}
  local uncovered = {}
  for _, m in ipairs(remaining_minterms) do
    if not covered[m] then uncovered[#uncovered+1] = m end
  end

  while #uncovered > 0 do
    local best_i, best_count = nil, 0
    for i, pi in ipairs(prime_imps) do
      local c = 0
      for _, m in ipairs(pi.minterms) do
        if not covered[m] then c = c + 1 end
      end
      if c > best_count then best_count = c; best_i = i end
    end
    if not best_i then break end
    selected[#selected+1] = best_i
    for _, m in ipairs(prime_imps[best_i].minterms) do
      covered[m] = true
    end
    local still = {}
    for _, m in ipairs(uncovered) do
      if not covered[m] then still[#still+1] = m end
    end
    uncovered = still
  end
  return selected
end

function M.simplify_bool(opts)
  local vars     = opts.vars
  local minterms = opts.minterms

  if #minterms == 0 then return "0" end

  local n = #vars
  local max_val = 2^n
  -- Check if tautology
  if #minterms == max_val then return "1" end

  -- Initialize implicants from minterms
  local implicants = {}
  for _, m in ipairs(minterms) do
    implicants[#implicants+1] = { val=m, mask=0, minterms={m}, used=false }
  end

  local prime_implicants = {}
  local all_implicants = { implicants }

  -- Iteratively merge
  while true do
    local current = all_implicants[#all_implicants]
    if #current == 0 then break end

    -- Group by popcount
    local groups = {}
    for _, imp in ipairs(current) do
      local pc = popcount(band(imp.val, bnot(imp.mask)))
      groups[pc] = groups[pc] or {}
      groups[pc][#groups[pc]+1] = imp
    end

    local next_level = {}
    local merged_any = false
    local merged_set = {}  -- set of implicant indices merged

    -- Compare adjacent groups
    for pc = 0, n-1 do
      local g1 = groups[pc]
      local g2 = groups[pc+1]
      if g1 and g2 then
        for i1, a in ipairs(g1) do
          for i2, b in ipairs(g2) do
            if can_merge(a, b) then
              local nm = merge(a, b)
              nm.minterms = merge_minterms(a.minterms, b.minterms)
              -- Deduplicate next_level
              local key = nm.val .. "," .. nm.mask
              if not merged_set[key] then
                merged_set[key] = true
                next_level[#next_level+1] = nm
              end
              a.used = true
              b.used = true
              merged_any = true
            end
          end
        end
      end
    end

    -- Collect unused implicants as prime implicants
    for _, imp in ipairs(current) do
      if not imp.used then
        prime_implicants[#prime_implicants+1] = imp
      end
    end

    if not merged_any then break end
    all_implicants[#all_implicants+1] = next_level
  end

  if #prime_implicants == 0 then
    -- All were merged at some level; the last level's items are prime
    local last = all_implicants[#all_implicants]
    for _, imp in ipairs(last) do
      prime_implicants[#prime_implicants+1] = imp
    end
  end

  -- Find essential prime implicants
  -- For each minterm, which PIs cover it?
  local minterm_set = {}
  for _, m in ipairs(minterms) do minterm_set[m] = true end

  local pi_covers = {}  -- pi_index → {minterm → bool}
  for i, pi in ipairs(prime_implicants) do
    pi_covers[i] = {}
    for _, m in ipairs(pi.minterms) do
      if minterm_set[m] then pi_covers[i][m] = true end
    end
  end

  -- For each minterm, list of covering PIs
  local mt_cover = {}
  for _, m in ipairs(minterms) do
    mt_cover[m] = {}
    for i, pi in ipairs(prime_implicants) do
      if pi_covers[i][m] then
        mt_cover[m][#mt_cover[m]+1] = i
      end
    end
  end

  local essential_pi = {}
  local essential_pi_set = {}
  local covered = {}

  for _, m in ipairs(minterms) do
    if #mt_cover[m] == 1 then
      local pi_idx = mt_cover[m][1]
      if not essential_pi_set[pi_idx] then
        essential_pi_set[pi_idx] = true
        essential_pi[#essential_pi+1] = pi_idx
        for _, cm in ipairs(prime_implicants[pi_idx].minterms) do
          covered[cm] = true
        end
      end
    end
  end

  -- Find remaining uncovered minterms
  local remaining = {}
  local essential_minterms = {}
  for _, m in ipairs(minterms) do
    if covered[m] then
      essential_minterms[#essential_minterms+1] = m
    else
      remaining[#remaining+1] = m
    end
  end

  -- Non-essential PIs
  local non_essential = {}
  for i = 1, #prime_implicants do
    if not essential_pi_set[i] then
      non_essential[#non_essential+1] = prime_implicants[i]
    end
  end

  -- Cover remaining minterms
  local extra = {}
  if #remaining > 0 then
    extra = find_cover(essential_minterms, remaining, non_essential)
    -- extra contains indices into non_essential
  end

  -- Build final expression
  local terms = {}
  for _, i in ipairs(essential_pi) do
    terms[#terms+1] = implicant_to_expr(prime_implicants[i], vars)
  end
  for _, i in ipairs(extra) do
    terms[#terms+1] = implicant_to_expr(non_essential[i], vars)
  end

  if #terms == 0 then return "0" end
  -- Wrap multi-literal products in parens when joining with OR
  local parts = {}
  for _, t in ipairs(terms) do
    if t:find(" AND ") then
      parts[#parts+1] = "(" .. t .. ")"
    else
      parts[#parts+1] = t
    end
  end
  return table.concat(parts, " OR ")
end

return M
