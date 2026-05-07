if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: FsmStateConfig = { on_enter?: (ctx: { [string]: unknown }) -> nil, on_exit?: (ctx: { [string]: unknown }) -> nil }
--:: FsmTransition = { from: string | { [integer]: string }, to: string, event: string }
--:: FsmConfig = { initial: string, states: { [string]: FsmStateConfig }, transitions: FsmTransition[], guards?: { [string]: (ctx: { [string]: unknown }, event_data: unknown) -> boolean }, actions?: { [string]: (ctx: { [string]: unknown }, event_data: unknown) -> nil } }
--:: Machine = { _config: FsmConfig, _lookup: { [string]: { [string]: { to: string } } }, _guards: { [string]: (ctx: { [string]: unknown }, event_data: unknown) -> boolean }, _actions: { [string]: (ctx: { [string]: unknown }, event_data: unknown) -> nil }, _listeners: { [integer]: (from: string, to: string, event: string, ctx: { [string]: unknown }) -> nil }, states: (self: Machine) -> { [integer]: string }, events: (self: Machine) -> { [integer]: string }, transitions_from: (self: Machine, state: string) -> { [integer]: { event: string, to: string } }, on_transition: (self: Machine, fn: (from: string, to: string, event: string, ctx: { [string]: unknown }) -> nil) -> nil, start: (self: Machine, ctx: ({ [string]: unknown } | nil)) -> Instance }
--:: Instance = { _machine: Machine, _state: string, _ctx: { [string]: unknown }, _history: { [integer]: string }, state: (self: Instance) -> string, context: (self: Instance) -> { [string]: unknown }, set_context: (self: Instance, ctx: { [string]: unknown }) -> nil, history: (self: Instance) -> { [integer]: string }, can: (self: Instance, event: string) -> boolean, send: (self: Instance, event: string, data: unknown) -> (boolean | nil, string | nil) }

-- Machine prototype (definition)
local Machine = {}
Machine.__index = Machine

-- Instance prototype (running machine)
local Instance = {}
Instance.__index = Instance

--: (config: FsmConfig | nil) -> (Machine | nil, string | nil)
function M.new(config)
  if not config then return nil, "config is required" end
  if not config.initial then return nil, "initial state is required" end
  if not config.states then return nil, "states table is required" end
  if not config.transitions then return nil, "transitions table is required" end
  if not config.states[config.initial] then
    return nil, "initial state '" .. config.initial .. "' is not in states"
  end

  -- Validate transitions reference known states
  for i = 1, #config.transitions do
    local t = config.transitions[i]
    if not t.event then return nil, "transition #" .. i .. " missing event" end
    if not t.to then return nil, "transition #" .. i .. " missing 'to' state" end
    if not t.from then return nil, "transition #" .. i .. " missing 'from' state" end
    if not config.states[t.to] then
      return nil, "transition #" .. i .. " references unknown state '" .. t.to .. "'"
    end
    if type(t.from) == "string" and t.from ~= "*" and not config.states[t.from] then
      return nil, "transition #" .. i .. " references unknown state '" .. t.from .. "'"
    end
    if type(t.from) == "table" then
      local from_list = t.from --[[: { [integer]: string }]]
      for j = 1, #from_list do
        if not config.states[from_list[j]] then
          return nil, "transition #" .. i .. " references unknown state '" .. from_list[j] .. "'"
        end
      end
    end
  end

  -- Build transition lookup: [state][event] = { to = ... }
  -- Also build wildcard lookup: ["*"][event] = { to = ... }
  local lookup = {} --: { [string]: { [string]: { to: string } } }
  for i = 1, #config.transitions do
    local t = config.transitions[i]
    local sources
    if type(t.from) == "table" then
      sources = t.from --[[: { [integer]: string }]]
    else
      sources = { t.from --[[: string]] } --[[: { [integer]: string }]]
    end
    for j = 1, #sources do
      local s = sources[j]
      if not lookup[s] then lookup[s] = {} end
      lookup[s][t.event] = { to = t.to }
    end
  end

  local machine = setmetatable({
    _config = config,
    _lookup = lookup,
    _guards = config.guards or {},
    _actions = config.actions or {},
    _listeners = {},
  }, Machine) --[[: Machine]]
  return machine
end

--: (self: Machine) -> { [integer]: string }
function Machine:states()
  local result = {} --: { [integer]: string }
  for name in pairs(self._config.states) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

--: (self: Machine) -> { [integer]: string }
function Machine:events()
  local seen = {} --: { [string]: boolean }
  local result = {} --: { [integer]: string }
  for i = 1, #self._config.transitions do
    local ev = self._config.transitions[i].event
    if not seen[ev] then
      seen[ev] = true
      result[#result + 1] = ev
    end
  end
  return result
end

--: (self: Machine, state: string) -> { [integer]: { event: string, to: string } }
function Machine:transitions_from(state)
  local result = {} --: { [integer]: { event: string, to: string } }
  for i = 1, #self._config.transitions do
    local t = self._config.transitions[i]
    local matches = false
    if type(t.from) == "table" then
      local from_list = t.from --[[: { [integer]: string }]]
      for j = 1, #from_list do
        if from_list[j] == state then matches = true; break end
      end
    elseif t.from == state or t.from == "*" then
      matches = true
    end
    if matches then
      result[#result + 1] = { event = t.event, to = t.to }
    end
  end
  return result
end

--: (self: Machine, fn: (from: string, to: string, event: string, ctx: { [string]: unknown }) -> nil) -> nil
function Machine:on_transition(fn)
  self._listeners[#self._listeners + 1] = fn
end

--: (self: Machine, ctx: ({ [string]: unknown } | nil)) -> Instance
function Machine:start(ctx)
  local instance = setmetatable({
    _machine = self,
    _state = self._config.initial,
    _ctx = ctx or {},
    _history = { self._config.initial },
  }, Instance) --[[: Instance]]
  -- Fire on_enter for initial state
  local state_def = self._config.states[self._config.initial]
  if state_def and state_def.on_enter then
    state_def.on_enter(instance._ctx)
  end
  return instance
end

--: (self: Instance) -> string
function Instance:state()
  return self._state
end

--: (self: Instance) -> { [string]: unknown }
function Instance:context()
  return self._ctx
end

--: (self: Instance, ctx: { [string]: unknown }) -> nil
function Instance:set_context(ctx)
  self._ctx = ctx
end

--: (self: Instance) -> { [integer]: string }
function Instance:history()
  local result = {} --: { [integer]: string }
  for i = 1, #self._history do
    result[i] = self._history[i]
  end
  return result
end

-- Find the transition definition for current state + event
--: (machine: Machine, current_state: string, event: string) -> { to: string } | nil
local function find_transition(machine, current_state, event)
  local lookup = machine._lookup
  -- Check specific state first
  local state_events = lookup[current_state]
  if state_events and state_events[event] then
    return state_events[event]
  end
  -- Check wildcard
  local wild = lookup["*"]
  if wild and wild[event] then
    return wild[event]
  end
  return nil
end

--: (self: Instance, event: string) -> boolean
function Instance:can(event)
  local t = find_transition(self._machine, self._state, event)
  if not t then return false end
  -- Check guard
  local guard = self._machine._guards[event]
  if guard and not guard(self._ctx, nil) then
    return false
  end
  return true
end

--: (self: Instance, event: string, data: unknown) -> (boolean | nil, string | nil)
function Instance:send(event, data)
  local t = find_transition(self._machine, self._state, event)
  if not t then
    return nil, "no transition from '" .. self._state .. "' on event '" .. event .. "'"
  end

  -- Check guard
  local guard = self._machine._guards[event]
  if guard and not guard(self._ctx, data) then
    return nil, "guard rejected transition on event '" .. event .. "'"
  end

  local from = self._state
  local to = t.to

  -- on_exit for current state
  local from_def = self._machine._config.states[from]
  if from_def and from_def.on_exit then
    from_def.on_exit(self._ctx)
  end

  -- Run action
  local action = self._machine._actions[event]
  if action then
    action(self._ctx, data)
  end

  -- Transition
  self._state = to
  self._history[#self._history + 1] = to

  -- on_enter for new state
  local to_def = self._machine._config.states[to]
  if to_def and to_def.on_enter then
    to_def.on_enter(self._ctx)
  end

  -- Notify listeners
  local listeners = self._machine._listeners
  for i = 1, #listeners do
    listeners[i](from, to, event, self._ctx)
  end

  return true
end

return M
