if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- DPLL SAT solver with unit propagation and pure literal elimination.
--
-- CNF formula: array of clauses; each clause = array of literals.
-- Literal: positive integer = variable, negative = negation.
-- Variable indices start at 1.

local M = {}
M._tier = "pure"

--:: FormulaObj = { _vars: { [string]: integer }, _clauses: { [integer]: { [integer]: integer } }, _nvars: integer }
--:: CnfFormula = { clauses: { [integer]: { [integer]: integer } }, vars: integer | nil }

-- ---------------------------------------------------------------------------
-- Internal DPLL engine
-- ---------------------------------------------------------------------------

-- Deep-copy a clauses table (array of arrays of ints).
local function copy_clauses(clauses)
  local out = {}
  for i = 1, #clauses do
    local c = clauses[i]
    local nc = {}
    for j = 1, #c do nc[j] = c[j] end
    out[i] = nc
  end
  return out
end

-- Apply an assignment (var -> bool) to clauses.
-- Returns new clause list or nil if a contradiction is found.
-- A clause with the literal true is removed.
-- A literal set false is removed from its clause.
-- An empty clause means UNSAT → return nil.
local function apply_assignment(clauses, var, val)
  local true_lit  = val and var or -var
  local false_lit = val and -var or var
  local out = {}
  for i = 1, #clauses do
    local c = clauses[i]
    local satisfied = false
    local nc = {}
    for j = 1, #c do
      local lit = c[j]
      if lit == true_lit then
        satisfied = true
        break
      elseif lit ~= false_lit then
        nc[#nc + 1] = lit
      end
    end
    if not satisfied then
      if #nc == 0 then return nil end  -- empty clause → contradiction
      out[#out + 1] = nc
    end
  end
  return out
end

-- Unit propagation: repeatedly assign unit clauses until fixpoint.
-- Modifies assignment table in place.
-- Returns updated clauses, or nil on contradiction.
local function unit_propagate(clauses, assignment)
  local changed = true
  while changed do
    changed = false
    for i = 1, #clauses do
      local c = clauses[i]
      if #c == 1 then
        local lit = c[1]
        local var = lit > 0 and lit or -lit
        local val = lit > 0
        if assignment[var] ~= nil then
          -- Already assigned; check consistency.
          if assignment[var] ~= val then return nil end
        else
          assignment[var] = val
          clauses = apply_assignment(clauses, var, val)
          if clauses == nil then return nil end
          changed = true
          break
        end
      end
    end
  end
  return clauses
end

-- Pure literal elimination: a literal is pure if it only appears with one
-- polarity across all remaining clauses. Assign it to satisfy all its clauses.
local function pure_literal_elim(clauses, assignment)
  local pos = {}  -- var -> true if seen positive
  local neg = {}  -- var -> true if seen negative
  for i = 1, #clauses do
    local c = clauses[i]
    for j = 1, #c do
      local lit = c[j]
      if lit > 0 then
        pos[lit] = true
      else
        neg[-lit] = true
      end
    end
  end
  local changed = false
  for var, _ in pairs(pos) do
    if not neg[var] and assignment[var] == nil then
      assignment[var] = true
      clauses = apply_assignment(clauses, var, true)
      if clauses == nil then return nil end
      changed = true
    end
  end
  for var, _ in pairs(neg) do
    if not pos[var] and assignment[var] == nil then
      assignment[var] = false
      clauses = apply_assignment(clauses, var, false)
      if clauses == nil then return nil end
      changed = true
    end
  end
  return clauses, changed
end

-- Choose the next unassigned variable (first literal in first clause).
local function choose_variable(clauses, nvars, assignment)
  for i = 1, #clauses do
    local c = clauses[i]
    for j = 1, #c do
      local lit = c[j]
      local var = lit > 0 and lit or -lit
      if assignment[var] == nil then
        return var
      end
    end
  end
  -- Fallback: scan all vars (handles empty formula).
  for v = 1, nvars do
    if assignment[v] == nil then return v end
  end
  return nil
end

-- Core DPLL recursion.
-- clauses: current CNF (already simplified)
-- nvars: total variable count
-- assignment: partial assignment table (var -> bool)
-- collect: if non-nil, a table to push complete assignments into (solve_all mode)
-- Returns true, assignment on first solution (solve mode).
-- In collect mode, always returns false after exhausting the search space.
local function dpll(clauses, nvars, assignment, collect)
  local collect_any = collect --[[: unknown]]
  -- Unit propagation: work on a copy of both clauses and assignment.
  local new_assignment = {}
  for k, v in pairs(assignment) do new_assignment[k] = v end
  clauses = unit_propagate(clauses, new_assignment)
  if clauses == nil then return false, nil end

  -- Pure literal elimination (loop until fixpoint).
  -- Disabled in collect mode: PLE skips branches, so it would miss solutions.
  if not collect_any then
    local changed = true
    while changed do
      clauses, changed = pure_literal_elim(clauses, new_assignment)
      if clauses == nil then return false, nil end
    end
  end

  -- Choose a variable to branch on (or nil if all assigned).
  local var = choose_variable(clauses, nvars, new_assignment)

  -- All clauses satisfied and all variables assigned?
  if #clauses == 0 and var == nil then
    if collect_any then
      local copy = {}
      for k, v in pairs(new_assignment) do copy[k] = v end
      collect_any[#collect_any + 1] = copy
      return false, nil  -- keep searching
    end
    return true, new_assignment
  end

  -- All clauses satisfied but free variables remain: enumerate them in collect mode.
  if #clauses == 0 then
    -- var is unassigned but no clauses constrain it.
    if collect_any then
      -- Branch on var to enumerate both assignments.
      local a_true = {}
      for k, v in pairs(new_assignment) do a_true[k] = v end
      a_true[var] = true
      dpll({}, nvars, a_true, collect_any)
      local a_false = {}
      for k, v in pairs(new_assignment) do a_false[k] = v end
      a_false[var] = false
      dpll({}, nvars, a_false, collect_any)
      return false, nil
    end
    -- solve mode: just pick false for remaining vars.
    for v = 1, nvars do
      if new_assignment[v] == nil then new_assignment[v] = false end
    end
    return true, new_assignment
  end

  if var == nil then
    -- No unassigned variable but clauses remain — contradiction.
    return false, nil
  end

  -- Branch var = true.
  local c_true = apply_assignment(clauses, var, true)
  if c_true ~= nil then
    local c_true_ = (c_true --[[: unknown]]) --[[:! { [integer]: { [integer]: integer } }]]
    local a_true = {}
    for k, v in pairs(new_assignment) do a_true[k] = v end
    a_true[var] = true
    local ok, result = dpll(c_true_, nvars, a_true, collect_any)
    if not collect_any and ok then return true, result end
  end

  -- Branch var = false.
  local c_false = apply_assignment(clauses, var, false)
  if c_false ~= nil then
    local c_false_ = (c_false --[[: unknown]]) --[[:! { [integer]: { [integer]: integer } }]]
    local a_false = {}
    for k, v in pairs(new_assignment) do a_false[k] = v end
    a_false[var] = false
    local ok, result = dpll(c_false_, nvars, a_false, collect_any)
    if not collect_any and ok then return true, result end
  end

  return false, nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Solve a CNF formula.
-- formula: { clauses = {{lit,...},...}, vars = n }
-- Returns { sat = true, assignment = {[var]=bool,...} } or { sat = false }.
--: (CnfFormula) -> { sat: boolean, assignment: { [integer]: boolean } | nil }
function M.solve(formula)
  local clauses = copy_clauses(formula.clauses)
  local nvars = (formula.vars or 0) --[[:! integer]]
  local ok, assignment = dpll(clauses, nvars, {}, nil)
  if ok then
    return { sat = true, assignment = assignment }
  else
    return { sat = false, assignment = nil }
  end
end

--- Enumerate all satisfying assignments.
-- Returns array of assignment tables.
--: (CnfFormula, unknown) -> { [integer]: { [integer]: boolean } }
function M.solve_all(formula, _opts)
  local clauses = copy_clauses(formula.clauses)
  local nvars = (formula.vars or 0) --[[:! integer]]
  local collect = {} --[[: unknown]]
  dpll(clauses, nvars, {}, collect)
  return collect --[[:! { [integer]: { [integer]: boolean } }]]
end

--- Count the number of satisfying assignments.
function M.count(formula, opts)
  return #M.solve_all(formula, opts)
end

-- ---------------------------------------------------------------------------
-- Formula builder
-- ---------------------------------------------------------------------------

local Formula = {}
Formula.__index = Formula

--- Create a new formula builder.
function M.formula()
  return setmetatable({
    _vars = {},    -- name -> literal id
    _clauses = {},
    _nvars = 0,
  }, Formula)
end

--- Declare a named variable; returns its positive literal id.
function Formula:var(name)
  local self_ = self --[[:! FormulaObj]]
  if self_._vars[name] then return self_._vars[name] end
  self_._nvars = self_._nvars + 1
  local id = self_._nvars
  self_._vars[name] = id
  return id
end

--- Add a clause (vararg literals).
function Formula:clause(...)
  local self_ = self --[[:! FormulaObj]]
  local lits = { ... }
  self_._clauses[#self_._clauses + 1] = lits --[[: unknown]]
end

--- Solve and return { sat, assignment? } with named variables.
function Formula:solve()
  local self_ = self --[[:! FormulaObj]]
  local raw = M.solve({ clauses = self_._clauses, vars = self_._nvars })
  if not raw.sat then return { sat = false, assignment = nil } end
  local named = {} --[[: unknown]]
  for name, id in pairs(self_._vars) do
    named[name] = (raw.assignment --[[: unknown]])[id]
  end
  return { sat = true, assignment = named }
end

--- Enumerate all solutions with named variables.
function Formula:solve_all()
  local self_ = self --[[:! FormulaObj]]
  local raws = M.solve_all({ clauses = self_._clauses, vars = self_._nvars }, nil)
  local results = {}
  for i = 1, #raws do
    local named = {} --[[: unknown]]
    for name, id in pairs(self_._vars) do
      named[name] = raws[i][id]
    end
    results[i] = named
  end
  return results
end

-- ---------------------------------------------------------------------------
-- Encodings
-- ---------------------------------------------------------------------------

M.encodings = {}

--- At-least-one: at least one of vars is true.
-- Returns array of clauses to add.
function M.encodings.at_least_one(vars)
  local clause = {}
  for i = 1, #vars do clause[i] = vars[i] end
  return { clause }
end

--- At-most-one (pairwise): at most one of vars is true.
-- Returns array of clauses (pairwise ¬x ∨ ¬y for all i<j).
function M.encodings.at_most_one(vars)
  local clauses = {}
  for i = 1, #vars do
    for j = i + 1, #vars do
      clauses[#clauses + 1] = { -vars[i], -vars[j] }
    end
  end
  return clauses
end

--- Exactly-one: exactly one of vars is true.
-- Returns combined at-least-one + at-most-one clauses.
local enc_any = M.encodings --[[: unknown]]
function M.encodings.exactly_one(vars)
  local clauses = enc_any.at_least_one(vars)
  local amo = enc_any.at_most_one(vars)
  for i = 1, #amo do clauses[#clauses + 1] = amo[i] end
  return clauses
end

return M
