if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Min-heap helpers (min by key)
local function heap_push(heap, item)
  heap[#heap + 1] = item
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].key > heap[i].key or
       (heap[parent].key == heap[i].key and heap[parent].seq > heap[i].seq) then
      heap[parent], heap[i] = heap[i], heap[parent]
      i = parent
    else
      break
    end
  end
end

local function heap_pop(heap)
  if #heap == 0 then return nil end
  local top = heap[1]
  local n = #heap
  heap[1] = heap[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left = i * 2
    local right = i * 2 + 1
    local smallest = i
    if left <= n then
      if heap[left].key < heap[smallest].key or
         (heap[left].key == heap[smallest].key and heap[left].seq < heap[smallest].seq) then
        smallest = left
      end
    end
    if right <= n then
      if heap[right].key < heap[smallest].key or
         (heap[right].key == heap[smallest].key and heap[right].seq < heap[smallest].seq) then
        smallest = right
      end
    end
    if smallest == i then break end
    heap[i], heap[smallest] = heap[smallest], heap[i]
    i = smallest
  end
  return top
end

local function heap_peek(heap)
  return heap[1]
end

-- Find and remove an item by id from the heap. O(n).
local function heap_remove_id(heap, id)
  local found = nil
  for i = 1, #heap do
    if heap[i].id == id then
      found = i
      break
    end
  end
  if not found then return false end
  local n = #heap
  heap[found] = heap[n]
  heap[n] = nil
  -- Re-heapify: simplest correct approach: rebuild from scratch
  local items = {}
  for i = 1, #heap do items[i] = heap[i] end
  for i = 1, #heap do heap[i] = nil end
  for _, item in ipairs(items) do
    heap_push(heap, item)
  end
  return true
end

-- Queue constructor
function M.new(opts)
  opts = opts or {}
  local q = {
    _heap = {},         -- min-heap of pending task entries
    _active = 0,        -- count of currently "running" tasks (sync: tracks within process())
    _tick = 0,          -- internal clock
    _seq = 0,           -- monotonic sequence for FIFO within same priority
    _max_retries = opts.max_retries ~= nil and opts.max_retries or 3,
    _retry_delay = opts.retry_delay ~= nil and opts.retry_delay or 0,
    _max_concurrent = opts.max_concurrent ~= nil and opts.max_concurrent or 1,
    _listeners = {},    -- event -> list of callbacks
    _stats = { processed = 0, succeeded = 0, failed = 0, retried = 0, cancelled = 0 },
    _id_counter = 0,    -- for auto-generated ids
    _cancelled = {},    -- set of cancelled ids
  }
  return setmetatable(q, { __index = M })
end

-- Generate a unique id
local function gen_id(q)
  q._id_counter = q._id_counter + 1
  return q._id_counter
end

-- Push a task onto the queue. Returns the task id.
function M:push(task)
  if type(task) ~= "table" then
    return nil, "task must be a table"
  end
  if type(task.fn) ~= "function" then
    return nil, "task.fn must be a function"
  end
  local id = task.id ~= nil and task.id or gen_id(self)
  local priority = task.priority ~= nil and task.priority or 0
  local delay = task.delay ~= nil and task.delay or 0
  self._seq = self._seq + 1
  local entry = {
    id = id,
    fn = task.fn,
    priority = priority,
    delay = delay,
    eligible_at = self._tick + delay,
    attempts = 0,
    max_retries = task.max_retries ~= nil and task.max_retries or self._max_retries,
    retry_delay = task.retry_delay ~= nil and task.retry_delay or self._retry_delay,
    -- heap key = priority; seq breaks ties (FIFO)
    key = priority,
    seq = self._seq,
  }
  heap_push(self._heap, entry)
  return id
end

-- Emit an event to all listeners
local function emit(q, event, ...)
  local listeners = q._listeners[event]
  if not listeners then return end
  for _, cb in ipairs(listeners) do
    cb(...)
  end
end

-- Process up to n eligible tasks. Returns array of result records.
function M:process(n)
  n = n or 1
  local results = {}
  local processed = 0

  -- Collect eligible entries from the heap. Since the heap may contain
  -- ineligible tasks at the front, we need to scan for eligible ones.
  -- Build a temporary list of eligible entries, then put ineligible back.
  -- To keep O(k log m) we do a full extraction pass.
  local eligible = {}
  local ineligible = {}

  while #self._heap > 0 do
    local entry = heap_pop(self._heap)
    if self._cancelled[entry.id] then
      -- skip cancelled tasks silently
    elseif entry.eligible_at <= self._tick then
      eligible[#eligible + 1] = entry
    else
      ineligible[#ineligible + 1] = entry
    end
  end

  -- Re-push ineligible tasks
  for _, entry in ipairs(ineligible) do
    heap_push(self._heap, entry)
  end

  -- Sort eligible by (key, seq) — already extracted in order but rebuild for safety
  table.sort(eligible, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    return a.seq < b.seq
  end)

  -- Process up to n eligible tasks
  local used = 0
  for i = 1, #eligible do
    if used >= n then
      -- Put remaining eligible tasks back
      for j = i, #eligible do
        heap_push(self._heap, eligible[j])
      end
      break
    end

    local entry = eligible[i]
    used = used + 1
    self._active = self._active + 1
    entry.attempts = entry.attempts + 1

    local ok, val, err_or_second = pcall(entry.fn)

    self._active = self._active - 1
    self._stats.processed = self._stats.processed + 1

    if ok then
      -- fn returned normally; check for (nil, err) convention
      if val == nil and err_or_second ~= nil then
        -- returned (nil, errmsg) — treat as failure/retry
        local errmsg = err_or_second
        if entry.attempts <= entry.max_retries then
          -- retry
          self._stats.retried = self._stats.retried + 1
          self._seq = self._seq + 1
          entry.eligible_at = self._tick + entry.retry_delay
          entry.key = entry.priority
          entry.seq = self._seq
          heap_push(self._heap, entry)
          results[#results + 1] = { id = entry.id, status = "retry", error = errmsg }
          emit(self, "retry", entry.id, errmsg, entry.attempts)
        else
          -- exhausted retries
          self._stats.failed = self._stats.failed + 1
          results[#results + 1] = { id = entry.id, status = "failed", error = errmsg }
          emit(self, "failure", entry.id, errmsg, entry.attempts)
        end
      else
        -- success
        self._stats.succeeded = self._stats.succeeded + 1
        results[#results + 1] = { id = entry.id, status = "success", result = val }
        emit(self, "success", entry.id, val)
      end
    else
      -- pcall caught a thrown error
      local errmsg = val  -- pcall returns error as second value
      if entry.attempts <= entry.max_retries then
        self._stats.retried = self._stats.retried + 1
        self._seq = self._seq + 1
        entry.eligible_at = self._tick + entry.retry_delay
        entry.key = entry.priority
        entry.seq = self._seq
        heap_push(self._heap, entry)
        results[#results + 1] = { id = entry.id, status = "retry", error = errmsg }
        emit(self, "retry", entry.id, errmsg, entry.attempts)
      else
        self._stats.failed = self._stats.failed + 1
        results[#results + 1] = { id = entry.id, status = "failed", error = errmsg }
        emit(self, "failure", entry.id, errmsg, entry.attempts)
      end
    end

    processed = processed + 1
  end

  return results
end

-- Advance the internal clock by 1 tick
function M:tick()
  self._tick = self._tick + 1
end

-- Number of pending tasks (excludes active tasks currently being processed)
function M:size()
  -- Count non-cancelled entries
  local count = 0
  for _, entry in ipairs(self._heap) do
    if not self._cancelled[entry.id] then
      count = count + 1
    end
  end
  return count
end

-- Number of currently active tasks
function M:active()
  return self._active
end

-- Peek at the highest-priority eligible task without removing it
function M:peek()
  -- Find the minimum eligible, non-cancelled entry
  local best = nil
  for _, entry in ipairs(self._heap) do
    if not self._cancelled[entry.id] and entry.eligible_at <= self._tick then
      if best == nil or entry.key < best.key or
         (entry.key == best.key and entry.seq < best.seq) then
        best = entry
      end
    end
  end
  return best
end

-- Cancel a task by id. Returns true if found and cancelled, false otherwise.
function M:cancel(id)
  -- Check if id exists in heap (non-cancelled)
  local found = false
  for _, entry in ipairs(self._heap) do
    if entry.id == id and not self._cancelled[id] then
      found = true
      break
    end
  end
  if not found then return false end
  self._cancelled[id] = true
  self._stats.cancelled = self._stats.cancelled + 1
  return true
end

-- Remove all pending tasks
function M:clear()
  -- Mark all as cancelled
  for _, entry in ipairs(self._heap) do
    self._cancelled[entry.id] = true
  end
  self._heap = {}
end

-- Return a copy of the stats table
function M:stats()
  return {
    processed = self._stats.processed,
    succeeded = self._stats.succeeded,
    failed = self._stats.failed,
    retried = self._stats.retried,
    cancelled = self._stats.cancelled,
  }
end

-- Subscribe to an event: "success", "failure", "retry"
function M:on(event, callback)
  if not self._listeners[event] then
    self._listeners[event] = {}
  end
  self._listeners[event][#self._listeners[event] + 1] = callback
end

return M
