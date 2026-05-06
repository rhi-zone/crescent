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
--:: Subscription = { _closed: boolean, _unsub: (() -> nil) | nil }
--:: Subscriber = { _obs: Observer, _sub: Subscription, _done: boolean }
--:: Subject = { _subscribers: { [integer]: Observer }, _closed: boolean, _error: unknown }
--:: BehaviorSubject = { _subscribers: { [integer]: Observer }, _closed: boolean, _error: unknown, _value: unknown }
--:: Observable = { _subscribe: (Subscriber) -> ((() -> nil) | nil) }

-- ---------------------------------------------------------------------------
-- Subscription
-- ---------------------------------------------------------------------------

local Subscription = {}
Subscription.__index = Subscription

--: ((() -> nil) | nil) -> Subscription
local function new_subscription(unsub_fn)
  return setmetatable({ _closed = false, _unsub = unsub_fn }, Subscription) --[[:! Subscription]]
end

--: (Subscription) -> nil
function Subscription:unsubscribe()
  local self_ = self --[[:! Subscription]]
  if not self_._closed then
    self_._closed = true
    if self_._unsub then self_._unsub() end
  end
end

-- Composite subscription: unsubscribing unsubscribes all children.
--: ({ [integer]: Subscription }) -> Subscription
local function composite_subscription(subs)
  return new_subscription(function()
    for i = 1, #subs do
      local s = subs[i] --[[:! Subscription]]
      -- call unsubscribe directly to avoid unknown method dispatch
      if not s._closed then
        s._closed = true
        if s._unsub then s._unsub() end
      end
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
  return setmetatable({ _obs = observer, _sub = subscription, _done = false }, Subscriber) --[[:! Subscriber]]
end

--: (Subscriber, unknown) -> nil
function Subscriber:next(v)
  local self_ = self --[[:! Subscriber]]
  if self_._done then return end
  local fn = self_._obs.next
  if fn ~= nil then (--[[:! (unknown) -> nil]] fn)(v) end
end

--: (Subscriber, unknown) -> nil
function Subscriber:error(e)
  local self_ = self --[[:! Subscriber]]
  if self_._done then return end
  self_._done = true
  self_._sub._closed = true
  local fn = self_._obs.error
  if fn ~= nil then (--[[:! (unknown) -> nil]] fn)(e) end
end

--: (Subscriber) -> nil
function Subscriber:complete()
  local self_ = self --[[:! Subscriber]]
  if self_._done then return end
  self_._done = true
  self_._sub._closed = true
  local fn = self_._obs.complete
  if fn ~= nil then (--[[:! () -> nil]] fn)() end
end

-- ---------------------------------------------------------------------------
-- Subscriber method shims (direct prototype calls for closures)
-- ---------------------------------------------------------------------------

--: (Subscriber, unknown) -> nil
local function sub_next(s, v) Subscriber.next(s, v) end
--: (Subscriber, unknown) -> nil
local function sub_error(s, e) Subscriber.error(s, e) end
--: (Subscriber) -> nil
local function sub_complete(s) Subscriber.complete(s) end

-- ---------------------------------------------------------------------------
-- Observable
-- ---------------------------------------------------------------------------

local Observable = {}
Observable.__index = Observable

--: ((Subscriber) -> ((() -> nil) | nil)) -> Observable
local function new_observable(subscribe_fn)
  return setmetatable({ _subscribe = subscribe_fn }, Observable) --[[:! Observable]]
end

-- Normalize observer argument: fn shorthand → {next=fn}
--: (unknown) -> Observer
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
local function observable_subscribe(obs, observer_or_fn)
  local obs_ = obs --[[:! Observable]]
  local observer = normalize_observer(observer_or_fn)
  -- Fast path: observable has _subscribe (created via new_observable)
  local subscribe_fn = obs_._subscribe
  if subscribe_fn ~= nil then
    local sub = new_subscription(nil)
    local subscriber = new_subscriber(observer, sub)
    local unsub_fn = subscribe_fn(subscriber)
    if not sub._closed and type(unsub_fn) == "function" then
      sub._unsub = unsub_fn --[[:! () -> nil]]
    end
    return sub
  end
  -- Fallback: subscribable without _subscribe (e.g. Subject created by M.subject()).
  -- Subjects store subscribe directly on the subj table object.
  -- We need to access it without the typechecker knowing the type.
  local sub_any = obs --[[:! unknown]]
  -- Dynamically call subscribe; type system can't verify this path
  -- This is safe: obs is always a subscribable passed internally
  local ok, r = pcall(function()
    local sub_method = (sub_any --[[:! { subscribe: (unknown, { complete: (() -> nil) | nil, error: ((unknown) -> nil) | nil, next: ((unknown) -> nil) | nil }) -> { _closed: boolean, _unsub: (() -> nil) | nil } }]]).subscribe
    return sub_method(obs, observer)
  end)
  if ok then return r --[[:! Subscription]] end
  return new_subscription(nil)
end

function Observable:subscribe(observer_or_fn)
  return observable_subscribe(self --[[:! Observable]], observer_or_fn)
end

-- ---------------------------------------------------------------------------
-- Factory constructors
-- ---------------------------------------------------------------------------

-- Obs.create(fn): raw constructor
--: ((Subscriber) -> ((() -> nil) | nil)) -> Observable
function M.create(fn)
  return new_observable(fn)
end

-- Obs.of(...): emit each argument
function M.of(...)
  local args = { ... }
  local n = select("#", ...) --[[:! integer]]
  return new_observable(function(s)
    for i = 1, n do
      if (s --[[:! Subscriber]])._done then return end
      sub_next(s, args[i])
    end
    sub_complete(s)
  end)
end

-- Obs.from(t): emit each element of array t
--: ({ [integer]: unknown }) -> Observable
function M.from(t)
  return new_observable(function(s)
    for i = 1, #t do
      if (s --[[:! Subscriber]])._done then return end
      sub_next(s, t[i])
    end
    sub_complete(s)
  end)
end

-- Obs.range(start, stop[, step]): emit integers
--: (integer, integer, integer | nil) -> Observable
function M.range(start, stop, step)
  step = step or 1
  return new_observable(function(s)
    local i = start
    while (step > 0 and i <= stop) or (step < 0 and i >= stop) do
      if (s --[[:! Subscriber]])._done then return end
      sub_next(s, i)
      i = i + step
    end
    sub_complete(s)
  end)
end

-- Obs.empty(): complete immediately
--: () -> Observable
function M.empty()
  return new_observable(function(s) sub_complete(s) end)
end

-- Obs.never(): never emits or completes
--: () -> Observable
function M.never()
  return new_observable(function(_) end)
end

-- Obs.error(msg): error immediately
--: (unknown) -> Observable
function M.error(msg)
  return new_observable(function(s) sub_error(s, msg) end)
end

-- Obs.defer(fn): create observable lazily per subscription
--: (() -> Observable) -> Observable
function M.defer(fn)
  return new_observable(function(s)
    local inner = fn() --[[:! Observable]]
    return inner._subscribe(s)
  end)
end

-- ---------------------------------------------------------------------------
-- Operators (methods on Observable)
-- ---------------------------------------------------------------------------

--: (Observable, (unknown) -> unknown) -> Observable
function Observable:map(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) sub_next(s, fn(v)) end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:filter(pred)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) if pred(v) then sub_next(s, v) end end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, integer) -> Observable
function Observable:take(n)
  local n_ = n --[[:! integer]]
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local count = 0
    -- sub may be nil during synchronous emission (local x = expr gotcha),
    -- so use s._done flag to stop; unsubscribe lazily after subscribe returns.
    local sub = observable_subscribe(source, {
      next = function(v)
        if (s --[[:! Subscriber]])._done then return end
        if count < n_ then
          count = count + 1
          sub_next(s, v)
          if count == n_ then
            sub_complete(s)  -- sets s._done; unsubscribe handled below
          end
        end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    }) --[[:! Subscription]]
    -- If the source completed synchronously inside subscribe, sub is already
    -- assigned here; unsubscribe to release resources.
    if (s --[[:! Subscriber]])._done then
      if not sub._closed then
        sub._closed = true
        if sub._unsub then sub._unsub() end
      end
    end
    return sub
  end)
end

--: (Observable, integer) -> Observable
function Observable:drop(n)
  local n_ = n --[[:! integer]]
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local count = 0
    return observable_subscribe(source, {
      next = function(v)
        if count < n_ then count = count + 1
        else sub_next(s, v) end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:take_while(pred)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local sub = observable_subscribe(source, {
      next = function(v)
        if (s --[[:! Subscriber]])._done then return end
        if pred(v) then
          sub_next(s, v)
        else
          sub_complete(s)  -- sets s._done; sub unsubscribed below
        end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    }) --[[:! Subscription]]
    if (s --[[:! Subscriber]])._done then
      if not sub._closed then
        sub._closed = true
        if sub._unsub then sub._unsub() end
      end
    end
    return sub
  end)
end

--: (Observable, (unknown) -> boolean) -> Observable
function Observable:drop_while(pred)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local dropping = true
    return observable_subscribe(source, {
      next = function(v)
        if dropping then
          if not pred(v) then
            dropping = false
            sub_next(s, v)
          end
        else
          sub_next(s, v)
        end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:flat_map(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next = function(v)
        if (s --[[:! Subscriber]])._done then return end
        local inner = fn(v) --[[:! Observable]]
        observable_subscribe(inner, {
          next     = function(iv) sub_next(s, iv) end,
          error    = function(e)  sub_error(s, e) end,
          complete = function()   end,
        })
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

-- merge_map is an alias for flat_map (RxJS terminology)
Observable.merge_map = Observable.flat_map

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:concat_map(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next = function(v)
        if (s --[[:! Subscriber]])._done then return end
        local inner = fn(v) --[[:! Observable]]
        observable_subscribe(inner, {
          next     = function(iv) sub_next(s, iv) end,
          error    = function(e)  sub_error(s, e) end,
          complete = function()   end,  -- synchronous: inner completes before next outer
        })
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown, unknown) -> unknown, unknown) -> Observable
function Observable:reduce(fn, seed)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local acc = seed
    return observable_subscribe(source, {
      next     = function(v) acc = fn(acc, v) end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_next(s, acc); sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown, unknown) -> unknown, unknown) -> Observable
function Observable:scan(fn, seed)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local acc = seed
    return observable_subscribe(source, {
      next = function(v)
        acc = fn(acc, v)
        sub_next(s, acc)
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable) -> Observable
function Observable:distinct()
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local NONE = {}
    local prev = NONE --[[:! unknown]]
    return observable_subscribe(source, {
      next = function(v)
        if prev == NONE or prev ~= v then
          prev = v
          sub_next(s, v)
        end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

-- Alias matching RxJS name
Observable.distinct_until_changed = Observable.distinct

--: (Observable, (unknown) -> nil) -> Observable
function Observable:do_next(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) fn(v); sub_next(s, v) end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown) -> nil) -> Observable
function Observable:do_error(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) sub_next(s, v) end,
      error    = function(e) fn(e); sub_error(s, e) end,
      complete = function()  sub_complete(s) end,
    })
  end)
end

--: (Observable, () -> nil) -> Observable
function Observable:do_complete(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) sub_next(s, v) end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  fn(); sub_complete(s) end,
    })
  end)
end

--: (Observable, (unknown) -> Observable) -> Observable
function Observable:catch(fn)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    return observable_subscribe(source, {
      next     = function(v) sub_next(s, v) end,
      error    = function(e)
        local recovery = fn(e) --[[:! Observable]]
        observable_subscribe(recovery, {
          next     = function(v) sub_next(s, v) end,
          error    = function(e2) sub_error(s, e2) end,
          complete = function()   sub_complete(s) end,
        })
      end,
      complete = function() sub_complete(s) end,
    })
  end)
end

--: (Observable, integer) -> Observable
function Observable:retry(n)
  local n_ = n --[[:! integer]]
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local attempts = 0
    local function attempt()
      observable_subscribe(source, {
        next  = function(v) sub_next(s, v) end,
        error = function(e)
          if attempts < n_ then
            attempts = attempts + 1
            attempt()
          else
            sub_error(s, e)
          end
        end,
        complete = function() sub_complete(s) end,
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
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local deadline = clock_fn() + ms
    return observable_subscribe(source, {
      next = function(v)
        if clock_fn() > deadline then
          sub_error(s, "timeout")
        else
          sub_next(s, v)
        end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()
        if clock_fn() > deadline then
          sub_error(s, "timeout")
        else
          sub_complete(s)
        end
      end,
    })
  end)
end

--: (Observable, unknown) -> Observable
function Observable:default_if_empty(default_val)
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local had_value = false
    return observable_subscribe(source, {
      next = function(v)
        had_value = true
        sub_next(s, v)
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()
        if not had_value then sub_next(s, default_val) end
        sub_complete(s)
      end,
    })
  end)
end

--: (Observable) -> Observable
function Observable:first()
  local self_ = self --[[:! Observable]]
  return Observable.take(self_, 1)
end

--: (Observable) -> Observable
function Observable:last()
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local last_val
    local had_value = false
    return observable_subscribe(source, {
      next = function(v)
        last_val = v
        had_value = true
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()
        if had_value then sub_next(s, last_val) end
        sub_complete(s)
      end,
    })
  end)
end

-- Blocking/sync collect: subscribes and returns array of all values.
-- Returns (array) or (nil, errmsg) on error.
--: (Observable) -> ({ [integer]: unknown } | nil, unknown | nil)
function Observable:to_array()
  local result = {} --[[:! { [integer]: unknown }]]
  local err_msg
  observable_subscribe(self --[[:! Observable]], {
    next     = function(v) result[#result + 1] = v end,
    error    = function(e) err_msg = e end,
    complete = function()  end,
  })
  if err_msg then return nil, err_msg end
  return result
end

--: (Observable) -> Observable
function Observable:count()
  local self_ = self --[[:! Observable]]
  return Observable.reduce(self_, function(acc, _) return (acc --[[:! integer]]) + 1 end, 0)
end

--: (Observable) -> Observable
function Observable:sum()
  local self_ = self --[[:! Observable]]
  return Observable.reduce(self_, function(acc, v) return (acc --[[:! number]]) + (v --[[:! number]]) end, 0)
end

--: (Observable) -> Observable
function Observable:min()
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local m
    return observable_subscribe(source, {
      next = function(v)
        if m == nil or (v --[[:! number]]) < (m --[[:! number]]) then m = v end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  if m ~= nil then sub_next(s, m) end; sub_complete(s) end,
    })
  end)
end

--: (Observable) -> Observable
function Observable:max()
  local source = self --[[:! Observable]]
  return new_observable(function(s)
    local m
    return observable_subscribe(source, {
      next = function(v)
        if m == nil or (v --[[:! number]]) > (m --[[:! number]]) then m = v end
      end,
      error    = function(e) sub_error(s, e) end,
      complete = function()  if m ~= nil then sub_next(s, m) end; sub_complete(s) end,
    })
  end)
end

-- ---------------------------------------------------------------------------
-- Combining constructors
-- ---------------------------------------------------------------------------

-- Obs.merge(...): interleave values from multiple observables
function M.merge(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  return new_observable(function(s)
    local subs = {} --[[:! { [integer]: Subscription }]]
    local completed = 0
    local total = #sources
    for i = 1, total do
      subs[i] = observable_subscribe(sources[i], {
        next  = function(v) sub_next(s, v) end,
        error = function(e) sub_error(s, e) end,
        complete = function()
          completed = completed + 1
          if completed == total then sub_complete(s) end
        end,
      }) --[[:! Subscription]]
    end
    return composite_subscription(subs)
  end)
end

-- Obs.concat(...): subscribe sequentially
function M.concat(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  return new_observable(function(s)
    local idx = 0
    local function next_source()
      idx = idx + 1
      if idx > #sources then
        sub_complete(s)
        return
      end
      observable_subscribe(sources[idx], {
        next     = function(v) sub_next(s, v) end,
        error    = function(e) sub_error(s, e) end,
        complete = next_source,
      })
    end
    next_source()
  end)
end

-- Obs.zip(obs1, obs2, ...[, fn]): pair values by index
-- If last argument is a function, use it to combine values; otherwise emit array.
function M.zip(...)
  local args = { ... } --[[:! { [integer]: unknown }]]
  local combine_fn
  if type(args[#args]) == "function" then
    combine_fn = args[#args] --[[:! (unknown) -> unknown]]
    args[#args] = nil
  end
  local sources = args --[[:! { [integer]: Observable }]]
  local n = #sources
  return new_observable(function(s)
    local buffers = {} --[[:! { [integer]: { [integer]: unknown } }]]
    local completed_mask = {} --[[:! { [integer]: boolean }]]
    for i = 1, n do buffers[i] = {}; completed_mask[i] = false end

    local function try_emit()
      for i = 1, n do
        if #buffers[i] == 0 then return end
      end
      local vals = {} --[[:! { [integer]: unknown }]]
      for i = 1, n do
        vals[i] = table.remove(buffers[i], 1)
      end
      if combine_fn then
        sub_next(s, (combine_fn --[[:! (unknown) -> unknown]])(unpack(vals)))
      else
        sub_next(s, vals)
      end
    end

    local function check_done(idx)
      completed_mask[idx] = true
      for i = 1, n do
        if not completed_mask[i] then return end
      end
      sub_complete(s)
    end

    local subs = {} --[[:! { [integer]: Subscription }]]
    for i = 1, n do
      local idx = i
      subs[i] = observable_subscribe(sources[i], {
        next = function(v)
          buffers[idx][#buffers[idx] + 1] = v
          try_emit()
        end,
        error    = function(e) sub_error(s, e) end,
        complete = function()  check_done(idx) end,
      }) --[[:! Subscription]]
    end
    return composite_subscription(subs)
  end)
end

-- Obs.combine_latest(obs1, obs2, ...): emit latest value from each on any update
function M.combine_latest(...)
  local sources = { ... } --[[:! { [integer]: Observable }]]
  local n = #sources
  return new_observable(function(s)
    local latest = {} --[[:! { [integer]: unknown }]]
    local has_value = {} --[[:! { [integer]: boolean }]]
    local completed_count = 0
    local ready = 0  -- count of sources that have emitted at least once

    local subs = {} --[[:! { [integer]: Subscription }]]
    for i = 1, n do
      local idx = i
      subs[i] = observable_subscribe(sources[i], {
        next = function(v)
          if not has_value[idx] then
            has_value[idx] = true
            ready = ready + 1
          end
          latest[idx] = v
          if ready == n then
            local vals = {} --[[:! { [integer]: unknown }]]
            for j = 1, n do vals[j] = latest[j] end
            sub_next(s, vals)
          end
        end,
        error = function(e) sub_error(s, e) end,
        complete = function()
          completed_count = completed_count + 1
          if completed_count == n then sub_complete(s) end
        end,
      }) --[[:! Subscription]]
    end
    return composite_subscription(subs)
  end)
end

-- ---------------------------------------------------------------------------
-- Subject (hot observable)
-- ---------------------------------------------------------------------------

local Subject = {}
Subject.__index = Subject

--: () -> Subject
function M.subject()
  local self = setmetatable({
    _subscribers = {} --[[:! { [integer]: Observer }]],
    _closed = false,
    _error = nil,
  }, Subject) --[[: Subject]]
  -- Also inherit Observable methods for operators
  return self
end

--: (Subject, Observer | ((unknown) -> nil) | nil) -> Subscription
function Subject:subscribe(observer_or_fn)
  local self_ = self --[[:! Subject]]
  local observer = normalize_observer(observer_or_fn)
  if self_._closed then
    if self_._error then
      if observer.error then observer.error(self_._error) end
    else
      if observer.complete then observer.complete() end
    end
    return new_subscription(nil)
  end

  local subs_list = self_._subscribers
  subs_list[#subs_list + 1] = observer
  local sub = new_subscription(function()
    for i = 1, #subs_list do
      if subs_list[i] == observer then
        table.remove(subs_list, i)
        return
      end
    end
  end) --[[:! Subscription]]
  return sub
end

--: (Subject, unknown) -> nil
function Subject:next(v)
  local self_ = self --[[:! Subject]]
  if self_._closed then return end
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.next then obs.next(v) end
  end
end

--: (Subject, unknown) -> nil
function Subject:error(e)
  local self_ = self --[[:! Subject]]
  if self_._closed then return end
  self_._closed = true
  self_._error = e
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.error then obs.error(e) end
  end
  self_._subscribers = {}
end

--: (Subject) -> nil
function Subject:complete()
  local self_ = self --[[:! Subject]]
  if self_._closed then return end
  self_._closed = true
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.complete then obs.complete() end
  end
  self_._subscribers = {}
end

-- Make Subject support operator chaining by inheriting Observable methods.
-- We wrap it as an Observable for operator use.
--: (Subject) -> Observable
function Subject:as_observable()
  local self_ref = self --[[:! Subject]]
  return new_observable(function(s)
    Subject.subscribe(self_ref, (s --[[:! Subscriber]])._obs)
    return nil
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

--: (unknown) -> BehaviorSubject
function M.behavior_subject(initial)
  local self = setmetatable({
    _subscribers = {} --[[:! { [integer]: Observer }]],
    _closed = false,
    _error = nil,
    _value = initial,
  }, BehaviorSubject) --[[: BehaviorSubject]]
  return self
end

--: (BehaviorSubject, Observer | ((unknown) -> nil) | nil) -> Subscription
function BehaviorSubject:subscribe(observer_or_fn)
  local self_ = self --[[:! BehaviorSubject]]
  local observer = normalize_observer(observer_or_fn)
  if self_._closed then
    if self_._error then
      if observer.error then observer.error(self_._error) end
    else
      if observer.next then observer.next(self_._value) end
      if observer.complete then observer.complete() end
    end
    return new_subscription(nil)
  end

  -- Emit current value immediately
  if observer.next then observer.next(self_._value) end

  local subs_list = self_._subscribers
  subs_list[#subs_list + 1] = observer
  local sub = new_subscription(function()
    for i = 1, #subs_list do
      if subs_list[i] == observer then
        table.remove(subs_list, i)
        return
      end
    end
  end) --[[:! Subscription]]
  return sub
end

--: (BehaviorSubject, unknown) -> nil
function BehaviorSubject:next(v)
  local self_ = self --[[:! BehaviorSubject]]
  if self_._closed then return end
  self_._value = v
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.next then obs.next(v) end
  end
end

--: (BehaviorSubject, unknown) -> nil
function BehaviorSubject:error(e)
  local self_ = self --[[:! BehaviorSubject]]
  if self_._closed then return end
  self_._closed = true
  self_._error = e
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.error then obs.error(e) end
  end
  self_._subscribers = {}
end

--: (BehaviorSubject) -> nil
function BehaviorSubject:complete()
  local self_ = self --[[:! BehaviorSubject]]
  if self_._closed then return end
  self_._closed = true
  for i = 1, #self_._subscribers do
    local obs = self_._subscribers[i]
    if obs.complete then obs.complete() end
  end
  self_._subscribers = {}
end

--: (BehaviorSubject) -> unknown
function BehaviorSubject:get_value()
  local self_ = self --[[:! BehaviorSubject]]
  return self_._value
end

-- Inherit Observable operators
for k, v in pairs(Observable) do
  if BehaviorSubject[k] == nil then
    BehaviorSubject[k] = v
  end
end

return M
