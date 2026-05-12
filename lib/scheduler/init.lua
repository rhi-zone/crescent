-- lib/scheduler/init.lua
-- Cooperative coroutine-based task scheduler with priorities, timers, and channels.
-- Tasks yield explicitly; no preemption. Coroutine-per-task model.
--
-- Scheduling within a step:
--   1. Advance virtual time via clock()
--   2. Move sleeping tasks whose wake_time has passed to the ready queue
--   3. Run each ready task once (resume until it yields)
--   4. Errors → mark failed, call on_task_failed hook
--   5. Coroutine dead → mark done, call on_task_done hook

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

--: string
M._tier = "pure"

--:: Task = { name: string, priority: number, seq: integer, status: string, error: string | nil, _sched: unknown, _co: Thread | nil, _cancelled: boolean, _wake_val: unknown }
--:: Channel = { _value: unknown, _has: boolean, _waiters: { [integer]: Task } }
--:: HeapEntry = { wake_time: number, task: Task }
--:: SchedObj = { _clock: () -> number, _ready: { [integer]: Task }, _sleeping: { [integer]: HeapEntry }, _all_tasks: { [integer]: Task }, _steps: integer, _done_hook: ((Task) -> unknown) | nil, _failed_hook: ((Task, string | nil) -> unknown) | nil, _seq: integer, spawn: (SchedObj, unknown, unknown) -> Task, step: (SchedObj) -> nil, done: (SchedObj) -> boolean }

local co_create  = coroutine.create
local co_resume  = coroutine.resume
local co_status  = coroutine.status
local co_yield   = coroutine.yield

-- ---------------------------------------------------------------------------
-- Min-heap for the timer queue (keyed by wake_time)
-- ---------------------------------------------------------------------------

--: ({ [integer]: HeapEntry }, HeapEntry) -> nil
local function heap_push(heap, item)
  heap[#heap + 1] = item
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].wake_time <= heap[i].wake_time then break end
    heap[parent], heap[i] = heap[i], heap[parent]
    i = parent
  end
end

--: ({ [integer]: HeapEntry }) -> HeapEntry | nil
local function heap_pop(heap)
  if #heap == 0 then return nil end
  local top = heap[1]
  local last = table.remove(heap)
  if not last then return top end
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local left  = i * 2
      local right = i * 2 + 1
      local smallest = i
      if left  <= #heap and heap[left].wake_time  < heap[smallest].wake_time then smallest = left  end
      if right <= #heap and heap[right].wake_time < heap[smallest].wake_time then smallest = right end
      if smallest == i then break end
      heap[i], heap[smallest] = heap[smallest], heap[i]
      i = smallest
    end
  end
  return top
end

--: ({ [integer]: HeapEntry }) -> HeapEntry | nil
local function heap_peek(heap)
  return heap[1]
end

-- ---------------------------------------------------------------------------
-- Channel
-- ---------------------------------------------------------------------------

local Channel = {}
Channel.__index = Channel

-- Create a new channel. Channels buffer one value and wake all waiters on send.
function M.channel()
  return setmetatable({
    _value    = nil,
    _has      = false,
    _waiters  = {},   -- list of tasks waiting on this channel
  }, Channel)
end

-- Non-blocking peek: returns current value or nil (does not consume).
function Channel:peek()
  return self._value
end

-- Whether the channel currently holds a value.
function Channel:has_value()
  return self._has
end

-- ---------------------------------------------------------------------------
-- Task
-- ---------------------------------------------------------------------------

local Task = {}
Task.__index = Task

-- ---------------------------------------------------------------------------
-- Scheduler
-- ---------------------------------------------------------------------------

local Sched = {}
Sched.__index = Sched

-- Create a new scheduler.
-- opts.clock_fn — injectable clock function (required)
function M.new(opts)
  opts = opts or {}
  local s = setmetatable({
    _clock         = opts.clock_fn or error("scheduler.new: opts.clock_fn is required"),
    _ready         = {},  -- array of tasks ready to run, sorted by priority desc
    _sleeping      = {},  -- min-heap of {wake_time, task}
    _all_tasks     = {},  -- all tasks ever spawned
    _steps         = 0,
    _done_hook     = nil,
    _failed_hook   = nil,
    _seq           = 0,   -- monotonic insertion counter for stable sort
  }, Sched)
  return s
end

-- Insert a task into the ready queue, maintaining descending priority order.
-- Higher priority number = runs first.
--: ({ [integer]: Task }, Task) -> nil
local function ready_insert(ready, task)
  local n = #ready
  local i = n + 1
  while i > 1 do
    local prev = ready[i - 1]
    -- Higher priority first; ties broken by seq (earlier = first)
    if prev.priority > task.priority or
       (prev.priority == task.priority and prev.seq <= task.seq) then
      break
    end
    ready[i] = ready[i - 1]
    i = i - 1
  end
  ready[i] = task
end

-- Spawn a new coroutine task.
-- fn(ctx) — the task body; ctx provides yield/sleep/await/send
-- opts.priority (number, default 0), opts.name (string)
--: (SchedObj, unknown, { name: string | nil, priority: number | nil, ... } | nil) -> Task
function Sched:spawn(fn, opts)
  self._seq = self._seq + 1
  local task = setmetatable({
    name      = opts and opts.name or ("task" .. self._seq),
    priority  = opts and opts.priority or 0,
    seq       = self._seq,
    status    = "pending",
    error     = nil,
    _sched    = self,
    _co       = nil,
    _cancelled = false,
  }, Task) --[[: unknown]]
  local task_ = task --[[:! Task]]

  -- Build the ctx table (closed over the task and scheduler).
  local ctx = {}

  -- Yield to scheduler; task will be re-queued for next step.
  ctx.yield = function()
    co_yield("yield")
  end

  -- Sleep for at least `seconds`; task re-queued when time passes.
  ctx.sleep = function(seconds)
    co_yield("sleep", seconds)
  end

  -- Block until channel has a value; returns that value.
  ctx.await = function(ch)
    local ch_ = ch --[[:! Channel]]
    -- If channel already has a value, return immediately.
    if ch_._has then
      return ch_._value
    end
    ch_._waiters[#ch_._waiters + 1] = task_
    local val = co_yield("await", ch_)
    return val
  end

  -- Send value to channel; wake all waiters and yield once to let them run.
  ctx.send = function(ch, val)
    local ch_ = ch --[[:! Channel]]
    ch_._value = val
    ch_._has   = true
    -- Move all waiters to the ready queue
    for i = 1, #ch_._waiters do
      local waiter = ch_._waiters[i]
      if not waiter._cancelled and waiter.status == "waiting" then
        waiter.status    = "pending"
        waiter._wake_val = val
        ready_insert(self._ready, waiter)
      end
    end
    ch_._waiters = {}
    -- Yield once to let waiters run before we continue
    co_yield("yield")
  end

  local fn_ = fn --[[:! (unknown) -> unknown]]
  local co = (co_create(function()
    fn_(ctx)
  end) --[[: unknown]]) --[[:! Thread]]
  task_._co = co
  self._all_tasks[#self._all_tasks + 1] = task_
  ready_insert(self._ready, task_)
  return task_
end

-- Spawn a task that runs fn once after delay_seconds.
function Sched:after(delay_seconds, fn, opts)
  return self:spawn(function(ctx)
    ctx.sleep(delay_seconds)
    fn(ctx)
  end, opts)
end

-- Spawn a task that runs fn every interval_seconds.
-- fn may return false to cancel itself.
function Sched:every(interval_seconds, fn, opts)
  return self:spawn(function(ctx)
    while true do
      ctx.sleep(interval_seconds)
      local result = fn(ctx)
      if result == false then break end
    end
  end, opts)
end

-- Register a hook called when a task completes successfully.
--: (SchedObj, (Task) -> unknown) -> nil
function Sched:on_task_done(fn)
  self._done_hook = fn
end

-- Register a hook called when a task fails.
--: (SchedObj, (Task, string | nil) -> unknown) -> nil
function Sched:on_task_failed(fn)
  self._failed_hook = fn
end

-- Cancel a task: mark it and remove from ready queue if present.
--: (SchedObj, Task) -> nil
function Sched:cancel(task)
  if task.status == "done" or task.status == "failed" then return end
  task._cancelled = true
  task.status = "done"  -- treat as done so done() can return true
  -- Remove from ready queue
  for i = 1, #self._ready do
    if self._ready[i] == task then
      local n = #self._ready
      for j = i, n - 1 do self._ready[j] = self._ready[j + 1] end
      self._ready[n] = ((nil --[[: unknown]]) --[[:! { task: unknown, wake_time: number }]])
      break
    end
  end
  -- Note: sleeping tasks will be skipped in step() when they wake.
end

-- Run one scheduling step.
--: (SchedObj) -> nil
function Sched:step()
  self._steps = self._steps + 1
  local now = self._clock()

  -- Move sleeping tasks whose wake time has passed to ready queue.
  while true do
    local top_ = heap_peek(self._sleeping)
    if not top_ then break end
    local top = top_ --[[:! HeapEntry]]
    if top.wake_time > now then break end
    heap_pop(self._sleeping)
    local task = top.task
    if not task._cancelled and task.status == "sleeping" then
      task.status = "pending"
      ready_insert(self._ready, task)
    end
  end

  -- Run each ready task once.
  -- Take a snapshot of the tasks that are ready right now. Any tasks that yield
  -- or get woken (channels) during this step are inserted into self._ready and
  -- will run in the NEXT step. We process only the snapshot tasks in this step.
  local snapshot = self._ready
  self._ready = {}
  for _, task in ipairs(snapshot) do
    if task._cancelled or task.status == "done" or task.status == "failed" then
      -- skip
    else
      task.status = "running"
      local resume_val = task._wake_val
      task._wake_val = nil

      local co_ = task._co --[[:! Thread]]
      local ok, a, b = co_resume(co_, resume_val)

      if not ok then
        -- Coroutine errored
        task.status = "failed"
        task.error  = tostring(a)
        local failed_hook_ = self._failed_hook
        if failed_hook_ then (failed_hook_ --[[:! (Task, string | nil) -> unknown]])(task, task.error) end
      elseif co_status(co_) == "dead" then
        -- Coroutine finished normally
        task.status = "done"
        local done_hook_ = self._done_hook
        if done_hook_ then (done_hook_ --[[:! (Task) -> unknown]])(task) end
      else
        -- Coroutine yielded — interpret the yield signal
        local signal = a  -- "yield" | "sleep" | "await"
        if signal == "sleep" then
          local seconds = (b or 0) --[[:! number]]
          task.status    = "sleeping"
          local entry    = { wake_time = now + seconds, task = task }
          heap_push(self._sleeping, entry)
        elseif signal == "await" then
          task.status = "waiting"
          -- task is already registered in ch._waiters by ctx.await
        else
          -- "yield" or unknown: re-queue for next step
          -- Update seq so this task goes after others with the same priority
          -- that are already in the queue (round-robin fairness).
          self._seq = self._seq + 1
          task.seq  = self._seq
          task.status = "pending"
          ready_insert(self._ready, task)
        end
      end
    end
  end
end

-- Run until all tasks are done or failed.
-- Safety limit: max_steps (default 1,000,000).
--: (SchedObj, integer | nil) -> nil
function Sched:run(max_steps)
  max_steps = max_steps or 1000000
  local i = 0
  while i < max_steps and not self:done() do
    self:step()
    i = i + 1
    -- If nothing is ready and nothing is sleeping but we're not done, break.
    if #self._ready == 0 and #self._sleeping == 0 then break end
  end
end

-- Run at most n_steps steps.
--: (SchedObj, integer) -> nil
function Sched:run_for(n_steps)
  for _ = 1, n_steps do
    if self:done() then break end
    self:step()
  end
end

-- Number of active tasks (not done/failed).
--: (SchedObj) -> integer
function Sched:task_count()
  local n = 0
  for i = 1, #self._all_tasks do
    local t = self._all_tasks[i]
    if t.status ~= "done" and t.status ~= "failed" and not t._cancelled then
      n = n + 1
    end
  end
  return n
end

-- True when all tasks are done or failed.
--: (SchedObj) -> boolean
function Sched:done()
  for i = 1, #self._all_tasks do
    local t = self._all_tasks[i]
    if t.status ~= "done" and t.status ~= "failed" then
      return false
    end
  end
  return true
end

-- Statistics snapshot.
--: (SchedObj) -> { total: integer, done: integer, failed: integer, pending: integer, steps: integer }
function Sched:stats()
  local total, done, failed, pending = 0, 0, 0, 0
  for i = 1, #self._all_tasks do
    local t = self._all_tasks[i]
    total = total + 1
    if t.status == "done" or t._cancelled then
      done = done + 1
    elseif t.status == "failed" then
      failed = failed + 1
    else
      pending = pending + 1
    end
  end
  return { total = total, done = done, failed = failed, pending = pending, steps = self._steps }
end

return M
