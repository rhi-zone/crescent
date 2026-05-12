if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Finite state machine (FSM) and hierarchical state machine (HSM) library.
-- Simple FSMs: flat state table with event→target transitions.
-- Guard conditions: per-transition guard function (ctx, data) → bool.
-- Callbacks: entry/exit per state, on_transition listeners.
-- History: tracks last substate per state for HSM use.

local M = {}
M._tier = "pure"

--:: Machine = { _initial: string, _current: string, _states: { [string]: unknown }, _listeners: { [integer]: unknown }, _history: { [string]: string }, _ctx: unknown }

-- ── Internals ────────────────────────────────────────────────────────────────

-- Resolve a transition spec.  It can be either:
--   a string  → {target=string}
--   a table   → {target, guard?, action?}
--:: Transition = { target: string, guard: (((unknown, unknown) -> boolean) | nil), action: (((unknown, unknown) -> nil) | nil) }
--: (string | Transition) -> Transition
local function resolve_transition(spec)
  if type(spec) == "string" then
    return { target = spec, guard = nil, action = nil }
  end
  return spec
end

-- ── Machine prototype ─────────────────────────────────────────────────────────

local Machine = {}
Machine.__index = Machine

-- Return the current state name.
--: (Machine) -> string
function Machine:state()
  return self._current
end

-- Return true if the current state name equals state_name.
--: (Machine, string) -> boolean
function Machine:matches(state_name)
  return self._current == state_name
end

-- Return true if event causes a transition from the current state.
-- Respects guard conditions: if the guard returns false, the event is
-- considered blocked (can returns false).
--: (Machine, string) -> boolean
function Machine:can(event)
  local state_def = self._states[self._current]
  if not state_def then return false end
  local on = state_def.on
  if not on then return false end
  local spec = on[event]
  if not spec then return false end
  local tr = resolve_transition(spec)
  if tr.guard and not tr.guard(self._ctx, nil) then return false end
  return true
end

-- Register a transition listener.  fn(from, to, event, data) is called
-- after every successful transition.
--: (Machine, (string, string, string, unknown) -> nil) -> nil
function Machine:on_transition(fn)
  self._listeners[#self._listeners + 1] = fn
end

-- Return the history table {state_name → last_substate_name}.
--: (Machine) -> { [string]: string }
function Machine:history()
  return self._history
end

-- Reset the machine to its initial state, calling exit on the current state
-- and entry on the initial state (if they differ).
--: (Machine) -> nil
function Machine:reset()
  local from = self._current
  local to   = self._initial

  -- Exit current state
  if from ~= to then
    local from_def = self._states[from]
    if from_def and from_def.exit then
      from_def.exit(self._ctx)
    end
  end

  self._current = to

  -- Enter initial state
  if from ~= to then
    local to_def = self._states[to]
    if to_def and to_def.entry then
      to_def.entry(self._ctx)
    end
  end

  -- Notify listeners
  if from ~= to then
    for i = 1, #self._listeners do
      self._listeners[i](from, to, "__reset__", nil)
    end
  end
end

-- Send an event to the machine, optionally with data.
-- Returns true on success, or (nil, errmsg) on failure.
--: (Machine, string, unknown) -> (boolean | nil, string | nil)
function Machine:send(event, data)
  local current = self._current
  local state_def = self._states[current]
  if not state_def then
    return nil, "unknown state: " .. tostring(current)
  end

  local on = state_def.on
  if not on then
    return nil, "no transitions defined for state '" .. current .. "'"
  end

  local spec = on[event]
  if not spec then
    return nil, "unknown event '" .. event .. "' in state '" .. current .. "'"
  end

  local tr = resolve_transition(spec)

  -- Check guard
  if tr.guard and not tr.guard(self._ctx, data) then
    return nil, "guard rejected event '" .. event .. "' in state '" .. current .. "'"
  end

  local target = tr.target
  if not self._states[target] then
    return nil, "transition target is unknown state: " .. tostring(target)
  end

  -- Exit current state
  if state_def.exit then
    state_def.exit(self._ctx)
  end

  -- Record history: the state we're leaving remembers where we were
  self._history[current] = current

  -- Update current state
  self._current = target

  -- Enter target state
  local target_def = self._states[target]
  if target_def.entry then
    target_def.entry(self._ctx)
  end

  -- Run action if present
  if tr.action then
    tr.action(self._ctx, data)
  end

  -- Notify listeners
  for i = 1, #self._listeners do
    self._listeners[i](current, target, event, data)
  end

  return true
end

-- ── Constructor ───────────────────────────────────────────────────────────────

-- Create a new finite state machine.
--
-- opts:
--   initial  string          — initial state name (required)
--   states   table           — map of state_name → state_def
--   context  table | nil     — optional context object passed to callbacks
--
-- state_def:
--   on     { event_name → transition }  — event transitions
--   entry  function(ctx) | nil          — called on entering state
--   exit   function(ctx) | nil          — called on leaving state
--
-- transition:
--   string                              — shorthand for { target = string }
--   { target, guard?, action? }         — full form with optional guard/action
--
--: ({ initial: string, states: { [string]: unknown }, context: unknown }) -> Machine
function M.machine(opts)
  assert(type(opts) == "table", "state.machine: opts must be a table")
  assert(type(opts.initial) == "string", "state.machine: opts.initial must be a string")
  assert(type(opts.states) == "table", "state.machine: opts.states must be a table")

  local initial = opts.initial
  assert(opts.states[initial], "state.machine: initial state '" .. initial .. "' not found in states")

  local self = setmetatable({}, Machine)
  self._initial   = initial
  self._current   = initial
  self._states    = opts.states
  self._listeners = {}
  self._history   = {}
  self._ctx       = opts.context or self  -- default ctx is the machine itself

  -- Call entry on the initial state at construction time
  local init_def = opts.states[initial]
  if init_def and init_def.entry then
    init_def.entry(self._ctx)
  end

  return self
end

return M
