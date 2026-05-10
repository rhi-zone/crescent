if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- Promise-based async/await over Lua coroutines.
-- Promises are plain tables with a state machine: pending → fulfilled | rejected.
-- Async functions are coroutines that yield on promises and resume when settled.
-- M.run / loop:run_until drive all pending continuations synchronously.
local M = {}
M._tier = "pure"

-- ── Promise state constants ──────────────────────────────────────────────────

local PENDING   = "pending"
local FULFILLED = "fulfilled"
local REJECTED  = "rejected"

-- ── Type aliases ─────────────────────────────────────────────────────────────

--:: CbList = { [integer]: (unknown) -> unknown }
--:: FinallyList = { [integer]: () -> unknown }
--:: PromiseP = { _state: string, value: unknown, reason: unknown, _on_fulfill: CbList, _on_reject: CbList, _on_finally: FinallyList, ... }
--:: ResolveFn = (value: unknown) -> nil
--:: RejectFn = (reason: unknown) -> nil
--:: LoopQ = { [integer]: () -> unknown }
--:: LoopTimers = { [integer]: { number, ResolveFn } }
--:: LoopObj = { _queue: LoopQ, _timers: LoopTimers, _time: number, tick: (LoopObj, number | nil) -> nil, run_until: (LoopObj, PromiseP) -> (unknown, unknown), sleep: (LoopObj, number) -> PromiseP, clear: (LoopObj) -> nil, queue: (LoopObj, () -> unknown) -> nil, ... }

-- ── Internal helpers ─────────────────────────────────────────────────────────

-- Forward declaration so settle is visible to all closures below.
local settle

-- Resolve a promise to a value (or flatten if value is a promise).
-- settle(p, "fulfilled"|"rejected", value_or_reason)
--: (PromiseP, string, unknown) -> nil
settle = function(p, state, value)
  if p._state ~= PENDING then return end
  -- If value is itself a promise, adopt its eventual state (flattening).
  if type(value) == "table" and value._state ~= nil then
    local vp = value --[[:! PromiseP]]
    if vp._state == PENDING then
      -- Subscribe to the inner promise.
      vp._on_fulfill[#vp._on_fulfill + 1] = function(v) settle(p, FULFILLED, v) end
      vp._on_reject[#vp._on_reject + 1]   = function(r) settle(p, REJECTED,  r) end
    elseif vp._state == FULFILLED then
      settle(p, FULFILLED, vp.value)
    else
      settle(p, REJECTED, vp.reason)
    end
    return
  end
  p._state = state
  if state == FULFILLED then
    p.value  = value
  else
    p.reason = value
  end
  -- Run all queued continuations.
  local cbs = p._on_fulfill --: CbList
  if state ~= FULFILLED then cbs = p._on_reject end
  for i = 1, #cbs do
    local ok, err = pcall(cbs[i], value)
    if not ok then
      -- Continuations that throw are swallowed; each derived promise
      -- captures its own rejection internally via the inline handlers below.
      _ = err
    end
  end
  -- If rejected with no rejection handlers, also drain on_fulfill (none).
  -- Drain the other side's "always" handlers (finally).
  local fncbs = p._on_finally --[[:! FinallyList]]
  for i = 1, #fncbs do
    pcall(fncbs[i])
  end
  p._on_fulfill = {}
  p._on_reject  = {}
  p._on_finally = {}
end

-- ── Promise constructor ──────────────────────────────────────────────────────

local Promise = {}
Promise.__index = Promise

--- Return a new { promise, resolve, reject } triple.
--: () -> (PromiseP, ResolveFn, RejectFn)
function M.promise()
  local on_fulfill = {} --: CbList
  local on_reject  = {} --: CbList
  local on_finally = {} --: FinallyList
  local p = setmetatable({
    _state      = PENDING,
    value       = nil,
    reason      = nil,
    _on_fulfill = on_fulfill,
    _on_reject  = on_reject,
    _on_finally = on_finally,
  }, Promise) --[[: any]]
  local p_ = p --[[:! PromiseP]]

  --: ResolveFn
  local function resolve(value) settle(p_, FULFILLED, value) end
  --: RejectFn
  local function reject(reason) settle(p_, REJECTED,  reason) end

  return p_, resolve, reject
end

--- Create an already-resolved promise.
function M.resolved(value)
  local p, resolve, _ = M.promise()
  resolve(value)
  return p
end

--- Create an already-rejected promise.
function M.rejected(reason)
  local p, _, reject = M.promise()
  reject(reason)
  return p
end

--- Create a promise that resolves with fn()'s return value on next loop tick.
-- If fn raises, the promise is rejected with the error.
-- Note: without an event loop, the fn is called immediately (synchronous defer).
function M.defer(fn)
  local p, resolve, reject = M.promise()
  local ok, result = pcall(fn)
  if ok then
    resolve(result)
  else
    reject(result)
  end
  return p
end

-- ── Promise methods ──────────────────────────────────────────────────────────

--- Chain a fulfillment handler. Returns a new promise.
-- fn(value) -> value | promise
function Promise:and_then(fn)
  local self_ = self --[[:! PromiseP]]
  local next_p = M.promise()
  -- Only one branch will fire depending on source state.
  if self_._state == PENDING then
    -- Queue both handlers; exactly one will fire.
    self_._on_fulfill[#self_._on_fulfill + 1] = function(v)
      local ok, result = pcall(fn, v)
      if ok then settle(next_p, FULFILLED, result)
      else      settle(next_p, REJECTED,  result) end
    end
    self_._on_reject[#self_._on_reject + 1] = function(r)
      settle(next_p, REJECTED, r)
    end
  elseif self_._state == FULFILLED then
    local ok, result = pcall(fn, self_.value)
    if ok then settle(next_p, FULFILLED, result)
    else      settle(next_p, REJECTED,  result) end
  else
    settle(next_p, REJECTED, self_.reason)
  end
  return next_p
end

--- Chain a rejection handler. Returns a new promise.
-- fn(reason) -> value | promise  (can recover)
function Promise:catch(fn)
  local self_ = self --[[:! PromiseP]]
  local next_p = M.promise()
  if self_._state == PENDING then
    self_._on_fulfill[#self_._on_fulfill + 1] = function(v)
      settle(next_p, FULFILLED, v)
    end
    self_._on_reject[#self_._on_reject + 1] = function(r)
      local ok, result = pcall(fn, r)
      if ok then settle(next_p, FULFILLED, result)
      else      settle(next_p, REJECTED,  result) end
    end
  elseif self_._state == FULFILLED then
    settle(next_p, FULFILLED, self_.value)
  else
    local ok, result = pcall(fn, self_.reason)
    if ok then settle(next_p, FULFILLED, result)
    else      settle(next_p, REJECTED,  result) end
  end
  return next_p
end

--- Register a callback called regardless of outcome. Returns a new promise
-- that settles with the same value/reason as self.
function Promise:finally(fn)
  local self_ = self --[[:! PromiseP]]
  local next_p = M.promise()

  local function on_settle_fulfill(v)
    pcall(fn)
    settle(next_p, FULFILLED, v)
  end
  local function on_settle_reject(r)
    pcall(fn)
    settle(next_p, REJECTED, r)
  end

  if self_._state == PENDING then
    self_._on_fulfill[#self_._on_fulfill + 1] = on_settle_fulfill
    self_._on_reject[#self_._on_reject + 1]   = on_settle_reject
  elseif self_._state == FULFILLED then
    on_settle_fulfill(self_.value)
  else
    on_settle_reject(self_.reason)
  end

  return next_p
end

function Promise:is_pending()   local s = self --[[:! PromiseP]]; return s._state == PENDING   end
function Promise:is_resolved()  local s = self --[[:! PromiseP]]; return s._state == FULFILLED end
function Promise:is_rejected()  local s = self --[[:! PromiseP]]; return s._state == REJECTED  end

-- ── Combinators ──────────────────────────────────────────────────────────────

--- Resolves with an array of values when all promises fulfill.
-- Rejects immediately when any promise rejects.
function M.all(promises)
  local n = #promises
  if n == 0 then return M.resolved({}) end

  local p, resolve, reject = M.promise()
  local results  = {}
  local done     = 0
  local rejected = false

  for i = 1, n do
    local idx = i
    promises[i]:and_then(function(v)
      if rejected then return end
      results[idx] = v
      done = done + 1
      if done == n then resolve(results) end
    end):catch(function(r)
      if rejected then return end
      rejected = true
      reject(r)
    end)
  end

  return p
end

--- Resolves or rejects with the first promise that settles.
function M.race(promises)
  local p, resolve, reject = M.promise()
  local settled = false

  for i = 1, #promises do
    promises[i]:and_then(function(v)
      if settled then return end
      settled = true
      resolve(v)
    end):catch(function(r)
      if settled then return end
      settled = true
      reject(r)
    end)
  end

  return p
end

--- Resolves with the first promise that fulfills.
-- Rejects with an aggregate table { errors = {...} } if all reject.
function M.any(promises)
  local n = #promises
  if n == 0 then
    return M.rejected({ errors = {}, message = "All promises were rejected" })
  end

  local p, resolve, reject = M.promise()
  local errors   = {}
  local rejected_count = 0
  local resolved = false

  for i = 1, n do
    local idx = i
    promises[i]:and_then(function(v)
      if resolved then return end
      resolved = true
      resolve(v)
    end):catch(function(r)
      if resolved then return end
      errors[idx] = r
      rejected_count = rejected_count + 1
      if rejected_count == n then
        reject({ errors = errors, message = "All promises were rejected" })
      end
    end)
  end

  return p
end

--- Always resolves with an array of settlement objects:
--   { status = "fulfilled", value = ... }
--   { status = "rejected",  reason = ... }
function M.all_settled(promises)
  local n = #promises
  if n == 0 then return M.resolved({}) end

  local p, resolve, _ = M.promise()
  local results = {}
  local count   = 0

  for i = 1, n do
    local idx = i
    promises[i]:and_then(function(v)
      results[idx] = { status = "fulfilled", value = v }
      count = count + 1
      if count == n then resolve(results) end
    end):catch(function(r)
      results[idx] = { status = "rejected", reason = r }
      count = count + 1
      if count == n then resolve(results) end
    end)
  end

  return p
end

-- ── Event loop ───────────────────────────────────────────────────────────────

local Loop = {}
Loop.__index = Loop

--- Create a new event loop.
--: () -> LoopObj
function M.loop()
  local lq = {} --: LoopQ
  local lt = {} --: LoopTimers
  local ltime = 0 --: number
  local lobj = setmetatable({
    _queue    = lq,
    _timers   = lt,
    _time     = ltime,
  }, Loop) --[[: any]]
  return lobj --[[:! LoopObj]]
end

--- Schedule fn for the next tick.
function Loop:queue(fn)
  local self_ = self --[[:! LoopObj]]
  self_._queue[#self_._queue + 1] = fn
end

--- Run all currently queued functions (and anything they enqueue), advancing
-- internal time by `elapsed` milliseconds (default 0).
function Loop:tick(elapsed)
  local self_ = self --[[:! LoopObj]]
  elapsed = elapsed or 0
  self_._time = self_._time + (elapsed --[[:! number]])

  -- Fire elapsed timers.
  for i = #self_._timers, 1, -1 do
    local t = self_._timers[i]
    if self_._time >= t[1] then
      table.remove(self_._timers, i)
      t[2](nil)  -- resolve the timer promise with nil
    end
  end

  -- Drain the queue (snapshot to avoid infinite loops if tick re-enqueues).
  local batch = self_._queue
  self_._queue = {}
  for i = 1, #batch do
    batch[i]()
  end
end

--- Run the loop until `promise` settles. Returns value, err.
-- Runs a bounded number of ticks (prevents infinite loops).
function Loop:run_until(promise)
  local self_ = self --[[:! LoopObj]]
  local p_ = promise --[[:! PromiseP]]
  local max_ticks = 100000
  local ticks = 0
  while p_._state == PENDING and ticks < max_ticks do
    self_:tick(0)
    ticks = ticks + 1
    -- If no more work to do but promise is still pending, bail.
    if #self_._queue == 0 and #self_._timers == 0 then break end
  end
  if p_._state == FULFILLED then
    return p_.value, nil
  elseif p_._state == REJECTED then
    return nil, p_.reason
  else
    return nil, "event loop exhausted without promise settling"
  end
end

--- Clear all queued work and timers.
function Loop:clear()
  local self_ = self --[[:! LoopObj]]
  self_._queue  = {}
  self_._timers = {}
end

--- Create a sleep promise that resolves after `ms` milliseconds.
-- Uses `clock_fn()` (defaults to loop's internal time counter).
function Loop:sleep(ms)
  local self_ = self --[[:! LoopObj]]
  local deadline = self_._time + ms
  local p, resolve, _ = M.promise()
  self_._timers[#self_._timers + 1] = { deadline, resolve }
  return p
end

-- ── Module-level sleep / run ─────────────────────────────────────────────────

--- Create a sleep promise on a given loop.
-- M.sleep(ms, loop) -> promise
function M.sleep(ms, loop_arg)
  if not loop_arg then
    error("M.sleep requires a loop argument; use loop:sleep(ms) or pass a loop as second arg")
  end
  return loop_arg:sleep(ms)
end

--- Drive a promise (or call fn and drive its result) synchronously to completion.
-- Returns value, err.
function M.run(promise_or_fn)
  local lp = M.loop()
  local p
  if type(promise_or_fn) == "function" then
    local ok, result = pcall(promise_or_fn)
    if not ok then return nil, result end
    p = result
    if type(p) ~= "table" or p._state == nil then
      -- fn returned a plain value, not a promise — wrap it.
      p = M.resolved(p)
    end
  else
    p = promise_or_fn
  end
  return lp:run_until(p)
end

-- ── Async / await ────────────────────────────────────────────────────────────

--- Wrap fn as an async function. Calling async_fn(...) returns a promise.
-- Inside fn, use M.await(promise) to suspend until the promise settles.
function M.async(fn)
  return function(...)
    local args = { ... }
    local p, resolve, reject = M.promise()

    -- co_box: wrap the coroutine so its type is known inside closures.
    local co_box = { co = coroutine.create(function()
      local ok, result = pcall(fn, unpack(args))
      if ok then
        resolve(result)
      else
        reject(result)
      end
    end) } --: { co: Thread }

    -- Drive the coroutine forward.
    local function step(val, is_err)
      local ok, yielded
      local co = co_box.co
      if is_err then
        -- Resume with error propagation: re-raise inside the coroutine.
        ok, yielded = coroutine.resume(co, nil, val)
      else
        ok, yielded = coroutine.resume(co, val)
      end

      if not ok then
        -- Coroutine itself errored (not a user pcall).
        reject(yielded)
        return
      end

      if coroutine.status(co) == "dead" then
        -- Coroutine finished — resolve/reject already called inside.
        return
      end

      -- `yielded` should be a promise.
      if type(yielded) ~= "table" then
        reject("async: coroutine yielded a non-promise value")
        return
      end
      local yp = yielded --[[:! PromiseP]]
      if yp._state == nil then
        reject("async: coroutine yielded a non-promise value")
        return
      end

      -- When the yielded promise settles, resume the coroutine.
      if yp._state == FULFILLED then
        step(yp.value, false)
      elseif yp._state == REJECTED then
        step(yp.reason, true)
      else
        yp._on_fulfill[#yp._on_fulfill + 1] = function(v) step(v, false) end
        yp._on_reject[#yp._on_reject + 1]   = function(r) step(r, true)  end
      end
    end

    step(nil, false)
    return p
  end
end

--- Await a promise inside an async function (coroutine).
-- Returns the resolved value, or raises the rejection reason.
function M.await(promise)
  if type(promise) ~= "table" or promise._state == nil then
    error("await: argument must be a promise")
  end
  -- If already settled, no yield needed.
  if promise._state == FULFILLED then
    return promise.value
  elseif promise._state == REJECTED then
    error(promise.reason)
  end
  -- Yield to the async machinery; will be resumed with (value) or (nil, err).
  local val, err = coroutine.yield(promise)
  if err ~= nil then
    error(err)
  end
  return val
end

return M
