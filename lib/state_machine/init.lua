-- lib/state_machine/init.lua
-- Finite state machine with guards, actions, on_enter/on_exit hooks, and context.
--
-- Public API:
--   M.new(def)              → sm | (nil, errmsg)
--   M.restore(def, snap)    → sm | (nil, errmsg)
--   sm:send(event)          → true | false
--   sm:can(event)           → boolean
--   sm:state()              → string
--   sm:states()             → list of state name strings
--   sm:transitions()        → list of {from, event, to} tables
--   sm:snapshot()           → {state, context} table
--   M._tier                 → "pure"

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: SMInstance = { _def: unknown, _state: string, context: unknown, ... }

-- ── helpers ────────────────────────────────────────────────────────────────────

-- Deep-copy a value (tables only — context may contain nested tables).
local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do
    t[k] = deep_copy(val)
  end
  return t
end

-- Normalise a transition spec into {target, guard, action}.
-- Accepts either a plain string (target) or a table {target, guard?, action?}.
local function normalise_trans(spec)
  if type(spec) == "string" then
    return { target = spec, guard = nil, action = nil }
  elseif type(spec) == "table" then
    return { target = spec.target, guard = spec.guard, action = spec.action }
  end
  return nil
end

-- ── validation ─────────────────────────────────────────────────────────────────

local function validate_def(def)
  if type(def) ~= "table" then
    return nil, "state_machine.new: def must be a table"
  end
  local def_ = def --[[:! { initial: unknown, states: unknown, ... }]]
  if type(def_.initial) ~= "string" then
    return nil, "state_machine.new: def.initial must be a string"
  end
  local initial = def_.initial --[[:! string]]
  if type(def_.states) ~= "table" then
    return nil, "state_machine.new: def.states must be a table"
  end
  local states = def_.states --[[:! { [string]: unknown }]]
  if states[initial] == nil then
    return nil, "state_machine.new: initial state '" .. initial .. "' is not defined in states"
  end
  -- Validate all transition targets reference defined states.
  for sname, sdef in pairs(def.states) do
    local sname_ = tostring(sname)
    if type(sdef) ~= "table" then
      return nil, "state_machine.new: state '" .. sname_ .. "' must be a table"
    end
    if sdef.on ~= nil then
      if type(sdef.on) ~= "table" then
        return nil, "state_machine.new: state '" .. sname_ .. "'.on must be a table"
      end
      for event, spec in pairs(sdef.on) do
        local event_ = tostring(event)
        local t = normalise_trans(spec)
        if t == nil then
          return nil, "state_machine.new: transition spec for '" .. sname_ .. "'." .. event_ .. " is invalid"
        end
        if def.states[t.target] == nil then
          return nil, "state_machine.new: transition '" .. sname_ .. "' --" .. event_ .. "--> '" .. tostring(t.target) .. "' target is not defined"
        end
      end
    end
  end
  return true
end

-- ── machine instance ───────────────────────────────────────────────────────────

local SM = {}
SM.__index = SM

--- Send an event to the machine.
-- Returns true if a transition occurred, false if blocked (guard failed or no
-- matching transition).
function SM:send(event)
  local sdef = self._def.states[self._state]
  if sdef == nil or sdef.on == nil then return false end
  local spec = sdef.on[event]
  if spec == nil then return false end
  local t = normalise_trans(spec)
  -- Evaluate guard.
  if t.guard ~= nil and not t.guard(self.context) then
    return false
  end
  -- on_exit current state.
  if sdef.on_exit ~= nil then
    sdef.on_exit(self.context)
  end
  -- Run transition action.
  if t.action ~= nil then
    t.action(self.context)
  end
  -- Move to new state.
  self._state = t.target
  -- on_enter new state.
  local new_sdef = self._def.states[self._state]
  if new_sdef ~= nil and new_sdef.on_enter ~= nil then
    new_sdef.on_enter(self.context)
  end
  return true
end

--- Query whether an event would cause a transition from the current state.
-- Returns true only when a transition exists AND the guard (if any) passes.
function SM:can(event)
  local sdef = self._def.states[self._state]
  if sdef == nil or sdef.on == nil then return false end
  local spec = sdef.on[event]
  if spec == nil then return false end
  local t = normalise_trans(spec)
  if t.guard ~= nil and not t.guard(self.context) then
    return false
  end
  return true
end

--- Return the current state name.
function SM:state()
  return self._state
end

--- Return a list of all state names defined in the machine.
function SM:states()
  local result = {}
  for k in pairs(self._def.states) do
    result[#result + 1] = k
  end
  table.sort(result)
  return result
end

--- Return a list of all transitions as {from, event, to} tables.
function SM:transitions()
  local result = {}
  for sname, sdef in pairs(self._def.states) do
    if sdef.on ~= nil then
      for event, spec in pairs(sdef.on) do
        local t = normalise_trans(spec)
        result[#result + 1] = { from = sname, event = event, to = t.target }
      end
    end
  end
  -- Sort for deterministic output: by from, then event.
  table.sort(result, function(a, b)
    if a.from ~= b.from then return a.from < b.from end
    return a.event < b.event
  end)
  return result
end

--- Capture a serialisable snapshot of the machine's current state and context.
-- The snapshot contains only plain data — the definition (callbacks, guards)
-- is NOT included. Use M.restore(def, snap) to reconstruct.
function SM:snapshot()
  return {
    state   = self._state,
    context = deep_copy(self.context),
  }
end

-- ── public constructors ────────────────────────────────────────────────────────

--- Create a new state machine from a definition table.
-- def = {
--   initial  : string,
--   states   : { [name] : { on: { [event]: spec }, on_enter?, on_exit? } },
--   context? : table,
-- }
function M.new(def)
  local ok, err = validate_def(def)
  if not ok then return nil, err end

  local sm_any = setmetatable({ _def = def, _state = def.initial, context = deep_copy(def.context or {}) }, SM) --[[: unknown]]
  local sm = sm_any --[[:! SMInstance]]

  -- Fire on_enter for the initial state.
  local isdef = def.states[def.initial]
  if isdef ~= nil and isdef.on_enter ~= nil then
    isdef.on_enter(sm.context)
  end

  return sm
end

--- Restore a machine from a definition and a previously captured snapshot.
function M.restore(def, snap)
  if type(snap) ~= "table" then
    return nil, "state_machine.restore: snap must be a table"
  end
  local snap_ = snap --[[:! { state: unknown, ... }]]
  if type(snap_.state) ~= "string" then
    return nil, "state_machine.restore: snap.state must be a string"
  end
  local snap_state = snap_.state --[[:! string]]
  local ok, err = validate_def(def)
  if not ok then return nil, err end
  local def_states = (def --[[:! { states: { [string]: unknown }, ... }]]).states
  if def_states[snap_state] == nil then
    return nil, "state_machine.restore: snap.state '" .. snap_state .. "' is not defined in states"
  end

  local sm = setmetatable({}, SM)
  sm._def    = def
  sm._state  = snap.state
  sm.context = deep_copy(snap.context or {})
  -- on_enter is NOT called on restore — snapshot represents an already-entered state.
  return sm
end

return M
