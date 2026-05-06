if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Reactive observable streams. Push-based data streams with operators.
--- Synchronous execution — no scheduler needed.
local M = {}

--:: Observer = { next: (unknown) -> (), error: (((string) -> ()) | nil), complete: ((() -> ()) | nil) }
--:: Teardown = () -> ()
--:: SafeObserverT = { _raw: Observer, _stopped: boolean }
--:: SubscribeFn = (SafeObserverT) -> (Teardown | nil)
--:: Observable = { _subscribe: SubscribeFn }
--:: Subject = { _observers: { [integer]: Observer }, _closed: boolean, next: (Subject, unknown) -> nil, error: (Subject, string) -> nil, complete: (Subject) -> nil }

--- Observable object. Created via M.create, M.of, M.from_array, etc.
local Observable = {}
Observable.__index = Observable

--- Create an observable from a subscribe function.
--- The subscribe function receives a SafeObserver with :next(v), :error(e), :complete().
--- It may return a teardown function.
--: (SubscribeFn) -> Observable
function M.create(subscribe_fn)
  return setmetatable({ _subscribe = subscribe_fn }, Observable) --[[:! Observable]]
end

--- Safe observer wrapper: guards against next-after-complete/error,
--- and ensures complete/error are called at most once.
local SafeObserver = {}
SafeObserver.__index = SafeObserver

--: (Observer) -> SafeObserverT
local function safe_observer(raw)
  return setmetatable({
    _raw = raw,
    _stopped = false,
  }, SafeObserver) --[[:! SafeObserverT]]
end

--: (SafeObserverT, unknown) -> nil
function SafeObserver:next(value)
  local self_ = self --[[:! SafeObserverT]]
  if self_._stopped then return end
  local fn = self_._raw.next
  if fn ~= nil then (--[[:! (unknown) -> ()]] fn)(value) end
end

--: (SafeObserverT, string) -> nil
function SafeObserver:error(err)
  local self_ = self --[[:! SafeObserverT]]
  if self_._stopped then return end
  self_._stopped = true
  local fn = self_._raw.error
  if fn ~= nil then (--[[:! (string) -> ()]] fn)(err) end
end

--: (SafeObserverT) -> nil
function SafeObserver:complete()
  local self_ = self --[[:! SafeObserverT]]
  if self_._stopped then return end
  self_._stopped = true
  local fn = self_._raw.complete
  if fn ~= nil then (--[[:! () -> ()]] fn)() end
end

-- Shims for use in closures without method call syntax
--: (SafeObserverT, unknown) -> nil
local function obs_next(o, v) SafeObserver.next(o, v) end
--: (SafeObserverT, string) -> nil
local function obs_error(o, e) SafeObserver.error(o, e) end
--: (SafeObserverT) -> nil
local function obs_complete(o) SafeObserver.complete(o) end

--- Create an observable that emits the given values then completes.
--: (...unknown) -> Observable
function M.of(...)
  local args = { ... }
  local n = select("#", ...) --[[:! integer]]
  return M.create(function(observer)
    for i = 1, n do
      obs_next(observer, args[i])
    end
    obs_complete(observer)
  end)
end

--- Create an observable from an array table.
--: ({ [integer]: unknown }) -> Observable
function M.from_array(arr)
  return M.create(function(observer)
    for i = 1, #arr do
      obs_next(observer, arr[i])
    end
    obs_complete(observer)
  end)
end

--- Create an observable that completes immediately without emitting.
--: () -> Observable
function M.empty()
  return M.create(function(observer)
    obs_complete(observer)
  end)
end

--- Create an observable that never emits and never completes.
--: () -> Observable
function M.never()
  return M.create(function(_observer) end)
end

--: (Observable, Observer) -> (Teardown | nil)
local function obs_subscribe(obs, observer)
  local obs_ = obs --[[:! Observable]]
  local safe = safe_observer(observer)
  local ok, teardown = pcall(obs_._subscribe, safe)
  if not ok then
    obs_error(safe, teardown --[[:! string]])
    return nil
  end
  return teardown
end

--- Subscribe to this observable.
--- observer is a table with optional next, error, complete functions.
--- Returns a teardown function (or nil).
--: (Observable, Observer) -> (Teardown | nil)
function Observable:subscribe(observer)
  return obs_subscribe(self --[[:! Observable]], observer)
end

--- Map each emitted value through fn.
--: (Observable, (unknown) -> unknown) -> Observable
function Observable:map(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    return obs_subscribe(source, {
      next = function(v) obs_next(observer, fn(v)) end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Emit only values for which fn returns truthy.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:filter(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    return obs_subscribe(source, {
      next = function(v)
        if fn(v) then obs_next(observer, v) end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Emit only the first n values, then complete.
--: (Observable, number) -> Observable
function Observable:take(n)
  local n_ = n --[[:! number]]
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local count = 0
    return obs_subscribe(source, {
      next = function(v)
        if count >= n_ then return end
        count = count + 1
        obs_next(observer, v)
        if count >= n_ then obs_complete(observer) end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Skip the first n values.
--: (Observable, number) -> Observable
function Observable:skip(n)
  local n_ = n --[[:! number]]
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local count = 0
    return obs_subscribe(source, {
      next = function(v)
        count = count + 1
        if count > n_ then obs_next(observer, v) end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Remove consecutive duplicates (by == equality).
--: (Observable) -> Observable
function Observable:distinct()
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local has_prev = false
    local prev
    return obs_subscribe(source, {
      next = function(v)
        if not has_prev or prev ~= v then
          has_prev = true
          prev = v
          obs_next(observer, v)
        end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Emit a single accumulated value on complete.
--: (Observable, unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:reduce(init, fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local acc = init
    return obs_subscribe(source, {
      next = function(v) acc = fn(acc, v) end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function()
        obs_next(observer, acc)
        obs_complete(observer)
      end,
    })
  end)
end

--- Emit the running accumulation on each value.
--: (Observable, unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:scan(init, fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local acc = init
    return obs_subscribe(source, {
      next = function(v)
        acc = fn(acc, v)
        obs_next(observer, acc)
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Map each value to an observable via fn, then flatten (subscribe to inner).
--: (Observable, (unknown) -> Observable) -> Observable
function Observable:flat_map(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local active = 1 -- 1 for source
    local source_complete = false
    return obs_subscribe(source, {
      next = function(v)
        local inner = fn(v) --[[:! Observable]]
        active = active + 1
        obs_subscribe(inner, {
          next = function(iv) obs_next(observer, iv) end,
          error = function(e) obs_error(observer, e --[[:! string]]) end,
          complete = function()
            active = active - 1
            if source_complete and active == 0 then
              obs_complete(observer)
            end
          end,
        })
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function()
        source_complete = true
        active = active - 1
        if active == 0 then
          obs_complete(observer)
        end
      end,
    })
  end)
end

--- Side-effect on each value (does not transform).
--: (Observable, (unknown) -> ()) -> Observable
function Observable:tap(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    return obs_subscribe(source, {
      next = function(v)
        fn(v)
        obs_next(observer, v)
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Emit all values from self, then all values from other.
--: (Observable, Observable) -> Observable
function Observable:concat(other)
  local source = self --[[:! Observable]]
  local other_ = other --[[:! Observable]]
  return M.create(function(observer)
    obs_subscribe(source, {
      next = function(v) obs_next(observer, v) end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function()
        obs_subscribe(other_, {
          next = function(v) obs_next(observer, v) end,
          error = function(e) obs_error(observer, e --[[:! string]]) end,
          complete = function() obs_complete(observer) end,
        })
      end,
    })
  end)
end

--- Interleave: for synchronous observables, emit all of self then all of other.
--: (Observable, Observable) -> Observable
function Observable:merge(other)
  local source = self --[[:! Observable]]
  local other_ = other --[[:! Observable]]
  return M.create(function(observer)
    local completed = 0
    local function on_complete()
      completed = completed + 1
      if completed >= 2 then obs_complete(observer) end
    end
    obs_subscribe(source, {
      next = function(v) obs_next(observer, v) end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = on_complete,
    })
    obs_subscribe(other_, {
      next = function(v) obs_next(observer, v) end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = on_complete,
    })
  end)
end

--- Emit values while fn returns truthy, then complete.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:take_while(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    return obs_subscribe(source, {
      next = function(v)
        if fn(v) then
          obs_next(observer, v)
        else
          obs_complete(observer)
        end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Skip values while fn returns truthy, then emit all remaining.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:skip_while(fn)
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local skipping = true
    return obs_subscribe(source, {
      next = function(v)
        if skipping then
          if not fn(v) then
            skipping = false
            obs_next(observer, v)
          end
        else
          obs_next(observer, v)
        end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Simplified debounce: skip values if fewer than n items since last emit.
--- For synchronous streams, this counts items between emits.
--: (Observable, number) -> Observable
function Observable:debounce(n)
  local n_ = n --[[:! number]]
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local since_emit = n_ -- start ready to emit
    return obs_subscribe(source, {
      next = function(v)
        since_emit = since_emit + 1
        if since_emit >= n_ then
          since_emit = 0
          obs_next(observer, v)
        end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function() obs_complete(observer) end,
    })
  end)
end

--- Collect n items into an array, emit the array, repeat.
--: (Observable, number) -> Observable
function Observable:buffer(n)
  local n_ = n --[[:! number]]
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local buf = {} --[[:! { [integer]: unknown }]]
    return obs_subscribe(source, {
      next = function(v)
        buf[#buf + 1] = v
        if #buf >= n_ then
          obs_next(observer, buf)
          buf = {} --[[:! { [integer]: unknown }]]
        end
      end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function()
        if #buf > 0 then
          obs_next(observer, buf)
        end
        obs_complete(observer)
      end,
    })
  end)
end

--- Collect all values into an array, emit the array on complete.
--: (Observable) -> Observable
function Observable:to_array()
  local source = self --[[:! Observable]]
  return M.create(function(observer)
    local arr = {} --[[:! { [integer]: unknown }]]
    return obs_subscribe(source, {
      next = function(v) arr[#arr + 1] = v end,
      error = function(e) obs_error(observer, e --[[:! string]]) end,
      complete = function()
        obs_next(observer, arr)
        obs_complete(observer)
      end,
    })
  end)
end

-- Combinators

--- Merge multiple observables. For synchronous: subscribes in order.
--: (...Observable) -> Observable
function M.merge(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  local n = select("#", ...) --[[:! integer]]
  return M.create(function(observer)
    local completed = 0
    for i = 1, n do
      obs_subscribe(sources[i], {
        next = function(v) obs_next(observer, v) end,
        error = function(e) obs_error(observer, e --[[:! string]]) end,
        complete = function()
          completed = completed + 1
          if completed >= n then obs_complete(observer) end
        end,
      })
    end
  end)
end

--- Concat multiple observables sequentially.
--: (...Observable) -> Observable
function M.concat(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  local n = select("#", ...) --[[:! integer]]
  return M.create(function(observer)
    local function subscribe_at(i)
      if i > n then
        obs_complete(observer)
        return
      end
      obs_subscribe(sources[i], {
        next = function(v) obs_next(observer, v) end,
        error = function(e) obs_error(observer, e --[[:! string]]) end,
        complete = function() subscribe_at(i + 1) end,
      })
    end
    subscribe_at(1)
  end)
end

--- Zip observables: pair elements by index. Emits tuples (as arrays).
--- Completes when any source completes.
--: (...Observable) -> Observable
function M.zip(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  local n = select("#", ...) --[[:! integer]]
  return M.create(function(observer)
    local queues = {} --[[:! { [integer]: { [integer]: unknown } }]]
    local done = {} --[[:! { [integer]: boolean }]]
    for i = 1, n do
      queues[i] = {}
      done[i] = false
    end
    local function try_emit()
      -- check all queues have at least one item
      for i = 1, n do
        if #queues[i] == 0 then return end
      end
      local tuple = {} --[[:! { [integer]: unknown }]]
      for i = 1, n do
        tuple[i] = table.remove(queues[i], 1)
      end
      obs_next(observer, tuple)
    end
    local function check_complete()
      for i = 1, n do
        if done[i] and #queues[i] == 0 then
          obs_complete(observer)
          return
        end
      end
    end
    for i = 1, n do
      obs_subscribe(sources[i], {
        next = function(v)
          queues[i][#queues[i] + 1] = v
          try_emit()
        end,
        error = function(e) obs_error(observer, e --[[:! string]]) end,
        complete = function()
          done[i] = true
          check_complete()
        end,
      })
    end
  end)
end

--- Combine latest: emit an array of latest values whenever any source emits.
--- Only starts emitting once all sources have emitted at least once.
--: (...Observable) -> Observable
function M.combine_latest(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  local n = select("#", ...) --[[:! integer]]
  return M.create(function(observer)
    local latest = {} --[[:! { [integer]: unknown }]]
    local has_value = {} --[[:! { [integer]: boolean }]]
    local ready = 0
    local completed = 0
    for i = 1, n do
      has_value[i] = false
    end
    for i = 1, n do
      obs_subscribe(sources[i], {
        next = function(v)
          if not has_value[i] then
            has_value[i] = true
            ready = ready + 1
          end
          latest[i] = v
          if ready >= n then
            -- emit a copy
            local copy = {} --[[:! { [integer]: unknown }]]
            for j = 1, n do copy[j] = latest[j] end
            obs_next(observer, copy)
          end
        end,
        error = function(e) obs_error(observer, e --[[:! string]]) end,
        complete = function()
          completed = completed + 1
          if completed >= n then obs_complete(observer) end
        end,
      })
    end
  end)
end

-- Subjects

--- A subject is both an observable and an observer.
--- Subscribers receive values pushed via :next(), :error(), :complete().
--: () -> Subject
function M.subject()
  local subscribers = {} --[[:! { [integer]: Observer }]]
  local stopped = false

  local subj = {} --[[:! Subject]]

  function subj:next(value)
    local self_ = self --[[:! Subject]]
    if stopped then return end
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.next then (--[[:! (unknown) -> ()]] s.next)(value) end
    end
  end

  function subj:error(err)
    local self_ = self --[[:! Subject]]
    if stopped then return end
    stopped = true
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.error then (--[[:! (string) -> ()]] s.error)(err) end
    end
  end

  function subj:complete()
    local self_ = self --[[:! Subject]]
    if stopped then return end
    stopped = true
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.complete then (--[[:! () -> ()]] s.complete)() end
    end
  end

  function subj:subscribe(observer)
    if stopped then
      return nil
    end
    subscribers[#subscribers + 1] = observer
    return function()
      for i = 1, #subscribers do
        if subscribers[i] == observer then
          table.remove(subscribers, i)
          return
        end
      end
    end
  end

  return subj
end

--- A replay subject buffers the last n values and replays them to late subscribers.
--: (number) -> Subject
function M.replay_subject(n)
  local n_ = n --[[:! number]]
  local subscribers = {} --[[:! { [integer]: Observer }]]
  local stopped = false
  local err_value = nil
  local completed = false
  local buffer = {} --[[:! { [integer]: unknown }]]

  local subj = {} --[[:! Subject]]

  function subj:next(value)
    local self_ = self --[[:! Subject]]
    if stopped then return end
    buffer[#buffer + 1] = value
    if #buffer > n_ then
      table.remove(buffer, 1)
    end
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.next then (--[[:! (unknown) -> ()]] s.next)(value) end
    end
  end

  function subj:error(err)
    local self_ = self --[[:! Subject]]
    if stopped then return end
    stopped = true
    err_value = err
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.error then (--[[:! (string) -> ()]] s.error)(err) end
    end
  end

  function subj:complete()
    local self_ = self --[[:! Subject]]
    if stopped then return end
    stopped = true
    completed = true
    for i = 1, #(self_._observers or subscribers) do
      local s = subscribers[i]
      if s and s.complete then (--[[:! () -> ()]] s.complete)() end
    end
  end

  function subj:subscribe(observer)
    -- replay buffered values
    for i = 1, #buffer do
      if observer.next then (--[[:! (unknown) -> ()]] observer.next)(buffer[i]) end
    end
    -- if already completed/errored, notify and return
    if completed then
      if observer.complete then (--[[:! () -> ()]] observer.complete)() end
      return nil
    end
    if stopped then
      if observer.error then (--[[:! (string) -> ()]] observer.error)(err_value --[[:! string]]) end
      return nil
    end
    subscribers[#subscribers + 1] = observer
    return function()
      for i = 1, #subscribers do
        if subscribers[i] == observer then
          table.remove(subscribers, i)
          return
        end
      end
    end
  end

  return subj
end

return M
