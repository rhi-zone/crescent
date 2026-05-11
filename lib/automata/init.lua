if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Finite automata: NFA and DFA construction, simulation, and operations.
-- NFA: nondeterministic finite automaton with epsilon transitions
-- DFA: deterministic finite automaton
-- Operations: NFA->DFA (subset construction), DFA minimization (Hopcroft),
--   complement, union, intersection, Thompson's construction from regex.
local M = {}
M._tier = "pure"

-- ── Utilities ──────────────────────────────────────────────────────────────

-- Sorted keys of a table (for determinism in DOT output, subset construction)
--: (t: { [string]: unknown }) -> string[]
local function sorted_keys(t)
  local ks = {} --: Arr<string>
  for k in pairs(t --[[:! { [string]: unknown }]]) do ks[#ks+1] = k end
  table.sort(ks --[[:! { [integer]: integer }]])
  return ks
end

-- Set operations on integer-keyed sets (values are true)
local function set_new() return {} end

local function set_add(s, v) s[v] = true end

local function set_union(a, b)
  local r = {}
  for k in pairs(a) do r[k] = true end
  for k in pairs(b) do r[k] = true end
  return r
end

local function set_to_sorted_list(s)
  local r = {}
  for k in pairs(s) do r[#r+1] = k end
  table.sort(r)
  return r
end

local function set_from_list(lst)
  local s = {}
  for _, v in ipairs(lst) do s[v] = true end
  return s
end

-- Canonical key for a set of state ids (sorted, comma-joined)
local function set_key(s)
  return table.concat(set_to_sorted_list(s), ",")
end

-- ── NFA ────────────────────────────────────────────────────────────────────

--:: NFA = {
--::   states: { [integer]: { accept: boolean } },
--::   start: integer | nil,
--::   trans: { [integer]: { [string | boolean]: { [integer]: boolean } } },
--::   _next_id: integer,
--::   add_state: (NFA, { accept: boolean } | nil) -> integer,
--::   set_start: (NFA, integer) -> nil,
--::   add_transition: (NFA, integer, string | nil, integer) -> nil,
--::   epsilon_closure: (NFA, { [integer]: boolean }) -> { [integer]: boolean },
--::   move: (NFA, { [integer]: boolean }, string) -> { [integer]: boolean },
--::   accepts: (NFA, string) -> boolean,
--::   alphabet: (NFA) -> { [string]: boolean },
--:: }

local NFA = {}
NFA.__index = NFA

--- Create a new NFA.
-- @return NFA object
--: () -> NFA
function M.nfa_new()
  local nfa = setmetatable({
    states = {},       -- {[id] = {accept=bool}}
    start = nil,       -- start state id
    trans = {},        -- {[from] = {[symbol or false] = {[to]=true}}}
    _next_id = 1,
  }, NFA) --[[:! NFA]]
  return nfa
end

--- Add a state to the NFA.
-- @param opts  optional {accept=bool}
-- @return state id (integer)
--: (self: NFA, opts: { accept: boolean } | nil) -> integer
function NFA:add_state(opts)
  local id = self._next_id
  self._next_id = id + 1
  self.states[id] = { accept = opts and opts.accept or false }
  return id
end

--- Set the start state.
--: (self: NFA, id: integer) -> nil
function NFA:set_start(id)
  self.start = id
end

--- Add a transition.
-- @param from   source state id
-- @param symbol input character (string of length 1), or nil for epsilon
-- @param to     destination state id
--: (self: NFA, from: integer, symbol: string | nil, to: integer) -> nil
function NFA:add_transition(from, symbol, to)
  --: string | boolean
  local key = symbol or false  -- nil = epsilon → false key
  local row = self.trans[from]
  if not row then row = {}; self.trans[from] = row end
  local set = row[key]
  if not set then set = {}; row[key] = set end
  set[to] = true
end

--- Compute the epsilon closure of a set of state ids.
-- @param states  {[id]=true}
-- @return new set {[id]=true}
--: (self: NFA, states: { [integer]: boolean }) -> { [integer]: boolean }
function NFA:epsilon_closure(states)
  local closure = {}
  local stack = {}
  for id in pairs(states) do
    closure[id] = true
    stack[#stack+1] = id
  end
  while #stack > 0 do
    local s = stack[#stack]; stack[#stack] = nil
    local row = self.trans[s]
    if row then
      local eps = row[false]
      if eps then
        for t in pairs(eps) do
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

--- Move: given a set of states, compute states reachable on symbol (no eps).
-- @param states  {[id]=true}
-- @param symbol  input character string
-- @return new set {[id]=true}
--: (self: NFA, states: { [integer]: boolean }, symbol: string) -> { [integer]: boolean }
function NFA:move(states, symbol)
  local result = {}
  for s in pairs(states) do
    local row = self.trans[s]
    if row then
      local dsts = row[symbol]
      if dsts then
        for t in pairs(dsts) do result[t] = true end
      end
    end
  end
  return result
end

--- Test whether the NFA accepts a string (powerset simulation).
-- @param input  string
-- @return boolean
--: (self: NFA, input: string) -> boolean
function NFA:accepts(input)
  if not self.start then return false end
  local current = self:epsilon_closure({ [self.start] = true })
  for i = 1, #input do
    local ch = input:sub(i, i)
    current = self:epsilon_closure(self:move(current, ch))
    if not next(current) then return false end
  end
  for id in pairs(current) do
    if self.states[id] and self.states[id].accept then return true end
  end
  return false
end

--- Collect all symbols used in transitions (excluding epsilon).
--: (self: NFA) -> { [string]: boolean }
function NFA:alphabet()
  local alpha = {}
  for _, row in pairs(self.trans) do
    for sym in pairs(row) do
      if sym ~= false then alpha[sym] = true end
    end
  end
  return alpha
end

-- ── DFA ────────────────────────────────────────────────────────────────────

--:: DFA = {
--::   states: { [integer]: { accept: boolean } },
--::   start: integer | nil,
--::   trans: { [integer]: { [string]: integer } },
--::   _next_id: integer,
--::   add_state: (DFA, { accept: boolean, start?: boolean } | nil) -> integer,
--::   add_transition: (DFA, integer, string, integer) -> nil,
--::   run: (DFA, integer | nil, string) -> integer | nil,
--::   accepts: (DFA, string) -> boolean,
--::   alphabet: (DFA) -> { [string]: boolean },
--::   to_dot: (DFA) -> string,
--:: }

local DFA = {}
DFA.__index = DFA

--- Create a new DFA.
-- @return DFA object
--: () -> DFA
function M.dfa_new()
  local raw = setmetatable({
    states = {},     -- {[id] = {accept=bool}}
    start = nil,
    trans = {},      -- {[from] = {[symbol] = to}}
    _next_id = 1,
  }, DFA) --[[: unknown]]
  local dfa = raw --[[:! DFA]]
  return dfa
end

--- Add a state to the DFA.
-- @param opts  optional {accept=bool, start=bool}
-- @return state id (integer)
--: (self: DFA, opts: { accept: boolean, start: boolean | nil } | nil) -> integer
function DFA:add_state(opts)
  local id = self._next_id
  self._next_id = id + 1
  self.states[id] = { accept = opts and opts.accept or false }
  if opts and opts.start then self.start = id end
  return id
end

--- Add a transition (deterministic — one target per symbol).
--: (self: DFA, from: integer, symbol: string, to: integer) -> nil
function DFA:add_transition(from, symbol, to)
  local row = self.trans[from]
  if not row then row = {}; self.trans[from] = row end
  row[symbol] = to
end

--- Run the DFA one step: from state `state` on `symbol`.
-- @return next state id, or nil if no transition
--: (self: DFA, state: integer | nil, symbol: string) -> integer | nil
function DFA:run(state, symbol)
  if not state then return nil end
  -- Allow feeding multiple characters at once (streaming helper)
  if #symbol > 1 then
    local cur = state --: integer | nil
    for i = 1, #symbol do
      cur = self:run(cur, symbol:sub(i,i))
      if cur == nil then return nil end
    end
    return cur
  end
  local row = self.trans[state]
  if not row then return nil end
  return row[symbol]
end

--- Test whether the DFA accepts a string.
-- @param input  string
-- @return boolean
--: (self: DFA, input: string) -> boolean
function DFA:accepts(input)
  if not self.start then return false end
  local cur = self.start
  for i = 1, #input do
    local ch = input:sub(i, i)
    local row = self.trans[cur]
    if not row then return false end
    cur = row[ch]
    if cur == nil then return false end
  end
  return self.states[cur] and self.states[cur].accept or false
end

--- Collect all symbols in DFA transitions.
--: (self: DFA) -> { [string]: boolean }
function DFA:alphabet()
  local alpha = {}
  for _, row in pairs(self.trans) do
    for sym in pairs(row) do alpha[sym] = true end
  end
  return alpha
end

--- Serialize DFA to GraphViz DOT format.
-- @return string
--: (self: DFA) -> string
function DFA:to_dot()
  local lines = { "digraph DFA {", '  rankdir=LR;' }
  -- invisible start arrow
  lines[#lines+1] = '  __start [shape=none label=""];'
  if self.start then
    lines[#lines+1] = '  __start -> ' .. self.start .. ';'
  end
  for _, id in ipairs(sorted_keys(self.states)) do
    local st = self.states[id]
    local shape = st.accept and "doublecircle" or "circle"
    lines[#lines+1] = '  ' .. id .. ' [shape=' .. shape .. '];'
  end
  for _, from in ipairs(sorted_keys(self.trans)) do
    local row = self.trans[tonumber(from) --[[:! integer]]]
    -- group by target to merge labels
    local by_to = {} --: { [string]: Arr<string> }
    for sym, to in pairs(row --[[:! { [string]: integer }]]) do
      local to_s = tostring(to)
      if not by_to[to_s] then by_to[to_s] = {} end
      by_to[to_s][#by_to[to_s]+1] = sym
    end
    for to, syms in pairs(by_to) do
      table.sort(syms --[[:! { [integer]: integer }]])
      local label = table.concat(syms, ",")
      lines[#lines+1] = '  ' .. from .. ' -> ' .. to .. ' [label="' .. label .. '"];'
    end
  end
  lines[#lines+1] = "}"
  return table.concat(lines, "\n")
end

-- ── NFA → DFA (subset construction) ───────────────────────────────────────

--- Convert an NFA to an equivalent DFA via subset construction.
-- @param nfa  NFA object
-- @return DFA object
--: (nfa: NFA) -> DFA
function M.nfa_to_dfa(nfa)
  local dfa = M.dfa_new()
  local alpha = nfa:alphabet()

  if not nfa.start then return dfa end

  local start_set = nfa:epsilon_closure({ [nfa.start] = true })
  local start_key = set_key(start_set)

  -- Map from frozenset-key to DFA state id
  local dfa_state = {}
  -- Queue of (nfa_set, dfa_id) to process
  --:: QueueEntry = { set: { [integer]: boolean }, id: integer }
  local queue = {} --: Arr<QueueEntry>

  local function is_accepting(nfa_set)
    for id in pairs(nfa_set) do
      if nfa.states[id] and nfa.states[id].accept then return true end
    end
    return false
  end

  local start_id = dfa:add_state({ accept = is_accepting(start_set) })
  dfa.start = start_id
  dfa_state[start_key] = start_id
  queue[#queue+1] = { set = start_set, id = start_id }

  local syms = sorted_keys(alpha)

  while #queue > 0 do
    local entry = queue[1]; table.remove(queue, 1)
    local cur_set = (entry --[[:! QueueEntry]]).set
    local cur_id = (entry --[[:! QueueEntry]]).id

    for _, sym in ipairs(syms) do
      local moved = nfa:move(cur_set, sym)
      local closed = nfa:epsilon_closure(moved)
      if next(closed) then
        local key = set_key(closed)
        local to_id = dfa_state[key]
        if not to_id then
          to_id = dfa:add_state({ accept = is_accepting(closed) })
          dfa_state[key] = to_id
          queue[#queue+1] = { set = closed, id = to_id }
        end
        dfa:add_transition(cur_id, sym, to_id --[[:! integer]])
      end
    end
  end

  return dfa
end

-- ── DFA minimization (Hopcroft's algorithm) ────────────────────────────────

--- Minimize a DFA using Hopcroft's partition-refinement algorithm.
-- @param dfa  DFA object
-- @return new minimized DFA
--: (dfa: DFA) -> DFA
function M.minimize(dfa)
  local alpha = dfa:alphabet()
  local syms = sorted_keys(alpha)

  -- Collect all reachable states via BFS from start
  local reachable = {}
  if dfa.start then
    local q = { dfa.start }
    reachable[dfa.start] = true
    local head = 1
    while head <= #q do
      local s = q[head]; head = head + 1
      local row = dfa.trans[s]
      if row then
        for _, to in pairs(row) do
          if not reachable[to] then
            reachable[to] = true
            q[#q+1] = to
          end
        end
      end
    end
  end

  local states_list = {}
  for s in pairs(reachable) do states_list[#states_list+1] = s end
  table.sort(--[[:! { [integer]: integer }]] states_list)

  if #states_list == 0 then return M.dfa_new() end

  -- Initial partition: accepting vs non-accepting
  local acc = {}
  local non_acc = {}
  for _, s in ipairs(states_list) do
    if dfa.states[s] and dfa.states[s].accept then
      acc[#acc+1] = s
    else
      non_acc[#non_acc+1] = s
    end
  end

  -- Partition is a list of sets; each set is {[state_id]=true}
  local partitions = {}
  if #acc > 0 then partitions[#partitions+1] = set_from_list(acc) end
  if #non_acc > 0 then partitions[#partitions+1] = set_from_list(non_acc) end

  -- Map state -> partition index
  local function build_state_to_part(parts)
    local sp = {}
    for pi, part in ipairs(parts) do
      for s in pairs(part) do sp[s] = pi end
    end
    return sp
  end

  -- Hopcroft refinement
  local changed = true
  while changed do
    changed = false
    local sp = build_state_to_part(partitions)
    local new_parts = {}

    for _, part in ipairs(partitions) do
      -- Try to split `part` on each symbol
      local splits = {}  -- list of sub-groups

      -- Start with one group = all states in part
      splits[1] = {}
      for s in pairs(part) do splits[1][s] = true end

      for _, sym in ipairs(syms) do
        local next_splits = {}
        for _, grp in ipairs(splits) do
          -- Group states by which partition their sym-successor falls in
          -- -1 means no transition (dead)
          local by_dest = {}
          for s in pairs(grp) do
            local row = dfa.trans[s]
            local dest_part = -1
            if row and row[sym] then
              dest_part = sp[row[sym]] or -1
            end
            if not by_dest[dest_part] then by_dest[dest_part] = {} end
            by_dest[dest_part][s] = true
          end
          -- Each group in by_dest becomes a new sub-split
          for _, sub in pairs(by_dest) do
            next_splits[#next_splits+1] = sub
          end
        end
        splits = next_splits
      end

      -- If splits produced more than one group from this partition, mark changed
      if #splits > 1 then changed = true end
      for _, sub in ipairs(splits) do
        new_parts[#new_parts+1] = sub
      end
    end

    partitions = new_parts
  end

  -- Build minimized DFA from partitions
  local sp = build_state_to_part(partitions)
  local min = M.dfa_new()

  -- Create one DFA state per partition
  local part_to_new = {}
  for pi, part in ipairs(partitions) do
    local is_acc = false
    for s in pairs(part) do
      if dfa.states[s] and dfa.states[s].accept then is_acc = true; break end
    end
    local new_id = min:add_state({ accept = is_acc })
    part_to_new[pi] = new_id
  end

  -- Set start state
  if dfa.start and sp[dfa.start] then
    min.start = part_to_new[sp[dfa.start]]
  end

  -- Add transitions (one representative per partition)
  local added = {}
  for pi, part in ipairs(partitions) do
    -- pick the smallest representative
    local rep = nil
    for s in pairs(part) do
      if not rep or s < rep then rep = s end
    end
    local new_from = part_to_new[pi]
    local key_base = tostring(new_from) .. ":"
    local row = rep and dfa.trans[rep --[[:! integer]]] or nil
    if row then
      for sym, to in pairs(row --[[:! { [string]: integer }]]) do
        if sp[to] then
          local key = key_base .. sym
          if not added[key] then
            min:add_transition(new_from, sym, part_to_new[sp[to]])
            added[key] = true
          end
        end
      end
    end
  end

  return min
end

-- ── DFA operations ─────────────────────────────────────────────────────────

--- Complete a DFA by adding a dead/sink state for missing transitions.
-- Returns a new DFA where every state has a transition for every symbol.
-- @param dfa    DFA object
-- @param alpha  set of symbols {[sym]=true}
-- @return new complete DFA, mapping from old ids to new ids
--: (dfa: DFA, alpha: { [string]: boolean }) -> (DFA, { [integer]: integer })
local function complete_dfa(dfa, alpha)
  local new_dfa = M.dfa_new()
  local old_to_new = {}

  -- Copy states
  for _, id in ipairs(sorted_keys(dfa.states)) do
    local st = dfa.states[id]
    local new_id = new_dfa:add_state({ accept = st.accept })
    old_to_new[id] = new_id
  end
  new_dfa.start = dfa.start and old_to_new[dfa.start]

  -- Dead state (created lazily)
  local dead = nil
  local function get_dead()
    if not dead then
      dead = new_dfa:add_state({ accept = false })
      -- dead loops on everything
      for sym in pairs(alpha) do
        new_dfa:add_transition(dead, sym, dead)
      end
    end
    return dead
  end

  -- Copy transitions, fill missing with dead
  for _, id in ipairs(sorted_keys(dfa.states)) do
    local new_from = old_to_new[id]
    local row = dfa.trans[id] or {}
    for sym in pairs(alpha) do
      local to = row[sym]
      if to then
        new_dfa:add_transition(new_from, sym, old_to_new[to])
      else
        new_dfa:add_transition(new_from, sym, get_dead())
      end
    end
  end

  return new_dfa, old_to_new
end

--- Complement of a DFA: accepts exactly the strings the original rejects.
-- @param dfa  DFA object
-- @return new DFA
--: (dfa: DFA) -> DFA
function M.complement(dfa)
  local alpha = dfa:alphabet()
  local cdfa = complete_dfa(dfa, alpha)
  -- Flip accept/reject
  for _, st in pairs(cdfa.states) do
    st.accept = not st.accept
  end
  return cdfa
end

--- Product construction for two DFAs (used by intersection and union).
-- @param accept_fn  function(a_accept, b_accept) -> bool
-- @return new DFA
--: (dfa1: DFA, dfa2: DFA, accept_fn: (boolean, boolean) -> boolean) -> DFA
local function product(dfa1, dfa2, accept_fn)
  -- Unified alphabet
  local alpha = {}
  for sym in pairs(dfa1:alphabet()) do alpha[sym] = true end
  for sym in pairs(dfa2:alphabet()) do alpha[sym] = true end
  local syms = sorted_keys(alpha)

  local dfa1c = complete_dfa(dfa1, alpha)
  local dfa2c = complete_dfa(dfa2, alpha)

  local result = M.dfa_new()

  -- States are pairs (s1, s2); encode as string key
  local pair_to_id = {} --: { [string]: integer }
  --:: ProductEntry = { s1: integer, s2: integer, id: integer }
  local queue = {} --: Arr<ProductEntry>

  local function get_pair(s1, s2)
    local key = s1 .. "," .. s2
    local id = pair_to_id[key]
    if not id then
      local a1 = dfa1c.states[s1] and dfa1c.states[s1].accept or false
      local a2 = dfa2c.states[s2] and dfa2c.states[s2].accept or false
      id = result:add_state({ accept = accept_fn(a1, a2) })
      pair_to_id[key] = id
      queue[#queue+1] = { s1 = s1, s2 = s2, id = id }
    end
    return id
  end

  if not dfa1c.start or not dfa2c.start then return result end

  local start_id = get_pair(dfa1c.start, dfa2c.start)
  result.start = start_id

  local head = 1
  while head <= #queue do
    local entry = (queue[head] --[[:! ProductEntry]]); head = head + 1
    local s1, s2, cur_id = entry.s1, entry.s2, entry.id
    for _, sym in ipairs(syms) do
      local r1 = dfa1c.trans[s1]
      local r2 = dfa2c.trans[s2]
      local t1 = r1 and r1[sym]
      local t2 = r2 and r2[sym]
      if t1 and t2 then
        local to_id = get_pair(t1, t2)
        result:add_transition(cur_id, sym, to_id)
      end
    end
  end

  return result
end

--- Intersection: accepts strings both DFAs accept.
-- @param dfa1  DFA object
-- @param dfa2  DFA object
-- @return new DFA
--: (dfa1: DFA, dfa2: DFA) -> DFA
function M.intersection(dfa1, dfa2)
  return product(dfa1, dfa2, function(a, b) return a and b end)
end

--- Union: accepts strings either DFA accepts.
-- @param dfa1  DFA object
-- @param dfa2  DFA object
-- @return new DFA
--: (dfa1: DFA, dfa2: DFA) -> DFA
function M.union(dfa1, dfa2)
  return product(dfa1, dfa2, function(a, b) return a or b end)
end

-- ── Thompson's construction (regex → NFA) ──────────────────────────────────
--
-- Regex syntax supported:
--   literal chars, | (alternation), * (Kleene star), + (one or more),
--   ? (optional), () (grouping), . (any single char marker)
--
-- The "." (dot) char is treated as a special symbol that matches any
-- single character in the NFA alphabet AT SIMULATION TIME; during NFA
-- construction it is stored as the literal string "." in transitions.
-- The NFA:accepts() method handles "." transitions by trying them whenever
-- normal transitions don't apply (and also when they do).
-- Implementation: wrap NFA move() to handle "." wildcard.

--- NFA fragment: a pair (start, accept) of state ids within a shared NFA.
-- Thompson's construction builds fragments and wires them together.

--- Build NFA from regex string using Thompson's construction.
-- @param pattern  regex string
-- @return NFA object, or (nil, errmsg)
--: (pattern: string) -> (NFA | nil, string | nil)
function M.from_regex(pattern)
  local nfa = M.nfa_new()

  -- Patch NFA move to support "." wildcard transitions
  local orig_move = NFA.move
  function nfa:move(states, symbol)
    local result = {}
    for s in pairs(states) do
      local row = self.trans[s]
      if row then
        -- exact match
        local dsts = row[symbol]
        if dsts then
          for t in pairs(dsts) do result[t] = true end
        end
        -- wildcard "." matches any symbol
        if symbol ~= false then
          local wdsts = row["."]
          if wdsts then
            for t in pairs(wdsts) do result[t] = true end
          end
        end
      end
    end
    return result
  end

  local pos = 1

  local function peek()
    return pattern:sub(pos, pos)
  end

  local function consume()
    local ch = pattern:sub(pos, pos)
    pos = pos + 1
    return ch
  end

  -- Forward declarations
  local parse_expr, parse_concat, parse_quantified, parse_atom

  -- NFA fragment helpers
  -- Each fragment: {start=id, accept=id} (single accept state for simplicity)
  --:: Frag = { start: integer, accept: integer }

  --: (ch: string) -> Frag
  local function frag_literal(ch)
    local s = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s, ch, a)
    return { start = s, accept = a }
  end

  --: () -> Frag
  local function frag_epsilon()
    local s = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s, nil, a)
    return { start = s, accept = a }
  end

  -- Concatenate two fragments
  --: (f1: Frag, f2: Frag) -> Frag
  local function frag_concat(f1, f2)
    nfa:add_transition(f1.accept, nil, f2.start)
    return { start = f1.start, accept = f2.accept }
  end

  -- Alternate two fragments (f1 | f2)
  --: (f1: Frag, f2: Frag) -> Frag
  local function frag_union(f1, f2)
    local s = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s, nil, f1.start)
    nfa:add_transition(s, nil, f2.start)
    nfa:add_transition(f1.accept, nil, a)
    nfa:add_transition(f2.accept, nil, a)
    return { start = s, accept = a }
  end

  -- Kleene star (zero or more)
  --: (f: Frag) -> Frag
  local function frag_star(f)
    local s = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s, nil, f.start)
    nfa:add_transition(s, nil, a)
    nfa:add_transition(f.accept, nil, f.start)
    nfa:add_transition(f.accept, nil, a)
    return { start = s, accept = a }
  end

  -- One or more (f+)
  --: (f: Frag) -> Frag
  local function frag_plus(f)
    -- f followed by f*
    local s2 = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s2, nil, f.start)
    nfa:add_transition(s2, nil, a)
    nfa:add_transition(f.accept, nil, s2)
    return { start = f.start, accept = a }
  end

  -- Optional (f?)
  --: (f: Frag) -> Frag
  local function frag_optional(f)
    local s = nfa:add_state()
    local a = nfa:add_state()
    nfa:add_transition(s, nil, f.start)
    nfa:add_transition(s, nil, a)
    nfa:add_transition(f.accept, nil, a)
    return { start = s, accept = a }
  end

  -- Grammar (recursive descent):
  --   expr     = concat ('|' concat)*
  --   concat   = quantified+
  --   quantified = atom ('*' | '+' | '?')*
  --   atom     = '(' expr ')' | '.' | literal_char

  parse_atom = function()
    local ch = peek()
    if ch == "(" then
      consume()
      local f = parse_expr()
      if peek() ~= ")" then
        return nil, "expected ')' at position " .. pos
      end
      consume()
      return f
    elseif ch == "." then
      consume()
      return frag_literal(".")
    elseif ch == "" or ch == "|" or ch == ")" or ch == "*" or ch == "+" or ch == "?" then
      return nil, "unexpected character '" .. ch .. "' at position " .. pos
    else
      consume()
      return frag_literal(ch)
    end
  end

  parse_quantified = function()
    local f, err = parse_atom()
    if not f then return nil, err end
    while true do
      local ch = peek()
      if ch == "*" then
        consume()
        f = frag_star(f)
      elseif ch == "+" then
        consume()
        f = frag_plus(f)
      elseif ch == "?" then
        consume()
        f = frag_optional(f)
      else
        break
      end
    end
    return f
  end

  parse_concat = function()
    local f, err = parse_quantified()
    if not f then return nil, err end
    while true do
      local ch = peek()
      if ch == "" or ch == "|" or ch == ")" then break end
      local f2, err2 = parse_quantified()
      if not f2 then return nil, err2 end
      f = frag_concat(f, f2)
    end
    return f
  end

  parse_expr = function()
    local f, err = parse_concat()
    if not f then return nil, err end
    while peek() == "|" do
      consume()
      local f2, err2 = parse_concat()
      if not f2 then return nil, err2 end
      f = frag_union(f, f2)
    end
    return f
  end

  local frag, err = parse_expr()
  if not frag then return nil, err end
  if pos <= #pattern then
    return nil, "unexpected character '" .. peek() .. "' at position " .. pos
  end

  nfa.states[frag.accept].accept = true
  nfa:set_start(frag.start)

  return nfa
end

return M
