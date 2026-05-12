if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Observable pattern (cold, synchronous) with operators.
-- Cold: each subscription re-runs the source independently.
-- Synchronous: no async/timer behavior.
-- Subject: hot observable (multicasts to current subscribers).
-- BehaviorSubject: hot + replays current value to new subscribers.

local M = {}
M._tier = "pure"

--:: Observer = { next: ((unknown) -> nil) | nil, error: ((unknown) -> nil) | nil, complete: (() -> nil) | nil }
--:: Subscription = { _closed: boolean, _unsub: (() -> nil) | nil, unsubscribe: (Subscription) -> nil }
--:: Subscriber = { _obs: Observer, _sub: Subscription, _done: boolean, next: (Subscriber, unknown) -> nil, error: (Subscriber, unknown) -> nil, complete: (Subscriber) -> nil }
--:: Subject = { _subscribers: { [integer]: Observer }, _closed: boolean, _error: unknown, subscribe: (Subject, Observer | ((unknown) -> nil) | nil) -> Subscription, next: (Subject, unknown) -> nil, error: (Subject, unknown) -> nil, complete: (Subject) -> nil }
--:: BehaviorSubject = { _subscribers: { [integer]: Observer }, _closed: boolean, _error: unknown, _value: unknown, subscribe: (BehaviorSubject, Observer | ((unknown) -> nil) | nil) -> Subscription, next: (BehaviorSubject, unknown) -> nil, error: (BehaviorSubject, unknown) -> nil, complete: (BehaviorSubject) -> nil, get_value: (BehaviorSubject) -> unknown }
--:: SubscribeFn = (subscriber: Subscriber) -> (Subscription | ((() -> nil) | nil))
--:: Observable = { _subscribe: SubscribeFn, subscribe: (Observable, Observer | ((unknown) -> nil) | nil) -> Subscription }

-- ---------------------------------------------------------------------------
-- Subscription
-- ---------------------------------------------------------------------------

local Subscription = {}
Subscription.__index = Subscription

--: ((() -> nil) | nil) -> Subscription
local function new_subscription(unsub_fn)
  return setmetatable({ _closed = false, _unsub = unsub_fn }, Subscription)
end

--: (Subscription) -> nil
function Subscription:unsubscribe()
  if not self._closed then
    self._closed = true
    if self._unsub then self._unsub() end
  end
end

-- Composite subscription: unsubscribing unsubscribes all children.
--: ({ [integer]: Subscription }) -> Subscription
local function composite_subscription(subs)
  return new_subscription(function()
    for i = 1, #subs do
      subs[i]:unsubscribe()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Observer (subscriber handle passed to create fn)
-- ---------------------------------------------------------------------------

local Subscriber = {}
Subscriber.__index = Subscriber

--: (Observer, Subscription) -> Subscriber
local function new_subscriber(observer, subscription)
  return setmetatable({ _obs = observer, _sub = subscription, _done = false }, Subscriber)
end

--: (Subscriber, unknown) -> nil
function Subscriber:next(v)
  if self._done then return end
  local fn = self._obs.next
  if fn ~= nil then (--[[:! (unknown) -> nil]] fn)(v) end
end

--: (Subscriber, unknown) -> nil
function Subscriber:error(e)
  if self._done then return end
  self._done = true
  self._sub._closed = true
  local fn = self._obs.error
  if fn ~= nil then (--[[:! (unknown) -> nil]] fn)(e) end
end

--: (Subscriber) -> nil
function Subscriber:complete()
  if self._done then return end
  self._done = true
  self._sub._closed = true
  local fn = self._obs.complete
  if fn ~= nil then (--[[:! () -> nil]] fn)() end
end

-- ---------------------------------------------------------------------------
-- Observable
-- ---------------------------------------------------------------------------

local Observable = {}
Observable.__index = Observable

--: (SubscribeFn) -> Observable
local function new_observable(subscribe_fn)
  return setmetatable({ _subscribe = subscribe_fn }, Observable)
end

-- Normalize observer argument: fn shorthand → {next=fn}
--: (Observer | ((unknown) -> nil) | nil) -> Observer
local function normalize_observer(observer_or_fn)
  if type(observer_or_fn) == "function" then
    return { next = observer_or_fn --[[:! (unknown) -> nil]], error = nil, complete = nil }
  end
  if observer_or_fn == nil then
    return { next = nil, error = nil, complete = nil }
  end
  return observer_or_fn --[[:! Observer]]
end

--: (Observable, Observer | ((unknown) -> nil) | nil) -> Subscription
function Observable:subscribe(observer_or_fn)
  local observer = normalize_observer(observer_or_fn)
  local sub = new_subscription(nil)
  local subscriber = new_subscriber(observer, sub)
  -- The subscribe fn may set sub._unsub for teardown
  local unsub_fn = self._subscribe(subscriber)
  if not sub._closed and type(unsub_fn) == "function" then
    sub._unsub = unsub_fn --[[:! () -> nil]]
  end
  return sub
end

-- ---------------------------------------------------------------------------
-- Factory constructors
-- ---------------------------------------------------------------------------

-- Obs.create(fn): raw constructor
--: (SubscribeFn) -> Observable
function M.create(fn)
  return new_observable(fn)
end

-- Obs.of(...): emit each argument
function M.of(...)
  local args = { ... }
  local n = select("#", ...)
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    for i = 1, n do
      if subscriber._done then return end
      subscriber:next(args[i])
    end
    subscriber:complete()
  end)
end

-- Obs.from(t): emit each element of array t
function M.from(t)
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    for i = 1, #t do
      if subscriber._done then return end
      subscriber:next(t[i])
    end
    subscriber:complete()
  end)
end

-- Obs.range(start, stop[, step]): emit integers
function M.range(start, stop, step)
  step = step or 1
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local i = start
    while (step > 0 and i <= stop) or (step < 0 and i >= stop) do
      if subscriber._done then return end
      subscriber:next(i)
      i = i + step
    end
    subscriber:complete()
  end)
end

-- Obs.empty(): complete immediately
function M.empty()
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    subscriber:complete()
  end)
end

-- Obs.never(): never emits or completes
function M.never()
  return new_observable(function(_) end)
end

-- Obs.error(msg): error immediately
function M.error(msg)
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    subscriber:error(msg)
  end)
end

-- Obs.defer(fn): create observable lazily per subscription
function M.defer(fn)
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local inner = fn() --[[:! Observable]]
    return inner._subscribe(subscriber)
  end)
end

-- ---------------------------------------------------------------------------
-- Operators (methods on Observable)
-- ---------------------------------------------------------------------------

--: (Observable, (unknown) -> unknown) -> Observable
function Observable:map(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) subscriber:next(fn(v)) end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:filter(pred)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) if pred(v) then subscriber:next(v) end end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, integer) -> Observable
function Observable:take(n)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local count = 0
    -- sub may be nil during synchronous emission (local x = expr gotcha),
    -- so use subscriber._done flag to stop; unsubscribe lazily after subscribe returns.
    local sub
    sub = source:subscribe({
      next = function(v)
        if subscriber._done then return end
        if count < n then
          count = count + 1
          subscriber:next(v)
          if count == n then
            subscriber:complete()  -- sets subscriber._done; unsubscribe handled below
          end
        end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
    -- If the source completed synchronously inside subscribe, sub is already
    -- assigned here; unsubscribe to release resources.
    if subscriber._done and sub then sub:unsubscribe() end
    return sub
  end)
end

--: (Observable, integer) -> Observable
function Observable:drop(n)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local count = 0
    return source:subscribe({
      next = function(v)
        if count < n then count = count + 1
        else subscriber:next(v) end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:take_while(pred)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local sub
    sub = source:subscribe({
      next = function(v)
        if subscriber._done then return end
        if pred(v) then
          subscriber:next(v)
        else
          subscriber:complete()  -- sets subscriber._done; sub unsubscribed below
        end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
    if subscriber._done and sub then sub:unsubscribe() end
    return sub
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:drop_while(pred)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local dropping = true
    return source:subscribe({
      next = function(v)
        if dropping then
          if not pred(v) then
            dropping = false
            subscriber:next(v)
          end
        else
          subscriber:next(v)
        end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:flat_map(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next = function(v)
        if subscriber._done then return end
        local inner = fn(v)
        inner:subscribe({
          next     = function(iv) subscriber:next(iv) end,
          error    = function(e)  subscriber:error(e) end,
          complete = function()   end,
        })
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

-- merge_map is an alias for flat_map (RxJS terminology)
Observable.merge_map = Observable.flat_map

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:concat_map(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next = function(v)
        if subscriber._done then return end
        local inner = fn(v)
        inner:subscribe({
          next     = function(iv) subscriber:next(iv) end,
          error    = function(e)  subscriber:error(e) end,
          complete = function()   end,  -- synchronous: inner completes before next outer
        })
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown, unknown) -> unknown, unknown) -> Observable
function Observable:reduce(fn, seed)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local acc = seed
    return source:subscribe({
      next     = function(v) acc = fn(acc, v) end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:next(acc); subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown, unknown) -> unknown, unknown) -> Observable
function Observable:scan(fn, seed)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local acc = seed
    return source:subscribe({
      next = function(v)
        acc = fn(acc, v)
        subscriber:next(acc)
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable) -> Observable
function Observable:distinct()
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local NONE = {}
    local prev = NONE --[[:! unknown]]
    return source:subscribe({
      next = function(v)
        if prev == NONE or prev ~= v then
          prev = v
          subscriber:next(v)
        end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

-- Alias matching RxJS name
Observable.distinct_until_changed = Observable.distinct

--: (Observable, (unknown) -> nil) -> Observable
function Observable:do_next(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) fn(v); subscriber:next(v) end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown) -> nil) -> Observable
function Observable:do_error(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) subscriber:next(v) end,
      error    = function(e) fn(e); subscriber:error(e) end,
      complete = function()  subscriber:complete() end,
    })
  end)
end

--: (Observable, () -> nil) -> Observable
function Observable:do_complete(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) subscriber:next(v) end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  fn(); subscriber:complete() end,
    })
  end)
end

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:catch(fn)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return source:subscribe({
      next     = function(v) subscriber:next(v) end,
      error    = function(e)
        local recovery = fn(e)
        recovery:subscribe({
          next     = function(v) subscriber:next(v) end,
          error    = function(e2) subscriber:error(e2) end,
          complete = function()   subscriber:complete() end,
        })
      end,
      complete = function() subscriber:complete() end,
    })
  end)
end

--: (Observable, integer) -> Observable
function Observable:retry(n)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local attempts = 0
    local function attempt()
      source:subscribe({
        next  = function(v) subscriber:next(v) end,
        error = function(e)
          if attempts < n then
            attempts = attempts + 1
            attempt()
          else
            subscriber:error(e)
          end
        end,
        complete = function() subscriber:complete() end,
      })
    end
    attempt()
  end)
end

-- timeout: error if no value arrives within ms milliseconds.
-- clock_fn() should return current time in milliseconds.
--: (Observable, number, () -> number) -> Observable
function Observable:timeout(ms, clock_fn)
  if not clock_fn then error("observer:timeout: clock_fn is required") end
  local source = self
  local cfn = clock_fn
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local deadline = cfn() + ms
    return source:subscribe({
      next = function(v)
        if cfn() > deadline then
          subscriber:error("timeout")
        else
          subscriber:next(v)
        end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()
        if cfn() > deadline then
          subscriber:error("timeout")
        else
          subscriber:complete()
        end
      end,
    })
  end)
end

--: (Observable, unknown) -> Observable
function Observable:default_if_empty(default_val)
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local had_value = false
    return source:subscribe({
      next = function(v)
        had_value = true
        subscriber:next(v)
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()
        if not had_value then subscriber:next(default_val) end
        subscriber:complete()
      end,
    })
  end)
end

--: (Observable) -> Observable
function Observable:first()
  return Observable.take(self, 1)
end

--: (Observable) -> Observable
function Observable:last()
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local last_val
    local had_value = false
    return source:subscribe({
      next = function(v)
        last_val = v
        had_value = true
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()
        if had_value then subscriber:next(last_val) end
        subscriber:complete()
      end,
    })
  end)
end

-- Blocking/sync collect: subscribes and returns array of all values.
-- Returns (array) or (nil, errmsg) on error.
function Observable:to_array()
  local result = {}
  local err_msg
  self:subscribe({
    next     = function(v) result[#result + 1] = v end,
    error    = function(e) err_msg = e end,
    complete = function()  end,
  })
  if err_msg then return nil, err_msg end
  return result
end

function Observable:count()
  return self:reduce(function(acc, _) return acc + 1 end, 0)
end

function Observable:sum()
  return self:reduce(function(acc, v) return acc + v end, 0)
end

function Observable:min()
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local m
    return source:subscribe({
      next = function(v)
        if m == nil or v < m then m = v end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  if m ~= nil then subscriber:next(m) end; subscriber:complete() end,
    })
  end)
end

function Observable:max()
  local source = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local m
    return source:subscribe({
      next = function(v)
        if m == nil or v > m then m = v end
      end,
      error    = function(e) subscriber:error(e) end,
      complete = function()  if m ~= nil then subscriber:next(m) end; subscriber:complete() end,
    })
  end)
end

-- ---------------------------------------------------------------------------
-- Combining constructors
-- ---------------------------------------------------------------------------

-- Obs.merge(...): interleave values from multiple observables
function M.merge(...)
  local sources = { ... }
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local subs = {} --[[: { [integer]: Subscription }]]
    local completed = 0
    local total = #sources
    for i = 1, total do
      local src = sources[i] --[[:! Observable]]
      subs[i] = src:subscribe({
        next  = function(v) subscriber:next(v) end,
        error = function(e) subscriber:error(e) end,
        complete = function()
          completed = completed + 1
          if completed == total then subscriber:complete() end
        end,
      })
    end
    return composite_subscription(subs)
  end)
end

-- Obs.concat(...): subscribe sequentially
function M.concat(...)
  local sources = { ... }
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local idx = 0
    local function next_source()
      idx = idx + 1
      if idx > #sources then
        subscriber:complete()
        return
      end
      local src = sources[idx] --[[:! Observable]]
      src:subscribe({
        next     = function(v) subscriber:next(v) end,
        error    = function(e) subscriber:error(e) end,
        complete = next_source,
      })
    end
    next_source()
  end)
end

-- Obs.zip(obs1, obs2, ...[, fn]): pair values by index
-- If last argument is a function, use it to combine values; otherwise emit array.
function M.zip(...)
  local args = { ... }
  local combine_fn --: ((...unknown) -> unknown) | nil
  if type(args[#args]) == "function" then
    combine_fn = args[#args] --[[:! (...unknown) -> unknown]]
    args[#args] = nil
  end
  local sources = args
  local n = #sources
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local buffers = {} --[[: { [integer]: { [integer]: unknown } }]]
    local completed_mask = {} --[[: { [integer]: boolean }]]
    for i = 1, n do buffers[i] = {}; completed_mask[i] = false end

    local function try_emit()
      for i = 1, n do
        if #buffers[i] == 0 then return end
      end
      local vals = {}
      for i = 1, n do
        vals[i] = table.remove(buffers[i], 1)
      end
      if combine_fn then
        subscriber:next(combine_fn(unpack(vals)))
      else
        subscriber:next(vals)
      end
    end

    local function check_done(idx)
      completed_mask[idx] = true
      for i = 1, n do
        if not completed_mask[i] then return end
      end
      subscriber:complete()
    end

    local subs = {} --[[: { [integer]: Subscription }]]
    for i = 1, n do
      local idx = i
      local src = sources[i] --[[:! Observable]]
      subs[i] = src:subscribe({
        next = function(v)
          buffers[idx][#buffers[idx] + 1] = v
          try_emit()
        end,
        error    = function(e) subscriber:error(e) end,
        complete = function()  check_done(idx) end,
      })
    end
    return composite_subscription(subs)
  end)
end

-- Obs.combine_latest(obs1, obs2, ...): emit latest value from each on any update
function M.combine_latest(...)
  local sources = { ... }
  local n = #sources
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    local latest = {}
    local has_value = {} --[[: { [integer]: boolean }]]
    local completed_count = 0
    local ready = 0  -- count of sources that have emitted at least once

    local subs = {} --[[: { [integer]: Subscription }]]
    for i = 1, n do
      local idx = i
      local src = sources[i] --[[:! Observable]]
      subs[i] = src:subscribe({
        next = function(v)
          if not has_value[idx] then
            has_value[idx] = true
            ready = ready + 1
          end
          latest[idx] = v
          if ready == n then
            local vals = {}
            for j = 1, n do vals[j] = latest[j] end
            subscriber:next(vals)
          end
        end,
        error = function(e) subscriber:error(e) end,
        complete = function()
          completed_count = completed_count + 1
          if completed_count == n then subscriber:complete() end
        end,
      })
    end
    return composite_subscription(subs)
  end)
end

-- ---------------------------------------------------------------------------
-- Subject (hot observable)
-- ---------------------------------------------------------------------------

local Subject = {}
Subject.__index = Subject

function M.subject()
  local self = setmetatable({
    _subscribers = {} --[[: { [integer]: Observer }]],
    _closed = false,
    _error = nil,
  }, Subject)
  -- Also inherit Observable methods for operators
  return self
end

--: (Subject, Observer | ((unknown) -> nil) | nil) -> Subscription
function Subject:subscribe(observer_or_fn)
  local observer = normalize_observer(observer_or_fn)
  if self._closed then
    if self._error then
      if observer.error then observer.error(self._error) end
    else
      if observer.complete then observer.complete() end
    end
    return new_subscription(nil)
  end

  local subs_list = self._subscribers
  subs_list[#subs_list + 1] = observer
  local sub = new_subscription(function()
    for i = 1, #subs_list do
      if subs_list[i] == observer then
        table.remove(subs_list, i)
        return
      end
    end
  end)
  return sub --[[:! Subscription]]
end

--: (Subject, unknown) -> nil
function Subject:next(v)
  if self._closed then return end
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.next then obs.next(v) end
  end
end

--: (Subject, unknown) -> nil
function Subject:error(e)
  if self._closed then return end
  self._closed = true
  self._error = e
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.error then obs.error(e) end
  end
  self._subscribers = {}
end

--: (Subject) -> nil
function Subject:complete()
  if self._closed then return end
  self._closed = true
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.complete then obs.complete() end
  end
  self._subscribers = {}
end

-- Make Subject support operator chaining by inheriting Observable methods.
-- We wrap it as an Observable for operator use.
function Subject:as_observable()
  local self_ref = self
  --: (Subscriber) -> (Subscription | ((() -> nil) | nil))
  return new_observable(function(subscriber)
    return self_ref:subscribe(subscriber._obs)
  end)
end

-- Allow operators like map/filter to be called on Subject directly
for k, v in pairs(Observable) do
  if Subject[k] == nil then
    Subject[k] = v
  end
end

-- ---------------------------------------------------------------------------
-- BehaviorSubject (hot + replays current value)
-- ---------------------------------------------------------------------------

local BehaviorSubject = {}
BehaviorSubject.__index = BehaviorSubject

function M.behavior_subject(initial)
  local self = setmetatable({
    _subscribers = {} --[[: { [integer]: Observer }]],
    _closed = false,
    _error = nil,
    _value = initial,
  }, BehaviorSubject)
  return self
end

--: (BehaviorSubject, Observer | ((unknown) -> nil) | nil) -> Subscription
function BehaviorSubject:subscribe(observer_or_fn)
  local observer = normalize_observer(observer_or_fn)
  if self._closed then
    if self._error then
      if observer.error then observer.error(self._error) end
    else
      if observer.next then observer.next(self._value) end
      if observer.complete then observer.complete() end
    end
    return new_subscription(nil)
  end

  -- Emit current value immediately
  if observer.next then observer.next(self._value) end

  local subs_list = self._subscribers
  subs_list[#subs_list + 1] = observer
  local sub = new_subscription(function()
    for i = 1, #subs_list do
      if subs_list[i] == observer then
        table.remove(subs_list, i)
        return
      end
    end
  end)
  return sub --[[:! Subscription]]
end

--: (BehaviorSubject, unknown) -> nil
function BehaviorSubject:next(v)
  if self._closed then return end
  self._value = v
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.next then obs.next(v) end
  end
end

--: (BehaviorSubject, unknown) -> nil
function BehaviorSubject:error(e)
  if self._closed then return end
  self._closed = true
  self._error = e
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.error then obs.error(e) end
  end
  self._subscribers = {}
end

--: (BehaviorSubject) -> nil
function BehaviorSubject:complete()
  if self._closed then return end
  self._closed = true
  for i = 1, #self._subscribers do
    local obs = self._subscribers[i]
    if obs.complete then obs.complete() end
  end
  self._subscribers = {}
end

--: (BehaviorSubject) -> unknown
function BehaviorSubject:get_value()
  return self._value
end

-- Inherit Observable operators
for k, v in pairs(Observable) do
  if BehaviorSubject[k] == nil then
    BehaviorSubject[k] = v
  end
end

return M
