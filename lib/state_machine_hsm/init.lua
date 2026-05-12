if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/state_machine_hsm: Hierarchical State Machine (HSM / Statechart)
--
-- Supports nested (compound) states, entry/exit actions on correct LCA paths,
-- guards, per-transition actions, shallow/deep history, and dot-notation paths.
--
-- API:
--   M.chart(spec)           -> chart
--   chart:machine(opts)     -> machine   opts: { context }
--   machine:start()
--   machine:send(event, data?) -> handled (bool)
--   machine:state()         -> dot-path string of current leaf state
--   machine:in_state(name)  -> bool
--   machine:context()       -> context table

local M = {}
M._tier = "pure"

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function split_path(s)
  local parts = {}
  for part in s:gmatch("[^.]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- Resolve a transition spec: string | {target=, guard=?, action=?}
local function resolve_transition(spec)
  if type(spec) == "string" then
    return { target = spec }
  end
  return spec
end

-- ── Chart compilation ─────────────────────────────────────────────────────────

-- Recursively compile a state node.
-- parent_path: dot-path of parent (empty string for root)
-- key: this state's own name segment
-- spec: the user-provided state definition table
-- nodes: flat map from dot-path → compiled node
--: (string, string, { on: { [string]: unknown }, ... }, { [string]: unknown }) -> unknown
local function compile_state(parent_path, key, spec, nodes)
  local path = parent_path == "" and key or (parent_path .. "." .. key)

  local node = {
    path     = path,
    key      = key,
    parent   = parent_path ~= "" and parent_path or nil,
    children = {},   -- ordered list of child keys
    on       = spec.on or {},
    entry    = spec.entry,
    exit     = spec.exit,
    initial  = spec.initial,
    history  = spec.history,  -- "shallow" | "deep" | nil
    atomic   = false,         -- filled in below
  }
  nodes[path] = node

  if spec.states then
    for child_key, child_spec in pairs(spec.states) do
      node.children[#node.children + 1] = child_key --[[:! string]]
      compile_state(path, child_key --[[:! string]], child_spec --[[:! { on: { [string]: unknown } }]], nodes)
    end
    node.atomic = false
    -- Default initial child if not specified: first key encountered
    if not node.initial then
      node.initial = node.children[1]
    end
  else
    node.atomic = true
  end

  return node
end

-- ── Chart prototype ───────────────────────────────────────────────────────────

local Chart = {}
Chart.__index = Chart

-- Forward declaration so Chart:machine can reference it.
local Machine

-- Resolve a dot-path target to the leaf initial state.
-- E.g. "active" with initial="running" resolves to "active.running".
local function resolve_to_leaf(nodes, path)
  local node = nodes[path]
  if not node then return nil, "unknown state: " .. tostring(path) end
  while not node.atomic do
    local child_key = node.initial
    if not child_key then
      return nil, "compound state '" .. node.path .. "' has no initial child"
    end
    local child_path = node.path .. "." .. child_key
    node = nodes[child_path]
    if not node then
      return nil, "initial child '" .. child_path .. "' not found"
    end
  end
  return node.path
end

-- Ancestors of a path as an ordered list from root to parent (not including self).
local function ancestors(nodes, path)
  local result = {}
  local node = nodes[path]
  while node and node.parent do
    table.insert(result, 1, node.parent)
    node = nodes[node.parent]
  end
  return result
end

-- Lowest Common Ancestor of two paths.
-- Returns the LCA path, or nil if they share no common ancestor (shouldn't happen).
local function lca(nodes, a, b)
  local anc_a = ancestors(nodes, a)
  anc_a[#anc_a + 1] = a  -- include self for lookup
  local set = {}
  for _, p in ipairs(anc_a) do set[p] = true end

  -- Walk up b's ancestors
  local node = nodes[b]
  while node do
    if set[node.path] then return node.path end
    node = node.parent and nodes[node.parent] or nil
  end
  return nil
end

-- States to exit when going from `from` (leaf) up to (but not including) `lca_path`.
-- Ordered innermost first.
local function states_to_exit(nodes, from, lca_path)
  local result = {}
  local node = nodes[from]
  while node and node.path ~= lca_path do
    result[#result + 1] = node.path
    node = node.parent and nodes[node.parent] or nil
  end
  return result
end

-- States to enter when going from `lca_path` down to `to` (leaf).
-- Ordered outermost first.
local function states_to_enter(nodes, to, lca_path)
  local result = {}
  local node = nodes[to]
  while node and node.path ~= lca_path do
    table.insert(result, 1, node.path)
    node = node.parent and nodes[node.parent] or nil
  end
  return result
end

-- Find a transition for `event` starting from `leaf` and bubbling up.
-- Returns (transition_spec, source_state_path) or nil.
local function find_transition(nodes, leaf, event)
  local node = nodes[leaf]
  while node do
    local on = node.on
    if on and on[event] then
      return resolve_transition(on[event]), node.path
    end
    node = node.parent and nodes[node.parent] or nil
  end
  return nil, nil
end

function Chart:machine(opts)
  opts = opts or {}
  local ctx = opts.context or {}

  local machine = {
    _chart   = self,
    _ctx     = ctx,
    _current = nil,    -- current leaf state path
    _history = {},     -- path → last visited child key (shallow history)
    _deep_history = {}, -- path → last visited leaf (deep history)
    _started = false,
  }
  setmetatable(machine, { __index = Machine })
  return machine
end

-- ── Machine prototype ─────────────────────────────────────────────────────────

--:: MachineObj = { _chart: { _nodes: { [string]: unknown }, ... }, _current: string | nil, _ctx: unknown, _history: { [string]: unknown }, _deep_history: { [string]: unknown }, _started: boolean, ... }

Machine = {}
Machine.__index = Machine

-- Enter a sequence of states (outermost first), firing entry actions.
-- Updates history for parent states if applicable.
--: (MachineObj, unknown, string | nil) -> nil
local function do_enter(machine, enter_list, prev_leaf)
  local nodes = machine._chart._nodes
  for _, path in ipairs(enter_list) do
    local node = nodes[path]
    if node and node.entry then
      node.entry(machine._ctx)
    end
  end
end

-- Exit a sequence of states (innermost first), firing exit actions.
local function do_exit(machine, exit_list)
  local nodes = machine._chart._nodes
  for _, path in ipairs(exit_list) do
    local node = nodes[path]
    if node and node.exit then
      node.exit(machine._ctx)
    end
    -- Record history in parent
    local parent_path = node and node.parent
    if parent_path then
      local parent = nodes[parent_path]
      if parent then
        if parent.history == "shallow" then
          machine._history[parent_path] = node.key
        elseif parent.history == "deep" then
          machine._deep_history[parent_path] = path
        end
      end
    end
  end
end

-- Resolve the actual leaf to enter for a target path, considering history.
local function resolve_target_with_history(machine, target_path)
  local nodes = machine._chart._nodes
  local node = nodes[target_path]
  if not node then return nil, "unknown state: " .. tostring(target_path) end

  while not node.atomic do
    local child_key
    if node.history == "deep" then
      local remembered = machine._deep_history[node.path]
      if remembered and nodes[remembered] then
        return remembered
      end
    elseif node.history == "shallow" then
      local remembered = machine._history[node.path]
      if remembered then
        local child_path = node.path .. "." .. remembered
        if nodes[child_path] then
          child_key = remembered
        end
      end
    end
    if not child_key then
      child_key = node.initial
    end
    if not child_key then
      return nil, "compound state '" .. node.path .. "' has no initial child"
    end
    local child_path = node.path .. "." .. child_key
    node = nodes[child_path]
    if not node then
      return nil, "initial child '" .. child_path .. "' not found"
    end
  end
  return node.path
end

function Machine:start()
  local chart = self._chart
  local nodes = chart._nodes
  local root_initial = chart._initial

  -- Find the leaf state from root initial
  local leaf, err = resolve_target_with_history(self, root_initial)
  if not leaf then
    error("state_machine_hsm: start failed: " .. tostring(err))
  end

  -- Build entry list: all ancestors of leaf (root-first) then leaf itself
  local enter_list = ancestors(nodes, leaf)
  enter_list[#enter_list + 1] = leaf

  self._current = leaf
  self._started = true
  do_enter(self, enter_list, nil)
end

--: (MachineObj, unknown, unknown) -> boolean
function Machine:send(event, data)
  if not self._started then return false end
  local nodes = self._chart._nodes
  local current = self._current --[[:! string]]

  local tr_, source = find_transition(nodes, current, event)
  if not tr_ then return false end
  local tr = tr_ --[[:! { target: string, guard: ((unknown, unknown) -> boolean) | nil, action: ((unknown, unknown) -> nil) | nil }]]

  -- Check guard
  if tr.guard and not tr.guard(self._ctx, data) then
    return false
  end

  -- Resolve target: follow dot-path segments
  local target_path = tr.target
  if not nodes[target_path] then
    return false
  end

  -- Determine actual leaf for target (with history)
  local target_leaf, err = resolve_target_with_history(self, target_path)
  if not target_leaf then
    return false
  end

  -- Compute LCA
  local lca_path = lca(nodes, --[[:! string]] current, target_leaf)

  -- Self-transition: if source == target (same node), use the source's parent as LCA
  -- so entry/exit fire on the state itself.
  -- If lca_path == source == target_leaf, it means transitioning to self or ancestor.
  -- For self-transitions (current == target_leaf), we exit and re-enter.
  if current == target_leaf then
    -- self-transition: exit and re-enter through the source state's parent
    lca_path = nodes[current].parent or ""
  end

  -- States to exit (innermost first, from current up to but not including LCA)
  local exit_list = states_to_exit(nodes, current, lca_path)
  -- States to enter (outermost first, from just below LCA down to target_leaf)
  local enter_list = states_to_enter(nodes, target_leaf, lca_path)

  -- Run exit actions (records history)
  do_exit(self, exit_list)

  -- Update current
  self._current = target_leaf

  -- Run transition action
  if tr.action then
    tr.action(self._ctx, data)
  end

  -- Run entry actions
  do_enter(self, enter_list, current)

  return true
end

function Machine:state()
  return self._current
end

function Machine:in_state(name)
  if not self._current then return false end
  -- Check if current equals name, or starts with name + "."
  if self._current == name then return true end
  if self._current:sub(1, #name + 1) == name .. "." then return true end
  return false
end

function Machine:context()
  return self._ctx
end

-- ── M.chart ───────────────────────────────────────────────────────────────────

--: ({ initial: string, states: { [string]: unknown } }) -> unknown
function M.chart(spec)
  assert(type(spec) == "table", "state_machine_hsm.chart: spec must be a table")
  assert(type(spec.initial) == "string", "state_machine_hsm.chart: spec.initial must be a string")
  assert(type(spec.states) == "table", "state_machine_hsm.chart: spec.states must be a table")

  local nodes = {}

  -- Compile all top-level states under a virtual root ""
  for key, state_spec in pairs(spec.states) do
    compile_state("", key --[[:! string]], state_spec --[[:! { on: { [string]: unknown } }]], nodes)
  end

  -- Validate initial state exists
  assert(nodes[spec.initial], "state_machine_hsm.chart: initial state '" .. spec.initial .. "' not found")

  local chart = setmetatable({
    _nodes   = nodes,
    _initial = spec.initial,
  }, { __index = Chart })

  return chart
end

return M
