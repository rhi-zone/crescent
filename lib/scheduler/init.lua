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
  local last_ = table.remove(heap)
  local last = last_ --[[:! HeapEntry]]
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
function Sched:spawn(fn, opts)
  local self_ = self --[[:! SchedObj]]
  opts = opts or {}
  self_._seq = self_._seq + 1
  local task = setmetatable({
    name      = opts.name or ("task" .. self_._seq),
    priority  = opts.priority or 0,
    seq       = self_._seq,
    status    = "pending",
    error     = nil,
    _sched    = self_,
    _co       = nil,
    _cancelled = false,
  }, Task) --[[: any]]
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
        ready_insert(self_._ready, waiter)
      end
    end
    ch_._waiters = {}
    -- Yield once to let waiters run before we continue
    co_yield("yield")
  end

  local co = co_create(function()
    fn(ctx)
  end)
  task_._co = co
  self_._all_tasks[#self_._all_tasks + 1] = task_
  ready_insert(self_._ready, task_)
  return task_
end

-- Spawn a task that runs fn once after delay_seconds.
function Sched:after(delay_seconds, fn, opts)
  local self_ = self --[[:! SchedObj]]
  return self_:spawn(function(ctx)
    ctx.sleep(delay_seconds)
    fn(ctx)
  end, opts)
end

-- Spawn a task that runs fn every interval_seconds.
-- fn may return false to cancel itself.
function Sched:every(interval_seconds, fn, opts)
  local self_ = self --[[:! SchedObj]]
  return self_:spawn(function(ctx)
    while true do
      ctx.sleep(interval_seconds)
      local result = fn(ctx)
      if result == false then break end
    end
  end, opts)
end

-- Register a hook called when a task completes successfully.
function Sched:on_task_done(fn)
  local self_ = self --[[:! SchedObj]]
  self_._done_hook = fn
end

-- Register a hook called when a task fails.
function Sched:on_task_failed(fn)
  local self_ = self --[[:! SchedObj]]
  self_._failed_hook = fn
end

-- Cancel a task: mark it and remove from ready queue if present.
function Sched:cancel(task)
  local self_ = self --[[:! SchedObj]]
  if task.status == "done" or task.status == "failed" then return end
  task._cancelled = true
  task.status = "done"  -- treat as done so done() can return true
  -- Remove from ready queue
  local ready_any = self_._ready --[[: any]]
  for i = 1, #self_._ready do
    if self_._ready[i] == task then
      table.remove(ready_any, i)
      break
    end
  end
  -- Note: sleeping tasks will be skipped in step() when they wake.
end

-- Run one scheduling step.
function Sched:step()
  local self_ = self --[[:! SchedObj]]
  self_._steps = self_._steps + 1
  local now = self_._clock()

  -- Move sleeping tasks whose wake time has passed to ready queue.
  while true do
    local top_ = heap_peek(self_._sleeping)
    if not top_ then break end
    local top = top_ --[[:! HeapEntry]]
    if top.wake_time > now then break end
    heap_pop(self_._sleeping)
    local task = top.task
    if not task._cancelled and task.status == "sleeping" then
      task.status = "pending"
      ready_insert(self_._ready, task)
    end
  end

  -- Run each ready task once.
  -- Take a snapshot of the tasks that are ready right now. Any tasks that yield
  -- or get woken (channels) during this step are inserted into self_._ready and
  -- will run in the NEXT step. We process only the snapshot tasks in this step.
  local snapshot = self_._ready
  self_._ready = {}
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
        local failed_hook_ = self_._failed_hook
        if failed_hook_ then (failed_hook_ --[[:! (Task, string | nil) -> unknown]])(task, task.error) end
      elseif co_status(co_) == "dead" then
        -- Coroutine finished normally
        task.status = "done"
        local done_hook_ = self_._done_hook
        if done_hook_ then (done_hook_ --[[:! (Task) -> unknown]])(task) end
      else
        -- Coroutine yielded — interpret the yield signal
        local signal = a  -- "yield" | "sleep" | "await"
        if signal == "sleep" then
          local seconds = (b or 0) --[[:! number]]
          task.status    = "sleeping"
          local entry    = { wake_time = now + seconds, task = task }
          heap_push(self_._sleeping, entry)
        elseif signal == "await" then
          task.status = "waiting"
          -- task is already registered in ch._waiters by ctx.await
        else
          -- "yield" or unknown: re-queue for next step
          -- Update seq so this task goes after others with the same priority
          -- that are already in the queue (round-robin fairness).
          self_._seq = self_._seq + 1
          task.seq  = self_._seq
          task.status = "pending"
          ready_insert(self_._ready, task)
        end
      end
    end
  end
end

-- Run until all tasks are done or failed.
-- Safety limit: max_steps (default 1,000,000).
function Sched:run(max_steps)
  local self_ = self --[[:! SchedObj]]
  max_steps = max_steps or 1000000
  local i = 0
  while i < max_steps and not self_:done() do
    self_:step()
    i = i + 1
    -- If nothing is ready and nothing is sleeping but we're not done, break.
    if #self_._ready == 0 and #self_._sleeping == 0 then break end
  end
end

-- Run at most n_steps steps.
function Sched:run_for(n_steps)
  local self_ = self --[[:! SchedObj]]
  for _ = 1, n_steps do
    if self_:done() then break end
    self_:step()
  end
end

-- Number of active tasks (not done/failed).
function Sched:task_count()
  local self_ = self --[[:! SchedObj]]
  local n = 0
  for i = 1, #self_._all_tasks do
    local t = self_._all_tasks[i]
    if t.status ~= "done" and t.status ~= "failed" and not t._cancelled then
      n = n + 1
    end
  end
  return n
end

-- True when all tasks are done or failed.
function Sched:done()
  local self_ = self --[[:! SchedObj]]
  for i = 1, #self_._all_tasks do
    local t = self_._all_tasks[i]
    if t.status ~= "done" and t.status ~= "failed" then
      return false
    end
  end
  return true
end

-- Statistics snapshot.
function Sched:stats()
  local self_ = self --[[:! SchedObj]]
  local total, done, failed, pending = 0, 0, 0, 0
  for i = 1, #self_._all_tasks do
    local t = self_._all_tasks[i]
    total = total + 1
    if t.status == "done" or t._cancelled then
      done = done + 1
    elseif t.status == "failed" then
      failed = failed + 1
    else
      pending = pending + 1
    end
  end
  return { total = total, done = done, failed = failed, pending = pending, steps = self_._steps }
end

return M
