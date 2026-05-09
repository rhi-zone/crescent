if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: HeapEntry = { id: unknown, fn: () -> unknown, priority: number, delay: number, eligible_at: number, attempts: integer, max_retries: integer, retry_delay: number, key: number, seq: integer }
--:: Heap = { [integer]: HeapEntry | nil, ... }
--:: QueueObj = { _heap: Heap, _active: integer, _tick: number, _seq: integer, _max_retries: integer, _retry_delay: number, _max_concurrent: integer, _listeners: { [string]: { [integer]: (...unknown) -> nil } }, _stats: { processed: integer, succeeded: integer, failed: integer, retried: integer, cancelled: integer }, _id_counter: integer, _cancelled: { [unknown]: boolean } }

-- Min-heap helpers (min by key)
--: (heap: Heap, item: HeapEntry) -> nil
local function heap_push(heap, item)
  local h = heap --[[:! { [integer]: HeapEntry }]]
  h[#h + 1] = item
  local i = #h
  while i > 1 do
    local parent = math.floor(i / 2)
    if h[parent].key > h[i].key or
       (h[parent].key == h[i].key and h[parent].seq > h[i].seq) then
      h[parent], h[i] = h[i], h[parent]
      i = parent
    else
      break
    end
  end
end

--: (heap: Heap) -> HeapEntry | nil
local function heap_pop(heap)
  local h = heap --[[:! { [integer]: HeapEntry }]]
  if #h == 0 then return nil end
  local top = h[1]
  local n = #h
  h[1] = h[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left = i * 2
    local right = i * 2 + 1
    local smallest = i
    if left <= n then
      if h[left].key < h[smallest].key or
         (h[left].key == h[smallest].key and h[left].seq < h[smallest].seq) then
        smallest = left
      end
    end
    if right <= n then
      if h[right].key < h[smallest].key or
         (h[right].key == h[smallest].key and h[right].seq < h[smallest].seq) then
        smallest = right
      end
    end
    if smallest == i then break end
    h[i], h[smallest] = h[smallest], h[i]
    i = smallest
  end
  return top
end

--: (heap: Heap) -> HeapEntry | nil
local function heap_peek(heap)
  return heap[1]
end

-- Find and remove an item by id from the heap. O(n).
--: (heap: Heap, id: unknown) -> boolean
local function heap_remove_id(heap, id)
  local h = heap --[[:! { [integer]: HeapEntry }]]
  local found = nil --: integer | nil
  for i = 1, #h do
    if h[i].id == id then
      found = i
      break
    end
  end
  if not found then return false end
  local n = #h
  h[found] = h[n]
  heap[n] = nil
  -- Re-heapify: simplest correct approach: rebuild from scratch
  local items = {} --: { [integer]: HeapEntry }
  for i = 1, #h do items[i] = h[i] end
  for i = 1, #h do heap[i] = nil end
  for _, item in ipairs(items) do
    heap_push(heap, item)
  end
  return true
end

-- Queue constructor
--: (opts: unknown) -> QueueObj
function M.new(opts)
  local opts_ = (opts or {}) --[[:! { max_retries: unknown, retry_delay: unknown, max_concurrent: unknown, ... }]]
  local q = {
    _heap = {},         -- min-heap of pending task entries
    _active = 0,        -- count of currently "running" tasks (sync: tracks within process())
    _tick = 0,          -- internal clock
    _seq = 0,           -- monotonic sequence for FIFO within same priority
    _max_retries = opts_.max_retries ~= nil and (opts_.max_retries --[[:! integer]]) or 3,
    _retry_delay = opts_.retry_delay ~= nil and (opts_.retry_delay --[[:! number]]) or 0,
    _max_concurrent = opts_.max_concurrent ~= nil and (opts_.max_concurrent --[[:! integer]]) or 1,
    _listeners = {},    -- event -> list of callbacks
    _stats = { processed = 0, succeeded = 0, failed = 0, retried = 0, cancelled = 0 },
    _id_counter = 0,    -- for auto-generated ids
    _cancelled = {},    -- set of cancelled ids
  }
  return setmetatable(q, { __index = M }) --[[:! QueueObj]]
end

-- Generate a unique id
local function gen_id(q)
  q._id_counter = q._id_counter + 1
  return q._id_counter
end

-- Push a task onto the queue. Returns the task id.
--: (self: QueueObj, task: unknown) -> (unknown, string | nil)
function M:push(task)
  if type(task) ~= "table" then
    return nil, "task must be a table"
  end
  local task_ = task --[[:! { fn: unknown, id: unknown, priority: unknown, delay: unknown, max_retries: unknown, retry_delay: unknown, ... }]]
  if type(task_.fn) ~= "function" then
    return nil, "task.fn must be a function"
  end
  local id = task_.id ~= nil and task_.id or gen_id(self)
  local priority = task_.priority ~= nil and (task_.priority --[[:! number]]) or 0
  local delay = task_.delay ~= nil and (task_.delay --[[:! number]]) or 0
  self._seq = self._seq + 1
  local entry = {
    id = id,
    fn = task_.fn --[[:! () -> unknown]],
    priority = priority,
    delay = delay,
    eligible_at = self._tick + delay,
    attempts = 0,
    max_retries = task_.max_retries ~= nil and (task_.max_retries --[[:! integer]]) or self._max_retries,
    retry_delay = task_.retry_delay ~= nil and (task_.retry_delay --[[:! number]]) or self._retry_delay,
    -- heap key = priority; seq breaks ties (FIFO)
    key = priority,
    seq = self._seq,
  } --: HeapEntry
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
--: (self: QueueObj, n: integer | nil) -> unknown
function M:process(n)
  n = n or 1
  local results = {} --: { [integer]: unknown }
  local processed = 0

  -- Collect eligible entries from the heap. Since the heap may contain
  -- ineligible tasks at the front, we need to scan for eligible ones.
  -- Build a temporary list of eligible entries, then put ineligible back.
  -- To keep O(k log m) we do a full extraction pass.
  local eligible = {} --: { [integer]: HeapEntry }
  local ineligible = {} --: { [integer]: HeapEntry }

  while #self._heap > 0 do
    local entry = heap_pop(self._heap)
    if entry == nil then break end
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
    local a_ = a --[[:! HeapEntry]]
    local b_ = b --[[:! HeapEntry]]
    if a_.key ~= b_.key then return a_.key < b_.key end
    return a_.seq < b_.seq
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
--: (self: QueueObj, id: unknown) -> boolean
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
