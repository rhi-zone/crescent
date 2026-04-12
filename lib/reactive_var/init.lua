-- lib/reactive_var/init.lua
-- Fine-grained reactive variable system (MobX/SolidJS/Vue Reactivity style).
-- Provides: var, computed, memo, effect, autorun, watch, batch, untracked,
--           reactive list, reactive map.
--
-- Distinct from lib/signals (which uses S.create / S.peek naming) and
-- lib/reactive (which uses explicit dependency arrays, not auto-tracking).
--
-- API:
--   local R = require("lib.reactive_var")
--   local x = R.var(0)          -- writable reactive variable
--   x()                          -- read (tracked)
--   x(5)                         -- write
--   x:get()                      -- explicit read
--   x:set(10)                    -- explicit write
--   local d = R.computed(fn)     -- lazy derived value
--   local stop = R.effect(fn)    -- run fn now, re-run on change; stop() disposes
--   local stop = R.autorun(fn)   -- alias for effect
--   local stop = R.watch(v, fn)  -- watch(source, fn(new, old)) explicit watcher
--   R.batch(fn)                  -- defer effects until fn completes
--   R.untracked(fn)              -- read inside fn without creating dependencies
--   local list = R.list(t)       -- reactive ordered list
--   local map  = R.map(t)        -- reactive key-value map

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Global scheduler state
-- ---------------------------------------------------------------------------

local _stack         = {}   -- stack[i] = active subscriber (effect/computed)
local _batch_depth   = 0
local _pending       = {}   -- { [eff] = true } effects queued during batch
local _flushing      = false
local _queued        = {}   -- effects queued during a single non-batch write

local function _push(sub) _stack[#_stack + 1] = sub end
local function _pop()     _stack[#_stack] = nil      end
local function _current() return _stack[#_stack]     end

-- ---------------------------------------------------------------------------
-- Tracking: link a reactive node to the current subscriber
-- ---------------------------------------------------------------------------

local function _track(node)
  local sub = _current()
  if sub and sub._kind ~= "untrack" then
    node._subs[sub] = true
    sub._deps[node] = true
  end
end

-- ---------------------------------------------------------------------------
-- Forward declarations
-- ---------------------------------------------------------------------------

local run_effect   -- defined below; referenced by _propagate

-- ---------------------------------------------------------------------------
-- Propagation: mark computeds dirty, collect effects
-- ---------------------------------------------------------------------------

local function _propagate(node)
  for sub in pairs(node._subs) do
    if sub._kind == "computed" then
      if not sub._dirty then
        sub._dirty = true
        _propagate(sub)   -- transitively dirty downstream computeds
      end
    elseif sub._kind == "effect" then
      if not sub._disposed then
        if _batch_depth > 0 then
          _pending[sub] = true
        else
          _queued[sub] = true
        end
      end
    end
  end
end

-- Notify: propagate, then run collected effects (only outside batch)
local function _notify(node)
  _propagate(node)
  if _batch_depth > 0 then return end
  if _flushing then return end
  _flushing = true
  while next(_queued) do
    local snap = {}
    for eff in pairs(_queued) do snap[#snap + 1] = eff end
    _queued = {}
    for i = 1, #snap do
      if not snap[i]._disposed then run_effect(snap[i]) end
    end
  end
  _flushing = false
end

-- Flush pending effects at end of batch
local function _flush_pending()
  while next(_pending) do
    local snap = {}
    for eff in pairs(_pending) do snap[#snap + 1] = eff end
    _pending = {}
    for i = 1, #snap do
      if not snap[i]._disposed then run_effect(snap[i]) end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Effect runner: rebuild dependency links on each run
-- ---------------------------------------------------------------------------

run_effect = function(eff)
  if eff._disposed then return end
  for dep in pairs(eff._deps) do dep._subs[eff] = nil end
  eff._deps = {}
  _push(eff)
  local ok, err = pcall(eff._fn)
  _pop()
  if not ok then error(err, 0) end
end

-- ---------------------------------------------------------------------------
-- Var metatable: callable + :get/:set methods
-- ---------------------------------------------------------------------------

local VarMT = {}
VarMT.__index = VarMT

function VarMT:get()
  _track(self._node)
  return self._node._value
end

function VarMT:set(new_val)
  local node = self._node
  local old = node._value
  if old == new_val then return end
  node._value = new_val
  -- Fire explicit watch listeners synchronously (before reactive effects)
  for _, entry in pairs(node._watches) do
    entry(new_val, old)
  end
  _notify(node)
end

function VarMT:__call(new_val)
  if new_val == nil then
    return self:get()
  else
    self:set(new_val)
  end
end

-- ---------------------------------------------------------------------------
-- R.var(initial) → writable reactive variable
-- ---------------------------------------------------------------------------

function M.var(initial)
  local node = {
    _value   = initial,
    _subs    = {},   -- { [sub_obj] = true }
    _watches = {},   -- { [id] = fn(new, old) }
    _watch_id = 0,
  }
  return setmetatable({ _node = node, _kind = "var" }, VarMT)
end

-- ---------------------------------------------------------------------------
-- Computed metatable
-- ---------------------------------------------------------------------------

local ComputedMT = {}
ComputedMT.__index = ComputedMT

function ComputedMT:get()
  local node = self._node
  _track(node)
  if node._dirty then
    if node._computing then
      -- Circular dep guard: return stale value
      return node._value
    end
    -- Rebuild deps
    for dep in pairs(node._deps) do dep._subs[node] = nil end
    node._deps      = {}
    node._dirty     = false
    node._computing = true
    _push(node)
    local ok, result = pcall(node._fn)
    _pop()
    node._computing = false
    if ok then
      node._value = result
    else
      node._dirty = true
      error(result, 0)
    end
  end
  return node._value
end

function ComputedMT:__call()
  return self:get()
end

-- ---------------------------------------------------------------------------
-- R.computed(fn) → lazy read-only derived value
-- ---------------------------------------------------------------------------

function M.computed(fn)
  local node = {
    _kind      = "computed",
    _fn        = fn,
    _value     = nil,
    _dirty     = true,
    _computing = false,
    _deps      = {},
    _subs      = {},
  }
  return setmetatable({ _node = node, _kind = "computed" }, ComputedMT)
end

-- R.memo is an alias for R.computed
M.memo = M.computed

-- ---------------------------------------------------------------------------
-- R.effect(fn) → stop() — run fn immediately, re-run on dependency change
-- ---------------------------------------------------------------------------

function M.effect(fn)
  local eff = {
    _kind     = "effect",
    _fn       = fn,
    _deps     = {},
    _disposed = false,
  }
  run_effect(eff)
  return function()
    if eff._disposed then return end
    eff._disposed = true
    for dep in pairs(eff._deps) do dep._subs[eff] = nil end
    eff._deps = {}
    _pending[eff] = nil
    _queued[eff]  = nil
  end
end

-- R.autorun is an alias for R.effect
M.autorun = M.effect

-- ---------------------------------------------------------------------------
-- R.watch(source, fn(new, old)) → stop() — explicit watcher on a Var
-- ---------------------------------------------------------------------------

function M.watch(source_var, fn)
  local node = source_var._node
  node._watch_id = node._watch_id + 1
  local id = node._watch_id
  node._watches[id] = fn
  return function()
    node._watches[id] = nil
  end
end

-- ---------------------------------------------------------------------------
-- R.batch(fn) — defer effect execution until fn completes
-- ---------------------------------------------------------------------------

function M.batch(fn)
  _batch_depth = _batch_depth + 1
  local ok, err = pcall(fn)
  _batch_depth = _batch_depth - 1
  if _batch_depth == 0 then
    _flush_pending()
  end
  if not ok then error(err, 2) end
end

-- ---------------------------------------------------------------------------
-- R.untracked(fn) — execute fn without registering any dependencies
-- ---------------------------------------------------------------------------

function M.untracked(fn)
  local sentinel = { _kind = "untrack", _deps = {} }
  _push(sentinel)
  local ok, result = pcall(fn)
  _pop()
  -- Clean up any accidental links
  for dep in pairs(sentinel._deps) do dep._subs[sentinel] = nil end
  if not ok then error(result, 2) end
  return result
end

-- ---------------------------------------------------------------------------
-- Reactive List
-- ---------------------------------------------------------------------------

local ListMT = {}
ListMT.__index = ListMT

-- Internal: mark the list node dirty and notify subscribers
local function _list_notify(self)
  _notify(self._node)
end

function ListMT:get(i)
  _track(self._node)
  return self._data[i]
end

function ListMT:set(i, v)
  self._data[i] = v
  _list_notify(self)
end

function ListMT:push(v)
  self._data[#self._data + 1] = v
  _list_notify(self)
end

function ListMT:pop()
  local data = self._data
  local n = #data
  if n == 0 then return nil end
  local v = data[n]
  data[n] = nil
  _list_notify(self)
  return v
end

function ListMT:length()
  _track(self._node)
  return #self._data
end

function ListMT:to_array()
  _track(self._node)
  local copy = {}
  for i = 1, #self._data do copy[i] = self._data[i] end
  return copy
end

-- R.list(t) → reactive list (1-indexed)
function M.list(t)
  local data = {}
  if t then
    for i = 1, #t do data[i] = t[i] end
  end
  local node = { _value = nil, _subs = {} }
  return setmetatable({ _node = node, _data = data }, ListMT)
end

-- ---------------------------------------------------------------------------
-- Reactive Map
-- ---------------------------------------------------------------------------

local MapMT = {}
MapMT.__index = MapMT

local function _map_notify(self)
  _notify(self._node)
end

function MapMT:get(k)
  _track(self._node)
  return self._data[k]
end

function MapMT:set(k, v)
  self._data[k] = v
  _map_notify(self)
end

function MapMT:delete(k)
  self._data[k] = nil
  _map_notify(self)
end

function MapMT:has(k)
  _track(self._node)
  return self._data[k] ~= nil
end

function MapMT:keys()
  _track(self._node)
  local ks = {}
  for k in pairs(self._data) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

function MapMT:size()
  _track(self._node)
  local n = 0
  for _ in pairs(self._data) do n = n + 1 end
  return n
end

-- R.map(t) → reactive map
function M.map(t)
  local data = {}
  if t then
    for k, v in pairs(t) do data[k] = v end
  end
  local node = { _value = nil, _subs = {} }
  return setmetatable({ _node = node, _data = data }, MapMT)
end

return M
