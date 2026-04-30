if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

--- Reactive observable streams. Push-based data streams with operators.
--- Synchronous execution — no scheduler needed.
local M = {}

--:: Observer = { next: (unknown) -> (), error: (((string) -> ()) | nil), complete: ((() -> ()) | nil) }
--:: Teardown = () -> ()
--:: SubscribeFn = (Observer) -> (Teardown | nil)
--:: Observable = { _subscribe: SubscribeFn }
--:: Subject = { _observers: { [integer]: Observer }, _closed: boolean, next: (Subject, unknown) -> nil, error: (Subject, string) -> nil, complete: (Subject) -> nil }

--- Observable object. Created via M.create, M.of, M.from_array, etc.
local Observable = {}
Observable.__index = Observable

--- Create an observable from a subscribe function.
--- The subscribe function receives an observer with :next(v), :error(e), :complete().
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
    for i = 1, n do
      observer:next(args[i])
    end
    observer:complete()
  end)
end

--- Create an observable from an array table.
--: (unknown[]) -> Observable
function M.from_array(arr)
  return M.create(function(observer)
    for i = 1, #arr do
      observer:next(arr[i])
    end
    observer:complete()
  end)
end

--- Create an observable that completes immediately without emitting.
--: () -> Observable
function M.empty()
  return M.create(function(observer)
    observer:complete()
  end)
end

--- Create an observable that never emits and never completes.
--: () -> Observable
function M.never()
  return M.create(function() end)
end

--- Safe observer wrapper: guards against next-after-complete/error,
--- and ensures complete/error are called at most once.
local SafeObserver = {}
SafeObserver.__index = SafeObserver

local function safe_observer(raw)
  return setmetatable({
    _raw = raw,
    _stopped = false,
  }, SafeObserver)
end

function SafeObserver:next(value)
  if self._stopped then return end
  local fn = self._raw.next
  if fn then fn(value) end
end

function SafeObserver:error(err)
  if self._stopped then return end
  self._stopped = true
  local fn = self._raw.error
  if fn then fn(err) end
end

function SafeObserver:complete()
  if self._stopped then return end
  self._stopped = true
  local fn = self._raw.complete
  if fn then fn() end
end

--- Subscribe to this observable.
--- observer is a table with optional next, error, complete functions.
--- Returns a teardown function (or nil).
--: (Observer) -> (Teardown | nil)
function Observable:subscribe(observer)
  local safe = safe_observer(observer)
  local ok, teardown = pcall(self._subscribe, safe)
  if not ok then
    safe:error(teardown) -- teardown is the error message here
    return nil
  end
  return teardown
end

--- Map each emitted value through fn.
--: ((unknown) -> unknown) -> Observable
function Observable:map(fn)
  local source = self
  return M.create(function(observer)
    return source:subscribe({
      next = function(v) observer:next(fn(v)) end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Emit only values for which fn returns truthy.
--: ((unknown) -> boolean) -> Observable
function Observable:filter(fn)
  local source = self
  return M.create(function(observer)
    return source:subscribe({
      next = function(v)
        if fn(v) then observer:next(v) end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Emit only the first n values, then complete.
--: (number) -> Observable
function Observable:take(n)
  local source = self
  return M.create(function(observer)
    local count = 0
    return source:subscribe({
      next = function(v)
        if count >= n then return end
        count = count + 1
        observer:next(v)
        if count >= n then observer:complete() end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Skip the first n values.
--: (number) -> Observable
function Observable:skip(n)
  local source = self
  return M.create(function(observer)
    local count = 0
    return source:subscribe({
      next = function(v)
        count = count + 1
        if count > n then observer:next(v) end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Remove consecutive duplicates (by == equality).
--: () -> Observable
function Observable:distinct()
  local source = self
  return M.create(function(observer)
    local has_prev = false
    local prev
    return source:subscribe({
      next = function(v)
        if not has_prev or prev ~= v then
          has_prev = true
          prev = v
          observer:next(v)
        end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Emit a single accumulated value on complete.
--: (unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:reduce(init, fn)
  local source = self
  return M.create(function(observer)
    local acc = init
    return source:subscribe({
      next = function(v) acc = fn(acc, v) end,
      error = function(e) observer:error(e) end,
      complete = function()
        observer:next(acc)
        observer:complete()
      end,
    })
  end)
end

--- Emit the running accumulation on each value.
--: (unknown, (unknown, unknown) -> unknown) -> Observable
function Observable:scan(init, fn)
  local source = self
  return M.create(function(observer)
    local acc = init
    return source:subscribe({
      next = function(v)
        acc = fn(acc, v)
        observer:next(acc)
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Map each value to an observable via fn, then flatten (subscribe to inner).
--: ((unknown) -> Observable) -> Observable
function Observable:flat_map(fn)
  local source = self
  return M.create(function(observer)
    local active = 1 -- 1 for source
    local source_complete = false
    return source:subscribe({
      next = function(v)
        local inner = fn(v)
        active = active + 1
        inner:subscribe({
          next = function(iv) observer:next(iv) end,
          error = function(e) observer:error(e) end,
          complete = function()
            active = active - 1
            if source_complete and active == 0 then
              observer:complete()
            end
          end,
        })
      end,
      error = function(e) observer:error(e) end,
      complete = function()
        source_complete = true
        active = active - 1
        if active == 0 then
          observer:complete()
        end
      end,
    })
  end)
end

--- Side-effect on each value (does not transform).
--: ((unknown) -> ()) -> Observable
function Observable:tap(fn)
  local source = self
  return M.create(function(observer)
    return source:subscribe({
      next = function(v)
        fn(v)
        observer:next(v)
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Emit all values from self, then all values from other.
--: (Observable) -> Observable
function Observable:concat(other)
  local source = self
  return M.create(function(observer)
    source:subscribe({
      next = function(v) observer:next(v) end,
      error = function(e) observer:error(e) end,
      complete = function()
        other:subscribe({
          next = function(v) observer:next(v) end,
          error = function(e) observer:error(e) end,
          complete = function() observer:complete() end,
        })
      end,
    })
  end)
end

--- Interleave: for synchronous observables, emit all of self then all of other.
--: (Observable) -> Observable
function Observable:merge(other)
  local source = self
  return M.create(function(observer)
    local completed = 0
    local function on_complete()
      completed = completed + 1
      if completed >= 2 then observer:complete() end
    end
    source:subscribe({
      next = function(v) observer:next(v) end,
      error = function(e) observer:error(e) end,
      complete = on_complete,
    })
    other:subscribe({
      next = function(v) observer:next(v) end,
      error = function(e) observer:error(e) end,
      complete = on_complete,
    })
  end)
end

--- Emit values while fn returns truthy, then complete.
--: ((unknown) -> boolean) -> Observable
function Observable:take_while(fn)
  local source = self
  return M.create(function(observer)
    return source:subscribe({
      next = function(v)
        if fn(v) then
          observer:next(v)
        else
          observer:complete()
        end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Skip values while fn returns truthy, then emit all remaining.
--: ((unknown) -> boolean) -> Observable
function Observable:skip_while(fn)
  local source = self
  return M.create(function(observer)
    local skipping = true
    return source:subscribe({
      next = function(v)
        if skipping then
          if not fn(v) then
            skipping = false
            observer:next(v)
          end
        else
          observer:next(v)
        end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Simplified debounce: skip values if fewer than n items since last emit.
--- For synchronous streams, this counts items between emits.
--: (number) -> Observable
function Observable:debounce(n)
  local source = self
  return M.create(function(observer)
    local since_emit = n -- start ready to emit
    return source:subscribe({
      next = function(v)
        since_emit = since_emit + 1
        if since_emit >= n then
          since_emit = 0
          observer:next(v)
        end
      end,
      error = function(e) observer:error(e) end,
      complete = function() observer:complete() end,
    })
  end)
end

--- Collect n items into an array, emit the array, repeat.
--: (number) -> Observable
function Observable:buffer(n)
  local source = self
  return M.create(function(observer)
    local buf = {}
    return source:subscribe({
      next = function(v)
        buf[#buf + 1] = v
        if #buf >= n then
          observer:next(buf)
          buf = {}
        end
      end,
      error = function(e) observer:error(e) end,
      complete = function()
        if #buf > 0 then
          observer:next(buf)
        end
        observer:complete()
      end,
    })
  end)
end

--- Collect all values into an array, emit the array on complete.
--: () -> Observable
function Observable:to_array()
  local source = self
  return M.create(function(observer)
    local arr = {}
    return source:subscribe({
      next = function(v) arr[#arr + 1] = v end,
      error = function(e) observer:error(e) end,
      complete = function()
        observer:next(arr)
        observer:complete()
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
    local completed = 0
    for i = 1, n do
      sources[i]:subscribe({
        next = function(v) observer:next(v) end,
        error = function(e) observer:error(e) end,
        complete = function()
          completed = completed + 1
          if completed >= n then observer:complete() end
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
    local function subscribe_at(i)
      if i > n then
        observer:complete()
        return
      end
      sources[i]:subscribe({
        next = function(v) observer:next(v) end,
        error = function(e) observer:error(e) end,
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
    local queues = {}
    local done = {}
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
      observer:next(tuple)
    end
    local function check_complete()
      for i = 1, n do
        if done[i] and #queues[i] == 0 then
          observer:complete()
          return
        end
      end
    end
    for i = 1, n do
      sources[i]:subscribe({
        next = function(v)
          queues[i][#queues[i] + 1] = v
          try_emit()
        end,
        error = function(e) observer:error(e) end,
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
    local latest = {}
    local has_value = {}
    local ready = 0
    local completed = 0
    for i = 1, n do
      has_value[i] = false
    end
    for i = 1, n do
      sources[i]:subscribe({
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
            observer:next(copy)
          end
        end,
        error = function(e) observer:error(e) end,
        complete = function()
          completed = completed + 1
          if completed >= n then observer:complete() end
        end,
      })
    end
  end)
end

-- Subjects

--- A subject is both an observable and an observer.
--- Subscribers receive values pushed via :next(), :error(), :complete().
function M.subject()
  local subscribers = {}
  local stopped = false

  local subj = {}

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
  local subscribers = {}
  local stopped = false
  local err_value = nil
  local completed = false
  local buffer = {}

  local subj = {}

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
    err_value = err
    for i = 1, #subscribers do
      local s = subscribers[i]
      if s and s.error then s.error(err) end
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

  function subj:subscribe(observer)
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
      if observer.error then observer.error(err_value) end
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
