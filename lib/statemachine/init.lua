-- lib/statemachine: hierarchical statechart library (Harel statecharts)
-- Supports nested (compound) states, entry/exit actions, guards, transient
-- transitions, context, and an XState-inspired service API.
--
-- State values:
--   atomic state  -> string, e.g. "idle"
--   compound state -> array table, e.g. {"active", "working"}
--
-- API:
--   M.create(config)                          -> machine
--   machine:initial_state()                   -> state
--   machine:transition(state, event, data)    -> new_state | (state, nil)
--   machine:matches(state, pattern)           -> bool
--   machine:states_list()                     -> list of all state names (flat)
--   machine:is_final(state)                   -> bool
--   machine:start(initial_context)            -> service
--   service:send(event, data)
--   service:matches(pattern)                  -> bool
--   service:stop()
--   service.state, service.context

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Deep-copy a table (shallow values, one level deep enough for context).
local function shallow_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- Resolve a state node given a path array relative to a states table.
-- Returns the node or nil.
local function resolve_node(states, path)
  local node = states
  for i = 1, #path do
    if type(node) ~= "table" then return nil end
    -- At each step we look into .states (for compound nodes) or the root table.
    local sub = node.states or node
    node = sub[path[i]]
    if node == nil then return nil end
  end
  return node
end

-- Return the "default" leaf path starting from a node.
-- For atomic nodes returns {}.
-- For compound nodes follows .initial recursively.
local function default_sub_path(node)
  if type(node) ~= "table" then return {} end
  if not node.initial then return {} end
  local sub = node.states and node.states[node.initial]
  local rest = sub and default_sub_path(sub) or {}
  local path = {node.initial}
  for i = 1, #rest do path[#path + 1] = rest[i] end
  return path
end

-- Build the full initial path for a machine config, starting from root.
local function initial_path(config)
  local path = {config.initial}
  local node = config.states[config.initial]
  local rest = node and default_sub_path(node) or {}
  for i = 1, #rest do path[#path + 1] = rest[i] end
  return path
end

-- Normalise a state value (string or table) to an array.
local function to_path(value)
  if type(value) == "string" then return {value} end
  return value
end

-- Convert path array to canonical state value (string if length 1, else table).
local function to_value(path)
  if #path == 1 then return path[1] end
  return path
end

-- Collect all ancestor nodes (and their state tables) for a given path.
-- Returns list of {name, node, parent_states} from root to leaf.
local function ancestor_chain(config, path)
  local chain = {}
  local states = config.states
  for i = 1, #path do
    local name = path[i]
    local node = states[name]
    chain[#chain + 1] = {name = name, node = node or {}, states = states}
    states = node and node.states or {}
  end
  return chain
end

-- Run entry actions from index `from` to end of chain (inclusive).
local function run_entry(chain, from, ctx)
  for i = from, #chain do
    local node = chain[i].node
    if node and node.entry then node.entry(ctx) end
  end
end

-- Run exit actions from end of chain down to index `to` (inclusive).
local function run_exit(chain, to, ctx)
  for i = #chain, to, -1 do
    local node = chain[i].node
    if node and node.exit then node.exit(ctx) end
  end
end

-- Find the LCA (lowest common ancestor) index in two ancestor chains.
-- Returns the index in the *old* chain after which paths diverge (0 = no common).
local function lca_index(old_chain, new_chain)
  local lca = 0
  for i = 1, math.min(#old_chain, #new_chain) do
    if old_chain[i].name == new_chain[i].name then
      lca = i
    else
      break
    end
  end
  return lca
end

-- ---------------------------------------------------------------------------
-- Transition resolution
-- ---------------------------------------------------------------------------

-- Given a current path and an event, find the first matching transition.
-- Searches from the leaf upward (inner states have priority).
-- Returns (transition_table, target_path) or (nil, nil).
local function find_transition(config, path, event_name, event_data, ctx)
  -- Walk from leaf to root looking for a handler.
  for depth = #path, 1, -1 do
    local sub_path = {}
    for i = 1, depth do sub_path[i] = path[i] end
    local node = resolve_node(config, sub_path)
    if node and node.on then
      local handler = node.on[event_name]
      if handler ~= nil then
        -- Normalise to table form.
        local t
        if type(handler) == "string" then
          t = {target = handler}
        else
          t = handler
        end
        -- Check guard.
        if t.guard and not t.guard(ctx, event_data) then
          -- Guard rejected — continue searching upward.
        else
          return t, t.target
        end
      end
    end
  end
  return nil, nil
end

-- Resolve a target string to a full absolute path.
-- Targets are resolved relative to the current path's ancestors, walking up
-- from the immediate parent to the root. This matches XState's relative-target
-- semantics: "paused" inside active.working resolves to active.paused.
local function resolve_target(config, current_path, target_str)
  if not target_str then return nil end
  -- Split on dots.
  local rel = {}
  for seg in target_str:gmatch("[^%.]+") do rel[#rel + 1] = seg end

  -- Try prefixes from deepest to shallowest (including empty prefix = root).
  for depth = #current_path, 0, -1 do
    -- Build candidate path: current_path[1..depth] + rel
    local candidate = {}
    for i = 1, depth do candidate[i] = current_path[i] end
    for i = 1, #rel do candidate[depth + i] = rel[i] end

    -- Walk from config.states using candidate.
    local node = config.states
    local ok = true
    local final_node
    for i = 1, #candidate do
      local n = node[candidate[i]]
      if n == nil then ok = false; break end
      if i == #candidate then
        final_node = n
      else
        node = n.states or {}
      end
    end
    if ok and final_node ~= nil then
      -- Extend with any sub-initial states.
      local rest = default_sub_path(final_node)
      for i = 1, #rest do candidate[#candidate + 1] = rest[i] end
      return candidate
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Machine object
-- ---------------------------------------------------------------------------

local Machine = {}
Machine.__index = Machine

function Machine:initial_state()
  local path = initial_path(self._config)
  local ctx = shallow_copy(self._config.context or {})
  -- Run entry actions for all nodes from root to leaf.
  local chain = ancestor_chain(self._config, path)
  -- (No previous state, so no exit actions needed.)
  run_entry(chain, 1, ctx)
  return {value = to_value(path), context = ctx}
end

-- Returns the new state object, or (old_state, nil) when no transition fires.
function Machine:transition(state, event_name, event_data)
  local path = to_path(state.value)
  local ctx = shallow_copy(state.context or {})

  local t, target_str = find_transition(self._config, path, event_name, event_data, ctx)
  if not t then
    return state, nil
  end

  -- Run action (mutates ctx copy).
  if t.action then t.action(ctx, event_data) end

  if not target_str then
    -- Internal transition (no target = no state change, no entry/exit).
    return {value = state.value, context = ctx}
  end

  local new_path = resolve_target(self._config, path, target_str)
  if not new_path then
    return nil, "statemachine: unknown target state '" .. target_str .. "'"
  end

  local old_chain = ancestor_chain(self._config, path)
  local new_chain = ancestor_chain(self._config, new_path)
  local lca = lca_index(old_chain, new_chain)

  -- For a self-transition (same path), the LCA is the parent of the leaf,
  -- so both exit and entry still fire for the leaf node.
  local same = (#path == #new_path)
  if same then
    for i = 1, #path do
      if path[i] ~= new_path[i] then same = false; break end
    end
  end
  if same and lca == #path then
    lca = lca - 1
  end

  -- Exit from leaf up to (but not including) LCA.
  run_exit(old_chain, lca + 1, ctx)
  -- Enter from LCA+1 down to new leaf.
  run_entry(new_chain, lca + 1, ctx)

  return {value = to_value(new_path), context = ctx}
end

-- pattern: "idle" or "active.working"
-- Matches if the state's path starts with the pattern path.
function Machine:matches(state, pattern)
  local path = to_path(state.value)
  local parts = {}
  for seg in pattern:gmatch("[^%.]+") do parts[#parts + 1] = seg end
  if #parts > #path then return false end
  for i = 1, #parts do
    if path[i] ~= parts[i] then return false end
  end
  return true
end

-- Returns a flat list of every leaf state name (breadth-first).
function Machine:states_list()
  local result = {}
  local function walk(states, prefix)
    for name, node in pairs(states) do
      local full = prefix ~= "" and (prefix .. "." .. name) or name
      result[#result + 1] = full
      if type(node) == "table" and node.states then
        walk(node.states, full)
      end
    end
  end
  walk(self._config.states, "")
  return result
end

function Machine:is_final(state)
  local path = to_path(state.value)
  local node = resolve_node(self._config, path)
  return node ~= nil and node.type == "final"
end

-- ---------------------------------------------------------------------------
-- Service (mutable wrapper)
-- ---------------------------------------------------------------------------

local Service = {}
Service.__index = Service

function Service:send(event_name, event_data)
  if self._stopped then return end
  local new_state, err = self._machine:transition(self.state, event_name, event_data)
  if new_state == nil then
    -- Propagate errors (unknown target etc.) silently; caller can check.
    return nil, err
  end
  self.state = new_state
  self.context = new_state.context
end

function Service:matches(pattern)
  return self._machine:matches(self.state, pattern)
end

function Service:stop()
  self._stopped = true
end

-- ---------------------------------------------------------------------------
-- M.create
-- ---------------------------------------------------------------------------

function M.create(config)
  if type(config) ~= "table" then
    return nil, "statemachine.create: config must be a table"
  end
  if not config.initial then
    return nil, "statemachine.create: config.initial is required"
  end
  if not config.states then
    return nil, "statemachine.create: config.states is required"
  end

  local machine = setmetatable({
    _config = config,
  }, Machine)

  -- Attach :start() here so it has machine in closure.
  function machine:start(initial_context)
    local cfg = self._config
    local path = initial_path(cfg)
    local ctx
    if initial_context then
      ctx = shallow_copy(initial_context)
    else
      ctx = shallow_copy(cfg.context or {})
    end
    -- Run entry actions.
    local chain = ancestor_chain(cfg, path)
    run_entry(chain, 1, ctx)
    local state = {value = to_value(path), context = ctx}
    local svc = setmetatable({
      _machine = self,
      _stopped = false,
      state = state,
      context = ctx,
    }, Service)
    return svc
  end

  return machine
end

return M
