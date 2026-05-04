-- lib/signals: fine-grained reactive signals (SolidJS/Preact Signals style)
-- Pure Lua implementation. No external dependencies.
-- Note: lib/reactive is explicit-dependency push-based; lib/signals is auto-tracking.
--
-- API:
--   local S = require("lib.signals")
--   local count = S.create(0)
--   count()          -- read: 0
--   count(5)         -- write: set to 5
--   count:peek()     -- read without tracking (method form)
--   S.peek(count)    -- read without tracking (function form)
--   S.computed(fn)   -- lazy derived signal (read-only)
--   S.memo(fn)       -- alias for computed
--   S.effect(fn)     -- side-effect; returns stop()
--   S.batch(fn)      -- defer effect runs until fn completes
--   S.untrack(fn)    -- run fn without registering any dependencies
--   S.on(sig, fn)    -- explicit subscription; returns unsub()

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: EffNode = { _kind: string, _fn: () -> unknown, _deps: { [any]: boolean }, _subs: { [any]: boolean }, _disposed: boolean, _dirty: boolean, _computing: boolean, _value: unknown }
--:: SubNode = { _kind: string, _deps: { [any]: boolean }, _subs: { [any]: boolean }, _disposed: boolean, _dirty: boolean, _computing: boolean, _value: unknown }

-- ---------------------------------------------------------------------------
-- Subscriber stack and batch state
-- ---------------------------------------------------------------------------

--: { [integer]: SubNode }
local _stack  = {}             -- stack of active subscriber objects
local _batch_depth   = 0       -- nesting level of M.batch()
local _pending_effects = {}    -- effects queued during a batch: { [eff] = true }
local _flushing      = false   -- true while flush_effects is running (prevents re-entry glitch)
local _queued_effects = {}     -- effects collected during a single write's propagation pass

local function _push(sub) _stack[#_stack + 1] = sub end
local function _pop()     _stack[#_stack] = nil --[[: any]] end
local function _current() return _stack[#_stack]     end

-- ---------------------------------------------------------------------------
-- Internal: link a node to the current subscriber (if any, and not untrack)
-- ---------------------------------------------------------------------------

local function _track(node)
  local sub = _current()
  if sub and sub._kind ~= "untrack" then
    node._subs[sub] = true
    sub._deps[node] = true
  end
end

-- ---------------------------------------------------------------------------
-- Internal: run one effect (re-establishing dependencies)
-- ---------------------------------------------------------------------------

-- Forward declaration so _notify can call it before it is defined.
local run_effect

-- ---------------------------------------------------------------------------
-- Internal: notify downstream when a node's value may have changed
-- ---------------------------------------------------------------------------

-- _propagate: mark computeds dirty and collect effects; does NOT run effects.
local function _propagate(node)
  for sub, _ in pairs(node._subs) do
    if sub._kind == "computed" then
      if not sub._dirty then
        sub._dirty = true
        _propagate(sub)
      end
    elseif sub._kind == "effect" then
      if not sub._disposed then
        if _batch_depth > 0 then
          _pending_effects[sub] = true
        else
          _queued_effects[sub] = true
        end
      end
    end
  end
end

-- _notify: propagate dirty + run collected effects (for non-batch writes)
local function _notify(node)
  if _batch_depth > 0 then
    _propagate(node)
    return
  end
  -- Collect effects first (full propagation pass), then run them.
  -- This prevents glitches where an effect reads a computed before
  -- its upstream computed has been marked dirty.
  _propagate(node)
  if not _flushing then
    _flushing = true
    while next(_queued_effects) do
      --: { [integer]: EffNode }
      local snapshot = {}
      for eff, _ in pairs(_queued_effects) do
        snapshot[#snapshot + 1] = eff --[[: any]]
      end
      _queued_effects = {}
      for i = 1, #snapshot do
        local eff_ = snapshot[i] --[[:! EffNode]]
        if not eff_._disposed then
          run_effect(eff_)
        end
      end
    end
    _flushing = false
  end
end

-- ---------------------------------------------------------------------------
-- Effect runner
-- ---------------------------------------------------------------------------

run_effect = function(eff)
  if eff._disposed then return end
  -- Unlink from all current dependencies so they are rebuilt on this run
  for dep, _ in pairs(eff._deps) do
    local dep_ = dep --[[:! SubNode]]
    dep_._subs[eff] = nil
  end
  eff._deps = {}
  _push(eff)
  local ok, err = pcall(eff._fn)
  _pop()
  if not ok then
    error(err, 0)
  end
end

-- ---------------------------------------------------------------------------
-- Flush queued effects (called when outermost batch ends)
-- ---------------------------------------------------------------------------

local function flush_effects()
  while next(_pending_effects) do
    --: { [integer]: EffNode }
    local snapshot = {}
    for eff, _ in pairs(_pending_effects) do
      snapshot[#snapshot + 1] = eff --[[: any]]
    end
    _pending_effects = {}
    for i = 1, #snapshot do
      local eff_ = snapshot[i] --[[:! EffNode]]
      if not eff_._disposed then
        run_effect(eff_)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Signal metatable: tables callable via __call, with :peek() method
-- ---------------------------------------------------------------------------

local SignalMT = {}
SignalMT.__index = SignalMT

-- Read without creating a dependency (method form: sig:peek())
function SignalMT:peek()
  return self._state._value
end

-- Call the signal: () → read, (v) → write
function SignalMT:__call(new_val)
  local state = self._state
  if new_val == nil then
    -- READ
    _track(state)
    return state._value
  else
    -- WRITE
    local old = state._value
    if old == new_val then return end
    state._value = new_val
    -- Fire explicit on() listeners synchronously
    for _, fn in pairs(state._on) do
      local fn_ = fn --[[:! (unknown, unknown) -> nil]]
      fn_(new_val, old)
    end
    -- Notify reactive subscribers
    _notify(state)
  end
end

local ComputedMT = {}
ComputedMT.__index = ComputedMT

function ComputedMT:peek()
  return self._state._value
end

function ComputedMT:__call()
  local state = self._state
  -- Register as a dependency of the outer subscriber
  _track(state)

  if state._dirty then
    if state._computing then
      -- Circular dependency guard: return stale value
      return state._value
    end
    -- Rebuild dependency links from scratch
    for dep, _ in pairs(state._deps) do
      local dep_ = dep --[[:! SubNode]]
      dep_._subs[state] = nil
    end
    state._deps      = {}
    state._dirty     = false
    state._computing = true
    _push(state)
    local ok, result = pcall(state._fn)
    _pop()
    state._computing = false
    if ok then
      state._value = result
    else
      state._dirty = true   -- retry next read
      error(result, 0)
    end
  end

  return state._value
end

-- ---------------------------------------------------------------------------
-- M.create(initial) → writable signal
-- ---------------------------------------------------------------------------

function M.create(initial)
  local state = {
    _value = initial,
    _subs  = {},  -- reactive subscribers: { [sub_obj] = true }
    _on    = {},  -- explicit listeners:   { [id] = fn }
    _on_id = 0,
  }
  local sig = setmetatable({ _state = state }, SignalMT)
  -- expose _signal for M.peek / M.on compatibility
  sig._signal = state
  return sig
end

-- ---------------------------------------------------------------------------
-- M.peek(sig) — read without tracking (module-level function form)
-- ---------------------------------------------------------------------------

function M.peek(sig)
  return sig._state._value
end

-- ---------------------------------------------------------------------------
-- M.on(sig, fn) → unsub — explicit subscription (not reactive)
-- ---------------------------------------------------------------------------

function M.on(sig, fn)
  local state = sig._state
  state._on_id = state._on_id + 1
  local id = state._on_id
  state._on[id] = fn
  return function()
    state._on[id] = nil
  end
end

-- ---------------------------------------------------------------------------
-- M.untrack(fn) — execute fn without registering any dependencies
-- ---------------------------------------------------------------------------

function M.untrack(fn)
  --: SubNode
  local sentinel = { _kind = "untrack", _deps = {}, _subs = {}, _disposed = false, _dirty = false, _computing = false, _value = nil }
  _push(sentinel)
  local ok, result = pcall(fn)
  _pop()
  -- Remove any accidental links
  for dep, _ in pairs(sentinel._deps) do
    local dep_ = dep --[[:! SubNode]]
    dep_._subs[sentinel] = nil
  end
  if not ok then error(result, 2) end
  return result
end

-- ---------------------------------------------------------------------------
-- M.computed(fn) → lazy read-only derived signal
-- ---------------------------------------------------------------------------

function M.computed(fn)
  local state = {
    _kind      = "computed",
    _fn        = fn,
    _value     = nil,
    _dirty     = true,
    _computing = false,
    _deps      = {},
    _subs      = {},
    _on        = {},
    _on_id     = 0,
  }
  local sig = setmetatable({ _state = state }, ComputedMT)
  sig._signal = state
  return sig
end

-- ---------------------------------------------------------------------------
-- M.memo(fn) — same as computed (cached lazy derived signal)
-- ---------------------------------------------------------------------------

M.memo = M.computed

-- ---------------------------------------------------------------------------
-- M.effect(fn) → stop() — run fn now and re-run on dependency change
-- ---------------------------------------------------------------------------

function M.effect(fn)
  local self = {
    _kind     = "effect",
    _fn       = fn,
    _deps     = {},
    _disposed = false,
  }
  run_effect(self)
  return function()
    if self._disposed then return end
    self._disposed = true
    for dep, _ in pairs(self._deps) do
      dep._subs[self] = nil
    end
    self._deps = {}
    _pending_effects[self] = nil --[[: any]]
  end
end

-- ---------------------------------------------------------------------------
-- M.batch(fn) — defer effect execution until fn completes
-- ---------------------------------------------------------------------------

function M.batch(fn)
  _batch_depth = _batch_depth + 1
  local ok, err = pcall(fn)
  _batch_depth = _batch_depth - 1
  if _batch_depth == 0 then
    flush_effects()
  end
  if not ok then error(err, 2) end
end

return M
