-- lib/entity_component/init.lua
-- Lightweight in-memory Entity-Component System (ECS) for LuaJIT.
--
-- Features:
--   - Components registered with optional default values
--   - Entities are plain integer IDs
--   - query() iterates entities having ALL specified components
--   - Systems are (component-list, fn) descriptors; world:run() applies them
--   - Simple event bus (on/emit) with built-in lifecycle events
--   - Multiple independent worlds
--   - Pure Lua — no FFI, no external deps
--
-- Lifecycle events emitted automatically:
--   "entity_created"    (entity)
--   "entity_destroyed"  (entity)
--   "component_added"   (entity, name)
--   "component_removed" (entity, name)

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Deep-copy a table (one level deep — component defaults are shallow records)
local function shallow_copy(t)
  if t == nil then return {} end
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

-- Merge src fields into dst, skipping keys already present
local function merge_defaults(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then dst[k] = v end
  end
end

-- ---------------------------------------------------------------------------
-- World
-- ---------------------------------------------------------------------------

local World = {}
World.__index = World

--- Create a new ECS world.
-- @return world
function M.world()
  local w = setmetatable({}, World)
  w._next_id    = 1          -- next entity ID counter
  w._alive      = {}         -- set: entity_id -> true
  w._components = {}         -- name -> { entity_id -> component_table }
  w._defaults   = {}         -- name -> default_table (shallow copy on add)
  w._listeners  = {}         -- event_name -> { fn, ... }
  return w
end

-- ---------------------------------------------------------------------------
-- Component registration
-- ---------------------------------------------------------------------------

--- Register a component type with optional default field values.
-- Must be called before world:add() uses this component name.
-- @param name   string  component name
-- @param defaults table|nil  default field values (shallow-copied on add)
function World:register(name, defaults)
  if self._components[name] == nil then
    self._components[name] = {}
  end
  self._defaults[name] = defaults or {}
end

-- ---------------------------------------------------------------------------
-- Entity lifecycle
-- ---------------------------------------------------------------------------

--- Create a new entity and return its integer ID.
function World:entity()
  local id = self._next_id
  self._next_id = id + 1
  self._alive[id] = true
  self:emit("entity_created", id)
  return id
end

--- Remove an entity and all its components.
function World:destroy(e)
  if not self._alive[e] then return end
  -- remove from every component store
  for name, store in pairs(self._components) do
    if store[e] ~= nil then
      store[e] = nil
      self:emit("component_removed", e, name)
    end
  end
  self._alive[e] = nil
  self:emit("entity_destroyed", e)
end

--- Remove all entities (and their components) from the world.
function World:clear()
  -- collect alive IDs first to avoid modifying during iteration
  local ids = {}
  for id in pairs(self._alive) do ids[#ids+1] = id end
  for _, id in ipairs(ids) do self:destroy(id) end
end

-- ---------------------------------------------------------------------------
-- Component mutation
-- ---------------------------------------------------------------------------

--- Add a component to an entity.
-- data is merged with the registered defaults; missing fields take defaults.
-- Errors: returns nil, errmsg if component not registered.
-- @param e     entity_id
-- @param name  string
-- @param data  table|nil  initial field values
-- @return true | nil, errmsg
function World:add(e, name, data)
  if not self._alive[e] then
    return nil, "entity " .. tostring(e) .. " does not exist"
  end
  if self._components[name] == nil then
    return nil, "component '" .. name .. "' not registered"
  end
  local comp = shallow_copy(data)
  merge_defaults(comp, self._defaults[name])
  self._components[name][e] = comp
  self:emit("component_added", e, name)
  return true
end

--- Remove a component from an entity.
-- No-op if entity doesn't have the component.
function World:remove(e, name)
  local store = self._components[name]
  if store and store[e] ~= nil then
    store[e] = nil
    self:emit("component_removed", e, name)
  end
end

--- Get a component table for an entity, or nil.
function World:get(e, name)
  local store = self._components[name]
  if store == nil then return nil end
  return store[e]
end

--- Return true if entity has the named component.
function World:has(e, name)
  local store = self._components[name]
  if store == nil then return false end
  return store[e] ~= nil
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Iterate entities that have ALL of the named components.
-- Yields: entity_id, c1, c2, ... (component tables in argument order).
-- Uses the first component's store as the candidate set (smallest heuristic
-- would require extra bookkeeping; first is simple and correct).
function World:query(...)
  local names = {...}
  local n = #names
  if n == 0 then
    -- yield all alive entities
    local ids = {}
    for id in pairs(self._alive) do ids[#ids+1] = id end
    local i = 0
    return function()
      i = i + 1
      return ids[i]
    end
  end

  -- gather stores
  local stores = {}
  for i = 1, n do
    local s = self._components[names[i]]
    if s == nil then
      -- component not registered → empty iterator
      return function() end
    end
    stores[i] = s
  end

  -- iterate candidates from first store
  local primary = stores[1]
  local candidates = {}
  for id in pairs(primary) do candidates[#candidates+1] = id end

  local idx = 0
  return function()
    while true do
      idx = idx + 1
      local e = candidates[idx]
      if e == nil then return nil end
      -- check remaining stores
      local ok = true
      for i = 2, n do
        if stores[i][e] == nil then ok = false; break end
      end
      if ok then
        -- build return values
        local comps = {}
        for i = 1, n do comps[i] = stores[i][e] end
        return e, unpack(comps)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Entity counting
-- ---------------------------------------------------------------------------

--- Count entities, optionally filtered to those having a component.
-- @param name  string|nil  if given, count entities with this component
-- @return integer
function World:count(name)
  if name == nil then
    local c = 0
    for _ in pairs(self._alive) do c = c + 1 end
    return c
  end
  local store = self._components[name]
  if store == nil then return 0 end
  local c = 0
  for _ in pairs(store) do c = c + 1 end
  return c
end

-- ---------------------------------------------------------------------------
-- Systems
-- ---------------------------------------------------------------------------

--- Create a system descriptor.
-- @param components  table of component names (strings)
-- @param fn          function(entity, c1, c2, ..., extra_args...)
-- @return system descriptor (opaque table)
function World:system(components, fn)
  return { components = components, fn = fn }
end

--- Run a system over all entities that match its component list.
-- Extra arguments (e.g. dt) are forwarded to the system function after
-- the component tables.
function World:run(sys, ...)
  local names = sys.components
  local fn    = sys.fn
  local n     = #names
  local args  = {...}
  local nargs = #args

  -- gather stores (same logic as query)
  local stores = {}
  for i = 1, n do
    local s = self._components[names[i]]
    if s == nil then return end
    stores[i] = s
  end

  local primary    = stores[1]
  local candidates = {}
  for id in pairs(primary) do candidates[#candidates+1] = id end

  for _, e in ipairs(candidates) do
    local ok = true
    for i = 2, n do
      if stores[i][e] == nil then ok = false; break end
    end
    if ok then
      -- build call: fn(e, c1, ..., cn, extra...)
      local call = {e}
      for i = 1, n do call[#call+1] = stores[i][e] end
      for i = 1, nargs do call[#call+1] = args[i] end
      fn(unpack(call))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

--- Register a listener for an event.
-- @param event  string
-- @param fn     function(...)
function World:on(event, fn)
  if not self._listeners[event] then
    self._listeners[event] = {}
  end
  local ls = self._listeners[event]
  ls[#ls+1] = fn
end

--- Emit an event, calling all registered listeners in order.
-- @param event  string
-- @param ...    arguments forwarded to listeners
function World:emit(event, ...)
  local ls = self._listeners[event]
  if ls == nil then return end
  for i = 1, #ls do ls[i](...) end
end

return M
