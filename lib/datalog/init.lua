if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}

--:: Database = { _facts: { [string]: { [string]: { [integer]: string } } }, _rules: { [string]: { [integer]: unknown } }, _dirty: boolean, _derived: { [string]: { [string]: { [integer]: string } } } }

local concat = table.concat

--- Hash a tuple into a string key for dedup.
--: (tuple: { [integer]: string }) -> string
local function tuple_key(tuple)
  return concat(tuple, "\0")
end

--- Check if a string is a variable name (starts with uppercase letter).
--: (s: string) -> boolean
local function is_var(s)
  local b = s:byte(1) or 0
  return (b >= 65 and b <= 90) and true or false -- A-Z
end

local DB = {} --[[: any]]
DB.__index = DB

--: () -> Database
function M.new()
  local self = setmetatable({
    _facts = {},    -- predicate -> { [tuple_key] = tuple }
    _rules = {},    -- predicate -> { {head_vars, body, guard} }
    _dirty = true,  -- whether derived facts need recomputation
    _derived = {},  -- predicate -> { [tuple_key] = tuple } (derived facts)
  }, DB) --[[: any]]
  return self --[[:! Database]]
end

--- Assert a single fact.
--: (self: Database, predicate: string, ...string) -> ()
function DB:assert(predicate, ...)
  local tuple = { ... }
  local facts = self._facts[predicate]
  if not facts then
    facts = {}
    self._facts[predicate] = facts
  end
  local key = tuple_key(tuple)
  if not facts[key] then
    facts[key] = tuple
    self._dirty = true
  end
end

--- Assert multiple facts at once.
--: (self: Database, fact_list: { [integer]: { [integer]: string } }) -> ()
function DB:assert_all(fact_list)
  local self_ = self --[[: any]]
  for i = 1, #fact_list do
    local f = fact_list[i]
    self_:assert(f[1], unpack(f, 2))
  end
end

--- Retract a single fact.
--: (self: Database, predicate: string, ...string) -> ()
function DB:retract(predicate, ...)
  local facts = self._facts[predicate]
  if not facts then return end
  local key = tuple_key({ ... })
  if facts[key] then
    facts[key] = nil
    self._dirty = true
  end
end

--- Define a rule: head(head_vars) :- body_goals [, guard].
--: (self: Database, predicate: string, head_vars: {string}, body: {{string}}, guard: (((bindings: {[string]: string}) -> boolean) | nil)) -> ()
function DB:rule(predicate, head_vars, body, guard)
  local rules = self._rules[predicate]
  if not rules then
    rules = {}
    self._rules[predicate] = rules
  end
  -- Collect all variable names used in the rule (head + body).
  local vars = {}
  for i = 1, #head_vars do
    vars[head_vars[i]] = true
  end
  for i = 1, #body do
    local goal = body[i]
    for j = 2, #goal do
      local term = goal[j]
      if is_var(term) then
        vars[term] = true
      end
    end
  end
  rules[#rules + 1] = { head_vars = head_vars, body = body, guard = guard, vars = vars }
  self._dirty = true
end

--- Match a single goal against a fact, extending bindings.
--- Returns new bindings table if match, nil otherwise.
--: (goal: {string}, fact: {string}, bindings: {[string]: string}, rule_vars: {[string]: true}) -> ({[string]: string} | nil)
local function match_goal(goal, fact, bindings, rule_vars)
  -- goal[1] is predicate, already matched by caller
  if #goal - 1 ~= #fact then return nil end
  local new_bindings = nil -- lazy copy
  for i = 2, #goal do
    local term = goal[i]
    local val = fact[i - 1]
    if rule_vars[term] then
      -- It's a variable
      local bound = (new_bindings and new_bindings[term]) or bindings[term]
      if bound then
        -- Already bound, must match
        if bound ~= val then return nil end
      else
        -- Bind it
        if not new_bindings then
          new_bindings = {}
          for k, v in pairs(bindings) do new_bindings[k] = v end
        end
        new_bindings[term] = val
      end
    elseif term == "?" then
      -- Wildcard, matches anything
    else
      -- Constant, must match exactly
      if term ~= val then return nil end
    end
  end
  return new_bindings or bindings
end

--- Get all facts for a predicate (base + derived).
--: (self: Database, predicate: string) -> { [string]: {string} }
local function all_facts(self, predicate)
  local base = self._facts[predicate]
  local derived = self._derived[predicate]
  if not base and not derived then return {} end
  if not derived then return base end
  if not base then return derived end
  -- Merge
  local merged = {}
  for k, v in pairs(base) do merged[k] = v end
  for k, v in pairs(derived) do merged[k] = v end
  return merged
end

--- Evaluate all body goals against current facts, producing bindings.
--: (self: Database, body: {{string}}, rule_vars: {[string]: true}) -> {{[string]: string}}
local function evaluate_body(self, body, rule_vars)
  -- Start with a single empty binding
  --: {{[string]: string}}
  local bindings_list = { {} }

  for i = 1, #body do
    local goal = body[i]
    local predicate = goal[1]
    local facts = all_facts(self, predicate)
    local new_bindings_list = {}
    local n = 0

    for j = 1, #bindings_list do
      local bindings = bindings_list[j]
      for _, fact in pairs(facts) do
        local extended = match_goal(goal, fact, bindings, rule_vars)
        if extended then
          n = n + 1
          new_bindings_list[n] = extended
        end
      end
    end

    bindings_list = new_bindings_list
    if n == 0 then return bindings_list end
  end

  return bindings_list
end

--- Run naive bottom-up evaluation to fixpoint.
--: (self: Database) -> ()
local function evaluate(self)
  if not self._dirty then return end

  -- Clear derived facts
  self._derived = {}

  local changed = true
  while changed do
    changed = false
    for predicate, rules in pairs(self._rules) do
      for r = 1, #rules do
        local rule = rules[r]
        local bindings_list = evaluate_body(self, rule.body, rule.vars)

        for i = 1, #bindings_list do
          local bindings = bindings_list[i]

          -- Apply guard
          if rule.guard and not rule.guard(bindings) then
            goto continue
          end

          -- Project to head variables
          local tuple = {}
          for j = 1, #rule.head_vars do
            tuple[j] = bindings[rule.head_vars[j]]
          end

          local key = tuple_key(tuple)

          -- Check if already known (base or derived)
          local base = self._facts[predicate]
          if base and base[key] then goto continue end

          local derived = self._derived[predicate]
          if not derived then
            derived = {}
            self._derived[predicate] = derived
          end
          if derived[key] then goto continue end

          derived[key] = tuple
          changed = true

          ::continue::
        end
      end
    end
  end

  self._dirty = false
end

--- Query with positional arguments. "?" is wildcard.
--: (self: Database, predicate: string, ...string) -> {{string}}
function DB:query(predicate, ...)
  evaluate(self)
  local args = { ... }
  local facts = all_facts(self, predicate)
  local results = {}
  local n = 0
  for _, fact in pairs(facts) do
    local match = true
    for i = 1, #args do
      if args[i] ~= "?" and args[i] ~= fact[i] then
        match = false
        break
      end
    end
    if match then
      n = n + 1
      results[n] = fact
    end
  end
  return results
end

--- Query with named variables, returns binding maps.
--: (self: Database, predicate: string, vars: {string}, fixed: ({[string]: string} | nil)) -> {{[string]: string}}
function DB:query_bindings(predicate, vars, fixed)
  evaluate(self)
  local facts = all_facts(self, predicate)
  local results = {}
  local n = 0
  for _, fact in pairs(facts) do
    local bindings = {}
    local match = true
    for i = 1, #vars do
      local var = vars[i]
      local val = fact[i]
      if fixed and fixed[var] then
        if fixed[var] ~= val then
          match = false
          break
        end
      end
      bindings[var] = val
    end
    if match then
      n = n + 1
      results[n] = bindings
    end
  end
  return results
end

--- Return all base facts for a predicate.
--: (self: Database, predicate: string) -> {{string}}
function DB:facts(predicate)
  local facts = self._facts[predicate]
  if not facts then return {} end
  local results = {}
  local n = 0
  for _, fact in pairs(facts) do
    n = n + 1
    results[n] = fact
  end
  return results
end

--- Return all known predicate names (from facts and rules).
--: (self: Database) -> {string}
function DB:predicates()
  local seen = {}
  local results = {}
  local n = 0
  for pred in pairs(self._facts) do
    if not seen[pred] then
      seen[pred] = true
      n = n + 1
      results[n] = pred
    end
  end
  for pred in pairs(self._rules) do
    if not seen[pred] then
      seen[pred] = true
      n = n + 1
      results[n] = pred
    end
  end
  return results
end

--- Count base facts for a predicate.
--: (self: Database, predicate: string) -> number
function DB:count(predicate)
  local facts = self._facts[predicate]
  if not facts then return 0 end
  local c = 0
  for _ in pairs(facts) do c = c + 1 end
  return c
end

return M
