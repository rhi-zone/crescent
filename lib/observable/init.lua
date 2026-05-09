if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Reactive observable streams. Push-based data streams with operators.
--- Synchronous execution — no scheduler needed.
local M = {}

--:: Observer = { next: (unknown) -> (), error: (((string) -> ()) | nil), complete: ((() -> ()) | nil) }
--:: Teardown = () -> ()
--:: SafeObserverT = { _raw: Observer, _stopped: boolean, next: (SafeObserverT, unknown) -> nil, error: (SafeObserverT, string) -> nil, complete: (SafeObserverT) -> nil }
--:: SubscribeFn = (observer: SafeObserverT) -> (Teardown | nil)
--:: Observable = { _subscribe: SubscribeFn, subscribe: (Observable, Observer) -> (Teardown | nil) }
--:: Subject = { next: (Subject, unknown) -> nil, error: (Subject, string) -> nil, complete: (Subject) -> nil, subscribe: (Subject, Observer) -> (Teardown | nil) }

--- Observable object. Created via M.create, M.of, M.from_array, etc.
local Observable = {}
Observable.__index = Observable

--- Create an observable from a subscribe function.
--- The subscribe function receives a SafeObserver with :next(v), :error(e), :complete().
--- It may return a teardown function.
--: (SubscribeFn) -> Observable
function M.create(subscribe_fn)
  return setmetatable({ _subscribe = subscribe_fn }, Observable)
end

--- Create an observable that emits the given values then completes.
function M.of(...)
  local args = { ... }
  local n = select("#", ...)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    for i = 1, n do
      obs:next(args[i])
    end
    obs:complete()
  end)
end

--- Create an observable from an array table.
--: (unknown[]) -> Observable
function M.from_array(arr)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    for i = 1, #arr do
      obs:next(arr[i])
    end
    obs:complete()
  end)
end

--- Create an observable that completes immediately without emitting.
--: () -> Observable
function M.empty()
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    obs:complete()
  end)
end

--- Create an observable that never emits and never completes.
--: () -> Observable
function M.never()
  return M.create(function(_observer) end)
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
  }, SafeObserver)
end

--: (SafeObserverT, unknown) -> nil
function SafeObserver:next(value)
  if self._stopped then return end
  local fn = self._raw.next
  if fn ~= nil then (--[[:! (unknown) -> ()]] fn)(value) end
end

--: (SafeObserverT, string) -> nil
function SafeObserver:error(err)
  if self._stopped then return end
  self._stopped = true
  local fn = self._raw.error
  if fn ~= nil then (--[[:! (string) -> ()]] fn)(err) end
end

--: (SafeObserverT) -> nil
function SafeObserver:complete()
  if self._stopped then return end
  self._stopped = true
  local fn = self._raw.complete
  if fn ~= nil then (--[[:! () -> ()]] fn)() end
end

--- Subscribe to this observable.
--- observer is a table with optional next, error, complete functions.
--- Returns a teardown function (or nil).
--: (Observable, Observer) -> (Teardown | nil)
function Observable:subscribe(observer)
  local safe = safe_observer(observer)
  local ok, teardown = pcall(self._subscribe, safe)
  if not ok then
    safe:error(tostring(teardown)) -- teardown is the error message here
    return nil
  end
  return teardown --[[:! Teardown | nil]]
end

--- Map each emitted value through fn.
--: (Observable, (unknown) -> unknown) -> Observable
function Observable:map(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    return source:subscribe({
      next = function(v) obs:next(fn(v)) end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Emit only values for which fn returns truthy.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:filter(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    return source:subscribe({
      next = function(v)
        if fn(v) then obs:next(v) end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Emit only the first n values, then complete.
--: (Observable, number) -> Observable
function Observable:take(n)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local count = 0
    return source:subscribe({
      next = function(v)
        if count >= n then return end
        count = count + 1
        obs:next(v)
        if count >= n then obs:complete() end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Skip the first n values.
--: (Observable, number) -> Observable
function Observable:skip(n)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local count = 0
    return source:subscribe({
      next = function(v)
        count = count + 1
        if count > n then obs:next(v) end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Remove consecutive duplicates (by == equality).
--: (Observable) -> Observable
function Observable:distinct()
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local has_prev = false
    local prev
    return source:subscribe({
      next = function(v)
        if not has_prev or prev ~= v then
          has_prev = true
          prev = v
          obs:next(v)
        end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Emit a single accumulated value on complete.
--: (Observable, unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:reduce(init, fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local acc = init
    return source:subscribe({
      next = function(v) acc = fn(acc, v) end,
      error = function(e) obs:error(e) end,
      complete = function()
        obs:next(acc)
        obs:complete()
      end,
    })
  end)
end

--- Emit the running accumulation on each value.
--: (Observable, unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:scan(init, fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local acc = init
    return source:subscribe({
      next = function(v)
        acc = fn(acc, v)
        obs:next(acc)
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Map each value to an observable via fn, then flatten (subscribe to inner).
--: (Observable, (unknown) -> Observable) -> Observable
function Observable:flat_map(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local active = 1 -- 1 for source
    local source_complete = false
    return source:subscribe({
      next = function(v)
        local inner = fn(v)
        active = active + 1
        inner:subscribe({
          next = function(iv) obs:next(iv) end,
          error = function(e) obs:error(e) end,
          complete = function()
            active = active - 1
            if source_complete and active == 0 then
              obs:complete()
            end
          end,
        })
      end,
      error = function(e) obs:error(e) end,
      complete = function()
        source_complete = true
        active = active - 1
        if active == 0 then
          obs:complete()
        end
      end,
    })
  end)
end

--- Side-effect on each value (does not transform).
--: (Observable, (unknown) -> ()) -> Observable
function Observable:tap(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    return source:subscribe({
      next = function(v)
        fn(v)
        obs:next(v)
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Emit all values from self, then all values from other.
--: (Observable, Observable) -> Observable
function Observable:concat(other)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    source:subscribe({
      next = function(v) obs:next(v) end,
      error = function(e) obs:error(e) end,
      complete = function()
        other:subscribe({
          next = function(v) obs:next(v) end,
          error = function(e) obs:error(e) end,
          complete = function() obs:complete() end,
        })
      end,
    })
  end)
end

--- Interleave: for synchronous observables, emit all of self then all of other.
--: (Observable, Observable) -> Observable
function Observable:merge(other)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local completed = 0
    local function on_complete()
      completed = completed + 1
      if completed >= 2 then obs:complete() end
    end
    source:subscribe({
      next = function(v) obs:next(v) end,
      error = function(e) obs:error(e) end,
      complete = on_complete,
    })
    other:subscribe({
      next = function(v) obs:next(v) end,
      error = function(e) obs:error(e) end,
      complete = on_complete,
    })
  end)
end

--- Emit values while fn returns truthy, then complete.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:take_while(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    return source:subscribe({
      next = function(v)
        if fn(v) then
          obs:next(v)
        else
          obs:complete()
        end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Skip values while fn returns truthy, then emit all remaining.
--: (Observable, (unknown) -> boolean) -> Observable
function Observable:skip_while(fn)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local skipping = true
    return source:subscribe({
      next = function(v)
        if skipping then
          if not fn(v) then
            skipping = false
            obs:next(v)
          end
        else
          obs:next(v)
        end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Simplified debounce: skip values if fewer than n items since last emit.
--- For synchronous streams, this counts items between emits.
--: (Observable, number) -> Observable
function Observable:debounce(n)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local since_emit = n -- start ready to emit
    return source:subscribe({
      next = function(v)
        since_emit = since_emit + 1
        if since_emit >= n then
          since_emit = 0
          obs:next(v)
        end
      end,
      error = function(e) obs:error(e) end,
      complete = function() obs:complete() end,
    })
  end)
end

--- Collect n items into an array, emit the array, repeat.
--: (Observable, number) -> Observable
function Observable:buffer(n)
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local buf = {}
    return source:subscribe({
      next = function(v)
        buf[#buf + 1] = v
        if #buf >= n then
          obs:next(buf)
          buf = {}
        end
      end,
      error = function(e) obs:error(e) end,
      complete = function()
        if #buf > 0 then
          obs:next(buf)
        end
        obs:complete()
      end,
    })
  end)
end

--- Collect all values into an array, emit the array on complete.
--: (Observable) -> Observable
function Observable:to_array()
  local source = self
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local arr = {}
    return source:subscribe({
      next = function(v) arr[#arr + 1] = v end,
      error = function(e) obs:error(e) end,
      complete = function()
        obs:next(arr)
        obs:complete()
      end,
    })
  end)
end

-- Combinators

--- Merge multiple observables. For synchronous: subscribes in order.
--: (...Observable) -> Observable
function M.merge(...)
  local sources = { ... }
  local n = select("#", ...)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local completed = 0
    for i = 1, n do
      local src = sources[i] --[[:! Observable]]
      src:subscribe({
        next = function(v) obs:next(v) end,
        error = function(e) obs:error(e) end,
        complete = function()
          completed = completed + 1
          if completed >= n then obs:complete() end
        end,
      })
    end
  end)
end

--- Concat multiple observables sequentially.
--: (...Observable) -> Observable
function M.concat(...)
  local sources = { ... }
  local n = select("#", ...)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local function subscribe_at(i)
      if i > n then
        obs:complete()
        return
      end
      local src = sources[i] --[[:! Observable]]
      src:subscribe({
        next = function(v) obs:next(v) end,
        error = function(e) obs:error(e) end,
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
  local sources = { ... }
  local n = select("#", ...)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
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
      local tuple = {}
      for i = 1, n do
        tuple[i] = table.remove(queues[i], 1)
      end
      obs:next(tuple)
    end
    local function check_complete()
      for i = 1, n do
        if done[i] and #queues[i] == 0 then
          obs:complete()
          return
        end
      end
    end
    for i = 1, n do
      local src = sources[i] --[[:! Observable]]
      src:subscribe({
        next = function(v)
          queues[i][#queues[i] + 1] = v
          try_emit()
        end,
        error = function(e) obs:error(e) end,
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
  local sources = { ... }
  local n = select("#", ...)
  return M.create(function(observer)
    local obs = observer --[[:! SafeObserverT]]
    local latest = {}
    local has_value = {} --[[:! { [integer]: boolean }]]
    local ready = 0
    local completed = 0
    for i = 1, n do
      has_value[i] = false
    end
    for i = 1, n do
      local src = sources[i] --[[:! Observable]]
      src:subscribe({
        next = function(v)
          if not has_value[i] then
            has_value[i] = true
            ready = ready + 1
          end
          latest[i] = v
          if ready >= n then
            -- emit a copy
            local copy = {}
            for j = 1, n do copy[j] = latest[j] end
            obs:next(copy)
          end
        end,
        error = function(e) obs:error(e) end,
        complete = function()
          completed = completed + 1
          if completed >= n then obs:complete() end
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
  local stopped = false --: boolean

  local subj = {} --[[:! Subject]]

  function subj:next(value)
    if stopped then return end
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.next then s.next(value) end
    end
  end

  function subj:error(err)
    if stopped then return end
    stopped = true
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.error then s.error(err) end
    end
  end

  function subj:complete()
    if stopped then return end
    stopped = true
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.complete then s.complete() end
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
  local subscribers = {} --[[:! { [integer]: Observer }]]
  local stopped = false --: boolean
  local err_value = nil --: string | nil
  local completed = false --: boolean
  local buffer = {} --[[:! { [integer]: unknown }]]

  local subj = {} --[[:! Subject]]

  function subj:next(value)
    if stopped then return end
    buffer[#buffer + 1] = value
    if #buffer > n then
      table.remove(buffer, 1)
    end
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.next then s.next(value) end
    end
  end

  function subj:error(err)
    if stopped then return end
    stopped = true
    local err_str = err --[[:! string]]
    err_value = err_str
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.error then s.error(err_str) end
    end
  end

  function subj:complete()
    if stopped then return end
    stopped = true
    completed = true
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.complete then s.complete() end
    end
  end

  function subj:subscribe(raw_observer)
    local observer = raw_observer --[[:! Observer]]
    -- replay buffered values
    for i = 1, #buffer do
      if observer.next then observer.next(buffer[i]) end
    end
    -- if already completed/errored, notify and return
    if completed then
      if observer.complete then observer.complete() end
      return nil
    end
    if stopped then
      if observer.error then
        local ev = err_value --[[:! string]]
        observer.error(ev)
      end
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
