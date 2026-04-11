if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Event emitter / pub-sub library.
-- Register named event listeners, emit events, support wildcards, once
-- listeners, priority ordering, and propagation control.

local M = {}

--:: Listener = { fn: (...unknown) -> unknown, priority: number, once: boolean, id: number }

local Emitter = {}
Emitter.__index = Emitter

local _next_id = 0

--- Create a new event emitter.
--: () -> Emitter
function M.new()
  local self = setmetatable({}, Emitter)
  self._listeners = {} --: { [string]: { Listener } }
  return self
end

--- Convert a wildcard pattern to a Lua pattern.
-- Only supports trailing `*` after a dot, e.g. `user.*` or bare `*`.
--: (string) -> string
local function wildcard_to_pattern(pattern)
  if pattern == "*" then return "^.+$" end
  -- Split off the trailing * before escaping
  local prefix = pattern:sub(1, -2) -- everything except trailing *
  -- Escape all Lua magic characters in the prefix
  local escaped = prefix:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  return "^" .. escaped .. ".+" .. "$"
end

--- Check if a pattern string contains a wildcard.
--: (string) -> boolean
local function is_wildcard(name)
  return name:find("*", 1, true) ~= nil
end

--- Insert listener into a sorted array by priority (descending).
--: ({ Listener }, Listener) -> ()
local function insert_sorted(arr, entry)
  local p = entry.priority
  for i = 1, #arr do
    if p > arr[i].priority then
      table.insert(arr, i, entry)
      return
    end
  end
  arr[#arr + 1] = entry
end

--- Register a listener for an event name (or wildcard pattern).
-- Returns a unique listener id for later removal via off_by_id.
--: (string, (...unknown) -> unknown, { priority: number }?) -> number
function Emitter:on(name, fn, opts)
  if type(name) ~= "string" then return nil, "event name must be a string" end
  if type(fn) ~= "function" then return nil, "listener must be a function" end
  _next_id = _next_id + 1
  local id = _next_id
  local priority = (opts and opts.priority) or 0
  local once = (opts and opts.once) or false
  local entry = { fn = fn, priority = priority, once = once, id = id }
  local listeners = self._listeners[name]
  if not listeners then
    listeners = {}
    self._listeners[name] = listeners
  end
  insert_sorted(listeners, entry)
  return id
end

--- Register a listener that fires only once.
--: (string, (...unknown) -> unknown, { priority: number }?) -> number
function Emitter:once(name, fn, opts)
  local o = { once = true }
  if opts then o.priority = opts.priority end
  return self:on(name, fn, o)
end

--- Remove listener(s).
-- off(name, fn) removes a specific listener.
-- off(name) removes all listeners for that event.
--: (string, ((...unknown) -> unknown)?) -> ()
function Emitter:off(name, fn)
  if type(name) ~= "string" then return nil, "event name must be a string" end
  if not fn then
    self._listeners[name] = nil
    return
  end
  local listeners = self._listeners[name]
  if not listeners then return end
  for i = #listeners, 1, -1 do
    if listeners[i].fn == fn then
      table.remove(listeners, i)
    end
  end
  if #listeners == 0 then
    self._listeners[name] = nil
  end
end

--- Remove a listener by its unique id.
--: (number) -> boolean
function Emitter:off_by_id(id)
  for name, listeners in pairs(self._listeners) do
    for i = #listeners, 1, -1 do
      if listeners[i].id == id then
        table.remove(listeners, i)
        if #listeners == 0 then
          self._listeners[name] = nil
        end
        return true
      end
    end
  end
  return false
end

--- Event object passed to listeners for propagation control.
local Event = {}
Event.__index = Event

--: () -> Event
local function new_event(name, args)
  return setmetatable({ name = name, args = args, _stopped = false }, Event)
end

--- Stop propagation to remaining listeners.
--: () -> ()
function Event:stop()
  self._stopped = true
end

--- Emit an event, calling all matching listeners.
-- Exact-match listeners run first, then wildcard listeners.
-- Returns true if any listener was called, false otherwise.
--: (string, ...unknown) -> boolean
function Emitter:emit(name, ...)
  if type(name) ~= "string" then return nil, "event name must be a string" end
  local evt = new_event(name, { ... })
  local called = false

  -- Collect all matching listener entries: exact match first, then wildcards.
  local to_call = {}
  local exact = self._listeners[name]
  if exact then
    for i = 1, #exact do
      to_call[#to_call + 1] = { entry = exact[i], key = name }
    end
  end

  -- Wildcard matches
  for pattern, listeners in pairs(self._listeners) do
    if pattern ~= name and is_wildcard(pattern) then
      local lua_pat = wildcard_to_pattern(pattern)
      if name:find(lua_pat) then
        for i = 1, #listeners do
          to_call[#to_call + 1] = { entry = listeners[i], key = pattern }
        end
      end
    end
  end

  -- Sort all collected entries by priority (descending), stable within group
  -- Since exact and wildcard groups are each already sorted by priority,
  -- we do a simple sort here.
  if #to_call > 1 then
    -- Stable sort: preserve insertion order for equal priorities
    for i = 1, #to_call do
      to_call[i]._order = i
    end
    table.sort(to_call, function(a, b)
      if a.entry.priority ~= b.entry.priority then
        return a.entry.priority > b.entry.priority
      end
      return a._order < b._order
    end)
  end

  -- Call listeners, handling once and stop propagation
  for i = 1, #to_call do
    local item = to_call[i]
    local entry = item.entry
    -- Check if entry was already removed (e.g. by a previous listener calling off)
    local key_listeners = self._listeners[item.key]
    if key_listeners then
      local still_present = false
      for j = 1, #key_listeners do
        if key_listeners[j] == entry then
          still_present = true
          break
        end
      end
      if still_present then
        called = true
        entry.fn(evt, ...)
        if entry.once then
          -- Remove the once listener
          for j = #key_listeners, 1, -1 do
            if key_listeners[j] == entry then
              table.remove(key_listeners, j)
              break
            end
          end
          if #key_listeners == 0 then
            self._listeners[item.key] = nil
          end
        end
        if evt._stopped then break end
      end
    end
  end

  return called
end

--- Return an array of listener functions for a given event name.
-- Only returns exact-match listeners (not wildcard).
--: (string) -> { ((...unknown) -> unknown) }
function Emitter:listeners(name)
  local result = {}
  local listeners = self._listeners[name]
  if listeners then
    for i = 1, #listeners do
      result[#result + 1] = listeners[i].fn
    end
  end
  return result
end

--- Return the count of listeners for a given event name.
--: (string) -> number
function Emitter:listener_count(name)
  local listeners = self._listeners[name]
  return listeners and #listeners or 0
end

--- Return an array of all event names that have listeners.
--: () -> { string }
function Emitter:event_names()
  local result = {}
  for name in pairs(self._listeners) do
    result[#result + 1] = name
  end
  table.sort(result)
  return result
end

--- Mixin: add event emitter methods to any table.
--: (table) -> table
function M.mixin(target)
  target._listeners = {}
  for k, v in pairs(Emitter) do
    if k ~= "__index" then
      target[k] = v
    end
  end
  return target
end

return M
