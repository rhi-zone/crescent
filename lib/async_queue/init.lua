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
local os_clock   = os.clock

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Insert into sorted pending list (stable, by priority asc then insertion order)
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
  opts = opts or {}
  local q = setmetatable({
    _concurrency  = opts.concurrency  or 1,
    _rate         = opts.rate,          -- tasks/sec, nil = unlimited
    _retry        = opts.retry        or 0,
    _retry_delay  = opts.retry_delay  or 0,
    _timeout      = opts.timeout,
    _on_error     = opts.on_error,
    _on_done      = opts.on_done,

    _pending      = {},  -- sorted array of task specs
    _active       = {},  -- array of running task states
    _paused       = false,
    _seq          = 0,   -- monotonic counter for FIFO within same priority

    -- rate limiter state
    _rate_window  = nil,  -- start of current second window
    _rate_count   = 0,    -- tasks started in current window

    -- stats
    _stats = { pending = 0, active = 0, completed = 0, failed = 0, retried = 0 },

    -- event listeners: "done" | "error" | "drain"
    _listeners = {},
  }, Queue)
  return q
end

--- Register an event listener.
-- event: "done" | "error" | "drain"
function Queue:on(event, fn)
  if not self._listeners[event] then
    self._listeners[event] = {}
  end
  local list = self._listeners[event]
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
  local spec
  if type(fn_or_spec) == "function" then
    spec = { fn = fn_or_spec }
  else
    spec = fn_or_spec
  end
  self._seq = self._seq + 1
  local task = {
    fn           = spec.fn,
    priority     = spec.priority or 10,
    id           = spec.id,
    data         = spec.data,
    seq          = self._seq,
    retries_left = self._retry,
    cancelled    = false,
  }
  pq_insert(self._pending, task)
  self._stats.pending = self._stats.pending + 1
  return task
end

--- Pause the queue. No new tasks will be started until resume().
function Queue:pause()
  self._paused = true
end

--- Resume the queue.
function Queue:resume()
  self._paused = false
end

--- Cancel a task by id. If it is pending it will be skipped; active tasks
--- are marked cancelled but may still run to completion in this tick.
function Queue:cancel(id)
  -- Mark pending tasks
  for i = 1, #self._pending do
    if self._pending[i].id == id then
      self._pending[i].cancelled = true
    end
  end
  -- Mark active tasks
  for i = 1, #self._active do
    if self._active[i].task.id == id then
      self._active[i].task.cancelled = true
    end
  end
end

--- Cancel all pending tasks.
function Queue:cancel_all()
  for i = 1, #self._pending do
    self._pending[i].cancelled = true
  end
end

--- Remove all pending tasks (does not affect active ones).
function Queue:clear()
  local removed = #self._pending
  self._pending = {}
  self._stats.pending = math.max(0, self._stats.pending - removed)
end

--- Return current statistics.
function Queue:stats()
  local s = self._stats
  return {
    pending   = s.pending,
    active    = s.active,
    completed = s.completed,
    failed    = s.failed,
    retried   = s.retried,
  }
end

-- Check rate limit: returns true if we can start a new task now.
local function rate_ok(q, clock)
  if not q._rate then return true end
  local now = clock or os_clock()
  if not q._rate_window or now - q._rate_window >= 1.0 then
    q._rate_window = now
    q._rate_count  = 0
  end
  if q._rate_count < q._rate then
    return true
  end
  return false
end

local function rate_consume(q)
  if q._rate then
    q._rate_count = q._rate_count + 1
  end
end

-- Complete a task (success or final failure).
local function finish_task(q, state, err, result)
  local task = state.task
  -- Remove from active list
  for i = 1, #q._active do
    if q._active[i] == state then
      table.remove(q._active, i)
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
local function reschedule_retry(q, task, clock)
  task.retries_left = task.retries_left - 1
  q._stats.retried  = q._stats.retried + 1
  task.retry_after  = (clock or os_clock()) + q._retry_delay
  -- Re-insert at front of its priority group (same seq = runs before new tasks)
  pq_insert(q._pending, task)
  q._stats.pending = q._stats.pending + 1
end

-- Start one task, returning a state table.
local function start_task(q, task, clock)
  local state = {
    task       = task,
    started_at = clock or os_clock(),
    done       = false,
    err        = nil,
    result     = nil,
  }

  -- The task function calls done(err, result) when finished.
  local function done_cb(err, result)
    state.done   = true
    state.err    = err
    state.result = result
  end

  -- Run in a coroutine so tasks may yield (though in pure Lua tick they run
  -- to completion synchronously unless they yield themselves).
  local co = co_create(function()
    task.fn(done_cb)
  end)
  state.co = co

  q._stats.active  = q._stats.active + 1
  q._active[#q._active + 1] = state

  local ok, err = co_resume(co)
  if not ok then
    -- Coroutine errored — treat as task error.
    state.done = true
    state.err  = tostring(err)
  end

  return state
end

--- Advance the scheduler by one tick.
-- clock: optional current time (os.clock() value). Defaults to os.clock().
-- Returns (active_count, pending_count).
function Queue:tick(clock)
  clock = clock or os_clock()

  -- 1. Continue any active coroutines that have not finished yet.
  local i = 1
  while i <= #self._active do
    local state = self._active[i]
    local task  = state.task

    -- Check timeout
    if self._timeout and not state.done then
      if clock - state.started_at >= self._timeout then
        state.done = true
        state.err  = "timeout"
      end
    end

    -- Resume coroutine if still running and not done yet.
    if not state.done and co_status(state.co) == "suspended" then
      local ok, err = co_resume(state.co)
      if not ok then
        state.done = true
        state.err  = tostring(err)
      end
    end

    if state.done then
      local err    = state.err
      local result = state.result

      if err and task.retries_left > 0 then
        -- Remove from active first
        table.remove(self._active, i)
        self._stats.active = math.max(0, self._stats.active - 1)
        reschedule_retry(self, task, clock)
        -- don't advance i, next element shifted down
      else
        finish_task(self, state, err, result)
        -- don't advance i
      end
    else
      i = i + 1
    end
  end

  -- 2. Start new tasks if capacity allows and queue is not paused.
  if not self._paused then
    -- Remove cancelled pending tasks first
    local j = 1
    while j <= #self._pending do
      local task = self._pending[j]
      if task.cancelled then
        table.remove(self._pending, j)
        self._stats.pending = math.max(0, self._stats.pending - 1)
      else
        j = j + 1
      end
    end

    while #self._active < self._concurrency
        and #self._pending > 0
        and rate_ok(self, clock) do
      local task = self._pending[1]

      -- Skip tasks whose retry_after hasn't elapsed yet.
      if task.retry_after and clock < task.retry_after then
        break
      end

      table.remove(self._pending, 1)
      self._stats.pending = math.max(0, self._stats.pending - 1)

      rate_consume(self)
      start_task(self, task, clock)
    end
  end

  -- 3. Emit drain if both queues are empty.
  if #self._active == 0 and #self._pending == 0 then
    emit(self, "drain")
  end

  return #self._active, #self._pending
end

--- Drive tick() until all tasks are complete.
-- Uses os.clock() for time advancement. Advances clock by retry_delay
-- as needed so retries eventually run.
function Queue:run_all()
  local clock = os_clock()
  local max_iterations = 100000  -- safety guard
  local iter = 0
  while iter < max_iterations do
    iter = iter + 1
    local active, pending = self:tick(clock)
    if active == 0 and pending == 0 then break end

    -- If there are pending tasks with retry_after in the future, advance clock.
    local min_retry = math.huge
    for _, task in ipairs(self._pending) do
      if task.retry_after and task.retry_after > clock then
        if task.retry_after < min_retry then
          min_retry = task.retry_after
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

local Batcher = {}
Batcher.__index = Batcher

--- Create a new batcher.
-- opts.key         (fn(item)->key)     — dedup/grouping key; nil = all in one batch
-- opts.batch_size  (int, default 100)  — max items per batch
-- opts.delay       (number, default 0) — seconds to wait before flushing
-- opts.process     (fn(batch, done))   — process a batch of items
function M.batcher(opts)
  opts = opts or {}
  local b = setmetatable({
    _key        = opts.key,
    _batch_size = opts.batch_size or 100,
    _delay      = opts.delay or 0,
    _process    = opts.process,
    _buckets    = {},  -- key -> {items}
    _bucket_order = {},  -- insertion-ordered keys
    _first_at   = {},  -- key -> clock when first item was added
  }, Batcher)
  return b
end

--- Add an item to the batcher.
-- clock: optional current time (os.clock() value). Used to record when the
-- first item in a bucket arrived, so flush(clock) can respect the delay.
function Batcher:push(item, clock)
  local key = self._key and self._key(item) or "__default__"
  if not self._buckets[key] then
    self._buckets[key] = {}
    self._bucket_order[#self._bucket_order + 1] = key
    self._first_at[key] = clock or os_clock()
  end
  local bucket = self._buckets[key]
  bucket[#bucket + 1] = item

  -- Auto-flush if batch_size reached
  if #bucket >= self._batch_size then
    self:_flush_key(key)
  end
end

--- Flush a specific key bucket.
function Batcher:_flush_key(key)
  local bucket = self._buckets[key]
  if not bucket or #bucket == 0 then return end

  local batch = bucket
  self._buckets[key] = nil
  self._first_at[key] = nil

  -- Remove from order list
  for i = 1, #self._bucket_order do
    if self._bucket_order[i] == key then
      table.remove(self._bucket_order, i)
      break
    end
  end

  if self._process then
    local done_called = false
    self._process(batch, function(err, result)
      done_called = true
    end)
  end
end

--- Flush all pending items, respecting delay.
-- clock: optional current time. Buckets whose delay has elapsed are flushed.
function Batcher:flush(clock)
  clock = clock or os_clock()
  local keys_to_flush = {}
  for _, key in ipairs(self._bucket_order) do
    local first = self._first_at[key]
    if first and (clock - first) >= self._delay then
      keys_to_flush[#keys_to_flush + 1] = key
    end
  end
  for _, key in ipairs(keys_to_flush) do
    self:_flush_key(key)
  end
end

--- Flush all pending items immediately regardless of delay.
function Batcher:flush_all()
  local keys = {}
  for _, key in ipairs(self._bucket_order) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    self:_flush_key(key)
  end
end

return M
