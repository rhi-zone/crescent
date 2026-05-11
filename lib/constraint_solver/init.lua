if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Constraint Satisfaction Problem (CSP) solver
-- Backtracking search with AC-3 arc consistency, MRV, LCV, and forward checking.

local M = {}
M._tier = "pure"

-- ========================
-- INTERNAL HELPERS
-- ========================

-- Deep-copy a domains table (variable -> array of values)
local function copy_domains(domains)
  local d = {}
  for k, v in pairs(domains) do
    local arr = {}
    for i = 1, #v do arr[i] = v[i] end
    d[k] = arr
  end
  return d
end

-- Remove a value from an array in-place; returns true if found and removed
local function remove_value(arr, val)
  for i = 1, #arr do
    if arr[i] == val then
      table.remove(arr, i)
      return true
    end
  end
  return false
end

-- Check whether value v satisfies all unary constraints on variable var
local function check_unary(problem, var, v)
  local unary = problem._unary[var]
  if unary then
    for _, fn in ipairs(unary) do
      if not fn(v) then return false end
    end
  end
  return true
end

-- Check whether assignment of var1=v1, var2=v2 satisfies all binary constraints between them
--: (CspProblem, string, unknown, string, unknown) -> boolean
local function check_binary(problem, var1, v1, var2, v2)
  local key = var1 .. "\0" .. var2
  local cs = problem._constraints[key]
  if cs then
    for _, fn in ipairs(cs) do
      if not fn(v1, v2) then return false end
    end
  end
  -- Also check reverse direction
  local rkey = var2 .. "\0" .. var1
  local rcs = problem._constraints[rkey]
  if rcs then
    for _, fn in ipairs(rcs) do
      if not fn(v2, v1) then return false end
    end
  end
  return true
end

-- Get all neighbors of a variable (variables that share a binary constraint)
--: (CspProblem, string) -> { [integer]: string }
local function get_neighbors(problem, var)
  local seen = {}
  local result = {}
  -- Forward arcs
  for key, _ in pairs(problem._constraints) do
    local sep = key:find("\0")
    if sep then
      local v1 = key:sub(1, sep - 1)
      local v2 = key:sub(sep + 1)
      if v1 == var and not seen[v2] then
        seen[v2] = true
        result[#result + 1] = v2
      elseif v2 == var and not seen[v1] then
        seen[v1] = true
        result[#result + 1] = v1
      end
    end
  end
  return result
end

-- ========================
-- AC-3 ARC CONSISTENCY
-- ========================

-- Revise: remove values from domain of xi that have no support in xj.
-- Returns true if domain was changed.
local function revise(problem, domains, xi, xj)
  local revised = false
  local di = domains[xi]
  local i = 1
  while i <= #di do
    local vx = di[i]
    -- Check if there exists some value vy in domain of xj that satisfies constraint xi=vx, xj=vy
    local has_support = false
    local dj = domains[xj]
    for _, vy in ipairs(dj) do
      if check_binary(problem, xi, vx, xj, vy) then
        has_support = true
        break
      end
    end
    if not has_support then
      table.remove(di, i)
      revised = true
      -- don't increment i since we removed element
    else
      i = i + 1
    end
  end
  return revised
end

-- Run AC-3 on the given domains (modifies in place).
-- Returns true if arc-consistent (no domain empty), false if domain wipeout detected.
local function ac3(problem, domains)
  -- Initialize queue with all arcs (xi, xj) for each binary constraint
  local queue = {} --: { [integer]: { [integer]: string } }
  for key, _ in pairs(problem._constraints) do
    local sep = key:find("\0")
    if sep then
      local v1 = key:sub(1, sep - 1)
      local v2 = key:sub(sep + 1)
      queue[#queue + 1] = { v1, v2 }
      queue[#queue + 1] = { v2, v1 }
    end
  end

  local head = 1
  while head <= #queue do
    local arc = queue[head]
    head = head + 1
    local xi = arc[1] --[[:! string]]
    local xj = arc[2] --[[:! string]]

    if domains[xi] and domains[xj] then
      if revise(problem, domains, xi, xj) then
        if #domains[xi] == 0 then
          return false  -- domain wipeout
        end
        -- Re-add all arcs (xk, xi) for neighbors xk of xi (excluding xj)
        local neighbors = get_neighbors(problem, xi)
        for _, xk in ipairs(neighbors) do
          if xk ~= xj then
            queue[#queue + 1] = { xk, xi }
          end
        end
      end
    end
  end
  return true
end

-- ========================
-- MRV + LCV HEURISTICS
-- ========================

-- Select the unassigned variable with smallest remaining domain (MRV).
-- Ties broken by degree (most constraints).
local function select_variable(problem, assignment, domains)
  local best = nil
  local best_size = math.huge
  local best_degree = -1

  for _, var in ipairs(problem._vars) do
    if assignment[var] == nil then
      local size = #domains[var]
      local degree = 0
      for _, nb in ipairs(get_neighbors(problem, var)) do
        if assignment[nb] == nil then
          degree = degree + 1
        end
      end
      if size < best_size or (size == best_size and degree > best_degree) then
        best = var
        best_size = size
        best_degree = degree
      end
    end
  end
  return best
end

-- Order values by LCV: least constraining value first.
-- Counts how many values in neighbors' domains would be eliminated by assigning var=val.
local function order_values(problem, var, domains, assignment)
  local vals = {}
  for _, v in ipairs(domains[var]) do
    vals[#vals + 1] = v
  end

  -- Count eliminations for each value
  local elim = {}
  for _, val in ipairs(vals) do
    local count = 0
    for _, nb in ipairs(get_neighbors(problem, var)) do
      if assignment[nb] == nil then
        for _, nbval in ipairs(domains[nb]) do
          if not check_binary(problem, var, val, nb, nbval) then
            count = count + 1
          end
        end
      end
    end
    elim[val] = count
  end

  table.sort(vals, function(a, b) return elim[a] < elim[b] end)
  return vals
end

-- ========================
-- FORWARD CHECKING
-- ========================

-- After assigning var=val, prune domains of unassigned neighbors.
-- Returns modified domains (copy), or nil if any domain becomes empty.
local function forward_check(problem, var, val, domains, assignment)
  local new_domains = copy_domains(domains)
  for _, nb in ipairs(get_neighbors(problem, var)) do
    if assignment[nb] == nil then
      local d = new_domains[nb]
      local i = 1
      while i <= #d do
        if not check_binary(problem, var, val, nb, d[i]) then
          table.remove(d, i)
        else
          i = i + 1
        end
      end
      if #d == 0 then
        return nil  -- domain wipeout
      end
    end
  end
  return new_domains
end

-- ========================
-- BACKTRACKING SEARCH
-- ========================

local function backtrack(problem, assignment, domains, solutions, limit)
  -- Check if all variables assigned
  if #assignment._keys == #problem._vars then
    local sol = {}
    for k, v in pairs(assignment) do
      if k ~= "_keys" then sol[k] = v end
    end
    solutions[#solutions + 1] = sol
    return limit and #solutions >= limit
  end

  local var = select_variable(problem, assignment, domains)
  if var == nil then return false end

  local ordered_vals = order_values(problem, var, domains, assignment)

  for _, val in ipairs(ordered_vals) do
    -- Check unary constraints
    if check_unary(problem, var, val) then
      -- Check binary constraints with already-assigned neighbors
      local consistent = true
      for _, nb in ipairs(get_neighbors(problem, var)) do
        if assignment[nb] ~= nil then
          if not check_binary(problem, var, val, nb, assignment[nb]) then
            consistent = false
            break
          end
        end
      end

      if consistent then
        -- Assign
        assignment[var] = val
        assignment._keys[#assignment._keys + 1] = var

        -- Forward check
        local new_domains = forward_check(problem, var, val, domains, assignment)

        if new_domains then
          local done = backtrack(problem, assignment, new_domains, solutions, limit)
          if done then return true end
        end

        -- Unassign
        assignment[var] = nil
        assignment._keys[#assignment._keys] = nil
      end
    end
  end

  return false
end

-- ========================
-- PROBLEM OBJECT
-- ========================

--:: CspFn = (...unknown) -> boolean
--:: CspProblem = { _vars: { [integer]: string }, _domain: { [string]: { [integer]: unknown } }, _constraints: { [string]: { [integer]: CspFn } }, _unary: { [string]: { [integer]: CspFn } }, _ternary: { [integer]: { [integer]: unknown } } }

local Problem = {}
Problem.__index = Problem

function Problem:variable(name, domain)
  local self_ = self --[[:! CspProblem]]
  if self_._domain[name] then
    return nil, "variable already defined: " .. name
  end
  self_._vars[#self_._vars + 1] = name
  local d = {}
  for i = 1, #domain do d[i] = domain[i] end
  self_._domain[name] = d
  self_._unary[name] = {}
  return self
end

-- Add binary constraint fn(v1, v2) -> bool between var1 and var2
function Problem:constraint(var1, var2, fn)
  local key = var1 .. "\0" .. var2
  if not self._constraints[key] then
    self._constraints[key] = {}
  end
  self._constraints[key][#self._constraints[key] + 1] = fn
  return self
end

-- Add unary constraint fn(v) -> bool for a single variable
function Problem:unary(var, fn)
  if not self._unary[var] then
    self._unary[var] = {}
  end
  self._unary[var][#self._unary[var] + 1] = fn
  return self
end

function Problem:not_equal(v1, v2)
  return self:constraint(v1, v2, function(a, b) return a ~= b end)
end

function Problem:less_than(v1, v2)
  return self:constraint(v1, v2, function(a, b) return a < b end)
end

function Problem:greater_than(v1, v2)
  return self:constraint(v1, v2, function(a, b) return a > b end)
end

function Problem:equals(v1, v2)
  return self:constraint(v1, v2, function(a, b) return a == b end)
end

-- N-ary all-different: decomposed into pairwise not_equal
function Problem:all_different(vars)
  for i = 1, #vars do
    for j = i + 1, #vars do
      self:not_equal(vars[i], vars[j])
    end
  end
  return self
end

-- Arithmetic constraint on 3 variables: fn(a,b,c) -> bool
function Problem:arithmetic(va, vb, vc, fn)
  -- Decompose into a ternary via auxiliary variable approach:
  -- We encode this as two nested binary constraints is not directly possible,
  -- so we store it as two binary arcs that both reference vc.
  -- The cleanest approach: add a constraint on (va,vb) that checks all vc values.
  -- But that requires knowing vc's domain. Instead we store a "ternary" constraint
  -- handled specially. We use a list of ternary constraints.
  self._ternary[#self._ternary + 1] = { va, vb, vc, fn }
  return self
end

-- Check ternary constraints for a proposed assignment (partial or full)
local function check_ternary(problem, assignment)
  for _, t in ipairs(problem._ternary) do
    local va, vb, vc, fn = t[1], t[2], t[3], t[4]
    local a, b, c = assignment[va], assignment[vb], assignment[vc]
    if a ~= nil and b ~= nil and c ~= nil then
      if not fn(a, b, c) then return false end
    end
  end
  return true
end

-- Wrap backtrack to also check ternary constraints
local function backtrack_with_ternary(problem, assignment, domains, solutions, limit)
  -- Check if all variables assigned
  if #assignment._keys == #problem._vars then
    if check_ternary(problem, assignment) then
      local sol = {}
      for k, v in pairs(assignment) do
        if k ~= "_keys" then sol[k] = v end
      end
      solutions[#solutions + 1] = sol
    end
    return limit and #solutions >= limit
  end

  local var = select_variable(problem, assignment, domains)
  if var == nil then return false end

  local ordered_vals = order_values(problem, var, domains, assignment)

  for _, val in ipairs(ordered_vals) do
    if check_unary(problem, var, val) then
      local consistent = true
      for _, nb in ipairs(get_neighbors(problem, var)) do
        if assignment[nb] ~= nil then
          if not check_binary(problem, var, val, nb, assignment[nb]) then
            consistent = false
            break
          end
        end
      end

      if consistent then
        assignment[var] = val
        assignment._keys[#assignment._keys + 1] = var

        -- Check ternary constraints with current partial assignment
        if check_ternary(problem, assignment) then
          local new_domains = forward_check(problem, var, val, domains, assignment)
          if new_domains then
            local done = backtrack_with_ternary(problem, assignment, new_domains, solutions, limit)
            if done then return true end
          end
        end

        assignment[var] = nil
        assignment._keys[#assignment._keys] = nil
      end
    end
  end

  return false
end

function Problem:solve(opts)
  local self_ = self --[[:! CspProblem]]
  opts = opts or {}

  -- Apply unary constraints to reduce domains upfront
  local domains = copy_domains(self_._domain)
  for var, unary_fns in pairs(self_._unary) do
    if #unary_fns > 0 then
      local d = domains[var]
      local i = 1
      while i <= #d do
        local ok = true
        for _, fn in ipairs(unary_fns) do
          if not fn(d[i]) then ok = false; break end
        end
        if not ok then table.remove(d, i) else i = i + 1 end
      end
    end
  end

  -- AC-3 preprocessing
  local consistent = ac3(self_, domains)
  if not consistent then return nil end

  local solutions = {}
  local assignment = { _keys = {} }

  local use_ternary = #self_._ternary > 0
  if use_ternary then
    backtrack_with_ternary(self_, assignment, domains, solutions, 1)
  else
    backtrack(self_, assignment, domains, solutions, 1)
  end

  return solutions[1]
end

function Problem:solve_all(opts)
  local self_ = self --[[:! CspProblem]]
  opts = opts or {}
  local limit = opts.limit

  -- Apply unary constraints to reduce domains upfront
  local domains = copy_domains(self_._domain)
  for var, unary_fns in pairs(self_._unary) do
    if #unary_fns > 0 then
      local d = domains[var]
      local i = 1
      while i <= #d do
        local ok = true
        for _, fn in ipairs(unary_fns) do
          if not fn(d[i]) then ok = false; break end
        end
        if not ok then table.remove(d, i) else i = i + 1 end
      end
    end
  end

  -- AC-3 preprocessing
  local consistent = ac3(self_, domains)
  if not consistent then return {} end

  local solutions = {}
  local assignment = { _keys = {} }

  local use_ternary = #self_._ternary > 0
  if use_ternary then
    backtrack_with_ternary(self_, assignment, domains, solutions, limit)
  else
    backtrack(self_, assignment, domains, solutions, limit)
  end

  return solutions
end

-- ========================
-- MODULE ENTRY POINT
-- ========================

function M.problem()
  return setmetatable({
    _vars = {},
    _domain = {},
    _constraints = {},
    _unary = {},
    _ternary = {},
  }, Problem)
end

return M
