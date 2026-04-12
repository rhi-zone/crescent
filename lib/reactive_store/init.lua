-- lib/reactive_store/init.lua
-- Redux/Zustand-inspired reactive state store.
-- Pure Lua, no dependencies.
--
-- Features: actions, reducers, middleware, memoized selectors, derived state,
-- time-travel debugging, immutable update helpers, combine/slice helpers,
-- logger/thunk/batch middleware.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Immutable update helpers ───────────────────────────────────────────────

-- Shallow merge: returns a new table that is state with keys from patch applied.
M.update = function(state, patch)
  local next = {}
  for k, v in pairs(state) do next[k] = v end
  for k, v in pairs(patch) do next[k] = v end
  return next
end

-- Navigate into nested tables following path, return value (or nil).
M.get_in = function(state, path)
  local cur = state
  for i = 1, #path do
    if type(cur) ~= "table" then return nil end
    cur = cur[path[i]]
  end
  return cur
end

-- Return a new state with the value at path updated via fn(old_val)->new_val.
-- Creates intermediate tables as needed (shallow copies).
M.update_in = function(state, path, fn)
  if #path == 0 then return fn(state) end
  if #path == 1 then
    local root = {}
    if type(state) == "table" then
      for k, v in pairs(state) do root[k] = v end
    end
    root[path[1]] = fn(type(state) == "table" and state[path[1]] or nil)
    return root
  end
  -- Build array of copies, one per path level.
  local copies = {}
  local cur = state
  for i = 1, #path - 1 do
    local copy = {}
    if type(cur) == "table" then
      for k, v in pairs(cur) do copy[k] = v end
    end
    copies[i] = copy
    cur = type(cur) == "table" and cur[path[i]] or nil
  end
  -- Leaf copy
  local leaf_copy = {}
  if type(cur) == "table" then
    for k, v in pairs(cur) do leaf_copy[k] = v end
  end
  leaf_copy[path[#path]] = fn(type(cur) == "table" and cur[path[#path]] or nil)
  -- Stitch back up: set each copy's key to the copy below it.
  local result = leaf_copy
  for i = #path - 1, 1, -1 do
    copies[i][path[i]] = result
    result = copies[i]
  end
  return result
end

-- ── Action creators ────────────────────────────────────────────────────────

-- Create an action creator function.
-- M.action(type_str, payload_fn?) -> creator_fn
-- creator_fn(...) -> { type = type_str, ...payload }
M.action = function(type_str, payload_fn)
  if type(type_str) ~= "string" then
    return nil, "action: type must be a string"
  end
  return function(...)
    local act = { type = type_str }
    if payload_fn then
      local payload = payload_fn(...)
      if type(payload) == "table" then
        for k, v in pairs(payload) do
          if k ~= "type" then act[k] = v end
        end
      end
    end
    return act
  end
end

-- Build a proxy table whose fields return namespaced type strings.
-- AT = M.action_type("todos")  →  AT.ADD == "todos/ADD"
M.action_type = function(prefix)
  return setmetatable({}, {
    __index = function(_, key)
      return prefix .. "/" .. key
    end,
  })
end

-- ── Reducer combiners ──────────────────────────────────────────────────────

-- Combine multiple sub-reducers into one.
-- Each sub-reducer receives state[key] and returns state[key].
M.combine = function(reducers)
  return function(state, action)
    state = state or {}
    local changed = false
    local next = {}
    for key, reducer in pairs(reducers) do
      local prev = state[key]
      local cur = reducer(prev, action)
      next[key] = cur
      if cur ~= prev then changed = true end
    end
    return changed and next or state
  end
end

-- Create a slice: { reducer, actions }.
-- opts: { name, initial_state, reducers = { action_name = fn(state, action) } }
-- Generates action creators at actions.ACTION_NAME (upper-cased action_name).
M.slice = function(opts)
  local name = opts.name
  local initial = opts.initial_state
  local case_reducers = opts.reducers or {}

  -- Build action creators and type->handler map
  local type_map = {}   -- "name/action_name" -> handler_fn
  local actions = {}    -- actions.ACTION_NAME = creator_fn

  for action_name, handler in pairs(case_reducers) do
    local type_str = name .. "/" .. action_name
    type_map[type_str] = handler
    local key = action_name:upper()
    actions[key] = M.action(type_str, function(payload) return payload end)
  end

  local function reducer(state, action)
    if state == nil then state = initial end
    if action == nil then return state end
    local handler = type_map[action.type]
    if handler then
      return handler(state, action)
    end
    return state
  end

  return { reducer = reducer, actions = actions }
end

-- ── Store ──────────────────────────────────────────────────────────────────

-- Build the dispatch chain from middleware list.
-- Each middleware: fn(store_api) -> fn(next) -> fn(action)
local function apply_middleware(store, middlewares, base_dispatch)
  if #middlewares == 0 then return base_dispatch end
  local store_api = {
    get_state = function() return store:get_state() end,
    dispatch  = function(action) return store:dispatch(action) end,
  }
  local dispatch = base_dispatch
  for i = #middlewares, 1, -1 do
    local mw = middlewares[i](store_api)
    local prev = dispatch
    dispatch = mw(prev)
  end
  return dispatch
end

-- M.store(reducer, initial_state, opts) -> store
M.store = function(reducer, initial_state, opts)
  opts = opts or {}
  local middlewares = opts.middleware or {}

  local _subscribers = {}    -- array of fn(state, action)
  local _history = {}        -- array of { action, state }
  local _batching = false    -- when true, subscriber calls are buffered
  local _batch_pending       -- last {state, action} during batch (or nil)
  local _dispatch_fn         -- set after middleware wrapping

  -- Initialize state: call reducer with initial_state and @@INIT action.
  -- This lets reducers with inline defaults (state = state or default) initialize.
  local _state = reducer(initial_state, { type = "@@INIT" })

  -- Notify subscribers (or buffer if batching).
  local function notify(state, action)
    if _batching then
      _batch_pending = { state = state, action = action }
      return
    end
    for i = 1, #_subscribers do
      _subscribers[i](state, action)
    end
  end

  -- Base dispatch (no middleware)
  local function base_dispatch(action)
    if type(action) ~= "table" then
      return nil, "dispatch: action must be a table"
    end
    if type(action.type) ~= "string" then
      return nil, "dispatch: action.type must be a string"
    end
    local next_state = reducer(_state, action)
    _state = next_state
    _history[#_history + 1] = { action = action, state = _state }
    notify(_state, action)
    return store
  end

  local store = {}

  store.history = _history

  store.dispatch = function(_, action)
    return _dispatch_fn(action)
  end

  store.get_state = function(_)
    return _state
  end

  store.subscribe = function(_, fn)
    _subscribers[#_subscribers + 1] = fn
    local removed = false
    return function()
      if removed then return end
      removed = true
      for i = 1, #_subscribers do
        if _subscribers[i] == fn then
          table.remove(_subscribers, i)
          return
        end
      end
    end
  end

  store.get_state_at = function(_, action_index)
    if _history[action_index] then
      return _history[action_index].state
    end
    return nil, "get_state_at: no history at index " .. tostring(action_index)
  end

  -- Internal batch control (used by M.batch.actions)
  store._begin_batch = function()
    _batching = true
    _batch_pending = nil
  end

  store._end_batch = function()
    _batching = false
    if _batch_pending then
      local s, a = _batch_pending.state, _batch_pending.action
      _batch_pending = nil
      for i = 1, #_subscribers do
        _subscribers[i](s, a)
      end
    end
  end

  -- Wrap dispatch with middleware
  _dispatch_fn = apply_middleware(store, middlewares, base_dispatch)

  return store
end

-- ── Selectors ─────────────────────────────────────────────────────────────

-- Memoized selector: caches last result based on state reference equality.
-- M.selector(fn) -> memoized_fn
-- The memoized_fn(state, ...) recomputes when state reference or args differ.
M.selector = function(fn)
  local last_state  = nil
  local last_args   = {}
  local last_result = nil
  local first_call  = true

  return function(state, ...)
    local args = {...}
    local same = not first_call and state == last_state and #args == #last_args
    if same then
      for i = 1, #args do
        if args[i] ~= last_args[i] then same = false; break end
      end
    end
    if not same then
      last_result = fn(state, ...)
      last_state  = state
      last_args   = args
      first_call  = false
    end
    return last_result
  end
end

-- Derived state: subscribes to a store and tracks a selector's result.
-- M.derived(store, selector_fn) -> { get(), subscribe(fn) -> unsub }
M.derived = function(store, selector_fn)
  local memo  = M.selector(selector_fn)
  local _subs = {}

  local function current()
    return memo(store:get_state())
  end

  local last_val = current()

  -- Subscribe to store; only notify derived subscribers when value changes.
  store:subscribe(function(state, _action)
    local new_val = memo(state)
    if new_val ~= last_val then
      last_val = new_val
      for i = 1, #_subs do
        _subs[i](new_val)
      end
    end
  end)

  local derived = {}

  derived.get = function()
    return current()
  end

  derived.subscribe = function(fn)
    _subs[#_subs + 1] = fn
    local removed = false
    return function()
      if removed then return end
      removed = true
      for i = 1, #_subs do
        if _subs[i] == fn then
          table.remove(_subs, i)
          return
        end
      end
    end
  end

  return derived
end

-- ── Middleware ─────────────────────────────────────────────────────────────

-- Logger middleware: logs each action and resulting state.
-- opts: { output = fn(msg) }  defaults to print
M.logger = function(opts)
  opts = opts or {}
  local output = opts.output or print
  return function(store_api)
    return function(next)
      return function(action)
        if type(action) == "table" then
          output("dispatching: " .. tostring(action.type))
        end
        local result = next(action)
        output("next state: " .. tostring(store_api.get_state()))
        return result
      end
    end
  end
end

-- Thunk middleware: allows dispatch of functions.
-- fn(dispatch, get_state) -> any
M.thunk = function()
  return function(store_api)
    return function(next)
      return function(action)
        if type(action) == "function" then
          return action(store_api.dispatch, store_api.get_state)
        end
        return next(action)
      end
    end
  end
end

-- Batch: M.batch.actions(store, fn) — dispatch multiple actions but notify
-- subscribers only once with the final state.
-- Also exposes M.batch.middleware() as a no-op middleware placeholder for
-- stores that want to declare batch usage explicitly in their middleware list.
M.batch = {
  -- middleware is a no-op; batching is controlled via _begin_batch/_end_batch.
  middleware = function()
    return function(_store_api)
      return function(next)
        return function(action)
          return next(action)
        end
      end
    end
  end,

  -- Run fn; hold subscriber notifications until fn returns, then fire once.
  actions = function(store, fn)
    store._begin_batch()
    local ok, err = pcall(fn)
    store._end_batch()
    if not ok then
      return nil, err
    end
    return true
  end,
}

return M
