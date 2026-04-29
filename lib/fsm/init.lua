if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Machine prototype (definition)
local Machine = {}
Machine.__index = Machine

-- Instance prototype (running machine)
local Instance = {}
Instance.__index = Instance

--: (config: { initial: string, states: { [string]: { on_enter: (((ctx: { [string]: unknown }) -> nil) | nil), on_exit: (((ctx: { [string]: unknown }) -> nil) | nil) } }, transitions: { from: string | { [number]: string }, to: string, event: string }[], guards: ({ [string]: (ctx: { [string]: unknown }, event_data: unknown) -> boolean } | nil), actions: ({ [string]: (ctx: { [string]: unknown }, event_data: unknown) -> nil } | nil) }) -> Machine | (nil, string)
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
      for j = 1, #t.from do
        if not config.states[t.from[j]] then
          return nil, "transition #" .. i .. " references unknown state '" .. t.from[j] .. "'"
        end
      end
    end
  end

  -- Build transition lookup: [state][event] = { to = ... }
  -- Also build wildcard lookup: ["*"][event] = { to = ... }
  local lookup = {}
  for i = 1, #config.transitions do
    local t = config.transitions[i]
    local sources
    if type(t.from) == "table" then
      sources = t.from
    else
      sources = { t.from }
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
  }, Machine)
  return machine
end

--: () -> { [number]: string }
function Machine:states()
  local result = {}
  for name in pairs(self._config.states) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

--: () -> { [number]: string }
function Machine:events()
  local seen = {}
  local result = {}
  for i = 1, #self._config.transitions do
    local ev = self._config.transitions[i].event
    if not seen[ev] then
      seen[ev] = true
      result[#result + 1] = ev
    end
  end
  return result
end

--: (state: string) -> { [number]: { event: string, to: string } }
function Machine:transitions_from(state)
  local result = {}
  for i = 1, #self._config.transitions do
    local t = self._config.transitions[i]
    local matches = false
    if type(t.from) == "table" then
      for j = 1, #t.from do
        if t.from[j] == state then matches = true; break end
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

--: (fn: (from: string, to: string, event: string, ctx: { [string]: unknown }) -> nil) -> nil
function Machine:on_transition(fn)
  self._listeners[#self._listeners + 1] = fn
end

--: (ctx: ({ [string]: unknown } | nil)) -> Instance
function Machine:start(ctx)
  local instance = setmetatable({
    _machine = self,
    _state = self._config.initial,
    _ctx = ctx or {},
    _history = { self._config.initial },
  }, Instance)
  -- Fire on_enter for initial state
  local state_def = self._config.states[self._config.initial]
  if state_def and state_def.on_enter then
    state_def.on_enter(instance._ctx)
  end
  return instance
end

--: () -> string
function Instance:state()
  return self._state
end

--: () -> { [string]: unknown }
function Instance:context()
  return self._ctx
end

--: (ctx: { [string]: unknown }) -> nil
function Instance:set_context(ctx)
  self._ctx = ctx
end

--: () -> { [number]: string }
function Instance:history()
  local result = {}
  for i = 1, #self._history do
    result[i] = self._history[i]
  end
  return result
end

-- Find the transition definition for current state + event
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

--: (event: string) -> boolean
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

--: (event: string, data: (unknown | nil)) -> true | (nil, string)
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
