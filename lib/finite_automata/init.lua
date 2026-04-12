if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Convert a string input to an array of single-character symbols.
-- If input is already a table, return it unchanged.
local function to_symbols(input)
  if type(input) == "table" then return input end
  local syms = {}
  for i = 1, #input do
    syms[i] = input:sub(i, i)
  end
  return syms
end

-- Shallow-copy a set table {key=true, ...}
local function set_copy(s)
  local t = {}
  for k in pairs(s) do t[k] = true end
  return t
end

-- Sorted keys of a table (for stable canonical keys)
local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks+1] = k end
  table.sort(ks)
  return ks
end

-- Canonical string key for a set of state names
local function set_key(set)
  local ks = sorted_keys(set)
  return table.concat(ks, "\0")
end

-- ---------------------------------------------------------------------------
-- DFA
-- ---------------------------------------------------------------------------

local DFA = {}
DFA.__index = DFA

-- dfa:run(input) → boolean
function DFA:run(input)
  local syms = to_symbols(input)
  local state = self.initial
  local trans = self.transitions
  for _, sym in ipairs(syms) do
    local row = trans[state]
    if not row then return false end
    local next = row[sym]
    if not next then return false end
    state = next
  end
  return self.accepting_set[state] == true
end

-- dfa:trace(input) → trace_array, accepted_bool
function DFA:trace(input)
  local syms = to_symbols(input)
  local state = self.initial
  local trans = self.transitions
  local trace = {state}
  for _, sym in ipairs(syms) do
    local row = trans[state]
    if not row then
      -- dead state — pad trace with nil to signal rejection
      return trace, false
    end
    local next = row[sym]
    if not next then
      return trace, false
    end
    state = next
    trace[#trace+1] = state
  end
  return trace, self.accepting_set[state] == true
end

-- dfa:minimize() → DFA  (Hopcroft's algorithm)
function DFA:minimize()
  local states = self.states
  local alphabet = self.alphabet
  local trans = self.transitions
  local acc = self.accepting_set

  -- Complete the DFA: add a dead state if any transition is missing
  local DEAD = "\0dead"
  local dead_needed = false
  local completed = {}  -- completed[state][sym] = next_state
  for _, s in ipairs(states) do
    completed[s] = {}
    for _, sym in ipairs(alphabet) do
      local row = trans[s]
      local nxt = row and row[sym]
      if nxt then
        completed[s][sym] = nxt
      else
        completed[s][sym] = DEAD
        dead_needed = true
      end
    end
  end
  if dead_needed then
    completed[DEAD] = {}
    for _, sym in ipairs(alphabet) do
      completed[DEAD][sym] = DEAD
    end
  end

  -- Full state list (possibly including dead)
  local all_states = {}
  for _, s in ipairs(states) do all_states[#all_states+1] = s end
  if dead_needed then all_states[#all_states+1] = DEAD end

  -- Initial partition: accepting vs non-accepting
  local part_accept = {}
  local part_nonaccept = {}
  for _, s in ipairs(all_states) do
    if acc[s] then
      part_accept[s] = true
    else
      part_nonaccept[s] = true
    end
  end

  -- partition is a list of sets; state_to_part[s] = index into partition
  local partition = {}
  local state_to_part = {}

  local function add_part(set)
    if next(set) == nil then return end
    local idx = #partition + 1
    partition[idx] = set
    for s in pairs(set) do state_to_part[s] = idx end
  end

  add_part(part_accept)
  add_part(part_nonaccept)

  -- Hopcroft worklist
  local worklist = {}
  for i = 1, #partition do worklist[i] = i end

  local function refine(part_idx)
    local group = partition[part_idx]
    for _, sym in ipairs(alphabet) do
      -- Find all states that transition INTO `group` via `sym`
      local splitter = {}
      for s in pairs(group) do splitter[s] = true end

      -- For each existing partition group, split by whether it transitions into splitter
      local new_partition = {}
      local changed = false
      for i, grp in ipairs(partition) do
        local inside = {}
        local outside = {}
        for s in pairs(grp) do
          local nxt = completed[s][sym]
          if splitter[nxt] then
            inside[s] = true
          else
            outside[s] = true
          end
        end
        if next(inside) and next(outside) then
          changed = true
          -- replace grp with inside; add outside as new
          partition[i] = inside
          for s in pairs(inside) do state_to_part[s] = i end
          local new_idx = #partition + 1
          partition[new_idx] = outside
          for s in pairs(outside) do state_to_part[s] = new_idx end
          -- add both to worklist
          new_partition[#new_partition+1] = i
          new_partition[#new_partition+1] = new_idx
        end
      end
      if changed then
        for _, ni in ipairs(new_partition) do
          worklist[#worklist+1] = ni
        end
      end
    end
  end

  local i = 1
  while i <= #worklist do
    local pidx = worklist[i]
    i = i + 1
    if partition[pidx] then  -- may have been split
      refine(pidx)
    end
  end

  -- Build minimized DFA: one representative state per partition group
  -- Representative = lexicographically first state name in each group
  local rep = {}  -- partition index → representative state name
  for idx, grp in ipairs(partition) do
    local ks = sorted_keys(grp)
    rep[idx] = ks[1]
  end

  -- Compute new states, initial, accepting, transitions
  local new_states_set = {}
  for _, r in pairs(rep) do new_states_set[r] = true end
  -- Remove dead state representative if it's the dead state itself
  if dead_needed then
    local dead_rep = rep[state_to_part[DEAD]]
    new_states_set[dead_rep] = nil
  end

  local new_states = sorted_keys(new_states_set)
  local new_initial = rep[state_to_part[self.initial]]
  local new_accepting = {}
  local new_accepting_set = {}
  for s in pairs(new_states_set) do
    if acc[s] then
      new_accepting[#new_accepting+1] = s
      new_accepting_set[s] = true
    end
  end

  local new_trans = {}
  for s in pairs(new_states_set) do
    new_trans[s] = {}
    for _, sym in ipairs(alphabet) do
      local nxt_raw = completed[s][sym]
      local nxt_rep = rep[state_to_part[nxt_raw]]
      -- Only include if not pointing to dead state representative
      if dead_needed then
        local dead_rep = rep[state_to_part[DEAD]]
        if nxt_rep ~= dead_rep then
          new_trans[s][sym] = nxt_rep
        end
      else
        new_trans[s][sym] = nxt_rep
      end
    end
  end

  return M.dfa({
    states = new_states,
    alphabet = self.alphabet,
    initial = new_initial,
    accepting = new_accepting,
    transitions = new_trans,
  })
end

-- dfa:enumerate(max_length) → array of accepted symbol-arrays
function DFA:enumerate(max_length)
  local results = {}
  local alphabet = self.alphabet
  local trans = self.transitions
  local acc = self.accepting_set

  -- BFS over (state, path)
  local queue = {{state = self.initial, path = {}}}
  local head = 1
  while head <= #queue do
    local item = queue[head]
    head = head + 1
    local state = item.state
    local path = item.path
    if acc[state] then
      results[#results+1] = path
    end
    if #path < max_length then
      for _, sym in ipairs(alphabet) do
        local row = trans[state]
        local nxt = row and row[sym]
        if nxt then
          local new_path = {}
          for j = 1, #path do new_path[j] = path[j] end
          new_path[#new_path+1] = sym
          queue[#queue+1] = {state = nxt, path = new_path}
        end
      end
    end
  end
  return results
end

-- ---------------------------------------------------------------------------
-- NFA
-- ---------------------------------------------------------------------------

local NFA = {}
NFA.__index = NFA

-- Compute epsilon closure of a set of states (set = {state=true,...})
local function epsilon_closure(states_set, transitions)
  local closure = set_copy(states_set)
  local stack = sorted_keys(states_set)
  local si = 1
  while si <= #stack do
    local s = stack[si]
    si = si + 1
    local row = transitions[s]
    if row then
      local eps = row[""]
      if eps then
        for _, t in ipairs(eps) do
          if not closure[t] then
            closure[t] = true
            stack[#stack+1] = t
          end
        end
      end
    end
  end
  return closure
end

-- nfa:run(input) → boolean
function NFA:run(input)
  local syms = to_symbols(input)
  local trans = self.transitions
  local current = epsilon_closure({[self.initial] = true}, trans)
  for _, sym in ipairs(syms) do
    local next_set = {}
    for s in pairs(current) do
      local row = trans[s]
      if row then
        local targets = row[sym]
        if targets then
          for _, t in ipairs(targets) do
            next_set[t] = true
          end
        end
      end
    end
    current = epsilon_closure(next_set, trans)
  end
  for s in pairs(current) do
    if self.accepting_set[s] then return true end
  end
  return false
end

-- nfa:to_dfa() → DFA  (subset construction)
function NFA:to_dfa()
  local trans = self.transitions
  local alphabet = self.alphabet
  local acc = self.accepting_set

  -- DFA states are sets of NFA states; canonical key → set
  local initial_set = epsilon_closure({[self.initial] = true}, trans)
  local initial_key = set_key(initial_set)

  -- map from canonical key → dfa state name (we'll use the key itself or an index)
  -- For readability, name DFA states as "{q0,q1,...}"
  local function set_name(set)
    local ks = sorted_keys(set)
    return "{" .. table.concat(ks, ",") .. "}"
  end

  local dfa_states = {}          -- ordered list of canonical keys
  local key_to_name = {}         -- key → friendly name string
  local key_to_set = {}          -- key → NFA state set
  local worklist = {initial_key}
  local wi = 1
  key_to_name[initial_key] = set_name(initial_set)
  key_to_set[initial_key] = initial_set
  dfa_states[#dfa_states+1] = initial_key

  local visited = {[initial_key] = true}

  local dfa_trans_by_key = {}  -- key → {sym → next_key}

  while wi <= #worklist do
    local key = worklist[wi]
    wi = wi + 1
    local set = key_to_set[key]
    dfa_trans_by_key[key] = {}
    for _, sym in ipairs(alphabet) do
      -- Move: union of transitions from each state in set on sym
      local moved = {}
      for s in pairs(set) do
        local row = trans[s]
        if row then
          local targets = row[sym]
          if targets then
            for _, t in ipairs(targets) do
              moved[t] = true
            end
          end
        end
      end
      -- Epsilon closure of moved
      local next_set = epsilon_closure(moved, trans)
      if next(next_set) then
        local next_key = set_key(next_set)
        dfa_trans_by_key[key][sym] = next_key
        if not visited[next_key] then
          visited[next_key] = true
          key_to_name[next_key] = set_name(next_set)
          key_to_set[next_key] = next_set
          dfa_states[#dfa_states+1] = next_key
          worklist[#worklist+1] = next_key
        end
      end
    end
  end

  -- Build final DFA tables
  local states = {}
  for _, k in ipairs(dfa_states) do
    states[#states+1] = key_to_name[k]
  end

  local accepting = {}
  local accepting_set = {}
  for _, k in ipairs(dfa_states) do
    local set = key_to_set[k]
    for s in pairs(set) do
      if acc[s] then
        local name = key_to_name[k]
        if not accepting_set[name] then
          accepting_set[name] = true
          accepting[#accepting+1] = name
        end
        break
      end
    end
  end

  local transitions = {}
  for _, k in ipairs(dfa_states) do
    local name = key_to_name[k]
    transitions[name] = {}
    for sym, nk in pairs(dfa_trans_by_key[k]) do
      transitions[name][sym] = key_to_name[nk]
    end
  end

  return M.dfa({
    states = states,
    alphabet = alphabet,
    initial = key_to_name[initial_key],
    accepting = accepting,
    transitions = transitions,
  })
end

-- ---------------------------------------------------------------------------
-- Equivalence check
-- ---------------------------------------------------------------------------

-- FA.equivalent(dfa1, dfa2) → boolean
-- Uses the table-filling algorithm (Hopcroft-Karp union-find approach).
-- Both DFAs must share the same alphabet.
function M.equivalent(dfa1, dfa2)
  -- We run the "product DFA" approach: states are pairs (s1, s2).
  -- Two DFAs are equivalent iff for every reachable pair, both are accepting
  -- or both are non-accepting.
  local trans1 = dfa1.transitions
  local trans2 = dfa2.transitions
  local acc1 = dfa1.accepting_set
  local acc2 = dfa2.accepting_set
  local alphabet = dfa1.alphabet

  local visited = {}
  local queue = {{dfa1.initial, dfa2.initial}}
  local qi = 1

  while qi <= #queue do
    local pair = queue[qi]
    qi = qi + 1
    local s1, s2 = pair[1], pair[2]
    local pk = s1 .. "\0" .. s2
    if not visited[pk] then
      visited[pk] = true
      -- Check: one accepting, other not → not equivalent
      if (acc1[s1] == true) ~= (acc2[s2] == true) then
        return false
      end
      -- Explore transitions (dead state = nil, treat as non-accepting sink)
      for _, sym in ipairs(alphabet) do
        local r1 = trans1[s1]
        local r2 = trans2[s2]
        local n1 = r1 and r1[sym]
        local n2 = r2 and r2[sym]
        -- Both nil → both go to dead; equivalent on this path
        -- Only one nil → one dead (non-accepting), other may differ
        if n1 or n2 then
          -- Use sentinel for dead state
          local nn1 = n1 or "\0dead1"
          local nn2 = n2 or "\0dead2"
          local npk = nn1 .. "\0" .. nn2
          if not visited[npk] then
            -- Check immediately if one is dead (non-accepting) and other is not
            local a1 = n1 and acc1[n1] or false
            local a2 = n2 and acc2[n2] or false
            if a1 ~= a2 then return false end
            -- Only enqueue if both are real states (not dead)
            if n1 and n2 then
              queue[#queue+1] = {n1, n2}
            elseif n1 then
              -- n2 is dead; n1 must also be non-accepting everywhere from here
              -- enqueue as (n1, dead) — we handle dead as never-accepting sink
              queue[#queue+1] = {n1, "\0dead2"}
            else
              queue[#queue+1] = {"\0dead1", n2}
            end
          end
        end
      end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Constructors
-- ---------------------------------------------------------------------------

-- FA.dfa(spec) → DFA object or (nil, errmsg)
function M.dfa(spec)
  if type(spec) ~= "table" then
    return nil, "dfa: spec must be a table"
  end
  if not spec.initial then return nil, "dfa: missing initial state" end
  if not spec.transitions then return nil, "dfa: missing transitions" end
  if not spec.alphabet then return nil, "dfa: missing alphabet" end

  local d = setmetatable({}, DFA)
  d.states = spec.states or {}
  d.alphabet = spec.alphabet
  d.initial = spec.initial
  d.transitions = spec.transitions

  -- Build accepting set for O(1) lookup
  d.accepting_set = {}
  for _, s in ipairs(spec.accepting or {}) do
    d.accepting_set[s] = true
  end
  d.accepting = spec.accepting or {}

  return d
end

-- FA.nfa(spec) → NFA object or (nil, errmsg)
function M.nfa(spec)
  if type(spec) ~= "table" then
    return nil, "nfa: spec must be a table"
  end
  if not spec.initial then return nil, "nfa: missing initial state" end
  if not spec.transitions then return nil, "nfa: missing transitions" end
  if not spec.alphabet then return nil, "nfa: missing alphabet" end

  local n = setmetatable({}, NFA)
  n.states = spec.states or {}
  n.alphabet = spec.alphabet
  n.initial = spec.initial
  n.transitions = spec.transitions

  -- Build accepting set for O(1) lookup
  n.accepting_set = {}
  for _, s in ipairs(spec.accepting or {}) do
    n.accepting_set[s] = true
  end
  n.accepting = spec.accepting or {}

  return n
end

return M
