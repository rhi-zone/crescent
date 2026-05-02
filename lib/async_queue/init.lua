-- lib/async_queue/init.lua
-- Coroutine-based work queue scheduler with priorities, concurrency limits,
-- retries, rate limiting, and a batch processor.
--
-- All "async" is simulated: tasks execute synchronously when tick() is called.
-- The concurrency limit controls how many are started per tick and retries/
-- delays are simulated via os.clock.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: string
M._tier = "pure"

local co_create  = coroutine.create
local co_resume  = coroutine.resume
local co_status  = coroutine.status

-- Generic array removal (avoids table.remove type inference issues)
--: ({ [integer]: any }, integer) -> nil
local function arr_remove(t, i)
  for k = i, #t - 1 do t[k] = t[k + 1] end
  t[#t] = nil
end

-- ---------------------------------------------------------------------------
-- Type aliases
-- ---------------------------------------------------------------------------

--:: AQDoneCb = (string | nil, any) -> nil
--:: AQTask = { fn: (AQDoneCb) -> nil, priority: integer, id: any, data: any, seq: integer, retries_left: integer, cancelled: boolean, retry_after: number | nil }
--:: AQState = { task: AQTask, started_at: number, done: boolean, err: string | nil, result: any, co: Thread | nil }
--:: AQStats = { pending: integer, active: integer, completed: integer, failed: integer, retried: integer }
--:: AQListeners = { [string]: { [integer]: any } }
--:: AQObj = { _concurrency: integer, _rate: number | nil, _retry: integer, _retry_delay: number, _timeout: number | nil, _on_error: any, _on_done: any, _clock_fn: () -> number, _pending: { [integer]: AQTask }, _active: { [integer]: AQState }, _paused: boolean, _seq: integer, _rate_window: number | nil, _rate_count: integer, _stats: AQStats, _listeners: AQListeners }

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Insert into sorted pending list (stable, by priority asc then insertion order)
--: ({ [integer]: AQTask }, AQTask) -> nil
local function pq_insert(list, item)
  -- Simple insertion into sorted array by (priority, seq)
  local n = #list
  local i = n + 1
  while i > 1 and (list[i - 1].priority > item.priority or
      (list[i - 1].priority == item.priority and list[i - 1].seq > item.seq)) do
    list[i] = list[i - 1]
    i = i - 1
  end
  list[i] = item
end

-- ---------------------------------------------------------------------------
-- Queue
-- ---------------------------------------------------------------------------

local Queue = {}
Queue.__index = Queue

--- Create a new async queue.
-- opts.concurrency  (int, default 1)    — max concurrent workers
-- opts.rate         (number, nil)       — max tasks per second
-- opts.retry        (int, default 0)    — retry count on failure
-- opts.retry_delay  (number, default 0) — seconds between retries
-- opts.timeout      (number, nil)       — per-task timeout in seconds
-- opts.on_error     (fn(task, err))     — global error callback
-- opts.on_done      (fn(task, result))  — global done callback
function M.new(opts)
  local opts_ = (opts or {}) --[[:! { concurrency: integer | nil, rate: number | nil, retry: integer | nil, retry_delay: number | nil, timeout: number | nil, on_error: any, on_done: any, clock_fn: (() -> number) | nil }]]
  if not opts_.clock_fn then error("async_queue.new: opts.clock_fn is required") end
  local clock_fn = opts_.clock_fn --[[:! () -> number]]
  local q = setmetatable({
    _concurrency  = opts_.concurrency  or 1,
    _rate         = opts_.rate,
    _retry        = opts_.retry        or 0,
    _retry_delay  = opts_.retry_delay  or 0,
    _timeout      = opts_.timeout,
    _on_error     = opts_.on_error,
    _on_done      = opts_.on_done,
    _clock_fn     = clock_fn,

    _pending      = {},  -- sorted array of task specs
    _active       = {},  -- array of running task states
    _paused       = false,
    _seq          = 0,

    -- rate limiter state
    _rate_window  = nil,
    _rate_count   = 0,

    -- stats
    _stats = { pending = 0, active = 0, completed = 0, failed = 0, retried = 0 },

    -- event listeners: "done" | "error" | "drain"
    _listeners = {},
  }, Queue) --[[: any]] --[[:! AQObj]]
  return q
end

--- Register an event listener.
-- event: "done" | "error" | "drain"
function Queue:on(event, fn)
  local self_ = self --[[:! AQObj]]
  if not self_._listeners[event] then
    self_._listeners[event] = {}
  end
  local list = self_._listeners[event]
  list[#list + 1] = fn
end

local function emit(q, event, ...)
  local list = q._listeners[event]
  if list then
    for i = 1, #list do
      list[i](...)
    end
  end
end

--- Add a task to the queue.
-- fn_or_spec may be:
--   function(done) ... done(err, result) end
--   { fn=fn, priority=N, id="...", data={...} }
function Queue:push(fn_or_spec)
  local self_ = self --[[:! AQObj]]
  local spec
  if type(fn_or_spec) == "function" then
    spec = { fn = fn_or_spec } --[[:! { fn: (AQDoneCb) -> nil, priority: integer | nil, id: any, data: any }]]
  else
    spec = fn_or_spec --[[:! { fn: (AQDoneCb) -> nil, priority: integer | nil, id: any, data: any }]]
  end
  self_._seq = self_._seq + 1
  local task = {
    fn           = spec.fn,
    priority     = spec.priority or 10,
    id           = spec.id,
    data         = spec.data,
    seq          = self_._seq,
    retries_left = self_._retry,
    cancelled    = false,
    retry_after  = nil --[[:! number | nil]],
  } --[[: any]] --[[:! AQTask]]
  pq_insert(self_._pending, task)
  self_._stats.pending = self_._stats.pending + 1
  return task
end

--- Pause the queue. No new tasks will be started until resume().
function Queue:pause()
  local self_ = self --[[:! AQObj]]
  self_._paused = true
end

--- Resume the queue.
function Queue:resume()
  local self_ = self --[[:! AQObj]]
  self_._paused = false
end

--- Cancel a task by id. If it is pending it will be skipped; active tasks
--- are marked cancelled but may still run to completion in this tick.
function Queue:cancel(id)
  local self_ = self --[[:! AQObj]]
  -- Mark pending tasks
  for i = 1, #self_._pending do
    if self_._pending[i].id == id then
      self_._pending[i].cancelled = true
    end
  end
  -- Mark active tasks
  for i = 1, #self_._active do
    if self_._active[i].task.id == id then
      self_._active[i].task.cancelled = true
    end
  end
end

--- Cancel all pending tasks.
function Queue:cancel_all()
  local self_ = self --[[:! AQObj]]
  for i = 1, #self_._pending do
    self_._pending[i].cancelled = true
  end
end

--- Remove all pending tasks (does not affect active ones).
function Queue:clear()
  local self_ = self --[[:! AQObj]]
  local removed = #self_._pending
  self_._pending = {}
  self_._stats.pending = math.max(0, self_._stats.pending - removed)
end

--- Return current statistics.
function Queue:stats()
  local self_ = self --[[:! AQObj]]
  local s = self_._stats
  return {
    pending   = s.pending,
    active    = s.active,
    completed = s.completed,
    failed    = s.failed,
    retried   = s.retried,
  }
end

-- Check rate limit: returns true if we can start a new task now.
--: (AQObj, number | nil) -> boolean
local function rate_ok(q, clock)
  local rate = q._rate
  if not rate then return true end
  local now = clock or q._clock_fn()
  local rw = q._rate_window
  if not rw then
    q._rate_window = now
    q._rate_count  = 0
  elseif now - (rw --[[:! number]]) >= 1.0 then
    q._rate_window = now
    q._rate_count  = 0
  end
  local rate_ = rate --[[:! number]]
  if q._rate_count < rate_ then
    return true
  end
  return false
end

--: (AQObj) -> nil
local function rate_consume(q)
  if q._rate then
    q._rate_count = q._rate_count + 1
  end
end

-- Complete a task (success or final failure).
--: (AQObj, AQState, string | nil, any) -> nil
local function finish_task(q, state, err, result)
  local task = state.task
  -- Remove from active list
  for i = 1, #q._active do
    if q._active[i] == state then
      arr_remove(q._active, i)
      break
    end
  end
  q._stats.active  = math.max(0, q._stats.active - 1)

  if err then
    q._stats.failed = q._stats.failed + 1
    if q._on_error then q._on_error(task, err) end
    emit(q, "error", task, err)
  else
    q._stats.completed = q._stats.completed + 1
    if q._on_done then q._on_done(task, result) end
    emit(q, "done", task, result)
  end
end

-- Reschedule a task for retry.
--: (AQObj, AQTask, number | nil) -> nil
local function reschedule_retry(q, task, clock)
  task.retries_left = task.retries_left - 1
  q._stats.retried  = q._stats.retried + 1
  task.retry_after  = (clock or q._clock_fn()) + q._retry_delay
  -- Re-insert at front of its priority group (same seq = runs before new tasks)
  pq_insert(q._pending, task)
  q._stats.pending = q._stats.pending + 1
end

-- Start one task, returning a state table.
--: (AQObj, AQTask, number | nil) -> AQState
local function start_task(q, task, clock)
  local state = {
    task       = task,
    started_at = clock or q._clock_fn(),
    done       = false,
    err        = nil,
    result     = nil,
    co         = nil,
  } --[[: any]] --[[:! AQState]]

  -- The task function calls done(err, result) when finished.
  local function done_cb(err, result)
    state.done   = true
    state.err    = err --[[:! string | nil]]
    state.result = result
  end

  -- Run in a coroutine so tasks may yield (though in pure Lua tick they run
  -- to completion synchronously unless they yield themselves).
  local co = co_create(function()
    task.fn(done_cb)
  end) --[[:! Thread]]
  state.co = co

  q._stats.active  = q._stats.active + 1
  q._active[#q._active + 1] = state

  local ok, co_err = co_resume(co)
  if not ok then
    -- Coroutine errored — treat as task error.
    state.done = true
    state.err  = tostring(co_err)
  end

  return state
end

--- Advance the scheduler by one tick.
-- clock: optional current time (os.clock() value). Defaults to os.clock().
-- Returns (active_count, pending_count).
function Queue:tick(clock)
  local self_ = self --[[:! AQObj]]
  local clock_ = clock or self_._clock_fn() --: number

  -- 1. Continue any active coroutines that have not finished yet.
  local i = 1
  while i <= #self_._active do
    local state = self_._active[i]
    local task  = state.task

    -- Check timeout
    if self_._timeout and not state.done then
      if clock_ - state.started_at >= self_._timeout then
        state.done = true
        state.err  = "timeout"
      end
    end

    -- Resume coroutine if still running and not done yet.
    local sco = state.co --[[:! Thread]]
    if not state.done and co_status(sco) == "suspended" then
      local ok, co_err = co_resume(sco)
      if not ok then
        state.done = true
        state.err  = tostring(co_err)
      end
    end

    if state.done then
      local err    = state.err
      local result = state.result

      if err and task.retries_left > 0 then
        -- Remove from active first
        arr_remove(self_._active, i)
        self_._stats.active = math.max(0, self_._stats.active - 1)
        reschedule_retry(self_, task, clock_)
        -- don't advance i, next element shifted down
      else
        finish_task(self_, state, err, result)
        -- don't advance i
      end
    else
      i = i + 1
    end
  end

  -- 2. Start new tasks if capacity allows and queue is not paused.
  if not self_._paused then
    -- Remove cancelled pending tasks first
    local j = 1
    while j <= #self_._pending do
      local task = self_._pending[j]
      if task.cancelled then
        arr_remove(self_._pending, j)
        self_._stats.pending = math.max(0, self_._stats.pending - 1)
      else
        j = j + 1
      end
    end

    while #self_._active < self_._concurrency
        and #self_._pending > 0
        and rate_ok(self_, clock_) do
      local task = self_._pending[1]

      -- Skip tasks whose retry_after hasn't elapsed yet.
      if task.retry_after and clock_ < task.retry_after then
        break
      end

      arr_remove(self_._pending, 1)
      self_._stats.pending = math.max(0, self_._stats.pending - 1)

      rate_consume(self_)
      start_task(self_, task, clock_)
    end
  end

  -- 3. Emit drain if both queues are empty.
  if #self_._active == 0 and #self_._pending == 0 then
    emit(self_, "drain")
  end

  return #self_._active, #self_._pending
end

--- Drive tick() until all tasks are complete.
-- Uses os.clock() for time advancement. Advances clock by retry_delay
-- as needed so retries eventually run.
function Queue:run_all()
  local self_ = self --[[:! AQObj]]
  local clock = self_._clock_fn()
  local max_iterations = 100000  -- safety guard
  local iter = 0
  while iter < max_iterations do
    iter = iter + 1
    local active, pending = Queue.tick(self_, clock)
    if active == 0 and pending == 0 then break end

    -- If there are pending tasks with retry_after in the future, advance clock.
    local min_retry = math.huge
    for _, task in ipairs(self_._pending) do
      local ra = task.retry_after
      if ra then
        local ra_ = ra --[[:! number]]
        if ra_ > clock and ra_ < min_retry then
          min_retry = ra_
        end
      end
    end
    if min_retry < math.huge then
      clock = min_retry
    else
      -- Advance clock slightly to avoid infinite loop on timeout tasks
      clock = clock + 0.001
    end
  end
end

--- Wait until the queue is empty (synchronous; equivalent to run_all for pure Lua).
function Queue:drain()
  self:run_all()
end

-- ---------------------------------------------------------------------------
-- Batcher
-- ---------------------------------------------------------------------------

--:: BatcherObj = { _key: any, _batch_size: integer, _delay: number, _process: any, _clock_fn: () -> number, _buckets: { [string]: { [integer]: any } }, _bucket_order: { [integer]: string }, _first_at: { [string]: number } }

local Batcher = {}
Batcher.__index = Batcher

--- Create a new batcher.
-- opts.key         (fn(item)->key)     — dedup/grouping key; nil = all in one batch
-- opts.batch_size  (int, default 100)  — max items per batch
-- opts.delay       (number, default 0) — seconds to wait before flushing
-- opts.process     (fn(batch, done))   — process a batch of items
function M.batcher(opts)
  local opts_ = (opts or {}) --[[:! { key: any, batch_size: integer | nil, delay: number | nil, process: any, clock_fn: (() -> number) | nil }]]
  if not opts_.clock_fn then error("async_queue.batcher: opts.clock_fn is required") end
  local b = setmetatable({
    _key        = opts_.key,
    _batch_size = opts_.batch_size or 100,
    _delay      = opts_.delay or 0,
    _process    = opts_.process,
    _clock_fn   = opts_.clock_fn --[[:! () -> number]],
    _buckets    = {},
    _bucket_order = {},
    _first_at   = {},
  }, Batcher) --[[: any]] --[[:! BatcherObj]]
  return b
end

--- Add an item to the batcher.
-- clock: optional current time (os.clock() value). Used to record when the
-- first item in a bucket arrived, so flush(clock) can respect the delay.
function Batcher:push(item, clock)
  local self_ = self --[[:! BatcherObj]]
  local key = self_._key and self_._key(item) or "__default__"
  local key_ = key --[[:! string]]
  if not self_._buckets[key_] then
    self_._buckets[key_] = {}
    self_._bucket_order[#self_._bucket_order + 1] = key_
    self_._first_at[key_] = clock or self_._clock_fn()
  end
  local bucket = self_._buckets[key_]
  bucket[#bucket + 1] = item

  -- Auto-flush if batch_size reached
  if #bucket >= self_._batch_size then
    Batcher._flush_key(self_, key_)
  end
end

--- Flush a specific key bucket.
function Batcher:_flush_key(key)
  local self_ = self --[[:! BatcherObj]]
  local bucket = self_._buckets[key]
  if not bucket or #bucket == 0 then return end

  local batch = bucket
  self_._buckets[key] = nil
  self_._first_at[key] = nil

  -- Remove from order list
  for i = 1, #self_._bucket_order do
    if self_._bucket_order[i] == key then
      arr_remove(self_._bucket_order, i)
      break
    end
  end

  if self_._process then
    self_._process(batch, function(err, result)
    end)
  end
end

--- Flush all pending items, respecting delay.
-- clock: optional current time. Buckets whose delay has elapsed are flushed.
function Batcher:flush(clock)
  local self_ = self --[[:! BatcherObj]]
  local clock_ = clock or self_._clock_fn() --: number
  local keys_to_flush = {} --: { [integer]: string }
  for _, key in ipairs(self_._bucket_order) do
    local first = self_._first_at[key]
    if first and (clock_ - first) >= self_._delay then
      keys_to_flush[#keys_to_flush + 1] = key
    end
  end
  for _, key in ipairs(keys_to_flush) do
    Batcher._flush_key(self_, key)
  end
end

--- Flush all pending items immediately regardless of delay.
function Batcher:flush_all()
  local self_ = self --[[:! BatcherObj]]
  local keys = {} --: { [integer]: string }
  for _, key in ipairs(self_._bucket_order) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    Batcher._flush_key(self_, key)
  end
end

return M
